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
}
