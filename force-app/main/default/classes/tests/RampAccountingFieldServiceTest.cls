/**
 * @description Test class for RampAccountingFieldService
 */
@IsTest
private class RampAccountingFieldServiceTest {

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    @IsTest
    static void testSyncAccountingVariablesToRamp_Success() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);

        Test.stopTest();

        // Verify all 4 fields were created
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('GL Account Variable 1'), 'Result should mention Variable 1');
        System.assert(result.contains('GL Account Variable 2'), 'Result should mention Variable 2');
        System.assert(result.contains('GL Account Variable 3'), 'Result should mention Variable 3');
        System.assert(result.contains('GL Account Variable 4'), 'Result should mention Variable 4');
        System.assert(result.contains('Created'), 'Result should indicate fields were created');
    }

    @IsTest
    static void testCreateCustomField_ApiFailure() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockError());

        try {
            RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);
            System.assert(false, 'Should have thrown exception');
        } catch (RampAccountingFieldService.RampAccountingFieldException e) {
            System.assert(e.getMessage().contains('Error'), 'Exception should contain error message');
        }

        Test.stopTest();
    }

    @IsTest
    static void testGetCustomFields() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.getCustomFields();

        Test.stopTest();

        System.assert(result.contains('Status: 200'), 'Should return status 200');
    }

    @IsTest
    static void testDeleteCustomField() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockDelete());

        String result = RampAccountingFieldService.deleteCustomField('test-field-id');

        Test.stopTest();

        System.assert(result.contains('Status: 204'), 'Should return status 204');
    }

    /**
     * Mock HTTP callout for successful field creation
     */
    private class RampAccountingFieldMockSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'POST') {
                // Create field response
                res.setStatusCode(201);
                res.setBody('{"id": "field_' + callCount++ + '", "name": "Test Field"}');
            } else if (req.getMethod() == 'GET') {
                // Get fields response
                res.setStatusCode(200);
                res.setBody('{"data": []}');
            }

            return res;
        }
    }

    /**
     * Mock HTTP callout for delete response
     */
    private class RampAccountingFieldMockDelete implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            res.setStatusCode(204);
            res.setBody('');
            return res;
        }
    }

    /**
     * Mock HTTP callout for error responses
     */
    private class RampAccountingFieldMockError implements HttpCalloutMock {
        private Boolean tokenProvided = false;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            res.setStatusCode(400);
            res.setBody('{"error": "Bad Request"}');
            return res;
        }
    }
}