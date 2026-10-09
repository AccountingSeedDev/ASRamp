/**
 * @description Syncs the records of one Ramp_Custom_Dimension__mdt registration to Ramp as
 * options on that registration's custom field, then chains the next registration from
 * finish(). One instance per registration keeps start() a single natural query and means a
 * failing object (bad config, Ramp rejection) is logged on its own Automated Job Result
 * without taking the remaining registrations down with it.
 *
 * Field resolution keys on the deterministic id RampCustomDimensionService sent when it
 * created the field — never on the field name, which is one rename in Ramp away from
 * breaking.
 *
 * Records leaving scope (Active_Field_API_Name__c false) have their option HIDDEN, never
 * deactivated: per Ramp, a deactivated option can no longer be synced, while a hidden one
 * only drops out of new coding — so transactions already coded to it keep exporting and
 * resolving. A record re-entering scope PATCHes the same option back to VISIBLE.
 *
 * Callout/DML ordering: Salesforce prohibits callouts after uncommitted DML in the same
 * transaction. execute() is structured in four explicit phases — all PATCHes, all POSTs,
 * all GETs, then a single DML — so a chunk never produces a "You have uncommitted work
 * pending" CalloutException.
 */
public class RampCustomDimensionOptionsSyncBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    /** Scope size per execute(). Phase 1 can spend one PATCH per record. */
    public static final Integer BATCH_SIZE = 50;

    /** Ramp's documented maximum number of options per field-options POST. */
    private static final Integer MAX_OPTIONS_PER_POST = 500;

    /** Ramp's field-options / fields GET accepts page_size 2–100. */
    private static final Integer LOOKUP_PAGE_SIZE = 100;

    /** Upper bound on lookup pages (LOOKUP_PAGE_SIZE * this = options scanned). */
    private static final Integer MAX_LOOKUP_PAGES = 50;

    /**
     * Callouts held back from the open-ended loops (lookup paging, one-at-a-time POST retry)
     * so a token refresh still fits — a LimitException is not catchable.
     */
    private static final Integer CALLOUT_RESERVE = 2;

    @TestVisible
    private static final String OPTION_ID_SEED_PREFIX = 'ASRampDimOpt:';

    /** Ramp's error code for a POSTed option whose id already exists on the field. */
    @TestVisible
    private static final String DUPLICATE_OPTION_CODE = 'DEVELOPER_7020';

    /** Ramp field-option visibility values. */
    @TestVisible
    private static final String VISIBILITY_VISIBLE = 'VISIBLE';
    @TestVisible
    private static final String VISIBILITY_HIDDEN = 'HIDDEN';

    private String accountingConnectionId;
    private Ramp_Custom_Dimension__mdt registration;
    private List<Ramp_Custom_Dimension__mdt> remainingRegistrations;

    private RampCustomDimensionService.ResolvedRegistration resolved;
    private String fieldId;
    private String fieldRampId;
    private Boolean fieldLookupDone = false;
    private String fieldLookupError;

    private Integer stampedCount = 0;
    private Integer updatedCount = 0;
    private Integer errorCount = 0;
    private List<String> errors = new List<String>();
    // Non-fatal conditions worth surfacing on the AJR without inflating the failure count —
    // e.g. a DEVELOPER_7020 rejection left behind by an earlier partial run.
    private List<String> warnings = new List<String>();

    /**
     * @description Constructor. The first registration is processed by this instance; the
     * rest are chained one at a time from finish().
     * @param accountingConnectionId The Ramp accounting connection ID
     * @param registrations Registrations still to process, in order
     */
    public RampCustomDimensionOptionsSyncBatch(String accountingConnectionId,
            List<Ramp_Custom_Dimension__mdt> registrations) {
        this.accountingConnectionId = accountingConnectionId;
        List<Ramp_Custom_Dimension__mdt> queue = registrations == null
            ? new List<Ramp_Custom_Dimension__mdt>()
            : new List<Ramp_Custom_Dimension__mdt>(registrations);
        this.registration = queue.isEmpty() ? null : queue.remove(0);
        this.remainingRegistrations = queue;
    }

    /**
     * @description Starts the chain over every active registration.
     * @param accountingConnectionId The Ramp accounting connection ID
     * @return Id The first batch job's Id, or null when there are no active registrations
     */
    public static Id startSync(String accountingConnectionId) {
        List<Ramp_Custom_Dimension__mdt> registrations = RampCustomDimensionService.getActiveRegistrations();
        if (registrations.isEmpty()) {
            return null;
        }
        return Database.executeBatch(
            new RampCustomDimensionOptionsSyncBatch(accountingConnectionId, registrations), BATCH_SIZE
        );
    }

    /**
     * @description Start method - query the registered object's records. Every object and
     * field name in the query comes from describe via RampCustomDimensionService.resolve(),
     * never from the raw CMDT text.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // An exception thrown out of start() kills the job before finish() runs, which would
        // also break the chain to the next registration. Catch it, record it, and hand back
        // an empty locator so finish() still logs the failure and chains.
        try {
            if (registration == null) {
                throw new RampCustomDimensionService.RampCustomDimensionException('No registration was provided.');
            }
            resolved = RampCustomDimensionService.resolve(registration);
            fieldId = RampCustomDimensionService.fieldIdFor(registration);
            return Database.getQueryLocator(buildQuery(resolved));
        } catch (Exception e) {
            errorCount++;
            errors.add('Registration skipped: ' + e.getMessage());
            return Database.getQueryLocator([SELECT Id FROM Account WHERE Id = NULL]);
        }
    }

    /**
     * @description Records that are active (so need an option) or already hold an option id
     * (so their option must be kept in step, including hiding it once the record leaves scope).
     */
    @TestVisible
    private static String buildQuery(RampCustomDimensionService.ResolvedRegistration r) {
        Set<String> fields = new Set<String>{ 'Id', r.labelFieldApiName, r.optionIdFieldApiName };
        if (r.activeFieldApiName != null) {
            fields.add(r.activeFieldApiName);
        }

        String soql = 'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM ' + r.objectApiName;
        if (r.activeFieldApiName != null) {
            soql += ' WHERE ' + r.activeFieldApiName + ' = true OR ' + r.optionIdFieldApiName + ' != null';
        }
        return soql + ' ORDER BY Id';
    }

    /**
     * @description Process each batch chunk in four fixed phases:
     *   Phase 1 — PATCH callouts for records that already hold a Ramp option id (no DML).
     *   Phase 2 — POST callouts creating options for records that lack one (no DML).
     *   Phase 3 — GET callouts resolving ramp_id for every record from Phase 2, whether or
     *             not its POST succeeded, so options already on Ramp are reconciled (no DML).
     *   Phase 4 — a single bulk DML stamping the option-id field.
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (!resolveField()) {
            errorCount += scope.size();
            return;
        }

        List<SObject> toUpdate = new List<SObject>();
        List<SObject> toCreate = new List<SObject>();
        for (SObject record : scope) {
            if (String.isBlank(labelOf(record))) {
                errorCount++;
                errors.add(record.Id + ': ' + resolved.labelFieldApiName + ' is blank, so it has no option value');
            } else if (String.isNotBlank(optionIdOf(record))) {
                toUpdate.add(record);
            } else {
                toCreate.add(record);
            }
        }

        // ── Phase 1: PATCH updates (callouts only, no DML) ──
        for (SObject record : toUpdate) {
            try {
                patchOption(record);
                updatedCount++;
            } catch (Exception e) {
                errorCount++;
                errors.add('Update ' + describe(record) + ': ' + e.getMessage());
            }
        }

        if (toCreate.isEmpty()) {
            return;
        }

        // ── Phase 2: POST creates (callouts only, no DML) ──
        // A POST failure is not conclusive — Phase 3 runs regardless and Phase 4 counts
        // whatever is genuinely missing, so record-level counts stay correct either way.
        createOptions(toCreate);

        // ── Phase 3: GET ramp_ids for stamping (callouts only, no DML) ──
        OptionLookup lookup = new OptionLookup();
        String lookupError;
        try {
            lookup = fetchOptionRampIds(toCreate);
        } catch (Exception e) {
            lookupError = e.getMessage();
            errors.add('Lookup: ' + lookupError);
        }

        // ── Phase 4: DML — stamp every resolved option id in one operation ──
        List<SObject> toStamp = new List<SObject>();
        for (SObject record : toCreate) {
            String rampId = lookup.recordIdToRampId.get(record.Id);
            if (String.isNotBlank(rampId)) {
                SObject stamp = record.getSObjectType().newSObject(record.Id);
                stamp.put(resolved.optionIdFieldApiName, rampId);
                toStamp.add(stamp);
            } else {
                errorCount++;
                errors.add('Create ' + describe(record) + ': ' + (
                    lookupError != null
                        ? 'Ramp option lookup failed'
                        : lookup.truncated
                            ? 'Ramp option lookup stopped before this record was found'
                            : 'Ramp option not found after POST'
                ));
            }
        }
        if (!toStamp.isEmpty()) {
            try {
                update toStamp;
                stampedCount += toStamp.size();
            } catch (Exception e) {
                errorCount += toStamp.size();
                errors.add('Stamp ' + resolved.optionIdFieldApiName + ' on ' + toStamp.size() + ' record(s): ' +
                           e.getMessage());
            }
        }
    }

    /**
     * @description Finish method - record this registration's Automated Job Result, then chain
     * the next registration.
     */
    public void finish(Database.BatchableContext bc) {
        Integer processed = stampedCount + updatedCount + errorCount;
        Integer succeeded = stampedCount + updatedCount;

        String notes = 'Registration: ' + (registration == null
            ? '(none)' : RampCustomDimensionService.registrationLabel(registration)) +
            '\nStamped: ' + stampedCount + ' · Updated: ' + updatedCount + ' · Errors: ' + errorCount;
        if (processed == 0) {
            notes += '\nNo records were found to sync.';
        }
        if (!errors.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, 'Error details:\n' + String.join(errors, '\n'));
        }
        if (!warnings.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, 'Warnings:\n' + String.join(warnings, '\n'));
        }
        notes = RampJobResultLogger.appendNote(notes, chainNext());

        RampJobResultLogger.record(
            null, RampJobResultLogger.JOB_CUSTOM_DIMENSION_SYNC, processed, succeeded, errorCount, notes
        );

        System.debug(notes);
    }

    private String chainNext() {
        if (remainingRegistrations.isEmpty()) {
            return null;
        }
        String next = RampCustomDimensionService.registrationLabel(remainingRegistrations[0]);
        try {
            Database.executeBatch(
                new RampCustomDimensionOptionsSyncBatch(accountingConnectionId, remainingRegistrations), BATCH_SIZE
            );
            return 'Next registration queued: ' + next;
        } catch (Exception e) {
            return 'Could not queue the remaining ' + remainingRegistrations.size() + ' registration(s) (next: ' +
                   next + '): ' + e.getMessage();
        }
    }

    /**
     * @description Resolves the Ramp field's ramp_id once per run (Database.Stateful), by
     * matching the deterministic id the package sent — never by name. Callout only.
     * @return Boolean true when the field was found
     */
    private Boolean resolveField() {
        if (!fieldLookupDone) {
            fieldLookupDone = true;
            try {
                fieldRampId = fetchFieldRampId(fieldId);
                if (String.isBlank(fieldRampId)) {
                    fieldLookupError = 'No Ramp field has id ' + fieldId + '. Run the custom dimension field sync first.';
                }
            } catch (Exception e) {
                fieldLookupError = 'Could not resolve Ramp field ' + fieldId + ': ' + e.getMessage();
            }
            if (fieldLookupError != null) {
                errors.add(fieldLookupError);
            }
        }
        return fieldLookupError == null;
    }

    private String fetchFieldRampId(String externalId) {
        String cursor = null;
        Integer pageCount = 0;

        do {
            String endpoint = '/developer/v1/accounting/fields?page_size=' + LOOKUP_PAGE_SIZE;
            if (cursor != null) {
                endpoint += '&start=' + EncodingUtil.urlEncode(cursor, 'UTF-8');
            }

            HttpResponse res = RampAPIService.get(endpoint);
            if (res.getStatusCode() != 200) {
                throw new RampCustomDimensionService.RampCustomDimensionException(
                    'GET fields failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
                );
            }

            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> fields = response.containsKey('data')
                ? (List<Object>) response.get('data')
                : new List<Object>();
            for (Object f : fields) {
                Map<String, Object> field = (Map<String, Object>) f;
                if (externalId == (String) field.get('id')) {
                    return (String) field.get('ramp_id');
                }
            }

            cursor = RampPaginationUtil.extractNextCursor(response);
            pageCount++;
        } while (cursor != null && pageCount < MAX_LOOKUP_PAGES && hasCalloutBudget());

        return null;
    }

    /**
     * @description PATCH an existing option in Ramp, keyed on the stored ramp_id. A record
     * out of scope is HIDDEN and one in scope is VISIBLE; is_active is deliberately never
     * sent, since a deactivated option can no longer be synced and would strand the
     * transactions already coded to it. Callout only — no DML.
     */
    private void patchOption(SObject record) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'value' => labelOf(record),
            'visibility' => isActive(record) ? VISIBILITY_VISIBLE : VISIBILITY_HIDDEN
        };

        HttpResponse res = RampAPIService.patch(
            '/developer/v1/accounting/field-options/' + optionIdOf(record), JSON.serialize(requestBody)
        );

        if (res.getStatusCode() != 200) {
            throw new RampCustomDimensionService.RampCustomDimensionException(
                'PATCH failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description POSTs new options in slices of MAX_OPTIONS_PER_POST. Ramp's POST is
     * all-or-nothing and rejects the whole slice with DEVELOPER_7020 when any option id
     * already exists — the state an earlier partial run (POST succeeded, stamp did not)
     * leaves behind. That is a warning, not a failure: the slice is retried one option at a
     * time so the genuinely new options still get created, and Phase 3 reconciles the rest.
     */
    private void createOptions(List<SObject> records) {
        for (Integer i = 0; i < records.size(); i += MAX_OPTIONS_PER_POST) {
            List<SObject> slice = new List<SObject>();
            for (Integer j = i; j < Math.min(i + MAX_OPTIONS_PER_POST, records.size()); j++) {
                slice.add(records[j]);
            }

            try {
                postOptions(slice);
            } catch (DuplicateOptionException e) {
                postIndividually(slice);
            } catch (Exception e) {
                errors.add('Create ' + slice.size() + ' option(s): ' + e.getMessage());
            }
        }
    }

    private void postIndividually(List<SObject> records) {
        Integer alreadyExisted = 0;
        Integer notAttempted = 0;
        for (SObject record : records) {
            if (!hasCalloutBudget()) {
                notAttempted++;
                continue;
            }
            try {
                postOptions(new List<SObject>{ record });
            } catch (DuplicateOptionException e) {
                alreadyExisted++;
            } catch (Exception e) {
                errors.add('Create ' + describe(record) + ': ' + e.getMessage());
            }
        }

        String warning = DUPLICATE_OPTION_CODE + ': ' + alreadyExisted + ' of ' + records.size() +
                         ' option(s) already existed in Ramp from an earlier partial run — re-linking them';
        if (notAttempted > 0) {
            warning += '; ' + notAttempted + ' not retried (callout limit) and will be picked up next run';
        }
        warnings.add(warning);
    }

    /**
     * @description POST options to Ramp. Callout only — no DML.
     * @throws DuplicateOptionException when Ramp rejects with DEVELOPER_7020
     */
    private void postOptions(List<SObject> records) {
        List<Map<String, Object>> options = new List<Map<String, Object>>();
        for (SObject record : records) {
            options.add(new Map<String, Object>{
                'id' => optionIdFor(record.Id),
                'value' => labelOf(record),
                'code' => String.valueOf(record.Id)
            });
        }

        Map<String, Object> requestBody = new Map<String, Object>{
            'field_id' => fieldRampId,
            'options' => options,
            'accounting_connection_id' => accountingConnectionId
        };

        HttpResponse res = RampAPIService.post('/developer/v1/accounting/field-options', JSON.serialize(requestBody));

        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            String message = 'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody();
            if (res.getBody() != null && res.getBody().contains(DUPLICATE_OPTION_CODE)) {
                throw new DuplicateOptionException(message);
            }
            throw new RampCustomDimensionService.RampCustomDimensionException(message);
        }
    }

    /**
     * @description Result of a paginated option lookup: the recordId→ramp_id pairs found,
     * plus whether paging stopped before every record was found.
     */
    private class OptionLookup {
        private Map<Id, String> recordIdToRampId = new Map<Id, String>();
        private Boolean truncated = false;
    }

    /**
     * @description Resolves ramp_id for the given records from GET /accounting/field-options,
     * filtered by field_remote_id (the deterministic field id). Options match on the id we
     * POSTed, falling back to code (the record Id). Callout only — no DML.
     *
     * page.next carries the complete URL of the next page, so RampPaginationUtil extracts
     * just the start cursor. The loop stops once every record is found, and is bounded by
     * MAX_LOOKUP_PAGES and the remaining callout budget.
     */
    private OptionLookup fetchOptionRampIds(List<SObject> records) {
        Map<String, Id> recordIdByKey = new Map<String, Id>();
        for (SObject record : records) {
            recordIdByKey.put(optionIdFor(record.Id), record.Id);
            recordIdByKey.put(String.valueOf(record.Id), record.Id);
        }

        OptionLookup result = new OptionLookup();
        String cursor = null;
        Integer pageCount = 0;

        do {
            String endpoint = '/developer/v1/accounting/field-options?field_remote_id=' +
                              EncodingUtil.urlEncode(fieldId, 'UTF-8') + '&page_size=' + LOOKUP_PAGE_SIZE;
            if (cursor != null) {
                endpoint += '&start=' + EncodingUtil.urlEncode(cursor, 'UTF-8');
            }

            HttpResponse res = RampAPIService.get(endpoint);
            if (res.getStatusCode() != 200) {
                throw new RampCustomDimensionService.RampCustomDimensionException(
                    'GET field-options failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
                );
            }

            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> options = response.containsKey('data')
                ? (List<Object>) response.get('data')
                : new List<Object>();
            for (Object o : options) {
                Map<String, Object> option = (Map<String, Object>) o;
                String rampId = (String) option.get('ramp_id');
                if (String.isBlank(rampId)) {
                    continue;
                }
                Id recordId = recordIdByKey.get((String) option.get('id'));
                if (recordId == null) {
                    recordId = recordIdByKey.get((String) option.get('code'));
                }
                if (recordId != null) {
                    result.recordIdToRampId.put(recordId, rampId);
                }
            }

            cursor = RampPaginationUtil.extractNextCursor(response);
            pageCount++;
        } while (cursor != null && result.recordIdToRampId.size() < records.size()
                 && pageCount < MAX_LOOKUP_PAGES && hasCalloutBudget());

        result.truncated = (cursor != null && result.recordIdToRampId.size() < records.size());
        return result;
    }

    /**
     * @description The option's external id: deterministic per field + record, so a re-run
     * POSTs the same id (and gets DEVELOPER_7020 rather than a duplicate), and two
     * registrations on the same object never collide on one record's id.
     */
    @TestVisible
    private String optionIdFor(Id recordId) {
        return RampDeterministicIdUtil.generateUUID(OPTION_ID_SEED_PREFIX + fieldId + ':' + recordId);
    }

    private String labelOf(SObject record) {
        Object value = record.get(resolved.labelFieldApiName);
        return value == null ? null : String.valueOf(value);
    }

    private String optionIdOf(SObject record) {
        return (String) record.get(resolved.optionIdFieldApiName);
    }

    private Boolean isActive(SObject record) {
        return resolved.activeFieldApiName == null || record.get(resolved.activeFieldApiName) == true;
    }

    private String describe(SObject record) {
        return labelOf(record) + ' (' + record.Id + ')';
    }

    private static Boolean hasCalloutBudget() {
        return Limits.getLimitCallouts() - Limits.getCallouts() > CALLOUT_RESERVE;
    }

    public class DuplicateOptionException extends Exception {}
}