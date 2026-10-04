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

## Build contract

[`mcp/Dockerfile`](mcp/Dockerfile) is a pure packaging Dockerfile:

1. `base` — pinned `node:26-alpine@sha256:...`, `apk upgrade`, and a hardened global npm
   (bundled `tar` / `brace-expansion` / `ip-address` / `undici` pinned to patched versions).
2. `deps-registry` — `npm install --omit=dev` of `@squadrules/mcp@${PACKAGE_VERSION}` with
   security `overrides`. No source, no local tarball.
3. `runtime` — non-root user, ports, healthcheck, `CMD ["node","node_modules/@squadrules/mcp/dist/index.js"]`.

`PACKAGE_VERSION` is a required build arg. The image content is fully determined by the
published npm version, so the same version always produces the same image.

## Pipeline

[`.github/workflows/build-publish.yml`](.github/workflows/build-publish.yml) — the image
pipeline. Triggers:

- **`schedule` (hourly)** — reconciliation against npm `latest`. No-op when the tag already
  exists.
- **`workflow_dispatch`** — manual build for an explicit `version` (or latest), with `force`
  and `dry-run` flags.
- **`pull_request`** — build + scan **only** (no publish) to gate Dockerfile/`.trivyignore`
  changes.

Steps: resolve version → `docker buildx build` (multi-arch OCI) → per-arch smoke
(`serve --help` + version assert) → Trivy `CRITICAL,HIGH` per arch (`.trivyignore`) →
`skopeo copy` to both registries → `cosign sign`/`verify` → promote aliases.

[`.github/workflows/security.yml`](.github/workflows/security.yml) — `.trivyignore` expiry
guard and the base-image OS Trivy scan that auto-remediates by bumping the pinned base
digest (PR flow commits to the branch; schedule/push flow opens an auto-merge PR).

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

## Repository provisioning

This repo is declared as code in
[`jakub-plichcinski/iac-github`](https://github.com/jakub-plichcinski/iac-github)
(`live/repos/squadrules/terragrunt.hcl`). Branch protection is added in a second IaC pass
once the `Container image pipeline passed` check has reported on `main`.

## License and trademark

The packaged application is distributed under the license and trademark terms in
[`SquadRules/mcp`](https://github.com/SquadRules/mcp). This repository contains only
packaging/CI.
