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

    @IsTest
    static void defaultLedger_resolvesByUniqueExtId() {
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            ledger.AcctSeed__ExtId__c = 'RAMP-LEDGER-001';
            update ledger;
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'RAMP-LEDGER-001',
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.resetCache();

        Test.startTest();
        Id resolved = RampSyncSettingsService.getDefaultLedgerId();
        Test.stopTest();

        System.assertEquals(ledger.Id, resolved, 'resolves by the unique External Id');
    }

    @IsTest
    static void referenceLookupEnabled_returnsTrueWhenSet() {
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'TestLedger',
            Enable_Reference_Lookup__c = true,
            Reference_Key_Template__c = '{merchant_name}'
        );
        RampSyncSettingsService.resetCache();

        System.assertEquals(true, RampSyncSettingsService.referenceLookupEnabled());
        System.assertEquals('{merchant_name}', RampSyncSettingsService.getReferenceKeyTemplate());
    }

    @IsTest
    static void referenceLookupEnabled_returnsFalseByDefault() {
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'TestLedger'
        );
        RampSyncSettingsService.resetCache();

        System.assertEquals(false, RampSyncSettingsService.referenceLookupEnabled());
        System.assertEquals(null, RampSyncSettingsService.getReferenceKeyTemplate());
    }

    @IsTest
    static void defaultLedger_byNameStampsExtId() {
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            ledger.Name = 'ExtIdTest-Ledger';
            ledger.AcctSeed__ExtId__c = null;
            update ledger;
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'ExtIdTest-Ledger',
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.resetCache();

        Test.startTest();
        Id resolved = RampSyncSettingsService.getDefaultLedgerId();
        Test.stopTest();

        System.assertEquals(ledger.Id, resolved, 'falls back to Name when no ExtId match');
        AcctSeed__Ledger__c refreshed = [
            SELECT AcctSeed__ExtId__c FROM AcctSeed__Ledger__c WHERE Id = :ledger.Id
        ];
        System.assertEquals('ExtIdTest-Ledger', refreshed.AcctSeed__ExtId__c,
            'Name is stamped into the blank External Id so later lookups use the unique key');
    }
}