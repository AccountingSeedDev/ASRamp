/**
 * @description Pure transformation from Ramp transactions to Accounting Seed
 * Journal Entry headers and lines. Resolves Ramp UUIDs to AS record Ids in
 * bulk; returns a BuildResult the caller can DML.
 *
 * Accounting model, per card transaction:
 *   Dr  Expense GL          $X   (one line per transaction.line_items, or one if no splits)
 *   Cr  Ramp Card Clearing       $X   (one clearing line, GL from the ledger's Ramp defaults)
 *
 * Transactions are grouped into JE headers per Ramp_Sync_Settings__mdt.Sync_Grouping__c:
 *   Daily             -> one JE per accounting date, per entity, per currency
 *   Accounting Period -> one JE per accounting period, per entity, per currency
 * The header's AcctSeed__ExtId__c IS the bucket key, so any later run upserts
 * into the same Daily/Period JE instead of creating a new one.
 * Lines stay keyed by Ramp txn id (idempotent); only the header they attach to changes.
 *
 * For refunds (transaction.amount < 0), sides are flipped on the same two-line shape.
 */
public with sharing class RampJournalEntryBuilder {

    // --------------------------------------------------------------------
    //  DTOs — match the Ramp Transaction OpenAPI response shape
    // --------------------------------------------------------------------

    public class RampTransaction {
        public String id;
        public Decimal amount;             // top-level: decimal dollars (not cents)
        public String currency_code;
        public String accounting_date;     // ISO8601
        public String user_transaction_time;
        public String merchant_name;
        public String memo;
        public String state;               // CLEARED, etc.
        public String sync_status;
        public String entity_id;           // Ramp business entity uuid — single-entity tenants always return the same value
        public CardHolder card_holder;
        public List<AccountingFieldSelection> accounting_field_selections;
        public List<LineItem> line_items;
    }

    public class CardHolder {
        public String user_id;
        public String first_name;
        public String last_name;
    }

    public class AccountingFieldSelection {
        public String id;                  // Ramp UUID of the *option*
        public String name;
        public String type;                // GL_ACCOUNT, SUBSIDIARY, PROJECT, etc.
        public String external_id;
        public String external_code;
        public CategoryInfo category_info;
    }

    public class CategoryInfo {
        public String id;                  // Ramp UUID of the *field* (parent)
        public String name;                // e.g. "GL Account Variable 1"
        public String type;
    }

    public class LineItem {
        public CurrencyAmount amount;      // CurrencyAmount — minor units
        public CurrencyAmount converted_amount;
        public String memo;
        public List<AccountingFieldSelection> accounting_field_selections;
    }

    public class CurrencyAmount {
        public Long amount;
        public String currency_code;
        public Integer minor_unit_conversion_rate;

        public Decimal toDecimal() {
            Integer divisor = (minor_unit_conversion_rate == null || minor_unit_conversion_rate == 0)
                ? 100
                : minor_unit_conversion_rate;
            return ((Decimal) amount) / divisor;
        }
    }

    // --------------------------------------------------------------------
    //  Build result
    // --------------------------------------------------------------------

    public class BuildResult {
        public List<JournalEntryBuild> successful = new List<JournalEntryBuild>();
        public Map<String, String> failed = new Map<String, String>(); // Ramp txn id -> reason
    }

    /**
     * @description One Journal Entry's worth of AS records, pre-DML. With
     * grouping, a single JE can fold in many Ramp transactions: one header plus
     * each transaction's debit + clearing lines. Header and lines are NOT yet
     * linked by SF Id — the caller upserts the header first, then sets
     * line.AcctSeed__Journal_Entry__c to the resulting Id and upserts the lines.
     */
    public class JournalEntryBuild {
        public String headerExtId;                 // == header.AcctSeed__ExtId__c, the group key
        public AcctSeed__Journal_Entry__c header;
        public List<AcctSeed__Journal_Entry_Line__c> lines = new List<AcctSeed__Journal_Entry_Line__c>();
        public List<String> rampTransactionIds = new List<String>(); // txns folded into this JE
    }

    // --------------------------------------------------------------------
    //  Entry point
    // --------------------------------------------------------------------

    /**
     * @param grouping RampSyncSettingsService.GROUPING_DAILY or GROUPING_BY_PERIOD —
     *        controls how transactions collapse into JE headers.
     */
    public static BuildResult build(List<RampTransaction> transactions, String grouping) {
        BuildResult result = new BuildResult();
        if (transactions == null || transactions.isEmpty()) {
            return result;
        }
        Boolean byPeriod = (grouping == RampSyncSettingsService.GROUPING_BY_PERIOD);

        // 1. Bulk-resolve all referenced GL and Variable option UUIDs to SF Ids.
        Set<String> glUuids = new Set<String>();
        Set<String> varUuids = new Set<String>();
        collectReferencedUuids(transactions, glUuids, varUuids);

        Map<String, Id> glByUuid = resolveGLs(glUuids);
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid = resolveVariables(varUuids);

        // 1b. Bulk-resolve vendor Accounts for the line-level Account lookup.
        //     Deterministic first (the transaction's Accounting Vendor coding,
        //     whose external_id is the SF Account Id we upload in vendor sync),
        //     then a strict merchant-name match against EXISTING vendor Accounts.
        //     Never creates Accounts — unmatched merchants (Chipotle et al.)
        //     simply leave the lookup blank.
        Map<String, Id> acctByVendorUuid = resolveVendorAccounts(collectVendorSelections(transactions));
        Map<String, Id> acctByMerchant = resolveMerchantAccounts(transactions);

        // 2. Resolve settings once.
        Id clearingGLId = RampSyncSettingsService.getCardClearingGLAccountId();
        Id ledgerId = RampSyncSettingsService.getDefaultLedgerId();
        Id suspenseGLId = RampSyncSettingsService.getSuspenseGLId();
        String defaultStatus = RampSyncSettingsService.getDefaultJEStatus();

        // 3. Bulk-resolve Accounting Periods. AS enforces that every JE has a
        // period and that period is open; we look the period up by date.
        Map<Date, Id> periodByDate = new Map<Date, Id>();
        Map<Id, String> periodNameById = new Map<Id, String>();
        Map<Id, Date> periodEndById = new Map<Id, Date>();
        Set<Date> allDates = new Set<Date>();
        for (RampTransaction txn : transactions) {
            Date d = parseDate(txn.accounting_date != null ? txn.accounting_date : txn.user_transaction_time);
            if (d != null) allDates.add(d);
        }
        if (!allDates.isEmpty()) {
            Date minDate = null;
            Date maxDate = null;
            for (Date d : allDates) {
                if (minDate == null || d < minDate) minDate = d;
                if (maxDate == null || d > maxDate) maxDate = d;
            }
            for (AcctSeed__Accounting_Period__c p : [
                SELECT Id, Name, AcctSeed__Start_Date__c, AcctSeed__End_Date__c
                FROM AcctSeed__Accounting_Period__c
                WHERE AcctSeed__Start_Date__c <= :maxDate AND AcctSeed__End_Date__c >= :minDate
            ]) {
                periodNameById.put(p.Id, p.Name);
                periodEndById.put(p.Id, p.AcctSeed__End_Date__c);
                for (Date d : allDates) {
                    if (d >= p.AcctSeed__Start_Date__c && d <= p.AcctSeed__End_Date__c) {
                        periodByDate.put(d, p.Id);
                    }
                }
            }
        }

        // 4. Build each transaction's lines and fold them into a JE bucket.
        //    Bucket key decides which header the lines attach to (and doubles as
        //    the header's AcctSeed__ExtId__c, so re-runs upsert the same JE):
        //      Daily             -> date + entity + currency
        //      Accounting Period -> period + entity + currency
        //    A JE must sit in one Accounting Period, so the key always pins a period.
        Map<String, JournalEntryBuild> bucketsByKey = new Map<String, JournalEntryBuild>();
        Map<String, Date> headerDateByKey = new Map<String, Date>();   // representative (max) date
        Map<String, Id> periodByKey = new Map<String, Id>();
        Map<String, String> entityByKey = new Map<String, String>();

        for (RampTransaction txn : transactions) {
            if (String.isBlank(txn.id)) {
                continue; // nothing we can key, ack, or report against
            }
            Date txnDate = parseDate(txn.accounting_date != null ? txn.accounting_date : txn.user_transaction_time);
            if (txnDate == null) {
                result.failed.put(txn.id, 'Could not parse a usable date from accounting_date or user_transaction_time');
                continue;
            }
            Id periodId = periodByDate.get(txnDate);
            if (periodId == null) {
                result.failed.put(txn.id,
                    'No Accounting Period in Accounting Seed covers date ' + String.valueOf(txnDate) +
                    '. Open a period that includes this date or adjust the transaction accounting_date in Ramp.');
                continue;
            }

            List<AcctSeed__Journal_Entry_Line__c> txnLines;
            try {
                txnLines = buildTransactionLines(txn, txnDate, glByUuid, varByUuid,
                    acctByVendorUuid, acctByMerchant, clearingGLId, suspenseGLId);
            } catch (BuildException e) {
                result.failed.put(txn.id, e.getMessage());
                continue;
            }

            String entity = String.isBlank(txn.entity_id) ? null : txn.entity_id;
            String currencyCode = String.isBlank(txn.currency_code) ? 'X' : txn.currency_code;
            String key = byPeriod
                ? 'P:' + periodId + ':' + (entity == null ? 'X' : entity) + ':' + currencyCode
                : 'D:' + String.valueOf(txnDate) + ':' + (entity == null ? 'X' : entity) + ':' + currencyCode;

            JournalEntryBuild jeb = bucketsByKey.get(key);
            if (jeb == null) {
                jeb = new JournalEntryBuild();
                jeb.headerExtId = key;
                bucketsByKey.put(key, jeb);
                periodByKey.put(key, periodId);
                entityByKey.put(key, entity);
            }
            jeb.lines.addAll(txnLines);
            jeb.rampTransactionIds.add(txn.id);

            Date maxSoFar = headerDateByKey.get(key);
            if (maxSoFar == null || txnDate > maxSoFar) {
                headerDateByKey.put(key, txnDate);
            }
        }

        // 5. Finalize one header per bucket.
        for (String key : bucketsByKey.keySet()) {
            JournalEntryBuild jeb = bucketsByKey.get(key);
            Id periodId = periodByKey.get(key);
            // Daily: the bucket date. Period: the period's end date — deterministic,
            // so re-runs upserting into the same period JE never shift it.
            Date headerDate = byPeriod ? periodEndById.get(periodId) : headerDateByKey.get(key);

            AcctSeed__Journal_Entry__c je = new AcctSeed__Journal_Entry__c();
            je.AcctSeed__ExtId__c = key;
            je.AcctSeed__Journal_Date__c = headerDate;
            je.AcctSeed__Accounting_Period__c = periodId;
            je.Ramp_Entity_Id__c = entityByKey.get(key);
            // AcctSeed__Type__c is a restricted picklist (Bank Transfer, EOM Adjustment,
            // Intercompany, Sub-ledger Adjustment) — none fit card spend, so leave null.
            je.AcctSeed__Status__c = defaultStatus;
            je.AcctSeed__Ledger__c = ledgerId;
            // Name convention (stable per bucket, like the ExtId):
            //   Daily             -> "RAMP - {yyyy-mm-dd}" (the bucket date)
            //   Accounting Period -> "RAMP - {periodName}"
            je.Name = byPeriod
                ? 'RAMP - ' + periodNameById.get(periodId)
                : 'RAMP - ' + String.valueOf(headerDate);
            je.Ramp_Sync_Status__c = 'Pending';
            jeb.header = je;
            result.successful.add(jeb);
        }

        return result;
    }

    // --------------------------------------------------------------------
    //  Internal: per-transaction lines (one transaction's debit + clearing
    //  pair, keyed by txn id so they stay idempotent regardless of which JE
    //  header they end up attached to).
    // --------------------------------------------------------------------

    private static List<AcctSeed__Journal_Entry_Line__c> buildTransactionLines(
        RampTransaction txn,
        Date txnDate,
        Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
        Map<String, Id> acctByVendorUuid,
        Map<String, Id> acctByMerchant,
        Id clearingGLId,
        Id suspenseGLId
    ) {
        List<AcctSeed__Journal_Entry_Line__c> lines = new List<AcctSeed__Journal_Entry_Line__c>();

        // ---- Debit line(s) ----
        Boolean isRefund = (txn.amount != null && txn.amount < 0);

        if (txn.line_items != null && !txn.line_items.isEmpty()) {
            // Multi-line splits — one debit per line_item
            for (Integer i = 0; i < txn.line_items.size(); i++) {
                LineItem li = txn.line_items[i];
                // Prefer converted_amount (settlement currency, matches the
                // top-level USD amount). line `amount` is the merchant's
                // ORIGINAL currency on FX transactions and would book e.g.
                // £80 as $80.
                CurrencyAmount money = (li.converted_amount != null && li.converted_amount.amount != null)
                    ? li.converted_amount
                    : li.amount;
                Decimal lineAmount = (money != null && money.amount != null) ? money.toDecimal() : null;
                if (lineAmount == null) {
                    throw new BuildException('Line item ' + i + ' has no amount');
                }
                // Refund line items carry negative amounts; sides are already
                // flipped via isRefund, so the line value itself must be positive
                // (mirrors the .abs() on the no-splits path below).
                lineAmount = lineAmount.abs();
                lines.add(buildDebitLine(
                    txn, txnDate, li.accounting_field_selections, lineAmount, li.memo, i,
                    glByUuid, varByUuid, acctByVendorUuid, acctByMerchant, suspenseGLId, isRefund
                ));
            }
        } else {
            // No splits — single debit from transaction.amount
            Decimal singleAmount = (txn.amount != null) ? txn.amount.abs() : null;
            if (singleAmount == null) {
                throw new BuildException('Transaction has no amount and no line items');
            }
            lines.add(buildDebitLine(
                txn, txnDate, txn.accounting_field_selections, singleAmount, txn.memo, 0,
                glByUuid, varByUuid, acctByVendorUuid, acctByMerchant, suspenseGLId, isRefund
            ));
        }

        // ---- Clearing line (one per transaction, so the pair always balances
        //      even when many transactions share one grouped JE) ----
        Decimal totalAmount = sumDebitAmounts(lines, isRefund);
        AcctSeed__Journal_Entry_Line__c clearing = new AcctSeed__Journal_Entry_Line__c();
        clearing.AcctSeed__ExtId__c = txn.id + ':cr';
        clearing.AcctSeed__GL_Account__c = clearingGLId;
        clearing.AcctSeed__Date__c = txnDate; // keep the pair on the txn's own date
        clearing.Ramp_Vendor_Name__c = txn.merchant_name; // trace the credit side too
        clearing.AcctSeed__Description__c = 'Ramp card clearing';
        if (isRefund) {
            // Refund: clearing is the DEBIT side
            clearing.AcctSeed__Debit__c = totalAmount;
        } else {
            clearing.AcctSeed__Credit__c = totalAmount;
        }
        lines.add(clearing);

        return lines;
    }

    private static AcctSeed__Journal_Entry_Line__c buildDebitLine(
        RampTransaction txn,
        Date txnDate,
        List<AccountingFieldSelection> lineSelections,
        Decimal amount,
        String lineMemo,
        Integer ordinal,
        Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
        Map<String, Id> acctByVendorUuid,
        Map<String, Id> acctByMerchant,
        Id suspenseGLId,
        Boolean isRefund
    ) {
        AcctSeed__Journal_Entry_Line__c line = new AcctSeed__Journal_Entry_Line__c();
        line.AcctSeed__ExtId__c = txn.id + ':dr:' + ordinal;
        line.AcctSeed__Date__c = txnDate; // the Ramp transaction's own date, not the header's
        line.AcctSeed__Description__c = String.isNotBlank(lineMemo) ? lineMemo : txn.memo;
        line.Ramp_Vendor_Name__c = txn.merchant_name;

        // Vendor Account (may stay null — never required):
        //   1. Accounting Vendor coding (line-level, then transaction-level).
        //      Ramp's accounting field type for the vendor dimension is
        //      'MERCHANT' (there is no VENDOR value in the selection enum).
        //   2. strict merchant-name match against existing vendor Accounts
        String vendorUuid = findSelectionId(lineSelections, 'MERCHANT');
        if (String.isBlank(vendorUuid)) {
            vendorUuid = findSelectionId(txn.accounting_field_selections, 'MERCHANT');
        }
        Id vendorAcct = String.isNotBlank(vendorUuid) ? acctByVendorUuid.get(vendorUuid) : null;
        if (vendorAcct == null && String.isNotBlank(txn.merchant_name)) {
            vendorAcct = acctByMerchant.get(txn.merchant_name.toLowerCase());
        }
        line.AcctSeed__Account__c = vendorAcct;

        // Resolve GL (line-level first, then transaction-level)
        String glUuid = findSelectionId(lineSelections, 'GL_ACCOUNT');
        if (String.isBlank(glUuid)) {
            glUuid = findSelectionId(txn.accounting_field_selections, 'GL_ACCOUNT');
        }

        if (String.isNotBlank(glUuid) && glByUuid.containsKey(glUuid)) {
            line.AcctSeed__GL_Account__c = glByUuid.get(glUuid);
        } else if (suspenseGLId != null) {
            line.AcctSeed__GL_Account__c = suspenseGLId;
        } else {
            throw new BuildException(
                'Could not resolve a GL Account for transaction ' + txn.id +
                ' (line ordinal ' + ordinal + '). Either code the transaction in Ramp ' +
                'or set the "Ramp Suspense" default GL Account on the sync ledger.'
            );
        }

        // Resolve variables 1-4 (line-level first, then transaction-level fallback)
        applyVariables(line, lineSelections, varByUuid);
        applyVariables(line, txn.accounting_field_selections, varByUuid);

        // Debit / credit assignment
        if (isRefund) {
            line.AcctSeed__Credit__c = amount;
        } else {
            line.AcctSeed__Debit__c = amount;
        }
        return line;
    }

    private static void applyVariables(
        AcctSeed__Journal_Entry_Line__c line,
        List<AccountingFieldSelection> selections,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid
    ) {
        if (selections == null) return;
        for (AccountingFieldSelection sel : selections) {
            if (String.isBlank(sel.id) || !varByUuid.containsKey(sel.id)) continue;
            AcctSeed__Accounting_Variable__c var = varByUuid.get(sel.id);
            // Variable's own AcctSeed__Type__c tells us which column (1-4)
            String varType = var.AcctSeed__Type__c;
            if (varType == 'GL Account Variable 1' && line.AcctSeed__GL_Account_Variable_1__c == null) {
                line.AcctSeed__GL_Account_Variable_1__c = var.Id;
            } else if (varType == 'GL Account Variable 2' && line.AcctSeed__GL_Account_Variable_2__c == null) {
                line.AcctSeed__GL_Account_Variable_2__c = var.Id;
            } else if (varType == 'GL Account Variable 3' && line.AcctSeed__GL_Account_Variable_3__c == null) {
                line.AcctSeed__GL_Account_Variable_3__c = var.Id;
            } else if (varType == 'GL Account Variable 4' && line.AcctSeed__GL_Account_Variable_4__c == null) {
                line.AcctSeed__GL_Account_Variable_4__c = var.Id;
            }
        }
    }

    private static String findSelectionId(List<AccountingFieldSelection> selections, String type) {
        if (selections == null) return null;
        for (AccountingFieldSelection sel : selections) {
            if (sel.type == type && String.isNotBlank(sel.id)) {
                return sel.id;
            }
        }
        return null;
    }

    private static Decimal sumDebitAmounts(List<AcctSeed__Journal_Entry_Line__c> lines, Boolean isRefund) {
        Decimal total = 0;
        for (AcctSeed__Journal_Entry_Line__c l : lines) {
            // Sum whichever side carries the expense (Debit on a charge, Credit on a refund)
            Decimal amt = isRefund ? l.AcctSeed__Credit__c : l.AcctSeed__Debit__c;
            if (amt != null) total += amt;
        }
        return total;
    }

    // --------------------------------------------------------------------
    //  Bulk FK resolution
    // --------------------------------------------------------------------

    private static void collectReferencedUuids(
        List<RampTransaction> transactions,
        Set<String> glUuids,
        Set<String> varUuids
    ) {
        for (RampTransaction txn : transactions) {
            collectSelectionUuids(txn.accounting_field_selections, glUuids, varUuids);
            if (txn.line_items != null) {
                for (LineItem li : txn.line_items) {
                    collectSelectionUuids(li.accounting_field_selections, glUuids, varUuids);
                }
            }
        }
    }

    private static void collectSelectionUuids(
        List<AccountingFieldSelection> selections,
        Set<String> glUuids,
        Set<String> varUuids
    ) {
        if (selections == null) return;
        for (AccountingFieldSelection sel : selections) {
            if (String.isBlank(sel.id)) continue;
            if (sel.type == 'GL_ACCOUNT') {
                glUuids.add(sel.id);
            } else {
                // Could be a variable option (GL Account Variable 1-4) or something else.
                // We try every non-GL option against AcctSeed__Accounting_Variable__c.Ramp_Field_Option_Id__c;
                // unmatched ones get silently filtered.
                varUuids.add(sel.id);
            }
        }
    }

    private static Map<String, Id> resolveGLs(Set<String> uuids) {
        Map<String, Id> result = new Map<String, Id>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__GL_Account__c gl : [
            SELECT Id, Ramp_Id__c
            FROM AcctSeed__GL_Account__c
            WHERE Ramp_Id__c IN :uuids AND AcctSeed__Active__c = true
        ]) {
            result.put(gl.Ramp_Id__c, gl.Id);
        }
        return result;
    }

    /**
     * @description Collect Accounting Vendor coding selections (line-level +
     * txn-level) as selection uuid -> external_id. Ramp types the vendor coding
     * dimension as 'MERCHANT' on transaction field selections. The external_id
     * is the SF Account Id we sent when syncing the vendor to Ramp
     * (see RampVendorSyncBatch).
     */
    private static Map<String, String> collectVendorSelections(List<RampTransaction> transactions) {
        Map<String, String> extByUuid = new Map<String, String>();
        for (RampTransaction txn : transactions) {
            addVendorSelections(txn.accounting_field_selections, extByUuid);
            if (txn.line_items != null) {
                for (LineItem li : txn.line_items) {
                    addVendorSelections(li.accounting_field_selections, extByUuid);
                }
            }
        }
        return extByUuid;
    }

    private static void addVendorSelections(List<AccountingFieldSelection> selections, Map<String, String> extByUuid) {
        if (selections == null) return;
        for (AccountingFieldSelection sel : selections) {
            if (sel.type == 'MERCHANT' && String.isNotBlank(sel.id)) {
                extByUuid.put(sel.id, sel.external_id);
            }
        }
    }

    /**
     * @description Resolve VENDOR selection uuids to Accounts. external_id as
     * the SF Account Id first (the ERP bridge), then the selection uuid against
     * Account.Ramp_Vendor_Id__c. Unresolved uuids are simply absent.
     */
    private static Map<String, Id> resolveVendorAccounts(Map<String, String> extByUuid) {
        Map<String, Id> result = new Map<String, Id>();
        if (extByUuid.isEmpty()) return result;

        // 1. external_id is usually the SF Account Id we uploaded.
        Map<Id, List<String>> uuidsByAcctId = new Map<Id, List<String>>();
        for (String uuid : extByUuid.keySet()) {
            Id candidate = asAccountId(extByUuid.get(uuid));
            if (candidate != null) {
                if (!uuidsByAcctId.containsKey(candidate)) uuidsByAcctId.put(candidate, new List<String>());
                uuidsByAcctId.get(candidate).add(uuid);
            }
        }
        if (!uuidsByAcctId.isEmpty()) {
            for (Account a : [SELECT Id FROM Account WHERE Id IN :uuidsByAcctId.keySet()]) {
                for (String uuid : uuidsByAcctId.get(a.Id)) {
                    result.put(uuid, a.Id);
                }
            }
        }

        // 2. Remaining uuids: the selection uuid is the accounting vendor's
        //    ramp_id, which vendor sync stamps on Account.Ramp_Vendor_Id__c.
        Set<String> unresolved = new Set<String>();
        for (String uuid : extByUuid.keySet()) {
            if (!result.containsKey(uuid)) unresolved.add(uuid);
        }
        if (!unresolved.isEmpty()) {
            for (Account a : [SELECT Id, Ramp_Vendor_Id__c FROM Account WHERE Ramp_Vendor_Id__c IN :unresolved]) {
                result.put(a.Ramp_Vendor_Id__c, a.Id);
            }
        }
        return result;
    }

    /**
     * @description Strict merchant-name fallback: lowercased merchant name ->
     * existing vendor-typed Account. Exact name only (SOQL IN is
     * case-insensitive), oldest Account wins ties, never creates records — so
     * untracked T&E merchants resolve to nothing by design.
     */
    private static Map<String, Id> resolveMerchantAccounts(List<RampTransaction> transactions) {
        Map<String, Id> result = new Map<String, Id>();
        Set<String> names = new Set<String>();
        for (RampTransaction txn : transactions) {
            if (String.isNotBlank(txn.merchant_name)) names.add(txn.merchant_name);
        }
        if (names.isEmpty()) return result;
        for (Account a : [
            SELECT Id, Name FROM Account
            WHERE Name IN :names
              AND AcctSeed__Accounting_Type__c IN ('Vendor', 'Customer and Vendor')
            ORDER BY CreatedDate ASC
        ]) {
            String key = a.Name.toLowerCase();
            if (!result.containsKey(key)) result.put(key, a.Id);
        }
        return result;
    }

    private static Id asAccountId(String s) {
        if (String.isBlank(s)) return null;
        try {
            Id parsed = (Id) s;
            return parsed.getSobjectType() == Account.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static Map<String, AcctSeed__Accounting_Variable__c> resolveVariables(Set<String> uuids) {
        Map<String, AcctSeed__Accounting_Variable__c> result = new Map<String, AcctSeed__Accounting_Variable__c>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__Accounting_Variable__c var : [
            SELECT Id, AcctSeed__Type__c, Ramp_Field_Option_Id__c
            FROM AcctSeed__Accounting_Variable__c
            WHERE Ramp_Field_Option_Id__c IN :uuids AND AcctSeed__Active__c = true
        ]) {
            result.put(var.Ramp_Field_Option_Id__c, var);
        }
        return result;
    }

    // --------------------------------------------------------------------
    //  Date parsing
    // --------------------------------------------------------------------

    private static Date parseDate(String isoOrDate) {
        if (String.isBlank(isoOrDate)) return null;
        try {
            if (isoOrDate.length() == 10) {
                return Date.valueOf(isoOrDate);
            }
            // Ramp serializes accounting_date with a TZ offset; we want the UTC
            // date so it doesn't shift +/-1 day depending on the running user's
            // timezone. dateGmt() preserves Ramp's intent.
            DateTime dt = (DateTime) JSON.deserialize('"' + isoOrDate + '"', DateTime.class);
            return dt.dateGmt();
        } catch (Exception e) {
            return null;
        }
    }

    public class BuildException extends Exception {}
}
