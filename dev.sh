#!/usr/bin/env bash
# Prove the unpublished *dev* API by installing JS packages from a moq checkout
# (path or git `dev`) and running contract cases a published-package matrix cannot
# see yet. The cargo/apt/brew/nix/docker media matrix is unchanged: this is a
# second channel, not a replacement.
#
#   MOQ_SRC=/path/to/moq ./dev.sh
#   ./dev.sh --src /path/to/moq
#   ./dev.sh                 # clones github.com/moq-dev/moq (dev) into a temp dir
set -euo pipefail

SMOKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENTS="$SMOKE_DIR/clients/dev"
TIMEOUT="${SMOKE_TIMEOUT:-30}"
PORT="${SMOKE_PORT:-}"
MOQ_SRC="${MOQ_SRC:-}"
MOQ_GIT="${MOQ_GIT:-https://github.com/moq-dev/moq.git}"
MOQ_REF="${MOQ_REF:-dev}"

require_value() {
    if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "error: $1 requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            require_value "$@"
            MOQ_SRC="$2"
            shift 2
            ;;
        --git)
            require_value "$@"
            MOQ_GIT="$2"
            shift 2
            ;;
        --ref)
            require_value "$@"
            MOQ_REF="$2"
            shift 2
            ;;
        --timeout)
            require_value "$@"
            TIMEOUT="$2"
            shift 2
            ;;
        --port)
            require_value "$@"
            PORT="$2"
            shift 2
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

kill_tree() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
    kill -KILL "$pid" 2>/dev/null || true
}

TMP=$(mktemp -d)
RELAY_PID=""
cleanup() {
    [[ -n "${RELAY_PID:-}" ]] && kill_tree "$RELAY_PID"
    rm -rf "$TMP"
}
trap cleanup EXIT

for t in bun cargo curl git pgrep; do
    have "$t" || {
        echo "error: missing $t" >&2
        exit 1
    }
done

if [[ -z "$MOQ_SRC" ]]; then
    echo "cloning $MOQ_GIT ($MOQ_REF)..."
    git clone --depth 1 --branch "$MOQ_REF" "$MOQ_GIT" "$TMP/moq"
    MOQ_SRC="$TMP/moq"
elif [[ ! -d "$MOQ_SRC" ]]; then
    echo "error: --src is not a directory: $MOQ_SRC" >&2
    exit 1
fi
MOQ_SRC=$(cd "$MOQ_SRC" && pwd)

echo "moq:     $MOQ_SRC"
echo "revision: $(git -C "$MOQ_SRC" rev-parse HEAD)"
echo "ref:      $(git -C "$MOQ_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"

RELAY="${RELAY_BIN:-}"
if [[ -z "$RELAY" ]]; then
    if [[ -x "$MOQ_SRC/target/debug/moq-relay" ]]; then
        RELAY="$MOQ_SRC/target/debug/moq-relay"
    else
        echo "building moq-relay from source..."
        (cd "$MOQ_SRC" && cargo build -p moq-relay) >"$TMP/cargo.log" 2>&1 || {
            sed 's/^/  cargo: /' "$TMP/cargo.log" >&2
            exit 1
        }
        RELAY="$MOQ_SRC/target/debug/moq-relay"
    fi
fi
if [[ ! -x "$RELAY" ]]; then
    echo "error: moq-relay not found at $RELAY" >&2
    exit 1
fi
echo "relay:   $RELAY"

# Resolve unpublished @moq/* from the moq workspace, and @moq/web-transport
# from npm. bun workspace globs skip the js/* symlinks, so link the packages
# into this client's node_modules after bun install in both trees.
echo "installing JS packages from $MOQ_SRC/js ..."
if ! (cd "$MOQ_SRC" && bun install) >"$TMP/bun-moq.log" 2>&1; then
    sed 's/^/  bun moq: /' "$TMP/bun-moq.log" >&2
    exit 1
fi
mkdir -p "$TMP/cases"
cp "$CLIENTS"/*.ts "$TMP/cases/"
cat >"$TMP/cases/package.json" <<'EOF'
{
  "name": "moq-dev-api",
  "private": true,
  "type": "module",
  "dependencies": {
    "@moq/web-transport": "latest"
  }
}
EOF
if ! (cd "$TMP/cases" && bun install) >"$TMP/bun-cases.log" 2>&1; then
    sed 's/^/  bun cases: /' "$TMP/bun-cases.log" >&2
    exit 1
fi
mkdir -p "$TMP/cases/node_modules/@moq"
for pkg in net hang json flate signals pattern loc; do
    [[ -d "$MOQ_SRC/js/$pkg" ]] || {
        echo "error: missing $MOQ_SRC/js/$pkg" >&2
        exit 1
    }
    ln -sfn "$MOQ_SRC/js/$pkg" "$TMP/cases/node_modules/@moq/$pkg"
done

if [[ -z "$PORT" ]]; then
    PORT=$(bun -e 'const n=require("node:net"); const s=n.createServer(); s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
fi
URL="http://127.0.0.1:${PORT}"

sed "s/4443/${PORT}/g" "$SMOKE_DIR/smoke.toml" >"$TMP/relay.toml"
echo "starting relay on 127.0.0.1:${PORT}..."
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

echo "running from-dev cases..."
(cd "$TMP/cases" && bun run.ts --url "$URL" --timeout "$TIMEOUT")
