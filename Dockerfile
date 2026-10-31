# check=skip=SecretsUsedInArgOrEnv
# False positive: the rule matches the "AUTH" substring in AUTH_ENABLED, a boolean.

# Packages the published @squadrules/mcp npm artifact. package.json is the build manifest and
# Dependabot owns that pin plus the base digest, so there are zero required build args.
# Runtime modes and environment variables are documented in README.md; the build pipeline, base
# digest ownership and credentials are documented in CONTRIBUTING.md.

# bookworm-slim, not Alpine: onnxruntime-node ships glibc-only binaries.
FROM node:26-bookworm-slim@sha256:28147155d47dc31abe0a46e0d12b59b2fb3d0a2dcc5dc65fce76a074180b16fe

WORKDIR /app

# libgomp1 backs the onnxruntime-node CPU execution provider.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgomp1 \
 && rm -rf /var/lib/apt/lists/*

# This manifest is ONLY a Dependabot-owned version pointer. Do not install it as the
# npm root: npm ignores @squadrules/mcp's security overrides beneath another root.
COPY package.json /tmp/image-manifest/package.json

# Extract the published MCP tarball as /app itself, making its package.json the npm
# root. Its security overrides (including native arm64 dependency selection) now apply.
# New releases carry a tested runtime lock under dist/runtime-lock.json. Older releases
# without that lock still use the same upstream root policy, but resolve dynamically.
# --ignore-scripts prevents onnxruntime-node from downloading unused CUDA providers.
RUN set -eu; \
    v="$(node -p "require('/tmp/image-manifest/package.json').dependencies['@squadrules/mcp']")"; \
    npm pack "@squadrules/mcp@$v" --pack-destination /tmp --ignore-scripts --silent; \
    tar -xzf "/tmp/squadrules-mcp-$v.tgz" --strip-components=1 -C /app; \
    test "$(node -p "require('/app/package.json').version")" = "$v"; \
    if [ -f /app/dist/runtime-lock.json ]; then \
      cp /app/dist/runtime-lock.json /app/package-lock.json; \
      npm ci --omit=dev --ignore-scripts --no-audit --no-fund; \
    else \
      echo "WARNING: MCP release has no runtime lock; using source-root overrides with npm install"; \
      npm install --omit=dev --ignore-scripts --no-audit --no-fund; \
    fi; \
    rm -f /app/package-lock.json /app/dist/runtime-lock.json "/tmp/squadrules-mcp-$v.tgz"; \
    npm cache clean --force; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /tmp/image-manifest

# Baked so a zero-env boot needs no Hugging Face egress. The id is read from the installed
# package, never hardcoded, so the baked layout cannot drift from what the app looks for.
# Kept out of ~/.config/squadrules so mounting that for the embedded LanceDB store cannot shadow
# it. Non-fatal: an outage must not block publication, the runtime re-downloads on first use.
ENV FASTEMBED_CACHE_DIR=/opt/squadrules/models
RUN mkdir -p "$FASTEMBED_CACHE_DIR" \
 && node --input-type=module -e 'const {FlagEmbedding}=await import("fastembed");const {FASTEMBED_MODEL:model}=await import("/app/dist/config.js");try{await FlagEmbedding.retrieveModel(model,process.env.FASTEMBED_CACHE_DIR,false);console.log("Baked embedding model "+model);}catch(err){console.warn("WARNING: model not baked ("+err.message+"); the runtime will download it on first use");}'

# Server on 3000, metrics on 9090. EXPOSE is documentation only.
EXPOSE 3000 9090

# AUTH_ENABLED is pinned off because under TRANSPORT_TYPE=http it would otherwise default to on
# and refuse to boot without Keycloak.
ENV NODE_ENV=production \
    TRANSPORT_TYPE=http \
    AUTH_ENABLED=false

# Built-in node user (uid/gid 1000), matching runAsUser: 1000 in SquadRules/charts.
USER node

# start-period covers the measured ~110s cold boot: /health answers only after startup has
# injected the bundled adapters, which is CPU-bound ONNX inference. Kubernetes ignores this.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["node","-e","require('http').get({host:'127.0.0.1',port:Number(process.env.SERVER_PORT||3000),path:'/health',timeout:5000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"]

# `serve` spawns the server as a child rather than exec'ing it, so run with --init (or
# shareProcessNamespace) for SIGTERM forwarding.
CMD ["node","/app/dist/cli/index.js","serve"]
