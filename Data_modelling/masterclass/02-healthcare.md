<!-- data-modelling-patterns: Healthcare -->

# Healthcare

## When to Use This Design

Healthcare data modeling is driven by questions that span both clinical and administrative domains:

- What is the total cost of care for patients with Type 2 Diabetes in the past year?
- Which patients had a lab result (HbA1c > 9) recorded after the encounter was finalized?
- Which claims were submitted to payer X but not yet adjudicated?
- Who accessed patient record Y on date Z? (HIPAA audit)

The critical design constraint absent from every other domain here: **healthcare data has legal definitions of "correct" that change over time**. A diagnosis code can be corrected retroactively. A lab result can be amended. The model must represent not only what was true in the clinical world (valid time) but also what the system believed at any given moment (transaction time). This is bi-temporal modeling, and it is not optional in healthcare.

## The Schema

### Patient Dimension

```sql
CREATE TABLE dim_patient (
    patient_key             BIGINT          NOT NULL,
    patient_id              VARCHAR(50)     NOT NULL,   -- MRN (Medical Record Number)
    mrn_system              VARCHAR(100)    NOT NULL,   -- issuing facility/system
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    date_of_birth           DATE,
    sex_at_birth            CHAR(1),                    -- 'M','F','U'
    gender_identity         VARCHAR(30),
    race_code               VARCHAR(10),
    ethnicity_code          VARCHAR(10),
    primary_language        VARCHAR(50),
    address_line1           VARCHAR(200),               -- store only if required for care
    city                    VARCHAR(100),
    state_code              CHAR(2),
    zip_code                VARCHAR(10),
    deceased_flag           BOOLEAN         NOT NULL    DEFAULT FALSE,
    deceased_date           DATE,
    -- SCD Type 2 columns
    valid_from_date         DATE            NOT NULL,
    valid_to_date           DATE            NOT NULL    DEFAULT '9999-12-31',
    is_current              BOOLEAN         NOT NULL    DEFAULT TRUE,
    -- Audit
    dw_inserted_at          TIMESTAMP       NOT NULL,
    dw_updated_at           TIMESTAMP       NOT NULL,
    source_system           VARCHAR(50)     NOT NULL,
    PRIMARY KEY (patient_key)
)
PARTITION BY (valid_from_date)
CLUSTER BY (state_code, zip_code);
```

**Row-Level Security Implication**: In a multi-facility system, analysts at Hospital A should not see patients of Hospital B. In Snowflake, this is implemented via Row Access Policies tied to a policy mapping table. In BigQuery, column-level security combined with row filters on `facility_id` is the pattern. The `dim_patient` table must carry a `facility_id` or `care_network_id` column even if that attribute seems redundant with the encounter data — the security policy must be evaluable on the dimension table itself, not via a join.

```sql
-- Snowflake row access policy
CREATE OR REPLACE ROW ACCESS POLICY patient_row_policy
AS (facility_id VARCHAR) RETURNS BOOLEAN ->
    'DATA_ADMIN' = CURRENT_ROLE()
    OR EXISTS (
        SELECT 1 FROM analyst_facility_access a
        WHERE a.analyst_email = CURRENT_USER()
        AND a.facility_id = facility_id
    );

ALTER TABLE dim_patient ADD ROW ACCESS POLICY patient_row_policy ON (facility_id);
```

### Encounter Fact (Clinical Events)

An encounter is the fundamental unit of care — an office visit, an ED visit, a hospitalization. Its grain is one row per encounter per patient. The temptation is to denormalize all diagnoses and procedures into the encounter row as arrays. This makes "patients with diagnosis code X" queries require array unnesting, which is a full scan regardless of indexes.

```sql
CREATE TABLE fact_encounter (
    encounter_key           BIGINT          NOT NULL,
    encounter_id            VARCHAR(80)     NOT NULL,
    patient_key             BIGINT          NOT NULL,
    encounter_type          VARCHAR(30)     NOT NULL,   -- 'OUTPATIENT','INPATIENT','ED','TELEHEALTH'
    admit_date_key          INT             NOT NULL,
    discharge_date_key      INT,                        -- NULL for outpatient / ongoing
    admit_datetime          TIMESTAMP       NOT NULL,
    discharge_datetime      TIMESTAMP,
    facility_key            BIGINT          NOT NULL,
    attending_provider_key  BIGINT,
    discharge_disposition   VARCHAR(50),               -- 'HOME','SNF','EXPIRED','TRANSFERRED'
    drg_code                VARCHAR(10),               -- Diagnosis Related Group (inpatient billing)
    los_days                INT,                       -- length of stay
    total_charges_amt       NUMERIC(14,2),
    total_payments_amt      NUMERIC(14,2),
    -- Bi-temporal columns
    valid_from              TIMESTAMP       NOT NULL,   -- when this was true in the real world
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,   -- when the system first recorded it
    corrected_at            TIMESTAMP,                  -- if this row supersedes a prior row
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,   -- for RLS policy
    PRIMARY KEY (encounter_key)
)
PARTITION BY (admit_date_key)
CLUSTER BY (patient_key, encounter_type, facility_id);
```

