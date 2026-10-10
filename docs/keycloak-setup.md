# Keycloak Connection Point Authorization — Getting Started

This guide configures Keycloak so that a machine client can operate on **multiple connection points with different permissions per connection point**.

The examples assume:

```text
Keycloak:        http://localhost:8081
Realm:           iec61850-test
Calling client:  ws-client
Resource server: iec61850-api
```

## 1. Authorization model

The basic authorization relation is:

```text
subject + resource + scope
```

For example:

```text
service-account-ws-client
    CAN schedule:write
    ON connection point 871687400000123456
```

while the same client may only be able to read schedules on another connection point:

```text
service-account-ws-client
    CAN schedule:read
    ON connection point 871687400000654321
```

The example authorization matrix is:

| Connection point     | measurement:read | schedule:read | schedule:write | setpoint:read | setpoint:write |
|----------------------|-----------------:|--------------:|---------------:|--------------:|---------------:|
| `871687400000123456` |               ✓ |            ✓ |             ✓ |            ✓ |             ✓ |
| `871687400000654321` |               ✓ |            ✓ |              — |             — |              — |

In Keycloak this becomes:

```text
ws-client
    │
    │ client_credentials
    ▼
service-account-ws-client
    │
    └── realm role: ws-client-access
              │
              ▼
       Authorization Services
              │
      ┌───────┴────────┐
      │                │
      ▼                ▼
   CP-001            CP-002
      │                │
      ├ read           ├ read
      ├ write          └ schedule:read
      └ operate
```

## 2. Prerequisites

The validation scripts require:

```bash
curl
jq
base64
```

Set the client secret used by the example:

```bash
export WS_CLIENT_SECRET='K4Nrd14seXG52J3xpnIqfMyILTJJu3VI'
```

For production environments, do not commit client secrets to source control.

---

# 3. Realm configuration

Create:

```text
iec61850-test-realm.json
```

with:

```json
{
  "realm": "iec61850-test",
  "enabled": true,

  "eventsEnabled": true,
  "eventsListeners": [
    "jboss-logging"
  ],

  "enabledEventTypes": [
    "CLIENT_LOGIN",
    "REFRESH_TOKEN",
    "CODE_TO_TOKEN"
  ],

  "accessTokenLifespan": 60,

  "roles": {
    "realm": [
      {
        "name": "ws-client-access"
      }
    ]
  },

  "clients": [
    {
      "clientId": "ws-client",
      "name": "ws-client",

      "enabled": true,
      "protocol": "openid-connect",

      "publicClient": false,
      "serviceAccountsEnabled": true,

      "clientAuthenticatorType": "client-secret",
      "secret": "${WS_CLIENT_SECRET}",

      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false
    },

    {
      "clientId": "iec61850-api",
      "name": "IEC 61850 API",

      "enabled": true,
      "protocol": "openid-connect",

      "publicClient": false,
      "bearerOnly": false,

      "serviceAccountsEnabled": true,
      "authorizationServicesEnabled": true,

      "clientAuthenticatorType": "client-secret",

      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,

      "authorizationSettings": {
        "allowRemoteResourceManagement": false,

        "policyEnforcementMode": "ENFORCING",
        "decisionStrategy": "UNANIMOUS",

        "scopes": [
          {
            "name": "measurement:read"
          },
          {
            "name": "schedule:read"
          },
          {
            "name": "schedule:write"
          },
          {
            "name": "setpoint:read"
          },
          {
            "name": "setpoint:write"
          }
        ],

        "resources": [
          {
            "name": "cp-871687400000123456",
            "displayName": "Connection Point 871687400000123456",

            "type": "urn:energy:connection-point",
            "ownerManagedAccess": false,

            "attributes": {
              "connectionPoint": [
                "871687400000123456"
              ]
            },

            "scopes": [
              {
                "name": "measurement:read"
              },
              {
                "name": "schedule:read"
              },
              {
                "name": "schedule:write"
              },
              {
                "name": "setpoint:read"
              },
              {
                "name": "setpoint:write"
              }
            ]
          },

          {
            "name": "cp-871687400000654321",
            "displayName": "Connection Point 871687400000654321",

            "type": "urn:energy:connection-point",
            "ownerManagedAccess": false,

            "attributes": {
              "connectionPoint": [
                "871687400000654321"
              ]
            },

            "scopes": [
              {
                "name": "measurement:read"
              },
              {
                "name": "schedule:read"
              }
            ]
          }
        ],

        "policies": [
          {
            "name": "ws-client-policy",
            "description": "Allow the ws-client service account",

            "type": "role",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "roles": "[{\"id\":\"ws-client-access\",\"required\":true}]"
            }
          },

          {
            "name": "cp1-measurement-read",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000123456\"]",
              "scopes": "[\"measurement:read\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp1-schedule-read",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000123456\"]",
              "scopes": "[\"schedule:read\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp1-schedule-write",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000123456\"]",
              "scopes": "[\"schedule:write\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp1-setpoint-read",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000123456\"]",
              "scopes": "[\"setpoint:read\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp1-setpoint-write",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000123456\"]",
              "scopes": "[\"setpoint:write\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp2-measurement-read",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000654321\"]",
              "scopes": "[\"measurement:read\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          },

          {
            "name": "cp2-schedule-read",
            "type": "scope",
            "logic": "POSITIVE",
            "decisionStrategy": "UNANIMOUS",

            "config": {
              "resources": "[\"cp-871687400000654321\"]",
              "scopes": "[\"schedule:read\"]",
              "applyPolicies": "[\"ws-client-policy\"]"
            }
          }
        ]
      }
    }
  ],

  "users": [
    {
      "username": "service-account-ws-client",
      "enabled": true,

      "serviceAccountClientId": "ws-client",

      "realmRoles": [
        "ws-client-access"
      ]
    }
  ]
}
```

