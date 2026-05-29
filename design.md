# Ramp → Accounting Seed: Transaction Sync Design

## Overview

This document defines the design for ingesting Ramp financial activity into Accounting Seed. It covers the three distinct Ramp sync pipelines — card transactions, bills, and reimbursements — and specifies how each maps to Accounting Seed records.

This is the second major integration phase. Phase 1 (master data sync) is implemented: vendors, GL accounts, and GL variables sync from Accounting Seed to Ramp. This document governs Phase 2: financial activity flowing from Ramp back into Accounting Seed.

---

## Scope

### In Scope

- Card transaction ingestion → Journal Entries
- Bill (AP) ingestion → Account Payables + Cash Disbursements
- Employee reimbursement ingestion → Expense Reports
- Sync state management (marking objects as synced in Ramp)
- Error handling and retry patterns
- Accounting period validation

**Why Journal Entries (not Expense Reports) for card spend:** card transactions are corporate-card spend that has already cleared the Ramp card account — the accounting effect is a direct posting (debit the expense GL, credit the Ramp card clearing GL). Expense Reports in Accounting Seed are designed for the out-of-pocket / submit-and-reimburse flow, which doesn't fit pre-cleared card spend (it would double-book the cardholder as the payee). Expense Reports are reserved for Pipeline 3 (reimbursements), which *is* an out-of-pocket flow.

### Out of Scope (MVP)

- Statement payment reconciliation (manual process)
- Cashback redemption accounting
- Accrual journal entries for unsynced period-end balances
- Multi-entity / multi-ledger support
- User/employee syncing (Ramp cardholder → Salesforce User linkage)

---

## Ramp API Sync Model

Ramp exposes three independent sync pipelines. Each must be polled separately. Objects become eligible for sync when their `sync_status` reaches a ready state.

### Polling Endpoints

```
GET /developer/v1/transactions?sync_status=SYNC_READY
GET /developer/v1/bills?sync_ready=true
GET /developer/v1/reimbursements?sync_status=SYNC_READY
```

**Bills are two-phase and use a different gating model than transactions/reimbursements.** The single `sync_ready=true` query returns anything with outstanding export work. Decide which phase(s) to post by combining the returned `bill.sync_status` with `bill.status`:

| `sync_status` | `bill.status` | What to sync |
|---|---|---|
| `NOT_SYNCED` | `OPEN` | `BILL_SYNC` (invoice only) |
| `NOT_SYNCED` | `PAID` | `BILL_SYNC` then `BILL_PAYMENT_SYNC` |
| `BILL_SYNCED` | `PAID` | `BILL_PAYMENT_SYNC` only |

### Acknowledging Sync Completion

After successfully creating records in Accounting Seed, call:

```
POST /developer/v1/accounting/syncs
```

Request body shape (verified against the OpenAPI):

```json
{
  "idempotency_key": "<uuid>",
  "sync_type": "TRANSACTION_SYNC",
  "successful_syncs": [
    { "id": "<ramp_object_uuid>", "reference_id": "<salesforce_record_id>" }
  ],
  "failed_syncs": [
    { "id": "<ramp_object_uuid>", "error": { "message": "human-readable reason" } }
  ]
}
```

`sync_type` enum values: `TRANSACTION_SYNC`, `BILL_SYNC`, `BILL_PAYMENT_SYNC`, `REIMBURSEMENT_SYNC`, `TRANSFER_SYNC`, `STATEMENT_CREDIT_SYNC`, `WALLET_TRANSFER_SYNC`, `BROKERAGE_ORDER_SYNC`. One POST per `sync_type`; up to 5,000 syncs per call. Idempotency key is required — reuse the same key on retries; Ramp dedupes server-side.

### Recommended Poll Cadence

- Weekdays: every 1–4 hours
- Weekends: every 12 hours
- On-demand: expose a manual trigger from the Ramp Configuration tab for period-end close scenarios

---

## Pipeline 1: Card Transactions → Journal Entries

### Trigger

A card transaction enters `sync_status = SYNC_READY` when the cardholder has completed all required coding (GL account, accounting variables, memo, receipt) and the transaction has been marked ready in Ramp's accounting queue.

### Routing Rule

All transactions returned by `GET /developer/v1/transactions?sync_status=SYNC_READY` are pre-cleared corporate-card spend and create **Journal Entries** in Accounting Seed.

> **Note on bill-paying card transactions:** When a Ramp card is used to pay a vendor bill, Ramp internally reclassifies that transaction as a bill payment and routes it through the Bills sync pipeline — not the Transactions pipeline. No cross-referencing or deduplication logic is required on the Accounting Seed side. The Transactions queue will only contain genuine employee card spend.

### Accounting model

Card spend posts as a balanced JE. The Ramp side (card liability or clearing) is the credit; the cardholder's coded GL is the debit:

```
Dr  Expense GL (coded on Ramp)        $X       per line_item, or one line if no splits
Cr  Ramp Card Clearing GL                  $X  one line totaling the debit side
```

For refunds (`transaction.amount < 0`), swap the sides on the same two-line JE:

```
Dr  Ramp Card Clearing GL              $X
Cr  Expense GL                              $X
```

The credit-side clearing GL is configured once in `Ramp_Sync_Settings__mdt.Card_Clearing_GL__c`. It represents the Ramp card's accumulated liability — paid down later when the statement is settled (statement reconciliation is out of scope for MVP; see Scope).

### Accounting Seed Record: Journal Entry

Each Ramp transaction creates one `AcctSeed__Journal_Entry__c` header with N+1 lines (N debit lines for the line items, plus 1 credit line for the clearing GL).

