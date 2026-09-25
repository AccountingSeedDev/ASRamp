/**
 * @description Tests for RampCustomDimensionService: validate() (the gatekeeper for
 * Ramp_Custom_Dimension__mdt registrations) and syncFieldsToRamp() (the field create/repair
 * callout built on top of it).
 */
@IsTest
private class RampCustomDimensionServiceTest {

    // No credential is packaged; inject a synthetic one for the callout path.
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    private static final String TEST_CONNECTION_ID = 'test-connection-12345678-1234-1234-1234-123456789012';

    // Ramp's internal field id is unrelated to the external id we send, as it is in Ramp.
    private static final String RAMP_ID_PREFIX = 'ramp-internal-';

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    private static Ramp_Custom_Dimension__mdt registration(String objectApiName, String labelField,
            String activeField, String optionIdField, String jeLineField, String payableLineField) {
        return new Ramp_Custom_Dimension__mdt(
            DeveloperName = 'Test_Dimension',
            Label = 'Test Dimension',
            Object_API_Name__c = objectApiName,
            Label_Field_API_Name__c = labelField,
            Active_Field_API_Name__c = activeField,
            Ramp_Option_Id_Field_API_Name__c = optionIdField,
            JE_Line_Field_API_Name__c = jeLineField,
            Payable_Line_Field_API_Name__c = payableLineField
        );
    }

    private static Ramp_Custom_Dimension__mdt validSyncRegistration(String objectApiName, String rampFieldLabel) {
        Ramp_Custom_Dimension__mdt r = registration(
            objectApiName, null, 'AcctSeed__Active__c', 'Ramp_Field_Option_Id__c', null, null
        );
        r.Ramp_Field_Label__c = rampFieldLabel;
        r.Active__c = true;
        return r;
    }

    @IsTest
    static void validate_nullRegistration_returnsProblemWithoutThrowing() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(null);
            Test.stopTest();

