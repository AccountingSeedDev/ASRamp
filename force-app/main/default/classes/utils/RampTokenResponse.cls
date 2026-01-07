/**
 * @description Wrapper class for Ramp OAuth token response
 */
public class RampTokenResponse {
    public String access_token { get; set; }
    public String token_type { get; set; }
    public Integer expires_in { get; set; }
    public String scope { get; set; }

    /**
     * @description Calculates the expiration datetime based on expires_in seconds
     * @return DateTime when the token will expire
     */
    public DateTime getExpirationDateTime() {
        if (expires_in != null) {
            return DateTime.now().addSeconds(expires_in);
        }
        return null;
    }

    /**
     * @description Checks if the token is valid (has an access token)
     * @return Boolean indicating if token is valid
     */
    public Boolean isValid() {
        return String.isNotBlank(access_token);
    }
}