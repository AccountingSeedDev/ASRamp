/**
 * @description Tests for RampSyncSettingsService — exercises the live
 * GL_Account_Default__c resolution path (no overrideGLDefaults injection) so the
 * SOQL against the ledger's default GL accounts is actually covered.
 */
@IsTest
private class RampSyncSettingsServiceTest {

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    private static String renameLedger() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        System.runAs(admin) {
            ledger.Name = 'SettingsTest-Ledger';
            update ledger;
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'SettingsTest-Ledger',
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.resetCache();
        return 'SettingsTest-Ledger';
    }

    @IsTest
    static void cardClearing_unconfigured_throws() {
        renameLedger();

        Test.startTest();
        Boolean threw = false;
        try {
            RampSyncSettingsService.getCardClearingGLAccountId();
        } catch (RampSyncSettingsService.RampSyncSettingsException e) {
            threw = true;
            System.assert(e.getMessage().contains('Ramp Card Clearing'), e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Expected an exception when no clearing default is set');
    }

    @IsTest
    static void suspense_unconfigured_returnsNull() {
        renameLedger();

        Test.startTest();
        Id result = RampSyncSettingsService.getSuspenseGLId();
        Test.stopTest();

        System.assertEquals(null, result, 'Suspense is optional — should be null when unset');
    }

    @IsTest
    static void defaultLedger_missing_throws() {
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.resetCache();

        Boolean threw = false;
        try {
            RampSyncSettingsService.getDefaultLedgerId();
        } catch (RampSyncSettingsService.RampSyncSettingsException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank Default_Ledger__c should throw');
    }

    @IsTest
    static void defaultJEStatus_blankFallsBackToInProcess() {
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'SettingsTest-Ledger'
        );
        RampSyncSettingsService.resetCache();

        System.assertEquals('In Process', RampSyncSettingsService.getDefaultJEStatus());
    }
}