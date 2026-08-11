/**
 * @description Deploy callback for the Ramp Custom Metadata deploys.
 *
 * Metadata.Operations.enqueueDeployment() is fire-and-forget: passing a null
 * callback makes a failed deploy completely invisible, while the LWC has already
 * shown the user "settings saved". A save that silently did not stick then looks
 * identical to one that worked (FS-15092).
 *
 * Failures (and partial successes) are recorded to Accounting Seed's Automated Job
 * Results, so a settings save that failed shows up in the same error queue as
 * every other Ramp job outcome. Successes are not logged — they would just be
 * noise on a screen used to find problems.
 */
public with sharing class RampMetadataDeployCallback implements Metadata.DeployCallback {

    public static final String JOB_SETTINGS_SAVE = 'Ramp Settings Save';

    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result != null && result.status == Metadata.DeployStatus.SUCCEEDED) {
            return;
        }
        RampJobResultLogger.record(null, JOB_SETTINGS_SAVE, 1, 0, 1, describeFailure(result));
    }

    /**
     * @description Human-readable failure summary. The component-level problems are
     * what identify which setting failed, so they are listed when present.
     */
    @TestVisible
    private static String describeFailure(Metadata.DeployResult result) {
        if (result == null) {
            return 'Ramp settings save failed: the Metadata API returned no deploy result. ' +
                'Re-open Setup & configuration, confirm the values, and save again.';
        }
        List<String> parts = new List<String>{
            'Ramp settings save did not complete. Deploy status: ' + result.status + '.'
        };
        if (result.details != null && result.details.componentFailures != null) {
            for (Metadata.DeployMessage m : result.details.componentFailures) {
                parts.add((m.fullName == null ? 'component' : m.fullName) + ': ' + m.problem);
            }
        }
        parts.add('The values shown in Setup & configuration may not match what the sync will use — save again.');
        return String.join(parts, '\n');
    }
}
