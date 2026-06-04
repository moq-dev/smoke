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
| Native JS | npm [`@moq/net`](https://www.npmjs.com/package/@moq/net) + [`@moq/hang`](https://www.npmjs.com/package/@moq/hang) + moq's own [`@moq/web-transport`](https://www.npmjs.com/package/@moq/web-transport) polyfill | non-browser runtimes: **node** and **bun** |
| Swift | SPM [`moq-dev/moq-swift`](https://github.com/moq-dev/moq-swift) | `swift build` (macOS, Xcode toolchain) |
| Kotlin | Maven Central [`dev.moq:moq`](https://central.sonatype.com/artifact/dev.moq/moq) | `gradle` (JVM) |
| C | [`libmoq`](https://github.com/moq-dev/moq/releases) prebuilt release assets | `cc` + the platform tarball |
| GStreamer | [`moq-gst`](https://github.com/moq-dev/moq/releases?q=moq-gst) prebuilt plugin (apt `gstreamer1.0-moq` / brew tap / rpm / tarball) | `gst-launch-1.0` + the platform tarball, against a **system** GStreamer |

The **Native JS** client runs the JS packages *outside* a browser, where there's no native WebTransport, using moq's own `@moq/web-transport` polyfill (a prebuilt NAPI QUIC/HTTP3 addon). It runs as two cells, `js-native-node` and `js-native-bun`, to catch runtime-specific breakage. Subscribe only here too: publishing media needs a WebCodecs encoder, which a native JS runtime lacks (reading raw container frames doesn't).

Swift, Kotlin, C, and GStreamer **subscribe only**. The FFI wrappers (Swift/Kotlin/C) publish through the streaming importer (`publish_media_stream`), which isn't in the published 0.2.x FFI yet, so they can only subscribe until it ships; the GStreamer cell drives `moqsrc` (publishing via `moqsink` needs an encoder + request-pad muxing — a follow-up). Rust and the browser publish today.

The **GStreamer** client downloads the latest `moq-gst` plugin tarball, points `GST_PLUGIN_PATH` at it, and runs `moqsrc url=… broadcast=… ! filesink` — the same "did a frame's bytes arrive" bar as every other subscriber, no decode. The prebuilt plugin dynamic-links the host's *system* GStreamer (the `.deb`/brew/tarball scenario), so this cell needs `gst-launch-1.0` + the core plugins on the system, not nix; under a bare nix shell with no system GStreamer it just marks itself unavailable. Point `MOQ_GST_PLUGIN_DIR` at a local `cargo build -p moq-gst` output to test an unreleased build.

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
smoke.sh                 orchestrator: relay + media interop matrix
smoke.toml               relay config (anonymous, self-signed localhost)
token.sh                 orchestrator: moq-token generate/verify interop matrix
clients/
  python/smoke.py        publish/subscribe via moq-rs (PyPI)
  go/                     publish/subscribe via moq-dev/moq-go (go get)
  js/                     headless-Chromium publish/subscribe via @moq/watch + @moq/publish;
                          three delivery variants: vite, esbuild, jsdelivr (shared jsdelivr/setup.js)
  swift/                  subscribe via moq-dev/moq-swift (SPM, macOS)
  kotlin/                 subscribe via dev.moq:moq (Gradle/JVM)
  c/subscribe.c          subscribe via libmoq (prebuilt release)
  js-native/subscribe.ts subscribe via @moq/net + @moq/hang + WebTransport polyfill (node, bun)
  (gst)                   subscribe via the moq-gst plugin (moqsrc); no client dir, driven by gst-launch
  token/js/              installs @moq/token (npm) for token.sh to drive under node + bun
freshness.sh             enforces the "always latest, no package locks" policy
.github/workflows/smoke.yml   nightly + on-demand CI matrix (os x channel)
```

## Token interop

`token.sh` is a second, independent smoke test for moq's authentication tooling.
`moq-relay` is keyed with a JWK and verifies the JWTs that publishers and
subscribers present, so a token minted by one implementation has to verify under
the implementation a relay was keyed with. The token tooling ships in several
published flavours, and this test proves they cross-verify:

| Cell | Source under test | Install |
|---|---|---|
| `rust` | the `moq-token-cli` binary (crates.io / Homebrew tap / apt repo / the moq flake) | `cargo install moq-token-cli`, `brew install moq-dev/tap/moq-token-cli`, `apt install`, `nix run github:moq-dev/moq#moq-token-cli` |
| `js-node` | npm [`@moq/token`](https://www.npmjs.com/package/@moq/token)'s `moq-token` CLI, run under **node** | `npm i @moq/token` |
| `js-bun` | the same published npm package, run under **bun** | `npm i @moq/token` |

Like `smoke.sh`, the Rust binary is taken from `PATH` (or `TOKEN_BIN`), so the
install channel is whatever put `moq-token-cli` there; `@moq/token` is installed
from npm on each run. For every *(generator × verifier × algorithm)* cell, the
generator mints a key and signs a token, and the verifier checks it — covering
both symmetric (`HS256`, shared secret) and asymmetric (`EdDSA`/`ES256`/`RS256`,
sign-private/verify-public) keys, and the fact that one side's key encoding
(the Rust CLI writes base64url-JSON; `@moq/token` writes plain JSON) loads on the
other. A negative pass then confirms each verifier **rejects** a tampered token
and a token signed by the wrong key, so a green cell means "accepts the valid
one and refuses the bad ones", not "accepts everything".

This complements moq's in-tree token unit tests: those run against workspace
source with hardcoded fixtures; this runs the real published CLIs, live on both
sides, so a packaging break (a missing bin in the `.deb`, a stale formula, an
export that didn't survive `tsc`) shows up as a red cell.

```bash
just token            # default: rust generates + verifies (roundtrip + negatives)
just token-full       # full matrix: rust, js-node, js-bun all generate + verify
# or call it directly with explicit axes:
./token.sh --generators rust,js-node --verifiers rust,js-bun --algorithms HS256,EdDSA
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
- **Native JS on bun** (`js-native-bun`): working. `@moq/net` + `@moq/hang` + moq's `@moq/web-transport` polyfill connect via WebTransport and read frames under Bun. (An earlier attempt with `@fails-components/webtransport` crashed Bun; moq's own polyfill is the one to use.)
- **Native JS on node** (`js-native-node`): red. `@moq/web-transport`'s `src/session.ts` does `import { NapiClient } from "../napi.js"` — a *named* import from a napi-rs CJS module whose exports node's ESM loader can't statically see, so node throws `does not provide an export named 'NapiClient'`. Bun's looser CJS interop accepts it. The fix lives in `@moq/web-transport` (default-import the CJS binding, then destructure); this cell goes green once that ships. Tracked upstream in moq-dev/web-transport.
- **Go (any role)**: red. The published `moq-dev/moq-go` module is still un-buildable (stuck at v0.2.15): it's missing the generated `moq.h` header (its `moq.go` does `#include <moq.h>`) and the linux static libs, so `go get` + build fails. Tracked upstream in moq-dev/moq's release-go packaging.
- **GStreamer subscribe** (`gst`): red — but only because no `moq-gst` release has been published yet. The plugin, its packaging (apt/brew/rpm/tarball + nix), and a `gst-inspect` CI check all exist in-tree, but no `moq-gst-v*` tag has been cut, so there's no installable artifact and the cell reports "no moq-gst-v\* release found". The interop itself is verified: built from source (`cargo build -p moq-gst`) and pointed at via `MOQ_GST_PLUGIN_DIR`, `moqsrc` reads a rust-published H.264 broadcast end-to-end. The cell flips green automatically once the first release ships.
- **Token interop** (`token.sh`): working. The published `moq-token-cli` (crates.io) and `@moq/token` (npm, under both node and bun) cross-verify every token in all nine generator×verifier pairings across `HS256`, `EdDSA`, `ES256`, and `RS256`, and each verifier rejects tampered tokens and the wrong key. Subscriber-only languages don't ship token tooling yet, so the matrix is rust + the two JS runtimes for now.

A broken published package fails only its own matrix cells (see `mark_broken` in `smoke.sh` / `token.sh`); it never aborts the rest of the run.
