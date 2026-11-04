# Kubernetes and ArgoCD — Getting Started

This guide runs the RTI-SO and RTI-FSP on Kubernetes with Helm charts that
ArgoCD deploys from this repository. It is a third deployment target next to
the single-host `docker-compose.yml` and the per-role Pis/VMs
([ADR 0002](decisions/0002-maintain-both-a-docker-compose-and-a-vm-fleet-deployment-target.md)),
decided in [ADR 0005](decisions/0005-deploy-so-and-fsp-to-kubernetes-with-helm-and-argocd.md).

Any number of SOs and FSPs can be installed: every installation is one Helm
release with its own name, in the same namespace or spread over namespaces
and clusters. With ArgoCD, adding an installation is adding a directory.

The examples assume:

```text
Cluster:       k3s on the Pis (arm64 nodes), ArgoCD in namespace argocd
Repository:    git@github.com:netbeheernederland/iec61850-websocket-demo.git, branch main
Images:        ghcr.io/netbeheernederland/iec61850-websocket/{rti-so,rti-fsp,dr-panel}
               (see docker-images-github.md)
Namespace:     rti-demo
```

## 1. Layout

```text
deploy/
├── helm/
│   ├── rti-so/                 chart: one SO (+ optional dr-panel sidecar)
│   └── rti-fsp/                chart: one FSP for one control point (+ optional dr-panel sidecar)
│       └── models/             FSP models bundled in the chart (model_1.py, model_2.py)
├── argocd/
│   ├── bootstrap.yaml          the one Application applied by hand
│   └── apps/                   synced by bootstrap.yaml
│       ├── project.yaml        AppProject rti-demo
│       ├── rti-so.yaml         ApplicationSet: one Application per deploy/installations/so/*/
│       └── rti-fsp.yaml        ApplicationSet: one Application per deploy/installations/fsp/*/
└── installations/
    ├── so/
    │   └── demo/               -> Application and release rti-so-demo
    │       ├── installation.yaml
    │       └── values.yaml
    └── fsp/
        ├── cp1/                -> rti-fsp-cp1 (cp1, port 5001, model_1.py)
        └── cp2/                -> rti-fsp-cp2 (cp2, port 5005, model_2.py)
```

The examples mirror `setup/nodes.env`: one SO and the two FSPs `cp1` and
`cp2`.

Each installation directory holds two files:

| File                | Read by           | Contents                                                     |
|---------------------|-------------------|--------------------------------------------------------------|
| `installation.yaml` | the ApplicationSet | `destination.server` and `destination.namespace`             |
| `values.yaml`       | Helm              | values for the chart, on top of the chart's `values.yaml`    |

The directory name becomes part of the Application, release and resource
names (`rti-fsp-<name>`), so it must be a DNS label: lower case letters,
digits and `-`.

## 2. What the charts deploy

Per installation, one **Deployment** with one pod (strategy `Recreate`, so
there are never two pods of an installation, not even during a rollout) and
one **Service**. The FSP chart adds a **ConfigMap** with the model.

| Value              | rti-so                     | rti-fsp                                  |
|--------------------|----------------------------|------------------------------------------|
| `image.tag`        | `latest`                   | `latest`                                 |
| `port`             | `5000` (API)               | `5001` (ACSI server)                     |
| `websocketPort`    | `8765`                     | —                                        |
| `cp`               | —                          | `cp1`                                    |
| `model.file`       | —                          | empty: the image's built-in model        |
| `model.content`    | —                          | model source inline, instead of a bundled file |
| `service.type`     | `ClusterIP`                | `ClusterIP`                              |
| `drPanel.enabled`  | `false`                    | `false`                                  |
| `certs.secretName` | empty: no `/certs`         | empty: no `/certs`                       |
| `imagePullSecrets` | none                       | none                                     |
| `nodeSelector`     | `kubernetes.io/arch: arm64` | `kubernetes.io/arch: arm64`             |

See each chart's `values.yaml` for all values and their comments.

**dr-panel sidecar.** With `drPanel.enabled: true` the IO plugin (`dr-panel`,
formerly `rti-io`, port 9000) runs in the same pod: on the same node, and
connected as the plugin `dr_panel` at `http://localhost:9000/plugin` (plugin
API version 2, upstream decision 0029). `drPanel.settings` are its settings,
e.g. `write_inputs: false`. The dr-panel container is
privileged (GPIO, I2C, SPI) and the pod uses the host's IPC namespace. Pin the
pod to the Pi with the hardware:

