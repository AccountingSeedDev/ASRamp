/**
 * @description Test class for RampConfigurationController
 */
@IsTest
private class RampConfigurationControllerTest {

    @IsTest
    static void testGetActiveCredential_NoCredential() {
        Test.startTest();
        RampConfigurationController.CredentialWrapper result =
            RampConfigurationController.getActiveCredential();
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null when no active credential exists');
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
        try {
            RampConfigurationController.testConnection();
            System.assert(false, 'Should throw an exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('failed'), 'Should contain error message');
        }
        Test.stopTest();
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
        try {
            RampConfigurationController.saveCredential(credential);
            System.assert(false, 'Should throw validation exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Client ID'), 'Should mention Client ID');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveCredential_MissingClientSecret() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.developerName = 'Test';
        credential.clientId = 'test_client_id';

        Test.startTest();
        try {
            RampConfigurationController.saveCredential(credential);
            System.assert(false, 'Should throw validation exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Client Secret'), 'Should mention Client Secret');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveCredential_MissingDeveloperName() {
        RampConfigurationController.CredentialWrapper credential =
            new RampConfigurationController.CredentialWrapper();
        credential.clientId = 'test_client_id';
        credential.clientSecret = 'test_secret';

        Test.startTest();
        try {
            RampConfigurationController.saveCredential(credential);
            System.assert(false, 'Should throw validation exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Developer Name'), 'Should mention Developer Name');
        }
        Test.stopTest();
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
            if (callCount == 1) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            }
            // Second call is for API test
            else {
                res.setStatusCode(200);
                res.setBody('{"id":"user123","email":"test@example.com"}');
            }

            return res;
        }
    }

    /**
     * @description Mock for failed connection test
     */
    private class RampConnectionFailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"error":"invalid_client"}');
            return res;
        }
    }
}