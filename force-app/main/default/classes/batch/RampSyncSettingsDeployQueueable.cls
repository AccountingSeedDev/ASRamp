/**
 * @description Deploys the Ramp_Sync_Settings__mdt.Default record via the Apex
 * Metadata API from an async context (same constraint as
 * RampCredentialDeployQueueable — enqueueDeployment can't run synchronously from
 * an @AuraEnabled request). A CMDT deploy replaces the record, so ALL settings
 * values are written here; the caller overlays only what changed.
 */
public class RampSyncSettingsDeployQueueable implements Queueable {

    private final String defaultLedger;
    private final String defaultJEStatus;
    private final String syncGrouping;
    private final Boolean sendSyncAck;
    private final Boolean vendorMatchRequiresPaymentHistory;
    private final Boolean enableReferenceLookup;
    private final String referenceKeyTemplate;

    public RampSyncSettingsDeployQueueable(String defaultLedger, String defaultJEStatus,
            String syncGrouping, Boolean sendSyncAck, Boolean vendorMatchRequiresPaymentHistory,
            Boolean enableReferenceLookup, String referenceKeyTemplate) {
        this.defaultLedger = defaultLedger;
        this.defaultJEStatus = defaultJEStatus;
        this.syncGrouping = syncGrouping;
        this.sendSyncAck = sendSyncAck;
        this.vendorMatchRequiresPaymentHistory = vendorMatchRequiresPaymentHistory;
        this.enableReferenceLookup = enableReferenceLookup;
        this.referenceKeyTemplate = referenceKeyTemplate;
    }

    public void execute(QueueableContext ctx) {
        String ns = namespacePrefix();
        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = ns + 'Ramp_Sync_Settings.Default';
        md.label = 'Default';

        if (String.isNotBlank(defaultLedger))   md.values.add(val(ns + 'Default_Ledger__c', defaultLedger));
        if (String.isNotBlank(defaultJEStatus)) md.values.add(val(ns + 'Default_JE_Status__c', defaultJEStatus));
        if (String.isNotBlank(syncGrouping))    md.values.add(val(ns + 'Sync_Grouping__c', syncGrouping));
        md.values.add(val(ns + 'Send_Sync_Ack__c', sendSyncAck == true));
        md.values.add(val(ns + 'Vendor_Match_Requires_Payment_History__c', vendorMatchRequiresPaymentHistory == true));
        md.values.add(val(ns + 'Enable_Reference_Lookup__c', enableReferenceLookup == true));
        md.values.add(val(ns + 'Reference_Key_Template__c', referenceKeyTemplate));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(md);
        if (!Test.isRunningTest()) {
            Metadata.Operations.enqueueDeployment(container, null);
        }
    }

    /** '<namespace>__' for the managed package, or '' if none. */
    @TestVisible
    private static String namespacePrefix() {
        String className = RampSyncSettingsDeployQueueable.class.getName();
        return className.contains('.') ? className.substringBefore('.') + '__' : '';
    }

    private static Metadata.CustomMetadataValue val(String field, Object value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        return v;
    }
}
