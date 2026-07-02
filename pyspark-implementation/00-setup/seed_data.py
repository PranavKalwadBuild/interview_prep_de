"""
00-setup/seed_data.py
Creates all 9 DataFrames from hardcoded Python data.
Same domain + same intentional flaws as sql-implementation/.

FLAW SUMMARY
------------
employees   emp 10  : salary=None  (contractor, no payroll)
employees   emp 15  : salary=None  (new hire, pending)
employees   emp 19  : salary=0.0   (soft-dup of emp 18, data entry)
employees   emp 22  : email=None   (data entry gap)
employees   emp 35  : status='Terminated', termination_date set
employees   emp 41  : hire_date=date(2025,8,1) — future date
salary_hist emp 5   : duplicate row on 2022-04-01 (same values, twice)
projects    proj 11 : end_date < start_date
projects    proj 7  : budget=None
proj_assign emp9/p9 : exact duplicate row
purch_ord   ord 19,20: exact duplicate rows
purch_ord   ord 25  : dept_id=None (orphaned)
leave_req   req 1,2 : overlapping for emp 12
leave_req   req 11  : leave_type=None
"""

from datetime import date, datetime
from pyspark.sql import SparkSession, DataFrame
from pyspark.sql.types import (
    StructType, StructField,
    IntegerType, LongType, StringType, DoubleType, DateType, TimestampType,
)


# ── Schemas ────────────────────────────────────────────────────────────────────

DEPT_SCHEMA = StructType([
    StructField("dept_id",    IntegerType(), False),
    StructField("dept_name",  StringType(),  False),
    StructField("location",   StringType(),  True),
    StructField("budget",     DoubleType(),  True),
    StructField("manager_id", IntegerType(), True),
])

EMP_SCHEMA = StructType([
    StructField("emp_id",           IntegerType(), False),
    StructField("first_name",       StringType(),  False),
    StructField("last_name",        StringType(),  False),
    StructField("email",            StringType(),  True),
    StructField("phone",            StringType(),  True),
    StructField("dept_id",          IntegerType(), True),
    StructField("manager_id",       IntegerType(), True),
    StructField("job_title",        StringType(),  True),
    StructField("hire_date",        DateType(),    False),
    StructField("salary",           DoubleType(),  True),
    StructField("status",           StringType(),  False),
    StructField("termination_date", DateType(),    True),
])

SAL_HIST_SCHEMA = StructType([
    StructField("hist_id",        IntegerType(), False),
    StructField("emp_id",         IntegerType(), False),
    StructField("salary_before",  DoubleType(),  True),
    StructField("salary_after",   DoubleType(),  False),
    StructField("effective_date", DateType(),    False),
    StructField("change_reason",  StringType(),  True),
    StructField("changed_by",     IntegerType(), True),
])

PROJECT_SCHEMA = StructType([
    StructField("project_id",   IntegerType(), False),
    StructField("project_name", StringType(),  False),
    StructField("dept_id",      IntegerType(), True),
    StructField("start_date",   DateType(),    False),
    StructField("end_date",     DateType(),    True),
    StructField("budget",       DoubleType(),  True),
    StructField("status",       StringType(),  False),
])

PROJ_ASSIGN_SCHEMA = StructType([
    StructField("assignment_id", IntegerType(), False),
    StructField("emp_id",        IntegerType(), False),
    StructField("project_id",    IntegerType(), False),
    StructField("role",          StringType(),  True),
    StructField("start_date",    DateType(),    True),
    StructField("end_date",      DateType(),    True),
    StructField("hours_billed",  DoubleType(),  True),
])

PERF_REVIEW_SCHEMA = StructType([
    StructField("review_id",     IntegerType(), False),
    StructField("emp_id",        IntegerType(), False),
    StructField("reviewer_id",   IntegerType(), True),
    StructField("review_date",   DateType(),    False),
    StructField("review_period", StringType(),  False),
    StructField("rating",        IntegerType(), True),
    StructField("comments",      StringType(),  True),
])

EMP_EVENTS_SCHEMA = StructType([
    StructField("event_id",   LongType(),      False),
    StructField("emp_id",     IntegerType(),   False),
    StructField("event_type", StringType(),    False),
    StructField("event_ts",   TimestampType(), False),
    StructField("page",       StringType(),    True),
    StructField("session_id", StringType(),    True),
])

PURCHASE_ORDER_SCHEMA = StructType([
    StructField("order_id",      IntegerType(), False),
    StructField("dept_id",       IntegerType(), True),
    StructField("vendor",        StringType(),  True),
    StructField("item_category", StringType(),  True),
    StructField("amount",        DoubleType(),  True),
    StructField("order_date",    DateType(),    False),
    StructField("status",        StringType(),  False),
])

