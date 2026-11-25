-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 2: University Fee Payments
-- Everything is created in the schema q02.

DROP SCHEMA IF EXISTS q02 CASCADE;
CREATE SCHEMA q02;
SET search_path TO q02, public;


-- (a) Tables
CREATE TABLE students (
    student_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number varchar(12) NOT NULL UNIQUE,
    full_name      varchar(100) NOT NULL,
    fee_due        numeric(10,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id integer NOT NULL REFERENCES students(student_id),
    amount     numeric(10,2) NOT NULL CHECK (amount > 0),
    paid_on    date NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id integer NOT NULL REFERENCES payments(payment_id),
    student_id integer NOT NULL REFERENCES students(student_id),
    amount     numeric(10,2) NOT NULL,
    logged_at  timestamptz NOT NULL DEFAULT current_timestamp
);

CREATE TABLE daily_collections (
    collection_date date PRIMARY KEY,
    payment_count   integer NOT NULL CHECK (payment_count >= 0),
    total_amount    numeric(12,2) NOT NULL CHECK (total_amount >= 0)
);


-- (b) Function: outstanding balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  numeric(10,2);
    v_paid numeric(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;

    -- coalesce gives 0 paid when the student has no payments, so the
    -- full fee is returned
    SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;


-- (c) Procedure: receive a payment
-- The student row is locked so two payments at once cannot both pass
-- the balance check. fee_due is never changed; the balance always comes
-- from fee_due minus the payments.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id integer,
                                               p_amount numeric,
                                               p_paid_on date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance numeric(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero';
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;

    v_balance := fn_fee_balance(p_student_id);   -- rejects an unknown student

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment of % is more than the outstanding balance of %',
            p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;


-- (d) Trigger: audit every new payment
-- The procedure does not write to payment_audit; this trigger does, so
-- payments inserted directly are audited too.
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, current_timestamp);
    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();


-- (a) Seed data
-- 2026001 pays the full fee, 2026002 pays part of it, 2026003 pays nothing.
INSERT INTO students (student_number, full_name, fee_due) VALUES
('2026001', 'Natasha Mulenga', 5000.00),
('2026002', 'Joseph Chanda',   8000.00),
('2026003', 'Ruth Kabwe',      6000.00);

CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  500.00, CURRENT_DATE - 1);

SELECT * FROM students ORDER BY student_id;
SELECT * FROM payments ORDER BY payment_id;
-- one audit row per payment (6)
SELECT * FROM payment_audit ORDER BY audit_id;

-- balances: 0.00, 5000.00 and the full 6000.00
SELECT student_number, fn_fee_balance(student_id) AS balance
FROM students ORDER BY student_id;

DO $$
BEGIN
    PERFORM q02.fn_fee_balance(99);
    RAISE NOTICE 'FAILED: unknown student accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'fn_fee_balance rejected: %', SQLERRM;
END;
$$;

-- Invalid payments: NULL, zero, negative, above the balance, unknown student
DO $$
DECLARE
    v_amount numeric;
BEGIN
    FOREACH v_amount IN ARRAY ARRAY[NULL, 0, -100, 5000.01]::numeric[] LOOP
        BEGIN
            CALL q02.pr_receive_payment(2, v_amount, CURRENT_DATE);
            RAISE NOTICE 'FAILED: amount % accepted', v_amount;
        EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'amount %: rejected - %', coalesce(v_amount::text, 'NULL'), SQLERRM;
        END;
    END LOOP;

    BEGIN
        CALL q02.pr_receive_payment(99, 100, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown student accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown student: rejected - %', SQLERRM;
    END;
END;
$$;

-- still 6 payments and 6 audit rows, fee_due unchanged
SELECT (SELECT count(*) FROM payments) AS payments,
       (SELECT count(*) FROM payment_audit) AS audit_rows,
       (SELECT fee_due FROM students WHERE student_id = 2) AS fee_due_2026002;


-- (e) View: students who still owe
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - coalesce(sum(p.amount), 0) AS outstanding_balance
FROM students AS s
LEFT JOIN payments AS p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - coalesce(sum(p.amount), 0) > 0;

-- 2026001 is fully paid, so only 2026002 and 2026003 appear
SELECT * FROM v_fee_balances ORDER BY student_number;


-- (f) Composite index for one student's payments in a date range
-- student_id first for the exact match, paid_on second for the range.
CREATE INDEX ix_payments_student_date ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- With so few rows a sequential scan is cheapest; turning it off for
-- this session shows the index is usable.
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


-- (g) Daily collections and the scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'A day is required';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, count(*), coalesce(sum(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 2);
CALL pr_refresh_collections(CURRENT_DATE - 1);
-- rerun replaces the row instead of adding a second one
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections ORDER BY collection_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q02 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q02'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q02, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: daily at 01:00 for the previous day (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q02_refresh_collections', '0 1 * * *',
                              'CALL q02.pr_refresh_collections(CURRENT_DATE - 1)');
        RAISE NOTICE 'Scheduled q02_refresh_collections at 01:00 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

