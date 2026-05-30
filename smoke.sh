#!/usr/bin/env bash
# Cross-language media interop smoke test against the PUBLIC packages.
#
# Unlike the in-repo smoke test (which builds from the moq-dev/moq workspace),
# this stands up a relay and clients installed straight from public package
# registries: cargo / brew / apt for the Rust binaries, PyPI for Python, the
# Go module proxy for Go, and npm for the browser. The point is to catch breakage
# that only a real consumer would see: a missing wheel, a stale formula, an
# export that didn't survive packaging.
#
# It stands up a real moq-relay, then for each publisher language publishes an
# H.264 broadcast and confirms every subscriber sees data flowing (a non-empty
# frame before the timeout). We check that bytes move end-to-end across
# implementations, not that H.264 decodes.
set -euo pipefail

SMOKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENTS="$SMOKE_DIR/clients"

PUBLISHERS="rust"
SUBSCRIBERS="rust"
TIMEOUT="${SMOKE_TIMEOUT:-20}"
FPS="${SMOKE_FPS:-30}"
SIZE="${SMOKE_SIZE:-320x240}"
WARMUP="${SMOKE_WARMUP:-2}"
PORT="${SMOKE_PORT:-4443}"
URL="http://127.0.0.1:${PORT}"
NEGATIVE=0

# Binaries under test. Whatever channel installed them (cargo/brew/apt) just has
# to leave them on PATH; override here to point at a specific build.
RELAY="${RELAY_BIN:-moq-relay}"
MOQ="${MOQ_BIN:-moq-cli}"

require_value() {
    # require_value <flag> "$@": the flag plus the rest of the argv. Ensures a
    # non-flag value follows, so `set -u` doesn't abort on a bare `--timeout`.
    if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "error: $1 requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publishers)
            require_value "$@"
            PUBLISHERS="$2"
            shift 2
            ;;
        --subscribers)
            require_value "$@"
            SUBSCRIBERS="$2"
            shift 2
            ;;
        --timeout)
            require_value "$@"
            TIMEOUT="$2"
            shift 2
            ;;
        --negative)
            NEGATIVE=1
            shift
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

IFS=',' read -r -a PUB_LIST <<<"$PUBLISHERS"
IFS=',' read -r -a SUB_LIST <<<"$SUBSCRIBERS"

needs() {
    # needs <lang>: true if <lang> appears in either list.
    local lang="$1" x
    for x in "${PUB_LIST[@]}" "${SUB_LIST[@]}"; do [[ "$x" == "$lang" ]] && return 0; done
    return 1
}

TMP=$(mktemp -d)
RELAY_PID=""
PY=""           # python interpreter with moq-rs installed (set in prepare)
GO_SMOKE=""     # compiled Go client binary (set in prepare)
SWIFT_SMOKE=""  # compiled Swift client binary (set in prepare)
KOTLIN_SMOKE="" # Kotlin run script from `gradle installDist` (set in prepare)
C_SMOKE=""      # compiled C client binary (set in prepare)
BROKEN_LANGS="" # clients whose public package failed to install/build

mark_broken() {
    # A client whose published package won't install/build fails only its own
    # matrix cells, instead of aborting the whole run. That's the point: a broken
    # registry artifact should show up as a red cell, not hide every other result.
    BROKEN_LANGS="$BROKEN_LANGS $1"
    echo "  WARN  $1 client unavailable: $2"
}

is_broken() {
    local lang="$1" x
    for x in $BROKEN_LANGS; do [[ "$x" == "$lang" ]] && return 0; done
    return 1
}

kill_tree() {
    # SIGKILL, depth-first. moq-cli ignores SIGTERM (handles only SIGINT), so a
    # polite kill would leak it; these are ephemeral test processes, so -9 is fine.
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
    kill -KILL "$pid" 2>/dev/null || true
}

# shellcheck disable=SC2329  # invoked indirectly via 'trap cleanup EXIT'
cleanup() {
    # Reap the last publisher too; subscribers self-terminate via their timeouts.
    [[ -n "${PUB_PID:-}" ]] && kill_tree "$PUB_PID"
    [[ -n "$RELAY_PID" ]] && kill_tree "$RELAY_PID"
    rm -rf "$TMP"
}
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
    # Only the relay, CLI, and harness essentials are hard requirements. A missing
    # per-client toolchain (uv / go / bun / swift / gradle / cc) just marks that
    # client broken in prepare, so it fails its own cells instead of the whole run.
    local missing=() t
    for t in ffmpeg curl pgrep timeout; do
        have "$t" || missing+=("$t")
    done
    have "$RELAY" || missing+=("$RELAY (cargo/brew/apt/nix install moq-relay)")
    have "$MOQ" || missing+=("$MOQ (cargo/brew/apt/nix install moq-cli)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "error: missing required tools: ${missing[*]}" >&2
        exit 1
    fi
}