LEAVE_REQ_SCHEMA = StructType([
    StructField("request_id", IntegerType(), False),
    StructField("emp_id",     IntegerType(), False),
    StructField("leave_type", StringType(),  True),
    StructField("start_date", DateType(),    False),
    StructField("end_date",   DateType(),    False),
    StructField("status",     StringType(),  False),
])


# ── Raw data ───────────────────────────────────────────────────────────────────

_DEPARTMENTS = [
    (1, "Engineering",  "San Francisco", 5000000.0, None),   # manager set after emp insert
    (2, "Sales",        "New York",      3000000.0, None),
    (3, "Finance",      "Chicago",       2000000.0, None),
    (4, "Marketing",    "Austin",        1500000.0, None),
    (5, "HR",           "San Francisco",  800000.0, None),
    (6, "Legal",        "New York",      1200000.0, None),
    (7, "Product",      "San Francisco", 2500000.0, None),
    (8, "Executive",    "San Francisco",      None, None),   # FLAW: NULL budget
]

_EMPLOYEES = [
    # (emp_id, first, last, email, phone, dept_id, manager_id, job_title, hire_date, salary, status, term_date)
    # Level 0
    (1,  "James",     "Wilson",   "j.wilson@corp.com",   "415-555-0101", 8, None, "Chief Executive Officer",   date(2015,3,1),  350000.0, "Active",     None),
    # Level 1
    (2,  "Sarah",     "Chen",     "s.chen@corp.com",     "415-555-0102", 1, 1,    "Chief Technology Officer",  date(2016,6,15), 280000.0, "Active",     None),
    (3,  "Carol",     "White",    "c.white@corp.com",    "212-555-0103", 2, 1,    "VP Sales",                  date(2016,1,20), 220000.0, "Active",     None),
    (4,  "David",     "Kim",      "d.kim@corp.com",      "312-555-0104", 3, 1,    "VP Finance",                date(2015,7,15), 230000.0, "Active",     None),
    (29, "Chloe",     "Nguyen",   "c.nguyen@corp.com",   "512-555-0129", 4, 1,    "Marketing Director",        date(2016,9,19), 200000.0, "Active",     None),
    (33, "Gina",      "Stewart",  "g.stewart@corp.com",  "415-555-0133", 5, 1,    "HR Director",               date(2015,11,30),185000.0, "Active",     None),
    (36, "Jake",      "Evans",    "j.evans@corp.com",    "212-555-0136", 6, 1,    "General Counsel",           date(2017,3,7),  250000.0, "Active",     None),
    (39, "Maria",     "Torres",   "m.torres@corp.com",   "415-555-0139", 7, 1,    "Product Director",          date(2016,4,25), 215000.0, "Active",     None),
    (41, "Riley",     "Scott",    "r.scott@corp.com",    "415-555-0141", 8, 1,    "Chief of Staff",            date(2025,8,1),  180000.0, "Active",     None),  # FLAW: future hire_date
    # Level 2
    (5,  "Emma",      "Davis",    "e.davis@corp.com",    "415-555-0105", 1, 2,    "Senior Software Engineer",  date(2018,9,10), 145000.0, "Active",     None),
    (6,  "Frank",     "Brown",    "f.brown@corp.com",    "415-555-0106", 1, 2,    "Software Engineer",         date(2019,4,22), 110000.0, "Active",     None),
    (7,  "Grace",     "Wilson",   "g.wilson@corp.com",   "415-555-0107", 1, 2,    "Senior Software Engineer",  date(2017,11,5), 155000.0, "Active",     None),
    (8,  "Henry",     "Moore",    "h.moore@corp.com",    "415-555-0108", 1, 2,    "DevOps Engineer",           date(2020,1,15), 125000.0, "Active",     None),
    (9,  "Iris",      "Taylor",   "i.taylor@corp.com",   "415-555-0109", 1, 2,    "Data Engineer",             date(2021,3,30), 120000.0, "Active",     None),
    (10, "Jack",      "Anderson", None,                  "415-555-0110", 1, 2,    "Senior Data Scientist",     date(2022,8,1),     None, "Active",     None),  # FLAW: NULL salary
    (18, "Rachel",    "Clark",    "r.clark@corp.com",    "212-555-0118", 2, 3,    "Regional Sales Lead",       date(2017,8,14), 115000.0, "Active",     None),
    (19, "Samuel",    "Clark",    "s.clark@corp.com",    "212-555-0119", 2, 3,    "Regional Sales Lead",       date(2017,8,14),      0.0, "Active",     None),  # FLAW: 0.0 salary, soft-dup of 18
    (20, "Tom",       "Lewis",    "t.lewis@corp.com",    "212-555-0120", 2, 3,    "Sales Manager",             date(2018,3,12), 135000.0, "Active",     None),
    (25, "Anna",      "Parker",   "a.parker@corp.com",   "312-555-0125", 3, 4,    "Finance Manager",           date(2017,5,3),  130000.0, "Active",     None),
    (30, "Dan",       "Rivera",   "d.rivera@corp.com",   "512-555-0130", 4, 29,   "Marketing Manager",         date(2018,10,8), 125000.0, "Active",     None),
    (34, "Harry",     "Gonzalez", "h.gonzalez@corp.com", "415-555-0134", 5, 33,   "HR Generalist",             date(2019,6,17),  85000.0, "Active",     None),
    (35, "Irene",     "Nelson",   "i.nelson@corp.com",   "415-555-0135", 5, 33,   "HR Coordinator",            date(2020,2,24),  68000.0, "Terminated", date(2024,3,31)),  # FLAW: terminated
    (37, "Karen",     "Edwards",  "k.edwards@corp.com",  "212-555-0137", 6, 36,   "Senior Counsel",            date(2019,1,22), 175000.0, "Active",     None),
    (40, "Nathan",    "Brown",    "n.brown@corp.com",    "415-555-0140", 7, 39,   "Product Manager",           date(2019,9,30), 140000.0, "Active",     None),
    # Level 3
    (11, "Karen",     "Thomas",   "k.thomas@corp.com",   "415-555-0111", 1, 5,    "Software Engineer",         date(2022,1,10), 108000.0, "Active",     None),
    (12, "Liam",      "Jackson",  "l.jackson@corp.com",  "415-555-0112", 1, 5,    "Software Engineer",         date(2023,5,15),  95000.0, "Active",     None),
    (13, "Mia",       "White",    "m.white@corp.com",    "415-555-0113", 1, 6,    "Junior Software Engineer",  date(2023,9,1),   85000.0, "Active",     None),
    (14, "Noah",      "Harris",   "n.harris@corp.com",   "415-555-0114", 1, 8,    "Site Reliability Engineer", date(2021,7,19), 135000.0, "Active",     None),
    (15, "Olivia",    "Martin",   "o.martin@corp.com",   "415-555-0115", 1, 9,    "Data Analyst",              date(2024,1,8),      None, "Active",     None),  # FLAW: NULL salary
    (16, "Peter",     "Martinez", "p.martinez@corp.com", "415-555-0116", 1, 7,    "Backend Engineer",          date(2020,6,1),  122000.0, "Active",     None),
    (17, "Quinn",     "Robinson", "q.robinson@corp.com", "415-555-0117", 1, 7,    "Frontend Engineer",         date(2021,10,25),115000.0, "Active",     None),
    (21, "Uma",       "Clark",    "u.clark@corp.com",    "212-555-0121", 2, 20,   "Sales Representative",      date(2020,7,6),   75000.0, "Active",     None),
    (22, "Victor",    "Lee",      None,                  "212-555-0122", 2, 20,   "Senior Sales Representative",date(2019,11,18), 95000.0,"Active",     None),  # FLAW: NULL email
    (23, "Wendy",     "Hall",     "w.hall@corp.com",     "212-555-0123", 2, 20,   "Sales Representative",      date(2021,2,28),  72000.0, "Active",     None),
    (24, "Xander",    "Young",    "x.young@corp.com",    "212-555-0124", 2, 20,   "Account Executive",         date(2022,5,16),  88000.0, "Active",     None),
    (26, "Brian",     "Collins",  "b.collins@corp.com",  "312-555-0126", 3, 25,   "Financial Analyst",         date(2019,8,26),  90000.0, "Active",     None),
    (27, "Christine", "Hughes",   "c.hughes@corp.com",   "312-555-0127", 3, 25,   "Senior Financial Analyst",  date(2018,2,14), 105000.0, "Active",     None),
    (28, "Derek",     "Foster",   "d.foster@corp.com",   "312-555-0128", 3, 25,   "Accounting Specialist",     date(2021,4,5),   82000.0, "Active",     None),
    (31, "Eva",       "Campbell", "e.campbell@corp.com", "512-555-0131", 4, 30,   "Content Specialist",        date(2021,6,14),  78000.0, "Active",     None),
    (32, "Fred",      "Mitchell", "f.mitchell@corp.com", "512-555-0132", 4, 30,   "Digital Marketing Analyst", date(2022,3,21),  80000.0, "Active",     None),
    (38, "Leo",       "Collins",  "l.collins@corp.com",  "212-555-0138", 6, 37,   "Legal Analyst",             date(2022,7,11),  90000.0, "Active",     None),
]

