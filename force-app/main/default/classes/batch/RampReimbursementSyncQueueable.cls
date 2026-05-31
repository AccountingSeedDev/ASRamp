/**
 * @description Drives the reimbursement sync — one Queueable handles one page of SYNC_READY
 * reimbursements and chains to the next page. Mirrors the card/bill queueables,
 * logging one cumulative AcctSeed__Automated_Job_Results__c per run.
 */
public class RampReimbursementSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final String startCursor;
    private final String runId;
    private final Id ajrId;
    private final Integer cumProcessed;
    private final Integer cumSucceeded;
    private final Integer cumFailed;
    private final String cumNotes;

    public RampReimbursementSyncQueueable() {
        this(null, RampTransactionService.newRunId());
    }

    public RampReimbursementSyncQueueable(String startCursor, String runId) {
        this(startCursor, runId, null, 0, 0, 0, null);
    }

    private RampReimbursementSyncQueueable(String startCursor, String runId, Id ajrId,
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
        RampReimbursementService.PageResult result;
        try {
            result = RampReimbursementService.syncPage(startCursor, runId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'RampReimbursementSyncQueueable page failed at cursor=' + startCursor + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_REIMBURSEMENT_SYNC,
                cumProcessed, cumSucceeded, cumFailed,
                RampJobResultLogger.appendNote(cumNotes, 'Page failed at cursor=' + startCursor + ': ' + e.getMessage()));
            return;
        }

        // Document grain: processed = reimbursements fetched; failed = build/DML
        // failures; succeeded = payables synced. Skipped (paybacks) aren't counted.
        Integer pageSucceeded = result.payablesCreated + result.payablesUpdated;
        Integer p = cumProcessed + result.reimbursementsFetched;
        Integer s = cumSucceeded + pageSucceeded;
        Integer f = cumFailed + result.failedCount;
        String notes = cumNotes;
        if (result.skippedCount > 0) {
            notes = RampJobResultLogger.appendNote(notes, 'Skipped ' + result.skippedCount + ' payback/USER_TO_BUSINESS reimbursement(s).');
        }
        if (!result.errorMessages.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, String.join(result.errorMessages, '\n'));
        }

        Id currentAjrId = RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_REIMBURSEMENT_SYNC, p, s, f, notes);

        if (String.isNotBlank(result.nextCursor) && !Test.isRunningTest()) {
            System.enqueueJob(new RampReimbursementSyncQueueable(result.nextCursor, runId, currentAjrId, p, s, f, notes));
        }
    }
}
