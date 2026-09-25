/**
 * @description Tests for RampDeterministicIdUtil — the shared deterministic id generator
 * extracted from RampAccountingFieldService.generateDeterministicUUID.
 */
@IsTest
private class RampDeterministicIdUtilTest {

    @IsTest
    static void generateUUID_sameSeed_isDeterministic() {
        String first = RampDeterministicIdUtil.generateUUID('ASRamp:GL Account Variable 1');
        String second = RampDeterministicIdUtil.generateUUID('ASRamp:GL Account Variable 1');

        System.assertEquals(first, second, 'The same seed must always produce the same id');
    }

    @IsTest
    static void generateUUID_differentPrefixes_produceDifferentIdsForTheSameName() {
        String forAccountingField = RampDeterministicIdUtil.generateUUID('ASRamp:GL Account Variable 1');
        String forCustomDimension = RampDeterministicIdUtil.generateUUID('ASRampDim:GL Account Variable 1');

        System.assertNotEquals(
            forAccountingField, forCustomDimension,
            'Different call-site prefixes must not collide on the same underlying name'
        );
    }

    @IsTest
    static void generateUUID_matchesV5Format() {
        String id = RampDeterministicIdUtil.generateUUID('ASRampDim:AcctSeed__GL_Account__c');

        System.assert(
            Pattern.matches('^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$', id),
            'Id should be a UUID v5-style string with version nibble 5 and variant nibble a: ' + id
        );
    }
}
