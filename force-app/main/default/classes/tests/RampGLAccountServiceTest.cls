/**
 * @description Test class for RampGLAccountService
 */
@IsTest
private class RampGLAccountServiceTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    // Captures the POST body from RampGLAccountCaptureMock (Apex forbids static members on inner classes).
    static String capturedPostBody;

    @TestSetup
    static void setup() {
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

            System.assert(result.contains('GL Account sync complete'), 'Should return success message: ' + result);
            System.assert(result.contains('created ' + expectedCount),
                         'Should report ' + expectedCount + ' GL Accounts created: ' + result);

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
    static void testSyncAllGLAccounts_RestoreFromExisting() {
        // Simulates the post-tenant-switch / post-clear scenario: Ramp already
        // holds GLs (POSTed in a prior session) but local Ramp_Id__c values are
        // null. syncAllGLAccounts should re-stamp them without POSTing.
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> activeGLs = [
                SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
            ];
            System.assert(activeGLs.size() > 0, 'Need at least one active GL');
            for (AcctSeed__GL_Account__c gl : activeGLs) gl.Ramp_Id__c = null;
            update activeGLs;

            // Mock: GET returns every active GL as if it's already on Ramp; POST should NEVER be called.
            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockAllExist(activeGLs));

            Test.startTest();
            String result = RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            System.assert(result.contains('restored Ramp_Id__c'), 'Should report restoration: ' + result);
            System.assert(!result.contains('created '), 'Should NOT report any creates: ' + result);

            // Every local GL should now have Ramp_Id__c populated.
            Integer stillNull = [
                SELECT COUNT() FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true AND Ramp_Id__c = null
            ];
            System.assertEquals(0, stillNull, 'All GLs should be re-stamped');
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
            Map<String, String> rampIds = RampGLAccountService.syncGLAccountBatch(glAccounts);
            Test.stopTest();

            System.assert(!rampIds.isEmpty(), 'Should return non-empty ramp ID map');
            for (AcctSeed__GL_Account__c gl : glAccounts) {
                System.assert(rampIds.containsKey(gl.Id), 'Ramp ID map should contain SF Id: ' + gl.Id);
            }
        }
    }

    /**
     * @description Mock for successful GL Account sync. Handles three call types:
     * - OAuth token request
     * - GET /accounting/accounts (the existence-check Ramp does before POSTing) — returns empty
     * - POST /accounting/accounts — echoes back with ramp_id stamped
     */
    private class RampGLAccountMockSuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/accounts')) {
                // Pretend Ramp has nothing yet so the whole local list goes through the create path.
                res.setStatusCode(200);
                res.setBody('{"data":[],"page":{"next":null}}');
                return res;
            }

            // POST /accounting/accounts — echo back with ramp_id stamped on each.
            res.setStatusCode(200);
            if (req.getBody() != null && req.getBody().contains('gl_accounts')) {
                Map<String, Object> requestMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                List<Object> requestAccounts = (List<Object>) requestMap.get('gl_accounts');
                List<Map<String, Object>> responseAccounts = new List<Map<String, Object>>();
                for (Object obj : requestAccounts) {
                    Map<String, Object> account = (Map<String, Object>) obj;
                    responseAccounts.add(new Map<String, Object>{
                        'id' => account.get('id'),
                        'ramp_id' => 'ramp_' + account.get('id'),
                        'name' => account.get('name'),
                        'code' => account.get('code'),
                        'classification' => account.get('classification')
                    });
                }
                res.setBody(JSON.serialize(new Map<String, Object>{ 'gl_accounts' => responseAccounts }));
            } else {
                res.setBody('{"success": true}');
            }
            return res;
        }
    }

    /**
     * @description Mock for the restore path: GET returns the local SF Ids as
     * if they were already POSTed in a prior session. Throws on any POST.
     */
    private class RampGLAccountMockAllExist implements HttpCalloutMock {
        private List<AcctSeed__GL_Account__c> gls;
        public RampGLAccountMockAllExist(List<AcctSeed__GL_Account__c> gls) { this.gls = gls; }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/accounts')) {
                List<Map<String, Object>> data = new List<Map<String, Object>>();
                for (AcctSeed__GL_Account__c gl : gls) {
                    data.add(new Map<String, Object>{
                        'id' => gl.Id,
                        'ramp_id' => 'ramp_uuid_' + gl.Id,
                        'is_active' => true,
                        'name' => 'mock'
                    });
                }
                Map<String, Object> body = new Map<String, Object>{
                    'data' => data,
                    'page' => new Map<String, Object>{ 'next' => null }
                };
                res.setStatusCode(200);
                res.setBody(JSON.serialize(body));
                return res;
            }
            // POST is unexpected on the restore path.
            res.setStatusCode(500);
            res.setBody('{"error": "POST should not have been called when all GLs already exist"}');
            return res;
        }
    }

    @IsTest
    static void testGetUnsyncedGLAccounts_SomeUnsynced() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> activeGLs = [
                SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true
            ];
            System.assert(activeGLs.size() > 0, 'TestDataFactory should create active GL Accounts');

            activeGLs[0].Ramp_Id__c = 'ramp_test_id';
            update activeGLs[0];

            Test.startTest();
            List<AcctSeed__GL_Account__c> result = RampGLAccountService.getUnsyncedGLAccounts();
            Test.stopTest();

            System.assertEquals(activeGLs.size() - 1, result.size(),
                'Should exclude the one synced GL Account');
        }
    }

    @IsTest
    static void testGetUnsyncedGLAccounts_AllSynced() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> activeGLs = [
                SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true
            ];
            for (AcctSeed__GL_Account__c gl : activeGLs) {
                gl.Ramp_Id__c = 'ramp_' + gl.Id;
            }
            update activeGLs;

            Test.startTest();
            List<AcctSeed__GL_Account__c> result = RampGLAccountService.getUnsyncedGLAccounts();
            Test.stopTest();

            System.assert(result.isEmpty(), 'Should return empty list when all GL Accounts are synced');
        }
    }

    @IsTest
    static void testSyncAllGLAccounts_InactiveOnRampNotDuplicated() {
        // Verifies that inactive accounts already on Ramp are treated as synced
        // (re-stamped locally) and are NOT re-POSTed, which would cause a 400.
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> activeGLs = [
                SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
            ];
            System.assert(activeGLs.size() > 0, 'Need at least one active GL');
            for (AcctSeed__GL_Account__c gl : activeGLs) gl.Ramp_Id__c = null;
            update activeGLs;

            // Mock: GET returns all GLs as inactive entries on Ramp; POST must never be called.
            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockAllExistInactive(activeGLs));

            Test.startTest();
            String result = RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            System.assert(result.contains('restored Ramp_Id__c'), 'Should report restoration: ' + result);
            System.assert(!result.contains('created '), 'Should NOT create when inactive entries already exist: ' + result);

            Integer stillNull = [
                SELECT COUNT() FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true AND Ramp_Id__c = null
            ];
            System.assertEquals(0, stillNull, 'All GLs should be restamped from inactive Ramp entries');
        }
    }

    @IsTest
    static void testSyncAllGLAccounts_CodeIsId() {
        // Verifies that the `code` field sent to Ramp is the 18-char SF ID, not the GL Account Name.
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            capturedPostBody = null;
            Test.setMock(HttpCalloutMock.class, new RampGLAccountCaptureMock());

            Test.startTest();
            RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            String capturedBody = capturedPostBody;
            System.assert(String.isNotBlank(capturedBody), 'POST body should have been captured');

            Map<String, Object> reqMap = (Map<String, Object>) JSON.deserializeUntyped(capturedBody);
            List<Object> sent = (List<Object>) reqMap.get('gl_accounts');
            System.assert(sent != null && !sent.isEmpty(), 'gl_accounts should be in POST body');

            for (Object o : sent) {
                Map<String, Object> acct = (Map<String, Object>) o;
                String sfId = (String) acct.get('id');
                String code = (String) acct.get('code');
                System.assertEquals(sfId, code, 'code should equal SF Id, not name: id=' + sfId + ' code=' + code);
            }
        }
    }

    @IsTest
    static void testSyncGLAccountBatch_ParseFailurePropagates() {
        // Verifies that a malformed POST response causes parseRampIds to surface a
        // RampGLAccountException (wrapping the JSON parse error).
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            List<AcctSeed__GL_Account__c> glAccounts = [
                SELECT Id, Name, AcctSeed__Type__c, AcctSeed__Active__c, Ramp_Id__c
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
                LIMIT 1
            ];

            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockMalformedResponse());

            Test.startTest();
            try {
                RampGLAccountService.syncGLAccountBatch(glAccounts);
                System.assert(false, 'Expected RampGLAccountException');
            } catch (RampGLAccountService.RampGLAccountException e) {
                System.assert(e.getMessage().contains('Error in batch sync'), 'Exception message: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }

    /**
     * @description Mock that fails the POST. The pre-flight GET still returns
     * empty so we reach the POST step where the failure occurs.
     */
    private class RampGLAccountMockError implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/accounts')) {
                res.setStatusCode(200);
                res.setBody('{"data":[],"page":{"next":null}}');
                return res;
            }
            // POST → 500
            res.setStatusCode(500);
            res.setBody('{"error": "Internal Server Error"}');
            return res;
        }
    }

    /**
     * @description Mock for the inactive-entry path: GET returns every local GL as
     * an inactive Ramp account (is_active: false). Any POST returns 500 — it
     * should never be called when all accounts are already represented on Ramp.
     */
    private class RampGLAccountMockAllExistInactive implements HttpCalloutMock {
        private List<AcctSeed__GL_Account__c> gls;
        public RampGLAccountMockAllExistInactive(List<AcctSeed__GL_Account__c> gls) { this.gls = gls; }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/accounts')) {
                List<Map<String, Object>> data = new List<Map<String, Object>>();
                for (AcctSeed__GL_Account__c gl : gls) {
                    data.add(new Map<String, Object>{
                        'id' => gl.Id,
                        'ramp_id' => 'ramp_uuid_inactive_' + gl.Id,
                        'is_active' => false,
                        'name' => 'mock'
                    });
                }
                Map<String, Object> body = new Map<String, Object>{
                    'data' => data,
                    'page' => new Map<String, Object>{ 'next' => null }
                };
                res.setStatusCode(200);
                res.setBody(JSON.serialize(body));
                return res;
            }
            // POST should never be called when all entries are already on Ramp.
            res.setStatusCode(500);
            res.setBody('{"error": "POST should not have been called for inactive Ramp entries"}');
            return res;
        }
    }

    /**
     * @description Recording mock that captures the last POST body so tests can
     * inspect the exact payload sent to Ramp. GET returns empty so all local GLs
     * flow through the create path.
     */
    private class RampGLAccountCaptureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/accounts')) {
                res.setStatusCode(200);
                res.setBody('{"data":[],"page":{"next":null}}');
                return res;
            }

            // POST — capture the body, then echo back with ramp_ids so the service can write back.
            capturedPostBody = req.getBody();
            res.setStatusCode(200);
            Map<String, Object> requestMap = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            List<Object> requestAccounts = (List<Object>) requestMap.get('gl_accounts');
            List<Map<String, Object>> responseAccounts = new List<Map<String, Object>>();
            for (Object obj : requestAccounts) {
                Map<String, Object> account = (Map<String, Object>) obj;
                responseAccounts.add(new Map<String, Object>{
                    'id' => account.get('id'),
                    'ramp_id' => 'ramp_' + account.get('id')
                });
            }
            res.setBody(JSON.serialize(new Map<String, Object>{ 'gl_accounts' => responseAccounts }));
            return res;
        }
    }

    /**
     * @description Mock that returns malformed JSON on POST to trigger a parse
     * failure inside parseRampIds, which should be re-thrown as
     * RampGLAccountException with the "Error in batch sync" prefix.
     */
    private class RampGLAccountMockMalformedResponse implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
                return res;
            }
            // POST returns invalid JSON to trigger parseRampIds failure.
            res.setStatusCode(200);
            res.setBody('not valid json {{{');
            return res;
        }
    }
}