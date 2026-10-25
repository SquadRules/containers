# check=skip=SecretsUsedInArgOrEnv
# False positive: the rule matches the "AUTH" substring in AUTH_ENABLED, a boolean.

# Packages the published @squadrules/mcp npm artifact. package.json is the build manifest and
# Dependabot owns that pin plus the base digest, so there are zero required build args.
# Runtime modes, environment variables and the pipeline are documented in README.md.

# bookworm-slim, not Alpine: onnxruntime-node ships glibc-only binaries.
FROM node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

WORKDIR /app

# libgomp1 backs the onnxruntime-node CPU execution provider.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgomp1 \
 && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./

# --ignore-scripts is load-bearing: the only install hook in the tree is onnxruntime-node's
# postinstall, which downloads CUDA provider binaries on linux/x64. The CPU binaries are already
# bundled, so skipping it keeps unused GPU libraries out. npm is then deleted — nothing at
# runtime invokes it, and it removes a "run arbitrary registry code" primitive.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm cache clean --force \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

# Baked so a zero-env boot needs no Hugging Face egress. The id is read from the installed
# package, never hardcoded, so the baked layout cannot drift from what the app looks for.
# Kept out of ~/.config/squadrules so mounting that for the embedded LanceDB store cannot shadow
# it. Non-fatal: an outage must not block publication, the runtime re-downloads on first use.
ENV FASTEMBED_CACHE_DIR=/opt/squadrules/models
RUN mkdir -p "$FASTEMBED_CACHE_DIR" \
 && node --input-type=module -e 'const {FlagEmbedding}=await import("fastembed");const {FASTEMBED_MODEL:model}=await import("/app/node_modules/@squadrules/mcp/dist/config.js");try{await FlagEmbedding.retrieveModel(model,process.env.FASTEMBED_CACHE_DIR,false);console.log("Baked embedding model "+model);}catch(err){console.warn("WARNING: model not baked ("+err.message+"); the runtime will download it on first use");}'

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
CMD ["node","/app/node_modules/@squadrules/mcp/dist/cli/index.js","serve"]
