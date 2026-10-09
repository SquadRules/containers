# SquadRules MCP runtime image — built FROM the published @squadrules/mcp npm package.
#
# This repository owns the container image only; the application source and the npm
# artifact are produced by SquadRules/mcp. There is no source build here: the deps stage
# installs `@squadrules/mcp@${PACKAGE_VERSION}` straight from the npm registry and only its
# node_modules leaves the image, so this is a pure packaging of an already-published,
# already-released version.
#
# Runtime modes — this image deliberately bakes NO mode-selecting environment:
#
#   * SIMPLE (the default): run the image with an empty environment. The CMD is the
#     `squadrules serve` entrypoint, which defaults to the stdio transport, and the app
#     then selects embedded LanceDB (no QDRANT_URL), authentication off, and the local
#     key-free fastembed model. MCP speaks JSON-RPC on stdin/stdout, so a container must
#     be attached (`docker run -i`); there is no HTTP listener and no port to publish.
#   * CLUSTER: override any setting through the environment. `TRANSPORT_TYPE=http` makes
#     the process an HTTP server (UI, /api, /mcp, /health, metrics); a non-empty
#     QDRANT_URL / KEY_VALUE_STORE_URL / AUTH_ENABLED=true switch the backing stores and
#     turn on OIDC. `docker exec`-style probes and Helm/Kubernetes liveness then apply.
#
# Node policy: Node.js 24 is the Active LTS line (it is what `node:lts` resolves to, and
# what SquadRules/mcp `.nvmrc` / `engines` declare). Non-LTS Current is exercised in the
# application repo's CI only, never as a second published image. Debian bookworm-slim is
# used rather than Alpine because the zero-config embedding path loads onnxruntime-node,
# which ships glibc-only binaries. The digest pin is supply-chain integrity, not freshness:
# the os-base stage upgrades the Debian packages, and the findings Debian has no fix for are
# accepted with an expiring review date in ../.trivyignore.
#
# Stages: deps -> model -> os-base -> runtime (the last one is the build target; `--target
# os-base` builds only the hardened OS layer, which is what the security workflow scans).
#
# Build:
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg PACKAGE_VERSION=<published-version> -f mcp/Dockerfile -t squadrules/mcp:<version> mcp

# --- Install the published package (never shipped; only node_modules leaves this stage).
FROM node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS deps

WORKDIR /app

ARG PACKAGE_VERSION
RUN test -n "$PACKAGE_VERSION" || (echo "Build-arg PACKAGE_VERSION is required" && exit 1)

# Build a synthetic npm root so the published package is installed with an exact version
# pin. The application repo's security `overrides` are read back from the registry instead
# of being duplicated here: npm applies `overrides` only to the root project being
# installed, so without this the image would resolve transitive deps to whatever the
# published package's semver ranges allow, i.e. ignoring the patches the release CI
# verified. `--ignore-scripts` is safe for this dependency tree — no production
# dependency ships an install/postinstall hook (LanceDB, onnxruntime-node, keyring and
# tokenizers all deliver prebuilt per-platform binaries).
#
# ONE packaging override is added on top of the app's own list, and it is architectural
# rather than security-driven: fastembed 3.x depends on "@anush008/tokenizers": "^0.0.0",
# and a caret on 0.0.x resolves to exactly 0.0.0, whose universal stub ships binaries only
# for darwin-universal / linux-x64-gnu / win32-x64-msvc. There is no linux-arm64 build at
# 0.0.0, so `import('fastembed')` throws MODULE_NOT_FOUND on linux/arm64 and the key-free
# local embedding path — i.e. SIMPLE mode — cannot work on arm64 images at all. 0.6.0 is
# the same napi project with linux-arm64-gnu/musl added, so it is forced here. Fix at
# source in SquadRules/mcp (dependency bump or override) and delete this line once a
# released @squadrules/mcp carries it.
RUN set -eux; \
    npm view "@squadrules/mcp@${PACKAGE_VERSION}" overrides --json > /tmp/overrides.json 2>/dev/null || true; \
    node -e 'const fs = require("fs"); let o = {}; try { o = JSON.parse(fs.readFileSync("/tmp/overrides.json", "utf8")) || {}; } catch { o = {}; } o["@anush008/tokenizers"] = "^0.6.0"; fs.writeFileSync("package.json", JSON.stringify({ private: true, name: "squadrules-mcp-image", dependencies: { "@squadrules/mcp": process.env.PACKAGE_VERSION }, overrides: o }, null, 2) + "\n");'; \
    cat package.json; \
    npm install --omit=dev --ignore-scripts --no-audit --no-fund; \
    npm cache clean --force

# --- Bake the local embedding model the installed package defaults to.
FROM deps AS model

WORKDIR /app

# The zero-config embedding backend downloads ONNX weights on first use. Fetching them
# here instead makes the image self-contained: a CLUSTER boot on a read-only root
# filesystem, or an air-gapped node, then needs no Hugging Face egress and pays no
# first-request latency. Kept out of the mutable config tree so mounting
# ~/.config/squadrules (for the embedded LanceDB store) cannot shadow the weights.
#
# The model id is taken from the installed package, never hardcoded here: fastembed's own
# MODEL_SOURCES maps it to a Hugging Face repo and directory name, so the baked layout is
# exactly what the app will look for. Weight content is frozen (the bge ONNX repos have
# not changed since their 2024 conversion) and MIT-licensed, so a build-time fetch is
# reproducible in practice; an unexpected registry change warns and falls back to the
# runtime download rather than blocking image publication, and the image pipeline asserts
# the baked directory exists.
ARG MODEL_CACHE_DIR=/opt/squadrules/models
# The directory is created up front so the runtime stage always has something to COPY, even
# when the bake below decides to skip.
RUN set -eux; \
    mkdir -p "${MODEL_CACHE_DIR}"; \
    node --input-type=module -e 'const { FlagEmbedding } = await import("fastembed"); const cfg = await import("/app/node_modules/@squadrules/mcp/dist/config.js"); const model = cfg.FASTEMBED_MODEL; try { const dir = await FlagEmbedding.retrieveModel(model, process.env.MODEL_CACHE_DIR, false); console.log("Baked embedding model " + model + " into " + dir); } catch (err) { console.warn("WARNING: embedding model not baked (" + err.message + "); the runtime will download it on first use"); }'; \
    du -sh "${MODEL_CACHE_DIR}" 2>/dev/null || true

