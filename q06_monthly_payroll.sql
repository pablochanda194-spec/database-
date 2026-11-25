-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing
-- gross = basic_salary + allowance, net = gross - deduction.
-- Everything is created in the schema q06.

DROP SCHEMA IF EXISTS q06 CASCADE;
CREATE SCHEMA q06;
SET search_path TO q06, public;


-- (a) Tables
CREATE TABLE employees (
    employee_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    varchar(100) NOT NULL,
    basic_salary numeric(10,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    numeric(10,2) NOT NULL CHECK (allowance >= 0),
    deduction    numeric(10,2) NOT NULL CHECK (deduction >= 0),
    active       boolean NOT NULL DEFAULT true
);

-- pay_month is always the first day of a month
CREATE TABLE payroll (
    payroll_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id integer NOT NULL REFERENCES employees(employee_id),
    pay_month   date NOT NULL
        CHECK (pay_month = date_trunc('month', pay_month)::date),
    gross_pay   numeric(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     numeric(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id integer NOT NULL REFERENCES employees(employee_id),
    old_salary  numeric(10,2) NOT NULL,
    new_salary  numeric(10,2) NOT NULL,
    changed_at  timestamptz NOT NULL DEFAULT current_timestamp
);


-- (b) Function: net pay from current figures
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_net numeric(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Net pay for employee % would be negative (%)', p_employee_id, v_net;
    END IF;

    RETURN v_net;
END;
$$;


-- (c) Procedure: process one month
-- A FOR loop over active employees. Existing rows are left as they are
-- (ON CONFLICT DO NOTHING). If fn_net_pay raises for any employee, the
-- error ends the CALL and every row inserted by it is rolled back.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month date)
LANGUAGE plpgsql
AS $$
DECLARE
    r       record;
    v_added integer := 0;
    v_rows  integer;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'Pay month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month,
                r.basic_salary + r.allowance,
                fn_net_pay(r.employee_id))
        ON CONFLICT (employee_id, pay_month) DO NOTHING;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_added := v_added + v_rows;
    END LOOP;

    RAISE NOTICE 'Payroll % : % new rows', p_month, v_added;
END;
$$;


-- (d) Trigger: log real salary changes
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();


-- (a) Seed data and two payroll months
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Agness Mwape',   9000.00, 1500.00, 1200.00, true),
('Bernard Siame',  7500.00, 1000.00,  900.00, true),
('Clara Nkonde',   6000.00,  800.00,  700.00, true),
('Dennis Kasonde', 5000.00,  500.00,  600.00, false);   -- inactive from the start

CALL pr_process_payroll(DATE '2026-09-01');   -- 3 rows

-- Clara leaves before October; her September row stays
UPDATE employees SET active = false WHERE full_name = 'Clara Nkonde';

CALL pr_process_payroll(DATE '2026-10-01');   -- 2 rows

-- Rerunning September adds nothing and changes nothing
CALL pr_process_payroll(DATE '2026-09-01');

SELECT * FROM payroll ORDER BY pay_month, employee_id;

SELECT employee_id, fn_net_pay(employee_id) AS net_now
FROM employees ORDER BY employee_id;

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q06.fn_net_pay(99);
        RAISE NOTICE 'FAILED: unknown employee accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_net_pay: %', SQLERRM;
    END;
    BEGIN
        CALL q06.pr_process_payroll(DATE '2026-11-15');
        RAISE NOTICE 'FAILED: mid-month date accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'mid-month date: %', SQLERRM;
    END;
END;
$$;

-- An employee whose deduction is larger than gross pay makes the whole
-- November run fail, so no November rows are kept for anyone. The test
-- employee is removed again by the same rolled-back block.
DO $$
DECLARE
    v_nov integer;
BEGIN
    BEGIN
        INSERT INTO q06.employees (full_name, basic_salary, allowance, deduction, active)
        VALUES ('Test Negative', 1000.00, 0.00, 2000.00, true);
        CALL q06.pr_process_payroll(DATE '2026-11-01');
        RAISE NOTICE 'FAILED: negative net pay accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'whole call failed: %', SQLERRM;
    END;
    SELECT count(*) INTO v_nov FROM q06.payroll WHERE pay_month = DATE '2026-11-01';
    RAISE NOTICE 'November rows after the failed call: %', v_nov;
END;
$$;

-- Salary audit: one real change, one update to the same value
UPDATE employees SET basic_salary = 9500.00 WHERE full_name = 'Agness Mwape';
UPDATE employees SET basic_salary = 9500.00 WHERE full_name = 'Agness Mwape';
UPDATE employees SET allowance = 1600.00 WHERE full_name = 'Agness Mwape';
-- only one audit row: 9000.00 -> 9500.00
SELECT * FROM salary_audit ORDER BY audit_id;

-- Processed rows were not changed by the salary increase
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;


-- (e) View: payroll with names
-- An inner join on payroll keeps every historical row, including Clara's
-- September pay although she is now inactive.
CREATE VIEW v_payroll_report AS
SELECT p.pay_month, e.employee_id, e.full_name, e.active,
       p.gross_pay, p.net_pay
FROM payroll AS p
JOIN employees AS e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;


-- (f) Index for a monthly report across all employees
-- The unique index (employee_id, pay_month) starts with employee_id, so
-- it cannot be searched by month alone. A separate index on pay_month
-- serves "all employees for one month" without repeating that index.
CREATE INDEX ix_payroll_pay_month ON payroll (pay_month);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q06 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q06'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q06, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- (g) Scheduled job: 02:00 on the 1st of each month, for the month before
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule(
            'q06_process_payroll', '0 2 1 * *',
            $job$CALL q06.pr_process_payroll((date_trunc('month', CURRENT_DATE) - interval '1 month')::date)$job$);
        RAISE NOTICE 'Scheduled q06_process_payroll at 02:00 on day 1 of each month';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

-- The date the job will pass when it runs on the 1st of a month
SELECT (date_trunc('month', DATE '2026-12-01') - interval '1 month')::date AS month_processed_on_1_dec;

-- Inspecting the job and its run history (pg_cron):
--   SELECT jobid, jobname, schedule, command, active
--   FROM cron.job
--   WHERE jobname = 'q06_process_payroll';
--
--   SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
--   FROM cron.job_run_details AS d
--   JOIN cron.job AS j ON j.jobid = d.jobid
--   WHERE j.jobname = 'q06_process_payroll'
--   ORDER BY d.start_time DESC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE NOTICE 'Job rows: %',
            (SELECT count(*) FROM cron.job WHERE jobname = 'q06_process_payroll');
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so there is no job history to show';
    END IF;
END;
$$;

