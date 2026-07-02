-- ============================================================
-- sql-implementation/00-setup/02-seed-data.sql
-- Inserts seed data into all 9 tables.
-- Run AFTER 01-database-and-schema.sql
-- ============================================================
--
-- FLAW LOCATIONS (quick reference):
--   employees  row 10  : salary = NULL  (contractor, no payroll)
--   employees  row 15  : salary = NULL  (new hire, pending)
--   employees  row 19  : salary = 0.00  (soft dup of row 18, data entry)
--   employees  row 22  : email  = NULL  (data entry gap)
--   employees  row 35  : status = 'Terminated', termination_date set
--   employees  row 41  : hire_date = '2025-08-01' (future, data entry error)
--   salary_history     : rows 16-17 exact duplicate (same emp/date/amounts)
--   projects   row 11  : end_date < start_date (data entry error)
--   projects   row 7   : budget = NULL
--   project_assignments: rows 24-25 exact duplicate (same emp/project/dates)
--   purchase_orders    : rows 16-17 exact duplicate
--   purchase_orders    : row 23 dept_id = NULL (orphaned order)
--   leave_requests     : rows 1-2 overlap for emp 12 (data entry error)
--   leave_requests     : row 11 leave_type = NULL
-- ============================================================

USE `sql-patterns`;

-- ── 1. departments ────────────────────────────────────────────
-- manager_id set to NULL; updated after employees are inserted.
-- FLAW: dept 8 (Executive) has NULL budget.

INSERT INTO departments (dept_id, dept_name, location, budget, manager_id) VALUES
(1, 'Engineering',   'San Francisco', 5000000.00, NULL),
(2, 'Sales',         'New York',      3000000.00, NULL),
(3, 'Finance',       'Chicago',       2000000.00, NULL),
(4, 'Marketing',     'Austin',        1500000.00, NULL),
(5, 'HR',            'San Francisco',  800000.00, NULL),
(6, 'Legal',         'New York',      1200000.00, NULL),
(7, 'Product',       'San Francisco', 2500000.00, NULL),
(8, 'Executive',     'San Francisco',       NULL, NULL); -- FLAW: NULL budget

-- ── 2. employees ──────────────────────────────────────────────
-- employees.manager_id is a self-referencing FK; must insert
-- parent before child. Disable FK checks to allow one bulk block.

SET FOREIGN_KEY_CHECKS = 0;

INSERT INTO employees
    (emp_id, first_name, last_name, email, phone,
     dept_id, manager_id, job_title, hire_date, salary,
     status, termination_date)
VALUES
-- Level 0: CEO
(1,  'James',     'Wilson',   'j.wilson@corp.com',    '415-555-0101', 8, NULL, 'Chief Executive Officer',   '2015-03-01', 350000.00, 'Active', NULL),
-- Level 1: direct reports to CEO
(2,  'Sarah',     'Chen',     's.chen@corp.com',      '415-555-0102', 1, 1,    'Chief Technology Officer',  '2016-06-15', 280000.00, 'Active', NULL),
(3,  'Carol',     'White',    'c.white@corp.com',     '212-555-0103', 2, 1,    'VP Sales',                  '2016-01-20', 220000.00, 'Active', NULL),
(4,  'David',     'Kim',      'd.kim@corp.com',       '312-555-0104', 3, 1,    'VP Finance',                '2015-07-15', 230000.00, 'Active', NULL),
(29, 'Chloe',     'Nguyen',   'c.nguyen@corp.com',    '512-555-0129', 4, 1,    'Marketing Director',        '2016-09-19', 200000.00, 'Active', NULL),
(33, 'Gina',      'Stewart',  'g.stewart@corp.com',   '415-555-0133', 5, 1,    'HR Director',               '2015-11-30', 185000.00, 'Active', NULL),
(36, 'Jake',      'Evans',    'j.evans@corp.com',     '212-555-0136', 6, 1,    'General Counsel',           '2017-03-07', 250000.00, 'Active', NULL),
(39, 'Maria',     'Torres',   'm.torres@corp.com',    '415-555-0139', 7, 1,    'Product Director',          '2016-04-25', 215000.00, 'Active', NULL),
(41, 'Riley',     'Scott',    'r.scott@corp.com',     '415-555-0141', 8, 1,    'Chief of Staff',            '2025-08-01', 180000.00, 'Active', NULL), -- FLAW: future hire_date

