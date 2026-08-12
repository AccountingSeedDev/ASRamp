/**
 * @description Orchestrates one page of card-transaction work — fetch SYNC_READY Ramp
 * card transactions, transform into grouped Journal Entries via
 * RampJournalEntryBuilder, upsert headers + lines, and POST the result to
 * /developer/v1/accounting/syncs.
 *
 * One call to {@link #syncPage} = one page of up to 100 transactions.
 * Returns the next-page cursor (or null when the queue is drained); the
 * Queueable chain reads that value to decide whether to enqueue itself again.
 *
 * Grouping (Ramp_Sync_Settings__mdt.Sync_Grouping__c) collapses many
 * transactions into fewer JE headers. Headers are keyed (AcctSeed__ExtId__c)
 * by date or accounting period, and lines stay keyed by Ramp txn id — so any
 * page of any run upserts into the same Daily/Period JE and re-runs are clean.
 */
public with sharing class RampTransactionService {

    private static final Integer PAGE_SIZE = 100;
    private static final String SYNC_TYPE_TRANSACTION = 'TRANSACTION_SYNC';

    public class PageResult {
        public Integer transactionsFetched = 0;
        public Integer journalEntriesCreated = 0;
        public Integer journalEntriesUpdated = 0;
        public Integer failedCount = 0;
        // Counted from transactions that actually reached a persisted Journal Entry —
        // never inferred as (fetched - failed), which reports a silently dropped
        // transaction as a success (FS-15031).
        public Integer succeededCount = 0;
        public String nextCursor;
        public Boolean isLastPage { get { return String.isBlank(nextCursor); } set; }
        public List<String> errorMessages = new List<String>();
    }

    /**
     * @description A fresh UUID. Not used for grouping — kept as a uniqueness
     * helper (e.g. RampHomeController scheduled-job names).
     */
    public static String newRunId() {
        return generateUuid();
    }

    /**
     * @description Fetch one page, build grouped JEs, DML, POST sync ack.
     * Idempotent — safe to retry the same cursor on transient failure.
     * @param startCursor null for page 1; otherwise the previous PageResult's nextCursor.
     */
    public static PageResult syncPage(String startCursor) {
        PageResult result = new PageResult();

        // 1. Fetch one page of SYNC_READY transactions.
        TransactionPageResponse page = fetchPage(startCursor);
        // page.next is a full URL — keep only its `start` token (same handling
        // as RampBillService / RampReimbursementService; passing the raw URL
        // back as `start` makes Ramp reject page 2 and kills the chain).
        result.nextCursor = page.page != null ? extractStartCursor(page.page.next) : null;

        List<RampJournalEntryBuilder.RampTransaction> transactions = page.data != null
            ? page.data
            : new List<RampJournalEntryBuilder.RampTransaction>();
        result.transactionsFetched = transactions.size();

        if (transactions.isEmpty()) {
            return result;
        }

        // 2. Build grouped JE(s) + lines. Resolve cardholder emails first
        //    (card_holder carries only user_id; email lives on the Users API).
        String grouping = RampSyncSettingsService.getSyncGrouping();
        Map<String, String> emailByUserId = fetchCardholderEmails(transactions);
        RampJournalEntryBuilder.BuildResult build = RampJournalEntryBuilder.build(
            transactions, grouping, emailByUserId, page.rawByTxnId);

        // 3. Upsert one header per group via AcctSeed__ExtId__c (the group key).
        List<AcctSeed__Journal_Entry__c> headers = new List<AcctSeed__Journal_Entry__c>();
        for (RampJournalEntryBuilder.JournalEntryBuild jeb : build.successful) {
            headers.add(jeb.header);
        }

        Map<String, String> headerFailureByExtId = new Map<String, String>(); // groupKey -> error
        if (!headers.isEmpty()) {
            Schema.SObjectField extIdField = AcctSeed__Journal_Entry__c.AcctSeed__ExtId__c;
            Database.UpsertResult[] upsertResults = Database.upsert(headers, extIdField, false);

            for (Integer i = 0; i < upsertResults.size(); i++) {
                Database.UpsertResult ur = upsertResults[i];
                if (!ur.isSuccess()) {
                    headerFailureByExtId.put(headers[i].AcctSeed__ExtId__c, formatDmlErrors(ur.getErrors()));
                } else if (ur.isCreated()) {
                    result.journalEntriesCreated++;
                } else {
                    result.journalEntriesUpdated++;
                }
            }
        }

        // 4. Upsert lines (only for groups whose header succeeded).
        List<AcctSeed__Journal_Entry_Line__c> linesToUpsert = new List<AcctSeed__Journal_Entry_Line__c>();
        for (RampJournalEntryBuilder.JournalEntryBuild jeb : build.successful) {
            if (headerFailureByExtId.containsKey(jeb.headerExtId)) continue;
            for (AcctSeed__Journal_Entry_Line__c line : jeb.lines) {
                line.AcctSeed__Journal_Entry__c = jeb.header.Id;
                linesToUpsert.add(line);
            }
        }

        Map<String, String> lineFailureByTxn = new Map<String, String>(); // txnId -> error
        if (!linesToUpsert.isEmpty()) {
            Schema.SObjectField lineExtField = AcctSeed__Journal_Entry_Line__c.AcctSeed__ExtId__c;
            Database.UpsertResult[] lineResults = Database.upsert(linesToUpsert, lineExtField, false);

            for (Integer i = 0; i < lineResults.size(); i++) {
                Database.UpsertResult ur = lineResults[i];
                if (!ur.isSuccess()) {
                    String extId = linesToUpsert[i].AcctSeed__ExtId__c;
                    String txnId = extId != null && extId.contains(':') ? extId.substringBefore(':') : extId;
                    lineFailureByTxn.put(txnId, formatDmlErrors(ur.getErrors()));
                }
            }
        }

        // 5. Build ack payload + decide which JEs the async step should flip.
        List<Map<String, Object>> successfulSyncs = new List<Map<String, Object>>();
        List<Map<String, Object>> failedSyncs = new List<Map<String, Object>>();
        Set<Id> jeIdsToFlip = new Set<Id>();
        List<AcctSeed__Journal_Entry__c> statusUpdates = new List<AcctSeed__Journal_Entry__c>();

        // Build-time failures (bad date, no period, unresolved GL) — never persisted.
        for (String txnId : build.failed.keySet()) {
            String reason = build.failed.get(txnId);
            failedSyncs.add(new Map<String, Object>{
                'id' => txnId,
                'error' => new Map<String, Object>{ 'message' => reason }
            });
            result.failedCount++;
            result.errorMessages.add(txnId + ': ' + reason);
        }

        for (RampJournalEntryBuilder.JournalEntryBuild jeb : build.successful) {
            String hdrReason = headerFailureByExtId.get(jeb.headerExtId);
            Boolean anySuccessInGroup = false;

            for (String txnId : jeb.rampTransactionIds) {
                String reason = (hdrReason != null) ? hdrReason : lineFailureByTxn.get(txnId);
                if (reason != null) {
                    failedSyncs.add(new Map<String, Object>{
                        'id' => txnId,
                        'error' => new Map<String, Object>{ 'message' => reason }
                    });
                    result.failedCount++;
                    result.errorMessages.add(txnId + ': ' + reason);
                } else {
                    successfulSyncs.add(new Map<String, Object>{
                        'id' => txnId,
                        'reference_id' => String.valueOf(jeb.header.Id)
                    });
                    anySuccessInGroup = true;
                }
            }

            if (jeb.header.Id != null) {
                if (anySuccessInGroup) {
                    // The Journal Entry is posted, so record that now instead of
                    // waiting on the ack. Send_Sync_Ack__c is off by default, so
                    // gating the status on the ack left every JE at "Pending" and
                    // the home dashboard reporting 0 synced (FS-15109).
                    statusUpdates.add(new AcctSeed__Journal_Entry__c(
                        Id = jeb.header.Id,
                        Ramp_Sync_Status__c = 'Synced_To_Ramp',
                        Ramp_Sync_Error__c = null
                    ));
                    jeIdsToFlip.add(jeb.header.Id);
                } else {
                    // Header persisted but every line failed — mark it Failed now.
                    statusUpdates.add(new AcctSeed__Journal_Entry__c(
                        Id = jeb.header.Id,
                        Ramp_Sync_Status__c = 'Failed',
                        Ramp_Sync_Error__c = truncate('All transaction lines failed to upsert', 1000)
                    ));
                }
            }
        }

        if (!statusUpdates.isEmpty()) {
            Database.update(statusUpdates, false);
        }

        // Success is counted, not inferred. Anything fetched that produced neither a
        // Journal Entry nor a recorded failure is a silent drop — report it rather
        // than let it inflate the success count and show a clean run (FS-15031).
        result.succeededCount = successfulSyncs.size();
        Integer unaccounted = result.transactionsFetched - result.succeededCount - result.failedCount;
        if (unaccounted > 0) {
            result.failedCount += unaccounted;
            result.errorMessages.add(unaccounted + ' transaction(s) were returned by Ramp but produced ' +
                'neither a Journal Entry nor an error. This is a defect in the sync — please report it ' +
                'with the run date so the transactions can be identified.');
        }

        // 6. Fire the /accounting/syncs POST async so it runs after this
        //    transaction's DML commits — Salesforce forbids callouts after DML.
        //    Skippable via Send_Sync_Ack__c so transactions can be left
        //    SYNC_READY in Ramp for repeatable testing; the JEs are already marked
        //    "Synced_To_Ramp" above either way.
        if ((!successfulSyncs.isEmpty() || !failedSyncs.isEmpty()) && RampSyncSettingsService.getSendSyncAck()) {
            postSyncAcksAsync(
                JSON.serialize(successfulSyncs),
                JSON.serialize(failedSyncs),
                JSON.serialize(new List<Id>(jeIdsToFlip))
            );
        }

        return result;
    }

    /**
     * @description Async ack — POSTs /accounting/syncs. The grouped JE headers are
     * already "Synced_To_Ramp" (stamped when they posted), so this only downgrades
     * them to "Failed" when the ack doesn't land and Ramp is left unaware of them.
     */
    @future(callout=true)
    @TestVisible
    private static void postSyncAcksAsync(String successfulSyncsJson, String failedSyncsJson, String jeIdsJson) {
        List<Object> successfulSyncs = (List<Object>) JSON.deserializeUntyped(successfulSyncsJson);
        List<Object> failedSyncs = (List<Object>) JSON.deserializeUntyped(failedSyncsJson);

        if (successfulSyncs.isEmpty() && failedSyncs.isEmpty()) return;

        Map<String, Object> body = new Map<String, Object>{
            'idempotency_key' => generateUuid(),
            'sync_type' => SYNC_TYPE_TRANSACTION
        };
        if (!successfulSyncs.isEmpty()) body.put('successful_syncs', successfulSyncs);
        if (!failedSyncs.isEmpty()) body.put('failed_syncs', failedSyncs);

        Boolean ackSucceeded = false;
        String errorMessage = null;
        try {
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/syncs', JSON.serialize(body));
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                ackSucceeded = true;
            } else {
                errorMessage = '/accounting/syncs returned ' + res.getStatusCode() + ': ' + res.getBody();
            }
        } catch (Exception e) {
            errorMessage = 'POST /accounting/syncs failed: ' + e.getMessage();
        }

        // Nothing to do on success — the JEs were stamped "Synced_To_Ramp" when they
        // posted. Only a failed ack changes anything: Ramp doesn't know about these
        // Journal Entries, so surface that on the records.
        if (ackSucceeded) return;

        List<Object> rawIds = (List<Object>) JSON.deserializeUntyped(jeIdsJson);
        Set<Id> jeIds = new Set<Id>();
        for (Object o : rawIds) {
            if (o != null) jeIds.add((Id) (String) o);
        }
        if (jeIds.isEmpty()) return;

        List<AcctSeed__Journal_Entry__c> jes = [
            SELECT Id, Ramp_Sync_Status__c
            FROM AcctSeed__Journal_Entry__c
            WHERE Id IN :jeIds AND Ramp_Sync_Status__c = 'Synced_To_Ramp'
        ];
        for (AcctSeed__Journal_Entry__c je : jes) {
            je.Ramp_Sync_Status__c = 'Failed';
            je.Ramp_Sync_Error__c = truncate(errorMessage, 1000);
        }
        if (!jes.isEmpty()) {
            Database.update(jes, false);
        }
    }

    // --------------------------------------------------------------------
    //  HTTP
    // --------------------------------------------------------------------

    @TestVisible
    private static TransactionPageResponse fetchPage(String startCursor) {
        String endpoint = '/developer/v1/transactions?sync_status=SYNC_READY&page_size=' + PAGE_SIZE;
        if (String.isNotBlank(startCursor)) {
            endpoint += '&start=' + EncodingUtil.urlEncode(startCursor, 'UTF-8');
        }

        HttpResponse res = RampAPIService.get(endpoint);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new RampTransactionServiceException(
                'Failed to fetch transactions. Status: ' + res.getStatusCode() +
                ', Body: ' + res.getBody()
            );
        }
        try {
            TransactionPageResponse parsed =
                (TransactionPageResponse) JSON.deserialize(res.getBody(), TransactionPageResponse.class);
            // JSON.deserialize skips field initializers, so the transient map is null here.
            if (parsed.rawByTxnId == null) parsed.rawByTxnId = new Map<String, Object>();
            // Stash raw attributes per txn id for the Reference Lookup template.
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Object rawData = body.get('data');
            if (rawData instanceof List<Object>) {
                for (Object o : (List<Object>) rawData) {
                    Map<String, Object> txn = (Map<String, Object>) o;
                    Object id = txn.get('id');
                    if (id != null) parsed.rawByTxnId.put(String.valueOf(id), txn);
                }
            }
            return parsed;
        } catch (Exception e) {
            throw new RampTransactionServiceException(
                'Failed to parse transactions response: ' + e.getMessage() +
                '. Body: ' + res.getBody()
            );
        }
    }


    // --------------------------------------------------------------------
    //  Helpers
    // --------------------------------------------------------------------

    /**
     * @description Resolve the distinct cardholder user_ids on this page to
     * emails via GET /developer/v1/users/{id}. card_holder carries only user_id;
     * email lives on the User resource. Per-id fetch keeps callouts proportional
     * to distinct cardholders on the page (typically a handful), not org size.
     * Failures are swallowed per-user — a missing email just leaves the line's
     * email/employee blank rather than failing the whole page.
     */
    @TestVisible
    private static Map<String, String> fetchCardholderEmails(List<RampJournalEntryBuilder.RampTransaction> transactions) {
        Set<String> userIds = new Set<String>();
        for (RampJournalEntryBuilder.RampTransaction txn : transactions) {
            if (txn.card_holder != null && String.isNotBlank(txn.card_holder.user_id)) {
                userIds.add(txn.card_holder.user_id);
            }
        }
        Map<String, String> emailByUserId = new Map<String, String>();
        for (String userId : userIds) {
            try {
                HttpResponse res = RampAPIService.get('/developer/v1/users/' + EncodingUtil.urlEncode(userId, 'UTF-8'));
                if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) continue;
                Map<String, Object> u = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                Object email = u.get('email');
                if (email != null) emailByUserId.put(userId, String.valueOf(email));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Ramp user email fetch failed for ' + userId + ': ' + e.getMessage());
            }
        }
        return emailByUserId;
    }

    /** @description Pull the `start` token out of Ramp's full next-page URL. */
    @TestVisible
    private static String extractStartCursor(String nextUrl) {
        if (String.isBlank(nextUrl)) return null;
        Integer i = nextUrl.indexOf('start=');
        if (i < 0) return null;
        String cursor = nextUrl.substring(i + 6);
        Integer amp = cursor.indexOf('&');
        if (amp >= 0) cursor = cursor.substring(0, amp);
        return EncodingUtil.urlDecode(cursor, 'UTF-8');
    }

    private static String formatDmlErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) return 'Unknown DML error';
        List<String> parts = new List<String>();
        for (Database.Error e : errors) {
            parts.add(e.getStatusCode() + ': ' + e.getMessage());
        }
        return String.join(parts, '; ');
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        return s.length() <= maxLen ? s : s.substring(0, maxLen);
    }

    /**
     * @description RFC4122 v4-ish UUID. Good enough for idempotency keys and run
     * ids — Ramp dedupes server-side, we just need cross-attempt uniqueness.
     */
    private static String generateUuid() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0,8) + '-' + hex.substring(8,12) + '-' + hex.substring(12,16) +
               '-' + hex.substring(16,20) + '-' + hex.substring(20,32);
    }

    // --------------------------------------------------------------------
    //  Response shape
    // --------------------------------------------------------------------

    public class TransactionPageResponse {
        public List<RampJournalEntryBuilder.RampTransaction> data;
        public PageMeta page;
        // Raw, untyped attributes per transaction id — powers the Reference Lookup
        // template (which can reference any/nested API field). Not from JSON.
        public transient Map<String, Object> rawByTxnId = new Map<String, Object>();
    }

    public class PageMeta {
        public String next;
    }

    public class RampTransactionServiceException extends Exception {}
}