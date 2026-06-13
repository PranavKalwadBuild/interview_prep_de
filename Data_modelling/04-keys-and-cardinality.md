<!-- Part of data-modelling-patterns: Keys, Cardinality and Relationships -->

# Keys, Cardinality and Relationships

---

## Keys

> **Keywords to spot:** "unique identifier", "business key", "natural key", "surrogate key", "composite key", "foreign key", "referential integrity"

### Natural Key
A key that exists in the real world and already uniquely identifies an entity. Examples: SSN, email address, ISBN, IATA airport code, VIN.

**Gotcha:** Natural keys change. Customers change email. Companies change legal name. If you use a natural key as a PK, every FK referencing it must be updated too. This is why warehouses use surrogate keys.

### Surrogate Key
A system-generated integer (or hash) with no business meaning. Used as the PK in dimensional models.

```sql
create table dim_customer (
    customer_sk     bigint        primary key,   -- surrogate key
    customer_id     varchar(50)   not null,      -- natural/business key
    full_name       varchar(200),
    email           varchar(255)
);
```

The surrogate key (`customer_sk`) is what fact tables reference. The natural key (`customer_id`) is preserved for traceability but is not the join key.

**Gotcha:** In SCD Type 2, a single customer_id maps to multiple `customer_sk` values (one per version). This is intentional — it's how you join a fact to the right version of the dimension that was active at the time of the event.

### Composite Key
A primary key made up of two or more columns. Common in junction/bridge tables and normalized OLTP schemas.

```sql
create table order_product (
    order_id    int  not null,
    product_id  int  not null,
    quantity    int  not null,
    primary key (order_id, product_id)
);
```

**Gotcha:** Composite PKs are fine in OLTP. In dimensional models, avoid them on fact tables — use a surrogate PK instead, and define uniqueness via unique constraints or documentation. Composite PKs on large fact tables complicate incremental loading.

### Foreign Key
A column (or set of columns) that references the PK of another table, enforcing referential integrity.

```sql
create table fact_order (
    order_sk        bigint  primary key,
    customer_sk     bigint  references dim_customer(customer_sk),
    product_sk      bigint  references dim_product(product_sk),
    order_date_sk   int     references dim_date(date_sk),
    revenue         decimal(12,2)
);
```

**Gotcha:** Most cloud warehouses (Snowflake, BigQuery, Redshift) don't enforce FK constraints at insert time — they are "informational only." Your pipeline must guarantee referential integrity. Don't rely on the database to catch orphaned FK values.

---

## Cardinality and Relationships

> **Keywords to spot:** "one-to-many", "many-to-many", "parent-child", "junction table", "bridge table", "M:N relationship"

### One-to-One (1:1)
Rare. One row in table A maps to exactly one row in table B. Example: employee and their assigned laptop (if every employee has exactly one, and every laptop is assigned to one).

Use case: Split a wide table into two for security (PII separation) or performance.

```
employee ──── employee_pii
  (1)             (1)
```

### One-to-Many (1:N)
The most common relationship. One row in table A maps to many rows in table B. Example: one customer → many orders.

```
customer ────< order
  (1)            (N)
```

In SQL: the FK lives on the "many" side.

```sql
create table orders (
    order_id    int primary key,
    customer_id int references customers(customer_id),  -- FK on the N side
    order_date  date
);
```

### Many-to-Many (M:N)
One row in A maps to many rows in B, and one row in B maps to many rows in A. Example: students enroll in many courses; courses have many students.

Implemented via a **bridge/junction table**:

```
student ────< enrollment >──── course
  (1)            (M:N)           (1)
```

```sql
create table enrollment (
    student_id  int  references students(student_id),
    course_id   int  references courses(course_id),
    enrolled_at date,
    primary key (student_id, course_id)
);
```

**Gotcha:** M:N relationships are the #1 source of fan-out (row multiplication) bugs in dimensional models. See Section 17.
