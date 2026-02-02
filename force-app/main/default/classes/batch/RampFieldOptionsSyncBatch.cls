/**
 * @description Batch job to sync Accounting Variable values to Ramp custom field options
 * Creates new options or updates existing ones based on Ramp_Field_Option_Id__c
 * Designed to run on a schedule for ongoing synchronization
 */
public class RampFieldOptionsSyncBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private String accountingConnectionId;
    private Map<String, String> fieldNameToRampId;
    private Integer createdCount = 0;
    private Integer updatedCount = 0;
    private Integer errorCount = 0;
    private List<String> errors = new List<String>();

    /**
     * @description Constructor
     * @param accountingConnectionId The Ramp accounting connection ID
     * @param fieldNameToRampId Map of field type names to their Ramp field IDs
     */
    public RampFieldOptionsSyncBatch(String accountingConnectionId, Map<String, String> fieldNameToRampId) {
        this.accountingConnectionId = accountingConnectionId;
        this.fieldNameToRampId = fieldNameToRampId;
    }

    /**
     * @description Start method - query all active accounting variables
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, AcctSeed__Type__c, AcctSeed__Active__c, Ramp_Field_Option_Id__c
            FROM AcctSeed__Accounting_Variable__c
            WHERE AcctSeed__Active__c = true
              AND AcctSeed__Type__c IN ('GL Account Variable 1', 'GL Account Variable 2',
                                         'GL Account Variable 3', 'GL Account Variable 4')
            ORDER BY AcctSeed__Type__c, Name
        ]);
    }

    /**
     * @description Execute method - process each batch of variables
     */
    public void execute(Database.BatchableContext bc, List<AcctSeed__Accounting_Variable__c> scope) {
        // Separate variables into those needing create vs update
        Map<String, List<AcctSeed__Accounting_Variable__c>> toCreateByField =
            new Map<String, List<AcctSeed__Accounting_Variable__c>>();
        List<AcctSeed__Accounting_Variable__c> toUpdate = new List<AcctSeed__Accounting_Variable__c>();

        for (AcctSeed__Accounting_Variable__c variable : scope) {
            if (String.isNotBlank(variable.Ramp_Field_Option_Id__c)) {
                // Has Ramp ID - needs update
                toUpdate.add(variable);
            } else {
                // No Ramp ID - needs create
                String fieldType = variable.AcctSeed__Type__c;
                if (!toCreateByField.containsKey(fieldType)) {
                    toCreateByField.put(fieldType, new List<AcctSeed__Accounting_Variable__c>());
                }
                toCreateByField.get(fieldType).add(variable);
            }
        }

        // Process updates (one at a time via PATCH)
        for (AcctSeed__Accounting_Variable__c variable : toUpdate) {
            try {
                updateFieldOption(variable);
                updatedCount++;
            } catch (Exception e) {
                errorCount++;
                errors.add('Update ' + variable.Name + ': ' + e.getMessage());
            }
        }

        // Process creates (batch by field type)
        for (String fieldType : toCreateByField.keySet()) {
            String rampFieldId = fieldNameToRampId.get(fieldType);
            if (String.isBlank(rampFieldId)) {
                errorCount++;
                errors.add(fieldType + ': No Ramp field ID found');
                continue;
            }

            try {
                List<AcctSeed__Accounting_Variable__c> variables = toCreateByField.get(fieldType);
                createFieldOptions(rampFieldId, variables);
                createdCount += variables.size();
            } catch (Exception e) {
                errorCount++;
                errors.add('Create ' + fieldType + ': ' + e.getMessage());
            }
        }
    }

    /**
     * @description Finish method - log results
     */
    public void finish(Database.BatchableContext bc) {
        String summary = 'RampFieldOptionsSyncBatch completed.\n' +
                        'Created: ' + createdCount + '\n' +
                        'Updated: ' + updatedCount + '\n' +
                        'Errors: ' + errorCount;

        if (!errors.isEmpty()) {
            summary += '\n\nError details:\n' + String.join(errors, '\n');
        }

        System.debug(summary);
    }

    /**
     * @description Updates an existing field option in Ramp via PATCH
     * @param variable The accounting variable to update
     */
    private void updateFieldOption(AcctSeed__Accounting_Variable__c variable) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'value' => variable.Name,
            'code' => variable.Id,
            'is_active' => variable.AcctSeed__Active__c
        };

        String body = JSON.serialize(requestBody);
        String endpoint = '/developer/v1/accounting/field-options/' + variable.Ramp_Field_Option_Id__c;

        HttpResponse res = RampAPIService.patch(endpoint, body);

        if (res.getStatusCode() != 200) {
            throw new RampAccountingFieldService.RampAccountingFieldException(
                'PATCH failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description Creates new field options in Ramp via batch POST
     * @param rampFieldId The Ramp field ID
     * @param variables List of accounting variables to create as options
     */
    private void createFieldOptions(String rampFieldId, List<AcctSeed__Accounting_Variable__c> variables) {
        // Build options array
        List<Map<String, Object>> options = new List<Map<String, Object>>();

        for (AcctSeed__Accounting_Variable__c variable : variables) {
            Map<String, Object> option = new Map<String, Object>{
                'id' => variable.Id,  // Use SF ID as the option ID
                'value' => variable.Name,
                'code' => variable.Id  // Store SF ID in code for correlation
            };
            options.add(option);
        }

        Map<String, Object> requestBody = new Map<String, Object>{
            'field_id' => rampFieldId,
            'options' => options,
            'accounting_connection_id' => accountingConnectionId
        };

        String body = JSON.serialize(requestBody);
        HttpResponse res = RampAPIService.post('/developer/v1/accounting/field-options', body);

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            // POST response may not include ramp_ids, so fetch them via GET
            fetchAndUpdateRampIds(rampFieldId, variables);
        } else {
            throw new RampAccountingFieldService.RampAccountingFieldException(
                'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description Fetches field options from Ramp and updates SF records with ramp_ids
     * @param rampFieldId The Ramp field ID
     * @param variables The variables that were created
     */
    private void fetchAndUpdateRampIds(String rampFieldId, List<AcctSeed__Accounting_Variable__c> variables) {
        // Build set of SF IDs we're looking for
        Set<String> sfIds = new Set<String>();
        for (AcctSeed__Accounting_Variable__c v : variables) {
            sfIds.add(v.Id);
        }

        // Fetch all options for this field
        Map<String, String> sfIdToRampId = new Map<String, String>();
        String nextPage = null;

        do {
            String endpoint = '/developer/v1/accounting/field-options?field_id=' + rampFieldId;
            if (nextPage != null) {
                endpoint += '&start=' + nextPage;
            }

            HttpResponse res = RampAPIService.get(endpoint);

            if (res.getStatusCode() == 200) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                if (response.containsKey('data')) {
                    List<Object> optionsList = (List<Object>) response.get('data');
                    for (Object opt : optionsList) {
                        Map<String, Object> optMap = (Map<String, Object>) opt;
                        String code = (String) optMap.get('code');
                        String rampId = (String) optMap.get('ramp_id');

                        // Only process if this is one of our variables
                        if (sfIds.contains(code) && String.isNotBlank(rampId)) {
                            sfIdToRampId.put(code, rampId);
                        }
                    }
                }

                // Check for pagination
                if (response.containsKey('page')) {
                    Map<String, Object> page = (Map<String, Object>) response.get('page');
                    nextPage = (String) page.get('next');
                } else {
                    nextPage = null;
                }
            } else {
                // Log error but don't fail - options were created, just couldn't get IDs
                System.debug('Failed to fetch field options: ' + res.getStatusCode() + ' - ' + res.getBody());
                nextPage = null;
            }
        } while (nextPage != null);

        // Update SF records with Ramp IDs
        List<AcctSeed__Accounting_Variable__c> toUpdateRecords = new List<AcctSeed__Accounting_Variable__c>();
        for (AcctSeed__Accounting_Variable__c variable : variables) {
            String rampId = sfIdToRampId.get(variable.Id);
            if (String.isNotBlank(rampId)) {
                toUpdateRecords.add(new AcctSeed__Accounting_Variable__c(
                    Id = variable.Id,
                    Ramp_Field_Option_Id__c = rampId
                ));
            }
        }

        if (!toUpdateRecords.isEmpty()) {
            update toUpdateRecords;
        }
    }
}