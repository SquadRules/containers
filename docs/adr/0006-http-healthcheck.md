# 0006 — HTTP healthcheck

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The image is an HTTP server ([ADR-0002](0002-http-by-default-runtime.md)):
`TRANSPORT_TYPE=http` is baked into the environment and the container is not
offered in a stdio posture. A Docker `HEALTHCHECK` should therefore reflect the
one thing an operator running the image directly cares about — is the HTTP
server up and serving?

An earlier cut made the healthcheck "mode-aware": it read `TRANSPORT_TYPE` and
no-oped (exit 0) whenever the transport was not `http`, so a hypothetical stdio
override would still report healthy. With stdio dropped as a supported posture,
that branch is dead code — `TRANSPORT_TYPE` is always `http` — and keeping it
would only obscure the intent.

## Decision

The healthcheck is a short Node script that always probes `/health`:

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["node","-e","require('http').get({host:'127.0.0.1',port:Number(process.env.SERVER_PORT||3000),path:'/health',timeout:5000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"]
```

- It probes `127.0.0.1:${SERVER_PORT:-3000}/health` and exits 0 on HTTP 200, 1
  otherwise. A 5-second socket timeout prevents a hung probe from consuming the
  whole `--timeout=10s`.
- `--start-period=180s` is sized for the measured cold boot (~110 s on an arm64
  laptop). Startup injects the bundled adapters, which is CPU-bound ONNX
  embedding work on the local model; `/health` only answers after that
  completes. A shorter start-period would cause the container to be marked
  unhealthy during a normal boot and restarted by the orchestrator in a loop.

## Consequences

- Kubernetes ignores the `HEALTHCHECK` directive — `SquadRules/charts` owns pod
  probes. The Docker healthcheck is for users running the image directly
  (`docker run`, `docker compose`).
- If someone forces a non-HTTP transport with `-e TRANSPORT_TYPE=…`, the
  healthcheck will fail and Docker will report the container unhealthy. That is
  intentional: HTTP is the only supported posture for this image, so an
  unsupported override should be visible rather than silently "healthy".
- The start-period is conservative. If the cold boot time changes significantly
  (e.g. a larger model is baked in, or startup optimisation reduces it), the
  value should be revisited. The smoke script measures the actual boot time on
  every run; the README records the most recent measurement.
- The healthcheck runs as the `node` user (uid 1000), which is sufficient — it
  only opens a loopback socket.

## Amendments

- **2026-10-15 — the cold boot is faster than recorded here.** Re-measured by
  booting a `linux/arm64` image (packaging `@squadrules/mcp` 5.4.1, baked model)
  on an Apple Silicon host with `docker run --init` and polling `/health`: the
  first 200 came **51 s** after start, not the ~110 s above, and the payload
  reported `status=healthy`, `transport=http`, `vectorStore=healthy`,
  `embedding=healthy`. The same run stopped in 0 s against `docker stop -t 20`,
  confirming `--init` forwards `SIGTERM`. The pipeline's own build-job comment
  puts the native amd64 leg at ~40 s, so the two agree and the ~110 s figure was
  a worst case that has since improved (smaller baked model).
- **2026-10-15 — `--start-period=180s` is kept.** Headroom rises from ~1.6x to
  ~3.5x over the measured boot, which is the right direction for a value that
  must also absorb a cold image layer, an under-provisioned node, and the
  adapter-embedding work at startup. Nothing here argues for lowering it; the
  consequence above still holds — revisit when boot time changes materially.
