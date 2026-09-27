# Phosphor Icons' regular and fill fonts (MIT), for the Linux UI's icon
# glyphs (EXTENSIBILITY.md §8.6). nixpkgs has no Phosphor package, so they
# come from the icon set's npm release, which ships the TTFs.
{
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "phosphor-icons-fonts";
  version = "2.1.2";

  src = fetchurl {
    url = "https://registry.npmjs.org/@phosphor-icons/web/-/web-${finalAttrs.version}.tgz";
    hash = "sha256-QOMJYJnKgYwEeXnOzmo3ZJRNUgDGe2QJL3vNi80dKwg=";
  };

  # The tarball unpacks to package/.
  sourceRoot = "package";

  installPhase = ''
    runHook preInstall
    install -Dm644 src/regular/Phosphor.ttf $out/share/fonts/truetype/Phosphor.ttf
    install -Dm644 src/fill/Phosphor-Fill.ttf $out/share/fonts/truetype/Phosphor-Fill.ttf
    install -Dm644 LICENSE $out/share/licenses/phosphor-icons/LICENSE
    runHook postInstall
  '';
})
