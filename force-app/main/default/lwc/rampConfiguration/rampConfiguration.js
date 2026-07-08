import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getActiveCredential from '@salesforce/apex/RampConfigurationController.getActiveCredential';
import testConnection from '@salesforce/apex/RampConfigurationController.testConnection';
import clearTokenCache from '@salesforce/apex/RampConfigurationController.clearTokenCache';
import saveCredential from '@salesforce/apex/RampConfigurationController.saveCredential';
import establishAccountingConnection from '@salesforce/apex/RampConfigurationController.establishAccountingConnection';
import hasAccountingConnection from '@salesforce/apex/RampConfigurationController.hasAccountingConnection';
import createAccountingFields from '@salesforce/apex/RampConfigurationController.createAccountingFields';
import syncAccountingVariables from '@salesforce/apex/RampConfigurationController.syncAccountingVariables';
import getRampCustomFields from '@salesforce/apex/RampConfigurationController.getRampCustomFields';
import updateRampCustomField from '@salesforce/apex/RampConfigurationController.updateRampCustomField';
import deleteRampCustomField from '@salesforce/apex/RampConfigurationController.deleteRampCustomField';
import syncTransactions from '@salesforce/apex/RampConfigurationController.syncTransactions';
import getTransactionSyncStats from '@salesforce/apex/RampConfigurationController.getTransactionSyncStats';
import getRecentTransactionFailures from '@salesforce/apex/RampConfigurationController.getRecentTransactionFailures';
import getReferenceLookupConfig from '@salesforce/apex/RampConfigurationController.getReferenceLookupConfig';
import saveReferenceLookupConfig from '@salesforce/apex/RampConfigurationController.saveReferenceLookupConfig';

export default class RampConfiguration extends LightningElement {
    // Optional deep-link target tab (set by a host such as rampHome). Defaults
    // to Authorization so the standalone tab behaves exactly as before.
    @api activeTab = 'authorization';
    @track developerName = 'Default';
    @track label = 'Default';
    @track clientId = '';
    @track clientSecret = '';
    @track tokenUrl = 'https://api.ramp.com/developer/v1/token';
    @track apiBaseUrl = 'https://api.ramp.com';
    @track scopes = 'transactions:read accounting:write';
    @track isActive = true;
    @track isLoading = false;
    @track hasExistingCredential = false;
    @track accountingConnectionStatus = false;
    @track customFields = [];
    @track customFieldsLoading = false;
    @track draftValues = [];
    @track transactionStats = { total: 0, synced: 0, pending: 0, failed: 0 };
    @track transactionStatsLoading = false;
    @track transactionFailures = [];
    @track referenceLookupEnabled = false;
    @track referenceKeyTemplate = '';

    transactionFailureColumns = [
        { label: 'Ramp Txn Id', fieldName: 'rampTransactionId', type: 'text', initialWidth: 280 },
        { label: 'JE Name', fieldName: 'name', type: 'text' },
        { label: 'Date', fieldName: 'date', type: 'date-local' },
        { label: 'Error', fieldName: 'error', type: 'text', wrapText: true }
    ];

    customFieldColumns = [
        { label: 'Ramp ID', fieldName: 'ramp_id', type: 'text', initialWidth: 320 },
        { label: 'Name', fieldName: 'name', type: 'text', editable: true },
        { label: 'Display Name', fieldName: 'display_name', type: 'text', editable: true },
        { label: 'Input Type', fieldName: 'inputTypeLabel', type: 'text' },
        { label: 'Created', fieldName: 'createdAtFormatted', type: 'text' },
        {
            type: 'action',
            typeAttributes: {
                rowActions: [
                    { label: 'Delete', name: 'delete', iconName: 'utility:delete' }
                ]
            }
        }
    ];

    // Wire to get existing credential
    @wire(getActiveCredential)
    wiredCredential({ error, data }) {
        if (data) {
            this.developerName = data.developerName || 'Default';
            this.label = data.label || 'Default';
            this.clientId = data.clientId || '';
            this.clientSecret = data.clientSecret || '';
            this.tokenUrl = data.tokenUrl || 'https://api.ramp.com/developer/v1/token';
            this.apiBaseUrl = data.apiBaseUrl || 'https://api.ramp.com';
            this.scopes = data.scopes || '';
            this.isActive = data.isActive !== undefined ? data.isActive : true;
            this.hasExistingCredential = true;

            // Check accounting connection status
            this.checkAccountingConnection();
        } else if (error) {
            console.error('Error loading credential:', error);
        }
    }

