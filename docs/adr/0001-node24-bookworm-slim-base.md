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
   with the embedding backend that SIMPLE mode depends on.

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
  the baked model vs ~400 MB Alpine could achieve). Accepted: the embedding
  backend is non-negotiable for SIMPLE mode, and the image is pulled once per
  node, not per request.
- OS CVE remediation now runs through `apt-get upgrade` in the `os-base`
  stage, not `apk upgrade`. See [ADR-0003](0003-digest-pin-plus-upgrade-layer.md).
- `onnxruntime-node` also pulls in `libgomp1` (OpenMP), which the `os-base`
  stage installs alongside the upgrade.
- Dependabot and the security workflow track the digest pin; the tag is
  updated by hand only when moving to a new Node line.
