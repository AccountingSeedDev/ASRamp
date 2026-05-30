import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getHomeData from '@salesforce/apex/RampHomeController.getHomeData';
import syncTransactions from '@salesforce/apex/RampConfigurationController.syncTransactions';
import syncGLAccounts from '@salesforce/apex/RampConfigurationController.syncGLAccounts';
import syncBills from '@salesforce/apex/RampConfigurationController.syncBills';
import syncReimbursements from '@salesforce/apex/RampConfigurationController.syncReimbursements';
import schedulePipeline from '@salesforce/apex/RampHomeController.schedulePipeline';
import unschedulePipeline from '@salesforce/apex/RampHomeController.unschedulePipeline';

const FREQ_OPTIONS = [
    { label: 'Hourly', value: 'HOURLY' },
    { label: 'Every 6 hours', value: 'EVERY_6H' },
    { label: 'Daily', value: 'DAILY' },
    { label: 'Weekdays', value: 'WEEKDAYS' }
];

const ICONS = {
    database: 'utility:database',
    card: 'utility:money',
    file: 'utility:file',
    receipt: 'utility:people'
};
const STATUS = {
    active: { label: 'Active', cls: 'pill pill-good' },
    warning: { label: 'Attention', cls: 'pill pill-warn' },
    errors: { label: 'Errors', cls: 'pill pill-bad' },
    pending: { label: 'Pending', cls: 'pill pill-warn' },
    notset: { label: 'Not set up', cls: 'pill pill-muted' }
};

export default class RampHome extends LightningElement {
    @track home;
    @track busy = {};
    @track lowerTab = 'errors';
    @track scheduleFor = null;   // pipeline id whose scheduler panel is open
    @track schedFreq = 'HOURLY';
    @track schedHour = '1';
    @track schedBusy = false;
    wiredResult;
    error;

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

    // ── derived view-model ──
    get ready() { return !!this.home; }
    get connected() { return this.home && this.home.connected; }
    get setupComplete() { return this.home && this.home.setupComplete; }
    get showSetupBanner() { return this.home && !this.home.setupComplete; }
    get business() { return this.home ? this.home.business : ''; }
    get donePct() { return this.home ? this.home.donePct : 0; }
    get connClass() { return this.connected ? 'conn-dot conn-ok' : 'conn-dot conn-warn'; }
    get connLabel() { return this.connected ? 'Connected' : 'Setup in progress'; }
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
            cls: `step-chip step-${s.state}`,
            badgeCls: `step-badge step-badge-${s.state}`
        }));
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
            { key: 'b', label: 'GL accounts in sync', value: this._glSyncedLabel(), sub: 'master data', toneCls: 'kpi-sub muted' },
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
                lastRunLabel: j.lastRun ? new Date(j.lastRun).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' }) : '—'
            };
        });
    }
    _glSyncedLabel() {
        const m = this.home.pipelines.find((p) => p.id === 'master');
        return m ? this._n(m.synced) : '0';
    }

    get pipelines() {
        if (!this.home) return [];
        return this.home.pipelines.map((p) => {
            const st = STATUS[p.statusKind] || STATUS.notset;
            const busy = !!this.busy[p.id];
            return {
                ...p,
                iconName: ICONS[p.icon] || 'utility:apex',
                tintCls: p.direction === 'out' ? 'p-icon tint-out' : 'p-icon tint-in',
                cardCls: p.implemented ? 'pcard' : 'pcard pcard-muted',
                statusLabel: busy ? 'Syncing…' : st.label,
                statusCls: busy ? 'pill pill-warn' : st.cls,
                counts: [
                    { key: 's', n: this._n(p.synced), label: 'Synced', cls: 'cn good' },
                    { key: 'p', n: this._n(p.pending), label: 'Pending', cls: p.pending ? 'cn warn' : 'cn muted' },
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
    get settings() { return this.home ? this.home.settings : []; }

    get tabErrorsCls() { return this._tabCls('errors'); }
    get tabSettingsCls() { return this._tabCls('settings'); }
    get tabScheduleCls() { return this._tabCls('schedule'); }
    get showErrors() { return this.lowerTab === 'errors'; }
    get showSettings() { return this.lowerTab === 'settings'; }
    get showSchedule() { return this.lowerTab === 'schedule'; }
    get errorTabLabel() { return this.hasFailures ? `Error queue · ${this.failures.length}` : 'Error queue'; }
    _tabCls(id) { return this.lowerTab === id ? 'ltab ltab-on' : 'ltab'; }

    get schedules() {
        return [
            { key: 'm', name: 'Master data sync', cadence: 'Every 4 hours · weekdays', note: 'Manual today' },
            { key: 't', name: 'Card transactions', cadence: 'Every 4 hours · weekdays', note: 'Manual today' },
            { key: 'b', name: 'Bills', cadence: 'Every 2 hours (recommended)', note: 'Manual today' },
            { key: 'r', name: 'Reimbursements', cadence: 'Every 4 hours (recommended)', note: 'Manual today' }
        ];
    }

    // ── actions ──
    selectTab(e) { this.lowerTab = e.currentTarget.dataset.id; }

    handlePipeSync(e) {
        const id = e.currentTarget.dataset.id;
        const action = e.currentTarget.dataset.action;
        this._run(id, action);
    }
    handleSyncAll() {
        this._run('master', 'syncGL');
        this._run('txn', 'syncTxn');
        this._run('bill', 'syncBill');
        this._run('reimb', 'syncReimb');
    }
    handleRefresh() { refreshApex(this.wiredResult); }

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