# Run swift with the Xcode toolchain. A loaded nix devShell exports SDKROOT /
# DEVELOPER_DIR pointing at a nix Apple SDK, which the Xcode swiftc rejects;
# clear those so swift picks its own matching SDK.
run_swift() {
    env -u SDKROOT -u DEVELOPER_DIR -u NIX_CFLAGS_COMPILE -u NIX_CFLAGS_LINK \
        -u CPATH -u LIBRARY_PATH -u MACOSX_DEPLOYMENT_TARGET swift "$@"
}

# Download the latest libmoq prebuilt release for this platform and compile the C
# client against it. The tarball ships include/moq.h + lib/libmoq.a.
c_prepare() {
    local cc="${CC:-cc}" target os_libs tag ver url root hdr=()
    have "$cc" || { echo "no C compiler ($cc) on PATH" >&2; return 1; }
    have curl || { echo "curl required" >&2; return 1; }
    have jq || { echo "jq required" >&2; return 1; }
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64) target=aarch64-apple-darwin ;;
        Darwin/x86_64) target=x86_64-apple-darwin ;;
        Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
        Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
        *) echo "unsupported platform: $(uname -s)/$(uname -m)" >&2; return 1 ;;
    esac
    case "$(uname -s)" in
        Darwin) os_libs="-framework CoreFoundation -framework Security" ;;
        *) os_libs="-lpthread -ldl -lm" ;;
    esac
    # Latest libmoq-v* release, never pinned. Authenticated if a token is around
    # (CI) to dodge the 60/hr anonymous GitHub API limit.
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    tag=$(curl -sf "${hdr[@]}" "https://api.github.com/repos/moq-dev/moq/releases?per_page=100" |
        jq -r '.[].tag_name' | grep '^libmoq-v' | head -1)
    [[ -n "$tag" ]] || { echo "no libmoq-v* release found" >&2; return 1; }
    ver=${tag#libmoq-v}
    url="https://github.com/moq-dev/moq/releases/download/$tag/moq-$ver-$target.tar.gz"
    echo "libmoq $tag ($target)"
    mkdir -p "$TMP/libmoq"
    curl -sfL "$url" | tar xz -C "$TMP/libmoq" || { echo "download/extract failed: $url" >&2; return 1; }
    root="$TMP/libmoq/moq-$ver-$target"
    # shellcheck disable=SC2086  # os_libs is a deliberate multi-flag word list
    "$cc" "$CLIENTS/c/subscribe.c" -I"$root/include" -L"$root/lib" -lmoq $os_libs -o "$C_SMOKE"
}

# ── setup ───────────────────────────────────────────────────────────────────
require_tools

# Surface any "we've drifted off latest" problem up front. Non-fatal here so the
# matrix still runs; `just freshness` / CI enforce it hard.
"$SMOKE_DIR/freshness.sh" || echo "WARN: freshness check failed (see above); continuing" >&2

echo "relay:   $(command -v "$RELAY")"
echo "moq-cli: $(command -v "$MOQ")"

if needs python; then
    echo "installing python client (moq-rs from PyPI)..."
    PY="$TMP/venv/bin/python"
    # Latest published wheel; sdist fallback needs a Rust toolchain + C compiler.
    if ! have uv; then
        mark_broken python "uv not found"
    elif uv venv --quiet "$TMP/venv" && uv pip install --quiet --python "$PY" moq-rs; then :; else
        mark_broken python "uv pip install moq-rs failed"
    fi
fi

if needs go; then
    echo "building go client (moq-dev/moq-go from the module proxy)..."
    GO_SMOKE="$TMP/go-smoke"
    # Pull the latest published module, then build the client against it.
    if ! have go; then
        mark_broken go "go not found"
    elif (cd "$CLIENTS/go" && go get "github.com/moq-dev/moq-go@latest" && CGO_ENABLED=1 go build -o "$GO_SMOKE" .) >"$TMP/go-build.log" 2>&1; then :; else
        mark_broken go "go get/build of moq-dev/moq-go failed"
        sed 's/^/        /' "$TMP/go-build.log" >&2 || true
    fi
fi

if needs js-browser; then
    echo "installing browser client (@moq/watch + @moq/publish from npm)..."
    # Nix provides Chromium via PLAYWRIGHT_BROWSERS_PATH; otherwise fetch it.
    js_prepare() {
        (cd "$CLIENTS/js" && bun install && bunx vite build) || return 1
        [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]] || (cd "$CLIENTS/js" && bunx playwright install chromium) || return 1
    }
    if ! have bun; then
        mark_broken js-browser "bun not found"
    elif js_prepare >"$TMP/js-build.log" 2>&1; then :; else
        mark_broken js-browser "npm install / vite build / playwright failed"
        sed 's/^/        /' "$TMP/js-build.log" >&2 || true
    fi
