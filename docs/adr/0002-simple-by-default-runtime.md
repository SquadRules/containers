# 0002 — SIMPLE-by-default runtime contract

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The previous image baked `QDRANT_URL`, `QDRANT_COLLECTION`, `SERVER_PORT`,
`METRICS_PORT`, and a `VOLUME /snapshots` directive into the Dockerfile. An
environment-less container could not start: the `serve` entrypoint would try
to connect to a Qdrant that did not exist and crash. This defeated the whole
point of packaging the image for end users, who should be able to `docker run`
it and have something work.

The application's runtime-mode contract (defined in
`SquadRules/mcp/src/config/runtime-mode.ts` and
`SquadRules/mcp/src/cli/commands/serve.ts`) already encodes a clean default:

- `serve` defaults the transport to **stdio**.
- Under stdio, an empty `QDRANT_URL` selects the embedded **LanceDB** store.
- `EMBEDDING_PROVIDER=auto` falls back to the local key-free **fastembed**
  model.
- `AUTH_ENABLED` defaults off under stdio, on under http.

So **no environment → SIMPLE mode** is already what the application does; the
image just had to stop getting in the way.

## Decision

The image bakes **no mode-selecting environment variable**. The only ENV
entries are `NODE_ENV=production` and `FASTEMBED_CACHE_DIR=/opt/squadrules/models`,
neither of which selects a runtime mode. The CMD is
`["node", "/app/node_modules/@squadrules/mcp/dist/cli/index.js", "serve"]`.

- **SIMPLE** (the default): `docker run -i --rm --init squadrules/mcp:5`.
  The container speaks MCP JSON-RPC on stdin/stdout. No port is published;
  there is no HTTP listener.
- **CLUSTER**: override through the environment. `TRANSPORT_TYPE=http` makes
  the process an HTTP server; `QDRANT_URL`, `KEY_VALUE_STORE_URL`,
  `AUTH_ENABLED=true`, and the Keycloak variables switch the backing stores
  and turn on OIDC.

The stdio guard in the application (`getStdioConfigViolations`) aborts startup
for `stdio` + a set `QDRANT_URL` and for `stdio` + auth — the fail-fast we
want. An empty `QDRANT_URL` under `TRANSPORT_TYPE=http` is legal and selects
the embedded store, which is what the CLUSTER smoke test exercises.

The `node` user (uid/gid 1000) is the base image's built-in non-root user; it
matches the `runAsUser: 1000` that `SquadRules/charts` already enforces in its
pod `securityContext`.

## Consequences

- An environment-less container now boots and serves MCP over stdio. This is
  the whole point of the image reset.
- The image carries no `VOLUME` directive. Persistent state (the embedded
  LanceDB store) lives under `/home/node/.config/squadrules`, which the user
  mounts explicitly (`-v squadrules-data:/home/node/.config/squadrules`).
- `serve` spawns a child process rather than `exec`-ing, so PID 1 does not
  forward SIGTERM. The recommendation is `docker run --init` (or
  `shareProcessNamespace` in Kubernetes); the smoke script and the healthcheck
  both assume `--init`.
- The chart still pins `app.image.tag: 4.8.6` and needs a version bump plus a
  `/tmp` emptyDir for `readOnlyRootFilesystem`. Flagged as follow-up work in
  `SquadRules/charts`.
