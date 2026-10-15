# 0001 — Node 24 LTS on Debian bookworm-slim as the base image

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The previous image was built on `node:22-alpine`. Two things changed at once:

1. **Node 24 entered Active LTS** (October 2025), matching the `engines`
   declaration and the `.nvmrc` in `SquadRules/mcp`. Node 22 is in
   Maintenance LTS and will reach end-of-life in April 2027. Node 26 does not
   enter Active LTS until late October 2026 and is not yet the line the
   application repo pins.
2. **The zero-config embedding path loads `onnxruntime-node`**, which ships
   glibc-only prebuilt binaries. Alpine's musl libc is therefore incompatible
   with the local embedding backend the image uses by default.

The base image choice is load-bearing: it determines the libc available to
native modules, the package manager used for OS CVE remediation, the attack
surface of the runtime, and the cadence at which the digest pin must be
refreshed.

## Decision

Use `node:24-bookworm-slim` digest-pinned to the current manifest-list index
(`sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20`
at the time of writing).

- **Node 24** (Active LTS) — matches the application repo's declared engine.
  Moving to Node 26 is a one-line digest/tag change once it enters Active LTS.
- **Debian bookworm-slim** (not Alpine) — glibc is required by
  `onnxruntime-node`. bookworm-slim is the smallest Debian variant that still
  carries a working `apt` for OS-level CVE remediation.
- **Digest-pinned** — the tag (`node:24-bookworm-slim`) is mutable; the digest
  is not. Pinning the digest makes the build supply-chain deterministic and
  lets Dependabot / the security workflow propose a single-line PR when
  upstream publishes a new index.

## Consequences

- The image is larger than an Alpine-based one would be (roughly 1.5 GB with
  the baked model vs ~400 MB Alpine could achieve). Accepted: the local
  embedding backend is non-negotiable for the default zero-config path, and the
  image is pulled once per node, not per request.
- OS CVE remediation now runs through `apt-get upgrade` in the `os-base`
  stage, not `apk upgrade`. See [ADR-0003](0003-digest-pin-plus-upgrade-layer.md).
- `onnxruntime-node` also pulls in `libgomp1` (OpenMP), which the `os-base`
  stage installs alongside the upgrade.
- Dependabot and the security workflow track the digest pin; the tag is
  updated by hand only when moving to a new Node line.

## Amendments

- **2026-10-15 — Context correction: the previous base was `node:26-alpine`, not
  `node:22-alpine`.** The scaffold commit `4eeafb7` (2026-10-03) pinned
  `node:26-alpine@sha256:0b36e8c1…`, and `node:22` appears nowhere in this
  repository's history. The correction strengthens the argument rather than
  changing it: Node 26 was not then, and is not now, the Active LTS line, so the
  image being replaced was shipping a non-LTS runtime — and it still is, because
  the published `docker.io/squadrules/mcp:latest` remains that pre-reset build
  (`NODE_VERSION=26.10.0` in its image config, `org.opencontainers.image.version
  = 5.9.2`).
- **2026-10-15 — measured sizes replace estimates.** First consequence, measured
  on a `linux/arm64` build of the current Dockerfile packaging `@squadrules/mcp`
  5.4.1: the image is **~1.2 GB** (`docker images`), with `du` inside the
  container accounting ~530 MB in `/app/node_modules` (`onnxruntime-node` ~208 MB,
  LanceDB's native bindings ~137 MB), ~223 MB in `/usr` and ~65 MB of baked
  weights in `/opt`. The "~400 MB Alpine could achieve" counterfactual was
  aspirational, not a baseline: the Alpine image it replaced measured **~1.0 GB**
  (`docker images`; ~501 MB `node_modules` + ~178 MB `/usr`), because it still
  shipped the npm CLI tree and its bundled library surface. The real cost of the
  glibc move is therefore roughly +180 MB — smaller than originally claimed, and
  the Alpine alternative additionally carried a broken local-embedding path on
  arm64 (see [ADR-0004](0004-baked-embedding-model.md), amended 2026-10-15). The
  decision is unaffected.
