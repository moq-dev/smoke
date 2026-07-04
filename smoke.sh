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
PORT="${SMOKE_PORT:-4443}"
URL="http://127.0.0.1:${PORT}"
NEGATIVE=0

# Binaries under test. Whatever channel installed them (cargo/brew/apt) just has
# to leave them on PATH; override here to point at a specific build.
RELAY="${RELAY_BIN:-moq-relay}"
# Name of the docker-channel relay container, shared with clients/docker/moq-relay
# so cleanup() can reap it after a SIGKILL of the wrapper (see cleanup()). Exported
# so the wrapper binds the same name; ignored by the non-docker channels.
RELAY_CONTAINER="${MOQ_RELAY_CONTAINER:-moq-relay-smoke}"
export MOQ_RELAY_CONTAINER="$RELAY_CONTAINER"
# The CLI binary under test. The package/crate is still distributed as moq-cli in
# some channels, but the installed executable is `moq`. Honor MOQ_BIN if set.
MOQ="${MOQ_BIN:-}"

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
PY=""             # python interpreter with moq-rs installed (set in prepare)
GO_SMOKE=""       # compiled Go client binary (set in prepare)
SWIFT_SMOKE=""    # compiled Swift client binary (set in prepare)
KOTLIN_SMOKE=""   # Kotlin run script from `gradle installDist` (set in prepare)
C_SMOKE=""        # C client, hand-rolled -I/-L/-l build (set in prepare)
C_PC_SMOKE=""     # C client, built via pkg-config + moq.pc (set in prepare)
C_CMAKE_SMOKE=""  # C client, built via the shipped CMake package (set in prepare)
LIBMOQ_ROOT=""    # extracted libmoq prebuilt tarball root, shared by the 3 C builds
LIBMOQ_OS_LIBS="" # system libs for the hand-rolled C build (set in libmoq_fetch)
GST_PLUGIN_DIR="" # dir holding the moq-gst plugin (libgstmoq.{so,dylib}; set in prepare)
BROKEN_LANGS=""   # clients whose public package failed to install/build

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
    # SIGKILL, depth-first. moq ignores SIGTERM (handles only SIGINT), so a
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
    # The docker-channel relay runs in a container that outlives a SIGKILL of its
    # wrapper's runtime client, so kill_tree alone leaves it holding the port and
    # blocking the next run in the same job. Reap it by name -- but only when the
    # docker wrapper is actually the relay, so a non-docker run on a host that
    # happens to have docker doesn't delete an unrelated container of that name.
    if [[ "$RELAY" == */clients/docker/moq-relay ]] && have "${SMOKE_DOCKER:-docker}"; then
        "${SMOKE_DOCKER:-docker}" rm -f "$RELAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
    # Resolve the CLI binary name unless MOQ_BIN pinned it.
    if [[ -z "$MOQ" ]]; then
        MOQ=moq
    fi
    # Only the relay, CLI, and harness essentials are hard requirements. A missing
    # per-client toolchain (uv / go / bun / swift / gradle / cc) just marks that
    # client broken in prepare, so it fails its own cells instead of the whole run.
    local missing=() t
    for t in ffmpeg curl pgrep timeout; do
        have "$t" || missing+=("$t")
    done
    have "$RELAY" || missing+=("$RELAY (cargo/brew/apt/nix install moq-relay)")
    have "$MOQ" || missing+=("moq (cargo/brew/apt/nix install moq-cli)")
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

# Download the latest libmoq prebuilt release for this platform. Sets LIBMOQ_ROOT
# (extracted tarball root) and LIBMOQ_OS_LIBS (system libs for the hand-rolled
# build). Idempotent: the three C build variants share one download. The tarball
# ships include/moq.h, lib/libmoq.a, lib/pkgconfig/moq.pc and lib/cmake/moq/.
libmoq_fetch() {
    [[ -n "$LIBMOQ_ROOT" && -d "$LIBMOQ_ROOT" ]] && return 0
    local target tag ver url hdr=()
    have curl || {
        echo "curl required" >&2
        return 1
    }
    have jq || {
        echo "jq required" >&2
        return 1
    }
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64) target=aarch64-apple-darwin ;;
        Darwin/x86_64) target=x86_64-apple-darwin ;;
        Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
        Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
        *)
            echo "unsupported platform: $(uname -s)/$(uname -m)" >&2
            return 1
            ;;
    esac
    case "$(uname -s)" in
        Darwin) LIBMOQ_OS_LIBS="-framework CoreFoundation -framework Security" ;;
        *) LIBMOQ_OS_LIBS="-lpthread -ldl -lm" ;;
    esac
    # Latest libmoq-v* release, never pinned. Authenticated if a token is around
    # (CI) to dodge the 60/hr anonymous GitHub API limit.
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    # macOS ships bash 3.2, where "${hdr[@]}" on an empty array trips `set -u`;
    # the ${arr[@]+...} guard expands to nothing when the array is unset/empty.
    tag=$(curl -sf ${hdr[@]+"${hdr[@]}"} "https://api.github.com/repos/moq-dev/moq/releases?per_page=100" |
        jq -r '.[].tag_name' | grep '^libmoq-v' | head -1)
    [[ -n "$tag" ]] || {
        echo "no libmoq-v* release found" >&2
        return 1
    }
    ver=${tag#libmoq-v}
    url="https://github.com/moq-dev/moq/releases/download/$tag/moq-$ver-$target.tar.gz"
    echo "libmoq $tag ($target)"
    mkdir -p "$TMP/libmoq"
    curl -sfL "$url" | tar xz -C "$TMP/libmoq" || {
        echo "download/extract failed: $url" >&2
        return 1
    }
    LIBMOQ_ROOT="$TMP/libmoq/moq-$ver-$target"
}

