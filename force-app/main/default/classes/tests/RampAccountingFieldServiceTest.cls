/**
 * @description Test class for RampAccountingFieldService
 */
@IsTest
private class RampAccountingFieldServiceTest {

    @TestSetup
    static void setup() {
        // Create test Accounting Variables for GL Account Variable 1
        List<AcctSeed__Accounting_Variable__c> variables = new List<AcctSeed__Accounting_Variable__c>();

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

        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Location A',
            AcctSeed__Type__c = 'GL Account Variable 2',
            AcctSeed__Active__c = true
        ));

        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Location B',
            AcctSeed__Type__c = 'GL Account Variable 2',
            AcctSeed__Active__c = true
        ));

        // Inactive variable - should not be synced
        variables.add(new AcctSeed__Accounting_Variable__c(
            Name = 'Inactive Dept',
            AcctSeed__Type__c = 'GL Account Variable 1',
            AcctSeed__Active__c = false
        ));

        insert variables;
    }

    @IsTest
    static void testSyncAccountingVariablesToRamp_Success() {
        // Setup mock responses
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        // Execute
        String result = RampAccountingFieldService.syncAccountingVariablesToRamp();

        Test.stopTest();

        // Verify
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('GL Account Variable 1'), 'Result should mention Variable 1');
        System.assert(result.contains('GL Account Variable 2'), 'Result should mention Variable 2');
    }

    @IsTest
    static void testSyncVariableType_WithNoVariables() {
        // Delete all variables
        delete [SELECT Id FROM AcctSeed__Accounting_Variable__c];

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.syncAccountingVariablesToRamp();

        Test.stopTest();

        // Verify - should handle empty variables gracefully
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('No active variables'), 'Should report no active variables');
    }

    @IsTest
    static void testCreateCustomField_ApiFailure() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockError());

        try {
            RampAccountingFieldService.syncAccountingVariablesToRamp();
            System.assert(false, 'Should have thrown exception');
        } catch (RampAccountingFieldService.RampAccountingFieldException e) {
            System.assert(e.getMessage().contains('Error'), 'Exception should contain error message');
        }

        Test.stopTest();
    }

    /**
     * Mock HTTP callout for successful responses
     */
    private class RampAccountingFieldMockSuccess implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Alternate between field creation and option upload
            if (req.getEndpoint().contains('/accounting/fields') &&
                !req.getEndpoint().contains('field-options')) {
                // Create field response
                res.setStatusCode(201);
                res.setBody('{"id": "field_' + callCount++ + '", "name": "Test Field"}');
            } else if (req.getEndpoint().contains('/accounting/field-options')) {
                // Upload options response
                res.setStatusCode(201);
                res.setBody('[{"id": "option_1", "name": "Option 1"}]');
            }

            return res;
        }
    }

    /**
     * Mock HTTP callout for error responses
     */
    private class RampAccountingFieldMockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(400);
            res.setBody('{"error": "Bad Request"}');
            return res;
        }
    }
}