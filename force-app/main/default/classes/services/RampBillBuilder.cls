/**
 * @description Pure transformation from Ramp bills to Accounting Seed Payables.
 * Bill → one Account_Payable__c header + one Account_Payable_Line__c
 * per bill line (debit/expense side only; AS posts the AP control credit).
 *
 * GL/variable coding reuses Ramp's accounting_field_selections mechanism (same as
 * card transactions) — the field TYPE lives in category_info.type (GL_ACCOUNT,
 * PROJECT, COST_CENTER, …). Amounts are CurrencyAmount (minor units / cents).
 *
 * DTOs match the pinned Bill schema (ApiBillResourceSchema): vendor is embedded
 * (ApiBillVendor) and vendor.remote_id is the ERP bridge = our SF Account Id.
 */
public with sharing class RampBillBuilder {

    // Payable header status until/unless made configurable. 'In Process' is a
    // safe, non-posted state.
    private static final String PAYABLE_STATUS = 'In Process';

    private static final String PERIOD_STATUS_OPEN = 'Open';

    // CurrencyIsoCode only exists when Multi-Currency is enabled; put()'ing it in a
    // single-currency org throws SObjectException and would fail the whole run.
    private static final Boolean MULTI_CURRENCY = UserInfo.isMultiCurrencyOrganization();

    // Ramp field options carry the Accounting Seed record Id in external_id (verified
    // against live Ramp payloads). Merchant selections populate external_id too, with
    // the Account prefix, so a dangling variable is only identifiable by key prefix.
    private static final String VARIABLE_KEY_PREFIX =
        AcctSeed__Accounting_Variable__c.SObjectType.getDescribe().getKeyPrefix();

    // --------------------------------------------------------------------
    //  DTOs — match GET /developer/v1/bills (Bill resource)
    // --------------------------------------------------------------------
    public class Bill {
        public String id;
        public BillVendor vendor;
        public CurrencyAmount amount;
        public List<BillFieldSelection> accounting_field_selections;
        public List<BillLineItem> line_items;
        public String invoice_number;
        public String issued_at;
        public String due_at;
        public String accounting_date;
        public String paid_at;
        public String memo;
        public String entity_id;
        public String status;        // OPEN | PAID
        public String sync_status;   // NOT_SYNCED | BILL_SYNCED | BILL_AND_PAYMENT_SYNCED
        public BillPayment payment;  // nested; used by the payment stage
    }

    public class BillVendor {
        public String id;            // native Ramp vendor id
        public String name;
        public String remote_id;     // = SF Account Id when ERP-mapped (the bridge)
        public String remote_code;   // vendor code (AccountNumber)
        public String remote_name;
        public String type;          // BUSINESS | INDIVIDUAL
    }

    public class BillFieldSelection {
        public String id;            // Ramp option id (GL → matches GL_Account.Ramp_Id__c)
        public String name;
        public String external_id;
        public String external_code;
        public BillField category_info;
    }

    public class BillField {
        public String id;
        public String external_id;
        public String name;
        public String type;          // GL_ACCOUNT, PROJECT, COST_CENTER, TAX_CODE, …
    }

    public class BillLineItem {
        public CurrencyAmount amount;
        public String memo;
        public List<BillFieldSelection> accounting_field_selections;
    }

    public class BillPayment {
        public String id;
        public CurrencyAmount amount;
        public String payment_method;
        public String payment_date;
        public String effective_date;
    }

    public class CurrencyAmount {
        public Long amount;
        public String currency_code;
        public Integer minor_unit_conversion_rate;
        public Decimal toDecimal() {
            Integer divisor = (minor_unit_conversion_rate == null || minor_unit_conversion_rate == 0)
                ? 100 : minor_unit_conversion_rate;
            return ((Decimal) amount) / divisor;
        }
    }

    // --------------------------------------------------------------------
    //  Build result
    // --------------------------------------------------------------------
    public class BuildResult {
        public List<PayableBuild> successful = new List<PayableBuild>();
        public Map<String, String> failed = new Map<String, String>(); // bill id -> reason
    }

    public class PayableBuild {
        public String billId;
        public AcctSeed__Account_Payable__c header;
        public List<AcctSeed__Account_Payable_Line__c> lines = new List<AcctSeed__Account_Payable_Line__c>();
        // Payment stage — populated only when the bill is PAID and a bill-payment bank GL is configured.
        public Boolean isPaid = false;
        public AcctSeed__Cash_Disbursement__c cashDisbursement;   // batch + payable links set by the service
        public AcctSeed__AP_Disbursement__c apDisbursement;       // payable + CD links set by the service
        public Id paymentPeriodId;
    }

    public class BuildException extends Exception {}

    // --------------------------------------------------------------------
    //  Entry point
    // --------------------------------------------------------------------
    public static BuildResult build(List<Bill> bills) {
        BuildResult result = new BuildResult();
        if (bills == null || bills.isEmpty()) return result;

        // 1. Resolve coding option UUIDs (GL + variables) in bulk.
        Set<String> glUuids = new Set<String>();
        Set<String> varUuids = new Set<String>();
        for (Bill b : bills) {
            collectUuids(b.accounting_field_selections, glUuids, varUuids);
            if (b.line_items != null) {
                for (BillLineItem li : b.line_items) collectUuids(li.accounting_field_selections, glUuids, varUuids);
            }
        }
        Map<String, Id> glByUuid = resolveGLs(glUuids);
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid = resolveVariables(varUuids);
        Set<String> unusableVarUuids = findInactiveVarUuids(varUuids, varByUuid.keySet());
        unusableVarUuids.addAll(findDeletedVarUuids(bills, varByUuid.keySet()));

        // 2. Resolve vendors (auto-create) → native vendor id -> Account Id.
        List<BillVendor> vendors = new List<BillVendor>();
        for (Bill b : bills) if (b.vendor != null) vendors.add(b.vendor);
        Map<String, Id> vendorByNativeId = RampVendorResolver.resolve(vendors);

        // 3. Settings + periods.
        Id ledgerId = RampSyncSettingsService.getDefaultLedgerId();
        Id suspenseGLId = RampSyncSettingsService.getSuspenseGLId();
        Id bankGLId = RampSyncSettingsService.getBillPaymentBankGLIdOrNull(); // null → skip payment build
        Map<Date, AcctSeed__Accounting_Period__c> periodByDate = resolvePeriods(bills);

        // 4. Per-bill build.
        for (Bill b : bills) {
            try {
                result.successful.add(buildOne(b, vendorByNativeId, glByUuid, varByUuid, unusableVarUuids, periodByDate, ledgerId, suspenseGLId, bankGLId));
            } catch (BuildException e) {
                result.failed.put(b.id, e.getMessage());
            }
        }
        return result;
    }

    private static PayableBuild buildOne(
        Bill b, Map<String, Id> vendorByNativeId, Map<String, Id> glByUuid,
        Map<String, AcctSeed__Accounting_Variable__c> varByUuid, Set<String> unusableVarUuids,
        Map<Date, AcctSeed__Accounting_Period__c> periodByDate, Id ledgerId, Id suspenseGLId, Id bankGLId
    ) {
        if (String.isBlank(b.id)) throw new BuildException('Bill missing id');

        Id vendorId = (b.vendor != null) ? vendorByNativeId.get(b.vendor.id) : null;
        if (vendorId == null) throw new BuildException('Could not resolve a vendor Account for the bill');

        Date billDate = parseDate(b.issued_at != null ? b.issued_at : b.accounting_date);
        if (billDate == null) throw new BuildException('Could not parse a usable date from issued_at/accounting_date');
        AcctSeed__Accounting_Period__c period = periodByDate.get(billDate);
        if (period == null) {
            throw new BuildException('No Accounting Period in Accounting Seed covers date ' + String.valueOf(billDate)
                + '. Open a period that includes this date or adjust the bill date in Ramp.');
        }
        if (period.AcctSeed__Status__c != PERIOD_STATUS_OPEN) {
            throw new BuildException(closedPeriodMessage(period.Name, billDate, 'bill date'));
        }
        Id periodId = period.Id;

        PayableBuild pb = new PayableBuild();
        pb.billId = b.id;

        AcctSeed__Account_Payable__c ap = new AcctSeed__Account_Payable__c();
        ap.AcctSeed__ExtId__c = b.id;
        ap.AcctSeed__Vendor__c = vendorId;
        ap.AcctSeed__Date__c = billDate;
        ap.AcctSeed__Due_Date__c = parseDate(b.due_at);
        ap.AcctSeed__Accounting_Period__c = periodId;
        ap.AcctSeed__Ledger__c = ledgerId;
        ap.AcctSeed__Status__c = PAYABLE_STATUS;
        ap.AcctSeed__Payee_Reference__c = b.invoice_number;
        ap.Ramp_Entity_Id__c = b.entity_id;
        ap.Ramp_Sync_Status__c = 'Pending';
        if (MULTI_CURRENCY && b.amount != null && String.isNotBlank(b.amount.currency_code)) {
            ap.put('CurrencyIsoCode', b.amount.currency_code);
        }
        pb.header = ap;

        // Lines: one per bill line_item; fall back to a single line from bill.amount.
        if (b.line_items != null && !b.line_items.isEmpty()) {
            for (Integer i = 0; i < b.line_items.size(); i++) {
                BillLineItem li = b.line_items[i];
                Decimal amt = (li.amount != null) ? li.amount.toDecimal() : null;
                if (amt == null) throw new BuildException('Line item ' + i + ' has no amount');
                pb.lines.add(buildLine(b, li.accounting_field_selections, amt, li.memo, i, billDate, glByUuid, varByUuid, unusableVarUuids, suspenseGLId));
            }
        } else {
            Decimal amt = (b.amount != null) ? b.amount.toDecimal() : null;
            if (amt == null) throw new BuildException('Bill has no amount and no line items');
            pb.lines.add(buildLine(b, b.accounting_field_selections, amt, b.memo, 0, billDate, glByUuid, varByUuid, unusableVarUuids, suspenseGLId));
        }

        // ---- Payment stage: paid bill → Cash Disbursement + AP Disbursement ----
        pb.isPaid = (b.status == 'PAID');
        if (pb.isPaid && bankGLId != null) {
            Decimal payAmt = (b.payment != null && b.payment.amount != null) ? b.payment.amount.toDecimal()
                : (b.amount != null ? b.amount.toDecimal() : null);
            Date payDate = parseDate(
                (b.payment != null && b.payment.payment_date != null) ? b.payment.payment_date : b.paid_at
            );
            if (payDate == null) payDate = billDate; // fall back to the bill date
            AcctSeed__Accounting_Period__c payPeriodRec = periodByDate.get(payDate);
            // A closed payment period fails the whole bill rather than silently
            // dropping the disbursement, which would leave the payable looking unpaid.
            if (payPeriodRec != null && payPeriodRec.AcctSeed__Status__c != PERIOD_STATUS_OPEN) {
                throw new BuildException(closedPeriodMessage(payPeriodRec.Name, payDate, 'payment date'));
            }
            Id payPeriod = (payPeriodRec != null) ? payPeriodRec.Id : null;
            if (payAmt != null && payPeriod != null) {
                AcctSeed__Cash_Disbursement__c cd = new AcctSeed__Cash_Disbursement__c();
                cd.AcctSeed__ExtId__c = b.id + ':cd';
                cd.AcctSeed__Vendor__c = vendorId;
                cd.AcctSeed__Amount__c = payAmt;
                cd.AcctSeed__Disbursement_Date__c = payDate;
                cd.AcctSeed__Accounting_Period__c = payPeriod;
                cd.AcctSeed__Ledger__c = ledgerId;
                cd.AcctSeed__Bank_Account__c = bankGLId;
                cd.AcctSeed__Source__c = 'Payable';
                cd.AcctSeed__Status__c = 'In Process';
                cd.AcctSeed__Type__c = mapPayType(b.payment != null ? b.payment.payment_method : null);
                cd.Ramp_Sync_Status__c = 'Pending';
                if (MULTI_CURRENCY && b.amount != null && String.isNotBlank(b.amount.currency_code)) {
                    cd.put('CurrencyIsoCode', b.amount.currency_code);
                }
                pb.cashDisbursement = cd;

                AcctSeed__AP_Disbursement__c apd = new AcctSeed__AP_Disbursement__c();
                apd.AcctSeed__ExtId__c = b.id + ':apd';
                apd.AcctSeed__Paid_Amount__c = payAmt;
                apd.AcctSeed__Applied_Date__c = payDate;
                apd.AcctSeed__Accounting_Period__c = payPeriod;
                apd.AcctSeed__Status__c = 'Approved';
                pb.apDisbursement = apd;
                pb.paymentPeriodId = payPeriod;
            }
        }
        return pb;
    }

    /** Map Ramp payment_method to the AS Cash Disbursement Type picklist. */
    private static String mapPayType(String paymentMethod) {
        if (paymentMethod != null && paymentMethod.equalsIgnoreCase('CHECK')) return 'Check';
        return 'Electronic';
    }

    private static AcctSeed__Account_Payable_Line__c buildLine(
        Bill b, List<BillFieldSelection> lineSelections, Decimal amount, String memo, Integer ordinal,
        Date billDate, Map<String, Id> glByUuid, Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
        Set<String> unusableVarUuids, Id suspenseGLId
    ) {
        AcctSeed__Account_Payable_Line__c line = new AcctSeed__Account_Payable_Line__c();
        line.AcctSeed__ExtId__c = b.id + ':L' + ordinal;
        line.AcctSeed__Date__c = billDate;
        line.AcctSeed__Description__c = String.isNotBlank(memo) ? memo : b.memo;
        line.AcctSeed__Amount__c = amount;

        String glUuid = findSelectionId(lineSelections, 'GL_ACCOUNT');
        if (String.isBlank(glUuid)) glUuid = findSelectionId(b.accounting_field_selections, 'GL_ACCOUNT');

        if (String.isNotBlank(glUuid) && glByUuid.containsKey(glUuid)) {
            line.AcctSeed__Expense_GL_Account__c = glByUuid.get(glUuid);
        } else if (suspenseGLId != null) {
            line.AcctSeed__Expense_GL_Account__c = suspenseGLId;
        } else {
            throw new BuildException('Could not resolve an Expense GL Account for bill ' + b.id
                + ' (line ' + ordinal + '). Code the bill in Ramp or set the "Ramp Suspense" default GL Account.');
        }

        applyVariables(line, lineSelections, varByUuid, unusableVarUuids);
        applyVariables(line, b.accounting_field_selections, varByUuid, unusableVarUuids);
        return line;
    }

    private static void applyVariables(AcctSeed__Account_Payable_Line__c line,
            List<BillFieldSelection> selections, Map<String, AcctSeed__Accounting_Variable__c> varByUuid,
            Set<String> unusableVarUuids) {
        if (selections == null) return;
        for (BillFieldSelection sel : selections) {
            if (unusableVarUuids.contains(sel.id)) {
                throw new BuildException('GL Variable "' + sel.name + '" (Ramp id=' + sel.id
                    + ') is no longer available in Accounting Seed — it was deleted or deactivated.'
                    + ' Restore it in Accounting Seed, or recode the bill in Ramp, before syncing.');
            }
            if (String.isBlank(sel.id) || !varByUuid.containsKey(sel.id)) continue;
            String t = varByUuid.get(sel.id).AcctSeed__Type__c;
            if (t == 'GL Account Variable 1' && line.AcctSeed__GL_Account_Variable_1__c == null) line.AcctSeed__GL_Account_Variable_1__c = varByUuid.get(sel.id).Id;
            else if (t == 'GL Account Variable 2' && line.AcctSeed__GL_Account_Variable_2__c == null) line.AcctSeed__GL_Account_Variable_2__c = varByUuid.get(sel.id).Id;
            else if (t == 'GL Account Variable 3' && line.AcctSeed__GL_Account_Variable_3__c == null) line.AcctSeed__GL_Account_Variable_3__c = varByUuid.get(sel.id).Id;
            else if (t == 'GL Account Variable 4' && line.AcctSeed__GL_Account_Variable_4__c == null) line.AcctSeed__GL_Account_Variable_4__c = varByUuid.get(sel.id).Id;
        }
    }

    // --------------------------------------------------------------------
    //  Resolution helpers
    // --------------------------------------------------------------------
    private static void collectUuids(List<BillFieldSelection> selections, Set<String> glUuids, Set<String> varUuids) {
        if (selections == null) return;
        for (BillFieldSelection sel : selections) {
            if (String.isBlank(sel.id)) continue;
            String t = (sel.category_info != null) ? sel.category_info.type : null;
            if (t == 'GL_ACCOUNT') glUuids.add(sel.id);
            else varUuids.add(sel.id);
        }
    }

    private static String findSelectionId(List<BillFieldSelection> selections, String fieldType) {
        if (selections == null) return null;
        for (BillFieldSelection sel : selections) {
            String t = (sel.category_info != null) ? sel.category_info.type : null;
            if (t == fieldType && String.isNotBlank(sel.id)) return sel.id;
        }
        return null;
    }

    private static Map<String, Id> resolveGLs(Set<String> uuids) {
        Map<String, Id> result = new Map<String, Id>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__GL_Account__c gl : [
            SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c
            WHERE Ramp_Id__c IN :uuids AND AcctSeed__Active__c = true
        ]) {
            result.put(gl.Ramp_Id__c, gl.Id);
        }
        return result;
    }

    private static Map<String, AcctSeed__Accounting_Variable__c> resolveVariables(Set<String> uuids) {
        Map<String, AcctSeed__Accounting_Variable__c> result = new Map<String, AcctSeed__Accounting_Variable__c>();
        if (uuids.isEmpty()) return result;
        for (AcctSeed__Accounting_Variable__c v : [
            SELECT Id, AcctSeed__Type__c, Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c
            WHERE Ramp_Field_Option_Id__c IN :uuids AND AcctSeed__Active__c = true
        ]) {
            result.put(v.Ramp_Field_Option_Id__c, v);
        }
        return result;
    }

    private static Set<String> findInactiveVarUuids(Set<String> requested, Set<String> activeUuids) {
        if (requested.isEmpty()) return new Set<String>();
        Set<String> known = new Set<String>();
        for (AcctSeed__Accounting_Variable__c v : [
            SELECT Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c
            WHERE Ramp_Field_Option_Id__c IN :requested
        ]) {
            known.add(v.Ramp_Field_Option_Id__c);
        }
        Set<String> inactive = new Set<String>(known);
        inactive.removeAll(activeUuids);
        return inactive;
    }

    /**
     * Ramp option ids whose Accounting Seed variable has been deleted. Deleting the
     * variable never reaches Ramp — only deactivation is PATCHed across — so the option
     * stays selectable and bills keep coding to it. The option carries the Accounting
     * Seed record Id in external_id; merchant selections carry an Account Id there too,
     * so candidates are narrowed by the Accounting Variable key prefix.
     */
    private static Set<String> findDeletedVarUuids(List<Bill> bills, Set<String> activeUuids) {
        Set<String> result = new Set<String>();
        if (String.isBlank(VARIABLE_KEY_PREFIX)) return result;

        Map<Id, String> uuidByVariableId = new Map<Id, String>();
        for (Bill b : bills) {
            List<BillFieldSelection> selections = new List<BillFieldSelection>();
            if (b.accounting_field_selections != null) selections.addAll(b.accounting_field_selections);
            if (b.line_items != null) {
                for (BillLineItem li : b.line_items) {
                    if (li.accounting_field_selections != null) selections.addAll(li.accounting_field_selections);
                }
            }
            for (BillFieldSelection sel : selections) {
                if (String.isBlank(sel.id) || activeUuids.contains(sel.id)) continue;
                String t = (sel.category_info != null) ? sel.category_info.type : null;
                if (t == 'GL_ACCOUNT') continue;
                Id variableId = toVariableId(sel.external_id);
                if (variableId != null) uuidByVariableId.put(variableId, sel.id);
            }
        }
        if (uuidByVariableId.isEmpty()) return result;

        Set<Id> stillExists = new Map<Id, AcctSeed__Accounting_Variable__c>([
            SELECT Id FROM AcctSeed__Accounting_Variable__c WHERE Id IN :uuidByVariableId.keySet()
        ]).keySet();
        for (Id variableId : uuidByVariableId.keySet()) {
            if (!stillExists.contains(variableId)) result.add(uuidByVariableId.get(variableId));
        }
        return result;
    }

    /** external_id as an Accounting Variable Id, or null when it points at anything else. */
    private static Id toVariableId(String externalId) {
        if (String.isBlank(externalId) || !externalId.startsWith(VARIABLE_KEY_PREFIX)) return null;
        if (externalId.length() != 15 && externalId.length() != 18) return null;
        try {
            return Id.valueOf(externalId);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * @description Date -> covering Accounting Period. Returns the period record (not
     * just its Id) so callers can reject a Closed period with a message naming it —
     * Accounting Seed only blocks closed periods at post time, and the records we
     * build are non-posted, so an unchecked Closed period strands them (FS-15065).
     */
    private static Map<Date, AcctSeed__Accounting_Period__c> resolvePeriods(List<Bill> bills) {
        Map<Date, AcctSeed__Accounting_Period__c> periodByDate = new Map<Date, AcctSeed__Accounting_Period__c>();
        Set<Date> allDates = new Set<Date>();
        for (Bill b : bills) {
            Date d = parseDate(b.issued_at != null ? b.issued_at : b.accounting_date);
            if (d != null) allDates.add(d);
            // Payment date too — Cash Disbursement posts in the payment's period.
            Date pd = parseDate((b.payment != null && b.payment.payment_date != null) ? b.payment.payment_date : b.paid_at);
            if (pd != null) allDates.add(pd);
        }
        if (allDates.isEmpty()) return periodByDate;
        Date minDate, maxDate;
        for (Date d : allDates) {
            if (minDate == null || d < minDate) minDate = d;
            if (maxDate == null || d > maxDate) maxDate = d;
        }
        for (AcctSeed__Accounting_Period__c p : [
            SELECT Id, Name, AcctSeed__Status__c, AcctSeed__Start_Date__c, AcctSeed__End_Date__c
            FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Start_Date__c <= :maxDate AND AcctSeed__End_Date__c >= :minDate
        ]) {
            for (Date d : allDates) {
                if (d >= p.AcctSeed__Start_Date__c && d <= p.AcctSeed__End_Date__c) periodByDate.put(d, p);
            }
        }
        return periodByDate;
    }

    /**
     * @description Wording for a Closed-period failure (FS-15065). Names both the
     * period and the date that landed in it, so the error queue entry is actionable
     * without opening Ramp.
     */
    private static String closedPeriodMessage(String periodName, Date d, String dateFieldLabel) {
        return 'Accounting Period ' + (String.isBlank(periodName) ? '(unnamed)' : periodName)
            + ' covering date ' + String.valueOf(d) + ' is closed in Accounting Seed. '
            + 'Reopen the period or adjust the ' + dateFieldLabel + ' in Ramp.';
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