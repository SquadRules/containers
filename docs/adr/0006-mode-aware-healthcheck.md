# 0006 — Mode-aware healthcheck

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The image supports two runtime modes ([ADR-0002](0002-simple-by-default-runtime.md)):
SIMPLE (stdio) and CLUSTER (HTTP). A healthcheck that probes an HTTP endpoint
only makes sense when the process is actually serving HTTP; under stdio there
is no socket to probe. A static healthcheck would either:

- always report healthy under stdio (useless, but harmless), or
- always fail under stdio (the container is marked unhealthy even though the
  process is running correctly).

Neither is what we want. The healthcheck needs to know which mode the
container is in.

## Decision

The healthcheck is a short Node script that reads `TRANSPORT_TYPE` from the
environment:

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["node","-e","const t=(process.env.TRANSPORT_TYPE||'').trim().toLowerCase();if(t!=='http')process.exit(0);require('http').get({host:'127.0.0.1',port:Number(process.env.SERVER_PORT||3000),path:'/health',timeout:5000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"]
```

- Under stdio (the default), the check exits 0 immediately — the container is
  reported healthy as long as the process is up.
- Under `TRANSPORT_TYPE=http`, the check probes `127.0.0.1:${SERVER_PORT:-3000}/health`
  and exits 0 on HTTP 200, 1 otherwise. A 5-second socket timeout prevents a
  hung probe from consuming the whole `--timeout=10s`.

`--start-period=180s` is sized for the measured CLUSTER cold boot (~110 s on
an arm64 laptop). Startup injects the bundled adapters, which is CPU-bound
ONNX embedding work on the local model; `/health` only answers after that
completes. A shorter start-period would cause the container to be marked
unhealthy during a normal boot and restarted by the orchestrator in a loop.

## Consequences

- Kubernetes ignores the `HEALTHCHECK` directive — `SquadRules/charts` owns
  pod probes. The Docker healthcheck is for users running the image directly
  (`docker run`, `docker compose`).
- The start-period is conservative. If the cold boot time changes
  significantly (e.g. a larger model is baked in, or startup optimisation
  reduces it), the value should be revisited. The smoke script measures the
  actual boot time on every run; the README records the most recent
  measurement.
- The healthcheck runs as the `node` user (uid 1000), which is sufficient —
  it only opens a loopback socket.
