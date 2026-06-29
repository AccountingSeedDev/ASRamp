# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ASRamp is a Salesforce DX integration package that connects Accounting Seed (Salesforce accounting software) with the Ramp expense management platform. It provides OAuth 2.0 authentication, GL Account synchronization, and Accounting Variable field mapping.

## Build/Test/Lint Commands

```bash
# Linting & Formatting
npm run lint                    # ESLint for LWC/Aura JavaScript
npm run prettier               # Format all files
npm run prettier:verify        # Check formatting without changes

# LWC Unit Tests (Jest)
npm run test                   # Run all LWC unit tests
npm run test:unit:watch        # Watch mode
npm run test:unit:coverage     # With coverage report

# Salesforce Deployment
sf project deploy start --source-dir force-app/main/default    # Deploy entire package
sf project deploy start --source-dir force-app/main/default/classes/services/RampAuthService.cls  # Deploy single file

# Apex Tests (run in org)
sf apex run test --test-level RunLocalTests --code-coverage    # Run all Apex tests
sf apex run test --class-names RampAuthServiceTest             # Run single test class
```

## Architecture

### Service Layer Pattern
All Ramp API integration follows a service-oriented architecture:

- **RampAuthService** - OAuth 2.0 client credentials flow with Org Cache token storage (48-hour TTL)
- **RampAPIService** - HTTP wrapper handling GET/POST/PATCH/DELETE with automatic token refresh on 401
- **RampAccountingService** - Manages Ramp accounting connection lifecycle
- **RampGLAccountService** - Batch syncs GL Accounts (500 per batch) from Accounting Seed to Ramp
- **RampAccountingFieldService** - Syncs Accounting Seed GL Account Variables 1-4 as Ramp custom fields

### Frontend
Single LWC component `rampConfiguration` with tabbed interface for authorization, connections, sync operations, and statistics.

### Key Salesforce Metadata
- **Ramp_Credential__mdt** - Custom Metadata Type storing OAuth credentials (Client ID, Secret, URLs, Scopes)
- **RampTokens** - Org Cache Partition for access token storage
- **Ramp_Id__c** - Custom field on AcctSeed__GL_Account__c linking to Ramp GL Account IDs

## Testing Patterns

### Apex Tests
- Use `HttpCalloutMock` interface for API mocking
- Custom Metadata (Ramp_Credential__mdt) cannot be inserted in tests; use `TestDataFactory` for mocks
- All service classes have corresponding test classes in `classes/tests/`

### LWC Tests
- Jest with `@salesforce/sfdx-lwc-jest`
- Pre-commit hooks run LWC tests on `lwc/**` changes

## Dependencies

- **Accounting Seed Financial Suite** (1GP) @3.348 - Required managed package
- Salesforce API Version: 65.0

## Credential Configuration

Ramp API credentials are stored in Custom Metadata Type `Ramp_Credential__mdt`. The credential XML files are gitignored (`customMetadata/Ramp_Credential.*.md-meta.xml`) - deploy credentials separately per environment.

---

# Coding Conventions

> These conventions describe how the ASRamp codebase is **actually written today**. The goal of agent-generated
> code is to be indistinguishable from the existing hand-written code in this repo. When in doubt, open a nearby
> file of the same kind (service, batch, controller, test) and follow its pattern — the existing file is the source
> of truth, not these notes.

## Directory Structure

All Salesforce source lives under `force-app/main/default/`:

```
force-app/main/default/
  classes/
    api/           — Global API surface (e.g., RampTransactionAPI)
    batch/         — Batchable / Queueable / Schedulable jobs (RampSyncSchedulable, *Queueable, *Batch)
    controllers/   — @AuraEnabled controllers for LWC (RampConfigurationController, RampHomeController)
    services/      — Core business logic: API wrappers, builders, resolvers, sync services
    utils/         — Small helpers / DTOs (RampTokenResponse)
    tests/         — All @IsTest classes + TestDataFactory
  lwc/             — Lightning Web Components (rampConfiguration, rampHome)
  objects/         — Custom objects/fields, including AcctSeed__* field additions and Ramp_*__mdt CMDTs
  customMetadata/  — Custom Metadata records (Ramp_Credential.*, Ramp_Sync_Settings.*)
  permissionsets/  — Ramp_Admin permission set
  cachePartitions/ — RampTokens Org Cache partition
  remoteSiteSettings/ — Ramp API endpoints
  tabs/            — Custom tabs
```

Paths must be **relative** (e.g., `force-app/main/default/classes/services/RampGLAccountService.cls`). Never use absolute paths. This package has **no triggers** and **no `CustomLabels.labels-meta.xml`** — do not introduce either unless a ticket explicitly requires it.

## Naming & Namespace

