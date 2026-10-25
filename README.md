<!--
SPDX-FileCopyrightText: 2026 Netbeheer Nederland

SPDX-License-Identifier: Apache-2.0
-->

# iec61850-websocket demo

Deployment and demo material for the **rti-demo** of
[iec61850-websocket](https://github.com/Netbeheer-Nederland/iec61850-websocket):
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
| `rti-fsp02`      | `rti-fsp`   | FSP on control point `cp2`, `model_2.py`          | 5005          |
| `keycloak`       | Keycloak 26 | OAuth server, realm `iec61850-test`               | 8080, 8443    |
| `cert-generator` | Alpine      | One-off: mints the CA and TLS certificates        | —             |

Images are named `${RTI_IMAGE_REPO}/rti-<role>:${RTI_IMAGE_TAG}`, by default
`netbeheer-nederland/iec61850-websocket/rti-<role>:latest`. Published images
live under `ghcr.io/netbeheer-nederland/iec61850-websocket`.

## Quick start (single host)

Requires Docker with Compose v2 and the images available locally (see
[docs/docker-images-github.md](docs/docker-images-github.md)), or point
Compose at the registry:

```bash
export RTI_IMAGE_REPO=ghcr.io/netbeheer-nederland/iec61850-websocket   # optional
docker compose up -d
```

`cert-generator` runs first and fills the shared `certs` volume; every
other service mounts it read-only at `/certs`. Then:

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
produces arm64 image archives and `scripts/deploy-rti-demo.sh` copies them,
with a role's compose file, to each Pi:

```bash
scripts/pull-rti-demo.sh
scripts/deploy-rti-demo.sh --start --role so 192.168.100.97 \
  --role fsp --cp cp1 --model modules/fsp01/models/model_1.py 192.168.100.98
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
