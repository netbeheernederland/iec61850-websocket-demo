# Docker Images on GitHub (GHCR) — Getting Started

This guide covers publishing the rti-demo images (`rti-fsp`, `rti-so`,
`rti-bff`, `rti-hmi`, the IO plugin `dr-panel`, formerly `rti-io`, and the
sample plugin `dr-leds`) to the **GitHub Container Registry** (GHCR,
`ghcr.io`) and getting them from there onto the Pis.

It does not replace the tarball flow. [ADR 0003](decisions/0003-ship-vm-fleet-images-as-docker-save-tarballs.md)
still holds: machines must be able to start without access to a registry, so
`scripts/build-rti-demo.sh` → `scripts/deploy-rti-demo.sh` stays the default.
GHCR adds a shared place to keep built images, so that not every developer
has to build arm64 under QEMU, and Pis that do have internet access can pull
directly.

The examples assume:

```text
Upstream repo:  https://github.com/netbeheernederland/iec61850-websocket
Branch:         main
Example dir:    examples/rti-demo
Registry:       ghcr.io/netbeheernederland/iec61850-websocket
Local name:     netbeheernederland/iec61850-websocket/rti-<image>:latest
                (plugins: .../dr-panel:latest)
Platform:       linux/arm64/v8 (the only arch the Pis run)
```

## 1. Image naming

GHCR names are `ghcr.io/<owner>/<name>`, where `<owner>` is the GitHub
organisation **in lower case**. Nested names are allowed, so the images map
one-to-one onto the names the compose files already use:

| Local name (compose files, tarballs)                 | GHCR name                                                    |
|------------------------------------------------------|--------------------------------------------------------------|
| `netbeheernederland/iec61850-websocket/rti-fsp`     | `ghcr.io/netbeheernederland/iec61850-websocket/rti-fsp`     |
| `netbeheernederland/iec61850-websocket/rti-so`      | `ghcr.io/netbeheernederland/iec61850-websocket/rti-so`      |
| `netbeheernederland/iec61850-websocket/dr-panel`    | `ghcr.io/netbeheernederland/iec61850-websocket/dr-panel`    |
| `netbeheernederland/iec61850-websocket/rti-bff`     | `ghcr.io/netbeheernederland/iec61850-websocket/rti-bff`     |
| `netbeheernederland/iec61850-websocket/rti-hmi`     | `ghcr.io/netbeheernederland/iec61850-websocket/rti-hmi`     |
| `netbeheernederland/iec61850-websocket/dr-leds`     | `ghcr.io/netbeheernederland/iec61850-websocket/dr-leds`     |

`modules/fsp/docker-compose.yml` and `modules/so/docker-compose.yml` refer to
the **local** name. Without a registry host, Docker reads that as a Docker Hub
name, so `docker compose pull` would not find it. Every flow below therefore
ends by re-tagging the GHCR image to its local name, which keeps the compose
files unchanged.

Tags used:

| Tag              | Meaning                                         |
|------------------|-------------------------------------------------|
| `latest`         | Last build of the `main` branch                 |
| `sha-<commit>`   | Build of that upstream commit; use it to pin (CI: full commit, by hand: as given) |
| `main`           | Last CI build of `main` (the same as `latest`)  |

## 2. Access tokens

GHCR authenticates with a GitHub **personal access token (classic)**;
fine-grained tokens cannot be used for the container registry.

| Who                      | Scopes                               | Used for                        |
|--------------------------|--------------------------------------|---------------------------------|
| Developer pushing images | `write:packages` (+ `read:packages`) | `docker push` from a laptop     |
| Pulling a private image  | `read:packages` only                 | Not needed: the images are public |
| Cleaning up old versions | `delete:packages`                    | Deleting package versions       |

Create one under *GitHub → Settings → Developer settings → Personal access
tokens → Tokens (classic)*. If the organisation uses SSO, authorise the token
for `netbeheernederland` afterwards (*Configure SSO* next to the token).

If you use the GitHub CLI, you can add the scope to its token instead of
creating a new one:

```bash
gh auth refresh -h github.com -s write:packages
```

Inside GitHub Actions no personal token is needed: the workflow's
`GITHUB_TOKEN` pushes (section 5).

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

The rti-demo images are public, so pulling needs no login; only pushing
does.

## 4. Build and push from a developer machine

`scripts/build-rti-demo.sh` builds the images with `--load` and saves them as
tarballs. To publish the same images, push them straight from buildx. The
Dockerfiles and contexts are the ones that script uses:

