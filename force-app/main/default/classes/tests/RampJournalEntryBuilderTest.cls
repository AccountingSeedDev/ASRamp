/**
 * @description Tests for RampJournalEntryBuilder — pure transformation from
 * Ramp transaction JSON shapes to AS Journal Entry + Lines.
 */
@IsTest
private class RampJournalEntryBuilderTest {

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    /**
     * @description Helper — picks one GL account from the bootstrapped data as
     * the "card clearing" GL, stamps it with a known Ramp_Id__c, and creates
     * an overrideSettings record pointing at it.
     */
    private static AcctSeed__GL_Account__c configureSettings(String clearingGLName, String defaultLedgerName) {
        User admin = TestDataFactory.getInstance().getAdminUser();

        AcctSeed__GL_Account__c clearingGL;
        System.runAs(admin) {
            // Use any active GL Account as clearing; mark it with a sentinel
            // Ramp_Id so createCodedGL() skips it when picking an expense GL.
            List<AcctSeed__GL_Account__c> gls = [
                SELECT Id, Name FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
                LIMIT 1
            ];
            clearingGL = gls[0];
            clearingGL.Name = clearingGLName;
            clearingGL.Ramp_Id__c = 'CLEARING_SENTINEL';
            update clearingGL;
        }

        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        System.runAs(admin) {
            ledger.Name = defaultLedgerName;
            update ledger;
        }

        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = defaultLedgerName,
            Default_JE_Status__c = 'In Process'
        );
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_CARD_CLEARING => clearingGL.Id
        };
        RampSyncSettingsService.resetCache();
        return clearingGL;
    }

    private static AcctSeed__GL_Account__c createCodedGL(String name, String rampUuid) {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__GL_Account__c gl;
        System.runAs(admin) {
            // Pick a different GL than clearing, stamp Ramp_Id__c
            List<AcctSeed__GL_Account__c> gls = [
                SELECT Id, Name, Ramp_Id__c FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true AND Ramp_Id__c = null
                LIMIT 1
            ];
            gl = gls[0];
            gl.Ramp_Id__c = rampUuid;
            update gl;
        }
        return gl;
    }

    private static Account createVendorAccount(String name, String rampVendorId) {
        User admin = TestDataFactory.getInstance().getAdminUser();
        Account a = new Account(
            Name = name,
            AcctSeed__Accounting_Type__c = 'Vendor',
            Ramp_Vendor_Id__c = rampVendorId
        );
        System.runAs(admin) {
            insert a;
        }
        return a;
    }

    private static AcctSeed__Accounting_Variable__c createVariable(String varType, String rampOptionUuid) {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Accounting_Variable__c var = new AcctSeed__Accounting_Variable__c(
            Name = 'TestVar-' + varType + '-' + rampOptionUuid.substring(0, 6),
            AcctSeed__Type__c = varType,
            AcctSeed__Active__c = true,
            Ramp_Field_Option_Id__c = rampOptionUuid
        );
        System.runAs(admin) {
            insert var;
        }
        return var;
    }

    private static Date pickPeriodDate() {
        // TestDataFactory creates periods covering a specific range; use the
        // start date of an open period so the JE definitely lands in one.
        List<AcctSeed__Accounting_Period__c> periods = [
            SELECT Id, AcctSeed__Start_Date__c
            FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open'
            ORDER BY AcctSeed__Start_Date__c DESC
            LIMIT 1
        ];
        return periods.isEmpty() ? Date.today() : periods[0].AcctSeed__Start_Date__c;
    }

    private static RampJournalEntryBuilder.RampTransaction sampleTransaction(String id, Decimal amount, String glUuid) {
        return sampleTransactionOn(id, amount, glUuid, pickPeriodDate());
    }

    private static RampJournalEntryBuilder.RampTransaction sampleTransactionOn(String id, Decimal amount, String glUuid, Date d) {
        String iso = String.valueOf(d) + 'T12:00:00+00:00';

        RampJournalEntryBuilder.RampTransaction t = new RampJournalEntryBuilder.RampTransaction();
        t.id = id;
        t.amount = amount;
        t.currency_code = 'USD';
        t.accounting_date = iso;
        t.user_transaction_time = iso;
        t.merchant_name = 'Acme Coffee';
        t.memo = 'Team meeting';
        t.state = 'CLEARED';
        t.sync_status = 'SYNC_READY';
        t.entity_id = 'entity-uuid-sample';
        t.card_holder = new RampJournalEntryBuilder.CardHolder();
        t.card_holder.first_name = 'Jane';
        t.card_holder.last_name = 'Doe';

        RampJournalEntryBuilder.AccountingFieldSelection sel = new RampJournalEntryBuilder.AccountingFieldSelection();
        sel.id = glUuid;
        sel.type = 'GL_ACCOUNT';
        sel.category_info = new RampJournalEntryBuilder.CategoryInfo();
        sel.category_info.name = 'GL Account';
        sel.category_info.type = 'GL_ACCOUNT';
        t.accounting_field_selections = new List<RampJournalEntryBuilder.AccountingFieldSelection>{ sel };
        return t;
    }

    @IsTest
    static void build_singleTransactionNoSplits_buildsHeaderAndTwoLines() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        AcctSeed__GL_Account__c expenseGL = createCodedGL('ExpenseGL', 'gl-uuid-1');

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-1', 50.0, 'gl-uuid-1');

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size(), 'Expected 1 successful build');
        System.assertEquals(0, result.failed.size(), 'Expected 0 failures');

        RampJournalEntryBuilder.JournalEntryBuild tb = result.successful[0];
        // Daily grouping: header is keyed by date+entity+currency, not the txn id.
        System.assert(tb.header.AcctSeed__ExtId__c.startsWith('D:'),
            'Daily header should be date-keyed: ' + tb.header.AcctSeed__ExtId__c);
        System.assertEquals(1, tb.rampTransactionIds.size());
        System.assertEquals('txn-1', tb.rampTransactionIds[0]);
        System.assertEquals(pickPeriodDate(), tb.header.AcctSeed__Journal_Date__c);
        System.assertEquals('Pending', tb.header.Ramp_Sync_Status__c);
        System.assertEquals('entity-uuid-sample', tb.header.Ramp_Entity_Id__c);
        System.assertEquals(2, tb.lines.size(), 'Expected one debit + one credit line');

        // Debit line
        AcctSeed__Journal_Entry_Line__c debit = tb.lines[0];
        System.assertEquals('txn-1:dr:0', debit.AcctSeed__ExtId__c);
        System.assertEquals(expenseGL.Id, debit.AcctSeed__GL_Account__c);
        System.assertEquals(50.0, debit.AcctSeed__Debit__c);
        System.assertEquals(null, debit.AcctSeed__Credit__c);
        System.assertEquals(pickPeriodDate(), debit.AcctSeed__Date__c, 'Debit line carries the txn date');
        System.assertEquals('Acme Coffee', debit.Ramp_Vendor_Name__c, 'Merchant name carried onto the line');
        System.assertEquals(null, debit.AcctSeed__Account__c, 'Untracked merchant must not match an Account');

        // Credit (clearing) line
        AcctSeed__Journal_Entry_Line__c credit = tb.lines[1];
        System.assertEquals('txn-1:cr', credit.AcctSeed__ExtId__c);
        System.assertEquals(50.0, credit.AcctSeed__Credit__c);
        System.assertEquals(null, credit.AcctSeed__Debit__c);
        System.assertEquals(pickPeriodDate(), credit.AcctSeed__Date__c, 'Clearing line carries the txn date');
        System.assertEquals('Acme Coffee', credit.Ramp_Vendor_Name__c, 'Merchant name carried onto the clearing line');
        System.assert(credit.AcctSeed__GL_Account__c != expenseGL.Id, 'Credit GL should be clearing, not expense');
    }

    @IsTest
    static void build_withLineItemSplits_producesOneDebitPerSplit() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-2');

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-split', 90.0, 'gl-uuid-2');

        RampJournalEntryBuilder.LineItem li1 = new RampJournalEntryBuilder.LineItem();
        li1.amount = new RampJournalEntryBuilder.CurrencyAmount();
        li1.amount.amount = 4000;
        li1.amount.currency_code = 'USD';
        li1.amount.minor_unit_conversion_rate = 100;
        li1.memo = 'Split A';

        RampJournalEntryBuilder.LineItem li2 = new RampJournalEntryBuilder.LineItem();
        li2.amount = new RampJournalEntryBuilder.CurrencyAmount();
        li2.amount.amount = 5000;
        li2.amount.currency_code = 'USD';
        li2.amount.minor_unit_conversion_rate = 100;
        li2.memo = 'Split B';

        t.line_items = new List<RampJournalEntryBuilder.LineItem>{ li1, li2 };

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size());
        RampJournalEntryBuilder.JournalEntryBuild tb = result.successful[0];
        System.assertEquals(3, tb.lines.size(), 'Two debit lines + one credit line');
        System.assertEquals('txn-split:dr:0', tb.lines[0].AcctSeed__ExtId__c);
        System.assertEquals(40.0, tb.lines[0].AcctSeed__Debit__c);
        System.assertEquals('txn-split:dr:1', tb.lines[1].AcctSeed__ExtId__c);
        System.assertEquals(50.0, tb.lines[1].AcctSeed__Debit__c);
        System.assertEquals('txn-split:cr', tb.lines[2].AcctSeed__ExtId__c);
        System.assertEquals(90.0, tb.lines[2].AcctSeed__Credit__c);
    }

    @IsTest
    static void build_refundFlipsDebitAndCredit() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-3');

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-refund', -25.0, 'gl-uuid-3');

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size());
        RampJournalEntryBuilder.JournalEntryBuild tb = result.successful[0];
        // Expense line: now a CREDIT
        System.assertEquals(25.0, tb.lines[0].AcctSeed__Credit__c);
        System.assertEquals(null, tb.lines[0].AcctSeed__Debit__c);
        // Clearing line: now a DEBIT
        System.assertEquals(25.0, tb.lines[1].AcctSeed__Debit__c);
        System.assertEquals(null, tb.lines[1].AcctSeed__Credit__c);
    }

    @IsTest
    static void build_resolvesAccountingVariables() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-4');
        AcctSeed__Accounting_Variable__c v1 = createVariable('GL Account Variable 1', 'var-uuid-1');
        AcctSeed__Accounting_Variable__c v2 = createVariable('GL Account Variable 2', 'var-uuid-2');

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-vars', 100.0, 'gl-uuid-4');

        // Add variable selections at the transaction level
        RampJournalEntryBuilder.AccountingFieldSelection s1 = new RampJournalEntryBuilder.AccountingFieldSelection();
        s1.id = 'var-uuid-1';
        s1.type = 'CUSTOM';
        s1.category_info = new RampJournalEntryBuilder.CategoryInfo();
        s1.category_info.name = 'GL Account Variable 1';
        t.accounting_field_selections.add(s1);

        RampJournalEntryBuilder.AccountingFieldSelection s2 = new RampJournalEntryBuilder.AccountingFieldSelection();
        s2.id = 'var-uuid-2';
        s2.type = 'CUSTOM';
        s2.category_info = new RampJournalEntryBuilder.CategoryInfo();
        s2.category_info.name = 'GL Account Variable 2';
        t.accounting_field_selections.add(s2);

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        AcctSeed__Journal_Entry_Line__c debit = result.successful[0].lines[0];
        System.assertEquals(v1.Id, debit.AcctSeed__GL_Account_Variable_1__c);
        System.assertEquals(v2.Id, debit.AcctSeed__GL_Account_Variable_2__c);
    }

    @IsTest
    static void build_unresolvedGLNoSuspense_failsTransaction() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        // Note: no createCodedGL — the gl-uuid we reference doesn't exist

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-fail', 50.0, 'gl-uuid-missing');

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(0, result.successful.size());
        System.assertEquals(1, result.failed.size());
        System.assert(result.failed.get('txn-fail').contains('Could not resolve a GL Account'));
    }

    @IsTest
    static void build_unresolvedGLWithSuspense_routesToSuspense() {
        TestDataFactory.getInstance();
        AcctSeed__GL_Account__c clearing = configureSettings('CardClearing-TEST', 'Ledger-TEST');

        // Designate a separate GL as suspense
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__GL_Account__c suspense;
        System.runAs(admin) {
            List<AcctSeed__GL_Account__c> gls = [
                SELECT Id, Name FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true AND Id != :clearing.Id
                LIMIT 1
            ];
            suspense = gls[0];
            suspense.Name = 'Suspense-TEST';
            update suspense;
        }

        // Add the suspense GL to the resolved defaults
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_CARD_CLEARING => clearing.Id,
            RampSyncSettingsService.SPEC_SUSPENSE => suspense.Id
        };
        RampSyncSettingsService.resetCache();

        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-suspense', 75.0, 'gl-uuid-missing');

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size());
        System.assertEquals(suspense.Id, result.successful[0].lines[0].AcctSeed__GL_Account__c);
    }

    // --------------------------------------------------------------------
    //  Grouping
    // --------------------------------------------------------------------

    @IsTest
    static void build_daily_sameDayCollapsesToOneJE() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-1');

        Date d = pickPeriodDate();
        RampJournalEntryBuilder.RampTransaction a = sampleTransactionOn('txn-a', 10.0, 'gl-uuid-1', d);
        RampJournalEntryBuilder.RampTransaction b = sampleTransactionOn('txn-b', 20.0, 'gl-uuid-1', d);

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ a, b },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size(), 'Same day/entity/currency => one JE');
        RampJournalEntryBuilder.JournalEntryBuild jeb = result.successful[0];
        System.assertEquals(2, jeb.rampTransactionIds.size(), 'Both txns folded into the JE');
        System.assertEquals(4, jeb.lines.size(), '2 debit + 2 clearing lines');
        System.assertEquals('RAMP - ' + String.valueOf(d), jeb.header.Name, 'Daily JE name convention');
    }

    @IsTest
    static void build_daily_differentDaysSplitIntoTwoJEs() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-1');

        Date d0 = pickPeriodDate();
        Date d1 = d0.addDays(1); // same monthly period, different day
        RampJournalEntryBuilder.RampTransaction a = sampleTransactionOn('txn-a', 10.0, 'gl-uuid-1', d0);
        RampJournalEntryBuilder.RampTransaction b = sampleTransactionOn('txn-b', 20.0, 'gl-uuid-1', d1);

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ a, b },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(2, result.successful.size(), 'Different days => two daily JEs');
    }

    @IsTest
    static void build_byPeriod_samePeriodCollapsesAcrossDays() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-1');

        Date d0 = pickPeriodDate();
        Date d1 = d0.addDays(1); // same period, different day
        RampJournalEntryBuilder.RampTransaction a = sampleTransactionOn('txn-a', 10.0, 'gl-uuid-1', d0);
        RampJournalEntryBuilder.RampTransaction b = sampleTransactionOn('txn-b', 20.0, 'gl-uuid-1', d1);

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ a, b },
            RampSyncSettingsService.GROUPING_BY_PERIOD
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size(), 'By Period: same period collapses across days');
        RampJournalEntryBuilder.JournalEntryBuild jeb = result.successful[0];
        System.assertEquals(2, jeb.rampTransactionIds.size());

        AcctSeed__Accounting_Period__c period = [
            SELECT Id, Name, AcctSeed__End_Date__c
            FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Start_Date__c <= :d0 AND AcctSeed__End_Date__c >= :d1
            LIMIT 1
        ];
        // Key has no run component — re-runs upsert the same period JE.
        System.assertEquals('P:' + period.Id + ':entity-uuid-sample:USD', jeb.header.AcctSeed__ExtId__c,
            'By Period header keyed by period+entity+currency');
        // Header date is the period end date — stable across re-runs.
        System.assertEquals(period.AcctSeed__End_Date__c, jeb.header.AcctSeed__Journal_Date__c);
        System.assertEquals('RAMP - ' + period.Name, jeb.header.Name,
            'By Period JE name convention: ' + jeb.header.Name);
        // Lines keep each transaction's own date even though they share one header.
        for (AcctSeed__Journal_Entry_Line__c l : jeb.lines) {
            System.assert(l.AcctSeed__Date__c == d0 || l.AcctSeed__Date__c == d1,
                'Line should carry its own txn date: ' + l.AcctSeed__ExtId__c + ' -> ' + l.AcctSeed__Date__c);
        }
    }

    @IsTest
    static void build_vendorCoding_resolvesAccountLookup() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-1');
        Account vendor = createVendorAccount('Atlassian', 'ramp-vendor-uuid-1');

        // Raw descriptor on the merchant — name matching would fail, so this
        // proves the resolution came from the Accounting Vendor coding.
        RampJournalEntryBuilder.RampTransaction t = sampleTransaction('txn-v1', 50.0, 'gl-uuid-1');
        t.merchant_name = 'ATLASSIAN*SUB 12345';
        RampJournalEntryBuilder.AccountingFieldSelection v = new RampJournalEntryBuilder.AccountingFieldSelection();
        v.id = 'ramp-vendor-uuid-1';
        v.type = 'MERCHANT'; // Ramp's selection type for the Accounting Vendor dimension
        v.external_id = vendor.Id;
        t.accounting_field_selections.add(v);

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ t },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size());
        AcctSeed__Journal_Entry_Line__c debit = result.successful[0].lines[0];
        System.assertEquals(vendor.Id, debit.AcctSeed__Account__c,
            'VENDOR coding selection should resolve the Account lookup');
        System.assertEquals('ATLASSIAN*SUB 12345', debit.Ramp_Vendor_Name__c);
    }

    @IsTest
    static void build_merchantName_matchesExistingVendorsOnly() {
        TestDataFactory.getInstance();
        configureSettings('CardClearing-TEST', 'Ledger-TEST');
        createCodedGL('ExpenseGL', 'gl-uuid-1');
        Account vendor = createVendorAccount('Atlassian', null);

        // Tracked vendor, no Ramp coding — exact merchant-name fallback hits.
        RampJournalEntryBuilder.RampTransaction tracked = sampleTransaction('txn-a', 50.0, 'gl-uuid-1');
        tracked.merchant_name = 'ATLASSIAN'; // case-insensitive match
        // Untracked T&E merchant — no Account exists, lookup must stay blank.
        RampJournalEntryBuilder.RampTransaction untracked = sampleTransaction('txn-b', 12.0, 'gl-uuid-1');
        untracked.merchant_name = 'Chipotle';

        Test.startTest();
        RampJournalEntryBuilder.BuildResult result = RampJournalEntryBuilder.build(
            new List<RampJournalEntryBuilder.RampTransaction>{ tracked, untracked },
            RampSyncSettingsService.GROUPING_DAILY
        );
        Test.stopTest();

        System.assertEquals(1, result.successful.size(), 'Same day collapses into one JE');
        Map<String, AcctSeed__Journal_Entry_Line__c> byExtId = new Map<String, AcctSeed__Journal_Entry_Line__c>();
        for (AcctSeed__Journal_Entry_Line__c l : result.successful[0].lines) {
            byExtId.put(l.AcctSeed__ExtId__c, l);
        }
        System.assertEquals(vendor.Id, byExtId.get('txn-a:dr:0').AcctSeed__Account__c,
            'Tracked merchant matches the existing vendor Account by name');
        System.assertEquals(null, byExtId.get('txn-b:dr:0').AcctSeed__Account__c,
            'Untracked merchant must not match (and must not be created)');
        System.assertEquals('Chipotle', byExtId.get('txn-b:dr:0').Ramp_Vendor_Name__c,
            'Merchant name still recorded as text even with no Account match');
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = 'Chipotle'],
            'No Account auto-created for untracked merchants');
    }
}
