/**
 * @description Test class for RampVendorSyncBatch
 */
@IsTest
private class RampVendorSyncBatchTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    @TestSetup
    static void setup() {
        // Builds the AcctSeedSysAdmin user and grants it Ramp_Admin (FLS on the
        // Ramp_* fields). Tests run the batch as this user so its SOQL/DML on
        // Ramp_Vendor_Id__c is permitted.
        TestDataFactory.getInstance().initialize();

        // Create test Accounts
        List<Account> accounts = new List<Account>();

        // Vendor without Ramp ID (will be created)
        accounts.add(new Account(
            Name = 'Test Vendor 1',
            AccountNumber = 'V001',
            AcctSeed__Accounting_Type__c = 'Vendor'
        ));

        // Customer and Vendor without Ramp ID (will be created)
        accounts.add(new Account(
            Name = 'Test Vendor 2',
            AccountNumber = 'V002',
            AcctSeed__Accounting_Type__c = 'Customer and Vendor'
        ));

        // Vendor with Ramp ID (will be updated)
        accounts.add(new Account(
            Name = 'Test Vendor 3',
            AccountNumber = 'V003',
            AcctSeed__Accounting_Type__c = 'Vendor',
            Ramp_Vendor_Id__c = 'existing-ramp-id-123'
        ));

        // Customer only (should be excluded)
        accounts.add(new Account(
            Name = 'Test Customer',
            AccountNumber = 'C001',
            AcctSeed__Accounting_Type__c = 'Customer'
        ));

        // Insert as the admin so the Ramp_Vendor_Id__c write is permitted.
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insert accounts;
        }
    }

    @IsTest
    static void testBatchExecution_Success() {
        Id jobId;
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new RampVendorMockSuccess());

            RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
            jobId = Database.executeBatch(batch, 10);

            Test.stopTest();
        }

        // Verify batch completed
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete successfully');
    }

    @IsTest
    static void testBatchExecution_NoConnectionId() {
        Id jobId;
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new RampVendorMockNoConnection());

            RampVendorSyncBatch batch = new RampVendorSyncBatch();
            jobId = Database.executeBatch(batch, 10);

            Test.stopTest();
        }

        // Batch should complete but with errors logged
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even without connection');
    }

    @IsTest
    static void testBatchExecution_RestoreFromExisting() {
        // Simulates post-tenant-switch / post-clear: Ramp already has every
        // vendor (keyed by SF Id) but local Ramp_Vendor_Id__c is null on the
        // create-bucket Accounts. Batch should re-stamp them without POSTing.
        Set<String> sfIds = new Set<String>();
        Id jobId;
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            List<Account> creatableVendors = [
                SELECT Id FROM Account
                WHERE AcctSeed__Accounting_Type__c IN ('Vendor', 'Customer and Vendor')
                  AND Ramp_Vendor_Id__c = null
            ];
            System.assert(creatableVendors.size() > 0, 'Setup expects at least one Account with null Ramp_Vendor_Id__c');

            for (Account a : creatableVendors) sfIds.add(a.Id);

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new RampVendorMockAllExist(sfIds));

            RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
            jobId = Database.executeBatch(batch, 10);

            Test.stopTest();

            AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
            System.assertEquals('Completed', job.Status, 'Batch should complete');

            // Every previously-null Account should now have Ramp_Vendor_Id__c populated.
            Integer stillNull = [
                SELECT COUNT() FROM Account
                WHERE Id IN :sfIds AND Ramp_Vendor_Id__c = null
            ];
            System.assertEquals(0, stillNull, 'All matched vendors should be re-stamped');
        }
    }

    @IsTest
    static void testBatchExecution_ApiError() {
        Id jobId;
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new RampVendorMockError());

            RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
            jobId = Database.executeBatch(batch, 10);

            Test.stopTest();
        }

        // Batch should complete but with errors
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even with API errors');
    }

    @IsTest
    static void testBatchExecution_RestoreAndUpdateInSameBatch() {
        // Issue #1: Verifies that having a Restore record AND Update records in the
        // same batch chunk does NOT cause the "uncommitted work pending" callout error.
        // The batch must process callouts (PATCH for updates) before DML (restore stamp).
        Set<String> sfIds = new Set<String>();
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            List<Account> creatableVendors = [
                SELECT Id FROM Account
                WHERE AcctSeed__Accounting_Type__c IN ('Vendor', 'Customer and Vendor')
                  AND Ramp_Vendor_Id__c = null
            ];
            System.assert(creatableVendors.size() > 0, 'Setup expects accounts without Ramp ID');
            for (Account a : creatableVendors) sfIds.add(a.Id);

            Test.startTest();
            // Mock: GET returns the creatable vendors as existing (triggers restore path),
            //       PATCH succeeds (for the pre-stamped vendor).
            Test.setMock(HttpCalloutMock.class, new RampVendorMockRestoreAndUpdate(sfIds));
            RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
            Id jobId = Database.executeBatch(batch, 200); // large chunk = all in one execute()
            Test.stopTest();

            AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
            System.assertEquals('Completed', job.Status, 'Batch should complete');

            // The formerly-null vendors should be re-stamped (restore path succeeded).
            Integer stillNull = [SELECT COUNT() FROM Account WHERE Id IN :sfIds AND Ramp_Vendor_Id__c = null];
            System.assertEquals(0, stillNull, 'Restored vendors should be stamped');
        }
    }

    @IsTest
    static void testExtractErrorDetail_Html404() {
        HTTPResponse res = new HTTPResponse();
        res.setStatusCode(404);
        res.setBody('<!doctype html><html><title>404 Not Found</title></html>');
        String detail = RampVendorSyncBatch.extractErrorDetail(res);
        System.assert(detail.contains('404'), 'Should mention 404');
        System.assert(!detail.contains('<'), 'Should not contain HTML tags');
    }

    @IsTest
    static void testExtractErrorDetail_HtmlNon404() {
        HTTPResponse res = new HTTPResponse();
        res.setStatusCode(500);
        res.setBody('<html><body>Internal Server Error</body></html>');
        String detail = RampVendorSyncBatch.extractErrorDetail(res);
        System.assert(!detail.contains('<'), 'Should not contain HTML tags');
        System.assert(detail.contains('500'), 'Should mention status code');
    }

    @IsTest
    static void testExtractErrorDetail_JsonError() {
        HTTPResponse res = new HTTPResponse();
        res.setStatusCode(400);
        res.setBody('{"error":"invalid_request","message":"Missing required field"}');
        String detail = RampVendorSyncBatch.extractErrorDetail(res);
        System.assertEquals('invalid_request', detail, 'Should extract error field from JSON');
    }

    /**
     * Mock HTTP callout for successful responses
     */
    private class RampVendorMockSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else if (req.getMethod() == 'PATCH') {
                res.setStatusCode(200);
                res.setBody('{"ramp_id": "updated-vendor-id", "name": "Updated Vendor"}');
            } else if (req.getMethod() == 'POST') {
                res.setStatusCode(201);
                res.setBody('{"data": [{"id": "001xx000001234AAA", "ramp_id": "new-ramp-id-1", "name": "Test"}]}');
            } else if (req.getMethod() == 'GET') {
                res.setStatusCode(200);
                res.setBody('{"data": [{"id": "001xx000001234AAA", "ramp_id": "new-ramp-id-1", "name": "Test"}], "page": {"next": null}}');
            }

            return res;
        }
    }

    /**
     * Mock for no accounting connection
     */
    private class RampVendorMockNoConnection implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else {
                res.setStatusCode(404);
                res.setBody('{"error": "Not found"}');
            }

            return res;
        }
    }

    /**
     * @description Mock for the restore path: GET /accounting/vendors returns
     * every Account we pass in as if it's already on Ramp's side. Throws on
     * any POST/PATCH so a regression that POSTs duplicates would fail loudly.
     */
    private class RampVendorMockAllExist implements HttpCalloutMock {
        private Set<String> sfIds;
        public RampVendorMockAllExist(Set<String> sfIds) { this.sfIds = sfIds; }

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
                return res;
            }
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/vendors')) {
                List<Map<String, Object>> data = new List<Map<String, Object>>();
                for (String sfId : sfIds) {
                    data.add(new Map<String, Object>{
                        'id' => sfId,
                        'ramp_id' => 'ramp_vendor_' + sfId,
                        'is_active' => true,
                        'name' => 'mock'
                    });
                }
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => data,
                    'page' => new Map<String, Object>{ 'next' => null }
                }));
                return res;
            }
            // PATCH on the toUpdate set (one record from @TestSetup) is fine.
            if (req.getMethod() == 'PATCH') {
                res.setStatusCode(200);
                res.setBody('{"ramp_id":"unchanged"}');
                return res;
            }
            // POST is unexpected on the restore path.
            res.setStatusCode(500);
            res.setBody('{"error":"POST should not be called when all vendors already exist"}');
            return res;
        }
    }

    /**
     * Mock HTTP callout for error responses
     */
    private class RampVendorMockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
            } else {
                res.setStatusCode(400);
                res.setBody('{"error": "Bad Request"}');
            }

            return res;
        }
    }

    /**
     * @description Mock for the restore-and-update-in-same-batch path (Issue #1).
     * GET returns the null-Ramp_Vendor_Id__c Accounts as already existing on Ramp
     * (triggering the restore bucket), while PATCH succeeds for the pre-stamped vendor.
     * Having both in the same chunk would previously fail with "uncommitted work pending"
     * because restore DML ran before the PATCH callout.
     */
    private class RampVendorMockRestoreAndUpdate implements HttpCalloutMock {
        private Set<String> sfIds;
        public RampVendorMockRestoreAndUpdate(Set<String> sfIds) { this.sfIds = sfIds; }

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000}');
                return res;
            }
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('/accounting/vendors')) {
                List<Map<String, Object>> data = new List<Map<String, Object>>();
                for (String sfId : sfIds) {
                    data.add(new Map<String, Object>{
                        'id' => sfId,
                        'ramp_id' => 'ramp_vendor_' + sfId,
                        'is_active' => true,
                        'name' => 'mock'
                    });
                }
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => data,
                    'page' => new Map<String, Object>{ 'next' => null }
                }));
                return res;
            }
            if (req.getMethod() == 'PATCH') {
                res.setStatusCode(200);
                res.setBody('{"ramp_id":"existing-ramp-id-123"}');
                return res;
            }
            res.setStatusCode(500);
            res.setBody('{"error":"Unexpected call"}');
            return res;
        }
    }
}
