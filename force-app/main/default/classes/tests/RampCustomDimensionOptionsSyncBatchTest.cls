/**
 * @description Tests for RampCustomDimensionOptionsSyncBatch. Registrations point at
 * AcctSeed__Accounting_Variable__c / Ramp_Field_Option_Id__c, the same valid registration
 * RampCustomDimensionServiceTest uses, and RampOptionsMock simulates Ramp's field and
 * field-option endpoints with an in-memory option store.
 */
@IsTest
private class RampCustomDimensionOptionsSyncBatchTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';
    private static final String FIELD_RAMP_ID = 'ramp-field-internal-1';
    private static final String RAMP_OPTION_PREFIX = 'ramp-opt-';

    // Every callout the mock sees, in order, as "METHOD /path". Apex inner classes cannot hold
    // static members, so the log lives here.
    private static List<String> callLog = new List<String>();
    // Raw `start` values the field-options GET received, to prove only bare cursors are sent.
    private static List<String> startParams = new List<String>();
    private static String lastPostFieldId;

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    private static Ramp_Custom_Dimension__mdt registration(String developerName, String rampFieldLabel) {
        return new Ramp_Custom_Dimension__mdt(
            DeveloperName = developerName,
            Label = developerName,
            Object_API_Name__c = 'AcctSeed__Accounting_Variable__c',
            Active_Field_API_Name__c = 'AcctSeed__Active__c',
            Ramp_Option_Id_Field_API_Name__c = 'Ramp_Field_Option_Id__c',
            Ramp_Field_Label__c = rampFieldLabel,
            Active__c = true
        );
    }

    private static List<AcctSeed__Accounting_Variable__c> insertVariables(Integer count, Boolean active) {
        List<AcctSeed__Accounting_Variable__c> variables = new List<AcctSeed__Accounting_Variable__c>();
        for (Integer i = 0; i < count; i++) {
            variables.add(new AcctSeed__Accounting_Variable__c(
                Name = (active ? 'Program ' : 'Retired Program ') + i,
                AcctSeed__Type__c = 'GL Account Variable 1',
                AcctSeed__Active__c = active
            ));
        }
        insert variables;
        return variables;
    }

    /** Every record the batch's query will pick up for the test registration. */
    private static List<AcctSeed__Accounting_Variable__c> inScopeVariables() {
        return [
            SELECT Id, Name, Ramp_Field_Option_Id__c
            FROM AcctSeed__Accounting_Variable__c
            WHERE AcctSeed__Active__c = true OR Ramp_Field_Option_Id__c != null
        ];
    }

    private static String optionIdFor(Ramp_Custom_Dimension__mdt r, Id recordId) {
        return RampDeterministicIdUtil.generateUUID(
            RampCustomDimensionOptionsSyncBatch.OPTION_ID_SEED_PREFIX +
            RampCustomDimensionService.fieldIdFor(r) + ':' + recordId
        );
    }

    private static AcctSeed__Automated_Job_Results__c onlyAjr() {
        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Processed__c, AcctSeed__Succeeded__c, AcctSeed__Failed__c, AcctSeed__Notes__c
            FROM AcctSeed__Automated_Job_Results__c
            WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_CUSTOM_DIMENSION_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'One registration run should log exactly one AJR');
        return ajrs[0];
    }

    private static Integer countCalls(String prefix) {
        Integer n = 0;
        for (String call : callLog) {
            if (call.startsWith(prefix)) n++;
        }
        return n;
    }

    // ─────────────────────────── full sync ───────────────────────────

    @IsTest
    static void fullSync_stampsOptionIdOnEveryActiveRecord() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(30, true);
            List<AcctSeed__Accounting_Variable__c> inactive = insertVariables(1, false);
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ r };
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));
            Integer expected = inScopeVariables().size();

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Id jobId = RampCustomDimensionOptionsSyncBatch.startSync(TEST_CONNECTION_ID);
            Test.stopTest();

            System.assertNotEquals(null, jobId, 'An active registration should start the chain');
            for (AcctSeed__Accounting_Variable__c v : inScopeVariables()) {
                System.assert(v.Ramp_Field_Option_Id__c != null && v.Ramp_Field_Option_Id__c.startsWith(RAMP_OPTION_PREFIX),
                    v.Name + ' should be stamped with its Ramp option id: ' + v.Ramp_Field_Option_Id__c);
            }
            System.assertEquals(expected, mock.optionsById.size(), 'Ramp should hold one option per active record');
            System.assertEquals(null,
                [SELECT Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c WHERE Id = :inactive[0].Id]
                    .Ramp_Field_Option_Id__c,
                'An inactive record that was never synced must not be created in Ramp');
            System.assertEquals(FIELD_RAMP_ID, lastPostFieldId, 'POST must target the resolved field ramp_id');

            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(expected, ajr.AcctSeed__Succeeded__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
        }
    }

    // ─────────────────────────── phase order ───────────────────────────

    @IsTest
    static void execute_runsPatchThenPostThenGetBeforeDml() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(3, true);
            AcctSeed__Accounting_Variable__c existing = new AcctSeed__Accounting_Variable__c(
                Name = 'Already Synced', AcctSeed__Type__c = 'GL Account Variable 1',
                AcctSeed__Active__c = true, Ramp_Field_Option_Id__c = RAMP_OPTION_PREFIX + 'existing'
            );
            insert existing;
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            Integer lastPatch = -1;
            Integer firstPost = -1;
            Integer lastPost = -1;
            Integer firstOptionGet = -1;
            for (Integer i = 0; i < callLog.size(); i++) {
                String call = callLog[i];
                if (call.startsWith('PATCH')) lastPatch = i;
                if (call.startsWith('POST /developer/v1/accounting/field-options')) {
                    if (firstPost < 0) firstPost = i;
                    lastPost = i;
                }
                if (call.startsWith('GET /developer/v1/accounting/field-options') && firstOptionGet < 0) firstOptionGet = i;
            }
            System.assert(lastPatch >= 0 && firstPost >= 0 && firstOptionGet >= 0, 'Calls: ' + callLog);
            System.assert(lastPatch < firstPost, 'Every PATCH must precede the POST: ' + callLog);
            System.assert(lastPost < firstOptionGet, 'Every POST must precede the lookup GET: ' + callLog);

            // Phase 4's DML ran after all of the callouts above — had it not, the callouts
            // would have thrown "You have uncommitted work pending" and nothing would be stamped.
            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            for (AcctSeed__Accounting_Variable__c v : inScopeVariables()) {
                System.assertNotEquals(null, v.Ramp_Field_Option_Id__c, v.Name + ' should be stamped');
            }
        }
    }

    // ─────────────────────────── leaving / re-entering scope ───────────────────────────

    /**
     * A record leaving scope must hide its option — never deactivate it — and keep its stamped
     * option id, so lines already coded to it keep exporting and resolving.
     */
    @IsTest
    static void execute_recordLeavingScope_hidesOptionAndNeverDeactivates() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            AcctSeed__Accounting_Variable__c retired = new AcctSeed__Accounting_Variable__c(
                Name = 'Retired', AcctSeed__Type__c = 'GL Account Variable 1',
                AcctSeed__Active__c = false, Ramp_Field_Option_Id__c = RAMP_OPTION_PREFIX + 'retired'
            );
            insert retired;
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            String body = mock.patchBodiesByPath.get('/developer/v1/accounting/field-options/' + RAMP_OPTION_PREFIX + 'retired');
            System.assertNotEquals(null, body, 'The retired option should be PATCHed: ' + callLog);
            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(body);
            System.assertEquals(RampCustomDimensionOptionsSyncBatch.VISIBILITY_HIDDEN, sent.get('visibility'),
                'A record leaving scope must hide its Ramp option: ' + body);
            System.assert(!sent.containsKey('is_active'),
                'is_active must never be sent for a record leaving scope: ' + body);
            System.assertEquals(0, countCalls('POST /developer/v1/accounting/field-options'),
                'A hidden record must not be re-created in Ramp: ' + callLog);
            System.assertEquals(RAMP_OPTION_PREFIX + 'retired',
                [SELECT Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c WHERE Id = :retired.Id]
                    .Ramp_Field_Option_Id__c,
                'Hiding must keep the stamped option id so existing codings still resolve');

            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(1, ajr.AcctSeed__Succeeded__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
        }
    }

    /**
     * A record re-entering scope still holds its option id, so it must un-hide that same option
     * rather than POST a new one.
     */
    @IsTest
    static void execute_recordReenteringScope_unhidesSameOption() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            AcctSeed__Accounting_Variable__c reopened = new AcctSeed__Accounting_Variable__c(
                Name = 'Reopened', AcctSeed__Type__c = 'GL Account Variable 1',
                AcctSeed__Active__c = true, Ramp_Field_Option_Id__c = RAMP_OPTION_PREFIX + 'reopened'
            );
            insert reopened;
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            String body = mock.patchBodiesByPath.get('/developer/v1/accounting/field-options/' + RAMP_OPTION_PREFIX + 'reopened');
            System.assertNotEquals(null, body, 'The re-entering option should be PATCHed: ' + callLog);
            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(body);
            System.assertEquals(RampCustomDimensionOptionsSyncBatch.VISIBILITY_VISIBLE, sent.get('visibility'),
                'A record re-entering scope must un-hide its Ramp option: ' + body);
            System.assert(!sent.containsKey('is_active'), 'is_active must not be sent: ' + body);
            System.assertEquals(0, countCalls('POST /developer/v1/accounting/field-options'),
                'A re-entering record must not be treated as a new option: ' + callLog);
            System.assertEquals(RAMP_OPTION_PREFIX + 'reopened',
                [SELECT Ramp_Field_Option_Id__c FROM AcctSeed__Accounting_Variable__c WHERE Id = :reopened.Id]
                    .Ramp_Field_Option_Id__c,
                'The record must stay linked to its original option');
        }
    }

    // ─────────────────────────── pagination ───────────────────────────

    @IsTest
    static void lookup_followsPageNextAcrossPages() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(5, true);
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));
            // 150 unrelated options ahead of ours push our records onto the second page.
            mock.fillerOptions = 150;

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            System.assert(countCalls('GET /developer/v1/accounting/field-options') >= 2,
                'The lookup must page past the first 100 options: ' + callLog);
            for (String start : startParams) {
                System.assert(!start.contains('http') && !start.contains('field_remote_id'),
                    'Only the bare cursor may be passed back as start, not the page.next URL: ' + start);
            }
            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            for (AcctSeed__Accounting_Variable__c v : inScopeVariables()) {
                System.assertNotEquals(null, v.Ramp_Field_Option_Id__c, v.Name + ' should be stamped');
            }
        }
    }

    // ─────────────────────────── resume after partial failure ───────────────────────────

    /**
     * Simulates an earlier run whose POST reached Ramp but whose stamp never committed: half
     * the options already exist, so Ramp's all-or-nothing POST rejects the batch with
     * DEVELOPER_7020. That must be a warning, the new half must still be created, and every
     * record must end up stamped.
     */
    @IsTest
    static void resume_duplicateRejection_isWarningAndEveryRecordIsStamped() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(10, true);
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));
            List<AcctSeed__Accounting_Variable__c> all = inScopeVariables();
            for (Integer i = 0; i < all.size(); i += 2) {
                mock.seedOption(optionIdFor(r, all[i].Id), all[i].Name, all[i].Id);
            }

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'DEVELOPER_7020 must not count as a failure: ' + ajr.AcctSeed__Notes__c);
            System.assertEquals(all.size(), ajr.AcctSeed__Succeeded__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assertEquals(all.size(), ajr.AcctSeed__Processed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assert(ajr.AcctSeed__Notes__c.contains('Warnings:') && ajr.AcctSeed__Notes__c.contains('DEVELOPER_7020'),
                'The rejection should be surfaced as a warning: ' + ajr.AcctSeed__Notes__c);
            System.assertEquals(all.size(), mock.optionsById.size(), 'The missing half must still be created');
            for (AcctSeed__Accounting_Variable__c v : inScopeVariables()) {
                System.assertNotEquals(null, v.Ramp_Field_Option_Id__c, v.Name + ' should be stamped');
            }
        }
    }

    // ─────────────────────────── field resolution ───────────────────────────

    @IsTest
    static void fieldResolution_keysOnDeterministicIdNotName() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(2, true);
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(r));
            // The real field was renamed in Ramp, and an unrelated field now carries the old name.
            mock.fieldName = 'Renamed In Ramp';
            mock.decoyFieldName = 'Program';

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            System.assertEquals(FIELD_RAMP_ID, lastPostFieldId,
                'The field must be found by its deterministic id, not by the (renamed) name');
            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(0, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
        }
    }

    @IsTest
    static void fieldResolution_fieldMissingInRamp_failsWithoutPosting() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(2, true);
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            RampOptionsMock mock = new RampOptionsMock('some-other-field-id');

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            System.assertEquals(0, countCalls('POST'), 'No option may be POSTed without the field: ' + callLog);
            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(inScopeVariables().size(), ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assert(ajr.AcctSeed__Notes__c.contains('Run the custom dimension field sync first'),
                'Notes: ' + ajr.AcctSeed__Notes__c);
        }
    }

    // ─────────────────────────── chaining / start ───────────────────────────

    @IsTest
    static void finish_chainsNextRegistration() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            insertVariables(2, true);
            Ramp_Custom_Dimension__mdt first = registration('First_Dimension', 'Program');
            Ramp_Custom_Dimension__mdt second = registration('Second_Dimension', 'Cost Center');
            RampCustomDimensionService.overrideRegistrations =
                new List<Ramp_Custom_Dimension__mdt>{ first, second };
            RampOptionsMock mock = new RampOptionsMock(RampCustomDimensionService.fieldIdFor(first));

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            RampCustomDimensionOptionsSyncBatch.startSync(TEST_CONNECTION_ID);
            Test.stopTest();

            // Test.stopTest() also runs the batch chained from finish(), so each registration
            // logs its own AJR.
            Map<String, String> notesByRegistration = new Map<String, String>();
            for (AcctSeed__Automated_Job_Results__c ajr : [
                SELECT AcctSeed__Notes__c
                FROM AcctSeed__Automated_Job_Results__c
                WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_CUSTOM_DIMENSION_SYNC
            ]) {
                String registrationName = ajr.AcctSeed__Notes__c.substringBetween('Registration: ', '\n');
                notesByRegistration.put(registrationName, ajr.AcctSeed__Notes__c);
            }
            System.assertEquals(new Set<String>{ 'First_Dimension', 'Second_Dimension' }, notesByRegistration.keySet(),
                'Each registration should log exactly one AJR: ' + notesByRegistration);

            String firstNotes = notesByRegistration.get('First_Dimension');
            System.assert(firstNotes.contains('Next registration queued: Second_Dimension'),
                'finish() should chain the next registration: ' + firstNotes);
            String secondNotes = notesByRegistration.get('Second_Dimension');
            System.assert(!secondNotes.contains('Next registration queued'),
                'The last registration must not chain further: ' + secondNotes);
            System.assertEquals(2, [
                SELECT COUNT() FROM AsyncApexJob
                WHERE JobType = 'BatchApex' AND ApexClass.Name = 'RampCustomDimensionOptionsSyncBatch'
            ], 'One batch instance per registration');
        }
    }

    @IsTest
    static void startSync_noActiveRegistrations_returnsNull() {
        RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>();
        System.assertEquals(null, RampCustomDimensionOptionsSyncBatch.startSync(TEST_CONNECTION_ID));
    }

    @IsTest
    static void start_invalidRegistration_isLoggedWithoutCallouts() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            Ramp_Custom_Dimension__mdt r = registration('Broken', 'Program');
            r.Object_API_Name__c = 'Not_A_Real_Object__c';
            RampOptionsMock mock = new RampOptionsMock('unused');

            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Database.executeBatch(new RampCustomDimensionOptionsSyncBatch(
                TEST_CONNECTION_ID, new List<Ramp_Custom_Dimension__mdt>{ r }), 50);
            Test.stopTest();

            System.assert(callLog.isEmpty(), 'An invalid registration must not reach Ramp: ' + callLog);
            AcctSeed__Automated_Job_Results__c ajr = onlyAjr();
            System.assertEquals(1, ajr.AcctSeed__Failed__c, 'Notes: ' + ajr.AcctSeed__Notes__c);
            System.assert(ajr.AcctSeed__Notes__c.contains('Registration skipped') &&
                          ajr.AcctSeed__Notes__c.contains('does not resolve to a known object'),
                'Notes: ' + ajr.AcctSeed__Notes__c);
        }
    }

    // ─────────────────────────── dynamic SOQL ───────────────────────────

    @IsTest
    static void buildQuery_usesDescribeDerivedNames() {
        System.runAs(TestDataFactory.getInstance().getAdminUser()) {
            Ramp_Custom_Dimension__mdt r = registration('Program', 'Program');
            // Unusual-but-valid spellings: wrong case and the package namespace spelled out.
            r.Object_API_Name__c = 'acctseed__accounting_variable__c';
            r.Active_Field_API_Name__c = 'ACCTSEED__ACTIVE__C';
            r.Ramp_Option_Id_Field_API_Name__c = 'AcctSeedRamp__Ramp_Field_Option_Id__c';
            r.Label_Field_API_Name__c = 'name';

            RampCustomDimensionService.ResolvedRegistration resolved = RampCustomDimensionService.resolve(r);
            String soql = RampCustomDimensionOptionsSyncBatch.buildQuery(resolved);

            Schema.DescribeSObjectResult d = AcctSeed__Accounting_Variable__c.SObjectType.getDescribe();
            System.assertEquals(d.getName(), resolved.objectApiName);
            System.assertEquals(d.fields.getMap().get('acctseed__active__c').getDescribe().getName(),
                resolved.activeFieldApiName);
            System.assertEquals(d.fields.getMap().get('name').getDescribe().getName(), resolved.labelFieldApiName);
            System.assert(soql.contains(' FROM ' + d.getName()), soql);
            System.assert(!soql.contains('acctseed__accounting_variable__c') && !soql.contains('ACCTSEED__ACTIVE__C'),
                'Raw CMDT text must never reach the query: ' + soql);
            Database.query(soql);
        }
    }

    @IsTest
    static void resolve_invalidRegistration_throws() {
        Ramp_Custom_Dimension__mdt r = registration('Broken', 'Program');
        r.Object_API_Name__c = 'Account; DELETE';
        try {
            RampCustomDimensionService.resolve(r);
            System.assert(false, 'An unresolvable object must throw');
        } catch (RampCustomDimensionService.RampCustomDimensionException e) {
            System.assert(e.getMessage().contains('does not resolve to a known object'), e.getMessage());
        }
    }

    /**
     * Simulates Ramp's accounting fields and field-options endpoints:
     *  - GET fields lists the registration's field (by its deterministic id) and an optional
     *    decoy that carries a confusable name.
     *  - POST field-options is all-or-nothing: any option id already in the store rejects the
     *    whole request with DEVELOPER_7020.
     *  - GET field-options requires field_remote_id and pages 100 at a time, returning the
     *    complete next-page URL in page.next and rejecting anything but a bare cursor as start
     *    with DEVELOPER_7001, as Ramp does.
     */
    private class RampOptionsMock implements HttpCalloutMock {
        public String fieldExternalId;
        public String fieldName = 'Program';
        public String decoyFieldName;
        public Integer fillerOptions = 0;
        public Map<String, Map<String, Object>> optionsById = new Map<String, Map<String, Object>>();
        public Map<String, String> patchBodiesByPath = new Map<String, String>();
        private List<String> orderedIds = new List<String>();

        public RampOptionsMock(String fieldExternalId) {
            this.fieldExternalId = fieldExternalId;
        }

        public void seedOption(String id, String value, String code) {
            orderedIds.add(id);
            optionsById.put(id, new Map<String, Object>{
                'id' => id, 'value' => value, 'code' => code,
                'ramp_id' => RAMP_OPTION_PREFIX + optionsById.size(), 'is_active' => true
            });
        }

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');
            String endpoint = req.getEndpoint();

            if (endpoint.contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            String path = endpoint.substring(endpoint.indexOf('/developer/'));
            String pathOnly = path.contains('?') ? path.substring(0, path.indexOf('?')) : path;
            callLog.add(req.getMethod() + ' ' + pathOnly);
            Map<String, String> params = new PageReference(path).getParameters();

            if (req.getMethod() == 'GET' && pathOnly.endsWith('/accounting/fields')) {
                List<Object> fields = new List<Object>();
                if (decoyFieldName != null) {
                    fields.add(new Map<String, Object>{
                        'id' => 'decoy-field-id', 'ramp_id' => 'ramp-field-decoy', 'name' => decoyFieldName
                    });
                }
                fields.add(new Map<String, Object>{
                    'id' => fieldExternalId, 'ramp_id' => FIELD_RAMP_ID, 'name' => fieldName
                });
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{ 'data' => fields, 'page' => new Map<String, Object>() }));
            } else if (req.getMethod() == 'POST' && pathOnly.endsWith('/accounting/field-options')) {
                Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                lastPostFieldId = (String) sent.get('field_id');
                List<Object> options = (List<Object>) sent.get('options');
                for (Object o : options) {
                    if (optionsById.containsKey((String) ((Map<String, Object>) o).get('id'))) {
                        res.setStatusCode(400);
                        res.setBody('{"error_v2":{"error_code":"DEVELOPER_7020",' +
                                    '"message":"Failed to upload custom field options: an option with the same id already exists"}}');
                        return res;
                    }
                }
                for (Object o : options) {
                    Map<String, Object> option = (Map<String, Object>) o;
                    seedOption((String) option.get('id'), (String) option.get('value'), (String) option.get('code'));
                }
                res.setStatusCode(201);
                res.setBody('{}');
            } else if (req.getMethod() == 'GET' && pathOnly.endsWith('/accounting/field-options')) {
                if (params.get('field_remote_id') != fieldExternalId) {
                    res.setStatusCode(200);
                    res.setBody('{"data":[],"page":{"next":null}}');
                    return res;
                }
                Integer offset = 0;
                String start = params.get('start');
                if (start != null) {
                    startParams.add(start);
                    if (!start.startsWith('cursor')) {
                        res.setStatusCode(400);
                        res.setBody('{"error_v2":{"error_code":"DEVELOPER_7001","message":"Not a valid UUID"}}');
                        return res;
                    }
                    offset = Integer.valueOf(start.substring(6));
                }

                List<Object> all = new List<Object>();
                for (Integer i = 0; i < fillerOptions; i++) {
                    all.add(new Map<String, Object>{
                        'id' => 'filler-' + i, 'code' => 'filler-' + i, 'ramp_id' => 'ramp-filler-' + i
                    });
                }
                for (String id : orderedIds) {
                    all.add(optionsById.get(id));
                }

                List<Object> page = new List<Object>();
                for (Integer i = offset; i < Math.min(offset + 100, all.size()); i++) {
                    page.add(all[i]);
                }
                String next = offset + 100 < all.size()
                    ? 'https://api.ramp.com/developer/v1/accounting/field-options?field_remote_id=' +
                      fieldExternalId + '&page_size=100&start=cursor' + (offset + 100)
                    : null;
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'data' => page, 'page' => new Map<String, Object>{ 'next' => next }
                }));
            } else if (req.getMethod() == 'PATCH') {
                patchBodiesByPath.put(pathOnly, req.getBody());
                res.setStatusCode(200);
                res.setBody('{}');
            } else {
                res.setStatusCode(404);
                res.setBody('{}');
            }
            return res;
        }
    }
}
