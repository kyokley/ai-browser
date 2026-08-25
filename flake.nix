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
              ai-browser-pkg = pkgs.stdenv.mkDerivation {
                pname = "ai-browser";
                inherit (pkgs.opencode) version;
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

                  chmod +x $out/lib/opencode/skills/ai-browser/scripts/{cdp.py,launch-browser.sh}

                  touch $out/lib/opencode/.gitignore

                  makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/ai-browser \
                    --set AI_BROWSER_CHROMIUM_CMD "${pkgs.chromium}/bin/chromium" \
                    --set AI_BROWSER_PYTHON_CMD "${python-websockets}/bin/python" \
                    --prefix PATH : ${
                      pkgs.lib.makeBinPath [
                        pkgs.chromium
                        python-websockets
                      ]
                    } \
                    --set OPENCODE_CONFIG_DIR "$out/lib/opencode"
                '';
              };
            in
            rec {
              inherit python-websockets;
              ai-browser = ai-browser-pkg;
              default = ai-browser;
            };

          apps = let
            ai-browser-app = pkgs.writeShellApplication {
              name = "ai-browser";
              runtimeInputs = [
                self'.packages.ai-browser
              ];
              text = ''
                exec ${self'.packages.ai-browser}/bin/ai-browser --prompt "open a chromium browser"
              '';
            };
            in rec {
            ai-browser = {
              type = "app";
              program = "${ai-browser-app}/bin/ai-browser";
              meta.description = "AI enhanced web browser";
            };
            default = ai-browser;
          };

          # Verify the wrapped opencode exports the bundled chromium and
          # python-websockets store paths and that both actually work.
          checks.ai-browser =
            pkgs.runCommand "ai-browser-bundled-tools-check"
              {
                nativeBuildInputs = [ self'.packages.ai-browser ];
                expectedChromium = "${pkgs.chromium}/bin/chromium";
                expectedPython = "${self'.packages.python-websockets}/bin/python";
              }
              ''
                set -euo pipefail

                # The wrapper is installed as bin/ai-browser.
                wrapper="$(command -v ai-browser)"
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
