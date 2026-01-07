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
     */
    private class RampAPIMockSuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"success": true}');
            return res;
        }
    }

    /**
     * @description Mock class that returns 401 first, then 200 on retry
     */
    private class RampAPIMock401ThenSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();

            if (callCount == 1) {
                res.setStatusCode(401);
                res.setBody('{"error": "Unauthorized"}');
            } else {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"success": true}');
            }

            return res;
        }
    }
}