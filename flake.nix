{
  description = "Vestal: a keypress-toggled dashboard overlay";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # darwin builds Vestal.app; Linux builds the CLI-only `vestal` for now.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Short commit hash for BuildInfo. On a dirty tree (uncommitted changes)
      # `self.shortRev` is missing; `dirtyShortRev` is the same hash with a
      # "-dirty" suffix.
      buildCommit = self.shortRev or self.dirtyShortRev or "dirty";
    in
    {
      packages = forAllSystems (pkgs: rec {
        # SwiftPM build of the `vestal` product; see package.nix.
        vestal = pkgs.callPackage ./package.nix { commit = buildCommit; };

        # The website (site/dist) as static files; see nix/site.nix.
        site = pkgs.callPackage ./nix/site.nix { inherit vestal; };

        default = vestal;
      });

      devShells = forAllSystems (pkgs: {
        # `swift build` with the same toolchain as the package. On Linux,
        # `swift test` fails here (nixpkgs' Swift has no libIndexStore to
        # discover tests with); `nix flake check` runs the tests instead.
        # Linux: clang as $CC, for SwiftPM's C target (see package.nix).
        default = (if pkgs.stdenv.hostPlatform.isLinux then pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } else pkgs.mkShell) (
          {
            packages = [
              pkgs.swift
              pkgs.swiftpm
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.swiftPackages.Foundation
              pkgs.swiftPackages.Dispatch
              pkgs.swiftPackages.XCTest
              # The GTK UI (VestalLinux): vestal-gtk4.pc and its libraries.
              pkgs.pkg-config
              pkgs.sqlite
              (pkgs.callPackage ./nix/gtk-pkgconfig.nix { })
            ];
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            # Where a dev build of the macOS UI finds the Phosphor icon fonts and the typefaces
            # (the app bundle has them in Contents/Resources/Fonts).
            VESTAL_FONT_DIRS = "${./Resources/icons}:${./Resources/fonts}";
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # SwiftPM compiles and runs Package.swift against libdispatch.
            LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.swiftPackages.Dispatch ];
            # Where a dev build of the Linux UI finds Geist, Geist Mono and
            # the Phosphor icon fonts (the package installs them next to the
            # binary instead).
            VESTAL_FONT_DIRS = lib.concatStringsSep ":" [
              "${pkgs.geist-font}/share/fonts"
              "${./Resources/icons}"
              "${./Resources/fonts}"
            ];
          }
        );
      });

      # pkgs.vestal built with the consumer's nixpkgs instead of this flake's,
      # for a system that should share its libraries (on Linux: GTK, and the
      # glibc the graphics drivers in /run/opengl-driver were built against).
      overlays.default = final: _prev: {
        vestal = final.callPackage ./package.nix { commit = buildCommit; };
      };

      checks = forAllSystems (pkgs: import ./nix/checks.nix { inherit pkgs self nixpkgs; });

      # Home Manager module: programs.vestal. See the README.
      homeManagerModules = {
        vestal = import ./nix/hm-module.nix self;
        default = self.homeManagerModules.vestal;
      };
    };
}
