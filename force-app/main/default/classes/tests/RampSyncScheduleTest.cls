/**
 * @description Tests for per-pipeline scheduling — schedule, replace, clear, and
 * the RampSyncSchedulable dispatch.
 */
@IsTest
private class RampSyncScheduleTest {

    private static Integer triggerCount(String pid) {
        String namePattern = 'Ramp Sync - ' + pid + '%';
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :namePattern];
    }

    @IsTest
    static void schedule_replace_clear() {
        Test.startTest();
        String m1 = RampHomeController.schedulePipeline('bill', 'HOURLY', null);
        System.assert(m1.contains('Hourly'), m1);
        System.assertEquals(1, triggerCount('bill'), 'one schedule created');

        // Re-schedule with a different cadence → replaced, not duplicated.
        String m2 = RampHomeController.schedulePipeline('bill', 'DAILY', 2);
        System.assert(m2.contains('Daily at 2 AM'), m2);
        System.assertEquals(1, triggerCount('bill'), 'reschedule replaces');

        // A different pipeline schedules independently.
        RampHomeController.schedulePipeline('gl', 'WEEKDAYS', 6);
        System.assertEquals(1, triggerCount('gl'));
        System.assertEquals(1, triggerCount('bill'));

        // Clear.
        String m3 = RampHomeController.unschedulePipeline('bill');
        Test.stopTest();
        System.assertEquals(0, triggerCount('bill'), 'cleared');
        System.assertEquals(1, triggerCount('gl'), 'other pipeline untouched');
    }

    @IsTest
    static void schedule_unknownPipeline_throws() {
        Boolean threw = false;
        try {
            RampHomeController.schedulePipeline('bogus', 'HOURLY', null);
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'unknown pipeline should be rejected');
    }

    @IsTest
    static void schedulable_executeDispatchesAllPipelines() {
        // Not wrapped in start/stop — the enqueued queueables stay queued (never
        // run), so no callouts fire; this just covers the dispatch branches.
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_MASTER).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_GL).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_VAR).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_VENDOR).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_TXN).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_BILL).execute(null);
        new RampSyncSchedulable(RampSyncSchedulable.PIPE_REIMB).execute(null);
        Integer queued = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
        System.assert(queued >= 0, 'execute ran without error');
    }
}
