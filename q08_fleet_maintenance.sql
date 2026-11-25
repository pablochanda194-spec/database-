-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance
-- A vehicle is due for service after 5,000 km since its last service.
-- Everything is created in the schema q08.

DROP SCHEMA IF EXISTS q08 CASCADE;
CREATE SCHEMA q08;
SET search_path TO q08, public;


-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration          varchar(15) NOT NULL UNIQUE,
    current_odometer      integer NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer integer NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     integer NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        date NOT NULL,
    start_odometer integer NOT NULL CHECK (start_odometer >= 0),
    end_odometer   integer NOT NULL,
    CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       integer PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service integer NOT NULL CHECK (km_since_service >= 0),
    flagged_on       date NOT NULL
);


-- (b) Function: is a service due?
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id integer)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_km integer;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;


-- (c) Procedure: record a trip
-- The procedure only checks the inputs and inserts. The trigger below
-- checks the start against the odometer and moves the odometer on, so
-- the odometer is updated in one place only.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id integer,
                                           p_trip_on date,
                                           p_start integer,
                                           p_end integer)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer % must be greater than start odometer %', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;


-- (d) Trigger: check the start and move the odometer
-- BEFORE INSERT FOR EACH ROW runs once per trip, so the odometer is
-- updated exactly once per trip. The vehicle row is locked so two trips
-- cannot start from the same reading. If the insert fails afterwards,
-- the odometer update is rolled back with it.
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_current integer;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
            v_current, NEW.start_odometer;
    END IF;
    IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'End odometer must be greater than start odometer';
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();


-- (a) Seed data
-- ABC 1001: 1,000 km since service, stays below the limit
-- BCD 2002: 4,000 km since service, crosses 5,000 after its trips
-- CDE 3003: 6,000 km since service, already due
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ABC 1001', 10000,  9000),
('BCD 2002', 20000, 16000),
('CDE 3003', 30000, 24000);

-- Trips loaded through the procedure after the trigger exists
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10250);
CALL pr_record_trip(2, CURRENT_DATE - 6, 20000, 20600);
CALL pr_record_trip(3, CURRENT_DATE - 5, 30000, 30150);
CALL pr_record_trip(1, CURRENT_DATE - 4, 10250, 10400);
CALL pr_record_trip(2, CURRENT_DATE - 3, 20600, 21200);
CALL pr_record_trip(3, CURRENT_DATE - 2, 30150, 30500);

SELECT * FROM trips ORDER BY trip_id;
-- odometers moved to 10400, 21200 and 30500
SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       current_odometer - last_service_odometer AS km_since_service,
       fn_service_due(vehicle_id) AS service_due
FROM vehicles ORDER BY vehicle_id;

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q08.fn_service_due(99);
        RAISE NOTICE 'FAILED: unknown vehicle accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_service_due: %', SQLERRM;
    END;
    BEGIN
        CALL q08.pr_record_trip(1, CURRENT_DATE, 10400, 10300);
        RAISE NOTICE 'FAILED: end before start accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'end before start: %', SQLERRM;
    END;
    BEGIN
        CALL q08.pr_record_trip(1, CURRENT_DATE, 9000, 9500);
        RAISE NOTICE 'FAILED: wrong start accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'wrong start: %', SQLERRM;
    END;
    -- direct SQL is checked by the trigger too
    BEGIN
        INSERT INTO q08.trips (vehicle_id, trip_on, start_odometer, end_odometer)
        VALUES (2, CURRENT_DATE, 25000, 25100);
        RAISE NOTICE 'FAILED: direct trip with wrong start accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'direct insert: %', SQLERRM;
    END;
END;
$$;

-- still 6 trips and the same odometers
SELECT count(*) AS trips FROM trips;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;


-- (e) View: vehicles that currently need a service
CREATE VIEW v_service_due AS
SELECT vehicle_id, registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- BCD 2002 (5,200 km) and CDE 3003 (6,500 km)
SELECT * FROM v_service_due ORDER BY registration;


-- (f) Index for one vehicle's trips in a date range
-- vehicle_id first for the exact match, trip_on second for the range.
CREATE INDEX ix_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;


-- (g) Service alerts and the scheduled job
-- Due vehicles get one alert row (inserted or updated); vehicles that
-- are no longer due have their alert removed.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, km_since_service, CURRENT_DATE
    FROM v_service_due
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    DELETE FROM service_alerts AS a
    WHERE NOT EXISTS (SELECT 1 FROM v_service_due AS d
                      WHERE d.vehicle_id = a.vehicle_id);
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- vehicles 2 and 3

-- CDE 3003 is serviced, so its alert is removed on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();   -- rerun: still one row for vehicle 2
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q08 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q08'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q08, public',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
                       r.routine);
    END LOOP;
END;
$$;

-- Schedule: every Monday at 06:00 (pg_cron)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q08_refresh_service_alerts', '0 6 * * 1',
                              'CALL q08.pr_refresh_service_alerts()');
        RAISE NOTICE 'Scheduled q08_refresh_service_alerts on Mondays at 06:00';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