### Diagnosis, Procedure, Medication — Separate Tables

These are NOT columns on the encounter. They are child facts.

```sql
-- Diagnosis (ICD-10 codes associated with an encounter)
CREATE TABLE fact_diagnosis (
    diagnosis_key           BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    diagnosis_date_key      INT             NOT NULL,
    icd10_code              VARCHAR(10)     NOT NULL,
    diagnosis_description   VARCHAR(300),
    diagnosis_type          VARCHAR(20)     NOT NULL,   -- 'PRIMARY','SECONDARY','ADMITTING','POA'
    diagnosis_sequence      INT             NOT NULL    DEFAULT 1,
    chronic_flag            BOOLEAN         NOT NULL    DEFAULT FALSE,
    hcc_category            VARCHAR(20),               -- Hierarchical Condition Category (risk scoring)
    -- Bi-temporal
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (diagnosis_key)
)
PARTITION BY (diagnosis_date_key)
CLUSTER BY (patient_key, icd10_code);

-- Procedure
CREATE TABLE fact_procedure (
    procedure_key           BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    procedure_date_key      INT             NOT NULL,
    cpt_code                VARCHAR(10),               -- Current Procedural Terminology
    icd10_pcs_code          VARCHAR(10),               -- ICD-10 Procedure Coding System (inpatient)
    procedure_description   VARCHAR(300),
    modifier_code           VARCHAR(10),
    units_performed         INT             NOT NULL    DEFAULT 1,
    rendering_provider_key  BIGINT,
    -- Bi-temporal
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (procedure_key)
)
PARTITION BY (procedure_date_key)
CLUSTER BY (patient_key, cpt_code);

-- Medication order
CREATE TABLE fact_medication_order (
    med_order_key           BIGINT          NOT NULL,
    encounter_key           BIGINT,                    -- NULL for outpatient scripts
    patient_key             BIGINT          NOT NULL,
    order_date_key          INT             NOT NULL,
    ndc_code                VARCHAR(15)     NOT NULL,   -- National Drug Code
    drug_name               VARCHAR(200),
    drug_class              VARCHAR(100),
    dose_amount             NUMERIC(10,3),
    dose_unit               VARCHAR(20),
    route                   VARCHAR(30),               -- 'ORAL','IV','TOPICAL'
    frequency               VARCHAR(30),
    days_supply             INT,
    quantity_dispensed      NUMERIC(10,3),
    prescribing_provider_key BIGINT,
    pharmacy_key            BIGINT,
    order_status            VARCHAR(20)     NOT NULL,  -- 'ORDERED','DISPENSED','CANCELLED'
    is_controlled_substance BOOLEAN         NOT NULL   DEFAULT FALSE,
    valid_from              TIMESTAMP       NOT NULL,
    valid_to                TIMESTAMP       NOT NULL    DEFAULT '9999-12-31 23:59:59',
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL   DEFAULT TRUE,
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (med_order_key)
)
PARTITION BY (order_date_key)
CLUSTER BY (patient_key, ndc_code);
```

### Bi-Temporal Modeling: Valid Time vs Transaction Time

This is where healthcare diverges sharply from other domains. Consider this scenario:

- On March 1, a physician documents an encounter, coding the primary diagnosis as J06.9 (acute upper respiratory infection).
- On March 15, a coder reviews the encounter and corrects the diagnosis to J18.9 (pneumonia, unspecified).
- On April 1, an auditor reviews the claim and confirms the correction was appropriate.

A naive SCD Type 2 model records the correction as of March 15 (transaction time) and marks the March 1 version as expired. **This is insufficient.** The question "what was the documented diagnosis as of March 7?" requires knowing both the valid time (March 1 = when the encounter occurred) and the transaction time (March 7 = what the system believed at that point). With SCD Type 2 alone, you cannot reconstruct the March 7 system view after the correction.

The bi-temporal pattern adds a `recorded_at` / `transaction_time` axis:

```sql
-- Reconstructing what the system believed on March 7 about the March 1 encounter
SELECT *
FROM fact_diagnosis
WHERE encounter_key = 12345
  AND valid_from <= '2024-03-01 23:59:59'     -- encounter was valid on this date
  AND valid_to   >= '2024-03-01 00:00:00'
  AND recorded_at <= '2024-03-07 23:59:59'    -- system believed this as of March 7
ORDER BY recorded_at DESC
LIMIT 1;
```

This query returns the March 1 version of the diagnosis — J06.9 — as it was known on March 7, before the correction was entered.

### HIPAA-Adjacent Audit Trail

