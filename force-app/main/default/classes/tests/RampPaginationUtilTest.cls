/**
 * @description Tests for RampPaginationUtil.extractNextCursor.
 */
@IsTest
private class RampPaginationUtilTest {

    private static Map<String, Object> pageWithNext(Object next) {
        return new Map<String, Object>{ 'data' => new List<Object>(), 'page' => new Map<String, Object>{ 'next' => next } };
    }

    @IsTest
    static void extractNextCursor_fullUrl_returnsBareCursor() {
        String next = 'https://api.ramp.com/developer/v1/accounting/field-options' +
                      '?field_remote_id=abc&page_size=100&start=cursor-123';
        System.assertEquals('cursor-123', RampPaginationUtil.extractNextCursor(pageWithNext(next)));
    }

    @IsTest
    static void extractNextCursor_startFollowedByMoreParams_stopsAtAmpersand() {
        String next = 'https://api.ramp.com/developer/v1/accounting/fields?start=cursor-9&page_size=100';
        System.assertEquals('cursor-9', RampPaginationUtil.extractNextCursor(pageWithNext(next)));
    }

    @IsTest
    static void extractNextCursor_noNextPage_returnsNull() {
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(pageWithNext(null)));
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(pageWithNext('')));
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(
            pageWithNext('https://api.ramp.com/developer/v1/accounting/fields?page_size=100')));
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(
            pageWithNext('https://api.ramp.com/developer/v1/accounting/fields?start=')));
    }

    @IsTest
    static void extractNextCursor_missingOrMalformedPage_returnsNull() {
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(null));
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(new Map<String, Object>()));
        System.assertEquals(null, RampPaginationUtil.extractNextCursor(new Map<String, Object>{ 'page' => 'oops' }));
    }
}
