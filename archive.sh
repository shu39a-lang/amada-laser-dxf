set -euo pipefail
bundle_id=com.shu39a.amadaoffline
build_root="$PWD/build"
mkdir -p "$build_root/ios/ipa"
# Read the matching profile installed by Codemagic's ios_signing step.
python3 - "$bundle_id" "$build_root" <<'PY'
import pathlib, plistlib, subprocess, sys
bundle_id, output = sys.argv[1:]
library = pathlib.Path.home() / "Library"
profiles = []
for directory in ("MobileDevice/Provisioning Profiles", "Developer/Xcode/UserData/Provisioning Profiles"):
    for path in (library / directory).glob("*.mobileprovision"):
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)]))
        entitlements = profile["Entitlements"]
        prefix = profile["ApplicationIdentifierPrefix"][0]
        if entitlements["application-identifier"] == prefix + "." + bundle_id and not entitlements.get("get-task-allow") and not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"):
            profiles.append(profile)
if not profiles:
    sys.exit("No matching App Store distribution profile installed")
profile = max(profiles, key=lambda p: p["ExpirationDate"])
team, uuid = profile["TeamIdentifier"][0], profile["UUID"]
options = dict(method="app-store-connect", signingStyle="manual", teamID=team, provisioningProfiles={bundle_id: uuid}, manageAppVersionAndBuildNumber=False)
root = pathlib.Path(output)
(root / "ExportOptions.plist").write_bytes(plistlib.dumps(options))
(root / "team").write_text(team)
(root / "profile").write_text(uuid)
PY
xcodebuild -project build-input/SheetMaster/SheetMaster.xcodeproj -scheme SheetMaster -configuration Release -destination 'generic/platform=iOS' -archivePath "$build_root/SheetMaster.xcarchive" SM_BUNDLE_ID="$bundle_id" SM_BUILD_NUMBER="${PROJECT_BUILD_NUMBER:?}" SM_TEAM_ID="$(cat "$build_root/team")" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" PROVISIONING_PROFILE_SPECIFIER="$(cat "$build_root/profile")" archive
archived_app="$build_root/SheetMaster.xcarchive/Products/Applications/SheetMaster.app/Info.plist"
test "$(plutil -extract CFBundleShortVersionString raw "$archived_app")" = "2.4.1"
test "$(plutil -extract CFBundleIdentifier raw "$archived_app")" = "$bundle_id"
xcodebuild -exportArchive -archivePath "$build_root/SheetMaster.xcarchive" -exportOptionsPlist "$build_root/ExportOptions.plist" -exportPath "$build_root/ios/ipa"