_SALARY_HISTORY = [
    # (hist_id, emp_id, salary_before, salary_after, effective_date, change_reason, changed_by)
    (1,  1,  None,      300000.0, date(2015,3,1),   "Initial hire",  33),
    (2,  1,  300000.0,  320000.0, date(2017,1,1),   "Annual review",  1),
    (3,  1,  320000.0,  350000.0, date(2020,1,1),   "Annual review",  1),
    (4,  2,  None,      240000.0, date(2016,6,15),  "Initial hire",   1),
    (5,  2,  240000.0,  265000.0, date(2019,1,1),   "Annual review",  1),
    (6,  2,  265000.0,  280000.0, date(2022,1,1),   "Annual review",  1),
    (7,  3,  None,      195000.0, date(2016,1,20),  "Initial hire",   1),
    (8,  3,  195000.0,  210000.0, date(2019,1,1),   "Annual review",  1),
    (9,  3,  210000.0,  220000.0, date(2022,1,1),   "Annual review",  1),
    (10, 4,  None,      210000.0, date(2015,7,15),  "Initial hire",   1),
    (11, 4,  210000.0,  225000.0, date(2018,1,1),   "Annual review",  1),
    (12, 4,  225000.0,  230000.0, date(2022,1,1),   "Annual review",  1),
    (13, 5,  None,      120000.0, date(2018,9,10),  "Initial hire",   2),
    (14, 5,  120000.0,  132000.0, date(2020,1,1),   "Annual review",  2),
    (15, 5,  132000.0,  145000.0, date(2022,4,1),   "Promotion",      2),  # clean
    (16, 5,  132000.0,  145000.0, date(2022,4,1),   "Promotion",      2),  # FLAW: exact duplicate of row 15
    (17, 7,  None,      135000.0, date(2017,11,5),  "Initial hire",   2),
    (18, 7,  135000.0,  148000.0, date(2019,6,1),   "Annual review",  2),
    (19, 7,  148000.0,  155000.0, date(2022,1,1),   "Annual review",  2),
    (20, 9,  None,      110000.0, date(2021,3,30),  "Initial hire",   2),
    (21, 9,  110000.0,  120000.0, date(2023,1,1),   "Annual review",  2),
    (22, 18, None,      100000.0, date(2017,8,14),  "Initial hire",   3),
    (23, 18, 100000.0,  115000.0, date(2021,1,1),   "Annual review",  3),
    (24, 20, None,      118000.0, date(2018,3,12),  "Initial hire",   3),
    (25, 20, 118000.0,  135000.0, date(2022,1,1),   "Promotion",      3),
    (26, 25, None,      115000.0, date(2017,5,3),   "Initial hire",   4),
    (27, 25, 115000.0,  130000.0, date(2021,1,1),   "Annual review",  4),
    (28, 29, None,      175000.0, date(2016,9,19),  "Initial hire",   1),
    (29, 29, 175000.0,  200000.0, date(2021,1,1),   "Annual review",  1),
    (30, 36, None,      220000.0, date(2017,3,7),   "Initial hire",   1),
    (31, 36, 220000.0,  250000.0, date(2022,1,1),   "Annual review",  1),
    (32, 39, None,      190000.0, date(2016,4,25),  "Initial hire",   1),
    (33, 39, 190000.0,  215000.0, date(2021,1,1),   "Annual review",  1),
]

