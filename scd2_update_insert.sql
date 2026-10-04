/* =====================================================================
   SCD2 на Oracle (12c+): без MERGE, три простых оператора, MD5

   Источник : SRC_CUSTOMER        (полный снимок, PK = customer_id)
   Приемник : DIM_CUSTOMER_SCD2

   Шаги:
     1) soft delete - активные записи, которых нет в источнике, закрываются
     2) закрытие    - активные записи с изменившимся хешем закрываются
     3) insert      - новые версии для всех ключей без активной записи
                      (новые, изменившиеся, вернувшиеся после удаления)

   Закрытая версия : date_end = TRUNC(SYSDATE) - 1, is_active = 0
   Новая версия    : date_begin = TRUNC(SYSDATE), date_end = 9999-12-31, is_active = 1
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

-- Для контроля "одна активная версия на ключ" можно добавить (шаги идут
-- последовательно, поэтому конфликтов не будет):
-- CREATE UNIQUE INDEX ux_dim_customer_active
--     ON dim_customer_scd2 (CASE WHEN is_active = 1 THEN customer_id END);

-- 2. Представление источника с MD5-хешем (список атрибутов меняется только здесь)
CREATE OR REPLACE VIEW v_src_customer AS
SELECT customer_id, full_name, email, city, status,
       STANDARD_HASH(NVL(full_name, '~') || '|' ||
                     NVL(email,     '~') || '|' ||
                     NVL(city,      '~') || '|' ||
                     NVL(status,    '~'), 'MD5') AS hash_diff
  FROM src_customer;

-- 3. Процедура
CREATE OR REPLACE PROCEDURE p_load_dim_customer_scd2 AS
    c_max_date CONSTANT DATE := DATE '9999-12-31';
    v_today    CONSTANT DATE := TRUNC(SYSDATE);
    v_deleted  PLS_INTEGER;
    v_changed  PLS_INTEGER;
    v_inserted PLS_INTEGER;
BEGIN
    -- 1) SOFT DELETE: в приемнике активна, в источнике нет
    UPDATE dim_customer_scd2 t
       SET t.date_end  = v_today - 1,
           t.is_active = 0
     WHERE t.is_active = 1
       AND NOT EXISTS (SELECT 1
                         FROM v_src_customer s
                        WHERE s.customer_id = t.customer_id);
    v_deleted := SQL%ROWCOUNT;

    -- 2) Закрываем активные версии, у которых изменились атрибуты
    UPDATE dim_customer_scd2 t
       SET t.date_end  = v_today - 1,
           t.is_active = 0
     WHERE t.is_active = 1
       AND EXISTS (SELECT 1
                     FROM v_src_customer s
                    WHERE s.customer_id = t.customer_id
                      AND s.hash_diff  <> t.hash_diff);
    v_changed := SQL%ROWCOUNT;

    -- 3) INSERT: все, у кого сейчас нет активной версии
    INSERT INTO dim_customer_scd2
           (customer_id, full_name, email, city, status,
            hash_diff, date_begin, date_end, is_active)
    SELECT s.customer_id, s.full_name, s.email, s.city, s.status,
           s.hash_diff, v_today, c_max_date, 1
      FROM v_src_customer s
     WHERE NOT EXISTS (SELECT 1
                         FROM dim_customer_scd2 t
                        WHERE t.customer_id = s.customer_id
                          AND t.is_active   = 1);
    v_inserted := SQL%ROWCOUNT;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('SCD2 customer | soft deleted: ' || v_deleted ||
                         ' | closed (changed): ' || v_changed ||
                         ' | inserted: ' || v_inserted);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END p_load_dim_customer_scd2;
/

-- 4. Проверка
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
