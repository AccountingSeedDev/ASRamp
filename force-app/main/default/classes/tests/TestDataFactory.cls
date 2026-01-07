@IsTest
public without sharing class TestDataFactory {

    private List<AcctSeed__Accounting_Period__c> accountingPeriods;
    private List<AcctSeed__GL_Account__c> glAccounts;
    private List<AcctSeed__Billing_Format__c> billingFormats;
    private List<AcctSeed__Ledger__c> ledgers;
    private List<AcctSeed__Accounting_Settings__c> accountingSettings;
    private List<Account> accounts;

    private User adminUser;
    private User currentUser;

    private static TestDataFactory instance;

    private TestDataFactory() {}

    public static TestDataFactory getInstance() {
        if (instance == null) {
            instance = new TestDataFactory();
        }
        return instance;
    }

    public TestDataFactory initialize() {
        AcctSeed.ServiceResult result = AcctSeed.TestService.setupTestData(true, false, false);
        if (result.isSuccess) {
            Map<String, List<SObject>> testData = (Map<String, List<SObject>>) JSON.deserializeStrict(result.data, Map<String, List<SObject>>.class);
            // Get Accounting Periods
            this.accountingPeriods = (List<AcctSeed__Accounting_Period__c>) testData.get('accountingPeriods');
            // Get GL Accounts
            this.glAccounts = (List<AcctSeed__GL_Account__c>) testData.get('glAccounts');
            // Get Billing Formats (PDF Formats)
            this.billingFormats = (List<AcctSeed__Billing_Format__c>) testData.get('billingFormats');
            // Get Ledgers
            this.ledgers = (List<AcctSeed__Ledger__c>) testData.get('ledgers');
            // Get Accounting Settings
            this.accountingSettings = (List<AcctSeed__Accounting_Settings__c>) testData.get('accountingSettings');
            // Create Accounts
            this.createAccounts();
        }
        return this;
    }

    public TestDataFactory disableAutoPost() {
        AcctSeed.TestService.disableAutoPostSourceDocuments();
        return this;
    }

    public TestDataFactory enableAutoPost() {
        AcctSeed.TestService.enableAutoPostSourceDocuments();
        return this;
    }

    public List<AcctSeed__Accounting_Period__c> getAccountingPeriods() {
        if (this.accountingPeriods == null) {
            System.runAs(this.getAdminUser()) {
                this.accountingPeriods = [SELECT Id, Name, AcctSeed__Start_Date__c, AcctSeed__End_Date__c FROM AcctSeed__Accounting_Period__c];
            }
        }
        return this.accountingPeriods;
    }

    public List<AcctSeed__GL_Account__c> getGLAccounts() {
        if (this.glAccounts == null) {
            System.runAs(this.getAdminUser()) {
                this.glAccounts = [SELECT Id, Name FROM AcctSeed__GL_Account__c];
            }
        }
        return this.glAccounts;
    }

    public List<AcctSeed__Billing_Format__c> getBillingFormats() {
        if (this.billingFormats == null) {
            System.runAs(this.getAdminUser()) {
                this.billingFormats = [SELECT Id, Name FROM AcctSeed__Billing_Format__c];
            }
        }
        return this.billingFormats;
    }

    public List<AcctSeed__Ledger__c> getLedgers() {
        if (this.ledgers == null) {
            System.runAs(this.getAdminUser()) {
                this.ledgers = [SELECT Id, Name, AcctSeed__Default_Bank_Account__c FROM AcctSeed__Ledger__c];
            }
        }
        return this.ledgers;
    }

    public List<AcctSeed__Accounting_Settings__c> getAccountingSettings() {
        if (this.accountingSettings == null) {
            System.runAs(this.getAdminUser()) {
                this.accountingSettings = [SELECT Id, Name FROM AcctSeed__Accounting_Settings__c];
            }
        }
        return this.accountingSettings;
    }

    public User getAdminUser() {
        if (this.adminUser == null) {
            this.adminUser = [SELECT Id, Name FROM User WHERE LastName = 'AcctSeedSysAdmin' LIMIT 1];
        }
        return this.adminUser;
    }

    public User getCurrentUser() {
        if (this.currentUser == null) {
            this.currentUser = [SELECT Id, Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        }
        return this.currentUser;
    }

    public void addAccountingSeedAgentsPermissionSet(User user) {
        System.runAs(getAdminUser()) {
            PermissionSet permissionSet = [
                    SELECT Id, Name
                    FROM PermissionSet
                    WHERE Name IN ('Accounting_Seed_Agents')
                    LIMIT 1
            ];

            PermissionSetAssignment permissionSetAssignment = new PermissionSetAssignment(
                    AssigneeId = user.Id,
                    PermissionSetId = permissionSet.Id
            );

            //prevent duplicates
            List<PermissionSetAssignment> existingPermissionSetAssignments = [
                    SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = :user.Id AND PermissionSetId = :permissionSet.Id
            ];

            if (existingPermissionSetAssignments.isEmpty()) {
                insert permissionSetAssignment;
            }
        }
    }

    public void addAccountingSeedFullAdminPermissionSet(User user) {
        System.runAs(getAdminUser()) {
            PermissionSet permissionSet = [
                    SELECT Id, Name
                    FROM PermissionSet
                    WHERE Name IN ('AS_Full_Admin')
                    LIMIT 1
            ];

            PermissionSetAssignment permissionSetAssignment = new PermissionSetAssignment(
                    AssigneeId = user.Id,
                    PermissionSetId = permissionSet.Id
            );

            //prevent duplicates
            List<PermissionSetAssignment> existingPermissionSetAssignments = [
                    SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = :user.Id AND PermissionSetId = :permissionSet.Id
            ];

            if (existingPermissionSetAssignments.isEmpty()) {
                insert permissionSetAssignment;
            }
        }
    }

    public TestDataFactory createAccounts() {
        if (this.accounts != null) {
            return this;
        }

        System.runAs(this.getAdminUser()) {
            this.accounts = new List<Account>{
                    new Account(
                            Name = 'Advanced Automation',
                            AcctSeed__Accounting_Active__c = true,
                            AcctSeed__Accounting_Type__c = 'Customer and Vendor'
                    ),
                    new Account(
                            Name = 'Elite Freight',
                            AcctSeed__Accounting_Active__c = true,
                            AcctSeed__Accounting_Type__c = 'Customer and Vendor'
                    ),
                    new Account(
                            Name = 'Global Logistics',
                            AcctSeed__Accounting_Active__c = true,
                            AcctSeed__Accounting_Type__c = 'Customer and Vendor'
                    ),
                    new Account(
                            Name = 'Western Realty Group',
                            AcctSeed__Accounting_Active__c = true,
                            AcctSeed__Accounting_Type__c = 'Customer and Vendor'
                    )
            };
            insert this.accounts;
        }

        return this;
    }

    public List<Account> getAccounts() {
        if (this.accounts == null) {
            System.runAs(this.getAdminUser()) {
                this.accounts = [SELECT Id, Name FROM Account WHERE AcctSeed__Accounting_Active__c = TRUE];
            }
        }
        return this.accounts ?? new List<Account>();
    }

    public static String generateFakeId(Schema.SObjectType sot) {
        String result = String.valueOf(Math.round(Math.random() * 99999999));
        return sot.getDescribe().getKeyPrefix() + '0'.repeat(12 - result.length()) + result;
    }

}