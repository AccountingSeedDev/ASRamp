/**
 * @description Resolves a Ramp reimbursement's employee to a Salesforce User by
 * email (Ramp user_email → User.Email). We can't create Users, so an unmatched
 * email returns no mapping and the caller reports the reimbursement as failed.
 *
 * Input is a map of Ramp user_id → email; output is Ramp user_id → User Id for
 * the ones that matched an active User.
 */
public with sharing class RampEmployeeResolver {

    public static Map<String, Id> resolveByEmail(Map<String, String> emailByRampUserId) {
        Map<String, Id> result = new Map<String, Id>();
        if (emailByRampUserId == null || emailByRampUserId.isEmpty()) return result;

        Set<String> emails = new Set<String>();
        for (String email : emailByRampUserId.values()) {
            if (String.isNotBlank(email)) emails.add(email);
        }
        if (emails.isEmpty()) return result;

        Map<String, Id> userByEmail = new Map<String, Id>();
        for (User u : [SELECT Id, Email FROM User WHERE Email IN :emails AND IsActive = true]) {
            if (String.isNotBlank(u.Email)) userByEmail.put(u.Email.toLowerCase(), u.Id);
        }

        for (String rampUserId : emailByRampUserId.keySet()) {
            String email = emailByRampUserId.get(rampUserId);
            if (String.isBlank(email)) continue;
            Id uid = userByEmail.get(email.toLowerCase());
            if (uid != null) result.put(rampUserId, uid);
        }
        return result;
    }
}
