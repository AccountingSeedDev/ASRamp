/**
 * @description Batch job to sync Accounts (Vendors) to Ramp accounting vendors.
 * Creates new vendors or updates existing ones based on Ramp_Vendor_Id__c.
 * Designed to run on a schedule for ongoing synchronization.
 *
 * Callout/DML ordering: all HTTP callouts are completed before any DML within
 * each execute() invocation, satisfying the Salesforce "no callout after DML"
 * rule. This prevents the "uncommitted work pending" error when a Restore record
 * (DML) and Update records (callout) land in the same batch chunk.
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
     * @description Execute method - process each batch of accounts.
     * All callouts are issued before any DML to comply with the Salesforce
     * "no callout after uncommitted work" restriction.
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

        // ── All callouts first ──────────────────────────────────────────────
        // Salesforce requires all callouts to precede any DML within a
        // transaction. Restore records only need DML (re-stamp), so they wait.

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

        // createVendorsAndReturnStamped does POST + GET callouts and returns
        // the Account records to stamp — DML happens below after all callouts.
        List<Account> newlyStamped = new List<Account>();
        if (!toCreate.isEmpty()) {
            try {
                newlyStamped = createVendorsAndReturnStamped(toCreate);
                createdCount += toCreate.size();
            } catch (Exception e) {
                errorCount++;
                errors.add('Create batch: ' + e.getMessage());
            }
        }

        // ── DML after all callouts ──────────────────────────────────────────

        if (!toRestore.isEmpty()) {
            try {
                update toRestore;
                restoredCount += toRestore.size();
            } catch (Exception e) {
                errorCount++;
                errors.add('Restore batch: ' + e.getMessage());
            }
        }

        if (!newlyStamped.isEmpty()) {
            try {
                update newlyStamped;
            } catch (Exception e) {
                errorCount++;
                errors.add('Stamp new vendors: ' + e.getMessage());
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
     * @description Updates an existing vendor in Ramp via PATCH.
     * Always sends the code field so that cleared AccountNumber values are
     * reflected in Ramp (omitting the field would leave the old value in place).
     * @param acc The Account to update
     */
    private void updateVendor(Account acc) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'name' => acc.Name,
            'code' => String.isBlank(acc.AccountNumber) ? null : acc.AccountNumber
        };

        String body = JSON.serialize(requestBody);
        String endpoint = '/developer/v1/accounting/vendors/' + acc.Ramp_Vendor_Id__c;

        HttpResponse res = RampAPIService.patch(endpoint, body);

        if (res.getStatusCode() != 200) {
            throw new RampVendorSyncException(
                'PATCH failed. Status: ' + res.getStatusCode() + ', Response: ' + extractErrorDetail(res)
            );
        }
    }

    /**
     * @description POSTs the new vendors to Ramp, then GETs the list to retrieve
     * their ramp_ids. Returns the Account records populated with Ramp_Vendor_Id__c
     * ready for a single DML update after all callouts complete.
     * @param accounts List of Accounts to create as vendors
     * @return List of Account records stamped with Ramp_Vendor_Id__c (no DML performed)
     */
    private List<Account> createVendorsAndReturnStamped(List<Account> accounts) {
        List<Map<String, Object>> vendors = new List<Map<String, Object>>();

        for (Account acc : accounts) {
            Map<String, Object> vendor = new Map<String, Object>{
                'id' => acc.Id,
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

        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new RampVendorSyncException(
                'POST failed. Status: ' + res.getStatusCode() + ', Response: ' + extractErrorDetail(res)
            );
        }

        return buildStampList(accounts);
    }

    /**
     * @description GETs all vendors from Ramp and returns Account records stamped
     * with ramp_id values for those that match our SF Ids. Pure callout — no DML.
     * @param accounts The accounts that were just created via POST
     * @return List of Account records with Ramp_Vendor_Id__c populated
     */
    private List<Account> buildStampList(List<Account> accounts) {
        Set<String> sfIds = new Set<String>();
        for (Account acc : accounts) {
            sfIds.add(acc.Id);
        }

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
                        if (sfIds.contains(vendorId) && String.isNotBlank(rampId)) {
                            sfIdToRampId.put(vendorId, rampId);
                        }
                    }
                }

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

        List<Account> toStamp = new List<Account>();
        for (Account acc : accounts) {
            String rampId = sfIdToRampId.get(acc.Id);
            if (String.isNotBlank(rampId)) {
                toStamp.add(new Account(Id = acc.Id, Ramp_Vendor_Id__c = rampId));
            }
        }
        return toStamp;
    }

    /**
     * @description Extracts a human-readable error detail from an HTTP response.
     * Avoids surfacing raw HTML (e.g., a Ramp 404 page) in error messages.
     * @param res The HTTP response from Ramp
     * @return A clean, human-readable error string
     */
    @TestVisible
    private static String extractErrorDetail(HttpResponse res) {
        Integer statusCode = res.getStatusCode();
        if (statusCode == 404) {
            return 'Vendor not found in Ramp (HTTP 404). The Ramp_Vendor_Id__c may be invalid or the vendor was deleted in Ramp.';
        }
        String responseBody = res.getBody();
        if (String.isBlank(responseBody) || responseBody.trim().startsWith('<')) {
            return 'HTTP ' + statusCode + ' error from Ramp (no JSON detail available).';
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            if (parsed.containsKey('error')) return String.valueOf(parsed.get('error'));
            if (parsed.containsKey('message')) return String.valueOf(parsed.get('message'));
        } catch (Exception e) {
            // Not valid JSON — fall through to truncated body below.
        }
        return responseBody.length() > 500 ? responseBody.substring(0, 500) + '...' : responseBody;
    }

    /**
     * @description Custom exception for Ramp Vendor Sync errors
     */
    public class RampVendorSyncException extends Exception {}
}
