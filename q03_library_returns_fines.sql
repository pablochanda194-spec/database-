-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines
-- Fine: K2 for each day after the due date. Everything is in schema q03.

DROP SCHEMA IF EXISTS q03 CASCADE;
CREATE SCHEMA q03;
SET search_path TO q03, public;


-- (a) Tables
CREATE TABLE books (
    book_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title   varchar(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id       integer NOT NULL REFERENCES books(book_id),
    borrower_name varchar(100) NOT NULL,
    borrowed_on   date NOT NULL,
    due_on        date NOT NULL,
    returned_on   date,
    fine_amount   numeric(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id         integer NOT NULL REFERENCES loans(loan_id),
    old_returned_on date,
    new_returned_on date,
    changed_at      timestamptz NOT NULL DEFAULT current_timestamp
);

CREATE TABLE overdue_summary (
    snapshot_date date PRIMARY KEY,
    overdue_count integer NOT NULL CHECK (overdue_count >= 0),
    total_fine    numeric(12,2) NOT NULL CHECK (total_fine >= 0)
);


-- (b) Function: fine for a loan as of a date
-- For a returned loan the earlier of p_as_of and returned_on is used, so
-- fines stop growing once the book is back.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id integer, p_as_of date)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      date;
    v_returned date;
    v_end      date;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'An as-of date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        v_end := least(p_as_of, v_returned);
    ELSE
        v_end := p_as_of;
    END IF;

    -- returning on the due date gives 0 days, and never below 0
    RETURN greatest(v_end - v_due, 0) * 2.00;
END;
$$;


-- (c) Procedure: return a loan
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id integer, p_returned_on date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed date;
    v_returned date;
    v_fine     numeric(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    -- return date and final fine are stored in the same UPDATE
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;


-- (d) Trigger: log changes to returned_on
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;   -- AFTER trigger, return value is ignored
END;
$$;

-- IS DISTINCT FROM also treats NULL to a date as a change
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();


-- (a) Seed data: three books and six loans
INSERT INTO books (title) VALUES
('Database System Concepts'),
('Fundamentals of Database Systems'),
('SQL Performance Explained');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Mutale Zulu',   CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL, 0),                -- 1 open, overdue 6 days
(2, 'Bwalya Ngoma',  CURRENT_DATE - 3,  CURRENT_DATE + 11, NULL, 0),                -- 2 open, on time
(3, 'Kondwani Phiri', CURRENT_DATE - 30, CURRENT_DATE - 16, CURRENT_DATE - 16, 0),  -- 3 returned on the due date
(1, 'Grace Lungu',   CURRENT_DATE - 15, CURRENT_DATE - 1,  NULL, 0),                -- 4 open, overdue 1 day
(2, 'Peter Mwale',   CURRENT_DATE - 25, CURRENT_DATE - 11, NULL, 0),                -- 5 open, returned below
(3, 'Alice Banda',   CURRENT_DATE - 10, CURRENT_DATE + 4,  NULL, 0);                -- 6 open, on time

SELECT * FROM books ORDER BY book_id;
SELECT * FROM loans ORDER BY loan_id;

-- fines as of today: loan 1 = 12.00, loan 3 = 0.00 (on the due date)
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today
FROM loans ORDER BY loan_id;

-- Return loan 5 four days late: fine 8.00, one audit row
CALL pr_return_loan(5, CURRENT_DATE - 7);
SELECT loan_id, returned_on, fine_amount FROM loans WHERE loan_id = 5;
SELECT * FROM loan_audit ORDER BY audit_id;

-- loan 5's fine stays 8.00 even when asked about a later date
SELECT fn_loan_fine(5, CURRENT_DATE + 30) AS fine_later;

-- Rejected returns
DO $$
BEGIN
    BEGIN
        CALL q03.pr_return_loan(99, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown loan accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown loan: %', SQLERRM;
    END;
    BEGIN
        CALL q03.pr_return_loan(5, CURRENT_DATE);
        RAISE NOTICE 'FAILED: second return accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'already returned: %', SQLERRM;
    END;
    BEGIN
        CALL q03.pr_return_loan(2, CURRENT_DATE - 10);
        RAISE NOTICE 'FAILED: return before borrowing accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'early return: %', SQLERRM;
    END;
END;
$$;

-- An update that leaves returned_on the same adds no audit row
UPDATE loans SET borrower_name = 'Peter Mwale' WHERE loan_id = 5;
SELECT count(*) AS audit_rows FROM loan_audit;   -- still 1


-- (e) View: open loans past their due date
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans AS l
JOIN books AS b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- loans 1 and 4
SELECT * FROM v_overdue_loans ORDER BY due_on;


-- (f) Index for a book's unreturned loans
-- A partial index holds only open loans, so it stays small and matches
-- the "returned_on IS NULL" search directly.
CREATE INDEX ix_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;


-- (g) Overdue snapshot and the scheduled job
-- Counts loans that were not yet returned on p_as_of and were already
-- past due, and adds up their fines as of that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'An as-of date is required';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           count(*),
           coalesce(sum(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

-- today: loans 1 and 4, fines 12.00 + 2.00 = 14.00
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same row
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q03 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q03'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q03, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: daily at 00:10 for CURRENT_DATE (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q03_refresh_overdue', '10 0 * * *',
                              'CALL q03.pr_refresh_overdue(CURRENT_DATE)');
        RAISE NOTICE 'Scheduled q03_refresh_overdue at 00:10 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

