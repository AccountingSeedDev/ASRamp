/**
 * @description Fetch one page of SYNC_READY Ramp reimbursements and
 * post them into Accounting Seed as employee Payables (+ Cash Disbursement / AP
 * Disbursement when already reimbursed). Single-phase sync (REIMBURSEMENT_SYNC),
 * like card transactions. Idempotent via AcctSeed__ExtId__c keys:
 *   payable=reimbId, line={reimbId}:L{n}, cash disbursement={reimbId}:cd,
 *   ap disbursement={reimbId}:apd, batch=RAMP-REIMB:{periodId}.
 */
public with sharing class RampReimbursementService {

    private static final Integer PAGE_SIZE = 100;
    private static final String SYNC_TYPE = 'REIMBURSEMENT_SYNC';
    private static final String BATCH_EXTID_PREFIX = 'RAMP-REIMB:';

    public class PageResult {
        public Integer reimbursementsFetched = 0;
        public Integer payablesCreated = 0;
        public Integer payablesUpdated = 0;
        public Integer cashDisbursementsCreated = 0;
        public Integer failedCount = 0;
        public Integer skippedCount = 0;
        public String nextCursor;
        public Boolean isLastPage { get { return String.isBlank(nextCursor); } set; }
        public List<String> errorMessages = new List<String>();
    }

    public static PageResult syncPage(String startCursor) {
        return syncPage(startCursor, RampTransactionService.newRunId());
    }

    public static PageResult syncPage(String startCursor, String runId) {
        PageResult result = new PageResult();

        ReimbPageResponse page = fetchPage(startCursor);
        result.nextCursor = (page.page != null) ? extractStartCursor(page.page.next) : null;

        List<RampReimbursementBuilder.Reimbursement> items = (page.data != null) ? page.data : new List<RampReimbursementBuilder.Reimbursement>();
        result.reimbursementsFetched = items.size();
        if (items.isEmpty()) return result;

        RampReimbursementBuilder.BuildResult build = RampReimbursementBuilder.build(items);
        result.skippedCount = build.skipped.size();

        // Payable headers.
        List<AcctSeed__Account_Payable__c> headers = new List<AcctSeed__Account_Payable__c>();
        for (RampReimbursementBuilder.ReimbursementBuild rb : build.successful) headers.add(rb.header);
        Map<String, String> headerFailure = new Map<String, String>();
        if (!headers.isEmpty()) {
            Database.UpsertResult[] urs = Database.upsert(headers, AcctSeed__Account_Payable__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < urs.size(); i++) {
                if (!urs[i].isSuccess()) headerFailure.put(headers[i].AcctSeed__ExtId__c, formatErrors(urs[i].getErrors()));
                else if (urs[i].isCreated()) result.payablesCreated++; else result.payablesUpdated++;
            }
        }

        // Payable lines.
        List<AcctSeed__Account_Payable_Line__c> lines = new List<AcctSeed__Account_Payable_Line__c>();
        for (RampReimbursementBuilder.ReimbursementBuild rb : build.successful) {
            if (headerFailure.containsKey(rb.reimbursementId)) continue;
            for (AcctSeed__Account_Payable_Line__c ln : rb.lines) { ln.AcctSeed__Account_Payable__c = rb.header.Id; lines.add(ln); }
        }
        Map<String, String> lineFailure = new Map<String, String>();
        if (!lines.isEmpty()) {
            Database.UpsertResult[] lrs = Database.upsert(lines, AcctSeed__Account_Payable_Line__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < lrs.size(); i++) {
                if (!lrs[i].isSuccess()) lineFailure.put(idFromExt(lines[i].AcctSeed__ExtId__c), formatErrors(lrs[i].getErrors()));
            }
        }

        // Payment (reimbursed): batch → CD → APD.
        List<RampReimbursementBuilder.ReimbursementBuild> paid = new List<RampReimbursementBuilder.ReimbursementBuild>();
        for (RampReimbursementBuilder.ReimbursementBuild rb : build.successful) {
            if (rb.cashDisbursement != null && !headerFailure.containsKey(rb.reimbursementId) && !lineFailure.containsKey(rb.reimbursementId)) paid.add(rb);
        }
        Map<String, String> cdFailure = new Map<String, String>();
        if (!paid.isEmpty()) {
            Map<Id, AcctSeed__Cash_Disbursement_Batch__c> batchByPeriod = new Map<Id, AcctSeed__Cash_Disbursement_Batch__c>();
            for (RampReimbursementBuilder.ReimbursementBuild rb : paid) {
                if (!batchByPeriod.containsKey(rb.paymentPeriodId)) {
                    String batchName = 'Ramp Reimbursement ' + String.valueOf(rb.cashDisbursement.AcctSeed__Disbursement_Date__c);
                    batchByPeriod.put(rb.paymentPeriodId, new AcctSeed__Cash_Disbursement_Batch__c(
                        Name = batchName,
                        AcctSeed__ExtId__c = BATCH_EXTID_PREFIX + rb.paymentPeriodId
                    ));
                }
            }
            Database.upsert(batchByPeriod.values(), AcctSeed__Cash_Disbursement_Batch__c.AcctSeed__ExtId__c, false);

            List<AcctSeed__Cash_Disbursement__c> cds = new List<AcctSeed__Cash_Disbursement__c>();
            for (RampReimbursementBuilder.ReimbursementBuild rb : paid) {
                rb.cashDisbursement.AcctSeed__Cash_Disbursement_Batch__c = batchByPeriod.get(rb.paymentPeriodId).Id;
                cds.add(rb.cashDisbursement);
            }
            Database.UpsertResult[] crs = Database.upsert(cds, AcctSeed__Cash_Disbursement__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < crs.size(); i++) {
                if (!crs[i].isSuccess()) cdFailure.put(idFromExt(cds[i].AcctSeed__ExtId__c), formatErrors(crs[i].getErrors()));
                else if (crs[i].isCreated()) result.cashDisbursementsCreated++;
            }

            List<AcctSeed__AP_Disbursement__c> apds = new List<AcctSeed__AP_Disbursement__c>();
            for (RampReimbursementBuilder.ReimbursementBuild rb : paid) {
                if (cdFailure.containsKey(rb.reimbursementId)) continue;
                rb.apDisbursement.AcctSeed__Account_Payable__c = rb.header.Id;
                rb.apDisbursement.AcctSeed__Cash_Disbursement__c = rb.cashDisbursement.Id;
                apds.add(rb.apDisbursement);
            }
            if (!apds.isEmpty()) {
                Database.UpsertResult[] ars = Database.upsert(apds, AcctSeed__AP_Disbursement__c.AcctSeed__ExtId__c, false);
                for (Integer i = 0; i < ars.size(); i++) {
                    if (!ars[i].isSuccess()) cdFailure.put(idFromExt(apds[i].AcctSeed__ExtId__c), formatErrors(ars[i].getErrors()));
                }
            }
        }

        // Ack payload (single phase).
        List<Map<String, Object>> okSyncs = new List<Map<String, Object>>();
        List<Map<String, Object>> failSyncs = new List<Map<String, Object>>();
        Set<Id> payableIdsToFlip = new Set<Id>();
        Set<Id> cdIdsToFlip = new Set<Id>();

        for (String reimbId : build.failed.keySet()) {
            failSyncs.add(entry(reimbId, build.failed.get(reimbId))); result.failedCount++;
            result.errorMessages.add(reimbId + ': ' + build.failed.get(reimbId));
        }
        for (RampReimbursementBuilder.ReimbursementBuild rb : build.successful) {
            String reason = headerFailure.get(rb.reimbursementId);
            if (reason == null) reason = lineFailure.get(rb.reimbursementId);
            if (reason == null) reason = cdFailure.get(rb.reimbursementId);
            if (reason != null) {
                failSyncs.add(entry(rb.reimbursementId, reason)); result.failedCount++;
                result.errorMessages.add(rb.reimbursementId + ': ' + reason);
            } else {
                okSyncs.add(ref(rb.reimbursementId, rb.header.Id));
                payableIdsToFlip.add(rb.header.Id);
                if (rb.cashDisbursement != null && rb.cashDisbursement.Id != null) cdIdsToFlip.add(rb.cashDisbursement.Id);
            }
        }

        // Mark DML-failed payables synchronously so the error queue can surface them.
        List<AcctSeed__Account_Payable__c> toFail = new List<AcctSeed__Account_Payable__c>();
        for (RampReimbursementBuilder.ReimbursementBuild rb : build.successful) {
            if (rb.header.Id == null) continue;
            String failReason = lineFailure.get(rb.reimbursementId);
            if (failReason == null) failReason = cdFailure.get(rb.reimbursementId);
            if (failReason != null) {
                toFail.add(new AcctSeed__Account_Payable__c(
                    Id = rb.header.Id,
                    Ramp_Sync_Status__c = 'Failed',
                    Ramp_Sync_Error__c = truncate(failReason, 1000)
                ));
            }
        }
        if (!toFail.isEmpty()) Database.update(toFail, false);

        if ((!okSyncs.isEmpty() || !failSyncs.isEmpty()) && RampSyncSettingsService.getSendSyncAck()) {
            postAckAsync(JSON.serialize(okSyncs), JSON.serialize(failSyncs),
                JSON.serialize(new List<Id>(payableIdsToFlip)), JSON.serialize(new List<Id>(cdIdsToFlip)));
        }
        return result;
    }

    @future(callout=true)
    @TestVisible
    private static void postAckAsync(String okJson, String failJson, String payableIdsJson, String cdIdsJson) {
        List<Object> okSyncs = (List<Object>) JSON.deserializeUntyped(okJson);
        List<Object> failSyncs = (List<Object>) JSON.deserializeUntyped(failJson);
        if (okSyncs.isEmpty() && failSyncs.isEmpty()) return;

        Map<String, Object> body = new Map<String, Object>{ 'idempotency_key' => RampTransactionService.newRunId(), 'sync_type' => SYNC_TYPE };
        if (!okSyncs.isEmpty()) body.put('successful_syncs', okSyncs);
        if (!failSyncs.isEmpty()) body.put('failed_syncs', failSyncs);

        Boolean ackSucceeded = false;
        String errorMessage = null;
        try {
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/syncs', JSON.serialize(body));
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) ackSucceeded = true;
            else errorMessage = '/accounting/syncs (REIMBURSEMENT_SYNC) returned ' + res.getStatusCode() + ': ' + res.getBody();
        } catch (Exception e) {
            errorMessage = 'POST /accounting/syncs (REIMBURSEMENT_SYNC) failed: ' + e.getMessage();
        }

        flip('AP', payableIdsJson, ackSucceeded, errorMessage);
        flip('CD', cdIdsJson, ackSucceeded, errorMessage);
    }

    private static void flip(String objType, String idsJson, Boolean ackSucceeded, String errorMessage) {
        Set<Id> ids = new Set<Id>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(idsJson)) if (o != null) ids.add((Id) (String) o);
        if (ids.isEmpty()) return;
        if (objType == 'AP') {
            List<AcctSeed__Account_Payable__c> recs = [SELECT Id, Ramp_Sync_Status__c FROM AcctSeed__Account_Payable__c WHERE Id IN :ids AND Ramp_Sync_Status__c = 'Pending'];
            for (AcctSeed__Account_Payable__c r : recs) {
                if (ackSucceeded) { r.Ramp_Sync_Status__c = 'Synced_To_Ramp'; r.Ramp_Sync_Error__c = null; }
                else { r.Ramp_Sync_Status__c = 'Failed'; r.Ramp_Sync_Error__c = truncate(errorMessage, 1000); }
            }
            if (!recs.isEmpty()) Database.update(recs, false);
        } else {
            List<AcctSeed__Cash_Disbursement__c> recs = [SELECT Id, Ramp_Sync_Status__c FROM AcctSeed__Cash_Disbursement__c WHERE Id IN :ids AND Ramp_Sync_Status__c = 'Pending'];
            for (AcctSeed__Cash_Disbursement__c r : recs) {
                if (ackSucceeded) { r.Ramp_Sync_Status__c = 'Synced_To_Ramp'; r.Ramp_Sync_Error__c = null; }
                else { r.Ramp_Sync_Status__c = 'Failed'; r.Ramp_Sync_Error__c = truncate(errorMessage, 1000); }
            }
            if (!recs.isEmpty()) Database.update(recs, false);
        }
    }

    @TestVisible
    private static ReimbPageResponse fetchPage(String startCursor) {
        String endpoint = '/developer/v1/reimbursements?sync_status=SYNC_READY&page_size=' + PAGE_SIZE;
        if (String.isNotBlank(startCursor)) endpoint += '&start=' + EncodingUtil.urlEncode(startCursor, 'UTF-8');
        HttpResponse res = RampAPIService.get(endpoint);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new RampReimbursementServiceException('Failed to fetch reimbursements. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
        }
        try {
            return (ReimbPageResponse) JSON.deserialize(res.getBody(), ReimbPageResponse.class);
        } catch (Exception e) {
            throw new RampReimbursementServiceException('Failed to parse reimbursements response: ' + e.getMessage() + '. Body: ' + res.getBody());
        }
    }

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

    private static String idFromExt(String extId) { return (extId != null && extId.contains(':')) ? extId.substringBefore(':') : extId; }
    private static Map<String, Object> entry(String id, String reason) { return new Map<String, Object>{ 'id' => id, 'error' => new Map<String, Object>{ 'message' => reason } }; }
    private static Map<String, Object> ref(String id, Id refId) { return new Map<String, Object>{ 'id' => id, 'reference_id' => String.valueOf(refId) }; }
    private static String formatErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) return 'Unknown DML error';
        List<String> parts = new List<String>();
        for (Database.Error e : errors) parts.add(e.getStatusCode() + ': ' + e.getMessage());
        return String.join(parts, '; ');
    }
    private static String truncate(String s, Integer maxLen) { return (s == null || s.length() <= maxLen) ? s : s.substring(0, maxLen); }

    public class ReimbPageResponse {
        public List<RampReimbursementBuilder.Reimbursement> data;
        public PageMeta page;
    }
    public class PageMeta { public String next; }
    public class RampReimbursementServiceException extends Exception {}
}
