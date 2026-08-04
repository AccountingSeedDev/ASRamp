/**
 * @description Batch job to sync Accounting Variable values to Ramp custom field options.
 * Creates new options or updates existing ones based on Ramp_Field_Option_Id__c.
 * Designed to run on a schedule for ongoing synchronization.
 *
 * Callout/DML ordering: Salesforce prohibits callouts after uncommitted DML in the
 * same transaction. execute() is structured in four explicit phases — all PATCHes,
 * all POSTs, all GETs, then a single DML — so multi-type chunks never produce a
 * "You have uncommitted work pending" CalloutException.
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
     * @description Process each batch chunk.
     *
     * Four explicit phases keep the transaction callout-safe when a chunk spans
     * more than one variable type:
     *   Phase 1 — PATCH callouts for records that already have a Ramp ID (no DML).
     *   Phase 2 — POST callouts to create options for records that lack a Ramp ID (no DML).
     *   Phase 3 — GET callouts to fetch Ramp IDs for each successfully POSTed type (no DML).
     *   Phase 4 — single batched DML to stamp all Ramp IDs on SF records.
     */
    public void execute(Database.BatchableContext bc, List<AcctSeed__Accounting_Variable__c> scope) {
        Map<String, List<AcctSeed__Accounting_Variable__c>> toCreateByField =
            new Map<String, List<AcctSeed__Accounting_Variable__c>>();
        List<AcctSeed__Accounting_Variable__c> toUpdate = new List<AcctSeed__Accounting_Variable__c>();

        for (AcctSeed__Accounting_Variable__c variable : scope) {
            if (String.isNotBlank(variable.Ramp_Field_Option_Id__c)) {
                toUpdate.add(variable);
            } else {
                String fieldType = variable.AcctSeed__Type__c;
                if (!toCreateByField.containsKey(fieldType)) {
                    toCreateByField.put(fieldType, new List<AcctSeed__Accounting_Variable__c>());
                }
                toCreateByField.get(fieldType).add(variable);
            }
        }

        // ── Phase 1: PATCH updates (callouts only, no DML) ──
        // Track stale IDs re-routed to the create path so Phase 4 can clear them if GET finds nothing.
        Set<String> staleIds = new Set<String>();
        for (AcctSeed__Accounting_Variable__c variable : toUpdate) {
            try {
                Boolean updated = updateFieldOption(variable);
                if (updated) {
                    updatedCount++;
                } else {
                    // Stale Ramp ID (404) — re-route through create path so POST+GET stamps the new ID
                    staleIds.add(variable.Id);
                    String fieldType = variable.AcctSeed__Type__c;
                    if (!toCreateByField.containsKey(fieldType)) {
                        toCreateByField.put(fieldType, new List<AcctSeed__Accounting_Variable__c>());
                    }
                    toCreateByField.get(fieldType).add(variable);
                }
            } catch (Exception e) {
                errorCount++;
                errors.add('Update ' + variable.Name + ': ' + e.getMessage());
            }
        }

        // ── Phases 2 & 3: POST creates then GET Ramp IDs (all callouts, no DML) ──
        Map<String, String> sfIdToRampId = new Map<String, String>();
        List<AcctSeed__Accounting_Variable__c> candidatesForStamp = new List<AcctSeed__Accounting_Variable__c>();

        for (String fieldType : toCreateByField.keySet()) {
            String rampFieldId = fieldNameToRampId.get(fieldType);
            List<AcctSeed__Accounting_Variable__c> variables = toCreateByField.get(fieldType);

            if (String.isBlank(rampFieldId)) {
                errorCount += variables.size();
                errors.add(fieldType + ': No Ramp field ID found');
                continue;
            }

            try {
                // Phase 2: POST — create options in Ramp (callout only)
                postFieldOptions(rampFieldId, variables);

                // Phase 3: GET — fetch Ramp IDs for stamping (callout only)
                Set<String> sfIds = new Set<String>();
                for (AcctSeed__Accounting_Variable__c v : variables) {
                    sfIds.add(v.Id);
                }
                sfIdToRampId.putAll(fetchRampIds(rampFieldId, sfIds));
                candidatesForStamp.addAll(variables);
            } catch (Exception e) {
                errorCount += variables.size();
                errors.add('Create ' + fieldType + ': ' + e.getMessage());
            }
        }

        // ── Phase 4: DML — stamp new Ramp IDs, and clear stale ones that weren't re-stamped ──
        Set<String> stampedIds = new Set<String>();
        List<AcctSeed__Accounting_Variable__c> toStamp = new List<AcctSeed__Accounting_Variable__c>();
        for (AcctSeed__Accounting_Variable__c variable : candidatesForStamp) {
            String rampId = sfIdToRampId.get(variable.Id);
            if (String.isNotBlank(rampId)) {
                toStamp.add(new AcctSeed__Accounting_Variable__c(
                    Id = variable.Id,
                    Ramp_Field_Option_Id__c = rampId
                ));
                stampedIds.add(variable.Id);
                createdCount++;
            } else if (!staleIds.contains(variable.Id)) {
                errorCount++;
                errors.add('Create ' + variable.Name + ': Ramp ID not returned after POST');
            }
        }
        // Clear stale IDs for records that went through POST+GET but still weren't found in Ramp
        for (AcctSeed__Accounting_Variable__c variable : candidatesForStamp) {
            if (staleIds.contains(variable.Id) && !stampedIds.contains(variable.Id)) {
                toStamp.add(new AcctSeed__Accounting_Variable__c(
                    Id = variable.Id,
                    Ramp_Field_Option_Id__c = null
                ));
                errorCount++;
                errors.add('Stale re-route ' + variable.Name + ': Ramp ID not returned after POST+GET — stale ID cleared');
            }
        }
        if (!toStamp.isEmpty()) {
            update toStamp;
        }
    }

    /**
     * @description Finish method - record an Automated Job Result so every run is
     * documented (incl. why nothing synced), mirroring the inbound pipelines.
     */
    public void finish(Database.BatchableContext bc) {
        Integer processed = createdCount + updatedCount + errorCount;
        Integer succeeded = createdCount + updatedCount;

        String notes = 'Created: ' + createdCount + ' · Updated: ' + updatedCount +
                       ' · Errors: ' + errorCount;
        if (processed == 0) {
            notes += '\nNo active GL Account Variables (1-4) were found to sync.';
        }
        if (!errors.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, 'Error details:\n' + String.join(errors, '\n'));
        }

        RampJobResultLogger.record(
            null, RampJobResultLogger.JOB_FIELD_OPTIONS_SYNC, processed, succeeded, errorCount, notes
        );

        System.debug(notes);
    }

    /**
     * @description PATCH an existing field option in Ramp. Callout only — no DML.
     * @param variable The accounting variable to update
     * @return true if the update succeeded (200), false if the Ramp ID is stale (404)
     */
    private Boolean updateFieldOption(AcctSeed__Accounting_Variable__c variable) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'value' => variable.Name,
            'is_active' => variable.AcctSeed__Active__c
        };

        String body = JSON.serialize(requestBody);
        String endpoint = '/developer/v1/accounting/field-options/' + variable.Ramp_Field_Option_Id__c;

        HttpResponse res = RampAPIService.patch(endpoint, body);

        if (res.getStatusCode() == 200) {
            return true;
        }
        if (res.getStatusCode() == 404) {
            return false;
        }
        throw new RampAccountingFieldService.RampAccountingFieldException(
            'PATCH failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
        );
    }

    /**
     * @description POST new field options to Ramp. Callout only — no DML.
     * @param rampFieldId The Ramp field ID
     * @param variables List of accounting variables to create as options
     */
    private void postFieldOptions(String rampFieldId, List<AcctSeed__Accounting_Variable__c> variables) {
        List<Map<String, Object>> options = new List<Map<String, Object>>();
        for (AcctSeed__Accounting_Variable__c variable : variables) {
            options.add(new Map<String, Object>{
                'id' => variable.Id,
                'value' => variable.Name,
                'code' => variable.Id
            });
        }

        Map<String, Object> requestBody = new Map<String, Object>{
            'field_id' => rampFieldId,
            'options' => options,
            'accounting_connection_id' => accountingConnectionId
        };

        HttpResponse res = RampAPIService.post('/developer/v1/accounting/field-options', JSON.serialize(requestBody));

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            return;
        }
        if (res.getStatusCode() == 400 && res.getBody().contains('DEVELOPER_7020')) {
            // Options already exist in Ramp; proceed to GET phase to stamp Ramp_Field_Option_Id__c
            return;
        }
        throw new RampAccountingFieldService.RampAccountingFieldException(
            'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
        );
    }

    /**
     * @description Fetch Ramp IDs for the given Salesforce record IDs from the
     * field-options GET endpoint. Handles Ramp's keyset pagination. Callout only —
     * no DML; the caller stamps SF records after all callouts complete.
     *
     * @param rampFieldId  Ramp field UUID for the GL Account Variable type
     * @param sfIds        SF record IDs to match against returned `code` values
     * @return Map from Salesforce Id to Ramp option ID
     */
    private Map<String, String> fetchRampIds(String rampFieldId, Set<String> sfIds) {
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
                        if (sfIds.contains(code) && String.isNotBlank(rampId)) {
                            sfIdToRampId.put(code, rampId);
                        }
                    }
                }

                if (response.containsKey('page')) {
                    Map<String, Object> page = (Map<String, Object>) response.get('page');
                    nextPage = (String) page.get('next');
                } else {
                    nextPage = null;
                }
            } else {
                throw new RampAccountingFieldService.RampAccountingFieldException(
                    'GET field-options failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
                );
            }
        } while (nextPage != null);

        return sfIdToRampId;
    }
}
