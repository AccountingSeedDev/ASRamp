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
            FieldResult field = createCustomField(fieldName, accountingConnectionId);

            if (field == null || String.isBlank(field.externalId)) {
                return fieldName + ': Failed to create';
            }

            // The POST leaves an existing field untouched, so a field that predates
            // is_splittable is still header-level only until we PATCH it (FS-15129).
            String repair = ensureSplittable(field);

            return fieldName + ': Created (ID: ' + field.externalId + ')'
                + (String.isBlank(repair) ? '' : ' · ' + repair);
        } catch (Exception e) {
            throw new RampAccountingFieldException(
                'Error creating ' + fieldName + ': ' + e.getMessage(), e
            );
        }
    }

    /**
     * @description Makes sure a field can be coded on split line items, PATCHing it when
     * Ramp reports it as header-level only.
     *
     * Only reachable through a PATCH: Ramp's POST returns an existing field unchanged and
     * discards is_splittable, so the flag on the create body applies to brand-new fields
     * only. The PATCH is keyed on ramp_id — our deterministic external id returns
     * 404 DEVELOPER_7002 (verified against the live API, FS-15129).
     *
     * @param field The field as Ramp returned it from the create call
     * @return String A note for the sync summary, or blank when nothing needed doing
     */
    private static String ensureSplittable(FieldResult field) {
        if (field.isSplittable == true) return '';

        if (String.isBlank(field.rampId)) {
            return 'could not be marked splittable: Ramp returned no ramp_id';
        }

        String body = JSON.serialize(new Map<String, Object>{ 'is_splittable' => true });
        HttpResponse res = RampAPIService.patch('/developer/v1/accounting/fields/' + field.rampId, body);

        if (res.getStatusCode() != 200) {
            throw new RampAccountingFieldException(
                'Failed to mark field as splittable. Status: ' + res.getStatusCode() +
                ', Response: ' + res.getBody()
            );
        }

        field.isSplittable = true;
        return 'marked splittable';
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
     * @description The GL Account Variable type a Ramp custom field id belongs to, or null
     * when the id is not one this package created. Lets callers key Ramp's field list on the
     * id we control rather than on Ramp's name, which an admin can rename from either side.
     * @param externalFieldId The 'id' Ramp echoes back for a custom field
     * @return String e.g. 'GL Account Variable 2', or null when the id is not one of ours
     */
    public static String variableTypeForFieldId(String externalFieldId) {
        if (String.isBlank(externalFieldId)) return null;

        for (Integer i = 1; i <= 4; i++) {
            String fieldName = 'GL Account Variable ' + i;
            if (generateDeterministicUUID(fieldName).equalsIgnoreCase(externalFieldId)) {
                return fieldName;
            }
        }
        return null;
    }

    /**
     * @description Creates a custom field in Ramp and reports back what Ramp stored.
     *
     * is_splittable is what lets the field annotate split line items; Ramp defaults it to
     * False. Without it the field is header-level only, so a bill split across programs or
     * funds carries no variable coding on its lines and the Payable Lines come through
     * blank (FS-15129). Note the flag only takes effect for a field Ramp does not already
     * hold — see ensureSplittable for the existing-field path.
     *
     * @param fieldName The name of the field
     * @param accountingConnectionId The Ramp accounting connection ID
     * @return FieldResult The ids and splittable state Ramp reported, or null when the
     *         response carried no id
     */
    @TestVisible
    private static FieldResult createCustomField(String fieldName, String accountingConnectionId) {
        try {
            // Generate a deterministic UUID based on field name to prevent duplicates
            String fieldId = generateDeterministicUUID(fieldName);

            // Build request body for custom field creation
            Map<String, Object> requestBody = new Map<String, Object>{
                'id' => fieldId,
                'name' => fieldName,
                'input_type' => 'SINGLE_CHOICE',
                'accounting_connection_id' => accountingConnectionId,
                'is_splittable' => true
            };

            String body = JSON.serialize(requestBody);

            // Make POST request to create custom field
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/fields', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                FieldResult result = new FieldResult();
                result.externalId = (String) response.get('id');
                result.rampId = (String) response.get('ramp_id');
                result.isSplittable = (response.get('is_splittable') == true);

                if (String.isBlank(result.externalId)) {
                    result.externalId = fieldId;
                }

                return result;
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
     * @description Marks an existing custom accounting field as splittable so it can be
     * coded on bill/transaction line items instead of only at the header level. Use this to
     * repair fields created before is_splittable was set.
     * Call from Anonymous Apex: System.debug(RampAccountingFieldService.makeFieldSplittable('ramp-id-uuid'));
     * @param rampId The Ramp *internal* field id (ramp_id). The deterministic external id
     *        we send as 'id' is rejected with 404 DEVELOPER_7002 on this endpoint.
     * @return String Result message
     */
    public static String makeFieldSplittable(String rampId) {
        try {
            String body = JSON.serialize(new Map<String, Object>{ 'is_splittable' => true });

            HttpResponse res = RampAPIService.patch('/developer/v1/accounting/fields/' + rampId, body);
            return 'Status: ' + res.getStatusCode() + '\nBody:\n' + res.getBody();
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }

    /**
     * @description Repairs the GL Account Variable 1-4 fields for orgs whose fields were
     * created before is_splittable was set, so their values can be coded on bill and
     * transaction line items instead of only at the header.
     *
     * Resolves each field's ramp_id from Ramp's field list rather than deriving it: PATCH
     * accepts only ramp_id, and our deterministic external id 404s. Skips fields Ramp
     * reports as inactive so a repair never silently reactivates a field an admin turned
     * off — unlike the create path, whose POST reactivates by design.
     *
     * Normally unnecessary: syncAccountingVariablesToRamp repairs as it goes, so the
     * "Create Accounting Fields" button in the Ramp Configuration tab is the supported
     * route. This exists for the case where only the flag needs touching.
     *
     * @return String Summary of repair results
     */
    public static String repairVariableFieldsSplittable() {
        List<String> results = new List<String>();

        try {
            Map<String, Map<String, Object>> byName = listFieldsByName();

            for (Integer i = 1; i <= 4; i++) {
                String fieldName = 'GL Account Variable ' + i;
                Map<String, Object> field = byName.get(fieldName);

                if (field == null) {
                    results.add(fieldName + ': not found in Ramp — run the accounting field sync first');
                    continue;
                }
                if (field.get('is_active') == false) {
                    results.add(fieldName + ': skipped (inactive in Ramp)');
                    continue;
                }
                if (field.get('is_splittable') == true) {
                    results.add(fieldName + ': already splittable');
                    continue;
                }

                String rampId = (String) field.get('ramp_id');
                if (String.isBlank(rampId)) {
                    results.add(fieldName + ': FAILED — Ramp returned no ramp_id');
                    continue;
                }

                HttpResponse res = RampAPIService.patch(
                    '/developer/v1/accounting/fields/' + rampId,
                    JSON.serialize(new Map<String, Object>{ 'is_splittable' => true })
                );
                results.add(fieldName + (res.getStatusCode() == 200
                    ? ': marked splittable'
                    : ': FAILED — Status ' + res.getStatusCode() + ', ' + res.getBody()));
            }
        } catch (Exception e) {
            results.add('Repair aborted: ' + e.getMessage());
        }

        return String.join(results, '\n');
    }

    /**
     * @description Ramp's active + inactive custom fields keyed by name, so a repair can
     * resolve ramp_id without deriving it. Pages at Ramp's documented maximum; page.next
     * carries a full URL, so only the start cursor is reused.
     * @return Map<String, Map<String, Object>> field name -> field as Ramp returned it
     */
    private static Map<String, Map<String, Object>> listFieldsByName() {
        Map<String, Map<String, Object>> byName = new Map<String, Map<String, Object>>();
        String cursor = null;

        do {
            String endpoint = '/developer/v1/accounting/fields?page_size=100';
            if (String.isNotBlank(cursor)) {
                endpoint += '&start=' + EncodingUtil.urlEncode(cursor, 'UTF-8');
            }

            HttpResponse res = RampAPIService.get(endpoint);
            if (res.getStatusCode() != 200) {
                throw new RampAccountingFieldException(
                    'Failed to list custom fields. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
                );
            }

            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> fields = response.containsKey('data')
                ? (List<Object>) response.get('data')
                : new List<Object>();

            for (Object f : fields) {
                Map<String, Object> field = (Map<String, Object>) f;
                String name = (String) field.get('name');
                if (String.isNotBlank(name)) byName.put(name, field);
            }

            cursor = extractNextCursor(response);
        } while (String.isNotBlank(cursor));

        return byName;
    }

    /**
     * @description Pulls the keyset cursor out of Ramp's page.next URL. Ramp returns the
     * complete URL of the next page, so passing it straight back as `start` is rejected
     * with DEVELOPER_7001 "Not a valid UUID".
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
     * @description A custom field as Ramp reported it back. Carries both ids because they
     * are not interchangeable: externalId is the deterministic id we send and match options
     * against, while rampId is the only key the field PATCH endpoint accepts.
     */
    public class FieldResult {
        public String externalId;
        public String rampId;
        public Boolean isSplittable = false;
    }

    /**
     * @description Custom exception for Ramp Accounting Field errors
     */
    public class RampAccountingFieldException extends Exception {}
}