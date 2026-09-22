/**
 * @description Validates Ramp_Custom_Dimension__mdt registrations. This is the gatekeeper in
 * front of every outbound and inbound behavior in the custom dimension epic — later stories
 * (field creation, option sync, inbound write-back) all read from records validated here.
 *
 * validate() never throws. Every problem found is returned as a human-readable string so it
 * can be rendered directly in the configuration UI rather than caught.
 */
public with sharing class RampCustomDimensionService {

    @TestVisible
    private static final String NAMESPACE = 'AcctSeedRamp';

    @TestVisible
    private static final Integer MIN_OPTION_ID_LENGTH = 36;

    @TestVisible
    private static final String RESERVED_LABEL_PREFIX = 'gl account variable';

    /**
     * @description Validates a single Ramp_Custom_Dimension__mdt registration against the
     * running user's schema access.
     * @param registration The registration to validate
     * @return List<String> Human-readable problems. Empty when the registration is valid.
     */
    public static List<String> validate(Ramp_Custom_Dimension__mdt registration) {
        List<String> problems = new List<String>();

        try {
            if (registration == null) {
                problems.add('No registration was provided.');
                return problems;
            }

            if (String.isNotBlank(registration.Ramp_Field_Label__c)
                    && registration.Ramp_Field_Label__c.toLowerCase().startsWith(RESERVED_LABEL_PREFIX)) {
                problems.add('Ramp_Field_Label__c "' + registration.Ramp_Field_Label__c + '" cannot start with '
                    + '"GL Account Variable" — that prefix is reserved for the packaged GL Account Variable '
                    + '1-4 fields and would break card transaction sync.');
            }

            Schema.DescribeSObjectResult objDescribe = resolveObject(registration.Object_API_Name__c, problems,
                'Object_API_Name__c');
            if (objDescribe == null) {
                return problems;
            }
            if (!objDescribe.isQueryable() || !objDescribe.isUpdateable()) {
                problems.add('Object_API_Name__c "' + registration.Object_API_Name__c + '" must be queryable '
                    + 'and updateable for the running user.');
            }

            Map<String, Schema.SObjectField> fieldsByName = objDescribe.fields.getMap();

            validateLabelField(registration, fieldsByName, problems);
            validateActiveField(registration, fieldsByName, problems);
            validateOptionIdField(registration, fieldsByName, problems);

            Schema.SObjectType registeredType = objDescribe.getSObjectType();
            validateLineField(registration.JE_Line_Field_API_Name__c, 'JE_Line_Field_API_Name__c',
                'AcctSeed__Journal_Entry_Line__c', registeredType, problems);
            validateLineField(registration.Payable_Line_Field_API_Name__c, 'Payable_Line_Field_API_Name__c',
                'AcctSeed__Account_Payable_Line__c', registeredType, problems);
        } catch (Exception e) {
            problems.add('Unexpected error validating registration: ' + e.getMessage());
        }

        return problems;
    }

    private static void validateLabelField(Ramp_Custom_Dimension__mdt registration,
            Map<String, Schema.SObjectField> fieldsByName, List<String> problems) {
        String raw = String.isBlank(registration.Label_Field_API_Name__c)
            ? 'Name' : registration.Label_Field_API_Name__c;
        Schema.DescribeFieldResult field = resolveField(fieldsByName, raw);
        if (field == null) {
            problems.add('Label_Field_API_Name__c "' + raw + '" does not exist on '
                + registration.Object_API_Name__c + '.');
            return;
        }
        if (!field.isAccessible()) {
            problems.add('Label_Field_API_Name__c "' + raw + '" is not accessible to the running user.');
        }
        if (!rendersAsText(field.getType())) {
            problems.add('Label_Field_API_Name__c "' + raw + '" must be a type that renders sensibly as text.');
        }
    }

    private static void validateActiveField(Ramp_Custom_Dimension__mdt registration,
            Map<String, Schema.SObjectField> fieldsByName, List<String> problems) {
        if (String.isBlank(registration.Active_Field_API_Name__c)) {
            return;
        }
        Schema.DescribeFieldResult field = resolveField(fieldsByName, registration.Active_Field_API_Name__c);
        if (field == null) {
            problems.add('Active_Field_API_Name__c "' + registration.Active_Field_API_Name__c + '" does not '
                + 'exist on ' + registration.Object_API_Name__c + '.');
            return;
        }
        if (field.getType() != Schema.DisplayType.BOOLEAN) {
            problems.add('Active_Field_API_Name__c "' + registration.Active_Field_API_Name__c
                + '" must be a Checkbox field.');
        }
    }

    private static void validateOptionIdField(Ramp_Custom_Dimension__mdt registration,
            Map<String, Schema.SObjectField> fieldsByName, List<String> problems) {
        if (String.isBlank(registration.Ramp_Option_Id_Field_API_Name__c)) {
            problems.add('Ramp_Option_Id_Field_API_Name__c is required.');
            return;
        }
        Schema.DescribeFieldResult field = resolveField(fieldsByName, registration.Ramp_Option_Id_Field_API_Name__c);
        if (field == null) {
            problems.add('Ramp_Option_Id_Field_API_Name__c "' + registration.Ramp_Option_Id_Field_API_Name__c
                + '" does not exist on ' + registration.Object_API_Name__c + '.');
            return;
        }
        if (field.getType() != Schema.DisplayType.STRING) {
            problems.add('Ramp_Option_Id_Field_API_Name__c "' + registration.Ramp_Option_Id_Field_API_Name__c
                + '" must be a Text field.');
        }
        if (!field.isUpdateable()) {
            problems.add('Ramp_Option_Id_Field_API_Name__c "' + registration.Ramp_Option_Id_Field_API_Name__c
                + '" must be updateable for the running user.');
        }
        if (field.getLength() < MIN_OPTION_ID_LENGTH) {
            problems.add('Ramp_Option_Id_Field_API_Name__c "' + registration.Ramp_Option_Id_Field_API_Name__c
                + '" must be at least ' + MIN_OPTION_ID_LENGTH + ' characters long to hold a Ramp option id.');
        }
    }

    private static void validateLineField(String rawFieldName, String fieldLabel, String lineObjectApiName,
            Schema.SObjectType registeredType, List<String> problems) {
        if (String.isBlank(rawFieldName)) {
            return;
        }

        Schema.SObjectType lineType = resolveObjectType(lineObjectApiName);
        if (lineType == null) {
            problems.add(fieldLabel + ': could not resolve line object "' + lineObjectApiName
                + '" to validate against.');
            return;
        }

        Map<String, Schema.SObjectField> lineFields = lineType.getDescribe().fields.getMap();
        Schema.DescribeFieldResult field = resolveField(lineFields, rawFieldName);
        if (field == null) {
            problems.add(fieldLabel + ' "' + rawFieldName + '" does not exist on ' + lineObjectApiName + '.');
            return;
        }
        if (!field.isUpdateable()) {
            problems.add(fieldLabel + ' "' + rawFieldName + '" must be updateable for the running user.');
        }

        if (field.getType() == Schema.DisplayType.REFERENCE) {
            Boolean referencesRegisteredObject = false;
            if (registeredType != null) {
                for (Schema.SObjectType refType : field.getReferenceTo()) {
                    if (refType == registeredType) {
                        referencesRegisteredObject = true;
                        break;
                    }
                }
            }
            if (!referencesRegisteredObject) {
                problems.add(fieldLabel + ' "' + rawFieldName + '" is a lookup but does not reference the '
                    + 'registered Object_API_Name__c.');
            }
        } else if (!rendersAsText(field.getType())) {
            problems.add(fieldLabel + ' "' + rawFieldName + '" is type ' + field.getType()
                + ', which is not a supported type for inbound coding.');
        }
    }

    /**
     * @description A field type is "supported" for label display / inbound coding when it has
     * a single displayable value. Excludes compound/binary types that have no sensible text
     * representation.
     */
    private static Boolean rendersAsText(Schema.DisplayType type) {
        return type != Schema.DisplayType.ADDRESS && type != Schema.DisplayType.BASE64;
    }

    private static Schema.DescribeSObjectResult resolveObject(String rawName, List<String> problems,
            String fieldLabel) {
        if (String.isBlank(rawName)) {
            problems.add(fieldLabel + ' is required.');
            return null;
        }
        Schema.SObjectType type = resolveObjectType(rawName);
        if (type == null) {
            problems.add(fieldLabel + ' "' + rawName + '" does not resolve to a known object.');
            return null;
        }
        return type.getDescribe();
    }

    private static Map<String, Schema.SObjectType> globalDescribeByLowerName;

    private static Schema.SObjectType resolveObjectType(String rawName) {
        if (String.isBlank(rawName)) {
            return null;
        }
        if (globalDescribeByLowerName == null) {
            globalDescribeByLowerName = new Map<String, Schema.SObjectType>();
            for (String key : Schema.getGlobalDescribe().keySet()) {
                globalDescribeByLowerName.put(key.toLowerCase(), Schema.getGlobalDescribe().get(key));
            }
        }
        for (String candidate : candidateApiNames(rawName)) {
            Schema.SObjectType type = globalDescribeByLowerName.get(candidate.toLowerCase());
            if (type != null) {
                return type;
            }
        }
        return null;
    }

    private static Schema.DescribeFieldResult resolveField(Map<String, Schema.SObjectField> fieldsByName,
            String rawName) {
        if (String.isBlank(rawName)) {
            return null;
        }
        for (String candidate : candidateApiNames(rawName)) {
            Schema.SObjectField field = fieldsByName.get(candidate.toLowerCase());
            if (field != null) {
                return field.getDescribe();
            }
        }
        return null;
    }

    /**
     * @description Namespace-tolerant candidates for an object/field API name: the literal
     * value as typed, the AcctSeedRamp__-prefixed form, and the unprefixed form — so a
     * registration works whether it was authored in an unpackaged dev org, a subscriber org
     * post-install, or with the namespace already spelled out.
     */
    private static List<String> candidateApiNames(String rawName) {
        List<String> candidates = new List<String>{ rawName };

        String prefixed = NAMESPACE + '__' + rawName;
        if (!candidates.contains(prefixed)) {
            candidates.add(prefixed);
        }

        String prefix = NAMESPACE + '__';
        String unprefixed = rawName.startsWith(prefix) ? rawName.substring(prefix.length()) : rawName;
        if (!candidates.contains(unprefixed)) {
            candidates.add(unprefixed);
        }

        return candidates;
    }
}
