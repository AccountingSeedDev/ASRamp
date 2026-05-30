/**
 * @description Tests for RampJobResultLogger — Automated Job Results insert/update.
 */
@IsTest
private class RampJobResultLoggerTest {

    @IsTest
    static void record_insertsThenUpdatesSameRecord() {
        Test.startTest();
        Id id = RampJobResultLogger.record(null, RampJobResultLogger.JOB_CARD_SYNC, 10, 8, 2, 'first');
        System.assertNotEquals(null, id, 'should insert an AJR');

        Id id2 = RampJobResultLogger.record(id, RampJobResultLogger.JOB_CARD_SYNC, 25, 22, 3, 'first\nsecond');
        Test.stopTest();

        System.assertEquals(id, id2, 'should update the same AJR, not create a new one');
        Integer cnt = [SELECT COUNT() FROM AcctSeed__Automated_Job_Results__c WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_CARD_SYNC];
        System.assertEquals(1, cnt);

        AcctSeed__Automated_Job_Results__c a = [
            SELECT AcctSeed__Schedule_Job_Type__c, AcctSeed__Processed__c, AcctSeed__Succeeded__c, AcctSeed__Failed__c, AcctSeed__Notes__c
            FROM AcctSeed__Automated_Job_Results__c WHERE Id = :id
        ];
        System.assertEquals(RampJobResultLogger.JOB_CARD_SYNC, a.AcctSeed__Schedule_Job_Type__c);
        System.assertEquals(25, a.AcctSeed__Processed__c);
        System.assertEquals(22, a.AcctSeed__Succeeded__c);
        System.assertEquals(3, a.AcctSeed__Failed__c);
    }

    @IsTest
    static void appendNote_buildsAndCaps() {
        System.assertEquals('a', RampJobResultLogger.appendNote(null, 'a'));
        System.assertEquals('a\nb', RampJobResultLogger.appendNote('a', 'b'));
        System.assertEquals('a', RampJobResultLogger.appendNote('a', null));
    }
}