# Hand-rolled build: -I/-L/-l with system libs we hardcode here. The baseline
# "does the static archive link at all" check; ignores moq.pc and the CMake
# config entirely.
c_build_direct() {
    local cc="${CC:-cc}" out="$1"
    have "$cc" || {
        echo "no C compiler ($cc) on PATH" >&2
        return 1
    }
    # shellcheck disable=SC2086  # LIBMOQ_OS_LIBS is a deliberate multi-flag word list
    "$cc" "$CLIENTS/c/subscribe.c" -I"$LIBMOQ_ROOT/include" -L"$LIBMOQ_ROOT/lib" -lmoq \
        $LIBMOQ_OS_LIBS -o "$out"
}

# pkg-config build: resolve cflags/libs from the shipped moq.pc, the way a real
# consumer (e.g. FFmpeg --enable-libmoq) does. libmoq is a static archive, so
# --static pulls Libs.private (the system frameworks/libs) too. A wrong
# includedir/libdir or a missing framework in moq.pc fails here -- exactly the
# breakage the hand-rolled build above can't see.
c_build_pkgconfig() {
    local cc="${CC:-cc}" out="$1" cflags libs
    have "$cc" || {
        echo "no C compiler ($cc) on PATH" >&2
        return 1
    }
    have pkg-config || {
        echo "pkg-config not on PATH (apt install pkg-config / brew install pkgconf)" >&2
        return 1
    }
    export PKG_CONFIG_PATH="$LIBMOQ_ROOT/lib/pkgconfig"
    cflags=$(pkg-config --cflags moq) || {
        echo "pkg-config --cflags moq failed" >&2
        return 1
    }
    libs=$(pkg-config --static --libs moq) || {
        echo "pkg-config --static --libs moq failed" >&2
        return 1
    }
    # shellcheck disable=SC2086  # cflags/libs are deliberate multi-flag word lists
    "$cc" "$CLIENTS/c/subscribe.c" $cflags $libs -o "$out"
}

# CMake build: find_package(moq) against the shipped lib/cmake/moq package, the
# way a CMake consumer imports the moq::moq target. A broken config (wrong paths,
# missing target or system libs) fails configure/build here. CMAKE_PREFIX_PATH
# points at the extracted tarball root; the binary lands at <builddir>/smoke.
c_build_cmake() {
    local builddir="$1"
    have cmake || {
        echo "cmake not on PATH (apt install cmake / brew install cmake)" >&2
        return 1
    }
    rm -rf "$builddir"
    cmake -S "$CLIENTS/c" -B "$builddir" -DCMAKE_PREFIX_PATH="$LIBMOQ_ROOT" \
        -DCMAKE_BUILD_TYPE=Release >/dev/null || {
        echo "cmake configure failed" >&2
        return 1
    }
    cmake --build "$builddir" >/dev/null || {
        echo "cmake build failed" >&2
        return 1
    }
}

