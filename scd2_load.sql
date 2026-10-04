/* =====================================================================
   SCD Type 2 на Oracle (12c+): date_begin / date_end / is_active (0/1)
   Источник : SRC_CUSTOMER        (полный снимок, PK = customer_id)
   Приемник : DIM_CUSTOMER_SCD2   (история изменений)

   Логика за один запуск:
     1) SOFT DELETE  - активные записи, которых больше нет в источнике,
                       закрываются (is_active = 0, date_end = дата загрузки)
     2) CLOSE        - активные записи, у которых изменились атрибуты,
                       закрываются
     3) INSERT       - вставляются новые версии: для новых ключей,
                       для измененных (после шага 2) и для "воскресших"
                       после удаления
   Интервал версии полуоткрытый: [date_begin, date_end).
   Для активной записи date_end = 9999-12-31.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 1. Таблицы (пример - подставьте свои имена и атрибуты)
-- ---------------------------------------------------------------------
CREATE TABLE src_customer (
    customer_id  NUMBER         NOT NULL,
    full_name    VARCHAR2(200),
    email        VARCHAR2(200),
    city         VARCHAR2(100),
    status       VARCHAR2(30),
    CONSTRAINT pk_src_customer PRIMARY KEY (customer_id)
);

CREATE TABLE dim_customer_scd2 (
    sk           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- суррогатный ключ
    customer_id  NUMBER         NOT NULL,                          -- бизнес-ключ
    full_name    VARCHAR2(200),
    email        VARCHAR2(200),
    city         VARCHAR2(100),
    status       VARCHAR2(30),
    hash_diff    RAW(32)        NOT NULL,                          -- хеш отслеживаемых атрибутов
    date_begin   DATE           NOT NULL,
    date_end     DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_active    NUMBER(1)      DEFAULT 1 NOT NULL,
    CONSTRAINT ck_dim_customer_active CHECK (is_active IN (0, 1))
);

-- не более одной активной версии на бизнес-ключ
CREATE UNIQUE INDEX ux_dim_customer_active
    ON dim_customer_scd2 (CASE WHEN is_active = 1 THEN customer_id END);

CREATE INDEX ix_dim_customer_bk ON dim_customer_scd2 (customer_id, is_active);

-- ---------------------------------------------------------------------
-- 2. Представление источника с хешем (единое место для списка атрибутов)
--    NULL-безопасно: NULL заменяется маркером, поля разделены '|'
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_src_customer AS
SELECT s.customer_id,
       s.full_name,
       s.email,
       s.city,
       s.status,
       STANDARD_HASH(
              NVL(s.full_name, '~null~') || '|' ||
              NVL(s.email,     '~null~') || '|' ||
              NVL(s.city,      '~null~') || '|' ||
              NVL(s.status,    '~null~'),
              'SHA256') AS hash_diff
FROM   src_customer s;

-- ---------------------------------------------------------------------
-- 3. Процедура загрузки
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE p_load_dim_customer_scd2 (
    p_load_dt IN DATE DEFAULT SYSDATE      -- дата/время "среза" (можно передать явно)
) AS
    c_max_date  CONSTANT DATE := DATE '9999-12-31';
    v_deleted   PLS_INTEGER := 0;
    v_changed   PLS_INTEGER := 0;
    v_inserted  PLS_INTEGER := 0;
BEGIN
    ------------------------------------------------------------------
    -- 1) SOFT DELETE: запись есть в приемнике (активная), но пропала в источнике
    ------------------------------------------------------------------
    UPDATE dim_customer_scd2 t
       SET t.date_end  = p_load_dt,
           t.is_active = 0
     WHERE t.is_active = 1
       AND NOT EXISTS (SELECT 1
                         FROM v_src_customer s
                        WHERE s.customer_id = t.customer_id);
    v_deleted := SQL%ROWCOUNT;

    ------------------------------------------------------------------
    -- 2) CLOSE: у активной записи изменились атрибуты - закрываем версию
    ------------------------------------------------------------------
    UPDATE dim_customer_scd2 t
       SET t.date_end  = p_load_dt,
           t.is_active = 0
     WHERE t.is_active = 1
       AND EXISTS (SELECT 1
                     FROM v_src_customer s
                    WHERE s.customer_id = t.customer_id
                      AND s.hash_diff  <> t.hash_diff);
    v_changed := SQL%ROWCOUNT;

    ------------------------------------------------------------------
    -- 3) INSERT: новые ключи + новые версии измененных + вернувшиеся после удаления
    --    (все, у кого сейчас нет активной записи в приемнике)
    ------------------------------------------------------------------
    INSERT INTO dim_customer_scd2
           (customer_id, full_name, email, city, status,
            hash_diff, date_begin, date_end, is_active)
    SELECT s.customer_id, s.full_name, s.email, s.city, s.status,
           s.hash_diff, p_load_dt, c_max_date, 1
      FROM v_src_customer s
     WHERE NOT EXISTS (SELECT 1
                         FROM dim_customer_scd2 t
                        WHERE t.customer_id = s.customer_id
                          AND t.is_active   = 1);
    v_inserted := SQL%ROWCOUNT;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('SCD2 load @ ' || TO_CHAR(p_load_dt, 'YYYY-MM-DD HH24:MI:SS')
                      || ' | soft deleted: ' || v_deleted
                      || ' | closed (changed): ' || v_changed
                      || ' | inserted (new + new versions): ' || v_inserted);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;   -- пробрасываем ошибку вызывающему (или пишите в свою таблицу логов)
END p_load_dim_customer_scd2;
/

-- ---------------------------------------------------------------------
-- 4. Пример проверки
-- ---------------------------------------------------------------------
/*
SET SERVEROUTPUT ON

INSERT INTO src_customer VALUES (1, 'Иван Иванов',  'ivan@mail.kz',  'Astana', 'NEW');
INSERT INTO src_customer VALUES (2, 'Петр Петров',  'petr@mail.kz',  'Almaty', 'NEW');
COMMIT;
EXEC p_load_dim_customer_scd2(SYSDATE);          -- 2 insert

UPDATE src_customer SET city = 'Shymkent' WHERE customer_id = 1;   -- изменение
DELETE FROM src_customer WHERE customer_id = 2;                    -- удаление
INSERT INTO src_customer VALUES (3, 'Анна Сидорова', 'anna@mail.kz', 'Astana', 'NEW'); -- новая
COMMIT;
EXEC p_load_dim_customer_scd2(SYSDATE + 1);      -- 1 deleted, 1 closed, 2 inserted

SELECT customer_id, city, date_begin, date_end, is_active
  FROM dim_customer_scd2
 ORDER BY customer_id, date_begin;
*/
