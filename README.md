# SquadRules containers

Container images for [SquadRules](https://github.com/SquadRules), built **from the
published [`@squadrules/mcp`](https://www.npmjs.com/package/@squadrules/mcp) npm
package** — never from source.

This repository exists to **decouple the container image from the npm release**. The
application source, tests, and npm publication live in [`SquadRules/mcp`](https://github.com/SquadRules/mcp);
this repo only packages an already-released version into a signed, scanned, multi-arch
image. An image / OS / library CVE therefore can never block an npm release or a code
merge in the application repo. It mirrors the earlier extraction of the Helm chart into
[`SquadRules/charts`](https://github.com/SquadRules/charts).

## Images

| Image | References |
|---|---|
| `docker.io/squadrules/mcp` | `:<version>`, plus `latest`, `:<major>`, `:<major>.<minor>` for stable releases |
| `quay.io/${QUAY_NAMESPACE}/mcp` | same tags as Docker Hub |

Both are multi-arch (`linux/amd64`, `linux/arm64`) and signed with
[`cosign`](https://docs.sigstore.dev/cosign/overview/) keyless (Fulcio OIDC).

## Runtime modes

The image bakes **no mode-selecting environment**. Its `CMD` is the `squadrules serve`
entrypoint, whose transport default is `stdio`, so the container environment alone decides
what the process becomes:

| | SIMPLE (default) | CLUSTER |
|---|---|---|
| trigger | empty environment | any override, e.g. `TRANSPORT_TYPE=http` |
| transport | stdio JSON-RPC on stdin/stdout | HTTP: UI, `/api`, `/mcp`, `/health`, metrics |
| vector store | embedded LanceDB under `~/.config/squadrules/lancedb` | Qdrant (`QDRANT_URL`) |
| key/value store | not used | Redis (`KEY_VALUE_STORE_URL`) |
| auth | off (stdio is a local, single-user pipe) | Keycloak OIDC (`AUTH_ENABLED=true`) |
| embeddings | local, key-free fastembed (weights baked in) | same, or `EMBEDDING_PROVIDER=openai` |

**SIMPLE** — nothing to configure, and nothing to publish: a stdio server opens no listener.
`-i` is required (MCP frames travel over stdin/stdout) and `--init` is recommended, because
`squadrules serve` spawns the server as a child rather than `exec`ing it, so PID 1 would not
forward `SIGTERM`:

```sh
docker run -i --rm --init docker.io/squadrules/mcp:latest
```

The mode guards are fail-fast, not silent: `QDRANT_URL` set while the transport resolves to
`stdio` aborts startup ("`TRANSPORT_TYPE=stdio` is local simple mode and must use the embedded
LanceDB store"), as does `AUTH_ENABLED=true` under stdio. An empty `QDRANT_URL` with
`TRANSPORT_TYPE=http` is *not* a violation — that combination is what the CLUSTER smoke test
above runs, and it selects the embedded store through the environment override.

**CLUSTER** — every setting is an environment override. `TRANSPORT_TYPE=http` alone already
gives a containerised server with the embedded vector store, which is enough for a single-pod
install:

```sh
docker run -d --name squadrules-mcp --init \
  -p 127.0.0.1:3000:3000 \
  -e TRANSPORT_TYPE=http \
  -e AUTH_ENABLED=false \
  docker.io/squadrules/mcp:latest
```

A full cluster deployment (Qdrant + Redis + Keycloak) with a read-only root filesystem:

```sh
docker run -d --name squadrules-mcp --init \
  -p 127.0.0.1:3000:3000 -p 127.0.0.1:9090:9090 \
  -e TRANSPORT_TYPE=http \
  -e QDRANT_URL=http://qdrant:6333 \
  -e QDRANT_COLLECTION=squadrules \
  -e KEY_VALUE_STORE_URL=redis://redis:6379 \
  -e AUTH_ENABLED=true \
  -e KEYCLOAK_URL=https://id.example.com \
  -e KEYCLOAK_REALM=squadrules \
  -e KEYCLOAK_CLIENT_ID=squadrules-mcp \
  -e AUTH_CALLBACK_BASE_URL=https://mcp.example.com \
  -e SESSION_SECRET="$(openssl rand -hex 32)" \
  --read-only --tmpfs /tmp \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -v squadrules-data:/home/node/.config/squadrules \
  docker.io/squadrules/mcp:latest
```

`/home/node/.config/squadrules` (uid/gid 1000) is the only writable path the server needs,
for the embedded LanceDB store and local artifacts; the baked model lives in read-only
`/opt/squadrules/models`, deliberately outside that tree so mounting the config directory can
never shadow the weights. Kubernetes deployments get their probes, volumes and security
context from [`SquadRules/charts`](https://github.com/SquadRules/charts) — the image's
`HEALTHCHECK` is for Docker/Podman and is ignored by the kubelet.

### Baked embedding model

The zero-config embedding backend (fastembed) would otherwise download ONNX weights on first
use — impossible on a read-only root filesystem or an air-gapped node, and it is the reason a
cold `/health` takes ~2 minutes. The build fetches them once into the image via fastembed's
own `retrieveModel()`, using the model id **read from the installed package**, so the baked
layout is exactly what the app looks for and the image is self-contained: users pull once
instead of running a StatefulSet or re-downloading at every boot. This is safe to freeze
because weight content is static — the `Qdrant/bge-*-onnx-Q` repos have not changed since
their 2024 conversion, the only 2026 commit was an Apache-2.0 → MIT license metadata change —
and the weights are MIT. If the bake ever fails, the build warns and falls back to the runtime
download rather than blocking publication; the pipeline's baked-model assertion is the hard
gate.

### Limitations

* **No npm inside the container.** The npm CLI and its bundled library tree are deleted from
  the runtime stage (they exist only to install packages at build time, and the server never
  spawns processes — shell challenges are executed by the agent on its own host). That removes
  the largest CVE surface of a Node image and any "install something from the registry at
  runtime" primitive. Consequence: `npm ls`, `npm outdated` and `squadrules update` do not work
  inside the container; upgrade by rebuilding the image at a new `PACKAGE_VERSION`.
* **`SIGTERM` needs `--init`** (or `shareProcessNamespace: true` in Kubernetes), as described
  above.
* The image is ~1.5 GB, dominated by `onnxruntime-node` (~208 MB unpacked), LanceDB's native
  bindings and the model weights. Debian `bookworm-slim` rather than Alpine is required by
  onnxruntime-node, which ships glibc-only binaries.

## Build contract

[`mcp/Dockerfile`](mcp/Dockerfile) is a pure packaging Dockerfile — three stages, no source:

1. `deps` — pinned `node:24-bookworm-slim@sha256:…`; a synthetic npm root that installs
   `@squadrules/mcp@${PACKAGE_VERSION}` at an exact version with the published package's own
   security `overrides` read back from the registry (npm applies `overrides` only to the root
   project being installed), plus `npm install --omit=dev --ignore-scripts`.
2. `model` — bakes the local embedding model the installed package defaults to.
3. `os-base` — the same pinned digest, `apt-get upgrade` and `libgomp1` (for the ONNX CPU
   provider) in one layer.
4. `runtime` — `FROM os-base`, the installed `node_modules` and baked weights copied in, npm
   deleted, two non-mode-affecting `ENV` values, the built-in `node` user (uid/gid **1000**,
   which is what `SquadRules/charts` enforces with `runAsUser: 1000`), a mode-aware
   `HEALTHCHECK`, OCI labels, and `CMD ["node","…/dist/cli/index.js","serve"]`.

`PACKAGE_VERSION` is a required build arg. The application content is fully determined by the
published npm version, so the same version always produces the same node_modules tree.

### OS CVE policy

A digest pin freezes a Debian snapshot, so pinning alone is not OS remediation: the `os-base`
stage runs `apt-get upgrade`, which closes every finding Debian has already fixed (seven
`perl-base` CVEs today). What is left — findings in `affected`, `fix_deferred` or `will_not_fix`
state — cannot be closed from inside the image, and is accepted in [`.trivyignore`](.trivyignore)
with a rationale, the affected package names, and an `exp:` review date that
[`scripts/ci-check-trivyignore-expiry.py`](scripts/ci-check-trivyignore-expiry.py) enforces. The
practical effect: **the gate blocks what is actionable and time-boxes what is not.** When Debian
ships one of those fixes, the entry expires (or the finding changes state and the next scan
fails), and the build picks it up through the upgrade layer without any edit.

`os-base` is a named stage precisely so the security workflow can build and scan it
(`docker buildx build --target os-base`) instead of reconstructing the apt line from greps — the
coupling that made the old Alpine version of that job brittle.

## Pipeline

[`.github/workflows/build-publish.yml`](.github/workflows/build-publish.yml) — the image
pipeline. Triggers:

- **`schedule` (hourly)** — reconciliation against npm `latest`. No-op when the tag already
  exists.
- **`workflow_dispatch`** — manual build for an explicit `version` (or latest), with `force`
  and `dry-run` flags.
- **`pull_request`** — build + smoke-test + scan **only** (no publish) to gate
  Dockerfile/`.trivyignore` changes.

Steps: resolve version → `docker buildx build` (multi-arch OCI, `--provenance=false
--sbom=false` so the built digest can be re-pushed verbatim) → per-arch `skopeo` extract and
`docker load` → [`scripts/ci-smoke-image.sh`](scripts/ci-smoke-image.sh) (package version,
baked model present, **SIMPLE** MCP `initialize`/`tools/list` handshake over stdio with an
empty environment, **CLUSTER** `TRANSPORT_TYPE=http` `/health` with the expected backend and a
graceful `SIGTERM` stop) → Trivy `CRITICAL,HIGH` per arch (`.trivyignore`) → unfiltered SPDX
SBOM per arch uploaded as a workflow artifact → `skopeo copy` to both registries →
`cosign sign`/`verify` → promote aliases.

[`.github/workflows/security.yml`](.github/workflows/security.yml) — `.trivyignore` expiry
guard, plus a Trivy scan of the `os-base` stage (`vuln-type: os`, CRITICAL,HIGH, `.trivyignore`)
that auto-remediates by bumping the pinned base digest — which is how a newer Node patch release
gets pulled in (PR flow commits to the branch; schedule/push flow opens an auto-merge PR).

## Required configuration

Secrets (repo → Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub push |
| `QUAY_USERNAME` / `QUAY_PASSWORD` | quay.io push |

Variables:

| Variable | Purpose |
|---|---|
| `QUAY_NAMESPACE` | quay.io namespace (validated `^[a-z0-9][a-z0-9_-]+$`) |

`cosign` keyless signing needs no secret; it uses the workflow's OIDC identity
(`id-token: write`) and verifies against `https://github.com/${GITHUB_WORKFLOW_REF}`.

## Verifying an image

```sh
cosign verify \
  --certificate-identity "https://github.com/SquadRules/containers/.github/workflows/build-publish.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  docker.io/squadrules/mcp:<version>
```

## Architecture decisions

Architecturally significant decisions are recorded as [Architecture Decision
Records (ADRs)](docs/adr/). Each ADR captures the context, the decision, and the
consequences (trade-offs, follow-ups, constraints). New ADRs are added as the
project evolves; superseded ADRs are marked `deprecated` and linked forward.

Current ADRs:

- [0001](docs/adr/0001-node24-bookworm-slim-base.md) — Node 24 LTS on Debian bookworm-slim as the base image
- [0002](docs/adr/0002-simple-by-default-runtime.md) — SIMPLE-by-default runtime contract
- [0003](docs/adr/0003-digest-pin-plus-upgrade-layer.md) — Digest pin plus apt-get upgrade layer and expiring-ignore risk register
- [0004](docs/adr/0004-baked-embedding-model.md) — Baked ONNX embedding model
- [0005](docs/adr/0005-npm-cli-removed-from-runtime.md) — npm CLI removed from the runtime image
- [0006](docs/adr/0006-mode-aware-healthcheck.md) — Mode-aware healthcheck
- [0007](docs/adr/0007-sboms-as-artifacts.md) — SPDX SBOMs as CI artifacts, not registry attachments
- [0008](docs/adr/0008-os-base-scan-target.md) — OS base scan target

## Repository provisioning

This repo is declared as code in
[`jakub-plichcinski/iac-github`](https://github.com/jakub-plichcinski/iac-github)
(`live/repos/squadrules/terragrunt.hcl`). Branch protection is added in a second IaC pass
once the `Container image pipeline passed` check has reported on `main`.

## License and trademark

The packaged application is distributed under the license and trademark terms in
[`SquadRules/mcp`](https://github.com/SquadRules/mcp). This repository contains only
packaging/CI.
