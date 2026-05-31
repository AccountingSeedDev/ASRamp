/**
 * @description Tests for RampBillService — fetch sync-ready bills, create Payables,
 * and acknowledge BILL_SYNC.
 */
@IsTest
private class RampBillServiceTest {

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    private static Id configureForSync() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        AcctSeed__Ledger__c ledger = TestDataFactory.getInstance().getLedgers()[0];
        AcctSeed__GL_Account__c coded;
        AcctSeed__GL_Account__c suspense;
        AcctSeed__GL_Account__c bank;
        System.runAs(admin) {
            ledger.Name = 'BillLedger-TEST';
            update ledger;
            List<AcctSeed__GL_Account__c> gls = [
                SELECT Id, Ramp_Id__c FROM AcctSeed__GL_Account__c
                WHERE AcctSeed__Active__c = true AND AcctSeed__Bank__c = false AND AcctSeed__Type__c = 'Expense'
                LIMIT 2
            ];
            coded = gls[0]; coded.Ramp_Id__c = 'gl-svc-1'; update coded;
            suspense = gls[1];
            bank = [SELECT Id FROM AcctSeed__GL_Account__c WHERE AcctSeed__Active__c = true AND AcctSeed__Bank__c = true LIMIT 1];
        }
        RampSyncSettingsService.overrideSettings = new Ramp_Sync_Settings__mdt(
            Default_Ledger__c = 'BillLedger-TEST', Default_JE_Status__c = 'In Process', Send_Sync_Ack__c = true
        );
        RampSyncSettingsService.overrideGLDefaults = new Map<String, Id>{
            RampSyncSettingsService.SPEC_SUSPENSE => suspense.Id,
            RampSyncSettingsService.SPEC_BILL_PAYMENT_BANK => bank.Id
        };
        RampSyncSettingsService.resetCache();

