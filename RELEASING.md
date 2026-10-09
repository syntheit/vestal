# Releasing the macOS app

Needs the Developer ID certificate in the login keychain
(`security find-identity -v -p codesigning`) and a notarytool keychain profile
named `notarytool` (another name: set `VESTAL_NOTARY_PROFILE`). To create it once:

```sh
xcrun notarytool store-credentials notarytool --apple-id <apple id> --team-id 6NHZWHQX37
```

## Checklist

1. Bump `BuildInfo.version` in `Sources/VestalCore/BuildInfo.swift` (the one source: the Nix build, the app's Info.plist and the script all read it). Commit it.
2. Check: `swift build -c release`, the Linux test run on harbor (`nix flake check`), `python3 nix/gen-docs.py` leaves no diff.
3. Tag locally: `git tag v<version>` (push it in step 6).
4. Build everything: `scripts/release-macos.sh all`. Or step by step: `build`, `sign`, `dmg`, `notarize`, `cask`. `dist/Vestal-<version>.dmg` is the result. `notarize` stops with the exact `store-credentials` command when the profile is missing, and points at developer.apple.com/account when Apple answers 403 (an agreement to accept). `ARCHS=arm64` builds Apple silicon only.
5. Test the stapled DMG on a Mac that has never run it: open it, drag to Applications, start it, `spctl -a -t exec -vv /Applications/Vestal.app` says `accepted source=Notarized Developer ID`.
6. Publish (these are the commands, run them by hand):

   ```sh
   git push origin main v<version>
   gh release create v<version> dist/Vestal-<version>.dmg \
     --repo syntheit/vestal --title "Vestal <version>" --notes "<notes>"
   ```

7. Update the cask. `scripts/release-macos.sh cask` already wrote `version` and the DMG's `sha256` (after stapling, which changes the file) into `packaging/homebrew/vestal.rb`; do not rebuild the DMG afterwards or the hash is stale. Copy it into the tap and push:

   ```sh
   cp packaging/homebrew/vestal.rb ../homebrew-vestal/Casks/vestal.rb
   cd ../homebrew-vestal && git add -A && git commit -m "vestal <version>" && git push
   ```

8. Check: `brew update && brew install --cask syntheit/vestal/vestal`.

## Notes

- The release build uses the system toolchain, not Nix, so the binary links only `/usr/lib` and `/System/Library` (the script fails otherwise).
- Entitlements are in `packaging/macos/Entitlements.plist`: calendars and Apple Events only. The app is not sandboxed, so network access needs none.
- `vestal login-item` registers `Contents/Library/LaunchAgents/io.matv.vestal.plist` from `packaging/macos/`.
