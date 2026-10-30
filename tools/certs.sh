# signing certificates, picked by kind and team so the name on them isn't spelled out in the scripts.
# sourced by build.sh and release.sh
cert() { security find-identity -v -p codesigning | awk -v kind="\"$1: " -v team="($2)" 'index($0, kind) && index($0, team) { print $2; exit }'; }
dev_identity() { cert "Apple Development" 3VSFGRSSZD; }
release_identity() { cert "Developer ID Application" TMF25D4TR4; }