The important import-time relationship is:

```json
{
  "username": "service-account-ws-client",
  "serviceAccountClientId": "ws-client",
  "realmRoles": [
    "ws-client-access"
  ]
}
```

This means no manual role assignment in the Keycloak Admin Console is necessary when creating the realm.

---

# 4. Docker Compose

Mount the realm into Keycloak's import directory:

```yaml
services:

  keycloak:
    image: quay.io/keycloak/keycloak:latest

    command:
      - start-dev
      - --import-realm
      - --http-port=8080

    ports:
      - "8081:8080"

    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin

      WS_CLIENT_SECRET: K4Nrd14seXG52J3xpnIqfMyILTJJu3VI

    volumes:
      - ./iec61850-test-realm.json:/opt/keycloak/data/import/iec61850-test-realm.json:ro
```

Start Keycloak:

```bash
docker compose up -d
```

The realm should become available at:

```text
http://localhost:8081/realms/iec61850-test
```

## Existing realms

`--import-realm` is intended primarily for creating realms during startup.

If the realm already exists, startup import does not replace it.

For a disposable development environment it is often simplest to remove the existing Keycloak database/volume and start again.

For controlled updates of an existing realm, use Keycloak's explicit import/provisioning mechanisms instead.

---

# 5. Validate the realm

Verify that the OIDC discovery endpoint exists:

```bash
curl \
  --fail \
  --silent \
  http://localhost:8081/realms/iec61850-test/.well-known/openid-configuration |
jq '.issuer'
```

Expected:

```json
"http://localhost:8081/realms/iec61850-test"
```

---

# 6. Obtain a client-credentials token

Define:

```bash
export KEYCLOAK_URL='http://localhost:8081'
export REALM='iec61850-test'

export WS_CLIENT_ID='ws-client'
export WS_CLIENT_SECRET='K4Nrd14seXG52J3xpnIqfMyILTJJu3VI'
```

Request the token:

```bash
TOKEN_RESPONSE=$(
  curl \
    --fail \
    --silent \
    -X POST \
    "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${WS_CLIENT_ID}" \
    --data-urlencode "client_secret=${WS_CLIENT_SECRET}" \
    --data-urlencode 'grant_type=client_credentials'
)

echo "${TOKEN_RESPONSE}" | jq
```

