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

# Full cross-language matrix with browser cold-start headroom. Rust + browser
# publish; everyone subscribes (swift needs the macOS Xcode toolchain).
full:
    ./smoke.sh --publishers rust,python,js-browser --subscribers rust,python,go,swift,kotlin,c,js-browser --timeout 30

# The "nix" channel: get moq-relay + moq-cli from the moq flake itself
# (a public distribution channel, `nix run github:moq-dev/moq#moq-cli`), instead
# of cargo/brew/apt. Referenced ad-hoc with --refresh so the moq version is the
# latest default-branch build, never locked by this repo. The devShell only
# carries client toolchains; moq is built separately here. Override the source
# with MOQ_FLAKE (e.g. a fork or a pinned ref).
MOQ_FLAKE := env_var_or_default("MOQ_FLAKE", "github:moq-dev/moq")
CACHIX_SUB := "https://kixelated.cachix.org"
CACHIX_KEY := "kixelated.cachix.org-1:CmFcV0lyM6KuVM2m9mih0q4SrAa0XyCsiM7GHrz3KKk="

nix-channel *args:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "building moq-relay + moq-cli from {{ MOQ_FLAKE }} (latest)..."
    nix_build() {
        nix build --refresh --no-link --print-out-paths \
            --extra-substituters "{{ CACHIX_SUB }}" \
            --extra-trusted-public-keys "{{ CACHIX_KEY }}" "$1"
    }
    relay=$(nix_build '{{ MOQ_FLAKE }}#moq-relay')
    cli=$(nix_build '{{ MOQ_FLAKE }}#moq-cli')
    echo "relay: $relay"
    echo "cli:   $cli"
    RELAY_BIN="$relay/bin/moq-relay" MOQ_BIN="$cli/bin/moq-cli" ./smoke.sh {{ args }}

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
