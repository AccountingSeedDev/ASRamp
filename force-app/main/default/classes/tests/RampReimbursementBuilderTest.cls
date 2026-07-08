/**
 * @description Tests for RampReimbursementBuilder — reimbursement → employee Payable.
 */
@IsTest
private class RampReimbursementBuilderTest {

    @TestSetup
    static void setup() { TestDataFactory.getInstance().initialize(); }

    private static AcctSeed__GL_Account__c suspenseGL;
    private static AcctSeed__GL_Account__c bankGL;
    private static String empEmail;

    private static void configure() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        System.runAs(admin) {
            ledger.Name = 'ReimbLedger-TEST';
            update ledger;
            suspenseGL = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Type__c = 'Expense' AND AcctSeed__Bank__c = false LIMIT 1];
            bankGL = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Bank__c = true LIMIT 1];
        }
        empEmail = [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email;
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(Default_Ledger__c = 'ReimbLedger-TEST', Default_JE_Status__c = 'In Process');
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => suspenseGL.Id,
            RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK => bankGL.Id
        };
        RampSyncSettingsService.resetCache();
    }

    private static Date openPeriodDate() {
        List<AcctSeed__Accounting_Period__c> p = [SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1];
        return p.isEmpty() ? Date.today() : p[0].AcctSeed__Start_Date__c;
    }

    private static RampReimbursementBuilder.Reimbursement sample(String id, Decimal amount, String email, String state) {
        Date d = openPeriodDate();
        RampReimbursementBuilder.Reimbursement r = new RampReimbursementBuilder.Reimbursement();
        r.id = id; r.user_id = 'ru-' + id; r.user_email = email; r.user_full_name = 'Test Emp';
        r.amount = amount; r.direction = 'BUSINESS_TO_USER'; r.type = 'OUT_OF_POCKET';
        r.state = state; r.sync_status = 'SYNC_READY';
        r.transaction_date = String.valueOf(d);
        r.memo = 'Lunch'; r.merchant = 'Cafe'; r.entity_id = 'e1';
        if (state == 'REIMBURSED') r.payment_processed_at = String.valueOf(d) + 'T00:00:00+00:00';
        return r;
    }

    @IsTest
    static void build_outOfPocket_buildsEmployeePayable() {
        configure();
        Test.startTest();
        RampReimbursementBuilder.BuildResult res = RampReimbursementBuilder.build(new List<RampReimbursementBuilder.Reimbursement>{ sample('rb-1', 60.00, empEmail, 'APPROVED') });
        Test.stopTest();

        System.assertEquals(1, res.successful.size(), 'Errors: ' + res.failed);
        RampReimbursementBuilder.ReimbursementBuild rb = res.successful[0];
        System.assertEquals('rb-1', rb.header.AcctSeed__ExtId__c);
        System.assertEquals(UserInfo.getUserId(), rb.header.AcctSeed__Employee__c, 'employee resolved by email');
        System.assertEquals(1, rb.lines.size());
        System.assertEquals(suspenseGL.Id, rb.lines[0].AcctSeed__Expense_GL_Account__c, 'uncoded → suspense GL');
        System.assertEquals(60.00, rb.lines[0].AcctSeed__Amount__c);
        System.assertEquals(openPeriodDate(), rb.lines[0].AcctSeed__Date__c, 'line date must match header date');
        System.assertEquals(false, rb.isPaid);
    }

    @IsTest
    static void build_reimbursed_buildsCashDisbursement() {
        configure();
        Test.startTest();
        RampReimbursementBuilder.BuildResult res = RampReimbursementBuilder.build(new List<RampReimbursementBuilder.Reimbursement>{ sample('rb-2', 90.00, empEmail, 'REIMBURSED') });
        Test.stopTest();

        System.assertEquals(1, res.successful.size(), 'Errors: ' + res.failed);
        RampReimbursementBuilder.ReimbursementBuild rb = res.successful[0];
        System.assertEquals(true, rb.isPaid);
        System.assertNotEquals(null, rb.cashDisbursement);
        System.assertEquals('rb-2:cd', rb.cashDisbursement.AcctSeed__ExtId__c);
        System.assertEquals(UserInfo.getUserId(), rb.cashDisbursement.AcctSeed__Employee__c);
        System.assertEquals(90.00, rb.cashDisbursement.AcctSeed__Amount__c);
        System.assertNotEquals(null, rb.apDisbursement);
    }

    @IsTest
    static void build_paybackAndUserToBusiness_skipped() {
        configure();
        RampReimbursementBuilder.Reimbursement payback = sample('rb-3', 50.00, empEmail, 'APPROVED');
        payback.type = 'PAYBACK_FULL';
        RampReimbursementBuilder.Reimbursement owed = sample('rb-4', 50.00, empEmail, 'APPROVED');
        owed.direction = 'USER_TO_BUSINESS';

        Test.startTest();
        RampReimbursementBuilder.BuildResult res = RampReimbursementBuilder.build(new List<RampReimbursementBuilder.Reimbursement>{ payback, owed });
        Test.stopTest();

        System.assertEquals(0, res.successful.size());
        System.assertEquals(2, res.skipped.size(), 'payback + USER_TO_BUSINESS skipped');
    }

    @IsTest
    static void build_unmatchedEmployee_fails() {
        configure();
        Test.startTest();
        RampReimbursementBuilder.BuildResult res = RampReimbursementBuilder.build(new List<RampReimbursementBuilder.Reimbursement>{ sample('rb-5', 25.00, 'nobody-zzz@nonexistent.example', 'APPROVED') });
        Test.stopTest();

        System.assertEquals(0, res.successful.size());
        System.assertEquals(1, res.failed.size());
        System.assert(res.failed.get('rb-5').contains('No active Salesforce User'), res.failed.get('rb-5'));
    }

    @IsTest
    static void build_deletedGLVariable_fails() {
        configure();
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            insert new AcctSeed__Accounting_Variable__c(
                Name = 'Deleted Dept',
                AcctSeed__Type__c = 'GL Account Variable 1',
                AcctSeed__Active__c = false,
                Ramp_Field_Option_Id__c = 'deleted-var-uuid-123'
            );
        }

        RampReimbursementBuilder.Reimbursement r = sample('rb-del', 50.00, empEmail, 'APPROVED');
        RampReimbursementBuilder.ReimbFieldSelection sel = new RampReimbursementBuilder.ReimbFieldSelection();
        sel.id = 'deleted-var-uuid-123';
        sel.name = 'Deleted Dept';
        sel.category_info = new RampReimbursementBuilder.ReimbField();
        sel.category_info.type = 'COST_CENTER';
        r.accounting_field_selections = new List<RampReimbursementBuilder.ReimbFieldSelection>{ sel };

        Test.startTest();
        RampReimbursementBuilder.BuildResult res = RampReimbursementBuilder.build(
            new List<RampReimbursementBuilder.Reimbursement>{ r }
        );
        Test.stopTest();

        System.assertEquals(0, res.successful.size(), 'Deleted variable should cause failure');
        System.assertEquals(1, res.failed.size());
        System.assert(res.failed.get('rb-del').contains('deleted'), 'Error message should mention deletion: ' + res.failed.get('rb-del'));
    }
}
