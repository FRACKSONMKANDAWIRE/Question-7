-- =====================================================================
-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Name: ________________ | Student number: ____________ | PostgreSQL 16 (PL/pgSQL)
-- Tariff: first 10 units K5 each, units above 10 K8 each. 0 units = K0.
-- =====================================================================

DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path TO q7;

-- ---------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL
        CHECK (reading_month = date_trunc('month', reading_month)::date),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_amount_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Mwila Banda'), ('Natasha Phiri'), ('Chanda Mulenga');
-- Readings are inserted after the trigger in (d) is installed.

-- ---------------------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %. Units must be zero or more.', p_units;
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5.00
               + GREATEST(p_units - 10, 0) * 8.00, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev NUMERIC(12,2);
    v_curr NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id
    FOR UPDATE;   -- stops two sessions billing the same reading

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger [8 marks]
-- BEFORE trigger raises, so a rejected reading is never stored, whether
-- it comes from the application or a direct SQL import.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

-- ---------------------------------------------------------------------
-- (a) continued: six readings covering 0, exactly 10 and above 10 units
-- ---------------------------------------------------------------------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-10-01', 100, 100),   -- 0 units -> K0.00
    (1, DATE '2026-11-01', 100, 110),   -- 10 units -> K50.00
    (2, DATE '2026-10-01',  50,  65),   -- 15 units -> K90.00
    (2, DATE '2026-11-01',  65,  72),   -- 7 units -> K35.00
    (3, DATE '2026-10-01',   0,  10),   -- 10 units -> K50.00
    (3, DATE '2026-11-01',  10,  35);   -- 25 units -> K170.00

-- Bills: October overdue, November not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Some payments
UPDATE bills SET amount_paid = 40.00 WHERE reading_id = 3;   -- part paid (owes 50)
UPDATE bills SET amount_paid = 50.00 WHERE reading_id = 5;   -- fully paid

-- Tests for (b)
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10,
       fn_water_charge(15) AS u15, fn_water_charge(12.5) AS u12_5;  -- 0.00 | 50.00 | 90.00 | 70.00
-- SELECT fn_water_charge(-1); -- ERROR: Invalid consumption
-- SELECT fn_water_charge(NULL); -- ERROR: Invalid consumption

-- Tests for (c)
-- CALL pr_generate_bill(1, CURRENT_DATE); -- ERROR: already has a bill
-- CALL pr_generate_bill(99, CURRENT_DATE); -- ERROR: Unknown reading_id
SELECT b.bill_id, r.customer_id, r.reading_month,
       r.current_reading - r.previous_reading AS units, b.charge, b.amount_paid, b.due_on
FROM bills b JOIN readings r ON r.reading_id = b.reading_id ORDER BY b.bill_id;

-- Tests for (d)
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
-- VALUES (1, DATE '2026-12-01', 110, 90); -- ERROR: below previous_reading, not stored
-- UPDATE readings SET current_reading = 5 WHERE reading_id = 2; -- ERROR, row unchanged
SELECT count(*) AS readings_rows FROM readings;   -- 6

-- ---------------------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;
-- Natasha Phiri | outstanding 50.00 (zero-charge and fully paid bills excluded)

-- ---------------------------------------------------------------------
-- (f) Index [5 marks]
-- Partial index on due_on for unpaid bills only. Overdue searches are
-- "due_on before a date AND not fully paid"; fully paid bills (most of
-- them over time) are left out, and due_on as the key supports the range.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- demo only: tiny table would otherwise use Seq Scan
EXPLAIN ANALYZE
SELECT bill_id, reading_id, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;
RESET enable_seqscan;
-- Plan: Index Scan using idx_bills_unpaid_due_on on bills
-- Index Cond: (due_on < CURRENT_DATE)

-- ---------------------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- Total of all unpaid balances today; ON CONFLICT replaces on rerun.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun replaces the same date
SELECT * FROM receivable_snapshot;   -- today | 305.00

-- Schedule daily at 00:30 (requires pg_cron)
ALTER PROCEDURE q7.pr_refresh_receivables() SET search_path = q7;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $$CALL q7.pr_refresh_receivables()$$
);
