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
              mkAiBrowser =
                {
                  browser,
                  browserName,
                  withPython ? false,
                }:
                pkgs.stdenv.mkDerivation {
                  pname = "ai-browser-${browserName}";
                  inherit (pkgs.opencode) version;
                  src = ./.;
                  nativeBuildInputs = with pkgs; [
                    makeWrapper
                  ];
                  buildInputs =
                    with pkgs;
                    [
                      opencode
                    ]
                    ++ pkgs.lib.optionals withPython [
                      python-websockets
                    ];

                  installPhase = ''
                    mkdir -p $out/{bin,lib}
                    cp -r ./bin ./lib $out/

                    chmod +x $out/lib/opencode/skills/ai-browser/scripts/{cdp.py,launch-browser.sh}

                    touch $out/lib/opencode/.gitignore

                    makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/ai-browser \
                      --set AI_BROWSER_CMD "${browser}/bin/${browserName}" \
                      ${pkgs.lib.optionalString withPython ''--set AI_BROWSER_PYTHON_CMD "${python-websockets}/bin/python"''} \
                      --prefix PATH : ${
                        pkgs.lib.makeBinPath (
                          [
                            browser
                          ]
                          ++ pkgs.lib.optionals withPython [
                            python-websockets
                          ]
                        )
                      } \
                      --set OPENCODE_CONFIG_DIR "$out/lib/opencode"
                  '';
                };
            in
            rec {
              inherit python-websockets;
              ai-browser-chromium = mkAiBrowser {
                browser = pkgs.chromium;
                browserName = "chromium";
                withPython = true;
              };
              ai-browser-firefox = mkAiBrowser {
                browser = pkgs.firefox;
                browserName = "firefox";
              };
              ai-browser = ai-browser-chromium;
              default = ai-browser;
            };

          apps =
            let
              mkAiBrowserApp =
                {
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
            in
            rec {
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

          checks =
            let
              mkBrowserCheck =
                {
                  name,
                  package,
                  browserCmd,
                  withPython ? false,
                }:
                pkgs.runCommand "ai-browser-${name}-bundled-tools-check"
                  {
                    nativeBuildInputs = [ package ];
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

                    # Chromium bundles Python + websockets for CDP; Firefox does not.
                    ${pkgs.lib.optionalString withPython ''
                      test "$AI_BROWSER_PYTHON_CMD" = "${self'.packages.python-websockets}/bin/python"
                      test -x "$AI_BROWSER_PYTHON_CMD"
                      "$AI_BROWSER_PYTHON_CMD" -c 'import websockets'
                    ''}

                    "$AI_BROWSER_CMD" --version >/dev/null

                    # Smoke-run the wrapper itself.
                    HOME="$TMPDIR" "$wrapper" --version >/dev/null

                    touch "$out"
                  '';
            in
            {
              ai-browser-chromium = mkBrowserCheck {
                name = "chromium";
                package = self'.packages.ai-browser-chromium;
                browserCmd = "${pkgs.chromium}/bin/chromium";
                withPython = true;
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
