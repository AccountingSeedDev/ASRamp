/**
 * @description Tests for RampCustomDimensionService.validate — the gatekeeper for
 * Ramp_Custom_Dimension__mdt registrations.
 */
@IsTest
private class RampCustomDimensionServiceTest {

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
}
