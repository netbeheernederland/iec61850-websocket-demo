# Scripts

Helper scripts for building, publishing and deploying the rti-demo images,
and for testing and recording the demo. Run them from the repository root.

Every script explains its options in its header comment; for the shell
scripts with options, `--help` prints it (e.g. `scripts/push-rti-demo.sh --help`).

| Script                       | What it does                                                          | Docs                                                        |
|------------------------------|-----------------------------------------------------------------------|-------------------------------------------------------------|
| `build-rti-demo.sh`          | Build the images from upstream, save them as `.tar.gz` archives        | [README](../README.md), [setup/README](../setup/README.md) |
| `pull-rti-demo.sh`           | Pull `fsp`/`so` from GHCR and save them as archives, instead of building | [GHCR guide §7a](../docs/docker-images-github.md)         |
| `push-rti-demo.sh`           | Tag the local images with their GHCR names and push them               | [GHCR guide §4](../docs/docker-images-github.md)            |
| `retag-images.sh`            | Only tag the local images with their GHCR names; prints push commands  | [GHCR guide §4](../docs/docker-images-github.md)            |
| `stage-rti-role.sh`          | Put one Pi's files for its role (`so`/`fsp`) in a directory            | [setup/README](../setup/README.md)                          |
| `deploy-rti-demo.sh`         | Copy the archives and a role's files to running Pis, optionally start  | [README](../README.md), [setup/README](../setup/README.md) |
| `load-and-start.sh`          | On the Pi: `docker load` the archives and `docker compose up -d`       | [setup/README](../setup/README.md)                          |
| `validate-keycloak-authz.sh` | Check Keycloak's realm, token and per-control-point authorisation     | [Keycloak setup](../docs/keycloak-setup.md)                 |
| `record_demo.py`             | Record the HMI while a playbook drives the demo                        | [Recording the demo](../docs/recording-the-demo.md)         |

## Typical flows

### Pis: build and deploy

```bash
scripts/build-rti-demo.sh                          # all images, linux/arm64/v8
scripts/deploy-rti-demo.sh --start --role so 192.168.100.97
```

`deploy-rti-demo.sh` uses `stage-rti-role.sh` to put each host's files
together and, with `--start`, runs `load-and-start.sh` on the host.
`setup/pi-user-data.sh --role` writes the same files into a new Pi image
instead, so the Pi starts its role on first boot.

### Pis: use the published images instead of building

```bash
scripts/pull-rti-demo.sh                           # fsp and so from GHCR
scripts/build-rti-demo.sh plugins                  # dr-panel and dr-leds aren't published
scripts/deploy-rti-demo.sh --start --role fsp 192.168.100.98
```

### Publish images to GHCR

```bash
echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin
scripts/build-rti-demo.sh fsp so
scripts/push-rti-demo.sh --dry-run --tag sha-1a2b3c4   # check first
scripts/push-rti-demo.sh --tag sha-1a2b3c4 fsp so
```

`push-rti-demo.sh` only pushes arm64 images unless given `--arch`, so an
amd64 build for the VM fleet can't replace the Pis' `latest`.

### Check and record the demo

```bash
docker compose up -d
scripts/validate-keycloak-authz.sh
uv run scripts/record_demo.py                      # playbooks/demo.yaml
```

## Environment

Shared by several scripts:

| Variable        | Used by                                    | Default                                            |
|-----------------|--------------------------------------------|----------------------------------------------------|
| `RTI_IMAGE_DIR` | build, pull, stage, deploy                 | `dist/rti-images-<arch>` (`dist/rti-images-arm64`) |
| `RTI_REGISTRY`  | pull, push, retag                          | `ghcr.io/netbeheernederland/iec61850-websocket`    |
| `CLONE_DIR`     | build                                      | `${TMPDIR:-/tmp}/iec61850-websocket-clone`         |
| `TARGET_USER`   | deploy                                     | `rti`                                              |

## VM fleet

The scripts that build and run the local VM fleet (`render.sh`,
`make-disks.sh`, `launch.sh`, `up.sh`, `destroy.sh`, `build-base.sh`,
`build-tarballs.sh`, `download-images.sh`) and `pi-user-data.sh` live in
[`setup/`](../setup/) and are described in [setup/README.md](../setup/README.md).
