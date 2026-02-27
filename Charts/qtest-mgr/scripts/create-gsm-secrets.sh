#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# create-gsm-secrets.sh
# Creates all required Google Secret Manager secrets for qTest.
#
# Usage:
#   export GCP_PROJECT="your-project-id"
#   export DB_PASSWORD="your-cloud-sql-password"
#   bash create-gsm-secrets.sh
#
# Prerequisites:
#   - gcloud CLI authenticated with roles/secretmanager.admin
#   - External Secrets Operator installed in the GKE cluster
#   - ESO controller's KSA bound to a GSA with
#     roles/secretmanager.secretAccessor
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT="${GCP_PROJECT:?Set GCP_PROJECT env var}"
DB_PASSWORD="${DB_PASSWORD:?Set DB_PASSWORD env var (Cloud SQL superuser password)}"

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
echo "Creating Google Secret Manager secrets for qTest"
echo "Project: $PROJECT"
echo "══════════════════════════════════════════════════════════════"

# ── Database Credentials (REQUIRED) ──────────────────────────────
echo ""
echo "── Database Credentials ──"
create_secret "qtest-db-password" "$DB_PASSWORD"
create_secret "qtest-db-readonly-password" "$DB_PASSWORD"  # same password unless you have a read replica user

# ── OAuth App Secrets (REQUIRED) ─────────────────────────────────
echo ""
echo "── OAuth App Secrets ──"
for name in \
  qtest-oauth-sp-secret \
  qtest-oauth-sessions-secret \
  qtest-oauth-explorer-secret \
  qtest-oauth-qmap-secret \
  qtest-oauth-jenkins-secret \
  qtest-oauth-bamboo-secret \
  qtest-oauth-pulse-secret \
  qtest-oauth-tosca-secret \
  qtest-oauth-web-explorer-secret; do
  create_secret "$name" "$(openssl rand -base64 32)"
done

# ── Session & CSRF Keys (REQUIRED) ──────────────────────────────
echo ""
echo "── Session & CSRF Keys ──"
create_secret "qtest-sessions-secret-key" "$(openssl rand -base64 32)"
create_secret "qtest-csrf-key" "$(openssl rand -base64 32)"
create_secret "qtest-csrf-secret-key" "$(openssl rand -base64 32)"

# ── Pulse Executor API Key (REQUIRED) ───────────────────────────
echo ""
echo "── Pulse ──"
create_secret "qtest-pulse-executor-api-key" "$(openssl rand -base64 32)"

# ── Encryption Keys (REQUIRED) ──────────────────────────────────
echo ""
echo "── Encryption Keys ──"
create_secret "qtest-aes-secret-keys" "$(openssl rand -base64 32)"

# ── Scenario Secrets (REQUIRED) ─────────────────────────────────
echo ""
echo "── Scenario ──"
create_secret "qtest-scenario-refresh-token-secret" "$(openssl rand -base64 32)"
create_secret "qtest-jira-cypher-key" "$(openssl rand -base64 32)"

# ── Integration Keys (OPTIONAL — empty because unused) ──────────
echo ""
echo "── Integration Keys (empty — unused) ──"
create_secret "qtest-mail-password" ""
create_secret "qtest-jira-oauth2-password" ""
create_secret "qtest-jira-oauth2-salt" ""
create_secret "qtest-launchdarkly-sdk-key" ""

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Done! All GSM secrets created."
echo ""
echo "Next steps:"
echo "  1. Ensure ESO is installed:  helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace"
echo "  2. Ensure the ESO KSA has WI binding to a GSA with roles/secretmanager.secretAccessor"
echo "  3. Deploy qTest:  helm upgrade --install qtest . -f values-gke-custom.yaml -n qtest"
echo "══════════════════════════════════════════════════════════════"
