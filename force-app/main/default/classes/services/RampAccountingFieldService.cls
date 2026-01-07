/**
 * @description Service class for syncing AcctSeed Accounting Variables to Ramp Custom Fields
 */
public with sharing class RampAccountingFieldService {

    /**
     * @description Syncs all GL Account Variables (1-4) to Ramp as custom fields
     * This should be called after establishing an accounting connection
     * @return String Summary of sync results
     */
    public static String syncAccountingVariablesToRamp() {
        try {
            List<String> results = new List<String>();

            // Sync each GL Account Variable type (1-4)
            for (Integer i = 1; i <= 4; i++) {
                String variableType = 'GL Account Variable ' + i;
                String result = syncVariableType(variableType, i);
                results.add(result);
            }

            return String.join(results, '\n');
        } catch (Exception e) {
            throw new RampAccountingFieldException('Error syncing accounting variables: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Syncs a specific variable type to Ramp
     * @param variableType The AcctSeed__Type__c value (e.g., 'GL Account Variable 1')
     * @param variableNumber The variable number (1-4)
     * @return String Result message
     */
    @TestVisible
    private static String syncVariableType(String variableType, Integer variableNumber) {
        try {
            // Query all active accounting variables of this type
            List<AcctSeed__Accounting_Variable__c> variables = [
                SELECT Id, Name, AcctSeed__Type__c, AcctSeed__Active__c
                FROM AcctSeed__Accounting_Variable__c
                WHERE AcctSeed__Type__c = :variableType
                  AND AcctSeed__Active__c = true
                ORDER BY Name
            ];

            if (variables.isEmpty()) {
                return 'No active variables found for ' + variableType;
            }

            // Step 1: Create the custom field in Ramp
            String fieldName = 'GL Account Variable ' + variableNumber;
            String rampFieldId = createCustomField(fieldName);

            if (String.isBlank(rampFieldId)) {
                return 'Failed to create custom field for ' + variableType;
            }

            // Step 2: Upload the field options
            Integer optionsCount = uploadFieldOptions(rampFieldId, variables);

            return 'Successfully synced ' + variableType + ': created field with ' +
                   optionsCount + ' option(s)';
        } catch (Exception e) {
            throw new RampAccountingFieldException(
                'Error syncing ' + variableType + ': ' + e.getMessage(), e
            );
        }
    }

    /**
     * @description Creates a custom field in Ramp
     * @param fieldName The name of the field
     * @return String The Ramp field ID
     */
    @TestVisible
    private static String createCustomField(String fieldName) {
        try {
            // Build request body for custom field creation
            Map<String, Object> requestBody = new Map<String, Object>{
                'name' => fieldName,
                'field_type' => 'SINGLE_SELECT' // Single choice field
            };

            String body = JSON.serialize(requestBody);

            // Make POST request to create custom field
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/fields', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String fieldId = (String) response.get('id');

                if (String.isBlank(fieldId)) {
                    throw new RampAccountingFieldException('Field ID not returned in response');
                }

                return fieldId;
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
     * @description Uploads field options to Ramp
     * @param rampFieldId The Ramp field ID
     * @param variables List of AcctSeed Accounting Variables to upload as options
     * @return Integer Number of options uploaded
     */
    @TestVisible
    private static Integer uploadFieldOptions(String rampFieldId, List<AcctSeed__Accounting_Variable__c> variables) {
        try {
            // Build field options list (max 500 per batch)
            List<Map<String, Object>> options = new List<Map<String, Object>>();

            for (AcctSeed__Accounting_Variable__c variable : variables) {
                Map<String, Object> option = new Map<String, Object>{
                    'field_id' => rampFieldId,
                    'remote_id' => variable.Id,
                    'remote_name' => variable.Name,
                    'name' => variable.Name
                };
                options.add(option);
            }

            // Process in batches if needed (max 500 per API call)
            Integer batchSize = 500;
            Integer totalUploaded = 0;

            for (Integer i = 0; i < options.size(); i += batchSize) {
                Integer endIdx = Math.min(i + batchSize, options.size());
                List<Map<String, Object>> batch = new List<Map<String, Object>>();

                for (Integer j = i; j < endIdx; j++) {
                    batch.add(options[j]);
                }

                String body = JSON.serialize(batch);

                // Make POST request to upload options
                HttpResponse res = RampAPIService.post('/developer/v1/accounting/field-options', body);

                if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                    totalUploaded += batch.size();
                } else {
                    throw new RampAccountingFieldException(
                        'Failed to upload field options. Status: ' + res.getStatusCode() +
                        ', Response: ' + res.getBody()
                    );
                }
            }

            return totalUploaded;
        } catch (Exception e) {
            throw new RampAccountingFieldException('Error uploading field options: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Custom exception for Ramp Accounting Field errors
     */
    public class RampAccountingFieldException extends Exception {}
}