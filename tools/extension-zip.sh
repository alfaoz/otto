#!/bin/bash
# the extension as the Chrome Web Store takes it: build/otto-extension.zip
# the store gives the item its own id, so the manifest's `key` (it pins the id of the unpacked copy) stays out.
# that id then goes into EXTENSION_IDS in core/src/cli.rs and into /extension in site/nginx.conf.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/store-extension
rm -rf "$out" build/otto-extension.zip
mkdir -p "$out"
cp -R extension/. "$out/"
find "$out" -name .DS_Store -delete
python3 - "$out/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
del manifest['key']
json.dump(manifest, open(path, 'w'), indent=2, ensure_ascii=False)
PY
(cd "$out" && zip -q -r -X ../otto-extension.zip .)
echo "build/otto-extension.zip"
