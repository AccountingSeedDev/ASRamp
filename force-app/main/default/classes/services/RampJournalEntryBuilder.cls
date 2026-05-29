/**
 * @description Pure transformation from Ramp transactions to Accounting Seed
 * Journal Entry headers and lines. Resolves Ramp UUIDs to AS record Ids in
 * bulk; returns a BuildResult the caller can DML.
 *
 * Accounting model (Pipeline 1), per transaction:
 *   Dr  Expense GL          $X   (one line per transaction.line_items, or one if no splits)
 *   Cr  Ramp Card Clearing       $X   (one clearing line, GL from the ledger's Ramp defaults)
 *
 * Transactions are grouped into JE headers per Ramp_Sync_Settings__mdt.Sync_Grouping__c:
 *   Daily  -> one JE per accounting date, per entity, per currency
 *   By Run -> one JE per accounting period, per sync run, per entity, per currency
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
     * @param grouping RampSyncSettingsService.GROUPING_DAILY or GROUPING_BY_RUN —
     *        controls how transactions collapse into JE headers.
     * @param runId    Stable id for the current sync run; only used by By Run
     *        grouping so all pages of one run land in the same per-period JE.
     */
    public static BuildResult build(List<RampTransaction> transactions, String grouping, String runId) {
        BuildResult result = new BuildResult();
        if (transactions == null || transactions.isEmpty()) {
            return result;
        }
        Boolean byRun = (grouping == RampSyncSettingsService.GROUPING_BY_RUN);

        // 1. Bulk-resolve all referenced GL and Variable option UUIDs to SF Ids.
        Set<String> glUuids = new Set<String>();
        Set<String> varUuids = new Set<String>();
        collectReferencedUuids(transactions, glUuids, varUuids);

        Map<String, Id> glByUuid = resolveGLs(glUuids);
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid = resolveVariables(varUuids);

        // 2. Resolve settings once.
        Id clearingGLId = RampSyncSettingsService.getCardClearingGLAccountId();
        Id ledgerId = RampSyncSettingsService.getDefaultLedgerId();
        Id suspenseGLId = RampSyncSettingsService.getSuspenseGLId();
        String defaultStatus = RampSyncSettingsService.getDefaultJEStatus();

        // 3. Bulk-resolve Accounting Periods. AS enforces that every JE has a
        // period and that period is open; we look the period up by date.
        Map<Date, Id> periodByDate = new Map<Date, Id>();
        Map<Id, String> periodNameById = new Map<Id, String>();
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
                for (Date d : allDates) {
                    if (d >= p.AcctSeed__Start_Date__c && d <= p.AcctSeed__End_Date__c) {
                        periodByDate.put(d, p.Id);
                    }
                }
            }
        }

        // 4. Build each transaction's lines and fold them into a JE bucket.
        //    Bucket key decides which header the lines attach to:
        //      Daily  -> date + entity + currency
        //      By Run -> runId + period + entity + currency
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
                txnLines = buildTransactionLines(txn, glByUuid, varByUuid, clearingGLId, suspenseGLId);
            } catch (BuildException e) {
                result.failed.put(txn.id, e.getMessage());
                continue;
            }

            String entity = String.isBlank(txn.entity_id) ? null : txn.entity_id;
            String currencyCode = String.isBlank(txn.currency_code) ? 'X' : txn.currency_code;
            String key = byRun
                ? 'R:' + runId + ':' + periodId + ':' + (entity == null ? 'X' : entity) + ':' + currencyCode
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
            Date headerDate = headerDateByKey.get(key);

            String dateStr = String.valueOf(headerDate); // yyyy-MM-dd
            AcctSeed__Journal_Entry__c je = new AcctSeed__Journal_Entry__c();
            je.AcctSeed__ExtId__c = key;
            je.AcctSeed__Journal_Date__c = headerDate;
            je.AcctSeed__Accounting_Period__c = periodByKey.get(key);
            je.Ramp_Entity_Id__c = entityByKey.get(key);
            // AcctSeed__Type__c is a restricted picklist (Bank Transfer, EOM Adjustment,
            // Intercompany, Sub-ledger Adjustment) — none fit card spend, so leave null.
            je.AcctSeed__Status__c = defaultStatus;
            je.AcctSeed__Ledger__c = ledgerId;
            // Name convention:
            //   Daily  -> "RAMP - {yyyy-mm-dd}"
            //   By Run -> "RAMP Sync - {yyyy-mm-dd} - {periodName}"
            je.Name = byRun
                ? 'RAMP Sync - ' + dateStr + ' - ' + periodNameById.get(periodByKey.get(key))
                : 'RAMP - ' + dateStr;
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
        Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
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
                Decimal lineAmount = (li.amount != null) ? li.amount.toDecimal() : null;
                if (lineAmount == null) {
                    throw new BuildException('Line item ' + i + ' has no amount');
                }
                lines.add(buildDebitLine(
                    txn, li.accounting_field_selections, lineAmount, li.memo, i,
                    glByUuid, varByUuid, suspenseGLId, isRefund
                ));
            }
        } else {
            // No splits — single debit from transaction.amount
            Decimal singleAmount = (txn.amount != null) ? txn.amount.abs() : null;
            if (singleAmount == null) {
                throw new BuildException('Transaction has no amount and no line items');
            }
            lines.add(buildDebitLine(
                txn, txn.accounting_field_selections, singleAmount, txn.memo, 0,
                glByUuid, varByUuid, suspenseGLId, isRefund
            ));
        }

        // ---- Clearing line (one per transaction, so the pair always balances
        //      even when many transactions share one grouped JE) ----
        Decimal totalAmount = sumDebitAmounts(lines, isRefund);
        AcctSeed__Journal_Entry_Line__c clearing = new AcctSeed__Journal_Entry_Line__c();
        clearing.AcctSeed__ExtId__c = txn.id + ':cr';
        clearing.AcctSeed__GL_Account__c = clearingGLId;
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
        List<AccountingFieldSelection> lineSelections,
        Decimal amount,
        String lineMemo,
        Integer ordinal,
        Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
        Id suspenseGLId,
        Boolean isRefund
    ) {
        AcctSeed__Journal_Entry_Line__c line = new AcctSeed__Journal_Entry_Line__c();
        line.AcctSeed__ExtId__c = txn.id + ':dr:' + ordinal;
        line.AcctSeed__Description__c = String.isNotBlank(lineMemo) ? lineMemo : txn.memo;

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
