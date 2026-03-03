# qTest on GKE with Cloud SQL Auth Proxy — Passwordless IAM Auth

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  GKE Pod                                              │
│  ┌──────────────┐    ┌─────────────────────────────┐  │
│  │ qTest App    │───▶│ Cloud SQL Auth Proxy         │  │
│  │              │    │  --auto-iam-authn            │  │
│  └──────────────┘    └──────────────┬──────────────┘  │
│   JDBC: 127.0.0.1:5432              │                 │
│   user: qtest-sa@PROJECT.iam        │                 │
│   pass: "unused" (ignored by proxy) │                 │
└─────────────────────────────────────┼─────────────────┘
                                      │ Proxy auto-generates
                                      │ OAuth2 IAM token
                                      ▼
                            ┌─────────────────┐
                            │  Cloud SQL       │
                            │  PostgreSQL      │
                            │  (Private IP)    │
                            └─────────────────┘
                             No password stored
                             anywhere — token-based
```

> [!CAUTION]
> Passwordless IAM auth is **not officially documented by Tricentis**. qTest may reject an empty password internally. We use `"unused"` as a dummy value — the proxy ignores it and substitutes an IAM token. **Test in staging first.**

---

## Step 1: Cloud SQL — Enable IAM Authentication

```bash
# Create instance with IAM auth flag enabled
gcloud sql instances create qtest-db \
  --database-version=POSTGRES_15 \
  --tier=db-custom-4-16384 \
  --region=REGION \
  --network=projects/PROJECT_ID/global/networks/VPC_NAME \
  --no-assign-ip \
  --database-flags=cloudsql.iam_authentication=on \
  --storage-size=100GB \
  --availability-type=REGIONAL

# If instance already exists, patch it:
gcloud sql instances patch qtest-db \
  --database-flags=cloudsql.iam_authentication=on
```

---

## Step 2: GCP — Create Service Account & IAM Roles

```bash
# Create GSA
gcloud iam service-accounts create qtest-sa \
  --display-name="qTest Service Account"

# Role 1: Connect to Cloud SQL via proxy
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:qtest-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Role 2: IAM database login (passwordless auth)
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:qtest-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudsql.instanceUser"

# Role 3: Secret Manager (for ESO — non-DB secrets like AES keys, OAuth secrets)
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:qtest-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Workload Identity binding
gcloud iam service-accounts add-iam-policy-binding \
  qtest-sa@PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:PROJECT_ID.svc.id.goog[qtest/qtest-sa]"
```

---

## Step 3: Cloud SQL — Create IAM DB User & Databases

```bash
# Create the IAM database user in Cloud SQL
gcloud sql users create qtest-sa@PROJECT_ID.iam \
  --instance=qtest-db \
  --type=CLOUD_IAM_SERVICE_ACCOUNT

# Connect as postgres admin
gcloud sql connect qtest-db --user=postgres
```

Then run the SQL:

```sql
-- 1. Create all 5 databases
CREATE DATABASE qtest;
CREATE DATABASE sessions;
CREATE DATABASE parameters;
CREATE DATABASE pulse;
CREATE DATABASE scenario;

-- 2. Setup each database (extensions + ownership)

\c qtest
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS tablefunc;
ALTER SCHEMA public OWNER TO "qtest-sa@PROJECT_ID.iam";
GRANT ALL PRIVILEGES ON DATABASE qtest TO "qtest-sa@PROJECT_ID.iam";
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "qtest-sa@PROJECT_ID.iam";

\c sessions
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS tablefunc;
ALTER SCHEMA public OWNER TO "qtest-sa@PROJECT_ID.iam";
GRANT ALL PRIVILEGES ON DATABASE sessions TO "qtest-sa@PROJECT_ID.iam";
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "qtest-sa@PROJECT_ID.iam";

\c parameters
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS tablefunc;
ALTER SCHEMA public OWNER TO "qtest-sa@PROJECT_ID.iam";
GRANT ALL PRIVILEGES ON DATABASE parameters TO "qtest-sa@PROJECT_ID.iam";
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "qtest-sa@PROJECT_ID.iam";

\c pulse
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS tablefunc;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
ALTER SCHEMA public OWNER TO "qtest-sa@PROJECT_ID.iam";
GRANT ALL PRIVILEGES ON DATABASE pulse TO "qtest-sa@PROJECT_ID.iam";
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "qtest-sa@PROJECT_ID.iam";

