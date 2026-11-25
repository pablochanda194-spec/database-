-- chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales
-- Everything is created in the schema q01.

DROP SCHEMA IF EXISTS q01 CASCADE;
CREATE SCHEMA q01;
SET search_path TO q01, public;


-- (a) Tables
CREATE TABLE medicines (
    medicine_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name varchar(100) NOT NULL UNIQUE,
    unit_price    numeric(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     integer NOT NULL CHECK (stock_qty >= 0)
);

-- unit_price here is the price at the time of the sale, so later price
-- changes do not alter old sales.
CREATE TABLE sales (
    sale_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id integer NOT NULL REFERENCES medicines(medicine_id),
    quantity    integer NOT NULL CHECK (quantity > 0),
    unit_price  numeric(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     date NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id integer NOT NULL REFERENCES medicines(medicine_id),
    old_qty     integer NOT NULL,
    new_qty     integer NOT NULL,
    changed_at  timestamptz NOT NULL DEFAULT current_timestamp
);

CREATE TABLE daily_sales (
    sales_date   date PRIMARY KEY,
    total_qty    integer NOT NULL CHECK (total_qty >= 0),
    total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0)
);


-- (b) Function: current price x quantity
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id integer, p_quantity integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_price numeric(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive whole number';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


-- (c) Procedure: record one sale
-- The medicine row is locked FOR UPDATE so two sales at the same time
-- cannot both use the same stock. All checks run before any change, and
-- any error cancels the whole CALL, so an invalid sale changes nothing.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id integer,
                                           p_quantity integer,
                                           p_sold_on date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock integer;
    v_price numeric(10,2);
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive whole number';
    END IF;

    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Not enough stock for medicine %: % available, % requested',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- stock is deducted once, here only
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;


-- (d) Trigger: audit stock changes
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

-- The WHEN clause means a price change, or an update that leaves the
-- stock the same, does not write an audit row.
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();


-- (a) Seed data: three medicines, then six sales through the procedure
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol 500mg', 2.50, 100),
('Amoxicillin 250mg', 8.00, 30),
('Cough Syrup 100ml', 35.00, 15);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2, 5,  CURRENT_DATE - 2);
CALL pr_record_sale(3, 2,  CURRENT_DATE - 2);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 6,  CURRENT_DATE - 1);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
-- one audit row per sale (6), each showing old and new stock
SELECT * FROM stock_audit ORDER BY audit_id;

-- function checks
SELECT fn_sale_value(2, 3) AS amoxicillin_x3;     -- expected 24.00

DO $$
BEGIN
    PERFORM q01.fn_sale_value(99, 1);
    RAISE NOTICE 'FAILED: unknown medicine accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'fn_sale_value rejected: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    PERFORM q01.fn_sale_value(1, 0);
    RAISE NOTICE 'FAILED: zero quantity accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'fn_sale_value rejected: %', SQLERRM;
END;
$$;

-- Invalid sale: more than the 7 cough syrups left. Both tables must be
-- unchanged afterwards.
SELECT (SELECT count(*) FROM sales) AS sales_before,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS syrup_stock_before;

DO $$
BEGIN
    CALL q01.pr_record_sale(3, 50, CURRENT_DATE);
    RAISE NOTICE 'FAILED: oversell accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'pr_record_sale rejected: %', SQLERRM;
END;
$$;

SELECT (SELECT count(*) FROM sales) AS sales_after,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS syrup_stock_after;

-- A price change does not touch stock, so no audit row is added
UPDATE medicines SET unit_price = 36.00 WHERE medicine_id = 3;
SELECT count(*) AS audit_rows FROM stock_audit;   -- still 6


-- (e) View: medicines with fewer than 10 left
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- After the sales above, Cough Syrup has 7 left
SELECT * FROM v_low_stock ORDER BY medicine_name;

-- one more sale takes Amoxicillin from 21 to 9, so it joins the view
CALL pr_record_sale(2, 12, CURRENT_DATE);
SELECT * FROM v_low_stock ORDER BY medicine_name;


-- (f) Index for one medicine's sales in a date range
-- medicine_id comes first because the query matches it exactly; sold_on
-- second lets the index read just the date range for that medicine.
CREATE INDEX ix_sales_medicine_date ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- With only a few rows the planner prefers a sequential scan. Turning
-- that off for this session shows the index can serve the query.
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;


-- (g) Daily totals and the scheduled job
-- ON CONFLICT replaces the day's row, so running it again for the same
-- day gives the same totals instead of adding them twice.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'A day is required';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           coalesce(sum(quantity), 0),
           coalesce(sum(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 2);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;

-- rerun: the same two rows with the same totals
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q01 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q01'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q01, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: every day at 00:15 for the previous day, using pg_cron.
-- The block skips the call where pg_cron is not installed.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q01_refresh_sales', '15 0 * * *',
                              'CALL q01.pr_refresh_sales(CURRENT_DATE - 1)');
        RAISE NOTICE 'Scheduled q01_refresh_sales at 00:15 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

-- Check the job where pg_cron is installed:
--   SELECT jobid, jobname, schedule, command FROM cron.job
--   WHERE jobname = 'q01_refresh_sales';

