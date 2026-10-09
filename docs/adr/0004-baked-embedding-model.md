# 0004 — Baked ONNX embedding model

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The zero-config embedding backend (`EMBEDDING_PROVIDER=auto`, the default)
downloads ONNX weights from Hugging Face on first use. In a container this
creates three problems:

1. **Air-gapped and egress-restricted clusters** cannot reach Hugging Face at
   all, so the default embedding path would not work.
2. **Read-only root filesystems** (the Kubernetes default under a strict
   `securityContext`) have nowhere to write the download, so the server would
   crash on the first embedding request.
3. **Cold-boot latency**: the download is ~65 MB and the first-request path
   also loads the ONNX model into memory, which is CPU-bound. Baking the
   weights removes the network round-trip from the critical path.

The user's framing of the image's purpose — "the idea behind this image is to
allow run in the cluster; if we embed the model, users will only have to
download the image once; otherwise we would need a StatefulSet in k8s or
download at each boot" — made baking the right default.

## Decision

The `model` stage runs at image build time:

```dockerfile
FROM deps AS model
RUN node --input-type=module -e '
  const { FlagEmbedding } = await import("fastembed");
  const cfg = await import("/app/node_modules/@squadrules/mcp/dist/config.js");
  const dir = await FlagEmbedding.retrieveModel(cfg.FASTEMBED_MODEL, "/opt/squadrules/models", false);
'
```

- The model id is taken from the installed package (`cfg.FASTEMBED_MODEL`),
  never hardcoded in the Dockerfile. `FlagEmbedding.retrieveModel` is
  fastembed's own download-only helper (no ONNX inference at build time, so no
  arch/native risk).
- The weights land in `/opt/squadrules/models`, which is outside the mutable
  config tree (`~/.config/squadrules`, where the embedded LanceDB store
  lives). Mounting a volume over the config directory cannot shadow the
  weights.
- The runtime stage sets `FASTEMBED_CACHE_DIR=/opt/squadrules/models` so the
  application looks for the weights where the bake put them.
- On failure the bake warns and continues — a future registry change must not
  block image publication. The CI smoke test asserts the baked directory
  exists, which is the hard gate.

The model content is frozen (the `Qdrant/bge-small-en-v1.5-onnx` repo has not
changed since its 2024 conversion) and MIT-licensed, so a build-time fetch is
reproducible in practice.

## Consequences

- The image is ~1.5 GB instead of ~1.3 GB (the baked weights add ~65 MB once
  mcp ships the small-model default; ~209 MB while `latest` is 5.1.0 and
  still points at `bge-base-en-v1.5`). Accepted: see the size trade-off in
  [ADR-0001](0001-node24-bookworm-slim-base.md).
- A CLUSTER boot on a read-only root filesystem, or an air-gapped node, needs
  no Hugging Face egress and pays no first-request download latency.
- The CI smoke test asserts the baked model directory exists
  (`scripts/ci-smoke-image.sh` step 2), so a regression in the bake is loud.
- If the upstream model repo changes, the bake warns and the image still
  builds; the runtime falls back to downloading on first use. The smoke test
  is the hard gate that catches a bake regression before publication.
- The `@anush008/tokenizers ^0.6.0` override in the `deps` stage is
  architectural, not security-driven: fastembed's `"^0.0.0"` resolves to
  0.0.0, whose universal stub ships no linux-arm64 binary, so SIMPLE mode
  cannot work on arm64 without the bump. Fix at source in `SquadRules/mcp`.