-- Level 2: reports to L1 managers
(5,  'Emma',      'Davis',    'e.davis@corp.com',     '415-555-0105', 1, 2,    'Senior Software Engineer',  '2018-09-10', 145000.00, 'Active', NULL),
(6,  'Frank',     'Brown',    'f.brown@corp.com',     '415-555-0106', 1, 2,    'Software Engineer',         '2019-04-22', 110000.00, 'Active', NULL),
(7,  'Grace',     'Wilson',   'g.wilson@corp.com',    '415-555-0107', 1, 2,    'Senior Software Engineer',  '2017-11-05', 155000.00, 'Active', NULL),
(8,  'Henry',     'Moore',    'h.moore@corp.com',     '415-555-0108', 1, 2,    'DevOps Engineer',           '2020-01-15', 125000.00, 'Active', NULL),
(9,  'Iris',      'Taylor',   'i.taylor@corp.com',    '415-555-0109', 1, 2,    'Data Engineer',             '2021-03-30', 120000.00, 'Active', NULL),
(10, 'Jack',      'Anderson', NULL,                   '415-555-0110', 1, 2,    'Senior Data Scientist',     '2022-08-01', NULL,      'Active', NULL), -- FLAW: NULL salary (contractor)
(18, 'Rachel',    'Clark',    'r.clark@corp.com',     '212-555-0118', 2, 3,    'Regional Sales Lead',       '2017-08-14', 115000.00, 'Active', NULL),
(19, 'Samuel',    'Clark',    's.clark@corp.com',     '212-555-0119', 2, 3,    'Regional Sales Lead',       '2017-08-14',      0.00, 'Active', NULL), -- FLAW: 0.00 salary; soft-dup of emp 18 (same dept/date/title)
(20, 'Tom',       'Lewis',    't.lewis@corp.com',     '212-555-0120', 2, 3,    'Sales Manager',             '2018-03-12', 135000.00, 'Active', NULL),
(25, 'Anna',      'Parker',   'a.parker@corp.com',    '312-555-0125', 3, 4,    'Finance Manager',           '2017-05-03', 130000.00, 'Active', NULL),
(30, 'Dan',       'Rivera',   'd.rivera@corp.com',    '512-555-0130', 4, 29,   'Marketing Manager',         '2018-10-08', 125000.00, 'Active', NULL),
(34, 'Harry',     'Gonzalez', 'h.gonzalez@corp.com',  '415-555-0134', 5, 33,   'HR Generalist',             '2019-06-17',  85000.00, 'Active', NULL),
(35, 'Irene',     'Nelson',   'i.nelson@corp.com',    '415-555-0135', 5, 33,   'HR Coordinator',            '2020-02-24',  68000.00, 'Terminated', '2024-03-31'), -- FLAW: terminated employee still in table
(37, 'Karen',     'Edwards',  'k.edwards@corp.com',   '212-555-0137', 6, 36,   'Senior Counsel',            '2019-01-22', 175000.00, 'Active', NULL),
(40, 'Nathan',    'Brown',    'n.brown@corp.com',     '415-555-0140', 7, 39,   'Product Manager',           '2019-09-30', 140000.00, 'Active', NULL),

