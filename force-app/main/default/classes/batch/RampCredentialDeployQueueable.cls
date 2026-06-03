/**
 * @description Deploys a Ramp_Credential__mdt record via the Apex Metadata API
 * from an ASYNCHRONOUS context. Metadata.Operations.enqueueDeployment is not
 * supported when called synchronously from a Lightning (@AuraEnabled) request —
 * it throws an uncatchable internal error there. Running it from a Queueable
 * (enqueued by RampConfigurationController.saveCredential) avoids that.
 *
 * Only primitive field values are held as state (Metadata.* objects aren't safely
 * serializable across the Queueable boundary); the container is rebuilt here.
 */
public class RampCredentialDeployQueueable implements Queueable {

    private final String developerName;
    private final String label;
    private final String clientId;
    private final String clientSecret;
    private final String tokenUrl;
    private final String apiBaseUrl;
    private final String scopes;
    private final Boolean isActive;

    public RampCredentialDeployQueueable(String developerName, String label, String clientId,
            String clientSecret, String tokenUrl, String apiBaseUrl, String scopes, Boolean isActive) {
        this.developerName = developerName;
        this.label = label;
        this.clientId = clientId;
        this.clientSecret = clientSecret;
        this.tokenUrl = tokenUrl;
        this.apiBaseUrl = apiBaseUrl;
        this.scopes = scopes;
        this.isActive = isActive;
    }

    public void execute(QueueableContext ctx) {
        // The Metadata API is string-based and does NOT auto-apply the package
        // namespace, so the type/field names must be namespace-qualified
        // (AcctSeedRamp__…) in a subscriber org. Derive the prefix from this
        // class's own name so it's correct in the dev org, subscriber orgs, and
        // any non-namespaced context alike.
        String ns = namespacePrefix();

        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = ns + 'Ramp_Credential.' + developerName;
        md.label = String.isBlank(label) ? developerName : label;

        md.values.add(val(ns + 'Client_ID__c', clientId));
        md.values.add(val(ns + 'Client_Secret__c', clientSecret));
        if (String.isNotBlank(tokenUrl))   md.values.add(val(ns + 'Token_URL__c', tokenUrl));
        if (String.isNotBlank(apiBaseUrl)) md.values.add(val(ns + 'API_Base_URL__c', apiBaseUrl));
        if (String.isNotBlank(scopes))     md.values.add(val(ns + 'Scopes__c', scopes));
        md.values.add(val(ns + 'Is_Active__c', isActive));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(md);
        // The Metadata API can't deploy in an @IsTest context — skip the actual
        // enqueue there (the name-building above is still covered).
        if (!Test.isRunningTest()) {
            Metadata.Operations.enqueueDeployment(container, null);
        }
    }

    /** '<namespace>__' for the managed package (e.g. 'AcctSeedRamp__'), or '' if none. */
    @TestVisible
    private static String namespacePrefix() {
        String className = RampCredentialDeployQueueable.class.getName(); // e.g. 'AcctSeedRamp.RampCredentialDeployQueueable'
        return className.contains('.') ? className.substringBefore('.') + '__' : '';
    }

    private static Metadata.CustomMetadataValue val(String field, Object value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        return v;
    }
}
