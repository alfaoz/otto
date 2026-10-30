#!/bin/bash
# ships a version of otto:  ./release.sh <version> [notes file]
#   1. the version goes into core/Cargo.toml (the app and the CLI read it from there)
#   2. build.sh --release: Developer ID, hardened runtime, notarized and stapled
#   3. the DMG (tools/dmg.py on tools/dmg-background.swift's background): signed, notarized, stapled
#   4. the update feed: the DMG goes in with otto's EdDSA signature (the private key stays in this Mac's
#      keychain, account "otto"), then the whole feed is signed too, which the app requires
#   5. everything lands in site/: download/otto-<version>.dmg, download/otto.dmg (the latest), appcast.xml,
#      releases.json. site/deploy.sh puts it online.
# notes: one change per line, shown in the update window.
# needs, once: xcrun notarytool store-credentials otto-notary --apple-id <you> --team-id TMF25D4TR4
set -euo pipefail
cd "$(dirname "$0")"
. tools/certs.sh
version=${1:?usage: ./release.sh <version> [notes file]}
notes=${2:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "a version like 0.2.0, not $version"; exit 1; }
if grep -q "\"version\": \"$version\"" site/releases.json 2>/dev/null; then echo "$version is out already"; exit 1; fi
[ -z "$notes" ] || [ -f "$notes" ] || { echo "no notes file $notes"; exit 1; }
identity=$(release_identity)
[ -n "$identity" ] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
sparkle=mac/.build/artifacts/sparkle/Sparkle/bin
[ -x build/venv/bin/dmgbuild ] || { python3 -m venv build/venv && build/venv/bin/pip install -q dmgbuild; }

sed -i '' "s/^version = \".*\"/version = \"$version\"/" core/Cargo.toml
./build.sh --release
[ -x "$sparkle/sign_update" ] || { echo "Sparkle's tools are missing: (cd mac && swift package resolve)"; exit 1; }

mkdir -p build/dmg site/download
dmg=site/download/otto-$version.dmg
swift tools/dmg-background.swift build/dmg "$version"
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff >/dev/null
rm -f "$dmg"
build/venv/bin/dmgbuild -s tools/dmg.py -D app=build/Otto.app -D background=build/dmg/background.tiff otto "$dmg" 2>&1 | grep -v deprecated || true
# the app as users drag it out has to pass the strictest check, not just Gatekeeper's
mnt=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1
strict=true
codesign --verify --deep --strict "$mnt/Otto.app" || strict=false
hdiutil detach "$mnt" -quiet
$strict || { echo "the app in the DMG fails a strict signature check"; exit 1; }
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile otto-notary --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"

signature=$("$sparkle/sign_update" --account otto -p "$dmg")
python3 tools/appcast.py site "$version" "$(stat -f%z "$dmg")" "$signature" "$notes"
"$sparkle/sign_update" --account otto site/appcast.xml
"$sparkle/sign_update" --account otto --verify site/appcast.xml
ln -sf "otto-$version.dmg" site/download/otto.dmg
sed -i '' "s|<span class=\"version\">[^<]*</span>|<span class=\"version\">$version</span>|g" site/index.html
echo "otto $version: $dmg, feed signed. next: site/deploy.sh"
