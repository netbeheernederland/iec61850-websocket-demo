# Docker Images on GitHub (GHCR) — Getting Started

This guide covers publishing the rti-demo images (`rti-fsp`, `rti-so`,
`rti-io`) to the **GitHub Container Registry** (GHCR, `ghcr.io`) and getting
them from there onto the Pis.

It does not replace the tarball flow. [ADR 0003](decisions/0003-ship-vm-fleet-images-as-docker-save-tarballs.md)
still holds: machines must be able to start without access to a registry, so
`scripts/build-rti-demo.sh` → `scripts/deploy-rti-demo.sh` stays the default.
GHCR adds a shared place to keep built images, so that not every developer
has to build arm64 under QEMU, and Pis that do have internet access can pull
directly.

The examples assume:

```text
Upstream repo:  https://github.com/Netbeheer-Nederland/iec61850-websocket
Branch:         initial-refactor
Example dir:    examples/rti-demo
Registry:       ghcr.io/netbeheer-nederland/iec61850-websocket
Local name:     netbeheer-nederland/iec61850-websocket/rti-<image>:latest
Platform:       linux/arm64/v8 (the only arch the Pis run)
```

## 1. Image naming

GHCR names are `ghcr.io/<owner>/<name>`, where `<owner>` is the GitHub
organisation **in lower case**. Nested names are allowed, so the images map
one-to-one onto the names the compose files already use:

| Local name (compose files, tarballs)                 | GHCR name                                                    |
|------------------------------------------------------|--------------------------------------------------------------|
| `netbeheer-nederland/iec61850-websocket/rti-fsp`     | `ghcr.io/netbeheer-nederland/iec61850-websocket/rti-fsp`     |
| `netbeheer-nederland/iec61850-websocket/rti-so`      | `ghcr.io/netbeheer-nederland/iec61850-websocket/rti-so`      |
| `netbeheer-nederland/iec61850-websocket/rti-io`      | `ghcr.io/netbeheer-nederland/iec61850-websocket/rti-io`      |

`modules/fsp/docker-compose.yml` and `modules/so/docker-compose.yml` refer to
the **local** name. Without a registry host, Docker reads that as a Docker Hub
name, so `docker compose pull` would not find it. Every flow below therefore
ends by re-tagging the GHCR image to its local name, which keeps the compose
files unchanged.

Tags used:

| Tag              | Meaning                                         |
|------------------|-------------------------------------------------|
| `latest`         | Last build of the `initial-refactor` branch     |
| `sha-<7 chars>`  | Build of that upstream commit; use it to pin    |
| `<branch>`       | Last build of another branch, if CI builds it   |

## 2. Access tokens

GHCR authenticates with a GitHub **personal access token (classic)**;
fine-grained tokens cannot be used for the container registry.

| Who                      | Scopes                               | Used for                        |
|--------------------------|--------------------------------------|---------------------------------|
| Developer pushing images | `write:packages` (+ `read:packages`) | `docker push` from a laptop     |
| Pi or build host pulling | `read:packages` only                 | `docker pull` of private images |
| Cleaning up old versions | `delete:packages`                    | Deleting package versions       |

Create one under *GitHub → Settings → Developer settings → Personal access
tokens → Tokens (classic)*. If the organisation uses SSO, authorise the token
for `Netbeheer-Nederland` afterwards (*Configure SSO* next to the token).

If you use the GitHub CLI, you can add the scope to its token instead of
creating a new one:

```bash
gh auth refresh -h github.com -s write:packages
```

Inside GitHub Actions no personal token is needed: the workflow's
`GITHUB_TOKEN` can push (section 5).

## 3. Log in

```bash
# With a personal access token in $GHCR_TOKEN
echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin

# Or with the GitHub CLI's token
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

`docker login` stores the token, only base64-encoded, in
`~/.docker/config.json` of the user running it. On a Pi that is the `rti`
user, so give the Pi a **read-only** token and never your push token.

Public packages can be pulled without logging in.

## 4. Build and push from a developer machine

`scripts/build-rti-demo.sh` builds the images with `--load` and saves them as
tarballs. To publish the same images, push them straight from buildx. The
Dockerfiles and contexts are the ones that script uses:

| Image | Dockerfile (in the clone)                                   | Context                                      |
|-------|-------------------------------------------------------------|----------------------------------------------|
| `fsp` | `examples/rti-demo/modules/fsp/docker/Dockerfile`           | repo root                                    |
| `so`  | `examples/rti-demo/modules/so/docker/Dockerfile`            | repo root                                    |
| `io`  | `examples/rti-demo/modules/io/docker/Dockerfile`            | `examples/rti-demo/modules/io`               |

Run `scripts/build-rti-demo.sh` once first: it creates the clone (default
`${TMPDIR:-/tmp}/iec61850-websocket-clone`), registers QEMU and creates the
`rti-builder` buildx builder. Then, for example for `fsp`:

```bash
CLONE_DIR="${TMPDIR:-/tmp}/iec61850-websocket-clone"
REGISTRY="ghcr.io/netbeheer-nederland/iec61850-websocket"
SHA="$(git -C "${CLONE_DIR}" rev-parse --short=7 HEAD)"

