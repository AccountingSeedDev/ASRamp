/**
 * @description Test class for RampAPIService
 */
@IsTest
private class RampAPIServiceTest {

    @IsTest
    static void testGet_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAPIMockSuccess());

        Test.startTest();
        HttpResponse res = RampAPIService.get('/v1/transactions');
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode(), 'Status code should be 200');
        String responseBody = RampAPIService.handleResponse(res);
        System.assertNotEquals(null, responseBody, 'Response body should not be null');
    }

    @IsTest
    static void testPost_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAPIMockSuccess());

        String requestBody = '{"test": "data"}';

        Test.startTest();
        HttpResponse res = RampAPIService.post('/v1/test', requestBody);
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode(), 'Status code should be 200');
    }

    @IsTest
    static void testPatch_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAPIMockSuccess());

        String requestBody = '{"test": "data"}';

        Test.startTest();
        HttpResponse res = RampAPIService.patch('/v1/test/123', requestBody);
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode(), 'Status code should be 200');
    }

    @IsTest
    static void testDelete_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAPIMockSuccess());

        Test.startTest();
        HttpResponse res = RampAPIService.doDelete('/v1/test/123');
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode(), 'Status code should be 200');
    }

    @IsTest
    static void testHandleResponse_Error() {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(400);
        res.setBody('{"error": "Bad Request"}');

        Test.startTest();
        try {
            RampAPIService.handleResponse(res);
            System.assert(false, 'Expected RampAPIException to be thrown');
        } catch (RampAPIService.RampAPIException e) {
            System.assert(
                e.getMessage().contains('400'),
                'Error message should contain status code'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void testMakeRequest_TokenRetry() {
        Test.setMock(HttpCalloutMock.class, new RampAPIMock401ThenSuccess());

        Test.startTest();
        HttpResponse res = RampAPIService.get('/v1/test');
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode(), 'Should succeed after retry');
    }

    /**
     * @description Mock class for successful API response
     * Handles both token request and API request
     */
    private class RampAPIMockSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is always for the token
            if (callCount == 1 || req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            }
            // Subsequent calls are for the actual API
            else {
                res.setStatusCode(200);
                res.setBody('{"success": true}');
            }

            return res;
        }
    }

    /**
     * @description Mock class that returns 401 first, then 200 on retry
     * Handles token request, 401 API response, token refresh, then success
     */
    private class RampAPIMock401ThenSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is for initial token
            if (callCount == 1) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            }
            // Second call is the API call that returns 401
            else if (callCount == 2) {
                res.setStatusCode(401);
                res.setBody('{"error": "Unauthorized"}');
            }
            // Third call is the token refresh
            else if (callCount == 3) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"new_test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            }
            // Fourth call is the retry that succeeds
            else {
                res.setStatusCode(200);
                res.setBody('{"success": true}');
            }

            return res;
        }
    }
}