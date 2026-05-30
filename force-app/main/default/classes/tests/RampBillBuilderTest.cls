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