**Header Mapping (`AcctSeed__Journal_Entry__c`)**

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Date__c` | `transaction.accounting_date` ?? `transaction.user_transaction_time` | `accounting_date` is Ramp's blessed posting date |
| `AcctSeed__Type__c` | `"Journal Entry"` | Standard JE type |
| `AcctSeed__Status__c` | Configuration default (e.g. `"In Process"` or `"Approved"`) | Stored on `Ramp_Sync_Settings__mdt.Default_JE_Status__c` |
| `AcctSeed__Ledger__c` | Configuration default | Single ledger for MVP |
| `AcctSeed__Accounting_Period__c` | Derived from JE date | Match to open `AcctSeed__Accounting_Period__c`; if closed, skip (see Accounting Period Handling) |
| `AcctSeed__Memo__c` | `"Ramp – " + merchant_name + " – " + card_holder.first_name + " " + card_holder.last_name + (" – " + transaction.memo if non-blank)` | Human-readable summary |
| `AcctSeed__ExtId__c` (existing AS field) | `transaction.id` | Use the stock AS External ID field — no new custom field needed. Upsert key for one-JE-per-Ramp-transaction idempotency. |
| `Ramp_Sync_Status__c` (custom) | `"Pending"` on insert; flipped to `"Synced_To_Ramp"` after `/accounting/syncs` POST succeeds | Tracks the acknowledgment leg independently of the JE insert |
| `Ramp_Sync_Error__c` (custom) | Null on success; last error message on failure | Long Text(1000) |

No employee/user lookup is needed — JE has no employee FK. The cardholder is captured in the memo for readability and on the Ramp Sync Log row for audit, not as a hard relationship.

**Line Mapping (`AcctSeed__Journal_Entry_Line__c`)**

Ramp transactions support line-item splits. For each `line_items` entry, create one **debit** line. Then add exactly one **credit** line totaling the debit side, pointing at the configured Card Clearing GL.

**Amount units:** transaction-level `amount` is a decimal (e.g. `90.0`). `line_items[].amount` and `line_items[].converted_amount` are `CurrencyAmount` objects in minor units (cents for USD) — divide by `minor_unit_conversion_rate` (100 for USD) to convert.

**Debit lines (one per `line_items[]`, or one total if no splits):**

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Journal_Entry__c` | Parent header | Master-detail |
| `AcctSeed__GL_Account__c` | Find selection where `type=GL_ACCOUNT` on `line_item.accounting_field_selections` (fall back to transaction-level); look up `AcctSeed__GL_Account__c WHERE Ramp_Id__c = selection.id` | If unresolved, route the whole transaction to `failed_syncs[]` — do not partially post |
| `AcctSeed__Debit__c` | `line_item.amount.amount / line_item.amount.minor_unit_conversion_rate` (or `transaction.amount` if no splits). If `transaction.amount < 0`, this is a refund — populate `AcctSeed__Credit__c` with `abs(amount)` instead and leave `AcctSeed__Debit__c` null. | One of Debit/Credit must be populated, never both |
| `AcctSeed__Credit__c` | Null (or used for refund — see above) | |
| `AcctSeed__GL_Account_Variable_1__c` | Find selection on `line_item.accounting_field_selections` whose `category_info.name = "GL Account Variable 1"`; look up `AcctSeed__Accounting_Variable__c WHERE Ramp_Field_Option_Id__c = selection.id`. Fall back to transaction-level selections if absent. | |
| `AcctSeed__GL_Account_Variable_2__c` | Same pattern for Variable 2 | |
| `AcctSeed__GL_Account_Variable_3__c` | Same pattern for Variable 3 | |
| `AcctSeed__GL_Account_Variable_4__c` | Same pattern for Variable 4 | |
| `AcctSeed__Memo__c` | `line_item.memo` ?? `transaction.memo` | |
| `AcctSeed__ExtId__c` (existing AS field) | `transaction.id + ":dr:" + line_index` (or `transaction.id + ":dr:0"` if no splits) | Deterministic surrogate — gives every JE line a stable external id even though `ApiTransactionLineItem` has no Ramp-side id. Upsert key for per-line idempotency. |

