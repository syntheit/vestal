# The website (site/), built offline with the vestal CLI from this flake:
# `node site/build.mjs` renders every sample and dashboard through
# `vestal render --json`, so nothing is fetched. The macOS-only screenshot
# checks in the build are optional and are skipped on Linux; the social card
# (og.png) is the committed site/src/og.png. $out is the contents of site/dist.
{
  lib,
  stdenvNoCC,
  nodejs,
  vestal,
}:

stdenvNoCC.mkDerivation {
  pname = "vestal-site";
  inherit (vestal) version;

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ../site
      ../AGENTS.md
      ../web
      ../docs
      ../examples
      ../Resources
      ../Tests/VestalCoreTests/Fixtures
    ];
  };

  nativeBuildInputs = [
    nodejs
    vestal
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    node site/build.mjs --vestal ${lib.getExe vestal} --no-preview
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r site/dist "$out"
    runHook postInstall
  '';

  meta = {
    description = "The vestal website, as static files";
    platforms = lib.platforms.unix;
  };
}
