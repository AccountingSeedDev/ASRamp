/**
 * @description Deterministic UUID generation shared by services that must derive a stable
 * external id from a name, so re-running a create is idempotent (Ramp returns/updates the
 * same field instead of creating a duplicate). Extracted from
 * RampAccountingFieldService.generateDeterministicUUID so RampCustomDimensionService can
 * produce ids in the identical format from its own seed.
 */
public class RampDeterministicIdUtil {

    /**
     * @description SHA-256 hashes the seed and formats the digest as a UUID v5-style string,
     * so the same seed always yields the same id.
     * @param seed The value to hash. Callers should give each call site its own prefix (e.g.
     *        'ASRamp:' vs 'ASRampDim:') so two different features can never collide on the
     *        same underlying name.
     * @return String A deterministic id formatted as xxxxxxxx-xxxx-5xxx-axxx-xxxxxxxxxxxx
     */
    @TestVisible
    public static String generateUUID(String seed) {
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(seed));
        String hex = EncodingUtil.convertToHex(hash);
        // Format as UUID v5: xxxxxxxx-xxxx-5xxx-yxxx-xxxxxxxxxxxx
        // Position 13 must be '5' (version 5 = name-based)
        // Position 17 must be 8, 9, a, or b (variant)
        return hex.substring(0, 8) + '-' +
               hex.substring(8, 12) + '-' +
               '5' + hex.substring(13, 16) + '-' +
               'a' + hex.substring(17, 20) + '-' +
               hex.substring(20, 32);
    }
}
