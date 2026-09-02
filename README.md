# moq smoke

Cross-language interop smoke test for the **public** [Media over QUIC](https://github.com/moq-dev/moq) packages, plus source-head interoperability coverage with [Cloudflare's `moq-rs`](https://github.com/cloudflare/moq-rs) and Meta's [`moxygen`](https://github.com/facebookexperimental/moxygen).

The [moq-dev/moq](https://github.com/moq-dev/moq) monorepo has its own in-tree smoke test, but it builds every client from workspace source. That proves the code in the tree works; it does **not** prove a real user can install the published artifacts and have them talk to each other. A missing wheel, a stale Homebrew formula, a broken `.deb`, an export that didn't survive packaging, a Go module missing its header. none of that shows up until someone installs from a registry.

This repo installs each client straight from its public package registry, stands up a relay, and runs the interop matrix:

- A relay (`moq-relay`) routes broadcasts.
- For each publisher language, publish an H.264 broadcast.
- For each subscriber language, confirm bytes flow end-to-end (a non-empty frame before the timeout).

We check that bytes move across implementations, not that H.264 decodes.

## Clients and channels

| Client | Source under test | Install |
|---|---|---|
| `moq-relay` + `moq` (Rust) | crates.io / Homebrew tap / apt repo / the moq flake / Docker Hub | `cargo install`, `brew install moq-dev/tap/...`, `apt install`, `nix build github:moq-dev/moq#...`, `docker run moqdev/moq-relay` |
| Python | [PyPI `moq-rs`](https://pypi.org/project/moq-rs/) (import `moq`) | `uv pip install moq-rs` |
| Go | [`github.com/moq-dev/moq-go`](https://github.com/moq-dev/moq-go) | `go get` |
| Browser | npm [`@moq/watch`](https://www.npmjs.com/package/@moq/watch) + [`@moq/publish`](https://www.npmjs.com/package/@moq/publish), delivered three ways | headless Chromium (Playwright) loading a **vite** bundle, an **esbuild** bundle, or straight from the **jsDelivr** ESM CDN |
| Native JS | npm [`@moq/net`](https://www.npmjs.com/package/@moq/net) + [`@moq/hang`](https://www.npmjs.com/package/@moq/hang) + moq's own [`@moq/web-transport`](https://www.npmjs.com/package/@moq/web-transport) polyfill | non-browser runtimes: **node** and **bun** |
| Swift | SPM [`moq-dev/moq-swift`](https://github.com/moq-dev/moq-swift) | `swift build` (macOS, Xcode toolchain) |
| Kotlin | Maven Central [`dev.moq:moq`](https://central.sonatype.com/artifact/dev.moq/moq) | `gradle` (JVM) |
| C | [`libmoq`](https://github.com/moq-dev/moq/releases) prebuilt release assets | `cc` + the platform tarball |
| GStreamer | [`moq-gst`](https://github.com/moq-dev/moq/releases?q=moq-gst) prebuilt plugin (apt `gstreamer1.0-moq` / brew tap / rpm / tarball) | `gst-launch-1.0` + the platform tarball, against a **system** GStreamer |

Cloudflare's fork is tested separately because it uses a different media catalog and track layout, so putting its fMP4 tools into the Hang media matrix would create application-format failures rather than transport interop coverage. [`cloudflare.sh`](cloudflare.sh) builds both projects' relays from their latest default branches (honoring each checkout's committed Rust dependency lock), then drives them with a purpose-built Cloudflare client over WebTransport and raw QUIC. Against both relays it validates 32 complete 64 KiB subgroup objects (2 MiB total) byte-for-byte; against Cloudflare's relay it also validates 32 complete QUIC datagrams per transport. This is deliberately stronger than a setup-only or single-object protocol probe.

Meta's moxygen is also tested separately from the Hang media matrix because its media samples use MoQ Media Interop packaging. [`moxygen.sh`](moxygen.sh) pulls moxygen's source-head `moxygen-interop-client` image and runs all six of its self-contained relay cases through the latest `moq-dev/moq` relay over WebTransport and raw QUIC: setup, namespace publication and withdrawal, expected subscription failure, announced publish/subscribe routing, and subscribe-before-announce behavior. The lane deliberately negotiates draft-16, which moxygen currently recommends for new integrations while its draft-18 support remains experimental. The published image is Linux/amd64 and the test uses Docker host networking, so this lane runs on Linux CI rather than in the package-channel matrix.

The **Native JS** client runs the JS packages *outside* a browser, where there's no native WebTransport, using moq's own `@moq/web-transport` polyfill (a prebuilt NAPI QUIC/HTTP3 addon). It runs as two cells, `js-native-node` and `js-native-bun`, to catch runtime-specific breakage. Subscribe only here too: publishing media needs a WebCodecs encoder, which a native JS runtime lacks (reading raw container frames doesn't).

Swift, Kotlin, C, and GStreamer **subscribe only**. The FFI wrappers (Swift/Kotlin/C) publish through the streaming importer (`publish_media_stream`), which isn't in the published 0.2.x FFI yet, so they can only subscribe until it ships; the GStreamer cell drives `moqsrc` (publishing via `moqsink` needs an encoder + request-pad muxing — a follow-up). Rust and the browser publish today.

The **GStreamer** client downloads the latest `moq-gst` plugin tarball, points `GST_PLUGIN_PATH` at it, and runs `moqsrc url=… broadcast=… ! filesink` — the same "did a frame's bytes arrive" bar as every other subscriber, no decode. The prebuilt plugin dynamic-links the host's *system* GStreamer (the `.deb`/brew/tarball scenario), so this cell needs `gst-launch-1.0` + the core plugins on the system, not nix; under a bare nix shell with no system GStreamer it just marks itself unavailable. Point `MOQ_GST_PLUGIN_DIR` at a local `cargo build -p moq-gst` output to test an unreleased build.

The Rust binaries (`moq-relay`, `moq`) ship through five channels that deliver the *same* binaries. CI treats each as a separate test where the OS supports it: Linux exercises **apt**, **cargo**, **nix**, **docker**; macOS exercises **brew**, **cargo**, **nix**. `smoke.sh` itself just takes whatever is on `PATH` (or `RELAY_BIN`/`MOQ_BIN`); the channel is chosen by how the binaries are provided:

- **cargo** / **brew** / **apt** put the binaries on `PATH` (`cargo install moq-relay moq-cli` installs `moq-relay` and `moq`, etc.).
- **nix** builds them from the moq flake (`just nix-channel`), the same package output `nix run github:moq-dev/moq#moq-cli` resolves. The moq flake is referenced ad-hoc with `--refresh`, so the moq version is always the latest default-branch build, never locked by this repo.
- **docker** points `RELAY_BIN`/`MOQ_BIN` at the wrapper scripts in [`clients/docker/`](clients/docker), which `docker run --network host` the published [`moqdev/moq-relay`](https://hub.docker.com/r/moqdev/moq-relay) + [`moqdev/moq-cli`](https://hub.docker.com/r/moqdev/moq-cli) images (`:latest`, pulled fresh). Host networking lets the containerised relay bind the ports the orchestrator and the cli containers reach on `127.0.0.1`, so the committed `smoke.toml` works unchanged. Linux-only (a native Docker daemon); the other language clients still install from their own registries, so this run also proves the Docker relay routes between every implementation. Override the runtime with `SMOKE_DOCKER=podman`.

The **browser** client is itself three delivery variants of the *same* page, run as separate matrix cells, to catch breakage specific to how the package is consumed:

- `js-vite` — bundled by [vite](https://vite.dev/).
- `js-esbuild` — bundled by [esbuild](https://esbuild.github.io/) (a different bundler).
- `js-jsdelivr` — no bundler, no install: the page `import`s the packages straight from the [jsDelivr](https://www.jsdelivr.com/) ESM CDN (`https://cdn.jsdelivr.net/npm/@moq/watch/element/+esm`), which resolves the export map and bundles the dep graph.

## Running locally

The repo ships a Nix flake (`.envrc` auto-loads it via direnv) with every client toolchain: ffmpeg, uv, go, bun, Node, Chromium via Playwright, cargo, coreutils, jq, and the linters. It does **not** carry the moq binaries; those come from a channel.

```bash
nix develop                       # drops you in a shell with the toolchain
# then either bring the binaries via a channel...
cargo install moq-relay moq-cli   # installs moq-relay + moq (or brew / apt)
just full                         # full matrix, --timeout 30
# Cloudflare client/relay self-test + Cloudflare client against moq-dev relay:
just cloudflare
# Moxygen's protocol interop client against the moq-dev relay (Linux Docker):
just moxygen
# ...or use the moq flake as the channel (builds moq, no install needed):
just nix-channel --publishers rust,js-vite --subscribers rust,python,js-jsdelivr --timeout 30
```

`PLAYWRIGHT_BROWSERS_PATH` is set by the flake, so the browser client uses the nix Chromium. The npm `playwright` in `clients/js/package.json` is pinned to match that Chromium build (enforced by `freshness.sh`); bumping nixpkgs means bumping that pin too.

Without Nix, you need the relay + CLI on `PATH` plus the toolchains for whichever clients you include:

```bash
cargo install moq-relay moq-cli       # installs moq-relay + moq (or brew / apt)
# python -> uv ; go -> go ; browser -> bun (+ chromium)

# default matrix is rust-only:
./smoke.sh

# full matrix (browser variants: js-vite, js-esbuild, js-jsdelivr):
just full   # or: ./smoke.sh --publishers rust,python,js-vite --subscribers rust,js-jsdelivr ...

# point at a specific build instead of PATH:
RELAY_BIN=/path/to/moq-relay MOQ_BIN=/path/to/moq ./smoke.sh

# prove the harness can fail: no publisher, every subscriber must time out.
./smoke.sh --negative --subscribers rust,python
```

`smoke.sh` installs the language clients (PyPI / Go proxy / npm) into a scratch dir on each run, so you always test the latest published versions. It does **not** install the Rust binaries; that is the channel under test.

## Layout

```
smoke.sh                 orchestrator: relay + media interop matrix
cloudflare.sh            orchestrator: Cloudflare client through both projects' relays
moxygen.sh               orchestrator: moxygen protocol client through the moq-dev relay
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
  docker/                 moq-relay + moq wrappers: docker run the moqdev/* images (the docker channel)
  token/js/              installs @moq/token (npm) for token.sh to drive under node + bun
  cloudflare/             deterministic subgroup/datagram client using cloudflare/moq-rs Git HEAD
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
| `rust` | the `moq-token` binary (crates.io / Homebrew tap / apt repo / the moq flake) | `cargo install moq-token-cli`, `brew install moq-dev/tap/moq-token-cli`, `apt install`, `nix run github:moq-dev/moq#moq-token-cli` |
| `js-node` | npm [`@moq/token`](https://www.npmjs.com/package/@moq/token)'s `moq-token` CLI, run under **node** | `npm i @moq/token` |
| `js-bun` | the same published npm package, run under **bun** | `npm i @moq/token` |
| `rust-docker` | the [`moqdev/moq-token-cli`](https://hub.docker.com/r/moqdev/moq-token-cli) Docker Hub image (`:latest`) | `docker run moqdev/moq-token-cli …` |

Like `smoke.sh`, the Rust binary is taken from `PATH` (or `TOKEN_BIN`), preferring
`moq-token` and falling back to `moq-token-cli` while channels finish the rename;
`@moq/token` is installed from npm on each run; `rust-docker` `docker pull`s the
`moqdev/moq-token-cli`
image fresh (`:latest`) and runs the CLI in a throwaway container with the scratch
dir bind-mounted. The image is built `FROM nixos/nix` and ships the nix store, so
it's a genuinely different artifact from the `cargo`/`brew`/`apt` binaries — and
in CI it runs only on the Linux runners (GitHub's macOS runners have no Docker
daemon); set `TOKEN_DOCKER=podman` to drive it with podman. For every
*(generator × verifier × algorithm)* cell, the
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
just token-full       # full matrix: rust, js-node, js-bun + rust-docker (the
                      # moqdev/moq-token-cli image, where a container runtime is
                      # available; set TOKEN_DOCKER=podman to use podman)
# or call it directly with explicit axes:
./token.sh --generators rust,js-node --verifiers rust,js-bun --algorithms HS256,EdDSA
```

## Always the latest moq packages (no package lock files)

To test what a user gets today, this repo commits **no package lock files** (`go.sum`, `bun.lock`, `Cargo.lock`, `uv.lock`, ... are gitignored). Every run re-resolves the moq packages to their latest published versions: `@moq/*` at the `latest` npm tag, `moq-rs` via `uv pip install`, `moq-go` via `go get @latest`, and the **nix** channel builds the moq flake ad-hoc with `--refresh`. The Cloudflare suite similarly resolves both `cloudflare/moq-rs` and `moq-dev/moq` from their unpinned Git default branches.

`flake.lock` *is* committed: it pins the dev **toolchain** (nixpkgs), not the moq packages, so the shell is reproducible. The moq flake is never an input here, so locking the toolchain never locks moq.

The one version that can't float freely is the npm `playwright`, which must match the Chromium the toolchain ships. The flake exports that version as `PLAYWRIGHT_VERSION`, and `freshness.sh` (run by `just freshness`, by CI, and at the top of `smoke.sh`) fails if the pin in `clients/js/package.json` drifts from it, if a *package* lock file gets committed, or if a moq package stops being requested at latest. So even the one pin can't go stale silently; bump the toolchain with `nix flake update` and the pin together.

```bash
just freshness   # enforce the policy
just check       # lint + freshness
```

## Current state

This test tracks the **latest published** packages, so it sometimes runs ahead of a release. A red cell is the signal, not noise. As of this writing:

- **Rust publish/subscribe** and **browser publish/subscribe** (all three delivery variants: vite, esbuild, jsDelivr): working (`cargo install` / `brew` / `apt` / `nix` + npm/CDN). The green baseline.
- **Docker channel** (`moqdev/moq-relay` + `moqdev/moq-cli`, Linux): working. The containerised relay routes the full matrix and the containerised `moq` publishes/subscribes end-to-end, validated against the published images.
- **Python publish/subscribe**: working. `moq-rs` 0.2.16 shipped the streaming importer (`publish_media_stream`), so Python now publishes a raw Annex-B broadcast too, verified end-to-end against rust/swift/c subscribers.
- **Swift / Kotlin / C subscribe**: working, verified end-to-end against the published 0.2.16 / 0.3.0 packages (`moq-dev/moq-swift`, `dev.moq:moq`, `libmoq`). Subscriber-only by choice.
- **Native JS on bun** (`js-native-bun`): working. `@moq/net` + `@moq/hang` + moq's `@moq/web-transport` polyfill connect via WebTransport and read frames under Bun. (An earlier attempt with `@fails-components/webtransport` crashed Bun; moq's own polyfill is the one to use.)
- **Native JS on node** (`js-native-node`): working. node briefly lagged bun here: `@moq/web-transport`'s `session.ts` did `import { NapiClient } from "../napi.js"` — a *named* import from a napi-rs CJS module whose exports node's ESM loader can't statically see, so node threw `does not provide an export named 'NapiClient'` while Bun's looser CJS interop accepted it. `@moq/web-transport` 0.1.2 shipped the predicted fix (default-import the now-`.cjs` binding, then destructure `NapiClient`), so this cell is green. Exactly the break-then-fix this repo exists to surface.
- **Go (any role)**: working. The `moq-dev/moq-go` module was un-buildable (stuck at v0.2.15, missing the generated `moq.h` header and the prebuilt static libs, so `go get` + build failed); v0.2.22 now ships `moq.h` plus `libmoq_ffi.a` for linux (amd64/arm64), darwin, and windows, and a `CGO_ENABLED=1 go build` against it links cleanly — verified in a linux/amd64 container, clearing the blocker that kept this cell red. One caveat the matrix doesn't see: building the Go client on **macOS** still fails to link, because the module's darwin cgo `LDFLAGS` omit `-framework CoreServices` (needed by the bundled Rust `notify` crate's FSEvents backend); CI only builds Go on Linux. Tracked upstream in moq-dev/moq's `go/moq/cgo.go`.
- **GStreamer subscribe** (`gst`): working. The first `moq-gst` releases have now shipped (latest `moq-gst-v0.2.7`, with apt/brew/rpm/tarball + nix artifacts), so the cell resolves the newest tag and downloads the prebuilt plugin instead of reporting "no moq-gst-v\* release found". The published plugin load-checks green — `gst-inspect-1.0 moq` exposes `moqsrc`/`moqsink` against a system GStreamer (verified locally against the 0.2.7 tarball) — and `moqsrc` reads a rust-published H.264 broadcast end-to-end.
- **Token interop** (`token.sh`): working on **cargo / apt / nix** plus the **`moqdev/moq-token-cli` Docker image** (Linux). The published `moq-token` binary (from crates.io / apt / nix / Docker Hub) and `@moq/token` (npm, under both node and bun) cross-verify every token across `HS256`, `EdDSA`, `ES256`, and `RS256`, and each verifier rejects tampered tokens and the wrong key. The Docker cell (`rust-docker`) proves the image — built `FROM nixos/nix`, so it carries the libiconv the brew bottle used to leak — runs cleanly. Subscriber-only languages don't ship token tooling yet, so the matrix is rust (binary + Docker) + the two JS runtimes for now.
- **Token interop on the Homebrew bottle** (`rust` cells, macOS `brew`): working. The `moq-dev/tap/moq-token-cli` package's `moq-token` binary used to abort on launch — it baked in a `/nix/store/…-libiconv/lib/libiconv.2.dylib` rpath from the build sandbox that doesn't exist on a user's Mac (`dyld: Library not loaded`). The 0.5.31 bottle fixes it: its only `LC_RPATH` is now `/usr/lib`, so `@rpath/libiconv.2.dylib` resolves to the system libiconv and the binary runs (verified locally — `generate --algorithm HS256` succeeds, no leaked `/nix/store` rpath). `token.sh` still probes the binary once at startup, so a relapse would be caught again. Exactly the break-then-fix this repo exists to surface.
- **Cloudflare interoperability**: the Cloudflare client publishes and subscribes over WebTransport and raw QUIC through both `cloudflare/moq-rs`'s `moq-relay-ietf` and `moq-dev/moq`'s `moq-relay`, with sustained subgroup payloads checked byte-for-byte. Cloudflare's relay additionally exercises datagrams in both directions. This is a source-head smoke test, so a later upstream commit can intentionally turn it red.
- **Moxygen interoperability**: currently **red**. Moxygen's published source-head interop client negotiates draft-16 and passes 5/6 relay scenarios through `moq-dev/moq`, but `announce-subscribe` closes the subscriber session instead of routing it to the announced publisher. The failure reproduces over WebTransport and raw QUIC with the published relay, and over WebTransport with current moq-dev HEAD. CI runs the full Linux/amd64 Docker lane as non-blocking diagnostic coverage until the mismatch is fixed; `just moxygen` still exits nonzero locally.

A broken published package fails only its own matrix cells (see `mark_broken` in `smoke.sh` / `token.sh`); it never aborts the rest of the run.
