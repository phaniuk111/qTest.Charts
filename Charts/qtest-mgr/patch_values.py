import re

with open('values-gke-custom.yaml', 'r') as f:
    content = f.read()

# 1. Update intro comments
content = content.replace("No Cloud SQL Auth Proxy sidecar is needed", "Cloud SQL Auth Proxy sidecar is used")
content = content.replace("username/password via the qtest-manager-secret", "IAM database authentication (passwordless)")
content = content.replace("No longer needed for Cloud SQL Auth Proxy.", "Used by Cloud SQL Auth Proxy for IAM authentication.")

# 2. Add extraContainers block to the root (for qtest-mgr)
root_extra_containers = """
# ── Extra Containers (Cloud SQL Auth Proxy) ──────────────────────────
extraContainers:
  - name: cloud-sql-proxy
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.2
    args:
      - "--port=5432"
      - "--auto-iam-authn"
      - "PROJECT_ID:REGION:INSTANCE_NAME" # TODO: replace
    securityContext:
      runAsNonRoot: true

"""

content = content.replace("affinity:", root_extra_containers + "affinity:")

# 3. Add extraContainers to subcharts
sidecar_yaml = """  extraContainers:
    - name: cloud-sql-proxy
      image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.2
      args:
        - "--port=5432"
        - "--auto-iam-authn"
        - "PROJECT_ID:REGION:INSTANCE_NAME" # TODO: replace
      securityContext:
        runAsNonRoot: true
"""

for chart in ["qtest-launch:", "qtest-insights:", "qtest-parameters:", 
              "qtest-scenario:", "qtest-session:", "qtest-pulse:", 
              "qtest-insights-etl:"]:
    content = content.replace(f"{chart}\n  enabled: true", f"{chart}\n  enabled: true\n{sidecar_yaml}")

# 4. Replace CLOUD_SQL_PRIVATE_IP with 127.0.0.1
content = content.replace("CLOUD_SQL_PRIVATE_IP", "127.0.0.1")

# 5. Replace "qtest_user" with IAM "my-service-account@project.iam"
content = content.replace('"qtest_user"', '"my-service-account@project.iam" # TODO: replace with IAM db user')

with open('values-gke-custom.yaml', 'w') as f:
    f.write(content)
