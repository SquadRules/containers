# Package the published npm release; no application source build.
FROM node:24-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/SquadRules/containers" \
      org.opencontainers.image.description="SquadRules MCP packaged from npm"

WORKDIR /opt/squadrules
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund \
    && npm cache clean --force

ENV NODE_ENV=production \
    TRANSPORT=http \
    TRANSPORT_TYPE=http \
    AUTH_ENABLED=false \
    HOST=0.0.0.0 \
    PORT=3000

WORKDIR /home/node
USER node
EXPOSE 3000
CMD ["/opt/squadrules/node_modules/.bin/squadrules", "serve"]
