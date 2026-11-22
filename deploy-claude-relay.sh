#!/usr/bin/env bash
set -euo pipefail

PROJECT="sheet-master-e2aa0"
REGION="asia-northeast1"
SERVICE="sheet-master-claude"
ACCOUNT="sheet-master-claude-relay"
SECRET="sheet-master-anthropic-key"
APP_ID="1:195319181441:ios:9bf5ca1c72cd9839429d80"

echo "Project: $PROJECT (Claude server only; original SHEET MASTER HTML unchanged)"
gcloud config set project "$PROJECT" >/dev/null
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com firebaseappcheck.googleapis.com

if ! gcloud iam service-accounts describe "$ACCOUNT@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$ACCOUNT" --project "$PROJECT" --display-name "SHEET MASTER Claude relay"
fi
SERVICE_EMAIL="$ACCOUNT@$PROJECT.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SERVICE_EMAIL" --role roles/firebaseappcheck.tokenVerifier --quiet >/dev/null

if ! gcloud secrets describe "$SECRET" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET" --project "$PROJECT" --replication-policy automatic
fi
gcloud secrets add-iam-policy-binding "$SECRET" --project "$PROJECT" --member "serviceAccount:$SERVICE_EMAIL" --role roles/secretmanager.secretAccessor --quiet >/dev/null

if ! gcloud secrets versions list "$SECRET" --project "$PROJECT" --filter 'state=ENABLED' --format 'value(name)' | grep -q .; then
  echo
  echo "Enter the Claude API key when requested. It stays off the screen and out of GitHub."
  read -r -s -p "Claude API key: " API_KEY
  echo
  if [[ ! "$API_KEY" == sk-ant-* ]]; then
    unset API_KEY
    echo "Input does not look like an Anthropic API key. Nothing deployed." >&2
    exit 1
  fi
  printf '%s' "$API_KEY" | gcloud secrets versions add "$SECRET" --project "$PROJECT" --data-file=-
  unset API_KEY
else
  echo "Existing secret version will be reused. No API key entry needed."
fi

gcloud run deploy "$SERVICE" \
  --project "$PROJECT" --region "$REGION" \
  --source "claude-relay" --allow-unauthenticated \
  --service-account "$SERVICE_EMAIL" \
  --set-secrets "ANTHROPIC_API_KEY=$SECRET:latest" \
  --set-env-vars "CLAUDE_MODEL=claude-sonnet-5-5,FIREBASE_APP_ID=$APP_ID" \
  --max-instances 1 --memory 512Mi --timeout 120 --quiet

URL=$(gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format 'value(status.url)')
echo
echo "SERVICE_URL=$URL"
echo "DRAWING_ANALYSIS_ENDPOINT=$URL/v1/analyze"
echo "Health check (not proof of Anthropic access):"
curl -fsS "$URL/health"
echo
echo "Do not share the API key. Share only DRAWING_ANALYSIS_ENDPOINT for next-step iOS configuration."
