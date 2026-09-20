---
parent: Decisions
nav_order: ADR.01
dct:
  identifier: urn:uuid:3f3a4e2e-2b9a-4e2b-9b2a-7a1a2f4c9101
  title: "Generate mTLS certificates with a dedicated cert-generator service"
  isVersionOf: accepted
  issued: 2026-09-07
  language: en
owl:
  versionIRI: "https://esa-artifacts.example.com/metamodel/decisions/2026-09/0001-generate-mtls-certificates-with-a-cert-generator-service.html"
  versionInfo: "v1.0.0 (2026-09-07)"
---
<!-- markdownlint-disable-next-line MD025 -->

# Generate mTLS certificates with a dedicated cert-generator service

## Context and Problem Statement

Every service in the stack (`rti-hmi`, `rti-bff`, `rti-fsp01`, `rti-fsp02`,
`rti-so`) needs a CA-signed server certificate and every internal client
connection needs a matching client certificate, so peers can authenticate
each other over mTLS. The demo has to boot on a bare Docker host with `docker
compose up` and no external dependency (no pre-existing CA, no secrets
manager, no manual cert-copying step), while still producing certificates
whose Subject Alternative Names (SANs) cover every container's hostname.
How should the stack mint and distribute this TLS material?

## Decision Drivers

* Zero-dependency bootstrap: the stack must come up from a clean `docker
  compose up` with no external CA, vault, or manually-provisioned secret.
* SAN coverage must track the service list without hand-editing certificate
  files whenever a service is added.
* Idempotent re-runs: repeated `docker compose up` must not regenerate (and
  thereby invalidate) certificates already in use by running containers.
* Certificates must be reachable read-only by every service, not just the
  one that mints them.

## Considered Options

* A `cert-generator` service that mints a CA + server/client cert pair into a
  shared Docker volume on first boot
* Certificates committed to the repository (pre-generated, checked in)
* An external CA / secrets manager (e.g. Vault, cert-manager) issuing certs
  at container start

## Decision Outcome

Chosen option: "A `cert-generator` service that mints a CA + server/client
cert pair into a shared Docker volume on first boot", because it is the only
option that satisfies zero-dependency bootstrap without also committing
private key material to the repository. It runs `cfssl` in an ephemeral
`alpine` container, writes `ca.pem`/`server.pem`/`client.pem`(+ keys) into
the `certs` named volume, and every other service mounts that volume
read-only at `/certs` and depends on `cert-generator` via
`service_completed_successfully`.

### Consequences

* Good, because no private key material is ever committed to the repository.
* Good, because SANs are driven by the `SERVER_HOSTNAMES` env var
  (`docker-compose.yml`), so adding a service is a one-line change rather
  than a manual re-issue.
* Good, because the generator exits 0 immediately if `ca.pem`/`server.pem`/
  `client.pem` already exist in the volume, so repeated `docker compose up`
  is safe and doesn't invalidate certs live containers are already using.
* Bad, because the CA is self-signed and regenerated per-deployment — there
  is no cross-environment trust; a client machine (e.g. a browser hitting
  `rti-hmi`) must import the generated CA to avoid TLS warnings.
* Bad, because changing `SERVER_HOSTNAMES` after certs already exist has no
  effect until the `certs` volume is deleted — this is a manual step, not
  automated by the generator.

### Confirmation

Verified by inspection: `docker compose up cert-generator` followed by
`docker compose up` brings up all services with healthy healthchecks (which
for `rti-hmi`/`rti-bff`/`rti-fsp*`/`rti-so` implicitly requires successful
TLS handshakes). The VM fleet under `setup/` uses the equivalent pattern
host-side (`setup/render.sh`'s `gen_certs()`), confirming the approach
generalizes beyond the single-host case.

## More Information

The VM fleet (`setup/`) cannot reuse this service directly — it has no
shared Docker network across nodes — so `setup/render.sh` reimplements the
same `cfssl`-based generation on the host and embeds the resulting PEMs into
each node's cloud-init. See `setup/certs/README.md` for the CSR/profile
config shared by both paths. A future ADR could evaluate unifying these two
generation paths behind a single script.
