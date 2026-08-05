/**
 * @description Tests for RampBillBuilder — Ramp bill → Accounting Seed Payable + lines.
 */
@IsTest
private class RampBillBuilderTest {

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    private static AcctSeed__GL_Account__c suspenseGL;
    private static AcctSeed__GL_Account__c bankGL;

    private static void configure() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        System.runAs(admin) {
            ledger.Name = 'BillLedger-TEST';
            update ledger;
            suspenseGL = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Type__c = 'Expense' LIMIT 1];
            bankGL = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Bank__c = true LIMIT 1];
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'BillLedger-TEST', Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => suspenseGL.Id,
            RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK => bankGL.Id
        };
        RampSyncSettingsService.resetCache();
    }

    private static AcctSeed__GL_Account__c codedGL(String rampId) {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__GL_Account__c gl;
        System.runAs(admin) {
            gl = [SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Type__c = 'Expense' AND Ramp_Id__c = null AND Id != :suspenseGL.Id LIMIT 1];
            gl.Ramp_Id__c = rampId;
            update gl;
        }
        return gl;
    }

    private static Id vendorAccount(String name) {
        Account a = new Account(Name = name, AcctSeed__Accounting_Type__c = 'Vendor');
        insert a;
        return a.Id;
    }

    private static Date openPeriodDate() {
        List<AcctSeed__Accounting_Period__c> p = [
            SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1
        ];
        return p.isEmpty() ? Date.today() : p[0].AcctSeed__Start_Date__c;
    }

    private static RampBillBuilder.Bill sampleBill(String id, Long cents, String glUuid, Id vendorAcctId) {
        Date d = openPeriodDate();
        String iso = String.valueOf(d) + 'T00:00:00+00:00';

        RampBillBuilder.Bill b = new RampBillBuilder.Bill();
        b.id = id;
        b.invoice_number = 'INV-' + id;
        b.issued_at = iso;
        b.due_at = iso;
        b.status = 'OPEN';
        b.sync_status = 'NOT_SYNCED';
        b.entity_id = 'entity-uuid';
        b.vendor = new RampBillBuilder.BillVendor();
        b.vendor.id = 'nv-' + id; b.vendor.name = 'Vendor ' + id; b.vendor.remote_id = vendorAcctId;

        RampBillBuilder.CurrencyAmount amt = new RampBillBuilder.CurrencyAmount();
        amt.amount = cents; amt.currency_code = 'USD'; amt.minor_unit_conversion_rate = 100;

        RampBillBuilder.BillLineItem li = new RampBillBuilder.BillLineItem();
        li.amount = amt; li.memo = 'Line memo';
        if (glUuid != null) {
            RampBillBuilder.BillFieldSelection sel = new RampBillBuilder.BillFieldSelection();
            sel.id = glUuid;
            sel.category_info = new RampBillBuilder.BillField();
            sel.category_info.type = 'GL_ACCOUNT';
            li.accounting_field_selections = new List<RampBillBuilder.BillFieldSelection>{ sel };
        }
        b.line_items = new List<RampBillBuilder.BillLineItem>{ li };
        return b;
    }

    @IsTest
    static void build_codedBill_producesPayableAndLine() {
        configure();
        AcctSeed__GL_Account__c gl = codedGL('gl-bill-1');
        Id vId = vendorAccount('Coded Vendor');

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{
            sampleBill('bill-1', 15000, 'gl-bill-1', vId)
        });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        RampBillBuilder.PayableBuild pb = r.successful[0];
        System.assertEquals('bill-1', pb.header.AcctSeed__ExtId__c);
        System.assertEquals(vId, pb.header.AcctSeed__Vendor__c);
        System.assertEquals('INV-bill-1', pb.header.AcctSeed__Payee_Reference__c);
        System.assertEquals('Pending', pb.header.Ramp_Sync_Status__c);
        System.assertEquals(1, pb.lines.size());
        System.assertEquals('bill-1:L0', pb.lines[0].AcctSeed__ExtId__c);
        System.assertEquals(gl.Id, pb.lines[0].AcctSeed__Expense_GL_Account__c);
        System.assertEquals(150.00, pb.lines[0].AcctSeed__Amount__c);
    }

    @IsTest
    static void build_uncodedBill_routesToSuspense() {
        configure();
        Id vId = vendorAccount('Uncoded Vendor');

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{
            sampleBill('bill-2', 5000, null, vId)
        });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        System.assertEquals(suspenseGL.Id, r.successful[0].lines[0].AcctSeed__Expense_GL_Account__c);
    }

    @IsTest
    static void build_payableLineDate_matchesBillDate() {
        configure();
        Id vId = vendorAccount('Date Vendor');
        RampBillBuilder.Bill b = sampleBill('bill-date', 10000, null, vId);

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        RampBillBuilder.PayableBuild pb = r.successful[0];
        System.assertEquals(pb.header.AcctSeed__Date__c, pb.lines[0].AcctSeed__Date__c,
            'Payable line date must match the payable header date');
    }

    @IsTest
    static void build_foreignCurrencyBill_setsCurrencyOnPayable() {
        configure();
        Id vId = vendorAccount('EUR Vendor');
        RampBillBuilder.Bill b = new RampBillBuilder.Bill();
        b.id = 'bill-eur';
        b.invoice_number = 'INV-EUR';
        Date d = openPeriodDate();
        b.issued_at = String.valueOf(d) + 'T00:00:00+00:00';
        b.due_at = b.issued_at;
        b.status = 'OPEN';
        b.sync_status = 'NOT_SYNCED';
        b.entity_id = 'e-eur';
        b.vendor = new RampBillBuilder.BillVendor();
        b.vendor.id = 'nv-eur'; b.vendor.name = 'EUR Vendor'; b.vendor.remote_id = vId;
        RampBillBuilder.CurrencyAmount amt = new RampBillBuilder.CurrencyAmount();
        amt.amount = 70000; amt.currency_code = 'EUR'; amt.minor_unit_conversion_rate = 100;
        b.amount = amt;
        RampBillBuilder.BillLineItem li = new RampBillBuilder.BillLineItem();
        li.amount = amt; li.memo = 'EUR line';
        b.line_items = new List<RampBillBuilder.BillLineItem>{ li };

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        // CurrencyIsoCode only exists when Multi-Currency is enabled; in a
        // single-currency org the build must still succeed without stamping it.
        String apJson = JSON.serialize(r.successful[0].header);
        if (UserInfo.isMultiCurrencyOrganization()) {
            System.assert(apJson.contains('EUR'), 'CurrencyIsoCode EUR should be set on the payable: ' + apJson);
        } else {
            System.assert(!apJson.contains('CurrencyIsoCode'),
                'CurrencyIsoCode must not be set in a single-currency org: ' + apJson);
        }
    }

    @IsTest
    static void build_inactiveGLVariable_failsBill() {
        configure();
        Id vId = vendorAccount('InactiveVar Vendor');

        // Create an Accounting Variable that has a Ramp field option id set,
        // then deactivate it so it won't appear in resolveVariables() but WILL
        // be found by findInactiveVarUuids().
        AcctSeed__Accounting_Variable__c av = new AcctSeed__Accounting_Variable__c(
            Name = 'Deleted Var',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = false,
            Ramp_Field_Option_Id__c = 'var-deleted-1'
        );
        insert av;

        RampBillBuilder.Bill b = sampleBill('bill-inactvar', 5000, null, vId);
        // Add a line-level variable selection referencing the now-inactive variable
        b.line_items[0].accounting_field_selections = new List<RampBillBuilder.BillFieldSelection>{
            varSelection('var-deleted-1', av.Id, 'Deleted Var')
        };

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(0, r.successful.size(), 'Bill with inactive GL variable should fail');
        System.assertEquals(1, r.failed.size(), 'Failed map should have one entry');
        System.assert(r.failed.get('bill-inactvar').contains('no longer available'),
            'Error message should mention unavailability: ' + r.failed.get('bill-inactvar'));
    }

    @IsTest
    static void build_deletedGLVariable_failsBill() {
        configure();
        Id vId = vendorAccount('DeletedVar Vendor');

        // Deleting the variable in Accounting Seed never reaches Ramp, so the option
        // stays selectable there. Reproduce that: the bill still codes to the option,
        // but the Accounting Seed record behind external_id is gone.
        AcctSeed__Accounting_Variable__c av = new AcctSeed__Accounting_Variable__c(
            Name = 'Doomed Var',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = true,
            Ramp_Field_Option_Id__c = 'var-gone-1'
        );
        insert av;
        Id goneId = av.Id;
        delete av;

        RampBillBuilder.Bill b = sampleBill('bill-delvar', 5000, null, vId);
        b.line_items[0].accounting_field_selections = new List<RampBillBuilder.BillFieldSelection>{
            varSelection('var-gone-1', goneId, 'Doomed Var')
        };

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(0, r.successful.size(), 'Bill with deleted GL variable should fail');
        System.assert(r.failed.get('bill-delvar').contains('no longer available'),
            'Error message should mention unavailability: ' + r.failed.get('bill-delvar'));
    }

    @IsTest
    static void build_merchantSelection_doesNotFailBill() {
        configure();
        Id vId = vendorAccount('Merchant Sel Vendor');

        // Merchant selections also carry an external_id (an Account Id) and are routed
        // into the variable bucket, so they must not be mistaken for a deleted variable.
        RampBillBuilder.Bill b = sampleBill('bill-merchant', 5000, null, vId);
        RampBillBuilder.BillFieldSelection merchantSel = new RampBillBuilder.BillFieldSelection();
        merchantSel.id = 'ramp-merchant-1';
        merchantSel.name = 'AdRoll';
        merchantSel.external_id = vId;               // Account Id, not an Accounting Variable
        merchantSel.category_info = new RampBillBuilder.BillField();
        merchantSel.category_info.type = 'MERCHANT';
        b.line_items[0].accounting_field_selections = new List<RampBillBuilder.BillFieldSelection>{ merchantSel };

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(),
            'Merchant selection must not be treated as a deleted GL Variable: ' + r.failed);
    }

    /**
     * A GL Account Variable selection as Ramp actually returns it: id is the Ramp
     * option uuid, external_id is the Accounting Seed record Id, and category_info.type
     * is OTHER (the four GL Account Variable fields are Ramp custom fields).
     */
    private static RampBillBuilder.BillFieldSelection varSelection(String rampOptionId, Id variableId, String name) {
        RampBillBuilder.BillFieldSelection sel = new RampBillBuilder.BillFieldSelection();
        sel.id = rampOptionId;
        sel.name = name;
        sel.external_id = variableId;
        sel.external_code = variableId;
        sel.category_info = new RampBillBuilder.BillField();
        sel.category_info.type = 'OTHER';
        sel.category_info.name = 'GL Account Variable 1';
        return sel;
    }

    @IsTest
    static void build_checkPayment_createsCashDisbursementWithCheckType() {
        configure();
        Id vId = vendorAccount('Check Vendor');
        RampBillBuilder.Bill b = sampleBill('bill-check', 10000, null, vId);
        b.status = 'PAID';
        b.paid_at = b.issued_at;
        b.payment = new RampBillBuilder.BillPayment();
        b.payment.payment_method = 'CHECK';
        b.payment.payment_date = String.valueOf(openPeriodDate());
        RampBillBuilder.CurrencyAmount pamt = new RampBillBuilder.CurrencyAmount();
        pamt.amount = 10000; pamt.currency_code = 'USD'; pamt.minor_unit_conversion_rate = 100;
        b.payment.amount = pamt;

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        System.assertNotEquals(null, r.successful[0].cashDisbursement);
        System.assertEquals('Check', r.successful[0].cashDisbursement.AcctSeed__Type__c,
            'Cash Disbursement type should be Check when payment_method is CHECK');
    }

    @IsTest
    static void build_paidBill_buildsCashDisbursementAndAPD() {
        configure();
        Id vId = vendorAccount('Paid Vendor');
        RampBillBuilder.Bill b = sampleBill('bill-3', 12000, null, vId);
        b.status = 'PAID';
        b.paid_at = b.issued_at;
        b.payment = new RampBillBuilder.BillPayment();
        b.payment.payment_method = 'PAID_MANUALLY';
        b.payment.payment_date = String.valueOf(openPeriodDate());
        RampBillBuilder.CurrencyAmount pamt = new RampBillBuilder.CurrencyAmount();
        pamt.amount = 12000; pamt.currency_code = 'USD'; pamt.minor_unit_conversion_rate = 100;
        b.payment.amount = pamt;

        Test.startTest();
        RampBillBuilder.BuildResult r = RampBillBuilder.build(new List<RampBillBuilder.Bill>{ b });
        Test.stopTest();

        System.assertEquals(1, r.successful.size(), 'Errors: ' + r.failed);
        RampBillBuilder.PayableBuild pb = r.successful[0];
        System.assertEquals(true, pb.isPaid);
        System.assertNotEquals(null, pb.cashDisbursement, 'CD should be built for a paid bill');
        System.assertEquals('bill-3:cd', pb.cashDisbursement.AcctSeed__ExtId__c);
        System.assertEquals(120.00, pb.cashDisbursement.AcctSeed__Amount__c);
        System.assertEquals(bankGL.Id, pb.cashDisbursement.AcctSeed__Bank_Account__c);
        System.assertEquals('Payable', pb.cashDisbursement.AcctSeed__Source__c);
        System.assertNotEquals(null, pb.apDisbursement, 'AP Disbursement should be built');
        System.assertEquals('bill-3:apd', pb.apDisbursement.AcctSeed__ExtId__c);
        System.assertEquals(120.00, pb.apDisbursement.AcctSeed__Paid_Amount__c);
    }
}
