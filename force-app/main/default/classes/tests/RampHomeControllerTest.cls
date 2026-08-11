/**
 * @description Tests for RampHomeController.getHomeData — pipelines (incl. the
 * reimbursement payable pipeline) and Automated-Job-Results-fed metrics.
 */
@IsTest
private class RampHomeControllerTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    @TestSetup
    static void setup() { TestDataFactory.getInstance().initialize(); }

    @IsTest
    static void getHomeData_buildsPipelinesAndJobMetrics() {
        // getHomeData queries the Ramp_* fields (vendor counts, transaction sync
        // status), so run as the admin granted Ramp_Admin FLS in initialize.
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_CARD_SYNC,
                AcctSeed__Processed__c = 10, AcctSeed__Succeeded__c = 8, AcctSeed__Failed__c = 2
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            System.assertEquals(6, d.pipelines.size(), 'gl + var + vendor + txn + bill + reimb');
            Boolean reimbImplemented = false;
            Boolean billImplemented = false;
            for (RampHomeController.Pipeline p : d.pipelines) {
                if (p.id == 'reimb') reimbImplemented = p.implemented;
                if (p.id == 'bill') billImplemented = p.implemented;
            }
            System.assert(reimbImplemented, 'reimbursement pipeline is live');
            System.assert(billImplemented, 'bill pipeline is live');

            // Automated Job Results feed the metrics (3 transaction + 3 master jobs).
            System.assertEquals(6, d.jobs.size());
            System.assert(d.recordsProcessed >= 10, 'recordsProcessed sourced from AJR');
            Boolean cardSeen = false;
            for (RampHomeController.JobMetric j : d.jobs) {
                if (j.label == 'Card transactions') {
                    cardSeen = true;
                    System.assertEquals(10, j.processed);
                    System.assertEquals(2, j.failed);
                    System.assertEquals('errors', j.statusKind);
                }
            }
            System.assert(cardSeen, 'card job metric present');
        }
    }

    @IsTest
    static void getPipelineAvailability_countsWithCap() {
        Test.setMock(HttpCalloutMock.class, new AvailMock());
        Test.startTest();
        Map<String, String> avail = RampHomeController.getPipelineAvailability();
        Test.stopTest();
        // mock returns 3 items + a next page → "3+"
        System.assertEquals('3+', avail.get('txn'));
        System.assertEquals('3+', avail.get('bill'));
        System.assertEquals('3+', avail.get('reimb'));
    }

    private class AvailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            if (req.getEndpoint().contains('/token')) {
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"transactions:read bills:read reimbursements:read"}');
            } else {
                res.setBody('{"data":[{},{},{}],"page":{"next":"https://demo-api.ramp.com/x?start=abc"}}');
            }
            return res;
        }
    }

    @IsTest
    static void getConnectionStatus_liveVerifiedReturnsBusinessName() {
        Test.setMock(HttpCalloutMock.class, new BizMock(200, '{"business_name_legal":"Acme Inc"}'));
        Test.startTest();
        RampHomeController.ConnStatus s = RampHomeController.getConnectionStatus();
        Test.stopTest();
        System.assert(s.connected, 'a 2xx from /business means the connection is live');
        System.assertEquals('Acme Inc', s.business, 'real workspace name comes from the response');
    }

    @IsTest
    static void getConnectionStatus_missingScopeStillConnected() {
        Test.setMock(HttpCalloutMock.class, new BizMock(403, '{"error":"forbidden"}'));
        Test.startTest();
        RampHomeController.ConnStatus s = RampHomeController.getConnectionStatus();
        Test.stopTest();
        System.assert(s.connected, '403 = authenticated but lacks business:read; still live');
    }

    @IsTest
    static void getConnectionStatus_authFailureNotConnected() {
        Test.setMock(HttpCalloutMock.class, new BizMock(401, '{"error":"unauthorized"}'));
        Test.startTest();
        RampHomeController.ConnStatus s = RampHomeController.getConnectionStatus();
        Test.stopTest();
        System.assert(!s.connected, '401 means authentication failed → not connected');
    }

    private class BizMock implements HttpCalloutMock {
        private Integer code;
        private String body;
        BizMock(Integer c, String b) { this.code = c; this.body = b; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"business:read"}');
            } else {
                res.setStatusCode(code);
                res.setBody(body);
            }
            return res;
        }
    }

    @IsTest
    static void getHomeData_reimbAjrFailures_surfacedInErrorQueue() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_REIMBURSEMENT_SYNC,
                AcctSeed__Processed__c = 1, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 1,
                AcctSeed__Notes__c = 'ramp-reimb-err-1: Could not resolve an Expense GL Account for reimbursement ramp-reimb-err-1'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean foundReimbFailure = false;
            for (RampHomeController.Failure f : d.failures) {
                if ('reimb'.equals(f.pipe)) { foundReimbFailure = true; break; }
            }
            System.assert(foundReimbFailure, 'AJR-based reimbursement failure should surface in error queue');
        }
    }

    @IsTest
    static void getHomeData_reimbAjrFailures_surfacedAlongsidePerRecordFailures() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            // Simulate a prior run that left a stale per-record Failed payable.
            AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
            AcctSeed__Accounting_Period__c period = TestDataFactory.getInstance().getAccountingPeriods()[0];
            AcctSeed__Account_Payable__c staleAp = new AcctSeed__Account_Payable__c(
                AcctSeed__Employee__c = UserInfo.getUserId(),
                AcctSeed__Date__c = period.AcctSeed__Start_Date__c,
                AcctSeed__Accounting_Period__c = period.Id,
                AcctSeed__Ledger__c = ledger.Id,
                AcctSeed__Status__c = 'In Process',
                AcctSeed__Payee_Reference__c = 'stale prior-run payee',
                Ramp_Sync_Status__c = 'Failed',
                Ramp_Sync_Error__c = 'stale prior-run error'
            );
            insert staleAp;

            // A new run AJR that also has a build failure (no payable created).
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_REIMBURSEMENT_SYNC,
                AcctSeed__Processed__c = 1, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 1,
                AcctSeed__Notes__c = 'ramp-reimb-new-1: No active Salesforce User matches email'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            // Both the per-record failure AND the AJR-based failure should appear.
            Integer reimbFailureCount = 0;
            for (RampHomeController.Failure f : d.failures) {
                if ('reimb'.equals(f.pipe)) reimbFailureCount++;
            }
            System.assert(reimbFailureCount >= 2,
                'Both the stale per-record failure and the AJR-based build failure should surface: count=' + reimbFailureCount);
        }
    }

    @IsTest
    static void getHomeData_billAjrFailures_surfacedInErrorQueue() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_BILL_SYNC,
                AcctSeed__Processed__c = 1, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 1,
                AcctSeed__Notes__c = 'ramp-bill-err-1: Could not resolve an Expense GL Account for bill ramp-bill-err-1'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean foundBillFailure = false;
            for (RampHomeController.Failure f : d.failures) {
                if ('bill'.equals(f.pipe)) { foundBillFailure = true; break; }
            }
            System.assert(foundBillFailure, 'AJR-based bill failure should surface in error queue');
        }
    }

    @IsTest
    static void getHomeData_vendorSyncFailuresCountTowardFollowUpTotal() {
        // Master-group failures are reported per job run, not per record, so they
        // used to be excluded from failedTotal. The home page then rendered "All
        // active pipelines healthy" (failedTotal == 0) directly above an error
        // queue listing vendor sync errors, with a Review-errors button that
        // looked dead (FS-15026).
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_VENDOR_SYNC,
                AcctSeed__Processed__c = 30, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 30,
                AcctSeed__Notes__c = 'Update ANA TRADING CORP: PATCH failed. Status: 422'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Integer masterFailures = 0;
            for (RampHomeController.Failure f : d.failures) {
                if ('master'.equals(f.groupKey)) masterFailures++;
            }
            System.assertEquals(1, masterFailures, 'Vendor sync AJR failure should surface in the error queue');
            System.assert(d.failedTotal > 0,
                'The health banner must not read healthy while master failures are queued: failedTotal=' + d.failedTotal);
        }
    }

    @IsTest
    static void getHomeData_noFailuresKeepsFollowUpTotalAtZero() {
        // Guards the inverse: a clean run must still report zero, so the banner
        // does not flip to "needs attention" on a healthy org.
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_VENDOR_SYNC,
                AcctSeed__Processed__c = 30, AcctSeed__Succeeded__c = 30, AcctSeed__Failed__c = 0
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            System.assertEquals(0, d.failedTotal, 'A successful vendor sync must not inflate the follow-up total');
            System.assert(d.failures.isEmpty(), 'No failures should be queued for a clean run');
        }
    }

    @IsTest
    static void getHomeData_cardBuildFailures_surfacedInErrorQueue() {
        // Card transactions that fail to build (unresolved GL, no open period) never
        // persist a Journal Entry, so there is no per-record row to query. Reproduced
        // live against the Ramp sandbox: AJR reported 5 failed while the error queue
        // returned 0 rows and the banner read "All active pipelines healthy" (FS-15031).
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_CARD_SYNC,
                AcctSeed__Processed__c = 5, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 5,
                AcctSeed__Notes__c = 'fff94db5: Could not resolve a GL Account for transaction fff94db5 (line ordinal 0).'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean foundCardFailure = false;
            for (RampHomeController.Failure f : d.failures) {
                if ('txn'.equals(f.pipe)) { foundCardFailure = true; break; }
            }
            System.assert(foundCardFailure, 'AJR-based card failure should surface in the error queue');
            System.assertEquals(5, d.failedTotal,
                'The run\'s 5 failures must reach the follow-up total: failedTotal=' + d.failedTotal);
        }
    }

    @IsTest
    static void getHomeData_cardHardPageFailure_surfacedDespiteZeroCounts() {
        // When syncPage() throws outright, the run is logged with every count at zero
        // and the reason only in Notes. Keying the error queue on Failed__c > 0 alone
        // would miss it entirely — observed live with an unconfigured Card Clearing GL.
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_CARD_SYNC,
                AcctSeed__Processed__c = 0, AcctSeed__Succeeded__c = 0, AcctSeed__Failed__c = 0,
                AcctSeed__Notes__c = 'Page failed at cursor=null: No "Ramp Card Clearing" GL Account is configured for the sync ledger.'
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean foundCardFailure = false;
            for (RampHomeController.Failure f : d.failures) {
                if ('txn'.equals(f.pipe)) { foundCardFailure = true; break; }
            }
            System.assert(foundCardFailure,
                'A hard page failure logged as 0/0/0 must still surface in the error queue');
            System.assert(d.failedTotal > 0,
                'The banner must not read healthy while that row is queued: failedTotal=' + d.failedTotal);
        }
    }

    @IsTest
    static void getHomeData_masterStepRemainsCompleteAfterAddingNewGLAccount() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            // Mark one GL Account as synced — simulates initial setup complete.
            List<AcctSeed__GL_Account__c> glAccounts = TestDataFactory.getInstance().getGLAccounts();
            glAccounts[0].Ramp_Id__c = 'ramp-gl-test-001';
            update glAccounts[0];
            // Remaining GL accounts have no Ramp_Id__c, simulating newly added records.

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean masterDone = false;
            for (RampHomeController.Step s : d.steps) {
                if (s.id == 'master') { masterDone = 'done'.equals(s.state); }
            }
            System.assert(masterDone, 'Master step must stay done once any GL account is synced, even if new unsynced records exist');
        }
    }

    @IsTest
    static void getHomeData_masterStepRemainsCompleteViaAjrWhenNoGLAccountsHaveRampId() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            // No GL accounts have Ramp_Id__c set (glSynced == 0), but an AJR record
            // shows the GL sync has previously run and succeeded.  This simulates the
            // scenario where old synced GL accounts are deactivated and new ones are
            // created — the banner must NOT reappear.
            insert new AcctSeed__Automated_Job_Results__c(
                AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_GL_SYNC,
                AcctSeed__Processed__c = 5, AcctSeed__Succeeded__c = 5, AcctSeed__Failed__c = 0
            );

            Test.startTest();
            RampHomeController.HomeData d = RampHomeController.getHomeData();
            Test.stopTest();

            Boolean masterDone = false;
            for (RampHomeController.Step s : d.steps) {
                if (s.id == 'master') { masterDone = 'done'.equals(s.state); }
            }
            System.assert(masterDone,
                'Master step must stay done when AJR confirms a prior successful GL sync, even if no active GL accounts currently have Ramp_Id__c set');
        }
    }
}