-- Level 3: individual contributors
(11, 'Karen',     'Thomas',   'k.thomas@corp.com',    '415-555-0111', 1, 5,    'Software Engineer',         '2022-01-10', 108000.00, 'Active', NULL),
(12, 'Liam',      'Jackson',  'l.jackson@corp.com',   '415-555-0112', 1, 5,    'Software Engineer',         '2023-05-15',  95000.00, 'Active', NULL),
(13, 'Mia',       'White',    'm.white@corp.com',     '415-555-0113', 1, 6,    'Junior Software Engineer',  '2023-09-01',  85000.00, 'Active', NULL),
(14, 'Noah',      'Harris',   'n.harris@corp.com',    '415-555-0114', 1, 8,    'Site Reliability Engineer', '2021-07-19', 135000.00, 'Active', NULL),
(15, 'Olivia',    'Martin',   'o.martin@corp.com',    '415-555-0115', 1, 9,    'Data Analyst',              '2024-01-08', NULL,      'Active', NULL), -- FLAW: NULL salary (pending payroll)
(16, 'Peter',     'Martinez', 'p.martinez@corp.com',  '415-555-0116', 1, 7,    'Backend Engineer',          '2020-06-01', 122000.00, 'Active', NULL),
(17, 'Quinn',     'Robinson', 'q.robinson@corp.com',  '415-555-0117', 1, 7,    'Frontend Engineer',         '2021-10-25', 115000.00, 'Active', NULL),
(21, 'Uma',       'Clark',    'u.clark@corp.com',     '212-555-0121', 2, 20,   'Sales Representative',      '2020-07-06',  75000.00, 'Active', NULL),
(22, 'Victor',    'Lee',      NULL,                   '212-555-0122', 2, 20,   'Senior Sales Representative','2019-11-18',  95000.00, 'Active', NULL), -- FLAW: NULL email
(23, 'Wendy',     'Hall',     'w.hall@corp.com',      '212-555-0123', 2, 20,   'Sales Representative',      '2021-02-28',  72000.00, 'Active', NULL),
(24, 'Xander',    'Young',    'x.young@corp.com',     '212-555-0124', 2, 20,   'Account Executive',         '2022-05-16',  88000.00, 'Active', NULL),
(26, 'Brian',     'Collins',  'b.collins@corp.com',   '312-555-0126', 3, 25,   'Financial Analyst',         '2019-08-26',  90000.00, 'Active', NULL),
(27, 'Christine', 'Hughes',   'c.hughes@corp.com',    '312-555-0127', 3, 25,   'Senior Financial Analyst',  '2018-02-14', 105000.00, 'Active', NULL),
(28, 'Derek',     'Foster',   'd.foster@corp.com',    '312-555-0128', 3, 25,   'Accounting Specialist',     '2021-04-05',  82000.00, 'Active', NULL),
(31, 'Eva',       'Campbell', 'e.campbell@corp.com',  '512-555-0131', 4, 30,   'Content Specialist',        '2021-06-14',  78000.00, 'Active', NULL),
(32, 'Fred',      'Mitchell', 'f.mitchell@corp.com',  '512-555-0132', 4, 30,   'Digital Marketing Analyst', '2022-03-21',  80000.00, 'Active', NULL),
(38, 'Leo',       'Collins',  'l.collins@corp.com',   '212-555-0138', 6, 37,   'Legal Analyst',             '2022-07-11',  90000.00, 'Active', NULL);

SET FOREIGN_KEY_CHECKS = 1;

-- Set department managers now that employees exist.
UPDATE departments SET manager_id = 2  WHERE dept_id = 1; -- Engineering → CTO
UPDATE departments SET manager_id = 3  WHERE dept_id = 2; -- Sales → VP Sales
UPDATE departments SET manager_id = 4  WHERE dept_id = 3; -- Finance → VP Finance
UPDATE departments SET manager_id = 29 WHERE dept_id = 4; -- Marketing → Marketing Director
UPDATE departments SET manager_id = 33 WHERE dept_id = 5; -- HR → HR Director
UPDATE departments SET manager_id = 36 WHERE dept_id = 6; -- Legal → General Counsel
UPDATE departments SET manager_id = 39 WHERE dept_id = 7; -- Product → Product Director
UPDATE departments SET manager_id = 1  WHERE dept_id = 8; -- Executive → CEO

-- ── 3. salary_history ─────────────────────────────────────────
-- salary_before = NULL means initial hire entry.
-- changed_by = HR director or direct manager emp_id.
-- FLAW: rows with hist_id 16 and 17 are exact duplicates.

INSERT INTO salary_history
    (emp_id, salary_before, salary_after, effective_date, change_reason, changed_by)