# Download the latest moq-gst prebuilt release for this platform and confirm the
# plugin loads against the host's *system* GStreamer. The plugin (libgstmoq.so /
# .dylib) dynamic-links libgstreamer, so this is the customer-facing scenario:
# install the .deb / brew tap / tarball, then `gst-inspect-1.0 moq`. Sets
# GST_PLUGIN_DIR to the dir holding the plugin. moqsrc connects over the network,
# so it's relay-channel-agnostic; GST_PLUGIN_DIR + a system GStreamer is all it
# needs. (Local nix shells have no GStreamer, and a prebuilt plugin wouldn't link
# against nixpkgs' gst anyway, so this cell wants a real system gst install.)
gst_prepare() {
    local target tag ver url root hdr=()
    have gst-launch-1.0 || {
        echo "gst-launch-1.0 not on PATH (apt install gstreamer1.0-tools / brew install gstreamer)" >&2
        return 1
    }
    have gst-inspect-1.0 || {
        echo "gst-inspect-1.0 not on PATH" >&2
        return 1
    }
    # Escape hatch: point at a locally-built plugin dir (e.g. target/release after
    # `cargo build -p moq-gst`) instead of the published tarball, mirroring the
    # RELAY_BIN/MOQ_BIN overrides. Skips the download but still load-checks it.
    if [[ -n "${MOQ_GST_PLUGIN_DIR:-}" ]]; then
        GST_PLUGIN_DIR="$MOQ_GST_PLUGIN_DIR"
        echo "moq-gst (local: $GST_PLUGIN_DIR)"
        [[ -d "$GST_PLUGIN_DIR" ]] || {
            echo "MOQ_GST_PLUGIN_DIR is not a directory: $GST_PLUGIN_DIR" >&2
            return 1
        }
        GST_PLUGIN_PATH_1_0="$GST_PLUGIN_DIR" GST_PLUGIN_SYSTEM_PATH_1_0="" \
            GST_REGISTRY_1_0="$TMP/gst-registry.bin" \
            gst-inspect-1.0 moq 2>/dev/null | grep -qE '^[[:space:]]+moqsrc:' ||
            {
                echo "moqsrc not exposed (plugin failed to load against this GStreamer)" >&2
                return 1
            }
        return 0
    fi
    have curl || {
        echo "curl required" >&2
        return 1
    }
    have jq || {
        echo "jq required" >&2
        return 1
    }
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64) target=aarch64-apple-darwin ;;
        Darwin/x86_64) target=x86_64-apple-darwin ;;
        Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
        Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
        *)
            echo "unsupported platform: $(uname -s)/$(uname -m)" >&2
            return 1
            ;;
    esac
    # Latest moq-gst-v* release, never pinned. Authenticated if a token is around
    # (CI) to dodge the 60/hr anonymous GitHub API limit.
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    tag=$(curl -sf ${hdr[@]+"${hdr[@]}"} "https://api.github.com/repos/moq-dev/moq/releases?per_page=100" |
        jq -r '.[].tag_name' | grep '^moq-gst-v' | head -1)
    [[ -n "$tag" ]] || {
        echo "no moq-gst-v* release found" >&2
        return 1
    }
    ver=${tag#moq-gst-v}
    url="https://github.com/moq-dev/moq/releases/download/$tag/moq-gst-$ver-$target.tar.gz"
    echo "moq-gst $tag ($target)"
    mkdir -p "$TMP/moq-gst"
    curl -sfL "$url" | tar xz -C "$TMP/moq-gst" || {
        echo "download/extract failed: $url" >&2
        return 1
    }
    root="$TMP/moq-gst/moq-gst-$ver-$target"
    GST_PLUGIN_DIR="$root/lib/gstreamer-1.0"
    [[ -d "$GST_PLUGIN_DIR" ]] || {
        echo "plugin dir missing in tarball: $GST_PLUGIN_DIR" >&2
        return 1
    }
    # gst-inspect exits 0 even when the .so fails to load, so grep for the
    # factory. Isolate discovery to our dir + a temp registry so a system-wide moq
    # plugin can't shadow it (mirrors moq-gst's own smoke.sh).
    GST_PLUGIN_PATH_1_0="$GST_PLUGIN_DIR" GST_PLUGIN_SYSTEM_PATH_1_0="" \
        GST_REGISTRY_1_0="$TMP/gst-registry.bin" \
        gst-inspect-1.0 moq 2>/dev/null | grep -qE '^[[:space:]]+moqsrc:' ||
        {
            echo "moqsrc not exposed (plugin failed to load against this GStreamer)" >&2
            return 1
        }
}

# ── setup ───────────────────────────────────────────────────────────────────
require_tools

# Surface any "we've drifted off latest" problem up front. Non-fatal here so the
# matrix still runs; `just freshness` / CI enforce it hard.
"$SMOKE_DIR/freshness.sh" || echo "WARN: freshness check failed (see above); continuing" >&2

echo "relay:   $(command -v "$RELAY")"
echo "moq:     $(command -v "$MOQ")"

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

