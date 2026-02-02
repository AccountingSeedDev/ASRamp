/**
 * @description Service class for handling Ramp OAuth authentication
 */
public with sharing class RampAuthService {
    private static final String GRANT_TYPE = 'client_credentials';
    private static final String CACHE_PARTITION = 'AcctSeedRamp.RampTokens';
    private static final Integer CACHE_TTL_SECONDS = 172800; // 48 hours (max allowed)

    /**
     * @description Retrieves the active Ramp credential configuration
     * @return Ramp_Credential__mdt The active credential record
     * @throws RampAuthException if no active credential is found
     */
    public static Ramp_Credential__mdt getActiveCredential() {
        List<Ramp_Credential__mdt> credentials = [
            SELECT Client_ID__c, Client_Secret__c, Token_URL__c,
                   API_Base_URL__c, Scopes__c, Is_Active__c, DeveloperName
            FROM Ramp_Credential__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];

        if (credentials.isEmpty()) {
            throw new RampAuthException('No active Ramp credential found');
        }

        return credentials[0];
    }

    /**
     * @description Gets an access token, retrieving from cache if available
     * @return String The access token
     */
    public static String getAccessToken() {
        Ramp_Credential__mdt credential = getActiveCredential();
        String cacheKey = 'token' + credential.DeveloperName;

        // Try to get from cache first
        Cache.OrgPartition orgPartition = Cache.Org.getPartition(CACHE_PARTITION);
        if (orgPartition != null) {
            String cachedToken = (String) orgPartition.get(cacheKey);
            if (String.isNotBlank(cachedToken)) {
                return cachedToken;
            }
        }

        // If not in cache, request new token
        RampTokenResponse tokenResponse = requestAccessToken(credential);

        if (tokenResponse.isValid()) {
            // Cache the token
            if (orgPartition != null) {
                orgPartition.put(cacheKey, tokenResponse.access_token, CACHE_TTL_SECONDS);
            }
            return tokenResponse.access_token;
        }

        throw new RampAuthException('Failed to obtain valid access token');
    }

    /**
     * @description Requests a new access token from Ramp OAuth endpoint
     * @param credential The Ramp credential configuration
     * @return RampTokenResponse The token response
     * @throws RampAuthException if the request fails
     */
    @TestVisible
    private static RampTokenResponse requestAccessToken(Ramp_Credential__mdt credential) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(credential.Token_URL__c);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        // Use HTTP Basic Auth: Base64(client_id:client_secret)
        String authString = credential.Client_ID__c + ':' + credential.Client_Secret__c;
        String authHeader = 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(authString));
        req.setHeader('Authorization', authHeader);

        // Build the request body - scope is required by Ramp
        if (String.isBlank(credential.Scopes__c)) {
            throw new RampAuthException('Scope is required for Ramp authentication');
        }

        String body = 'grant_type=' + GRANT_TYPE;
        body += '&scope=' + EncodingUtil.urlEncode(credential.Scopes__c, 'UTF-8');

        req.setBody(body);

        Http http = new Http();
        HttpResponse res;

        try {
            res = http.send(req);
        } catch (Exception e) {
            throw new RampAuthException('Failed to send OAuth request: ' + e.getMessage(), e);
        }

        if (res.getStatusCode() == 200) {
            try {
                return (RampTokenResponse) JSON.deserialize(
                    res.getBody(),
                    RampTokenResponse.class
                );
            } catch (Exception e) {
                throw new RampAuthException('Failed to parse token response: ' + e.getMessage(), e);
            }
        } else {
            throw new RampAuthException(
                'OAuth request failed with status ' + res.getStatusCode() +
                ': ' + res.getBody()
            );
        }
    }

    /**
     * @description Clears the cached access token for the active credential
     */
    public static void clearCachedToken() {
        Ramp_Credential__mdt credential = getActiveCredential();
        String cacheKey = 'token' + credential.DeveloperName;

        Cache.OrgPartition orgPartition = Cache.Org.getPartition(CACHE_PARTITION);
        if (orgPartition != null) {
            orgPartition.remove(cacheKey);
        }
    }

    /**
     * @description Custom exception for Ramp authentication errors
     */
    public class RampAuthException extends Exception {}
}