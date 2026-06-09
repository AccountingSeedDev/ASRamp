/**
 * @description Global API for retrieving a single Ramp card transaction using
 * the org's configured Ramp connection (active Ramp_Credential__mdt + cached
 * token). Subscriber-org Apex calls:
 *
 *     RampTransactionAPI.RampTransaction txn = RampTransactionAPI.getTransaction('<uuid>');
 *
 * The returned object mirrors the Ramp GET /developer/v1/transactions/{id}
 * response. Field names match Ramp's JSON so the response deserializes directly.
 * `rawJson` carries the full untouched response for any field not modeled here.
 *
 * NOTE: global members are a permanent managed-package API contract — additive
 * changes only.
 */
global with sharing class RampTransactionAPI {

    /**
     * @description Fetch one Ramp transaction by its UUID.
     * @param transactionId Ramp transaction id (UUID).
     * @return The transaction, mirroring the Ramp API response.
     * @throws RampTransactionAPIException on blank input, 404 (not found), or any non-2xx response.
     */
    global static RampTransaction getTransaction(String transactionId) {
        if (String.isBlank(transactionId)) {
            throw new RampTransactionAPIException('transactionId is required.');
        }
        HttpResponse res = RampAPIService.get(
            '/developer/v1/transactions/' + EncodingUtil.urlEncode(transactionId, 'UTF-8'));
        Integer code = res.getStatusCode();
        if (code == 404) {
            throw new RampTransactionAPIException('Ramp transaction not found: ' + transactionId);
        }
        if (code < 200 || code >= 300) {
            throw new RampTransactionAPIException(
                'Ramp API error retrieving transaction ' + transactionId + ' (HTTP ' + code + '): ' + res.getBody());
        }
        RampTransaction txn;
        try {
            txn = (RampTransaction) JSON.deserialize(res.getBody(), RampTransaction.class);
        } catch (Exception e) {
            throw new RampTransactionAPIException(
                'Failed to parse Ramp transaction response: ' + e.getMessage());
        }
        if (txn == null) txn = new RampTransaction();
        txn.rawJson = res.getBody();
        return txn;
    }

    // ── Response DTOs (field names mirror Ramp's JSON) ──

    global class RampTransaction {
        global String id;
        global Decimal amount;
        global String currency_code;
        global String accounting_date;
        global String user_transaction_time;
        global String settlement_date;
        global String synced_at;
        global String merchant_name;
        global String merchant_descriptor;
        global String merchant_id;
        global String merchant_category_code;
        global String merchant_category_code_description;
        global String memo;
        global String state;
        global String sync_status;
        global String entity_id;
        global String card_id;
        global Boolean card_present;
        global Integer sk_category_id;
        global String sk_category_name;
        global CardHolder card_holder;
        global List<AccountingFieldSelection> accounting_field_selections;
        global List<LineItem> line_items;
        // Full untouched Ramp response — use for any field not modeled above.
        global String rawJson;
    }

    global class CardHolder {
        global String user_id;
        global String first_name;
        global String last_name;
        global String department_id;
        global String department_name;
        global String location_id;
        global String location_name;
        global String employee_id;
    }

    global class AccountingFieldSelection {
        global String id;
        global String name;
        global String type;
        global String external_id;
        global String external_code;
        global CategoryInfo category_info;
    }

    global class CategoryInfo {
        global String id;
        global String name;
        global String type;
        global String external_id;
    }

    global class LineItem {
        global CurrencyAmount amount;
        global CurrencyAmount converted_amount;
        global String memo;
        global List<AccountingFieldSelection> accounting_field_selections;
    }

    global class CurrencyAmount {
        global Long amount;
        global String currency_code;
        global Integer minor_unit_conversion_rate;
    }

    global class RampTransactionAPIException extends Exception {}
}
