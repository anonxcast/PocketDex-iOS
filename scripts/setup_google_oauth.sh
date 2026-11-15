#!/usr/bin/env bash
# One-time developer setup: create an iOS OAuth client for PocketDex and bake it in.
# End users never see a Client ID — it ships in Info.plist like Delta.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="$ROOT/ios/Secrets/GoogleOAuthClientID"
BUNDLE_ID="com.anonxcast.pocketdex"
PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-pocketdex-ios}"

export PATH="/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/share/google-cloud-sdk/bin:$PATH"
if ! command -v gcloud >/dev/null; then
  echo "Install Google Cloud SDK first (brew install --cask google-cloud-sdk)" >&2
  exit 1
fi

if [[ ! -f "$SECRET" ]] || [[ -z "$(tr -d '[:space:]' < "$SECRET" || true)" ]]; then
  echo "==> Signing into Google Cloud (browser)…"
  gcloud auth login --brief
  gcloud auth application-default login --quiet || true

  echo "==> Ensuring project $PROJECT_ID…"
  if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud projects create "$PROJECT_ID" --name="PocketDex iOS" || true
  fi
  gcloud config set project "$PROJECT_ID"
  gcloud services enable drive.googleapis.com --project="$PROJECT_ID"

  echo "==> Creating iOS OAuth client for $BUNDLE_ID…"
  # Requires OAuth consent screen configured once in Console if brand-new project.
  DISPLAY_NAME="PocketDex iOS"
  # Prefer gcloud alpha/beta if available; fall back to printing Console steps.
  if gcloud alpha iap oauth-clients list --help >/dev/null 2>&1; then
    :
  fi

  mkdir -p "$(dirname "$SECRET")"
  if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]]; then
    printf '%s\n' "$GOOGLE_OAUTH_CLIENT_ID" > "$SECRET"
  else
    cat <<EOF
Open:
  https://console.cloud.google.com/apis/credentials?project=$PROJECT_ID

1) Configure OAuth consent screen (External, your email) if prompted
2) Create Credentials → OAuth client ID → Application type: iOS
3) Bundle ID: $BUNDLE_ID
4) Paste the Client ID below (….apps.googleusercontent.com)
EOF
    read -r -p "Client ID: " CID
    printf '%s\n' "$CID" > "$SECRET"
  fi
fi

CID="$(tr -d '[:space:]' < "$SECRET")"
if [[ ! "$CID" == *.apps.googleusercontent.com ]]; then
  echo "Invalid client id in $SECRET" >&2
  exit 1
fi
PREFIX="${CID%.apps.googleusercontent.com}"
SCHEME="com.googleusercontent.apps.$PREFIX"
echo "Baked client: $CID"
echo "URL scheme:  $SCHEME"
echo "Write these into ios/project.yml GOOGLE_OAUTH_CLIENT_ID + CFBundleURLSchemes, then rebuild."
