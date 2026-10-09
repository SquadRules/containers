# 0005 — npm CLI removed from the runtime image

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The previous image shipped the full Node.js distribution, including the npm
CLI (`/usr/local/lib/node_modules/npm`, `/usr/local/bin/npm`,
`/usr/local/bin/npx`). The server runtime never invokes npm — it is a
long-running process that loads its dependencies at startup and does not
install anything afterwards. Shell-challenge adapters are executed by the
*agent* on its own host, not inside the container
(`SquadRules/mcp/src/tools/shell-challenge-invocation.ts`).

Shipping npm in the runtime was therefore pure attack surface:

- npm bundles a large tree of third-party libraries (each one a potential CVE
  finding — the old `.trivyignore` carried two npm-bundled CVEs for this
  reason).
- npm is a "run arbitrary registry code" primitive inside the container. Even
  though the container runs as non-root with no capabilities, removing the
  primitive is defence in depth.

## Decision

The runtime stage deletes the npm CLI before switching to the `node` user:

```dockerfile
RUN set -eux; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx; \
    test ! -e /usr/local/bin/npm
```

The assertion (`test ! -e`) makes the removal a build-time invariant: if a
future base image moves the npm binary, the build fails rather than silently
shipping it.

## Consequences

- The two npm-bundled CVEs in the old `.trivyignore` (`CVE-2026-12151`,
  `CVE-2026-93748`) were pruned — the libraries are no longer present in the
  image at all. Trivy against the built image confirms they do not appear.
- `npm ls`, `npm install`, and `squadrules update` (if it ever shells out to
  npm) are unavailable inside the container. Documented as a limitation in
  the README.
- The `deps` stage still uses npm to install the published `@squadrules/mcp`
  package; only the runtime image has npm removed. The multi-stage build
  keeps the two concerns separate.
- If a future version of the server needs to invoke npm at runtime, the
  removal will have to be revisited. The assertion in the Dockerfile makes
  that decision explicit.