| Image | Dockerfile (in the clone)                                   | Context                                      |
|-------|-------------------------------------------------------------|----------------------------------------------|
| `fsp` | `examples/rti-demo/modules/fsp/docker/Dockerfile`           | repo root                                    |
| `so`  | `examples/rti-demo/modules/so/docker/Dockerfile`            | repo root                                    |
| `dr-panel` | `examples/rti-plugins/dr_panel/docker/Dockerfile`      | `examples/rti-plugins/dr_panel`              |

Run `scripts/build-rti-demo.sh` once first: it creates the clone (default
`${TMPDIR:-/tmp}/iec61850-websocket-clone`), registers QEMU and creates the
`rti-builder` buildx builder. Then, for example for `fsp`:

```bash
CLONE_DIR="${TMPDIR:-/tmp}/iec61850-websocket-clone"
REGISTRY="ghcr.io/netbeheernederland/iec61850-websocket"
SHA="$(git -C "${CLONE_DIR}" rev-parse --short=7 HEAD)"

docker buildx build --builder rti-builder --platform linux/arm64/v8 \
  -f "${CLONE_DIR}/examples/rti-demo/modules/fsp/docker/Dockerfile" \
  -t "${REGISTRY}/rti-fsp:latest" \
  -t "${REGISTRY}/rti-fsp:sha-${SHA}" \
  --label org.opencontainers.image.source=https://github.com/netbeheernederland/iec61850-websocket \
  --annotation "index:org.opencontainers.image.source=https://github.com/netbeheernederland/iec61850-websocket" \
  --push "${CLONE_DIR}"
```

For `dr-panel`, use its Dockerfile and
`"${CLONE_DIR}/examples/rti-plugins/dr_panel"` as the context, and tag it
`${REGISTRY}/dr-panel` (a plugin keeps its own name, without `rti-`).

The `org.opencontainers.image.source` label/annotation **links the package to
the upstream repository**. A linked package shows up on the repo's page and
can inherit the repo's access settings; without it the package belongs only
to the organisation and must be shared by hand.

> Already have the image loaded locally (after `build-rti-demo.sh`)? Then
> tagging and pushing is enough. `scripts/retag-images.sh` adds the GHCR
> names (`latest`, plus `--tag sha-…` if given) to every local
> `rti-*` image, or just the ones you name, and prints the push commands:
>
> ```bash
> scripts/retag-images.sh --tag "sha-${SHA}" fsp
> docker push ghcr.io/netbeheernederland/iec61850-websocket/rti-fsp:latest
> docker push ghcr.io/netbeheernederland/iec61850-websocket/rti-fsp:sha-${SHA}
> ```
>
> It shows each image's architecture: check it before pushing over
> `latest`. The package is then not linked to the repo; link it once in the
> package settings (*Connect repository*).
>
> `scripts/push-rti-demo.sh` pushes multi-platform images in one go, from
> the amd64 and arm64 archives `build-rti-demo.sh` writes. Each platform is
> pushed as `<tag>-amd64` and `<tag>-arm64`, then combined into one
> multi-platform `latest` (and `--tag`), so `docker pull` picks the machine's
> own platform. It checks the architecture inside every archive and that you
> are logged in to `ghcr.io` before it pushes anything:
>
> ```bash
> scripts/push-rti-demo.sh --dry-run --tag "sha-${SHA}"   # show what would be pushed
> scripts/push-rti-demo.sh --tag "sha-${SHA}" fsp so      # push two images
> scripts/push-rti-demo.sh --no-latest --tag test hmi     # leave latest alone
> scripts/push-rti-demo.sh --platform arm64 hmi           # one platform only
> ```
>
> Keep the `-<arch>` tags: the multi-platform tags point at them. The
> combined image is a Docker manifest list, which can't carry the
> `org.opencontainers.image.source` annotation, so link each package to the
> repo once by hand (*Connect repository*).

## 5. Build and push with GitHub Actions (upstream)

The upstream repository, `netbeheernederland/iec61850-websocket`, builds and
pushes the images with `.github/workflows/images.yml` (upstream decision
0047). Pushing by hand (section 4) still works, but the next CI build of the
same image replaces its `latest`.

| | |
|---|---|
| Runs on | a push to `main`, a `v*` tag, a pull request, or by hand (*Run workflow*) |
| Pushes | on `main`, a tag and a manual run; a pull request only builds |
| Builds | only the images whose files changed; all six on a tag or by hand |
| Images | `rti-fsp`, `rti-so`, `rti-bff`, `rti-hmi`, `dr-panel`, `dr-leds`, each for `linux/amd64` and `linux/arm64` |
| Tags | `main` and `latest` on `main`, `<version>` on a tag, `sha-<full commit>` on every push |
| Labels | the OCI labels (title, description, vendor, source, revision) on every image |

