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
                dontBuild = true;
                nativeBuildInputs = with pkgs; [
                  makeWrapper
                ];
                buildInputs = with pkgs; [
                  opencode
                ];

                installPhase = ''
                  mkdir -p $out/bin
                  makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/opencode \
                    --set AI_BROWSER_CHROMIUM_CMD "${pkgs.chromium}/bin/chromium" \
                    --set AI_BROWSER_PYTHON_CMD "${python-websockets}/bin/python"
                '';
              };
            in
            {
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
            };
        };
    };
}
