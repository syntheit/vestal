#!/usr/bin/env bash
# Build, sign, package and notarize Vestal.app for a public macOS release.
#
#   scripts/release-macos.sh build|sign|dmg|notarize|cask|all
#
# Each step can run alone and reads what the one before left in dist/:
#   build     swift build -c release (universal if possible), dist/Vestal.app
#   sign      hardened-runtime Developer ID signature, inside out, verified
#   dmg       dist/Vestal-<version>.dmg with an /Applications link, signed
#   notarize  notarytool submit --wait, staple the DMG and the app, spctl
#   cask      write the version and the DMG's sha256 into the Homebrew cask
#   all       build sign dmg notarize cask
#
# Environment:
#   SIGN_IDENTITY  default "Developer ID Application: Daniel Miller (6NHZWHQX37)"
#   VESTAL_NOTARY_PROFILE default "notarytool" (a notarytool keychain profile)
#   ARCHS          default "arm64 x86_64"; "arm64" for an Apple-silicon-only build
#
# Nothing here publishes: no git push, no tags, no GitHub release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Daniel Miller (6NHZWHQX37)}"
NOTARY_PROFILE="${VESTAL_NOTARY_PROFILE:-notarytool}"
ARCHS="${ARCHS:-arm64 x86_64}"
DIST="$ROOT/dist"
APP="$DIST/Vestal.app"
ENTITLEMENTS="$ROOT/packaging/macos/Entitlements.plist"
AGENT_PLIST="$ROOT/packaging/macos/io.matv.vestal.plist"
CASK="$ROOT/packaging/homebrew/vestal.rb"

# The version has one source: BuildInfo.version.
VERSION="$(sed -n 's/.*static let version[^"]*"\([^"]*\)".*/\1/p' Sources/VestalCore/BuildInfo.swift)"
[[ -n "$VERSION" ]] || { echo "release: no BuildInfo.version found" >&2; exit 1; }
DMG="$DIST/Vestal-$VERSION.dmg"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "release: $*" >&2; exit 1; }

need_app() { [[ -d "$APP" ]] || die "$APP is missing; run: scripts/release-macos.sh build"; }
need_dmg() { [[ -f "$DMG" ]] || die "$DMG is missing; run: scripts/release-macos.sh dmg"; }

# Fail unless the binary links only the OS: /usr/lib, /System/Library and
# @rpath (the Swift runtime, which macOS 14+ ships in /usr/lib/swift).
check_links() {
    local bin="$1" bad
    say "otool -L $bin"
    otool -L "$bin"
    # Dependency lines start with a tab; a universal binary also prints a
    # "<path> (architecture x):" header per slice.
    bad="$(otool -L "$bin" | awk '/^\t/{print $1}' \
        | grep -Ev '^(/usr/lib/|/System/Library/|@rpath/)' || true)"
    [[ -z "$bad" ]] || die "links outside the OS:
$bad"
    # Every @rpath library must be found in an rpath that points at the OS.
    otool -l "$bin" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | sort -u | sed 's/^/rpath: /'
}

# MARK: build

write_info_plist() {
    # The same values as package.nix's infoPlist (nix/check-info-plist.py checks them).
    cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ATSApplicationFontsPath</key>
	<string>Fonts</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Vestal</string>
	<key>CFBundleExecutable</key>
	<string>vestal</string>
	<key>CFBundleIdentifier</key>
	<string>io.matv.vestal</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Vestal</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Vestal shows what your media player is playing and can pause it.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Vestal shows your upcoming events on the dashboard.</string>
	<key>NSCalendarsUsageDescription</key>
	<string>Vestal shows your upcoming events on the dashboard.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF
}

step_build() {
    say "build: Vestal $VERSION, archs: $ARCHS (system toolchain, not Nix)"
    local commit info backup arch_flags=()
    for a in $ARCHS; do arch_flags+=(--arch "$a"); done
    commit="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
    info="Sources/VestalCore/BuildInfo.swift"
    backup="$(mktemp)"
    cp "$info" "$backup"
    # Stamp the commit as the Nix build does; restored on exit.
    trap 'cp "'"$backup"'" "'"$ROOT/$info"'"; rm -f "'"$backup"'"' EXIT
    /usr/bin/sed -i '' "s/let commit  = \"dev\"/let commit  = \"$commit\"/" "$info"

    swift build -c release --product vestal "${arch_flags[@]}"
    local bin
    bin="$(swift build -c release --product vestal "${arch_flags[@]}" --show-bin-path)/vestal"
    [[ -x "$bin" ]] || die "no binary at $bin"
    cp "$backup" "$info"

    say "assemble $APP"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Library/LaunchAgents"
    install -m755 "$bin" "$APP/Contents/MacOS/vestal"
    write_info_plist
    printf 'APPL????' > "$APP/Contents/PkgInfo"
    install -m644 Resources/icons/Phosphor.ttf "$APP/Contents/Resources/Fonts/Phosphor.ttf"
    install -m644 Resources/icons/Phosphor-Fill.ttf "$APP/Contents/Resources/Fonts/Phosphor-Fill.ttf"
    install -m644 Resources/icons/LICENSE "$APP/Contents/Resources/Fonts/LICENSE-Phosphor"
    cp -R Resources/samples "$APP/Contents/Resources/samples"
    cp -R Resources/starters "$APP/Contents/Resources/starters"
    [[ -d Resources/shaders ]] && cp -R Resources/shaders "$APP/Contents/Resources/shaders"
    # `vestal login-item on` registers this agent (SMAppService).
    install -m644 "$AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/io.matv.vestal.plist"

    # SwiftPM leaves the build machine's toolchain directory as an rpath; the
    # OS's Swift runtime (/usr/lib/swift) is the one that is used.
    local rp
    while IFS= read -r rp; do
        install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/vestal"
    done < <(otool -l "$APP/Contents/MacOS/vestal" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | sort -u | grep '^/Library/Developer\|^/Applications/Xcode' || true)

    plutil -lint "$APP/Contents/Info.plist"
    python3 nix/check-info-plist.py "$APP/Contents/Info.plist" "$VERSION"
    say "architectures"
    lipo -archs "$APP/Contents/MacOS/vestal"
    check_links "$APP/Contents/MacOS/vestal"
    say "built $APP ($(du -sh "$APP" | awk '{print $1}'))"
}

