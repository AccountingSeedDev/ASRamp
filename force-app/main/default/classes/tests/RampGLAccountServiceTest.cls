/**
 * @description Test class for RampGLAccountService
 */
@IsTest
private class RampGLAccountServiceTest {

    @TestSetup
    public static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    @IsTest
    static void testSyncAllGLAccounts_Success() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            // Get the count of active GL Accounts created by TestDataFactory
            List<AcctSeed__GL_Account__c> activeGLAccounts = [
                SELECT Id
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
            ];
            Integer expectedCount = activeGLAccounts.size();

            System.assert(expectedCount > 0, 'TestDataFactory should create GL Accounts');

            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockSuccess());

            Test.startTest();
            String result = RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            System.assert(result.contains('Successfully synced'), 'Should return success message');
            System.assert(result.contains(String.valueOf(expectedCount)),
                         'Should sync ' + expectedCount + ' GL Accounts');

            // Verify Ramp IDs were updated
            List<AcctSeed__GL_Account__c> glAccounts = [
                SELECT Id, Ramp_Id__c
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
            ];

            Integer syncedCount = 0;
            for (AcctSeed__GL_Account__c gl : glAccounts) {
                if (String.isNotBlank(gl.Ramp_Id__c)) {
                    syncedCount++;
                }
            }

            System.assertEquals(expectedCount, syncedCount,
                               'All ' + expectedCount + ' GL Accounts should have Ramp IDs');
        }
    }

    @IsTest
    static void testSyncAllGLAccounts_NoActiveAccounts() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            // Deactivate all GL Accounts
            List<AcctSeed__GL_Account__c> glAccounts = [
                SELECT Id, AcctSeed__Active__c
                FROM AcctSeed__GL_Account__c
            ];

            for (AcctSeed__GL_Account__c gl : glAccounts) {
                gl.AcctSeed__Active__c = false;
            }
            update glAccounts;

            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockSuccess());

            Test.startTest();
            String result = RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            System.assert(result.contains('No active GL Accounts'), 'Should return no accounts message');
        }
    }

    @IsTest
    static void testSyncAllGLAccounts_APIError() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockError());

            Test.startTest();
            try {
                RampGLAccountService.syncAllGLAccounts();
                System.assert(false, 'Expected exception to be thrown');
            } catch (RampGLAccountService.RampGLAccountException e) {
                System.assert(
                    e.getMessage().contains('Error syncing GL Accounts'),
                    'Should throw RampGLAccountException'
                );
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGetSyncStatistics() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            // Get all active GL Accounts
            List<AcctSeed__GL_Account__c> allGLAccounts = [
                SELECT Id, Ramp_Id__c
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
            ];

            Integer totalCount = allGLAccounts.size();
            Integer syncCount = Math.min(totalCount / 2, 5); // Sync up to 5 accounts or half

            // Update some GL Accounts with Ramp IDs
            List<AcctSeed__GL_Account__c> glAccountsToSync = new List<AcctSeed__GL_Account__c>();
            for (Integer i = 0; i < syncCount; i++) {
                allGLAccounts[i].Ramp_Id__c = 'ramp_' + allGLAccounts[i].Id;
                glAccountsToSync.add(allGLAccounts[i]);
            }
            update glAccountsToSync;

            Test.startTest();
            Map<String, Integer> stats = RampGLAccountService.getSyncStatistics();
            Test.stopTest();

            System.assertEquals(totalCount, stats.get('total'),
                               'Should have ' + totalCount + ' total GL Accounts');
            System.assertEquals(syncCount, stats.get('synced'),
                               'Should have ' + syncCount + ' synced GL Accounts');
            System.assertEquals(totalCount - syncCount, stats.get('not_synced'),
                               'Should have ' + (totalCount - syncCount) + ' pending GL Accounts');
        }
    }

    @IsTest
    static void testSyncGLAccountBatch_Success() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> glAccounts = [
                SELECT Id, Name, AcctSeed__Type__c, AcctSeed__Active__c, Ramp_Id__c
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
                LIMIT 5
            ];

            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockSuccess());

            Test.startTest();
            RampGLAccountService.syncGLAccountBatch(glAccounts);
            Test.stopTest();

            // Verify the method completed without exceptions
            System.assert(glAccounts.size() > 0, 'Should have processed GL Accounts');
        }
    }

    /**
     * @description Mock class for successful GL Account sync response
     * Handles both token request and API request
     */
    private class RampGLAccountMockSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is for token
            if (callCount == 1 || req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            // Subsequent calls are for GL Account API
            res.setStatusCode(200);

            // Check if this is a GL Account sync request
            if (req.getBody() != null && req.getBody().contains('gl_accounts')) {
                // Parse the request body to get the GL Accounts
                Map<String, Object> requestMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                List<Object> requestAccounts = (List<Object>) requestMap.get('gl_accounts');

                // Build response with Ramp IDs
                List<Map<String, Object>> responseAccounts = new List<Map<String, Object>>();

                for (Object obj : requestAccounts) {
                    Map<String, Object> account = (Map<String, Object>) obj;
                    Map<String, Object> responseAccount = new Map<String, Object>();
                    responseAccount.put('id', account.get('id'));
                    responseAccount.put('ramp_id', 'ramp_' + account.get('id'));
                    responseAccount.put('name', account.get('name'));
                    responseAccount.put('code', account.get('code'));
                    responseAccount.put('classification', account.get('classification'));
                    responseAccounts.add(responseAccount);
                }

                Map<String, Object> responseBody = new Map<String, Object>{
                    'gl_accounts' => responseAccounts
                };
                res.setBody(JSON.serialize(responseBody));
            } else {
                res.setBody('{"success": true}');
            }

            return res;
        }
    }

    /**
     * @description Mock class for API error response
     * Handles token request first, then returns error for API call
     */
    private class RampGLAccountMockError implements HttpCalloutMock {
        private Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            // First call is for token
            if (callCount == 1 || req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            // Subsequent calls return error
            res.setStatusCode(500);
            res.setBody('{"error": "Internal Server Error"}');
            return res;
        }
    }
}