Extract the token:

```bash
ACCESS_TOKEN=$(
  jq -r '.access_token' <<<"${TOKEN_RESPONSE}"
)
```

Verify:

```bash
test -n "${ACCESS_TOKEN}"
test "${ACCESS_TOKEN}" != "null"
```

---

# 7. Decode a JWT

For development and testing, define:

```bash
jwt_payload()
{
  local token="$1"
  local payload

  payload="$(
    printf '%s' "${token}" |
      cut -d. -f2 |
      tr '_-' '/+'
  )"

  case $((${#payload} % 4)) in
    2)
      payload="${payload}=="
      ;;
    3)
      payload="${payload}="
      ;;
  esac

  printf '%s' "${payload}" |
    base64 --decode 2>/dev/null
}
```

Inspect the token:

```bash
jwt_payload "${ACCESS_TOKEN}" | jq
```

Or only show relevant claims:

```bash
jwt_payload "${ACCESS_TOKEN}" |
jq '{
  sub,
  azp,
  preferred_username,
  realm_access
}'
```

The token should represent:

```text
service-account-ws-client
```

and should contain:

```text
ws-client-access
```

under:

```json
{
  "realm_access": {
    "roles": [
      "ws-client-access"
    ]
  }
}
```

---

# 8. Request authorization for a connection point

The ordinary client token identifies the caller.

Keycloak Authorization Services subsequently evaluates:

```text
resource + scope
```

Define:

```bash
request_permission()
{
  local resource="$1"
  local scope="$2"

  curl \
    --silent \
    -X POST \
    "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode \
      'grant_type=urn:ietf:params:oauth:grant-type:uma-ticket' \
    --data-urlencode \
      'audience=iec61850-api' \
    --data-urlencode \
      "permission=${resource}#${scope}"
}
```

---

# 9. Positive authorization tests

## CP1 — schedule:write

This is permitted:

```bash
request_permission \
  'cp-871687400000123456' \
  'schedule:write' |
jq
```

An authorization token should be returned.

## CP2 — schedule:read

This is also permitted:

```bash
request_permission \
  'cp-871687400000654321' \
  'schedule:read' |
jq
```

---

# 10. Negative authorization test

The second connection point does **not** permit `schedule:write`.

Test:

```bash
request_permission \
  'cp-871687400000654321' \
  'schedule:write' |
jq
```

Authorization should be denied.

This demonstrates why a resource/scope model is preferable to claims such as:

```json
{
  "connection_points": [
    "CP1",
    "CP2"
  ],

  "scope": "schedule:read schedule:write"
}
```

That representation cannot express that `schedule:write` applies only to CP1.

---

# 11. Inspect the authorization token

Request an allowed permission:

```bash
RPT_RESPONSE=$(
  request_permission \
    'cp-871687400000123456' \
    'schedule:write'
)
```

Extract:

```bash
RPT=$(
  jq -r '.access_token' <<<"${RPT_RESPONSE}"
)
```

Decode:

```bash
jwt_payload "${RPT}" |
jq '.authorization'
```

The authorization section should contain a structure similar to:

```json
{
  "permissions": [
    {
      "rsname": "cp-871687400000123456",
      "scopes": [
        "schedule:write"
      ]
    }
  ]
}
```

The authorization statement is therefore explicit:

```text
resource:
    cp-871687400000123456

scope:
    schedule:write
```

---

# 12. Complete validation script

Run:

```bash
./scripts/validate-keycloak-authz.sh
```

Expected output:

```text
Checking Keycloak realm...
PASS: realm is reachable

Obtaining service-account token...
PASS: client_credentials token acquired
PASS: service account contains ws-client-access

Testing CP1...
PASS: cp-871687400000123456#measurement:read allowed
PASS: cp-871687400000123456#schedule:read allowed
PASS: cp-871687400000123456#schedule:write allowed
PASS: cp-871687400000123456#setpoint:read allowed
PASS: cp-871687400000123456#setpoint:write allowed

Testing CP2...
PASS: cp-871687400000654321#measurement:read allowed
PASS: cp-871687400000654321#schedule:read allowed
PASS: cp-871687400000654321#schedule:write denied
PASS: cp-871687400000654321#setpoint:read denied
PASS: cp-871687400000654321#setpoint:write denied

All authorization checks passed.
```

