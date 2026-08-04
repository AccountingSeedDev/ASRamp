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
    static void testGetActiveCredential_MultipleActiveThrows() {
        RampAuthService.overrideCredentialQuery = new List<Ramp_Credential__mdt>{
            RampAuthService.buildTestCredential(),
            RampAuthService.buildTestCredential()
        };
        Test.startTest();
        try {
            RampAuthService.getActiveCredential();
            System.assert(false, 'Expected RampAuthException for multiple active credentials');
        } catch (RampAuthService.RampAuthException e) {
            System.assert(e.getMessage().contains('Multiple active Ramp credentials'),
                'Expected multiple-active error, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetActiveCredential_EmptyQueryThrows() {
        RampAuthService.overrideCredentialQuery = new List<Ramp_Credential__mdt>();
        Test.startTest();
        try {
            RampAuthService.getActiveCredential();
            System.assert(false, 'Expected RampAuthException when no active credential');
        } catch (RampAuthService.RampAuthException e) {
            System.assert(e.getMessage().contains('No active Ramp credential found'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testCacheKey_KeyedOnClientIdNotRecordName() {
        Ramp_Credential__mdt a = RampAuthService.buildTestCredential();
        Ramp_Credential__mdt b = RampAuthService.buildTestCredential();
        b.Client_ID__c = 'a_different_business_client_id';
        // Same DeveloperName, different client ids -> different cache keys, so a
        // credential swap can never serve a token minted for another business.
        System.assertNotEquals(RampAuthService.cacheKeyFor(a), RampAuthService.cacheKeyFor(b),
            'Cache key must change when the client id changes');
        System.assertEquals(RampAuthService.cacheKeyFor(a), RampAuthService.cacheKeyFor(a),
            'Cache key must be stable for the same client id');
        System.assert(RampAuthService.cacheKeyFor(a).isAlphanumeric(),
            'Platform cache keys must be alphanumeric');
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
    static void testRequestAccessToken_RetriesOnTransient5xx() {
        Ramp_Credential__mdt mockCredential = new Ramp_Credential__mdt(
            Client_ID__c = 'test_client_id',
            Client_Secret__c = 'test_client_secret',
            Token_URL__c = 'https://api.ramp.com/oauth/token',
            Scopes__c = 'transactions:read',
            DeveloperName = 'Test_Credential'
        );

        // First call 502s (transient gateway error), retry succeeds.
        Test.setMock(HttpCalloutMock.class, new RampAuth5xxThenSuccessMock());

        Test.startTest();
        RampTokenResponse response = RampAuthService.requestAccessToken(mockCredential);
        Test.stopTest();

        System.assert(response.isValid(), 'Should recover on retry after a transient 502');
        System.assertEquals('recovered_token', response.access_token,
            'Should return the token from the successful retry');
    }

    @IsTest
    static void testRequestAccessToken_5xxErrorIsCleanNoHtml() {
        Ramp_Credential__mdt mockCredential = new Ramp_Credential__mdt(
            Client_ID__c = 'test_client_id',
            Client_Secret__c = 'test_client_secret',
            Token_URL__c = 'https://api.ramp.com/oauth/token',
            Scopes__c = 'transactions:read',
            DeveloperName = 'Test_Credential'
        );

        // Persistent 502 with an HTML body — must not leak raw HTML into the error.
        Test.setMock(HttpCalloutMock.class, new RampAuth5xxHtmlMock());

        Test.startTest();
        try {
            RampAuthService.requestAccessToken(mockCredential);
            System.assert(false, 'Expected RampAuthException to be thrown');
        } catch (RampAuthService.RampAuthException e) {
            System.assert(!e.getMessage().contains('<'),
                'Error must not contain raw HTML: ' + e.getMessage());
            System.assert(e.getMessage().contains('502'), 'Should mention the status code');
            System.assert(e.getMessage().contains('temporarily unavailable'),
                'Should give a readable reason: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testDescribeAuthFailure_JsonErrorDescription() {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(400);
        res.setBody('{"error":"invalid_scope","error_description":"requested scope not allowed"}');
        System.assertEquals('requested scope not allowed',
            RampAuthService.describeAuthFailure(res), 'Should surface error_description');
    }

    @IsTest
    static void testDescribeAuthFailure_4xxHtmlBodyNotLeaked() {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(400);
        res.setBody('<html><body>nope</body></html>');
        String detail = RampAuthService.describeAuthFailure(res);
        System.assert(!detail.contains('<'), 'No raw HTML: ' + detail);
        System.assert(detail.contains('400'), 'Mentions status code: ' + detail);
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

    @IsTest
    static void testGetAccessToken_TransactionCachePreventsDuplicateCallout() {
        // Arrange: inject credential so the callout path is exercised.
        RampAuthService.overrideCredential = RampAuthService.buildTestCredential();
        // Ensure no stale transaction token from a previous test.
        RampAuthService.transactionToken = null;

        // The mock counts how many times it is called.
        RampAuthCallCountMock countMock = new RampAuthCallCountMock();
        Test.setMock(HttpCalloutMock.class, countMock);

        Test.startTest();
        String firstToken  = RampAuthService.getAccessToken();
        String secondToken = RampAuthService.getAccessToken();
        String thirdToken  = RampAuthService.getAccessToken();
        Test.stopTest();

        System.assertEquals(1, countMock.callCount,
            'Only one HTTP callout should occur; subsequent calls must use transactionToken');
        System.assertEquals(firstToken, secondToken, 'All calls must return the same token');
        System.assertEquals(firstToken, thirdToken,  'All calls must return the same token');
        System.assertEquals('transaction_cached_token', firstToken, 'Token value should match mock');
    }

    @IsTest
    static void testClearTransactionToken_AllowsFreshFetch() {
        RampAuthService.overrideCredential = RampAuthService.buildTestCredential();
        RampAuthService.transactionToken = null;

        RampAuthCallCountMock countMock = new RampAuthCallCountMock();
        Test.setMock(HttpCalloutMock.class, countMock);

        Test.startTest();
        RampAuthService.getAccessToken(); // populates transactionToken (1 callout)
        RampAuthService.clearTransactionToken();
        RampAuthService.getAccessToken(); // transactionToken cleared — should callout again (2nd callout)
        Test.stopTest();

        System.assertEquals(2, countMock.callCount,
            'Clearing the transaction token should force a new callout on the next getAccessToken()');
    }

    @IsTest
    static void testClearCachedToken_AlsoClearsTransactionToken() {
        RampAuthService.overrideCredential = RampAuthService.buildTestCredential();
        // Seed a non-blank transaction token directly via the @TestVisible field.
        RampAuthService.transactionToken = 'seeded_token';

        Test.startTest();
        RampAuthService.clearCachedToken();
        Test.stopTest();

        System.assertEquals(null, RampAuthService.transactionToken,
            'clearCachedToken() must also null out transactionToken');
    }

    @IsTest
    static void testGetAccessToken_TransactionTokenPreemptsCacheCallout() {
        RampAuthService.overrideCredential = RampAuthService.buildTestCredential();
        // Pre-populate the transaction token to simulate a second batch-execute chunk.
        RampAuthService.transactionToken = 'preloaded_token';

        // If getAccessToken() ignores transactionToken it would attempt a callout;
        // Salesforce would throw "callout not allowed after DML" — but more
        // importantly it would be a wasted callout. Using a CountMock ensures zero
        // callouts are made.
        RampAuthCallCountMock countMock = new RampAuthCallCountMock();
        Test.setMock(HttpCalloutMock.class, countMock);

        Test.startTest();
        String token = RampAuthService.getAccessToken();
        Test.stopTest();

        System.assertEquals(0, countMock.callCount,
            'No callout should occur when transactionToken is already set');
        System.assertEquals('preloaded_token', token,
            'Should return the cached transaction token');
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

    /**
     * @description Returns a transient 502 (HTML body) on the first call, then a
     * valid token — exercises the retry-once-on-5xx path.
     */
    private class RampAuth5xxThenSuccessMock implements HttpCalloutMock {
        private Integer calls = 0;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            calls++;
            if (calls == 1) {
                res.setStatusCode(502);
                res.setHeader('Content-Type', 'text/html');
                res.setBody('<!DOCTYPE html><html><title>502 Bad Gateway</title></html>');
            } else {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'application/json');
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'access_token' => 'recovered_token',
                    'token_type' => 'Bearer',
                    'expires_in' => 864000
                }));
            }
            return res;
        }
    }

    /**
     * @description Always returns a 502 with an HTML gateway page — verifies the
     * raw HTML never reaches the error message.
     */
    private class RampAuth5xxHtmlMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(502);
            res.setHeader('Content-Type', 'text/html');
            res.setBody('<!DOCTYPE html><html lang=en><title>| 502: Bad gateway</title><body>Bad gateway</body></html>');
            return res;
        }
    }

    /**
     * @description Counts how many times it is invoked and always returns a valid
     * token response.  Used to assert the number of HTTP callouts made during a test.
     */
    private class RampAuthCallCountMock implements HttpCalloutMock {
        public Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'access_token' => 'transaction_cached_token',
                'token_type'   => 'Bearer',
                'expires_in'   => 864000
            }));
            return res;
        }
    }
}
