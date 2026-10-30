#!/bin/bash
# builds Otto.app: the Swift app plus the Rust `otto` binary (service, CLI, MCP server,
# browser helper). signs with a stable identity so the keychain item and the Accessibility /
# Screen Recording grants survive rebuilds, then installs to ~/Applications.
#   ./build.sh            build + install (quits a running otto first)
#   ./build.sh --open     build + install + launch
#   ./build.sh --no-install
#   ./build.sh --release   build/Otto.app signed with the Developer ID, notarized and stapled, with the update feed
#                          (not installed; release.sh makes the DMG). once: xcrun notarytool store-credentials
#                          otto-notary --apple-id <you> --team-id TMF25D4TR4 --password <app-specific password>
#                          the release build is signed by another identity than the dev one, so on a Mac that ran
#                          a dev build, macOS asks once for the keychain item and for Accessibility again.
# the version is core/Cargo.toml's, for the app and the CLI alike.
set -euo pipefail
cd "$(dirname "$0")"
. tools/certs.sh
identity=$(dev_identity)
release=false
if [ "${1:-}" = "--release" ]; then
  release=true
  identity=$(release_identity)
  xcrun notarytool history --keychain-profile otto-notary >/dev/null 2>&1 || {
    echo "no notarytool profile \"otto-notary\" yet: xcrun notarytool store-credentials otto-notary --apple-id <you> --team-id TMF25D4TR4"; exit 1; }
fi
[ -n "$identity" ] || { echo "no signing certificate for this build in the keychain"; exit 1; }
version=$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)
(cd core && cargo build --release)
(cd mac && swift build -c release)
app=build/Otto.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/extension" "$app/Contents/Frameworks"
cp mac/.build/release/OttoApp "$app/Contents/MacOS/OttoApp"
cp core/target/release/otto "$app/Contents/MacOS/otto"
cp mac/Info.plist "$app/Contents/"
plist() { /usr/libexec/PlistBuddy -c "$1" "$app/Contents/Info.plist"; }
plist "Set :CFBundleShortVersionString $version"
plist "Set :CFBundleVersion $version"
# updates: only release builds have a feed (a dev build never replaces itself). the feed and each download
# must carry otto's EdDSA signature (SUPublicEDKey in Info.plist), checked before anything is unpacked
if $release; then
  plist "Add :SUFeedURL string https://otto.alfaoz.dev/appcast.xml"
  plist "Add :SURequireSignedFeed bool true"
  plist "Add :SUVerifyUpdateBeforeExtraction bool true"
  plist "Add :SUEnableAutomaticChecks bool true"
fi
# Sparkle, without its XPC services: those are for sandboxed apps, and otto isn't one
ditto mac/.build/release/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
cp mac/Resources/AppIcon.icns "$app/Contents/Resources/"
# card brands' logos (vector)
cp -R mac/Resources/brands mac/Resources/agents "$app/Contents/Resources/"
plist "Add :CFBundleIconFile string AppIcon"
# accent color (a warm graphite, so system controls match otto instead of blue)
xcrun actool mac/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor --output-partial-info-plist build/assets.plist >/dev/null
plist "Add :NSAccentColorName string AccentColor"
cp -R extension/manifest.json extension/background.js extension/offscreen.html extension/offscreen.js extension/popup.html extension/popup.js extension/popup.css extension/icons "$app/Contents/Resources/extension/"
# notarization wants a secure timestamp; dev builds are signed as they always were
stamp=()
$release && stamp=(--timestamp)
# inside out: Sparkle's helpers, Sparkle, the CLI, then the app
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for part in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
  codesign --force --options runtime ${stamp[@]+"${stamp[@]}"} --sign "$identity" "$part"
done
codesign --force --options runtime ${stamp[@]+"${stamp[@]}"} --identifier dev.alfaoz.otto.cli --sign "$identity" "$app/Contents/MacOS/otto"
codesign --force --options runtime ${stamp[@]+"${stamp[@]}"} --entitlements mac/otto.entitlements --sign "$identity" "$app"
if $release; then
  ditto -c -k --keepParent "$app" build/Otto-notarize.zip
  xcrun notarytool submit build/Otto-notarize.zip --keychain-profile otto-notary --wait
  xcrun stapler staple "$app"
  rm build/Otto-notarize.zip
  spctl --assess --type execute -v "$app"
  echo "notarized: $app ($version)"
  exit 0
fi
[ "${1:-}" = "--no-install" ] && exit 0
if pgrep -x OttoApp >/dev/null; then
  pkill -TERM -x OttoApp || true
  for _ in $(seq 20); do pgrep -x OttoApp >/dev/null || break; sleep 0.25; done
fi
rm -rf ~/Applications/Otto.app
cp -R "$app" ~/Applications/
echo "installed ~/Applications/Otto.app"
if [ "${1:-}" = "--open" ]; then open ~/Applications/Otto.app; fi
