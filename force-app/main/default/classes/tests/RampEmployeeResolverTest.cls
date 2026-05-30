/**
 * @description Tests for RampEmployeeResolver — Ramp user_email → Salesforce User.
 */
@IsTest
private class RampEmployeeResolverTest {

    @IsTest
    static void matchesActiveUserByEmail() {
        User u = [SELECT Id, Email FROM User WHERE Id = :UserInfo.getUserId()];
        Test.startTest();
        Map<String, Id> r = RampEmployeeResolver.resolveByEmail(new Map<String, String>{ 'ramp-user-1' => u.Email });
        Test.stopTest();
        System.assertEquals(u.Id, r.get('ramp-user-1'), 'should match the active user by email');
    }

    @IsTest
    static void unmatchedEmailReturnsNothing() {
        Map<String, Id> r = RampEmployeeResolver.resolveByEmail(new Map<String, String>{ 'ramp-user-2' => 'no-such-user-9f8a@nonexistent.example' });
        System.assertEquals(0, r.size());
    }
}
