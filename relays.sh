#!/usr/bin/env bash
# Publish/subscribe through the PUBLIC MoQ relays other implementations run.
#
# The relay list is the moq-interop-runner registry (every roles.relay.remote
# endpoint), fetched live so a newly registered relay shows up without a change
# here. smoke.sh runs its usual publisher x subscriber matrix through each
# endpoint (--relay), using the same published clients as the local matrix.
#
# Third-party relays negotiate an IETF moq-transport draft rather than moq-lite,
# go down, and change underneath us, so most are OPTIONAL: they're reported in the
# summary but never fail the run. Only --required implementations gate the exit
# code (default: moq-dev's own public relay).
set -euo pipefail

SMOKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REGISTRY="${RELAYS_REGISTRY:-https://raw.githubusercontent.com/englishm/moq-interop-runner/main/implementations.json}"
REQUIRED="moq-dev-rs"
ONLY=""
SMOKE_ARGS=()

usage() {
    cat >&2 <<'USAGE'
usage: relays.sh [--required KEYS] [--only KEYS] [--registry URL|FILE] [smoke.sh flags...]

  --required KEYS   comma-separated registry keys whose relays must pass (default: moq-dev-rs)
  --only KEYS       only test these registry keys (e.g. moq-rs-draft-18,moxygen)
  --registry SRC    implementations.json URL or path (default: moq-interop-runner main)

Any other flag (--publishers, --subscribers, --timeout) is passed to smoke.sh.
USAGE
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --required | --only | --registry)
            [[ $# -ge 2 && "$2" != -* ]] || usage
            case "$1" in
                --required) REQUIRED="$2" ;;
                --only) ONLY="$2" ;;
                --registry) REGISTRY="$2" ;;
            esac
            shift 2
            ;;
        -h | --help) usage ;;
        *)
            SMOKE_ARGS+=("$1")
            shift
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -f "$REGISTRY" ]]; then
    cp "$REGISTRY" "$TMP/registry.json"
elif ! curl -sfL --retry 3 --retry-all-errors -o "$TMP/registry.json" "$REGISTRY"; then
    echo "error: failed to fetch relay registry: $REGISTRY" >&2
    exit 1
fi

in_list() {
    # in_list <item> <comma-list>
    [[ ",$2," == *",$1,"* ]]
}

# One row per endpoint: key, display name, url. Deduplicated by URL (an entry
# can list the same URL twice under different transport labels); the transport
# is taken from the URL scheme rather than the registry's label.
jq -r '.implementations | to_entries[] | .key as $k | .value.name as $n |
    (.value.roles.relay.remote // [])[] | [$k, $n, .url] | @tsv' "$TMP/registry.json" |
    awk -F'\t' '!seen[$3]++' >"$TMP/endpoints.tsv"

relay_args=()
while IFS=$'\t' read -r key name url; do
    [[ -z "$ONLY" ]] || in_list "$key" "$ONLY" || continue
    relay_args+=(--relay "$url")
    printf '%s\t%s\t%s\n' "$key" "$name" "$url" >>"$TMP/selected.tsv"
done <"$TMP/endpoints.tsv"

# A required implementation that vanished from the registry must not pass by
# default just because none of its endpoints ran.
IFS=',' read -r -a required_keys <<<"$REQUIRED"
for key in ${required_keys[@]+"${required_keys[@]}"}; do
    if ! cut -f1 "$TMP/endpoints.tsv" | grep -qxF "$key"; then
        echo "error: required relay '$key' has no public endpoint in $REGISTRY" >&2
        exit 1
    fi
done

if [[ ${#relay_args[@]} -eq 0 ]]; then
    echo "error: no relay endpoints selected from $REGISTRY" >&2
    exit 1
fi

# smoke.sh's exit status covers optional relays too; the verdict comes from the
# per-cell results instead.
: >"$TMP/results.tsv"
"$SMOKE_DIR/smoke.sh" "${relay_args[@]}" --results "$TMP/results.tsv" ${SMOKE_ARGS[@]+"${SMOKE_ARGS[@]}"} || true

if [[ ! -s "$TMP/results.tsv" ]]; then
    echo "error: smoke.sh recorded no results (see its output above)" >&2
    exit 1
fi

# ── summary ─────────────────────────────────────────────────────────────────
# A markdown table (one row per endpoint, one column per publisher -> subscriber
# pair), printed and appended to the GitHub job summary when running in CI.
# An endpoint passes when at least one cell passed and none failed, so one that
# never reported (smoke.sh died mid-run) counts as failing.
summary="$TMP/summary.md"
failed_required=$(
    awk -F'\t' -v required="$REQUIRED" -v out="$summary" '
    function icon(s) { return s == "PASS" ? "✅" : s == "FAIL" ? "❌" : s == "SKIP" ? "➖" : " " }
    function scheme(u) { return u ~ /^moqt:/ ? "QUIC" : "WebTransport" }
    BEGIN { n = split(required, r, ","); for (i = 1; i <= n; i++) req[r[i]] = 1 }
    FNR == NR {
        # selected.tsv: key, name, url (registry order)
        key[$3] = $1; name[$3] = $2; urls[++nurl] = $3
        next
    }
    {
        url = $1; pair = $2 " → " $3
        if (!(pair in pseen)) { pseen[pair] = 1; pairs[++npair] = pair }
        cell[url, pair] = $4
        if ($4 == "PASS") pass[url] = 1
        if ($4 == "FAIL") fail[url] = 1
    }
    END {
        print "## External relay interop\n" > out
        header = "| Relay | Transport | Endpoint | Gate |"; sep = "|---|---|---|---|"
        for (p = 1; p <= npair; p++) { header = header " " pairs[p] " |"; sep = sep "---|" }
        print header > out; print sep > out
        for (u = 1; u <= nurl; u++) {
            url = urls[u]; k = key[url]
            ok = (url in pass) && !(url in fail)
            gate = (k in req) ? "required" : "optional"
            if (gate == "required") { rtotal++; if (ok) rpass++; else bad = bad " " url }
            else { ototal++; if (ok) opass++ }
            row = "| " name[url] " (`" k "`) | " scheme(url) " | `" url "` | " gate " |"
            for (p = 1; p <= npair; p++) row = row " " icon(cell[url, pairs[p]]) " |"
            print row > out
        }
        printf "\nRequired: %d/%d endpoints passing. Optional: %d/%d endpoints passing.\n", rpass, rtotal, opass, ototal > out
        print "✅ bytes flowed · ❌ no data / error · ➖ skipped (client can'"'"'t dial that transport)" > out
        print bad
    }' "$TMP/selected.tsv" "$TMP/results.tsv"
)

echo
cat "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$summary" >>"$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${failed_required// /}" ]]; then
    echo "relays: required relay(s) failed:$failed_required" >&2
    exit 1
fi
echo "relays: all required relays passed"
