# Design: Scaling FSP/SO nodes in the root docker-compose stack

- Status: Draft
- Date: 2026-09-20
- Scope: `docker-compose.yml`, `modules/bff/config/connections.json`, new `scripts/render-compose.sh`

## Problem

`docker-compose.yml` currently hand-lists each RTI-FSP / RTI-SO service as a
full copy-pasted block (`rti-fsp01`, `rti-fsp02`, `rti-so`), each with its own
port mapping, `CP`, optional `MODELPATH`, health check, and labels.
`modules/bff/config/connections.json` and the `cert-generator` service's
`SERVER_HOSTNAMES` env var must be kept in sync with that same list by hand.

This does not scale to the tens of FSP/SO nodes the demo needs to support.
Growing the fleet today means editing three places (compose services,
`connections.json`, `SERVER_HOSTNAMES`) consistently by hand, which is
error-prone and gets worse linearly with node count.

The VM fleet under `setup/` already solved the equivalent problem for its
deployment target with `render.sh` + `nodes.env`: one node list drives
generation of certs, `connections.json`, and per-node compose files. This
spec ports that pattern to the root `docker-compose.yml`, scoped to
docker-compose only (the `setup/` VM fleet is out of scope for this spec and
is not required to share the generator).

## Non-goals

- Changing how the VM fleet (`setup/`) generates its own artifacts.
- Supporting node counts beyond "tens" (the ceiling that motivated this;
  hundreds of nodes would need a different node-list format, e.g. generated
  from a count rather than hand-written lines — not addressed here).
- Changing the BFF/HMI/websocket protocol surface, or `rti-bff` /
  `rti-hmi` themselves (they remain hand-maintained, fixed services).
- Runtime dynamic node registration — nodes are still declared statically,
  just generated instead of hand-copied.

## Design

### Inputs: `scripts/compose-nodes.env`

A new file, same shape as `setup/nodes.env`, listing only `so` and `fsp`
role nodes (root compose has no `edge` VM role — `rti-bff` and `rti-hmi`
are not generated):

```
NODES=(
  "rti-so     so    port=5000"
  "rti-fsp01  fsp   port=5001 cp=cp1 model=model_1.py"
  "rti-fsp02  fsp   port=5005 cp=cp2 model="
)
```

Each line: `<container-name> <role> <key=value ...>`. Recognized extras:
`port` (required), and for `fsp` only: `cp`, `model` (filename under
`modules/fsp01/models/`, or empty).

### Outputs

`scripts/render-compose.sh` regenerates, in place:

1. **`docker-compose.yml`** — the block between two sentinel comments
   (`# BEGIN generated nodes` / `# END generated nodes`) is replaced with one
   service stanza per `so`/`fsp` line, built from two small heredoc
   templates (one per role) inside the script — mirroring how
   `render.sh` builds `connections.json` inline rather than from a
   Jinja template. Everything outside the sentinels (`cert-generator`,
   `rti-hmi`, `rti-bff`, `volumes:`, `networks:`) is untouched.
2. **`modules/bff/config/connections.json`** — fully regenerated from the
   same node list, replacing today's hand-maintained file. Field mapping
   matches the existing schema (`id`, `name`, `host`, `port`, `type`,
   `acsi`, `ws_mode`, `OAuth` stub, `status`), following the same
   `so`/`fsp` → `RTI-SO`/`RTI-FSP`, `client`/`server`, `passive`/`active`
   mapping `render.sh`'s `render_connections()` already uses.
3. **`SERVER_HOSTNAMES`** for `cert-generator` — printed by the script as
   the value to export (or written to a `.env` file consumed by
   `docker-compose.yml`'s existing `${SERVER_HOSTNAMES:-...}` default), so
   generated node names are always covered by the server cert's SANs.

### Idempotency & safety

- Re-running with an unchanged node list produces byte-identical output
  (no timestamps or non-deterministic ordering in the generated sections).
- The script only ever rewrites text between its own sentinels in
  `docker-compose.yml` and fully overwrites `connections.json` (which is
  already 100% generated content, never hand-edited alongside generated
  nodes). If the sentinels are missing, the script fails loudly rather than
  guessing where to inject.
- No changes to `cert-generator`'s existing idempotency (it already skips
  regeneration if `/out/*.pem` exist); a `SERVER_HOSTNAMES` change requires
  clearing the `certs` volume to take effect, same as today.

### Testing

- `docker compose -f docker-compose.yml config` validates the generated
  YAML parses and resolves.
- A smoke test runs `render-compose.sh` against a sample node list, brings
  the stack up, and polls each generated FSP/SO's `/api/status` and the
  BFF's `/api/health` until healthy.
- A unit-level check diffs `render-compose.sh`'s output for a fixed sample
  node list against a committed golden file, to catch accidental format
  drift.

## Open questions for implementation planning

- Exact sentinel comment text and indentation rules for the generated
  block (must survive repeated regeneration cleanly).
- Whether `render-compose.sh` should also validate `compose-nodes.env`
  (duplicate names, port collisions) before writing output.
