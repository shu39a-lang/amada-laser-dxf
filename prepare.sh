set -euo pipefail
printf '%s  %s\n' 501b684be5158f695a82e0aa0a5f0afcb19a639ef4bda91901e297ccc7f49fe6 SheetMaster_v2.4.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.4.zip -d build-input
mv build-input/SheetMaster_v2.4 build-input/SheetMaster