_PROJECTS = [
    # (project_id, project_name, dept_id, start_date, end_date, budget, status)
    (1,  "Phoenix ERP Migration",      3, date(2022,6,1),  date(2023,12,31), 1500000.0, "Completed"),
    (2,  "Mobile App v3.0",            1, date(2023,1,15), None,              800000.0, "Active"),
    (3,  "Sales Pipeline Automation",  2, date(2023,4,1),  date(2024,3,31),   450000.0, "Completed"),
    (4,  "Data Lake Infrastructure",   1, date(2023,7,1),  None,             1200000.0, "Active"),
    (5,  "Brand Refresh",              4, date(2024,1,1),  date(2024,6,30),   300000.0, "Completed"),
    (6,  "HR Self-Service Portal",     5, date(2023,9,1),  date(2024,5,31),   250000.0, "Completed"),
    (7,  "Cloud Security Audit",       6, date(2024,2,1),  None,                  None, "Active"),    # FLAW: NULL budget
    (8,  "Customer Success Platform",  2, date(2024,3,1),  None,              600000.0, "Active"),
    (9,  "Analytics Dashboard",        1, date(2023,11,1), date(2024,10,31),  350000.0, "Active"),
    (10, "Compliance Framework",       6, date(2024,1,15), date(2024,12,31),  200000.0, "Active"),
    (11, "Product Roadmap 2025",       7, date(2024,6,1),  date(2024,2,28),   150000.0, "Planning"), # FLAW: end < start
    (12, "Onboarding Automation",      5, date(2023,3,1),  date(2023,10,31),  120000.0, "Completed"),
]

