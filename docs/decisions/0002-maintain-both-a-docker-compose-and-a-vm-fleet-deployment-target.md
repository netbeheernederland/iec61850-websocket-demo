---
parent: Decisions
nav_order: ADR.02
dct:
  identifier: urn:uuid:7c1b6a9e-1d4f-4a3e-9c2f-6b8e4d2a2f02
  title: "Maintain both a single-host docker-compose target and a per-role VM fleet"
  isVersionOf: accepted
  issued: 2026-09-13
  language: en
owl:
  versionIRI: "https://esa-artifacts.example.com/metamodel/decisions/2026-09/0002-maintain-both-a-docker-compose-and-a-vm-fleet-deployment-target.html"
  versionInfo: "v1.0.0 (2026-09-13)"
---
<!-- markdownlint-disable-next-line MD025 -->

# Maintain both a single-host docker-compose target and a per-role VM fleet

## Context and Problem Statement

The stack (`rti-hmi`, `rti-bff`, `rti-fsp01/02`, `rti-so`) needs to serve two
different purposes: a fast, disposable demo/dev environment that a developer
can bring up in one command, and a fleet-shaped demo that shows the same
services distributed across separate machines with real network boundaries
(DHCP, mDNS, per-host certs) — closer to how the system would actually be
deployed at a customer site. A single deployment mechanism cannot serve both
well: a single `docker-compose.yml` can't demonstrate cross-host discovery
and per-node provisioning, and a full VM fleet is too slow and heavyweight
for routine local development.

## Decision Drivers

* Fast local iteration: contributors need a sub-minute `docker compose up`
  loop for day-to-day development.
* A believable multi-host demo: stakeholders need to see the services
  running as they would on separate physical/virtual machines, with
  realistic network boundaries (DHCP-assigned IPs, mDNS name resolution,
  per-node TLS material).
* Limited maintenance capacity: duplicating full application logic across
  two deployment paths is not sustainable for a small team.

## Considered Options

* Maintain two deployment targets: a root `docker-compose.yml` (single host)
  and a `setup/` VM fleet (one KVM guest per role), sharing the `modules/`
  application layer
* VM fleet only — drop the single-host compose file
* docker-compose only — drop the VM fleet, simulate multi-host behavior with
  Docker networks/aliases instead

## Decision Outcome

Chosen option: "Maintain two deployment targets, sharing the `modules/`
application layer", because it is the only option that satisfies both the
fast-iteration driver and the believable-multi-host-demo driver
simultaneously — the other two options each sacrifice one. The `setup/`
role directories (`roles/edge`, `roles/so`, `roles/fsp`) explicitly mirror
`modules/bff`, `modules/fsp01`, `modules/so`, so application code and config
are written once and consumed by both targets (see `setup/README.md`).

### Consequences

* Good, because a contributor can validate application changes with
  `docker compose up` in seconds, without touching libvirt/KVM.
* Good, because the VM fleet demonstrates real network-boundary behavior
  (DHCP reservations, mDNS `.local` resolution, per-node TLS, `docker save`
  tarball distribution) that a single Docker network cannot show.
* Bad, because some concerns must be implemented twice: cert generation
  (`cert-generator` service vs. `setup/render.sh`'s `gen_certs()`) and
  `connections.json` generation (hand-maintained vs. `render.sh`'s
  `render_connections()`) each have a compose-side and a fleet-side version.
* Bad, because the two targets can drift — e.g. `RTI_SERVICE_DISCOVERY_ENABLED`
  is `true` in `docker-compose.yml` but must be `false` in the VM fleet
  (`setup/README.md`: "BFF service discovery is disabled — it can't see
  other hosts' Docker"), which is an implicit, easy-to-miss difference
  between the two environments.

### Confirmation

Both targets exist and boot independently: `docker compose up` at the repo
root, and `cd setup && ./up.sh` for the fleet. Divergence between them is
currently caught only by manual review (e.g. of `setup/README.md`'s "Key
differences" section) rather than by an automated check.

## More Information

If the duplication in Consequences grows further (e.g. once
`../specs/2026-09-20-compose-node-scaling-design.md`'s
generator script exists), consider a follow-up ADR on whether to factor the
shared generation logic (certs, `connections.json`) into a single script
consumed by both targets, rather than parallel implementations.
