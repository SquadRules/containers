# 0003 — Digest pin plus apt-get upgrade layer and expiring-ignore risk register

- **Date:** 2026-10-08
- **Status:** accepted
- **Deciders:** maintainers

## Context

The original plan assumed that digest-pinning the base image would replace the
need for an OS-level upgrade layer: pin the digest, get a known-good snapshot,
done. That premise was falsified during implementation.

Trivy against the image built from the pinned
`node:24-bookworm-slim@sha256:d6aa75…` digest reported **56 CRITICAL/HIGH**
findings. The pinned digest resolves to the *current* Debian snapshot
upstream publishes today — pinning it is supply-chain integrity (the build
always uses exactly this content), not OS remediation (the content itself
carries whatever Debian has published, including its backlog of `affected`,
`fix_deferred`, and `will_not_fix` findings).

Three response options were on the table:

1. **Ignore status, use `--ignore-unfixed`.** Rejected: this weakens npm
   library scanning too (the flag is global, not scoped to OS packages), and
   the image still installs one npm package with transitive dependencies.
2. **Switch to a distroless base.** Rejected: distroless drops `apt` entirely,
   which removes the ability to take an upgrade when Debian does publish a fix
   — the opposite of what we need for a risk register.
3. **Add an upgrade layer and carry the remainder in `.trivyignore` with
   expiring review dates.** Accepted.

## Decision

The Dockerfile has four stages: `deps → model → os-base → runtime`.

- The **`os-base`** stage runs `apt-get update && apt-get upgrade -y --no-install-recommends`
  on top of the same digest-pinned base, then installs `libgomp1`. It is kept
  as a named stage so the security workflow can build and scan exactly this
  layer (`docker buildx build --target os-base`) without re-creating the apt
  invocation.
- The **runtime** stage is `FROM os-base`, so it inherits the upgraded
  packages.
- **`.trivyignore`** carries the findings Debian has no fix for. Each entry is
  a bare `CVE-YYYY-NNNNN exp:YYYY-MM-DD` line (the expiry guard
  `scripts/ci-check-trivyignore-expiry.py` validates the dates in CI). The
  `exp:` date is a review commitment, not an auto-expire: when it passes, the
  guard fails the Security workflow and a maintainer re-evaluates whether
  Debian has since published a fix, whether the package is still reachable, or
  whether the ignore should be extended.
- Each ignore entry carries a per-family reachability rationale in a comment
  (which packages, why the server does not load them, what would have to be
  true for the finding to be exploitable in this image).

The two npm-bundled CVEs that were in the old `.trivyignore`
(`CVE-2026-12151`, `CVE-2026-93748`) were pruned: the runtime stage deletes
the npm CLI, so those libraries are no longer present in the image at all.

## Consequences

- The upgrade layer closes the fixable findings (perl-base
  `5.36.0-7+deb12u3 → 5.36.0-7+deb12u4`, seven CVEs) on every image build.
- The 11 remaining findings are `affected` / `fix_deferred` / `will_not_fix`
  in Debian bookworm and are accepted with a review date of 2027-04-01.
- Trivy against the built image reports **0 CRITICAL/HIGH** with the ignore
  file applied.
- The security workflow's base-OS job scans `--target os-base` with
  `.trivyignore` applied; when upstream publishes a new digest, the workflow
  rebuilds, rescans, and opens a PR if the digest has moved. See
  [ADR-0008](0008-os-base-scan-target.md).
- The `exp:` dates are a maintenance commitment. The expiry guard script is
  the enforcement mechanism; it runs in the Security workflow.