_PROJECT_ASSIGNMENTS = [
    # (assignment_id, emp_id, project_id, role, start_date, end_date, hours_billed)
    (1,  5,  2, "Senior Engineer",  date(2023,1,15), None,            480.0),
    (2,  6,  2, "Engineer",         date(2023,1,15), None,            320.0),
    (3,  7,  2, "Senior Engineer",  date(2023,2,1),  None,            560.0),
    (4,  9,  4, "Data Engineer Lead",date(2023,7,1), None,            None),   # FLAW: NULL hours_billed
    (5,  10, 4, "Data Scientist",   date(2023,9,1),  None,            None),   # FLAW: NULL hours_billed
    (6,  14, 4, "SRE",              date(2023,7,1),  None,            240.0),
    (7,  2,  9, "CTO Sponsor",      date(2023,11,1), None,             80.0),
    (8,  5,  9, "Tech Lead",        date(2023,11,1), None,            None),   # FLAW: NULL hours_billed
    (9,  8,  9, "DevOps",           date(2023,11,15),None,            160.0),
    (10, 4,  1, "Exec Sponsor",     date(2022,6,1),  date(2023,12,31),120.0),
    (11, 25, 1, "Finance Lead",     date(2022,6,1),  date(2023,12,31),380.0),
    (12, 5,  1, "Tech Advisor",     date(2022,8,1),  date(2023,12,31),200.0),
    (13, 20, 3, "Sales Lead",       date(2023,4,1),  date(2024,3,31), 340.0),
    (14, 18, 3, "Sales Rep",        date(2023,4,1),  date(2024,3,31), 280.0),
    (15, 21, 3, "Sales Rep",        date(2023,4,1),  date(2024,3,31), 260.0),
    (16, 29, 5, "Dir Sponsor",      date(2024,1,1),  date(2024,6,30),  60.0),
    (17, 30, 5, "Marketing Lead",   date(2024,1,1),  date(2024,6,30), 320.0),
    (18, 31, 5, "Content Lead",     date(2024,1,1),  date(2024,6,30), 280.0),
    (19, 33, 6, "Exec Sponsor",     date(2023,9,1),  date(2024,5,31),  80.0),
    (20, 34, 6, "HR Lead",          date(2023,9,1),  date(2024,5,31), 420.0),
    (21, 37, 7, "Legal Lead",       date(2024,2,1),  None,            160.0),
    (22, 38, 7, "Legal Analyst",    date(2024,2,1),  None,            200.0),
    (23, 39,11, "Dir Sponsor",      date(2024,6,1),  None,             40.0),
    (24, 40,11, "Product Lead",     date(2024,6,1),  None,            None),   # FLAW: NULL hours_billed
    (25, 9,  9, "Data Engineer",    date(2023,11,1), None,            300.0),  # clean
    (26, 9,  9, "Data Engineer",    date(2023,11,1), None,            300.0),  # FLAW: exact duplicate of row 25
]

_PERFORMANCE_REVIEWS = [
    # (review_id, emp_id, reviewer_id, review_date, review_period, rating, comments)
    (1,  2,  1,    date(2024,1,20),  "2023-H2", 5, "Exceptional technical leadership."),
    (2,  3,  1,    date(2024,1,20),  "2023-H2", 4, "Strong sales results, exceeded targets."),
    (3,  5,  2,    date(2023,7,15),  "2023-H1", 4, "Strong performance across all metrics."),
    (4,  5,  2,    date(2024,1,20),  "2023-H2", 5, "Outstanding year, promotion warranted."),
    (5,  5,  None, date(2024,7,20),  "2024-H1", None, "Pending submission."),     # FLAW: NULL reviewer + NULL rating
    (6,  6,  5,    date(2023,7,15),  "2023-H1", 3, "Meets expectations."),
    (7,  6,  5,    date(2024,1,20),  "2023-H2", 3, "Meets expectations. Areas to grow."),
    (8,  7,  2,    date(2023,7,15),  "2023-H1", 4, "Above expectations on architecture."),
    (9,  7,  2,    date(2024,1,20),  "2023-H2", None, "Review not completed by reviewer."),  # FLAW: NULL rating
    (10, 9,  2,    date(2023,7,15),  "2023-H1", 4, "Excellent data pipeline work."),
    (11, 9,  2,    date(2024,1,20),  "2023-H2", 5, "Exceptional — key contributor to data lake."),
    (12, 11, 5,    date(2024,1,20),  "2023-H2", 3, "Good progress since joining."),
    (13, 12, 5,    date(2024,1,20),  "2023-H2", 2, "Needs improvement in delivery."),
    (14, 20, 3,    date(2023,7,15),  "2023-H1", 4, "Sales targets exceeded by 12%."),
    (15, 20, 3,    date(2024,1,20),  "2023-H2", 4, "Consistent performer."),
    (16, 21, 20,   date(2024,1,20),  "2023-H2", 3, "Good first full year."),
    (17, 25, 4,    date(2023,7,15),  "2023-H1", 5, "Excellent FP&A skills."),
    (18, 25, 4,    date(2024,1,20),  "2023-H2", 4, "Strong performance."),
    (19, 30, 29,   date(2024,1,20),  "2023-H2", 4, "Creative campaigns."),
    (20, 33, 1,    date(2024,1,20),  "2023-H2", 4, "Excellent HR leadership."),
]