VALUES
-- emp 1 (James Wilson, CEO)
(1,  NULL,      300000.00, '2015-03-01', 'Initial hire',      33),
(1,  300000.00, 320000.00, '2017-01-01', 'Annual review',      1),
(1,  320000.00, 350000.00, '2020-01-01', 'Annual review',      1),
-- emp 2 (Sarah Chen, CTO)
(2,  NULL,      240000.00, '2016-06-15', 'Initial hire',       1),
(2,  240000.00, 265000.00, '2019-01-01', 'Annual review',      1),
(2,  265000.00, 280000.00, '2022-01-01', 'Annual review',      1),
-- emp 3 (Carol White, VP Sales)
(3,  NULL,      195000.00, '2016-01-20', 'Initial hire',       1),
(3,  195000.00, 210000.00, '2019-01-01', 'Annual review',      1),
(3,  210000.00, 220000.00, '2022-01-01', 'Annual review',      1),
-- emp 4 (David Kim, VP Finance)
(4,  NULL,      210000.00, '2015-07-15', 'Initial hire',       1),
(4,  210000.00, 225000.00, '2018-01-01', 'Annual review',      1),
(4,  225000.00, 230000.00, '2022-01-01', 'Annual review',      1),
-- emp 5 (Emma Davis, Sr Software Engineer)
(5,  NULL,      120000.00, '2018-09-10', 'Initial hire',       2),
(5,  120000.00, 132000.00, '2020-01-01', 'Annual review',      2),
(5,  132000.00, 145000.00, '2022-04-01', 'Promotion',          2), -- row 15 (clean)
(5,  132000.00, 145000.00, '2022-04-01', 'Promotion',          2), -- FLAW: exact duplicate of row above
-- emp 7 (Grace Wilson, Sr Software Engineer)
(7,  NULL,      135000.00, '2017-11-05', 'Initial hire',       2),
(7,  135000.00, 148000.00, '2019-06-01', 'Annual review',      2),
(7,  148000.00, 155000.00, '2022-01-01', 'Annual review',      2),
-- emp 9 (Iris Taylor, Data Engineer)
(9,  NULL,      110000.00, '2021-03-30', 'Initial hire',       2),
(9,  110000.00, 120000.00, '2023-01-01', 'Annual review',      2),
-- emp 18 (Rachel Clark, Regional Sales Lead)
(18, NULL,      100000.00, '2017-08-14', 'Initial hire',       3),
(18, 100000.00, 115000.00, '2021-01-01', 'Annual review',      3),
-- emp 20 (Tom Lewis, Sales Manager)
(20, NULL,      118000.00, '2018-03-12', 'Initial hire',       3),
(20, 118000.00, 135000.00, '2022-01-01', 'Promotion',          3),
-- emp 25 (Anna Parker, Finance Manager)
(25, NULL,      115000.00, '2017-05-03', 'Initial hire',       4),
(25, 115000.00, 130000.00, '2021-01-01', 'Annual review',      4),
-- emp 29 (Chloe Nguyen, Marketing Director)
(29, NULL,      175000.00, '2016-09-19', 'Initial hire',       1),
(29, 175000.00, 200000.00, '2021-01-01', 'Annual review',      1),
-- emp 36 (Jake Evans, General Counsel)
(36, NULL,      220000.00, '2017-03-07', 'Initial hire',       1),
(36, 220000.00, 250000.00, '2022-01-01', 'Annual review',      1),
-- emp 39 (Maria Torres, Product Director)
(39, NULL,      190000.00, '2016-04-25', 'Initial hire',       1),
(39, 190000.00, 215000.00, '2021-01-01', 'Annual review',      1);

-- ── 4. projects ───────────────────────────────────────────────
-- FLAW: project 7 has NULL budget.
-- FLAW: project 11 has end_date before start_date.

INSERT INTO projects (project_id, project_name, dept_id, start_date, end_date, budget, status) VALUES
(1,  'Phoenix ERP Migration',      3, '2022-06-01', '2023-12-31', 1500000.00, 'Completed'),
(2,  'Mobile App v3.0',            1, '2023-01-15', NULL,          800000.00, 'Active'),
(3,  'Sales Pipeline Automation',  2, '2023-04-01', '2024-03-31',  450000.00, 'Completed'),
(4,  'Data Lake Infrastructure',   1, '2023-07-01', NULL,         1200000.00, 'Active'),
(5,  'Brand Refresh',              4, '2024-01-01', '2024-06-30',  300000.00, 'Completed'),
(6,  'HR Self-Service Portal',     5, '2023-09-01', '2024-05-31',  250000.00, 'Completed'),
(7,  'Cloud Security Audit',       6, '2024-02-01', NULL,               NULL, 'Active'),  -- FLAW: NULL budget
(8,  'Customer Success Platform',  2, '2024-03-01', NULL,          600000.00, 'Active'),
(9,  'Analytics Dashboard',        1, '2023-11-01', '2024-10-31',  350000.00, 'Active'),
(10, 'Compliance Framework',       6, '2024-01-15', '2024-12-31',  200000.00, 'Active'),
(11, 'Product Roadmap 2025',       7, '2024-06-01', '2024-02-28',  150000.00, 'Planning'), -- FLAW: end_date < start_date
(12, 'Onboarding Automation',      5, '2023-03-01', '2023-10-31',  120000.00, 'Completed');

-- ── 5. project_assignments ────────────────────────────────────
-- FLAW: rows 24 and 25 are exact duplicates.
-- FLAW: some hours_billed = NULL (hours not yet logged).

