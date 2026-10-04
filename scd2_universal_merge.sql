/* =====================================================================
   УНИВЕРСАЛЬНАЯ ЗАГРУЗКА SCD2 (Oracle 12c+) ОДНИМ MERGE + ЛОГ

   p_load_scd2(
       p_src_table      - источник (таблица/представление, можно schema.name)
       p_tgt_table      - приемник SCD2 (можно schema.name)
       p_key_cols       - бизнес-ключ, через запятую: 'CUSTOMER_ID' или 'A_ID,B_ID'
       p_attr_cols      - отслеживаемые атрибуты через запятую;
                          NULL = все колонки источника, кроме ключа
       p_load_dt        - дата среза (date_begin новой версии / date_end закрытой)
       p_detect_deletes - 'Y' = soft delete записей, пропавших в источнике
       p_commit         - 'Y' = COMMIT после MERGE
       p_col_*          - имена служебных колонок приемника
   )

   Как работает единый MERGE (источник MERGE = UNION ALL из трех наборов):
     'C' - активная версия изменилась  -> MATCHED: закрыть (is_active=0, date_end)
     'D' - ключа нет в источнике       -> MATCHED: закрыть (soft delete)
     'I' - нет актуальной версии       -> NOT MATCHED: вставить новую версию
           (новый ключ / изменившийся / вернувшийся после удаления)
   Связка строк MERGE идет по t.ROWID (ON не содержит обновляемых колонок,
   поэтому нет ORA-38104).

   Требования к приемнику: колонки ключа и атрибутов (те же имена, что в
   источнике) + служебные: HASH_DIFF RAW(32), DATE_BEGIN DATE, DATE_END DATE,
   IS_ACTIVE NUMBER(1). Суррогатный ключ (identity/sequence) допускается.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 1. ЛОГ-ТАБЛИЦА
-- ---------------------------------------------------------------------
CREATE TABLE etl_scd2_log (
    log_id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proc_name           VARCHAR2(128)  DEFAULT 'P_LOAD_SCD2',
    src_table           VARCHAR2(300),
    tgt_table           VARCHAR2(300),
    key_cols            VARCHAR2(1000),
    attr_cols           VARCHAR2(4000),
    load_dt             DATE,
    start_ts            TIMESTAMP(6)   DEFAULT SYSTIMESTAMP NOT NULL,
    end_ts              TIMESTAMP(6),
    status              VARCHAR2(10)   DEFAULT 'RUNNING' NOT NULL,
    rows_src            NUMBER,        -- строк в источнике
    rows_inserted       NUMBER,        -- вставлено новых версий (new + changed + reappeared)
    rows_closed_changed NUMBER,        -- закрыто из-за изменений
    rows_closed_deleted NUMBER,        -- закрыто из-за удаления в источнике (soft delete)
    rows_merged         NUMBER,        -- SQL%ROWCOUNT MERGE (контроль: = inserted + changed + deleted)
    sql_text            CLOB,          -- выполненный MERGE (для отладки)
    error_code          NUMBER,
    error_msg           VARCHAR2(4000),
    error_backtrace     VARCHAR2(4000),
    db_user             VARCHAR2(128)  DEFAULT SYS_CONTEXT('USERENV','SESSION_USER'),
    CONSTRAINT ck_etl_scd2_log_status CHECK (status IN ('RUNNING','SUCCESS','ERROR'))
);

-- ---------------------------------------------------------------------
-- 2. ЛОГИРОВАНИЕ В АВТОНОМНЫХ ТРАНЗАКЦИЯХ
--    (запись об ошибке сохраняется, даже если основная транзакция откатилась)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION f_scd2_log_start (
    p_src_table IN VARCHAR2,
    p_tgt_table IN VARCHAR2,
    p_key_cols  IN VARCHAR2,
    p_attr_cols IN VARCHAR2,
    p_load_dt   IN DATE
) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_id NUMBER;
BEGIN
    INSERT INTO etl_scd2_log (src_table, tgt_table, key_cols, attr_cols, load_dt)
    VALUES (SUBSTR(p_src_table,1,300), SUBSTR(p_tgt_table,1,300),
            SUBSTR(p_key_cols,1,1000), SUBSTR(p_attr_cols,1,4000), p_load_dt)
    RETURNING log_id INTO v_id;
    COMMIT;
    RETURN v_id;
END f_scd2_log_start;
/

CREATE OR REPLACE PROCEDURE p_scd2_log_finish (
    p_log_id   IN NUMBER,
    p_status   IN VARCHAR2,
    p_rows_src IN NUMBER   DEFAULT NULL,
    p_ins      IN NUMBER   DEFAULT NULL,
    p_chg      IN NUMBER   DEFAULT NULL,
    p_del      IN NUMBER   DEFAULT NULL,
    p_merged   IN NUMBER   DEFAULT NULL,
    p_sql      IN CLOB     DEFAULT NULL,
    p_err_code IN NUMBER   DEFAULT NULL,
    p_err_msg  IN VARCHAR2 DEFAULT NULL,
    p_err_bt   IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    UPDATE etl_scd2_log
       SET end_ts              = SYSTIMESTAMP,
           status              = p_status,
           rows_src            = p_rows_src,
           rows_inserted       = p_ins,
           rows_closed_changed = p_chg,
           rows_closed_deleted = p_del,
           rows_merged         = p_merged,
           sql_text            = p_sql,
           error_code          = p_err_code,
           error_msg           = SUBSTR(p_err_msg, 1, 4000),
           error_backtrace     = SUBSTR(p_err_bt,  1, 4000)
     WHERE log_id = p_log_id;
    COMMIT;
END p_scd2_log_finish;
/

-- ---------------------------------------------------------------------
-- 3. УНИВЕРСАЛЬНАЯ ПРОЦЕДУРА
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE p_load_scd2 (
    p_src_table      IN VARCHAR2,
    p_tgt_table      IN VARCHAR2,
    p_key_cols       IN VARCHAR2,
    p_attr_cols      IN VARCHAR2 DEFAULT NULL,
    p_load_dt        IN DATE     DEFAULT SYSDATE,
    p_detect_deletes IN VARCHAR2 DEFAULT 'Y',
    p_commit         IN VARCHAR2 DEFAULT 'Y',
    p_col_date_begin IN VARCHAR2 DEFAULT 'DATE_BEGIN',
    p_col_date_end   IN VARCHAR2 DEFAULT 'DATE_END',
    p_col_is_active  IN VARCHAR2 DEFAULT 'IS_ACTIVE',
    p_col_hash       IN VARCHAR2 DEFAULT 'HASH_DIFF'
) AS
    TYPE t_list IS TABLE OF VARCHAR2(128) INDEX BY PLS_INTEGER;
    TYPE t_vc   IS TABLE OF VARCHAR2(10)  INDEX BY PLS_INTEGER;
    TYPE t_num  IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;

    c_max_date CONSTANT VARCHAR2(30) := q'[DATE '9999-12-31']';

    v_log_id   NUMBER;
    v_load_dt  DATE := NVL(p_load_dt, SYSDATE);

    v_src      VARCHAR2(300);
    v_tgt      VARCHAR2(300);
    v_src_own  VARCHAR2(128);
    v_src_nm   VARCHAR2(128);
    v_tgt_own  VARCHAR2(128);
    v_tgt_nm   VARCHAR2(128);

    v_dbegin   VARCHAR2(128);
    v_dend     VARCHAR2(128);
    v_act      VARCHAR2(128);
    v_hcol     VARCHAR2(128);

    v_keys     t_list;
    v_attrs    t_list;

    v_dt       VARCHAR2(106);
    v_term     VARCHAR2(1000);
    v_expr     VARCHAR2(32767);
    v_hash     VARCHAR2(32767);

    v_using    CLOB;
    v_merge    CLOB;

    v_ops      t_vc;
    v_cnts     t_num;

    v_cnt      NUMBER;
    v_rows_src NUMBER := 0;
    v_ins      NUMBER := 0;
    v_chg      NUMBER := 0;
    v_del      NUMBER := 0;
    v_merged   NUMBER := 0;

    v_code     NUMBER;
    v_msg      VARCHAR2(4000);
    v_bt       VARCHAR2(4000);

    ---------------------------------------------------------------- helpers
    FUNCTION split_list (p IN VARCHAR2) RETURN t_list IS
        r t_list;
        v VARCHAR2(4000);
        i PLS_INTEGER := 1;
    BEGIN
        LOOP
            v := TRIM(REGEXP_SUBSTR(p, '[^,]+', 1, i));
            EXIT WHEN v IS NULL;
            r(i) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(v));
            i := i + 1;
        END LOOP;
        RETURN r;
    END split_list;

    PROCEDURE split_obj (p IN VARCHAR2, o OUT VARCHAR2, n OUT VARCHAR2) IS
    BEGIN
        IF INSTR(p, '.') > 0 THEN
            o := UPPER(SUBSTR(p, 1, INSTR(p, '.') - 1));
            n := UPPER(SUBSTR(p, INSTR(p, '.') + 1));
        ELSE
            o := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
            n := UPPER(p);
        END IF;
    END split_obj;

    FUNCTION f_col_type (o IN VARCHAR2, n IN VARCHAR2, c IN VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(106);
    BEGIN
        SELECT data_type INTO v
          FROM all_tab_columns
         WHERE owner = o AND table_name = n AND column_name = c;
        RETURN v;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN NULL;
    END f_col_type;

    FUNCTION f_in_list (l IN t_list, v IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. l.COUNT LOOP
            IF l(i) = v THEN RETURN TRUE; END IF;
        END LOOP;
        RETURN FALSE;
    END f_in_list;

    -- применяет шаблон (#C# = имя колонки) к каждому элементу списка
    FUNCTION f_join (p_l IN t_list, p_tpl IN VARCHAR2, p_sep IN VARCHAR2) RETURN VARCHAR2 IS
        r VARCHAR2(32767);
    BEGIN
        FOR i IN 1 .. p_l.COUNT LOOP
            r := r || CASE WHEN i > 1 THEN p_sep END || REPLACE(p_tpl, '#C#', p_l(i));
        END LOOP;
        RETURN r;
    END f_join;

BEGIN
    v_log_id := f_scd2_log_start(p_src_table, p_tgt_table, p_key_cols, p_attr_cols, v_load_dt);

    ------------------------------------------------------------------
    -- Валидация параметров и метаданных
    ------------------------------------------------------------------
    v_src := DBMS_ASSERT.SQL_OBJECT_NAME(p_src_table);
    v_tgt := DBMS_ASSERT.SQL_OBJECT_NAME(p_tgt_table);
    split_obj(v_src, v_src_own, v_src_nm);
    split_obj(v_tgt, v_tgt_own, v_tgt_nm);

    v_dbegin := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_col_date_begin));
    v_dend   := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_col_date_end));
    v_act    := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_col_is_active));
    v_hcol   := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(p_col_hash));

    v_keys := split_list(p_key_cols);
    IF v_keys.COUNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Не задан бизнес-ключ (p_key_cols)');
    END IF;

    IF p_attr_cols IS NULL THEN
        FOR r IN (SELECT column_name
                    FROM all_tab_columns
                   WHERE owner = v_src_own AND table_name = v_src_nm
                   ORDER BY column_id) LOOP
            IF NOT f_in_list(v_keys, r.column_name) THEN
                v_attrs(v_attrs.COUNT + 1) := r.column_name;
            END IF;
        END LOOP;
    ELSE
        v_attrs := split_list(p_attr_cols);
    END IF;
    IF v_attrs.COUNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Нет отслеживаемых атрибутов');
    END IF;

    FOR c IN (SELECT v_dbegin AS c FROM dual UNION ALL SELECT v_dend FROM dual
              UNION ALL SELECT v_act FROM dual UNION ALL SELECT v_hcol FROM dual) LOOP
        IF f_col_type(v_tgt_own, v_tgt_nm, c.c) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'В приемнике нет служебной колонки ' || c.c);
        END IF;
    END LOOP;

    FOR i IN 1 .. v_keys.COUNT LOOP
        IF f_col_type(v_src_own, v_src_nm, v_keys(i)) IS NULL
           OR f_col_type(v_tgt_own, v_tgt_nm, v_keys(i)) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20004, 'Колонка ключа ' || v_keys(i) || ' отсутствует в источнике или приемнике');
        END IF;
    END LOOP;

    FOR i IN 1 .. v_attrs.COUNT LOOP
        IF f_col_type(v_tgt_own, v_tgt_nm, v_attrs(i)) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20005, 'Атрибут ' || v_attrs(i) || ' отсутствует в приемнике');
        END IF;
    END LOOP;

    -- дубли ключа в источнике дали бы ORA-30926
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (SELECT 1 FROM ' || v_src ||
                      ' GROUP BY ' || f_join(v_keys, '#C#', ', ') || ' HAVING COUNT(*) > 1)'
        INTO v_cnt;
    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20006, 'В источнике ' || v_cnt || ' дублей бизнес-ключа');
    END IF;

    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_src INTO v_rows_src;

    ------------------------------------------------------------------
    -- Выражение хеша отслеживаемых атрибутов (NULL-безопасное)
    ------------------------------------------------------------------
    FOR i IN 1 .. v_attrs.COUNT LOOP
        v_dt := f_col_type(v_src_own, v_src_nm, v_attrs(i));
        IF v_dt IS NULL THEN
            RAISE_APPLICATION_ERROR(-20007, 'Атрибут ' || v_attrs(i) || ' отсутствует в источнике');
        END IF;

        v_term := CASE
            WHEN v_dt = 'DATE'                         THEN q'[TO_CHAR(#C#,'YYYYMMDDHH24MISS')]'
            WHEN v_dt LIKE 'TIMESTAMP%'                THEN q'[TO_CHAR(#C#,'YYYYMMDDHH24MISSFF9')]'
            WHEN v_dt IN ('NUMBER','FLOAT','BINARY_FLOAT','BINARY_DOUBLE')
                                                       THEN q'[TO_CHAR(#C#,'TM9','NLS_NUMERIC_CHARACTERS=''.,''')]'
            WHEN v_dt = 'RAW'                          THEN 'RAWTOHEX(#C#)'
            WHEN v_dt IN ('VARCHAR2','CHAR','NVARCHAR2','NCHAR')
                                                       THEN '#C#'
            WHEN v_dt IN ('CLOB','NCLOB','BLOB','LONG','LONG RAW','BFILE','XMLTYPE')
                                                       THEN NULL
            ELSE 'TO_CHAR(#C#)'
        END;
        IF v_term IS NULL THEN
            RAISE_APPLICATION_ERROR(-20008, 'Тип ' || v_dt || ' (колонка ' || v_attrs(i) || ') не поддерживается в хеше');
        END IF;

        v_expr := v_expr || CASE WHEN i > 1 THEN ' || ''|'' || ' END
                         || 'NVL(' || REPLACE(v_term, '#C#', v_attrs(i)) || ',''~null~'')';
    END LOOP;
    v_hash := 'STANDARD_HASH(' || v_expr || ',''SHA256'')';

    ------------------------------------------------------------------
    -- Набор-источник для MERGE: C (changed) / I (insert) / D (deleted)
    ------------------------------------------------------------------
    v_using :=
        'WITH s AS (SELECT ' || f_join(v_keys, '#C#', ', ') || ', ' || f_join(v_attrs, '#C#', ', ') ||
        ', ' || v_hash || ' AS scd_hash FROM ' || v_src || ')' || CHR(10) ||
        -- C: изменившиеся активные версии -> закрыть
        'SELECT t.ROWID AS scd_rid, ''C'' AS scd_op, ' ||
            f_join(v_keys, 's.#C#', ', ') || ', ' || f_join(v_attrs, 's.#C#', ', ') || ', s.scd_hash' || CHR(10) ||
        '  FROM s JOIN ' || v_tgt || ' t ON ' || f_join(v_keys, 't.#C# = s.#C#', ' AND ') ||
            ' AND t.' || v_act || ' = 1' || CHR(10) ||
        ' WHERE t.' || v_hcol || ' <> s.scd_hash' || CHR(10) ||
        ' UNION ALL' || CHR(10) ||
        -- I: нет актуальной версии (новый / изменился / вернулся) -> вставить
        'SELECT NULL, ''I'', ' ||
            f_join(v_keys, 's.#C#', ', ') || ', ' || f_join(v_attrs, 's.#C#', ', ') || ', s.scd_hash' || CHR(10) ||
        '  FROM s WHERE NOT EXISTS (SELECT 1 FROM ' || v_tgt || ' t WHERE ' ||
            f_join(v_keys, 't.#C# = s.#C#', ' AND ') ||
            ' AND t.' || v_act || ' = 1 AND t.' || v_hcol || ' = s.scd_hash)';

    IF UPPER(p_detect_deletes) = 'Y' THEN
        v_using := v_using || CHR(10) || ' UNION ALL' || CHR(10) ||
            -- D: активная версия есть, ключа в источнике нет -> soft delete
            'SELECT t.ROWID, ''D'', ' || f_join(v_keys, 't.#C#', ', ') || ', ' ||
                f_join(v_attrs, 'NULL', ', ') || ', NULL' || CHR(10) ||
            '  FROM ' || v_tgt || ' t WHERE t.' || v_act || ' = 1' ||
            ' AND NOT EXISTS (SELECT 1 FROM s WHERE ' || f_join(v_keys, 's.#C# = t.#C#', ' AND ') || ')';
    END IF;

    v_merge :=
        'MERGE INTO ' || v_tgt || ' t' || CHR(10) ||
        'USING (' || v_using || ') m' || CHR(10) ||
        'ON (t.ROWID = m.scd_rid)' || CHR(10) ||
        'WHEN MATCHED THEN UPDATE SET t.' || v_dend || ' = :b1, t.' || v_act || ' = 0' || CHR(10) ||
        'WHEN NOT MATCHED THEN INSERT (' ||
            f_join(v_keys, '#C#', ', ') || ', ' || f_join(v_attrs, '#C#', ', ') || ', ' ||
            v_hcol || ', ' || v_dbegin || ', ' || v_dend || ', ' || v_act || ')' || CHR(10) ||
        'VALUES (' ||
            f_join(v_keys, 'm.#C#', ', ') || ', ' || f_join(v_attrs, 'm.#C#', ', ') || ', ' ||
            'm.scd_hash, :b2, ' || c_max_date || ', 1)' || CHR(10) ||
        'WHERE m.scd_op = ''I''';

    ------------------------------------------------------------------
    -- Подсчет по типам операций (для лога) и выполнение MERGE
    ------------------------------------------------------------------
    EXECUTE IMMEDIATE 'SELECT scd_op, COUNT(*) FROM (' || v_using || ') GROUP BY scd_op'
        BULK COLLECT INTO v_ops, v_cnts;
    FOR i IN 1 .. v_ops.COUNT LOOP
        IF    v_ops(i) = 'I' THEN v_ins := v_cnts(i);
        ELSIF v_ops(i) = 'C' THEN v_chg := v_cnts(i);
        ELSIF v_ops(i) = 'D' THEN v_del := v_cnts(i);
        END IF;
    END LOOP;

    EXECUTE IMMEDIATE v_merge USING v_load_dt, v_load_dt;
    v_merged := SQL%ROWCOUNT;

    IF UPPER(p_commit) = 'Y' THEN
        COMMIT;
    END IF;

    p_scd2_log_finish(v_log_id, 'SUCCESS', v_rows_src, v_ins, v_chg, v_del, v_merged, v_merge);

    DBMS_OUTPUT.PUT_LINE('SCD2 ' || v_src || ' -> ' || v_tgt ||
                         ' | src: ' || v_rows_src || ' | inserted: ' || v_ins ||
                         ' | closed(changed): ' || v_chg || ' | closed(deleted): ' || v_del ||
                         ' | merged: ' || v_merged || ' | log_id: ' || v_log_id);
EXCEPTION
    WHEN OTHERS THEN
        v_code := SQLCODE;
        v_msg  := SUBSTR(SQLERRM, 1, 4000);
        v_bt   := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
        ROLLBACK;
        IF v_log_id IS NOT NULL THEN
            p_scd2_log_finish(v_log_id, 'ERROR', v_rows_src, v_ins, v_chg, v_del, v_merged,
                              v_merge, v_code, v_msg, v_bt);
        END IF;
        RAISE;
END p_load_scd2;
/

-- ---------------------------------------------------------------------
-- 4. ПРИМЕР: таблицы, запуск, проверка
--    (уникальный индекс именно по (ключ, date_begin): он не конфликтует с
--     порядком обработки строк внутри одного MERGE. Индекс "только одна
--     активная версия" лучше не создавать - при порядке INSERT раньше UPDATE
--     внутри MERGE возможен ORA-00001; единственность активной версии
--     гарантирует логика процедуры.)
-- ---------------------------------------------------------------------
/*
CREATE TABLE src_customer (
    customer_id NUMBER PRIMARY KEY,
    full_name   VARCHAR2(200),
    email       VARCHAR2(200),
    city        VARCHAR2(100),
    status      VARCHAR2(30)
);

CREATE TABLE dim_customer_scd2 (
    sk          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id NUMBER NOT NULL,
    full_name   VARCHAR2(200),
    email       VARCHAR2(200),
    city        VARCHAR2(100),
    status      VARCHAR2(30),
    hash_diff   RAW(32)   NOT NULL,
    date_begin  DATE      NOT NULL,
    date_end    DATE      DEFAULT DATE '9999-12-31' NOT NULL,
    is_active   NUMBER(1) DEFAULT 1 NOT NULL,
    CONSTRAINT ck_dim_cust_active CHECK (is_active IN (0,1))
);
CREATE UNIQUE INDEX ux_dim_cust_bk_begin ON dim_customer_scd2 (customer_id, date_begin);
CREATE INDEX ix_dim_cust_bk_active       ON dim_customer_scd2 (customer_id, is_active);

SET SERVEROUTPUT ON

INSERT INTO src_customer VALUES (1,'Иван Иванов','ivan@mail.kz','Astana','NEW');
INSERT INTO src_customer VALUES (2,'Петр Петров','petr@mail.kz','Almaty','NEW');
COMMIT;

BEGIN
    p_load_scd2(p_src_table => 'SRC_CUSTOMER',
                p_tgt_table => 'DIM_CUSTOMER_SCD2',
                p_key_cols  => 'CUSTOMER_ID',
                p_attr_cols => 'FULL_NAME,EMAIL,CITY,STATUS',   -- или NULL = все колонки
                p_load_dt   => SYSDATE);
END;
/

UPDATE src_customer SET city = 'Shymkent' WHERE customer_id = 1;   -- изменение
DELETE FROM src_customer WHERE customer_id = 2;                    -- удаление
INSERT INTO src_customer VALUES (3,'Анна Сидорова','anna@mail.kz','Astana','NEW');
COMMIT;

EXEC p_load_scd2('SRC_CUSTOMER','DIM_CUSTOMER_SCD2','CUSTOMER_ID', NULL, SYSDATE + 1);

SELECT customer_id, city, date_begin, date_end, is_active
  FROM dim_customer_scd2 ORDER BY customer_id, date_begin;

SELECT log_id, status, rows_src, rows_inserted, rows_closed_changed,
       rows_closed_deleted, rows_merged, error_msg, start_ts, end_ts
  FROM etl_scd2_log ORDER BY log_id DESC;

-- составной ключ и произвольные имена служебных колонок:
-- EXEC p_load_scd2('STG.ORDERS','DWH.ORDERS_H','ORDER_ID,LINE_NO',NULL,SYSDATE,'Y','Y',
--                  'VALID_FROM','VALID_TO','ACTUAL_FLAG','ROW_HASH');
*/
