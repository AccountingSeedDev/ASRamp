/**
 * @description Logs Ramp sync runs to Accounting Seed's Automated Job Results
 * (AcctSeed__Automated_Job_Results__c), mirroring the package's own
 * AutomatedJobResultsHandler pattern so Ramp jobs show up alongside native jobs
 * for reporting/dashboards.
 *
 * The Ramp pipelines are cursor-paginated Queueable chains, so each run threads
 * an AJR Id through its pages and updates the same record with cumulative
 * Processed / Succeeded / Failed counts (and an error Notes summary) — the same
 * preset-then-update approach AS uses for its recurring batches.
 */
public with sharing class RampJobResultLogger {

    public static final String JOB_CARD_SYNC = 'Ramp Card Transaction Sync';
    public static final String JOB_BILL_SYNC = 'Ramp Bill Sync';
    public static final String JOB_REIMBURSEMENT_SYNC = 'Ramp Reimbursement Sync';

    private static final Integer NOTES_MAX = 30000;

    /**
     * @description Insert (when existingId is null) or update the run's Automated
     * Job Result with cumulative totals. Returns the record Id so the next page in
     * the chain can keep updating the same row. Never throws — logging must not
     * break the sync.
     */
    public static Id record(Id existingId, String jobType, Integer processed, Integer succeeded, Integer failed, String notes) {
        try {
            AcctSeed__Automated_Job_Results__c ajr = new AcctSeed__Automated_Job_Results__c();
            if (existingId != null) ajr.Id = existingId;
            ajr.AcctSeed__Schedule_Job_Type__c = jobType;
            ajr.AcctSeed__Processed__c = (processed == null) ? 0 : processed;
            ajr.AcctSeed__Succeeded__c = (succeeded == null) ? 0 : succeeded;
            ajr.AcctSeed__Failed__c = (failed == null) ? 0 : failed;
            ajr.AcctSeed__Notes__c = truncate(notes, NOTES_MAX);
            upsert ajr;
            return ajr.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'RampJobResultLogger failed: ' + e.getMessage());
            return existingId;
        }
    }

    /** Append a note line, keeping the most recent content within the field cap. */
    public static String appendNote(String existing, String add) {
        if (String.isBlank(add)) return existing;
        String combined = String.isBlank(existing) ? add : existing + '\n' + add;
        return truncate(combined, NOTES_MAX);
    }

    private static String truncate(String s, Integer maxLen) {
        if (String.isBlank(s)) return null;
        return s.length() <= maxLen ? s : s.substring(s.length() - maxLen);
    }
}