# The browser client ships three delivery variants (js-vite, js-esbuild,
# js-jsdelivr) that all drive the same <moq-publish>/<moq-watch> elements; they
# differ only in how the published npm packages reach the page.
if needs js-vite || needs js-esbuild || needs js-jsdelivr; then
    echo "installing browser clients (@moq/watch + @moq/publish from npm)..."
    if ! have bun; then
        for v in js-vite js-esbuild js-jsdelivr; do mark_broken "$v" "bun not found"; done
    else
        js_base() {
            (cd "$CLIENTS/js" && bun install) || return 1
            # Nix provides Chromium via PLAYWRIGHT_BROWSERS_PATH; otherwise fetch it.
            [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]] || (cd "$CLIENTS/js" && bunx playwright install chromium) || return 1
        }
        if js_base >"$TMP/js-base.log" 2>&1; then
            # jsdelivr imports from the CDN at runtime, so it needs no build. The
            # bundler variants each build their own page; a build failure fails
            # only that variant.
            if needs js-vite && ! (cd "$CLIENTS/js" && bunx vite build) >"$TMP/js-vite.log" 2>&1; then
                mark_broken js-vite "vite build failed"
                sed 's/^/        /' "$TMP/js-vite.log" >&2 || true
            fi
            if needs js-esbuild && ! (cd "$CLIENTS/js" && bun build-esbuild.ts) >"$TMP/js-esbuild.log" 2>&1; then
                mark_broken js-esbuild "esbuild build failed"
                sed 's/^/        /' "$TMP/js-esbuild.log" >&2 || true
            fi
        else
            for v in js-vite js-esbuild js-jsdelivr; do mark_broken "$v" "bun install / playwright failed"; done
            sed 's/^/        /' "$TMP/js-base.log" >&2 || true
        fi
    fi
fi

# Native (non-browser) JS: the published @moq/net + @moq/hang under a runtime
# with no native WebTransport, using moq's own @moq/web-transport polyfill.
# Run under bun (js-native-bun) and node (js-native-node).
if needs js-native-bun || needs js-native-node; then
    echo "installing native-js client (@moq/net + @moq/hang + webtransport polyfill)..."
    if ! have bun; then
        for v in js-native-bun js-native-node; do mark_broken "$v" "bun not found (needed to install)"; done
    elif (cd "$CLIENTS/js-native" && bun install) >"$TMP/js-native.log" 2>&1; then
        if needs js-native-node && ! have node; then
            mark_broken js-native-node "node not found"
        fi
    else
        for v in js-native-bun js-native-node; do mark_broken "$v" "bun install failed"; done
        sed 's/^/        /' "$TMP/js-native.log" >&2 || true
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

# The C client ships three build variants (c, c-pkgconfig, c-cmake) that all
# produce the same subscribe-only binary from the same prebuilt libmoq; they
# differ only in how the build discovers it: hand-rolled flags, pkg-config (the
# moq.pc consumer path), or find_package (the CMake package consumer path).
if needs c || needs c-pkgconfig || needs c-cmake; then
    echo "building c client(s) against the libmoq prebuilt release..."
    if libmoq_fetch >"$TMP/c-fetch.log" 2>&1; then
        cat "$TMP/c-fetch.log"
        if needs c; then
            C_SMOKE="$TMP/c-smoke"
            if c_build_direct "$C_SMOKE" >"$TMP/c-build.log" 2>&1; then :; else
                mark_broken c "direct compile failed"
                sed 's/^/        /' "$TMP/c-build.log" >&2 || true
            fi
        fi
        if needs c-pkgconfig; then
            C_PC_SMOKE="$TMP/c-pc-smoke"
            if c_build_pkgconfig "$C_PC_SMOKE" >"$TMP/c-pc-build.log" 2>&1; then :; else
                mark_broken c-pkgconfig "pkg-config build failed"
                sed 's/^/        /' "$TMP/c-pc-build.log" >&2 || true
            fi
        fi
        if needs c-cmake; then
            C_CMAKE_SMOKE="$TMP/c-cmake/smoke"
            if c_build_cmake "$TMP/c-cmake" >"$TMP/c-cmake-build.log" 2>&1; then :; else
                mark_broken c-cmake "cmake build failed"
                sed 's/^/        /' "$TMP/c-cmake-build.log" >&2 || true
            fi
        fi
    else
        sed 's/^/        /' "$TMP/c-fetch.log" >&2 || true
        for v in c c-pkgconfig c-cmake; do mark_broken "$v" "libmoq download failed"; done
    fi
fi

if needs gst; then
    echo "installing gstreamer client (moq-gst prebuilt release)..."
    if gst_prepare >"$TMP/gst-build.log" 2>&1; then :; else
        mark_broken gst "moq-gst download / plugin load failed"
        sed 's/^/        /' "$TMP/gst-build.log" >&2 || true
    fi
