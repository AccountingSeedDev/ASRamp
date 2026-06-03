import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getHomeData from '@salesforce/apex/RampHomeController.getHomeData';
import syncTransactions from '@salesforce/apex/RampConfigurationController.syncTransactions';
import syncGLAccounts from '@salesforce/apex/RampConfigurationController.syncGLAccounts';
import syncBills from '@salesforce/apex/RampConfigurationController.syncBills';
import syncReimbursements from '@salesforce/apex/RampConfigurationController.syncReimbursements';
import syncAccountingVariables from '@salesforce/apex/RampConfigurationController.syncAccountingVariables';
import syncVendors from '@salesforce/apex/RampConfigurationController.syncVendors';
import schedulePipeline from '@salesforce/apex/RampHomeController.schedulePipeline';
import unschedulePipeline from '@salesforce/apex/RampHomeController.unschedulePipeline';
import getPipelineAvailability from '@salesforce/apex/RampHomeController.getPipelineAvailability';
import getConnectionStatus from '@salesforce/apex/RampHomeController.getConnectionStatus';

const FREQ_OPTIONS = [
    { label: 'Hourly', value: 'HOURLY' },
    { label: 'Every 6 hours', value: 'EVERY_6H' },
    { label: 'Daily', value: 'DAILY' },
    { label: 'Weekdays', value: 'WEEKDAYS' }
];

const ICONS = {
    database: 'utility:database',
    apps: 'utility:apps',
    building: 'utility:company',
    card: 'utility:money',
    file: 'utility:file',
    receipt: 'utility:people'
};
const STATUS = {
    active: { label: 'Active', cls: 'pill pill-good' },
    good: { label: 'Success', cls: 'pill pill-good' },
    warning: { label: 'Attention', cls: 'pill pill-warn' },
    errors: { label: 'Errors', cls: 'pill pill-bad' },
    pending: { label: 'Pending', cls: 'pill pill-warn' },
    notset: { label: 'Not set up', cls: 'pill pill-muted' }
};

// Maps a setup step to the rampConfiguration tab that completes it.
const STEP_TAB = {
    connect: 'authorization',
    acctconn: 'authorization',
    master: 'glaccounts',
    settings: 'glaccounts',
    firstrun: 'glaccounts'
};

export default class RampHome extends NavigationMixin(LightningElement) {
    @track home;
    @track busy = {};
    @track pipeTab = 'transaction';   // active Sync-pipelines tab: 'transaction' | 'master'
    @track showConfig = false;        // configuration modal open?
    @track configTab = 'authorization';
    @track scheduleFor = null;   // pipeline id whose scheduler panel is open
    @track schedFreq = 'HOURLY';
    @track schedHour = '1';
    @track schedBusy = false;
    @track availability = {};   // pipelineId → "available to sync in Ramp" (live callout, e.g. "12" / "100+")
    @track conn = null;         // live connection status (real Ramp API call); null until first load
    wiredResult;
    error;

    connectedCallback() {
        this.loadAvailability();
        this.loadConnection();
    }

    @wire(getHomeData)
    wiredHome(result) {
        this.wiredResult = result;
        if (result.data) {
            this.home = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = this._msg(result.error);
        }
    }

    // Live count of what's waiting in Ramp per inbound pipeline (non-cacheable callout).
    loadAvailability() {
        getPipelineAvailability()
            .then((r) => { this.availability = r || {}; })
            .catch(() => { /* leave as-is; cards fall back to local counts */ });
    }

    // Live connection check — authenticates and hits the Ramp API (non-cacheable callout).
    loadConnection() {
        getConnectionStatus()
            .then((r) => { this.conn = r; })
            .catch(() => { /* leave as-is; pill falls back to config-based state */ });
    }

