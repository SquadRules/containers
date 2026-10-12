# 0002 — HTTP-by-default standalone runtime

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The previous image baked `QDRANT_URL`, `QDRANT_COLLECTION`, `SERVER_PORT`,
`METRICS_PORT`, and a `VOLUME /snapshots` directive into the Dockerfile, so an
environment-less container could not start.

The first cut of this reset over-corrected: it made the CMD a bare
`squadrules serve` with no baked transport, on the theory that "no environment
→ SIMPLE". But `serve`'s own default is stdio
(`resolveServeTransport(..., defaultStdio = true)`), which is the *local-agent*
posture — a stdio container must be attached with `docker run -i`, opens no
listener, and has no port to reach. That is the wrong default for an image
whose stated purpose is to "run in the cluster".

The application agrees. `resolveTransportType` documents that stdio is selected
*only* for the `squadrules-mcp` bin and `squadrules serve`, while "every other
entrypoint (compose, **container CMD**, `node dist/index.js`) keeps the
historical `http` default". A container should therefore default to HTTP.

One consequence has to be handled explicitly. Under HTTP, `resolveAuthEnabled`
defaults `AUTH_ENABLED` to **true**, and auth-on triggers Keycloak/OIDC
validation — so a zero-env `docker run` on HTTP would refuse to boot without
Keycloak config. That would defeat "zero env just works".

## Decision

Bake the HTTP-server default into the image environment:

```dockerfile
ENV TRANSPORT_TYPE=http \
    AUTH_ENABLED=false
```

with `CMD ["node", ".../dist/cli/index.js", "serve"]`. `serve` reads
`TRANSPORT_TYPE` from the environment, so the baked value makes an
environment-less container an HTTP server; `AUTH_ENABLED=false` keeps it
self-contained. The result is three postures, all reachable from the same image
by environment override:

- **Default (zero env):** a self-contained HTTP server on `:3000` (UI, `/api`,
  `/mcp`, `/health`, metrics) backed by embedded LanceDB and the local key-free
  fastembed model, with no external dependencies and no auth.
  `docker run -p 3000:3000 squadrules/mcp:<version>`.
- **stdio (local agent):** `-e TRANSPORT_TYPE=stdio` gives the single-user MCP
  server an agent host spawns — JSON-RPC on stdin/stdout (`docker run -i`), no
  listener.
- **Full cluster:** add `-e AUTH_ENABLED=true` plus `QDRANT_URL` /
  `KEY_VALUE_STORE_URL` / `KEYCLOAK_*` to move to external stores and OIDC.

The stdio guards still apply under the override: `TRANSPORT_TYPE=stdio` with a
set `QDRANT_URL`, or with `AUTH_ENABLED=true`, aborts startup
(`getStdioConfigViolations`).

## Consequences

- A zero-env container now boots a reachable, self-contained HTTP server — the
  image works with `docker run -p 3000:3000` and no configuration, which is
  what "run in the cluster" needs.
- The default is **unauthenticated** and binds `:3000`. That is an intentional
  standalone posture (matching the embedded-store, baked-model design), not a
  production cluster config: operators exposing the port publicly must set
  `AUTH_ENABLED=true` and the OIDC vars, or front it with an authenticating
  proxy. Documented in the README.
- The healthcheck now probes `/health` by default (see
  [ADR-0006](0006-mode-aware-healthcheck.md)) instead of no-oping.
- `serve` still spawns the server as a child rather than `exec`-ing it, so PID 1
  does not forward SIGTERM; run with `--init` (or `shareProcessNamespace` in
  Kubernetes).
- The chart still pins `app.image.tag: 4.8.6` and needs a version bump plus a
  `/tmp` emptyDir for `readOnlyRootFilesystem`. Flagged as follow-up in
  `SquadRules/charts`.
