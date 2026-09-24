#!/usr/bin/env bash
# Assemble the relay interop report site: the static page, the latest
# results.json from `relays.sh --json`, and a rolling history.json.
#
#   report/build.sh RESULTS_JSON OUT_DIR [PREVIOUS_HISTORY_URL]
#
# History lives only on the published site: pass the currently deployed
# history.json URL and this run is appended to it (last 60 runs kept). A missing
# or unreadable history just starts a new one.
set -euo pipefail

results="$1"
out="$2"
history_url="${3:-}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mkdir -p "$out"
cp "$here/index.html" "$out/index.html"
cp "$results" "$out/results.json"

previous="[]"
if [[ -n "$history_url" ]]; then
    fetched=$(curl -sfL --retry 3 "$history_url" 2>/dev/null || true)
    if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$fetched"; then
        previous="$fetched"
    else
        echo "no previous history at $history_url; starting fresh" >&2
    fi
fi

jq --argjson previous "$previous" '
    $previous + [{
        generated,
        run_url,
        endpoints: (.endpoints | map({key: .url, value: {ok, versions}}) | from_entries)
    }] | .[-60:]' "$results" >"$out/history.json"