    // ── derived view-model ──
    get ready() { return !!this.home; }
    // Once the live check returns, it is authoritative; until then fall back to
    // the config-presence flag from the cacheable getHomeData (avoids a flicker).
    get connected() { return this.conn ? this.conn.connected : !!(this.home && this.home.connected); }
    get setupComplete() { return this.home && this.home.setupComplete; }
    get showSetupBanner() { return this.home && !this.home.setupComplete; }
    get business() {
        if (this.conn && this.conn.business) return this.conn.business;
        return this.home ? this.home.business : '';
    }
    get donePct() { return this.home ? this.home.donePct : 0; }
    // A live check that ran and failed shows a red error dot; an unconfigured /
    // pre-check state shows the amber "setup" dot.
    get connError() { return !!this.conn && !this.conn.connected && !!(this.home && this.home.connected); }
    get connClass() {
        if (this.connected) return 'conn-dot conn-ok';
        return this.connError ? 'conn-dot conn-bad' : 'conn-dot conn-warn';
    }
    get connLabel() {
        if (this.connected) return 'Connected';
        return this.connError ? 'Connection error' : 'Setup in progress';
    }
    get connTitle() { return this.conn ? this.conn.detail : 'Checking connection to Ramp…'; }
    get anyBusy() { return Object.values(this.busy).some(Boolean); }
    get syncAllLabel() { return this.anyBusy ? 'Syncing…' : 'Sync all now'; }
    get syncAllDisabled() { return !this.setupComplete || this.anyBusy; }
    get progressStyle() { return `width:${this.donePct}%`; }
    get ringStyle() {
        const p = this.donePct;
        return `background: conic-gradient(#1AA2DC ${p * 3.6}deg, rgba(255,255,255,0.18) 0deg);`;
    }
    get nextStepTitle() {
        if (!this.home) return '';
        const s = this.home.steps.find((x) => x.state === 'current');
        return s ? s.title : 'Review configuration';
    }
    get doneCountLabel() {
        if (!this.home) return '';
        const done = this.home.steps.filter((x) => x.state === 'done').length;
        return `${done} of ${this.home.steps.length} steps done`;
    }

    get steps() {
        if (!this.home) return [];
        return this.home.steps.map((s, i) => ({
            ...s,
            n: i + 1,
            isDone: s.state === 'done',
            isCurrent: s.state === 'current',
            tab: STEP_TAB[s.id] || 'authorization',
            cls: `step-chip step-${s.state}`,
            badgeCls: `step-badge step-badge-${s.state}`
        }));
    }

    // Tab the "Continue setup" button should jump to (the first unfinished step).
    get nextStepTab() {
        if (!this.home) return 'authorization';
        const s = this.home.steps.find((x) => x.state === 'current');
        return s ? (STEP_TAB[s.id] || 'authorization') : 'authorization';
    }

    get healthHealthy() { return this.home && this.home.failedTotal === 0; }
    get healthClass() { return this.healthHealthy ? 'strip strip-good' : 'strip strip-bad'; }
    get healthIcon() { return this.healthHealthy ? 'utility:success' : 'utility:warning'; }
    get healthTitle() {
        if (!this.home) return '';
        return this.healthHealthy ? 'All active pipelines healthy'
            : `${this.home.failedTotal} record${this.home.failedTotal === 1 ? '' : 's'} need attention`;
    }
    get healthDetail() {
        return this.healthHealthy
            ? 'Every scheduled sync completed and was acknowledged by Ramp.'
            : 'Some records couldn’t post — unresolved GL accounts, missing vendors or a closed period. They stay in Ramp’s queue until resolved.';
    }

    get kpis() {
        if (!this.home) return [];
        const h = this.home;
        return [
            { key: 'a', label: 'Records processed', value: this._n(h.recordsProcessed), sub: 'latest sync runs', toneCls: 'kpi-sub muted' },
            { key: 'b', label: 'Master records in sync', value: this._glSyncedLabel(), sub: 'GL accounts + variables', toneCls: 'kpi-sub muted' },
            { key: 'c', label: 'Pending acknowledgement', value: this._n(h.pendingTotal), sub: h.pendingTotal ? 'awaiting Ramp acknowledgement' : 'all caught up', toneCls: h.pendingTotal ? 'kpi-sub warn' : 'kpi-sub good' },
            { key: 'd', label: 'Need follow-up', value: this._n(h.failedTotal), sub: h.failedTotal ? 'records to resolve' : 'no failures', toneCls: h.failedTotal ? 'kpi-sub bad' : 'kpi-sub good' }
        ];
    }