docker buildx build --builder rti-builder --platform linux/arm64/v8 \
  -f "${CLONE_DIR}/examples/rti-demo/modules/fsp/docker/Dockerfile" \
  -t "${REGISTRY}/rti-fsp:latest" \
  -t "${REGISTRY}/rti-fsp:sha-${SHA}" \
  --label org.opencontainers.image.source=https://github.com/Netbeheer-Nederland/iec61850-websocket \
  --annotation "index:org.opencontainers.image.source=https://github.com/Netbeheer-Nederland/iec61850-websocket" \
  --push "${CLONE_DIR}"
```

For `io`, use its Dockerfile and `"${CLONE_DIR}/examples/rti-demo/modules/io"`
as the context.

The `org.opencontainers.image.source` label/annotation **links the package to
the upstream repository**. A linked package shows up on the repo's page and
can inherit the repo's access settings; without it the package belongs only
to the organisation and must be shared by hand.

> Already have the image loaded locally (after `build-rti-demo.sh`)? Then
> tagging and pushing is enough:
>
> ```bash
> docker tag netbeheer-nederland/iec61850-websocket/rti-fsp:latest \
>   ghcr.io/netbeheer-nederland/iec61850-websocket/rti-fsp:latest
> docker push ghcr.io/netbeheer-nederland/iec61850-websocket/rti-fsp:latest
> ```
>
> The package is then not linked to the repo; link it once in the package
> settings (*Connect repository*).

## 5. Build and push with GitHub Actions

Because this repository lives on GitLab, the workflow belongs in the
**upstream** GitHub repo, `Netbeheer-Nederland/iec61850-websocket`, as for
example `.github/workflows/rti-demo-images.yml`. It builds the three images on
every push to `initial-refactor` that touches the example or the shared core:

```yaml
name: rti-demo images

on:
  push:
    branches: [initial-refactor]
    paths:
      - "examples/rti-demo/**"
      - "src/**"
      - "uv.lock"
      - ".github/workflows/rti-demo-images.yml"
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    # Native arm64 runner: no QEMU, much faster than emulated builds
    runs-on: ubuntu-24.04-arm
    strategy:
      fail-fast: false
      matrix:
        include:
          - image: fsp
            dockerfile: examples/rti-demo/modules/fsp/docker/Dockerfile
            context: .
          - image: so
            dockerfile: examples/rti-demo/modules/so/docker/Dockerfile
            context: .
          - image: io
            dockerfile: examples/rti-demo/modules/io/docker/Dockerfile
            context: examples/rti-demo/modules/io
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/netbeheer-nederland/iec61850-websocket/rti-${{ matrix.image }}
          tags: |
            type=raw,value=latest,enable=${{ github.ref_name == 'initial-refactor' }}
            type=sha,prefix=sha-
            type=ref,event=branch

      - uses: docker/build-push-action@v6
        with:
          context: ${{ matrix.context }}
          file: ${{ matrix.dockerfile }}
          platforms: linux/arm64/v8
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          annotations: ${{ steps.meta.outputs.annotations }}
          cache-from: type=gha,scope=rti-${{ matrix.image }}
          cache-to: type=gha,mode=max,scope=rti-${{ matrix.image }}
```

Notes:

* `docker/metadata-action` sets the `org.opencontainers.image.source` label
  and annotation, so the packages are linked to the repo automatically.
* `permissions: packages: write` lets `GITHUB_TOKEN` push. If a package was
  first pushed by hand (section 4), give the repo write access to it once:
  *package → Package settings → Manage Actions access → Add repository →
  Role: Write*. Otherwise the push fails with `403 Forbidden`.
* `ubuntu-24.04-arm` is a hosted arm64 runner. If it is not available for the
  repository, use `runs-on: ubuntu-latest` and add
  `- uses: docker/setup-qemu-action@v3` before the buildx step; the build then
  runs emulated, like `build-rti-demo.sh`.
* `workflow_dispatch` adds a *Run workflow* button to rebuild by hand.

## 6. Package visibility

New packages are **private**. Set visibility per package under
*Organisation → Packages → `<package>` → Package settings → Danger zone →
Change visibility*.

* **Private** (default): every machine that pulls needs a `read:packages`
  token (section 3).
* **Public**: anyone can pull without logging in. Only do this if the images
  contain nothing confidential (no keys, certificates, internal hostnames).
  The organisation may have disabled public packages.

## 7. Getting GHCR images onto the Pis

### 7a. Offline Pis: pull on the build host, then deploy tarballs as usual

This keeps ADR 0003's model and the existing scripts. Instead of building, pull
the arm64 images and write the archives `deploy-rti-demo.sh` expects, under the
local names the compose files use. `scripts/pull-rti-demo.sh` does this:

```bash
scripts/pull-rti-demo.sh                        # all three, tag latest
scripts/pull-rti-demo.sh --tag sha-1a2b3c4 fsp  # one image, pinned build
scripts/deploy-rti-demo.sh --start --role so 192.168.100.97
```

It also checks that each pulled image is arm64. By hand, the same steps are:

```bash
REGISTRY="ghcr.io/netbeheer-nederland/iec61850-websocket"
LOCAL="netbeheer-nederland/iec61850-websocket"
OUT="dist/rti-images"
TAG="latest"            # or sha-<commit> to pin a build
mkdir -p "${OUT}"

