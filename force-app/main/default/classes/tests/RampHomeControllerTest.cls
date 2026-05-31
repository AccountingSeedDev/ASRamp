/**
 * @description Tests for RampHomeController.getHomeData — pipelines (incl. the
 * reimbursement payable pipeline) and Automated-Job-Results-fed metrics.
 */
@IsTest
private class RampHomeControllerTest {

    @TestSetup
    static void setup() { TestDataFactory.getInstance().initialize(); }

    @IsTest
    static void getHomeData_buildsPipelinesAndJobMetrics() {
        insert new AcctSeed__Automated_Job_Results__c(
            AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_CARD_SYNC,
            AcctSeed__Processed__c = 10, AcctSeed__Succeeded__c = 8, AcctSeed__Failed__c = 2
        );

        Test.startTest();
        RampHomeController.HomeData d = RampHomeController.getHomeData();
        Test.stopTest();

        System.assertEquals(4, d.pipelines.size(), 'master + txn + bill + reimb');
        Boolean reimbImplemented = false;
        Boolean billImplemented = false;
        for (RampHomeController.Pipeline p : d.pipelines) {
            if (p.id == 'reimb') reimbImplemented = p.implemented;
            if (p.id == 'bill') billImplemented = p.implemented;
        }
        System.assert(reimbImplemented, 'reimbursement pipeline is live');
        System.assert(billImplemented, 'bill pipeline is live');

        // Automated Job Results feed the metrics.
        System.assertEquals(3, d.jobs.size());
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
}
