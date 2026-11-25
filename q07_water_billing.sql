-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 7: Water Meter Readings and Billing
-- Tariff: first 10 units K5 each, units above 10 K8 each.
-- Everything is created in the schema q07.

DROP SCHEMA IF EXISTS q07 CASCADE;
CREATE SCHEMA q07;
SET search_path TO q07, public;


-- (a) Tables
CREATE TABLE customers (
    customer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   varchar(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      integer NOT NULL REFERENCES customers(customer_id),
    reading_month    date NOT NULL
        CHECK (reading_month = date_trunc('month', reading_month)::date),
    previous_reading numeric(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  numeric(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id  integer NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      numeric(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid numeric(10,2) NOT NULL DEFAULT 0,
    due_on      date NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date date PRIMARY KEY,
    total_due     numeric(12,2) NOT NULL CHECK (total_due >= 0)
);


-- (b) Function: charge for a number of units
CREATE OR REPLACE FUNCTION fn_water_charge(p_units numeric)
RETURNS numeric
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be zero or more, got %', p_units;
    END IF;

    RETURN round(least(p_units, 10) * 5
               + greatest(p_units - 10, 0) * 8, 2);
END;
$$;


-- (d) Trigger: current reading may not go below the previous one.
-- BEFORE INSERT OR UPDATE, so imports and direct SQL are checked and a
-- rejected reading is never stored.
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading % is below previous reading %',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();


-- (c) Procedure: generate a bill for a reading
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id integer, p_due_on date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_units numeric(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT current_reading - previous_reading INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;


-- (a) Seed data: units 0, 10 exactly, and above 10
INSERT INTO customers (full_name) VALUES
('Hope Chileshe'), ('Isaac Mutale'), ('Jane Nyirenda');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, DATE '2026-09-01', 100.00, 100.00),   -- 0 units
(1, DATE '2026-10-01', 100.00, 110.00),   -- 10 units
(2, DATE '2026-09-01', 250.00, 265.00),   -- 15 units
(2, DATE '2026-10-01', 265.00, 277.50),   -- 12.5 units
(3, DATE '2026-09-01',  40.00,  48.00),   -- 8 units
(3, DATE '2026-10-01',  48.00,  70.00);   -- 22 units

-- function checks: 0, 50.00, 50.00, 90.00, 70.00, 146.00
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10,
       fn_water_charge(10.00) AS u10_00, fn_water_charge(15) AS u15,
       fn_water_charge(12.5) AS u12_5, fn_water_charge(22) AS u22;

-- September bills are already due; October bills are due later
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Payments: customer 3 paid September in full, customer 2 paid part
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;
UPDATE bills SET amount_paid = 40.00 WHERE reading_id = 3;

SELECT b.*, r.current_reading - r.previous_reading AS units
FROM bills AS b JOIN readings AS r ON r.reading_id = b.reading_id
ORDER BY b.bill_id;

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q07.fn_water_charge(-1);
        RAISE NOTICE 'FAILED: negative units accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_water_charge: %', SQLERRM;
    END;
    BEGIN
        PERFORM q07.fn_water_charge(NULL);
        RAISE NOTICE 'FAILED: NULL units accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_water_charge: %', SQLERRM;
    END;
    BEGIN
        CALL q07.pr_generate_bill(99, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown reading accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown reading: %', SQLERRM;
    END;
    BEGIN
        CALL q07.pr_generate_bill(1, CURRENT_DATE);
        RAISE NOTICE 'FAILED: second bill accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'second bill: %', SQLERRM;
    END;
    -- a direct import with the meter going backwards
    BEGIN
        INSERT INTO q07.readings (customer_id, reading_month, previous_reading, current_reading)
        VALUES (3, DATE '2026-11-01', 70.00, 65.00);
        RAISE NOTICE 'FAILED: backwards reading stored';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'backwards reading: %', SQLERRM;
    END;
END;
$$;

-- the rejected reading was not stored (still 6)
SELECT count(*) AS readings FROM readings;


-- (e) View: overdue bills that are not fully paid
CREATE VIEW v_overdue_bills AS
SELECT b.bill_id, c.full_name, b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills AS b
JOIN readings AS r ON r.reading_id = b.reading_id
JOIN customers AS c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Isaac owes 50.00 on September; Hope's 0.00 bill and Jane's paid bill
-- do not appear
SELECT * FROM v_overdue_bills ORDER BY due_on, full_name;


-- (f) Index for date-based overdue searches
-- A partial index on due_on that only holds unpaid bills. Paid bills,
-- which become most of the table over time, are left out, and the
-- index condition matches the view's "amount_paid < charge" filter.
CREATE INDEX ix_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;
RESET enable_seqscan;


-- (g) Receivables snapshot and the scheduled job
-- Total unpaid balance on all bills today; a rerun replaces the row.
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, coalesce(sum(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

-- 50.00 + 50.00 + 70.00 + 146.00 = 316.00
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q07 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q07'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q07, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: daily at 00:30 (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q07_refresh_receivables', '30 0 * * *',
                              'CALL q07.pr_refresh_receivables()');
        RAISE NOTICE 'Scheduled q07_refresh_receivables at 00:30 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

