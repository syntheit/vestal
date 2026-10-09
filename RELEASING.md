# Releasing the macOS app

Needs the Developer ID certificate in the login keychain
(`security find-identity -v -p codesigning`) and a notarytool keychain profile
named `notarytool` (another name: set `VESTAL_NOTARY_PROFILE`). To create it once:

```sh
xcrun notarytool store-credentials notarytool --apple-id <apple id> --team-id 6NHZWHQX37
```

## Checklist

Version 0.5.0 is bumped, built, signed and packaged (`dist/Vestal-0.5.0.dmg`); steps 1 to 4 below are done for it. Notes for the section: `CHANGELOG.md`, `## [0.5.0]`.

1. Bump `BuildInfo.version` in `Sources/VestalCore/BuildInfo.swift` (the one source: the Nix build, the app's Info.plist and the script all read it), add a `CHANGELOG.md` entry, commit.
2. Check: `swift build -c release`, the Linux test run on harbor (`nix flake check`), `python3 nix/gen-docs.py` leaves no diff.
3. Build, sign, package: `scripts/release-macos.sh build && scripts/release-macos.sh sign && scripts/release-macos.sh dmg`. `ARCHS=arm64` builds Apple silicon only.
4. Merge the README branch (once): `git merge worktree-agent-a57db9593940948ae`.
5. Notarize and staple the DMG and app: `VESTAL_NOTARY_PROFILE=notarytool scripts/release-macos.sh notarize`. It stops with the exact `store-credentials` command when the profile is missing, and points at developer.apple.com/account when Apple answers 403 (an agreement to accept).
6. Regenerate the cask. Stapling changes the DMG, so the hash from before notarizing is stale; always run this after step 5 and never rebuild the DMG afterwards: `scripts/release-macos.sh cask`. Commit `packaging/homebrew/vestal.rb`.
7. Test the stapled DMG on a Mac that has never run it: open it, drag to Applications, start it, `spctl -a -t exec -vv /Applications/Vestal.app` says `accepted source=Notarized Developer ID`.
8. Tag and push:

   ```sh
   git tag v0.5.0
   git push origin main v0.5.0
   ```

9. Create the release, with the changelog section as notes:

   ```sh
   awk '/^## \[0.5.0\]/{f=1;next} /^## /{f=0} f' CHANGELOG.md > dist/notes.md
   gh release create v0.5.0 dist/Vestal-0.5.0.dmg \
     --repo syntheit/vestal --title "Vestal 0.5.0" --notes-file dist/notes.md
   ```

10. Create the tap (first time only), then publish the cask:

    ```sh
    gh repo create syntheit/homebrew-vestal --public --description "Homebrew tap for Vestal"
    git clone git@github.com:syntheit/homebrew-vestal.git ../homebrew-vestal
    mkdir -p ../homebrew-vestal/Casks
    cp packaging/homebrew/vestal.rb ../homebrew-vestal/Casks/vestal.rb
    cd ../homebrew-vestal && git add -A && git commit -m "vestal 0.5.0" && git push
    ```

    Later releases: the same `cp`, commit and push.

11. Check: `brew update && brew install --cask syntheit/vestal/vestal`.
12. Website (first time): add the DNS record `CNAME vestal -> syntheit.github.io` at the matv.io DNS host, then enable Pages with the custom domain and HTTPS (`site/README.md`, "Go live"):

    ```sh
    gh api -X POST repos/syntheit/vestal/pages -f build_type=workflow
    gh api -X PUT repos/syntheit/vestal/pages -f cname=vestal.matv.io
    ```

13. Deploy the site, after the release exists: `gh workflow run pages.yml --repo syntheit/vestal`.

## The website

Steps 12 and 13 above; details in `site/README.md`. The site is deployed by hand.

## Notes

- The release build uses the system toolchain, not Nix, so the binary links only `/usr/lib` and `/System/Library` (the script fails otherwise).
- Entitlements are in `packaging/macos/Entitlements.plist`: calendars and Apple Events only. The app is not sandboxed, so network access needs none.
- `vestal login-item` registers `Contents/Library/LaunchAgents/io.matv.vestal.plist` from `packaging/macos/`.
