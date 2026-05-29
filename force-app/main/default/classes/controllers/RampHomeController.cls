/**
 * @description Read-only aggregator for the Ramp Integration Home (rampHome LWC).
 *
 * Composes the data the home dashboard needs in a single cacheable call —
 * connection / setup state, per-pipeline counts, roll-up KPIs, a settings
 * snapshot and the recent failure queue. SOQL-only (no callouts/DML) so it can
 * be `cacheable=true` and refreshed with refreshApex().
 *
 * Mutating actions (run a sync, retry) are intentionally NOT here — the LWC
 * reuses the existing RampConfigurationController.syncTransactions /
 * syncGLAccounts / syncAccountingVariables so there is one source of truth for
 * how a sync is kicked off.
 *
 * Pipelines 2 (Bills) and 3 (Reimbursements) are described in design.md but not
 * yet implemented in this package, so they are returned with implemented=false
 * and render as a muted "not enabled yet" state. When those queueables land,
 * fill in their branches in buildPipelines() and flip implemented=true.
 */
public with sharing class RampHomeController {

    // ───────────────────────── wrapper types ─────────────────────────
    public class Pipeline {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String shortName;
        @AuraEnabled public String target;
        @AuraEnabled public String direction;   // 'in' (Ramp→AS) | 'out' (AS→Ramp)
        @AuraEnabled public String fromLabel;
        @AuraEnabled public String toLabel;
        @AuraEnabled public String phase;
        @AuraEnabled public String icon;
        @AuraEnabled public Boolean implemented = false;
        @AuraEnabled public String statusKind;  // active|errors|warning|pending|notset
        @AuraEnabled public Integer synced = 0;
        @AuraEnabled public Integer pending = 0;
        @AuraEnabled public Integer failed = 0;
        @AuraEnabled public Integer skipped = 0;
        @AuraEnabled public String records;
        @AuraEnabled public String blurb;
        @AuraEnabled public String action;      // LWC action key: 'syncGL'|'syncTxn'|null
    }

    public class Step {
        @AuraEnabled public String id;
        @AuraEnabled public String title;
        @AuraEnabled public String descr;
        @AuraEnabled public String state;       // done|current|todo
        public Boolean done = false;
    }

    public class Setting {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Boolean isSet = false;
    }

    public class Failure {
        @AuraEnabled public String id;          // Salesforce record Id
        @AuraEnabled public String name;        // record Name
        @AuraEnabled public String rampId;      // AcctSeed__ExtId__c (Ramp object id)
        @AuraEnabled public String objType;     // 'Journal Entry'
        @AuraEnabled public String pipe;        // pipeline id
        @AuraEnabled public Date theDate;
        @AuraEnabled public String error;
    }

    public class HomeData {
        @AuraEnabled public Boolean connected = false;
        @AuraEnabled public Boolean accountingConfigured = false;
        @AuraEnabled public Boolean setupComplete = false;
        @AuraEnabled public String business;
        @AuraEnabled public Integer donePct = 0;
        @AuraEnabled public Integer syncedToday = 0;
        @AuraEnabled public Integer pendingTotal = 0;
        @AuraEnabled public Integer failedTotal = 0;
        @AuraEnabled public List<Step> steps = new List<Step>();
        @AuraEnabled public List<Pipeline> pipelines = new List<Pipeline>();
        @AuraEnabled public List<Setting> settings = new List<Setting>();
        @AuraEnabled public List<Failure> failures = new List<Failure>();
    }

    // ───────────────────────── entry point ─────────────────────────
    @AuraEnabled(cacheable=true)
    public static HomeData getHomeData() {
        try {
            HomeData d = new HomeData();

            // Active credential → connection signal + business label.
            List<Ramp_Credential__mdt> creds = [
                SELECT Label, Client_ID__c FROM Ramp_Credential__mdt
                WHERE Is_Active__c = true LIMIT 1
            ];
            d.connected = !creds.isEmpty() && String.isNotBlank(creds[0].Client_ID__c);
            d.business = creds.isEmpty() ? 'Your Ramp workspace' : creds[0].Label;

            // GL account sync stats {total, synced, not_synced}.
            Map<String, Integer> gl = RampGLAccountService.getSyncStatistics();
            Integer glTotal = nz(gl.get('total'));
            Integer glSynced = nz(gl.get('synced'));
            Integer glPending = nz(gl.get('not_synced'));
            Integer varCount = [SELECT COUNT() FROM AcctSeed__Accounting_Variable__c];

            // Journal Entry (Pipeline 1) sync stats.
            Map<String, Integer> tx = transactionStats();
            Integer txTotal = nz(tx.get('total'));
            Integer txSynced = nz(tx.get('synced'));
            Integer txPending = nz(tx.get('pending'));
            Integer txFailed = nz(tx.get('failed'));

            // "synced" is a proxy for the accounting connection being live —
            // we only get a Ramp_Id__c back after a successful connected sync.
            d.accountingConfigured = glSynced > 0;
            d.syncedToday = [
                SELECT COUNT() FROM AcctSeed__Journal_Entry__c
                WHERE Ramp_Sync_Status__c != null AND LastModifiedDate = TODAY
            ];
            d.pendingTotal = txPending;
            d.failedTotal = txFailed;

            // Settings snapshot.
            d.settings = buildSettings();
            Boolean settingsSet = false;
            for (Setting s : d.settings) { if (s.label == 'Default ledger') settingsSet = s.isSet; }

            // Setup checklist.
            d.steps = buildSteps(d.connected, d.accountingConfigured, glTotal, glPending, settingsSet, txTotal);
            Integer doneCount = 0;
            for (Step s : d.steps) { if (s.done) doneCount++; }
            d.donePct = d.steps.isEmpty() ? 0 : (Integer) Math.round(100.0 * doneCount / d.steps.size());
            d.setupComplete = doneCount == d.steps.size();

            // Pipelines.
            d.pipelines = buildPipelines(glTotal, glSynced, glPending, varCount, txTotal, txSynced, txPending, txFailed);

            // Failure queue (Pipeline 1 only for now).
            d.failures = recentFailures();

            return d;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading Ramp home: ' + e.getMessage());
        }
    }

    // ───────────────────────── helpers ─────────────────────────
    private static Integer nz(Integer i) { return i == null ? 0 : i; }

    private static Map<String, Integer> transactionStats() {
        Map<String, Integer> s = new Map<String, Integer>{
            'pending' => 0, 'synced' => 0, 'failed' => 0, 'total' => 0
        };
        for (AggregateResult ar : [
            SELECT Ramp_Sync_Status__c status, COUNT(Id) c
            FROM AcctSeed__Journal_Entry__c
            WHERE Ramp_Sync_Status__c != null
            GROUP BY Ramp_Sync_Status__c
        ]) {
            String st = (String) ar.get('status');
            Integer c = (Integer) ar.get('c');
            s.put('total', s.get('total') + c);
            if (st == 'Pending') s.put('pending', c);
            else if (st == 'Synced_To_Ramp') s.put('synced', c);
            else if (st == 'Failed') s.put('failed', c);
        }
        return s;
    }

    private static List<Step> buildSteps(Boolean connected, Boolean acctConfigured,
            Integer glTotal, Integer glPending, Boolean settingsSet, Integer txTotal) {
        List<Step> steps = new List<Step>();
        steps.add(step('connect',  'Connect to Ramp',            'Authorize with your Ramp OAuth client ID and secret.', connected));
        steps.add(step('acctconn', 'Establish accounting link',  'Open the accounting connection so Ramp can exchange data.', acctConfigured));
        steps.add(step('master',   'Map master data',            'Sync GL accounts and accounting variables to Ramp.', glTotal > 0 && glPending == 0));
        steps.add(step('settings', 'Configure sync settings',    'Set the clearing GL, ledger and JE status.', settingsSet));
        steps.add(step('firstrun', 'Run your first sync',         'Pull ready transactions from Ramp into Accounting Seed.', txTotal > 0));
        // First not-done step becomes 'current'.
        Boolean markedCurrent = false;
        for (Step s : steps) {
            if (s.done) { s.state = 'done'; }
            else if (!markedCurrent) { s.state = 'current'; markedCurrent = true; }
            else { s.state = 'todo'; }
        }
        return steps;
    }
    private static Step step(String id, String title, String descr, Boolean done) {
        Step s = new Step();
        s.id = id; s.title = title; s.descr = descr; s.done = done;
        return s;
    }

    private static List<Pipeline> buildPipelines(Integer glTotal, Integer glSynced, Integer glPending,
            Integer varCount, Integer txTotal, Integer txSynced, Integer txPending, Integer txFailed) {
        List<Pipeline> pipes = new List<Pipeline>();

        Pipeline master = new Pipeline();
        master.id = 'master'; master.name = 'Master data sync'; master.shortName = 'Master data';
        master.target = 'Vendors · GL accounts · Variables'; master.direction = 'out';
        master.fromLabel = 'Accounting Seed'; master.toLabel = 'Ramp'; master.phase = 'Phase 1'; master.icon = 'database';
        master.implemented = true; master.synced = glSynced; master.pending = glPending; master.failed = 0;
        master.records = glTotal + ' GL accounts · ' + varCount + ' variables';
        master.statusKind = glTotal == 0 ? 'notset' : (glPending > 0 ? 'warning' : 'active');
        master.blurb = 'Pushes the chart of accounts and accounting dimensions to Ramp so card coding stays in lockstep.';
        master.action = 'syncGL';
        pipes.add(master);

        Pipeline txn = new Pipeline();
        txn.id = 'txn'; txn.name = 'Card transactions'; txn.shortName = 'Transactions';
        txn.target = 'Journal Entries'; txn.direction = 'in';
        txn.fromLabel = 'Ramp'; txn.toLabel = 'Accounting Seed'; txn.phase = 'Pipeline 1'; txn.icon = 'card';
        txn.implemented = true; txn.synced = txSynced; txn.pending = txPending; txn.failed = txFailed;
        txn.records = txSynced + ' journal entries';
        txn.statusKind = txTotal == 0 ? 'notset' : (txFailed > 0 ? 'errors' : 'active');
        txn.blurb = 'Cleared card spend posts as balanced journal entries — expense GL debit, card clearing GL credit.';
        txn.action = 'syncTxn';
        pipes.add(txn);

        pipes.add(notEnabled('bill', 'Bills', 'Bills', 'Payables + Cash Disbursements', 'Pipeline 2', 'file',
            'Vendor bills sync as Account Payables, then payments close them out as Cash Disbursements.'));
        pipes.add(notEnabled('reimb', 'Reimbursements', 'Reimbursements', 'Expense Reports', 'Pipeline 3', 'receipt',
            'Approved out-of-pocket spend creates employee Expense Reports. Payback types are skipped.'));
        return pipes;
    }
    private static Pipeline notEnabled(String id, String name, String shortName, String target,
            String phase, String icon, String blurb) {
        Pipeline p = new Pipeline();
        p.id = id; p.name = name; p.shortName = shortName; p.target = target; p.direction = 'in';
        p.fromLabel = 'Ramp'; p.toLabel = 'Accounting Seed'; p.phase = phase; p.icon = icon;
        p.implemented = false; p.statusKind = 'notset'; p.records = 'Pipeline not enabled yet'; p.blurb = blurb;
        return p;
    }

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
        ack.label = 'Send sync acknowledgment'; ack.isSet = (r != null && r.Send_Sync_Ack__c == true);
        ack.value = ack.isSet ? 'On' : 'Off';
        out.add(ack);
        // Card clearing / suspense GLs are configured via GL Account Specification CMDT.
        out.add(setting('Card clearing GL', glSpec('Ramp_Card_Clearing') ? 'Configured (GL Account Specification)' : null));
        out.add(setting('Suspense GL', glSpec('Ramp_Suspense') ? 'Configured (GL Account Specification)' : null));
        return out;
    }
    private static Setting setting(String label, String value) {
        Setting s = new Setting();
        s.label = label;
        s.isSet = String.isNotBlank(value);
        s.value = s.isSet ? value : 'Not set';
        return s;
    }
    private static Boolean glSpec(String devName) {
        return [SELECT COUNT() FROM AcctSeed__GL_Account_Specification__mdt WHERE DeveloperName = :devName] > 0;
    }

    private static List<Failure> recentFailures() {
        List<Failure> rows = new List<Failure>();
        for (AcctSeed__Journal_Entry__c je : [
            SELECT Id, Name, AcctSeed__ExtId__c, AcctSeed__Journal_Date__c, Ramp_Sync_Error__c
            FROM AcctSeed__Journal_Entry__c
            WHERE Ramp_Sync_Status__c = 'Failed'
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ]) {
            Failure f = new Failure();
            f.id = je.Id; f.name = je.Name; f.rampId = je.AcctSeed__ExtId__c;
            f.objType = 'Journal Entry'; f.pipe = 'txn';
            f.theDate = je.AcctSeed__Journal_Date__c; f.error = je.Ramp_Sync_Error__c;
            rows.add(f);
        }
        return rows;
    }
}