**Credit line (exactly one, last):**

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Journal_Entry__c` | Parent header | |
| `AcctSeed__GL_Account__c` | `Ramp_Sync_Settings__mdt.Card_Clearing_GL__c` (resolves to an `AcctSeed__GL_Account__c`) | Single config; same for every Ramp card transaction |
| `AcctSeed__Credit__c` | Sum of all debit-line amounts. For refunds (transaction.amount < 0), populate `AcctSeed__Debit__c` instead with `abs(amount)`. | Balances the JE |
| `AcctSeed__Debit__c` | Null (or used for refund — see above) | |
| `AcctSeed__Memo__c` | `"Ramp card clearing"` | Constant |
| `AcctSeed__ExtId__c` (existing AS field) | `transaction.id + ":cr"` | Constant suffix `:cr` for the single clearing line per transaction. |

**If a transaction has no line items**, the debit side is a single line built from the transaction-level `accounting_field_selections` and `transaction.amount` (already a decimal — no cents conversion).

**Line item identifier:** `ApiTransactionLineItem` has no `id` field, only `amount`, `converted_amount`, `memo`, `accounting_field_selections`. To re-correlate lines on a re-pull, key by `(transaction.id, ordinal index in line_items)`. In practice, since the JE upserts on `Ramp_Transaction_Id__c` and we delete-and-recreate the child lines on each upsert, the ordinal is only relevant if we ever choose to do partial updates.

**Required configuration (`Ramp_Sync_Settings__mdt`):** new CMDT with a single Default record:

| Field | Type | Notes |
|---|---|---|
| `Default_Ledger__c` | Text(80) | DeveloperName/Name of the `AcctSeed__Ledger__c` to use for JEs |
| `Card_Clearing_GL__c` | Text(80) | Name of the `AcctSeed__GL_Account__c` to credit (the Ramp card liability/clearing account) |
| `Default_JE_Status__c` | Text(40) | `"In Process"` (safe default — accountant reviews before posting) or `"Approved"` |
| `Suspense_GL__c` | Text(80) | Optional — GL to use when a transaction's coded GL can't be resolved. If blank, the transaction goes to `failed_syncs[]` instead. |

### Ramp Transaction Object — Key Fields

Shape verified against the OpenAPI Transaction schema. Notable: top-level `amount` is decimal; line-item amounts are `CurrencyAmount` (cents).

```json
{
  "id": "fd14cd6a-846e-4994-9315-5a59e6bb465f",
  "amount": 90.0,
  "currency_code": "USD",
  "accounting_date": "2022-05-03T00:00:00+00:00",
  "user_transaction_time": "2022-04-28T00:00:00+00:00",
  "merchant_name": "United Airlines",
  "merchant_id": "2907e304-cac2-4abf-84c4-b3b454ae3b8c",
  "memo": "Flight to NYC - Q4 planning",
  "state": "CLEARED",
  "sync_status": "SYNC_READY",
  "card_id": "6bc41b14-f853-4862-bae5-4f122f123f6e",
  "card_holder": { "user_id": "a26c82c9-...", "first_name": "Patrick", "last_name": "Robinson" },
  "entity_id": "24850cdb-1b3f-4eb9-bf20-967ca9f97605",
  "accounting_field_selections": [
    {
      "id": "07b4ce4d-2750-412e-aef4-6b7815f1411c",
      "name": "Travel",
      "type": "GL_ACCOUNT",
      "external_id": "<ERP-side id we POSTed during chart-of-accounts upload>",
      "external_code": "...",
      "category_info": {
        "id": "0c0d0bcc-8716-4e05-a651-4ad5e64d2b3e",
        "name": "Category",
        "type": "GL_ACCOUNT"
      }
    }
  ],
  "line_items": [
    {
      "amount": { "amount": 4000, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
      "converted_amount": { "amount": 4000, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
      "memo": "Outbound segment",
      "accounting_field_selections": [
        {
          "id": "07b4ce4d-2750-412e-aef4-6b7815f1411b",
          "name": "Ramp LP",
          "type": "SUBSIDIARY",
          "category_info": { "id": "15e9565d-...", "name": "Subsidiary", "type": "SUBSIDIARY" }
        }
      ]
    }
  ]
}
```

**Notes on the real schema (vs older drafts of this doc):**
- `accounting_field_selection` uses `id`, `type`, `category_info` — there is no `custom_field` / `custom_field_option` / `remote_id` envelope.
- `selection.id` is the Ramp UUID of the *option* (look up against `Ramp_Field_Option_Id__c` on variables, or `Ramp_Id__c` on GL accounts).
- `category_info.id` is the Ramp UUID of the *field* (i.e. the parent — "GL Account Variable 1", etc.).
- `selection.external_id` / `external_code` are the ERP-side values we POSTed during the Phase 1 chart-of-accounts upload. We can use them as a secondary lookup if needed.
- The 17 `type` enum values are: `AMORTIZATION_TEMPLATE`, `BILLABLE`, `COST_CENTER`, `CUSTOMERS_JOBS`, `DEFERRAL_CODE`, `EXPENSE_ENTITY`, `GL_ACCOUNT`, `INVENTORY_ITEM`, `JOURNAL`, `MERCHANT`, `NON_ERP`, `OTHER`, `PROJECT`, `REPORTING_TAG`, `SUBSIDIARY`, `TAX_CODE`, `UNIT_OF_MEASURE`. For MVP we only act on `GL_ACCOUNT` and selections whose `category_info.name` matches `"GL Account Variable 1..4"`.

---

## Pipeline 2: Bills → Account Payables + Cash Disbursements

### Overview

Bills follow a two-step sync process. The invoice must be synced first (creating an Account Payable), then the payment syncs separately once the payment clears (creating a Cash Disbursement that closes the payable).

### Step 1: Invoice Sync → Account Payable

**Trigger:** Bill returned by `GET /developer/v1/bills?sync_ready=true` with `sync_status = NOT_SYNCED`.

**Accounting Seed Record: `AcctSeed__Account_Payable__c`**

**Amount units:** `bill.amount` is a `CurrencyAmount` object — `{ "amount": 96993, "currency_code": "USD", "minor_unit_conversion_rate": 100 }`. Divide `amount.amount` by `amount.minor_unit_conversion_rate` (100 for USD) to get the posted dollar value. Same for every line-item amount.

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Vendor__c` | `bill.vendor.id` → `Account.Ramp_Vendor_Id__c` | Lookup by stored Ramp vendor UUID. `bill.vendor` is an `ApiBillVendor` object whose `id` is required. |
| `AcctSeed__AP_Date__c` | `bill.accounting_date` ?? `bill.issued_at` | `issued_at`, not `issue_date` |
| `AcctSeed__Due_Date__c` | `bill.due_at` | |
| `AcctSeed__Accounting_Period__c` | Derived from AP date | Match to open period |
| `AcctSeed__Ledger__c` | Configuration default | |
| `AcctSeed__Invoice_Number__c` | `bill.invoice_number` | |
| `AcctSeed__Memo__c` | `bill.memo` | |
| `Ramp_Bill_Id__c` (custom) | `bill.id` | External ID; prevents duplicates |

**Line Mapping (`AcctSeed__Account_Payable_Line__c`)**

Bills have two parallel line-item arrays in the response: `line_items` (regular line items, fields: `accounting_field_selections`, `amount`, `memo`) and `inventory_line_items` (additionally include `quantity` and `unit_price`). Process **both** — flatten into a single set of AP lines. For MVP we ignore `quantity` / `unit_price` and just post the line `amount`, but the schema needs an inventory-line iteration step to avoid silently dropping those lines.

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Account_Payable__c` | Parent | |
| `AcctSeed__Amount__c` | `line_item.amount.amount / line_item.amount.minor_unit_conversion_rate` | CurrencyAmount → decimal |
| `AcctSeed__GL_Account__c` | Find selection on `line_item.accounting_field_selections` where `type=GL_ACCOUNT`; look up `AcctSeed__GL_Account__c WHERE Ramp_Id__c = selection.id` | |
| `AcctSeed__GL_Account_Variable_1__c` | Find selection whose `category_info.name = "GL Account Variable 1"`; look up `AcctSeed__Accounting_Variable__c WHERE Ramp_Field_Option_Id__c = selection.id` | |
| `AcctSeed__GL_Account_Variable_2__c` | Same pattern | |
| `AcctSeed__GL_Account_Variable_3__c` | Same pattern | |
| `AcctSeed__GL_Account_Variable_4__c` | Same pattern | |
| `AcctSeed__Memo__c` | `line_item.memo` | |
| `AcctSeed__Project__c` | If project dimension is configured | Optional |

After successful insert, POST sync acknowledgment with `sync_type: "BILL_SYNC"` (see `POST /developer/v1/accounting/syncs` shape above; `id` = `bill.id`, `reference_id` = the inserted AP record's Salesforce Id).

### Step 2: Payment Sync → Cash Disbursement + AP Disbursement

**Trigger:** Bill returned by `GET /developer/v1/bills?sync_ready=true` with `sync_status = BILL_SYNCED` and `bill.status = PAID` (i.e. invoice already synced in Step 1, payment now ready). Bills can also be in `sync_status = NOT_SYNCED` + `status = PAID` — those need both phases in one pass.

**Two AS records per cleared payable, plus optional batch:**

```
AcctSeed__Cash_Disbursement_Batch__c     (optional; one per sync run if opt-in)
  └─ AcctSeed__Cash_Disbursement__c      (one per unique customer_friendly_payment_id)
        └─ AcctSeed__AP_Disbursement__c  (one per (payable, payment) pair — the junction)
```

There is no `bill.details` object. Payment information lives in:
- `bill.paid_at` (datetime, top-level) — set when the bill's payment status is `PAID`.
- `bill.payment` (singular, legacy) — first non-vendor-credit payment.
- `bill.payments[]` (array) — full list of payments. A single bill may have several (partial payments). A single payment may also span multiple bills — Ramp exposes a `customer_friendly_payment_id` filter on `GET /bills` to fetch all bills "belonging to the same payment".

**Grouping strategy:** for each page of bills returned with payment-phase work to do, group all `bill.payments[]` entries across the page by `customer_friendly_payment_id`. Each unique payment id becomes one Cash Disbursement; every bill that participated in that payment becomes one AP Disbursement under that CD.

#### `AcctSeed__Cash_Disbursement__c` mapping (one per unique `customer_friendly_payment_id`)

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Disbursement_Date__c` | `payment.payment_date` (or `payment.effective_date`) | |
| `AcctSeed__Amount__c` | Sum of `payment.amount.amount / minor_unit_conversion_rate` across all bills sharing this payment id | The CD total equals what actually left the bank account |
| `AcctSeed__Bank_Account__c` | Configuration default (`Ramp_Sync_Settings__mdt.Default_Bank_Account_GL__c`) | The bank GL the money came from |
| `AcctSeed__Accounting_Period__c` | Derived from payment date | |
| `AcctSeed__Type__c` | Derived from `payment.payment_method` (see mapping below) | AS Cash Disbursement Type picklist values are typically `"Check"`, `"Electronic"`, `"Credit Card"` |
| `AcctSeed__Reference__c` | `customer_friendly_payment_id` (e.g. `"A6PMDVX628"`) | Stored as both Reference (for AP screens) and `AcctSeed__ExtId__c` (for upsert key) |
| `AcctSeed__Memo__c` | `"Ramp Bill Pay – " + vendor_name(s) + " (" + payment.payment_method + ")"` | `payment_method` enum: ACH, CARD, CHECK, DOMESTIC_WIRE, INTERNATIONAL, LOCAL_BANK_TRANSFER, ONE_TIME_CARD, PAID_MANUALLY, SWIFT |
| `AcctSeed__Cash_Disbursement_Batch__c` | The current sync run's batch (if `Group_Disbursements_Into_Batch__c = true`), else null | Optional grouping for AS batch workflows |
| `AcctSeed__ExtId__c` | `customer_friendly_payment_id` | Upsert key; repeats across passes safely |

**Payment method → CD type mapping** (rough — confirm exact AS picklist values per org):

| Ramp `payment_method` | AS `Type` |
|---|---|
| `ACH`, `DOMESTIC_WIRE`, `SWIFT`, `INTERNATIONAL`, `LOCAL_BANK_TRANSFER` | Electronic |
| `CHECK` | Check |
| `CARD`, `ONE_TIME_CARD`, `ONE_TIME_CARD_DELIVERY` | Credit Card |
| `PAID_MANUALLY` | Electronic (with a memo note that it was manual) |

#### `AcctSeed__AP_Disbursement__c` mapping (one per (payable, payment) pair — the junction)

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Cash_Disbursement__c` | The CD created above for this `customer_friendly_payment_id` | Master |
| `AcctSeed__Account_Payable__c` | Lookup by `AcctSeed__ExtId__c = bill.id` | Master — links to the AP created in Step 1 |
| `AcctSeed__Amount__c` | The portion of the CD that paid *this* payable: `bill.payments[matching].amount.amount / minor_unit_conversion_rate` | Sum across all AP Disbursements under one CD must equal the CD's `AcctSeed__Amount__c` |
| `AcctSeed__ExtId__c` | `<bill.id>:apd:<customer_friendly_payment_id>` | Upsert key |

After successful insert(s) of CDs + AP Disbursements, POST sync acknowledgment with `sync_type: "BILL_PAYMENT_SYNC"`. Per the ERP guide, the `successful_syncs[].id` is still the **bill's** UUID (not a payment id or AP Disbursement id) — the bill is the carrier object that owns the payment lifecycle. `successful_syncs[].reference_id` should be the Cash Disbursement's Salesforce Id (the visible AS record for the payment).

If multiple bills shared one Ramp payment, send one `successful_syncs[]` entry per bill, all with the same `reference_id` (the shared CD's SF Id). Ramp's `/accounting/syncs` endpoint handles this fine — it acknowledges each bill independently.

### Ramp Bill Object — Key Fields

Shape verified against the OpenAPI `Bill` schema.

```json
{
  "id": "6e3816e3-0e53-42ae-b075-bdb0adff10c4",
  "invoice_number": "INV-2025-001",
  "amount": { "amount": 96993, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
  "due_at": "2022-12-31T00:00:00+00:00",
  "issued_at": "2022-12-31T00:00:00+00:00",
  "accounting_date": "2024-05-12T00:00:00+00:00",
  "posting_date": "2024-05-12T00:00:00+00:00",
  "paid_at": "2024-05-15T14:02:28.298Z",
  "status": "OPEN",
  "status_summary": "PAYMENT_SCHEDULED",
  "sync_status": "NOT_SYNCED",
  "approval_status": "APPROVED",
  "vendor": {
    "id": "<vendor-ramp-uuid>",
    "name": "Acme Corp",
    "remote_id": "AMZON12",
    "remote_name": "Amazon",
    "type": "BUSINESS"
  },
  "payment": {
    "amount": { "amount": 96993, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
    "customer_friendly_payment_id": "A6PMDVX628",
    "effective_date": "2024-05-13T00:00:00+00:00",
    "payment_date": "2024-05-13T00:00:00+00:00",
    "payment_method": "ACH",
    "trace_id": { "descriptor": "ACH Trace ID", "trace_id": "076921900257224" }
  },
  "payments": [ /* zero or more entries with the same shape as `payment` */ ],
  "line_items": [
    { "amount": { "amount": 1998, "currency_code": "USD", "minor_unit_conversion_rate": 100 }, "memo": "...", "accounting_field_selections": [] }
  ],
  "inventory_line_items": [
    { "amount": {...}, "memo": "...", "quantity": 5, "unit_price": {...}, "accounting_field_selections": [] }
  ],
  "accounting_field_selections": [],
  "enable_accounting_sync": true,
  "remote_id": null
}
```

**Field corrections worth noting (vs older drafts of this doc):**
- `issued_at`, not `issue_date`.
- No `bill.details` object exists. Payment info is at `bill.paid_at` (top-level), `bill.payment` (singular legacy), and `bill.payments[]` (array).
- `bill.amount` is a `CurrencyAmount` with `minor_unit_conversion_rate`, not a raw number.
- `bill.vendor.id` is a required uuid (confirmed in `ApiBillVendor` schema), so the `Ramp_Vendor_Id__c` lookup is valid.
- `customer_friendly_payment_id` (e.g. `"A6PMDVX628"`) is the closest thing to a "payment id" we can show users — there is no separate payment uuid in the response.

> **Note on card transactions that pay a bill:** When a Ramp card is used to pay a vendor bill, Ramp internally reclassifies that transaction as a bill payment and routes it through the Bills sync pipeline — not the Transactions pipeline. Those transactions are excluded from `GET /developer/v1/transactions?sync_status=SYNC_READY`. No cross-referencing or deduplication logic is required on the Accounting Seed side.

---

## Pipeline 3: Reimbursements → Expense Reports

### Decision

Employee reimbursements (out-of-pocket expenses submitted for repayment) create **Expense Reports** in Accounting Seed. Reimbursements are the only pipeline that maps to Expense Reports — card spend (Pipeline 1) and bills (Pipeline 2) post directly as Journal Entries and Account Payables respectively.

> **Alternative considered:** Creating vendor bills with the employee as vendor (the industry norm in NetSuite/Sage integrations). This was rejected because Accounting Seed's Expense Report object is purpose-built for employee out-of-pocket spend, carries the employee relationship natively, and avoids polluting the vendor master with employee records.

### Trigger

A reimbursement reaches `sync_status = SYNC_READY` when it has been approved and payment has been initiated (or approved for manual payment).

### Filter: skip paybacks for MVP

The `Reimbursement.type` enum has 5 values: `MILEAGE`, `OUT_OF_POCKET`, `PAYBACK_FULL`, `PAYBACK_PARTIAL`, `PER_DIEM`. `PAYBACK_*` reimbursements are credits from an employee back to the company (e.g. clawback of a misused card spend) and are linked to existing transactions/reimbursements — posting them as fresh Expense Reports would double-book the original expense. For MVP, **skip** reimbursements where `type` starts with `PAYBACK_`. Log them to the Sync Log with status `SKIPPED` and **do not** POST to `/accounting/syncs` (leave them in the Ramp queue for manual handling).

Similarly, `direction = USER_TO_BUSINESS` represents an inflow to the business; we don't handle that for MVP. Skip with the same pattern.

### Accounting Seed Record: Expense Report

Each Ramp reimbursement creates one `AcctSeed__Expense_Report__c` header with one or more `AcctSeed__Expense_Report_Line__c` records.

**Header Mapping (`AcctSeed__Expense_Report__c`)**

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Employee__c` | `reimbursement.user_id` (or `reimbursement.employee_id`) → resolved to a Salesforce User/Contact via `Ramp_User_Id__c` | **Blocker — see Open Questions.** This requires a Ramp-user-to-SF-user mapping. Without it, the Expense Report cannot be created (the field is typically required). Either (a) ship Pipeline 3 only after a user-sync feature exists, (b) use a configured "Ramp default employee" fallback for unmapped users, or (c) defer Pipeline 3 to a later release. |
| `AcctSeed__Expense_Report_Date__c` | `reimbursement.accounting_date` ?? `reimbursement.transaction_date` | |
| `AcctSeed__Accounting_Period__c` | Derived from date | Match to open period |
| `AcctSeed__Ledger__c` | Configuration default (shared with Pipeline 1) | Single ledger for MVP |
| `Name` | `"Ramp Reimbursement – " + user_full_name + " – " + transaction_date` | |
| `Ramp_Reimbursement_Id__c` (custom) | `reimbursement.id` | External ID, Unique |
| `Ramp_Reimbursement_State__c` (custom, optional) | `reimbursement.state` | Stores raw Ramp state (23 enum values: `APPROVED`, `AWAITING_PAYMENT`, `REIMBURSED`, `PUSH_PAYMENT_FAILED`, etc.) for downstream visibility/filtering |

**Line Mapping (`AcctSeed__Expense_Report_Line__c`)**

Each `reimbursement.line_items[]` entry creates one Expense Report Line. If `line_items` is empty, fall back to a single line built from the reimbursement-level `accounting_field_selections` and `original_reimbursement_amount` (or top-level `amount`).

| Accounting Seed Field | Source | Notes |
|---|---|---|
| `AcctSeed__Expense_Report__c` | Parent header | |
| `AcctSeed__Amount__c` | `line_item.amount.amount / line_item.amount.minor_unit_conversion_rate` | Line items are `CurrencyAmount` (cents); top-level `reimbursement.amount` is a decimal — use the per-line CurrencyAmount when present |
| `AcctSeed__GL_Account__c` | Find selection where `type=GL_ACCOUNT`; look up by `Ramp_Id__c = selection.id` | Same resolution rule as Pipelines 1 & 2 |
| `AcctSeed__GL_Account_Variable_1..4__c` | Same pattern by `category_info.name` | |
| `AcctSeed__Memo__c` | `line_item.memo` ?? `reimbursement.memo` | |

**On `state`:** Ramp does not expose a `payment_status` field. The closest is `state`. If we capture state on the Expense Report, store the raw value and decide visibility/filtering downstream.

### Ramp Reimbursement Object — Key Fields

Shape verified against the OpenAPI `Reimbursement` schema. Note the heterogeneous amount handling: top-level `amount` is a decimal, but every nested `*Amount` is a `CurrencyAmount` in minor units.

```json
{
  "id": "d47ba06e-14ac-4a7b-89b4-4775412ba545",
  "amount": 484.46,
  "currency": "USD",
  "type": "OUT_OF_POCKET",
  "direction": "BUSINESS_TO_USER",
  "state": "REIMBURSED",
  "sync_status": "SYNC_READY",
  "user_id": "7979392e-8d41-4f97-815b-ccd7584802bf",
  "employee_id": "...",
  "user_full_name": "Dwight Schrute",
  "user_email": "dwight@dundermilflin.com",
  "merchant": "Delta Airlines",
  "merchant_id": "752ba160-72f0-4935-b405-7fc333b1e273",
  "memo": "Airfare for business travel",
  "transaction_date": "2022-08-19",
  "accounting_date": null,
  "submitted_at": "2023-08-20T:00:00+00:00",
  "approved_at": "...",
  "payment_id": "NDPHKHCN6G",
  "payment_batch_id": "ef025463-050a-460b-a62a-f242876e8ce0",
  "payment_processed_at": "2023-08-22T:00:00+00:00",
  "original_reimbursement_amount": { "amount": 48446, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
  "payee_amount": { "amount": 48446, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
  "entity_id": "4bec9dc1-710e-4781-b254-fc606c76a241",
  "accounting_field_selections": [],
  "line_items": [
    {
      "amount": { "amount": 43446, "currency_code": "USD", "minor_unit_conversion_rate": 100 },
      "accounting_field_selections": []
    }
  ]
}
```

**Field corrections (vs older drafts):** there is no nested `employee` object — use `user_id` / `user_full_name` / `user_email`. There is no `payment_status` — use `state`. `merchant` is a flat string; `merchant_id` is a separate optional uuid.

---

## Sync Architecture

### Direction

All three pipelines are **Ramp → Accounting Seed** (inbound). This is the reverse direction from Phase 1 (master data sync was Salesforce → Ramp).

### Execution Model

**Chained Queueables** for each pipeline, not Batchable. Rationale: the source data is a cursor-paginated REST API, not a SOQL queryable — `Database.QueryLocator` doesn't fit. Each enqueue handles exactly one page of the Ramp response, which keeps each Apex transaction well under the callout limit (max 100/transaction) and the 10-second cumulative HTTP timeout, while still allowing the pipeline to drain an arbitrarily long queue across many transactions.

```
RampTransactionSyncQueueable      implements Queueable, Database.AllowsCallouts
RampBillSyncQueueable             implements Queueable, Database.AllowsCallouts
RampReimbursementSyncQueueable    implements Queueable, Database.AllowsCallouts
```

Per-enqueue flow:
1. Call the Ramp list endpoint for one page (page size 100), passing the cursor from the prior enqueue (or null for page 1).
2. Resolve all GL / variable / vendor lookups in one bulked SOQL pass.
3. Build Accounting Seed records and `Database.upsert(..., externalIdField, allOrNone=false)` so a single bad record doesn't sink the page.
4. POST `/developer/v1/accounting/syncs` once for the page (with `successful_syncs[]` and `failed_syncs[]`).
5. Write per-record results to `Ramp_Sync_Log__c`.
6. If `page.next` is non-null, `System.enqueueJob(new <Pipeline>SyncQueueable(nextCursor))`. Otherwise, the chain ends.

Scheduled jobs (`Schedulable`) enqueue page 1 of each pipeline on the configured cadence; everything after page 1 happens in the chain.

This is a deliberate departure from the existing `RampVendorSyncBatch` / `RampFieldOptionsSyncBatch` pattern, which use `Database.Batchable`. Those classes drive off a SOQL `start()` query (rows we already have locally); inbound sync drives off a REST cursor (rows we don't have until we ask Ramp). The two access patterns warrant different concurrency primitives.

### Pagination

Ramp uses cursor-based pagination. Each response includes a `page.next` value to pass as `?start=<cursor>` on the next call. Default page size is 20; max is 100. We always request `page_size=100` and let the Queueable chain drain the cursor.

### Scheduling

Register each batch class with `System.schedule()` on a configurable cron. Expose schedule management in the Ramp Configuration tab.

Recommended defaults:
- Transaction sync: every 4 hours on weekdays, every 12 hours on weekends
- Bill sync: every 2 hours (time-sensitive for vendor payment confirmation)
- Reimbursement sync: every 4 hours

### Idempotency

Every Accounting Seed record we land uses an External-ID field as the upsert key. Where Accounting Seed already ships `AcctSeed__ExtId__c` (confirmed on `AcctSeed__Journal_Entry__c` and `AcctSeed__Journal_Entry_Line__c`; verify per object for the others), use it directly. Where it doesn't exist, add the per-pipeline custom field listed in the Data Model section.

| Pipeline | Object | Upsert key | Value |
|---|---|---|---|
| 1 — Card transactions (header) | `AcctSeed__Journal_Entry__c` | `AcctSeed__ExtId__c` | `transaction.id` |
| 1 — Card transactions (debit line) | `AcctSeed__Journal_Entry_Line__c` | `AcctSeed__ExtId__c` | `<transaction.id>:dr:<N>` |
| 1 — Card transactions (credit line) | `AcctSeed__Journal_Entry_Line__c` | `AcctSeed__ExtId__c` | `<transaction.id>:cr` |
| 2a — Bill invoice | `AcctSeed__Account_Payable__c` | `AcctSeed__ExtId__c` | `bill.id` |
| 2a — Bill invoice lines | `AcctSeed__Account_Payable_Line__c` | `AcctSeed__ExtId__c` | `<bill.id>:line:<N>` / `<bill.id>:inv:<N>` |
| 2b — Bill payment (CD) | `AcctSeed__Cash_Disbursement__c` | `AcctSeed__ExtId__c` | `customer_friendly_payment_id` (one CD per unique Ramp payment) |
| 2b — Bill payment (junction) | `AcctSeed__AP_Disbursement__c` | `AcctSeed__ExtId__c` | `<bill.id>:apd:<customer_friendly_payment_id>` |
| 2b — Disbursement batch (optional) | `AcctSeed__Cash_Disbursement_Batch__c` | `AcctSeed__ExtId__c` | `"ramp:sync:<sync_run_uuid>"` |
| 3 — Reimbursements (header) | `AcctSeed__Expense_Report__c` | `AcctSeedRamp__External_Id__c` (new custom field) | `reimbursement.id` |
| 3 — Reimbursements (lines) | `AcctSeed__Expense_Report_Line__c` | `AcctSeedRamp__External_Id__c` (new custom field) | `<reimbursement.id>:line:<N>` |

Use `Database.upsert(records, externalIdField, allOrNone=false)` so a single bad record doesn't sink the page.

**Child lines on re-pull:** because every child line carries a deterministic composite external ID, we can **upsert child lines directly** rather than deleting and recreating them. The ordinal in the composite key is stable as long as Ramp returns the line items in the same order on each pull (which the API guarantees). If a transaction's line count *decreases* between pulls (e.g. user removed a split), we still need to delete the now-orphaned lines — query for child lines whose `AcctSeed__ExtId__c` starts with the parent's external ID but doesn't appear in the current upsert payload, and delete those.

If the parent JE / AP / ER is already posted in Accounting Seed (immutable), skip the upsert entirely and log to `Ramp_Sync_Log__c` with `SKIPPED`.

---

## Data Model Additions Required

### Use the stock AS `AcctSeed__ExtId__c` external-ID field where it exists

Accounting Seed ships `AcctSeed__ExtId__c` (Text, External ID) on the transactional objects Pipelines 1 and 2 target:

- `AcctSeed__Journal_Entry__c`
- `AcctSeed__Journal_Entry_Line__c`
- `AcctSeed__Account_Payable__c`
- `AcctSeed__Account_Payable_Line__c`
- `AcctSeed__Cash_Disbursement__c`
- `AcctSeed__Cash_Disbursement_Batch__c` (master grouping object — `AcctSeed__Cash_Disbursement__c` is its child; one batch can hold many CDs from the same sync run)
- `AcctSeed__AP_Disbursement__c` (the junction object linking Cash Disbursement ↔ Account Payable; one CD may pay several payables via multiple AP Disbursements)

We use the stock field directly as the upsert key for those objects — no new field needed. Benefits:

- No new field metadata to deploy on objects that already have one.
- Plays cleanly with other AS integrations that key off the same field.
- Surfaces in standard AS list views and reports without any LWC/Permission-Set churn.

The Expense Report objects (Pipeline 3) do **not** ship with `AcctSeed__ExtId__c`, so we add equivalent fields ourselves following the same pattern (see below).

**AS Cash Disbursement data model (clarification):**

```
AcctSeed__Cash_Disbursement_Batch__c    (master, optional grouping)
   └─ AcctSeed__Cash_Disbursement__c    (one money-out event — e.g. one ACH wire)
         └─ AcctSeed__AP_Disbursement__c (junction; one row per payable cleared by this CD)
                └─ AcctSeed__Account_Payable__c
```

A single CD can clear multiple payables (a vendor paid for three invoices in one ACH is one CD with three AP Disbursements). This matches Ramp's payment model — `customer_friendly_payment_id` filters bills "belonging to the same payment", so multiple bills can share one Ramp payment, and we mirror that as one CD with N AP Disbursements.

**Naming convention for composite external IDs** (when a single Ramp object spans multiple AS records): `"<ramp-uuid-or-id>:<discriminator>[:<ordinal>]"`. Examples:
- JE header: `<transaction.id>`
- JE debit line N: `<transaction.id>:dr:<N>`
- JE credit (clearing) line: `<transaction.id>:cr`
- Bill line: `<bill.id>:line:<N>` / inventory line: `<bill.id>:inv:<N>`
- Cash Disbursement (one per unique Ramp payment): `<customer_friendly_payment_id>` (Ramp's payment id is already a stable, human-readable identifier — e.g. `"A6PMDVX628"`)
- AP Disbursement (one per cleared payable): `<bill.id>:apd:<customer_friendly_payment_id>`
- Cash Disbursement Batch (one per sync run, if grouping is enabled): `"ramp:sync:<sync_run_uuid>"`

### Per-object field plan

**`AcctSeed__Journal_Entry__c`** (Pipeline 1 — card transactions)
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores `transaction.id`.
- New: `Ramp_Sync_Status__c` — Picklist (Pending, Synced_To_Ramp, Failed). Tracks the `/accounting/syncs` acknowledgment leg independently of the JE insert.
- New: `Ramp_Sync_Error__c` — Long Text(1000). Last failure message; nulled on next successful retry.

**`AcctSeed__Journal_Entry_Line__c`**
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores the composite key (`<transaction.id>:dr:<N>` or `<transaction.id>:cr`). This gives every JE line a stable external id even though `ApiTransactionLineItem` has no Ramp-side id, enabling clean per-line upsert on re-pull rather than delete-and-recreate.

**`AcctSeed__Account_Payable__c`**
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores `bill.id`. No new field.

**`AcctSeed__Account_Payable_Line__c`**
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores composite (`<bill.id>:line:<N>` for regular line items, `<bill.id>:inv:<N>` for inventory line items). No new field.

**`AcctSeed__Cash_Disbursement__c`**
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores `<customer_friendly_payment_id>` (one CD per unique Ramp payment). If two bills share a `customer_friendly_payment_id`, the upsert is a no-op on the second pass — the existing CD is just linked to via a new AP Disbursement.
- No new field.

**`AcctSeed__AP_Disbursement__c`** (the junction — one row per payable cleared by a CD)
- Use stock `AcctSeed__ExtId__c` as the upsert key — stores composite `<bill.id>:apd:<customer_friendly_payment_id>`. One AP Disbursement per (payable, payment) pair.
- No new field.

**`AcctSeed__Cash_Disbursement_Batch__c`** (optional grouping; opt-in)
- If `Ramp_Sync_Settings__mdt.Group_Disbursements_Into_Batch__c = true`, create one batch per sync run and parent the new CDs to it. Upsert by `AcctSeed__ExtId__c = "ramp:sync:<sync_run_uuid>"`.
- Off by default for MVP — most customers process CDs individually and would find auto-batching surprising.

**`AcctSeed__Expense_Report__c`** (Pipeline 3 — reimbursements)
- **New custom field:** `External_Id__c` — Text(80), External ID, Unique. Follows the same purpose as the stock `AcctSeed__ExtId__c` on JE / AP / CD. Stores `reimbursement.id`. Under the project namespace (`AcctSeedRamp`), this deploys as `AcctSeedRamp__External_Id__c`.
- New: `Ramp_Reimbursement_State__c` — Text(40), optional. Stores the raw `reimbursement.state` value (23 enum values).

**`AcctSeed__Expense_Report_Line__c`**
- **New custom field:** `External_Id__c` — Text(80), External ID, Unique. Stores composite `<reimbursement.id>:line:<N>`.

**Collision risk to flag:** `AcctSeed__ExtId__c` is shared with any other AS-bound integration the customer may have wired up (e.g. a payroll connector also populating the same field). For each object we use it on, we should make sure the integration only upserts on rows whose `AcctSeed__ExtId__c` value starts with a Ramp-distinguishable prefix — either the bare UUID format (no other integration uses raw uuids), or we prefix with `"ramp:"` and update all Ramp-side reads/writes to match. Our own `External_Id__c` on the Expense Report objects is namespaced (`AcctSeedRamp__External_Id__c`) so collisions there are limited to customers who installed multiple instances of our package, which is structurally prevented.

### New Custom Metadata Type: `Ramp_Sync_Settings__mdt`

Single Default record. Holds runtime configuration for the inbound pipelines.

| Field | Type | Purpose |
|---|---|---|
| `Default_Ledger__c` | Text(80) | Name of the `AcctSeed__Ledger__c` used for all JEs / APs / ERs |
| `Card_Clearing_GL__c` | Text(80) | Name of the `AcctSeed__GL_Account__c` to credit for Pipeline 1 card spend |
| `Default_Bank_Account_GL__c` | Text(80) | Name of the `AcctSeed__GL_Account__c` (or `AcctSeed__Bank__c`) used for Cash Disbursements in Pipeline 2 |
| `Group_Disbursements_Into_Batch__c` | Checkbox, default false | If true, every Pipeline 2 sync run creates an `AcctSeed__Cash_Disbursement_Batch__c` and parents all new CDs to it. Off by default — most customers process CDs individually. |
| `Default_JE_Status__c` | Text(40) | `"In Process"` or `"Approved"` |
| `Suspense_GL__c` | Text(80), optional | Fallback GL when a coded `GL_ACCOUNT` selection can't be resolved. If blank, the unresolved transaction goes to `failed_syncs[]` instead. |
| `Default_Employee_For_Reimbursements__c` | Text(80), optional | Fallback for Pipeline 3 when `reimbursement.user_id` can't be mapped to an SF User. If blank, the reimbursement goes to `failed_syncs[]`. |

### New Custom Object: Ramp Sync Log

Captures sync outcomes for visibility, audit, and retry handling.

| Field | Type | Purpose |
|---|---|---|
| `Ramp_Object_Id__c` | Text(100), External ID | Ramp UUID of synced object |
| `Ramp_Object_Type__c` | Picklist | TRANSACTION, BILL, BILL_PAYMENT, REIMBURSEMENT |
| `Salesforce_Record_Id__c` | Text(18) | ID of created/updated AS record |
| `Sync_Status__c` | Picklist | SUCCESS, FAILED, SKIPPED |
| `Error_Message__c` | Long Text | Stack trace or API error |
| `Synced_At__c` | DateTime | Timestamp of sync attempt |
| `Accounting_Period__c` | Lookup | Accounting period the record landed in |

### Permission Set Updates (`Ramp_Admin`)

Add field-level permissions for all new custom fields across all five objects above.

---

## Accounting Period Handling

Before creating any Accounting Seed record, validate that the target period is open.

```apex
// Pseudocode
AcctSeed__Accounting_Period__c period = getPeriodForDate(transactionDate);
if (period == null || period.AcctSeed__Status__c == 'Closed') {
    // Log to Ramp Sync Log with status SKIPPED
    // Do NOT call POST /accounting/syncs — leave the object in SYNC_READY
    // Surface in Ramp Configuration tab for manual resolution
}
```

Objects skipped due to closed periods should remain in Ramp's sync queue and be retried on the next poll cycle. When a period is reopened (or the accounting date is adjusted), the record will be picked up automatically.

---

## Vendor Resolution

When processing a bill, the vendor must resolve to an Accounting Seed Account. Resolution logic:

1. Look up `Account` by `Ramp_Vendor_Id__c = bill.vendor.id` — the stored Ramp vendor ID from Phase 1 sync
2. If not found, check `Account.Name = bill.vendor.name` (fuzzy fallback, only if unique match)
3. If still not found, create a Ramp Sync Conflict record for manual resolution and skip the bill

Do not auto-create vendor records on bill ingestion. Vendor creation remains manual or via the explicit vendor sync pipeline.

---

## GL Account and Variable Resolution

Accounting field selections on transactions, bills, and reimbursements share the `ApiTransactionAccountingFieldSelection` / `ApiReimbursementAccountingFieldSelection` shape:

```json
{
  "id": "<option ramp uuid>",
  "name": "Travel",
  "type": "GL_ACCOUNT",
  "external_id": "<the value we POSTed during chart-of-accounts upload>",
  "external_code": "...",
  "category_info": {
    "id": "<field ramp uuid>",
    "name": "GL Account Variable 1",
    "type": "GL_ACCOUNT"
  }
}
```

Resolution uses Phase 1's stored Ramp UUIDs as the lookup key — **not** `remote_id` / `external_id`:

| What we're resolving | Phase 1 storage | Lookup |
|---|---|---|
| GL account | `RampGLAccountService` populated `AcctSeed__GL_Account__c.Ramp_Id__c` with the Ramp UUID returned at upload | `SELECT Id FROM AcctSeed__GL_Account__c WHERE Ramp_Id__c = :selection.id` (the option's `id`, filtered to selections with `type = GL_ACCOUNT`) |
| GL Account Variable 1–4 | `RampFieldOptionsSyncBatch` populated `AcctSeed__Accounting_Variable__c.Ramp_Field_Option_Id__c` with the Ramp UUID; the variable's own `AcctSeed__Type__c` is `"GL Account Variable N"` | `SELECT Id, AcctSeed__Type__c FROM AcctSeed__Accounting_Variable__c WHERE Ramp_Field_Option_Id__c = :selection.id` — the variable's `AcctSeed__Type__c` determines which JE/ERL column (`AcctSeed__GL_Account_Variable_1..4__c`) gets the value |

If we can't resolve a selection (stale `Ramp_Id__c` / `Ramp_Field_Option_Id__c` — e.g. record deleted in Salesforce after being uploaded to Ramp), we have two fallbacks:
1. Try `external_id`: for variables, `RampFieldOptionsSyncBatch` sends the SF Id as `code` — we can re-resolve by querying for that SF Id directly.
2. If still unresolved, log to Ramp Sync Log with status `FAILED` and add to the `failed_syncs[]` array of the `/accounting/syncs` POST so the user sees an Export Error in the Ramp UI.

Do not use `selection.id` (Ramp UUID) as the Salesforce record ID directly — Phase 1 did not populate it that way, and the two ID formats are different lengths and character sets.

---

## Error Handling

### Per-Record Errors

Errors on individual records must not abort the batch. Use `Database.AllowsCallouts` with try/catch per record. Log each failure to the Ramp Sync Log object.

Common error scenarios:

| Error | Handling |
|---|---|
| Accounting period closed | Skip + log; leave in Ramp sync queue |
| Vendor not found | Skip + log; create conflict record |
| GL account not found (stale `remote_id`) | Skip + log; surface in Configuration tab |
| Duplicate external ID (already synced) | Upsert safely overwrites; not an error |
| Ramp API 429 (rate limit) | Abort batch; reschedule with backoff |
| Ramp API 5xx | Abort batch; retry on next scheduled run |
| Accounting Seed DML exception | Log specific records; continue batch |

### Visibility

Expose a "Sync Errors" section in the Ramp Configuration tab showing records in `FAILED` status from the Ramp Sync Log, with error messages and a manual re-try trigger.

---

## Sync Acknowledgment Flow

The following sequence must complete for each page of synced objects:

```
1. Fetch one page of ready-to-sync objects from Ramp
2. Per record: create/upsert Accounting Seed record (allOrNone=false)
3. Per record: write outcome to Ramp_Sync_Log__c
4. Per page: POST /developer/v1/accounting/syncs   (one call per sync_type)

   {
     "idempotency_key": "<page-uuid-generated-once>",
     "sync_type": "TRANSACTION_SYNC",
     "successful_syncs": [
       { "id": "<ramp_uuid>", "reference_id": "<salesforce_record_id>" },
       ...
     ],
     "failed_syncs": [
       { "id": "<ramp_uuid>", "error": { "message": "Vendor not found for bill" } },
       ...
     ]
   }

5. Ramp removes successfully-synced objects from sync queue; failed ones surface as Export Errors in the Ramp UI
6. If page.next is non-null, enqueue next page
```

If step 4 fails after step 2 succeeds, the objects will re-appear on the next poll. The upsert on `Ramp_*_Id__c` ensures no duplicate AS record is created. Step 4 should be retried independently rather than rolling back step 2.

**Idempotency key:** generate one UUID per page (per `/accounting/syncs` POST). On retry of the same page, reuse the same key — Ramp dedupes server-side per the ERP Integrations guide.

**`sync_type` per pipeline:**
- Card transactions → `TRANSACTION_SYNC`
- Bill invoice phase → `BILL_SYNC`
- Bill payment phase → `BILL_PAYMENT_SYNC`
- Reimbursements → `REIMBURSEMENT_SYNC`

For bills that need both phases in one pass (`sync_status=NOT_SYNCED` + `status=PAID`), make two POSTs: first `BILL_SYNC` (with the Ramp bill id and the AP's SF id), then `BILL_PAYMENT_SYNC` (same bill id, the Cash Disbursement's SF id). Each call gets its own idempotency key.

---

## Configuration Tab Additions

The existing `rampConfiguration` LWC requires new sections:

- **Transaction Sync** tab
    - Sync status summary per pipeline (last run time, records synced, errors)
    - Manual sync trigger buttons per pipeline (Pipeline 1: card transactions → JEs, Pipeline 2: bills → AP + CD, Pipeline 3: reimbursements → ER)
    - Sync schedule configuration
    - Error queue with re-try and dismiss actions

- **Settings** section (writes through to `Ramp_Sync_Settings__mdt`)
    - Default Ledger (shared across all pipelines)
    - **Card Clearing GL** (Pipeline 1 — the credit side of every card-spend JE)
    - Default Bank Account GL for Cash Disbursements (Pipeline 2)
    - Default JE Status (`In Process` / `Approved` — Pipeline 1)
    - Suspense GL (optional — fallback when a coded GL can't be resolved)
    - Default Employee for Reimbursements (optional — fallback when `user_id` can't be mapped; only used by Pipeline 3)
    - Default Accounting Period fallback behavior (skip vs. use next open period)
    - Sync cadence (hours) per pipeline

---

## Open Questions

1. **JE default status (Pipeline 1):** should card-spend JEs land in `"In Process"` (accountant reviews before posting — safer) or `"Approved"` (Ramp's approval is treated as sufficient)? Default in `Ramp_Sync_Settings__mdt.Default_JE_Status__c` is configurable either way; need to pick the shipped default.

2. **Statement payment reconciliation (Pipeline 1):** card-spend JEs accumulate as credits against `Card_Clearing_GL__c`. When the customer pays Ramp's statement, a separate JE (Dr Card Clearing, Cr Operating Bank) needs to clear that balance. The current scope marks this as out-of-MVP / manual — confirm that's acceptable for initial release, or whether we need a statement-payment ingestion step in v1.

3. **Multi-currency:** Ramp supports foreign currency transactions; line items expose `converted_amount` alongside `amount`. Accounting Seed supports multi-currency. For MVP, are all Ramp transactions assumed to be USD, or do we need FX-aware posting (use `converted_amount` and capture `fx_conversion_rate`) at launch?

4. **User linkage (Pipeline 3 blocker):** Ramp's `user_id` on a reimbursement must map to a Salesforce User/Contact for `AcctSeed__Employee__c`, which is typically required on Expense Reports. This is **no longer a blocker for Pipeline 1** (Journal Entries have no employee FK). For Pipeline 3 we need one of:
   - (a) Ship a User Sync feature (new `Ramp_User_Id__c` on User, sync process) before/with this release.
   - (b) Use `Ramp_Sync_Settings__mdt.Default_Employee_For_Reimbursements__c` as a single fallback user (all reimbursements land under one shared employee record; accountants reassign manually).
   - (c) Defer Pipeline 3 to a later release; Pipelines 1 and 2 ship first.

5. **JE re-pull behavior:** if a Ramp transaction's coding changes after we've created the JE, should we update the JE (delete+recreate child lines) on the next pull, or treat the first sync as final? Either is defensible — current design assumes "update if JE is not yet posted in AS, skip if posted." Confirm.

6. **Historical backfill:** on initial activation, how far back should the sync reach? Ramp has no lookback limit, but creating historical JEs / APs / ERs mid-year has accounting implications (closed periods, restated financials).

---

## Appendix: Ramp Sync Status Values

The `sync_status` enum differs by object type. Values are taken directly from the OpenAPI schemas — older drafts of this doc combined these into one table, which was incorrect.

**Transactions (`Transaction.sync_status`)** — also the `sync_status` query filter on `GET /transactions`:

| Status | Meaning |
|---|---|
| `NOT_SYNC_READY` | Cardholder has not yet marked it ready in the Ramp UI |
| `SYNC_READY` | Ready to export to ERP — this is what we poll for |
| `SYNCED` | Already exported (we acknowledged it via `POST /accounting/syncs`) |

**Reimbursements (`Reimbursement.sync_status`)** — same three values as transactions:

| Status | Meaning |
|---|---|
| `NOT_SYNC_READY` | Approval or payment-init incomplete |
| `SYNC_READY` | Ready to export to ERP |
| `SYNCED` | Already exported |

**Bills (`Bill.sync_status`)** — only three values; the two-phase model is encoded by combining `sync_status` with the orthogonal `sync_ready=true` query filter and `bill.status`:

| Status | Meaning |
|---|---|
| `NOT_SYNCED` | Neither the invoice nor the payment has been synced |
| `BILL_SYNCED` | Invoice synced (AP created); payment still outstanding |
| `BILL_AND_PAYMENT_SYNCED` | Both phases complete |

**Per-pipeline sync decision matrix:**

| Endpoint + filter | When the object is returned | What to do |
|---|---|---|
| `GET /transactions?sync_status=SYNC_READY` | Cardholder marked ready in Ramp UI | Create Journal Entry (Dr expense GL, Cr card clearing GL) → POST `TRANSACTION_SYNC` |
| `GET /reimbursements?sync_status=SYNC_READY` | Reimbursement approved + payment initiated | Create ER → POST `REIMBURSEMENT_SYNC` (skip if `type` is `PAYBACK_*` or `direction` is `USER_TO_BUSINESS`) |
| `GET /bills?sync_ready=true` returning `sync_status=NOT_SYNCED` + `status=OPEN` | Bill approved, not yet paid | Create AP → POST `BILL_SYNC` |
| `GET /bills?sync_ready=true` returning `sync_status=NOT_SYNCED` + `status=PAID` | Bill approved and already paid | Create AP, then Cash Disbursement(s) → POST `BILL_SYNC`, then `BILL_PAYMENT_SYNC` |
| `GET /bills?sync_ready=true` returning `sync_status=BILL_SYNCED` + `status=PAID` | Invoice already synced last cycle; payment now ready | Create Cash Disbursement(s) → POST `BILL_PAYMENT_SYNC` |

There is no `SYNC_FAILED` status. Failure surfaces in the Ramp UI as Export Errors via `failed_syncs[]` in the `/accounting/syncs` POST — Ramp does not flip the object's `sync_status`.

---

*Document status: Draft — pending resolution of open questions above*  
*Related: Ramp Integration Requirements (Confluence), Phase 1 master data sync implementation*