- All package Apex classes are prefixed `Ramp` (e.g., `RampBillService`, `RampVendorResolver`).
- The package namespace is `AcctSeedRamp`. In source, this package's own custom fields are unprefixed (e.g., `Ramp_Id__c`, `Ramp_Sync_Status__c`); the namespace is applied at package-build time.
- Fields and objects from the managed dependency use the `AcctSeed__` prefix (e.g., `AcctSeed__GL_Account__c`, `AcctSeed__Account_Payable__c`). Never strip or guess these prefixes — copy them exactly from existing code.

## 1. Access Modifiers

- All new **outer** Apex classes are `public with sharing` (see every class in `classes/services/`).
- Inner DTO/result/exception classes are plain `public class` (e.g., `PageResult`, `BuildResult`, `CurrencyAmount`, `BuildException`).
- Test classes are `@IsTest private class`. `TestDataFactory` is the one exception: `@IsTest public without sharing class` (it must assign permission sets and create data as admin).
- Do NOT use `global` except for the genuinely external API surface in `classes/api/` (e.g., `RampTransactionAPI`), and only when a ticket requires an externally callable method.

## 2. SOQL

This package uses **inline SOQL** with bind variables. There is no `SOQLBuilder` here — do not introduce it.

```apex
List<AcctSeed__GL_Account__c> recs = [
    SELECT Id, Ramp_Id__c
    FROM AcctSeed__GL_Account__c
    WHERE Ramp_Id__c IN :uuids AND AcctSeed__Active__c = true
];
```

- Always use bind variables (`:ids`), never string-concatenate values into a query.
- Select only the fields you need.
- Keep queries out of loops; bulkify by querying with `IN :collection`.

## 3. DML

This package uses **bare DML** (`insert`, `update`, `upsert`, `delete`). There is no `SFDCSecurityUtils` proxy here — do not introduce it.

```apex
update toUpdateRecords;
insert toCreate;
upsert ajr;
```

- Bulkify: operate on lists, never DML inside a loop.
- When a sync/restore path must run regardless of the running user's sharing, follow the existing pattern in the relevant service (several services are `with sharing` and rely on the admin/automation context).

## 4. Error Handling

- **Controllers** (`@AuraEnabled` methods consumed by LWC) throw `AuraHandledException` with a plain, human-readable string literal. This is the established pattern — there are **no `Label.ERR_*` Custom Labels** in this repo.

  ```apex
  throw new AuraHandledException('No accounting connection found. Please establish a connection first.');
  throw new AuraHandledException('Error syncing GL Accounts: ' + e.getMessage());
  ```

- **Services / builders / batch** throw typed custom exceptions defined as inner classes where a caller needs to distinguish failure modes (e.g., `BuildException`, `RampVendorSyncException`). Otherwise let exceptions propagate to the controller, which wraps them in `AuraHandledException`.
- Use `RampJobResultLogger` to record async job outcomes to `AcctSeed__Automated_Job_Results__c` rather than swallowing errors silently.

## 5. Service Layer Architecture

Follow the existing roles when deciding where code belongs:

| Role | Examples | Responsibility |
|------|----------|----------------|
| Auth | `RampAuthService` | OAuth client-credentials token, Org Cache (`RampTokens`, 48h TTL) |
| HTTP | `RampAPIService` | GET/POST/PATCH/DELETE wrapper; refresh token on 401 and retry once |
| Sync services | `RampGLAccountService`, `RampAccountingFieldService`, `RampSyncSettingsService` | Push/pull Accounting Seed ↔ Ramp data |
| Builders | `RampBillBuilder`, `RampJournalEntryBuilder`, `RampReimbursementBuilder` | Construct SObjects from Ramp payloads; return a `BuildResult`, throw `BuildException` |
| Resolvers | `RampVendorResolver`, `RampEmployeeResolver` | Map Ramp entity IDs/emails to Salesforce records |
| Async | `classes/batch/*Queueable`, `*Batch`, `RampSyncSchedulable` | Long-running / scheduled sync (batch size ~500) |
| Controllers | `RampConfigurationController`, `RampHomeController` | Thin `@AuraEnabled` surface for the LWC; delegate to services |

- Controllers should be thin: validate input, delegate to a service, wrap failures in `AuraHandledException`. Do not put integration logic in controllers.
- Services return wrapper/DTO objects (`PageResult`, `BuildResult`, `CurrencyAmount`, etc.) — reuse the existing wrapper for a given service rather than inventing a parallel one.

## 6. LWC

- This repo's LWC components (`rampConfiguration`, `rampHome`) use **inline strings** — there is **no `labels.js` and no `@salesforce/label` imports**. Match the existing component: keep user-facing text inline as the surrounding code does. Do not add a Custom Labels layer.
- A component folder contains `.html`, `.js`, `.js-meta.xml` (and `.css` only if needed, as `rampHome` has). There is no separate modal sub-component pattern — follow whatever the component you are editing already does.
- `@AuraEnabled(cacheable=true)` for read-only data; `@AuraEnabled` (or `cacheable=false`) for mutations.
- Set boolean attributes on lightning base components explicitly (`required="true"`), matching the existing markup.

