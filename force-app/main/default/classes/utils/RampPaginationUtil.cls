/**
 * @description Shared helpers for Ramp's keyset-paginated list endpoints. Extracted from the
 * identical private extractNextCursor copies that previously lived in each service/batch, so
 * every paginated caller reads page.next the same way.
 */
public class RampPaginationUtil {

    /**
     * @description Pulls the keyset cursor out of Ramp's page.next URL. Ramp returns the
     * complete URL of the next page (e.g. ".../field-options?field_remote_id=<id>&start=<cursor>"),
     * so the cursor must be extracted rather than used as-is — passing the whole URL back as
     * `start` makes Ramp reject the request (DEVELOPER_7001 "Not a valid UUID").
     * @param responseMap The parsed JSON body of a paginated Ramp response
     * @return String The start cursor for the next page, or null if there is none
     */
    public static String extractNextCursor(Map<String, Object> responseMap) {
        if (responseMap == null) return null;
        Object pageObj = responseMap.get('page');
        if (!(pageObj instanceof Map<String, Object>)) return null;
        String nextUrl = (String) ((Map<String, Object>) pageObj).get('next');
        if (String.isBlank(nextUrl)) return null;
        Integer i = nextUrl.indexOf('start=');
        if (i < 0) return null;
        String cursor = nextUrl.substring(i + 6);
        Integer amp = cursor.indexOf('&');
        if (amp >= 0) cursor = cursor.substring(0, amp);
        return String.isBlank(cursor) ? null : cursor;
    }
}
