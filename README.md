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
| `docker.io/squadrules/mcp` | `:<version>`, plus `latest`, `:<major>`, `:<major>.<minor>` for stable releases; a prerelease `X.Y.Z-<channel>.N` publishes only the `<channel>` tag |
| `quay.io/${QUAY_NAMESPACE}/mcp` | same tags as Docker Hub |

Both are multi-arch (`linux/amd64`, `linux/arm64`) and signed with
[`cosign`](https://docs.sigstore.dev/cosign/overview/) keyless (Fulcio OIDC).

## Runtime modes

The image is an **HTTP server**: `TRANSPORT_TYPE=http` and `AUTH_ENABLED=false` are baked in, so
an environment-less `docker run` boots a self-contained server with no external dependencies.
Every setting is still an environment override, so the same image also covers a full
authenticated cluster:

| | default (zero env) | full cluster |
|---|---|---|
| trigger | empty environment | `AUTH_ENABLED=true` + external stores |
| transport | HTTP: UI, `/api`, `/mcp`, `/health`, metrics | HTTP |
| vector store | embedded LanceDB under `~/.config/squadrules/lancedb` | Qdrant (`QDRANT_URL`) |
| key/value store | not used | Redis (`KEY_VALUE_STORE_URL`) |
| auth | off | Keycloak OIDC |
| embeddings | local, key-free fastembed (weights baked in) | same, or `EMBEDDING_PROVIDER=openai` |
| reach it | publish `-p 3000:3000` | publish `-p 3000:3000` |

**Default (zero env)** — a self-contained HTTP server on `:3000` backed by embedded LanceDB and
the local fastembed model, auth off. `--init` is recommended because `squadrules serve` spawns the
server as a child rather than `exec`ing it, so PID 1 would not forward `SIGTERM`:

```sh
docker run -d --name squadrules-mcp --init \
  -p 127.0.0.1:3000:3000 \
  docker.io/squadrules/mcp:latest
# → http://localhost:3000/health  (no configuration required)
```

> The default is **unauthenticated** and binds `:3000`. That is deliberate for a standalone
> single-container install (it matches the embedded store and baked model). Do not expose the port
> publicly without either `-e AUTH_ENABLED=true` plus the OIDC variables below, or an
> authenticating reverse proxy in front.

**Full cluster** — Qdrant + Redis + Keycloak with a read-only root filesystem. `TRANSPORT_TYPE` is
already `http` by default, so it is omitted here (set it explicitly only to override):

```sh
docker run -d --name squadrules-mcp --init \
  -p 127.0.0.1:3000:3000 -p 127.0.0.1:9090:9090 \
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
use — impossible on a read-only root filesystem or an air-gapped node, and the reason an
unbaked cold boot was measured at ~2 minutes. With the weights baked in, a `linux/arm64` cold
boot answered `/health` in **~50 s** (single sample, Apple Silicon host). The build fetches them
once into the image via fastembed's
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
* The image is **~1.2 GB** (`docker images`, linux/arm64 build of the current Dockerfile). Measured
  in place: `/app/node_modules` ~530 MB — of which `onnxruntime-node` is ~208 MB and LanceDB's
  native bindings ~137 MB — the Debian base under `/usr` ~223 MB, and the baked model ~65 MB. The
  ~1.5 GB figure recorded in [ADR-0004](docs/adr/0004-baked-embedding-model.md) predates the
  small-model default, when the baked weights were ~209 MB. Debian `bookworm-slim` rather than
  Alpine is required by onnxruntime-node, which ships glibc-only binaries.

## Build contract

[`mcp/Dockerfile`](mcp/Dockerfile) is a pure packaging Dockerfile — four named stages
(`deps` → `model` → `os-base` → `runtime`), no source:

1. `deps` — pinned `node:24-bookworm-slim@sha256:…`; a synthetic npm root that installs
   `@squadrules/mcp@${PACKAGE_VERSION}` at an exact version with the published package's own
   security `overrides` read back from the registry (npm applies `overrides` only to the root
   project being installed), plus one packaging override: `@anush008/tokenizers` is forced to
   `^0.6.0` because fastembed's `^0.0.0` resolves to a stub with no linux-arm64 binary, which
   would break the key-free local embedding path on arm64. Installed with
   `npm install --omit=dev --ignore-scripts`.
2. `model` — bakes the local embedding model the installed package defaults to.
3. `os-base` — the same pinned digest, `apt-get upgrade` and `libgomp1` (for the ONNX CPU
   provider) in one layer.
4. `runtime` — `FROM os-base`, the installed `node_modules` and baked weights copied in, npm
   deleted, `ENV` defaults that make a zero-env container an HTTP server (`TRANSPORT_TYPE=http`,
   `AUTH_ENABLED=false`, plus `NODE_ENV` and `FASTEMBED_CACHE_DIR`), the built-in `node` user
   (uid/gid **1000**, which is what `SquadRules/charts` enforces with `runAsUser: 1000`), an
   HTTP `/health` `HEALTHCHECK`, OCI labels, and `CMD ["node","…/dist/cli/index.js","serve"]`.

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

- **`schedule` (daily, 04:17 UTC)** — reconciliation against npm `latest`. No-op only when the
  tag exists in **both** registries; a tag present on docker.io but missing on quay.io is
  reported as a partial publish and the run continues so quay.io catches up.
- **`workflow_dispatch`** — manual build for an explicit `version` (or latest), with `force`
  and `dry-run` flags.
- **`pull_request`** — build + smoke-test + scan **only** (no publish) to gate
  Dockerfile/`.trivyignore` changes.

Steps: resolve version (semver validated; the `publish` and `skip` outputs gate every
downstream job) → `docker buildx build` (multi-arch OCI, with GitHub-Actions layer caching at
`mode=max` so the base-image, `npm install` and model-bake layers are reused across PRs and the
daily run; `--provenance=false --sbom=false` so the built digest can be re-pushed verbatim) →
per-arch `skopeo` extract and `docker load` → [`scripts/ci-smoke-image.sh`](scripts/ci-smoke-image.sh) →
Trivy `CRITICAL,HIGH` per arch (`.trivyignore`) → unfiltered SPDX SBOM per arch uploaded as a
workflow artifact → publish to both registries → verify the published tags resolve.

The script has three legs. Legs 1 and 2 run identically on both architectures (the package
version inside the image matches the npm version it was built from; the embedding model is
baked in). Leg 3 diverges: **amd64** boots the **zero-env default** and asserts `/health` answers
`status=healthy` on `transport=http` with the `embedded-lancedb` backend, then stops gracefully on
`SIGTERM`; **arm64** runs under QEMU on the x86 runner, where that same boot would spend 45+
minutes on emulated ONNX inference, so `SMOKE_SKIP_HEALTH=1` replaces it with a `require()` check
that `onnxruntime-node` and `@lancedb/lancedb` load on the target arch — the actual packaging
risk, since npm optional platform dependencies are per-arch.

Publishing treats **each registry as an independent atomic unit**: push the immutable version tag
(`skopeo copy --all --preserve-digests`), `cosign sign` and `cosign verify` that digest, then
promote the channel aliases by copying the same digest. One registry failing no longer aborts the
other — which previously left docker.io holding an unsigned version tag with no aliases whenever
quay.io failed — though the step still exits non-zero if any registry failed, so branch
protection is preserved. A pre-flight probe of the quay.io tag list raises a warning before the
loop, because a missing repository and a missing permission are otherwise indistinguishable from
an opaque push error.

[`.github/workflows/security.yml`](.github/workflows/security.yml) — `.trivyignore` expiry
guard, plus a Trivy scan of the `os-base` stage (`vuln-type: os`, CRITICAL,HIGH, `.trivyignore`)
that auto-remediates by bumping the pinned base digest — which is how a newer Node patch release
gets pulled in (PR flow commits to the branch; schedule/push flow opens an auto-merge PR). The OS
layer is built straight from the Dockerfile with `--target os-base` rather than re-assembled from
grepped lines, so the job cannot drift from what ships; the replacement digest is resolved as the
multi-arch **manifest index** digest via `docker buildx imagetools inspect` (a per-platform digest
would break the other architecture), and the bumped layer is rescanned before anything is
committed.

Both workflows end in an aggregate job that is the branch-protection surface: `Container image
pipeline passed` and `Security workflow passed`. Neither workflow filters the `pull_request`
trigger by paths — a filter would strand non-image PRs on a required check that never runs.
The image pipeline serialises runs per ref and cancels in-progress work only for pull requests,
so a scheduled or publishing run is never cancelled mid-push; the security workflow uses a per-ref
group with `cancel-in-progress: true`, so only the latest run of a branch executes.

## Required configuration

Secrets (repo → Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub push |
| `QUAY_USERNAME` / `QUAY_PASSWORD` | quay.io push |

Variables:

| Variable | Purpose |
|---|---|
| `QUAY_NAMESPACE` | quay.io namespace. Read as-is — nothing in the pipeline validates its shape, so a wrong or unset value surfaces as the quay.io reachability warning plus a failed publish/verify step |

`cosign` keyless signing needs no secret; it uses the workflow's OIDC identity
(`id-token: write`) and verifies against `https://github.com/${GITHUB_WORKFLOW_REF}`.

## Verifying an image

```sh
cosign verify \
  --certificate-identity "https://github.com/SquadRules/containers/.github/workflows/build-publish.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  docker.io/squadrules/mcp:<version>
```

## Repository provisioning

This repo is declared as code in
[`jakub-plichcinski/iac-github`](https://github.com/jakub-plichcinski/iac-github)
(`live/repos/squadrules/terragrunt.hcl`). Branch protection is enforced on `main`
(PR-only, two required status checks: `Container image pipeline passed` and
`Security workflow passed`). Repository-level security updates are enabled through
that same IaC.

Dependabot (`.github/dependabot.yml`) tracks **GitHub Actions only**. The pinned base-image
digest is deliberately *not* given a `docker` ecosystem entry: it is owned by the
`container-base-os-trivy` job in [`.github/workflows/security.yml`](.github/workflows/security.yml),
and letting two mechanisms edit the same `FROM` line would have them fight over it.

## Architecture decisions

Architecturally significant decisions are recorded as [Architecture Decision
Records (ADRs)](docs/adr/). Each ADR captures the context, the decision, and the
consequences (trade-offs, follow-ups, constraints). New ADRs are added as the
project evolves; superseded ADRs are marked `deprecated` and linked forward.

Current ADRs:

- [0001](docs/adr/0001-node24-bookworm-slim-base.md) — Node 24 LTS on Debian bookworm-slim as the base image
- [0002](docs/adr/0002-http-by-default-runtime.md) — HTTP-by-default standalone runtime
- [0003](docs/adr/0003-digest-pin-plus-upgrade-layer.md) — Digest pin plus apt-get upgrade layer and expiring-ignore risk register
- [0004](docs/adr/0004-baked-embedding-model.md) — Baked ONNX embedding model
- [0005](docs/adr/0005-npm-cli-removed-from-runtime.md) — npm CLI removed from the runtime image
- [0006](docs/adr/0006-http-healthcheck.md) — HTTP healthcheck
- [0007](docs/adr/0007-sboms-as-artifacts.md) — SPDX SBOMs as CI artifacts, not registry attachments
- [0008](docs/adr/0008-os-base-scan-target.md) — OS base scan target

## License and trademark

The packaged application is distributed under the license and trademark terms in
[`SquadRules/mcp`](https://github.com/SquadRules/mcp). This repository contains only
packaging/CI.
