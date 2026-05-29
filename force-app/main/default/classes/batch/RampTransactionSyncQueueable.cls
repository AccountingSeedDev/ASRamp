/**
 * @description Drives Pipeline 1 — one Queueable instance handles one page
 * of SYNC_READY transactions and, if the response has a next-page cursor,
 * enqueues itself again with that cursor.
 *
 * Why Queueable and not Database.Batchable:
 *   the source is a cursor-paginated REST API, not a SOQL queryable, so
 *   Database.QueryLocator does not fit. Chaining per page keeps each Apex
 *   transaction's callouts at 2 (fetch + sync ack) — well under limits.
 */
public class RampTransactionSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final String startCursor;
    private final String runId;

    public RampTransactionSyncQueueable() {
        this(null, RampTransactionService.newRunId());
    }

    public RampTransactionSyncQueueable(String startCursor, String runId) {
        this.startCursor = startCursor;
        this.runId = runId;
    }

    public void execute(QueueableContext ctx) {
        RampTransactionService.PageResult result;
        try {
            result = RampTransactionService.syncPage(startCursor, runId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'RampTransactionSyncQueueable page failed at cursor=' + startCursor + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            // Don't chain on a hard failure — the user can re-run from the LWC,
            // and the page's transactions are still SYNC_READY in Ramp.
            return;
        }

        System.debug('RampTransactionSyncQueueable page complete: '
            + 'fetched=' + result.transactionsFetched
            + ' created=' + result.journalEntriesCreated
            + ' updated=' + result.journalEntriesUpdated
            + ' failed=' + result.failedCount
            + ' nextCursor=' + result.nextCursor);

        if (!result.errorMessages.isEmpty()) {
            for (String msg : result.errorMessages) {
                System.debug(LoggingLevel.WARN, 'Transaction sync error: ' + msg);
            }
        }

        // Chain when there's more to drain. Don't chain inside a test — the
        // platform won't fire chained Queueables under Test.startTest/stopTest
        // anyway, and queueing one just complicates assertions.
        if (String.isNotBlank(result.nextCursor) && !Test.isRunningTest()) {
            // Same runId across the chain so By Run grouping folds every page
            // of this run into the same per-period JE.
            System.enqueueJob(new RampTransactionSyncQueueable(result.nextCursor, runId));
        }
    }
}
