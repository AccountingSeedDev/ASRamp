/**
 * @description Tests for RampVendorResolver — bill vendor → AS Account via the
 * remote_id bridge, name match, and auto-create.
 */
@IsTest
private class RampVendorResolverTest {

    private static RampBillBuilder.BillVendor vendor(String nativeId, String name, String remoteId, String code) {
        RampBillBuilder.BillVendor v = new RampBillBuilder.BillVendor();
        v.id = nativeId; v.name = name; v.remote_id = remoteId; v.remote_code = code;
        return v;
    }

    @IsTest
    static void resolvesByRemoteIdBridge() {
        Account a = new Account(Name = 'Acme Co', AcctSeed__Accounting_Type__c = 'Vendor');
        insert a;

        Test.startTest();
        Map<String, Id> r = RampVendorResolver.resolve(new List<RampBillBuilder.BillVendor>{
            vendor('nv-1', 'Acme Co', a.Id, null)
        });
        Test.stopTest();

        System.assertEquals(a.Id, r.get('nv-1'), 'remote_id should resolve straight to the Account');
    }

    @IsTest
    static void resolvesByNameWhenRemoteIdBlank() {
        Account a = new Account(Name = 'Beta LLC', AcctSeed__Accounting_Type__c = 'Vendor');
        insert a;

        Test.startTest();
        Map<String, Id> r = RampVendorResolver.resolve(new List<RampBillBuilder.BillVendor>{
            vendor('nv-2', 'Beta LLC', null, null)
        });
        Test.stopTest();

        System.assertEquals(a.Id, r.get('nv-2'), 'should match the existing vendor by name');
    }

    @IsTest
    static void createsWhenUnmapped() {
        Test.startTest();
        Map<String, Id> r = RampVendorResolver.resolve(new List<RampBillBuilder.BillVendor>{
            vendor('nv-3', 'Gamma Inc', null, 'V-100')
        });
        Test.stopTest();

        System.assertNotEquals(null, r.get('nv-3'), 'a new Account should be created');
        Account created = [
            SELECT Name, AccountNumber, AcctSeed__Accounting_Type__c
            FROM Account WHERE Id = :r.get('nv-3')
        ];
        System.assertEquals('Gamma Inc', created.Name);
        System.assertEquals('V-100', created.AccountNumber);
        System.assertEquals('Vendor', created.AcctSeed__Accounting_Type__c);
    }

    @IsTest
    static void staleRemoteIdFallsBackToCreate() {
        // remote_id points at a non-existent Account → should not resolve to it.
        RampBillBuilder.BillVendor v = vendor('nv-4', 'Delta Co', '001000000000000AAA', null);
        Test.startTest();
        Map<String, Id> r = RampVendorResolver.resolve(new List<RampBillBuilder.BillVendor>{ v });
        Test.stopTest();
        System.assertNotEquals(null, r.get('nv-4'));
        System.assertNotEquals('001000000000000AAA', String.valueOf(r.get('nv-4')), 'should create, not use the stale id');
    }
}
