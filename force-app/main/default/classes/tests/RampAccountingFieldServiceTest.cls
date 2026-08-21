/**
 * @description Test class for RampAccountingFieldService
 */
@IsTest
private class RampAccountingFieldServiceTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    // Ramp's internal field id is unrelated to the external id we send, as it is in Ramp.
    private static final String RAMP_ID_PREFIX = 'ramp-internal-';

    @IsTest
    static void testSyncAccountingVariablesToRamp_Success() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);

        Test.stopTest();

        // Verify all 4 fields were created
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.contains('GL Account Variable 1'), 'Result should mention Variable 1');
        System.assert(result.contains('GL Account Variable 2'), 'Result should mention Variable 2');
        System.assert(result.contains('GL Account Variable 3'), 'Result should mention Variable 3');
        System.assert(result.contains('GL Account Variable 4'), 'Result should mention Variable 4');
        System.assert(result.contains('Created'), 'Result should indicate fields were created');
    }

    @IsTest
    static void testCreateCustomField_ApiFailure() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockError());

        try {
            RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);
            System.assert(false, 'Should have thrown exception');
        } catch (RampAccountingFieldService.RampAccountingFieldException e) {
            System.assert(e.getMessage().contains('Error'), 'Exception should contain error message');
        }

        Test.stopTest();
    }

    @IsTest
    static void testCreateVariableField_SendsSplittableFlag() {
        RampAccountingFieldMockSuccess mock = new RampAccountingFieldMockSuccess();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);

        RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);

        Test.stopTest();

        System.assert(
            mock.lastRequestBody != null && mock.lastRequestBody.contains('"is_splittable":true'),
            'Field creation request should mark the field as splittable so it can be coded on line items'
        );
    }

    /**
     * The regression guard for FS-15129. Ramp's POST leaves an existing field alone, so the
     * sync has to follow up with a PATCH — and that PATCH has to target ramp_id, because the
     * deterministic external id 404s. Asserting the endpoint (not just "a PATCH happened")
     * is what makes this fail against the id the original fix used.
     */
    @IsTest
    static void testSyncAccountingVariablesToRamp_PatchesSplittableByRampId() {
        RampAccountingFieldMockSuccess mock = new RampAccountingFieldMockSuccess();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);

        String result = RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);

        Test.stopTest();

        System.assertEquals(4, mock.patchCount, 'Each of the 4 fields should be PATCHed when Ramp reports it as header-level only');
        System.assert(
            mock.lastPatchEndpoint != null && mock.lastPatchEndpoint.contains(RAMP_ID_PREFIX),
            'PATCH must target the ramp_id; the external id returns 404 DEVELOPER_7002. Endpoint was: ' + mock.lastPatchEndpoint
        );
        System.assert(result.contains('marked splittable'), 'Summary should report the repair: ' + result);
    }

    /**
     * A field Ramp already reports as splittable needs no PATCH — re-running the sync
     * should not spend a callout per field on every run.
     */
    @IsTest
    static void testSyncAccountingVariablesToRamp_SkipsPatchWhenAlreadySplittable() {
        RampAccountingFieldMockSuccess mock = new RampAccountingFieldMockSuccess();
        mock.postReturnsSplittable = true;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);

        String result = RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);

        Test.stopTest();

        System.assertEquals(0, mock.patchCount, 'No PATCH should be sent for a field that is already splittable');
        System.assert(!result.contains('marked splittable'), 'Summary should not claim a repair: ' + result);
    }

    @IsTest
    static void testSyncAccountingVariablesToRamp_PatchFailureSurfaces() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockPatchRejected());

        try {
            RampAccountingFieldService.syncAccountingVariablesToRamp(TEST_CONNECTION_ID);
            System.assert(false, 'A rejected PATCH should not be reported as a successful sync');
        } catch (RampAccountingFieldService.RampAccountingFieldException e) {
            System.assert(
                e.getMessage().contains('splittable'),
                'Exception should name the splittable repair: ' + e.getMessage()
            );
        }

        Test.stopTest();
    }

    @IsTest
    static void testMakeFieldSplittable_Success() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.makeFieldSplittable(RAMP_ID_PREFIX + 'field-1');

        Test.stopTest();

        System.assert(result.contains('Status: 200'), 'Should return a success status: ' + result);
    }

    @IsTest
    static void testMakeFieldSplittable_ExternalIdIsRejected() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        // The deterministic id we send as 'id' is not a key this endpoint resolves.
        String result = RampAccountingFieldService.makeFieldSplittable('03e8de8f-b0fe-5c11-a07d-ec31a96eec01');

        Test.stopTest();

        System.assert(result.contains('Status: 404'), 'External id should not resolve to a field: ' + result);
    }

    @IsTest
    static void testRepairVariableFieldsSplittable_ResolvesRampIdAndSkipsInactive() {
        RampAccountingFieldMockSuccess mock = new RampAccountingFieldMockSuccess();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);

        String result = RampAccountingFieldService.repairVariableFieldsSplittable();

        Test.stopTest();

        System.assert(result.contains('GL Account Variable 1: marked splittable'), 'Variable 1 should be repaired: ' + result);
        System.assert(result.contains('GL Account Variable 3: marked splittable'), 'Variable 3 should be repaired: ' + result);
        // Variable 4 is inactive in the mocked field list; a repair must not reactivate it.
        System.assert(result.contains('GL Account Variable 4: skipped (inactive in Ramp)'), 'Variable 4 should be skipped: ' + result);
        System.assertEquals(3, mock.patchCount, 'Only the 3 active fields should be PATCHed');
        System.assert(
            mock.lastPatchEndpoint != null && mock.lastPatchEndpoint.contains(RAMP_ID_PREFIX),
            'Repair must PATCH the ramp_id from the field list: ' + mock.lastPatchEndpoint
        );
    }

    @IsTest
    static void testRepairVariableFieldsSplittable_ReportsMissingField() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockEmptyFieldList());

        String result = RampAccountingFieldService.repairVariableFieldsSplittable();

        Test.stopTest();

        System.assert(
            result.contains('not found in Ramp'),
            'A field Ramp does not hold should be reported, not silently skipped: ' + result
        );
    }

    @IsTest
    static void testGetCustomFields() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockSuccess());

        String result = RampAccountingFieldService.getCustomFields();

        Test.stopTest();

        System.assert(result.contains('Status: 200'), 'Should return status 200');
    }

    @IsTest
    static void testDeleteCustomField() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new RampAccountingFieldMockDelete());

        String result = RampAccountingFieldService.deleteCustomField('test-field-id');

        Test.stopTest();

        System.assert(result.contains('Status: 204'), 'Should return status 204');
    }

    /**
     * Mock that mirrors how Ramp actually answers these endpoints, verified against the
     * live API while diagnosing FS-15129:
     *
     *  - POST /accounting/fields for an id Ramp already holds answers 201 with the STORED
     *    field and silently discards is_splittable. Returning is_splittable:false here even
     *    though the request said true is the whole point — a mock that echoes the request
     *    back passes against code that never PATCHes.
     *  - PATCH /accounting/fields/{id} accepts ONLY ramp_id. The deterministic external id
     *    we send as 'id' answers 404 DEVELOPER_7002, so a mock that accepts any PATCH URL
     *    passes against code that PATCHes the wrong id.
     */
    private class RampAccountingFieldMockSuccess implements HttpCalloutMock {
        public String lastRequestBody;
        public String lastPatchEndpoint;
        public Integer patchCount = 0;
        // Set true to have POST report a field that is already splittable (a fresh create).
        public Boolean postReturnsSplittable = false;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'POST') {
                lastRequestBody = req.getBody();
                Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                String externalId = (String) sent.get('id');
                res.setStatusCode(201);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'id' => externalId,
                    'ramp_id' => RAMP_ID_PREFIX + externalId,
                    'name' => sent.get('name'),
                    'is_active' => true,
                    // Ramp ignores is_splittable on an existing field — do not echo it back.
                    'is_splittable' => postReturnsSplittable
                }));
            } else if (req.getMethod() == 'PATCH') {
                lastRequestBody = req.getBody();
                lastPatchEndpoint = req.getEndpoint();
                patchCount++;
                if (!req.getEndpoint().contains(RAMP_ID_PREFIX)) {
                    // Anything other than a ramp_id does not resolve to a field.
                    res.setStatusCode(404);
                    res.setBody('{"error_v2":{"error_code":"DEVELOPER_7002",' +
                        '"message":"The requested Accounting Field does not exist."}}');
                } else {
                    res.setStatusCode(200);
                    res.setBody('{"id":"ext","ramp_id":"' + RAMP_ID_PREFIX + 'ext","is_splittable":true}');
                }
            } else if (req.getMethod() == 'GET') {
                res.setStatusCode(200);
                res.setBody(fieldListBody());
            }

            return res;
        }

        /**
         * GL Account Variable 1-4 as Ramp would list them for an org that connected before
         * is_splittable was set: 1-3 active and header-level only, 4 deactivated.
         */
        private String fieldListBody() {
            List<Object> data = new List<Object>();
            for (Integer i = 1; i <= 4; i++) {
                data.add(new Map<String, Object>{
                    'id' => 'external-uuid-' + i,
                    'ramp_id' => RAMP_ID_PREFIX + i,
                    'name' => 'GL Account Variable ' + i,
                    'is_active' => (i != 4),
                    'is_splittable' => false
                });
            }
            return JSON.serialize(new Map<String, Object>{
                'data' => data,
                'page' => new Map<String, Object>{ 'next' => null }
            });
        }
    }

    /**
     * POST succeeds but the follow-up PATCH is rejected, so the sync must not report the
     * field as usable.
     */
    private class RampAccountingFieldMockPatchRejected implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'POST') {
                Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                res.setStatusCode(201);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'id' => sent.get('id'),
                    'ramp_id' => RAMP_ID_PREFIX + sent.get('id'),
                    'is_splittable' => false
                }));
                return res;
            }

            res.setStatusCode(400);
            res.setBody('{"error_v2":{"error_code":"DEVELOPER_7001","message":"Invalid input"}}');
            return res;
        }
    }

    /**
     * Ramp holds no custom fields — the repair has nothing to resolve a ramp_id from.
     */
    private class RampAccountingFieldMockEmptyFieldList implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            res.setStatusCode(200);
            res.setBody('{"data":[],"page":{"next":null}}');
            return res;
        }
    }

    /**
     * Mock HTTP callout for delete response
     */
    private class RampAccountingFieldMockDelete implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            res.setStatusCode(204);
            res.setBody('');
            return res;
        }
    }

    /**
     * Mock HTTP callout for error responses
     */
    private class RampAccountingFieldMockError implements HttpCalloutMock {
        private Boolean tokenProvided = false;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            // Handle OAuth token request
            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            res.setStatusCode(400);
            res.setBody('{"error": "Bad Request"}');
            return res;
        }
    }
}