_EMP_EVENTS = [
    # (event_id, emp_id, event_type, event_ts, page, session_id)
    # emp 9 — two sessions same day
    (1,  9,  "login",          datetime(2024,1,15,9,0,0),   "/login",   "sess-9A"),
    (2,  9,  "view_payslip",   datetime(2024,1,15,9,5,30),  "/payslip", "sess-9A"),
    (3,  9,  "update_profile", datetime(2024,1,15,9,12,45), "/profile", "sess-9A"),
    (4,  9,  "logout",         datetime(2024,1,15,9,18,0),  "/logout",  "sess-9A"),
    (5,  9,  "login",          datetime(2024,1,15,11,2,0),  "/login",   "sess-9B"),  # 104-min gap
    (6,  9,  "submit_leave",   datetime(2024,1,15,11,8,0),  "/leave",   "sess-9B"),  # FLAW: no logout
    # emp 5 — complete funnel, two sessions
    (7,  5,  "login",          datetime(2024,1,15,10,0,0),  "/login",   "sess-5A"),
    (8,  5,  "view_payslip",   datetime(2024,1,15,10,4,0),  "/payslip", "sess-5A"),
    (9,  5,  "update_profile", datetime(2024,1,15,10,9,0),  "/profile", "sess-5A"),
    (10, 5,  "submit_leave",   datetime(2024,1,15,10,14,0), "/leave",   "sess-5A"),
    (11, 5,  "logout",         datetime(2024,1,15,10,20,0), "/logout",  "sess-5A"),
    (12, 5,  "login",          datetime(2024,1,15,14,0,0),  "/login",   "sess-5B"),
    (13, 5,  "approve_leave",  datetime(2024,1,15,14,5,0),  "/approve", "sess-5B"),
    (14, 5,  "logout",         datetime(2024,1,15,14,9,0),  "/logout",  "sess-5B"),
    # emp 6 — drops at step 2
    (15, 6,  "login",          datetime(2024,1,15,10,30,0), "/login",   "sess-6A"),
    (16, 6,  "view_payslip",   datetime(2024,1,15,10,35,0), "/payslip", "sess-6A"),
    (17, 6,  "logout",         datetime(2024,1,15,10,41,0), "/logout",  "sess-6A"),
    # emp 7 — drops at step 3
    (18, 7,  "login",          datetime(2024,1,16,14,0,0),  "/login",   "sess-7A"),
    (19, 7,  "view_payslip",   datetime(2024,1,16,14,6,0),  "/payslip", "sess-7A"),
    (20, 7,  "update_profile", datetime(2024,1,16,14,11,0), "/profile", "sess-7A"),  # FLAW: no logout
    # emp 8 — complete funnel
    (21, 8,  "login",          datetime(2024,1,16,15,0,0),  "/login",   "sess-8A"),
    (22, 8,  "view_payslip",   datetime(2024,1,16,15,3,0),  "/payslip", "sess-8A"),
    (23, 8,  "update_profile", datetime(2024,1,16,15,8,0),  "/profile", "sess-8A"),
    (24, 8,  "submit_leave",   datetime(2024,1,16,15,14,0), "/leave",   "sess-8A"),
    (25, 8,  "logout",         datetime(2024,1,16,15,21,0), "/logout",  "sess-8A"),
    # emp 12 — two sessions
    (26, 12, "login",          datetime(2024,2,5,8,45,0),   "/login",   "sess-12A"),
    (27, 12, "view_payslip",   datetime(2024,2,5,8,50,0),   "/payslip", "sess-12A"),
    (28, 12, "logout",         datetime(2024,2,5,8,57,0),   "/logout",  "sess-12A"),
    (29, 12, "login",          datetime(2024,2,5,13,30,0),  "/login",   "sess-12B"),
    (30, 12, "submit_leave",   datetime(2024,2,5,13,35,0),  "/leave",   "sess-12B"),
    (31, 12, "logout",         datetime(2024,2,5,13,40,0),  "/logout",  "sess-12B"),
    # emp 14 — NULL session_id (untracked device)
    (32, 14, "login",          datetime(2024,3,10,9,0,0),   "/login",   None),  # FLAW: NULL session_id
    (33, 14, "update_profile", datetime(2024,3,10,9,22,0),  "/profile", None),  # FLAW
    (34, 14, "submit_leave",   datetime(2024,3,10,9,45,0),  "/leave",   None),  # FLAW
    # emp 20 — approve_leave action
    (35, 20, "login",          datetime(2024,2,20,11,0,0),  "/login",   "sess-20A"),
    (36, 20, "approve_leave",  datetime(2024,2,20,11,3,0),  "/approve", "sess-20A"),
    (37, 20, "logout",         datetime(2024,2,20,11,7,0),  "/logout",  "sess-20A"),
    # emp 25 — quick payslip check
    (38, 25, "login",          datetime(2024,3,15,16,30,0), "/login",   "sess-25A"),
    (39, 25, "view_payslip",   datetime(2024,3,15,16,34,0), "/payslip", "sess-25A"),
    (40, 25, "logout",         datetime(2024,3,15,16,39,0), "/logout",  "sess-25A"),
]

