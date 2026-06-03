/**
 * @description Test class for RampConfigurationController
 */
@IsTest
private class RampConfigurationControllerTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    @IsTest
    static void testGetActiveCredential_WithCredential() {
        // The config screen reads the raw CMDT record directly (not via the
        // RampAuthService seam). Credentials are deployed per-environment, so a
        // clean org has none — assert against whichever state this org is in.
        Boolean hasCredential = ![
            SELECT Id FROM Ramp_Credential__mdt WHERE Is_Active__c = true LIMIT 1
        ].isEmpty();

        Test.startTest();
        RampConfigurationController.CredentialWrapper result =
            RampConfigurationController.getActiveCredential();
        Test.stopTest();

        if (hasCredential) {
            System.assertNotEquals(null, result, 'Should return the active credential');
            System.assertNotEquals(null, result.developerName, 'Developer name should not be null');
        } else {
            System.assertEquals(null, result, 'Returns null when no active credential exists');
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
        Map<String, Object> credential = new Map<String, Object>{
            'developerName' => 'Test',
            'label' => 'Test Credential',
            'clientId' => 'test_client_id',
            'clientSecret' => 'test_secret',
            'tokenUrl' => 'https://api.ramp.com/oauth/token',
            'apiBaseUrl' => 'https://api.ramp.com',
            'scopes' => 'transactions:read',
            'isActive' => true
        };

        Test.startTest();
        String result = RampConfigurationController.saveCredential(credential);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.toLowerCase().contains('credential'), 'Should report on the credential save: ' + result);
    }

    @IsTest
    static void testSaveCredential_MissingClientId() {
        Map<String, Object> credential = new Map<String, Object>{
            'developerName' => 'Test',
            'clientSecret' => 'test_secret'
        };

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // AuraHandledException may not preserve message in tests
            // Just verify an exception was thrown for validation
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception when Client ID is missing');
    }

    @IsTest
    static void testSaveCredential_MissingClientSecret() {
        Map<String, Object> credential = new Map<String, Object>{
            'developerName' => 'Test',
            'clientId' => 'test_client_id'
        };

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // AuraHandledException may not preserve message in tests
            // Just verify an exception was thrown for validation
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception when Client Secret is missing');
    }

    @IsTest
    static void testSaveCredential_MissingDeveloperName() {
        Map<String, Object> credential = new Map<String, Object>{
            'clientId' => 'test_client_id',
            'clientSecret' => 'test_secret'
        };

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RampConfigurationController.saveCredential(credential);
        } catch (Exception e) {
            exceptionThrown = true;
            // AuraHandledException may not preserve message in tests
            // Just verify an exception was thrown for validation
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw validation exception when Developer Name is missing');
    }

    @IsTest
    static void testCreateAccountingFields_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldsMock());

        Test.startTest();
        String result = RampConfigurationController.createAccountingFields();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('GL Account Variable'), 'Should contain field names');
    }

    @IsTest
    static void testSyncAccountingVariables_Success() {
        // Create test accounting variables
        insert new AcctSeed__Accounting_Variable__c(
            Name = 'Test Variable',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = true
        );

        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldsMock());

        Test.startTest();
        String result = RampConfigurationController.syncAccountingVariables();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('Sync job started'), 'Should indicate batch job started');
    }

    @IsTest
    static void testGetRampCustomFields_Success() {
        Test.setMock(HttpCalloutMock.class, new RampCustomFieldsMock());

        Test.startTest();
        List<Map<String, Object>> result = RampConfigurationController.getRampCustomFields();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void testHasAccountingConnection_Success() {
        Test.setMock(HttpCalloutMock.class, new RampAccountingConnectionMock());

        Test.startTest();
        Boolean result = RampConfigurationController.hasAccountingConnection();
        Test.stopTest();

        System.assertEquals(true, result, 'Should return true when connection exists');
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

    /**
     * @description Mock for accounting fields operations
     */
    private class RampAccountingFieldsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else if (req.getEndpoint().contains('/accounting/connection')) {
                res.setStatusCode(200);
                res.setBody('{"id":"connection-123","remote_provider_name":"ACCOUNTING_SEED"}');
            } else if (req.getEndpoint().contains('/accounting/fields')) {
                if (req.getMethod() == 'POST') {
                    res.setStatusCode(201);
                    res.setBody('{"id":"field-123","name":"GL Account Variable 1","ramp_id":"ramp-field-123"}');
                } else {
                    res.setStatusCode(200);
                    res.setBody('{"data":[{"name":"GL Account Variable 1","ramp_id":"ramp-field-123","is_active":true}]}');
                }
            }

            return res;
        }
    }

    /**
     * @description Mock for custom fields retrieval
     */
    private class RampCustomFieldsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"data":[{"name":"Test Field","ramp_id":"ramp-123","is_active":true}]}');
            }

            return res;
        }
    }

    /**
     * @description Mock for accounting connection check
     */
    private class RampAccountingConnectionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"id":"connection-123","remote_provider_name":"ACCOUNTING_SEED"}');
            }

            return res;
        }
    }

    // --------------------------------------------------------------------
    //  Transaction sync
    // --------------------------------------------------------------------

    private static void configureSettingsForSyncTests() {
        // Override CMDT so tests don't depend on the deployed Default record's values.
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'TestLedger',
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.resetCache();
    }

    @IsTest
    static void syncTransactions_returnsJobId() {
        // No HTTP mock — the Queueable will try to make callouts when it runs,
        // but we stop the test before it executes by checking the return value
        // from System.enqueueJob right away.
        // Note: the Queueable still gets fired by Test.stopTest. Set a mock to
        // keep it from blowing up.
        TestDataFactory.getInstance().initialize();
        configureSettingsForSyncTests();
        Test.setMock(HttpCalloutMock.class, new EmptyPageMock());

        Test.startTest();
        String result = RampConfigurationController.syncTransactions();
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.contains('Transaction sync started'), 'Should return started message: ' + result);
        System.assert(result.contains('Job Id'), 'Should include job id: ' + result);
    }

    @IsTest
    static void getTransactionSyncStats_aggregatesByStatus() {
        TestDataFactory.getInstance().initialize();
        TestDataFactory.getInstance().disableAutoPost();
        User admin = TestDataFactory.getInstance().getAdminUser();

        // Seed three JEs with varied statuses (skip the JE-line balance constraint
        // by using a small inline DML approach — but JE inserts need at least
        // basic required fields)
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        AcctSeed__Accounting_Period__c period = [
            SELECT Id, AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open'
            ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1
        ];

        System.runAs(admin) {
            insert new List<AcctSeed__Journal_Entry__c>{
                new AcctSeed__Journal_Entry__c(
                    AcctSeed__Journal_Date__c = period.AcctSeed__Start_Date__c,
                    AcctSeed__Ledger__c = ledger.Id,
                    AcctSeed__Accounting_Period__c = period.Id,
                    AcctSeed__Status__c = 'In Process',
                    AcctSeed__ExtId__c = 'pending-1',
                    Ramp_Sync_Status__c = 'Pending'
                ),
                new AcctSeed__Journal_Entry__c(
                    AcctSeed__Journal_Date__c = period.AcctSeed__Start_Date__c,
                    AcctSeed__Ledger__c = ledger.Id,
                    AcctSeed__Accounting_Period__c = period.Id,
                    AcctSeed__Status__c = 'In Process',
                    AcctSeed__ExtId__c = 'synced-1',
                    Ramp_Sync_Status__c = 'Synced_To_Ramp'
                ),
                new AcctSeed__Journal_Entry__c(
                    AcctSeed__Journal_Date__c = period.AcctSeed__Start_Date__c,
                    AcctSeed__Ledger__c = ledger.Id,
                    AcctSeed__Accounting_Period__c = period.Id,
                    AcctSeed__Status__c = 'In Process',
                    AcctSeed__ExtId__c = 'failed-1',
                    Ramp_Sync_Status__c = 'Failed',
                    Ramp_Sync_Error__c = 'Test failure'
                )
            };
        }

        Test.startTest();
        Map<String, Integer> stats = RampConfigurationController.getTransactionSyncStats();
        Test.stopTest();

        System.assertEquals(1, stats.get('pending'));
        System.assertEquals(1, stats.get('synced'));
        System.assertEquals(1, stats.get('failed'));
        System.assertEquals(3, stats.get('total'));
    }

    @IsTest
    static void getRecentTransactionFailures_returnsFailedJEs() {
        TestDataFactory.getInstance().initialize();
        TestDataFactory.getInstance().disableAutoPost();
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        AcctSeed__Accounting_Period__c period = [
            SELECT Id, AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open'
            ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1
        ];

        System.runAs(admin) {
            insert new AcctSeed__Journal_Entry__c(
                AcctSeed__Journal_Date__c = period.AcctSeed__Start_Date__c,
                AcctSeed__Ledger__c = ledger.Id,
                AcctSeed__Accounting_Period__c = period.Id,
                AcctSeed__Status__c = 'In Process',
                AcctSeed__ExtId__c = 'failure-row',
                AcctSeed__Reference__c = 'Failure memo',
                Ramp_Sync_Status__c = 'Failed',
                Ramp_Sync_Error__c = 'Synthesized error'
            );
        }

        Test.startTest();
        List<Map<String, Object>> rows = RampConfigurationController.getRecentTransactionFailures();
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals('failure-row', (String) rows[0].get('rampTransactionId'));
        System.assertEquals('Synthesized error', (String) rows[0].get('error'));
    }

    /** Mock that always returns an empty page — used by syncTransactions_returnsJobId. */
    private class EmptyPageMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"transactions:read accounting:write"}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"data":[],"page":{"next":null}}');
            }
            return res;
        }
    }
}