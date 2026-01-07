/**
 * @description Test class for RampConfigurationController
 */
@IsTest
private class RampConfigurationControllerTest {

    @IsTest
    static void testGetActiveCredential_WithCredential() {
        // Since we have a Default credential in the org, test that it's returned
        Test.startTest();
        RampConfigurationController.CredentialWrapper result =
            RampConfigurationController.getActiveCredential();
        Test.stopTest();

        // If a credential exists, it should be returned
        // This test validates that getActiveCredential works correctly
        System.assertNotEquals(null, result, 'Should return credential if one exists');
        if (result != null) {
            System.assertNotEquals(null, result.developerName, 'Developer name should not be null');
        }
    }

    @IsTest
    static void testTestConnection_Success() {
        Test.setMock(HttpCalloutMock.class, new RampConnectionSuccessMock());

        Test.startTest();
        String result = RampConfigurationController.testConnection();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('successful'), 'Should contain success message');
    }

    @IsTest
    static void testTestConnection_Failure() {
        Test.setMock(HttpCalloutMock.class, new RampConnectionFailureMock());

        Test.startTest();
        String result = RampConfigurationController.testConnection();
        Test.stopTest();

        // When API returns non-200, it returns a message (not throws exception)
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('401') || result.contains('status'),
                     'Should mention the error status: ' + result);
    }

    @IsTest
    static void testClearTokenCache_Success() {
        Test.startTest();
        String result = RampConfigurationController.clearTokenCache();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('cleared'), 'Should contain success message');
    }

    @IsTest
    static void testSaveCredential_Success() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.developerName = 'Test';
        credential.label = 'Test Credential';
        credential.clientId = 'test_client_id';
        credential.clientSecret = 'test_secret';
        credential.tokenUrl = 'https://api.ramp.com/oauth/token';
        credential.apiBaseUrl = 'https://api.ramp.com';
        credential.scopes = 'transactions:read';
        credential.isActive = true;

        Test.startTest();
        String result = RampConfigurationController.saveCredential(credential);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('deploy'), 'Should contain deployment instructions');
    }

    @IsTest
    static void testSaveCredential_MissingClientId() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.developerName = 'Test';
        credential.clientSecret = 'test_secret';

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // Verify the exception message mentions Client ID
            String msg = e.getMessage();
            System.assert(msg != null && (msg.contains('Client ID') || msg.contains('Client_ID')),
                         'Exception message should mention Client ID. Got: ' + msg);
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception');
    }

    @IsTest
    static void testSaveCredential_MissingClientSecret() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.developerName = 'Test';
        credential.clientId = 'test_client_id';

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // Verify the exception message mentions Client Secret
            String msg = e.getMessage();
            System.assert(msg != null && (msg.contains('Client Secret') || msg.contains('Client_Secret')),
                         'Exception message should mention Client Secret. Got: ' + msg);
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception');
    }

    @IsTest
    static void testSaveCredential_MissingDeveloperName() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.clientId = 'test_client_id';
        credential.clientSecret = 'test_secret';

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // Verify the exception message mentions Developer Name
            String msg = e.getMessage();
            System.assert(msg != null && (msg.contains('Developer Name') || msg.contains('DeveloperName')),
                         'Exception message should mention Developer Name. Got: ' + msg);
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception');
    }

    /**
     * @description Mock for successful connection test
     */
    private class RampConnectionSuccessMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is for token
            if (callCount == 1 || req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            }
            // Second call is for API test
            else {
                res.setStatusCode(200);
                res.setBody('{"data":[{"id":"tx123"}]}');
            }

            return res;
        }
    }

    /**
     * @description Mock for failed connection test
     */
    private class RampConnectionFailureMock implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is for token - return success so we can test the API failure
            if (callCount == 1 || req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read"}');
            }
            // Second call is for API test - return 401
            else {
                res.setStatusCode(401);
                res.setBody('{"error":"invalid_client"}');
            }

            return res;
        }
    }
}