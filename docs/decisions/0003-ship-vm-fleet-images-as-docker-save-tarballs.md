---
parent: Decisions
nav_order: ADR.03
dct:
  identifier: urn:uuid:9e2d5c7a-4f1b-4a6e-8d3a-1c9f6e7b0303
  title: "Ship VM fleet container images as docker save tarballs instead of a registry"
  isVersionOf: accepted
  issued: 2026-09-13
  language: en
owl:
  versionIRI: "https://esa-artifacts.example.com/metamodel/decisions/2026-09/0003-ship-vm-fleet-images-as-docker-save-tarballs.html"
  versionInfo: "v1.0.0 (2026-09-13)"
---
<!-- markdownlint-disable-next-line MD025 -->

# Ship VM fleet container images as docker save tarballs instead of a registry

## Context and Problem Statement

Each VM in the `setup/` fleet (`rti-edge`, `rti-so`, `rti-fsp*`) needs the
right container images available locally before its `compose.yaml` can start
— the images are built once from this repo's `docker-compose.yml` and must
end up on machines that boot from cloud-init with no guaranteed outbound
network access to a registry (per `setup/README.md`: "Nothing is pulled from
a registry"). How should images get from the build host onto each VM?

## Decision Drivers

* VMs must be able to boot and start their containers without requiring
  network access to an external or self-hosted image registry at boot time.
* The demo must be runnable entirely from a laptop/build host, without
  standing up supporting infrastructure (a registry, object storage) just to
  distribute images.
* Per-role image sets differ (`edge` needs `rti-bff`+`rti-hmi`, `so` needs
  `rti-so`, `fsp` needs `rti-fsp`) and should not force every VM to carry
  every image.

## Considered Options

* `docker save` the built images to tarballs and copy them into each VM's
  disk image at build time (`setup/build-tarballs.sh` + `setup/make-disks.sh`)
* Stand up a local/self-hosted registry (e.g. a `registry:2` container) and
  have each VM `docker pull` from it over the libvirt network at boot
* Push images to an external registry (e.g. a company or public registry)
  and have each VM pull from there

## Decision Outcome

Chosen option: "`docker save` the built images to tarballs and copy them
into each VM's disk image at build time", because it is the only option
that satisfies the no-registry-at-boot driver — a self-hosted registry
still requires the network to be up and the registry container healthy
before any other VM can start, and an external registry additionally
requires outbound internet access and registry credentials, neither of
which this demo can assume. `setup/build-tarballs.sh` runs `docker save` for
the `ROLE_TARBALLS`/`IMAGE_REF` sets defined in `setup/roles.env`, and
`setup/make-disks.sh` copies the per-role tarballs into each VM's overlay
disk, where cloud-init `docker load`s them on first boot.

### Consequences

* Good, because VMs boot and start their application containers with zero
  network dependency beyond the libvirt NAT (needed only for OS package
  installs during first boot, not for image delivery).
* Good, because each VM only carries the tarballs its role needs
  (`ROLE_TARBALLS` in `setup/roles.env`), not the full image set.
* Bad, because every image rebuild requires re-running
  `build-tarballs.sh` + `make-disks.sh` for affected roles — there is no
  incremental "just push the diff" path like a registry would give.
* Bad, because tarballs are embedded per-VM-disk rather than shared, so disk
  usage scales with VM count even when multiple VMs share a role (mitigated
  today since only `fsp` has more than one instance, and `rti-fsp01`/
  `rti-fsp02` currently use the same image).

### Confirmation

Verified by inspection of `setup/build-tarballs.sh`, `setup/make-disks.sh`,
and `setup/roles.env`'s `ROLE_TARBALLS`/`IMAGE_REF` maps, and by running
`./up.sh` end-to-end per `setup/README.md`'s documented run order.

## More Information

If the fleet grows to the "tens of nodes" scale referenced in
`docs/superpowers/specs/2026-09-20-compose-node-scaling-design.md` (for the
docker-compose target) and an equivalent scale-up is later wanted for the VM
fleet, the per-VM-tarball-copy cost in the second "Bad" consequence above
should be re-evaluated against standing up a local registry at that point.
