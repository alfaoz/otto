#!/bin/bash
# puts the website, the downloads and the update feed online: site/deploy.sh
# justtype-vps (an ssh alias) serves them from /var/www/otto.alfaoz.dev with nginx (site/nginx.conf).
# nothing is deleted there, so older versions stay downloadable.
set -euo pipefail
cd "$(dirname "$0")"
[ -e download/otto.dmg ] && [ -f appcast.xml ] || { echo "no release in site/ yet: ./release.sh <version> first"; exit 1; }
# no -p: files get the server's default modes (the rsync macOS ships has no --chmod)
rsync -rlt --itemize-changes \
  --exclude deploy.sh --exclude nginx.conf --exclude releases.json --exclude '.*' \
  ./ justtype-vps:/var/www/otto.alfaoz.dev/
echo "online: https://otto.alfaoz.dev"