        Account v = new Account(Name = 'Mock Vendor', AcctSeed__Accounting_Type__c = 'Vendor');
        insert v;
        return v.Id;
    }

    @IsTest
    static void syncPage_emptyResponse_returnsEmpty() {
        configureForSync();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        Test.startTest();
        RampBillService.PageResult r = RampBillService.syncPage(null);
        Test.stopTest();

        System.assertEquals(0, r.billsFetched);
        System.assertEquals(0, r.payablesCreated);
        System.assertEquals(true, r.isLastPage);
    }

    @IsTest
    static void syncPage_singleBill_createsPayableAndAcks() {
        Id vId = configureForSync();
        Test.setMock(HttpCalloutMock.class, new SingleBillMock(vId));

        Test.startTest();
        RampBillService.PageResult r = RampBillService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.billsFetched);
        System.assertEquals(1, r.payablesCreated, 'Errors: ' + r.errorMessages);
        System.assertEquals(0, r.failedCount, 'Errors: ' + r.errorMessages);

        List<AcctSeed__Account_Payable__c> aps = [
            SELECT Ramp_Sync_Status__c, AcctSeed__Vendor__c,
                (SELECT AcctSeed__ExtId__c, AcctSeed__Amount__c FROM AcctSeed__Project_Account_Payable_Lines__r)
            FROM AcctSeed__Account_Payable__c WHERE AcctSeed__ExtId__c = 'ramp-bill-1'
        ];
        System.assertEquals(1, aps.size());
        System.assertEquals(vId, aps[0].AcctSeed__Vendor__c);
        System.assertEquals('Synced_To_Ramp', aps[0].Ramp_Sync_Status__c, 'BILL_SYNC ack should flip status');
        System.assertEquals(1, aps[0].AcctSeed__Project_Account_Payable_Lines__r.size());
        System.assertEquals('ramp-bill-1:L0', aps[0].AcctSeed__Project_Account_Payable_Lines__r[0].AcctSeed__ExtId__c);
    }

    @IsTest
    static void syncPage_paidBill_createsCashDisbursementAndAPD() {
        Id vId = configureForSync();
        Test.setMock(HttpCalloutMock.class, new PaidBillMock(vId));

        Test.startTest();
        RampBillService.PageResult r = RampBillService.syncPage(null);
        Test.stopTest();

        System.assertEquals(1, r.payablesCreated, 'Errors: ' + r.errorMessages);
        System.assertEquals(1, r.cashDisbursementsCreated, 'Errors: ' + r.errorMessages);

        AcctSeed__Account_Payable__c ap = [SELECT Id FROM AcctSeed__Account_Payable__c WHERE AcctSeed__ExtId__c = 'ramp-bill-paid'];
        List<AcctSeed__Cash_Disbursement__c> cds = [SELECT Id, AcctSeed__Amount__c FROM AcctSeed__Cash_Disbursement__c WHERE AcctSeed__ExtId__c = 'ramp-bill-paid:cd'];
        System.assertEquals(1, cds.size(), 'Cash Disbursement should be created');
        System.assertEquals(200.00, cds[0].AcctSeed__Amount__c);
        List<AcctSeed__AP_Disbursement__c> apds = [
            SELECT Id, AcctSeed__Paid_Amount__c, AcctSeed__Account_Payable__c, AcctSeed__Cash_Disbursement__c
            FROM AcctSeed__AP_Disbursement__c WHERE AcctSeed__ExtId__c = 'ramp-bill-paid:apd'
        ];
        System.assertEquals(1, apds.size(), 'AP Disbursement should link payable + CD');
        System.assertEquals(ap.Id, apds[0].AcctSeed__Account_Payable__c);
        System.assertEquals(cds[0].Id, apds[0].AcctSeed__Cash_Disbursement__c);
        System.assertEquals(200.00, apds[0].AcctSeed__Paid_Amount__c);
    }

    @IsTest
    static void queueable_logsAutomatedJobResult() {
        Id vId = configureForSync();
        Test.setMock(HttpCalloutMock.class, new SingleBillMock(vId));

        Test.startTest();
        System.enqueueJob(new RampBillSyncQueueable());
        Test.stopTest();

        List<AcctSeed__Automated_Job_Results__c> ajrs = [
            SELECT AcctSeed__Processed__c, AcctSeed__Succeeded__c, AcctSeed__Failed__c
            FROM AcctSeed__Automated_Job_Results__c WHERE AcctSeed__Schedule_Job_Type__c = :RampJobResultLogger.JOB_BILL_SYNC
        ];
        System.assertEquals(1, ajrs.size(), 'Bill queueable should log one Automated Job Result');
        System.assertEquals(1, ajrs[0].AcctSeed__Processed__c);
        System.assertEquals(1, ajrs[0].AcctSeed__Succeeded__c);
    }

    // --------------------------------------------------------------------
    //  Mocks
    // --------------------------------------------------------------------
    private abstract class BaseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"t","token_type":"Bearer","expires_in":864000,"scope":"bills:read accounting:write"}');
                return res;
            }
            return api(req, res);
        }
        protected abstract HttpResponse api(HttpRequest req, HttpResponse res);
    }

    private class EmptyMock extends BaseMock {
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            res.setStatusCode(200); res.setBody('{"data":[],"page":{"next":null}}'); return res;
        }
    }

    private class SingleBillMock extends BaseMock {
        private Id vendorId;
        public SingleBillMock(Id v) { this.vendorId = v; }
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/bills')) {
                res.setStatusCode(200);
                res.setBody(billJson(vendorId));
            } else if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(201); res.setBody('{"id":"sync-uuid"}');
            } else {
                res.setStatusCode(404); res.setBody('unexpected ' + req.getEndpoint());
            }
            return res;
        }
    }

    private class PaidBillMock extends BaseMock {
        private Id vendorId;
        public PaidBillMock(Id v) { this.vendorId = v; }
        protected override HttpResponse api(HttpRequest req, HttpResponse res) {
            if (req.getEndpoint().contains('/bills')) {
                res.setStatusCode(200); res.setBody(paidBillJson(vendorId));
            } else if (req.getEndpoint().contains('/accounting/syncs')) {
                res.setStatusCode(201); res.setBody('{"id":"sync-uuid"}');
            } else { res.setStatusCode(404); res.setBody('unexpected ' + req.getEndpoint()); }
            return res;
        }
    }

    private static String openIso() {
        Date d = [
            SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1
        ].AcctSeed__Start_Date__c;
        return String.valueOf(d);
    }

    private static String paidBillJson(Id vendorId) {
        String day = openIso();
        String iso = day + 'T00:00:00+00:00';
        Map<String, Object> money = new Map<String, Object>{ 'amount' => 20000, 'currency_code' => 'USD', 'minor_unit_conversion_rate' => 100 };
        Map<String, Object> line = new Map<String, Object>{ 'amount' => money, 'memo' => 'paid line', 'accounting_field_selections' => new List<Object>{
            new Map<String, Object>{ 'id' => 'gl-svc-1', 'category_info' => new Map<String, Object>{ 'type' => 'GL_ACCOUNT' } } } };
        Map<String, Object> payment = new Map<String, Object>{ 'id' => 'pay-1', 'amount' => money, 'payment_method' => 'PAID_MANUALLY', 'payment_date' => day };
        Map<String, Object> bill = new Map<String, Object>{
            'id' => 'ramp-bill-paid', 'invoice_number' => 'INV-PAID', 'issued_at' => iso, 'due_at' => iso, 'paid_at' => iso,
            'status' => 'PAID', 'sync_status' => 'NOT_SYNCED', 'entity_id' => 'e1', 'amount' => money,
            'vendor' => new Map<String, Object>{ 'id' => 'nv-paid', 'name' => 'Paid Mock Vendor', 'remote_id' => String.valueOf(vendorId) },
            'line_items' => new List<Object>{ line }, 'payment' => payment
        };
        return JSON.serialize(new Map<String, Object>{ 'data' => new List<Object>{ bill }, 'page' => new Map<String, Object>{ 'next' => null } });
    }

    private static String billJson(Id vendorId) {
        Date d = [
            SELECT AcctSeed__Start_Date__c FROM AcctSeed__Accounting_Period__c
            WHERE AcctSeed__Status__c = 'Open' ORDER BY AcctSeed__Start_Date__c DESC LIMIT 1
        ].AcctSeed__Start_Date__c;
        String iso = String.valueOf(d) + 'T00:00:00+00:00';
        Map<String, Object> money = new Map<String, Object>{ 'amount' => 10000, 'currency_code' => 'USD', 'minor_unit_conversion_rate' => 100 };
        Map<String, Object> sel = new Map<String, Object>{ 'id' => 'gl-svc-1', 'category_info' => new Map<String, Object>{ 'type' => 'GL_ACCOUNT' } };
        Map<String, Object> line = new Map<String, Object>{ 'amount' => money, 'memo' => 'svc line', 'accounting_field_selections' => new List<Object>{ sel } };
        Map<String, Object> bill = new Map<String, Object>{
            'id' => 'ramp-bill-1', 'invoice_number' => 'INV-1', 'issued_at' => iso, 'due_at' => iso,
            'status' => 'OPEN', 'sync_status' => 'NOT_SYNCED', 'entity_id' => 'e1', 'amount' => money,
            'vendor' => new Map<String, Object>{ 'id' => 'nv-1', 'name' => 'Mock Vendor', 'remote_id' => String.valueOf(vendorId) },
            'line_items' => new List<Object>{ line }
        };
        return JSON.serialize(new Map<String, Object>{ 'data' => new List<Object>{ bill }, 'page' => new Map<String, Object>{ 'next' => null } });
    }
}
