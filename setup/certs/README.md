# Test Certificates

This directory holds the **cfssl configuration** used to mint the local
CA + server/client TLS certificates:

| file               | purpose                                  |
| ------------------ | ---------------------------------------- |
| `ca-config.json`   | signing profiles (`server`, `client`)   |
| `ca-csr.json`      | root CA subject                          |
| `server-csr.json`  | server certificate subject / key        |
| `client-csr.json`  | client certificate subject / key        |
| `generate.sh`      | host-side generation (needs cfssl)      |

The generated `*.pem` / `*.csr` files are **not** committed (see `.gitignore`).

## Generating certificates

### With Docker (recommended)

The `cert-generator` service in `../docker-compose.yml` installs `cfssl`, runs
the same steps as `generate.sh`, and writes the results into the shared `certs`
volume. Every other service mounts that volume read-only at `/certs`.

For the per-VM `setup/` workflow, `../render.sh` reuses these same cfssl config
files (via `CERTS_SRC`) to mint the fleet's certificates.

```bash
docker compose up cert-generator      # one-off
docker compose up                     # runs automatically as a dependency
```

It is idempotent — if the `certs` volume already contains `ca.pem`,
`server.pem` and `client.pem` it does nothing. To force a fresh set:

```bash
docker compose down
docker volume rm rti-demo_certs
docker compose up cert-generator
```

Add or change SANs via the `SERVER_HOSTNAMES` env var:

```bash
SERVER_HOSTNAMES=localhost,127.0.0.1,rti-hmi,bff-server,extra-host docker compose up cert-generator
```

### On the host

```bash
./generate.sh                         # requires cfssl + cfssljson on PATH
```
