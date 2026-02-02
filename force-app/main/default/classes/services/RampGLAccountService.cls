/**
 * @description Service class for syncing GL Accounts with Ramp
 */
public with sharing class RampGLAccountService {
    private static final Integer BATCH_SIZE = 500; // Ramp API limit

    /**
     * @description Wrapper class for GL Account data sent to Ramp
     */
    public class GLAccountWrapper {
        public String id { get; set; }
        public String name { get; set; }
        public String code { get; set; }
        public String classification { get; set; }
    }

    /**
     * @description Maps Accounting Seed GL Account Type to Ramp classification
     * @param acctSeedType The AcctSeed__Type__c value
     * @return String The Ramp classification value
     */
    private static String mapToRampClassification(String acctSeedType) {
        if (String.isBlank(acctSeedType)) {
            return 'EXPENSE';
        }

        String typeUpper = acctSeedType.toUpperCase();
        if (typeUpper.contains('REVENUE') || typeUpper.contains('INCOME')) {
            return 'REVENUE';
        } else if (typeUpper.contains('EXPENSE')) {
            return 'EXPENSE';
        } else if (typeUpper.contains('LIABILITY')) {
            return 'LIABILITY';
        } else if (typeUpper.contains('EQUITY')) {
            return 'EQUITY';
        } else if (typeUpper.contains('ASSET') || typeUpper.contains('BALANCE SHEET')) {
            return 'ASSET';
        }
        return 'EXPENSE'; // Default fallback
    }

    /**
     * @description Syncs all active GL Accounts to Ramp
     * @return String Summary message with sync results
     */
    public static String syncAllGLAccounts() {
        try {
            // Query all active GL Accounts
            List<AcctSeed__GL_Account__c> glAccounts = [
                SELECT Id, Name, AcctSeed__Bank__c, AcctSeed__Type__c,
                       AcctSeed__Active__c, Ramp_Id__c
                FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
                ORDER BY Name
            ];

            if (glAccounts.isEmpty()) {
                return 'No active GL Accounts found to sync.';
            }

            Integer totalSynced = 0;
            Integer totalBatches = (Integer) Math.ceil((Decimal) glAccounts.size() / BATCH_SIZE);

            // Process in batches of 500
            for (Integer i = 0; i < totalBatches; i++) {
                Integer startIdx = i * BATCH_SIZE;
                Integer endIdx = Math.min(startIdx + BATCH_SIZE, glAccounts.size());
                List<AcctSeed__GL_Account__c> batch = new List<AcctSeed__GL_Account__c>();

                for (Integer j = startIdx; j < endIdx; j++) {
                    batch.add(glAccounts[j]);
                }

                syncGLAccountBatch(batch);
                totalSynced += batch.size();
            }

            return 'Successfully synced ' + totalSynced + ' GL Account(s) to Ramp in ' +
                   totalBatches + ' batch(es).';
        } catch (Exception e) {
            throw new RampGLAccountException('Error syncing GL Accounts: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Syncs a batch of GL Accounts to Ramp
     * @param glAccounts List of GL Accounts to sync (max 500)
     */
    @TestVisible
    private static void syncGLAccountBatch(List<AcctSeed__GL_Account__c> glAccounts) {
        try {
            // Build request body
            List<GLAccountWrapper> accountsToSync = new List<GLAccountWrapper>();

            for (AcctSeed__GL_Account__c gl : glAccounts) {
                GLAccountWrapper wrapper = new GLAccountWrapper();
                wrapper.id = gl.Id;
                wrapper.name = gl.Name;
                wrapper.code = gl.Name; // Using Name as code; adjust if GL Account has a code field
                wrapper.classification = mapToRampClassification(gl.AcctSeed__Type__c);

                accountsToSync.add(wrapper);
            }

            // Wrap accounts in a dictionary as required by Ramp API
            Map<String, Object> requestBody = new Map<String, Object>{
                'gl_accounts' => accountsToSync
            };
            String body = JSON.serialize(requestBody);

            // Send to Ramp
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/accounts', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                // Parse response and update Ramp IDs
                updateRampIds(glAccounts, res.getBody());
            } else {
                throw new RampGLAccountException(
                    'Failed to sync GL Accounts. Status: ' + res.getStatusCode() +
                    ', Response: ' + res.getBody()
                );
            }
        } catch (Exception e) {
            throw new RampGLAccountException('Error in batch sync: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Updates GL Accounts with Ramp IDs from the response
     * @param glAccounts The GL Accounts that were synced
     * @param responseBody The JSON response from Ramp
     */
    private static void updateRampIds(List<AcctSeed__GL_Account__c> glAccounts, String responseBody) {
        try {
            // Parse response - Ramp may return object with gl_accounts array or just an array
            Object parsed = JSON.deserializeUntyped(responseBody);
            List<Object> syncedAccounts;

            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> responseMap = (Map<String, Object>) parsed;
                if (responseMap.containsKey('gl_accounts')) {
                    syncedAccounts = (List<Object>) responseMap.get('gl_accounts');
                } else {
                    // Response might be a single object or different structure
                    return;
                }
            } else if (parsed instanceof List<Object>) {
                syncedAccounts = (List<Object>) parsed;
            } else {
                return;
            }

            // Create a map of our ID to Ramp's returned ID
            Map<String, String> sfIdToRampId = new Map<String, String>();

            for (Object obj : syncedAccounts) {
                Map<String, Object> account = (Map<String, Object>) obj;
                // The 'id' we sent is our Salesforce ID, Ramp may return it back
                // along with their internal ID (could be in a different field)
                String ourId = (String) account.get('id');
                String rampId = (String) account.get('ramp_id');

                // If ramp_id not present, the 'id' field might be Ramp's ID
                // and our ID might be in a different field
                if (String.isBlank(rampId)) {
                    rampId = ourId;
                }

                if (String.isNotBlank(ourId) && String.isNotBlank(rampId)) {
                    sfIdToRampId.put(ourId, rampId);
                }
            }

            // Update GL Accounts with Ramp IDs
            List<AcctSeed__GL_Account__c> toUpdate = new List<AcctSeed__GL_Account__c>();

            for (AcctSeed__GL_Account__c gl : glAccounts) {
                if (sfIdToRampId.containsKey(gl.Id)) {
                    gl.Ramp_Id__c = sfIdToRampId.get(gl.Id);
                    toUpdate.add(gl);
                }
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
        } catch (Exception e) {
            // Log error but don't fail the entire sync
            System.debug('Error updating Ramp IDs: ' + e.getMessage());
        }
    }

    /**
     * @description Gets sync statistics
     * @return Map<String, Integer> Statistics about GL Account sync status
     */
    public static Map<String, Integer> getSyncStatistics() {
        Map<String, Integer> stats = new Map<String, Integer>();

        List<AggregateResult> results = [
            SELECT
                COUNT(Id) total,
                COUNT(Ramp_Id__c) synced
            FROM AcctSeed__GL_Account__c
            WHERE AcctSeed__Active__c = true
        ];

        if (!results.isEmpty()) {
            AggregateResult result = results[0];
            stats.put('total', (Integer) result.get('total'));
            stats.put('synced', (Integer) result.get('synced'));
            stats.put('not_synced', (Integer) result.get('total') - (Integer) result.get('synced'));
        }

        return stats;
    }

    /**
     * @description Custom exception for GL Account sync errors
     */
    public class RampGLAccountException extends Exception {}
}