```yaml
drPanel:
  enabled: true
nodeSelector:
  kubernetes.io/hostname: rti-pi5    # merged with the default kubernetes.io/arch
```

**Other plugins.** `plugins` lists more plugins to connect to, after
`dr_panel`, as `{name, url, settings}`. The chart passes them, with
`dr_panel`, to the SO or FSP
as `PLUGINS`. A plugin outside the pod writes back to `host_url`, which is
`http://localhost:<port>` unless `pluginHostUrl` is set: set it to the SO's or
FSP's address as that plugin reaches it, for example its LoadBalancer address.

```yaml
plugins:
  - name: display_st7789
    url: http://192.168.0.226:8000/plugin
    settings: {}
pluginHostUrl: http://192.168.0.226:5001
```

If the cluster enforces Pod Security Standards, label the namespace
`pod-security.kubernetes.io/enforce=privileged`. k3s does not enforce them by
default.

**FSP models.** `model.file` picks a file from `deploy/helm/rti-fsp/models/`;
the chart puts it in a ConfigMap mounted at `/models` and sets `MODELPATH`.
Helm cannot read files outside the chart, so these are copies of
`modules/fsp01/models/model_1.py` and `modules/fsp02/models/model_2.py`, like
`setup/roles/fsp/models/`. When a model changes, update the copies too. For a
model used by one installation only, put its source in that installation's
`values.yaml` as `model.content` instead (name it with `model.file`). The pod
restarts when the model changes.

**Certificates.** The compose setup mounts the cert-generator's output at
`/certs`. To do the same, create a secret with those files and set
`certs.secretName`:

```bash
kubectl -n rti-demo create secret generic rti-certs \
  --from-file=ca.pem --from-file=server.pem --from-file=server-key.pem \
  --from-file=client.pem --from-file=client-key.pem
```

## 3. Prerequisites

### 3a. ArgoCD can read this repository

The repository is public on GitHub. ArgoCD still reads it over SSH, as the
`repoURL`s say (`git@github.com:...`), and SSH needs a key even for a public
repository: give ArgoCD a read-only deploy key (*GitHub → repository →
Settings → Deploy keys → Add deploy key*, leave *Allow write access* off) and
register it. ArgoCD already trusts GitHub's SSH host keys, so no
`argocd cert add-ssh` is needed:

```bash
ssh-keygen -t ed25519 -N "" -f argocd-deploy-key -C argocd-rti-demo
# add argocd-deploy-key.pub as a deploy key on GitHub, then:
argocd repo add git@github.com:netbeheernederland/iec61850-websocket-demo.git \
  --ssh-private-key-path argocd-deploy-key
```

The repository URL appears in `deploy/argocd/bootstrap.yaml`,
`deploy/argocd/apps/project.yaml` and both ApplicationSets. Change all of them
if it moves.

### 3b. The cluster can pull the images

The images are public on GHCR, so the cluster pulls them without a pull
secret; the installations set no `imagePullSecrets`.

If you use a private registry instead (`image.repository`), create a
docker-registry secret in each installation namespace and name it in the
installation's values:

```bash
kubectl create namespace rti-demo
kubectl -n rti-demo create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<read:packages token>
```

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

The images hold amd64 and arm64; the charts schedule onto
`kubernetes.io/arch: arm64` nodes (the Pis) by default.

## 4. Bootstrap

Once, after the repository and namespace setup above:

```bash
kubectl apply -n argocd -f deploy/argocd/bootstrap.yaml
```

The `rti-demo` Application syncs `deploy/argocd/apps`: the AppProject and the
two ApplicationSets. Those create one Application per installation directory,
which sync automatically (prune and self-heal on):

```bash
argocd app list -l app.kubernetes.io/part-of=rti-demo
kubectl -n rti-demo get deploy,svc,pods
```

The AppProject allows only this repository, namespaces named `rti-*`, and the
kinds the charts create (Deployment, Service, ConfigMap, and Namespace for
`CreateNamespace=true`).

## 5. Working with installations