Every read and write access to PHI must be auditable. This is not a data model concern for analytics workloads — it is a platform concern (Snowflake access history, BigQuery data access logs, Databricks audit logs). However, the analytics warehouse must carry a separate audit dimension for data changes that are clinically significant:

```sql
CREATE TABLE audit_clinical_change (
    audit_key               BIGINT          NOT NULL,
    table_name              VARCHAR(100)    NOT NULL,
    record_key              BIGINT          NOT NULL,
    change_type             VARCHAR(20)     NOT NULL,   -- 'INSERT','CORRECT','VOID','AMEND'
    changed_by_user         VARCHAR(200)    NOT NULL,
    changed_at              TIMESTAMP       NOT NULL,
    prior_value_json        VARCHAR,                    -- previous state as JSON
    new_value_json          VARCHAR,                    -- new state as JSON
    change_reason           VARCHAR(500),
    facility_id             VARCHAR(50)     NOT NULL,
    PRIMARY KEY (audit_key)
)
PARTITION BY DATE(changed_at)
CLUSTER BY (table_name, record_key);
```

## The Hard Problems

**Sparse Columns Across Specialties**: A cardiology encounter has different clinical attributes than an oncology encounter. If you try to represent all specialty-specific attributes in a single `fact_encounter`, you get a table with 300 columns where any given row has 80% NULLs. The solution is an **entity-attribute-value (EAV) extension table** for specialty-specific clinical observations, combined with a structured `fact_observation` table:

```sql
CREATE TABLE fact_observation (
    observation_key         BIGINT          NOT NULL,
    encounter_key           BIGINT          NOT NULL,
    patient_key             BIGINT          NOT NULL,
    observation_date_key    INT             NOT NULL,
    observation_datetime    TIMESTAMP       NOT NULL,
    loinc_code              VARCHAR(20)     NOT NULL,   -- LOINC standardizes observation types
    observation_description VARCHAR(300),
    value_numeric           NUMERIC(14,4),
    value_text              VARCHAR(500),
    value_code              VARCHAR(50),
    unit_of_measure         VARCHAR(30),
    reference_range_low     NUMERIC(14,4),
    reference_range_high    NUMERIC(14,4),
    abnormal_flag           VARCHAR(5),                 -- 'H','L','A','N'
    result_status           VARCHAR(20),               -- 'FINAL','PRELIMINARY','CORRECTED'
    ordering_provider_key   BIGINT,
    facility_id             VARCHAR(50)     NOT NULL,
    valid_from              TIMESTAMP       NOT NULL,
    recorded_at             TIMESTAMP       NOT NULL,
    is_current_version      BOOLEAN         NOT NULL    DEFAULT TRUE,
    PRIMARY KEY (observation_key)
)
PARTITION BY (observation_date_key)
CLUSTER BY (patient_key, loinc_code);
```

Using `loinc_code` as the observation type identifier means any new lab test or vital sign is a new row, not a new column. This scales indefinitely without schema changes.

**Late-Arriving Lab Results**: A lab specimen collected during an encounter on Monday may not have results finalized until Wednesday. The encounter is closed. The result arrives as a new row in `fact_observation` with `valid_from` = Monday (specimen collection time) and `recorded_at` = Wednesday (when the lab transmitted). Your incremental loads that run nightly will correctly insert Wednesday's new records. The complication is that any pre-computed aggregate that was materialized on Tuesday ("all observations for encounters closed today") will be stale — it will not include Wednesday's lab results that are clinically associated with Tuesday's encounters. The solution is a **watermark-based processing pattern**: never materialize aggregates with a cutoff date of "today." Use a configurable lag (e.g., results are typically final within 72 hours) and set the aggregate materialization cutoff to `today - 3 days`.

## Scale Mechanics

Large healthcare systems (regional networks, national payers) accumulate 100M–500M encounter records over a 10-year retention window. The `fact_observation` table grows faster — a single inpatient stay may generate 500+ observations.

| Table | Partition Key | Clustering | Incremental Strategy |
|-------|--------------|------------|---------------------|
| fact_encounter | admit_date_key | patient_key, encounter_type | MERGE on encounter_id + is_current_version |
| fact_diagnosis | diagnosis_date_key | patient_key, icd10_code | Append new + insert corrections as new rows |
| fact_observation | observation_date_key | patient_key, loinc_code | Append-only (corrections create new rows) |
| audit_clinical_change | DATE(changed_at) | table_name, record_key | Append-only |

The bi-temporal model is append-only by design: corrections never delete old rows, they insert new rows with updated `valid_to` on the old and a fresh `valid_from` on the new. This makes incremental loads simple (no deletes, no MERGE complexity) but makes current-state queries require a `WHERE is_current_version = TRUE` filter on every query. That filter, combined with `patient_key` clustering, enables efficient point-lookups even at 1B rows.