fi

if needs swift; then
    echo "building swift client (moq-dev/moq-swift via SPM)..."
    SWIFT_SMOKE="$CLIENTS/swift/.build/debug/smoke"
    # `from: 0.2.0` + `swift package update` resolves the latest 0.x each run.
    if ! have swift; then
        mark_broken swift "swift not found (needs the Xcode toolchain; macOS only)"
    elif (cd "$CLIENTS/swift" && run_swift package update && run_swift build) >"$TMP/swift-build.log" 2>&1; then :; else
        mark_broken swift "swift package update / build failed"
        sed 's/^/        /' "$TMP/swift-build.log" >&2 || true
    fi
fi

if needs kotlin; then
    echo "building kotlin client (dev.moq:moq from Maven Central)..."
    KOTLIN_SMOKE="$CLIENTS/kotlin/build/install/smoke/bin/smoke"
    # `latest.release` + disabled dynamic-version caching resolves the newest each run.
    if ! have gradle; then
        mark_broken kotlin "gradle not found"
    elif (cd "$CLIENTS/kotlin" && gradle --quiet --console=plain installDist) >"$TMP/kotlin-build.log" 2>&1; then :; else
        mark_broken kotlin "gradle installDist failed"
        sed 's/^/        /' "$TMP/kotlin-build.log" >&2 || true
    fi
fi

if needs c; then
    echo "building c client (libmoq prebuilt release)..."
    C_SMOKE="$TMP/c-smoke"
    if c_prepare >"$TMP/c-build.log" 2>&1; then :; else
        mark_broken c "libmoq download / compile failed"
        sed 's/^/        /' "$TMP/c-build.log" >&2 || true
    fi
fi

if curl -sf "$URL/certificate.sha256" >/dev/null 2>&1; then
    echo "error: something is already listening on 127.0.0.1:4443 (stale relay?)" >&2
    exit 1
fi

echo "starting relay on 127.0.0.1:${PORT}..."
# smoke.toml is the source of truth; rewrite its port into a scratch copy so a
# busy 4443 (a dev relay, a parallel run) doesn't require editing the committed file.
sed "s/4443/${PORT}/g" "$SMOKE_DIR/smoke.toml" >"$TMP/relay.toml"
"$RELAY" "$TMP/relay.toml" >"$TMP/relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 60); do
    curl -sf "$URL/certificate.sha256" >/dev/null 2>&1 && break
    sleep 0.5
done
if ! curl -sf "$URL/certificate.sha256" >/dev/null 2>&1; then
    echo "relay never became ready" >&2
    sed 's/^/  relay: /' "$TMP/relay.log" >&2 || true
    exit 1
fi

# ── client dispatch ─────────────────────────────────────────────────────────
# Encode an endless H.264 Annex-B stream from a synthetic source to stdout.
# Paced with -re so the broadcast streams in real time until the reader closes.
# Baseline + repeat-headers re-emits SPS/PPS before every keyframe so a late
# subscriber (or the stream importer) can initialize without the first packet.
ffmpeg_h264() {
    ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc=size=${SIZE}:rate=${FPS}" \
        -an -c:v libx264 -profile:v baseline -preset ultrafast -pix_fmt yuv420p \
        -x264-params "keyint=${FPS}:min-keyint=${FPS}:scenecut=0:repeat-headers=1" \
        -f h264 -
}

# Sets global PUB_PID. Called in the current shell (no command substitution) so
# $! refers to the backgrounded job and kill_tree can reap the whole pipeline.
# Every publisher just consumes the same ffmpeg Annex-B stream on stdin; the
# client frames it (moq-cli / the FFI importers only frame-and-forward, ffmpeg
# encodes).
PUB_PID=""
start_publisher() {
    local lang="$1" broadcast="$2" log="$TMP/pub-$1.log"
    case "$lang" in
        rust)
            (ffmpeg_h264 | "$MOQ" publish --url "$URL" --broadcast "$broadcast" avc3) >"$log" 2>&1 &
            ;;
        python)
            (ffmpeg_h264 | "$PY" "$CLIENTS/python/smoke.py" \
                publish --url "$URL" --broadcast "$broadcast") >"$log" 2>&1 &
            ;;
        go)
            (ffmpeg_h264 | "$GO_SMOKE" publish --url "$URL" --broadcast "$broadcast") >"$log" 2>&1 &
            ;;
        js-browser)
            # Headless Chromium encodes its own H.264 from a fake camera via
            # WebCodecs (lazily, once a subscriber creates demand).
            (cd "$CLIENTS/js" && bun driver.ts publish \
                --url "$URL" --broadcast "$broadcast") >"$log" 2>&1 &
            ;;
        *)
            echo "unknown publisher: $lang" >&2
            return 1
            ;;
    esac
    PUB_PID=$!
}

