{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.systems.url = "github:nix-systems/aarch64-darwin";
  inputs.parts.url = "github:hercules-ci/flake-parts";
  inputs.parts.inputs.nixpkgs-lib.follows = "nixpkgs";

  outputs =
    inputs:
    inputs.parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      flake.overlays.default = pkgs: _: { aniremind = pkgs.callPackage ./default.nix { }; };

      perSystem =
        { lib
        , pkgs
        , system
        , ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
          };

          packages = { inherit (pkgs) aniremind; default = pkgs.aniremind; };

          devShells.default = pkgs.mkShell {
            inputsFrom = with pkgs; [ aniremind ];
            packages = with pkgs; [
              nixpkgs-fmt
              swiftPackages.swift-format
            ];
          };

          formatter = pkgs.writeShellScriptBin "formatter" ''
            set -eoux pipefail
            shopt -s globstar

            root="$PWD"
            while [[ ! -f "$root/.git/index" ]]; do
              if [[ "$root" == "/" ]]; then
                exit 1
              fi
              root="$(dirname "$root")"
            done
            pushd "$root" > /dev/null

            ${lib.getExe pkgs.deno} fmt .
            ${lib.getExe pkgs.gitleaks} git --pre-commit --staged --verbose
            ${lib.getExe pkgs.nixpkgs-fmt} .
            ${lib.getExe pkgs.swiftPackages.swift-format} --in-place --recursive .

            popd
          '';
        };
    };
}
