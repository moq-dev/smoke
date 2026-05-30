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
| `moq-relay` + `moq-cli` (Rust) | crates.io / Homebrew tap / apt repo / the moq flake | `cargo install`, `brew install moq-dev/tap/...`, `apt install`, `nix build github:moq-dev/moq#...` |
| Python | [PyPI `moq-rs`](https://pypi.org/project/moq-rs/) (import `moq`) | `uv pip install moq-rs` |
| Go | [`github.com/moq-dev/moq-go`](https://github.com/moq-dev/moq-go) | `go get` |
| Browser | npm [`@moq/watch`](https://www.npmjs.com/package/@moq/watch) + [`@moq/publish`](https://www.npmjs.com/package/@moq/publish), delivered three ways | headless Chromium (Playwright) loading a **vite** bundle, an **esbuild** bundle, or straight from the **jsDelivr** ESM CDN |
| Swift | SPM [`moq-dev/moq-swift`](https://github.com/moq-dev/moq-swift) | `swift build` (macOS, Xcode toolchain) |
| Kotlin | Maven Central [`dev.moq:moq`](https://central.sonatype.com/artifact/dev.moq/moq) | `gradle` (JVM) |
| C | [`libmoq`](https://github.com/moq-dev/moq/releases) prebuilt release assets | `cc` + the platform tarball |

Swift, Kotlin, and C **subscribe only**. Every non-browser client publishes through the streaming importer (`publish_media_stream`), which isn't in the published 0.2.x FFI yet, so those FFI wrappers can only subscribe until it ships. Rust and the browser publish today.

The Rust binaries (`moq-relay`, `moq-cli`) ship through four channels that install the *same* binaries. CI treats each as a separate test where the OS supports it: Linux exercises **apt**, **cargo**, **nix**; macOS exercises **brew**, **cargo**, **nix**. `smoke.sh` itself just takes whatever is on `PATH` (or `RELAY_BIN`/`MOQ_BIN`); the channel is chosen by how the binaries are installed:

- **cargo** / **brew** / **apt** put the binaries on `PATH` (`cargo install moq-relay moq-cli`, etc.).
- **nix** builds them from the moq flake (`just nix-channel`), the same outputs `nix run github:moq-dev/moq#moq-cli` resolves. The moq flake is referenced ad-hoc with `--refresh`, so the moq version is always the latest default-branch build, never locked by this repo.

The **browser** client is itself three delivery variants of the *same* page, run as separate matrix cells, to catch breakage specific to how the package is consumed:

- `js-vite` — bundled by [vite](https://vite.dev/).
- `js-esbuild` — bundled by [esbuild](https://esbuild.github.io/) (a different bundler).
- `js-jsdelivr` — no bundler, no install: the page `import`s the packages straight from the [jsDelivr](https://www.jsdelivr.com/) ESM CDN (`https://cdn.jsdelivr.net/npm/@moq/watch/element/+esm`), which resolves the export map and bundles the dep graph.

## Running locally

The repo ships a Nix flake (`.envrc` auto-loads it via direnv) with every client toolchain: ffmpeg, uv, go, bun, Node, Chromium via Playwright, cargo, coreutils, jq, and the linters. It does **not** carry the moq binaries; those come from a channel.

```bash
nix develop                       # drops you in a shell with the toolchain
# then either bring the binaries via a channel...
cargo install moq-relay moq-cli   # (or brew / apt)
just full                         # full matrix, --timeout 30
# ...or use the moq flake as the channel (builds moq, no install needed):
just nix-channel --publishers rust,js-vite --subscribers rust,python,js-jsdelivr --timeout 30
```

`PLAYWRIGHT_BROWSERS_PATH` is set by the flake, so the browser client uses the nix Chromium. The npm `playwright` in `clients/js/package.json` is pinned to match that Chromium build (enforced by `freshness.sh`); bumping nixpkgs means bumping that pin too.

Without Nix, you need the relay + CLI on `PATH` plus the toolchains for whichever clients you include:

```bash
cargo install moq-relay moq-cli       # or brew / apt
# python -> uv ; go -> go ; browser -> bun (+ chromium)

# default matrix is rust-only:
./smoke.sh

# full matrix (browser variants: js-vite, js-esbuild, js-jsdelivr):
just full   # or: ./smoke.sh --publishers rust,python,js-vite --subscribers rust,js-jsdelivr ...

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
  js/                     headless-Chromium publish/subscribe via @moq/watch + @moq/publish;
                          three delivery variants: vite, esbuild, jsdelivr (shared jsdelivr/setup.js)
  swift/                  subscribe via moq-dev/moq-swift (SPM, macOS)
  kotlin/                 subscribe via dev.moq:moq (Gradle/JVM)
  c/subscribe.c          subscribe via libmoq (prebuilt release)
freshness.sh             enforces the "always latest, no package locks" policy
.github/workflows/smoke.yml   nightly + on-demand CI matrix (os x channel)
```

## Always the latest moq packages (no package lock files)

To test what a user gets today, this repo commits **no package lock files** (`go.sum`, `bun.lock`, `Cargo.lock`, `uv.lock`, ... are gitignored). Every run re-resolves the moq packages to their latest published versions: `@moq/*` at the `latest` npm tag, `moq-rs` via `uv pip install`, `moq-go` via `go get @latest`, and the **nix** channel builds the moq flake ad-hoc with `--refresh`.

`flake.lock` *is* committed: it pins the dev **toolchain** (nixpkgs), not the moq packages, so the shell is reproducible. The moq flake is never an input here, so locking the toolchain never locks moq.

The one version that can't float freely is the npm `playwright`, which must match the Chromium the toolchain ships. The flake exports that version as `PLAYWRIGHT_VERSION`, and `freshness.sh` (run by `just freshness`, by CI, and at the top of `smoke.sh`) fails if the pin in `clients/js/package.json` drifts from it, if a *package* lock file gets committed, or if a moq package stops being requested at latest. So even the one pin can't go stale silently; bump the toolchain with `nix flake update` and the pin together.

```bash
just freshness   # enforce the policy
just check       # lint + freshness
```

## Current state

This test tracks the **latest published** packages, so it sometimes runs ahead of a release. A red cell is the signal, not noise. As of this writing:

- **Rust publish/subscribe** and **browser publish/subscribe** (all three delivery variants: vite, esbuild, jsDelivr): working (`cargo install` / `brew` / `apt` / `nix` + npm/CDN). The green baseline.
- **Python publish/subscribe**: working. `moq-rs` 0.2.16 shipped the streaming importer (`publish_media_stream`), so Python now publishes a raw Annex-B broadcast too, verified end-to-end against rust/swift/c subscribers.
- **Swift / Kotlin / C subscribe**: working, verified end-to-end against the published 0.2.16 / 0.3.0 packages (`moq-dev/moq-swift`, `dev.moq:moq`, `libmoq`). Subscriber-only by choice.
- **Go (any role)**: red. The published `moq-dev/moq-go` module is still un-buildable (stuck at v0.2.15): it's missing the generated `moq.h` header (its `moq.go` does `#include <moq.h>`) and the linux static libs, so `go get` + build fails. Tracked upstream in moq-dev/moq's release-go packaging.

A broken published package fails only its own matrix cells (see `mark_broken` in `smoke.sh`); it never aborts the rest of the run.
