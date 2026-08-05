/**
 * @description Drives the bill sync — one Queueable handles one page of sync-ready
 * bills and, if there's a next-page cursor, enqueues itself again. Mirrors
 * RampTransactionSyncQueueable.
 *
 * Each run logs one AcctSeed__Automated_Job_Results__c, threaded + updated
 * cumulatively across the page chain (see RampJobResultLogger).
 */
public class RampBillSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final String startCursor;
    private final String runId;
    private final Id ajrId;
    private final Integer cumProcessed;
    private final Integer cumSucceeded;
    private final Integer cumFailed;
    private final String cumNotes;

    public RampBillSyncQueueable() {
        this(null, RampTransactionService.newRunId());
    }

    public RampBillSyncQueueable(String startCursor, String runId) {
        this(startCursor, runId, null, 0, 0, 0, null);
    }

    private RampBillSyncQueueable(String startCursor, String runId, Id ajrId,
            Integer cumProcessed, Integer cumSucceeded, Integer cumFailed, String cumNotes) {
        this.startCursor = startCursor;
        this.runId = runId;
        this.ajrId = ajrId;
        this.cumProcessed = cumProcessed;
        this.cumSucceeded = cumSucceeded;
        this.cumFailed = cumFailed;
        this.cumNotes = cumNotes;
    }

    public void execute(QueueableContext ctx) {
        RampBillService.PageResult result;
        try {
            result = RampBillService.syncPage(startCursor, runId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'RampBillSyncQueueable page failed at cursor=' + startCursor + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_BILL_SYNC,
                cumProcessed, cumSucceeded, cumFailed,
                RampJobResultLogger.appendNote(cumNotes, 'Page failed at cursor=' + startCursor + ': ' + e.getMessage()));
            return;
        }

        // Document grain: processed = bills fetched; succeeded = payables synced;
        // failed = build/DML failures from either phase. A paid bill whose payable
        // syncs but whose CD/APD fails counts in both, so s + f can exceed p.
        Integer pageSucceeded = result.payablesCreated + result.payablesUpdated;
        Integer p = cumProcessed + result.billsFetched;
        Integer s = cumSucceeded + pageSucceeded;
        Integer f = cumFailed + result.failedCount;
        String notes = cumNotes;
        if (!result.errorMessages.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, String.join(result.errorMessages, '\n'));
        }

        Id currentAjrId = RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_BILL_SYNC, p, s, f, notes);

        if (String.isNotBlank(result.nextCursor) && !Test.isRunningTest()) {
            System.enqueueJob(new RampBillSyncQueueable(result.nextCursor, runId, currentAjrId, p, s, f, notes));
        }
    }
}