---

# 13. Authorization in the API

The receiving resource server should validate:

```text
JWT signature
issuer
audience
expiration
authorization.permissions
```

The authorization check itself can conceptually be implemented as:

```python
def permitted(
    token,
    connection_point,
    required_scope,
):
    resource = f"cp-{connection_point}"

    permissions = (
        token
        .get("authorization", {})
        .get("permissions", [])
    )

    return any(
        permission.get("rsname") == resource
        and required_scope in permission.get(
            "scopes",
            [],
        )
        for permission in permissions
    )
```

For example:

```text
871687400000123456 + schedule:write
    -> ALLOW

871687400000654321 + schedule:read
    -> ALLOW

871687400000654321 + schedule:write
    -> DENY
```

Do not use JWT decoding alone as signature validation. The resource server must cryptographically validate the token before trusting its contents.

---

# 14. Adding another connection point

A connection point is a Keycloak Authorization Services resource:

```json
{
  "name": "cp-871687400000999999",

  "displayName":
    "Connection Point 871687400000999999",

  "type": "urn:energy:connection-point",

  "attributes": {
    "connectionPoint": [
      "871687400000999999"
    ]
  },

  "scopes": [
    {
      "name": "measurement:read"
    },
    {
      "name": "schedule:read"
    }
  ]
}
```

Permissions then determine which clients or market participants may exercise those scopes.

---

# 15. Adding domain-specific scopes

The model is not limited to generic CRUD-style permissions.

For an energy-system interface, scopes can express actual business operations:

```text
measurement:read

telemetry:write

schedule:read
schedule:write

setpoint:read
setpoint:write

constraint:read

flexibility:activate

switching:operate
```

For example:

```text
Connection Point A
    measurement:read
    schedule:read
    schedule:write
    setpoint:write

Connection Point B
    measurement:read
    schedule:read
```

This keeps the authorization semantics explicit:

```text
WHO
    service-account / market participant

MAY DO WHAT
    authorization scope

ON WHAT
    connection point
```

---

# 16. Why not put everything in ordinary JWT scopes?

Avoid a token structure such as:

```json
{
  "connection_points": [
    "871687400000123456",
    "871687400000654321"
  ],

  "scope":
    "measurement:read schedule:read schedule:write"
}
```

It loses the relation between resource and permission.

A consumer could incorrectly conclude:

```text
schedule:write
    applies to
871687400000654321
```

Instead, Keycloak Authorization Services produces an authorization relation such as:

```json
{
  "authorization": {
    "permissions": [
      {
        "rsname":
          "cp-871687400000123456",

        "scopes": [
          "schedule:write"
        ]
      }
    ]
  }
}
```

The resource/scope association therefore remains explicit.

---

# 17. Production considerations

For production:

- use HTTPS rather than plain HTTP;
- keep client secrets outside the realm JSON or inject them through environment variables/secrets;
- validate JWT signatures against the Keycloak realm keys;
- validate `iss`, `aud`, `exp`, and other required claims;
- keep access and authorization tokens appropriately short-lived;
- use domain-specific authorization scopes;
- avoid putting thousands of connection-point entitlements into normal access tokens;
- separate OAuth clients from protected resource-server clients;
- manage changes to existing realms with controlled provisioning/import tooling rather than relying solely on startup import.

The resulting architectural model is:

```text
OAuth Client
    ws-client
         │
         ▼
Service Account
    service-account-ws-client
         │
         ▼
Policy
    ws-client-policy
         │
         ▼
Permission
    resource + scope
         │
         ├── Connection Point
         │
         └── Operation
```

This allows one client or market participant to have different rights on different connection points without conflating identity, resources, and authorization.