INSERT INTO project_assignments (emp_id, project_id, role, start_date, end_date, hours_billed) VALUES
-- Mobile App v3.0 (proj 2)
(5,  2, 'Senior Engineer',  '2023-01-15', NULL,         480.00),
(6,  2, 'Engineer',         '2023-01-15', NULL,         320.00),
(7,  2, 'Senior Engineer',  '2023-02-01', NULL,         560.00),
-- Data Lake (proj 4)
(9,  4, 'Data Engineer Lead','2023-07-01', NULL,         NULL),   -- FLAW: hours_billed NULL
(10, 4, 'Data Scientist',   '2023-09-01', NULL,         NULL),   -- FLAW: hours_billed NULL
(14, 4, 'SRE',              '2023-07-01', NULL,         240.00),
-- Analytics Dashboard (proj 9)
(2,  9, 'CTO Sponsor',      '2023-11-01', NULL,          80.00),
(5,  9, 'Tech Lead',        '2023-11-01', NULL,         NULL),   -- FLAW: hours_billed NULL
(8,  9, 'DevOps',           '2023-11-15', NULL,         160.00),
-- Phoenix ERP Migration (proj 1)
(4,  1, 'Exec Sponsor',     '2022-06-01', '2023-12-31', 120.00),
(25, 1, 'Finance Lead',     '2022-06-01', '2023-12-31', 380.00),
(5,  1, 'Tech Advisor',     '2022-08-01', '2023-12-31', 200.00),
-- Sales Pipeline Automation (proj 3)
(20, 3, 'Sales Lead',       '2023-04-01', '2024-03-31', 340.00),
(18, 3, 'Sales Rep',        '2023-04-01', '2024-03-31', 280.00),
(21, 3, 'Sales Rep',        '2023-04-01', '2024-03-31', 260.00),
-- Brand Refresh (proj 5)
(29, 5, 'Dir Sponsor',      '2024-01-01', '2024-06-30',  60.00),
(30, 5, 'Marketing Lead',   '2024-01-01', '2024-06-30', 320.00),
(31, 5, 'Content Lead',     '2024-01-01', '2024-06-30', 280.00),
-- HR Self-Service Portal (proj 6)
(33, 6, 'Exec Sponsor',     '2023-09-01', '2024-05-31',  80.00),
(34, 6, 'HR Lead',          '2023-09-01', '2024-05-31', 420.00),
-- Cloud Security Audit (proj 7)
(37, 7, 'Legal Lead',       '2024-02-01', NULL,         160.00),
(38, 7, 'Legal Analyst',    '2024-02-01', NULL,         200.00),
-- Product Roadmap (proj 11)
(39, 11,'Dir Sponsor',      '2024-06-01', NULL,          40.00),
(40, 11,'Product Lead',     '2024-06-01', NULL,          NULL),  -- FLAW: hours_billed NULL
-- FLAW: duplicate assignment (same emp, same project, same dates)
(9,  9, 'Data Engineer',    '2023-11-01', NULL,         300.00),
(9,  9, 'Data Engineer',    '2023-11-01', NULL,         300.00); -- FLAW: exact duplicate of row above

-- ── 6. performance_reviews ────────────────────────────────────
-- FLAW: row 17 reviewer_id = NULL and rating = NULL (not submitted).
-- FLAW: row 6 rating = NULL (review started but not completed).

INSERT INTO performance_reviews (emp_id, reviewer_id, review_date, review_period, rating, comments) VALUES
-- Sarah Chen (emp 2) reviewed by CEO (emp 1)
(2,  1,    '2024-01-20', '2023-H2', 5, 'Exceptional technical leadership.'),
-- Carol White (emp 3) reviewed by CEO (emp 1)
(3,  1,    '2024-01-20', '2023-H2', 4, 'Strong sales results, exceeded targets.'),
-- Emma Davis (emp 5) reviewed by CTO (emp 2)
(5,  2,    '2023-07-15', '2023-H1', 4, 'Strong performance across all metrics.'),
(5,  2,    '2024-01-20', '2023-H2', 5, 'Outstanding year, promotion warranted.'),
(5,  NULL, '2024-07-20', '2024-H1', NULL, 'Pending submission.'), -- FLAW: NULL reviewer + NULL rating
-- Frank Brown (emp 6) reviewed by Emma Davis (emp 5)
(6,  5,    '2023-07-15', '2023-H1', 3, 'Meets expectations.'),
(6,  5,    '2024-01-20', '2023-H2', 3, 'Meets expectations. Areas to grow in code quality.'),
-- Grace Wilson (emp 7) reviewed by CTO (emp 2)
(7,  2,    '2023-07-15', '2023-H1', 4, 'Above expectations on architecture tasks.'),
(7,  2,    '2024-01-20', '2023-H2', NULL, 'Review not completed by reviewer.'), -- FLAW: NULL rating
-- Iris Taylor (emp 9) reviewed by CTO (emp 2)
(9,  2,    '2023-07-15', '2023-H1', 4, 'Excellent data pipeline work.'),
(9,  2,    '2024-01-20', '2023-H2', 5, 'Exceptional — key contributor to data lake project.'),
-- Karen Thomas (emp 11) reviewed by Emma Davis (emp 5)
(11, 5,    '2024-01-20', '2023-H2', 3, 'Good progress since joining.'),
-- Liam Jackson (emp 12) reviewed by Emma Davis (emp 5)
(12, 5,    '2024-01-20', '2023-H2', 2, 'Needs improvement in delivery consistency.'),
-- Tom Lewis (emp 20) reviewed by Carol White (emp 3)
(20, 3,    '2023-07-15', '2023-H1', 4, 'Sales targets exceeded by 12%.'),
(20, 3,    '2024-01-20', '2023-H2', 4, 'Consistent performer, strong team leadership.'),
-- Uma Clark (emp 21) reviewed by Tom Lewis (emp 20)
(21, 20,   '2024-01-20', '2023-H2', 3, 'Good first full year, developing pipeline skills.'),
-- Anna Parker (emp 25) reviewed by VP Finance (emp 4)
(25, 4,    '2023-07-15', '2023-H1', 5, 'Excellent FP&A and board presentation skills.'),
(25, 4,    '2024-01-20', '2023-H2', 4, 'Strong performance, reliable across all tasks.'),
-- Dan Rivera (emp 30) reviewed by Marketing Director (emp 29)
(30, 29,   '2024-01-20', '2023-H2', 4, 'Creative campaigns, strong brand consistency.'),
-- Gina Stewart (emp 33) reviewed by CEO (emp 1)
(33, 1,    '2024-01-20', '2023-H2', 4, 'Excellent HR leadership through growth phase.');

