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
     * @description Kicks off the batch job that syncs vendor Accounts to Ramp.
     * Independent of the GL-account and accounting-variable syncs.
     * @return String Job Id and status message
     */
    @AuraEnabled
    public static String syncVendors() {
        try {
            // RampVendorSyncBatch() resolves the accounting connection itself.
            Id jobId = Database.executeBatch(new RampVendorSyncBatch(), 50);
            return 'Vendor sync started. Job Id: ' + jobId +
                '. Creates/updates Ramp vendors from vendor Accounts and logs an Automated Job Result.';
        } catch (Exception e) {
            throw new AuraHandledException('Error starting vendor sync: ' + e.getMessage());
        }
    }

    /**
     * @description Builds a map of field names to their Ramp IDs from existing custom fields
     * @return Map<String, String> Field name to Ramp ID mapping
     */
    private static Map<String, String> getFieldNameToRampIdMap() {
        Map<String, String> fieldMap = new Map<String, String>();
        String nextPage = null;

        try {
            do {
                String endpoint = '/developer/v1/accounting/fields';
                if (String.isNotBlank(nextPage)) {
                    endpoint += '?start=' + nextPage;
                }

                HttpResponse res = RampAPIService.get(endpoint);

                if (res.getStatusCode() != 200) {
                    System.debug('Error fetching accounting fields page: ' + res.getStatusCode() + ' - ' + res.getBody());
                    break;
                }

                Object parsed = JSON.deserializeUntyped(res.getBody());
                List<Object> fields;

                if (parsed instanceof List<Object>) {
                    fields = (List<Object>) parsed;
                    nextPage = null;
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> responseMap = (Map<String, Object>) parsed;
                    fields = responseMap.containsKey('data')
                        ? (List<Object>) responseMap.get('data')
                        : new List<Object>();

                    if (responseMap.containsKey('page')) {
                        Map<String, Object> page = (Map<String, Object>) responseMap.get('page');
                        nextPage = (String) page.get('next');
                    } else {
                        nextPage = null;
                    }
                } else {
                    fields = new List<Object>();
                    nextPage = null;
                }

                for (Object field : fields) {
                    Map<String, Object> fieldData = (Map<String, Object>) field;
                    Object isActive = fieldData.get('is_active');
                    if (isActive == null || isActive == true) {
                        String name = (String) fieldData.get('name');
                        String rampId = (String) fieldData.get('ramp_id');
                        if (String.isNotBlank(name) && String.isNotBlank(rampId)) {
                            fieldMap.put(name, rampId);
                        }
                    }
                }
            } while (String.isNotBlank(nextPage));
        } catch (Exception e) {
            System.debug('Error getting field map: ' + e.getMessage());
        }

        return fieldMap;
    }

    /**
     * @description Saves credential configuration by enqueueing a Metadata API
     * deployment that upserts the Ramp_Credential__mdt record in place.
     * Requires the running user to have Modify Metadata Through Metadata API
     * (or Customize Application).
     *
     * @param credential A map of credential fields from the LWC (developerName,
     *        label, clientId, clientSecret, tokenUrl, apiBaseUrl, scopes, isActive).
     *        A Map<String,Object> is used rather than a custom Apex class because
     *        Aura/LWC cannot reliably marshal a JS object into an inner Apex class
     *        parameter — that fails as a generic "internal server error" before
     *        the method body runs. A Map marshals cleanly.
     * @return String Success message including the deployment job Id
     */
    @AuraEnabled
    public static String saveCredential(Map<String, Object> credential) {
        try {
            String developerName = strVal(credential, 'developerName');
            String clientId = strVal(credential, 'clientId');
            String clientSecret = strVal(credential, 'clientSecret');
            if (String.isBlank(developerName)) {
                throw new AuraHandledException('Developer Name is required');
            }
            if (String.isBlank(clientId)) {
                throw new AuraHandledException('Client ID is required');
            }
            if (String.isBlank(clientSecret)) {
                throw new AuraHandledException('Client Secret is required');
            }
            String label = strVal(credential, 'label');
            String tokenUrl = strVal(credential, 'tokenUrl');
            String apiBaseUrl = strVal(credential, 'apiBaseUrl');
            String scopes = strVal(credential, 'scopes');
            Boolean isActive = credential.get('isActive') == true;

            // Clear the cached token — once the new credential lands, the next
            // API call should re-OAuth using the updated client id/secret.
            RampAuthService.clearCachedToken();

            // Deploy the CMDT record from a Queueable so the metadata deployment
            // runs async and doesn't block the save round-trip. Skip in tests
            // (the Metadata API can't deploy in an @IsTest context).
            if (Test.isRunningTest()) {
                return 'Credential validated (test mode — deployment skipped).';
            }
            Id jobId = System.enqueueJob(new RampCredentialDeployQueueable(
                developerName, String.isBlank(label) ? developerName : label,
                clientId, clientSecret, tokenUrl, apiBaseUrl, scopes, isActive
            ));
            return 'Credential save submitted. Deployment Job Id: ' + jobId +
                ' — the new values will be live within a few seconds. ' +
                'Refresh this page to see them and try Test Connection.';
        } catch (Exception e) {
            throw new AuraHandledException('Error saving credential: ' + e.getMessage());
        }
    }

    private static String strVal(Map<String, Object> m, String key) {
        Object v = m.get(key);
        return v == null ? null : String.valueOf(v);
    }

    /**
     * @description Retrieves all custom accounting fields from Ramp
     * @return List<Map<String, Object>> List of custom field data
     */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getRampCustomFields() {
        try {
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            String nextPage = null;

            do {
                String endpoint = '/developer/v1/accounting/fields';
                if (String.isNotBlank(nextPage)) {
                    endpoint += '?start=' + nextPage;
                }

                HttpResponse res = RampAPIService.get(endpoint);

                if (res.getStatusCode() != 200) {
                    throw new AuraHandledException('Failed to retrieve custom fields. Status: ' + res.getStatusCode());
                }

                Object parsed = JSON.deserializeUntyped(res.getBody());

                List<Object> fields;
                if (parsed instanceof List<Object>) {
                    fields = (List<Object>) parsed;
                    nextPage = null;
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> responseMap = (Map<String, Object>) parsed;
                    fields = responseMap.containsKey('data')
                        ? (List<Object>) responseMap.get('data')
                        : new List<Object>();

                    if (responseMap.containsKey('page')) {
                        Map<String, Object> page = (Map<String, Object>) responseMap.get('page');
                        nextPage = (String) page.get('next');
                    } else {
                        nextPage = null;
                    }
                } else {
                    fields = new List<Object>();
                    nextPage = null;
                }

                for (Object field : fields) {
                    Map<String, Object> fieldData = (Map<String, Object>) field;
                    Object isActive = fieldData.get('is_active');
                    if (isActive == null || isActive == true) {
                        result.add(fieldData);
                    }
                }
            } while (String.isNotBlank(nextPage));

            return result;
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
     * @description Enqueues the card-transaction sync — starts a chained Queueable that
     * fetches one page of SYNC_READY transactions, builds Journal Entries,
     * and POSTs the sync acknowledgment back to Ramp.
     * @return String The Apex Job Id and a short status message
     */
    @AuraEnabled
    public static String syncTransactions() {
        try {
            Id jobId = System.enqueueJob(new RampTransactionSyncQueueable());
            return 'Transaction sync started. Job Id: ' + jobId +
                '. The job will drain all SYNC_READY transactions across pages and ' +
                'POST sync acknowledgements back to Ramp.';
        } catch (Exception e) {
            throw new AuraHandledException('Error starting transaction sync: ' + e.getMessage());
        }
    }

    /**
     * @description Kicks off the bill sync — bills → Account Payables (+ payments).
     */
    @AuraEnabled
    public static String syncBills() {
        try {
            Id jobId = System.enqueueJob(new RampBillSyncQueueable());
            return 'Bill sync started. Job Id: ' + jobId +
                '. Drains sync-ready bills across pages, creating Payables (and Cash Disbursements for paid bills).';
        } catch (Exception e) {
            throw new AuraHandledException('Error starting bill sync: ' + e.getMessage());
        }
    }

    /**
     * @description Kicks off the reimbursement sync — reimbursements → employee Payables (+ payments).
     */
    @AuraEnabled
    public static String syncReimbursements() {
        try {
            Id jobId = System.enqueueJob(new RampReimbursementSyncQueueable());
            return 'Reimbursement sync started. Job Id: ' + jobId +
                '. Drains SYNC_READY reimbursements across pages, creating employee Payables.';
        } catch (Exception e) {
            throw new AuraHandledException('Error starting reimbursement sync: ' + e.getMessage());
        }
    }

    /**
     * @description Aggregate stats for the Transactions tab in the LWC.
     * @return Map of Pending/Synced_To_Ramp/Failed counts (and total) over
     * Journal Entries that originated from Ramp (Ramp_Sync_Status__c not null).
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Integer> getTransactionSyncStats() {
        try {
            Map<String, Integer> stats = new Map<String, Integer>{
                'pending' => 0,
                'synced' => 0,
                'failed' => 0,
                'total' => 0
            };
            for (AggregateResult ar : [
                SELECT Ramp_Sync_Status__c status, COUNT(Id) c
                FROM AcctSeed__Journal_Entry__c
                WHERE Ramp_Sync_Status__c != null
                GROUP BY Ramp_Sync_Status__c
            ]) {
                String status = (String) ar.get('status');
                Integer c = (Integer) ar.get('c');
                stats.put('total', stats.get('total') + c);
                if (status == 'Pending') stats.put('pending', c);
                else if (status == 'Synced_To_Ramp') stats.put('synced', c);
                else if (status == 'Failed') stats.put('failed', c);
            }
            return stats;
        } catch (Exception e) {
            throw new AuraHandledException('Error getting transaction sync stats: ' + e.getMessage());
        }
    }

    /**
     * @description Returns the most recent JE failures for surfacing in the
     * LWC error queue. Limited to 50 rows; sorted newest first.
     */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getRecentTransactionFailures() {
        try {
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            for (AcctSeed__Journal_Entry__c je : [
                SELECT Id, Name, AcctSeed__ExtId__c, AcctSeed__Journal_Date__c,
                       AcctSeed__Reference__c, Ramp_Sync_Error__c, LastModifiedDate
                FROM AcctSeed__Journal_Entry__c
                WHERE Ramp_Sync_Status__c = 'Failed'
                ORDER BY LastModifiedDate DESC
                LIMIT 50
            ]) {
                rows.add(new Map<String, Object>{
                    'id' => je.Id,
                    'name' => je.Name,
                    'rampTransactionId' => je.AcctSeed__ExtId__c,
                    'date' => je.AcctSeed__Journal_Date__c,
                    'memo' => je.AcctSeed__Reference__c,
                    'error' => je.Ramp_Sync_Error__c,
                    'lastModifiedDate' => je.LastModifiedDate
                });
            }
            return rows;
        } catch (Exception e) {
            throw new AuraHandledException('Error getting recent failures: ' + e.getMessage());
        }
    }

    // ───────────────────── Reference Lookup config ─────────────────────

    public class ReferenceLookupConfig {
        @AuraEnabled public Boolean enabled { get; set; }
        @AuraEnabled public String template { get; set; }
    }

    /** @description Read the Reference Lookup toggle + key template for the config subtab. */
    @AuraEnabled(cacheable=true)
    public static ReferenceLookupConfig getReferenceLookupConfig() {
        ReferenceLookupConfig cfg = new ReferenceLookupConfig();
        cfg.enabled = RampSyncSettingsService.referenceLookupEnabled();
        cfg.template = RampSyncSettingsService.getReferenceKeyTemplate();
        return cfg;
    }

    /**
     * @description Save the Reference Lookup toggle + template. Reads the current
     * Default settings record and re-deploys it with only these two values
     * changed (a CMDT deploy replaces the record, so the rest must be preserved).
     */
    @AuraEnabled
    public static String saveReferenceLookupConfig(Boolean enabled, String template) {
        try {
            Ramp_Sync_Settings__mdt s = RampSyncSettingsService.getSettings();
            System.enqueueJob(new RampSyncSettingsDeployQueueable(
                s.Default_Ledger__c, s.Default_JE_Status__c, s.Sync_Grouping__c,
                s.Send_Sync_Ack__c, s.Vendor_Match_Requires_Payment_History__c,
                enabled, template));
            return 'Reference Lookup settings saved. Changes apply on the next sync.';
        } catch (Exception e) {
            throw new AuraHandledException('Could not save Reference Lookup settings: ' + e.getMessage());
        }
    }

}