fi

# A relay from a previous run in the same job is reaped by cleanup(), but the
# kernel can take a moment to release the (host-network) socket afterwards, so
# wait briefly for the port to clear before treating it as a real conflict.
for _ in $(seq 1 20); do
    curl -sf "$URL/certificate.sha256" >/dev/null 2>&1 || break
    sleep 0.5
done
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
# client frames it (moq / the FFI importers only frame-and-forward, ffmpeg
# encodes).
PUB_PID=""
start_publisher() {
    local lang="$1" broadcast="$2" log="$TMP/pub-$1.log"
    case "$lang" in
        rust)
            (ffmpeg_h264 | "$MOQ" --client-connect "$URL" --broadcast "$broadcast" import avc3) >"$log" 2>&1 &
            ;;
        python)
            (ffmpeg_h264 | "$PY" "$CLIENTS/python/smoke.py" \
                publish --url "$URL" --broadcast "$broadcast") >"$log" 2>&1 &
            ;;
        go)
            (ffmpeg_h264 | "$GO_SMOKE" publish --url "$URL" --broadcast "$broadcast") >"$log" 2>&1 &
            ;;
        js-vite | js-esbuild | js-jsdelivr)
            # Headless Chromium encodes its own H.264 from a fake camera via
            # WebCodecs (lazily, once a subscriber creates demand). The variant
            # selects how the published packages reach the page.
            (cd "$CLIENTS/js" && bun driver.ts publish --variant "${lang#js-}" \
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
            # moq only handles SIGINT, so -k forces SIGKILL if it ignores the
            # SIGTERM that fires when no data arrives within the timeout.
            local n
            n=$(timeout -k 3 "$TIMEOUT" "$MOQ" --client-connect "$URL" --broadcast "$broadcast" \
                export fmp4 2>/dev/null | head -c 1 | wc -c | tr -d ' ' || true)
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
        c | c-pkgconfig | c-cmake)
            # Same subscribe-only client; the three cells differ only in how it
            # was built (hand-rolled, pkg-config, or CMake) against the same
            # prebuilt libmoq. The run is identical.
            local bin
            case "$lang" in
                c) bin="$C_SMOKE" ;;
                c-pkgconfig) bin="$C_PC_SMOKE" ;;
                c-cmake) bin="$C_CMAKE_SMOKE" ;;
            esac
            "$bin" subscribe --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT"
            ;;
        gst)
            # moqsrc exposes the broadcast's video as a Sometimes pad (video_%u,
            # ANY caps); gst-launch links it to filesink once it appears. We pipe
            # the raw frames to stdout and grab one byte, the same "bytes moved"
            # bar (and the same head -c 1 early-exit idiom) as the rust subscriber
            # -- no decode. head closing the pipe SIGPIPEs gst-launch, so success
            # returns at once; no data just runs out the timeout. Our plugin dir
            # rides on top of the system path (which provides filesink); a private
            # registry keeps the scan off the user's cache. buffer-mode=2 makes
            # filesink unbuffered so the first frame reaches head immediately.
            local n
            n=$(GST_PLUGIN_PATH_1_0="$GST_PLUGIN_DIR" GST_REGISTRY_1_0="$TMP/gst-run-registry.bin" \
                timeout -k 3 "$TIMEOUT" gst-launch-1.0 -q \
                moqsrc url="$URL" broadcast="$broadcast" ! filesink location=/dev/stdout buffer-mode=2 \
                2>/dev/null | head -c 1 | wc -c | tr -d ' ' || true)
            [[ "${n:-0}" -ge 1 ]]
            ;;
        js-vite | js-esbuild | js-jsdelivr)
            # Headless Chromium decodes via WebCodecs; exits 0 once a frame lands.
            (cd "$CLIENTS/js" && bun driver.ts subscribe --variant "${lang#js-}" \
                --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT")
            ;;
        js-native-bun)
            # Native @moq/net via the WebTransport polyfill, under bun.
            (cd "$CLIENTS/js-native" && bun subscribe.ts subscribe \
                --url "$URL" --broadcast "$broadcast" --timeout "$TIMEOUT")
            ;;
        js-native-node)
            # Same, under node (tsx runs the TS directly).
            (cd "$CLIENTS/js-native" && node --import tsx subscribe.ts subscribe \
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
    # ${arr[@]+...} guard: a round may have no live subscribers (all broken),
    # and bash 3.2 (macOS) errors on "${!pids[@]}" for an empty array under `set -u`.
    for i in ${pids[@]+"${!pids[@]}"}; do
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
