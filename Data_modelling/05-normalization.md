<!-- data-modelling-patterns: Normalization — 1NF, 2NF, 3NF, BCNF, Denormalization -->

# Normalization (OLTP)

---

## 1. First Normal Form (1NF)

**What it solves:** Eliminates repeating groups and non-atomic values. Ensures every cell holds a single value, and every row is uniquely identifiable.

> **Keywords to spot:** "repeating groups", "comma-separated values in a column", "array in a cell", "multi-valued attribute", "flatten", "atomicity"

**Business Context:**
- **E-commerce:** An `orders` table storing `product_ids = "101,102,103"` in one column
- **HR:** An `employees` table with `phone1`, `phone2`, `phone3` columns instead of a separate `employee_phones` table
- **Healthcare:** A `patient` table storing `allergies = "penicillin, latex, ibuprofen"` in one varchar field

**Violation — before 1NF:**

```sql
-- BAD: storing multiple products in one column
create table orders_bad (
    order_id    int primary key,
    customer_id int,
    product_ids varchar(200),   -- "101,102,103" — NOT atomic
    order_date  date
);
```

**Fixed — 1NF:**

```sql
-- Parent order table
create table orders (
    order_id    int primary key,
    customer_id int,
    order_date  date
);

-- Child line items — each row is one product on one order
create table order_line_items (
    order_id    int  references orders(order_id),
    product_id  int,
    quantity    int,
    unit_price  decimal(10,2),
    primary key (order_id, product_id)
);
```

**Gotchas:**
- JSON/ARRAY columns in modern databases (Snowflake VARIANT, BigQuery ARRAY, Postgres JSONB) technically violate 1NF, but are acceptable in OLAP schemas where you control the querying layer. In OLTP, avoid them as primary storage.
- "Repeating groups" means both comma-separated values AND multiple numbered columns (`tag1`, `tag2`, `tag3`). Both violate 1NF.
- A table with no PK or a PK that is ambiguous also violates 1NF — you need a way to uniquely identify every row.

---

## 2. Second Normal Form (2NF)

**What it solves:** Eliminates partial dependencies. Every non-key attribute must depend on the **whole** primary key, not just part of it. Only applies to tables with composite primary keys.

> **Keywords to spot:** "partial dependency", "composite key", "attribute depends on part of the key", "redundant data in junction table"

**Business Context:**
- **E-commerce:** Order-product junction table storing `product_name` — product name depends only on `product_id`, not on `(order_id, product_id)`
- **SaaS:** User-role table storing `role_description` — description depends only on `role_id`
- **Logistics:** Shipment-item table storing `warehouse_address` — address depends on `warehouse_id`, not the composite key

**Violation — 1NF but not 2NF:**

```sql
-- Composite PK is (order_id, product_id)
-- product_name depends ONLY on product_id — partial dependency!
create table order_items_bad (
    order_id        int,
    product_id      int,
    product_name    varchar(200),   -- depends only on product_id — VIOLATION
    quantity        int,
    unit_price      decimal(10,2),
    primary key (order_id, product_id)
);
```

**Fixed — 2NF:**

```sql
-- product_name belongs in the products table
create table products (
    product_id      int primary key,
    product_name    varchar(200),
    category        varchar(100)
);

-- order_items only stores what depends on the full composite key
create table order_items (
    order_id    int,
    product_id  int  references products(product_id),
    quantity    int,
    unit_price  decimal(10,2),
    primary key (order_id, product_id)
);
```

**Gotchas:**
- 2NF violations only occur with composite PKs. A table with a single-column PK that satisfies 1NF automatically satisfies 2NF.
- Interviewers test this by asking: "If the product name changes, how many rows need updating?" The answer should always be one row in one table, not N rows scattered across a junction table.
- `unit_price` stays in `order_items` even though `product` has a price — the price at time of order is a fact about the order-product relationship, not just the product. This is a deliberate 2NF-compliant design choice.

---

## 3. Third Normal Form (3NF)

**What it solves:** Eliminates transitive dependencies. Every non-key attribute must depend directly on the PK — not on another non-key attribute.

> **Keywords to spot:** "transitive dependency", "attribute depends on another non-key column", "redundant lookup data embedded in table", "department name stored on employee row"

**Business Context:**
- **HR:** `employees` table storing both `dept_id` and `dept_name` — `dept_name` depends on `dept_id`, not on `emp_id`
- **E-commerce:** `orders` table storing `customer_city` and `customer_zip` — city depends on zip, not on order_id
- **SaaS:** `subscriptions` table storing `plan_id` and `plan_monthly_cost` — cost depends on plan, not on subscription

**Violation — 2NF but not 3NF:**

```sql
-- dept_name depends on dept_id, which depends on emp_id
-- dept_name -> dept_id -> emp_id: that's a transitive dependency
create table employees_bad (
    emp_id      int primary key,
    emp_name    varchar(100),
    dept_id     int,
    dept_name   varchar(100),   -- VIOLATION: depends on dept_id, not emp_id
    salary      decimal(10,2)
);
```

**Fixed — 3NF:**

```sql
create table departments (
    dept_id     int primary key,
    dept_name   varchar(100) not null
);

create table employees (
    emp_id      int primary key,
    emp_name    varchar(100),
    dept_id     int  references departments(dept_id),
    salary      decimal(10,2)
);
```

