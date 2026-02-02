/**
 * @description Test class for RampVendorSyncBatch
 */
@IsTest
private class RampVendorSyncBatchTest {

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    @TestSetup
    static void setup() {
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

        insert accounts;
    }

    @IsTest
    static void testBatchExecution_Success() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampVendorMockSuccess());

        RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Verify batch completed
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete successfully');
    }

    @IsTest
    static void testBatchExecution_NoConnectionId() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampVendorMockNoConnection());

        RampVendorSyncBatch batch = new RampVendorSyncBatch();
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Batch should complete but with errors logged
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even without connection');
    }

    @IsTest
    static void testBatchExecution_ApiError() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampVendorMockError());

        RampVendorSyncBatch batch = new RampVendorSyncBatch(TEST_CONNECTION_ID);
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Batch should complete but with errors
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even with API errors');
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
}