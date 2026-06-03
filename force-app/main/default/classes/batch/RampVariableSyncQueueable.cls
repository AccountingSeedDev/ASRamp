/**
 * @description Callout-safe wrapper so the accounting-variable (field options)
 * sync can run from a scheduled job. Scheduled Apex can't make callouts directly;
 * a Queueable can. Delegates to RampConfigurationController.syncAccountingVariables,
 * which resolves the connection + Ramp field ids and kicks off the batch.
 */
public class RampVariableSyncQueueable implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext ctx) {
        try {
            RampConfigurationController.syncAccountingVariables();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'RampVariableSyncQueueable failed: ' + e.getMessage());
        }
    }
}
