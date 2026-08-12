/**
 * @description Tests for RampTransactionService (page orchestration) and
 * RampTransactionSyncQueueable (the chained driver).
 */
@IsTest
private class RampTransactionServiceTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
        TestDataFactory.getInstance().disableAutoPost();
    }

    /**
     * @description Sets up the overrideSettings, a clearing GL, and a coded
     * expense GL with a known Ramp_Id__c. Returns the expense GL's Ramp UUID
     * for use in mock responses.
     */
    private static String configureForSync() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__GL_Account__c clearingGL;
        AcctSeed__GL_Account__c expenseGL;
        System.runAs(admin) {
            List<AcctSeed__GL_Account__c> gls = [
                SELECT Id, Name FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true
                LIMIT 2
            ];
            clearingGL = gls[0];
            clearingGL.Name = 'CardClearing-TEST';
            expenseGL = gls[1];
            expenseGL.Ramp_Id__c = 'expense-gl-uuid';
            update new List<AcctSeed__GL_Account__c>{ clearingGL, expenseGL };
        }
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        System.runAs(admin) {
            ledger.Name = 'Ledger-TEST';
            update ledger;
        }

        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'Ledger-TEST',
            Default_JE_Status__c = 'In Process',
            Send_Sync_Ack__c = true
        );
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_CARD_CLEARING => clearingGL.Id
        };
        RampSyncSettingsService.resetCache();
        return 'expense-gl-uuid';
    }

    @IsTest
    static void syncPage_emptyResponse_returnsEmptyResult() {
        configureForSync();
        Test.setMock(HttpCalloutMock.class, new EmptyPageMock());

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(0, result.transactionsFetched);
        System.assertEquals(0, result.journalEntriesCreated);
        System.assertEquals(true, result.isLastPage);
    }

    @IsTest
    static void syncPage_singleTransaction_insertsJEAndAcks() {
        String glUuid = configureForSync();
        Test.setMock(HttpCalloutMock.class, new SinglePageMock(glUuid));

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, result.transactionsFetched);
        System.assertEquals(1, result.journalEntriesCreated, 'Errors: ' + result.errorMessages);
        System.assertEquals(0, result.failedCount, 'Errors: ' + result.errorMessages);
        System.assertEquals(0, result.errorMessages.size(), 'Unexpected errors: ' + result.errorMessages);

        // The header is keyed by the daily group, not the txn id; locate it via
        // the transaction's lines (which stay keyed by txn id).
        List<AcctSeed__Journal_Entry__c> jes = [
            SELECT Id, AcctSeed__ExtId__c, Ramp_Sync_Status__c, Ramp_Sync_Error__c,
                (SELECT Id, AcctSeed__ExtId__c, AcctSeed__Debit__c, AcctSeed__Credit__c
                 FROM AcctSeed__Journal_Entry_Lines__r ORDER BY AcctSeed__ExtId__c)
            FROM AcctSeed__Journal_Entry__c
            WHERE AcctSeed__ExtId__c = :dailyKeyForMock()
        ];
        System.assertEquals(1, jes.size());
        System.assertEquals('Synced_To_Ramp', jes[0].Ramp_Sync_Status__c, 'A posted JE is marked synced');
        System.assertEquals(null, jes[0].Ramp_Sync_Error__c);
        System.assertEquals(2, jes[0].AcctSeed__Journal_Entry_Lines__r.size(), 'One debit + one credit');
        System.assertEquals('ramp-txn-success-1:cr', jes[0].AcctSeed__Journal_Entry_Lines__r[0].AcctSeed__ExtId__c);
    }

    @IsTest
    static void syncPage_ackDisabled_stillMarksJESynced() {
        String glUuid = configureForSync();
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'Ledger-TEST',
            Default_JE_Status__c = 'In Process',
            Send_Sync_Ack__c = false
        );
        Test.setMock(HttpCalloutMock.class, new SinglePageMock(glUuid));

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, result.journalEntriesCreated, 'Errors: ' + result.errorMessages);
        // FS-15109: Send_Sync_Ack__c is off by default, so gating the status on the
        // ack left every JE at "Pending" and the dashboard reporting 0 synced.
        AcctSeed__Journal_Entry__c je = [
            SELECT Ramp_Sync_Status__c FROM AcctSeed__Journal_Entry__c
            WHERE AcctSeed__ExtId__c = :dailyKeyForMock()
        ];
        System.assertEquals('Synced_To_Ramp', je.Ramp_Sync_Status__c,
            'A posted JE is synced whether or not the ack is enabled');
    }

    @IsTest
    static void syncPage_ackFails_downgradesJEToFailed() {
        String glUuid = configureForSync();   // ack enabled
        Test.setMock(HttpCalloutMock.class, new AckFailMock(glUuid));

        Test.startTest();
        RampTransactionService.syncPage(null);
        Test.stopTest();

        AcctSeed__Journal_Entry__c je = [
            SELECT Ramp_Sync_Status__c, Ramp_Sync_Error__c FROM AcctSeed__Journal_Entry__c
            WHERE AcctSeed__ExtId__c = :dailyKeyForMock()
        ];
        System.assertEquals('Failed', je.Ramp_Sync_Status__c,
            'Ramp never learned about this JE, so the record must say so');
        System.assert(je.Ramp_Sync_Error__c.contains('500'),
            'Error should carry the ack response: ' + je.Ramp_Sync_Error__c);
    }

    @IsTest
    static void syncPage_idempotent_secondPullDoesNotDuplicate() {
        // Pre-seed a JE with the same AcctSeed__ExtId__c the mock will return,
        // then verify syncPage updates it in place rather than creating a duplicate.
        // This avoids the mixed-DML/uncommitted-work problem of calling syncPage
        // twice in the same test transaction.
        String glUuid = configureForSync();
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];

        AcctSeed__Accounting_Period__c period;
        System.runAs(admin) {
            List<AcctSeed__Accounting_Period__c> periods = [
                SELECT Id, AcctSeed__Start_Date__c
                FROM AcctSeed__Accounting_Period__c
                WHERE AcctSeed__Status__c = 'Open'
                ORDER BY AcctSeed__Start_Date__c DESC
                LIMIT 1
            ];
            period = periods[0];

            insert new AcctSeed__Journal_Entry__c(
                AcctSeed__Journal_Date__c = period.AcctSeed__Start_Date__c,
                AcctSeed__Ledger__c = ledger.Id,
                AcctSeed__Accounting_Period__c = period.Id,
                AcctSeed__Status__c = 'In Process',
                AcctSeed__ExtId__c = dailyKeyForMock(),
                Ramp_Sync_Status__c = 'Pending'
            );
        }

        Test.setMock(HttpCalloutMock.class, new SinglePageMock(glUuid));

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(0, result.journalEntriesCreated, 'Pre-existing daily JE should be updated, not re-created');
        System.assertEquals(1, result.journalEntriesUpdated, 'Pre-existing daily JE should be updated');

        Integer count = [SELECT COUNT() FROM AcctSeed__Journal_Entry__c WHERE AcctSeed__ExtId__c = :dailyKeyForMock()];
        System.assertEquals(1, count, 'Upsert by the daily group key should be idempotent');
    }

    @IsTest
    static void syncPage_unresolvedGL_marksFailedAndReportsToRamp() {
        configureForSync(); // expense-gl-uuid is configured
        Test.setMock(HttpCalloutMock.class, new UnknownGLMock());

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, result.transactionsFetched);
        System.assertEquals(0, result.journalEntriesCreated);
        System.assertEquals(1, result.failedCount);
        // No JE created (builder rejected the transaction)
        Integer count = [SELECT COUNT() FROM AcctSeed__Journal_Entry__c WHERE AcctSeed__ExtId__c = 'ramp-txn-unknown-gl'];
        System.assertEquals(0, count);
    }

    @IsTest
    static void syncPage_paginates_returnsNextCursor() {
        String glUuid = configureForSync();
        Test.setMock(HttpCalloutMock.class, new MultiPageMock(glUuid));

        Test.startTest();
        RampTransactionService.PageResult page1 = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals('cursor-page-2', page1.nextCursor);
        System.assertEquals(false, page1.isLastPage);
        System.assertEquals(1, page1.transactionsFetched);
    }

    @IsTest
    static void queueable_singlePage_executesAndPersists() {
        String glUuid = configureForSync();
        Test.setMock(HttpCalloutMock.class, new SinglePageMock(glUuid));

        Test.startTest();
        System.enqueueJob(new RampTransactionSyncQueueable());
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM AcctSeed__Journal_Entry_Line__c WHERE AcctSeed__ExtId__c = 'ramp-txn-success-1:cr'];
        System.assertEquals(1, count, 'Queueable should drive the same syncPage flow and persist the clearing line');

        // The run logs an Automated Job Result.
        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Processed__c, AcctSeed__Succeeded__c, AcctSeed__Failed__c
            FROM AcctSeed__Automated_Job_Results__c WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_CARD_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'Queueable should log one Automated Job Result');
        System.assertEquals(1, ajrs[0].AcctSeed__Processed__c);
        System.assertEquals(1, ajrs[0].AcctSeed__Succeeded__c);
        System.assertEquals(0, ajrs[0].AcctSeed__Failed__c);
    }

    // --------------------------------------------------------------------
    //  Mocks
    // --------------------------------------------------------------------

    /** Common base — handles the OAuth /token call once, then defers to respondToApi. */
    @IsTest
    static void syncPage_succeededCountIsTalliedNotInferred() {
        String glUuid = configureForSync();
        Test.setMock(HttpCalloutMock.class, new SinglePageMock(glUuid));

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, result.succeededCount,
            'A transaction that reached a persisted JE must be counted as succeeded: ' + result.errorMessages);
        System.assertEquals(0, result.failedCount, 'Errors: ' + result.errorMessages);
        System.assertEquals(result.transactionsFetched, result.succeededCount + result.failedCount,
            'processed must equal succeeded + failed');
    }

    @IsTest
    static void syncPage_buildFailureIsNotCountedAsSuccess() {
        configureForSync();
        Test.setMock(HttpCalloutMock.class, new UnknownGLMock());

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(0, result.succeededCount,
            'A transaction that produced no JE must never be counted as succeeded');
        System.assertEquals(1, result.failedCount);
        System.assertEquals(result.transactionsFetched, result.succeededCount + result.failedCount,
            'processed must equal succeeded + failed');
    }

    @IsTest
    static void syncPage_silentlyDroppedTransactionIsReportedNotCountedAsSuccess() {
        // A transaction with no usable id is skipped by the builder without entering
        // BuildResult.failed. Deriving success as (fetched - failed) reported it as a
        // clean sync with no JE and no error — the FS-15031 symptom. It must now be
        // surfaced as a failure instead.
        configureForSync();
        Test.setMock(HttpCalloutMock.class, new BlankIdMock());

        Test.startTest();
        RampTransactionService.PageResult result = RampTransactionService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, result.transactionsFetched);
        System.assertEquals(0, result.succeededCount, 'A dropped transaction is not a success');
        System.assertEquals(1, result.failedCount, 'The drop must be reported as a failure');
        System.assertEquals(0, [SELECT COUNT() FROM AcctSeed__Journal_Entry__c], 'No JE should exist');

        Boolean explained = false;
        for (String m : result.errorMessages) {
            if (m.contains('neither a Journal Entry nor an error')) explained = true;
        }
        System.assert(explained, 'The run must say why the count does not add up: ' + result.errorMessages);
    }

    /** Returns one transaction with a blank id — the builder's only silent-skip path. */
    private class BlankIdMock extends BaseRampMock {
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/transactions')) {
                res.setStatusCode(200);
                res.setBody(buildTransactionsResponse('expense-gl-uuid', '', null));
            } else if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(201);
                res.setBody('{"id":"sync-resource-uuid"}');
            }
            return res;
        }
    }

    private abstract class BaseRampMock implements HttpCalloutMock {
        protected Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"transactions:read accounting:write"}');
                return res;
            }
            return respondToApi(req, res);
        }

        protected abstract HttpResponse respondToApi(HttpRequest req, HttpResponse res);
    }

    private class EmptyPageMock extends BaseRampMock {
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            res.setStatusCode(200);
            res.setBody('{"data":[],"page":{"next":null}}');
            return res;
        }
    }

    /** One good page, but /accounting/syncs rejects the ack. */
    private class AckFailMock extends BaseRampMock {
        private String glUuid;
        public AckFailMock(String glUuid) { this.glUuid = glUuid; }
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(500);
                res.setBody('{"error":"boom"}');
            } else if (req.getEndpoint().contains('/transactions')) {
                res.setStatusCode(200);
                res.setBody(buildTransactionsResponse(glUuid, 'ramp-txn-success-1', null));
            } else {
                res.setStatusCode(404);
                res.setBody('unexpected ' + req.getEndpoint());
            }
            return res;
        }
    }

    private class SinglePageMock extends BaseRampMock {
        private String glUuid;
        public SinglePageMock(String glUuid) { this.glUuid = glUuid; }
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/transactions')) {
                res.setStatusCode(200);
                res.setBody(buildTransactionsResponse(glUuid, 'ramp-txn-success-1', null));
            } else if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(201);
                res.setBody('{"id":"sync-resource-uuid"}');
            } else {
                res.setStatusCode(404);
                res.setBody('Unexpected endpoint: ' + req.getEndpoint());
            }
            return res;
        }
    }

    private class UnknownGLMock extends BaseRampMock {
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/transactions')) {
                res.setStatusCode(200);
                res.setBody(buildTransactionsResponse('gl-uuid-NOT-IN-ORG', 'ramp-txn-unknown-gl', null));
            } else if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(201);
                res.setBody('{"id":"sync-resource-uuid"}');
            }
            return res;
        }
    }

    private class MultiPageMock extends BaseRampMock {
        private String glUuid;
        public MultiPageMock(String glUuid) { this.glUuid = glUuid; }
        protected override HttpResponse respondToApi(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/transactions')) {
                res.setStatusCode(200);
                // Real shape: page.next is a FULL URL, not a bare token — the
                // service must extract the `start` param to chain correctly.
                res.setBody(buildTransactionsResponse(glUuid, 'ramp-txn-page1',
                    'https://api.ramp.com/developer/v1/transactions?sync_status=SYNC_READY&page_size=100&start=cursor-page-2'));
            } else {
                res.setStatusCode(201);
                res.setBody('{"id":"sync-resource-uuid"}');
            }
            return res;
        }
    }

    /**
     * The Daily group key the builder will derive for the mock transaction:
     * entity_id is null (-> 'X'), currency 'USD', date = latest open period start.
     */
    private static String dailyKeyForMock() {
        Date d = [
            SELECT AcctSeed__Start_Date__c
            FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open'
            ORDER BY AcctSeed__Start_Date__c DESC
            LIMIT 1
        ].AcctSeed__Start_Date__c;
        return 'D:' + String.valueOf(d) + ':X:USD';
    }

    private static String buildTransactionsResponse(String glUuid, String txnId, String nextCursor) {
        List<AcctSeed__Accounting_Period__c> periods = [
            SELECT AcctSeed__Start_Date__c
            FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open'
            ORDER BY AcctSeed__Start_Date__c DESC
            LIMIT 1
        ];
        Date d = periods.isEmpty() ? Date.today() : periods[0].AcctSeed__Start_Date__c;
        String iso = String.valueOf(d) + 'T12:00:00+00:00';
        Map<String, Object> txn = new Map<String, Object>{
            'id' => txnId,
            'amount' => 42.50,
            'currency_code' => 'USD',
            'accounting_date' => iso,
            'user_transaction_time' => iso,
            'merchant_name' => 'Mock Merchant',
            'memo' => 'Mock memo',
            'state' => 'CLEARED',
            'sync_status' => 'SYNC_READY',
            'card_holder' => new Map<String, Object>{
                'first_name' => 'Mock', 'last_name' => 'User'
            },
            'accounting_field_selections' => new List<Object>{
                new Map<String, Object>{
                    'id' => glUuid,
                    'name' => 'Expense',
                    'type' => 'GL_ACCOUNT',
                    'category_info' => new Map<String, Object>{
                        'id' => 'field-uuid',
                        'name' => 'GL Account',
                        'type' => 'GL_ACCOUNT'
                    }
                }
            }
        };
        Map<String, Object> body = new Map<String, Object>{
            'data' => new List<Object>{ txn },
            'page' => new Map<String, Object>{ 'next' => nextCursor }
        };
        return JSON.serialize(body);
    }
}