Notes:

* CI tags a commit as `sha-<full commit>`, not `sha-<7 chars>` as the
  `push-rti-demo.sh --tag` examples do; pin with the tag the registry shows
  (section 8).
* An image whose files didn't change keeps its previous `latest`, which may
  still be one pushed by hand; *Run workflow* rebuilds and pushes all six.
* A package first pushed by hand needs the upstream repository to have write
  access to it, once: *package → Package settings → Manage Actions access →
  Add repository → Role: Write*. Otherwise the push fails with
  `403 Forbidden`.

## 6. Package visibility

The rti-demo images are **public**: anyone can pull them without logging
in. They contain no keys or certificates; those are mounted or generated at
start.

A package pushed for the first time is **private**, so make each new one
public once under *Organisation → Packages → `<package>` → Package settings
→ Danger zone → Change visibility*. A private package needs a
`read:packages` token on every machine that pulls it (section 3).

## 7. Getting GHCR images onto the Pis

### 7a. Offline Pis: pull on the build host, then deploy tarballs as usual

This keeps ADR 0003's model and the existing scripts. Instead of building, pull
the arm64 images and write the archives `deploy-rti-demo.sh` expects, under the
local names the compose files use. `scripts/pull-rti-demo.sh` does this:

```bash
scripts/pull-rti-demo.sh                        # fsp, so, dr-panel and dr-leds, tag latest
scripts/pull-rti-demo.sh --tag sha-1a2b3c4 fsp  # one image, pinned build
scripts/deploy-rti-demo.sh --start --role so 192.168.100.97
```

It also checks that each pulled image is arm64. Of the plugins it pulls
`dr-leds`, which every role runs, and `dr-panel`, which so runs by default.
(`dr-panel` replaces the published `rti-io`, the IO server from before it
became the plugin `dr_panel`, which the role compose files no longer use.)
For a Pi that is not flashed
yet, `setup/pi-user-data.sh --role so|fsp` writes the same archives into a
new Pi image instead, and the Pi starts them on first boot (see
[setup/README.md](../setup/README.md#writing-an-image-to-an-sd-card-or-ssd)).

By hand, the same steps are:

```bash
REGISTRY="ghcr.io/netbeheernederland/iec61850-websocket"
LOCAL="netbeheernederland/iec61850-websocket"
OUT="dist/rti-images-arm64"
TAG="latest"            # or sha-<commit> to pin a build
mkdir -p "${OUT}"

for image in rti-fsp rti-so dr-panel dr-leds; do
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

No login is needed: the images are public. In `~/rti` (where `deploy-rti-demo.sh` or the first boot puts the compose
file), for the role's base image (`so`: `rti-so`; `fsp`: `rti-fsp`) and
the plugins it runs (by default `so`: `dr-panel dr-leds`; `fsp`: `dr-leds`):

```bash
REGISTRY="ghcr.io/netbeheernederland/iec61850-websocket"
LOCAL="netbeheernederland/iec61850-websocket"

for image in rti-so dr-panel dr-leds; do
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
docker buildx imagetools inspect ghcr.io/netbeheernederland/iec61850-websocket/rti-fsp:latest

# All versions of a package (organisation-owned)
gh api /orgs/netbeheernederland/packages/container/iec61850-websocket%2Frti-fsp/versions \
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
  /orgs/netbeheernederland/packages/container/iec61850-websocket%2Frti-fsp/versions/<version-id>
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
        image: [rti-fsp, rti-so, dr-panel]
    steps:
      - uses: actions/delete-package-versions@v5
        with:
          package-name: iec61850-websocket/${{ matrix.image }}
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
| `denied: denied` / `unauthorized` on pull                      | The package is still private (section 6), or a stale login: `docker logout ghcr.io` and pull again.                      |
| `403 Forbidden` on push from Actions                           | Workflow lacks `permissions: packages: write`, or the repo has no write access to an existing package (section 5).       |
| `invalid reference format: repository name must be lowercase`  | Owner written as `NetbeheerNederland`; GHCR names must be lower case.                                                    |
| `pull access denied for netbeheernederland/…` on `compose up` | The GHCR image was pulled but not re-tagged to the local name the compose file uses (section 7).                         |
| `exec format error` when a container starts                    | The image is amd64; rebuild or pull with `linux/arm64/v8`.                                                               |
| Pi starts an old version after pulling                         | `load-and-start.sh` re-loaded old `*.tar.gz` archives in `~/rti` (section 7b).                                           |
