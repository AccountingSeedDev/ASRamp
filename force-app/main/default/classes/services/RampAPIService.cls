/**
 * @description Service class for making Ramp API callouts
 */
public with sharing class RampAPIService {
    private static final Integer TIMEOUT = 120000; // 120 seconds

    /**
     * @description Makes a GET request to the Ramp API
     * @param endpoint The API endpoint (relative to base URL, e.g., '/v1/transactions')
     * @return HttpResponse The API response
     */
    public static HttpResponse get(String endpoint) {
        return makeRequest('GET', endpoint, null);
    }

    /**
     * @description Makes a POST request to the Ramp API
     * @param endpoint The API endpoint (relative to base URL)
     * @param body The request body as JSON string
     * @return HttpResponse The API response
     */
    public static HttpResponse post(String endpoint, String body) {
        return makeRequest('POST', endpoint, body);
    }

    /**
     * @description Makes a PATCH request to the Ramp API
     * @param endpoint The API endpoint (relative to base URL)
     * @param body The request body as JSON string
     * @return HttpResponse The API response
     */
    public static HttpResponse patch(String endpoint, String body) {
        return makeRequest('PATCH', endpoint, body);
    }

    /**
     * @description Makes a DELETE request to the Ramp API
     * @param endpoint The API endpoint (relative to base URL)
     * @return HttpResponse The API response
     */
    public static HttpResponse doDelete(String endpoint) {
        return makeRequest('DELETE', endpoint, null);
    }

    /**
     * @description Makes an HTTP request to the Ramp API
     * @param method HTTP method (GET, POST, PATCH, DELETE)
     * @param endpoint The API endpoint (relative to base URL)
     * @param body The request body (optional)
     * @return HttpResponse The API response
     */
    @TestVisible
    private static HttpResponse makeRequest(String method, String endpoint, String body) {
        // Get credential and access token
        Ramp_Credential__mdt credential = RampAuthService.getActiveCredential();
        String accessToken = RampAuthService.getAccessToken();

        // Construct full URL
        String fullUrl = credential.API_Base_URL__c;
        if (!endpoint.startsWith('/')) {
            fullUrl += '/';
        }
        fullUrl += endpoint;

        // Build request
        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod(method);
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT);

        if (String.isNotBlank(body)) {
            req.setBody(body);
        }

        system.debug('get endpoint: ' + req.getEndpoint());
        system.debug('get method: ' + req.getMethod());
        system.debug('get body: ' + req.getBody());

        // Send request
        Http http = new Http();
        HttpResponse res;

        try {
            res = http.send(req);
            system.debug('resp: ' + res.getStatusCode());
            system.debug('resp status: ' + res.getStatus());
            system.debug('resp body: ' + res.getBody());
        } catch (Exception e) {
            throw new RampAPIException('API request failed: ' + e.getMessage(), e);
        }

        // Handle token expiration (401) by clearing cache and retrying once
        if (res.getStatusCode() == 401) {
            RampAuthService.clearCachedToken();
            accessToken = RampAuthService.getAccessToken();
            req.setHeader('Authorization', 'Bearer ' + accessToken);

            try {
                res = http.send(req);
            } catch (Exception e) {
                throw new RampAPIException('API retry failed: ' + e.getMessage(), e);
            }
        }

        return res;
    }

    /**
     * @description Parses the API response and throws an exception if not successful
     * @param res The HTTP response
     * @return String The response body
     * @throws RampAPIException if the response indicates an error
     */
    public static String handleResponse(HttpResponse res) {
        Integer statusCode = res.getStatusCode();

        // Success codes: 200-299
        if (statusCode >= 200 && statusCode < 300) {
            return res.getBody();
        }

        // Build error message
        String errorMessage = 'Ramp API error (Status ' + statusCode + ')';

        try {
            Map<String, Object> errorBody = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (errorBody.containsKey('error')) {
                errorMessage += ': ' + errorBody.get('error');
            } else if (errorBody.containsKey('message')) {
                errorMessage += ': ' + errorBody.get('message');
            }
        } catch (Exception e) {
            errorMessage += ': ' + res.getBody();
        }

        throw new RampAPIException(errorMessage);
    }

    /**
     * @description Custom exception for Ramp API errors
     */
    public class RampAPIException extends Exception {}
}