set -euo pipefail
printf '%s  %s\n' 05103086c34efad3a1f11b4b6223c951d35a996868592d37f8cbf498db18bc00 SheetMaster_v2.5.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.5.zip -d build-input
mv build-input/SheetMaster_v2.5 build-input/SheetMaster
