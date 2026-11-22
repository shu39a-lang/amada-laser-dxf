#!/usr/bin/env bash
set -euo pipefail

project=sheet-master-e2aa0
region=asia-northeast1
service=sheet-master-ocr
source_dir=$(cd "$(dirname "$0")" && pwd)
gcp() { gcloud "$@" --project="$project"; }

billing=$(gcp billing projects describe "$project" --format='value(billingEnabled)')
if [[ "${billing,,}" != true ]]; then
    echo "このプロジェクトには請求先が設定されていません。ここで終了します。"
    exit 1
fi
app_id=$(python3 - "$source_dir/../AMADAOffline/GoogleService-Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    config = plistlib.load(f)
if (config["PROJECT_ID"], config["BUNDLE_ID"]) != ("sheet-master-e2aa0", "com.shu39a.amadaoffline"):
    sys.exit("Firebase設定がSHEET MASTERと一致しません")
print(config["GOOGLE_APP_ID"])
PY
)

echo "東京に図面読み取りサービスを配置します。無料枠を超えた利用や、ビルド・イメージ保存に料金が発生する場合があります。"
read -r -p "このプロジェクトで配置を実行しますか？ [y/N] " answer
[[ "$answer" == [yY] ]] || exit 0

gcp services enable vision.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com iam.googleapis.com firebaseappcheck.googleapis.com
runtime_id=sheet-ocr-runtime
builder_id=sheet-ocr-builder
for id in "$runtime_id" "$builder_id"; do
    email="$id@$project.iam.gserviceaccount.com"
    if ! gcp iam service-accounts describe "$email" >/dev/null 2>&1; then
        gcp iam service-accounts create "$id" --display-name="$id"
    fi
done
runtime="$runtime_id@$project.iam.gserviceaccount.com"
builder="$builder_id@$project.iam.gserviceaccount.com"
gcp projects add-iam-policy-binding "$project" --member="serviceAccount:$builder" \
    --role=roles/run.builder --condition=None --format=none
gcp projects add-iam-policy-binding "$project" --member="serviceAccount:$runtime" \
    --role=roles/serviceusage.serviceUsageConsumer --condition=None --format=none
gcp run deploy "$service" --region="$region" --source="$source_dir" \
    --service-account="$runtime" --build-service-account="projects/$project/serviceAccounts/$builder" \
    --set-env-vars="FIREBASE_IOS_APP_ID=$app_id,GOOGLE_CLOUD_PROJECT=$project" \
    --min-instances=0 --max-instances=1 --allow-unauthenticated --quiet
url=$(gcp run services describe "$service" --region="$region" --format='value(status.url)')
response=$(mktemp)
trap 'rm -f "$response"' EXIT
status=$(curl -sS --max-time 60 -o "$response" -w '%{http_code}' -X POST "$url/v1/ocr")
if [[ "$status" != 401 ]] || ! python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("error") != "App Check token required")' "$response"; then
    echo "App Checkの未認証リクエスト拒否を確認できませんでした (HTTP $status)。"
    exit 1
fi
echo "App Check未認証の拒否を確認しました。接続先: $url/v1/ocr"
