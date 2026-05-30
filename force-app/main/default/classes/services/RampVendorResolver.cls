/**
 * @description Resolves a Ramp bill's embedded vendor (ApiBillVendor) to a
 * Salesforce vendor Account, bulk. Strategy (auto-create):
 *   1. vendor.remote_id → Account by Id (the ERP bridge — remote_id is the SF
 *      Account Id we sent when the vendor was synced to Ramp as an accounting vendor)
 *   2. else match an active vendor Account by Name
 *   3. else create a new vendor Account
 *
 * Returns a map keyed by the native Ramp vendor id (vendor.id).
 */
public with sharing class RampVendorResolver {

    public static Map<String, Id> resolve(List<RampBillBuilder.BillVendor> vendors) {
        Map<String, Id> result = new Map<String, Id>();
        if (vendors == null || vendors.isEmpty()) return result;

        // De-dupe by native vendor id.
        Map<String, RampBillBuilder.BillVendor> byNative = new Map<String, RampBillBuilder.BillVendor>();
        for (RampBillBuilder.BillVendor v : vendors) {
            if (v != null && String.isNotBlank(v.id)) byNative.put(v.id, v);
        }
        if (byNative.isEmpty()) return result;

        // 1. Bridge: remote_id is our SF Account Id when the vendor is ERP-mapped.
        Set<Id> candidateIds = new Set<Id>();
        for (RampBillBuilder.BillVendor v : byNative.values()) {
            Id parsed = asId(v.remote_id);
            if (parsed != null) candidateIds.add(parsed);
        }
        Set<Id> existingIds = new Set<Id>();
        if (!candidateIds.isEmpty()) {
            for (Account a : [SELECT Id FROM Account WHERE Id IN :candidateIds]) {
                existingIds.add(a.Id);
            }
        }

        Map<String, RampBillBuilder.BillVendor> needName = new Map<String, RampBillBuilder.BillVendor>();
        for (String nativeId : byNative.keySet()) {
            RampBillBuilder.BillVendor v = byNative.get(nativeId);
            Id parsed = asId(v.remote_id);
            if (parsed != null && existingIds.contains(parsed)) {
                result.put(nativeId, parsed);
            } else {
                needName.put(nativeId, v);
            }
        }

        if (needName.isEmpty()) return result;

        // 2. Name match against existing vendor Accounts.
        Set<String> names = new Set<String>();
        for (RampBillBuilder.BillVendor v : needName.values()) {
            if (String.isNotBlank(v.name)) names.add(v.name);
        }
        Map<String, Id> idByName = new Map<String, Id>();
        if (!names.isEmpty()) {
            for (Account a : [
                SELECT Id, Name FROM Account
                WHERE Name IN :names
                  AND AcctSeed__Accounting_Type__c IN ('Vendor', 'Customer and Vendor')
                ORDER BY CreatedDate ASC
            ]) {
                if (!idByName.containsKey(a.Name)) idByName.put(a.Name, a.Id);
            }
        }

        // 3. Create the genuinely-new vendors.
        List<Account> toCreate = new List<Account>();
        List<String> createNativeIds = new List<String>();
        for (String nativeId : needName.keySet()) {
            RampBillBuilder.BillVendor v = needName.get(nativeId);
            if (String.isNotBlank(v.name) && idByName.containsKey(v.name)) {
                result.put(nativeId, idByName.get(v.name));
            } else {
                Account a = new Account(
                    Name = String.isBlank(v.name) ? 'Ramp Vendor ' + v.id : v.name,
                    AcctSeed__Accounting_Type__c = 'Vendor'
                );
                if (String.isNotBlank(v.remote_code)) a.AccountNumber = v.remote_code;
                toCreate.add(a);
                createNativeIds.add(nativeId);
            }
        }
        if (!toCreate.isEmpty()) {
            insert toCreate;
            for (Integer i = 0; i < toCreate.size(); i++) {
                result.put(createNativeIds[i], toCreate[i].Id);
            }
        }
        return result;
    }

    private static Id asId(String s) {
        if (String.isBlank(s)) return null;
        try { return (Id) s; } catch (Exception e) { return null; }
    }
}