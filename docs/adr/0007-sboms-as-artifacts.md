# 0007 — SPDX SBOMs as CI artifacts, not registry attachments

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The image pipeline's whole point is publishing the digest of the image it
built. Idempotency is enforced by `skopeo inspect` against the published tag;
the publish step uses `skopeo copy --all --preserve-digests` to move the
exact same OCI archive from the build to both registries (Docker Hub and
quay.io), and cosign signs that digest.

Buildkit can attach SPDX SBOMs and SLSA provenance to an image as OCI
attestations. Doing so changes the image's manifest, which changes its
digest — and the pipeline must not change the digest between build and
publish.

## Decision

SBOMs are generated as build artifacts and uploaded as GitHub Actions
artifacts, not attached to the registry image:

```yaml
- name: Generate SPDX SBOM (amd64)
  uses: aquasecurity/trivy-action@v0.36.0
  with:
    input: .local/scan-amd64.tar
    scanners: vuln
    format: spdx-json
    output: .local/sbom-amd64.spdx.json
    list-all-pkgs: 'true'

- name: Upload SBOMs
  uses: actions/upload-artifact@v5
  with:
    name: sbom-${{ needs.resolve.outputs.version }}
    retention-days: 90
    path: .local/sbom-*.spdx.json
```

The build step also passes `--provenance=false --sbom=false` to
`docker buildx build` to ensure buildkit does not attach anything that would
change the digest.

The SBOMs are unfiltered: no severity limit, no `.trivyignore`, every package
whether or not it has a CVE. An SBOM is an inventory, and a suppressed
finding must stay visible in it.

## Consequences

- The published digest is stable between build and publish. `skopeo copy
  --preserve-digests` works as intended.
- SBOMs are available as GitHub Actions artifacts for 90 days, downloadable
  by anyone with read access to the repository. They are not attached to the
  registry image, so `cosign verify` and `skopeo inspect` see the same digest
  the build produced.
- If a consumer needs the SBOM attached to the image (e.g. for supply-chain
  compliance that requires in-band attestations), the pipeline would need to
  be restructured: build the SBOM, attach it, then publish the new digest.
  That is a different pipeline and not what this one does.
- Provenance is also disabled (`--provenance=false`). If SLSA provenance is
  needed, it would have to be generated out-of-band (e.g. by the GitHub
  Actions workflow itself) and attached after publish, again changing the
  digest. Not in scope for this pipeline.
