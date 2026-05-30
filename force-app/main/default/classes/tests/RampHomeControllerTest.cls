/**
 * @description Tests for RampHomeController.getHomeData — pipelines (incl. the
 * reimbursement payable pipeline) and Automated-Job-Results-fed metrics.
 */
@IsTest
private class RampHomeControllerTest {

    @TestSetup
    static void setup() { TestDataFactory.getInstance().initialize(); }

    @IsTest
    static void getHomeData_buildsPipelinesAndJobMetrics() {
        insert new AcctSeed__Automated_Job_Results__c(
            AcctSeed__Schedule_Job_Type__c = RampJobResultLogger.JOB_CARD_SYNC,
            AcctSeed__Processed__c = 10, AcctSeed__Succeeded__c = 8, AcctSeed__Failed__c = 2
        );

        Test.startTest();
        RampHomeController.HomeData d = RampHomeController.getHomeData();
        Test.stopTest();

        System.assertEquals(4, d.pipelines.size(), 'master + txn + bill + reimb');
        Boolean reimbImplemented = false;
        Boolean billImplemented = false;
        for (RampHomeController.Pipeline p : d.pipelines) {
            if (p.id == 'reimb') reimbImplemented = p.implemented;
            if (p.id == 'bill') billImplemented = p.implemented;
        }
        System.assert(reimbImplemented, 'reimbursement pipeline is live');
        System.assert(billImplemented, 'bill pipeline is live');

        // Automated Job Results feed the metrics.
        System.assertEquals(3, d.jobs.size());
        System.assert(d.recordsProcessed >= 10, 'recordsProcessed sourced from AJR');
        Boolean cardSeen = false;
        for (RampHomeController.JobMetric j : d.jobs) {
            if (j.label == 'Card transactions') {
                cardSeen = true;
                System.assertEquals(10, j.processed);
                System.assertEquals(2, j.failed);
                System.assertEquals('errors', j.statusKind);
            }
        }
        System.assert(cardSeen, 'card job metric present');
    }
}
