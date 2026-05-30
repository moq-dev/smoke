#!/usr/bin/env just --justfile
#
# Using Just: https://github.com/casey/just?tab=readme-ov-file#installation
#
# Convenience wrapper around smoke.sh. The clients install themselves from public
# registries on each run; you bring moq-relay + moq-cli on PATH (cargo/brew/apt).

# Run the smoke matrix (default: rust only). Pass flags through, e.g.
#   just smoke --publishers rust,python,go,js-browser --subscribers rust,python,go,js-browser
default *args:
    ./smoke.sh {{ args }}

# Alias for the default recipe.
smoke *args:
    ./smoke.sh {{ args }}

# Full cross-language matrix with browser cold-start headroom.
full:
    ./smoke.sh --publishers rust,python,go,js-browser --subscribers rust,python,go,js-browser --timeout 30

# Negative control: no publisher, every subscriber must time out.
negative *args:
    ./smoke.sh --negative {{ args }}

# Assert we pin nothing stale: no committed lock files, and any version we are
# forced to pin (npm playwright) matches what the toolchain provides.
freshness:
    ./freshness.sh

# Lint the harness. Each tool is guarded so it skips when not on PATH.
check:
    command -v shellcheck >/dev/null && shellcheck smoke.sh freshness.sh || echo "shellcheck: skipped"
    command -v shfmt >/dev/null && shfmt -d -i 4 -ci smoke.sh freshness.sh || echo "shfmt: skipped"
    command -v actionlint >/dev/null && actionlint || echo "actionlint: skipped"
    just freshness
