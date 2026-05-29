#!/usr/bin/env just --justfile
# Convenience wrapper around smoke.sh. The clients install themselves from public
# registries on each run; you bring moq-relay + moq-cli on PATH (cargo/brew/apt).

# Run the smoke matrix (default: rust only). Pass flags through, e.g.
#   just smoke --publishers rust,python,go,js-browser --subscribers rust,python,go,js-browser
smoke *args:
    ./smoke.sh {{ args }}

# Full cross-language matrix with browser cold-start headroom.
full:
    ./smoke.sh --publishers rust,python,go,js-browser --subscribers rust,python,go,js-browser --timeout 30

# Negative control: no publisher, every subscriber must time out.
negative *args:
    ./smoke.sh --negative {{ args }}
