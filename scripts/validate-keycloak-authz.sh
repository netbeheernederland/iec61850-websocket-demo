#!/usr/bin/env bash

set -euo pipefail


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8081}"
REALM="${REALM:-iec61850-test}"

WS_CLIENT_ID="${WS_CLIENT_ID:-ws-client}"
WS_CLIENT_SECRET="${WS_CLIENT_SECRET:-K4Nrd14seXG52J3xpnIqfMyILTJJu3VI}"

RESOURCE_SERVER="${RESOURCE_SERVER:-iec61850-api}"

CP1="${CP1:-cp-871687400000123456}"
CP2="${CP2:-cp-871687400000654321}"

TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}


pass()
{
    echo "PASS: $*"
}


jwt_payload()
{
    local token="$1"
    local payload

    payload="$(
        printf '%s' "${token}" \
            | cut -d. -f2 \
            | tr '_-' '/+'
    )"

    case $((${#payload} % 4)) in
        2)
            payload="${payload}=="
            ;;
        3)
            payload="${payload}="
            ;;
    esac

    printf '%s' "${payload}" \
        | base64 --decode 2>/dev/null
}


request_permission()
{
    local token="$1"
    local resource="$2"
    local scope="$3"

    curl \
        --silent \
        -X POST \
        "${TOKEN_ENDPOINT}" \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode \
        'grant_type=urn:ietf:params:oauth:grant-type:uma-ticket' \
        --data-urlencode \
        "audience=${RESOURCE_SERVER}" \
        --data-urlencode \
        "permission=${resource}#${scope}"
}


expect_allowed()
{
    local token="$1"
    local resource="$2"
    local scope="$3"

    local response
    local rpt
    local found

    response="$(
        request_permission \
            "${token}" \
            "${resource}" \
            "${scope}"
    )"

    rpt="$(
        jq -r '.access_token // empty' <<<"${response}"
    )"

    if [[ -z "${rpt}" ]]; then
        echo "${response}" | jq >&2
        fail "${resource}#${scope} should be allowed"
    fi

    found="$(
        jwt_payload "${rpt}" \
            | jq \
                -r \
                --arg resource "${resource}" \
                --arg scope "${scope}" \
                '
                    [
                        .authorization.permissions[]?
                        | select(.rsname == $resource)
                        | .scopes[]?
                        | select(. == $scope)
                    ]
                    | length
                '
    )"

    if [[ "${found}" -eq 0 ]]; then
        echo
        echo "Authorization token:"
        jwt_payload "${rpt}" | jq
        echo

        fail "RPT does not contain ${resource}#${scope}"
    fi

    pass "${resource}#${scope} allowed"
}

expect_denied()
{
    local token="$1"
    local resource="$2"
    local scope="$3"

    local response
    local rpt
    local error
    local description

    response="$(
        request_permission \
            "${token}" \
            "${resource}" \
            "${scope}"
    )"

    rpt="$(
        jq -r '.access_token // empty' <<<"${response}"
    )"

    if [[ -n "${rpt}" ]]; then
        echo
        echo "Unexpected authorization token:"
        jwt_payload "${rpt}" | jq
        echo

        fail "${resource}#${scope} should be denied"
    fi

    error="$(
        jq -r '.error // empty' <<<"${response}"
    )"

    description="$(
        jq -r '.error_description // empty' <<<"${response}"
    )"

    case "${error}" in
        access_denied)
            pass \
                "${resource}#${scope} denied (${description:-access_denied})"
            ;;

        invalid_resource)
            pass \
                "${resource}#${scope} not applicable to resource"
            ;;

        *)
            echo "${response}" | jq >&2

            fail \
                "${resource}#${scope} returned unexpected error: ${error:-<none>}"
            ;;
    esac
}

# ------------------------------------------------------------
# Realm
# ------------------------------------------------------------

echo "Checking Keycloak realm..."

if ! curl \
    --fail \
    --silent \
    "${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration" \
    >/dev/null
then
    fail "realm ${REALM} is not reachable"
fi

pass "realm is reachable"


# ------------------------------------------------------------
# Client credentials
# ------------------------------------------------------------

echo
echo "Obtaining service-account token..."

TOKEN_RESPONSE="$(
    curl \
        --fail \
        --silent \
        -X POST \
        "${TOKEN_ENDPOINT}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode \
        "client_id=${WS_CLIENT_ID}" \
        --data-urlencode \
        "client_secret=${WS_CLIENT_SECRET}" \
        --data-urlencode \
        'grant_type=client_credentials'
)"

ACCESS_TOKEN="$(
    jq -r '.access_token // empty' <<<"${TOKEN_RESPONSE}"
)"

if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo "${TOKEN_RESPONSE}" | jq >&2
    fail "client_credentials did not return an access token"
fi

pass "client_credentials token acquired"


# ------------------------------------------------------------
# Calling client
# ------------------------------------------------------------

AUTHORIZED_PARTY="$(
    jwt_payload "${ACCESS_TOKEN}" \
        | jq -r '.azp // empty'
)"

if [[ "${AUTHORIZED_PARTY}" != "${WS_CLIENT_ID}" ]]; then
    echo
    echo "Token:"
    jwt_payload "${ACCESS_TOKEN}" | jq
    echo

    fail \
        "expected authorized party ${WS_CLIENT_ID}, got ${AUTHORIZED_PARTY:-<none>}"
fi

pass "token was issued to ${WS_CLIENT_ID}"


# ------------------------------------------------------------
# Authorization tests
# ------------------------------------------------------------

echo
echo "Testing CP1..."

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP1}" \
    'measurement:read'

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP1}" \
    'schedule:read'

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP1}" \
    'schedule:write'

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP1}" \
    'setpoint:read'

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP1}" \
    'setpoint:write'


echo
echo "Testing CP2..."

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP2}" \
    'measurement:read'

expect_allowed \
    "${ACCESS_TOKEN}" \
    "${CP2}" \
    'schedule:read'

expect_denied \
    "${ACCESS_TOKEN}" \
    "${CP2}" \
    'schedule:write'

expect_denied \
    "${ACCESS_TOKEN}" \
    "${CP2}" \
    'setpoint:read'

expect_denied \
    "${ACCESS_TOKEN}" \
    "${CP2}" \
    'setpoint:write'


# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "All authorization checks passed."
