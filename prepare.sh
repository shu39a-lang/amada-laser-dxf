set -euo pipefail
printf '%s  %s\n' c827b9b219ed793dd146f2297bfc006752c54bd5ac6810954af6d29c4204cefc SheetMaster_v2.zip | shasum -a 256 -c -
unzip -q SheetMaster_v2.zip -d build-input
cd build-input/SheetMaster
export SHEET_BUILD_NUMBER="${PROJECT_BUILD_NUMBER:-1}"
python3 - <<'PY'
import os, pathlib
p = pathlib.Path('project.yml')
s = p.read_text()
for old, new in [('PRODUCT_BUNDLE_IDENTIFIER: com.example.sheetmaster', 'PRODUCT_BUNDLE_IDENTIFIER: com.shu39a.amadaoffline'), ('CURRENT_PROJECT_VERSION: "1"', 'CURRENT_PROJECT_VERSION: "' + str(int(os.environ['SHEET_BUILD_NUMBER'])) + '"')]:
    assert s.count(old) == 1
    s = s.replace(old, new)
p.write_text(s)
PY
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