for image in rti-fsp rti-so rti-io; do
  docker pull --platform linux/arm64/v8 "${REGISTRY}/${image}:${TAG}"
  docker tag "${REGISTRY}/${image}:${TAG}" "${LOCAL}/${image}:latest"
  docker save "${LOCAL}/${image}:latest" | gzip > "${OUT}/${image}.tar.gz.partial"
  mv "${OUT}/${image}.tar.gz.partial" "${OUT}/${image}.tar.gz"
done

scripts/deploy-rti-demo.sh --start --role so 192.168.100.97
```

On an amd64 build host, pulling with `--platform linux/arm64/v8` works without
QEMU; the image is only stored, not run. If Docker uses the containerd image
store and `docker save` complains about missing content for the host
platform, add `--platform linux/arm64/v8` to `docker save` as well.

### 7b. Pis with internet access: pull on the Pi

On each Pi, as the `rti` user, once:

```bash
echo "<read-only token>" | docker login ghcr.io -u <github-user> --password-stdin
```

Then, in `~/rti` (where `deploy-rti-demo.sh` puts the compose file), for each
image the role needs (`so`: `rti-so rti-io`; `fsp`: `rti-fsp rti-io`):

```bash
REGISTRY="ghcr.io/netbeheer-nederland/iec61850-websocket"
LOCAL="netbeheer-nederland/iec61850-websocket"

for image in rti-so rti-io; do
  docker pull "${REGISTRY}/${image}:latest"
  docker tag "${REGISTRY}/${image}:latest" "${LOCAL}/${image}:latest"
done

docker compose up -d
```

Do not run `load-and-start.sh` afterwards if old `*.tar.gz` archives are still
in `~/rti`: it loads them again and replaces the freshly pulled images. Remove
the archives first, or start with `docker compose up -d` only.

## 8. Checking what is in the registry

```bash
# Tags and platforms of one image
docker buildx imagetools inspect ghcr.io/netbeheer-nederland/iec61850-websocket/rti-fsp:latest

# All versions of a package (organisation-owned)
gh api /orgs/Netbeheer-Nederland/packages/container/iec61850-websocket%2Frti-fsp/versions \
  -q '.[] | "\(.id)\t\(.metadata.container.tags | join(","))\t\(.created_at)"'
```

Nested package names are URL-encoded in the API: `/` becomes `%2F`.

`imagetools inspect` should list `linux/arm64` (plus `unknown/unknown`
entries for build attestations, which are normal). If it shows only
`linux/amd64`, the image was built for the wrong platform and will fail on the
Pis with `exec format error`.

## 9. Cleaning up old versions

Every CI build adds a `sha-…` version. Delete old ones by hand under
*Package settings → Manage versions*, or with the API (needs
`delete:packages`):

```bash
gh api -X DELETE \
  /orgs/Netbeheer-Nederland/packages/container/iec61850-websocket%2Frti-fsp/versions/<version-id>
```

Or let the workflow clean up after itself by adding a job such as:

```yaml
  cleanup:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      packages: write
    strategy:
      matrix:
        image: [fsp, so, io]
    steps:
      - uses: actions/delete-package-versions@v5
        with:
          package-name: iec61850-websocket/rti-${{ matrix.image }}
          package-type: container
          min-versions-to-keep: 10
          ignore-versions: '^latest$'
```

`delete-package-versions` counts untagged manifests (the per-platform entries
behind a tag) as versions too; keep `min-versions-to-keep` generous so it does
not delete layers a kept tag still needs.

## 10. Troubleshooting

| Symptom                                                        | Cause and fix                                                                                                            |
|----------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `denied: denied` / `unauthorized` on pull                      | Not logged in, token lacks `read:packages`, or token not SSO-authorised for the organisation.                            |
| `403 Forbidden` on push from Actions                           | Workflow lacks `permissions: packages: write`, or the repo has no write access to an existing package (section 5).       |
| `invalid reference format: repository name must be lowercase`  | Owner written as `Netbeheer-Nederland`; GHCR names must be lower case.                                                    |
| `pull access denied for netbeheer-nederland/…` on `compose up` | The GHCR image was pulled but not re-tagged to the local name the compose file uses (section 7).                         |
| `exec format error` when a container starts                    | The image is amd64; rebuild or pull with `linux/arm64/v8`.                                                               |
| Pi starts an old version after pulling                         | `load-and-start.sh` re-loaded old `*.tar.gz` archives in `~/rti` (section 7b).                                           |