_PURCHASE_ORDERS = [
    # (order_id, dept_id, vendor, item_category, amount, order_date, status)
    (1,  1, "TechSoft Inc", "Software",       45000.0, date(2024,1,10), "Approved"),
    (2,  1, "HardwarePlus", "Hardware",       28000.0, date(2024,1,10), "Approved"),
    (3,  1, "CloudCo",      "Cloud Services", 65000.0, date(2024,1,10), "Approved"),
    (4,  1, "LearnFast",    "Training",        8500.0, date(2024,2,15), "Approved"),
    (5,  1, "TechSoft Inc", "Software",       52000.0, date(2024,3,20), "Approved"),
    (6,  1, "CloudCo",      "Cloud Services", 71000.0, date(2024,3,20), "Approved"),
    (7,  1, "ConsuLead",    "Consulting",     90000.0, date(2024,4,10), "Approved"),
    (8,  2, "LearnFast",    "Training",       12000.0, date(2024,1,20), "Approved"),
    (9,  2, "TravelEase",   "Travel",          9500.0, date(2024,1,20), "Approved"),
    (10, 2, "LearnFast",    "Training",       14000.0, date(2024,4,5),  "Approved"),
    (11, 2, "TravelEase",   "Travel",         15000.0, date(2024,5,1),  "Approved"),
    (12, 3, "TechSoft Inc", "Software",       32000.0, date(2024,2,1),  "Approved"),
    (13, 3, "ConsuLead",    "Consulting",     40000.0, date(2024,2,1),  "Approved"),
    (14, 3, "LearnFast",    "Training",        6000.0, date(2024,2,1),  "Approved"),
    (15, 3, "OfficeWorld",  "Office Supplies", 1800.0, date(2024,5,15), "Approved"),
    (16, 4, "TechSoft Inc", "Software",       18000.0, date(2024,1,25), "Approved"),
    (17, 4, "LearnFast",    "Training",        7500.0, date(2024,1,25), "Approved"),
    (18, 4, "ConsuLead",    "Consulting",     25000.0, date(2024,1,25), "Approved"),
    (19, 5, "LearnFast",    "Training",        5500.0, date(2024,3,1),  "Approved"),  # clean
    (20, 5, "LearnFast",    "Training",        5500.0, date(2024,3,1),  "Approved"),  # FLAW: exact dup of 19
    (21, 5, "OfficeWorld",  "Office Supplies", 1200.0, date(2024,3,1),  "Approved"),
    (22, 6, "LexisNexis",   "Legal Services", 85000.0, date(2024,2,10), "Approved"),
    (23, 6, "ConsuLead",    "Consulting",     35000.0, date(2024,2,10), "Approved"),
    (24, 7, "TechSoft Inc", "Software",       22000.0, date(2024,3,15), "Approved"),
    (25, None,"OfficeWorld","Office Supplies",   450.0, date(2024,4,1), "Approved"),  # FLAW: NULL dept_id
]

