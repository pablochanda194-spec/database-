-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment
-- Qualifies when age is 18 to 25, monthly income is at most K3,000 and
-- the average mark is at least 70. Everything is in schema q10.

DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;


-- (a) Tables
CREATE TABLE students (
    student_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number varchar(12) NOT NULL UNIQUE,
    full_name      varchar(100) NOT NULL
);

CREATE TABLE applications (
    application_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id         integer NOT NULL REFERENCES students(student_id),
    age_at_application integer NOT NULL CHECK (age_at_application > 0),
    monthly_income     numeric(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       numeric(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       date NOT NULL,
    status             varchar(8) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id integer NOT NULL REFERENCES applications(application_id),
    old_status     varchar(8) NOT NULL,
    new_status     varchar(8) NOT NULL,
    changed_at     timestamptz NOT NULL DEFAULT current_timestamp
);


-- (b) Function: does an applicant qualify?
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age integer,
                                                   p_income numeric,
                                                   p_mark numeric)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;


-- (c) Procedure: assess one application
-- The row is locked FOR UPDATE so two runs cannot assess it twice.
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application %', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed as %',
            p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE
            WHEN fn_scholarship_eligible(v_app.age_at_application,
                                         v_app.monthly_income,
                                         v_app.average_mark)
            THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;


-- (d) Trigger: record real status changes
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, current_timestamp);
    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();


-- (a) Seed data: six PENDING applications, three students
INSERT INTO students (student_number, full_name) VALUES
('2026201', 'Natasha Kaunda'),
('2026202', 'Oscar Mwansa'),
('2026203', 'Priscilla Daka');

INSERT INTO applications
    (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
(1, 18, 3000.00, 70.00, CURRENT_DATE - 10),   -- 1 all lower boundaries: qualifies
(1, 25, 1500.00, 85.50, CURRENT_DATE - 9),    -- 2 age upper boundary: qualifies
(2, 26, 1200.00, 90.00, CURRENT_DATE - 8),    -- 3 too old by one year
(2, 21, 3000.01, 80.00, CURRENT_DATE - 7),    -- 4 income one ngwee over
(3, 20, 2000.00, 69.99, CURRENT_DATE - 6),    -- 5 mark just below 70
(3, 17, 1000.00, 95.00, CURRENT_DATE - 5);    -- 6 too young

SELECT * FROM applications ORDER BY application_id;

-- function results: t, t, f, f, f, f
SELECT application_id,
       fn_scholarship_eligible(age_at_application, monthly_income, average_mark) AS eligible
FROM applications ORDER BY application_id;

-- Function rejections
DO $$
BEGIN
    BEGIN
        PERFORM q10.fn_scholarship_eligible(NULL, 1000, 80);
        RAISE NOTICE 'FAILED: NULL age accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'NULL input: %', SQLERRM;
    END;
    BEGIN
        PERFORM q10.fn_scholarship_eligible(20, -1, 80);
        RAISE NOTICE 'FAILED: negative income accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'negative income: %', SQLERRM;
    END;
    BEGIN
        PERFORM q10.fn_scholarship_eligible(0, 1000, 80);
        RAISE NOTICE 'FAILED: age 0 accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'age 0: %', SQLERRM;
    END;
    BEGIN
        PERFORM q10.fn_scholarship_eligible(20, 1000, 101);
        RAISE NOTICE 'FAILED: mark 101 accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'mark 101: %', SQLERRM;
    END;
END;
$$;

-- Assess application 1 on its own
CALL pr_assess_application(1);
SELECT application_id, status FROM applications WHERE application_id = 1;

DO $$
BEGIN
    BEGIN
        CALL q10.pr_assess_application(1);
        RAISE NOTICE 'FAILED: second assessment accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'already assessed: %', SQLERRM;
    END;
    BEGIN
        CALL q10.pr_assess_application(99);
        RAISE NOTICE 'FAILED: unknown application accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown application: %', SQLERRM;
    END;
END;
$$;

-- An update that keeps the same status writes no audit row
UPDATE applications SET status = 'APPROVED' WHERE application_id = 1;
SELECT count(*) AS audit_rows FROM decision_audit;   -- 1


-- (e) View: approved applicants only, without household income
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.application_id,
       a.average_mark, a.status
FROM applications AS a
JOIN students AS s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';


-- (f) Index for applications by status within a date range
-- status first for the exact match, submitted_on second for the range.
CREATE INDEX ix_applications_status_date ON applications (status, submitted_on);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


-- (g) Assess all pending applications, and the scheduled job
-- A FOR loop over PENDING applications only. Assessed applications are
-- never selected again, so a rerun changes nothing and adds no audit rows.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r       record;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY submitted_on, application_id
    LOOP
        CALL pr_assess_application(r.application_id);
        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'Applications assessed: %', v_count;
END;
$$;

CALL pr_assess_pending();   -- assesses 2 to 6
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;   -- 6 rows

CALL pr_assess_pending();   -- "Applications assessed: 0"
SELECT count(*) AS audit_rows_after_rerun FROM decision_audit;   -- still 6

-- applications 1 and 2
SELECT * FROM v_approved_applicants ORDER BY application_id;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q10 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q10'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q10, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: every Monday at 08:00 (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q10_assess_pending', '0 8 * * 1',
                              'CALL q10.pr_assess_pending()');
        RAISE NOTICE 'Scheduled q10_assess_pending on Mondays at 08:00';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