**Iterative build — adding more depth:**

A 3NF schema naturally grows into a web of normalized tables. Here's what a 3NF HR schema looks like:

```
departments ────< employees >──── employee_roles
     |                                   |
     |                               role_types
     |
  locations
```

```sql
create table locations (
    location_id int primary key,
    city        varchar(100),
    country     varchar(100)
);

create table departments (
    dept_id     int primary key,
    dept_name   varchar(100),
    location_id int  references locations(location_id)
);

create table role_types (
    role_type_id    int primary key,
    role_name       varchar(100),
    grade_band      varchar(20)
);

create table employees (
    emp_id          int primary key,
    emp_name        varchar(100),
    dept_id         int  references departments(dept_id),
    role_type_id    int  references role_types(role_type_id),
    hire_date       date,
    salary          decimal(10,2)
);
```

**Gotchas:**
- 3NF is the target for OLTP. It minimizes update anomalies — when a department name changes, you update one row in `departments`, not thousands of employee rows.
- In analytical models, you deliberately denormalize back (see Section 5 and Section 8). The normalization journey exists so you understand what you're trading away.
- "3NF" is often used loosely to mean "well-normalized." In interviews, saying "I'd normalize this to 3NF for the operational layer, then denormalize into a star schema for analytics" is the right frame.

---

## 4. Boyce-Codd Normal Form (BCNF)

**What it solves:** A stricter version of 3NF. Eliminates anomalies that 3NF misses when a table has multiple overlapping candidate keys.

> **Keywords to spot:** "overlapping candidate keys", "functional dependency from non-prime attribute", "BCNF violation", "stricter than 3NF"

**The rule:** For every functional dependency X → Y, X must be a superkey. In 3NF you allowed non-superkey determinants as long as Y is a prime attribute. BCNF removes that exception.

**When does this come up?**

Rare in practice. The classic example: a table where an instructor can teach only one subject, but a subject can have multiple instructors, and a student can be in only one section per subject.

```sql
-- Candidate keys: (student, subject) and (student, instructor)
-- instructor -> subject is a functional dependency where instructor is NOT a superkey
-- This violates BCNF even though it may satisfy 3NF
create table enrollment_bad (
    student_id      int,
    instructor_id   int,
    subject         varchar(100),
    primary key (student_id, subject)  -- one of the candidate keys
    -- instructor -> subject dependency violates BCNF
);
```

**Fixed — BCNF:**

```sql
-- Split into two tables: instructor-subject assignment + student-instructor enrollment
create table instructor_subjects (
    instructor_id   int primary key,
    subject         varchar(100)
);

create table student_instructors (
    student_id      int,
    instructor_id   int  references instructor_subjects(instructor_id),
    primary key (student_id, instructor_id)
);
```

**Gotchas:**
- BCNF decomposition can lose some functional dependencies — you sometimes can't enforce a constraint without a multi-table check. This is the known trade-off.
- In data warehouse interviews, BCNF rarely comes up. It matters more in OLTP / database theory interviews. Know the concept, know the classic example, don't over-engineer.
- Most practical 3NF schemas are already BCNF compliant. BCNF violations only appear when you have multiple overlapping candidate keys.

---

## 5. Denormalization

**What it solves:** Deliberately reintroduces redundancy to improve read performance. Used when normalized schemas are too slow to query at scale.

> **Keywords to spot:** "read performance", "too many joins", "flatten", "pre-join", "analytical workload", "reporting table", "wide table", "materialized"

**Business Context:**
- **E-commerce:** Flatten order + customer + product into a single `orders_enriched` table so BI tools don't need 5-way joins
- **SaaS:** Pre-join subscription + plan + account into one table for dashboard queries
- **Fintech:** Combine transaction + account + customer into a reporting table refreshed nightly
- **Healthcare:** Pre-aggregate patient encounter data with demographics for population health dashboards

**Base — normalized (3NF):**

```sql
create table orders (order_id int primary key, customer_id int, order_date date, total decimal(12,2));
create table customers (customer_id int primary key, name varchar(200), city varchar(100), segment varchar(50));
create table order_items (order_id int, product_id int, qty int, unit_price decimal(10,2));
create table products (product_id int primary key, name varchar(200), category varchar(100));
```

**Denormalized — analytical reporting table:**

```sql
create table orders_enriched (
    order_id            int,
    order_date          date,
    order_total         decimal(12,2),
    customer_id         int,
    customer_name       varchar(200),
    customer_city       varchar(100),
    customer_segment    varchar(50),
    product_id          int,
    product_name        varchar(200),
    product_category    varchar(100),
    line_qty            int,
    line_revenue        decimal(12,2)
    -- grain: one row per order line item
);
```

**Gotchas:**
- Denormalization is a deliberate, documented choice — not a mistake. Always note the grain and which source tables it's derived from.
- Update anomalies return. If a customer's segment changes, every row for that customer in the denormalized table is stale until the next load. Your pipeline must handle this.
- Don't denormalize prematurely. Normalize first, measure query performance, then denormalize the specific joins that are bottlenecks.
- Denormalization ≠ the same as OBT. OBT (Section 14) is an extreme form — one row per entity with all attributes. Denormalization is a spectrum.
