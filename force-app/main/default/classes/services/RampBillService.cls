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

        // ---- Acks (wired; fire only when enabled) ----
        if (RampSyncSettingsService.getSendSyncAck()) {
            if (!billOk.isEmpty() || !billFail.isEmpty()) {
                postAckAsync(SYNC_TYPE_BILL, JSON.serialize(billOk), JSON.serialize(billFail), 'AP', JSON.serialize(new List<Id>(payableIdsToFlip)));
            }
            if (!payOk.isEmpty() || !payFail.isEmpty()) {
                postAckAsync(SYNC_TYPE_PAYMENT, JSON.serialize(payOk), JSON.serialize(payFail), 'CD', JSON.serialize(new List<Id>(cdIdsToFlip)));
            }
        }
        return result;
    }

    @future(callout=true)
    @TestVisible
    private static void postAckAsync(String syncType, String successfulJson, String failedJson, String objType, String idsJson) {
        List<Object> successful = (List<Object>) JSON.deserializeUntyped(successfulJson);
        List<Object> failed = (List<Object>) JSON.deserializeUntyped(failedJson);
        if (successful.isEmpty() && failed.isEmpty()) return;

        Map<String, Object> body = new Map<String, Object>{
            'idempotency_key' => RampTransactionService.newRunId(),
            'sync_type' => syncType
        };
        if (!successful.isEmpty()) body.put('successful_syncs', successful);
        if (!failed.isEmpty()) body.put('failed_syncs', failed);

        Boolean ackSucceeded = false;
        String errorMessage = null;
        try {
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/syncs', JSON.serialize(body));
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) ackSucceeded = true;
            else errorMessage = '/accounting/syncs (' + syncType + ') returned ' + res.getStatusCode() + ': ' + res.getBody();
        } catch (Exception e) {
            errorMessage = 'POST /accounting/syncs (' + syncType + ') failed: ' + e.getMessage();
        }

        List<Object> rawIds = (List<Object>) JSON.deserializeUntyped(idsJson);
        Set<Id> ids = new Set<Id>();
        for (Object o : rawIds) if (o != null) ids.add((Id) (String) o);
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
