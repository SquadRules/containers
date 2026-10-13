#!/usr/bin/env bash
#
# Image smoke test for the SquadRules MCP container.
#
# Runs against a locally loaded image (the pipeline loads one architecture at a time out of
# the OCI archive with skopeo) and proves the HTTP server the image exists to serve:
#
#   1. package version inside the image matches the npm version it was built from;
#   2. the embedding model is baked in, so a boot never depends on registry egress;
#   3. default (zero env) — the image's baked TRANSPORT_TYPE=http / AUTH_ENABLED=false must
#      bring up /health on an EMPTY environment, report the embedded LanceDB backend, then shut
#      down on SIGTERM without being killed on timeout. Reaching /health also proves the native
#      fastembed/onnxruntime modules load on this architecture (npm optional platform deps are
#      per-arch): startup embeds the bundled adapters before /health answers.
#
# Usage: ci-smoke-image.sh <image-ref> <expected-package-version> [--platform <platform>]
#
# The deadline defaults to 600s because startup embeds the bundled adapters with a local ONNX
# model; under QEMU (the arm64 leg of an x86 CI runner) that is roughly an order of magnitude
# slower than native and overruns 600s, so the pipeline raises SMOKE_CLUSTER_DEADLINE for the
# arm64 leg. Override it here for any other slow host.
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") <image-ref> <expected-package-version> [--platform <platform>]" >&2
    exit 2
}

# Accept the platform both as `--platform <value>` (the form the pipeline uses) and as
# `--platform=<value>`; the image ref and expected version are positional in any order
# relative to the flag. A naive `$1/$2/$3` read would drop the value that follows a bare
# `--platform` and fall through to usage.
IMAGE=""
VERSION=""
PLATFORM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            [ $# -ge 2 ] || usage
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#--platform=}"
            shift
            ;;
        *)
            if [ -z "$IMAGE" ]; then IMAGE="$1"
            elif [ -z "$VERSION" ]; then VERSION="$1"
            else usage
            fi
            shift
            ;;
    esac
done
[ -n "$IMAGE" ] && [ -n "$VERSION" ] || usage
[ -n "$PLATFORM" ] || PLATFORM=""

# The architecture is always pinned explicitly: it names the platform that was actually
# exercised in the log, and a non-empty RUN_ARGS keeps `set -u` working on bash 3.2 (macOS),
# where expanding an empty array is a hard error.
if [ -z "$PLATFORM" ]; then
    case "$(uname -m)" in
        arm64|aarch64) PLATFORM=linux/arm64 ;;
        x86_64|amd64) PLATFORM=linux/amd64 ;;
        *)
            echo "::error::unrecognised host architecture '$(uname -m)'; pass --platform explicitly" >&2
            exit 2
            ;;
    esac
fi
RUN_ARGS=(--platform "$PLATFORM")

WORKDIR_TMP="$(mktemp -d)"
CONTAINERS=()
cleanup() {
    if [ ${#CONTAINERS[@]} -gt 0 ]; then
        for cid in "${CONTAINERS[@]}"; do
            docker rm -f "$cid" >/dev/null 2>&1 || true
        done
    fi
    rm -rf "$WORKDIR_TMP"
}
trap cleanup EXIT

say() { printf '\n=== %s ===\n' "$*"; }

# docker stop measures SIGTERM handling: it returns as soon as PID 1 acts on the signal, so
# consuming the whole grace window means the signal was ignored — the regression `--init` exists
# to avoid, because `squadrules serve` spawns the server as a child rather than exec'ing it.
stop_measured() {
    local target="$1" label="$2" grace="${3:-20}" started seconds
    started=$SECONDS
    if ! docker stop -t "$grace" "$target" >/dev/null 2>&1; then
        echo "::error::docker stop failed for the ${label} container" >&2
        return 1
    fi
    seconds=$((SECONDS - started))
    if [ "$seconds" -ge "$grace" ]; then
        echo "::error::${label} container ignored SIGTERM (docker stop took ${seconds}s)" >&2
        return 1
    fi
    echo "ok: ${label} graceful shutdown in ${seconds}s"
}

say "1) package version is ${VERSION}"
actual="$(docker run --rm "${RUN_ARGS[@]}" --entrypoint node "$IMAGE" \
    -p "require('./node_modules/@squadrules/mcp/package.json').version")"
if [ "$actual" != "$VERSION" ]; then
    echo "::error::image reports package version '${actual}', expected '${VERSION}'" >&2
    exit 1
fi
echo "ok: ${actual}"

say "2) embedding model is baked into the image"
# Any non-empty model directory is enough: the model id is whatever the installed package
# defaults to, and the app resolves the same path from FASTEMBED_CACHE_DIR at runtime.
model_dir="$(docker run --rm "${RUN_ARGS[@]}" --entrypoint sh "$IMAGE" -c \
    'ls -A "${FASTEMBED_CACHE_DIR:-/opt/squadrules/models}" 2>/dev/null | head -1')"
if [ -z "$model_dir" ]; then
    echo "::error::${FASTEMBED_CACHE_DIR:-/opt/squadrules/models} is empty — the build did not bake the local embedding model" >&2
    exit 1
fi
echo "ok: ${model_dir}"

say "3) default (zero env): HTTP transport boots, serves /health, stops on signal"
# No -e flags: this leg proves the image's baked default (TRANSPORT_TYPE=http, AUTH_ENABLED=false)
# boots a reachable, self-contained server on an empty environment. Reaching /health 200 with no
# Keycloak vars at all is also the proof that auth is off by default (auth-on would fail startup).
cluster_cid="$(docker run -d --init "${RUN_ARGS[@]}" --name "squadrules-smoke-default-${RANDOM}" \
    -p 127.0.0.1::3000 \
    "$IMAGE")"
CONTAINERS+=("$cluster_cid")
host_port="$(docker port "$cluster_cid" 3000/tcp | head -1 | sed 's/.*://')"

health=""
deadline=$((SECONDS + ${SMOKE_CLUSTER_DEADLINE:-600}))
while [ "$SECONDS" -lt "$deadline" ]; do
    health="$(curl -fsS --max-time 5 "http://127.0.0.1:${host_port}/health" 2>/dev/null || true)"
    [ -n "$health" ] && break
    if ! docker inspect -f '{{.State.Running}}' "$cluster_cid" | grep -q true; then
        echo "::error::default-mode container exited before serving /health" >&2
        docker logs --tail 40 "$cluster_cid" >&2 || true
        exit 1
    fi
    sleep 5
done
if [ -z "$health" ]; then
    echo "::error::/health never answered on 127.0.0.1:${host_port}" >&2
    docker logs --tail 40 "$cluster_cid" >&2 || true
    exit 1
fi
printf '%s' "$health" | node -e '
let raw = "";
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  const h = JSON.parse(raw);
  const problems = [];
  if (h.status !== "healthy") problems.push("status=" + h.status);
  if (h.transport !== "http") problems.push("transport=" + h.transport);
  const backend = (h.details || {}).vectorStoreBackend || "";
  // With no QDRANT_URL the baked http default selects the embedded store; that is the contract.
  if (backend !== "embedded-lancedb") problems.push("vectorStoreBackend=" + backend);
  if (problems.length) { console.error(problems.join(", ")); process.exit(1); }
  console.log("ok: /healthy over http, backend=" + backend);
});
' || {
    echo "::error::unexpected /health payload: $health" >&2
    exit 1
}

# Graceful shutdown (see stop_measured).
stop_measured "$cluster_cid" default || exit 1

say "smoke passed for ${IMAGE}${PLATFORM:+ (${PLATFORM})}"
