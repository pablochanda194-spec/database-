-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries
-- Rates per kg: grade A K5, B K4, C K3. Everything is in schema q09.

DROP SCHEMA IF EXISTS q09 CASCADE;
CREATE SCHEMA q09;
SET search_path TO q09, public;


-- (a) Tables
CREATE TABLE farmers (
    farmer_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number varchar(12) NOT NULL UNIQUE,
    full_name     varchar(100) NOT NULL
);

-- unit_rate and total_value are always set by the trigger
CREATE TABLE deliveries (
    delivery_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id    integer NOT NULL REFERENCES farmers(farmer_id),
    grade        char(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    numeric(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    numeric(6,2) NOT NULL,
    total_value  numeric(12,2) NOT NULL,
    delivered_on date NOT NULL,
    is_paid      boolean NOT NULL DEFAULT false
);

CREATE TABLE daily_purchases (
    purchase_date date PRIMARY KEY,
    total_weight  numeric(12,2) NOT NULL CHECK (total_weight >= 0),
    total_value   numeric(14,2) NOT NULL CHECK (total_value >= 0)
);


-- (b) Function: rate for a grade (lower case and spaces are accepted)
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade text)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_grade text;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_grade := upper(btrim(p_grade));
    IF v_grade = 'A' THEN
        RETURN 5.00;
    ELSIF v_grade = 'B' THEN
        RETURN 4.00;
    ELSIF v_grade = 'C' THEN
        RETURN 3.00;
    END IF;

    RAISE EXCEPTION 'Unsupported grade %', p_grade;
END;
$$;


-- (d) Trigger: price every delivery the same way
-- Runs on INSERT and UPDATE, so direct SQL cannot store a different
-- rate or total.
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    NEW.grade := upper(btrim(NEW.grade));
    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := round(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();


-- (c) Procedure: receive a delivery
-- Only the basic fields are inserted; the trigger fills in the rate and
-- total value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id integer,
                                                p_grade text,
                                                p_weight numeric,
                                                p_date date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer %', p_farmer_id;
    END IF;
    PERFORM fn_maize_rate(p_grade);   -- rejects NULL or unsupported grades
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, upper(btrim(p_grade)), p_weight, p_date, false);
END;
$$;


-- (a) Seed data: all grades, paid and unpaid
INSERT INTO farmers (farmer_number, full_name) VALUES
('F001', 'Kalaba Mwale'),
('F002', 'Lombe Tembo'),
('F003', 'Mapalo Sichone');

CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'B', 750.50, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'c', 300.00, CURRENT_DATE - 2);   -- lower case is accepted
CALL pr_receive_delivery(1, 'B', 400.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A', 250.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 120.25, CURRENT_DATE - 1);

-- Farmer 3 is paid for both deliveries, farmer 1 for the first one
UPDATE deliveries SET is_paid = true WHERE farmer_id = 3;
UPDATE deliveries SET is_paid = true WHERE delivery_id = 1;

SELECT * FROM deliveries ORDER BY delivery_id;

-- A direct insert with a made-up rate and total is corrected by the trigger
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (2, 'C', 100.00, 99.00, 9900.00, CURRENT_DATE);
SELECT delivery_id, grade, weight_kg, unit_rate, total_value
FROM deliveries WHERE delivered_on = CURRENT_DATE;   -- 3.00 and 300.00

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q09.fn_maize_rate('D');
        RAISE NOTICE 'FAILED: grade D accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_maize_rate: %', SQLERRM;
    END;
    BEGIN
        PERFORM q09.fn_maize_rate(NULL);
        RAISE NOTICE 'FAILED: NULL grade accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_maize_rate: %', SQLERRM;
    END;
    BEGIN
        CALL q09.pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown farmer accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown farmer: %', SQLERRM;
    END;
    BEGIN
        CALL q09.pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
        RAISE NOTICE 'FAILED: zero weight accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'zero weight: %', SQLERRM;
    END;
    BEGIN
        UPDATE q09.deliveries SET weight_kg = -5 WHERE delivery_id = 2;
        RAISE NOTICE 'FAILED: negative weight update accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'negative weight update: %', SQLERRM;
    END;
END;
$$;


-- (e) View: unpaid value per farmer, including farmers owed nothing
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       coalesce(sum(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers AS f
LEFT JOIN deliveries AS d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- F001 1600.00, F002 4552.00 (including today's 300.00 direct insert),
-- F003 0.00
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;


-- (f) Composite index for a farmer's deliveries between two dates
-- farmer_id first for the exact match, delivered_on for the range.
CREATE INDEX ix_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;


-- (g) Daily purchases and the scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'A day is required';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, coalesce(sum(weight_kg), 0), coalesce(sum(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 2);
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun replaces, not adds
SELECT * FROM daily_purchases ORDER BY purchase_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q09 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q09'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q09, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: daily at 01:30 for the previous day (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q09_refresh_purchases', '30 1 * * *',
                              'CALL q09.pr_refresh_purchases(CURRENT_DATE - 1)');
        RAISE NOTICE 'Scheduled q09_refresh_purchases at 01:30 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

