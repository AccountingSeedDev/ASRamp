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

    /**
     * Ramp's field-options GET accepts page_size 2–100 and defaults to 20. Request the
     * documented maximum so a chunk's lookup costs as few callouts as possible — Phase 1
     * can already spend one PATCH per record, and a LimitException is not catchable.
     */
    private static final Integer LOOKUP_PAGE_SIZE = 100;

    /** Upper bound on lookup pages per field type (LOOKUP_PAGE_SIZE * this = options scanned). */
    private static final Integer MAX_LOOKUP_PAGES = 50;

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
        for (AcctSeed__Accounting_Variable__c variable : toUpdate) {
            try {
                updateFieldOption(variable);
                updatedCount++;
            } catch (Exception e) {
                errorCount++;
                errors.add('Update ' + variable.Name + ': ' + e.getMessage());
            }
        }

        // ── Phases 2 & 3: POST creates then GET Ramp IDs (all callouts, no DML) ──
        // Accumulate sfId→rampId pairs and the candidate records across all types
        // before touching the database.
        Map<String, String> sfIdToRampId = new Map<String, String>();
        List<AcctSeed__Accounting_Variable__c> candidatesForStamp = new List<AcctSeed__Accounting_Variable__c>();
        // Field types whose Ramp lookup hit MAX_LOOKUP_PAGES before finding every record,
        // so Phase 4 can report truncation instead of blaming the POST.
        Set<String> truncatedLookups = new Set<String>();

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
                RampIdLookup lookup = fetchRampIds(rampFieldId, sfIds);
                sfIdToRampId.putAll(lookup.sfIdToRampId);
                if (lookup.truncated) {
                    truncatedLookups.add(fieldType);
                }
                candidatesForStamp.addAll(variables);
            } catch (Exception e) {
                errorCount += variables.size();
                errors.add('Create ' + fieldType + ': ' + e.getMessage());
            }
        }

        // ── Phase 4: DML — stamp all Ramp IDs in one operation ──
        List<AcctSeed__Accounting_Variable__c> toStamp = new List<AcctSeed__Accounting_Variable__c>();
        for (AcctSeed__Accounting_Variable__c variable : candidatesForStamp) {
            String rampId = sfIdToRampId.get(variable.Id);
            if (String.isNotBlank(rampId)) {
                toStamp.add(new AcctSeed__Accounting_Variable__c(
                    Id = variable.Id,
                    Ramp_Field_Option_Id__c = rampId
                ));
                createdCount++;
            } else {
                errorCount++;
                errors.add('Create ' + variable.Name + ': ' + (
                    truncatedLookups.contains(variable.AcctSeed__Type__c)
                        ? 'Ramp option lookup stopped at the ' + MAX_LOOKUP_PAGES +
                          '-page limit (' + (MAX_LOOKUP_PAGES * LOOKUP_PAGE_SIZE) +
                          ' options) before this record was found'
                        : 'Ramp ID not returned after POST'
                ));
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
     */
    private void updateFieldOption(AcctSeed__Accounting_Variable__c variable) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'value' => variable.Name,
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

        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new RampAccountingFieldService.RampAccountingFieldException(
                'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description Result of a paginated field-option lookup: the sfId→rampId pairs
     * found, plus whether paging stopped early at MAX_LOOKUP_PAGES (so the caller can
     * distinguish truncation from Ramp genuinely not returning an ID).
     */
    private class RampIdLookup {
        private Map<String, String> sfIdToRampId = new Map<String, String>();
        private Boolean truncated = false;
    }

    /**
     * @description Fetch Ramp IDs for the given Salesforce record IDs from the
     * field-options GET endpoint. Callout only — no DML; the caller stamps SF records
     * after all callouts complete.
     *
     * Paging follows Ramp's keyset pagination: page.next carries the complete URL of the
     * next page, so extractNextCursor() pulls out just the start cursor. Requests
     * page_size=LOOKUP_PAGE_SIZE (Ramp's documented max) rather than the default 20.
     * The loop stops early once every requested ID is found, and is bounded at
     * MAX_LOOKUP_PAGES so a very large option set cannot exhaust the callout limit —
     * that bound is reported back via RampIdLookup.truncated.
     *
     * @param rampFieldId  Ramp field UUID for the GL Account Variable type
     * @param sfIds        SF record IDs to match against returned `code` values
     * @return RampIdLookup holding the sfId→rampId pairs and the truncation flag
     */
    private RampIdLookup fetchRampIds(String rampFieldId, Set<String> sfIds) {
        RampIdLookup result = new RampIdLookup();
        Map<String, String> sfIdToRampId = result.sfIdToRampId;
        String nextCursor = null;
        Integer pageCount = 0;

        do {
            String endpoint = '/developer/v1/accounting/field-options?field_id=' + rampFieldId +
                              '&page_size=' + LOOKUP_PAGE_SIZE;
            if (nextCursor != null) {
                endpoint += '&start=' + EncodingUtil.urlEncode(nextCursor, 'UTF-8');
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

                nextCursor = extractNextCursor(response);
                pageCount++;
            } else {
                throw new RampAccountingFieldService.RampAccountingFieldException(
                    'GET field-options failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
                );
            }
        } while (nextCursor != null && sfIdToRampId.size() < sfIds.size() && pageCount < MAX_LOOKUP_PAGES);

        result.truncated = (nextCursor != null && sfIdToRampId.size() < sfIds.size());
        return result;
    }

    /**
     * @description Pulls the keyset cursor out of Ramp's page.next URL. Ramp returns the
     * complete URL of the next page (e.g. ".../field-options?field_id=<id>&start=<cursor>"),
     * so the cursor must be extracted rather than used as-is — passing the whole URL as
     * `start` makes Ramp reject the request (DEVELOPER_7001 "Not a valid UUID").
     * @param responseMap The parsed JSON body of a paginated Ramp response
     * @return String The start cursor for the next page, or null if there is none
     */
    private static String extractNextCursor(Map<String, Object> responseMap) {
        Object pageObj = responseMap.get('page');
        if (!(pageObj instanceof Map<String, Object>)) return null;
        String nextUrl = (String) ((Map<String, Object>) pageObj).get('next');
        if (String.isBlank(nextUrl)) return null;
        Integer i = nextUrl.indexOf('start=');
        if (i < 0) return null;
        String cursor = nextUrl.substring(i + 6);
        Integer amp = cursor.indexOf('&');
        if (amp >= 0) cursor = cursor.substring(0, amp);
        return cursor;
    }
}
