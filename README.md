# SquadRules MCP container

Ready-to-run container image for [`@squadrules/mcp`](https://www.npmjs.com/package/@squadrules/mcp)
— the SquadRules MCP server for agent automation: persistent memory and deterministic workflow
execution. Multi-arch, scanned, and signed.

This repository only packages the published npm artifact into an image. The application source
lives in [`SquadRules/mcp`](https://github.com/SquadRules/mcp).

## Get it

```
docker.io/squadrules/mcp
quay.io/squadrules/mcp
```

- **Tags:** `<version>` (e.g. `5.13.5`), `<major>.<minor>`, `<major>`, and `latest`.
- **Platforms:** `linux/amd64` and `linux/arm64`.
- Both registries serve the identical manifest index, so a tag resolves to the same digest
  everywhere. Pin by digest for reproducibility.

## Run it

With no configuration at all, the container is a self-contained HTTP server on port 3000 — UI,
`/api`, `/mcp`, `/health`, metrics on `:9090` — backed by embedded LanceDB and a local, key-free
embedding model baked into the image. No external services, no auth, no API keys.

```sh
docker run --init -p 3000:3000 squadrules/mcp:latest
```

Always pass `--init`: `serve` spawns the server as a child rather than exec'ing it, so without an
init process SIGTERM is not forwarded and `docker stop` waits out the full grace period. In
Kubernetes use `shareProcessNamespace` instead.

### Full cluster mode

Turn on OIDC and point at external stores:

```sh
docker run --init -e AUTH_ENABLED=true \
  -e QDRANT_URL=... -e KEY_VALUE_STORE_URL=... -e KEYCLOAK_URL=... \
  squadrules/mcp:latest
```

Everything is env-overridable. `TRANSPORT_TYPE` defaults to `http` and `AUTH_ENABLED` to `false`;
under `http` the app would otherwise default auth on and refuse to boot without Keycloak, so the
image pins it off for the zero-env case.

### Cold start

First boot is slow — roughly 110s on an arm64 laptop. `/health` only answers after startup injects
the bundled adapters, which is CPU-bound ONNX inference over the baked model. The image
`HEALTHCHECK` carries `--start-period=180s` for that reason. Kubernetes ignores the Docker
`HEALTHCHECK`; pod probes belong to [`SquadRules/charts`](https://github.com/SquadRules/charts),
which sets `runAsUser: 1000` to match the image's `node` user.

## Verify an image

Every published image is signed with cosign keyless (Fulcio OIDC), pinned to this repository's
publish workflow on `main`. To check authenticity and provenance:

```sh
cosign verify \
  --certificate-identity-regexp '^https://github\.com/SquadRules/containers/\.github/workflows/image\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/squadrules/mcp:<version>
```

Inspect the manifest index (platforms, digest, OCI labels):

```sh
docker buildx imagetools inspect docker.io/squadrules/mcp:<version>
```

An image signed by a fork, a branch, or any other workflow fails verification. Signatures are
attached as OCI referrers (sigstore bundles), so use a recent cosign (v2.4 or newer).

## Related repositories

- [`SquadRules/mcp`](https://github.com/SquadRules/mcp) — application source and npm publish
- [`SquadRules/charts`](https://github.com/SquadRules/charts) — Helm chart, pod probes, `runAsUser`

---

Building the image, the CI pipeline, the release process, and maintainer/credential documentation
live in [CONTRIBUTING.md](CONTRIBUTING.md).
