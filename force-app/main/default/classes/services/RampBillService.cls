/**
 * @description Fetch one page of sync-ready Ramp bills and post them
 * into Accounting Seed. Two stages per the ERP guide's decision table, driven by
 * each bill's sync_status + status:
 *   - BILL_SYNC: bill → Account_Payable__c + lines.
 *   - BILL_PAYMENT_SYNC: a PAID bill also → Cash Disbursement (in a
 *     per-period batch) + AP Disbursement, clearing the payable.
 *
 * Fetches sync_ready=true (everything with outstanding export work) and decides
 * per bill what to create/ack. Idempotent via AcctSeed__ExtId__c keys:
 *   payable=billId, line={billId}:L{n}, cash disbursement={billId}:cd,
 *   ap disbursement={billId}:apd, batch=RAMP-BILLPAY:{periodId}.
 */
public with sharing class RampBillService {

    private static final Integer PAGE_SIZE = 100;
    private static final String SYNC_TYPE_BILL = 'BILL_SYNC';
    private static final String SYNC_TYPE_PAYMENT = 'BILL_PAYMENT_SYNC';
    private static final String BATCH_EXTID_PREFIX = 'RAMP-BILLPAY:';

    public class PageResult {
        public Integer billsFetched = 0;
        public Integer payablesCreated = 0;
        public Integer payablesUpdated = 0;
        public Integer cashDisbursementsCreated = 0;
        public Integer failedCount = 0;
        public String nextCursor;
        public Boolean isLastPage { get { return String.isBlank(nextCursor); } set; }
        public List<String> errorMessages = new List<String>();
    }

    public static PageResult syncPage(String startCursor) {
        return syncPage(startCursor, RampTransactionService.newRunId());
    }

    public static PageResult syncPage(String startCursor, String runId) {
        PageResult result = new PageResult();

        BillPageResponse page = fetchPage(startCursor);
        result.nextCursor = (page.page != null) ? extractStartCursor(page.page.next) : null;

        List<RampBillBuilder.Bill> bills = (page.data != null) ? page.data : new List<RampBillBuilder.Bill>();
        result.billsFetched = bills.size();
        if (bills.isEmpty()) return result;

        Map<String, RampBillBuilder.Bill> billById = new Map<String, RampBillBuilder.Bill>();
        for (RampBillBuilder.Bill b : bills) billById.put(b.id, b);

        RampBillBuilder.BuildResult build = RampBillBuilder.build(bills);

        // ---- Payable headers ----
        List<AcctSeed__Account_Payable__c> headers = new List<AcctSeed__Account_Payable__c>();
        for (RampBillBuilder.PayableBuild pb : build.successful) headers.add(pb.header);
        Map<String, String> headerFailure = new Map<String, String>();
        if (!headers.isEmpty()) {
            Database.UpsertResult[] urs = Database.upsert(headers, AcctSeed__Account_Payable__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < urs.size(); i++) {
                if (!urs[i].isSuccess()) headerFailure.put(headers[i].AcctSeed__ExtId__c, formatErrors(urs[i].getErrors()));
                else if (urs[i].isCreated()) result.payablesCreated++;
                else result.payablesUpdated++;
            }
        }

        // ---- Payable lines (headers that succeeded) ----
        List<AcctSeed__Account_Payable_Line__c> lines = new List<AcctSeed__Account_Payable_Line__c>();
        for (RampBillBuilder.PayableBuild pb : build.successful) {
            if (headerFailure.containsKey(pb.billId)) continue;
            for (AcctSeed__Account_Payable_Line__c ln : pb.lines) {
                ln.AcctSeed__Account_Payable__c = pb.header.Id;
                lines.add(ln);
            }
        }
        Map<String, String> lineFailure = new Map<String, String>();
        if (!lines.isEmpty()) {
            Database.UpsertResult[] lrs = Database.upsert(lines, AcctSeed__Account_Payable_Line__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < lrs.size(); i++) {
                if (!lrs[i].isSuccess()) lineFailure.put(billIdFromExt(lines[i].AcctSeed__ExtId__c), formatErrors(lrs[i].getErrors()));
            }
        }

        // ---- Payment stage: batches → cash disbursements → AP disbursements ----
        // Only for paid builds whose payable succeeded.
        List<RampBillBuilder.PayableBuild> payable2b = new List<RampBillBuilder.PayableBuild>();
        for (RampBillBuilder.PayableBuild pb : build.successful) {
            if (pb.cashDisbursement != null && !headerFailure.containsKey(pb.billId) && !lineFailure.containsKey(pb.billId)) {
                payable2b.add(pb);
            }
        }
        Map<String, String> cdFailure = new Map<String, String>();
        if (!payable2b.isEmpty()) {
            // One batch per payment period.
            Map<Id, AcctSeed__Cash_Disbursement_Batch__c> batchByPeriod = new Map<Id, AcctSeed__Cash_Disbursement_Batch__c>();
            for (RampBillBuilder.PayableBuild pb : payable2b) {
                if (!batchByPeriod.containsKey(pb.paymentPeriodId)) {
                    batchByPeriod.put(pb.paymentPeriodId, new AcctSeed__Cash_Disbursement_Batch__c(
                        AcctSeed__ExtId__c = BATCH_EXTID_PREFIX + pb.paymentPeriodId,
                        Name = 'Ramp Bill Payment ' + String.valueOf(pb.cashDisbursement.AcctSeed__Disbursement_Date__c)
                    ));
                }
            }
            Database.upsert(batchByPeriod.values(), AcctSeed__Cash_Disbursement_Batch__c.AcctSeed__ExtId__c, false);

            List<AcctSeed__Cash_Disbursement__c> cds = new List<AcctSeed__Cash_Disbursement__c>();
            for (RampBillBuilder.PayableBuild pb : payable2b) {
                pb.cashDisbursement.AcctSeed__Cash_Disbursement_Batch__c = batchByPeriod.get(pb.paymentPeriodId).Id;
                cds.add(pb.cashDisbursement);
            }
            Database.UpsertResult[] crs = Database.upsert(cds, AcctSeed__Cash_Disbursement__c.AcctSeed__ExtId__c, false);
            for (Integer i = 0; i < crs.size(); i++) {
                if (!crs[i].isSuccess()) cdFailure.put(billIdFromExt(cds[i].AcctSeed__ExtId__c), formatErrors(crs[i].getErrors()));
                else if (crs[i].isCreated()) result.cashDisbursementsCreated++;
            }

            // AP disbursements (link payable + CD) for CDs that succeeded.
            List<AcctSeed__AP_Disbursement__c> apds = new List<AcctSeed__AP_Disbursement__c>();
            for (RampBillBuilder.PayableBuild pb : payable2b) {
                if (cdFailure.containsKey(pb.billId)) continue;
                pb.apDisbursement.AcctSeed__Account_Payable__c = pb.header.Id;
                pb.apDisbursement.AcctSeed__Cash_Disbursement__c = pb.cashDisbursement.Id;
                apds.add(pb.apDisbursement);
            }
            if (!apds.isEmpty()) {
                Database.UpsertResult[] ars = Database.upsert(apds, AcctSeed__AP_Disbursement__c.AcctSeed__ExtId__c, false);
                for (Integer i = 0; i < ars.size(); i++) {
                    if (!ars[i].isSuccess()) cdFailure.put(billIdFromExt(apds[i].AcctSeed__ExtId__c), formatErrors(ars[i].getErrors()));
                }
            }
        }

        // ---- Build the two ack payloads ----
        List<Map<String, Object>> billOk = new List<Map<String, Object>>();
        List<Map<String, Object>> billFail = new List<Map<String, Object>>();
        List<Map<String, Object>> payOk = new List<Map<String, Object>>();
        List<Map<String, Object>> payFail = new List<Map<String, Object>>();
        Set<Id> payableIdsToFlip = new Set<Id>();
        Set<Id> cdIdsToFlip = new Set<Id>();

        for (String billId : build.failed.keySet()) {
            addEntry(billFail, billId, build.failed.get(billId)); result.failedCount++;
            result.errorMessages.add(billId + ': ' + build.failed.get(billId));
        }

        for (RampBillBuilder.PayableBuild pb : build.successful) {
            RampBillBuilder.Bill bill = billById.get(pb.billId);
            String reason = headerFailure.get(pb.billId);
            if (reason == null) reason = lineFailure.get(pb.billId);

            // BILL_SYNC phase — only bills not already bill-synced.
            Boolean needsBillSync = (bill != null && bill.sync_status == 'NOT_SYNCED');
            if (needsBillSync) {
                if (reason != null) { addEntry(billFail, pb.billId, reason); result.failedCount++; result.errorMessages.add(pb.billId + ': ' + reason); }
                else { addRef(billOk, pb.billId, pb.header.Id); payableIdsToFlip.add(pb.header.Id); }
            }

            // BILL_PAYMENT_SYNC phase — paid bills.
            if (pb.isPaid) {
                if (reason != null) {
                    // payable failed → can't record payment
                    addEntry(payFail, pb.billId, reason); result.failedCount++;
                } else if (pb.cashDisbursement == null) {
                    String msg = 'Bill is paid but no "Ramp Bill Payment Bank" GL Account is configured (or payment period is not open).';
                    addEntry(payFail, pb.billId, msg); result.failedCount++; result.errorMessages.add(pb.billId + ': ' + msg);
                } else if (cdFailure.containsKey(pb.billId)) {
                    addEntry(payFail, pb.billId, cdFailure.get(pb.billId)); result.failedCount++; result.errorMessages.add(pb.billId + ': ' + cdFailure.get(pb.billId));
                } else {
                    addRef(payOk, pb.billId, pb.cashDisbursement.Id); cdIdsToFlip.add(pb.cashDisbursement.Id);
                }
            }
        }

        // ---- Record what posted, synchronously ----
        // The ack below is optional and off by default, so a status that waits on
        // it leaves every payable at "Pending" and the home dashboard reporting 0
        // synced no matter how many records posted cleanly (FS-15109). Status
        // reflects the Accounting Seed write; a failed ack downgrades it after.
        List<AcctSeed__Account_Payable__c> apStatus = new List<AcctSeed__Account_Payable__c>();
        List<AcctSeed__Cash_Disbursement__c> cdStatus = new List<AcctSeed__Cash_Disbursement__c>();
        for (RampBillBuilder.PayableBuild pb : build.successful) {
            if (pb.header.Id == null) continue;   // header upsert failed — no record to stamp
            String reason = headerFailure.get(pb.billId);
            if (reason == null) reason = lineFailure.get(pb.billId);
            apStatus.add(payableStatus(pb.header.Id, reason));

            if (pb.cashDisbursement != null && pb.cashDisbursement.Id != null) {
                cdStatus.add(new AcctSeed__Cash_Disbursement__c(
                    Id = pb.cashDisbursement.Id,
                    Ramp_Sync_Status__c = cdFailure.containsKey(pb.billId) ? 'Failed' : 'Synced_To_Ramp',
                    Ramp_Sync_Error__c = cdFailure.containsKey(pb.billId) ? truncate(cdFailure.get(pb.billId), 1000) : null
                ));
            }
        }
        if (!apStatus.isEmpty()) Database.update(apStatus, false);
        if (!cdStatus.isEmpty()) Database.update(cdStatus, false);

        // ---- Acks (fire only when enabled) ----
        // One @future making two sequential POSTs, not two racing ones: Ramp
        // rejects BILL_PAYMENT_SYNC for a bill it hasn't accepted a BILL_SYNC for
        // yet ("not ready for sync"), and parallel @futures have no ordering
        // guarantee. When the payment ack won that race it 400'd and stamped
        // perfectly good Cash Disbursements "Failed".
        Boolean anyAck = !billOk.isEmpty() || !billFail.isEmpty() || !payOk.isEmpty() || !payFail.isEmpty();
        if (anyAck && RampSyncSettingsService.getSendSyncAck()) {
            postAckAsync(
                JSON.serialize(billOk), JSON.serialize(billFail), JSON.serialize(new List<Id>(payableIdsToFlip)),
                JSON.serialize(payOk), JSON.serialize(payFail), JSON.serialize(new List<Id>(cdIdsToFlip)));
        }
        return result;
    }

    /** Payable status for a posted bill — Failed with the reason, or Synced. */
    private static AcctSeed__Account_Payable__c payableStatus(Id recId, String reason) {
        return new AcctSeed__Account_Payable__c(
            Id = recId,
            Ramp_Sync_Status__c = (reason == null) ? 'Synced_To_Ramp' : 'Failed',
            Ramp_Sync_Error__c = (reason == null) ? null : truncate(reason, 1000)
        );
    }

    /**
     * @description Acknowledge one page to Ramp: BILL_SYNC first, then
     * BILL_PAYMENT_SYNC only once the bill ack has succeeded. The order is a Ramp
     * requirement — a payment ack for a bill that isn't bill-synced yet is
     * rejected — so both POSTs run sequentially inside one @future.
     */
    @future(callout=true)
    @TestVisible
    private static void postAckAsync(String billOkJson, String billFailJson, String payableIdsJson,
            String payOkJson, String payFailJson, String cdIdsJson) {
        AckOutcome bill = postAck(SYNC_TYPE_BILL, billOkJson, billFailJson);
        Boolean billAckFailed = bill.attempted && !bill.succeeded;
        if (billAckFailed) markFailed('AP', payableIdsJson, bill.error);

        if (!hasPayload(payOkJson, payFailJson)) return;

        // Ramp is unaware of the bills, so a payment ack cannot succeed. Don't
        // send it — and say why on the disbursements rather than reporting Ramp's
        // "not ready for sync" rejection, which reads like a data problem.
        if (billAckFailed) {
            markFailed('CD', cdIdsJson,
                'Bill acknowledgement failed, so the payment was not acknowledged to Ramp: ' + bill.error);
            return;
        }

        AckOutcome pay = postAck(SYNC_TYPE_PAYMENT, payOkJson, payFailJson);
        if (pay.attempted && !pay.succeeded) markFailed('CD', cdIdsJson, pay.error);
    }

    /** Result of one /accounting/syncs POST. attempted=false → nothing to send. */
    public class AckOutcome {
        public Boolean attempted = false;
        public Boolean succeeded = false;
        public String error;
    }

    private static Boolean hasPayload(String okJson, String failJson) {
        return !((List<Object>) JSON.deserializeUntyped(okJson)).isEmpty()
            || !((List<Object>) JSON.deserializeUntyped(failJson)).isEmpty();
    }

    private static AckOutcome postAck(String syncType, String okJson, String failJson) {
        AckOutcome out = new AckOutcome();
        List<Object> successful = (List<Object>) JSON.deserializeUntyped(okJson);
        List<Object> failed = (List<Object>) JSON.deserializeUntyped(failJson);
        if (successful.isEmpty() && failed.isEmpty()) return out;

        out.attempted = true;
        Map<String, Object> body = new Map<String, Object>{
            'idempotency_key' => RampTransactionService.newRunId(),
            'sync_type' => syncType
        };
        if (!successful.isEmpty()) body.put('successful_syncs', successful);
        if (!failed.isEmpty()) body.put('failed_syncs', failed);

        try {
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/syncs', JSON.serialize(body));
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) out.succeeded = true;
            else out.error = '/accounting/syncs (' + syncType + ') returned ' + res.getStatusCode() + ': ' + res.getBody();
        } catch (Exception e) {
            out.error = 'POST /accounting/syncs (' + syncType + ') failed: ' + e.getMessage();
        }
        return out;
    }

    /**
     * @description Downgrade records whose ack didn't land. A successful ack needs
     * no write — syncPage already stamped these "Synced_To_Ramp" when they posted.
     */
    private static void markFailed(String objType, String idsJson, String errorMessage) {
        Set<Id> ids = new Set<Id>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(idsJson)) if (o != null) ids.add((Id) (String) o);
        if (ids.isEmpty()) return;

        if (objType == 'AP') {
            List<AcctSeed__Account_Payable__c> recs = [
                SELECT Id, Ramp_Sync_Status__c FROM AcctSeed__Account_Payable__c
                WHERE Id IN :ids AND Ramp_Sync_Status__c = 'Synced_To_Ramp'
            ];
            for (AcctSeed__Account_Payable__c r : recs) {
                r.Ramp_Sync_Status__c = 'Failed';
                r.Ramp_Sync_Error__c = truncate(errorMessage, 1000);
            }
            if (!recs.isEmpty()) Database.update(recs, false);
        } else {
            List<AcctSeed__Cash_Disbursement__c> recs = [
                SELECT Id, Ramp_Sync_Status__c FROM AcctSeed__Cash_Disbursement__c
                WHERE Id IN :ids AND Ramp_Sync_Status__c = 'Synced_To_Ramp'
            ];
            for (AcctSeed__Cash_Disbursement__c r : recs) {
                r.Ramp_Sync_Status__c = 'Failed';
                r.Ramp_Sync_Error__c = truncate(errorMessage, 1000);
            }
            if (!recs.isEmpty()) Database.update(recs, false);
        }
    }

    // --------------------------------------------------------------------
    //  HTTP
    // --------------------------------------------------------------------
    @TestVisible
    private static BillPageResponse fetchPage(String startCursor) {
        String endpoint = '/developer/v1/bills?sync_ready=true&page_size=' + PAGE_SIZE;
        if (String.isNotBlank(startCursor)) endpoint += '&start=' + EncodingUtil.urlEncode(startCursor, 'UTF-8');

        HttpResponse res = RampAPIService.get(endpoint);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new RampBillServiceException('Failed to fetch bills. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
        }
        try {
            return (BillPageResponse) JSON.deserialize(res.getBody(), BillPageResponse.class);
        } catch (Exception e) {
            throw new RampBillServiceException('Failed to parse bills response: ' + e.getMessage() + '. Body: ' + res.getBody());
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

    // --------------------------------------------------------------------
    //  Helpers
    // --------------------------------------------------------------------
    private static String billIdFromExt(String extId) {
        return (extId != null && extId.contains(':')) ? extId.substringBefore(':') : extId;
    }
    private static void addEntry(List<Map<String, Object>> bucket, String billId, String reason) {
        bucket.add(new Map<String, Object>{ 'id' => billId, 'error' => new Map<String, Object>{ 'message' => reason } });
    }
    private static void addRef(List<Map<String, Object>> bucket, String billId, Id refId) {
        bucket.add(new Map<String, Object>{ 'id' => billId, 'reference_id' => String.valueOf(refId) });
    }
    private static String formatErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) return 'Unknown DML error';
        List<String> parts = new List<String>();
        for (Database.Error e : errors) parts.add(e.getStatusCode() + ': ' + e.getMessage());
        return String.join(parts, '; ');
    }
    private static String truncate(String s, Integer maxLen) {
        return (s == null || s.length() <= maxLen) ? s : s.substring(0, maxLen);
    }

    public class BillPageResponse {
        public List<RampBillBuilder.Bill> data;
        public PageMeta page;
    }
    public class PageMeta { public String next; }
    public class RampBillServiceException extends Exception {}
}
