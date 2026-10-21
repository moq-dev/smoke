#!/usr/bin/env bash
# moq-lite-06 conformance of the moq CLI, scored against the draft text by
# moq-contribution-interop-runner.
#
# The runner plays the relay and the subscriber; the CLI dials it and publishes
# through the runner's own moq-lite adapter. Every row the runner judges `fail`
# fails the lane. Rows it cannot judge against this publisher (`not_run`,
# `not_applicable`) are expected.
set -euo pipefail

RUNNER_REPO="https://github.com/mondain/moq-contribution-interop-runner"
MOQ="${MOQ_BIN:-moq}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

missing=()
for tool in git cmake c++ pkg-config perl curl jq openssl ffmpeg timeout "$MOQ"; do
    have "$tool" || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required tools: ${missing[*]}" >&2
    exit 1
fi
MOQ=$(command -v "$MOQ")
echo "publisher: $("$MOQ" --version) ($MOQ)"

echo "building the interop runner from $RUNNER_REPO (latest default branch)..."
runner="$TMP/runner"
if ! {
    git clone --quiet --depth 1 "$RUNNER_REPO" "$runner" &&
        git -C "$runner" log -1 --format='runner: %h %s' &&
        cmake -S "$runner" -B "$runner/build" -DCMAKE_BUILD_TYPE=Release -DMOQ_INTEROP_BUILD_TESTS=OFF &&
        cmake --build "$runner/build" --target moq-interop-runner moq-interop-audit -j "$(nproc)"
} >"$TMP/build.log" 2>&1; then
    echo "error: failed to build the interop runner" >&2
    sed 's/^/  /' "$TMP/build.log" >&2 || true
    exit 1
fi
grep '^runner: ' "$TMP/build.log"

overall=0
for transport in native_quic webtransport; do
    echo "=== moq-lite-06 / $transport ==="
    # Exit 77 is the runner's skip for a missing tool: a failure here.
    status=0
    MOQ_CLI_BIN="$MOQ" bash "$runner/tests/e2e/driven-moq-lite.sh" \
        "$transport" "$runner/build/moq-interop-runner" >"$TMP/$transport.log" 2>&1 || status=$?
    grep -E '^scenario=|^  row .* fail$|^  (harness_error|context_skipped) ' "$TMP/$transport.log" | sed 's/^/  /' || true
    if [[ "$status" -ne 0 ]]; then
        echo "  FAIL  the runner exited $status" >&2
        sed 's/^/        /' "$TMP/$transport.log" >&2
        overall=1
    elif grep -qE '^  row .* fail$' "$TMP/$transport.log"; then
        echo "  FAIL  $(grep -cE '^  row .* fail$' "$TMP/$transport.log") failing rows (IDs above; see docs/ in $RUNNER_REPO)" >&2
        overall=1
    fi
done

if [[ "$overall" -eq 0 ]]; then
    echo "moq-lite conformance: no failing rows"
else
    echo "moq-lite conformance: FAILURES detected" >&2
fi
exit "$overall"