# --- Hardened Debian base, kept as its own named stage.
# It exists so .github/workflows/security.yml can build and scan exactly this layer
# (`docker buildx build --target os-base`) instead of grepping the apt line out of this file and
# re-creating it — the coupling that made the old Alpine version of that job brittle.
FROM node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS os-base

# A digest pin freezes whatever Debian snapshot upstream published, so the pin on its own is not
# an OS remediation: `apt-get upgrade` closes the findings Debian has already fixed (perl-base
# today), and `.trivyignore` carries the documented, expiring remainder that has no fix to take.
# libgomp1 is required by the onnxruntime-node CPU execution provider, which both runtime modes
# load whenever embeddings are produced locally; it is installed after the upgrade so it comes
# from the refreshed index too. One layer, and `/var/lib/apt/lists` never survives it.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y --no-install-recommends; \
    apt-get install -y --no-install-recommends libgomp1; \
    rm -rf /var/lib/apt/lists/*

# --- Runtime image.
FROM os-base AS runtime

WORKDIR /app

# Re-declared because ARGs do not cross stage boundaries; the value must match the model
# stage so the baked weights land where ENV FASTEMBED_CACHE_DIR points.
ARG MODEL_CACHE_DIR=/opt/squadrules/models

COPY --from=deps /app/package.json /app/package.json
COPY --from=deps /app/node_modules /app/node_modules
COPY --from=model ${MODEL_CACHE_DIR} ${MODEL_CACHE_DIR}

# The npm CLI is only needed to install packages; nothing in the server runtime invokes it
# (shell-challenge adapters are executed by the agent on its own host, not here). Removing
# it drops a large tree of npm-bundled libraries from the image and from every CVE report,
# and takes away a "run arbitrary registry code" primitive from the container. `npm ls`
# and `squadrules update` are therefore unavailable inside the container.
RUN set -eux; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx; \
    test ! -e /usr/local/bin/npm; \
    du -sh "${MODEL_CACHE_DIR}"

# Documentation only — EXPOSE carries no enforcement, and the ports are unused in SIMPLE
# mode because a stdio server opens no listener. Values mirror the app defaults
# (SERVER_PORT 3000, METRICS_PORT 9090); both are overridable by environment in CLUSTER.
EXPOSE 3000 9090

# Only two environment variables are set, and neither selects a runtime mode: NODE_ENV is
# the usual production switch, and FASTEMBED_CACHE_DIR points at the baked weights (kept
# outside ~/.config/squadrules so mounting that directory for the embedded LanceDB store
# cannot shadow them). Both track the build args above rather than duplicating literals.
ENV NODE_ENV=production \
    FASTEMBED_CACHE_DIR=${MODEL_CACHE_DIR}

# Built-in `node` user (uid/gid 1000) — no root, no new user, and it matches the
# runAsUser: 1000 that the SquadRules/charts pod securityContext already enforces.
USER node

# Mode-aware healthcheck. A stdio process has no socket to probe, so the check is a no-op
# there (Docker reports healthy as long as the process is up) and only verifies /health
# once an HTTP transport is configured. start-period is sized for the measured cold boot of
# a CLUSTER container (~110s on an arm64 laptop): /health only answers after startup has
# injected the bundled adapters, which is CPU-bound ONNX embedding on the local model.
# Kubernetes ignores this instruction — SquadRules/charts owns pod probes.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["node","-e","const t=(process.env.TRANSPORT_TYPE||'').trim().toLowerCase();if(t!=='http')process.exit(0);require('http').get({host:'127.0.0.1',port:Number(process.env.SERVER_PORT||3000),path:'/health',timeout:5000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"]

# OCI base-image annotations. The pipeline supplies the values it knows only at build time as
# build args (BUILD_REVISION / BUILD_SOURCE) rather than `--label`, so `docker inspect` of a
# locally built image and of the published one show the same thing. `created` is deliberately not
# annotated: buildkit already records the image's own creation timestamp in its config, and a
# second one here would only make rebuilds of the same version differ by more than the version.
ARG PACKAGE_VERSION
ARG BUILD_REVISION=unknown
ARG BUILD_SOURCE=https://github.com/SquadRules/containers
LABEL org.opencontainers.image.title="SquadRules MCP" \
      org.opencontainers.image.description="SquadRules MCP server for agent automation: persistent memory and deterministic workflow execution" \
      org.opencontainers.image.vendor="SquadRules" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="${BUILD_SOURCE}" \
      org.opencontainers.image.version="${PACKAGE_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.base.name="docker.io/library/node:24-bookworm-slim"

# `serve` (not `dist/index.js`) is the point: it is the entrypoint whose transport default
# is stdio, which is what makes an environment-less container SIMPLE.
CMD ["node", "/app/node_modules/@squadrules/mcp/dist/cli/index.js", "serve"]
