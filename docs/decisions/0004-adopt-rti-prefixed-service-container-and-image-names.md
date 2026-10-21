---
parent: Decisions
nav_order: ADR.04
dct:
  identifier: urn:uuid:1a8f3d6c-5e2a-4b9c-a7f1-3d6c5e2a0404
  title: "Adopt rti-prefixed names for every service, container, and image"
  isVersionOf: accepted
  issued: 2026-09-20
  language: en
owl:
  versionIRI: "https://esa-artifacts.example.com/metamodel/decisions/2026-09/0004-adopt-rti-prefixed-service-container-and-image-names.html"
  versionInfo: "v1.0.0 (2026-09-20)"
---
<!-- markdownlint-disable-next-line MD025 -->

# Adopt rti-prefixed names for every service, container, and image

## Context and Problem Statement

Compose service keys, `container_name`s, and image names must match
consistently across `docker-compose.yml`, `setup/roles.env`, the per-role
VM compose templates, `connections.json`, and the `SERVER_HOSTNAMES` cert
SAN list — a mismatch in any one place breaks TLS SAN coverage, mDNS
resolution, or `depends_on` wiring. Most services already followed an
`rti-<role>` pattern (`rti-hmi`, `rti-so`, `rti-fsp01`, `rti-fsp02`), but the
BFF service was named `bff-server`, the one outlier. What naming pattern
should every service, container, and image follow going forward?

## Decision Drivers

* Consistency reduces cross-file mismatch risk: the same name string is
  repeated in at least five places (compose service key, `container_name`,
  image path, `SERVER_HOSTNAMES`, `connections.json` `host` field) and any
  one being spelled differently silently breaks TLS SANs or discovery.
* Names should communicate at a glance that a container belongs to this
  demo's RTI service set, distinguishing it from unrelated containers a
  host might be running (`cert-generator` is deliberately exempt — it is
  infrastructure, not an RTI service).
* Renaming has a real cost (every reference must be updated together), so
  the pattern should be settled once rather than revisited per-service.

## Considered Options

* `rti-<role>` for every RTI service (`rti-hmi`, `rti-bff`, `rti-so`,
  `rti-fsp01`, `rti-fsp02`), infrastructure services (`cert-generator`)
  unprefixed
* Leave `bff-server` as the outlier, prefix only newly-added services going
  forward
* Drop the `rti-` prefix everywhere for shorter names (`hmi`, `bff`, `so`,
  `fsp01`)

## Decision Outcome

Chosen option: "`rti-<role>` for every RTI service, infrastructure services
unprefixed", because it is the only option that resolves the existing
inconsistency (`bff-server` vs. `rti-hmi`/`rti-so`/`rti-fsp*`) rather than
either freezing it in place or discarding a pattern three of five services
already used. `bff-server` was renamed to `rti-bff` across
`docker-compose.yml` (service key, `container_name`, image path,
`SERVER_HOSTNAMES`, `rti.service`/`rti.host` labels), `setup/roles.env`,
`setup/roles/edge/compose.yaml`, `scripts/retag-bff-hmi.sh`, and the
`setup/` READMEs.

### Consequences

* Good, because every RTI service name, container name, and image path is
  now derivable from the same `rti-<role>` rule, reducing the chance of a
  cross-file mismatch when adding a service.
* Good, because it directly enables predictable name generation for the
  scaling work in
  `../specs/2026-09-20-compose-node-scaling-design.md` — a
  generator can construct `rti-<role><NN>` without a per-service exception
  table.
* Neutral, because `modules/bff/` (the module/config directory) was
  deliberately left unrenamed — it sits alongside `modules/fsp01/` and
  `modules/so/`, which also omit the `rti-` prefix, so renaming only `bff`
  would have introduced a new inconsistency at the module-directory level.
* Bad, because any external reference to the old `bff-server` image name
  (e.g. a previously-built local image tag, or a pinned deployment
  manifest outside this repo) will not resolve until manually updated —
  this rename is not backward-compatible.

### Confirmation

Verified with `docker compose -f docker-compose.yml config`, which parses
and resolves the renamed service without error, and by `grep -rn
"bff-server"` across the repository returning no remaining matches after
the rename.

## More Information

Rename executed 2026-09-20. See commit "Rename bff-server service/
container/image to rti-bff". If `modules/` is ever restructured, revisit
whether module directory names should also gain the `rti-` prefix for full
consistency with the runtime naming decided here.