    checkAccountingConnection() {
        hasAccountingConnection()
            .then(result => {
                this.accountingConnectionStatus = result;
                // Load custom fields if connected
                if (result) {
                    this.loadCustomFields();
                }
            })
            .catch(error => {
                console.error('Error checking accounting connection:', error);
                this.accountingConnectionStatus = false;
            });
    }

    get hasTransactionFailures() {
        return this.transactionFailures && this.transactionFailures.length > 0;
    }

    loadTransactionStats() {
        this.transactionStatsLoading = true;
        Promise.all([getTransactionSyncStats(), getRecentTransactionFailures()])
            .then(([stats, failures]) => {
                this.transactionStats = stats || { total: 0, synced: 0, pending: 0, failed: 0 };
                this.transactionFailures = failures || [];
            })
            .catch(error => {
                console.error('Error loading transaction stats:', error);
            })
            .finally(() => {
                this.transactionStatsLoading = false;
            });
    }

    handleSyncTransactions() {
        this.isLoading = true;
        syncTransactions()
            .then(result => {
                this.showToast('Success', result, 'success');
                // Stats won't reflect the new run immediately (Queueable runs
                // async); user can hit Refresh after a minute.
                this.loadTransactionStats();
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleRefreshTransactionStats() {
        this.loadTransactionStats();
    }

    handleInputChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this[field] = value;
    }

    handleTestConnection() {
        this.isLoading = true;
        testConnection()
            .then(result => {
                this.showToast('Success', result, 'success');
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get referenceTemplatePlaceholder() {
        return '{merchant_name}-{memo}';
    }

    // Commonly-useful Ramp transaction attributes for the Reference key template.
    // Any other top-level or nested transaction API field also works; these are
    // the ones most useful as lookup keys. (card_holder has no email field —
    // cardholder email is resolved separately and isn't template-addressable.)
    get supportedReferenceTokens() {
        return [
            { token: '{merchant_name}', desc: 'Ramp-normalized merchant name (e.g. Chipotle)' },
            { token: '{merchant_descriptor}', desc: 'Raw card-network statement descriptor' },
            { token: '{merchant_category_code}', desc: 'MCC code' },
            { token: '{merchant_category_code_description}', desc: 'MCC description' },
            { token: '{sk_category_name}', desc: 'Ramp spend category name' },
            { token: '{memo}', desc: 'Transaction memo' },
            { token: '{currency_code}', desc: 'ISO currency code' },
            { token: '{state}', desc: 'Transaction state (e.g. CLEARED)' },
            { token: '{card_holder.first_name}', desc: 'Cardholder first name' },
            { token: '{card_holder.last_name}', desc: 'Cardholder last name' },
            { token: '{card_holder.department_name}', desc: 'Cardholder department' },
            { token: '{card_holder.location_name}', desc: 'Cardholder location' },
            { token: '{card_holder.employee_id}', desc: 'Cardholder employee id' }
        ];
    }

    connectedCallback() {
        this.loadReferenceLookupConfig();
    }

    loadReferenceLookupConfig() {
        getReferenceLookupConfig()
            .then(data => {
                this.referenceLookupEnabled = data.enabled === true;
                this.referenceKeyTemplate = data.template || '';
            })
            .catch(error => {
                console.error('Error loading reference lookup config:', error);
            });
    }

    handleReferenceEnabledChange(event) {
        this.referenceLookupEnabled = event.target.checked;
    }

    handleReferenceTemplateChange(event) {
        this.referenceKeyTemplate = event.target.value;
    }

    handleSaveReferenceLookup() {
        this.isLoading = true;
        saveReferenceLookupConfig({ enabled: this.referenceLookupEnabled, template: this.referenceKeyTemplate })
            .then((result) => {
                this.showToast('Success', result, 'success');
            })
            .catch((error) => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleClearCache() {
        this.isLoading = true;
        clearTokenCache()
            .then(result => {
                this.showToast('Success', result, 'success');
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleEstablishAccountingConnection() {
        this.isLoading = true;
        establishAccountingConnection()
            .then(result => {
                this.showToast('Success', result, 'success');
                this.accountingConnectionStatus = true;
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleCreateAccountingFields() {
        this.isLoading = true;
        createAccountingFields()
            .then(result => {
                this.showToast('Success', result, 'success');
                // Refresh custom fields list after creation
                this.loadCustomFields();
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleSyncAccountingVariables() {
        this.isLoading = true;
        syncAccountingVariables()
            .then(result => {
                this.showToast('Info', result, 'info');
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadCustomFields() {
        this.customFieldsLoading = true;
        getRampCustomFields()
            .then(result => {
                this.customFields = result.map(field => ({
                    ...field,
                    inputTypeLabel: this.formatInputType(field.input_type),
                    createdAtFormatted: field.created_at ? new Date(field.created_at).toLocaleDateString() : '',
                    isEditing: false
                }));
            })
            .catch(error => {
                console.error('Error loading custom fields:', error);
                this.customFields = [];
            })
            .finally(() => {
                this.customFieldsLoading = false;
            });
    }

    formatInputType(inputType) {
        const typeMap = {
            'SINGLE_CHOICE': 'Single Choice',
            'FREE_FORM_TEXT': 'Free Form Text',
            'BOOLEAN': 'Boolean',
            'DATE': 'Date'
        };
        return typeMap[inputType] || inputType;
    }

    handleRefreshCustomFields() {
        this.loadCustomFields();
    }

    handleInlineSave(event) {
        const draftValues = event.detail.draftValues;

        // Process each changed row - use ramp_id for the API call
        const promises = draftValues.map(draft => {
            return updateRampCustomField({
                fieldId: draft.ramp_id,
                name: draft.name || null,
                displayName: draft.display_name || null
            });
        });

        this.isLoading = true;
        Promise.all(promises)
            .then(() => {
                this.showToast('Success', 'Custom field(s) updated successfully', 'success');
                this.draftValues = [];
                this.loadCustomFields();
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;

        if (action.name === 'delete') {
            this.handleDeleteField(row.ramp_id, row.name);
        }
    }

    handleDeleteField(rampId, fieldName) {
        if (!confirm(`Are you sure you want to delete the custom field "${fieldName}"? This cannot be undone.`)) {
            return;
        }

        this.isLoading = true;
        deleteRampCustomField({ rampId })
            .then(result => {
                this.showToast('Success', result, 'success');
                this.loadCustomFields();
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get hasCustomFields() {
        return this.customFields && this.customFields.length > 0;
    }

    handleSave() {
        // Validate required fields
        if (!this.clientId || !this.clientSecret || !this.scopes) {
            this.showToast('Validation Error', 'Client ID, Client Secret, and Scopes are required', 'error');
            return;
        }

        this.isLoading = true;

        const credential = {
            developerName: this.developerName,
            label: this.label,
            clientId: this.clientId,
            clientSecret: this.clientSecret,
            tokenUrl: this.tokenUrl,
            apiBaseUrl: this.apiBaseUrl,
            scopes: this.scopes,
            isActive: this.isActive
        };

        saveCredential({ credential })
            .then(result => {
                this.showToast('Success', result, 'success');
                this.hasExistingCredential = true;
            })
            .catch(error => {
                this.showToast('Error', this.getErrorMessage(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant, mode = 'dismissable') {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
            mode: mode
        });
        this.dispatchEvent(event);
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        }
        return 'An unknown error occurred';
    }

    get isTestDisabled() {
        return this.isLoading || !this.hasExistingCredential;
    }

    get isSaveDisabled() {
        return this.isLoading || !this.clientId || !this.clientSecret || !this.scopes;
    }

    get accountingConnectionIcon() {
        return this.accountingConnectionStatus ? 'utility:success' : 'utility:warning';
    }

    get accountingConnectionMessage() {
        return this.accountingConnectionStatus
            ? 'Connected to Accounting Seed'
            : 'Not connected - Click "Establish Accounting Connection" after testing credentials';
    }

}