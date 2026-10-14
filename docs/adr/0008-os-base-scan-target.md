# 0008 — OS base scan target

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The security workflow runs a `container-base-os-trivy` job that scans the
base OS layer for CRITICAL/HIGH findings and opens a PR to bump the digest
pin when upstream publishes a new one. The old version of that job grepped
the Dockerfile for the literal `RUN apk update && apk upgrade --no-cache`
line and re-created it in a throwaway Dockerfile — a brittle coupling that
broke every time the apt invocation changed.

With the introduction of the `os-base` stage ([ADR-0003](0003-digest-pin-plus-upgrade-layer.md)),
the Dockerfile already contains a named stage that builds exactly the
hardened OS layer. The security workflow can build that stage directly
instead of re-creating it.

## Decision

The `container-base-os-trivy` job:

1. Extracts the base image name and current digest from the Dockerfile by
   grepping for ` AS os-base$`:
   ```yaml
   line=$(grep -m1 ' AS os-base$' mcp/Dockerfile)
   img_name=$(echo "$line" | sed 's/.*FROM \([^@]*\)@.*/\1/')
   current_digest=$(echo "$line" | sed 's/.*@\([^ ]*\).*/\1/')
   ```
2. Builds the `os-base` stage:
   ```yaml
   docker buildx build --target os-base -t squadrules-os:ci -f mcp/Dockerfile mcp
   ```
3. Scans it with Trivy (`vuln-type: os`, `severity: CRITICAL,HIGH`,
   `trivyignores: .trivyignore`).
4. If findings remain, fetches the current upstream digest via
   `docker buildx imagetools inspect "$img_name" --format '{{json .Manifest.Digest}}'`
   (which returns the manifest *index* digest, unlike `docker inspect
   .RepoDigests` which is per-platform), validates it matches `^sha256:`,
   `sed`s the Dockerfile to replace all occurrences, rebuilds, and rescans.
5. Opens a PR (or auto-merges, depending on repository settings) with the
   digest bump.

## Consequences

- The security workflow no longer re-creates the apt invocation; it builds
  the same stage the production image uses. Changes to the `os-base` stage
  (e.g. adding a package, changing the apt flags) are automatically picked up
  by the scan.
- The `.trivyignore` file is applied to the scan, so the job does not fail
  on findings that have been explicitly accepted
  ([ADR-0003](0003-digest-pin-plus-upgrade-layer.md)).
- The `imagetools` approach returns the manifest index digest, which is the
  same digest the Dockerfile pins. The old `docker inspect .RepoDigests`
  approach returned per-platform digests, which caused the workflow to bump
  the wrong digest on multi-arch images.
- The `grep ' AS os-base$'` coupling is intentional: the stage must be named
  `os-base` for the workflow to find it. Renaming the stage requires updating
  the workflow. Documented in the Dockerfile header.
