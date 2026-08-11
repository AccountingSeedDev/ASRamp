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
                RampJobResultLogger.record(null, RampJobResultLogger.JOB_GL_SYNC, 0, 0, 0,
                    'No active GL Accounts found to sync.');
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

            // 3. POST only the truly new ones — all callouts first, collect ramp_id maps, NO DML yet.
            Integer created = 0;
            Integer totalBatches = 0;
            Map<String, String> allNewRampIds = new Map<String, String>();
            if (!toCreate.isEmpty()) {
                totalBatches = (Integer) Math.ceil((Decimal) toCreate.size() / BATCH_SIZE);
                for (Integer i = 0; i < totalBatches; i++) {
                    Integer startIdx = i * BATCH_SIZE;
                    Integer endIdx = Math.min(startIdx + BATCH_SIZE, toCreate.size());
                    List<AcctSeed__GL_Account__c> batch = new List<AcctSeed__GL_Account__c>();
                    for (Integer j = startIdx; j < endIdx; j++) batch.add(toCreate[j]);
                    allNewRampIds.putAll(syncGLAccountBatch(batch));
                    created += batch.size();
                }
            }

            // 4. All callouts done — now safe to do all DML.
            // Use partial-success DML (allOrNone=false) so write-back failures caused
            // by validation rules or sharing rules do not throw, which would roll back
            // the AJR insert and leave no audit trail of the run.
            List<AcctSeed__GL_Account__c> toWriteBack = new List<AcctSeed__GL_Account__c>();
            for (AcctSeed__GL_Account__c gl : toCreate) {
                String rampId = allNewRampIds.get(gl.Id);
                if (String.isNotBlank(rampId)) {
                    gl.Ramp_Id__c = rampId;
                    toWriteBack.add(gl);
                }
            }

            Integer writeBackOk = 0;
            Integer writeBackFailed = 0;
            List<String> writeBackErrors = new List<String>();
            if (!toWriteBack.isEmpty()) {
                List<Database.SaveResult> srs = Database.update(toWriteBack, false);
                for (Integer i = 0; i < srs.size(); i++) {
                    if (srs[i].isSuccess()) {
                        writeBackOk++;
                    } else {
                        writeBackFailed++;
                        List<Database.Error> errs = srs[i].getErrors();
                        String errMsg = errs.isEmpty() ? 'Unknown error' : errs[0].getMessage();
                        writeBackErrors.add(toWriteBack[i].Name + ': ' + errMsg);
                    }
                }
            }

            Integer restamped = 0;
            Integer restampFailed = 0;
            if (!toRestamp.isEmpty()) {
                List<Database.SaveResult> srs = Database.update(toRestamp, false);
                for (Integer i = 0; i < srs.size(); i++) {
                    if (srs[i].isSuccess()) {
                        restamped++;
                    } else {
                        restampFailed++;
                        List<Database.Error> errs = srs[i].getErrors();
                        String errMsg = errs.isEmpty() ? 'Unknown error' : errs[0].getMessage();
                        writeBackErrors.add('Restamp ' + toRestamp[i].Name + ': ' + errMsg);
                    }
                }
            }

            // Records Ramp accepted but whose ID was not echoed back — write-back impossible.
            Integer notStamped = toCreate.size() - toWriteBack.size();
            Integer totalFailed = notStamped + writeBackFailed + restampFailed;

            List<String> parts = new List<String>();
            if (writeBackOk > 0) parts.add('created ' + writeBackOk + ' (' + totalBatches + ' batch(es))');
            if (restamped > 0) parts.add('restored Ramp_Id__c on ' + restamped + ' existing record(s)');
            if (notStamped > 0) parts.add('WARNING: ' + notStamped + ' record(s) sent to Ramp but received no ID echo — Ramp_Id__c not stamped');
            if (writeBackFailed > 0) parts.add('ERROR: ' + writeBackFailed + ' Ramp_Id__c write-back failure(s) — GL Account created in Ramp but Salesforce record not updated');
            if (restampFailed > 0) parts.add('ERROR: ' + restampFailed + ' re-stamp failure(s) — Ramp_Id__c could not be saved to existing record(s)');
            if (parts.isEmpty()) parts.add('all GL Accounts already linked — nothing to do');
            String summary = 'GL Account sync complete: ' + String.join(parts, '; ') + '.';
            String notes = summary;
            if (!writeBackErrors.isEmpty()) {
                notes = RampJobResultLogger.appendNote(notes, 'Write-back errors:\n' + String.join(writeBackErrors, '\n'));
            }
            RampJobResultLogger.record(null, RampJobResultLogger.JOB_GL_SYNC,
                glAccounts.size(), writeBackOk + restamped, totalFailed, notes);
            return summary;
        } catch (Exception e) {
            RampJobResultLogger.record(null, RampJobResultLogger.JOB_GL_SYNC, 0, 0, 1,
                'GL Account sync failed: ' + e.getMessage());
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
                    if (String.isNotBlank(sfId) && String.isNotBlank(rampId)) {
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
     * @description Syncs a batch of GL Accounts to Ramp and returns the map of
     * Salesforce Id to Ramp Id parsed from the response. No DML is performed here.
     * @param glAccounts List of GL Accounts to sync (max 500)
     * @return Map of Salesforce Id to Ramp Id for each synced account
     */
    @TestVisible
    private static Map<String, String> syncGLAccountBatch(List<AcctSeed__GL_Account__c> glAccounts) {
        try {
            List<GLAccountWrapper> accountsToSync = new List<GLAccountWrapper>();

            for (AcctSeed__GL_Account__c gl : glAccounts) {
                GLAccountWrapper wrapper = new GLAccountWrapper();
                wrapper.id = gl.Id;
                wrapper.name = gl.Name;
                wrapper.code = gl.Id;
                wrapper.classification = mapToRampClassification(gl.AcctSeed__Type__c);
                accountsToSync.add(wrapper);
            }

            Map<String, Object> requestBody = new Map<String, Object>{
                'gl_accounts' => accountsToSync
            };
            String body = JSON.serialize(requestBody);

            HttpResponse res = RampAPIService.post('/developer/v1/accounting/accounts', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                return parseRampIds(res.getBody());
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
     * @description Parses the Ramp POST response and returns a map of
     * Salesforce Id (the "id" we sent) to Ramp Id. No DML is performed.
     * @param responseBody The JSON response from Ramp
     * @return Map of Salesforce Id to Ramp Id
     */
    private static Map<String, String> parseRampIds(String responseBody) {
        Map<String, String> sfIdToRampId = new Map<String, String>();
        try {
            Object parsed = JSON.deserializeUntyped(responseBody);
            List<Object> syncedAccounts;

            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> responseMap = (Map<String, Object>) parsed;
                if (responseMap.containsKey('gl_accounts')) {
                    syncedAccounts = (List<Object>) responseMap.get('gl_accounts');
                } else {
                    return sfIdToRampId;
                }
            } else if (parsed instanceof List<Object>) {
                syncedAccounts = (List<Object>) parsed;
            } else {
                return sfIdToRampId;
            }

            for (Object obj : syncedAccounts) {
                Map<String, Object> account = (Map<String, Object>) obj;
                String ourId = (String) account.get('id');
                String rampId = (String) account.get('ramp_id');
                if (String.isBlank(rampId)) {
                    rampId = ourId;
                }
                if (String.isNotBlank(ourId) && String.isNotBlank(rampId)) {
                    sfIdToRampId.put(ourId, rampId);
                }
            }
        } catch (Exception e) {
            throw new RampGLAccountException('Failed to parse Ramp response: ' + e.getMessage(), e);
        }
        return sfIdToRampId;
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

    public static List<AcctSeed__GL_Account__c> getUnsyncedGLAccounts() {
        return [
            SELECT Id, Name
            FROM AcctSeed__GL_Account__c
            WHERE AcctSeed__Active__c = true
            AND Ramp_Id__c = null
            ORDER BY Name
        ];
    }

    /**
     * @description Custom exception for GL Account sync errors
     */
    public class RampGLAccountException extends Exception {}
}