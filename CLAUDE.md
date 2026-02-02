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