\c scenario
ALTER SCHEMA public OWNER TO "qtest-sa@PROJECT_ID.iam";
GRANT ALL PRIVILEGES ON DATABASE scenario TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "qtest-sa@PROJECT_ID.iam";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "qtest-sa@PROJECT_ID.iam";
```

---

## Step 4: Helm Chart — Proxy Sidecar Config

The proxy sidecar in `values-gke-custom.yaml` uses `--auto-iam-authn`:

```yaml
extraContainers:
  - name: cloud-sql-proxy
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.2
    args:
      - "--port=5432"
      - "--auto-iam-authn"                     # ← passwordless
      - "PROJECT_ID:REGION:qtest-db"           # ← instance connection name
    securityContext:
      runAsNonRoot: true
```

### JDBC Configuration

```yaml
qTestManager:
  client:
    jdbc:
      postgresUrl: "jdbc:postgresql://127.0.0.1:5432/qtest"
      postgresUserName: "qtest-sa@PROJECT_ID.iam"   # IAM user (no .gserviceaccount.com)
      postgresPassword: "unused"                      # dummy — proxy ignores this
      postgresReadOnlyUrl: "jdbc:postgresql://127.0.0.1:5432/qtest"
      postgresReadOnlyUserName: "qtest-sa@PROJECT_ID.iam"
      postgresReadOnlyPassword: "unused"
```

> [!NOTE]
> The password `"unused"` never reaches Cloud SQL. The proxy intercepts it on localhost and substitutes a real IAM token. We set it to a non-empty string to avoid potential Java validation rejecting an empty password.

---

## Step 5: Deploy

```bash
cd Charts/qtest-mgr

# 1. Update dependencies
helm dependency update .

# 2. Deploy ECK Operator
cd ../eck-operator
helm upgrade --install elastic-operator . -n elastic-system --create-namespace --wait

# 3. Deploy Elasticsearch cluster via ECK
cd ../qtest-eck-elasticsearch
helm upgrade --install qtest-elasticsearch . -f values.yaml -n qtest

# Wait for the ES pod to be ready:
# kubectl get pods -n qtest -w

# 4. Deploy qTest Manager
cd ../qtest-mgr
helm upgrade --install qtest . -f values-gke-custom.yaml -n qtest
```

---

## Step 6: Verify

```bash
# All pods should show 2/2 READY (app + proxy sidecar)
kubectl get pods -n qtest

# Proxy logs — look for "ready for new connections"
kubectl logs deployment/mgr-ui-deployment -c cloud-sql-proxy -n qtest

# App logs — check for successful DB connection
kubectl logs deployment/mgr-ui-deployment -c qtest-mgr -n qtest | head -100

# Liquibase job — should be Completed
kubectl get jobs -n qtest
```

### If qTest fails to connect

| Symptom | Cause | Fix |
|---|---|---|
| `password authentication failed` | IAM user not created in Cloud SQL | Run `gcloud sql users create` from Step 3 |
| `password is required` in app logs | qTest rejects empty password | Set `postgresPassword: "unused"` (already done) |
| `Connection refused` on startup | Proxy not ready yet, app retried | Normal — HikariCP retries automatically |
| `permission denied for schema` | Schema ownership not set | Run `ALTER SCHEMA public OWNER TO` from Step 3 |

---

## Checklist

| # | Task | Status |
|---|---|---|
| 1 | Cloud SQL instance with `cloudsql.iam_authentication=on` | ☐ |
| 2 | GSA with `cloudsql.client` + `cloudsql.instanceUser` roles | ☐ |
| 3 | Workload Identity binding (KSA → GSA) | ☐ |
| 4 | IAM DB user created via `gcloud sql users create --type=CLOUD_IAM_SERVICE_ACCOUNT` | ☐ |
| 5 | 5 databases created (`qtest`, `sessions`, `parameters`, `pulse`, `scenario`) | ☐ |
| 6 | Extensions + schema ownership granted on all databases | ☐ |
| 7 | `values-gke-custom.yaml` with `--auto-iam-authn` proxy + `127.0.0.1` | ☐ |
| 8 | ESO configured for non-DB secrets (AES keys, OAuth, etc.) | ☐ |
| 9 | ECK Operator installed in `elastic-system` | ☐ |
| 10 | Elasticsearch deployed via ECK (`qtest-es`) | ☐ |
| 11 | `helm upgrade --install` qTest | ☐ |
| 12 | All pods 2/2 READY, Liquibase completed | ☐ |