## 7. Tests — TestDataFactory Pattern

Tests live in `classes/tests/` and follow the `TestDataFactory` singleton pattern (NOT the `TestDataSuite` pattern from the core Accounting Seed package).

```apex
@IsTest
private class RampGLAccountServiceTest {

    // Inject a synthetic credential so callout paths work (no credential is packaged).
    static { RampAuthService.overrideCredential = RampAuthService.buildTestCredential(); }

    @TestSetup
    static void setup() {
        TestDataFactory.getInstance().initialize();
    }

    @IsTest
    static void testSyncAllGLAccounts_Success() {
        User adminUser = TestDataFactory.getInstance().getAdminUser();

        System.runAs(adminUser) {
            Test.setMock(HttpCalloutMock.class, new RampGLAccountMockSuccess());

            Test.startTest();
            String result = RampGLAccountService.syncAllGLAccounts();
            Test.stopTest();

            System.assert(result.contains('GL Account sync complete'), 'Should return success message: ' + result);
        }
    }
}
```

Key rules:

- `@TestSetup` calls `TestDataFactory.getInstance().initialize()` — this delegates to `AcctSeed.TestService.setupTestData(...)` and creates periods, GL accounts, ledgers, settings, billing formats, and a set of Accounts.
- In test methods, get the singleton with `TestDataFactory.getInstance()` and use its accessors: `getAdminUser()`, `getCurrentUser()`, `getAccounts()`, `getGLAccounts()`, `getAccountingPeriods()`, `getLedgers()`, `getBillingFormats()`, `getAccountingSettings()`. Use these **exact** method names.
- Wrap logic in `System.runAs(TestDataFactory.getInstance().getAdminUser())`.
- Use `TestDataFactory.generateFakeId(SObjectType)` when you need a synthetic Id.
- For permission tests use `addAccountingSeedAgentsPermissionSet(user)` / `addAccountingSeedFullAdminPermissionSet(user)`.

### HTTP Callout Mocks

Every test that exercises a Ramp API path must set a mock. Define mocks as **private inner classes** implementing `HttpCalloutMock`, commonly extending a shared `BaseMock` inner class (see `RampBillServiceTest`, `RampReimbursementServiceTest`):

```apex
private abstract class BaseMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(200);
        res.setBody(body(req));
        return res;
    }
    protected abstract String body(HttpRequest req);
}

private class EmptyMock extends BaseMock {
    protected override String body(HttpRequest req) { return '{"data":[]}'; }
}
```

- Set with `Test.setMock(HttpCalloutMock.class, new YourMock());` before `Test.startTest()`.
- Custom Metadata (`Ramp_Credential__mdt`, `Ramp_Sync_Settings__mdt`) **cannot be inserted in tests** — use `RampAuthService.overrideCredential = RampAuthService.buildTestCredential();` (and the equivalent settings override) instead of creating CMDT records.

### Coverage expectations

- New/modified `public`/`global` methods need at least a happy-path test and, where the method validates input or can fail, an error-path test.
- New Apex class → create the matching `*Test.cls` in `classes/tests/`.

## 8. API Version

`sfdx-project.json` `sourceApiVersion` is the source of truth (currently **65.0**). New `-meta.xml` files must match the project API version — do NOT guess a version from training data.

- **In the automated workflow:** read the pre-set `SF_API_VERSION` env var (`echo $SF_API_VERSION`) and use that value in all `-meta.xml` files.
- **When working locally:** use the `sourceApiVersion` from `sfdx-project.json` (65.0), or fetch the latest:
  ```bash
  curl -s https://na1.salesforce.com/services/data/ | python3 -c "import json,sys; v=json.load(sys.stdin); v.sort(key=lambda x:float(x['version'])); print(v[-1]['version'])"
  ```

---

## Special File Handling

### Custom Metadata records (`customMetadata/*.md-meta.xml`)

- `Ramp_Credential.*.md-meta.xml` is **gitignored** — never commit credentials. Deploy them separately per environment.
- When adding a CMDT field/record type, update the corresponding object under `objects/Ramp_Credential__mdt/` or `objects/Ramp_Sync_Settings__mdt/`.

### Permission set (`permissionsets/Ramp_Admin.permissionset-meta.xml`)

When you add a new Apex class, object, field, tab, or LWC-backed page, grant access in `Ramp_Admin`:

- Read the file first to match its existing structure.
- Add entries in the correct section: `classAccesses`, `objectPermissions`, `fieldPermissions`, `tabSettings`, `userPermissions`, `applicationVisibilities`.

### `sfdx-project.json`

Don't bump `versionNumber`/`versionName` or edit `packageAliases` as part of a feature change unless the ticket is specifically about packaging.