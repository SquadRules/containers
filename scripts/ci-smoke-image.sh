#!/usr/bin/env bash
#
# Image smoke test for the SquadRules MCP container.
#
# Runs against a locally loaded image (the pipeline loads one architecture at a time out of
# the OCI archive with skopeo) and proves the two runtime modes the image exists to serve:
#
#   1. package version inside the image matches the npm version it was built from;
#   2. the embedding model is baked in, so a boot never depends on registry egress;
#   3. stdio override — TRANSPORT_TYPE=stdio must answer an MCP initialize/tools/list handshake
#      over stdin/stdout. This is the check that proves the stdio transport and the native
#      fastembed/onnxruntime modules actually load on this architecture (npm optional platform
#      deps are per-arch);
#   4. default (zero env) — the image's baked TRANSPORT_TYPE=http / AUTH_ENABLED=false must
#      bring up /health on an EMPTY environment, report the embedded LanceDB backend, then shut
#      down on SIGTERM without being killed on timeout.
#
# Usage: ci-smoke-image.sh <image-ref> <expected-package-version> [--platform <platform>]
#
# Deadlines default to 600s per mode because startup embeds the bundled adapters with a local
# ONNX model; under QEMU (the arm64 leg of an x86 CI runner) that is several times slower than
# native. Override with SMOKE_SIMPLE_DEADLINE / SMOKE_CLUSTER_DEADLINE.
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

say "3) stdio override: MCP handshake over stdin/stdout (TRANSPORT_TYPE=stdio)"
# Startup is the slow part (bundled-adapter injection through the local ONNX model), so the
# response — not a fixed sleep — decides when we are done. stdin is held open on a fifo for the
# whole leg: a client keeps the pipe of a stdio MCP server alive, so the container is named and
# torn down by signal rather than by stdin EOF.
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"containers-smoke","version":"1"}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'
TOOLS_LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
simple_cid="squadrules-smoke-simple-${RANDOM}"
mkfifo "$WORKDIR_TMP/simple-stdin"
docker run -i --rm --init --name "$simple_cid" "${RUN_ARGS[@]}" \
    -e TRANSPORT_TYPE=stdio "$IMAGE" \
    < "$WORKDIR_TMP/simple-stdin" > "$WORKDIR_TMP/simple-out" 2> "$WORKDIR_TMP/simple-err" &
simple_pid=$!
CONTAINERS+=("$simple_cid")
exec 9>"$WORKDIR_TMP/simple-stdin"
printf '%s\n%s\n%s\n' "$INIT" "$INITIALIZED" "$TOOLS_LIST" >&9

deadline=$((SECONDS + ${SMOKE_SIMPLE_DEADLINE:-600}))
handshake=no
while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -q '"serverInfo"' "$WORKDIR_TMP/simple-out" 2>/dev/null \
        && grep -q '"tools"' "$WORKDIR_TMP/simple-out" 2>/dev/null; then
        handshake=yes
        break
    fi
    # The docker CLI exiting means the server died before answering; stop polling.
    kill -0 "$simple_pid" 2>/dev/null || break
    sleep 5
done

exec 9>&- || true
if [ "$handshake" != yes ]; then
    echo "::error::stdio mode never answered the MCP handshake (initialize + tools/list)" >&2
    echo "::error::stdout was $(wc -c < "$WORKDIR_TMP/simple-out") byte(s) within ${SMOKE_SIMPLE_DEADLINE:-600}s" >&2
    tail -40 "$WORKDIR_TMP/simple-err" >&2 || true
    exit 1
fi
# A stdio server must not open a listener; the banner is the assertion that it did not. The
# banner line is `  http:       no listener (...)` (see mcp stdio-banner.ts); match it with a
# spacing-tolerant regex so a re-indent there does not silently break this leg.
if ! grep -qE 'http:[[:space:]]+no listener' "$WORKDIR_TMP/simple-err"; then
    echo "::error::expected the stdio banner ('http: no listener') on stderr" >&2
    tail -20 "$WORKDIR_TMP/simple-err" >&2 || true
    exit 1
fi
echo "ok: initialize + tools/list served over stdio, no listener opened"
stop_measured "$simple_cid" stdio || exit 1
# `--rm` already removed the container; the entry stays in CONTAINERS so an early exit between
# stop and reap still cleans up (docker rm -f on a gone container is silently ignored).
wait "$simple_pid" 2>/dev/null || true   # reaped after docker stop; exit status is the signal's

say "4) default (zero env): HTTP transport boots, serves /health, stops on signal"
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
