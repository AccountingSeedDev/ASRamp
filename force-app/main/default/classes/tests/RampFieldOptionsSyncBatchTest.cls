/**
 * @description Test class for RampFieldOptionsSyncBatch
 */
@IsTest
private class RampFieldOptionsSyncBatchTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

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

        // An Automated Job Result should document the run and WHY it failed.
        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Failed__c, AcctSeed__Notes__c
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_FIELD_OPTIONS_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'The variable sync run should log one AJR');
        System.assert(ajrs[0].AcctSeed__Failed__c > 0, 'Missing field id should be recorded as a failure');
        System.assert(
            ajrs[0].AcctSeed__Notes__c.contains('No Ramp field ID found'),
            'AJR notes should explain why records did not sync: ' + ajrs[0].AcctSeed__Notes__c
        );
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

    @IsTest
    static void testBatchExecution_MultipleTypes() {
        // Insert one variable of each type WITHOUT a Ramp ID so both land in
        // the "to create" path and — with a large batch size — end up in the
        // same execute() chunk.  This exercises the multi-type-per-chunk fix
        // that moved DML after all callouts to avoid a "uncommitted work" error.
        List<AcctSeed__Accounting_Variable__c> extraVars = new List<AcctSeed__Accounting_Variable__c>();
        extraVars.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Cost Center X',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = true
        ));
        extraVars.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Region Y',
            AcctSeed__Type__c = 'GL Account Variable 2',
            AcctSeed__Active__c = true
        ));
        insert extraVars;

        Map<String, String> fieldNameToRampId = new Map<String, String>{
            'GL Account Variable 1' => 'ramp-field-id-1',
            'GL Account Variable 2' => 'ramp-field-id-2'
        };

        // RampFieldOptionsMockSuccess returns 201 on POST and an implicit
        // non-200 (status 0) on GET, so fetchRampIds returns an empty map —
        // every newly-created variable is counted as an error.  The key
        // assertion is that the batch still reaches Status = 'Completed'
        // (before the fix it threw a CalloutException mid-execute).
        Test.setMock(HttpCalloutMock.class, new RampFieldOptionsMockSuccess());

        Test.startTest();
        RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(TEST_CONNECTION_ID, fieldNameToRampId);
        Id jobId = Database.executeBatch(batch, 200);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete when multiple types share a chunk');

        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Failed__c
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_FIELD_OPTIONS_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'Finish should log exactly one AJR');
        System.assert(ajrs[0].AcctSeed__Failed__c > 0,
            'Variables whose Ramp IDs were not returned by GET should be counted as failures');
    }

    @IsTest
    static void testBatchExecution_MultipleTypes_HappyPath() {
        // Insert one variable of each type without a Ramp ID so both land in the
        // "to create" path and end up in the same execute() chunk.
        insert new List<AcctSeed__Accounting_Variable__c>{
            new AcctSeed__Accounting_Variable__c(
                Name = 'Cost Center X',
                AcctSeed__Type__c = 'GL Account Variable 3',
                AcctSeed__Active__c = true
            ),
            new AcctSeed__Accounting_Variable__c(
                Name = 'Region Y',
                AcctSeed__Type__c = 'GL Account Variable 4',
                AcctSeed__Active__c = true
            )
        };

        // Query ALL active variables that will be processed (no Ramp ID yet) so
        // the mock can echo every one of their IDs back in GET responses.  The
        // @TestSetup data (Department A/B) also lack Ramp IDs and must be included,
        // otherwise those records won't match in Phase 4 and would show as failures.
        Set<String> allUnsyncedIds = new Set<String>();
        for (AcctSeed__Accounting_Variable__c v : [
            SELECT Id FROM AcctSeed__Accounting_Variable__c
            WHERE AcctSeed__Active__c = true
              AND Ramp_Field_Option_Id__c = null
              AND AcctSeed__Type__c IN ('GL Account Variable 1', 'GL Account Variable 2',
                                        'GL Account Variable 3', 'GL Account Variable 4')
        ]) {
            allUnsyncedIds.add(v.Id);
        }

        Map<String, String> fieldNameToRampId = new Map<String, String>{
            'GL Account Variable 1' => 'ramp-field-id-1',
            'GL Account Variable 2' => 'ramp-field-id-2',
            'GL Account Variable 3' => 'ramp-field-id-3',
            'GL Account Variable 4' => 'ramp-field-id-4'
        };

        Test.setMock(HttpCalloutMock.class, new RampFieldOptionsMockWithGet(allUnsyncedIds));

        Test.startTest();
        RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(TEST_CONNECTION_ID, fieldNameToRampId);
        Id jobId = Database.executeBatch(batch, 200);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete for multi-type chunk happy path');

        // All unsynced variables should now have Ramp IDs stamped.
        List<AcctSeed__Accounting_Variable__c> stamped = [
            SELECT Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c
            WHERE Id IN :allUnsyncedIds
        ];
        for (AcctSeed__Accounting_Variable__c v : stamped) {
            System.assertNotEquals(null, v.Ramp_Field_Option_Id__c,
                'Phase 4 DML should stamp Ramp_Field_Option_Id__c for each created variable');
        }

        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Succeeded__c, AcctSeed__Failed__c
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_FIELD_OPTIONS_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'Finish should log exactly one AJR');
        System.assertEquals(0, (Integer) ajrs[0].AcctSeed__Failed__c,
            'No failures expected when Ramp returns IDs for all created variables');
        System.assert((Integer) ajrs[0].AcctSeed__Succeeded__c > 0,
            'AJR succeeded count should reflect the stamped variables');
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

    /**
     * Mock that handles GET /accounting/field-options by returning the given SF IDs
     * echoed back with fake Ramp IDs so Phase 4 can stamp Ramp_Field_Option_Id__c.
     */
    private class RampFieldOptionsMockWithGet implements HttpCalloutMock {
        private Set<String> sfIds;

        public RampFieldOptionsMockWithGet(Set<String> sfIds) {
            this.sfIds = sfIds;
        }

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getMethod() == 'PATCH') {
                res.setStatusCode(200);
                res.setBody('{"ramp_id": "updated-option-id", "value": "Updated"}');
            } else if (req.getMethod() == 'POST') {
                res.setStatusCode(201);
                res.setBody('{}');
            } else if (req.getMethod() == 'GET') {
                // Build data array echoing each known SF ID back with a synthetic Ramp ID.
                List<Object> data = new List<Object>();
                Integer idx = 0;
                for (String sfId : sfIds) {
                    data.add(new Map<String, Object>{
                        'ramp_id' => 'ramp-option-' + (++idx),
                        'code' => sfId,
                        'value' => 'Test Option ' + idx
                    });
                }
                Map<String, Object> body = new Map<String, Object>{
                    'data' => data,
                    'page' => new Map<String, Object>{ 'next' => null }
                };
                res.setStatusCode(200);
                res.setBody(JSON.serialize(body));
            }

            return res;
        }
    }
}