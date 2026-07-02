# 11 — Security and Governance: PII Masking, Credential Expiry, and Access Failures

---

## 1. The Problem

Three related failure modes under one security umbrella:

**Mode A — Credential expiry:** Short-lived IAM tokens (default 1–12 hours) expire during a long-running job. Job processes 90% of data over 7 hours, then every task suddenly fails with `AccessDeniedException`. All work is lost unless checkpointing is in place.

**Mode B — PII leakage:** SSN, email, credit card numbers are written unmasked to the data warehouse because the pipeline has no masking step. Violates GDPR/CCPA. Discovered during a compliance audit or, worse, a breach.

**Mode C — Executor access failures:** The executor node's IAM role or service account lacks `s3:GetObject` / `s3:PutObject` on the specific bucket prefix. Job fails on the first file read or write.

---

## 2. Interview Trigger Phrases

- "PII"
- "GDPR" or "CCPA"
- "credential expiry"
- "AccessDenied" mid-job
- "data masking"
- "tokenization"
- "encryption at rest"
- "column-level security"
- "role-based access control"
- "service account permissions"
- "right to erasure"

---

## 3. Detection Signals

| Signal | Where to Look |
|--------|---------------|
| `AccessDeniedException` in executor logs | Spark UI → Executors → stderr logs |
| Job runs fine for hours then all tasks fail simultaneously | Credential token expiry (check IAM token TTL vs. job duration) |
| Credentials rotation event correlates with job failure time | CloudTrail → IAM AssumeRole events |
| PII columns visible in data preview or query results | Data catalog column profiling; manual inspection |
| `NoCredentialsError` or `ExpiredTokenException` | Executor stderr; `yarn logs -applicationId <app_id>` |

---

## 4. Root Cause

**Credential expiry:**
Static credentials or STS session tokens have fixed TTLs. When a job outlives the token TTL, every subsequent S3 API call is rejected. The driver may have already planned all tasks, but executor file I/O fails at runtime.

**PII leakage:**
No masking/tokenization stage in the ETL pipeline. Data flows straight from source to sink with all sensitive fields intact. Schema enforcement does not mask — it only validates types.

**Access failures:**
Executor nodes run under an IAM role (EC2 instance profile, EKS service account, Databricks cluster IAM role). If that role lacks permissions on the specific bucket prefix, all file operations fail. The driver role (which plans the job) may have different permissions than the executor role (which reads/writes data), causing deceptive errors.

---

## 5. Fix Pattern

### Credential Management — Use Instance Profiles, Not Static Keys

```python
# WRONG: static keys expire and are visible in environment variables
spark.conf.set("fs.s3a.access.key", "AKIAIOSFODNN7EXAMPLE")
spark.conf.set("fs.s3a.secret.key", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

# RIGHT: instance profile credentials auto-refresh — no expiry issue
# Set via spark-submit (see config delta section)
```

For Databricks with Azure:
```python
# Use secret scopes (backed by Azure Key Vault or Databricks secrets)
# Never hardcode — secrets are redacted from logs
spark.conf.set(
    "fs.azure.account.key.<storage-account>.dfs.core.windows.net",
    dbutils.secrets.get(scope="kv-scope", key="storage-account-key")
)
```

For long-running jobs requiring STS assume-role with extended session:
```bash
# Extend role session duration to 12 hours (max) on the IAM role definition
# Trust policy: MaxSessionDuration = 43200
aws sts assume-role \
  --role-arn arn:aws:iam::123456789012:role/SparkIngestionRole \
  --role-session-name spark-job-$(date +%s) \
  --duration-seconds 43200
```

### PII Masking in the Pipeline

```python
from pyspark.sql import functions as F
import hashlib

# Tokenization (non-reversible, consistent: same input → same token)
# Use a secret salt stored in secrets manager — never hardcode
SALT = get_secret("pii-hash-salt")  # retrieve from AWS Secrets Manager

@F.udf("string")
def tokenize(value: str) -> str:
    if value is None:
        return None
    return hashlib.sha256(f"{SALT}{value}".encode()).hexdigest()[:16]

# Partial masking (keeps last 4 of SSN for display use cases)
# Full redaction for fields with no legitimate downstream use
df = (
    df
    .withColumn("email",       tokenize(F.col("email")))           # tokenize
    .withColumn("ssn",         F.regexp_replace("ssn", r"^\d{5}", "XXXXX"))  # partial mask
    .withColumn("credit_card", F.lit("MASKED"))                    # full redaction
    .withColumn("phone",       F.regexp_replace("phone", r"\d{6}$", "XXXXXX"))
)

# Apply masking BEFORE any write — never write raw PII to intermediate paths
df.write.mode("append").parquet(target_path)
```