    // ── recent sync runs (Automated Job Results) ──
    get jobs() {
        if (!this.home || !this.home.jobs) return [];
        return this.home.jobs.map((j) => {
            const st = STATUS[j.statusKind] || STATUS.notset;
            return {
                ...j,
                pillCls: st.cls,
                pillLabel: j.hasRun ? st.label : 'No runs yet',
                processedN: this._n(j.processed),
                succeededN: this._n(j.succeeded),
                failedN: this._n(j.failed),
                failedCls: j.failed ? 'jm-num bad' : 'jm-num muted',
                lastRunLabel: j.lastRun ? new Date(j.lastRun).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' }) : '—',
                hasRecord: !!j.recordId
            };
        });
    }

    // Open the underlying Automated Job Result record for a sync-run card.
    viewJobResult(e) {
        const recordId = e.currentTarget.dataset.id;
        if (!recordId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName: 'AcctSeed__Automated_Job_Results__c', actionName: 'view' }
        });
    }
    _glSyncedLabel() {
        const total = (this.home.pipelines || [])
            .filter((p) => p.groupKey === 'master')
            .reduce((sum, p) => sum + (p.synced || 0), 0);
        return this._n(total);
    }

    get pipelines() {
        if (!this.home) return [];
        return this.home.pipelines.map((p) => {
            const st = STATUS[p.statusKind] || STATUS.notset;
            const busy = !!this.busy[p.id];
            // Inbound pipelines: "Pending" = live count of what's waiting in Ramp
            // (SYNC_READY), from getPipelineAvailability. Master (outbound) falls
            // back to its local not-yet-pushed count.
            const avail = this.availability ? this.availability[p.id] : undefined;
            const hasAvail = avail !== undefined && avail !== null;
            const pendingN = hasAvail ? avail : this._n(p.pending);
            const pendingWarn = hasAvail ? (avail !== '0' && avail !== '—') : p.pending > 0;
            return {
                ...p,
                iconName: ICONS[p.icon] || 'utility:apex',
                tintCls: p.direction === 'out' ? 'p-icon tint-out' : 'p-icon tint-in',
                cardCls: p.implemented ? 'pcard' : 'pcard pcard-muted',
                statusLabel: busy ? 'Syncing…' : st.label,
                statusCls: busy ? 'pill pill-warn' : st.cls,
                counts: [
                    { key: 's', n: this._n(p.synced), label: 'Synced', cls: 'cn good' },
                    { key: 'p', n: pendingN, label: 'Pending', cls: pendingWarn ? 'cn warn' : 'cn muted' },
                    { key: 'f', n: this._n(p.failed), label: 'Failed', cls: p.failed ? 'cn bad' : 'cn muted' }
                ],
                showSync: p.implemented && !!p.action,
                syncDisabled: busy || !this.setupComplete,
                syncLabel: busy ? 'Syncing' : 'Sync now',
                notEnabled: !p.implemented,
                hasLastRun: !!p.lastRun,
                scheduleOpen: this.scheduleFor === p.id,
                schedActive: !!p.scheduled,
                schedSummary: p.scheduleSummary,
                schedNext: p.nextRun ? new Date(p.nextRun).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' }) : null,
                schedBtnLabel: p.scheduled ? 'Edit schedule' : 'Schedule'
            };
        });
    }

    // ── scheduler ──
    get freqOptions() {
        return FREQ_OPTIONS.map((o) => ({ ...o, selected: o.value === this.schedFreq }));
    }
    get hourOptions() {
        const out = [];
        for (let h = 0; h < 24; h++) {
            const suffix = h < 12 ? 'AM' : 'PM';
            let h12 = h % 12; if (h12 === 0) h12 = 12;
            out.push({ value: String(h), label: `${h12}:00 ${suffix}`, selected: String(h) === this.schedHour });
        }
        return out;
    }
    get showHour() { return this.schedFreq === 'DAILY' || this.schedFreq === 'WEEKDAYS'; }

    get failures() { return this.home ? this.home.failures : []; }
    get hasFailures() { return this.failures.length > 0; }

    // ── Sync-pipelines tabs: Transaction (default + first), then Master data.
    // Each tab scopes its own pipeline cards, recent runs, and error queue.
    selectPipeTab(e) { this.pipeTab = e.currentTarget.dataset.id; }
    get txnTabCls() { return this.pipeTab === 'transaction' ? 'ptab ptab-on' : 'ptab'; }
    get masterTabCls() { return this.pipeTab === 'master' ? 'ptab ptab-on' : 'ptab'; }
    get activePipelines() { return this.pipelines.filter((p) => p.groupKey === this.pipeTab); }
    get activeJobs() { return this.jobs.filter((j) => j.groupKey === this.pipeTab); }
    get activeFailures() { return this.failures.filter((f) => f.groupKey === this.pipeTab); }
    get activeHasFailures() { return this.activeFailures.length > 0; }
    get activeFailuresCount() { return this.activeFailures.length; }

    // Health-strip "Review errors" → jump to a tab that has failures.
    reviewErrors() {
        if (this.failures.some((f) => f.groupKey === 'transaction')) this.pipeTab = 'transaction';
        else if (this.failures.some((f) => f.groupKey === 'master')) this.pipeTab = 'master';
    }

    // ── configuration modal ──
    openConfig(e) {
        const tab = (e && e.currentTarget && e.currentTarget.dataset.tab) || 'authorization';
        this.configTab = tab;
        this.showConfig = true;
    }
    openConfigNext() {
        this.configTab = this.nextStepTab;
        this.showConfig = true;
    }
    stopProp(e) { e.stopPropagation(); }
    closeConfig() {
        this.showConfig = false;
        // Reflect anything saved in config (credential, GL sync, settings).
        refreshApex(this.wiredResult);
    }

    handlePipeSync(e) {
        const id = e.currentTarget.dataset.id;
        const action = e.currentTarget.dataset.action;
        this._run(id, action);
    }
    handleSyncAll() {
        this._run('gl', 'syncGL');
        this._run('var', 'syncVar');
        this._run('vendor', 'syncVendor');
        this._run('txn', 'syncTxn');
        this._run('bill', 'syncBill');
        this._run('reimb', 'syncReimb');
    }
    handleRefresh() { refreshApex(this.wiredResult); this.loadAvailability(); this.loadConnection(); }

    // ── scheduler actions ──
    openSchedule(e) {
        const id = e.currentTarget.dataset.id;
        this.scheduleFor = id;
        this.schedFreq = 'HOURLY';
        this.schedHour = '1';
    }
    closeSchedule() { this.scheduleFor = null; }
    onFreqChange(e) { this.schedFreq = e.target.value; }
    onHourChange(e) { this.schedHour = e.target.value; }

    saveSchedule(e) {
        const id = e.currentTarget.dataset.id;
        this.schedBusy = true;
        schedulePipeline({ pipelineId: id, frequency: this.schedFreq, hour: parseInt(this.schedHour, 10) })
            .then((msg) => { this._toast('Schedule saved', msg, 'success'); this.scheduleFor = null; })
            .catch((err) => this._toast('Error', this._msg(err), 'error'))
            .finally(() => { this.schedBusy = false; refreshApex(this.wiredResult); });
    }
    clearSchedule(e) {
        const id = e.currentTarget.dataset.id;
        this.schedBusy = true;
        unschedulePipeline({ pipelineId: id })
            .then((msg) => { this._toast('Schedule cleared', msg, 'success'); this.scheduleFor = null; })
            .catch((err) => this._toast('Error', this._msg(err), 'error'))
            .finally(() => { this.schedBusy = false; refreshApex(this.wiredResult); });
    }

    _run(id, action) {
        if (this.busy[id]) return;
        const fn = action === 'syncGL' ? syncGLAccounts
            : action === 'syncVar' ? syncAccountingVariables
            : action === 'syncVendor' ? syncVendors
            : action === 'syncTxn' ? syncTransactions
            : action === 'syncBill' ? syncBills
            : action === 'syncReimb' ? syncReimbursements
            : null;
        if (!fn) return;
        this.busy = { ...this.busy, [id]: true };
        fn()
            .then((res) => {
                this._toast('Sync started', res, 'success');
            })
            .catch((err) => {
                this._toast('Error', this._msg(err), 'error');
            })
            .finally(() => {
                this.busy = { ...this.busy, [id]: false };
                // Queueables run async; give the user fresh counts on next tick.
                refreshApex(this.wiredResult);
                this.loadAvailability();
                this.loadConnection();
            });
    }

    // ── utils ──
    _n(v) { return (v == null ? 0 : v).toLocaleString('en-US'); }
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: 'dismissable' }));
    }
    _msg(e) {
        return (e && e.body && e.body.message) ? e.body.message : (e && e.message) ? e.message : 'Unexpected error';
    }
}
