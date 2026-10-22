# 0009 — Push trigger as image release surface

- **Date:** 2026-10-22
- **Status:** accepted
- **Deciders:** maintainers

## Context

The container image pipeline ([`build-publish.yml`](../.github/workflows/build-publish.yml))
previously fired only on `schedule` (daily), `workflow_dispatch`, and `pull_request`.
A Dockerfile change merged to main — whether by human PR or by the security workflow's
auto-merge digest bump — did **not** republish the image. The daily schedule then skipped
because the version tag already existed in both registries (the idempotency probe found
the old image and short-circuited). The practical effect: security patches to the base
image digest sat un-published until the next upstream npm release forced a rebuild.

Four trigger sources are now required:

| Source | Requirement |
|---|---|
| (a) New upstream `@squadrules/mcp` release → image | Hourly `npm view` poll |
| (b) Base OS / Node security patch → image | `security.yml` bumps digest → PR auto-merges → push trigger rebuilds |
| (c) Change to `mcp/Dockerfile` → image | `push` trigger filtered to `mcp/Dockerfile` + `.trivyignore` |
| CI auto-update without image release | Dependabot `github-actions` only; paths filter excludes `.github/workflows/**` |

Two constraints shaped the design:

1. **PR #2 standing directive**: *"do not set dependencies between mcp, containers, and
   charts repos at this time. Each repo operates independently."* — `repository_dispatch`
   from upstream was deliberately removed. The hourly poll honours this directive while
   providing ≤1h latency.
2. **GitHub's recursion rule**: *"events triggered by the GITHUB_TOKEN will not create a
   new workflow run."* The security workflow's auto-merge PR (previously using
   `secrets.GITHUB_TOKEN`) produced a merge push that could **not** fire the new push
   trigger. Requirement (b) was dead without switching to the shared App token
   (`squadrules-auto`), whose merge pushes DO trigger downstream workflows.

## Decision

1. **Add `push` trigger** to `build-publish.yml`, filtered to paths `mcp/Dockerfile` and
   `.trivyignore` on `main`. CI-only changes (`.github/workflows/**`, `scripts/**`,
   `README.md`, `docs/**`, `.qoder/**`, `CHANGELOG.md`, `.release-please-manifest.json`)
   are excluded by the paths filter and never trigger a release.

2. **Narrow the idempotency skip** to `schedule` events only. Previously the skip block
   ran for any non-`workflow_dispatch` event; a `push`-triggered run at an unchanged
   npm version would have probed the registries, found the old tag, and silently skipped.
   Now only the hourly reconciliation poll skips — push events always rebuild.

3. **Switch `security.yml` auto-merge** from `secrets.GITHUB_TOKEN` to the shared
   `squadrules-auto` App token (`AUTO_APP_ID` / `AUTO_APP_PRIVATE_KEY`). The auto-merge
   PR is authored by `squadrules-auto[bot]`; its merge push event CAN trigger
   `build-publish.yml`'s new push path. End-to-end: Trivy finds OS CVE → security.yml
   bumps digest → auto-merges PR → push event → build-publish rebuilds + republishes.

4. **Tighten the poll cadence** from daily (04:17 UTC) to hourly (`:17`). Upstream
   publishes ~2 releases/day; hourly reduces latency from ≤24h to ≤1h at negligible
   cost (the idempotency skip makes unchanged runs a ~5s no-op).

5. **No `repository_dispatch`**. The hourly poll is both simpler and more correct —
   upstream's release.yml creates the GitHub Release *before* npm Trusted Publishing
   completes, so a release-event hook could fire before the artifact exists. `npm view`
   can only succeed once it does.

## Consequences

- **≤1h upstream latency** for new npm versions (down from ≤24h).
- **Tag overwrite on Dockerfile-only changes**: a Dockerfile change at an unchanged npm
  version republishes `:X.Y.Z` at a new digest. This is the intended semantics of
  "security patch → new image". Consumers should pin by digest for reproducibility;
  tag-pinned consumers silently move to the new digest (which is the point).
- **Dependabot isolated by paths filter**: `.github/workflows/**` changes do not trigger
  a rebuild, so Dependabot's GitHub Actions updates never republish the image.
- **`pull_request` trigger stays unfiltered**: a paths filter on `pull_request` would
  strand non-image PRs on the "Container image pipeline passed" required check that
  never runs. The aggregate always reports.
- **Concurrent rebuilds are safe**: the existing `concurrency: container-image-pipeline-${{ github.ref }}`
  serialises per ref and does NOT cancel in-progress for non-PR events.
- **Legacy App installations can be deprecated** after ≥1 week of green runs on the
  shared App: `DOCS_APP_*`, `RELEASE_APP_*`, `squadrules-wiki-bot`, `squadrules-release`.
