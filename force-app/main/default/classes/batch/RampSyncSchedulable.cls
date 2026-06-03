/**
 * @description Schedulable that runs one Ramp sync pipeline on a cron schedule.
 * Each pipeline schedules its own instance independently (e.g. nightly master
 * data, hourly bills). execute() enqueues the pipeline's Queueable — Queueables
 * allow the callouts the syncs need.
 */
public class RampSyncSchedulable implements Schedulable {

    public static final String PIPE_MASTER = 'master';   // legacy alias → GL
    public static final String PIPE_GL = 'gl';
    public static final String PIPE_VAR = 'var';
    public static final String PIPE_VENDOR = 'vendor';
    public static final String PIPE_TXN = 'txn';
    public static final String PIPE_BILL = 'bill';
    public static final String PIPE_REIMB = 'reimb';

    private final String pipeline;

    public RampSyncSchedulable(String pipeline) {
        this.pipeline = pipeline;
    }

    public void execute(SchedulableContext sc) {
        if (pipeline == PIPE_TXN) {
            System.enqueueJob(new RampTransactionSyncQueueable());
        } else if (pipeline == PIPE_BILL) {
            System.enqueueJob(new RampBillSyncQueueable());
        } else if (pipeline == PIPE_REIMB) {
            System.enqueueJob(new RampReimbursementSyncQueueable());
        } else if (pipeline == PIPE_GL || pipeline == PIPE_MASTER) {
            System.enqueueJob(new RampMasterSyncQueueable());   // GL account sync
        } else if (pipeline == PIPE_VAR) {
            System.enqueueJob(new RampVariableSyncQueueable());
        } else if (pipeline == PIPE_VENDOR) {
            System.enqueueJob(new RampVendorSyncQueueable());
        }
    }
}
