/**
 * @description Test class for RampFieldOptionsSyncBatch
 */
@IsTest
private class RampFieldOptionsSyncBatchTest {

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    @TestSetup
    static void setup() {
        // Create test Accounting Variables
        List<AcctSeed__Accounting_Variable__c> variables = new List<AcctSeed__Accounting_Variable__c>();

        // Variables without Ramp ID (will be created)
        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Department A',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = true
        ));

        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Department B',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = true
        ));

        // Variable with Ramp ID (will be updated)
        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Location A',
            AcctSeed__Type__c = 'GL Account Variable 2',
            AcctSeed__Active__c = true,
            Ramp_Field_Option_Id__c = 'existing-ramp-id-123'
        ));

        // Inactive variable (should be excluded)
        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Inactive Dept',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = false
        ));

        insert variables;
    }

    @IsTest
    static void testBatchExecution_Success() {
        // Build field name to Ramp ID map
        Map<String, String> fieldNameToRampId = new Map<String, String>{
            'GL Account Variable 1' => 'ramp-field-id-1',
            'GL Account Variable 2' => 'ramp-field-id-2',
            'GL Account Variable 3' => 'ramp-field-id-3',
            'GL Account Variable 4' => 'ramp-field-id-4'
        };

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampFieldOptionsMockSuccess());

        RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(TEST_CONNECTION_ID, fieldNameToRampId);
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Verify batch completed
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete successfully');
    }

    @IsTest
    static void testBatchExecution_MissingFieldId() {
        // Build field name to Ramp ID map with missing entry
        Map<String, String> fieldNameToRampId = new Map<String, String>{
            // Intentionally missing 'GL Account Variable 1'
            'GL Account Variable 2' => 'ramp-field-id-2'
        };

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampFieldOptionsMockSuccess());

        RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(TEST_CONNECTION_ID, fieldNameToRampId);
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Batch should still complete, but with errors logged
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even with missing field IDs');
    }

    @IsTest
    static void testBatchExecution_ApiError() {
        Map<String, String> fieldNameToRampId = new Map<String, String>{
            'GL Account Variable 1' => 'ramp-field-id-1',
            'GL Account Variable 2' => 'ramp-field-id-2'
        };

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampFieldOptionsMockError());

        RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(TEST_CONNECTION_ID, fieldNameToRampId);
        Id jobId = Database.executeBatch(batch, 10);

        Test.stopTest();

        // Batch should complete but with errors
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete even with API errors');
    }

    /**
     * Mock HTTP callout for successful responses
     */
    private class RampFieldOptionsMockSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getMethod() == 'PATCH') {
                // Update response
                res.setStatusCode(200);
                res.setBody('{"ramp_id": "updated-option-id", "value": "Updated Value"}');
            } else if (req.getMethod() == 'POST') {
                // Create response - return data with ramp_ids
                res.setStatusCode(201);
                res.setBody('{"data": [{"ramp_id": "new-ramp-id-1", "code": "a08xx000001234AAA", "value": "Test"}]}');
            }

            return res;
        }
    }

    /**
     * Mock HTTP callout for error responses
     */
    private class RampFieldOptionsMockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(400);
            res.setBody('{"error": "Bad Request"}');
            return res;
        }
    }
}