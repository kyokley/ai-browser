# SPDX-License-Identifier: Unlicense
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
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

      perSystem = {
        system,
        pkgs,
        # inputs',
        self',
        ...
      }: let
        mac-firefox-install = pkgs.stdenv.mkDerivation rec {
          pname = "Firefox";
          version = "152.0.6";
          nativeBuildInputs = [pkgs.undmg];
          sourceRoot = ".";
          phases = ["unpackPhase" "installPhase"];
          unpackPhase = ''
            undmg "$src"
          '';
          installPhase = ''
            mkdir -p "$out/Applications"
            cp -r Firefox.app "$out/Applications/Firefox.app"
          '';
          src = builtins.fetchurl {
            name = "Firefox-${version}.dmg";
            url = "https://download-installer.cdn.mozilla.net/pub/firefox/releases/${version}/mac/en-US/Firefox%20${version}.dmg";
            sha256 = "0v41lygbxry844an4rmqncw49n769yrh1ig0dl80ngh6jbah4w3l";
          };
        };
          firefox-pkg =
            if pkgs.stdenv.hostPlatform.isDarwin
            then mac-firefox-install
            else pkgs.firefox;
      in {
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

        packages = let
          python-websockets = pkgs.python3.withPackages (ps: [
            ps.websockets
          ]);
          mkAiBrowser = {
            browser,
            browserName,
          }:
            pkgs.stdenv.mkDerivation {
              pname = "ai-browser-${browserName}";
              inherit (pkgs.opencode) version;
              src = ./.;
              nativeBuildInputs = with pkgs; [
                makeWrapper
              ];
              buildInputs = with pkgs; [
                opencode
                python-websockets
              ];

              installPhase = ''
                mkdir -p $out/{bin,lib}
                cp -r ./bin ./lib $out/

                chmod +x $out/lib/opencode/skills/ai-browser/scripts/{cdp.py,launch-browser.sh}

                touch $out/lib/opencode/.gitignore

                makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/ai-browser \
                  --set AI_BROWSER_CMD "${browser}/bin/${browserName}" \
                  --set AI_BROWSER_PYTHON_CMD "${python-websockets}/bin/python" \
                  --prefix PATH : ${
                  pkgs.lib.makeBinPath [
                    browser
                    python-websockets
                  ]
                } \
                  --set OPENCODE_CONFIG_DIR "$out/lib/opencode"
              '';
            };
        in rec {
          inherit python-websockets;
          ai-browser-chromium = mkAiBrowser {
            browser = pkgs.chromium;
            browserName = "chromium";
          };
          ai-browser-firefox = mkAiBrowser {
            browser = firefox-pkg;
            browserName = "firefox";
          };
          ai-browser = ai-browser-chromium;
          default = ai-browser;
        };

        apps = let
          mkAiBrowserApp = {
            package,
            prompt,
          }:
            pkgs.writeShellApplication {
              name = "ai-browser";
              runtimeInputs = [
                package
              ];
              text = ''
                exec ${package}/bin/ai-browser --prompt "${prompt}"
              '';
            };
        in rec {
          ai-browser-chromium = {
            type = "app";
            program = "${
              mkAiBrowserApp {
                package = self'.packages.ai-browser-chromium;
                prompt = "open a chromium browser";
              }
            }/bin/ai-browser";
            meta.description = "AI enhanced web browser (Chromium)";
          };
          ai-browser-firefox = {
            type = "app";
            program = "${
              mkAiBrowserApp {
                package = self'.packages.ai-browser-firefox;
                prompt = "open a firefox browser";
              }
            }/bin/ai-browser";
            meta.description = "AI enhanced web browser (Firefox)";
          };
          ai-browser = ai-browser-chromium;
          default = ai-browser;
        };

        checks = let
          mkBrowserCheck = {
            name,
            package,
            browserCmd,
          }:
            pkgs.runCommand "ai-browser-${name}-bundled-tools-check"
            {
              nativeBuildInputs = [package];
              expectedBrowser = browserCmd;
            }
            ''
              set -euo pipefail

              # The wrapper is installed as bin/ai-browser.
              wrapper="$(command -v ai-browser)"
              test -x "$wrapper"

              # Materialize the environment the wrapper hands to opencode.
              exports="$(grep '^export ' "$wrapper")"
              eval "$exports"

              test "$AI_BROWSER_CMD" = "$expectedBrowser"

              test -x "$AI_BROWSER_CMD"

              # Python + websockets are always bundled for CDP/WebSocket use.
              test "$AI_BROWSER_PYTHON_CMD" = "${self'.packages.python-websockets}/bin/python"
              test -x "$AI_BROWSER_PYTHON_CMD"
              "$AI_BROWSER_PYTHON_CMD" -c 'import websockets'

              "$AI_BROWSER_CMD" --version >/dev/null

              # Smoke-run the wrapper itself.
              HOME="$TMPDIR" "$wrapper" --version >/dev/null

              touch "$out"
            '';
        in {
          ai-browser-chromium = mkBrowserCheck {
            name = "chromium";
            package = self'.packages.ai-browser-chromium;
            browserCmd = "${pkgs.chromium}/bin/chromium";
          };
          ai-browser-firefox = mkBrowserCheck {
            name = "firefox";
            package = self'.packages.ai-browser-firefox;
            browserCmd = "${pkgs.firefox}/bin/firefox";
          };
        };
      };
    };
}
