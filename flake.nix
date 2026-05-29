{
  description = "moq smoke - interop test for the public moq packages";

  # nixpkgs is pinned to the same revision moq-dev/moq locks, so the toolchain
  # (and the Playwright Chromium) is already in most contributors' nix store.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ebc08544afa77957cc348ba72dc490ec73b87f68";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          # smoke.sh installs the clients from public registries; this shell only
          # provides the toolchains those installs need. The Rust binaries under
          # test (moq-relay, moq-cli) come from a channel (cargo/brew/apt), not
          # from here -- though `cargo` is included so `cargo install moq-cli` works.
          packages = with pkgs; [
            # orchestrator + harness tools
            just
            ffmpeg
            curl
            coreutils # GNU `timeout` (macOS lacks it)
            procps # `pgrep`

            # rust client + a way to `cargo install` the binaries under test
            cargo
            rustc

            # python client (PyPI moq-rs)
            uv
            python3

            # go client (go get moq-dev/moq-go); cgo links the prebuilt libmoq_ffi.a
            go

            # browser client (npm @moq/watch + @moq/publish)
            bun
            nodejs_24
            # Headless Chromium. The npm `playwright` version in clients/js must
            # match the browser build this ships (chromium-1208 here), so it's
            # pinned exactly there; bumping nixpkgs means bumping that pin too.
            playwright-driver.browsers
          ];

          shellHook = ''
            # Use the nix-provided Chromium instead of letting Playwright download one.
            export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
          '';
        };
      }
    );
}
