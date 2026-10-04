/* =====================================================================
   SCD2 на Oracle (12c+): одна таблица = одна процедура, один MERGE, MD5

   Источник : SRC_CUSTOMER        (полный снимок, PK = customer_id)
   Приемник : DIM_CUSTOMER_SCD2

   Правила:
     новая запись / изменилась  -> date_begin = TRUNC(SYSDATE), date_end = 9999-12-31, is_active = 1
     старая версия при изменении -> date_end = TRUNC(SYSDATE) - 1, is_active = 0
     запись пропала в источнике  -> soft delete: date_end = TRUNC(SYSDATE) - 1, is_active = 0
   ===================================================================== */

-- 1. Таблицы (пример)
CREATE TABLE src_customer (
    customer_id NUMBER PRIMARY KEY,
    full_name   VARCHAR2(200),
    email       VARCHAR2(200),
    city        VARCHAR2(100),
    status      VARCHAR2(30)
);

CREATE TABLE dim_customer_scd2 (
    sk          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id NUMBER    NOT NULL,
    full_name   VARCHAR2(200),
    email       VARCHAR2(200),
    city        VARCHAR2(100),
    status      VARCHAR2(30),
    hash_diff   RAW(16)   NOT NULL,                              -- MD5 = 16 байт
    date_begin  DATE      NOT NULL,
    date_end    DATE      DEFAULT DATE '9999-12-31' NOT NULL,
    is_active   NUMBER(1) DEFAULT 1 NOT NULL,
    CONSTRAINT ck_dim_customer_active CHECK (is_active IN (0, 1))
);

CREATE INDEX ix_dim_customer_bk ON dim_customer_scd2 (customer_id, is_active);

-- 2. Процедура
CREATE OR REPLACE PROCEDURE p_load_dim_customer_scd2 AS
    c_max_date CONSTANT DATE := DATE '9999-12-31';
    v_today    CONSTANT DATE := TRUNC(SYSDATE);
BEGIN
    MERGE INTO dim_customer_scd2 t
    USING (
        WITH s AS (
            SELECT customer_id, full_name, email, city, status,
                   STANDARD_HASH(NVL(full_name, '~') || '|' ||
                                 NVL(email,     '~') || '|' ||
                                 NVL(city,      '~') || '|' ||
                                 NVL(status,    '~'), 'MD5') AS hash_diff
              FROM src_customer
        )
        -- C: активная версия изменилась -> закрыть
        SELECT d.ROWID AS rid, 'C' AS op,
               s.customer_id, s.full_name, s.email, s.city, s.status, s.hash_diff
          FROM s
          JOIN dim_customer_scd2 d
            ON d.customer_id = s.customer_id
           AND d.is_active   = 1
         WHERE d.hash_diff <> s.hash_diff
        UNION ALL
        -- I: нет актуальной версии (новая / изменившаяся / вернувшаяся) -> вставить
        SELECT NULL, 'I',
               s.customer_id, s.full_name, s.email, s.city, s.status, s.hash_diff
          FROM s
         WHERE NOT EXISTS (SELECT 1
                             FROM dim_customer_scd2 d
                            WHERE d.customer_id = s.customer_id
                              AND d.is_active   = 1
                              AND d.hash_diff   = s.hash_diff)
        UNION ALL
        -- D: в источнике записи больше нет -> soft delete
        SELECT d.ROWID, 'D',
               d.customer_id, NULL, NULL, NULL, NULL, NULL
          FROM dim_customer_scd2 d
         WHERE d.is_active = 1
           AND NOT EXISTS (SELECT 1 FROM s WHERE s.customer_id = d.customer_id)
    ) m
    ON (t.ROWID = m.rid)
    WHEN MATCHED THEN
        UPDATE SET t.date_end  = v_today - 1,
                   t.is_active = 0
    WHEN NOT MATCHED THEN
        INSERT (customer_id, full_name, email, city, status,
                hash_diff, date_begin, date_end, is_active)
        VALUES (m.customer_id, m.full_name, m.email, m.city, m.status,
                m.hash_diff, v_today, c_max_date, 1)
        WHERE m.op = 'I';

    DBMS_OUTPUT.PUT_LINE('SCD2 customer: rows merged = ' || SQL%ROWCOUNT);
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END p_load_dim_customer_scd2;
/

-- 3. Проверка
/*
SET SERVEROUTPUT ON

INSERT INTO src_customer VALUES (1, 'Иван Иванов', 'ivan@mail.kz', 'Astana', 'NEW');
INSERT INTO src_customer VALUES (2, 'Петр Петров', 'petr@mail.kz', 'Almaty', 'NEW');
COMMIT;
EXEC p_load_dim_customer_scd2;

UPDATE src_customer SET city = 'Shymkent' WHERE customer_id = 1;   -- изменение
DELETE FROM src_customer WHERE customer_id = 2;                    -- удаление
INSERT INTO src_customer VALUES (3, 'Анна Сидорова', 'anna@mail.kz', 'Astana', 'NEW');
COMMIT;
EXEC p_load_dim_customer_scd2;

SELECT customer_id, city, date_begin, date_end, is_active
  FROM dim_customer_scd2
 ORDER BY customer_id, date_begin;
*/
