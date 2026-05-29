# moq smoke

Cross-language interop smoke test for the **public** [Media over QUIC](https://github.com/moq-dev/moq) packages.

The [moq-dev/moq](https://github.com/moq-dev/moq) monorepo has its own in-tree smoke test, but it builds every client from workspace source. That proves the code in the tree works; it does **not** prove a real user can install the published artifacts and have them talk to each other. A missing wheel, a stale Homebrew formula, a broken `.deb`, an export that didn't survive packaging, a Go module missing its header. none of that shows up until someone installs from a registry.

This repo installs each client straight from its public package registry, stands up a relay, and runs the interop matrix:

- A relay (`moq-relay`) routes broadcasts.
- For each publisher language, publish an H.264 broadcast.
- For each subscriber language, confirm bytes flow end-to-end (a non-empty frame before the timeout).

We check that bytes move across implementations, not that H.264 decodes.

## Clients and channels

| Client | Source under test | Install |
|---|---|---|
| `moq-relay` + `moq-cli` (Rust) | crates.io / Homebrew tap / apt repo | `cargo install`, `brew install moq-dev/tap/...`, `apt install` |
| Python | [PyPI `moq-rs`](https://pypi.org/project/moq-rs/) (import `moq`) | `uv pip install moq-rs` |
| Go | [`github.com/moq-dev/moq-go`](https://github.com/moq-dev/moq-go) | `go get` |
| Browser | npm [`@moq/watch`](https://www.npmjs.com/package/@moq/watch) + [`@moq/publish`](https://www.npmjs.com/package/@moq/publish) | `bun add` + Playwright/Chromium |

The Rust binaries (`moq-relay`, `moq-cli`) ship through three channels that install the *same* binaries. CI treats each as a separate test where the OS supports it: macOS exercises **brew** and **cargo**; Linux exercises **apt** and **cargo**. `smoke.sh` itself just takes whatever is on `PATH`; the channel is chosen by how CI installs it.

## Running locally

The repo ships a Nix flake with every client toolchain (ffmpeg, uv, go, bun, Chromium via Playwright, coreutils, curl, cargo). It pins the same nixpkgs revision as moq-dev/moq, so the store paths are usually already cached:

```bash
nix develop                       # drops you in a shell with the toolchain
# then `cargo install moq-relay moq-cli` (or brew/apt), and:
just full                         # full matrix, --timeout 30
```

`PLAYWRIGHT_BROWSERS_PATH` is set by the flake, so the browser client uses the nix Chromium. The npm `playwright` in `clients/js/package.json` is pinned to match that Chromium build; bumping the nixpkgs pin means bumping that pin too.

Without Nix, you need the relay + CLI on `PATH` plus the toolchains for whichever clients you include:

```bash
cargo install moq-relay moq-cli       # or brew / apt
# python -> uv ; go -> go ; browser -> bun (+ chromium)

# default matrix is rust-only:
./smoke.sh

# full matrix:
./smoke.sh --publishers rust,python,go,js-browser \
           --subscribers rust,python,go,js-browser --timeout 30

# point at a specific build instead of PATH:
RELAY_BIN=/path/to/moq-relay MOQ_BIN=/path/to/moq-cli ./smoke.sh

# prove the harness can fail: no publisher, every subscriber must time out.
./smoke.sh --negative --subscribers rust,python
```

`smoke.sh` installs the language clients (PyPI / Go proxy / npm) into a scratch dir on each run, so you always test the latest published versions. It does **not** install the Rust binaries; that is the channel under test.

## Layout

```
smoke.sh                 orchestrator: relay + matrix
smoke.toml               relay config (anonymous, self-signed localhost)
clients/
  python/smoke.py        publish/subscribe via moq-rs (PyPI)
  go/                     publish/subscribe via moq-dev/moq-go (go get)
  js/                     headless-Chromium publish/subscribe via @moq/watch + @moq/publish (npm)
.github/workflows/smoke.yml   nightly + on-demand CI matrix (os x channel)
```

## Current state

This test tracks the **latest published** packages, so it sometimes runs ahead of a release. A red cell is the signal, not noise. As of this writing:

- **Rust publish/subscribe** and **browser publish/subscribe**: working (`cargo install` / `brew` / `apt` + npm). These are the green baseline.
- **Python / Go subscribe**: working once their package installs (Python verified against `moq-rs` 0.2.15).
- **Python / Go publish**: red. Every non-browser client publishes through the streaming importer (`publish_media_stream` / `PublishMediaStream`), which infers frame boundaries from a raw Annex-B pipe. It's in the moq source but not in the published 0.2.15 wheel/module yet, so raw-stream publishing from Python/Go waits on the next release.
- **Go (any role)**: red. The published `moq-dev/moq-go` module is currently un-buildable: it's missing the generated `moq.h` header (its `moq.go` does `#include <moq.h>`) and the linux static libs, so `go get` + build fails. Tracked upstream in moq-dev/moq's release-go packaging.

A broken published package fails only its own matrix cells (see `mark_broken` in `smoke.sh`); it never aborts the rest of the run.
