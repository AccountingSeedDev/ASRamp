/**
 * @description Drives the card-transaction sync — one Queueable instance handles one page of
 * SYNC_READY transactions and, if the response has a next-page cursor, enqueues
 * itself again with that cursor.
 *
 * Why Queueable and not Database.Batchable:
 *   the source is a cursor-paginated REST API, not a SOQL queryable, so
 *   Database.QueryLocator does not fit. Chaining per page keeps each Apex
 *   transaction's callouts at 2 (fetch + sync ack) — well under limits.
 *
 * Each run logs one AcctSeed__Automated_Job_Results__c, threaded + updated
 * cumulatively across the page chain (see RampJobResultLogger).
 */
public class RampTransactionSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final String startCursor;
    private final Id ajrId;
    private final Integer cumProcessed;
    private final Integer cumSucceeded;
    private final Integer cumFailed;
    private final String cumNotes;

    public RampTransactionSyncQueueable() {
        this(null);
    }

    public RampTransactionSyncQueueable(String startCursor) {
        this(startCursor, null, 0, 0, 0, null);
    }

    private RampTransactionSyncQueueable(String startCursor, Id ajrId,
            Integer cumProcessed, Integer cumSucceeded, Integer cumFailed, String cumNotes) {
        this.startCursor = startCursor;
        this.ajrId = ajrId;
        this.cumProcessed = cumProcessed;
        this.cumSucceeded = cumSucceeded;
        this.cumFailed = cumFailed;
        this.cumNotes = cumNotes;
    }

    public void execute(QueueableContext ctx) {
        RampTransactionService.PageResult result;
        try {
            result = RampTransactionService.syncPage(startCursor);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'RampTransactionSyncQueueable page failed at cursor=' + startCursor + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            // Record the run as failed so it surfaces in Automated Job Results.
            RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_CARD_SYNC,
                cumProcessed, cumSucceeded, cumFailed,
                RampJobResultLogger.appendNote(cumNotes, 'Page failed at cursor=' + startCursor + ': ' + e.getMessage()));
            // Don't chain on a hard failure — the page's transactions are still
            // SYNC_READY in Ramp and the user can re-run from the LWC.
            return;
        }

        // Count at the transaction (document) grain so processed = succeeded + failed.
        // (Many transactions can fold into fewer grouped JEs, so JE count is not the
        // success count.)
        Integer pageSucceeded = Math.max(0, result.transactionsFetched - result.failedCount);
        Integer p = cumProcessed + result.transactionsFetched;
        Integer s = cumSucceeded + pageSucceeded;
        Integer f = cumFailed + result.failedCount;
        String notes = cumNotes;
        if (!result.errorMessages.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, String.join(result.errorMessages, '\n'));
        }

        Id currentAjrId = RampJobResultLogger.record(ajrId, RampJobResultLogger.JOB_CARD_SYNC, p, s, f, notes);

        // Chain when there's more to drain. Don't chain inside a test — the
        // platform won't fire chained Queueables under Test.startTest/stopTest.
        if (String.isNotBlank(result.nextCursor) && !Test.isRunningTest()) {
            System.enqueueJob(new RampTransactionSyncQueueable(result.nextCursor, currentAjrId, p, s, f, notes));
        }
    }
}
