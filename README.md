# SquadRules MCP — minimal npm-based container

An independent packaging experiment for the **published** `@squadrules/mcp`
npm package. No application build, no source checkout, and no extra service
containers.

## Build and run

```sh
docker build -t squadrules-mcp-npm .
docker run --rm -p 3000:3000 squadrules-mcp-npm
```

After the GitHub Actions push job succeeds:

```sh
docker run --rm -p 3000:3000 ghcr.io/squadrules/mcp-npm:latest
```

The image runs `squadrules serve` with HTTP transport on port 3000.
The server uses the non-root `node` user and its home directory is writable.
`AUTH_ENABLED=false` is for local evaluation only: **do not expose this
configuration directly to the public Internet.** Configure authentication
and persistent storage before production use.

## Release process

- `package.json` pins the published npm version (currently `5.12.1`).
- The GitHub Actions workflow builds both `linux/amd64` and `linux/arm64`,
  publishes the `latest` and commit-SHA tags to `ghcr.io/squadrules/mcp-npm`,
  and checks PR builds without publishing them.
- Docker, GitHub Actions, and npm dependencies are eligible for Dependabot
  version updates.
- **GitHub limitation:** Dependabot only reads `.github/dependabot.yml` from
  the repository's *default* branch. This orphan branch is a standalone
  experiment; until it becomes default, the config must also be added to
  `main` with `target-branch: orphan/npm-ghcr` for each ecosystem.
- A package lockfile is not committed in this minimal prototype, so
  transitive dependencies may change between builds. For reproducible
  production releases, generate and commit `package-lock.json` with
  `npm install --package-lock-only` and change `npm install` to `npm ci`.

The image name is intentionally separate from `ghcr.io/squadrules/mcp`,
so this experiment cannot overwrite an established production `latest` tag.
