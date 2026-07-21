/**
 * @description Pure transformation from Ramp reimbursements to Accounting Seed
 * employee Payables. A reimbursement is a liability owed to an employee, so it
 * maps to an Account_Payable__c with an Employee (User) payee + expense lines
 * (Dr Expense / Cr AP control). When the reimbursement is already REIMBURSED by
 * Ramp, a Cash Disbursement + AP Disbursement clear the payable — reusing the
 * same machinery as bill pay.
 *
 * USER_TO_BUSINESS and PAYBACK_* reimbursements are skipped (not a business
 * payout). GL/variable coding reuses accounting_field_selections (field type in
 * category_info.type). Single-phase sync (REIMBURSEMENT_SYNC).
 */
public with sharing class RampReimbursementBuilder {

    private static final String PAYABLE_STATUS = 'In Process';
    private static final Set<String> SKIP_TYPES = new Set<String>{ 'PAYBACK_FULL', 'PAYBACK_PARTIAL' };
    private static final String PAID_STATE = 'REIMBURSED';

    // --------------------------------------------------------------------
    //  DTOs — GET /developer/v1/reimbursements (Reimbursement resource)
    // --------------------------------------------------------------------
    public class Reimbursement {
        public String id;
        public String user_id;
        public String user_email;
        public String user_full_name;
        public Decimal amount;          // top-level: decimal dollars
        public String currency_x;       // 'currency' is reserved-ish; remapped below
        public String direction;        // BUSINESS_TO_USER | USER_TO_BUSINESS
        public String type;             // OUT_OF_POCKET | MILEAGE | PER_DIEM | PAYBACK_*
        public String state;            // REIMBURSED, APPROVED, ...
        public String sync_status;
        public String transaction_date;
        public String accounting_date;
        public String memo;
        public String merchant;
        public String entity_id;
        public String payment_processed_at;
        public List<ReimbFieldSelection> accounting_field_selections;
        public List<ReimbLineItem> line_items;
    }

    public class ReimbLineItem {
        public CurrencyAmount amount;
        public String memo;
        public List<ReimbFieldSelection> accounting_field_selections;
    }

    public class ReimbFieldSelection {
        public String id;
        public String name;
        public String external_id;
        public String external_code;
        public ReimbField category_info;
    }

    public class ReimbField {
        public String id;
        public String external_id;
        public String name;
        public String type;             // GL_ACCOUNT, PROJECT, COST_CENTER, ...
    }

    public class CurrencyAmount {
        public Long amount;
        public String currency_code;
        public Integer minor_unit_conversion_rate;
        public Decimal toDecimal() {
            Integer divisor = (minor_unit_conversion_rate == null || minor_unit_conversion_rate == 0) ? 100 : minor_unit_conversion_rate;
            return ((Decimal) amount) / divisor;
        }
    }

    // --------------------------------------------------------------------
    //  Build result
    // --------------------------------------------------------------------
    public class BuildResult {
        public List<ReimbursementBuild> successful = new List<ReimbursementBuild>();
        public Map<String, String> failed = new Map<String, String>();  // reimbursement id -> reason
        public Set<String> skipped = new Set<String>();                 // payback / USER_TO_BUSINESS
    }

    public class ReimbursementBuild {
        public String reimbursementId;
        public AcctSeed__Account_Payable__c header;
        public List<AcctSeed__Account_Payable_Line__c> lines = new List<AcctSeed__Account_Payable_Line__c>();
        public Boolean isPaid = false;
        public AcctSeed__Cash_Disbursement__c cashDisbursement;
        public AcctSeed__AP_Disbursement__c apDisbursement;
        public Id paymentPeriodId;
    }

    public class BuildException extends Exception {}

    // --------------------------------------------------------------------
    //  Entry point
    // --------------------------------------------------------------------
    public static BuildResult build(List<Reimbursement> reimbursements) {
        BuildResult result = new BuildResult();
        if (reimbursements == null || reimbursements.isEmpty()) return result;

        // Resolve coding UUIDs.
        Set<String> glUuids = new Set<String>();
        Set<String> varUuids = new Set<String>();
        for (Reimbursement r : reimbursements) {
            collectUuids(r.accounting_field_selections, glUuids, varUuids);
            if (r.line_items != null) for (ReimbLineItem li : r.line_items) collectUuids(li.accounting_field_selections, glUuids, varUuids);
        }
        Map<String, Id> glByUuid = resolveGLs(glUuids);
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid = resolveVariables(varUuids);

        // Resolve employees by email.
        Map<String, String> emailByRampUserId = new Map<String, String>();
        for (Reimbursement r : reimbursements) {
            if (String.isNotBlank(r.user_id) && String.isNotBlank(r.user_email)) emailByRampUserId.put(r.user_id, r.user_email);
        }
        Map<String, Id> employeeByRampUserId = RampEmployeeResolver.resolveByEmail(emailByRampUserId);

        Id ledgerId = RampSyncSettingsService.getDefaultLedgerId();
        Id suspenseGLId = RampSyncSettingsService.getSuspenseGLId();
        Id bankGLId = RampSyncSettingsService.getBillPaymentBankGLIdOrNull();
        Map<Date, Id> periodByDate = resolvePeriods(reimbursements);

        for (Reimbursement r : reimbursements) {
            // Skip paybacks / employee-owes-business.
            if (r.direction == 'USER_TO_BUSINESS' || (r.type != null && SKIP_TYPES.contains(r.type))) {
                result.skipped.add(r.id);
                continue;
            }
            try {
                result.successful.add(buildOne(r, employeeByRampUserId, glByUuid, varByUuid, periodByDate, ledgerId, suspenseGLId, bankGLId));
            } catch (BuildException e) {
                result.failed.put(r.id, e.getMessage());
            }
        }
        return result;
    }

    private static ReimbursementBuild buildOne(
        Reimbursement r, Map<String, Id> employeeByRampUserId, Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid, Map<Date, Id> periodByDate,
        Id ledgerId, Id suspenseGLId, Id bankGLId
    ) {
        if (String.isBlank(r.id)) throw new BuildException('Reimbursement missing id');

        Id employeeId = employeeByRampUserId.get(r.user_id);
        if (employeeId == null) {
            throw new BuildException('No active Salesforce User matches the employee email "' + r.user_email + '".');
        }

        Date txnDate = parseDate(r.transaction_date != null ? r.transaction_date : r.accounting_date);
        if (txnDate == null) throw new BuildException('Could not parse a usable date from transaction_date/accounting_date');
        Id periodId = periodByDate.get(txnDate);
        if (periodId == null) {
            throw new BuildException('No Accounting Period in Accounting Seed covers date ' + String.valueOf(txnDate) + '.');
        }

        ReimbursementBuild rb = new ReimbursementBuild();
        rb.reimbursementId = r.id;

        AcctSeed__Account_Payable__c ap = new AcctSeed__Account_Payable__c();
        ap.AcctSeed__ExtId__c = r.id;
        ap.AcctSeed__Employee__c = employeeId;
        ap.AcctSeed__Date__c = txnDate;
        ap.AcctSeed__Accounting_Period__c = periodId;
        ap.AcctSeed__Ledger__c = ledgerId;
        ap.AcctSeed__Status__c = PAYABLE_STATUS;
        ap.AcctSeed__Payee_Reference__c = String.isNotBlank(r.merchant) ? r.merchant : r.memo;
        ap.Ramp_Entity_Id__c = r.entity_id;
        ap.Ramp_Sync_Status__c = 'Pending';
        rb.header = ap;

        if (r.line_items != null && !r.line_items.isEmpty()) {
            for (Integer i = 0; i < r.line_items.size(); i++) {
                ReimbLineItem li = r.line_items[i];
                Decimal amt = (li.amount != null) ? li.amount.toDecimal() : null;
                if (amt == null) throw new BuildException('Line item ' + i + ' has no amount');
                rb.lines.add(buildLine(r, li.accounting_field_selections, amt, li.memo, i, txnDate, glByUuid, varByUuid, suspenseGLId));
            }
        } else {
            if (r.amount == null) throw new BuildException('Reimbursement has no amount and no line items');
            rb.lines.add(buildLine(r, r.accounting_field_selections, r.amount, r.memo, 0, txnDate, glByUuid, varByUuid, suspenseGLId));
        }

        // Reimbursed → Ramp already paid the employee: clear the payable.
        rb.isPaid = (r.state == PAID_STATE);
        if (rb.isPaid && bankGLId != null) {
            Decimal total = 0;
            for (AcctSeed__Account_Payable_Line__c ln : rb.lines) total += ln.AcctSeed__Amount__c;
            Date payDate = parseDate(r.payment_processed_at);
            if (payDate == null) payDate = txnDate;
            Id payPeriod = periodByDate.get(payDate);
            if (payPeriod != null) {
                AcctSeed__Cash_Disbursement__c cd = new AcctSeed__Cash_Disbursement__c();
                cd.AcctSeed__ExtId__c = r.id + ':cd';
                cd.AcctSeed__Employee__c = employeeId;
                cd.AcctSeed__Amount__c = total;
                cd.AcctSeed__Disbursement_Date__c = payDate;
                cd.AcctSeed__Accounting_Period__c = payPeriod;
                cd.AcctSeed__Ledger__c = ledgerId;
                cd.AcctSeed__Bank_Account__c = bankGLId;
                cd.AcctSeed__Source__c = 'Payable';
                cd.AcctSeed__Status__c = 'In Process';
                cd.AcctSeed__Type__c = 'Electronic';
                cd.Ramp_Sync_Status__c = 'Pending';
                rb.cashDisbursement = cd;

                AcctSeed__AP_Disbursement__c apd = new AcctSeed__AP_Disbursement__c();
                apd.AcctSeed__ExtId__c = r.id + ':apd';
                apd.AcctSeed__Paid_Amount__c = total;
                apd.AcctSeed__Applied_Date__c = payDate;
                apd.AcctSeed__Accounting_Period__c = payPeriod;
                apd.AcctSeed__Status__c = 'Approved';
                rb.apDisbursement = apd;
                rb.paymentPeriodId = payPeriod;
            }
        }
        return rb;
    }

    private static AcctSeed__Account_Payable_Line__c buildLine(
        Reimbursement r, List<ReimbFieldSelection> lineSelections, Decimal amount, String memo, Integer ordinal, Date txnDate,
        Map<String, Id> glByUuid, Map<String, AcctSeed__Accounting_Variable__c> varByUuid, Id suspenseGLId
    ) {
        AcctSeed__Account_Payable_Line__c line = new AcctSeed__Account_Payable_Line__c();
        line.AcctSeed__ExtId__c = r.id + ':L' + ordinal;
        line.AcctSeed__Description__c = String.isNotBlank(memo) ? memo : r.memo;
        line.AcctSeed__Amount__c = amount;
        line.AcctSeed__Date__c = txnDate;

        String glUuid = findSelectionId(lineSelections, 'GL_ACCOUNT');
        if (String.isBlank(glUuid)) glUuid = findSelectionId(r.accounting_field_selections, 'GL_ACCOUNT');

        if (String.isNotBlank(glUuid) && glByUuid.containsKey(glUuid)) {
            line.AcctSeed__Expense_GL_Account__c = glByUuid.get(glUuid);
        } else if (suspenseGLId != null) {
            line.AcctSeed__Expense_GL_Account__c = suspenseGLId;
        } else {
            throw new BuildException('Could not resolve an Expense GL Account for reimbursement ' + r.id
                + ' (line ' + ordinal + '). Code it in Ramp or set the "Ramp Suspense" default GL Account.');
        }

        applyVariables(line, lineSelections, varByUuid);
        applyVariables(line, r.accounting_field_selections, varByUuid);
        return line;
    }

    private static void applyVariables(AcctSeed__Account_Payable_Line__c line,
            List<ReimbFieldSelection> selections, Map<String, AcctSeed__Accounting_Variable__c> varByUuid) {
        if (selections == null) return;
        for (ReimbFieldSelection sel : selections) {
            if (String.isBlank(sel.id)) continue;
            // GL Account selections are resolved separately in buildLine — skip them here.
            String selType = (sel.category_info != null) ? sel.category_info.type : null;
            if (selType == 'GL_ACCOUNT') continue;

            AcctSeed__Accounting_Variable__c v = varByUuid.get(sel.id);
            String selLabel = (sel.name != null ? sel.name : sel.id);
            if (v == null) {
                // No live Accounting Variable maps to this option — the variable was
                // deleted in Accounting Seed but remains selectable in Ramp. Fail the
                // record rather than syncing silently with a blank variable field.
                throw new BuildException('GL Variable "' + selLabel + '" (option id: ' + sel.id + ') no longer exists in Accounting Seed (it was deleted) and cannot be used for coding.');
            }
            if (!v.AcctSeed__Active__c) {
                throw new BuildException('GL Variable "' + selLabel + '" (option id: ' + sel.id + ') is inactive in Accounting Seed and cannot be used for coding.');
            }
            String t = v.AcctSeed__Type__c;
            if (t == 'GL Account Variable 1' && line.AcctSeed__GL_Account_Variable_1__c == null) line.AcctSeed__GL_Account_Variable_1__c = v.Id;
            else if (t == 'GL Account Variable 2' && line.AcctSeed__GL_Account_Variable_2__c == null) line.AcctSeed__GL_Account_Variable_2__c = v.Id;
            else if (t == 'GL Account Variable 3' && line.AcctSeed__GL_Account_Variable_3__c == null) line.AcctSeed__GL_Account_Variable_3__c = v.Id;
            else if (t == 'GL Account Variable 4' && line.AcctSeed__GL_Account_Variable_4__c == null) line.AcctSeed__GL_Account_Variable_4__c = v.Id;
        }
    }

    private static void collectUuids(List<ReimbFieldSelection> sels, Set<String> glUuids, Set<String> varUuids) {
        if (sels == null) return;
        for (ReimbFieldSelection sel : sels) {
            if (String.isBlank(sel.id)) continue;
            String t = (sel.category_info != null) ? sel.category_info.type : null;
            if (t == 'GL_ACCOUNT') glUuids.add(sel.id); else varUuids.add(sel.id);
        }
    }

    private static String findSelectionId(List<ReimbFieldSelection> sels, String fieldType) {
        if (sels == null) return null;
        for (ReimbFieldSelection sel : sels) {
            String t = (sel.category_info != null) ? sel.category_info.type : null;
            if (t == fieldType && String.isNotBlank(sel.id)) return sel.id;
        }
        return null;
    }

    private static Map<String, Id> resolveGLs(Set<String> uuids) {
        Map<String, Id> result = new Map<String, Id>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__GL_Account__c gl : [SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c WHERE Ramp_Id__c IN :uuids AND AcctSeed__Active__c = true]) {
            result.put(gl.Ramp_Id__c, gl.Id);
        }
        return result;
    }

    private static Map<String, AcctSeed__Accounting_Variable__c> resolveVariables(Set<String> uuids) {
        Map<String, AcctSeed__Accounting_Variable__c> result = new Map<String, AcctSeed__Accounting_Variable__c>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__Accounting_Variable__c v : [SELECT Id, AcctSeed__Type__c, AcctSeed__Active__c, Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c WHERE Ramp_Field_Option_Id__c IN :uuids]) {
            result.put(v.Ramp_Field_Option_Id__c, v);
        }
        return result;
    }

    private static Map<Date, Id> resolvePeriods(List<Reimbursement> reimbursements) {
        Map<Date, Id> periodByDate = new Map<Date, Id>();
        Set<Date> allDates = new Set<Date>();
        for (Reimbursement r : reimbursements) {
            Date d = parseDate(r.transaction_date != null ? r.transaction_date : r.accounting_date);
            if (d != null) allDates.add(d);
            Date pd = parseDate(r.payment_processed_at);
            if (pd != null) allDates.add(pd);
        }
        if (allDates.isEmpty()) return periodByDate;
        Date minDate, maxDate;
        for (Date d : allDates) { if (minDate == null || d < minDate) minDate = d; if (maxDate == null || d > maxDate) maxDate = d; }
        for (AcctSeed__Accounting_Period__c p : [
            SELECT Id, AcctSeed__Start_Date__c, AcctSeed__End_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Start_Date__c <= :maxDate AND AcctSeed__End_Date__c >= :minDate
        ]) {
            for (Date d : allDates) if (d >= p.AcctSeed__Start_Date__c && d <= p.AcctSeed__End_Date__c) periodByDate.put(d, p.Id);
        }
        return periodByDate;
    }

    private static Date parseDate(String isoOrDate) {
        if (String.isBlank(isoOrDate)) return null;
        try {
            if (isoOrDate.length() == 10) return Date.valueOf(isoOrDate);
            DateTime dt = (DateTime) JSON.deserialize('"' + isoOrDate + '"', DateTime.class);
            return dt.dateGmt();
        } catch (Exception e) { return null; }
    }
}
