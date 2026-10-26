# Contributing & CI

Maintainer documentation for the SquadRules containers packaging pipeline. For how to **run** the
image, see [README.md](README.md).

This repository holds no application source. It packages the already-published
[`@squadrules/mcp`](https://www.npmjs.com/package/@squadrules/mcp) npm artifact into a multi-arch,
scanned, signed OCI image. The image version *is* the npm pin — this repo mints no version of its
own.

## How a release happens

There is no version file, no marker, no release-please and no scheduled poll. The image version is
the `@squadrules/mcp` pin in `package.json`, and Dependabot owns it:

```
Dependabot npm PR  ->  merge to main  ->  build  ->  verify  ->  publish  ->  sign
```

Merging a bump touches a path in `image.yml`'s push filter and publishes. Merging anything else —
a workflow edit, a docs change — touches no filtered path and publishes nothing. That filter is the
entire release-isolation mechanism. Manual `workflow_dispatch` is restricted to `main`, so selecting
another branch cannot accidentally overwrite published tags.

Dependabot also owns the `node:NN-bookworm-slim` base digest and every action version. It cannot
manage a Dockerfile `ARG`
([dependabot-core#2057](https://github.com/dependabot/dependabot-core/issues/2057) is still open),
which is exactly why the version lives in `package.json` and the Dockerfile has zero required build
args.

### No GitHub Releases

This repo deliberately has **no GitHub Releases and no git tags**. For a container packaging repo the
registry tag (+ immutable digest) *is* the release, matching
[distroless](https://github.com/GoogleContainerTools/distroless/blob/main/RELEASES.md) and
[docker-library/official-images](https://github.com/docker-library/faq): version bumps are commits,
and the registry is the source of truth. Minting a separate `vX.Y.Z` release axis would drift from
the real image version (the npm pin) — the exact failure that motivated the 2026-10 reset. Provenance
lives in the registry as cosign signatures plus SBOM/provenance OCI referrers, which GitHub Releases
cannot express.

## Pipeline

`.github/workflows/image.yml`, two jobs:

- **build** (`Build and verify`) — runs on every PR and every image-affecting push. Builds
  `linux/amd64`, asserts the packaged version and that the model bake landed, boots the container and
  waits on `/health`, scans with Trivy, and uploads an SPDX SBOM as an artifact. Never touches a
  registry. It is the only job that runs on PRs, so it is the sole required branch-protection check
  on `main`.
- **publish** (`Publish`) — runs only after a push to `main`
  (`if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'`). Builds both
  architectures under QEMU, pushes the one index to both registries in a single `build-push-action`
  call, then signs and verifies with cosign keyless (Fulcio OIDC — no private key, no registry signing
  secret).

Trivy runs with `ignore-unfixed: true`, so it fails only on CRITICAL/HIGH findings Debian has actually
fixed. A Dependabot base-digest bump is that fix. This replaced the old `.trivyignore` file and its
expiry-governance tooling: findings with no upstream fix are skipped by construction rather than
tracked in a file that needed a validator.

The Dockerfile carries no `LABEL` instructions. `docker/metadata-action` emits the OCI label set
(`title`, `description`, `url`, `source`, `version`, `created`, `revision`, `licenses`) from the
repository at build time, so hand-writing them only invited drift. `vendor` and `licenses` are
supplied explicitly in the workflow.

There are no scripts in this repository. The only shell is four inline lines per job that read the
version out of `package.json`.

## Credentials

Repo-level, all pre-existing:

| Name | Kind | Used for |
|---|---|---|
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | secret | docker.io push |
| `QUAY_USERNAME` / `QUAY_PASSWORD` | secret | quay.io push |
| `DOCKER_NAMESPACE` | variable | docker.io namespace (`squadrules`) |
| `QUAY_NAMESPACE` | variable | quay.io namespace (`squadrules`) |
| `IMAGE_NAME` | variable | image name across both registries (`mcp`) |

`QUAY_USERNAME` must be a robot account, formatted `namespace+robotname`, holding the `write` role on
`squadrules/mcp` (that is, `<QUAY_NAMESPACE>/<IMAGE_NAME>`). Quay's `qro_`-prefixed Robot API token is
a different credential with a separate lifecycle and will not authenticate a push.

No org-level secrets and no GitHub App token are used.

### Branch protection

`main` requires exactly one status check — `Build and verify` (the build job's `name:`) — with
`strict`, `enforce_admins`, and a zero-approval PR gate. It is managed with `gh api` (the
`iac-github` Terraform repo is deprecated). Requiring the PR-skipped `Publish` job would strand every
PR in Pending.

## Building locally

```sh
docker build -t squadrules/mcp:local .
```

No build args. Node on Debian bookworm-slim is required rather than Alpine because `onnxruntime-node`
ships glibc-only binaries. `libgomp1` is installed for the same reason — it backs the onnxruntime CPU
execution provider. The install runs with `--ignore-scripts`: the only install hook in the tree is
`onnxruntime-node`'s postinstall, which downloads CUDA provider binaries on linux/x64, and the CPU
binaries are already bundled in the tarball. Skipping it keeps unused GPU libraries out of the image.
The npm CLI is then deleted, so `npm ls` and `squadrules update` are unavailable inside the container.

### The baked model

The build downloads the default embedding model into `FASTEMBED_CACHE_DIR=/opt/squadrules/models`
(~65 MB), so a zero-env boot needs no Hugging Face egress and pays no first-request latency.

- The model id is read from the installed `@squadrules/mcp/dist/config.js` at build time, never
  hardcoded, so the baked layout cannot drift from what the application looks for.
- The cache lives outside `~/.config/squadrules` on purpose: mounting that directory to persist the
  embedded LanceDB store cannot shadow the weights.
- A failed bake warns and the build continues. A Hugging Face outage must not block publication — the
  runtime simply re-downloads the weights on first use.

The `# check=skip=SecretsUsedInArgOrEnv` directive at the top of the Dockerfile silences one BuildKit
lint false positive: the rule matches the `AUTH` substring in `AUTH_ENABLED`, which is a boolean
rather than a credential. Every other lint check stays enabled.