-- ── 7. emp_events ─────────────────────────────────────────────
-- Funnel steps (ordered): login → view_payslip → update_profile
--                       → submit_leave → logout
-- Sessionization: 30-min idle gap = new session.
-- FLAW: missing logout events for some sessions.
-- FLAW: 3 rows with NULL session_id (emp 14, untracked device).

INSERT INTO emp_events (emp_id, event_type, event_ts, page, session_id) VALUES
-- ── emp 9 (Iris Taylor) — two sessions, same day, sessionization demo ──
(9,  'login',          '2024-01-15 09:00:00', '/login',   'sess-9A'),
(9,  'view_payslip',   '2024-01-15 09:05:30', '/payslip', 'sess-9A'),
(9,  'update_profile', '2024-01-15 09:12:45', '/profile', 'sess-9A'),
(9,  'logout',         '2024-01-15 09:18:00', '/logout',  'sess-9A'),
-- 104-minute idle gap → new session
(9,  'login',          '2024-01-15 11:02:00', '/login',   'sess-9B'),
(9,  'submit_leave',   '2024-01-15 11:08:00', '/leave',   'sess-9B'),
-- FLAW: no logout for sess-9B

-- ── emp 5 (Emma Davis) — complete funnel, session A ──
(5,  'login',          '2024-01-15 10:00:00', '/login',   'sess-5A'),
(5,  'view_payslip',   '2024-01-15 10:04:00', '/payslip', 'sess-5A'),
(5,  'update_profile', '2024-01-15 10:09:00', '/profile', 'sess-5A'),
(5,  'submit_leave',   '2024-01-15 10:14:00', '/leave',   'sess-5A'),
(5,  'logout',         '2024-01-15 10:20:00', '/logout',  'sess-5A'),
-- emp 5, session B (same day, after 3h+ gap)
(5,  'login',          '2024-01-15 14:00:00', '/login',   'sess-5B'),
(5,  'approve_leave',  '2024-01-15 14:05:00', '/approve', 'sess-5B'),
(5,  'logout',         '2024-01-15 14:09:00', '/logout',  'sess-5B'),

-- ── emp 6 (Frank Brown) — drops at funnel step 2 ──
(6,  'login',          '2024-01-15 10:30:00', '/login',   'sess-6A'),
(6,  'view_payslip',   '2024-01-15 10:35:00', '/payslip', 'sess-6A'),
(6,  'logout',         '2024-01-15 10:41:00', '/logout',  'sess-6A'),

-- ── emp 7 (Grace Wilson) — drops at funnel step 3 ──
(7,  'login',          '2024-01-16 14:00:00', '/login',   'sess-7A'),
(7,  'view_payslip',   '2024-01-16 14:06:00', '/payslip', 'sess-7A'),
(7,  'update_profile', '2024-01-16 14:11:00', '/profile', 'sess-7A'),
-- FLAW: no logout for sess-7A (dropped at step 4)