_LEAVE_REQUESTS = [
    # (request_id, emp_id, leave_type, start_date, end_date, status)
    (1,  12, "Annual Leave",  date(2024,4,10), date(2024,4,17), "Approved"),   # clean
    (2,  12, "Annual Leave",  date(2024,4,15), date(2024,4,22), "Approved"),   # FLAW: overlaps Apr 15-17 with req 1
    (3,  5,  "Sick Leave",    date(2024,1,15), date(2024,1,17), "Approved"),
    (4,  5,  "Sick Leave",    date(2024,1,18), date(2024,1,19), "Approved"),   # consecutive with req 3 → same island
    (5,  5,  "Annual Leave",  date(2024,3,5),  date(2024,3,8),  "Approved"),   # gap → separate island
    (6,  7,  "Annual Leave",  date(2024,2,1),  date(2024,2,5),  "Approved"),
    (7,  7,  "Annual Leave",  date(2024,2,8),  date(2024,2,12), "Approved"),   # Feb 6-7 gap → separate island
    (8,  9,  "Parental Leave",date(2024,5,1),  date(2024,5,31), "Approved"),
    (9,  16, "Annual Leave",  date(2023,12,27),date(2023,12,31),"Approved"),
    (10, 16, "Annual Leave",  date(2024,1,2),  date(2024,1,5),  "Approved"),   # Jan 1 gap → separate island
    (11, 34, None,            date(2024,7,15), date(2024,7,19), "Approved"),   # FLAW: NULL leave_type
    (12, 20, "Annual Leave",  date(2024,8,5),  date(2024,8,9),  "Approved"),
    (13, 27, "Sick Leave",    date(2024,3,20), date(2024,3,21), "Approved"),
    (14, 27, "Annual Leave",  date(2024,6,10), date(2024,6,14), "Approved"),
    (15, 26, "Annual Leave",  date(2024,9,2),  date(2024,9,6),  "Approved"),
    (16, 11, "Annual Leave",  date(2024,7,22), date(2024,7,26), "Approved"),
    (17, 6,  "Sick Leave",    date(2024,5,13), date(2024,5,14), "Approved"),
    (18, 6,  "Sick Leave",    date(2024,5,15), date(2024,5,15), "Approved"),   # consecutive with req 17 → same island
    (19, 25, "Annual Leave",  date(2024,10,7), date(2024,10,11),"Approved"),
    (20, 32, "Annual Leave",  date(2024,11,25),date(2024,11,29),"Pending"),
]


# ── DataFrame factories ────────────────────────────────────────────────────────

def create_departments_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_DEPARTMENTS, schema=DEPT_SCHEMA)

def create_employees_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_EMPLOYEES, schema=EMP_SCHEMA)

def create_salary_history_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_SALARY_HISTORY, schema=SAL_HIST_SCHEMA)

def create_projects_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_PROJECTS, schema=PROJECT_SCHEMA)

def create_project_assignments_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_PROJECT_ASSIGNMENTS, schema=PROJ_ASSIGN_SCHEMA)

def create_performance_reviews_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_PERFORMANCE_REVIEWS, schema=PERF_REVIEW_SCHEMA)

def create_emp_events_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_EMP_EVENTS, schema=EMP_EVENTS_SCHEMA)

def create_purchase_orders_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_PURCHASE_ORDERS, schema=PURCHASE_ORDER_SCHEMA)

def create_leave_requests_df(spark: SparkSession) -> DataFrame:
    return spark.createDataFrame(_LEAVE_REQUESTS, schema=LEAVE_REQ_SCHEMA)


def load_all(spark: SparkSession) -> dict:
    """
    Create all 9 DataFrames and return as a dict.

    Returns
    -------
    dict with keys:
        departments, employees, salary_history, projects,
        project_assignments, performance_reviews,
        emp_events, purchase_orders, leave_requests
    """
    return {
        "departments":         create_departments_df(spark),
        "employees":           create_employees_df(spark),
        "salary_history":      create_salary_history_df(spark),
        "projects":            create_projects_df(spark),
        "project_assignments": create_project_assignments_df(spark),
        "performance_reviews": create_performance_reviews_df(spark),
        "emp_events":          create_emp_events_df(spark),
        "purchase_orders":     create_purchase_orders_df(spark),
        "leave_requests":      create_leave_requests_df(spark),
    }


def register_views(spark: SparkSession) -> dict:
    """
    Create all DataFrames AND register them as Spark SQL temp views.
    Enables spark.sql("SELECT ...") in any pattern script.
    Returns the same dict as load_all().
    """
    dfs = load_all(spark)
    for name, df in dfs.items():
        df.createOrReplaceTempView(name)
    print(f"  Registered {len(dfs)} temp views: {', '.join(dfs.keys())}")
    return dfs
