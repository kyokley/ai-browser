# SPDX-License-Identifier: Unlicense
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        # inputs.flake-parts.flakeModules.partitions
        inputs.treefmt-nix.flakeModule
      ];

      # partitions.dev = {
      #   extraInputsFlake = ./dev;
      #   module = {
      #     imports = [ ./dev/flake-module.nix ];
      #   };
      # };

      # partitionedAttrs = {
      #   checks = "dev";
      #   devShells = "dev";
      # };

      perSystem =
        {
          system,
          pkgs,
          inputs',
          self',
          ...
        }:
        {
          # You can use `extend' to extend the packages with an overlay (or use
          # `import inputs.nixpkgs { ... }`).
          _module.args.pkgs = inputs.nixpkgs.legacyPackages.${system};

          devShells.default = pkgs.mkShell {
            packages = with self'.packages; [
              ai-browser
              opencode-wrapped
            ];
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              zizmor.enable = true;
            };
          };

          packages =
            let
              python-websockets = pkgs.python3.withPackages (ps: [
                ps.websockets
              ]);
              opencode-wrapped = pkgs.stdenv.mkDerivation {
                inherit (pkgs.opencode) pname version;
                src = ./.;
                nativeBuildInputs = with pkgs; [
                  makeWrapper
                ];
                buildInputs = with pkgs; [
                  opencode
                ];

                installPhase = ''
                  mkdir -p $out/{bin,lib}
                  cp -r ./bin ./lib $out/

                  touch $out/lib/opencode/.gitignore

                  makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/opencode \
                    --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.chromium python-websockets]} \
                    --set OPENCODE_CONFIG_DIR "$out/lib/opencode"

                  chmod +x $out/bin/opencode
                '';
              };
            in
            rec {
              inherit opencode-wrapped python-websockets;
              ai-browser = pkgs.stdenv.mkDerivation {
                pname = "ai-browser";
                version = "0.0.1";
                src = ./.;
                dontBuild = true;
                nativeBuildInputs = with pkgs; [
                  makeWrapper
                ];
                buildInputs = [
                  pkgs.chromium
                  python-websockets
                  opencode-wrapped
                ];

                installPhase = ''
                  mkdir -p $out/bin $out/lib/ai-browser
                  install -m755 bin/ai-browser $out/bin/ai-browser
                  install -m644 lib/cdp.py $out/lib/ai-browser/cdp.py
                  wrapProgram $out/bin/ai-browser \
                    --set AI_BROWSER_CHROMIUM_CMD "${pkgs.chromium}/bin/chromium" \
                    --set AI_BROWSER_PYTHON_CMD "${python-websockets}/bin/python"
                '';
              };
              default = ai-browser;
            };

          apps = {
            ai-browser = {
              type = "app";
              program = "${self'.packages.ai-browser}/bin/ai-browser";
            };
          };

          # Verify the wrapped opencode exports the bundled chromium and
          # python-websockets store paths and that both actually work.
          checks.opencode-wrapped-bundled-tools =
            pkgs.runCommand "opencode-wrapped-bundled-tools-check"
              {
                nativeBuildInputs = [ self'.packages.opencode-wrapped ];
                expectedChromium = "${pkgs.chromium}/bin/chromium";
                expectedPython = "${self'.packages.python-websockets}/bin/python";
              }
              ''
                set -euo pipefail

                wrapper="$(command -v opencode)"
                test -x "$wrapper"

                # Materialize the environment the wrapper hands to opencode.
                exports="$(grep '^export ' "$wrapper")"
                eval "$exports"

                test "$AI_BROWSER_CHROMIUM_CMD" = "$expectedChromium"
                test "$AI_BROWSER_PYTHON_CMD" = "$expectedPython"

                test -x "$AI_BROWSER_CHROMIUM_CMD"
                test -x "$AI_BROWSER_PYTHON_CMD"

                # The bundled interpreters must actually work.
                "$AI_BROWSER_PYTHON_CMD" -c 'import websockets'
                "$AI_BROWSER_CHROMIUM_CMD" --version >/dev/null

                # Smoke-run the wrapper itself.
                HOME="$TMPDIR" "$wrapper" --version >/dev/null

                touch "$out"
              '';
        };
    };
}
