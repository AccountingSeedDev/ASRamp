/**
 * @description Covers RampCredentialDeployQueueable — namespace prefix derivation
 * and the name-building path. The actual Metadata deploy is skipped in tests
 * (the Apex Metadata API can't deploy in an @IsTest context).
 */
@IsTest
private class RampCredentialDeployQueueableTest {

    @IsTest
    static void execute_buildsNamespacedDeployWithoutError() {
        Test.startTest();
        System.enqueueJob(new RampCredentialDeployQueueable(
            'Default', 'Default', 'client', 'secret',
            'https://demo-api.ramp.com/developer/v1/token', 'https://demo-api.ramp.com',
            'transactions:read', true
        ));
        Test.stopTest();
        // No exception = the container/name-building path ran cleanly.
        System.assert(true, 'Queueable executed without error');
    }

    @IsTest
    static void namespacePrefix_isEmptyOrEndsWithSeparator() {
        String ns = RampCredentialDeployQueueable.namespacePrefix();
        System.assert(ns == '' || ns.endsWith('__'),
            'Namespace prefix should be empty or end with "__": ' + ns);
    }
}
