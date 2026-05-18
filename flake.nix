{
  description = "Vestal — a native macOS dashboard";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        vestal = pkgs.stdenv.mkDerivation {
          pname = "vestal";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.swift ];

          buildPhase = ''
            runHook preBuild
            swiftc -O \
              -framework AppKit \
              -framework SwiftUI \
              -framework IOKit \
              -framework EventKit \
              -framework CoreAudio \
              -framework Metal \
              -framework MetalKit \
              -framework QuartzCore \
              -o vestal \
              Sources/Vestal/*.swift
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp vestal $out/bin/
            runHook postInstall
          '';

          meta = {
            description = "Native macOS dashboard — press a key, see everything at a glance";
            platforms = [
              "aarch64-darwin"
              "x86_64-darwin"
            ];
            mainProgram = "vestal";
          };
        };

        default = vestal;
      });
    };
}
