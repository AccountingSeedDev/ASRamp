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
     * @description Syncs all active GL Accounts to Ramp.
     *
     * Idempotent: first fetches every existing GL account already on Ramp and
     * splits the local list into "already there" vs "needs create."  The
     * already-there ones just have Ramp_Id__c re-stamped locally — no POST,
     * no duplicate-id 400. New ones are POSTed in batches of {@link #BATCH_SIZE}.
     * This makes the LWC button safe to click after a tenant switch or after
     * a manual local clear of Ramp_Id__c.
     */
    public static String syncAllGLAccounts() {
        try {
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

            // 1. Discover what's already on Ramp so we can skip duplicate POSTs.
            Map<String, String> existingByOurId = fetchExistingRampAccounts();

            // 2. Split into already-there (just re-stamp) vs. needs-create.
            List<AcctSeed__GL_Account__c> toCreate = new List<AcctSeed__GL_Account__c>();
            List<AcctSeed__GL_Account__c> toRestamp = new List<AcctSeed__GL_Account__c>();
            for (AcctSeed__GL_Account__c gl : glAccounts) {
                String rampId = existingByOurId.get(gl.Id);
                if (String.isBlank(rampId)) {
                    toCreate.add(gl);
                } else if (gl.Ramp_Id__c != rampId) {
                    gl.Ramp_Id__c = rampId;
                    toRestamp.add(gl);
                }
            }

            Integer restamped = 0;
            if (!toRestamp.isEmpty()) {
                update toRestamp;
                restamped = toRestamp.size();
            }

            // 3. POST only the truly new ones, in batches of BATCH_SIZE.
            Integer created = 0;
            Integer totalBatches = 0;
            if (!toCreate.isEmpty()) {
                totalBatches = (Integer) Math.ceil((Decimal) toCreate.size() / BATCH_SIZE);
                for (Integer i = 0; i < totalBatches; i++) {
                    Integer startIdx = i * BATCH_SIZE;
                    Integer endIdx = Math.min(startIdx + BATCH_SIZE, toCreate.size());
                    List<AcctSeed__GL_Account__c> batch = new List<AcctSeed__GL_Account__c>();
                    for (Integer j = startIdx; j < endIdx; j++) batch.add(toCreate[j]);

                    syncGLAccountBatch(batch);
                    created += batch.size();
                }
            }

            List<String> parts = new List<String>();
            if (created > 0) parts.add('created ' + created + ' (' + totalBatches + ' batch(es))');
            if (restamped > 0) parts.add('restored Ramp_Id__c on ' + restamped + ' existing record(s)');
            if (parts.isEmpty()) parts.add('all GL Accounts already linked — nothing to do');
            return 'GL Account sync complete: ' + String.join(parts, '; ') + '.';
        } catch (Exception e) {
            throw new RampGLAccountException('Error syncing GL Accounts: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Pulls every active GL account from Ramp and returns a map
     * keyed by the "id" we originally sent (= our Salesforce 18-char Id).
     */
    @TestVisible
    private static Map<String, String> fetchExistingRampAccounts() {
        Map<String, String> sfIdToRampId = new Map<String, String>();
        String nextStart = null;
        Integer pages = 0;

        do {
            String endpoint = '/developer/v1/accounting/accounts?page_size=100';
            if (String.isNotBlank(nextStart)) {
                endpoint += '&start=' + EncodingUtil.urlEncode(nextStart, 'UTF-8');
            }

            HttpResponse res = RampAPIService.get(endpoint);
            if (res.getStatusCode() != 200) {
                // Don't fail the whole sync — just proceed as if Ramp has nothing.
                System.debug(LoggingLevel.WARN,
                    'fetchExistingRampAccounts failed at page ' + pages +
                    ': ' + res.getStatusCode() + ' ' + res.getBody());
                break;
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> data = (List<Object>) body.get('data');
            if (data != null) {
                for (Object o : data) {
                    Map<String, Object> a = (Map<String, Object>) o;
                    String sfId = (String) a.get('id');
                    String rampId = (String) a.get('ramp_id');
                    Boolean isActive = (Boolean) a.get('is_active');
                    if (String.isNotBlank(sfId) && String.isNotBlank(rampId) && isActive == true) {
                        sfIdToRampId.put(sfId, rampId);
                    }
                }
            }

            nextStart = extractNextCursor(body);
            pages++;
        } while (String.isNotBlank(nextStart) && pages < 50);

        return sfIdToRampId;
    }

    /**
     * @description Pulls the cursor out of Ramp's page.next URL. Returns null
     * when there's no next page.
     */
    private static String extractNextCursor(Map<String, Object> body) {
        Map<String, Object> page = (Map<String, Object>) body.get('page');
        if (page == null) return null;
        String nextUrl = (String) page.get('next');
        if (String.isBlank(nextUrl)) return null;
        Integer i = nextUrl.indexOf('start=');
        if (i < 0) return null;
        String cursor = nextUrl.substring(i + 6);
        Integer amp = cursor.indexOf('&');
        if (amp >= 0) cursor = cursor.substring(0, amp);
        return cursor;
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