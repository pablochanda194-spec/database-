-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 5: Hostel Room Allocation
-- Everything is created in the schema q05.

DROP SCHEMA IF EXISTS q05 CASCADE;
CREATE SCHEMA q05;
SET search_path TO q05, public;


-- (a) Tables
CREATE TABLE students (
    student_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number varchar(12) NOT NULL UNIQUE,
    full_name      varchar(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number varchar(10) NOT NULL UNIQUE,
    capacity    integer NOT NULL CHECK (capacity > 0)
);

-- ACTIVE must have no release date, ENDED must have one.
CREATE TABLE allocations (
    allocation_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    integer NOT NULL REFERENCES students(student_id),
    room_id       integer NOT NULL REFERENCES rooms(room_id),
    allocated_on  date NOT NULL,
    released_on   date,
    status        varchar(6) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK ((status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL)),
    CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date date NOT NULL,
    room_id       integer NOT NULL REFERENCES rooms(room_id),
    occupied_beds integer NOT NULL CHECK (occupied_beds >= 0),
    free_beds     integer NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);


-- (b) Function: free beds in a room
-- Only ACTIVE allocations take a bed; ENDED ones are history.
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity integer;
    v_active   integer;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room %', p_room_id;
    END IF;

    SELECT count(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;


-- (d) Trigger: capacity and one ACTIVE allocation per student, also for
-- direct SQL. The row being updated is left out when counting others.
-- The room row is locked so two allocations at once cannot both take
-- the last bed.
CREATE OR REPLACE FUNCTION trg_fn_check_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity integer;
    v_others   integer;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND allocation_id <> NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_capacity
        FROM rooms WHERE room_id = NEW.room_id
        FOR UPDATE;

        SELECT count(*) INTO v_others
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id <> NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_allocation();


-- (c) Procedure: allocate a room
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id integer,
                                             p_room_id integer,
                                             p_allocated_on date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    -- fn_free_beds also rejects an unknown room
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;


-- (a) Seed data: R101 full, R102 partly occupied, R103 empty
INSERT INTO students (student_number, full_name) VALUES
('2026101', 'Chilufya Mwanza'),
('2026102', 'Daniel Simwanza'),
('2026103', 'Esther Lungu'),
('2026104', 'Frank Mbewe'),
('2026105', 'Gift Zimba');

INSERT INTO rooms (room_number, capacity) VALUES
('R101', 2), ('R102', 3), ('R103', 2);

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);

-- History: student 4 used to be in R103 and has moved out
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- free beds: R101 0, R102 2, R103 2 (the ENDED row does not count)
SELECT room_number, fn_free_beds(room_id) AS free_beds
FROM rooms ORDER BY room_id;

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q05.fn_free_beds(99);
        RAISE NOTICE 'FAILED: unknown room accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_free_beds: %', SQLERRM;
    END;
    BEGIN
        CALL q05.pr_allocate_room(5, 1, CURRENT_DATE);
        RAISE NOTICE 'FAILED: full room accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'full room: %', SQLERRM;
    END;
    BEGIN
        CALL q05.pr_allocate_room(1, 2, CURRENT_DATE);
        RAISE NOTICE 'FAILED: second ACTIVE allocation accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'second allocation: %', SQLERRM;
    END;
    BEGIN
        CALL q05.pr_allocate_room(99, 2, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown student accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown student: %', SQLERRM;
    END;
    -- direct SQL is checked by the trigger
    BEGIN
        INSERT INTO q05.allocations (student_id, room_id, allocated_on, status)
        VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
        RAISE NOTICE 'FAILED: direct insert into full room accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'direct insert: %', SQLERRM;
    END;
    BEGIN
        UPDATE q05.allocations SET room_id = 1 WHERE student_id = 3 AND status = 'ACTIVE';
        RAISE NOTICE 'FAILED: direct move into full room accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'direct update: %', SQLERRM;
    END;
END;
$$;

-- An update to an ACTIVE row in a full room is allowed, because the row
-- itself is not counted among the "other" allocations
UPDATE allocations SET allocated_on = allocated_on WHERE student_id = 1;

-- Student 2 moves out of R101 and into R102
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE
WHERE student_id = 2 AND status = 'ACTIVE';
CALL pr_allocate_room(2, 2, CURRENT_DATE);

SELECT * FROM allocations ORDER BY allocation_id;


-- (e) View: every room's occupancy, including empty rooms
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       count(a.allocation_id) AS occupied_beds,
       r.capacity - count(a.allocation_id) AS free_beds
FROM rooms AS r
LEFT JOIN allocations AS a
  ON a.room_id = r.room_id
 AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- R101 1 of 2, R102 2 of 3, R103 0 of 2
SELECT * FROM v_room_occupancy ORDER BY room_number;


-- (f) Index for ACTIVE allocations in a room
-- A partial index on room_id that holds only ACTIVE rows. It is used by
-- the capacity check, fn_free_beds and the occupancy view, and ENDED
-- history rows never make it bigger.
CREATE INDEX ix_allocations_room_active ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, COSTS OFF)
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';
RESET enable_seqscan;


-- (g) Daily occupancy snapshot and the scheduled job
-- One row per date and room; a rerun on the same day replaces it.
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- still 3 rows for today
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q05 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q05'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q05, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: daily at 23:55 (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q05_refresh_occupancy', '55 23 * * *',
                              'CALL q05.pr_refresh_occupancy()');
        RAISE NOTICE 'Scheduled q05_refresh_occupancy at 23:55 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

