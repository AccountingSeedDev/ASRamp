/**
 * @description Controller for Ramp Configuration Lightning Component
 */
public with sharing class RampConfigurationController {

    /**
     * @description Wrapper class for credential data
     */
    public class CredentialWrapper {
        @AuraEnabled public String developerName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String clientId { get; set; }
        @AuraEnabled public String clientSecret { get; set; }
        @AuraEnabled public String tokenUrl { get; set; }
        @AuraEnabled public String apiBaseUrl { get; set; }
        @AuraEnabled public String scopes { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
    }

    /**
     * @description Retrieves the active Ramp credential configuration
     * @return CredentialWrapper The credential data or null if not found
     */
    @AuraEnabled(cacheable=true)
    public static CredentialWrapper getActiveCredential() {
        try {
            List<Ramp_Credential__mdt> credentials = [
                SELECT DeveloperName, Label, Client_ID__c, Client_Secret__c,
                       Token_URL__c, API_Base_URL__c, Scopes__c, Is_Active__c
                FROM Ramp_Credential__mdt
                WHERE Is_Active__c = true
                LIMIT 1
            ];

            if (!credentials.isEmpty()) {
                Ramp_Credential__mdt cred = credentials[0];
                CredentialWrapper wrapper = new CredentialWrapper();
                wrapper.developerName = cred.DeveloperName;
                wrapper.label = cred.Label;
                wrapper.clientId = cred.Client_ID__c;
                wrapper.clientSecret = cred.Client_Secret__c;
                wrapper.tokenUrl = cred.Token_URL__c;
                wrapper.apiBaseUrl = cred.API_Base_URL__c;
                wrapper.scopes = cred.Scopes__c;
                wrapper.isActive = cred.Is_Active__c;
                return wrapper;
            }

            return null;
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving credential: ' + e.getMessage());
        }
    }

    /**
     * @description Tests the Ramp credentials by attempting to get an access token
     * @return String Success message with token info or error message
     */
    @AuraEnabled
    public static String testConnection() {
        try {
            String token = RampAuthService.getAccessToken();

            if (String.isNotBlank(token)) {
                // Make a test API call to verify the token works
                // Using transactions endpoint since we have transactions:read scope
                HttpResponse res = RampAPIService.get('/developer/v1/transactions?page_size=2');

                if (res.getStatusCode() == 200) {
                    return 'Connection successful! API responded with status 200.';
                } else {
                    return 'Connection established but API returned status ' + res.getStatusCode() +
                           '. Response: ' + res.getBody();
                }
            } else {
                throw new AuraHandledException('Failed to obtain access token');
            }
        } catch (Exception e) {
            throw new AuraHandledException('Connection test failed: ' + e.getMessage());
        }
    }

    /**
     * @description Clears the cached access token
     * @return String Success message
     */
    @AuraEnabled
    public static String clearTokenCache() {
        try {
            RampAuthService.clearCachedToken();
            return 'Token cache cleared successfully';
        } catch (Exception e) {
            throw new AuraHandledException('Error clearing cache: ' + e.getMessage());
        }
    }

    /**
     * @description Establishes accounting connection with Ramp
     * @return String Success message with connection ID
     */
    @AuraEnabled
    public static String establishAccountingConnection() {
        try {
            // Create accounting connection for Accounting Seed
            String result = RampAccountingService.createAccountingConnection('ACCOUNTING_SEED');
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Error establishing accounting connection: ' + e.getMessage());
        }
    }

    /**
     * @description Checks if accounting connection exists
     * @return Boolean True if connection exists
     */
    @AuraEnabled
    public static Boolean hasAccountingConnection() {
        try {
            return RampAccountingService.testAccountingConnection();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Syncs all GL Accounts to Ramp
     * @return String Summary of sync results
     */
    @AuraEnabled
    public static String syncGLAccounts() {
        try {
            return RampGLAccountService.syncAllGLAccounts();
        } catch (Exception e) {
            throw new AuraHandledException('Error syncing GL Accounts: ' + e.getMessage());
        }
    }

    /**
     * @description Gets GL Account sync statistics
     * @return Map<String, Integer> Statistics about sync status
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Integer> getGLAccountStats() {
        try {
            return RampGLAccountService.getSyncStatistics();
        } catch (Exception e) {
            throw new AuraHandledException('Error getting GL Account stats: ' + e.getMessage());
        }
    }

    /**
     * @description Creates the GL Account Variable 1-4 custom fields in Ramp
     * @return String Summary of field creation results
     */
    @AuraEnabled
    public static String createAccountingFields() {
        try {
            // Get the accounting connection ID first
            Map<String, Object> connection = RampAccountingService.getAccountingConnection();
            String connectionId = (String) connection.get('id');

            if (String.isBlank(connectionId)) {
                throw new AuraHandledException('No accounting connection found. Please establish a connection first.');
            }

            return RampAccountingFieldService.syncAccountingVariablesToRamp(connectionId);
        } catch (Exception e) {
            throw new AuraHandledException('Error creating Accounting Fields: ' + e.getMessage());
        }
    }

    /**
     * @description Kicks off batch job to sync Accounting Variable values to Ramp field options
     * @return String Job ID and status message
     */
    @AuraEnabled
    public static String syncAccountingVariables() {
        try {
            // Get the accounting connection
            Map<String, Object> connection = RampAccountingService.getAccountingConnection();
            String connectionId = (String) connection.get('id');

            if (String.isBlank(connectionId)) {
                throw new AuraHandledException('No accounting connection found. Please establish a connection first.');
            }

            // Get the existing custom fields to build field name to Ramp ID map
            Map<String, String> fieldNameToRampId = getFieldNameToRampIdMap();

            if (fieldNameToRampId.isEmpty()) {
                throw new AuraHandledException('No custom fields found in Ramp. Please create accounting fields first.');
            }

            // Start the batch job
            RampFieldOptionsSyncBatch batch = new RampFieldOptionsSyncBatch(connectionId, fieldNameToRampId);
            Id jobId = Database.executeBatch(batch, 50);

            return 'Sync job started. Job ID: ' + jobId + '\nThe job will create new options and update existing ones.';
        } catch (Exception e) {
            throw new AuraHandledException('Error starting sync job: ' + e.getMessage());
        }
    }

    /**
     * @description Builds a map of field names to their Ramp IDs from existing custom fields
     * @return Map<String, String> Field name to Ramp ID mapping
     */
    private static Map<String, String> getFieldNameToRampIdMap() {
        Map<String, String> fieldMap = new Map<String, String>();

        try {
            HttpResponse res = RampAPIService.get('/developer/v1/accounting/fields');

            if (res.getStatusCode() == 200) {
                Object parsed = JSON.deserializeUntyped(res.getBody());
                List<Object> fields;

                if (parsed instanceof List<Object>) {
                    fields = (List<Object>) parsed;
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> responseMap = (Map<String, Object>) parsed;
                    fields = responseMap.containsKey('data')
                        ? (List<Object>) responseMap.get('data')
                        : new List<Object>();
                } else {
                    fields = new List<Object>();
                }

                for (Object field : fields) {
                    Map<String, Object> fieldMap2 = (Map<String, Object>) field;
                    // Only include active fields
                    Object isActive = fieldMap2.get('is_active');
                    if (isActive == null || isActive == true) {
                        String name = (String) fieldMap2.get('name');
                        String rampId = (String) fieldMap2.get('ramp_id');
                        if (String.isNotBlank(name) && String.isNotBlank(rampId)) {
                            fieldMap.put(name, rampId);
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug('Error getting field map: ' + e.getMessage());
        }

        return fieldMap;
    }

    /**
     * @description Saves credential configuration
     * Note: This method provides instructions for manual deployment
     * Automated Custom Metadata deployment requires Metadata API and cannot be done directly from Apex in the UI
     *
     * @param credential The credential data to save
     * @return String Instructions for deploying the metadata
     */
    @AuraEnabled
    public static String saveCredential(CredentialWrapper credential) {
        try {
            // Validate inputs
            if (String.isBlank(credential.developerName)) {
                throw new AuraHandledException('Developer Name is required');
            }
            if (String.isBlank(credential.clientId)) {
                throw new AuraHandledException('Client ID is required');
            }
            if (String.isBlank(credential.clientSecret)) {
                throw new AuraHandledException('Client Secret is required');
            }

            // Generate the Custom Metadata XML
            String metadataXml = generateMetadataXml(credential);

            // Since we can't deploy directly from Apex in Lightning, return instructions
            String instructions = 'To deploy this configuration:\n\n';
            instructions += '1. Create a file: force-app/main/default/customMetadata/Ramp_Credential.' +
                           credential.developerName + '.md-meta.xml\n';
            instructions += '2. Use the following content:\n\n' + metadataXml + '\n\n';
            instructions += '3. Deploy using: sf project deploy start --source-dir force-app/main/default/customMetadata\n\n';
            instructions += 'Alternatively, you can update the Custom Metadata directly in Setup > Custom Metadata Types.';

            return instructions;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving credential: ' + e.getMessage());
        }
    }

    /**
     * @description Generates the XML content for Custom Metadata deployment
     * @param credential The credential data
     * @return String The XML content
     */
    private static String generateMetadataXml(CredentialWrapper credential) {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xml += '<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" ';
        xml += 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ';
        xml += 'xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n';
        xml += '    <label>' + escapeXml(credential.label) + '</label>\n';
        xml += '    <protected>false</protected>\n';

        if (String.isNotBlank(credential.clientId)) {
            xml += '    <values>\n';
            xml += '        <field>Client_ID__c</field>\n';
            xml += '        <value xsi:type="xsd:string">' + escapeXml(credential.clientId) + '</value>\n';
            xml += '    </values>\n';
        }

        if (String.isNotBlank(credential.clientSecret)) {
            xml += '    <values>\n';
            xml += '        <field>Client_Secret__c</field>\n';
            xml += '        <value xsi:type="xsd:string">' + escapeXml(credential.clientSecret) + '</value>\n';
            xml += '    </values>\n';
        }

        if (String.isNotBlank(credential.tokenUrl)) {
            xml += '    <values>\n';
            xml += '        <field>Token_URL__c</field>\n';
            xml += '        <value xsi:type="xsd:string">' + escapeXml(credential.tokenUrl) + '</value>\n';
            xml += '    </values>\n';
        }

        if (String.isNotBlank(credential.apiBaseUrl)) {
            xml += '    <values>\n';
            xml += '        <field>API_Base_URL__c</field>\n';
            xml += '        <value xsi:type="xsd:string">' + escapeXml(credential.apiBaseUrl) + '</value>\n';
            xml += '    </values>\n';
        }

        if (String.isNotBlank(credential.scopes)) {
            xml += '    <values>\n';
            xml += '        <field>Scopes__c</field>\n';
            xml += '        <value xsi:type="xsd:string">' + escapeXml(credential.scopes) + '</value>\n';
            xml += '    </values>\n';
        }

        xml += '    <values>\n';
        xml += '        <field>Is_Active__c</field>\n';
        xml += '        <value xsi:type="xsd:boolean">' + credential.isActive + '</value>\n';
        xml += '    </values>\n';

        xml += '</CustomMetadata>';

        return xml;
    }

    /**
     * @description Retrieves all custom accounting fields from Ramp
     * @return List<Map<String, Object>> List of custom field data
     */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getRampCustomFields() {
        try {
            HttpResponse res = RampAPIService.get('/developer/v1/accounting/fields');

            if (res.getStatusCode() == 200) {
                Object parsed = JSON.deserializeUntyped(res.getBody());

                // Handle both array and object with 'data' key
                List<Object> fields;
                if (parsed instanceof List<Object>) {
                    fields = (List<Object>) parsed;
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> responseMap = (Map<String, Object>) parsed;
                    if (responseMap.containsKey('data')) {
                        fields = (List<Object>) responseMap.get('data');
                    } else {
                        fields = new List<Object>();
                    }
                } else {
                    fields = new List<Object>();
                }

                List<Map<String, Object>> result = new List<Map<String, Object>>();
                for (Object field : fields) {
                    Map<String, Object> fieldMap = (Map<String, Object>) field;
                    // Filter out soft-deleted fields (is_active = false)
                    Object isActive = fieldMap.get('is_active');
                    if (isActive == null || isActive == true) {
                        result.add(fieldMap);
                    }
                }
                return result;
            } else {
                throw new AuraHandledException('Failed to retrieve custom fields. Status: ' + res.getStatusCode());
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving custom fields: ' + e.getMessage());
        }
    }

    /**
     * @description Updates a custom accounting field in Ramp
     * @param fieldId The Ramp internal field ID (ramp_id from the field object)
     * @param name The new name (optional)
     * @param displayName The new display name (optional)
     * @return String Success message
     */
    @AuraEnabled
    public static String updateRampCustomField(String fieldId, String name, String displayName) {
        try {
            Map<String, Object> requestBody = new Map<String, Object>();

            if (String.isNotBlank(name)) {
                requestBody.put('name', name);
            }
            if (String.isNotBlank(displayName)) {
                requestBody.put('display_name', displayName);
            }

            if (requestBody.isEmpty()) {
                throw new AuraHandledException('At least one field (name or display_name) must be provided');
            }

            String body = JSON.serialize(requestBody);
            HttpResponse res = RampAPIService.patch('/developer/v1/accounting/fields/' + fieldId, body);

            if (res.getStatusCode() == 200) {
                return 'Custom field updated successfully';
            } else {
                throw new AuraHandledException('Failed to update custom field. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody());
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error updating custom field: ' + e.getMessage());
        }
    }

    /**
     * @description Deletes a custom accounting field from Ramp
     * @param rampId The Ramp internal field ID (ramp_id from the field object)
     * @return String Success message
     */
    @AuraEnabled
    public static String deleteRampCustomField(String rampId) {
        try {
            HttpResponse res = RampAPIService.doDelete('/developer/v1/accounting/fields/' + rampId);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 204) {
                return 'Custom field deleted successfully';
            } else {
                throw new AuraHandledException('Failed to delete custom field. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody());
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting custom field: ' + e.getMessage());
        }
    }

    /**
     * @description Escapes XML special characters
     * @param input The input string
     * @return String The escaped string
     */
    private static String escapeXml(String input) {
        if (String.isBlank(input)) {
            return input;
        }
        return input.replace('&', '&amp;')
                    .replace('<', '&lt;')
                    .replace('>', '&gt;')
                    .replace('"', '&quot;')
                    .replace('\'', '&apos;');
    }
}