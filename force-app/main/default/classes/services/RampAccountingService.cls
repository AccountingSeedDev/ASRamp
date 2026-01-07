/**
 * @description Service class for Ramp Accounting integrations
 */
public with sharing class RampAccountingService {

    /**
     * @description Creates or updates an accounting connection with Ramp
     * @param remoteProviderName The accounting provider name (e.g., 'ACCOUNTING_SEED')
     * @return String The connection ID or status message
     */
    public static String createAccountingConnection(String remoteProviderName) {
        try {
            // Build request body for accounting connection
            Map<String, Object> requestBody = new Map<String, Object>{
                'remote_provider_name' => remoteProviderName
            };

            String body = JSON.serialize(requestBody);

            // Make POST request to create accounting connection
            HttpResponse res = RampAPIService.post('/developer/v1/accounting/connection', body);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String connectionId = (String) response.get('id');

                // Sync custom accounting fields (GL Account Variables 1-4)
                String fieldSyncResult = RampAccountingFieldService.syncAccountingVariablesToRamp();

                return 'Accounting connection established successfully. Connection ID: ' +
                       connectionId + '\n\nCustom Fields:\n' + fieldSyncResult;
            } else {
                throw new RampAccountingException(
                    'Failed to create accounting connection. Status: ' + res.getStatusCode() +
                    ', Response: ' + res.getBody()
                );
            }
        } catch (Exception e) {
            throw new RampAccountingException('Error creating accounting connection: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Retrieves the current accounting connection
     * @return Map<String, Object> The connection details
     */
    public static Map<String, Object> getAccountingConnection() {
        try {
            HttpResponse res = RampAPIService.get('/developer/v1/accounting/connection');

            if (res.getStatusCode() == 200) {
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return response;
            } else {
                throw new RampAccountingException(
                    'Failed to retrieve accounting connection. Status: ' + res.getStatusCode()
                );
            }
        } catch (Exception e) {
            throw new RampAccountingException('Error retrieving accounting connection: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Tests the accounting connection
     * @return Boolean True if connection is active
     */
    public static Boolean testAccountingConnection() {
        try {
            Map<String, Object> connection = getAccountingConnection();
            return connection != null && connection.containsKey('id');
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Custom exception for Ramp Accounting errors
     */
    public class RampAccountingException extends Exception {}
}