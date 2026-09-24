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
      # Short commit hash for BuildInfo. `self.shortRev` is null on a dirty
      # tree (uncommitted changes); fall back to a marker so the info popup
      # still reads something.
      buildCommit = self.shortRev or "dirty";
    in
    {
      packages = forAllSystems (pkgs: rec {
        # SwiftPM build of the `vestal` product; see package.nix.
        vestal = pkgs.callPackage ./package.nix { commit = buildCommit; };

        default = vestal;
      });
    };
}
