/**
 * @description Callout-safe wrapper so the vendor sync can run from a scheduled
 * job. Scheduled Apex can't make callouts directly; a Queueable can. Delegates to
 * RampConfigurationController.syncVendors, which kicks off RampVendorSyncBatch.
 */
public class RampVendorSyncQueueable implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext ctx) {
        try {
            RampConfigurationController.syncVendors();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RampVendorSyncQueueable failed: ' + e.getMessage());
        }
    }
}
