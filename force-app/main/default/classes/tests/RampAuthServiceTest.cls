/**
 * @description Test class for RampAuthService
 */
@IsTest
private class RampAuthServiceTest {

    @TestSetup
    static void setup() {
        // Note: Custom Metadata cannot be inserted in tests
        // Tests will need to rely on existing Custom Metadata records
        // or use dependency injection patterns for full unit testing
    }

    @IsTest
    static void testGetActiveCredential_NoActiveCredential() {
        // Custom Metadata cannot be controlled in tests
        // Behavior depends on whether credentials are deployed to the org
        Test.startTest();
        List<Ramp_Credential__mdt> activeCredentials = [
            SELECT Id FROM Ramp_Credential__mdt WHERE Is_Active__c = true LIMIT 1
        ];

        if (activeCredentials.isEmpty()) {
            try {
                RampAuthService.getActiveCredential();
                System.assert(false, 'Expected RampAuthException to be thrown');
            } catch (RampAuthService.RampAuthException e) {
                System.assert(
                    e.getMessage().contains('No active Ramp credential found'),
                    'Expected specific error message'
                );
            }
        } else {
            // Active credential exists in org - verify method returns it
            Ramp_Credential__mdt credential = RampAuthService.getActiveCredential();
            System.assertNotEquals(null, credential, 'Should return an active credential');
            System.assert(credential.Is_Active__c, 'Returned credential should be active');
        }
        Test.stopTest();
    }

    @IsTest
    static void testRequestAccessToken_Success() {
        // Create a mock credential
        Ramp_Credential__mdt mockCredential = new Ramp_Credential__mdt(
            Client_ID__c = 'test_client_id',
            Client_Secret__c = 'test_client_secret',
            Token_URL__c = 'https://api.ramp.com/oauth/token',
            Scopes__c = 'transactions:read',
            DeveloperName = 'Test_Credential'
        );

        // Set up mock response
        Test.setMock(HttpCalloutMock.class, new RampAuthSuccessMock());

        Test.startTest();
        RampTokenResponse response = RampAuthService.requestAccessToken(mockCredential);
        Test.stopTest();

        System.assertNotEquals(null, response, 'Response should not be null');
        System.assert(response.isValid(), 'Token should be valid');
        System.assertEquals('test_access_token', response.access_token, 'Access token should match');
        System.assertEquals('Bearer', response.token_type, 'Token type should be Bearer');
        System.assertEquals(864000, response.expires_in, 'Expires in should be 10 days');
    }

    @IsTest
    static void testRequestAccessToken_Failure() {
        Ramp_Credential__mdt mockCredential = new Ramp_Credential__mdt(
            Client_ID__c = 'test_client_id',
            Client_Secret__c = 'test_client_secret',
            Token_URL__c = 'https://api.ramp.com/oauth/token',
            Scopes__c = 'transactions:read',
            DeveloperName = 'Test_Credential'
        );

        Test.setMock(HttpCalloutMock.class, new RampAuthFailureMock());

        Test.startTest();
        try {
            RampAuthService.requestAccessToken(mockCredential);
            System.assert(false, 'Expected RampAuthException to be thrown');
        } catch (RampAuthService.RampAuthException e) {
            System.assert(
                e.getMessage().contains('OAuth request failed'),
                'Expected OAuth failure message'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void testTokenResponse_ExpirationDateTime() {
        RampTokenResponse response = new RampTokenResponse();
        response.expires_in = 3600; // 1 hour

        DateTime expirationTime = response.getExpirationDateTime();
        System.assertNotEquals(null, expirationTime, 'Expiration time should not be null');
        System.assert(
            expirationTime > DateTime.now(),
            'Expiration time should be in the future'
        );
    }

    @IsTest
    static void testTokenResponse_IsValid() {
        RampTokenResponse validResponse = new RampTokenResponse();
        validResponse.access_token = 'test_token';
        System.assert(validResponse.isValid(), 'Token with access_token should be valid');

        RampTokenResponse invalidResponse = new RampTokenResponse();
        System.assert(!invalidResponse.isValid(), 'Token without access_token should be invalid');
    }

    /**
     * @description Mock class for successful OAuth response
     */
    private class RampAuthSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            Map<String, Object> responseBody = new Map<String, Object>{
                'access_token' => 'test_access_token',
                'token_type' => 'Bearer',
                'expires_in' => 864000,
                'scope' => 'transactions:read'
            };

            res.setBody(JSON.serialize(responseBody));
            return res;
        }
    }

    /**
     * @description Mock class for failed OAuth response
     */
    private class RampAuthFailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"error": "invalid_client"}');
            return res;
        }
    }
}