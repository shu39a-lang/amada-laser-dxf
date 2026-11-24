set -euo pipefail
printf '%s  %s\n' bcb98f2f84187fc1081abedec4d1556f6853c6c1f7ff6fa5a5fa395bcb13b098 SheetMaster_v2.4.2.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.4.2.zip -d build-input
mv build-input/SheetMaster_v2.4.2 build-input/SheetMaster