run_subscriber() {
    local lang="$1" broadcast="$2"
    case "$lang" in
        rust)
            # moq-cli only handles SIGINT, so -k forces SIGKILL if it ignores the
            # SIGTERM that fires when no data arrives within the timeout.
            local n
            n=$(timeout -k 3 "$TIMEOUT" "$MOQ" subscribe --url "$URL" --broadcast "$broadcast" \
                --format fmp4 2>/dev/null | head -c 1 | wc -c | tr -d ' ' || true)
            [[ "${n:-0}" -ge 1 ]]
            ;;
        python)
            "$PY" "$CLIENTS/python/smoke.py" \
                subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        go)
            "$GO_SMOKE" subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        swift)
            "$SWIFT_SMOKE" subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        kotlin)
            "$KOTLIN_SMOKE" subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        c)
            "$C_SMOKE" subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        js-browser)
            # Headless Chromium decodes via WebCodecs; exits 0 once a frame lands.
            (cd "$CLIENTS/js" && bun driver.ts subscribe \
                --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT")
            ;;
        *)
            echo "unknown subscriber: $lang" >&2
            return 1
            ;;
    esac
}

# ── matrix ──────────────────────────────────────────────────────────────────
overall=0

run_round() {
    local pub="$1" broadcast="$2" pub_pid="$3"
    local pids=() names=() i sub
    # Let the publisher announce the broadcast + catalog before subscribers
    # connect. Native subscribers tolerate the race, but the browser watch gives
    # up on a catalog RESET_STREAM if it connects first.
    [[ -n "$pub_pid" ]] && sleep "$WARMUP"
    for sub in "${SUB_LIST[@]}"; do
        if is_broken "$sub"; then
            echo "  FAIL  $pub -> $sub (subscriber client unavailable)"
            overall=1
            continue
        fi
        (run_subscriber "$sub" "$broadcast") >"$TMP/$pub-$sub.log" 2>&1 &
        pids+=("$!")
        names+=("$sub")
    done
    # A publisher that streams forever should still be alive; if it died, the
    # subscriber failures below are a publisher bug, so surface its log.
    if [[ -n "$pub_pid" ]] && ! kill -0 "$pub_pid" 2>/dev/null; then
        echo "  WARN  publisher '$pub' exited early:"
        sed 's/^/        /' "$TMP/pub-$pub.log" 2>/dev/null || true
    fi
    local want_pass=1 got
    [[ "$NEGATIVE" -eq 1 ]] && want_pass=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then got=1; else got=0; fi
        if [[ "$got" -eq "$want_pass" ]]; then
            echo "  PASS  $pub -> ${names[$i]}"
        else
            echo "  FAIL  $pub -> ${names[$i]}"
            sed 's/^/        /' "$TMP/$pub-${names[$i]}.log" 2>/dev/null || true
            overall=1
        fi
    done
    if [[ -n "$pub_pid" ]]; then
        kill_tree "$pub_pid"
        wait "$pub_pid" 2>/dev/null || true
        # Don't let cleanup() later signal this now-reaped (possibly recycled) PID.
        [[ "${PUB_PID:-}" == "$pub_pid" ]] && PUB_PID=""
    fi
    return 0
}

if [[ "$NEGATIVE" -eq 1 ]]; then
    # Negative control: no publisher. Every subscriber must FAIL (time out with
    # no data), proving the harness can actually report failure.
    echo "=== negative control: subscribers expect NO data ==="
    run_round "none" "smoke-missing-$$-$RANDOM.hang" ""
else
    for pub in "${PUB_LIST[@]}"; do
        broadcast="smoke-${pub}-$$-${RANDOM}.hang"
        echo "=== publisher: $pub  broadcast: $broadcast ==="
        if is_broken "$pub"; then
            for sub in "${SUB_LIST[@]}"; do
                echo "  FAIL  $pub -> $sub (publisher client unavailable)"
            done
            overall=1
            continue
        fi
        start_publisher "$pub" "$broadcast"
        run_round "$pub" "$broadcast" "$PUB_PID"
    done
fi

if [[ "$overall" -eq 0 ]]; then
    echo "smoke: all checks passed"
else
    echo "smoke: FAILURES detected" >&2
fi
exit "$overall"