-- ── emp 8 (Henry Moore) — complete funnel ──
(8,  'login',          '2024-01-16 15:00:00', '/login',   'sess-8A'),
(8,  'view_payslip',   '2024-01-16 15:03:00', '/payslip', 'sess-8A'),
(8,  'update_profile', '2024-01-16 15:08:00', '/profile', 'sess-8A'),
(8,  'submit_leave',   '2024-01-16 15:14:00', '/leave',   'sess-8A'),
(8,  'logout',         '2024-01-16 15:21:00', '/logout',  'sess-8A'),

-- ── emp 12 (Liam Jackson) — two sessions, same day ──
(12, 'login',          '2024-02-05 08:45:00', '/login',   'sess-12A'),
(12, 'view_payslip',   '2024-02-05 08:50:00', '/payslip', 'sess-12A'),
(12, 'logout',         '2024-02-05 08:57:00', '/logout',  'sess-12A'),
-- 273-minute idle gap → new session
(12, 'login',          '2024-02-05 13:30:00', '/login',   'sess-12B'),
(12, 'submit_leave',   '2024-02-05 13:35:00', '/leave',   'sess-12B'),
(12, 'logout',         '2024-02-05 13:40:00', '/logout',  'sess-12B'),

-- ── emp 14 (Noah Harris) — NULL session_id (untracked device) ──
(14, 'login',          '2024-03-10 09:00:00', '/login',   NULL),  -- FLAW: NULL session_id
(14, 'update_profile', '2024-03-10 09:22:00', '/profile', NULL),  -- FLAW: NULL session_id
(14, 'submit_leave',   '2024-03-10 09:45:00', '/leave',   NULL),  -- FLAW: NULL session_id

-- ── emp 20 (Tom Lewis) — approve leave action ──
(20, 'login',          '2024-02-20 11:00:00', '/login',   'sess-20A'),
(20, 'approve_leave',  '2024-02-20 11:03:00', '/approve', 'sess-20A'),
(20, 'logout',         '2024-02-20 11:07:00', '/logout',  'sess-20A'),

-- ── emp 25 (Anna Parker) — quick payslip check ──
(25, 'login',          '2024-03-15 16:30:00', '/login',   'sess-25A'),
(25, 'view_payslip',   '2024-03-15 16:34:00', '/payslip', 'sess-25A'),
(25, 'logout',         '2024-03-15 16:39:00', '/logout',  'sess-25A');

-- ── 8. purchase_orders ────────────────────────────────────────
-- Used for market basket / category co-occurrence analysis.
-- FLAW: orders 16 and 17 are exact duplicates.
-- FLAW: order 23 has dept_id = NULL (orphaned).

INSERT INTO purchase_orders (order_id, dept_id, vendor, item_category, amount, order_date, status) VALUES
-- Engineering (dept 1) — multi-category basket on 2024-01-10
(1,  1, 'TechSoft Inc',       'Software',       45000.00, '2024-01-10', 'Approved'),
(2,  1, 'HardwarePlus',       'Hardware',       28000.00, '2024-01-10', 'Approved'),
(3,  1, 'CloudCo',            'Cloud Services', 65000.00, '2024-01-10', 'Approved'),
(4,  1, 'LearnFast',          'Training',        8500.00, '2024-02-15', 'Approved'),
(5,  1, 'TechSoft Inc',       'Software',       52000.00, '2024-03-20', 'Approved'),
(6,  1, 'CloudCo',            'Cloud Services', 71000.00, '2024-03-20', 'Approved'),
(7,  1, 'ConsuLead',          'Consulting',     90000.00, '2024-04-10', 'Approved'),
-- Sales (dept 2) — training + travel basket
(8,  2, 'LearnFast',          'Training',       12000.00, '2024-01-20', 'Approved'),
(9,  2, 'TravelEase',         'Travel',          9500.00, '2024-01-20', 'Approved'),
(10, 2, 'LearnFast',          'Training',       14000.00, '2024-04-05', 'Approved'),
(11, 2, 'TravelEase',         'Travel',         15000.00, '2024-05-01', 'Approved'),
-- Finance (dept 3) — software + consulting + training basket
(12, 3, 'TechSoft Inc',       'Software',       32000.00, '2024-02-01', 'Approved'),
(13, 3, 'ConsuLead',          'Consulting',     40000.00, '2024-02-01', 'Approved'),
(14, 3, 'LearnFast',          'Training',        6000.00, '2024-02-01', 'Approved'),
(15, 3, 'OfficeWorld',        'Office Supplies', 1800.00, '2024-05-15', 'Approved'),
-- Marketing (dept 4) — software + training + consulting basket
(16, 4, 'TechSoft Inc',       'Software',       18000.00, '2024-01-25', 'Approved'),
(17, 4, 'LearnFast',          'Training',        7500.00, '2024-01-25', 'Approved'),
(18, 4, 'ConsuLead',          'Consulting',     25000.00, '2024-01-25', 'Approved'),
-- HR (dept 5) — FLAW: orders 19 and 20 are exact duplicates
(19, 5, 'LearnFast',          'Training',        5500.00, '2024-03-01', 'Approved'), -- clean
(20, 5, 'LearnFast',          'Training',        5500.00, '2024-03-01', 'Approved'), -- FLAW: duplicate of order 19
(21, 5, 'OfficeWorld',        'Office Supplies', 1200.00, '2024-03-01', 'Approved'),
-- Legal (dept 6) — legal services + consulting basket
(22, 6, 'LexisNexis',         'Legal Services', 85000.00, '2024-02-10', 'Approved'),
(23, 6, 'ConsuLead',          'Consulting',     35000.00, '2024-02-10', 'Approved'),
-- Product (dept 7) — software + cloud basket
(24, 7, 'TechSoft Inc',       'Software',       22000.00, '2024-03-15', 'Approved'),
(25, NULL, 'OfficeWorld',     'Office Supplies',   450.00, '2024-04-01', 'Approved'); -- FLAW: NULL dept_id (orphaned)