            System.assertEquals(1, problems.size());
        }
    }

    @IsTest
    static void validate_fullyValidRegistration_returnsNoProblems() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c',
                'Ramp_Field_Option_Id__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assertEquals(0, problems.size(), 'Expected no problems: ' + problems);
        }
    }

    @IsTest
    static void validate_blankObjectApiName_reportsRequired() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(null, null, null, 'Ramp_Field_Option_Id__c', null, null);

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'Object_API_Name__c is required'), 'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_unknownObject_reportsUnresolved() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'Not_A_Real_Object__c', null, null, 'Ramp_Field_Option_Id__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'does not resolve to a known object'),
                'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_missingOptionIdField_reportsRequired() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, null, null, null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'Ramp_Option_Id_Field_API_Name__c is required'),
                'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_optionIdFieldWrongTypeAndTooShort_reportsBothProblems() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, null, 'AcctSeed__Active__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'must be a Text field'), 'Problems: ' + problems);
            System.assert(hasProblemContaining(problems, 'must be at least 36 characters'), 'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_activeFieldWrongType_reportsProblem() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'Name', 'Ramp_Field_Option_Id__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'must be a Checkbox field'), 'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_labelFieldUnknown_reportsProblem() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', 'Not_A_Real_Field__c', 'AcctSeed__Active__c',
                'Ramp_Field_Option_Id__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'Label_Field_API_Name__c "Not_A_Real_Field__c" does not exist'),
                'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_reservedGLAccountVariableLabel_isRejectedCaseInsensitively() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c', 'Ramp_Field_Option_Id__c', null, null
            );
            r.Ramp_Field_Label__c = 'gl account variable 5';

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'cannot start with'), 'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_jeLineReferenceField_matchingRegisteredObject_returnsNoProblems() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__GL_Account__c', null, 'AcctSeed__Active__c', 'Ramp_Id__c',
                'AcctSeed__GL_Account__c', null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assertEquals(0, problems.size(), 'Expected no problems: ' + problems);
        }
    }

    @IsTest
    static void validate_jeLineReferenceField_mismatchedRegisteredObject_reportsProblem() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c', 'Ramp_Field_Option_Id__c',
                'AcctSeed__GL_Account__c', null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'is a lookup but does not reference'),
                'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_payableLineFieldUnknown_reportsProblem() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c', 'Ramp_Field_Option_Id__c',
                null, 'Not_A_Real_Field__c'
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(hasProblemContaining(problems, 'Payable_Line_Field_API_Name__c "Not_A_Real_Field__c" does not exist'),
                'Problems: ' + problems);
        }
    }

    @IsTest
    static void validate_payableLineFieldValid_returnsNoProblems() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c', 'Ramp_Field_Option_Id__c',
                null, 'Ramp_Description__c'
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assertEquals(0, problems.size(), 'Expected no problems: ' + problems);
        }
    }

    @IsTest
    static void validate_namespacePrefixedFieldName_resolvesToUnprefixedField() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'AcctSeed__Accounting_Variable__c', null, 'AcctSeed__Active__c',
                'AcctSeedRamp__Ramp_Field_Option_Id__c', null, null
            );

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assertEquals(0, problems.size(), 'Expected the namespace-prefixed field name to resolve: ' + problems);
        }
    }

    @IsTest
    static void validate_garbageInput_neverThrows() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt r = registration(
                'Nonsense__c', 'Nonsense__c', 'Nonsense__c', 'Nonsense__c', 'Nonsense__c', 'Nonsense__c'
            );
            r.Ramp_Field_Label__c = 'GL Account Variable Nonsense';

            Test.startTest();
            List<String> problems = RampCustomDimensionService.validate(r);
            Test.stopTest();

            System.assert(!problems.isEmpty(), 'Expected problems to be reported, not thrown: ' + problems);
        }
    }

    private static Boolean hasProblemContaining(List<String> problems, String substring) {
        for (String problem : problems) {
            if (problem.contains(substring)) {
                return true;
            }
        }
        return false;
    }

    // ─────────────────────────── syncFieldsToRamp ───────────────────────────

    @IsTest
    static void syncFieldsToRamp_validActiveRegistration_postsSingleChoiceWithDeterministicId() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt registration = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ registration };

            RampCustomDimensionMockSuccess mock = new RampCustomDimensionMockSuccess();
            mock.postReturnsSplittable = true;

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, mock);
            String result = RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
            Test.stopTest();

            System.assertEquals(1, mock.postCount, 'Exactly one POST should fire for the one valid registration');
            System.assert(mock.lastRequestBody.contains('"input_type":"SINGLE_CHOICE"'), 'Body: ' + mock.lastRequestBody);

            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequestBody);
            System.assertEquals(
                RampCustomDimensionService.fieldIdFor(registration), (String) sent.get('id'),
                'The field id must be the deterministic id derived from Object_API_Name__c'
            );

            System.assert(result.contains('Created'), 'Result: ' + result);
            System.assertEquals(0, mock.patchCount, 'An already-splittable field should not trigger a PATCH');
        }
    }

    @IsTest
    static void syncFieldsToRamp_reRun_isIdempotent() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt registration = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ registration };

            RampCustomDimensionMockSuccess mock = new RampCustomDimensionMockSuccess();
            mock.postReturnsSplittable = true;

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, mock);
            RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
            RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
            Test.stopTest();

            System.assertEquals(2, mock.postCount, 'Each run posts once; re-running does not skip the call');
            System.assertEquals(
                mock.firstRequestId, mock.lastRequestId,
                'Re-running must send the same deterministic id both times, so Ramp treats it as the same field'
            );
        }
    }

    @IsTest
    static void syncFieldsToRamp_relabeling_reusesSameDeterministicId() {
        Ramp_Custom_Dimension__mdt original = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
        Ramp_Custom_Dimension__mdt relabeled = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Cost Center');

        System.assertEquals(
            RampCustomDimensionService.fieldIdFor(original), RampCustomDimensionService.fieldIdFor(relabeled),
            'The id is derived from Object_API_Name__c only, so relabeling must not change it'
        );
    }

    /**
     * The regression guard for FS-15129. Ramp's POST leaves an existing field alone, so the
     * sync has to follow up with a PATCH — and that PATCH has to target ramp_id, because the
     * deterministic external id 404s.
     */
    @IsTest
    static void syncFieldsToRamp_notSplittable_patchesRampIdNotDeterministicId() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt registration = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ registration };

            RampCustomDimensionMockSuccess mock = new RampCustomDimensionMockSuccess();
            mock.postReturnsSplittable = false;

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, mock);
            String result = RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
            Test.stopTest();

            String deterministicId = RampCustomDimensionService.fieldIdFor(registration);
            System.assertEquals(1, mock.patchCount, 'A non-splittable create must trigger exactly one PATCH');
            System.assert(
                mock.lastPatchEndpoint.contains(RAMP_ID_PREFIX),
                'PATCH must target the ramp_id: ' + mock.lastPatchEndpoint
            );
            System.assert(
                !mock.lastPatchEndpoint.contains(deterministicId),
                'PATCH must never target the deterministic external id: ' + mock.lastPatchEndpoint
            );
            System.assert(result.contains('marked splittable'), 'Result: ' + result);
        }
    }

    @IsTest
    static void syncFieldsToRamp_invalidRegistration_isSkippedWithoutCallout() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt invalid = validSyncRegistration(null, 'Bad Dimension');
            Ramp_Custom_Dimension__mdt valid = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ invalid, valid };

            RampCustomDimensionMockSuccess mock = new RampCustomDimensionMockSuccess();
            mock.postReturnsSplittable = true;

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, mock);
            String result = RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
            Test.stopTest();

            System.assertEquals(1, mock.postCount, 'No callout should be attempted for the invalid registration');
            System.assert(result.contains('skipped'), 'Result should report the skip: ' + result);
            System.assert(result.contains('Created'), 'Result should still process the valid registration: ' + result);
        }
    }

    @IsTest
    static void syncFieldsToRamp_createFailure_throwsWithContext() {
        User admin = TestDataFactory.getInstance().getAdminUser();
        System.runAs(admin) {
            Ramp_Custom_Dimension__mdt registration = validSyncRegistration('AcctSeed__Accounting_Variable__c', 'Program');
            RampCustomDimensionService.overrideRegistrations = new List<Ramp_Custom_Dimension__mdt>{ registration };

            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new RampCustomDimensionMockError());

            try {
                RampCustomDimensionService.syncFieldsToRamp(TEST_CONNECTION_ID);
                System.assert(false, 'Expected an exception when the create call fails');
            } catch (RampCustomDimensionService.RampCustomDimensionException e) {
                System.assert(e.getMessage().contains('Test_Dimension'), 'Exception should name the registration: ' + e.getMessage());
            }

            Test.stopTest();
        }
    }

    /**
     * Mirrors how Ramp actually answers these endpoints (see RampAccountingFieldServiceTest):
     * POST for an id Ramp already holds returns 201 with the stored field, and PATCH accepts
     * only ramp_id — the deterministic external id 404s with DEVELOPER_7002.
     */
    private class RampCustomDimensionMockSuccess implements HttpCalloutMock {
        public String lastRequestBody;
        public String firstRequestId;
        public String lastRequestId;
        public String lastPatchEndpoint;
        public Integer postCount = 0;
        public Integer patchCount = 0;
        public Boolean postReturnsSplittable = false;

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"test_token","token_type":"Bearer","expires_in":864000,"scope":"accounting:write"}');
                return res;
            }

            if (req.getMethod() == 'POST') {
                postCount++;
                lastRequestBody = req.getBody();
                Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                String externalId = (String) sent.get('id');
                if (firstRequestId == null) firstRequestId = externalId;
                lastRequestId = externalId;

                res.setStatusCode(201);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'id' => externalId,
                    'ramp_id' => RAMP_ID_PREFIX + postCount,
                    'name' => sent.get('name'),
                    'is_active' => true,
                    'is_splittable' => postReturnsSplittable
                }));
            } else if (req.getMethod() == 'PATCH') {
                patchCount++;
                lastPatchEndpoint = req.getEndpoint();
                if (!req.getEndpoint().contains(RAMP_ID_PREFIX)) {
                    res.setStatusCode(404);
                    res.setBody('{"error_v2":{"error_code":"DEVELOPER_7002",' +
                        '"message":"The requested Accounting Field does not exist."}}');
                } else {
                    res.setStatusCode(200);
                    res.setBody('{"is_splittable":true}');
                }
            }

            return res;
        }
    }

    private class RampCustomDimensionMockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setHeader('Content-Type', 'application/json');

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
