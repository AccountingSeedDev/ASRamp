/**
 * @description Read-only aggregator for the Ramp Integration Home (rampHome LWC).
 *
 * Composes the home dashboard's data in one cacheable call — connection/setup
 * state, per-pipeline counts, roll-up KPIs, a settings snapshot, recent sync-run
 * metrics, and the follow-up queue. SOQL-only (no callouts/DML) so it can be
 * cacheable and refreshed with refreshApex().
 *
 * Pipelines (all live): master data (GL/vars → Ramp), card transactions (→
 * Journal Entries), bills (→ vendor Payables + payments), and reimbursements (→
 * employee Payables + payments). Run-level metrics come from Accounting Seed's
 * Automated Job Results (AcctSeed__Automated_Job_Results__c) that each sync logs.
 */
public with sharing class RampHomeController {

    // ───────────────────────── wrapper types ─────────────────────────
    public class Pipeline {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String shortName;
        @AuraEnabled public String target;
        @AuraEnabled public String direction;
        @AuraEnabled public String fromLabel;
        @AuraEnabled public String toLabel;
        @AuraEnabled public String phase;
        @AuraEnabled public String icon;
        @AuraEnabled public Boolean implemented = false;
        @AuraEnabled public String statusKind;
        @AuraEnabled public Integer synced = 0;
        @AuraEnabled public Integer pending = 0;
        @AuraEnabled public Integer failed = 0;
        @AuraEnabled public Integer skipped = 0;
        @AuraEnabled public String records;
        @AuraEnabled public String blurb;
        @AuraEnabled public String action;
        @AuraEnabled public String lastRun;   // AJR last-run summary
        @AuraEnabled public Boolean scheduled = false;
        @AuraEnabled public String scheduleSummary;
        @AuraEnabled public Datetime nextRun;
        @AuraEnabled public String cron;
    }

    public class Step {
        @AuraEnabled public String id;
        @AuraEnabled public String title;
        @AuraEnabled public String descr;
        @AuraEnabled public String state;
        public Boolean done = false;
    }

    public class Setting {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Boolean isSet = false;
    }

    public class Failure {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String rampId;
        @AuraEnabled public String objType;
        @AuraEnabled public String pipe;
        @AuraEnabled public String action;     // which sync to re-run
        @AuraEnabled public Date theDate;
        @AuraEnabled public String error;
    }

    /** Run-level metrics sourced from Automated Job Results. */
    public class JobMetric {
        @AuraEnabled public String jobType;
        @AuraEnabled public String label;
        @AuraEnabled public Integer processed = 0;
        @AuraEnabled public Integer succeeded = 0;
        @AuraEnabled public Integer failed = 0;
        @AuraEnabled public Datetime lastRun;
        @AuraEnabled public String statusKind;  // good | errors | notset
        @AuraEnabled public Boolean hasRun = false;
    }

    public class HomeData {
        @AuraEnabled public Boolean connected = false;
        @AuraEnabled public Boolean accountingConfigured = false;
        @AuraEnabled public Boolean setupComplete = false;
        @AuraEnabled public String business;
        @AuraEnabled public Integer donePct = 0;
        @AuraEnabled public Integer recordsProcessed = 0;   // Σ latest-run processed (AJR)
        @AuraEnabled public Integer syncedRecent = 0;       // Σ latest-run succeeded (AJR)
        @AuraEnabled public Integer pendingTotal = 0;       // live pending across pipelines
        @AuraEnabled public Integer failedTotal = 0;        // live follow-up queue size
        @AuraEnabled public List<Step> steps = new List<Step>();
        @AuraEnabled public List<Pipeline> pipelines = new List<Pipeline>();
        @AuraEnabled public List<JobMetric> jobs = new List<JobMetric>();
        @AuraEnabled public List<Setting> settings = new List<Setting>();
        @AuraEnabled public List<Failure> failures = new List<Failure>();
    }

    // ───────────────────────── entry point ─────────────────────────
    @AuraEnabled(cacheable=true)
    public static HomeData getHomeData() {
        try {
            HomeData d = new HomeData();

            List<Ramp_Credential__mdt> creds = [
                SELECT Label, Client_ID__c FROM Ramp_Credential__mdt WHERE Is_Active__c = true LIMIT 1
            ];
            d.connected = !creds.isEmpty() && String.isNotBlank(creds[0].Client_ID__c);
            d.business = creds.isEmpty() ? 'Your Ramp workspace' : creds[0].Label;

            // Master data.
            Map<String, Integer> gl = RampGLAccountService.getSyncStatistics();
            Integer glTotal = nz(gl.get('total'));
            Integer glSynced = nz(gl.get('synced'));
            Integer glPending = nz(gl.get('not_synced'));
            Integer varCount = [SELECT COUNT() FROM AcctSeed__Accounting_Variable__c];

            // Live record-state stats per pipeline.
            Map<String, Integer> tx = jeStats();
            Map<String, Integer> bill = payableStats(false);   // vendor payee
            Map<String, Integer> reimb = payableStats(true);   // employee payee

            d.accountingConfigured = glSynced > 0;

            // Run-level metrics from Automated Job Results.
            Map<String, AcctSeed__Automated_Job_Results__c> ajr = latestJobResults();
            d.jobs = buildJobs(ajr);
            for (JobMetric j : d.jobs) {
                d.recordsProcessed += j.processed;
                d.syncedRecent += j.succeeded;
            }

            // Live follow-up + pending across all pipelines.
            d.failedTotal = nz(tx.get('failed')) + nz(bill.get('failed')) + nz(reimb.get('failed'));
            d.pendingTotal = nz(tx.get('pending')) + nz(bill.get('pending')) + nz(reimb.get('pending'));

            d.settings = buildSettings();
            Boolean settingsSet = false;
            for (Setting s : d.settings) { if (s.label == 'Default ledger') settingsSet = s.isSet; }

            d.steps = buildSteps(d.connected, d.accountingConfigured, glTotal, glPending, settingsSet, nz(tx.get('total')));
            Integer doneCount = 0;
            for (Step s : d.steps) { if (s.done) doneCount++; }
            d.donePct = d.steps.isEmpty() ? 0 : (Integer) Math.round(100.0 * doneCount / d.steps.size());
            d.setupComplete = doneCount == d.steps.size();

            d.pipelines = buildPipelines(glTotal, glSynced, glPending, varCount, tx, bill, reimb, ajr);

            // Attach per-pipeline scheduled-job state.
            Map<String, CronTrigger> sched = scheduledByPipeline();
            for (Pipeline p : d.pipelines) {
                CronTrigger ct = sched.get(p.id);
                if (ct != null) {
                    p.scheduled = true;
                    p.nextRun = ct.NextFireTime;
                    p.cron = ct.CronExpression;
                    p.scheduleSummary = summarizeCron(ct.CronExpression);
                }
            }

            d.failures = recentFailures();
            return d;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading Ramp home: ' + e.getMessage());
        }
    }

    // ───────────────────────── scheduling ─────────────────────────
    private static final Map<String, String> PIPE_LABELS = new Map<String, String>{
        'master' => 'Master data sync', 'txn' => 'Card transactions', 'bill' => 'Bills', 'reimb' => 'Reimbursements'
    };

    /**
     * @description Schedule (or re-schedule) a pipeline's sync. Any existing
     * schedule for the pipeline is aborted and replaced with the new cadence.
     * @param frequency HOURLY | EVERY_6H | DAILY | WEEKDAYS
     * @param hour      hour-of-day 0–23 for DAILY/WEEKDAYS (ignored otherwise)
     */
    @AuraEnabled
    public static String schedulePipeline(String pipelineId, String frequency, Integer hour) {
        try {
            String pid = requirePipeline(pipelineId);
            Integer hr = (hour == null) ? 1 : Math.mod(hour, 24);
            String cron = buildCron(frequency, hr);
            // Replace any existing schedule, then schedule under a fresh unique
            // name (avoids the same-name "already scheduled" race in one txn).
            abortExisting(pid);
            String name = 'Ramp Sync - ' + pid + ' - ' + RampTransactionService.newRunId();
            System.schedule(name, cron, new RampSyncSchedulable(pid));
            return 'Scheduled ' + PIPE_LABELS.get(pid) + ' — ' + summarizeCron(cron) + '.';
        } catch (Exception e) {
            throw new AuraHandledException('Could not schedule: ' + e.getMessage());
        }
    }

    /** @description Remove a pipeline's scheduled job. */
    @AuraEnabled
    public static String unschedulePipeline(String pipelineId) {
        try {
            String pid = requirePipeline(pipelineId);
            Integer n = abortExisting(pid);
            return n > 0 ? 'Cleared schedule for ' + PIPE_LABELS.get(pid) + '.' : 'No schedule found for ' + PIPE_LABELS.get(pid) + '.';
        } catch (Exception e) {
            throw new AuraHandledException('Could not clear schedule: ' + e.getMessage());
        }
    }

    private static String requirePipeline(String pid) {
        if (!PIPE_LABELS.containsKey(pid)) throw new RampHomeException('Unknown pipeline: ' + pid);
        return pid;
    }
    private static Integer abortExisting(String pid) {
        String namePattern = 'Ramp Sync - ' + pid + '%';
        Integer n = 0;
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :namePattern]) {
            System.abortJob(ct.Id); n++;
        }
        return n;
    }

    private static String buildCron(String frequency, Integer hour) {
        if (frequency == 'HOURLY') return '0 0 * * * ?';
        if (frequency == 'EVERY_6H') return '0 0 0,6,12,18 * * ?';
        if (frequency == 'WEEKDAYS') return '0 0 ' + hour + ' ? * MON-FRI';
        return '0 0 ' + hour + ' * * ?'; // DAILY (default)
    }

    private static String summarizeCron(String cron) {
        if (cron == '0 0 * * * ?') return 'Hourly';
        if (cron == '0 0 0,6,12,18 * * ?') return 'Every 6 hours';
        List<String> parts = cron.split(' ');
        if (parts.size() >= 6) {
            String hr = formatHour(parts[2]);
            return parts[5] == 'MON-FRI' ? 'Weekdays at ' + hr : 'Daily at ' + hr;
        }
        return 'Custom schedule';
    }
    private static String formatHour(String hh) {
        try {
            Integer h = Integer.valueOf(hh);
            String suffix = h < 12 ? 'AM' : 'PM';
            Integer h12 = Math.mod(h, 12); if (h12 == 0) h12 = 12;
            return h12 + ' ' + suffix;
        } catch (Exception e) { return hh + ':00'; }
    }

    private static Map<String, CronTrigger> scheduledByPipeline() {
        Map<String, CronTrigger> m = new Map<String, CronTrigger>();
        for (CronTrigger ct : [
            SELECT Id, CronJobDetail.Name, NextFireTime, State, CronExpression
            FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Ramp Sync - %'
        ]) {
            // Name = 'Ramp Sync - <pid> - <epoch>' → pid is the segment after the prefix.
            String pid = ct.CronJobDetail.Name.substringAfter('Ramp Sync - ').substringBefore(' - ');
            m.put(pid, ct);
        }
        return m;
    }

    public class RampHomeException extends Exception {}

    // ───────────────────────── stats helpers ─────────────────────────
    private static Integer nz(Integer i) { return i == null ? 0 : i; }

    private static Map<String, Integer> jeStats() {
        Map<String, Integer> s = new Map<String, Integer>{ 'pending' => 0, 'synced' => 0, 'failed' => 0, 'total' => 0 };
        for (AggregateResult ar : [
            SELECT Ramp_Sync_Status__c status, COUNT(Id) c FROM AcctSeed__Journal_Entry__c
            WHERE Ramp_Sync_Status__c != null GROUP BY Ramp_Sync_Status__c
        ]) {
            tally(s, (String) ar.get('status'), (Integer) ar.get('c'));
        }
        return s;
    }

    /** Payable stats split by payee: employee=true → reimbursements; false → bills. */
    private static Map<String, Integer> payableStats(Boolean employeePayee) {
        Map<String, Integer> s = new Map<String, Integer>{ 'pending' => 0, 'synced' => 0, 'failed' => 0, 'total' => 0 };
        List<AggregateResult> rows = employeePayee
            ? [SELECT Ramp_Sync_Status__c status, COUNT(Id) c FROM AcctSeed__Account_Payable__c
               WHERE Ramp_Sync_Status__c != null AND AcctSeed__Employee__c != null GROUP BY Ramp_Sync_Status__c]
            : [SELECT Ramp_Sync_Status__c status, COUNT(Id) c FROM AcctSeed__Account_Payable__c
               WHERE Ramp_Sync_Status__c != null AND AcctSeed__Vendor__c != null GROUP BY Ramp_Sync_Status__c];
        for (AggregateResult ar : rows) tally(s, (String) ar.get('status'), (Integer) ar.get('c'));
        return s;
    }

    private static void tally(Map<String, Integer> s, String status, Integer c) {
        s.put('total', s.get('total') + c);
        if (status == 'Pending') s.put('pending', c);
        else if (status == 'Synced_To_Ramp') s.put('synced', c);
        else if (status == 'Failed') s.put('failed', c);
    }

    // ───────────────────────── Automated Job Results ─────────────────────────
    private static Map<String, AcctSeed__Automated_Job_Results__c> latestJobResults() {
        Map<String, AcctSeed__Automated_Job_Results__c> latest = new Map<String, AcctSeed__Automated_Job_Results__c>();
        for (AcctSeed__Automated_Job_Results__c r : [
            SELECT AcctSeed__Schedule_Job_Type__c, AcctSeed__Processed__c, AcctSeed__Succeeded__c, AcctSeed__Failed__c, CreatedDate
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c LIKE 'Ramp %'
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]) {
            String t = r.AcctSeed__Schedule_Job_Type__c;
            if (!latest.containsKey(t)) latest.put(t, r); // first seen = most recent
        }
        return latest;
    }

    private static List<JobMetric> buildJobs(Map<String, AcctSeed__Automated_Job_Results__c> ajr) {
        List<JobMetric> jobs = new List<JobMetric>();
        jobs.add(jobMetric(RampJobResultLogger.JOB_CARD_SYNC, 'Card transactions', ajr));
        jobs.add(jobMetric(RampJobResultLogger.JOB_BILL_SYNC, 'Bills', ajr));
        jobs.add(jobMetric(RampJobResultLogger.JOB_REIMBURSEMENT_SYNC, 'Reimbursements', ajr));
        return jobs;
    }

    private static JobMetric jobMetric(String jobType, String label, Map<String, AcctSeed__Automated_Job_Results__c> ajr) {
        JobMetric j = new JobMetric();
        j.jobType = jobType;
        j.label = label;
        AcctSeed__Automated_Job_Results__c r = ajr.get(jobType);
        if (r == null) {
            j.statusKind = 'notset';
            return j;
        }
        j.hasRun = true;
        j.processed = (Integer) nzDec(r.AcctSeed__Processed__c);
        j.succeeded = (Integer) nzDec(r.AcctSeed__Succeeded__c);
        j.failed = (Integer) nzDec(r.AcctSeed__Failed__c);
        j.lastRun = r.CreatedDate;
        j.statusKind = j.failed > 0 ? 'errors' : 'good';
        return j;
    }

    private static Decimal nzDec(Decimal d) { return d == null ? 0 : d; }

    // ───────────────────────── steps ─────────────────────────
    private static List<Step> buildSteps(Boolean connected, Boolean acctConfigured,
            Integer glTotal, Integer glPending, Boolean settingsSet, Integer txTotal) {
        List<Step> steps = new List<Step>();
        steps.add(step('connect',  'Connect to Ramp',           'Authorize with your Ramp OAuth client ID and secret.', connected));
        steps.add(step('acctconn', 'Establish accounting link', 'Open the accounting connection so Ramp can exchange data.', acctConfigured));
        steps.add(step('master',   'Map master data',           'Sync GL accounts and accounting variables to Ramp.', glTotal > 0 && glPending == 0));
        steps.add(step('settings', 'Configure sync settings',   'Set the clearing GL, ledger and JE status.', settingsSet));
        steps.add(step('firstrun', 'Run your first sync',        'Pull ready records from Ramp into Accounting Seed.', txTotal > 0));
        Boolean markedCurrent = false;
        for (Step s : steps) {
            if (s.done) { s.state = 'done'; }
            else if (!markedCurrent) { s.state = 'current'; markedCurrent = true; }
            else { s.state = 'todo'; }
        }
        return steps;
    }
    private static Step step(String id, String title, String descr, Boolean done) {
        Step s = new Step(); s.id = id; s.title = title; s.descr = descr; s.done = done; return s;
    }

    // ───────────────────────── pipelines ─────────────────────────
    private static List<Pipeline> buildPipelines(Integer glTotal, Integer glSynced, Integer glPending,
            Integer varCount, Map<String, Integer> tx, Map<String, Integer> bill, Map<String, Integer> reimb,
            Map<String, AcctSeed__Automated_Job_Results__c> ajr) {
        List<Pipeline> pipes = new List<Pipeline>();

        Pipeline master = new Pipeline();
        master.id = 'master'; master.name = 'Master data sync'; master.shortName = 'Master data';
        master.target = 'GL accounts · Variables · Vendors'; master.direction = 'out';
        master.fromLabel = 'Accounting Seed'; master.toLabel = 'Ramp'; master.phase = 'Phase 1'; master.icon = 'database';
        master.implemented = true; master.synced = glSynced; master.pending = glPending; master.failed = 0;
        master.records = glTotal + ' GL accounts · ' + varCount + ' variables';
        master.statusKind = glTotal == 0 ? 'notset' : (glPending > 0 ? 'warning' : 'active');
        master.blurb = 'Pushes the chart of accounts and dimensions to Ramp so card coding stays in lockstep.';
        master.action = 'syncGL';
        pipes.add(master);

        pipes.add(payablePipe('txn', 'Card transactions', 'Transactions', 'Journal Entries', 'in', 'Pipeline 1', 'card',
            tx, tx.get('synced') + ' journal entries', 'syncTxn',
            'Cleared card spend posts as balanced journal entries — expense debit, card clearing credit.',
            RampJobResultLogger.JOB_CARD_SYNC, ajr));

        pipes.add(payablePipe('bill', 'Bills', 'Bills', 'Vendor Payables', 'in', 'Pipeline 2', 'file',
            bill, bill.get('total') + ' payables', 'syncBill',
            'Vendor bills post as Account Payables; paid bills add a Cash Disbursement that clears them.',
            RampJobResultLogger.JOB_BILL_SYNC, ajr));

        pipes.add(payablePipe('reimb', 'Reimbursements', 'Reimbursements', 'Employee Payables', 'in', 'Pipeline 3', 'receipt',
            reimb, reimb.get('total') + ' reimbursements', 'syncReimb',
            'Employee out-of-pocket spend posts as employee Payables; reimbursed items add a Cash Disbursement.',
            RampJobResultLogger.JOB_REIMBURSEMENT_SYNC, ajr));

        return pipes;
    }

    private static Pipeline payablePipe(String id, String name, String shortName, String target, String direction,
            String phase, String icon, Map<String, Integer> stats, String records, String action, String blurb,
            String jobType, Map<String, AcctSeed__Automated_Job_Results__c> ajr) {
        Pipeline p = new Pipeline();
        p.id = id; p.name = name; p.shortName = shortName; p.target = target; p.direction = direction;
        p.fromLabel = 'Ramp'; p.toLabel = 'Accounting Seed'; p.phase = phase; p.icon = icon;
        p.implemented = true;
        p.synced = nz(stats.get('synced')); p.pending = nz(stats.get('pending')); p.failed = nz(stats.get('failed'));
        p.records = records; p.action = action; p.blurb = blurb;
        Integer total = nz(stats.get('total'));
        p.statusKind = total == 0 ? 'notset' : (p.failed > 0 ? 'errors' : (p.pending > 0 ? 'warning' : 'active'));
        AcctSeed__Automated_Job_Results__c r = ajr.get(jobType);
        if (r != null) {
            p.lastRun = 'Last run: ' + (Integer) nzDec(r.AcctSeed__Processed__c) + ' processed · '
                + (Integer) nzDec(r.AcctSeed__Failed__c) + ' failed';
        }
        return p;
    }

    // ───────────────────────── settings ─────────────────────────
    private static List<Setting> buildSettings() {
        List<Setting> out = new List<Setting>();
        List<Ramp_Sync_Settings__mdt> rows = [
            SELECT Default_Ledger__c, Default_JE_Status__c, Send_Sync_Ack__c, Sync_Grouping__c
            FROM Ramp_Sync_Settings__mdt WHERE DeveloperName = 'Default' LIMIT 1
        ];
        Ramp_Sync_Settings__mdt r = rows.isEmpty() ? null : rows[0];
        out.add(setting('Default ledger', r == null ? null : r.Default_Ledger__c));
        out.add(setting('Default JE status', r == null ? null : r.Default_JE_Status__c));
        out.add(setting('Sync grouping', r == null ? null : r.Sync_Grouping__c));
        Setting ack = new Setting();
        ack.label = 'Send sync acknowledgement'; ack.isSet = (r != null && r.Send_Sync_Ack__c == true);
        ack.value = ack.isSet ? 'On' : 'Off';
        out.add(ack);
        out.add(setting('Card clearing GL', glSpec('Ramp_Card_Clearing') ? 'Configured (GL Account Specification)' : null));
        out.add(setting('Suspense GL', glSpec('Ramp_Suspense') ? 'Configured (GL Account Specification)' : null));
        out.add(setting('Bill payment bank GL', glSpec('Ramp_Bill_Payment_Bank') ? 'Configured (GL Account Specification)' : null));
        return out;
    }
    private static Setting setting(String label, String value) {
        Setting s = new Setting();
        s.label = label; s.isSet = String.isNotBlank(value); s.value = s.isSet ? value : 'Not set';
        return s;
    }
    private static Boolean glSpec(String devName) {
        return [SELECT COUNT() FROM AcctSeed__GL_Account_Specification__mdt WHERE DeveloperName = :devName] > 0;
    }

    // ───────────────────────── follow-up queue ─────────────────────────
    private static List<Failure> recentFailures() {
        List<Failure> rows = new List<Failure>();
        for (AcctSeed__Journal_Entry__c je : [
            SELECT Id, Name, AcctSeed__ExtId__c, AcctSeed__Journal_Date__c, Ramp_Sync_Error__c
            FROM AcctSeed__Journal_Entry__c WHERE Ramp_Sync_Status__c = 'Failed'
            ORDER BY LastModifiedDate DESC LIMIT 25
        ]) {
            rows.add(failure(je.Id, je.Name, je.AcctSeed__ExtId__c, 'Journal Entry', 'txn', 'syncTxn', je.AcctSeed__Journal_Date__c, je.Ramp_Sync_Error__c));
        }
        for (AcctSeed__Account_Payable__c ap : [
            SELECT Id, Name, AcctSeed__ExtId__c, AcctSeed__Date__c, Ramp_Sync_Error__c, AcctSeed__Employee__c
            FROM AcctSeed__Account_Payable__c WHERE Ramp_Sync_Status__c = 'Failed'
            ORDER BY LastModifiedDate DESC LIMIT 25
        ]) {
            Boolean isReimb = ap.AcctSeed__Employee__c != null;
            rows.add(failure(ap.Id, ap.Name, ap.AcctSeed__ExtId__c, isReimb ? 'Reimbursement Payable' : 'Vendor Payable',
                isReimb ? 'reimb' : 'bill', isReimb ? 'syncReimb' : 'syncBill', ap.AcctSeed__Date__c, ap.Ramp_Sync_Error__c));
        }
        return rows;
    }
    private static Failure failure(Id recId, String name, String rampId, String objType, String pipe, String action, Date d, String error) {
        Failure f = new Failure();
        f.id = recId; f.name = name; f.rampId = rampId; f.objType = objType; f.pipe = pipe; f.action = action; f.theDate = d; f.error = error;
        return f;
    }
}
