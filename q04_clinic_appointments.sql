-- Chanda mapalo
-- Student Number: 202409462
-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling
-- Slots: 09:00, 10:00, 11:00, 12:00. Everything is in schema q04.

DROP SCHEMA IF EXISTS q04 CASCADE;
CREATE SCHEMA q04;
SET search_path TO q04, public;


-- (a) Tables
CREATE TABLE patients (
    patient_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  varchar(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name varchar(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      integer NOT NULL REFERENCES patients(patient_id),
    doctor_id       integer NOT NULL REFERENCES doctors(doctor_id),
    appointment_day date NOT NULL,
    slot_time       time NOT NULL
        CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    status          varchar(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    date PRIMARY KEY,
    booked_count    integer NOT NULL CHECK (booked_count >= 0),
    attended_count  integer NOT NULL CHECK (attended_count >= 0),
    cancelled_count integer NOT NULL CHECK (cancelled_count >= 0)
);


-- (b) Function: a doctor's non-cancelled appointments on a day
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id integer, p_day date)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;

    -- count(*) returns 0 when the day has no bookings
    SELECT count(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;


-- (d) Trigger: no two non-cancelled appointments in the same doctor,
-- day and slot. Created before the procedure is used so every booking
-- is checked. On UPDATE the row being changed is left out of the search.
CREATE OR REPLACE FUNCTION trg_fn_check_clash()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1
        FROM appointments AS a
        WHERE a.doctor_id = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time = NEW.slot_time
          AND a.status <> 'CANCELLED'
          AND a.appointment_id <> NEW.appointment_id
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();


-- (c) Procedure: book an appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id integer,
                                                p_doctor_id integer,
                                                p_day date,
                                                p_slot time)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date must be today or later';
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;


-- (a) Seed data
INSERT INTO patients (full_name) VALUES
('Mwila Chanda'), ('Thandiwe Banda'), ('Lubinda Sakala');

INSERT INTO doctors (full_name) VALUES
('Dr. Ngosa Mumba'), ('Dr. Chileshe Tembo'), ('Dr. Musonda Phiri');

-- Yesterday's appointments (past, so loaded directly with their outcome)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
(2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED');

-- Today and tomorrow through the procedure
CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE, '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE + 1, '10:00');

SELECT * FROM appointments ORDER BY appointment_day, slot_time;

-- loads: doctor 1 has 1 today, doctor 3 has 0 today
SELECT fn_daily_load(1, CURRENT_DATE) AS dr1_today,
       fn_daily_load(3, CURRENT_DATE) AS dr3_today;

-- Rejections
DO $$
BEGIN
    BEGIN
        PERFORM q04.fn_daily_load(99, CURRENT_DATE);
        RAISE NOTICE 'FAILED: unknown doctor accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'fn_daily_load: %', SQLERRM;
    END;
    BEGIN
        CALL q04.pr_book_appointment(2, 1, CURRENT_DATE, '09:00');
        RAISE NOTICE 'FAILED: clash accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'clash: %', SQLERRM;
    END;
    BEGIN
        CALL q04.pr_book_appointment(2, 1, CURRENT_DATE - 1, '11:00');
        RAISE NOTICE 'FAILED: past date accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'past date: %', SQLERRM;
    END;
    BEGIN
        CALL q04.pr_book_appointment(2, 1, CURRENT_DATE, '14:00');
        RAISE NOTICE 'FAILED: unsupported slot accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'bad slot: %', SQLERRM;
    END;
    BEGIN
        CALL q04.pr_book_appointment(99, 1, CURRENT_DATE, '10:00');
        RAISE NOTICE 'FAILED: unknown patient accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'unknown patient: %', SQLERRM;
    END;
    -- a direct UPDATE that moves an appointment into a taken slot
    BEGIN
        UPDATE q04.appointments
        SET doctor_id = 1, appointment_day = CURRENT_DATE, slot_time = '09:00'
        WHERE patient_id = 1 AND doctor_id = 2;
        RAISE NOTICE 'FAILED: clashing update accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'clashing update: %', SQLERRM;
    END;
END;
$$;

-- Updating a row without moving it is allowed, because the row being
-- changed is excluded from the clash search
UPDATE appointments SET status = 'BOOKED'
WHERE doctor_id = 1 AND appointment_day = CURRENT_DATE;

-- A cancelled slot can be booked again: yesterday 10:00 for doctor 1
-- was cancelled, so a past-dated direct insert there is not a clash
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (3, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED');

SELECT * FROM appointments ORDER BY appointment_day, slot_time;


-- (e) View: today's booked appointments
-- Only names and the slot are shown, no other patient details.
CREATE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name,
       d.full_name AS doctor_name, a.slot_time
FROM appointments AS a
JOIN patients AS p ON p.patient_id = a.patient_id
JOIN doctors AS d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;


-- (f) Non-unique index for searches by day and doctor
-- appointment_day first: the daily view and the summary both filter by
-- day, and doctor_id narrows it to one doctor's list for the clash check
-- and fn_daily_load.
CREATE INDEX ix_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN (ANALYZE, COSTS OFF)
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;


-- (g) Daily summary and the scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day date)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'A day is required';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           count(*) FILTER (WHERE status = 'BOOKED'),
           count(*) FILTER (WHERE status = 'ATTENDED'),
           count(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- yesterday: 0 booked, 2 attended, 1 cancelled
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces
SELECT * FROM clinic_summary ORDER BY summary_date;

-- Fix the search path of every function and procedure in this schema,
-- so the triggers and the scheduled job find the q04 tables from any
-- session (pg_cron does not use this file's SET search_path).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine, p.prokind
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'q04'
    LOOP
        EXECUTE format('ALTER %s %s SET search_path = q04, public',
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
        PERFORM cron.schedule('q04_refresh_clinic_summary', '0 1 * * *',
                              'CALL q04.pr_refresh_clinic_summary(CURRENT_DATE - 1)');
        RAISE NOTICE 'Scheduled q04_refresh_clinic_summary at 01:00 daily';
    ELSE
        RAISE NOTICE 'pg_cron is not installed here, so the job was not scheduled';
    END IF;
END;
$$;