# MARK: sign

step_sign() {
    need_app
    say "sign: $SIGN_IDENTITY (hardened runtime, timestamp), inside out"
    security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
        || die "signing identity not in the keychain: $SIGN_IDENTITY (security find-identity -v -p codesigning)"
    # Nested code first (none today: one executable, fonts and plists are
    # resources), then the main executable, then the bundle. No --deep.
    local f main="$APP/Contents/MacOS/vestal"
    while IFS= read -r f; do
        [[ "$f" == "$main" ]] && continue
        if file -b "$f" | grep -q 'Mach-O'; then
            echo "sign nested: ${f#"$APP/"}"
            codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
        fi
    done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name '*.dylib' \))
    echo "sign main executable"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --identifier io.matv.vestal --sign "$SIGN_IDENTITY" "$main"
    echo "sign bundle"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"

    say "codesign --verify --strict --verbose=2"
    codesign --verify --strict --verbose=2 "$APP"
    codesign -dvv --entitlements - "$APP" 2>&1 | grep -E 'Identifier|Authority|Timestamp|flags|TeamIdentifier|com.apple' || true
    say "spctl -a -t exec -vv (rejected as unnotarized until the notarize step)"
    spctl -a -t exec -vv "$APP" || true
}

# MARK: dmg

step_dmg() {
    need_app
    say "dmg: $DMG"
    local stage="$DIST/dmg-stage"
    rm -rf "$stage" "$DMG"
    mkdir -p "$stage"
    # ditto keeps the signature, xattrs and symlinks intact.
    ditto "$APP" "$stage/Vestal.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "Vestal $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$stage"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
    hdiutil verify "$DMG" | tail -1
    say "size: $(du -h "$DMG" | awk '{print $1}')  sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
}

# MARK: notarize

# Explain a failed notarytool call: an expired agreement (HTTP 403) or a
# missing keychain profile.
notary_fail() {
    echo "$1" >&2
    if echo "$1" | grep -qE '403|agreement'; then
        cat >&2 <<EOF

release: Apple answered 403, "A required agreement is missing or has expired".
Accept the updated agreement at https://developer.apple.com/account (sign in as the
account holder and accept the banner), wait a few minutes, then run again:
  scripts/release-macos.sh notarize
EOF
    else
        cat >&2 <<EOF

release: notarytool failed with keychain profile '$NOTARY_PROFILE'. If the profile does not
exist, store it (once) with:

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your apple id> --team-id 6NHZWHQX37

It asks for an app-specific password (appleid.apple.com > Sign-In and Security).
Another profile name: VESTAL_NOTARY_PROFILE=<name> scripts/release-macos.sh notarize
EOF
    fi
    exit 1
}

step_notarize() {
    need_app
    need_dmg
    say "notarize: profile '$NOTARY_PROFILE'"
    local out
    if ! out="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
        notary_fail "$out"
    fi
    local cmd=(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait)
    echo "+ ${cmd[*]}"
    if ! out="$("${cmd[@]}" 2>&1)"; then
        notary_fail "$out"
    fi
    echo "$out" | tee "$DIST/notarize.log"
    grep -q 'status: Accepted' "$DIST/notarize.log" \
        || die "notarization was not accepted; see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    echo "+ xcrun stapler staple $DMG"
    xcrun stapler staple "$DMG"
    echo "+ xcrun stapler staple $APP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$DMG"
    say "spctl"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
    spctl -a -t exec -vv "$APP"
}

# MARK: cask

step_cask() {
    need_dmg
    local sha
    sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    say "cask: version $VERSION sha256 $sha"
    /usr/bin/sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 .*/  sha256 \"$sha\"/" "$CASK"
    grep -nE '^  (version|sha256)' "$CASK"
    echo "Upload $DMG to the v$VERSION release, then copy $CASK into the tap (see RELEASING.md)."
}

case "${1:-}" in
    build) step_build ;;
    sign) step_sign ;;
    dmg) step_dmg ;;
    notarize) step_notarize ;;
    cask) step_cask ;;
    all) step_build; step_sign; step_dmg; step_notarize; step_cask ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
