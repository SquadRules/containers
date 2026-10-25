# SquadRules containers

Container packaging for [`@squadrules/mcp`](https://www.npmjs.com/package/@squadrules/mcp).
This repository holds no application source — it packages the already-published npm artifact
into a multi-arch, signed image.

```
docker.io/${DOCKER_NAMESPACE}/${IMAGE_NAME}
quay.io/${QUAY_NAMESPACE}/${IMAGE_NAME}
```

Tags: `<version>`, `<major>.<minor>`, `<major>`, `latest`. Platforms: `linux/amd64`,
`linux/arm64`. Both registries receive the identical manifest index, so a tag resolves to the
same digest everywhere.

## Running it

With no environment at all, the container is a self-contained HTTP server on port 3000 — UI,
`/api`, `/mcp`, `/health`, metrics on 9090 — backed by embedded LanceDB and a local key-free
embedding model baked into the image. No external services, no auth.

```sh
docker run --init -p 3000:3000 ${DOCKER_NAMESPACE}/${IMAGE_NAME}:latest
```

`--init` matters: `serve` spawns the server as a child rather than exec'ing it, so without an
init process SIGTERM is not forwarded and `docker stop` waits out the grace period. In
Kubernetes use `shareProcessNamespace` instead; `SquadRules/charts` already sets
`runAsUser: 1000`, which matches the image's `node` user.

For a full cluster, turn on OIDC and point at external stores:

```sh
docker run --init -e AUTH_ENABLED=true \
  -e QDRANT_URL=... -e KEY_VALUE_STORE_URL=... -e KEYCLOAK_URL=... \
  ${DOCKER_NAMESPACE}/${IMAGE_NAME}:latest
```

Everything is env-overridable. `TRANSPORT_TYPE` defaults to `http` and `AUTH_ENABLED` to
`false`; under `http` the app would otherwise default auth to on and refuse to boot without
Keycloak, so the image pins it off.

Cold start is slow — roughly 110s on an arm64 laptop. `/health` only answers after startup has
injected the bundled adapters, which is CPU-bound ONNX inference over the baked model. The
image `HEALTHCHECK` carries `--start-period=180s` for that reason. Kubernetes ignores it; pod
probes belong to the chart.

## How a release happens

There is no version file, no marker, no release-please and no scheduled poll. The image version
*is* the `@squadrules/mcp` pin in `package.json`, and Dependabot owns it:

```
Dependabot npm PR  ->  merge to main  ->  build  ->  verify  ->  publish  ->  sign
```

Merging a bump touches a path in `image.yml`'s push filter and publishes. Merging anything else
— a workflow edit, a README change — touches no filtered path and publishes nothing. That filter
is the entire release-isolation mechanism. Manual workflow dispatch (`workflow_dispatch`) is also
restricted to the `main` branch, so selecting another branch cannot accidentally overwrite
published tags.

Dependabot also owns the `node:24-bookworm-slim` digest pin and every action version. It cannot
manage a Dockerfile `ARG` ([dependabot-core#2057](https://github.com/dependabot/dependabot-core/issues/2057)
is still open), which is precisely why the version lives in `package.json` and the Dockerfile has
zero required build args.

## Pipeline

`.github/workflows/image.yml`, two jobs:

- **build** — runs on every PR and every image-affecting push. Builds `linux/amd64`, asserts the
  packaged version and that the model bake landed, boots the container and waits on `/health`,
  scans with Trivy, and uploads an SPDX SBOM as an artifact. Never touches a registry.
- **publish** — runs only after a push to main. Builds both architectures, pushes the one index
  to both registries in a single `build-push-action` call, then signs and verifies with cosign
  keyless (Fulcio OIDC — no private key, no registry signing secret).

Trivy runs with `ignore-unfixed: true`, so it fails only on CRITICAL/HIGH findings Debian has
actually fixed. A Dependabot base-digest bump is that fix. This is what replaced the old
`.trivyignore` file and its expiry-governance tooling: findings with no upstream fix are skipped
by construction rather than tracked in a file that needed a validator.

The Dockerfile carries no `LABEL` instructions. `docker/metadata-action` emits the OCI label set
(`title`, `description`, `url`, `source`, `version`, `created`, `revision`, `licenses`) from the
repository at build time, so hand-writing them only invited drift. `vendor` and `licenses` are
supplied explicitly in the workflow.

There are no scripts in this repository. The only shell is four inline lines per job that read
the version out of `package.json`.

## Credentials

Repo-level, all pre-existing:

| Name | Kind | Used for |
|---|---|---|
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | secret | docker.io push |
| `QUAY_USERNAME` / `QUAY_PASSWORD` | secret | quay.io push |
| `DOCKER_NAMESPACE` | variable | docker.io namespace (e.g., `squadrules`) |
| `QUAY_NAMESPACE` | variable | quay.io namespace (e.g., `squadrules`) |
| `IMAGE_NAME` | variable | image name across both registries (e.g., `mcp`) |

`QUAY_USERNAME` must be a robot account, formatted `namespace+robotname`, holding the `write`
role on `<QUAY_NAMESPACE>/<IMAGE_NAME>`. Quay's `qro_`-prefixed Robot API token is a different credential
with a separate lifecycle and will not authenticate a push.

No org-level secrets and no GitHub App token are used.

## Verifying an image

```sh
cosign verify \
  --certificate-identity-regexp '^https://github\.com/SquadRules/containers/\.github/workflows/image\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/${DOCKER_NAMESPACE}/${IMAGE_NAME}:<version>

docker buildx imagetools inspect docker.io/${DOCKER_NAMESPACE}/${IMAGE_NAME}:<version>
```

The identity is pinned to this workflow's ref on `main`, so an image signed by a fork, a branch
or any other workflow fails verification. Note that this regexp changed when the pipeline was
rewritten — anything still checking the old `build-publish.yml@refs/heads/main` identity must be
updated.

## Building locally

```sh
docker build -t ${DOCKER_NAMESPACE}/${IMAGE_NAME}:local .
```

No build args. Node 24 on Debian bookworm-slim is required rather than Alpine because
`onnxruntime-node` ships glibc-only binaries. `libgomp1` is installed for the same reason — it
backs the onnxruntime CPU execution provider. The install runs with `--ignore-scripts`: the only
install hook in the tree is `onnxruntime-node`'s postinstall, which downloads CUDA provider
binaries on linux/x64, and the CPU binaries are already bundled in the tarball. Skipping it keeps
unused GPU libraries out of the image. The npm CLI is then deleted, so `npm ls` and
`squadrules update` are unavailable inside the container.

### The baked model

The build downloads the default embedding model into `FASTEMBED_CACHE_DIR=/opt/squadrules/models`
(~65 MB), so a zero-env boot needs no Hugging Face egress and pays no first-request latency.

- The model id is read from the installed `@squadrules/mcp/dist/config.js` at build time, never
  hardcoded, so the baked layout cannot drift from what the application looks for.
- The cache lives outside `~/.config/squadrules` on purpose: mounting that directory to persist
  the embedded LanceDB store cannot shadow the weights.
- A failed bake warns and the build continues. A Hugging Face outage must not block publication —
  the runtime simply re-downloads the weights on first use.

The `# check=skip=SecretsUsedInArgOrEnv` directive at the top of the Dockerfile silences one
BuildKit lint false positive: the rule matches the `AUTH` substring in `AUTH_ENABLED`, which is a
boolean rather than a credential. Every other lint check stays enabled.

## Related repositories

- [`SquadRules/mcp`](https://github.com/SquadRules/mcp) — application source and npm publish
- [`SquadRules/charts`](https://github.com/SquadRules/charts) — Helm chart, pod probes, `runAsUser`
