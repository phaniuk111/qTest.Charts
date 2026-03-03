#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# create-gsm-secrets.sh
# Creates all required Google Secret Manager secrets for qTest 2025.8
# on GKE with Cloud SQL Auth Proxy (IAM passwordless authentication).
#
# Usage:
#   export GCP_PROJECT="your-project-id"
#   bash create-gsm-secrets.sh
#
# DB passwords are NOT stored here — authentication is handled by the
# Cloud SQL Auth Proxy using IAM tokens (--auto-iam-authn). The dummy
# value "unused" is stored so the app's secretKeyRef lookups succeed;
# the proxy intercepts the connection and substitutes an IAM token.
#
# Prerequisites:
#   - gcloud CLI authenticated with roles/secretmanager.admin
#   - External Secrets Operator installed in the GKE cluster
#   - ESO controller KSA bound to a GSA with:
#       roles/secretmanager.secretAccessor
#       roles/cloudsql.client
#       roles/cloudsql.instanceUser
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT="${GCP_PROJECT:?Set GCP_PROJECT env var}"

# Helper: create a GSM secret with a plaintext value
create_secret() {
  local name="$1"
  local value="$2"
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
echo "Creating Google Secret Manager secrets for qTest 2025.8"
echo "Project: $PROJECT"
echo "Auth mode: Cloud SQL Auth Proxy — IAM passwordless (--auto-iam-authn)"
echo "══════════════════════════════════════════════════════════════"

# ── Database Password Placeholders (REQUIRED — dummy values) ──────
# Real authentication is handled by the Cloud SQL Auth Proxy.
# The app container and Liquibase job have secretKeyRef lookups that
# MUST resolve — so we store "unused" rather than deleting the secret.
# The proxy intercepts the JDBC connection on 127.0.0.1:5432 and
# replaces the password with a live IAM OAuth2 token.
echo ""
echo "── Database Password Placeholders (dummy — proxy handles real auth) ──"
create_secret "qtest-db-password"          "unused"
create_secret "qtest-db-readonly-password" "unused"

# ── OAuth App Secrets (REQUIRED — internal tokens, not Jira/Jenkins) ─
# These are internal qTest microservice tokens, generated randomly.
# Jenkins, Bamboo, Tosca, and Web Explorer are NOT used in this deployment.
echo ""
echo "── OAuth App Secrets (5 — internal microservices only) ──"
for name in \
  qtest-oauth-sp-secret \
  qtest-oauth-sessions-secret \
  qtest-oauth-explorer-secret \
  qtest-oauth-qmap-secret \
  qtest-oauth-pulse-secret; do
  create_secret "$name" "$(openssl rand -base64 32)"
done

# ── Jira OAuth2 Keys (REQUIRED — startup-mandatory internal keys) ──
# These are NOT Jira integration credentials. They are qTest's internal
# encryption keys for the OAuth2 token subsystem.
# ⚠️  MUST contain real random values — qTest will NOT start if empty.
echo ""
echo "── Jira OAuth2 Internal Keys (startup-mandatory — NOT Jira credentials) ──"
create_secret "qtest-jira-oauth2-password" "$(openssl rand -base64 32)"
create_secret "qtest-jira-oauth2-salt"     "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)"

# ── Session & CSRF Keys (REQUIRED) ──────────────────────────────────
echo ""
echo "── Session & CSRF Keys ──"
create_secret "qtest-sessions-secret-key" "$(openssl rand -base64 32)"
create_secret "qtest-csrf-key"            "$(openssl rand -base64 32)"
create_secret "qtest-csrf-secret-key"     "$(openssl rand -base64 32)"

# ── Pulse Executor API Key (REQUIRED) ───────────────────────────────
echo ""
echo "── Pulse ──"
create_secret "qtest-pulse-executor-api-key" "$(openssl rand -base64 32)"

# ── Mail Password (REQUIRED by Insights startup — empty is valid) ───
echo ""
echo "── Mail Password (empty — SMTP not configured) ──"
create_secret "qtest-mail-password" ""

# ── AES Encryption Key (REQUIRED) ───────────────────────────────────
echo ""
echo "── AES Encryption Key ──"
create_secret "qtest-aes-secret-keys" "$(openssl rand -base64 32)"

# ── Scenario Secrets (REQUIRED) ─────────────────────────────────────
echo ""
echo "── Scenario ──"
create_secret "qtest-scenario-refresh-token-secret" "$(openssl rand -base64 32)"
create_secret "qtest-jira-cypher-key"               "$(openssl rand -base64 32)"

# ── i-ETL DB Password Placeholders (REQUIRED — dummy values) ─────────
# The qtest-i-etl deployment has hardcoded secretKeyRef lookups for
# these 4 keys. All point at 127.0.0.1:5432 via the proxy sidecar.
# Values are "unused" — the proxy handles real authentication.
echo ""
echo "── i-ETL DB Password Placeholders (dummy — proxy handles real auth) ──"
create_secret "qtest-i-etl-db-password"             "unused"
create_secret "qtest-i-etl-sessions-write-password" "unused"
create_secret "qtest-i-etl-sessions-read-password"  "unused"
create_secret "qtest-i-etl-insights-db-password"    "unused"

# ── LaunchDarkly SDK Key (OPTIONAL — empty) ──────────────────────────
echo ""
echo "── LaunchDarkly (empty — not used) ──"
create_secret "qtest-launchdarkly-sdk-key" ""

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Done! All GSM secrets created."
echo ""
echo "Secret summary:"
echo "  DB placeholders (proxy auth)  :  2  (qtest-db-password, qtest-db-readonly-password)"
echo "  OAuth app secrets             :  5  (sp, sessions, explorer, qmap, pulse)"
echo "  Jira OAuth2 internal keys     :  2  (password, salt — startup-mandatory)"
echo "  Session / CSRF / Pulse keys   :  4"
echo "  Mail password                 :  1  (empty)"
echo "  AES encryption key            :  1"
echo "  Scenario secrets              :  2"
echo "  i-ETL DB placeholders         :  4  (all 'unused')"
echo "  LaunchDarkly SDK key          :  1  (empty)"
echo "  ─────────────────────────────────"
echo "  TOTAL                         : 22  GSM secrets → 26 K8s keys"
echo ""
echo "Next steps:"
echo "  1. Verify ESO is installed:   helm list -n external-secrets"
echo "  2. Verify WI binding:         kubectl describe sa qtest-sa -n qtest"
echo "  3. Deploy Elasticsearch:      helm upgrade --install qtest-elasticsearch Charts/qtest-elasticsearch -n qtest"
echo "  4. Deploy qTest:              helm upgrade --install qtest Charts/qtest-mgr -f values-gke-custom.yaml -n qtest"
echo "  5. Verify pods are 2/2:       kubectl get pods -n qtest"
echo "══════════════════════════════════════════════════════════════"
