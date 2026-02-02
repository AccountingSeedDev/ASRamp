/**
 * @description Service class for syncing AcctSeed Accounting Variables to Ramp Custom Fields
 */
public with sharing class RampAccountingFieldService {

    /**
     * @description Creates GL Account Variable 1-4 custom fields in Ramp
     * This only creates the field definitions - options are synced separately via batch
     * @param accountingConnectionId The Ramp accounting connection ID
     * @return String Summary of sync results
     */
    public static String syncAccountingVariablesToRamp(String accountingConnectionId) {
        try {
            List<String> results = new List<String>();

            // Create each GL Account Variable field (1-4)
            for (Integer i = 1; i <= 4; i++) {
                String fieldName = 'GL Account Variable ' + i;
                String result = createVariableField(fieldName, i, accountingConnectionId);
                results.add(result);
            }

            return String.join(results, '\n');
        } catch (Exception e) {
            throw new RampAccountingFieldException('Error creating accounting variable fields: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Creates a GL Account Variable custom field in Ramp
     * @param fieldName The name of the field (e.g., 'GL Account Variable 1')
     * @param variableNumber The variable number (1-4)
     * @param accountingConnectionId The Ramp accounting connection ID
     * @return String Result message
     */
    @TestVisible
    private static String createVariableField(String fieldName, Integer variableNumber, String accountingConnectionId) {
        try {
            String rampFieldId = createCustomField(fieldName, accountingConnectionId);

            if (String.isBlank(rampFieldId)) {
                return fieldName + ': Failed to create';
            }

            return fieldName + ': Created (ID: ' + rampFieldId + ')';
        } catch (Exception e) {
            throw new RampAccountingFieldException(
                'Error creating ' + fieldName + ': ' + e.getMessage(), e
            );
        }
    }

    /**
     * @description Generates a deterministic UUID v5-style string based on field name
     * This ensures the same field always gets the same ID to prevent duplicates
     * @param fieldName The field name to generate UUID from
     * @return String A properly formatted UUID
     */
    @TestVisible
    private static String generateDeterministicUUID(String fieldName) {
        // Use SHA-256 hash of field name for deterministic UUID
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf('ASRamp:' + fieldName));
        String hex = EncodingUtil.convertToHex(hash);
        // Format as UUID v5: xxxxxxxx-xxxx-5xxx-yxxx-xxxxxxxxxxxx
        // Position 13 must be '5' (version 5 = name-based)
        // Position 17 must be 8, 9, a, or b (variant)
        return hex.substring(0, 8) + '-' +
               hex.substring(8, 12) + '-' +
               '5' + hex.substring(13, 16) + '-' +
               'a' + hex.substring(17, 20) + '-' +
               hex.substring(20, 32);
    }

    /**
     * @description Creates a custom field in Ramp
     * @param fieldName The name of the field
     * @param accountingConnectionId The Ramp accounting connection ID
     * @return String The Ramp field ID
     */
    @TestVisible
    private static String createCustomField(String fieldName, String accountingConnectionId) {
        try {
            // Generate a deterministic UUID based on field name to prevent duplicates
            String fieldId = generateDeterministicUUID(fieldName);

            // Build request body for custom field creation
            Map<String, Object> requestBody = new Map<String, Object>{
                'id' => fieldId,
                'name' => fieldName,
                'input_type' => 'SINGLE_CHOICE',
                'accounting_connection_id' => accountingConnectionId
            };

            String body = JSON.serialize(requestBody);

            // Make POST request to create custom field
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/fields', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String returnedId = (String) response.get('id');

                if (String.isBlank(returnedId)) {
                    returnedId = fieldId;
                }

                return returnedId;
            } else {
                throw new RampAccountingFieldException(
                    'Failed to create custom field. Status: ' + res.getStatusCode() +
                    ', Response: ' + res.getBody()
                );
            }
        } catch (Exception e) {
            throw new RampAccountingFieldException('Error creating custom field: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Retrieves all custom accounting fields from Ramp for debugging
     * Call from Anonymous Apex: System.debug(RampAccountingFieldService.getCustomFields());
     * @return String JSON response of all custom fields
     */
    public static String getCustomFields() {
        try {
            HttpResponse res = RampAPIService.get('/developer/v1/accounting/fields');
            return 'Status: ' + res.getStatusCode() + '\nBody:\n' + res.getBody();
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }

    /**
     * @description Retrieves custom field options for a specific field
     * Call from Anonymous Apex: System.debug(RampAccountingFieldService.getFieldOptions('field-uuid'));
     * @param fieldId The Ramp field ID
     * @return String JSON response of field options
     */
    public static String getFieldOptions(String fieldId) {
        try {
            HttpResponse res = RampAPIService.get('/developer/v1/accounting/field-options?field_id='+fieldId);
            return 'Status: ' + res.getStatusCode() + '\nBody:\n' + res.getBody();
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }

    /**
     * @description Deletes a custom accounting field from Ramp
     * Call from Anonymous Apex: System.debug(RampAccountingFieldService.deleteCustomField('field-uuid'));
     * @param fieldId The Ramp field ID to delete
     * @return String Result message
     */
    public static String deleteCustomField(String fieldId) {
        try {
            HttpResponse res = RampAPIService.doDelete('/developer/v1/accounting/fields/' + fieldId);
            return 'Status: ' + res.getStatusCode() + '\nBody:\n' + res.getBody();
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }

    /**
     * @description Custom exception for Ramp Accounting Field errors
     */
    public class RampAccountingFieldException extends Exception {}
}