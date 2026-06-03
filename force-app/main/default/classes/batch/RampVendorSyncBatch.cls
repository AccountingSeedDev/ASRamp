/**
 * @description Batch job to sync Accounts (Vendors) to Ramp accounting vendors
 * Creates new vendors or updates existing ones based on Ramp_Vendor_Id__c
 * Designed to run on a schedule for ongoing synchronization
 */
public class RampVendorSyncBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private String accountingConnectionId;
    private Integer createdCount = 0;
    private Integer updatedCount = 0;
    private Integer restoredCount = 0;
    private Integer errorCount = 0;
    private List<String> errors = new List<String>();

    // Lazily-populated map of (SF Account Id -> Ramp vendor UUID) for vendors
    // that already exist on Ramp's side. Used to skip duplicate POSTs after a
    // tenant switch or local Ramp_Vendor_Id__c clear.
    private Map<String, String> existingByOurId;
    private Boolean existingMapLoaded = false;

    /**
     * @description Constructor - fetches accounting connection ID
     */
    public RampVendorSyncBatch() {
        try {
            Map<String, Object> connection = RampAccountingService.getAccountingConnection();
            this.accountingConnectionId = (String) connection.get('id');
        } catch (Exception e) {
            this.accountingConnectionId = null;
        }
    }

    /**
     * @description Constructor with explicit connection ID
     * @param accountingConnectionId The Ramp accounting connection ID
     */
    public RampVendorSyncBatch(String accountingConnectionId) {
        this.accountingConnectionId = accountingConnectionId;
    }

    /**
     * @description Start method - query Accounts that are Vendors
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, AccountNumber, Ramp_Vendor_Id__c
            FROM Account
            WHERE AcctSeed__Accounting_Type__c IN ('Vendor', 'Customer and Vendor')
        ]);
    }

    /**
     * @description Execute method - process each batch of accounts
     */
    public void execute(Database.BatchableContext bc, List<Account> scope) {
        if (String.isBlank(accountingConnectionId)) {
            errors.add('No accounting connection ID available');
            errorCount++;
            return;
        }

        // Lazy-load the "already on Ramp" map on first execute. One callout
        // shared across all chunks since the class is Database.Stateful.
        if (!existingMapLoaded) {
            try {
                existingByOurId = fetchExistingRampVendors();
            } catch (Exception e) {
                // Don't fail the run — treat Ramp as empty if discovery breaks.
                System.debug(LoggingLevel.WARN, 'fetchExistingRampVendors failed: ' + e.getMessage());
                existingByOurId = new Map<String, String>();
            }
            existingMapLoaded = true;
        }

        // Three buckets:
        //   toUpdate  — local Ramp_Vendor_Id__c is set → PATCH
        //   toRestore — Ramp already has a vendor with our SF Id but local pointer is null → re-stamp, no API
        //   toCreate  — neither side has a record → POST
        List<Account> toCreate = new List<Account>();
        List<Account> toUpdate = new List<Account>();
        List<Account> toRestore = new List<Account>();

        for (Account acc : scope) {
            if (String.isNotBlank(acc.Ramp_Vendor_Id__c)) {
                toUpdate.add(acc);
            } else if (existingByOurId.containsKey(acc.Id)) {
                acc.Ramp_Vendor_Id__c = existingByOurId.get(acc.Id);
                toRestore.add(acc);
            } else {
                toCreate.add(acc);
            }
        }

        // Restamp locally — no callouts.
        if (!toRestore.isEmpty()) {
            try {
                update toRestore;
                restoredCount += toRestore.size();
            } catch (Exception e) {
                errorCount++;
                errors.add('Restore batch: ' + e.getMessage());
            }
        }

        // PATCH existing records.
        for (Account acc : toUpdate) {
            try {
                updateVendor(acc);
                updatedCount++;
            } catch (Exception e) {
                errorCount++;
                errors.add('Update ' + acc.Name + ': ' + e.getMessage());
            }
        }

        // POST genuinely-new ones.
        if (!toCreate.isEmpty()) {
            try {
                createVendors(toCreate);
                createdCount += toCreate.size();
            } catch (Exception e) {
                errorCount++;
                errors.add('Create batch: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Paginates GET /accounting/vendors and returns a map keyed by
     * the "id" we originally sent (= our Salesforce 18-char Id).
     */
    @TestVisible
    private Map<String, String> fetchExistingRampVendors() {
        Map<String, String> sfIdToRampId = new Map<String, String>();
        String nextStart = null;
        Integer pages = 0;

        do {
            String endpoint = '/developer/v1/accounting/vendors?page_size=100';
            if (String.isNotBlank(nextStart)) {
                endpoint += '&start=' + EncodingUtil.urlEncode(nextStart, 'UTF-8');
            }

            HttpResponse res = RampAPIService.get(endpoint);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.WARN,
                    'fetchExistingRampVendors page ' + pages + ' returned ' +
                    res.getStatusCode() + ': ' + res.getBody());
                break;
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> data = (List<Object>) body.get('data');
            if (data != null) {
                for (Object o : data) {
                    Map<String, Object> v = (Map<String, Object>) o;
                    String sfId = (String) v.get('id');
                    String rampId = (String) v.get('ramp_id');
                    Boolean isActive = (Boolean) v.get('is_active');
                    Boolean active = (isActive == null) ? true : isActive;
                    if (String.isNotBlank(sfId) && String.isNotBlank(rampId) && active) {
                        sfIdToRampId.put(sfId, rampId);
                    }
                }
            }

            nextStart = extractNextCursor(body);
            pages++;
        } while (String.isNotBlank(nextStart) && pages < 50);

        return sfIdToRampId;
    }

    private static String extractNextCursor(Map<String, Object> body) {
        Map<String, Object> page = (Map<String, Object>) body.get('page');
        if (page == null) return null;
        String nextUrl = (String) page.get('next');
        if (String.isBlank(nextUrl)) return null;
        Integer i = nextUrl.indexOf('start=');
        if (i < 0) return null;
        String cursor = nextUrl.substring(i + 6);
        Integer amp = cursor.indexOf('&');
        if (amp >= 0) cursor = cursor.substring(0, amp);
        return cursor;
    }

    /**
     * @description Finish method - log results
     */
    public void finish(Database.BatchableContext bc) {
        Integer processed = createdCount + updatedCount + restoredCount + errorCount;
        Integer succeeded = createdCount + updatedCount + restoredCount;

        String notes = 'Created: ' + createdCount + ' · Updated: ' + updatedCount +
                       ' · Restored: ' + restoredCount + ' · Errors: ' + errorCount;
        if (processed == 0) {
            notes += '\nNo vendor Accounts (Accounting Type Vendor / Customer and Vendor) were found to sync.';
        }
        if (!errors.isEmpty()) {
            notes = RampJobResultLogger.appendNote(notes, 'Error details:\n' + String.join(errors, '\n'));
        }

        RampJobResultLogger.record(
            null, RampJobResultLogger.JOB_VENDOR_SYNC, processed, succeeded, errorCount, notes
        );

        System.debug(notes);
    }

    /**
     * @description Updates an existing vendor in Ramp via PATCH
     * @param acc The Account to update
     */
    private void updateVendor(Account acc) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'name' => acc.Name
        };

        if (String.isNotBlank(acc.AccountNumber)) {
            requestBody.put('code', acc.AccountNumber);
        }

        String body = JSON.serialize(requestBody);
        String endpoint = '/developer/v1/accounting/vendors/' + acc.Ramp_Vendor_Id__c;

        HttpResponse res = RampAPIService.patch(endpoint, body);

        if (res.getStatusCode() != 200) {
            throw new RampVendorSyncException(
                'PATCH failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description Creates new vendors in Ramp via batch POST
     * @param accounts List of Accounts to create as vendors
     */
    private void createVendors(List<Account> accounts) {
        // Build vendors array
        List<Map<String, Object>> vendors = new List<Map<String, Object>>();

        for (Account acc : accounts) {
            Map<String, Object> vendor = new Map<String, Object>{
                'id' => acc.Id,  // Use SF ID as the vendor ID
                'name' => acc.Name
            };

            if (String.isNotBlank(acc.AccountNumber)) {
                vendor.put('code', acc.AccountNumber);
            }

            vendors.add(vendor);
        }

        Map<String, Object> requestBody = new Map<String, Object>{
            'vendors' => vendors,
            'accounting_connection_id' => accountingConnectionId
        };

        String body = JSON.serialize(requestBody);
        HttpResponse res = RampAPIService.post('/developer/v1/accounting/vendors', body);

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            // Fetch the created vendors to get ramp_ids
            fetchAndUpdateRampIds(accounts);
        } else {
            throw new RampVendorSyncException(
                'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody()
            );
        }
    }

    /**
     * @description Fetches vendors from Ramp and updates Account records with ramp_ids
     * @param accounts The accounts that were created
     */
    private void fetchAndUpdateRampIds(List<Account> accounts) {
        // Build set of SF IDs we're looking for
        Set<String> sfIds = new Set<String>();
        for (Account acc : accounts) {
            sfIds.add(acc.Id);
        }

        // Fetch vendors from Ramp and build id -> ramp_id map
        Map<String, String> sfIdToRampId = new Map<String, String>();
        String nextPage = null;

        do {
            String endpoint = '/developer/v1/accounting/vendors';
            if (nextPage != null) {
                endpoint += '?start=' + nextPage;
            }

            HttpResponse res = RampAPIService.get(endpoint);

            if (res.getStatusCode() == 200) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                if (response.containsKey('data')) {
                    List<Object> vendorsList = (List<Object>) response.get('data');
                    for (Object v : vendorsList) {
                        Map<String, Object> vendorMap = (Map<String, Object>) v;
                        String vendorId = (String) vendorMap.get('id');
                        String rampId = (String) vendorMap.get('ramp_id');

                        // Only process if this is one of our accounts
                        if (sfIds.contains(vendorId) && String.isNotBlank(rampId)) {
                            sfIdToRampId.put(vendorId, rampId);
                        }
                    }
                }

                // Check for pagination
                if (response.containsKey('page')) {
                    Map<String, Object> page = (Map<String, Object>) response.get('page');
                    nextPage = (String) page.get('next');
                } else {
                    nextPage = null;
                }
            } else {
                System.debug('Failed to fetch vendors: ' + res.getStatusCode() + ' - ' + res.getBody());
                nextPage = null;
            }
        } while (nextPage != null && sfIdToRampId.size() < sfIds.size());

        // Update Account records with Ramp IDs
        List<Account> toUpdateRecords = new List<Account>();
        for (Account acc : accounts) {
            String rampId = sfIdToRampId.get(acc.Id);
            if (String.isNotBlank(rampId)) {
                toUpdateRecords.add(new Account(
                    Id = acc.Id,
                    Ramp_Vendor_Id__c = rampId
                ));
            }
        }

        if (!toUpdateRecords.isEmpty()) {
            update toUpdateRecords;
        }
    }

    /**
     * @description Custom exception for Ramp Vendor Sync errors
     */
    public class RampVendorSyncException extends Exception {}
}