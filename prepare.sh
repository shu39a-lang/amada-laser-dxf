set -euo pipefail
printf '%s  %s\n' 4914ae170b9291cb8e9dce591035c7faaa7669d920b45357f1c1a0e5032d6754 SheetMaster_v2.2.zip | shasum -a 256 -c -
printf '%s  %s\n' e917cc1bf8c813414ee022dcf135bcb65b858310b8c1b608abc485100745f4d1 SheetMaster_v2.3.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.2.zip 'SheetMaster/project.yml' 'SheetMaster/SheetMaster/Assets.xcassets/*' -d build-input
unzip -q SheetMaster_v2.3.zip -d build-input
cp -R build-input/SheetMaster_v2.3/SheetMaster/. build-input/SheetMaster/SheetMaster/
cd build-input/SheetMaster
export SHEET_BUILD_NUMBER="${PROJECT_BUILD_NUMBER:-1}"
python3 - <<'PY'
import os, pathlib
p = pathlib.Path('project.yml')
s = p.read_text()
for old, new in [('MARKETING_VERSION: "2.2.0"', 'MARKETING_VERSION: "2.3"'), ('PRODUCT_BUNDLE_IDENTIFIER: com.example.sheetmaster', 'PRODUCT_BUNDLE_IDENTIFIER: com.shu39a.amadaoffline'), ('CURRENT_PROJECT_VERSION: "1"', 'CURRENT_PROJECT_VERSION: "' + str(int(os.environ['SHEET_BUILD_NUMBER'])) + '"')]:
    assert s.count(old) == 1
    s = s.replace(old, new)
p.write_text(s)
PY
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
