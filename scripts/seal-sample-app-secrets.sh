#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT="${CERT:-${ROOT_DIR}/ansible/sealed-secrets.pem}"
OUTPUT="${OUTPUT:-${ROOT_DIR}/charts/sample-app/values.sealed.yaml}"

RELEASE_NAME="${RELEASE_NAME:-app}"
NAMESPACE="${NAMESPACE:-sample-app}"
CHART_NAME="sample-app"

if [[ "$RELEASE_NAME" == *"$CHART_NAME"* ]]; then
  SECRET_NAME="${RELEASE_NAME}-app-secrets"
else
  SECRET_NAME="${RELEASE_NAME}-${CHART_NAME}-app-secrets"
fi

: "${APP_KEY:?APP_KEY is required (ex. base64:...)}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"

if [[ ! -f "$CERT" ]]; then
  echo "Certificat introuvable : $CERT" >&2
  exit 1
fi

APP_KEY_ENC=$(printf '%s' "$APP_KEY" | kubeseal \
  --raw \
  --cert="$CERT" \
  --scope=strict \
  --namespace="$NAMESPACE" \
  --name="$SECRET_NAME")

DB_PASS_ENC=$(printf '%s' "$DB_PASSWORD" | kubeseal \
  --raw \
  --cert="$CERT" \
  --scope=strict \
  --namespace="$NAMESPACE" \
  --name="$SECRET_NAME")

cat > "$OUTPUT" <<EOF
secrets:
  useSealedSecrets: true
  scope: strict
  encryptedData:
    appKey: ${APP_KEY_ENC}
    dbPassword: ${DB_PASS_ENC}
EOF

echo "OK → $OUTPUT (secret: $SECRET_NAME, namespace: $NAMESPACE)"