### Column-Level Security (Query Layer — More Robust Than Pipeline Masking)

```sql
-- Databricks Unity Catalog: column masking policy
CREATE OR REPLACE FUNCTION mask_email(email STRING)
  RETURN IF(IS_ACCOUNT_GROUP_MEMBER('pii-readers'), email, sha2(email, 256));

ALTER TABLE schema.events
  ALTER COLUMN email SET MASK mask_email;

-- Apache Ranger (Hive/Spark SQL): configure column masking policy in Ranger UI
-- Applies at query execution time regardless of which job reads the table
```

### Audit Logging

```python
# Emit an audit record for every job that touches PII tables
audit_record = {
    "job_id":      spark.sparkContext.applicationId,
    "table":       target_table,
    "run_time":    datetime.utcnow().isoformat(),
    "user":        spark.sparkContext.sparkUser(),
    "row_count":   df.count(),
    "pii_columns": ["email", "ssn", "credit_card"],
    "masking":     "sha256-tokenized",
}
# Write to immutable audit table (append-only, separate S3 bucket with WORM policy)
spark.createDataFrame([audit_record]).write.mode("append").json(audit_log_path)
```

### GDPR Right-to-Erasure Design Pattern

```python
# Design for deletion at partition level
# Partition on a pseudonymized customer_id so you can drop one partition

# Delta Lake DELETE (targeted, no full rewrite)
spark.sql(f"""
    DELETE FROM schema.events
    WHERE customer_token = '{customer_token_to_erase}'
""")

# For non-Delta: re-partition and rewrite excluding the erased customer
df_clean = spark.read.parquet(table_path) \
               .filter(F.col("customer_token") != customer_token_to_erase)
df_clean.write.mode("overwrite").partitionBy("year", "month").parquet(table_path)
```

### spark-submit Config Delta

```bash
# Use instance profile credentials — auto-refreshed, no expiry
--conf spark.hadoop.fs.s3a.aws.credentials.provider=\
      com.amazonaws.auth.InstanceProfileCredentialsProvider

# Encrypt inter-executor shuffle traffic
--conf spark.authenticate=true
--conf spark.network.crypto.enabled=true

# SSL for shuffle service
--conf spark.ssl.enabled=true
--conf spark.ssl.keyStore=/etc/ssl/spark.jks
--conf spark.ssl.keyStorePassword=${KEY_STORE_PWD}  # from secrets manager

# Databricks: use cluster IAM role (set in cluster config, not spark-submit)
```

---

## 6. Gotchas

- **Never put credentials in `--conf` flags or environment variables visible in `ps aux`.** Use instance profiles or secrets manager. Spark UI exposes spark config values to anyone with cluster access.
- **SHA-256 is tokenization, not encryption.** It is one-way and deterministic. With the same input, output is always the same — useful for joining tokenized records. Store the salt securely; without it, tokenization cannot be reversed (which may be the goal for erasure, but not for pseudonymization).
- **Pipeline-layer masking has a race condition.** If an intermediate shuffle or checkpoint writes un-masked data to disk before the masking step runs, PII may be exposed in temp paths. Always mask as early as possible in the DAG.
- **GDPR right-to-erasure requires partition-aware design.** If you can't delete by partition, you must rewrite entire tables. Design `customer_token` partitioning upfront.
- **Column masking at the query layer (Unity Catalog / Ranger) is more robust** than pipeline masking because it applies universally regardless of which pipeline or analyst queries the table. Pipeline masking only protects one write path.
- **`is_account_group_member` checks in Unity Catalog are evaluated at query time per user.** They correctly serve different users different views of the same table without duplicating data.
- **Executor roles ≠ driver roles on EMR.** The driver runs on the master node; executors run on core/task nodes. If you attach the IAM role only to the master node profile, all executor S3 reads fail. Attach the role to both master and core/task profiles.

---

## 7. Interview One-Liner

> "The three security failure modes — credential expiry, PII leakage, and access misconfigurations — are fixed by: instance profile credentials (auto-refreshing, no TTL problem), SHA-256 tokenization applied before any write with the salt in secrets manager, and column masking policies at the catalog layer (Unity Catalog or Ranger) which enforce masking universally regardless of which pipeline writes the data."
