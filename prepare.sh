set -euo pipefail
printf '%s  %s\n' 3561a598d0af5c4ce4ed19e9eb105661c5f30839c7985738c3e73e68441a55e1 SheetMaster_v2.4.1.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.4.1.zip -d build-input
mv build-input/SheetMaster_v2.4.1 build-input/SheetMaster
