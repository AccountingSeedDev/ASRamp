/**
 * @description Callout-safe wrapper around the master-data (GL account) sync so
 * it can be kicked off from a scheduled job. RampGLAccountService.syncAllGLAccounts()
 * makes synchronous HTTP callouts, which scheduled Apex can't do directly — a
 * Queueable can.
 */
public class RampMasterSyncQueueable implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext ctx) {
        try {
            RampGLAccountService.syncAllGLAccounts();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RampMasterSyncQueueable failed: ' + e.getMessage());
        }
    }
}