-- ── 9. leave_requests ─────────────────────────────────────────
-- Used for gap-and-islands: consecutive leave blocks = one island.
-- FLAW: requests 1 and 2 overlap for emp 12 (data entry error).
-- FLAW: request 11 has NULL leave_type.

INSERT INTO leave_requests (request_id, emp_id, leave_type, start_date, end_date, status) VALUES
-- emp 12 (Liam Jackson) — FLAW: overlapping ranges
(1,  12, 'Annual Leave', '2024-04-10', '2024-04-17', 'Approved'), -- clean
(2,  12, 'Annual Leave', '2024-04-15', '2024-04-22', 'Approved'), -- FLAW: overlaps Apr 15-17 with request 1

-- emp 5 (Emma Davis) — gap-and-islands demo
-- Island 1: Jan 15-17 (sick) + Jan 18-19 (consecutive → same island)
(3,  5,  'Sick Leave',   '2024-01-15', '2024-01-17', 'Approved'),
(4,  5,  'Sick Leave',   '2024-01-18', '2024-01-19', 'Approved'), -- consecutive with request 3
-- Island 2: separate block in March
(5,  5,  'Annual Leave', '2024-03-05', '2024-03-08', 'Approved'),

-- emp 7 (Grace Wilson) — two blocks with weekend gap
(6,  7,  'Annual Leave', '2024-02-01', '2024-02-05', 'Approved'),
(7,  7,  'Annual Leave', '2024-02-08', '2024-02-12', 'Approved'), -- Feb 6-7 gap → separate island

-- emp 9 (Iris Taylor) — long continuous block
(8,  9,  'Parental Leave','2024-05-01', '2024-05-31', 'Approved'),

-- emp 16 (Peter Martinez) — cross-year blocks
(9,  16, 'Annual Leave', '2023-12-27', '2023-12-31', 'Approved'),
(10, 16, 'Annual Leave', '2024-01-02', '2024-01-05', 'Approved'), -- Jan 1 gap → separate island

-- emp 34 (Harry Gonzalez) — FLAW: NULL leave_type
(11, 34, NULL,           '2024-07-15', '2024-07-19', 'Approved'), -- FLAW: NULL leave_type

-- emp 20 (Tom Lewis) — approved leave
(12, 20, 'Annual Leave', '2024-08-05', '2024-08-09', 'Approved'),

-- emp 27 (Christine Hughes)
(13, 27, 'Sick Leave',   '2024-03-20', '2024-03-21', 'Approved'),
(14, 27, 'Annual Leave', '2024-06-10', '2024-06-14', 'Approved'),

-- emp 26 (Brian Collins)
(15, 26, 'Annual Leave', '2024-09-02', '2024-09-06', 'Approved'),

-- emp 11 (Karen Thomas)
(16, 11, 'Annual Leave', '2024-07-22', '2024-07-26', 'Approved'),

-- emp 6 (Frank Brown) — two consecutive blocks merging
(17, 6,  'Sick Leave',   '2024-05-13', '2024-05-14', 'Approved'),
(18, 6,  'Sick Leave',   '2024-05-15', '2024-05-15', 'Approved'), -- consecutive with request 17 → same island

-- emp 25 (Anna Parker)
(19, 25, 'Annual Leave', '2024-10-07', '2024-10-11', 'Approved'),

-- emp 32 (Fred Mitchell) — pending request
(20, 32, 'Annual Leave', '2024-11-25', '2024-11-29', 'Pending');
