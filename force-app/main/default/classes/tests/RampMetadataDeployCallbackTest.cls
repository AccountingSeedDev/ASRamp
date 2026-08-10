/**
 * @description Tests for RampMetadataDeployCallback — a failed Custom Metadata
 * deploy must surface in the Automated Job Results error queue instead of being
 * swallowed while the UI reports the save as successful (FS-15092).
 */
@IsTest
private class RampMetadataDeployCallbackTest {

    private static Metadata.DeployResult resultWith(Metadata.DeployStatus status, String fullName, String problem) {
        Metadata.DeployResult r = new Metadata.DeployResult();
        r.status = status;
        if (problem != null) {
            Metadata.DeployMessage m = new Metadata.DeployMessage();
            m.fullName = fullName;
            m.problem = problem;
            Metadata.DeployDetails d = new Metadata.DeployDetails();
            d.componentFailures = new List<Metadata.DeployMessage>{ m };
            r.details = d;
        }
        return r;
    }

    private static List<AcctSeed__Automated_Job_Results__c> settingsSaveResults() {
        return [
            SELECT AcctSeed__Schedule_Job_Type__c, AcctSeed__Processed__c,
                   AcctSeed__Succeeded__c, AcctSeed__Failed__c, AcctSeed__Notes__c
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c = :RampMetadataDeployCallback.JOB_SETTINGS_SAVE
        ];
    }

    @IsTest
    static void handleResult_failedDeploy_logsToErrorQueue() {
        Metadata.DeployResult failed = resultWith(
            Metadata.DeployStatus.FAILED, 'Ramp_Sync_Settings.Default', 'Field is not writeable');

        Test.startTest();
        new RampMetadataDeployCallback().handleResult(failed, null);
        Test.stopTest();

        List<AcctSeed__Automated_Job_Results__c> ajrs = settingsSaveResults();
        System.assertEquals(1, ajrs.size(), 'A failed settings deploy must be recorded');
        System.assertEquals(1, ajrs[0].AcctSeed__Failed__c, 'Should count as a failure');
        System.assertEquals(0, ajrs[0].AcctSeed__Succeeded__c, 'Should not count as a success');
        System.assert(ajrs[0].AcctSeed__Notes__c.contains('Field is not writeable'),
            'Notes should carry the component problem: ' + ajrs[0].AcctSeed__Notes__c);
        System.assert(ajrs[0].AcctSeed__Notes__c.contains('Ramp_Sync_Settings.Default'),
            'Notes should name the failing component: ' + ajrs[0].AcctSeed__Notes__c);
    }

    @IsTest
    static void handleResult_succeededDeploy_logsNothing() {
        Metadata.DeployResult ok = resultWith(Metadata.DeployStatus.SUCCEEDED, null, null);

        Test.startTest();
        new RampMetadataDeployCallback().handleResult(ok, null);
        Test.stopTest();

        System.assertEquals(0, settingsSaveResults().size(),
            'A successful save must not add noise to the error queue');
    }

    @IsTest
    static void handleResult_nullResult_stillLogsSomethingActionable() {
        Test.startTest();
        new RampMetadataDeployCallback().handleResult(null, null);
        Test.stopTest();

        List<AcctSeed__Automated_Job_Results__c> ajrs = settingsSaveResults();
        System.assertEquals(1, ajrs.size(), 'A missing deploy result must still be reported');
        System.assert(ajrs[0].AcctSeed__Notes__c.contains('save again'),
            'Notes should tell the user what to do: ' + ajrs[0].AcctSeed__Notes__c);
    }
}
