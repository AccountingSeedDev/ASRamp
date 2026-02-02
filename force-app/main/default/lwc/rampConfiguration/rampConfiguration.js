import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getActiveCredential from '@salesforce/apex/RampConfigurationController.getActiveCredential';
import testConnection from '@salesforce/apex/RampConfigurationController.testConnection';
import clearTokenCache from '@salesforce/apex/RampConfigurationController.clearTokenCache';
import saveCredential from '@salesforce/apex/RampConfigurationController.saveCredential';
import establishAccountingConnection from '@salesforce/apex/RampConfigurationController.establishAccountingConnection';
import hasAccountingConnection from '@salesforce/apex/RampConfigurationController.hasAccountingConnection';
import syncGLAccounts from '@salesforce/apex/RampConfigurationController.syncGLAccounts';
import getGLAccountStats from '@salesforce/apex/RampConfigurationController.getGLAccountStats';
import createAccountingFields from '@salesforce/apex/RampConfigurationController.createAccountingFields';
import syncAccountingVariables from '@salesforce/apex/RampConfigurationController.syncAccountingVariables';
import getRampCustomFields from '@salesforce/apex/RampConfigurationController.getRampCustomFields';
import updateRampCustomField from '@salesforce/apex/RampConfigurationController.updateRampCustomField';
import deleteRampCustomField from '@salesforce/apex/RampConfigurationController.deleteRampCustomField';

export default class RampConfiguration extends LightningElement {
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
    @track glAccountStats = { total: 0, synced: 0, not_synced: 0 };
    @track customFields = [];
    @track customFieldsLoading = false;
    @track draftValues = [];

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
            // Load GL Account stats
            this.loadGLAccountStats();
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

    loadGLAccountStats() {
        getGLAccountStats()
            .then(result => {
                this.glAccountStats = result;
            })
            .catch(error => {
                console.error('Error loading GL Account stats:', error);
            });
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

    handleSyncGLAccounts() {
        this.isLoading = true;
        syncGLAccounts()
            .then(result => {
                this.showToast('Success', result, 'success');
                // Refresh stats after sync
                this.loadGLAccountStats();
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
                this.showToast('Instructions', result, 'info', 'sticky');
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

    get glAccountSyncMessage() {
        const total = this.glAccountStats.total || 0;
        const synced = this.glAccountStats.synced || 0;
        const notSynced = this.glAccountStats.not_synced || 0;

        return `${synced} of ${total} GL Accounts synced to Ramp (${notSynced} pending)`;
    }

    get hasPendingGLAccounts() {
        return (this.glAccountStats.not_synced || 0) > 0;
    }
}