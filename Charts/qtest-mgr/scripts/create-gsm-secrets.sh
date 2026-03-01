#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# create-gsm-secrets.sh
# Creates ALL Google Secret Manager secrets for qTest 2026.2 on GKE.
#
# No kubectl create is used. ESO pulls everything from GSM.
#
# Usage:
#   export GCP_PROJECT="your-project-id"
#   export DB_PASSWORD="your-cloud-sql-password"
#   bash create-gsm-secrets.sh
#
# Prerequisites:
#   gcloud CLI authenticated with roles/secretmanager.admin
#
# Total: 17 GSM secrets
#   2  DB credentials
#   5  OAuth app secrets (sp, sessions, explorer, qmap, pulse)
#   2  Jira OAuth2 encryption keys  (MUST NOT be empty)
#   4  Internal service keys        (sessions, pulse executor, csrf×2)
#   1  Mail password                (empty string — required by Insights)
#   1  AES encryption key
#   2  Scenario secrets
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT="${GCP_PROJECT:?Set GCP_PROJECT env var}"
DB_PASSWORD="${DB_PASSWORD:?Set DB_PASSWORD env var}"

create_secret() {
  local name="$1" value="$2"
  if gcloud secrets describe "$name" --project="$PROJECT" &>/dev/null; then
    echo "  [exists] $name — adding new version"
    printf '%s' "$value" | gcloud secrets versions add "$name" \
      --project="$PROJECT" --data-file=-
  else
    echo "  [create] $name"
    printf '%s' "$value" | gcloud secrets create "$name" \
      --project="$PROJECT" --data-file=- --replication-policy=automatic
  fi
}

echo "══════════════════════════════════════════════════════════════"
echo "qTest 2026.2 — Creating GSM secrets (all via ESO, no kubectl)"
echo "Project: $PROJECT"
echo "══════════════════════════════════════════════════════════════"

# ── 1. Database Credentials ───────────────────────────────────────
echo ""
echo "── 1. Database Credentials ──"
create_secret "qtest-db-password"          "$DB_PASSWORD"
create_secret "qtest-db-readonly-password" "$DB_PASSWORD"

# ── 2. OAuth App Secrets ──────────────────────────────────────────
# Only the 5 integrations used in this deployment.
# sp        = Service Provider (core SSO — always required)
# sessions  = qtest-session subchart
# explorer  = Desktop Explorer
# qmap      = qtest-parameters subchart
# pulse     = qtest-pulse subchart
# (Jenkins, Bamboo, Tosca, Web Explorer removed — not used)
echo ""
echo "── 2. OAuth App Secrets ──"
for name in \
  qtest-oauth-sp-secret \
  qtest-oauth-sessions-secret \
  qtest-oauth-explorer-secret \
  qtest-oauth-qmap-secret \
  qtest-oauth-pulse-secret; do
  create_secret "$name" "$(openssl rand -base64 32 | tr -d '\n')"
done

# ── 3. Jira OAuth2 Encryption Keys ───────────────────────────────
# CRITICAL: These are internal qTest encryption keys — NOT Jira credentials.
# qTest WILL NOT START if either is empty.
# Generate ONCE only — changing them invalidates all stored Jira OAuth2 tokens.
echo ""
echo "── 4. Jira OAuth2 Encryption Keys (internal — MUST NOT be empty) ──"
create_secret "qtest-jira-oauth2-password" "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
create_secret "qtest-jira-oauth2-salt"     "$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')"

# ── 5. Internal Service Keys ──────────────────────────────────────
echo ""
echo "── 5. Internal Service Keys ──"
create_secret "qtest-sessions-secret-key"    "$(head -c 32 /dev/urandom | base64 | head -c 32 | base64 | tr -d '\n')"
create_secret "qtest-pulse-executor-api-key" "$(head -c 32 /dev/urandom | base64 | head -c 32 | base64 | tr -d '\n')"
create_secret "qtest-csrf-secret-key"        "$(openssl rand -base64 32 | tr -d '\n')"
create_secret "qtest-csrf-key"               "$(openssl rand -base64 32 | tr -d '\n')"

# ── 6. Mail Password ─────────────────────────────────────────────
# Required by Insights pod startup even if SMTP not configured.
# Store empty string — update to real SMTP password if email needed.
echo ""
echo "── 6. Mail Password ──"
create_secret "qtest-mail-password" ""

# ── 7. AES Integration Secret Key ────────────────────────────────
# Used by all Manager pods as env var AES_SECRET_KEYS.
# Stored separately in qtest-aes-secret-keys K8s secret.
echo ""
echo "── 7. AES Integration Secret Key ──"
create_secret "qtest-aes-secret-keys" "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"

# ── 8. Scenario Secrets ───────────────────────────────────────────
echo ""
echo "── 8. Scenario Secrets ──"
create_secret "qtest-scenario-refresh-token-secret" "$(openssl rand -base64 32 | tr -d '\n')"
create_secret "qtest-jira-cypher-key"               "$(openssl rand -base64 32 | tr -d '\n')"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Done! 17 GSM secrets created → 4 K8s Secrets"
echo ""
echo "K8s Secret              Keys  GSM secrets used"
echo "──────────────────────────────────────────────────────────────"
echo "qtest-manager-secret    15    qtest-db-{password,readonly-password}"
echo "                              qtest-oauth-{sp,sessions,explorer,qmap,pulse}-secret"
echo "                              qtest-jira-oauth2-{password,salt}"
echo "                              qtest-sessions-secret-key"
echo "                              qtest-pulse-executor-api-key"
echo "                              qtest-csrf-{secret-key,key}"
echo "                              qtest-mail-password"
echo "qtest-aes-secret-keys    1    qtest-aes-secret-keys"
echo "qtest-scenario-secret    2    qtest-scenario-refresh-token-secret"
echo "                              qtest-jira-cypher-key"
echo "qtest-i-etl-secret       4    qtest-db-password (×4 reused)"
echo "──────────────────────────────────────────────────────────────"
echo "TOTAL                   22 K8s keys from 17 distinct GSM secrets"
echo ""
echo "Next steps:"
echo "  1. Install ESO:"
echo "     helm install external-secrets external-secrets/external-secrets \\"
echo "       -n external-secrets --create-namespace"
echo "  2. Bind ESO KSA → GSA with roles/secretmanager.secretAccessor (WI)"
echo "  3. Replace CLOUD_SQL_PRIVATE_IP and SA_NAME@PROJECT_ID in values-gke-custom.yaml"
echo "  4. Deploy: helm upgrade --install qtest . -f values-gke-custom.yaml -n qtest"
echo "══════════════════════════════════════════════════════════════"
