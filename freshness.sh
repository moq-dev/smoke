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
locks=$(git ls-files 2>/dev/null | grep -E '(^|/)(go\.sum|bun\.lock|bun\.lockb|Cargo\.lock|uv\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock)$' || true)
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
