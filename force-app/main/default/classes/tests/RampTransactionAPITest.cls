/**
 * @description Tests for the global RampTransactionAPI.getTransaction.
 */
@IsTest
private class RampTransactionAPITest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    private static final String TXN_JSON =
        '{"id":"abc-123","amount":111.42,"currency_code":"USD",' +
        '"accounting_date":"2026-05-10T12:00:00+00:00","user_transaction_time":"2026-05-10T12:00:00+00:00",' +
        '"merchant_name":"Atlassian","merchant_descriptor":"ATLASSIAN*SUB 12345","state":"CLEARED",' +
        '"sync_status":"SYNC_READY","sk_category_name":"SaaS",' +
        '"card_holder":{"user_id":"u-1","first_name":"Jane","last_name":"Doe","department_name":"Eng"},' +
        '"accounting_field_selections":[{"id":"gl-1","type":"GL_ACCOUNT","name":"6000",' +
        '"category_info":{"type":"GL_ACCOUNT","name":"GL Account"}}],' +
        '"line_items":[{"memo":"split","amount":{"amount":11142,"currency_code":"USD","minor_unit_conversion_rate":100},' +
        '"converted_amount":{"amount":11142,"currency_code":"USD","minor_unit_conversion_rate":100}}],' +
        '"unmodeled_field":"still in rawJson"}';

    private class Mock implements HttpCalloutMock {
        private Integer status;
        Mock(Integer status) { this.status = status; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            } else {
                res.setStatusCode(status);
                res.setBody(status == 200 ? TXN_JSON : '{"error":{"message":"nope"}}');
            }
            return res;
        }
    }

    @IsTest
    static void getTransaction_parsesStructuredResponse() {
        Test.setMock(HttpCalloutMock.class, new Mock(200));
        Test.startTest();
        RampTransactionAPI.RampTransaction t = RampTransactionAPI.getTransaction('abc-123');
        Test.stopTest();

        System.assertEquals('abc-123', t.id);
        System.assertEquals(111.42, t.amount);
        System.assertEquals('Atlassian', t.merchant_name);
        System.assertEquals('ATLASSIAN*SUB 12345', t.merchant_descriptor);
        System.assertEquals('SYNC_READY', t.sync_status);
        System.assertEquals('Eng', t.card_holder.department_name);
        System.assertEquals('GL_ACCOUNT', t.accounting_field_selections[0].type);
        System.assertEquals(11142, t.line_items[0].converted_amount.amount);
        System.assert(t.rawJson != null && t.rawJson.contains('unmodeled_field'),
            'rawJson should carry the full response, including unmodeled fields');
    }

    @IsTest
    static void getTransaction_blankIdThrows() {
        Test.startTest();
        try {
            RampTransactionAPI.getTransaction('  ');
            System.assert(false, 'Expected exception for blank id');
        } catch (RampTransactionAPI.RampTransactionAPIException e) {
            System.assert(e.getMessage().contains('required'));
        }
        Test.stopTest();
    }

    @IsTest
    static void getTransaction_notFoundThrows() {
        Test.setMock(HttpCalloutMock.class, new Mock(404));
        Test.startTest();
        try {
            RampTransactionAPI.getTransaction('missing-uuid');
            System.assert(false, 'Expected not-found exception');
        } catch (RampTransactionAPI.RampTransactionAPIException e) {
            System.assert(e.getMessage().contains('not found'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void getTransaction_apiErrorThrows() {
        Test.setMock(HttpCalloutMock.class, new Mock(500));
        Test.startTest();
        try {
            RampTransactionAPI.getTransaction('boom');
            System.assert(false, 'Expected error exception');
        } catch (RampTransactionAPI.RampTransactionAPIException e) {
            System.assert(e.getMessage().contains('HTTP 500'), e.getMessage());
        }
        Test.stopTest();
    }
}