All changes go through Git: commit and push, and ArgoCD applies them (within
its polling interval, three minutes by default, or at once with
`argocd app sync <app>`).

**Add an FSP** for control point `cp3` with a third model:

```bash
mkdir deploy/installations/fsp/cp3
cp deploy/installations/fsp/cp2/installation.yaml deploy/installations/fsp/cp3/
cat > deploy/installations/fsp/cp3/values.yaml <<'EOF'
cp: cp3
port: 5006
model:
  file: model_3.py
  content: |
    # ... the model source ...
service:
  type: LoadBalancer
EOF
git add deploy/installations/fsp/cp3 && git commit -m "Add FSP cp3" && git push
```

The ApplicationSet creates `rti-fsp-cp3`. A second SO works the same way under
`deploy/installations/so/`.

**Put an installation elsewhere**: change `destination.namespace` (must start
with `rti-`) or `destination.server` (a cluster registered with
`argocd cluster add`) in its `installation.yaml`.

**Roll out a new image**: set `image.tag` (and `drPanel.image.tag`) to the new
`sha-<commit>` tag in `values.yaml`. With `latest`, ArgoCD sees no change and
a running pod keeps its image; pinning tags is what makes rollouts visible in
Git.

**Remove an installation**: delete its directory and push. The ApplicationSet
deletes the Application, and its finalizer deletes the Deployment, Service
and ConfigMap. The namespace and secrets stay.

## 6. Reaching the SO and FSPs

Inside the cluster, a Service per installation:

```text
http://rti-so-demo.rti-demo.svc:5000      ws://rti-so-demo.rti-demo.svc:8765
http://rti-fsp-cp1.rti-demo.svc:5001
http://rti-fsp-cp2.rti-demo.svc:5005
```

The example installations use `service.type: LoadBalancer`. On k3s, ServiceLB
then opens the port on the nodes' IPs, as the host ports do in the compose
files, so a BFF outside the cluster can keep using `host:port` entries in
`modules/bff/config/connections.json`. Each installation needs its own port
for this; that is why `cp2` uses 5005. Use `NodePort` (with
`service.nodePort`) on clusters without a load balancer.

Quick check of one installation:

```bash
kubectl -n rti-demo port-forward svc/rti-fsp-cp1 5001
curl http://localhost:5001/api/status
```

## 7. Without ArgoCD

The charts are plain Helm. Use the same release name and values as ArgoCD
would:

```bash
helm upgrade --install rti-fsp-cp1 deploy/helm/rti-fsp -n rti-demo --create-namespace \
  -f deploy/installations/fsp/cp1/values.yaml

# Render only, to review
helm template rti-so-demo deploy/helm/rti-so -n rti-demo \
  -f deploy/installations/so/demo/values.yaml
```

Do not mix this with ArgoCD for the same installation: ArgoCD's self-heal
reverts changes made outside Git.

## 8. Troubleshooting

| Symptom                                                    | Cause and fix                                                                                                         |
|------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| No Applications appear for the installations               | ArgoCD cannot read the repository (section 3a); see `kubectl -n argocd describe applicationset rti-fsp`.             |
| Application error `namespace ... is not permitted in project` | The namespace does not start with `rti-`; rename it or extend `destinations` in `project.yaml`.                     |
| Pod `ImagePullBackOff`                                     | Wrong `image.tag`, or a private registry without a pull secret in the namespace (section 3b).                          |
| Pod `Pending`, `didn't match Pod's node affinity/selector` | No arm64 node, or the `kubernetes.io/hostname` in `nodeSelector` does not match a node name (`kubectl get nodes`).   |
| `model.file "…" is not in the chart's models/ directory`   | The file is not bundled: add it to `deploy/helm/rti-fsp/models/` or give `model.content`.                             |
| Pod rejected: `violates PodSecurity "baseline"`            | dr-panel sidecar is privileged; label the namespace `pod-security.kubernetes.io/enforce=privileged`.                       |
| LoadBalancer Service stays `<pending>`                     | Two installations use the same port, or the cluster has no load balancer; use another port or `NodePort`.            |
| New image not running after pushing it to GHCR             | `image.tag` did not change (`latest`); pin `sha-<commit>`, or `kubectl -n rti-demo rollout restart deploy/<name>` with `pullPolicy: Always`. |
