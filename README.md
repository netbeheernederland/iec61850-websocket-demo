<!--
SPDX-FileCopyrightText: 2026 Netbeheer Nederland

SPDX-License-Identifier: Apache-2.0
-->

# iec61850-websocket demo

Deployment and demo material for the **rti-demo** of
[iec61850-websocket](https://github.com/netbeheernederland/iec61850-websocket):
a system operator (**SO**, ACSI client) talking IEC 61850 over WebSocket to
flexibility service providers (**FSPs**, ACSI servers), watched and driven
from a web HMI.

This repository holds no application code. It pulls or builds the upstream
images and wires them together, with mTLS certificates, Keycloak, FSP
models and demo playbooks, for three deployment targets.

## Services

| Service          | Image       | Role                                              | Host port(s)  |
|------------------|-------------|---------------------------------------------------|---------------|
| `rti-hmi`        | `rti-hmi`   | Web HMI                                           | 80            |
| `rti-bff`        | `rti-bff`   | Backend-for-frontend; runs playbooks              | 3000          |
| `rti-so`         | `rti-so`    | System operator (ACSI client)                     | —             |
| `rti-fsp01`      | `rti-fsp`   | FSP on control point `cp1`, `model_1.py`          | 5001          |
| `rti-fsp02`      | `rti-fsp`   | FSP on control point `cp2`, `model_2.py`; connects to the SO at start | 5005 |
| `dr-leds-fsp02`, `dr-leds-so` | `dr-leds` | Plugin: two simulated LEDs for `rti-fsp02` and `rti-so` | — |
| `keycloak`       | Keycloak 26 | OAuth server, realm `iec61850-test`               | 8080, 8443    |
| `cert-generator` | Alpine      | One-off: mints the CA and TLS certificates        | —             |

Images are named `${RTI_IMAGE_REPO}/rti-<role>:${RTI_IMAGE_TAG}` (plugins
`.../dr-leds`, `.../dr-panel`), by default
`netbeheernederland/iec61850-websocket/rti-<role>:latest`. Published images
live under `ghcr.io/netbeheernederland/iec61850-websocket`, for amd64 and
arm64. `rti-fsp01` connects to the display plugin `display_st7789` on the
network instead ([modules/fsp01/plugins.json](modules/fsp01/plugins.json)).

## Quick start (single host)

Requires Docker with Compose v2 and the images available locally (see
[docs/docker-images-github.md](docs/docker-images-github.md)), or point
Compose at the registry:

```bash
export RTI_IMAGE_REPO=ghcr.io/netbeheernederland/iec61850-websocket   # optional
docker compose up -d
```

`cert-generator` runs first and fills the shared `certs` volume; every
other service mounts it read-only at `/certs`.

Each service's log level is set from the host environment, default `info`:
`BFF_LOG_LEVEL`, `HMI_LOG_LEVEL`, `SO_LOG_LEVEL` and `FSP_LOG_LEVEL` (both
FSPs), e.g. `FSP_LOG_LEVEL=debug docker compose up -d`. `HMI_BFF_HOST` and
`HMI_BFF_PORT` set the BFF address as the browser reaches it (default
`localhost:3000`).

Then:

- HMI: <http://localhost>
- BFF: <http://localhost:3000>
- Keycloak admin: <http://localhost:8080> (`admin` / `admin`)

The BFF reads its connections from
[modules/bff/config/connections.json](modules/bff/config/connections.json).
Check under HMI → Connections that the SO and both FSPs are registered.

## Running the demo

Playbooks script a demo as a list of steps (link, read, write, operate,
reports, …) that the BFF runs and checks. Run one from the HMI (Traffic →
Playbook) or from the command line with [uv](https://docs.astral.sh/uv/):

```bash
uv run playbooks/runner/run.py playbooks/demo.yaml
```

To record a playbook run as a video of the HMI:

```bash
uv run scripts/record_demo.py
```

See [playbooks/README.md](playbooks/README.md) and
[docs/recording-the-demo.md](docs/recording-the-demo.md).

## Deployment targets

| Target                 | Where                                                         | Guide                                                    |
|------------------------|---------------------------------------------------------------|----------------------------------------------------------|
| Single host            | `docker-compose.yml`                                          | this README                                              |
| VM fleet / Pis         | `setup/` (KVM + cloud-init), `scripts/` and `modules/{so,fsp}` (Pis) | [setup/README.md](setup/README.md)                |
| Kubernetes             | `deploy/` (Helm charts + ArgoCD ApplicationSets)              | [docs/kubernetes-argocd.md](docs/kubernetes-argocd.md)   |

For Raspberry Pis, `scripts/build-rti-demo.sh` (or `scripts/pull-rti-demo.sh`)
produces arm64 image archives (`build-rti-demo.sh` also amd64 ones, unless
given `--platform linux/arm64/v8`) and `scripts/deploy-rti-demo.sh` copies them,
with a role's compose file, to each Pi. `build-rti-demo.sh` builds the base
images `rti-fsp`, `rti-so`, `rti-bff` and `rti-hmi` and every upstream plugin
in `examples/rti-plugins/`: the IO plugin `dr-panel` and the sample plugin
`dr-leds`. `--plugins` picks the plugins a Pi runs, comma-separated or
`none`; by default so runs `dr-panel,dr-leds` and fsp `dr-leds`.
`pull-rti-demo.sh` pulls `rti-fsp`, `rti-so` and `dr-leds`; build `dr-panel`,
which so runs by default, with `build-rti-demo.sh dr-panel`:

```bash
scripts/build-rti-demo.sh        # or: pull-rti-demo.sh && build-rti-demo.sh dr-panel
scripts/deploy-rti-demo.sh --start --role so 192.168.100.97 \
  --role fsp --cp cp1 --model modules/fsp01/models/model_1.py 192.168.100.98 \
  --plugins dr-panel,dr-leds --cp cp2 192.168.100.99
```

Or make a Pi image with the role in it and flash that, so the Pi starts it
on first boot without a deploy step:

```bash
setup/pi-user-data.sh --rpi 5 --hostname rti-fsp-pi5 \
  --role fsp --cp cp1 --model modules/fsp01/models/model_1.py
# -> setup/images/rti-fsp-pi5.img; setup/images/base-rti-rpi5.img is unchanged
```

See [setup/README.md](setup/README.md#writing-an-image-to-an-sd-card-or-ssd).

## Repository layout

```text
docker-compose.yml   single-host stack
modules/
  bff/config/        BFF connections.json
  fsp01/, fsp02/     FSP models (and plugins.json) for the compose stack
  fsp/, so/          per-role compose files for the Pis
  keycloak/          realm import (iec61850-test)
playbooks/           demo playbooks and the CLI runner
scripts/             image build/pull/deploy, demo recording, Keycloak checks
setup/               VM fleet: base images, cloud-init, certs config
deploy/              Helm charts, ArgoCD apps, per-installation values
docs/                guides, decisions (ADRs) and specs
```

## Documentation

- [Keycloak connection point authorization](docs/keycloak-setup.md)
- [Docker images on GitHub (GHCR)](docs/docker-images-github.md)
- [Kubernetes and ArgoCD](docs/kubernetes-argocd.md)
- [Recording the demo](docs/recording-the-demo.md)
- [Test certificates](setup/certs/README.md)
- [Architecture decision records](docs/decisions/README.md)
- Design specs and plans: [docs/specs/](docs/specs/)
