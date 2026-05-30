#!/usr/bin/env bash
# Guard the "always test the latest published packages" policy:
#   1. no committed PACKAGE lock files (go.sum, bun.lock, Cargo.lock, ...), so
#      every run re-resolves the moq packages to their latest. flake.lock is
#      fine: it pins the dev toolchain, not the moq packages, and the moq "nix"
#      channel references the moq flake ad-hoc so the moq version is never locked;
#   2. the moq packages under test are requested as "latest", never pinned;
#   3. the one unavoidable pin (npm `playwright`, which must match the toolchain's
#      Chromium build) equals what the toolchain ships, so a toolchain bump can't
#      quietly leave it stale.
#
# Run standalone (`just freshness`) or as the opening step of smoke.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
PKG=clients/js/package.json
fail=0
note() { printf '  %-5s %s\n' "$1" "$2"; }
json_dep() { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$PKG" | sed -E 's/.*"([^"]*)"$/\1/'; }

echo "== no committed package lock files =="
# flake.lock is intentionally excluded: it locks the toolchain, not moq packages.
locks=$(git ls-files 2>/dev/null | grep -E '(^|/)(go\.sum|bun\.lock|bun\.lockb|Cargo\.lock|uv\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock|Package\.resolved|gradle\.lockfile)$' || true)
if [[ -n "$locks" ]]; then
    note FAIL "package lock files are checked in (delete them and add to .gitignore):"
    echo "$locks" | sed 's/^/        /'
    fail=1
else
    note ok "none tracked"
fi

echo "== moq packages requested at latest =="
for dep in @moq/watch @moq/publish; do
    ver=$(json_dep "$dep")
    if [[ "$ver" == "latest" ]]; then note ok "$dep -> \"$ver\""; else note FAIL "$dep pinned to \"$ver\" (want \"latest\")"; fail=1; fi
done
# The native-JS client (@moq/net + @moq/hang + @moq/web-transport) must also be latest.
for dep in @moq/net @moq/hang @moq/web-transport; do
    ver=$(grep -oE "\"$dep\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" clients/js-native/package.json | sed -E 's/.*"([^"]*)"$/\1/')
    if [[ "$ver" == "latest" ]]; then note ok "$dep -> \"$ver\""; else note FAIL "$dep pinned to \"$ver\" (want \"latest\")"; fail=1; fi
done
# The jsDelivr CDN variant must not pin @version, so it serves the latest release.
if grep -qE 'cdn\.jsdelivr\.net/npm/@moq/[a-z-]+@[0-9]' clients/js/jsdelivr/index.html; then
    note FAIL "jsdelivr/index.html pins a @moq version (drop @x.y.z so the CDN serves latest)"
    fail=1
else
    note ok "jsdelivr @moq/* -> unpinned (latest)"
fi
if grep -q 'uv pip install --quiet --python "$PY" moq-rs' smoke.sh; then
    note ok "moq-rs -> uv pip install (unpinned)"
else
    note FAIL "smoke.sh no longer installs moq-rs unpinned"
    fail=1
fi
if grep -q 'go get "github.com/moq-dev/moq-go@latest"' smoke.sh; then
    note ok "moq-go -> go get @latest"
else
    note FAIL "smoke.sh no longer go-gets moq-go @latest"
    fail=1
fi
# Swift: `from: "x"` floats to the newest compatible; an `.exact(` pin would not.
if grep -q '\.exact(' clients/swift/Package.swift; then
    note FAIL "moq-swift pinned with .exact( (want from:, which floats to latest)"
    fail=1
else
    note ok "moq-swift -> from: (floats to latest)"
fi
# Kotlin: a dynamic version (latest.release / +) re-resolves to the newest each run.
if grep -qE '"dev\.moq:moq:(latest\.release|\+)"' clients/kotlin/build.gradle.kts; then
    note ok "dev.moq:moq -> dynamic (latest)"
else
    note FAIL "dev.moq:moq is not a dynamic latest version in build.gradle.kts"
    fail=1
fi
# C: smoke.sh resolves the newest libmoq-v* release, never a fixed version.
if grep -q "grep '\^libmoq-v' | head -1" smoke.sh; then
    note ok "libmoq -> latest release"
else
    note FAIL "smoke.sh no longer resolves the latest libmoq-v* release"
    fail=1
fi

echo "== forced pin (npm playwright) tracks the toolchain =="
pin=$(json_dep playwright)
if [[ "$pin" == ^* || "$pin" == "~"* || "$pin" == "latest" || "$pin" == *"x" || "$pin" == *"*"* ]]; then
    note FAIL "playwright must be an exact version matching the toolchain's Chromium, got \"$pin\""
    fail=1
elif [[ -n "${PLAYWRIGHT_VERSION:-}" ]]; then
    if [[ "$pin" == "$PLAYWRIGHT_VERSION" ]]; then
        note ok "playwright $pin == toolchain $PLAYWRIGHT_VERSION"
    else
        note FAIL "playwright pinned to $pin but the toolchain ships $PLAYWRIGHT_VERSION; bump $PKG"
        fail=1
    fi
else
    note warn "PLAYWRIGHT_VERSION unset (not a nix shell); can't confirm \"$pin\" matches the Chromium in use"
fi

if [[ "$fail" -eq 0 ]]; then
    echo "freshness: ok"
else
    echo "freshness: FAILURES detected" >&2
    exit 1
fi
