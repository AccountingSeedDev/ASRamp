/**
 * @description CMDT accessor for Ramp_Sync_Settings__mdt plus the GL Account
 * defaults the transaction sync needs.
 *
 * GL Account resolution is delegated to Accounting Seed's native per-ledger
 * "Default GL Accounts" construct (AcctSeed__GL_Account_Default__c) rather than
 * carrying GL Account names on the API config record. Two packaged
 * GL_Account_Specification__mdt "slots" — Ramp_Card_Clearing and Ramp_Suspense —
 * surface on the standard Default GL Accounts screen, where admins assign the
 * actual GL Account per ledger. We look those assignments up here.
 *
 * The spec is stored on GL_Account_Default__c.GL_Account_Specification__c as the
 * bare DeveloperName (no namespace prefix), verified against AS's own specs
 * (e.g. AP_Control_GL_Account), so the constants below are unqualified.
 */
public with sharing class RampSyncSettingsService {

    public static final String SPEC_CARD_CLEARING = 'Ramp_Card_Clearing';
    public static final String SPEC_SUSPENSE = 'Ramp_Suspense';
    public static final String SPEC_BILL_PAYMENT_BANK = 'Ramp_Bill_Payment_Bank';
    private static final Set<String> RAMP_SPECS = new Set<String>{
        SPEC_CARD_CLEARING, SPEC_SUSPENSE, SPEC_BILL_PAYMENT_BANK
    };

    // Sync_Grouping__c picklist values — how transactions collapse into JEs.
    public static final String GROUPING_DAILY = 'Daily';
    public static final String GROUPING_BY_RUN = 'By Run';

    @TestVisible
    private static Ramp_Sync_Settings__mdt overrideSettings;

    // Test hook: spec DeveloperName -> GL Account Id. When set, bypasses the
    // GL_Account_Default__c query so tests need not seed master-detail rows.
    @TestVisible
    private static Map<String, Id> overrideGLDefaults;

    private static Ramp_Sync_Settings__mdt cachedSettings;
    private static Id cachedLedgerId;
    private static Map<String, Id> cachedGLDefaultsBySpec;

    public static Ramp_Sync_Settings__mdt getSettings() {
        if (overrideSettings != null) {
            return overrideSettings;
        }
        if (cachedSettings != null) {
            return cachedSettings;
        }

        List<Ramp_Sync_Settings__mdt> records = [
            SELECT Default_Ledger__c, Default_JE_Status__c, Sync_Grouping__c, Send_Sync_Ack__c
            FROM Ramp_Sync_Settings__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];

        if (records.isEmpty()) {
            throw new RampSyncSettingsException(
                'No Default record found on Ramp_Sync_Settings__mdt. ' +
                'Deploy the Default Custom Metadata record and configure it before syncing transactions.'
            );
        }

        cachedSettings = records[0];
        return cachedSettings;
    }

    public static Id getDefaultLedgerId() {
        if (cachedLedgerId != null) {
            return cachedLedgerId;
        }

        String ledgerName = getSettings().Default_Ledger__c;
        if (String.isBlank(ledgerName)) {
            throw new RampSyncSettingsException(
                'Default_Ledger__c is not configured on Ramp_Sync_Settings__mdt.Default.'
            );
        }

        List<AcctSeed__Ledger__c> matches = [
            SELECT Id FROM AcctSeed__Ledger__c WHERE Name = :ledgerName LIMIT 2
        ];

        if (matches.isEmpty()) {
            throw new RampSyncSettingsException('No Ledger named "' + ledgerName + '" was found.');
        }
        if (matches.size() > 1) {
            throw new RampSyncSettingsException(
                'Multiple Ledgers share the name "' + ledgerName + '". Pick a unique value.'
            );
        }

        cachedLedgerId = matches[0].Id;
        return cachedLedgerId;
    }

    /**
     * @description The card-clearing/liability GL Account credited on every Ramp
     * JE. Resolved from the "Ramp Card Clearing" default GL Account on the sync
     * ledger. Required — throws if unset.
     */
    public static Id getCardClearingGLAccountId() {
        Id glId = getGLDefaultsBySpec().get(SPEC_CARD_CLEARING);
        if (glId == null) {
            throw new RampSyncSettingsException(
                'No "Ramp Card Clearing" GL Account is configured for the sync ledger. ' +
                'In Accounting Home > Setup > Configurations > Default GL Accounts, select the ledger ' +
                'and set the "Ramp Card Clearing" default GL Account.'
            );
        }
        return glId;
    }

    /**
     * @description Optional fallback expense GL for transactions with no GL
     * coding in Ramp. Resolved from the "Ramp Suspense" default GL Account on the
     * sync ledger. Returns null when unset — the builder handles that per line.
     */
    public static Id getSuspenseGLId() {
        return getGLDefaultsBySpec().get(SPEC_SUSPENSE);
    }

    /**
     * @description The bank/cash GL credited when a paid Ramp bill posts a Cash
     * Disbursement. Resolved from the "Ramp Bill Payment Bank" default GL Account
     * on the sync ledger. Required for Phase 2b — throws if unset.
     */
    /** Non-throwing variant — null when the bank GL default isn't configured. */
    public static Id getBillPaymentBankGLIdOrNull() {
        return getGLDefaultsBySpec().get(SPEC_BILL_PAYMENT_BANK);
    }

    public static Id getBillPaymentBankGLId() {
        Id glId = getGLDefaultsBySpec().get(SPEC_BILL_PAYMENT_BANK);
        if (glId == null) {
            throw new RampSyncSettingsException(
                'No "Ramp Bill Payment Bank" GL Account is configured for the sync ledger. ' +
                'In Accounting Home > Setup > Configurations > Default GL Accounts, select the ledger ' +
                'and set the "Ramp Bill Payment Bank" default GL Account.'
            );
        }
        return glId;
    }

    public static String getDefaultJEStatus() {
        String value = getSettings().Default_JE_Status__c;
        return String.isBlank(value) ? 'In Process' : value;
    }

    /**
     * @description How transactions are grouped into Journal Entries.
     * Defaults to Daily when unset.
     */
    public static String getSyncGrouping() {
        String value = getSettings().Sync_Grouping__c;
        return value == GROUPING_BY_RUN ? GROUPING_BY_RUN : GROUPING_DAILY;
    }

    /**
     * @description Whether to POST a sync acknowledgement to Ramp after creating
     * JEs (which marks the transactions SYNCED in Ramp). Defaults to true.
     * Set false to leave transactions SYNC_READY for repeatable testing.
     */
    public static Boolean getSendSyncAck() {
        Boolean value = getSettings().Send_Sync_Ack__c;
        return value == null ? true : value;
    }

    /**
     * @description Resolves the Ramp GL Account Defaults on the sync ledger into
     * a spec-DeveloperName -> GL Account Id map. Mirrors the package's own
     * resolution (DomainUtils.gLAccountDefaultsBySpecification) but filtered to
     * our ledger + specs, so we don't depend on cross-namespace global Apex.
     */
    private static Map<String, Id> getGLDefaultsBySpec() {
        if (overrideGLDefaults != null) {
            return overrideGLDefaults;
        }
        if (cachedGLDefaultsBySpec != null) {
            return cachedGLDefaultsBySpec;
        }

        Id ledgerId = getDefaultLedgerId();
        Map<String, Id> result = new Map<String, Id>();
        for (AcctSeed__GL_Account_Default__c d : [
            SELECT AcctSeed__GL_Account__c, AcctSeed__GL_Account_Specification__c
            FROM AcctSeed__GL_Account_Default__c
            WHERE AcctSeed__Ledger__c = :ledgerId
              AND AcctSeed__GL_Account_Specification__c IN :RAMP_SPECS
        ]) {
            result.put(d.AcctSeed__GL_Account_Specification__c, d.AcctSeed__GL_Account__c);
        }

        cachedGLDefaultsBySpec = result;
        return cachedGLDefaultsBySpec;
    }

    /**
     * @description Reset all cached lookups. Test-only — used to force re-resolve
     * after overrideSettings / overrideGLDefaults is changed mid-test.
     */
    @TestVisible
    private static void resetCache() {
        cachedSettings = null;
        cachedLedgerId = null;
        cachedGLDefaultsBySpec = null;
    }

    public class RampSyncSettingsException extends Exception {}
}