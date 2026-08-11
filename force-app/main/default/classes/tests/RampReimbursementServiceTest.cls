/**
 * @description Tests for RampReimbursementService — fetch SYNC_READY reimbursements,
 * create employee Payables, and acknowledge REIMBURSEMENT_SYNC.
 */
@IsTest
private class RampReimbursementServiceTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    @TestSetup
    static void setup() { TestDataFactory.getInstance().initialize(); }

    private static String configureForSync() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        AcctSeed__GL_Account__c suspense, bank;
        System.runAs(admin) {
            ledger.Name = 'ReimbLedger-TEST';
            update ledger;
            suspense = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Type__c = 'Expense' AND AcctSeed__Bank__c = false LIMIT 1];
            bank = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Bank__c = true LIMIT 1];
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(Default_Ledger__c = 'ReimbLedger-TEST', Default_JE_Status__c = 'In Process', Send_Sync_Ack__c = true);
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => suspense.Id,
            RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK => bank.Id
        };
        RampSyncSettingsService.resetCache();
        return [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email;
    }

    @IsTest
    static void syncPage_reimbursement_createsPayableAndAcks() {
        String email = configureForSync();
        Test.setMock(HttpCalloutMock.class, new ReimbMock(email));

        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.reimbursementsFetched);
        System.assertEquals(1, r.payablesCreated, 'Errors: ' + r.errorMessages);
        System.assertEquals(0, r.failedCount, 'Errors: ' + r.errorMessages);

        List<AcctSeed__Account_Payable__c> aps = [
            SELECT AcctSeed__Employee__c, Ramp_Sync_Status__c,
                (SELECT AcctSeed__Amount__c FROM AcctSeed__Project_Account_Payable_Lines__r)
            FROM AcctSeed__Account_Payable__c WHERE AcctSeed__ExtId__c = 'ramp-reimb-1'
        ];
        System.assertEquals(1, aps.size());
        System.assertEquals(UserInfo.getUserId(), aps[0].AcctSeed__Employee__c, 'employee payee set');
        System.assertEquals('Synced_To_Ramp', aps[0].Ramp_Sync_Status__c, 'REIMBURSEMENT_SYNC ack flips status');
        System.assertEquals(1, aps[0].AcctSeed__Project_Account_Payable_Lines__r.size());
    }

    @IsTest
    static void syncPage_empty_returnsEmpty() {
        configureForSync();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());
        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();
        System.assertEquals(0, r.reimbursementsFetched);
        System.assertEquals(true, r.isLastPage);
    }

    // --------------------------------------------------------------------
    private abstract class BaseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"reimbursements:read accounting:write"}');
                return res;
            }
            return api(req, res);
        }
        protected abstract HttpResponse api(HttpRequest req, HttpResponse res);
    }

    private class EmptyMock extends BaseMock {
        protected override HttpResponse api(HttpRequest req, HttpResponse res) { res.setStatusCode(200); res.setBody('{"data":[],"page":{"next":null}}'); return res; }
    }

    private class ReimbMock extends BaseMock {
        private String email;
        public ReimbMock(String e) { this.email = e; }
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/reimbursements')) { res.setStatusCode(200); res.setBody(reimbJson(email)); }
            else if (req.getEndpoint().contains('/accounting/syncs')) { res.setStatusCode(201); res.setBody('{"id":"sync-uuid"}'); }
            else { res.setStatusCode(404); res.setBody('unexpected ' + req.getEndpoint()); }
            return res;
        }
    }

    private static String reimbJson(String email) {
        Date d = [SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1].AcctSeed__Start_Date__c;
        Map<String, Object> reimb = new Map<String, Object>{
            'id' => 'ramp-reimb-1', 'user_id' => 'ru-1', 'user_email' => email, 'user_full_name' => 'Test Emp',
            'amount' => 75.00, 'currency' => 'USD', 'direction' => 'BUSINESS_TO_USER', 'type' => 'OUT_OF_POCKET',
            'state' => 'APPROVED', 'sync_status' => 'SYNC_READY', 'transaction_date' => String.valueOf(d),
            'memo' => 'Client dinner', 'merchant' => 'Cafe', 'entity_id' => 'e1'
        };
        return JSON.serialize(new Map<String, Object>{ 'data' => new List<Object>{ reimb }, 'page' => new Map<String, Object>{ 'next' => null } });
    }

    private static String configureForSyncNoSuspense() {
        String email = configureForSync();
        // Remove the suspense GL so the builder throws BuildException for
        // any reimbursement whose GL Account cannot be resolved.
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK => RampSyncSettingsService.overrideGLDefaults.get(RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK)
        };
        RampSyncSettingsService.resetCache();
        return email;
    }

    private static String configureForSyncNoBankGL() {
        String email = configureForSync();
        // Remove bank GL so the builder skips CD creation for REIMBURSED reimbursements.
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => RampSyncSettingsService.overrideGLDefaults.get(RampSyncSettingsService.SPEC_SUSPENSE)
        };
        RampSyncSettingsService.resetCache();
        return email;
    }

    @IsTest
    static void syncPage_lineDmlFailure_marksPayableFailed() {
        String email = configureForSync();
        // Override suspense GL to a fake non-existent Id so the builder's line
        // references an invalid GL Account, causing the line upsert (allOrNone=false)
        // to fail while the header upsert succeeds.
        Id fakeGLId = TestDataFactory.generateFakeId(AcctSeed__GL_Account__c.getSObjectType());
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => fakeGLId
        };
        RampSyncSettingsService.resetCache();
        Test.setMock(HttpCalloutMock.class, new NoGLMock(email));

        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.failedCount, 'Line DML failure should increment failedCount: ' + r.errorMessages);
        List<AcctSeed__Account_Payable__c> aps = [
            SELECT Ramp_Sync_Status__c, Ramp_Sync_Error__c
            FROM AcctSeed__Account_Payable__c WHERE AcctSeed__ExtId__c = 'ramp-reimb-fail-1'
        ];
        System.assertEquals(1, aps.size(), 'Payable header should have been created despite line failure');
        System.assertEquals('Failed', aps[0].Ramp_Sync_Status__c, 'toFail block should mark payable as Failed');
        System.assert(String.isNotBlank(aps[0].Ramp_Sync_Error__c), 'Ramp_Sync_Error__c should be populated with the line error');
    }

    @IsTest
    static void syncPage_builderFailure_incrementsFailedCount() {
        String email = configureForSyncNoSuspense();
        Test.setMock(HttpCalloutMock.class, new NoGLMock(email));

        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.failedCount, 'Builder failure should increment failedCount');
        System.assertEquals(1, r.errorMessages.size(), 'Error message should be recorded');
        System.assert(r.errorMessages[0].contains('ramp-reimb-fail-1'), 'Error message should include the reimbursement id: ' + r.errorMessages[0]);
    }

    @IsTest
    static void syncPage_reimbursed_createsBatchWithCorrectName() {
        String email = configureForSync();
        Date payDate = [SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1].AcctSeed__Start_Date__c;
        Test.setMock(HttpCalloutMock.class, new ReimbursedMock(email, payDate));

        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.payablesCreated, 'Errors: ' + r.errorMessages);
        System.assertEquals(1, r.cashDisbursementsCreated, 'Errors: ' + r.errorMessages);
        List<AcctSeed__Cash_Disbursement_Batch__c> batches = [SELECT Name FROM AcctSeed__Cash_Disbursement_Batch__c WHERE AcctSeed__ExtId__c LIKE 'RAMP-REIMB:%'];
        System.assertEquals(1, batches.size(), 'One batch should be created');
        System.assertEquals('Ramp Reimbursement ' + String.valueOf(payDate), batches[0].Name, 'Batch name must follow naming convention');
    }

    @IsTest
    static void syncPage_reimbursedNoBankGL_warnsInNotes() {
        String email = configureForSyncNoBankGL();
        Date payDate = [SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1].AcctSeed__Start_Date__c;
        Test.setMock(HttpCalloutMock.class, new ReimbursedMock(email, payDate));

        Test.startTest();
        RampReimbursementService.PageResult r = RampReimbursementService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.payablesCreated, 'Payable should still be created: ' + r.errorMessages);
        System.assertEquals(0, r.failedCount, 'failedCount should remain 0 — payable succeeded');
        System.assertEquals(0, r.cashDisbursementsCreated, 'No CD should be created without bank GL');
        System.assertEquals(1, r.errorMessages.size(), 'Warning should be logged to AJR notes: ' + r.errorMessages);
        System.assert(r.errorMessages[0].contains('Ramp Bill Payment Bank'), 'Warning should mention the missing GL Account config: ' + r.errorMessages[0]);
    }

    private class ReimbursedMock extends BaseMock {
        private String email;
        private Date payDate;
        public ReimbursedMock(String e, Date d) { this.email = e; this.payDate = d; }
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/reimbursements')) { res.setStatusCode(200); res.setBody(reimbursedJson(email, payDate)); }
            else if (req.getEndpoint().contains('/accounting/syncs')) { res.setStatusCode(201); res.setBody('{"id":"sync-uuid"}'); }
            else { res.setStatusCode(404); res.setBody('unexpected ' + req.getEndpoint()); }
            return res;
        }
    }

    private class NoGLMock extends BaseMock {
        private String email;
        public NoGLMock(String e) { this.email = e; }
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/reimbursements')) { res.setStatusCode(200); res.setBody(noGLJson(email)); }
            else { res.setStatusCode(404); res.setBody('unexpected ' + req.getEndpoint()); }
            return res;
        }
    }

    private static String noGLJson(String email) {
        Date d = [SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1].AcctSeed__Start_Date__c;
        Map<String, Object> reimb = new Map<String, Object>{
            'id' => 'ramp-reimb-fail-1', 'user_id' => 'ru-fail-1', 'user_email' => email, 'user_full_name' => 'Test Emp',
            'amount' => 50.00, 'currency' => 'USD', 'direction' => 'BUSINESS_TO_USER', 'type' => 'OUT_OF_POCKET',
            'state' => 'APPROVED', 'sync_status' => 'SYNC_READY', 'transaction_date' => String.valueOf(d),
            'memo' => 'Office supplies', 'merchant' => 'Store', 'entity_id' => 'e3'
        };
        return JSON.serialize(new Map<String, Object>{ 'data' => new List<Object>{ reimb }, 'page' => new Map<String, Object>{ 'next' => null } });
    }

    private static String reimbursedJson(String email, Date payDate) {
        Map<String, Object> reimb = new Map<String, Object>{
            'id' => 'ramp-reimb-paid-1', 'user_id' => 'ru-paid-1', 'user_email' => email, 'user_full_name' => 'Test Emp',
            'amount' => 50.00, 'currency' => 'USD', 'direction' => 'BUSINESS_TO_USER', 'type' => 'OUT_OF_POCKET',
            'state' => 'REIMBURSED', 'sync_status' => 'SYNC_READY', 'transaction_date' => String.valueOf(payDate),
            'payment_processed_at' => String.valueOf(payDate) + 'T00:00:00+00:00',
            'memo' => 'Travel', 'merchant' => 'Hotel', 'entity_id' => 'e2'
        };
        return JSON.serialize(new Map<String, Object>{ 'data' => new List<Object>{ reimb }, 'page' => new Map<String, Object>{ 'next' => null } });
    }
}
