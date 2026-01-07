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
import syncAccountingVariables from '@salesforce/apex/RampConfigurationController.syncAccountingVariables';

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

    handleSyncAccountingVariables() {
        this.isLoading = true;
        syncAccountingVariables()
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