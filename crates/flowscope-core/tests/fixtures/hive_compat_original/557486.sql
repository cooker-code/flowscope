-- USER-APPROVED TRANSFERS: latest unique cohort, no open-cohort costs or duplicate orders.
-- Source loss, ambiguous cohorts, unsupported unrefreshed closed destinations fail closed.
-- Daily continuity: verified 1018 bootstrap once, then strict previous day.
-- Frozen baseline hashes pinned; full history copied to each new snapshot.
-- Existing policy safety horizon <= 2026-11-16 retained, no new tables.
-- Candidate: single writer lifecycle, two sequential production writes.
-- Prewrite QA is embedded in the final INSERT; old B remains unscheduled.
-- Requires Change multi-statement failure propagation and test confirmation.
-- DAILY ADAPTER: run earliest 08:00; business date is yesterday, any weekday.
-- Select actual closed cohorts (Monday <= date - 7); refresh ages 7..35, renewal capped at +29.
-- Generated locally; not evidence of Spark execution or release.
SET spark.sql.session.timeZone=Asia/Shanghai;
SET spark.driver.memory=16g;
SET spark.sql.maxPlanStringLength=8192;
SET spark.sql.ui.explainMode=simple;
SET spark.sql.shuffle.partitions=200;
SET spark.sql.analyzer.maxIterations=500;
SET spark.sql.sources.partitionOverwriteMode=dynamic;
SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
WITH
w00_scope_keys AS (
SELECT DISTINCT CAST(d.order_id AS STRING) AS order_id,
       CAST(d.start_class_dt AS STRING) AS start_class_dt
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
WHERE d.dt='${date}' AND CAST(d.start_class_dt AS STRING) BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
),
n00_target_calendar AS (
SELECT start_class_dt AS target_cohort,'${date}' AS snapshot_dt,
       COUNT(*) AS expected_orders,COUNT(DISTINCT order_id) AS unique_expected_orders,
       COALESCE(SUM(CASE WHEN order_id IS NULL OR LOWER(TRIM(order_id)) IN
       ('','-1','-1.0','null','none','nan','@pipe_null@','__null__') THEN 1 ELSE 0 END),0) AS invalid_scope_orders
FROM w00_scope_keys GROUP BY start_class_dt
),
n02_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n02_opening_calendar AS (
SELECT DISTINCT CAST(d.start_class_dt AS STRING) AS source_cohort
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n02_params p
    WHERE d.dt=p.as_of_dt AND d.start_class_dt<=p.end_dt
      AND TO_DATE(d.start_class_dt) IS NOT NULL
),
n02_ranked_calendar AS (
-- 已确认固定4期。窗口直接携带前3期，避免两次排名表自连接。
    SELECT source_cohort,
           COLLECT_LIST(source_cohort) OVER (
               ORDER BY source_cohort ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
           ) AS pool_cohorts
    FROM n02_opening_calendar
),
n02_cohort_windows AS (
SELECT c.source_cohort AS target_cohort,
           '${date}' AS snapshot_dt,
           EXPLODE(c.pool_cohorts) AS source_cohort
    FROM n02_ranked_calendar c CROSS JOIN n02_params p
    WHERE c.source_cohort BETWEEN p.start_dt AND p.end_dt
      AND c.source_cohort IN (SELECT target_cohort FROM n00_target_calendar)
),
bs_cohort_windows AS (
SELECT * FROM n02_cohort_windows
),
n05_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n05_skill_windows AS (
SELECT DISTINCT TO_DATE(target_cohort) target_cohort,TO_DATE(snapshot_dt) snapshot_dt,
           TO_DATE(source_cohort) source_cohort FROM bs_cohort_windows
),
n05_skill_source_union AS (
SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,
           CAST(a.order_id AS STRING) AS order_id_raw,
           CAST(a.user_id AS STRING) AS user_id_raw,
           CAST(a.order_status AS STRING) AS order_status_raw,
           CAST(a.subject AS STRING) AS subject_raw,
           CAST(a.pay_dt AS STRING) AS pay_dt_raw,
           CAST(a.pay_tp AS STRING) AS pay_tp_raw,
           CAST(a.keyfrom AS STRING) AS keyfrom_raw,
           CAST(a.semester_type AS STRING) AS semester_type_raw,
           CAST(a.pay_amt AS STRING) AS pay_amt_raw,
           CAST(a.platform_5 AS STRING) AS platform_5_raw,
           CAST(a.platform_5_6 AS STRING) AS platform_5_6_raw,
           CAST(a.season_order_id AS STRING) AS season_order_id_raw,
           CAST(a.season_subject AS STRING) AS season_subject_raw,
           CAST(a.season_pay_dt AS STRING) AS season_pay_dt_raw,
           CAST(a.season_pay_tp AS STRING) AS season_pay_tp_raw,
           CAST(a.season_pay_amt AS STRING) AS season_pay_amt_raw,
           CAST(a.season_keyfrom AS STRING) AS season_keyfrom_raw,
           CAST(a.season_refund_type AS STRING) AS season_refund_type_raw,
           CAST(a.is_no_settle AS STRING) AS is_no_settle_raw,
           CAST(a.end_xb_dt AS STRING) AS end_xb_dt_raw,
           SHA2(TO_JSON(NAMED_STRUCT(
               'pay_dt',CAST(a.pay_dt AS STRING),
               'pay_tp',CAST(a.pay_tp AS STRING),
               'order_id',CAST(a.order_id AS STRING),
               'user_id',CAST(a.user_id AS STRING),
               'order_status',CAST(a.order_status AS STRING),
               'subject',CAST(a.subject AS STRING),
               'keyfrom',CAST(a.keyfrom AS STRING),
               'semester_type',CAST(a.semester_type AS STRING),
               'pay_amt',CAST(a.pay_amt AS STRING),
               'period_type',CAST(a.period_type AS STRING),
               'platform_5',CAST(a.platform_5 AS STRING),
               'platform_5_6',CAST(a.platform_5_6 AS STRING),
               'season_order_id',CAST(a.season_order_id AS STRING),
               'season_subject',CAST(a.season_subject AS STRING),
               'season_pay_dt',CAST(a.season_pay_dt AS STRING),
               'season_pay_tp',CAST(a.season_pay_tp AS STRING),
               'season_pay_amt',CAST(a.season_pay_amt AS STRING),
               'season_keyfrom',CAST(a.season_keyfrom AS STRING),
               'season_refund_type',CAST(a.season_refund_type AS STRING),
               'is_add_wechat',CAST(a.is_add_wechat AS STRING),
               'is_active',CAST(a.is_active AS STRING),
               'is_attend',CAST(a.is_attend AS STRING),
               'is_finish',CAST(a.is_finish AS STRING),
               'is_attend_first_day',CAST(a.is_attend_first_day AS STRING),
               'start_class_dt',CAST(a.start_class_dt AS STRING),
               'end_xb_dt',CAST(a.end_xb_dt AS STRING),
               'outorderid',CAST(a.outorderid AS STRING),
               'province',CAST(a.province AS STRING),
               'city',CAST(a.city AS STRING),
               'city_level',CAST(a.city_level AS STRING),
               'dt',CAST(a.dt AS STRING),
               'is_no_settle',CAST(a.is_no_settle AS STRING),
               'masked_phone',CONCAT(SUBSTR(a.phone,0,3),'****',SUBSTR(a.phone,8,11))
           )),256) AS source_record_hash,
           'MAIN' AS source_family
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da a
    CROSS JOIN n05_params cfg
    JOIN n05_skill_windows w ON a.dt=CAST(w.snapshot_dt AS STRING)
         AND TO_DATE(a.start_class_dt)=w.source_cohort
    WHERE a.dt='${date}'
    UNION ALL
    SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,
           CAST(a.order_id AS STRING) AS order_id_raw,
           CAST(a.user_id AS STRING) AS user_id_raw,
           CAST(a.order_status AS STRING) AS order_status_raw,
           CAST(a.subject AS STRING) AS subject_raw,
           CAST(a.pay_dt AS STRING) AS pay_dt_raw,
           CAST(a.pay_tp AS STRING) AS pay_tp_raw,
           CAST(a.keyfrom AS STRING) AS keyfrom_raw,
           CAST(a.semester_type AS STRING) AS semester_type_raw,
           CAST(a.pay_amt AS STRING) AS pay_amt_raw,
           CAST(a.platform_5 AS STRING) AS platform_5_raw,
           CAST(a.platform_5_6 AS STRING) AS platform_5_6_raw,
           CAST(a.season_order_id AS STRING) AS season_order_id_raw,
           CAST(a.season_subject AS STRING) AS season_subject_raw,
           CAST(a.season_pay_dt AS STRING) AS season_pay_dt_raw,
           CAST(a.season_pay_tp AS STRING) AS season_pay_tp_raw,
           CAST(a.season_pay_amt AS STRING) AS season_pay_amt_raw,
           CAST(a.season_keyfrom AS STRING) AS season_keyfrom_raw,
           CAST(a.season_refund_type AS STRING) AS season_refund_type_raw,
           CAST(a.is_no_settle AS STRING) AS is_no_settle_raw,
           CAST(a.end_xb_dt AS STRING) AS end_xb_dt_raw,
           SHA2(TO_JSON(NAMED_STRUCT(
               'pay_dt',CAST(a.pay_dt AS STRING),
               'pay_tp',CAST(a.pay_tp AS STRING),
               'order_id',CAST(a.order_id AS STRING),
               'user_id',CAST(a.user_id AS STRING),
               'order_status',CAST(a.order_status AS STRING),
               'subject',CAST(a.subject AS STRING),
               'keyfrom',CAST(a.keyfrom AS STRING),
               'semester_type',CAST(a.semester_type AS STRING),
               'pay_amt',CAST(a.pay_amt AS STRING),
               'period_type',CAST(a.period_type AS STRING),
               'platform_5',CAST(a.platform_5 AS STRING),
               'platform_5_6',CAST(a.platform_5_6 AS STRING),
               'season_order_id',CAST(a.season_order_id AS STRING),
               'season_subject',CAST(a.season_subject AS STRING),
               'season_pay_dt',CAST(a.season_pay_dt AS STRING),
               'season_pay_tp',CAST(a.season_pay_tp AS STRING),
               'season_pay_amt',CAST(a.season_pay_amt AS STRING),
               'season_keyfrom',CAST(a.season_keyfrom AS STRING),
               'season_refund_type',CAST(a.season_refund_type AS STRING),
               'is_add_wechat',CAST(a.is_add_wechat AS STRING),
               'is_active',CAST(a.is_active AS STRING),
               'is_attend',CAST(a.is_attend AS STRING),
               'is_finish',CAST(a.is_finish AS STRING),
               'is_attend_first_day',CAST(a.is_attend_first_day AS STRING),
               'start_class_dt',CAST(a.start_class_dt AS STRING),
               'end_xb_dt',CAST(a.end_xb_dt AS STRING),
               'outorderid',CAST(a.outorderid AS STRING),
               'province',CAST(a.province AS STRING),
               'city',CAST(a.city AS STRING),
               'city_level',CAST(a.city_level AS STRING),
               'dt',CAST(a.dt AS STRING),
               'is_no_settle',CAST(a.is_no_settle AS STRING),
               'masked_phone',CONCAT(SUBSTR(a.phone,0,3),'****',SUBSTR(a.phone,8,11))
           )),256) AS source_record_hash,
           'BD' AS source_family
    FROM dw_conan_dwd.dwd_order_course_detail_bd_try_double_try_da a
    CROSS JOIN n05_params cfg
    JOIN n05_skill_windows w ON a.dt=CAST(w.snapshot_dt AS STRING)
         AND TO_DATE(a.start_class_dt)=w.source_cohort
    WHERE a.dt='${date}'
),
bs_skill_source_union AS (
SELECT * FROM n05_skill_source_union
),
n06_skill_source_records AS (
SELECT DISTINCT target_cohort,snapshot_dt,source_cohort,order_id_raw,user_id_raw,order_status_raw,subject_raw,pay_dt_raw,pay_tp_raw,keyfrom_raw,semester_type_raw,pay_amt_raw,platform_5_raw,platform_5_6_raw,season_order_id_raw,season_subject_raw,season_pay_dt_raw,season_pay_tp_raw,season_pay_amt_raw,season_keyfrom_raw,season_refund_type_raw,is_no_settle_raw,end_xb_dt_raw,source_record_hash FROM bs_skill_source_union
),
n06_skill_source_origins AS (
SELECT target_cohort,order_id_raw,CONCAT_WS('+',SORT_ARRAY(COLLECT_SET(source_family))) source_family
    FROM bs_skill_source_union GROUP BY target_cohort,order_id_raw
),
n06_skill_source_keys AS (
SELECT target_cohort,order_id_raw AS order_id,COUNT(*) source_variant_count,
           CASE WHEN COUNT(DISTINCT source_cohort)=1 THEN MAX(source_cohort) END source_cohort,
           CASE WHEN COUNT(DISTINCT snapshot_dt)=1 THEN MAX(snapshot_dt) END snapshot_dt
    FROM n06_skill_source_records GROUP BY target_cohort,order_id_raw
),
n06_skill_source_single AS (
SELECT r.* FROM n06_skill_source_records r
    JOIN n06_skill_source_keys k ON r.target_cohort=k.target_cohort AND r.order_id_raw=k.order_id
    WHERE k.source_variant_count=1
),
n06_skill_source_clean AS (
SELECT k.target_cohort,k.snapshot_dt,k.source_cohort,k.order_id,k.source_variant_count,
           o.source_family,
           r.user_id_raw AS user_id,r.subject_raw AS subject,r.order_status_raw AS order_status,
           r.pay_dt_raw AS pay_dt,r.pay_tp_raw AS pay_tp,r.semester_type_raw AS semester_type,
           CAST(r.pay_amt_raw AS DECIMAL(28,8)) AS pay_amt,
           CASE WHEN LOWER(TRIM(COALESCE(r.keyfrom_raw,''))) IN ('','nan','none','null','@pipe_null@')
                THEN NULL ELSE r.keyfrom_raw END AS keyfrom,
           r.platform_5_raw AS platform_5,r.platform_5_6_raw AS platform_5_6,
           CASE WHEN LOWER(TRIM(COALESCE(r.season_order_id_raw,''))) IN ('','-1','-1.0','nan','none','null','@pipe_null@')
                THEN NULL ELSE r.season_order_id_raw END AS original_season_order_id,
           r.season_refund_type_raw AS original_season_refund_type,
           TO_DATE(r.season_pay_dt_raw) AS original_season_pay_dt,
           r.season_pay_tp_raw AS original_season_pay_tp,
           r.season_subject_raw AS original_season_subject,
           r.season_pay_amt_raw AS original_season_pay_amt,
           r.season_keyfrom_raw AS original_season_keyfrom,
           r.is_no_settle_raw AS is_no_settle,
           LEAST(DATE_ADD(k.source_cohort,29),k.snapshot_dt) AS end_xb_dt,
           CASE WHEN r.keyfrom_raw NOT LIKE '%dyfx%' AND r.keyfrom_raw NOT LIKE '%-bmzx%'
                     AND r.keyfrom_raw NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN r.keyfrom_raw LIKE '%dyfx%' OR r.keyfrom_raw LIKE '%bmzx%'
                     OR r.keyfrom_raw LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM n06_skill_source_keys k
    LEFT JOIN n06_skill_source_single r ON k.target_cohort=r.target_cohort AND k.order_id=r.order_id_raw
    LEFT JOIN n06_skill_source_origins o ON k.target_cohort=o.target_cohort AND k.order_id=o.order_id_raw
),
bs_skill_source_clean AS (
SELECT * FROM n06_skill_source_clean
),
n07_skill_policy_raw AS (
SELECT TRIM(CAST(type AS STRING)) AS contract_type,
           TRIM(CAST(platform_name AS STRING)) AS platform_name,
           TRIM(CAST(platform AS STRING)) AS policy_keyfrom,
           TRIM(CAST(platform_5 AS STRING)) AS policy_authorid,
           TRIM(CAST(party_B AS STRING)) AS party_b,
           TRIM(CAST(contract_code AS STRING)) AS contract_code_raw,
           TRIM(CAST(ori_sign_date AS STRING)) AS ori_sign_date_raw,
           TRIM(CAST(is_normal AS STRING)) AS is_normal,
           TRIM(CAST(is_tmk AS STRING)) AS is_tmk,
           TRIM(CAST(is_bollte_allowance AS STRING)) AS is_bollte_allowance,
           TRIM(CAST(is_max_allowance AS STRING)) AS is_max_allowance,
           TRIM(CAST(is_ka AS STRING)) AS is_ka,
           CASE WHEN TRIM(COALESCE(CAST(deduction_amount AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(deduction_amount AS DECIMAL(28,8)) END AS deduction_amount,
           CASE WHEN TRIM(COALESCE(CAST(excluded_commission AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(excluded_commission AS DECIMAL(28,8)) END AS excluded_commission
    FROM temp.channel_pay_regular WHERE type='双周'
),
n07_skill_policy_normalized AS (
SELECT *,
           CASE WHEN platform_name='臻好（铭栎）'
                 AND contract_code_raw=CONCAT('BJ-YLJY-02-20260611-03068、',CHR(10),'BJ-YLJY-02-20260622-01949')
                THEN REPLACE(contract_code_raw,CHR(10),'') ELSE contract_code_raw END AS contract_code,
           CASE WHEN ori_sign_date_raw RLIKE '^[0-9]{4,6}$'
                THEN CONCAT(YEAR(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'年',
                            MONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'月',
                            DAYOFMONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'日')
                WHEN ori_sign_date_raw RLIKE '^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日?$'
                THEN CONCAT(CAST(REGEXP_EXTRACT(ori_sign_date_raw,'^([0-9]{4})年',1) AS INT),'年',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'年([0-9]{1,2})月',1) AS INT),'月',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'月([0-9]{1,2})',1) AS INT),'日')
                ELSE ori_sign_date_raw END AS ori_sign_date,
           CASE WHEN policy_keyfrom NOT LIKE '%dyfx%' AND policy_keyfrom NOT LIKE '%-bmzx%'
                     AND policy_keyfrom NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN policy_keyfrom LIKE '%dyfx%' OR policy_keyfrom LIKE '%bmzx%'
                     OR policy_keyfrom LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM n07_skill_policy_raw
),
bs_skill_policy_normalized AS (
SELECT * FROM n07_skill_policy_normalized
),
n08_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n08_skill_windows AS (
SELECT DISTINCT TO_DATE(target_cohort) target_cohort,TO_DATE(snapshot_dt) snapshot_dt,
           TO_DATE(source_cohort) source_cohort FROM bs_cohort_windows
),
n08_skill_author_rows AS (
SELECT DISTINCT TO_DATE(c.dt) AS snapshot_dt,CAST(c.conan_order_id AS STRING) AS order_id,
           CAST(GET_JSON_OBJECT(c.json_extra,'$.authorId') AS STRING) AS authorid
    FROM dw_conan_dwd.dwd_conan_growth_thirdapi_third_vendor_order_detail_da c
    CROSS JOIN n08_params cfg
    JOIN (SELECT DISTINCT snapshot_dt FROM n08_skill_windows) w ON c.dt=CAST(w.snapshot_dt AS STRING)
    WHERE c.dt='${date}'
),
bs_skill_author_rows AS (
SELECT * FROM n08_skill_author_rows
),
n09_skill_policy_candidates AS (
SELECT s.target_cohort,s.order_id,CAST(NULL AS STRING) AS authorid,p.*
    FROM bs_skill_source_clean s JOIN bs_skill_policy_normalized p
      ON s.is_normal_branch=1 AND s.is_author_branch=0 AND p.is_normal_branch=1
     AND SIZE(SPLIT(s.keyfrom,'-'))>4 AND SIZE(SPLIT(p.policy_keyfrom,'-'))>4
     AND SPLIT(s.keyfrom,'-')[2]=SPLIT(p.policy_keyfrom,'-')[2]
     AND SPLIT(s.keyfrom,'-')[4]=SPLIT(p.policy_keyfrom,'-')[4]
     AND LOWER(TRIM(SPLIT(s.keyfrom,'-')[2])) NOT IN ('','nan','none','null','@pipe_null@')
     AND LOWER(TRIM(SPLIT(s.keyfrom,'-')[4])) NOT IN ('','nan','none','null','@pipe_null@')
     AND s.keyfrom NOT LIKE '%whkf%'
    UNION ALL
    SELECT s.target_cohort,s.order_id,c.authorid,p.*
    FROM bs_skill_source_clean s
    JOIN bs_skill_author_rows c ON s.order_id=c.order_id AND s.snapshot_dt=c.snapshot_dt
    JOIN bs_skill_policy_normalized p ON c.authorid=p.policy_authorid AND p.is_author_branch=1
    WHERE s.is_author_branch=1 AND s.is_normal_branch=0
      AND LOWER(TRIM(COALESCE(c.authorid,''))) NOT IN ('','nan','none','null','@pipe_null@')
),
bs_skill_policy_candidates AS (
SELECT * FROM n09_skill_policy_candidates
),
n10_skill_policy_matches AS (
SELECT target_cohort,order_id,COUNT(*) policy_candidate_count,
           CONCAT_WS(';',SORT_ARRAY(COLLECT_SET(platform_name))) AS candidate_platform_names,
           CASE WHEN COUNT(*)=1 THEN MAX(authorid) END AS authorid,
           CASE WHEN COUNT(*)=1 THEN MAX(contract_type) END AS contract_type,
           CASE WHEN COUNT(*)=1 THEN MAX(platform_name) END AS platform_name,
           CASE WHEN COUNT(*)=1 THEN MAX(policy_keyfrom) END AS policy_keyfrom,
           CASE WHEN COUNT(*)=1 THEN MAX(party_b) END AS party_b,
           CASE WHEN COUNT(*)=1 THEN MAX(contract_code_raw) END AS contract_code_raw,
           CASE WHEN COUNT(*)=1 THEN MAX(contract_code) END AS contract_code,
           CASE WHEN COUNT(*)=1 THEN MAX(ori_sign_date) END AS ori_sign_date,
           CASE WHEN COUNT(*)=1 THEN MAX(is_normal) END AS is_normal,
           CASE WHEN COUNT(*)=1 THEN MAX(is_tmk) END AS is_tmk,
           CASE WHEN COUNT(*)=1 THEN MAX(is_bollte_allowance) END AS is_bollte_allowance,
           CASE WHEN COUNT(*)=1 THEN MAX(is_max_allowance) END AS is_max_allowance,
           CASE WHEN COUNT(*)=1 THEN MAX(is_ka) END AS is_ka,
           CASE WHEN COUNT(*)=1 THEN MAX(deduction_amount) END AS deduction_amount,
           CASE WHEN COUNT(*)=1 THEN MAX(excluded_commission) END AS excluded_commission
    FROM bs_skill_policy_candidates GROUP BY target_cohort,order_id
),
bs_skill_policy_matches AS (
SELECT * FROM n10_skill_policy_matches
),
n11_skill_windows AS (
SELECT DISTINCT TO_DATE(target_cohort) target_cohort,TO_DATE(snapshot_dt) snapshot_dt,
           TO_DATE(source_cohort) source_cohort FROM bs_cohort_windows
),
n11_skill_window_checks AS (
SELECT target_cohort,COUNT(*) window_count,COUNT(DISTINCT snapshot_dt) snapshot_count,
           MAX(snapshot_dt) snapshot_dt,
           SUM(CASE WHEN DATE_ADD(source_cohort,7)<=snapshot_dt THEN 0 ELSE 1 END) immature_windows
    FROM n11_skill_windows GROUP BY target_cohort
),
n11_skill_source_records AS (
SELECT DISTINCT target_cohort,snapshot_dt,source_cohort,order_id_raw,user_id_raw,order_status_raw,subject_raw,pay_dt_raw,pay_tp_raw,keyfrom_raw,semester_type_raw,pay_amt_raw,platform_5_raw,platform_5_6_raw,season_order_id_raw,season_subject_raw,season_pay_dt_raw,season_pay_tp_raw,season_pay_amt_raw,season_keyfrom_raw,season_refund_type_raw,is_no_settle_raw,end_xb_dt_raw,source_record_hash FROM bs_skill_source_union
),
n11_skill_pool_presence AS (
SELECT target_cohort,COUNT(DISTINCT source_cohort) present_source_cohorts
    FROM n11_skill_source_records GROUP BY target_cohort
),
n11_skill_source_fact_checks AS (
SELECT target_cohort,
           SUM(CASE WHEN source_variant_count<>1
                     OR LOWER(TRIM(COALESCE(order_id,''))) IN ('','-1','-1.0','nan','none','null','@pipe_null@')
                     OR order_status IS NULL OR order_status NOT IN ('正常','退款')
                     OR (original_season_order_id IS NOT NULL AND
                         (original_season_pay_dt IS NULL OR original_season_refund_type IS NULL
                          OR original_season_refund_type NOT IN ('正常','退款')))
                    THEN 1 ELSE 0 END) AS invalid_fact_orders
    FROM bs_skill_source_clean GROUP BY target_cohort
),
n11_skill_author_presence AS (
SELECT snapshot_dt,order_id,
           COUNT(DISTINCT CASE WHEN LOWER(TRIM(COALESCE(authorid,''))) NOT IN ('','nan','none','null','@pipe_null@')
                               THEN authorid END) AS author_id_count
    FROM bs_skill_author_rows GROUP BY snapshot_dt,order_id
),
n11_skill_candidate_group_conflicts AS (
SELECT DISTINCT c.target_cohort,
           CASE WHEN c.platform_name IN ('开朗文化阅读','开朗文化双科') THEN '开朗文化'
                WHEN c.platform_name IN ('京渝永建英语','京渝永建双科') THEN '京渝永建'
                ELSE c.platform_name END AS conflict_platform
    FROM bs_skill_policy_candidates c
    JOIN bs_skill_policy_matches m ON c.target_cohort=m.target_cohort AND c.order_id=m.order_id
    WHERE m.policy_candidate_count>1
),
n11_skill_input_source_gate AS (
SELECT s.*,p.authorid,p.contract_type,p.platform_name,p.policy_keyfrom,p.party_b,
           p.contract_code_raw,p.contract_code,p.ori_sign_date,
           p.is_normal,p.is_tmk,p.is_bollte_allowance,p.is_max_allowance,p.is_ka,
           p.deduction_amount,p.excluded_commission,p.candidate_platform_names,
           COALESCE(p.policy_candidate_count,0) AS policy_candidate_count,
           CASE
             WHEN w.window_count<>4 OR w.snapshot_count<>1 OR w.immature_windows<>0
                  OR COALESCE(q.present_source_cohorts,0)<>4 THEN 'pool_window_incomplete'
             WHEN f.invalid_fact_orders>0 THEN 'pool_source_validation_failed'
             WHEN s.source_variant_count<>1 THEN 'source_order_conflict'
             WHEN LOWER(TRIM(COALESCE(s.order_id,''))) IN ('','-1','-1.0','nan','none','null','@pipe_null@') THEN 'source_order_id_missing'
             WHEN s.order_status NOT IN ('正常','退款') OR s.order_status IS NULL THEN 'source_order_status_invalid'
             WHEN s.original_season_order_id IS NOT NULL AND
                  (s.original_season_pay_dt IS NULL OR s.original_season_refund_type NOT IN ('正常','退款')
                   OR s.original_season_refund_type IS NULL) THEN 'source_renewal_invalid'
             WHEN s.keyfrom IS NULL THEN 'source_key_missing'
             WHEN s.is_normal_branch=1 AND s.is_author_branch=1 THEN 'mapping_branch_conflict'
             WHEN s.is_normal_branch=1 AND s.keyfrom LIKE '%whkf%' THEN 'template_whkf_excluded'
             WHEN s.is_normal_branch=1 AND SIZE(SPLIT(s.keyfrom,'-'))<5 THEN 'normal_key_too_short'
             WHEN s.is_author_branch=1 AND COALESCE(a.author_id_count,0)=0 THEN 'author_id_missing'
             WHEN COALESCE(p.policy_candidate_count,0)=0 THEN 'policy_unmapped'
             WHEN p.policy_candidate_count<>1 THEN 'policy_multiple_matches'
             WHEN LOWER(TRIM(COALESCE(p.platform_name,''))) IN ('','nan','none','null','@pipe_null@')
                  OR LOWER(TRIM(COALESCE(p.party_b,''))) IN ('','nan','none','null','@pipe_null@')
                  OR LOWER(TRIM(COALESCE(p.contract_code,''))) IN ('','nan','none','null','@pipe_null@')
                  OR LOWER(TRIM(COALESCE(p.ori_sign_date,''))) IN ('','nan','none','null','@pipe_null@') THEN 'policy_required_field_missing'
             WHEN p.deduction_amount IS NULL OR p.excluded_commission IS NULL THEN 'policy_adjustment_invalid'
             WHEN g.conflict_platform IS NOT NULL THEN 'policy_group_conflict'
             ELSE 'matched' END AS policy_match_status
    FROM bs_skill_source_clean s
    LEFT JOIN bs_skill_policy_matches p ON s.target_cohort=p.target_cohort AND s.order_id=p.order_id
    LEFT JOIN n11_skill_author_presence a ON s.snapshot_dt=a.snapshot_dt AND s.order_id=a.order_id
    LEFT JOIN n11_skill_window_checks w ON s.target_cohort=w.target_cohort
    LEFT JOIN n11_skill_pool_presence q ON s.target_cohort=q.target_cohort
    LEFT JOIN n11_skill_source_fact_checks f ON s.target_cohort=f.target_cohort
    LEFT JOIN n11_skill_candidate_group_conflicts g ON s.target_cohort=g.target_cohort
      AND (CASE WHEN p.platform_name IN ('开朗文化阅读','开朗文化双科') THEN '开朗文化'
                WHEN p.platform_name IN ('京渝永建英语','京渝永建双科') THEN '京渝永建'
                ELSE p.platform_name END)=g.conflict_platform
),
n11_skill_input_present AS (
SELECT target_cohort,snapshot_dt,source_cohort,order_id,user_id,order_status,
           subject,pay_dt,pay_tp,pay_amt,keyfrom,semester_type,platform_5,platform_5_6,
           CASE WHEN SIZE(SPLIT(keyfrom,'-'))>3 THEN UPPER(SPLIT(keyfrom,'-')[3]) END AS type,
           CASE WHEN original_season_order_id IS NOT NULL AND original_season_pay_dt<=end_xb_dt
                THEN original_season_order_id END AS season_order_id,
           CASE WHEN original_season_order_id IS NOT NULL AND original_season_pay_dt<=end_xb_dt
                THEN original_season_refund_type ELSE '正常' END AS season_refund_type,
           CASE WHEN original_season_order_id IS NOT NULL AND original_season_pay_dt<=end_xb_dt
                THEN original_season_pay_dt END AS season_pay_dt,
           CASE WHEN original_season_order_id IS NOT NULL AND original_season_pay_dt<=end_xb_dt
                THEN original_season_pay_tp END AS season_pay_tp,
           end_xb_dt,is_no_settle,authorid,contract_type,platform_name,policy_keyfrom,party_b,
           contract_code,contract_code_raw,ori_sign_date,
           is_normal,is_tmk,is_bollte_allowance,is_max_allowance,is_ka,
           deduction_amount,excluded_commission,policy_match_status,
           policy_candidate_count,candidate_platform_names,source_variant_count,source_family,
           CASE WHEN original_season_order_id IS NOT NULL AND original_season_pay_dt>end_xb_dt THEN 1 ELSE 0 END AS late_renewal_cleared
    FROM n11_skill_input_source_gate
),
bs_skill_input_present AS (
SELECT * FROM n11_skill_input_present
),
w_policy_frozen_raw AS (
SELECT * FROM VALUES
 ('双周','静魅','yxzz-sw-sq-CPA-jingmei','jingmei','是','否','否','否','','','泉州市静魅文化传媒有限公司','BJ-YLJY-02-20240308-00038','2024年3月8日','否'),
 ('双周','学研星途','yxzz-sw-sq-CPA-xyxt','xyxt','是','否','否','否','','','武汉学研星途科技有限公司','BJ-YLJY-02-20250714-00066','2025年7月14日','否'),
 ('双周','学研星途','yxzz-sw-sy-CPA-xyxt','xyxt','是','否','否','否','','','武汉学研星途科技有限公司','BJ-YLJY-02-20250714-00066','2025年7月14日','否'),
 ('双周','时光学','yxzz-sw-sq-CPA-shiguangxue','shiguangxue','是','否','否','否','','','江西一学就慧文化科技有限公司青岛分公司','BJ-YLJY-02-20240220-00071','2024年1月15日','否'),
 ('双周','佳效','yxzz-sw-sq-CPA-jiaxiao','jiaxiao','是','否','否','否','','','洛阳佳效信息科技有限公司','BJ-YLJY-02-20231103-00108','2023年11月4日','否'),
 ('双周','新动力','yxzz-sw-sq-CPA-xdl','xdl','是','否','否','否','','','北京中企新动力网络科技有限公司','BJ-YLJY-02-20231103-00027','2023年11月3日','否'),
 ('双周','优优','yxzz-sw-sq-CPA-youyou','youyou','是','否','否','否','','','北京优优未来科技发展有限公司','BJ-YLJY-02-20231205-00003','2023年11月1日','否'),
 ('双周','阳明（学为先）','yxzz-sw-sq-CPA-xueweixian','xueweixian','是','否','否','否','','','南昌阳明信息技术有限公司','BJ-YLJY-02-20231204-00164、BJ-YLJY-02-20240430-00013','2023年11月1日','是'),
 ('双周','阳明（学为先）','yxzz-sw-sq-CPA-ncym','ncym','是','否','否','否','','','南昌阳明信息技术有限公司','BJ-YLJY-02-20231204-00164、BJ-YLJY-02-20240430-00013','2023年11月1日','是'),
 ('双周','擎拓','yxzz-sw-sq-CPA-qingtuo','qingtuo','是','否','否','否','','','桐城铭才信息科技有限公司','BJ-YLJY-02-20231204-00186、BJ-YLJY-02-20231205-00004、BJ-YLJY-02-20240415-00026','2023年11月1日','否'),
 ('双周','精厚','yxzz-sw-sq-CPA-jinghou','jinghou','是','否','否','否','','','精厚文化传播（河北）有限公司','BJ-YLJY-02-20231114-00068','2023年11月1日','否'),
 ('双周','中轶','yxzz-sw-sq-CPA-zhongyixx','zhongyixx','是','否','否','否','','','安徽省中轶信息咨询有限公司','BJ-YLJY-02-20231027-00003','2023年10月27日','否'),
 ('双周','网聚天下社群','yxzz-sw-sq-CPA-syabl','syabl','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20250507-00231','2025年5月7日','是'),
 ('双周','网聚天下bpo','yxzz-sw-tmk-cpa-bpowjtx','bpowjtx','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20260204-00611','2026年2月5日','否'),
 ('双周','酬勤信息','yxzz-sw-dt-CPA-cqxx','cqxx','否','否','0.07','是','','','邯郸酬信科技有限公司','BJ-YLJY-02-20250414-00247、BJ-YLJY-02-20260302-00571、BJ-YLJY-02-20260210-00892','2025年4月14日','是'),
 ('双周','酬勤信息','yxzz-sw-sq-CPA-cqxx','cqxx','否','否','0.07','是','','','邯郸酬信科技有限公司','BJ-YLJY-02-20250414-00247、BJ-YLJY-02-20260302-00571、BJ-YLJY-02-20260210-00892','2025年4月14日','是'),
 ('双周','元慷文化','yxzz-sw-sq-CPA-yuankang','yuankang','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-sq-CPA-yuankangwh','yuankangwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-qt-cpa-ykwh','ykwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-sy-cpa-ykwh','ykwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','奇趣','yxzz-sw-ss-cpa-qiqu','qiqu','是','否','否','否','','','鄂州市葛店经济技术开发区奇趣电子商务工作室（个体工商户）','BJ-YLJY-02-20260403-00933','2026年4月3日','否'),
 ('双周','新服','yxzz-sw-sq-CPA-xinfu','xinfu','是','否','否','否','','','山西新服时代信息科技有限公司','BJ-YLJY-02-20230907-00006','2023年8月23日','是'),
 ('双周','褚岩（吾醒）','yxzz-sw-sq-CPA-wuxing','wuxing','是','否','否','否','','','保定褚岩网络科技有限公司','BJ-YLJY-02-20230907-00072','2023年8月22日','否'),
 ('双周','幸树','yxzz-sw-sq-CPA-xingshu','xingshu','是','否','否','否','','','安徽盈幸树信息科技有限公司','BJ-YLJY-02-20230907-00005','2023年8月22日','否'),
 ('双周','路迦','yxzz-sw-sq-cpa-lujia','lujia','是','否','否','否','','','江西阿路迦信息科技有限公司','BJ-YLJY-02-20230907-00074','2023年8月22日','否'),
 ('双周','保定佳学','yxzz-sw-sq-cpa-bdjiaxue','bdjiaxue','是','否','否','否','','','保定佳学教育科技有限公司','BJ-YLJY-02-20230907-00075','2023年8月22日','否'),
 ('双周','碟塔','yxzz-sw-sq-CPA-dieta','dieta','是','否','否','否','','','广州磐碟塔信息科技有限公司','BJ-YLJY-02-20230726-00003','2023年7月26日','否'),
 ('双周','盛和文（茂密文化）','yxzz-sw-sq-CPA-shmiwen','shmiwen','是','否','否','否','','','上海盛和文网络科技有限公司','BJ-YLJY-02-20231204-00183、BJ-YLJY-02-20231204-00184','2023年7月20日','否'),
 ('双周','茂密文化','yxzz-sw-sq-CPA-mw','mw','是','否','否','否','','','上海茂密文化传播有限公司','BJ-YLJY-02-20230720-00088、BJ-YLJY-02-20231007-00071、BJ-YLJY-02-20231113-00025','2023年7月20日','否'),
 ('双周','云梯','yxzz-sw-sq-CPA-yunti','yunti','是','否','否','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20230717-00013','2023年7月17日','否'),
 ('双周','有大志','yxzz-sw-sq-CPA-youdazhi','youdazhi','是','否','否','否','','','温州有大志网络科技有限公司','BJ-YLJY-02-20230628-00007','2023年6月29日','否'),
 ('双周','铭栎（臻好）','yxzz-sw-sq-CPA-nbzhenhao','nbzhenhao','是','否','否','否','','','宁波铭栎智能科技有限公司','BJ-YLJY-02-20250317-00036、BJ-YLJY-02-20250318-00103、BJ-YLJY-02-20250408-00039','2025年3月1日','否'),
 ('双周','够玩','yxzz-sw-sy-cpa-gzgouwan','gzgouwan','是','否','否','否','','','广州够玩网络科技有限公司','BJ-YLJY-02-20250925-00023','2025年8月1日','否'),
 ('双周','够玩','yxzz-sw-sq-CPA-gzgouwan','gzgouwan','是','否','否','否','','','广州够玩网络科技有限公司','BJ-YLJY-02-20250925-00023','2025年8月1日','否'),
 ('双周','神州鹰','yxzz-sw-sq-CPA-shenzhouying','shenzhouying','是','否','否','否','','','苏州神州鹰网络科技有限公司','BJ-YLJY-02-20241121-00036','2024年11月23日','否'),
 ('双周','脉点','yxzz-sw-sq-cpa-dyfx','61522582482','是','否','否','否','','','杭州脉点文化传媒有限公司','BJ-YLJY-02-20250224-00034','2025年2月17日','是'),
 ('双周','中云','yxzz-sw-sq-CPA-zhongyun','zhongyun','是','否','否','否','','','资溪县中云信息服务中心（个体工商户）','BJ-YLJY-02-20250224-00035','2025年2月12日','否'),
 ('双周','三云','yxzz-sw-sq-CPA-sanyun','sanyun','是','否','否','否','','','三云网络科技（广州）有限公司','BJ-YLJY-02-20250225-00016','2025年2月25日','否'),
 ('双周','雅艺','yxzz-sw-sq-cpa-dyfx','4200561827384891','是','否','否','否','','','湖北雅艺传媒有限公司','BJ-YLJY-02-20250304-00046','2025年3月1日','否'),
 ('双周','怡彩','yxzz-sw-sq-CPA-yicai','yicai','是','否','否','否','','','沙市区怡彩信息技术咨询服务中心','BJ-YLJY-02-20250331-00087','2025年2月16日','否'),
 ('双周','千亿教育','yxzz-sw-sq-CPA-qyjy','qyjy','是','否','否','否','','','湖北千亿教育科技有限公司','BJ-YLJY-02-20250317-00088','2025年3月17日','否'),
 ('双周','千亿教育','yxzz-sw-sy-CPA-qyjy','qyjy','是','否','否','否','','','湖北千亿教育科技有限公司','BJ-YLJY-02-20250317-00088','2025年3月17日','否'),
 ('双周','涵科','yxzz-sw-sq-CPA-hanke','hanke','是','否','否','否','','','蚌埠涵科科技有限公司','BJ-YLJY-02-20250318-00118','2025年3月18日','否'),
 ('双周','嘉宝','yxzz-sw-sq-CPA-szjiabao','szjiabao','是','否','否','否','','','苏州嘉宝禾信息技术有限公司','BJ-YLJY-02-20250402-00042','2025年4月2日','否'),
 ('双周','乐知（凌泽）','yxzz-sw-sq-CPA-lingze','lingze','否','是','0.07','是','','','北京乐知科技有限公司','BJ-YLJY-02-20260331-00998、BJ-YLJY-02-20260407-00677','2026年2月1日','是'),
 ('双周','臻好（铭栎）','yxzz-sw-sq-CPA-mingli','mingli','否','是','0.07','是','','','宁波臻好信息技术有限公司','BJ-YLJY-02-20260611-03068、BJ-YLJY-02-20260622-01949','2026年4月1日','是'),
 ('双周','书纽','yxzz-sw-ss-cpa-shuniu','shuniu','是','否','否','否','','','武汉书纽科技有限公司','BJ-YLJY-02-20250508-00076','2025年4月29日','否'),
 ('双周','书纽','yxzz-sw-sq-CPA-shuniu','shuniu','是','否','否','否','','','武汉书纽科技有限公司','BJ-YLJY-02-20250508-00076','2025年4月29日','否'),
 ('双周','时科','yxzz-sw-sq-CPA-shike','shike','是','否','否','否','','','北京子木时代科技有限公司','BJ-YLJY-02-20250325-00070','2025年3月25日','否'),
 ('双周','铭祺','yxzz-sw-sy-cpa-mingqi','mingqi','是','否','否','否','','','深圳市铭祺电子商务有限公司','BJ-YLJY-02-20250609-00160','2025年6月5日','否'),
 ('双周','铭祺','yxzz-sw-sq-CPA-mingqi','mingqi','是','否','否','否','','','深圳市铭祺电子商务有限公司','BJ-YLJY-02-20250609-00160','2025年6月5日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','3043886234337671','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','3087056828895051','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','乐学科技','yxzz-sw-sq-CPA-lexuekj','lexuekj','是','否','否','否','','','武汉好乐学科技有限公司','BJ-YLJY-02-20250324-00078','2025年3月24日','否'),
 ('双周','蓝智（怡乐）','yxzz-sw-sy-cpa-yile','yile','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','蓝智（怡乐）','yxzz-sw-sq-CPA-yile','yile','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','蓝智','yxzz-sw-sy-cpa-lanzhi1','lanzhi1','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','sddr','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','博学（谦受益）','yxzz-sw-sq-CPA-qsy','qsy','否','是','0.07','是','','','江西慎思之信息科技有限公司','BJ-YLJY-02-20260422-00、BJ-YLJY-02-20260428-00669、BJ-YLJY-02-20260710-01934','2026年3月1日','是'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','2791040445891170','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','黑木','yxzz-sw-sq-CPA-heimu','heimu','是','否','否','否','','','杭州黑木文化有限公司','BJ-YLJY-02-20250905-00048','2025年9月6日','否'),
 ('双周','茂密','yxzz-sw-sq-CPA-maomi','maomi','是','否','否','否','','','上海茂密文化传播有限公司','BJ-YLJY-02-20250909-00016','2025年9月10日','否'),
 ('双周','启睿','yxzz-sw-sy-cpa-qirui','qirui','是','否','否','否','','','武汉启睿优学科技有限公司','BJ-YLJY-02-20250911-00064','2025年8月5日','否'),
 ('双周','启睿','yxzz-sw-sq-CPA-qirui','qirui','是','否','否','否','','','武汉启睿优学科技有限公司','BJ-YLJY-02-20250911-00064','2025年8月5日','否'),
 ('双周','湖州云梯','yxzz-sw-sq-CPA-hzyt','hzyt','是','否','否','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20250725-00053','2025年7月26日','否'),
 ('双周','湖州云梯','yxzz-sw-ss-cpa-hzyt','hzyt','是','否','0.095','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20260729-02900','2026年7月29日','否'),
 ('双周','优考','yxzz-sw-sq-CPA-youkao','youkao','是','否','否','否','','','杭州优考文化发展有限公司','BJ-YLJY-02-20250327-00035','2025年3月28日','否'),
 ('双周','童趣','yxzz-sw-sq-cpa-dyfx','1201131541503580','是','否','否','否','','','郑州童趣宝盒信息技术有限公司','BJ-YLJY-02-20250918-00150','2025年9月18日','否'),
 ('双周','禧泽（长台）','yxzz-sw-jz-cpa-xize','xize','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','禧泽（长台）','yxzz-sw-sq-CPA-xize','xize','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','逗爸','yxzz-sw-sq-cpa-sphfx','sphdujHUEzWRb6W','否','否','0.07','否','','','深圳楚航信息科技有限公司','BJ-YLJY-02-20260113-00966','2026年1月13日','是'),
 ('双周','百杰胜','yxzz-sw-ss-cpa-bjssq','bjssq','否','否','否','否','','','武汉智成杰数字科技有限公司','BJ-YLJY-02-20260320-00820、BJ-YLJY-02-20260327-00720','2026年4月1日','否'),
 ('双周','京渝永建双科','yxzz-sw-sq-CPA-jyyj','jyyj','是','否','否','否','','','重庆京渝永建科技有限公司','BJ-YLJY-02-20260616-03341','2026年6月16日','否'),
 ('双周','北极鸥','yxzz-sw-sy-cpa-bjojy','bjojy','是','否','否','否','','','青岛北极鸥教育信息咨询有限公司','BJ-YLJY-02-20251021-00691','2025年10月21日','否'),
 ('双周','全商','yxzz-sw-sy-cpa-quanshang','quanshang','是','否','否','否','','','华容县殷全商务服务站','J-YLJY-02-20251203-00518','2025年10月1日','否'),
 ('双周','全商','yxzz-sw-sq-CPA-quanshang','quanshang','是','否','否','否','','','华容县殷全商务服务站','J-YLJY-02-20251203-00518','2025年10月1日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','280525644','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','海裕','yxzz-sw-sy-cpa-haiyu','haiyu','是','否','否','否','','','北京启明钰泉科技有限公司','BJ-YLJY-02-20260508-00666','2026年5月8日','否'),
 ('双周','海裕','yxzz-sw-sq-CPA-haiyu','haiyu','是','否','否','否','','','北京启明钰泉科技有限公司','BJ-YLJY-02-20260508-00666','2026年5月8日','否'),
 ('双周','坚壳','yxzz-sw-sq-CPA-jianke','jianke','是','否','否','否','','','江苏坚壳科技有限公司','BJ-YLJY-02-20250925-00241','2025年10月1日','否'),
 ('双周','精灵','yxzz-sw-sy-cpa-htjl','htjl','是','否','否','否','10000','','武汉海豚精灵网络科技有限公司','BJ-YLJY-02-20251121-00835','2025年11月22日','否'),
 ('双周','精灵','yxzz-sw-sq-CPA-htjl','htjl','是','否','否','否','','','武汉海豚精灵网络科技有限公司','BJ-YLJY-02-20251121-00835','2025年11月22日','否'),
 ('双周','哪吒','yxzz-sw-sy-cpa-nezha','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','哪吒','yxzz-sw-ss-cpa-nezha19','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','哪吒','yxzz-sw-ss-cpa-nezha','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','仁轩','yxzz-sw-sq-CPA-renxuan','renxuan','是','否','否','否','','','郑州仁轩教育科技有限公司','BJ-YLJY-02-20260107-00804、BJ-YLJY-02-20260424-00810','2026年1月12日','否'),
 ('双周','仁轩','yxzz-sw-sy-cpa-renxuan','renxuan','是','否','否','否','','','郑州仁轩教育科技有限公司','BJ-YLJY-02-20260107-00804、BJ-YLJY-02-20260424-00810','2026年1月12日','否'),
 ('双周','稻果','yxzz-sw-jz-cpa-daoguowh','daoguowh','是','否','0.06','否','','','深圳市稻果文化传播有限公司','BJ-YLJY-02-20260325-00938','2026年3月24日','否'),
 ('双周','燃势网络','yxzz-dy-cpa-bmzx','819579791613644','否','是','0.05','否','','','北京燃势网络科技有限公司','BJ-YLJY-02-20260320-00917','2026年3月23日','否'),
 ('双周','潇沐','yxzz-dy-cpa-bmzx','2709644393854711','是','否','0.05','否','','','山西潇沐网络科技有限公司','BJ-YLJY-02-20260421-00744','2026年4月1日','否'),
 ('双周','诚学','yxzz-sw-sy-cpa-chengxue','chengxue','是','否','否','否','','','武汉诚学汇科技有限公司','BJ-YLJY-02-20260506-01316','2026年4月1日','否'),
 ('双周','玉琴','yxzz-mr-sy-cpa-yuqin','yuqin','是','否','否','否','','','郑州誉景和商贸有限责任公司','BJ-YLJY-02-20260629-03144','2026年4月9日','否'),
 ('双周','星耀学1','yxzz-mr-sy-cpa-xingyaoxue','xingyaoxue1','是','否','否','否','','','北京星耀学文化传播有限公司','BJ-YLJY-02-20260410-00892','2026年4月10日','否'),
 ('双周','长台','yxzz-sw-jz-cpa-changtai','changtai','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','昆紫','yxzz-sw-sy-cpa-kunzi','kunzi','是','否','否','否','','','林州昆紫信息技术有限公司','BJ-YLJY-02-20260423-01107','2026年4月21日','否'),
 ('双周','胖虎','yxzz-sw-ss-cpa-panghu','panghu','是','否','否','否','','','菏泽胖虎网络科技有限公司','BJ-YLJY-02-20260320-00965','2026年3月1日','否'),
 ('双周','破晓','yxzz-sw-ss-cpa-poxiao','poxiao','是','否','否','否','','','菏泽倍优教育科技有限公司','BJ-YLJY-02-20260327-00923','2026年3月27日','否'),
 ('双周','悦冠','yxzz-sw-ss-cpa-yueguan','yueguan','是','否','否','否','','','徐州向学信息科技有限公司','BJ-YLJY-02-20260408-00665','2026年4月8日','否'),
 ('双周','巨航','yxzz-sw-ss-cpa-juhang','juhang','是','否','否','否','','','菏泽巨航电子商务有限公司','BJ-YLJY-02-20260421-00917','2026年4月21日','否'),
 ('双周','乐学1','yxzz-sw-sy-cpa-lexu','lexu','否','否','否','否','','','海口乐学科技有限公司','BJ-YLJY-02-20260415-01157','2026年5月15日','是'),
 ('双周','文荀','yxzz-sw-sy-cpa-wenxun','wenxun','是','否','否','否','','','合肥创硕优科技有限公司','BJ-YLJY-02-20260721-02548','2026年5月1日','否'),
 ('双周','元昔','yxzz-sw-sy-cpa-yuanxi','yuanxi','是','否','否','否','','','北京攀升科技有限公司','BJ-YLJY-02-20260608-01651','2026年4月1日','否'),
 ('双周','乐都','yxzz-sw-sy-cpa-ledou','lefou','是','否','否','否','','','青海乐读文化传媒有限公司','BJ-YLJY-02-20260623-02571','2026年5月21日','否'),
 ('双周','雅艺','yxzz-sw-sy-cpa-yayi','yayi','是','否','否','否','','','湖北雅艺传媒有限公司','BJ-YLJY-02-20260623-02040','2026年6月8日','否'),
 ('双周','目标','yxzz-sw-jz-cpa-mubiao','mubiao','是','否','0.065','否','','','郴州目标信息咨询有限公司','BJ-YLJY-02-20260527-00949','2026年5月27日','否'),
 ('双周','馨松','yxzz-sw-sy-cpa-xinsong1','xinsong1','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','八斗','yxzz-sw-jz-cpa-badou','badou','是','否','0.065','否','','','深圳市高八斗科技有限公司','BJ-YLJY-02-20260521-00976','2026年5月18日','否'),
 ('双周','静魅','yxzz-sw-jz-cpa-jingmeiqz','jingmeiqz','是','否','0.065','否','','','泉州市静魅文化传媒有限公司','BJ-YLJY-02-20260525-01049','2026年5月25日','否'),
 ('双周','清之意','yxzz-sw-qt-cpa-qzy','qzy','是','否','否','否','','','贵州清之意科技有限责任公司','BJ-YLJY-02-20260519-00938','2026年5月19日','否'),
 ('双周','文化','yxzz-sw-sy-cpa-wenhua','wenhua','是','否','否','否','','','广州有点文化发展有限公司','BJ-YLJY-02-20260604-01275','2026年6月4日','否'),
 ('双周','盈推','yxzz-sw-sy-cpa-yingwei','yingwei','是','否','否','否','','','宁波盈推信息技术服务有限公司','BJ-YLJY-02-20260518-00687','2026年5月18日','否'),
 ('双周','云电','yxzz-sw-sy-cpa-yundian','yundian','是','否','0.09','否','','','湖北停云电子科技有限公司','BJ-YLJY-02-20260605-01280','2026年6月5日','否'),
 ('双周','优投','yxzz-sw-sq-CPA-youtou','youtou','是','否','0.06','否','','','杭州优投智数科技有限公司','BJ-YLJY-02-20260420-00842','2026年4月20日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphTExGDtq5100J','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphTHGqRfXXZRfG','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphQpNl8PowodqC','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphpSPyAZhAssRY','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphOte1cxigd56j','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','3722327016875712','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','731652064292043','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1804742529655881','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1857548839823209','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','4355612637930179','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','2332513424648508','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','132978274471588','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1628809348255993','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','4474326611661387','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','164242089867824','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1184589921401500','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','3722327016875712','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','731652064292043','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1804742529655881','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1857548839823209','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','4355612637930179','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','2332513424648508','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','132978274471588','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1628809348255993','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','4474326611661387','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','164242089867824','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1184589921401500','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','亿起发','yxzz-sw-ss-cpa-yiqifa','yiqifa','是','否','0.055','否','','','滁州亿起发网络科技有限公司','BJ-YLJY-02-20260518-01284','2026年5月18日','否'),
 ('双周','微尚','yxzz-sw-ss-cpa-weishang','weishang','是','否','0.055','否','','','北京晨鑫益晟家政服务有限公司','BJ-YLJY-02-20260616-02977','2026年4月20日','否'),
 ('双周','壹佰分','yxzz-sw-ss-cpa-yibaifen','yibaifen','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','壹佰分','yxzz-sw-sy-cpa-beijixing','beijixing','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','壹佰分','yxzz-sw-ss-cpa-yibaifenyy','yibaifenyy','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','晨曦','yxzz-sw-ss-cpa-chenxi','chenxi','是','否','0.05','否','','','菏泽晨曦文化传媒有限公司','BJ-YLJY-02-20260520-00683','2026年5月20日','否'),
 ('双周','温老师','yxzz-sw-ss-cpa-wenlaoshi','wenlaoshi','是','否','0.065','否','','','菏泽市曹县辰锦网络科技有限公司','BJ-YLJY-02-20260609-01905','2026年6月9日','否'),
 ('双周','小瓶盖','yxzz-sw-ss-cpa-xiaopinggai','xiaopinggai','是','否','0.105','否','','','徐州小瓶盖信息科技有限公司','BJ-YLJY-02-20260706-02511','2026年5月26日','否'),
 ('双周','绿韵','yxzz-sw-ss-cpa-lvyun','lvyun','是','否','0.1','否','','','菏泽市牡丹区绿韵电子商务有限公司','BJ-YLJY-02-20260612-01605','2026年5月26日','否'),
 ('双周','酷游','yxzz-sw-ss-cpa-kuyou','kuyou','是','否','0.1','否','','','菏泽酷游网络科技有限公司','BJ-YLJY-02-20260526-01140','2026年6月13日','否'),
 ('双周','云岛','yxzz-sw-sy-cpa-yundao','yundao','是','否','0.055','否','','','广州云岛科技有限公司','BJ-YLJY-02-20260611-00163','2026年6月10日','否'),
 ('双周','雅览','yxzz-sw-ss-cpa-yalan','yalan','是','否','0.1','否','','','菏泽雅览教育服务有限公司','BJ-YLJY-02-20260626-03039','2026年6月26日','否'),
 ('双周','廷嘉','yxzz-bd-jx-cpa-tingjia','tingjia','是','否','0.06','否','','','广州市廷嘉科技有限公司','BJ-YLJY-02-20260528-01244','2026年6月1日','否'),
 ('双周','优思睿','yxzz-bd-jx-cpa-yousirui','yousirui','是','否','0.06','否','','','昆山优丞嘻信息技术有限公司','BJ-YLJY-02-20260529-00647、BJ-YLJY-02-20260814-0200','2026年6月1日','否'),
 ('双周','尔瑞','yxzz-bd-jx-cpa-errui','errui','是','否','0.06','否','','','深圳尔瑞信息技术有限公司','BJ-YLJY-02-20260601-00659','2026年6月1日','否'),
 ('双周','墨点','yxzz-bd-jx-cpa-modian','modian','是','否','0.06','否','','','固镇县墨点科技有限公司','BJ-YLJY-02-20260602-00801','2026年6月1日','否'),
 ('双周','德才','yxzz-bd-jx-cpa-decai','decai','是','否','0.06','否','','','山西德才教育科技有限公司','BJ-YLJY-02-20260605-01517','2026年6月1日','否'),
 ('双周','开朗文化阅读','yxzz-sw-sq-cpa-klwh','klwh','否','否','是','否','','','商丘开朗文化传播有限公司','BJ-YLJY-02-20260630-01840','2026年6月30日','否'),
 ('双周','童画','yxzz-sw-jz-cpa-tonghua','tonghua','是','否','0.065','否','','','童画（广州）网络科技有限公司','BJ-YLJY-02-20260527-01167','2026年6月1日','否'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sph8jg7SHnaMaem','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sphrIR3dvJX7XL3','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sphpj7ahkKSbRci','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','廷嘉','yxzz-sw-jz-cpa-tingjia','tingjia','是','否','0.06','否','','','广州市廷嘉科技有限公司','BJ-YLJY-02-20260528-01244','2026年6月1日','否'),
 ('双周','优思睿','yxzz-sw-jz-cpa-yousirui','yousirui','是','否','0.06','否','','','昆山优丞嘻信息技术有限公司','BJ-YLJY-02-20260529-00647、BJ-YLJY-02-20260814-02007','2026年6月1日','否'),
 ('双周','尔瑞','yxzz-sw-jz-cpa-errui','errui','是','否','0.06','否','','','深圳尔瑞信息技术有限公司','BJ-YLJY-02-20260601-00659','2026年6月1日','否'),
 ('双周','墨点','yxzz-sw-jz-cpa-modian','modian','是','否','0.06','否','','','固镇县墨点科技有限公司','BJ-YLJY-02-20260602-00801','2026年6月1日','否'),
 ('双周','德才','yxzz-sw-jz-cpa-decai','decai','是','否','0.06','否','','','山西德才教育科技有限公司','BJ-YLJY-02-20260605-01517','2026年6月1日','否'),
 ('双周','长台1','yxzz-sw-jz-cpa-changtaixx','changtaixx','是','否','0.1','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260617-02386','2026年6月15日','否'),
 ('双周','无忧','yxzz-sw-jz-cpa-wuyou','wuyou','是','否','0.065','否','','','深圳市无忧空间传媒有限公司','BJ-YLJY-02-20260831-02094','2026年8月31日','否'),
 ('双周','萌宝1','yxzz-sw-sy-cpa-mengbao1','mengbao1','是','否','否','否','','','华容县萌宝启蒙文化传媒工作室','BJ-YLJY-02-20260717-03087','2026年7月17日','否'),
 ('双周','网聚天下社群','yxzz-jd-kecheng-sw','jd','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20250507-00231','2025年5月7日','是'),
 ('双周','胖虎','yxzz-sw-ss-cpa-panghuyy','panghuyy','是','否','是','否','','','菏泽胖虎网络科技有限公司','BJ-YLJY-02-20260902-02382','2026年8月31日','否'),
 ('双周','佳慕','yxzz-sw-ss-cpa-jiamuyy','jiamuyy','是','否','是','否','','','山东佳慕电子科技有限公司','BJ-YLJY-02-20260902-02384','2026年9月1日','否')
 AS p(`type`,`platform_name`,`platform`,`platform_5`,`is_normal`,`is_tmk`,`is_bollte_allowance`,`is_max_allowance`,`deduction_amount`,`excluded_commission`,`party_b`,`contract_code`,`ori_sign_date`,`is_ka`)
),
w_policy_frozen_policy_raw AS (
SELECT TRIM(CAST(type AS STRING)) AS contract_type,
           TRIM(CAST(platform_name AS STRING)) AS platform_name,
           TRIM(CAST(platform AS STRING)) AS policy_keyfrom,
           TRIM(CAST(platform_5 AS STRING)) AS policy_authorid,
           TRIM(CAST(party_B AS STRING)) AS party_b,
           TRIM(CAST(contract_code AS STRING)) AS contract_code_raw,
           TRIM(CAST(ori_sign_date AS STRING)) AS ori_sign_date_raw,
           TRIM(CAST(is_normal AS STRING)) AS is_normal,
           TRIM(CAST(is_tmk AS STRING)) AS is_tmk,
           TRIM(CAST(is_bollte_allowance AS STRING)) AS is_bollte_allowance,
           TRIM(CAST(is_max_allowance AS STRING)) AS is_max_allowance,
           TRIM(CAST(is_ka AS STRING)) AS is_ka,
           CASE WHEN TRIM(COALESCE(CAST(deduction_amount AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(deduction_amount AS DECIMAL(28,8)) END AS deduction_amount,
           CASE WHEN TRIM(COALESCE(CAST(excluded_commission AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(excluded_commission AS DECIMAL(28,8)) END AS excluded_commission
    FROM w_policy_frozen_raw WHERE type='双周'
),
w_policy_frozen_policy_normalized AS (
SELECT *,
           CASE WHEN platform_name='臻好（铭栎）'
                 AND contract_code_raw=CONCAT('BJ-YLJY-02-20260611-03068、',CHR(10),'BJ-YLJY-02-20260622-01949')
                THEN REPLACE(contract_code_raw,CHR(10),'') ELSE contract_code_raw END AS contract_code,
           CASE WHEN ori_sign_date_raw RLIKE '^[0-9]{4,6}$'
                THEN CONCAT(YEAR(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'年',
                            MONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'月',
                            DAYOFMONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'日')
                WHEN ori_sign_date_raw RLIKE '^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日?$'
                THEN CONCAT(CAST(REGEXP_EXTRACT(ori_sign_date_raw,'^([0-9]{4})年',1) AS INT),'年',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'年([0-9]{1,2})月',1) AS INT),'月',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'月([0-9]{1,2})',1) AS INT),'日')
                ELSE ori_sign_date_raw END AS ori_sign_date,
           CASE WHEN policy_keyfrom NOT LIKE '%dyfx%' AND policy_keyfrom NOT LIKE '%-bmzx%'
                     AND policy_keyfrom NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN policy_keyfrom LIKE '%dyfx%' OR policy_keyfrom LIKE '%bmzx%'
                     OR policy_keyfrom LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM w_policy_frozen_policy_raw
),
w_policy_live_policy_raw AS (
SELECT TRIM(CAST(type AS STRING)) AS contract_type,
           TRIM(CAST(platform_name AS STRING)) AS platform_name,
           TRIM(CAST(platform AS STRING)) AS policy_keyfrom,
           TRIM(CAST(platform_5 AS STRING)) AS policy_authorid,
           TRIM(CAST(party_B AS STRING)) AS party_b,
           TRIM(CAST(contract_code AS STRING)) AS contract_code_raw,
           TRIM(CAST(ori_sign_date AS STRING)) AS ori_sign_date_raw,
           TRIM(CAST(is_normal AS STRING)) AS is_normal,
           TRIM(CAST(is_tmk AS STRING)) AS is_tmk,
           TRIM(CAST(is_bollte_allowance AS STRING)) AS is_bollte_allowance,
           TRIM(CAST(is_max_allowance AS STRING)) AS is_max_allowance,
           TRIM(CAST(is_ka AS STRING)) AS is_ka,
           CASE WHEN TRIM(COALESCE(CAST(deduction_amount AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(deduction_amount AS DECIMAL(28,8)) END AS deduction_amount,
           CASE WHEN TRIM(COALESCE(CAST(excluded_commission AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(excluded_commission AS DECIMAL(28,8)) END AS excluded_commission
    FROM temp.channel_pay_regular WHERE type='双周'
),
w_policy_live_policy_normalized AS (
SELECT *,
           CASE WHEN platform_name='臻好（铭栎）'
                 AND contract_code_raw=CONCAT('BJ-YLJY-02-20260611-03068、',CHR(10),'BJ-YLJY-02-20260622-01949')
                THEN REPLACE(contract_code_raw,CHR(10),'') ELSE contract_code_raw END AS contract_code,
           CASE WHEN ori_sign_date_raw RLIKE '^[0-9]{4,6}$'
                THEN CONCAT(YEAR(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'年',
                            MONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'月',
                            DAYOFMONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'日')
                WHEN ori_sign_date_raw RLIKE '^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日?$'
                THEN CONCAT(CAST(REGEXP_EXTRACT(ori_sign_date_raw,'^([0-9]{4})年',1) AS INT),'年',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'年([0-9]{1,2})月',1) AS INT),'月',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'月([0-9]{1,2})',1) AS INT),'日')
                ELSE ori_sign_date_raw END AS ori_sign_date,
           CASE WHEN policy_keyfrom NOT LIKE '%dyfx%' AND policy_keyfrom NOT LIKE '%-bmzx%'
                     AND policy_keyfrom NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN policy_keyfrom LIKE '%dyfx%' OR policy_keyfrom LIKE '%bmzx%'
                     OR policy_keyfrom LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM w_policy_live_policy_raw
),
w_policy_frozen_effective AS (SELECT contract_type,platform_name,policy_keyfrom,policy_authorid,party_b,contract_code,ori_sign_date,is_normal,is_tmk,is_bollte_allowance,is_max_allowance,is_ka,deduction_amount,excluded_commission FROM w_policy_frozen_policy_normalized),
w_policy_live_effective AS (SELECT contract_type,platform_name,policy_keyfrom,policy_authorid,party_b,contract_code,ori_sign_date,is_normal,is_tmk,is_bollte_allowance,is_max_allowance,is_ka,deduction_amount,excluded_commission FROM w_policy_live_policy_normalized),
w_policy_missing AS (SELECT * FROM w_policy_frozen_effective EXCEPT ALL SELECT * FROM w_policy_live_effective),
w_policy_extra AS (SELECT * FROM w_policy_live_effective EXCEPT ALL SELECT * FROM w_policy_frozen_effective),
w_policy_counts AS (
SELECT (SELECT COUNT(*) FROM w_policy_frozen_effective) AS frozen_rows,
       (SELECT COUNT(*) FROM w_policy_live_effective) AS live_rows,
       (SELECT COUNT(*) FROM w_policy_missing) AS missing_rows,
       (SELECT COUNT(*) FROM w_policy_extra) AS extra_rows
),
w_source_keys_raw AS (
SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,CAST(a.order_id AS STRING) AS order_id
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da a
JOIN bs_cohort_windows w ON a.dt=w.snapshot_dt
 AND CAST(a.start_class_dt AS STRING)=w.source_cohort
WHERE a.dt='${date}'
UNION ALL
SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,CAST(a.order_id AS STRING) AS order_id
FROM dw_conan_dwd.dwd_order_course_detail_bd_try_double_try_da a
JOIN bs_cohort_windows w ON a.dt=w.snapshot_dt
 AND CAST(a.start_class_dt AS STRING)=w.source_cohort
WHERE a.dt='${date}'
),
w_source_keys AS (
SELECT target_cohort,order_id,MAX(snapshot_dt) AS snapshot_dt,
       MAX(source_cohort) AS source_cohort,
       COUNT(DISTINCT snapshot_dt) AS snapshot_variants,
       COUNT(DISTINCT source_cohort) AS cohort_variants
FROM w_source_keys_raw GROUP BY target_cohort,order_id
),
w_input_keys AS (
SELECT CAST(target_cohort AS STRING) AS target_cohort,order_id,
       MAX(CAST(snapshot_dt AS STRING)) AS snapshot_dt,
       MAX(CAST(source_cohort AS STRING)) AS source_cohort,
       COUNT(*) AS input_rows,
       COUNT(DISTINCT snapshot_dt) AS snapshot_variants,
       COUNT(DISTINCT source_cohort) AS cohort_variants,
       SUM(CASE WHEN source_variant_count IS NULL OR source_variant_count<>1
                 OR policy_match_status IN ('pool_window_incomplete','pool_source_validation_failed',
                    'source_order_conflict','source_order_id_missing','source_order_status_invalid',
                    'source_renewal_invalid') THEN 1 ELSE 0 END) AS invalid_fact_rows
FROM bs_skill_input_present GROUP BY target_cohort,order_id
),
w_source_coverage AS (
SELECT COUNT(*) AS checked_orders,
       COALESCE(SUM(CASE WHEN s.order_id IS NULL OR i.order_id IS NULL
              OR LOWER(TRIM(COALESCE(s.order_id,''))) IN ('','-1','-1.0','null','none','nan','@pipe_null@','__null__')
              OR s.snapshot_variants<>1 OR s.cohort_variants<>1
              OR i.input_rows<>1 OR i.snapshot_variants<>1 OR i.cohort_variants<>1
              OR i.invalid_fact_rows<>0 OR NOT(s.snapshot_dt <=> i.snapshot_dt)
              OR NOT(s.source_cohort <=> i.source_cohort)
              OR s.target_cohort NOT BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) OR s.snapshot_dt<>'${date}'
            THEN 1 ELSE 0 END),0) AS invalid_source_keys
FROM w_source_keys s FULL OUTER JOIN w_input_keys i
 ON s.target_cohort=i.target_cohort AND s.order_id=i.order_id
),
w_target_source_coverage AS (
SELECT COUNT(*) AS scope_orders,
       COALESCE(SUM(CASE WHEN s.order_id IS NULL OR s.source_cohort<>t.start_class_dt
             OR s.snapshot_dt<>'${date}' THEN 1 ELSE 0 END),0) AS missing_target_facts
FROM w00_scope_keys t LEFT JOIN w_source_keys s
 ON t.order_id=s.order_id AND t.start_class_dt=s.target_cohort
),
w_window_checks AS (
SELECT COUNT(*) AS target_n,SUM(windows_n) AS windows_n,MIN(ok) AS all_windows_ok
FROM (
 SELECT target_cohort,COUNT(*) AS windows_n,
 CASE WHEN COUNT(*)=4 AND COUNT(DISTINCT source_cohort)=4
       AND COUNT(DISTINCT snapshot_dt)=1 AND MAX(snapshot_dt)='${date}'
       AND SUM(CASE WHEN target_cohort NOT BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
                 OR source_cohort>target_cohort OR DATE_ADD(TO_DATE(source_cohort),7)>TO_DATE('${date}')
                 THEN 1 ELSE 0 END)=0 THEN 1 ELSE 0 END AS ok
 FROM bs_cohort_windows GROUP BY target_cohort
) x
),
w_source_presence AS (
SELECT COUNT(*) AS target_n,MIN(CASE WHEN present_cohorts=4 THEN 1 ELSE 0 END) AS all_present
FROM (SELECT target_cohort,COUNT(DISTINCT source_cohort) AS present_cohorts
      FROM w_source_keys GROUP BY target_cohort) x
),
w_daily_prev_partition AS (
SELECT MAX(dt) AS prev_dt FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da
WHERE dt>='2026-10-18' AND dt<'${date}'
),
w_daily_prev_check AS (
SELECT p.prev_dt,COUNT(h.order_id) AS prev_rows,
       COUNT(DISTINCT h.start_class_dt) AS prev_cohorts,
       COALESCE(SUM(CASE WHEN h.order_id IS NULL OR h.start_class_dt IS NULL
          OR h.calculation_version IS NULL
          OR h.calculation_version NOT IN ('biz1-cpa-window30-backfill-20261018-v1','biz1-cpa-daily-window30-transfer-v2-20261022')
          OR h.fact_snapshot_dt IS NULL OR h.fact_snapshot_dt>p.prev_dt
          OR (p.prev_dt='2026-10-18' AND
              (h.calculation_version<>'biz1-cpa-window30-backfill-20261018-v1' OR h.fact_snapshot_dt<>'2026-10-18'))
          THEN 1 ELSE 0 END),0) AS bad_rows,
       CASE WHEN p.prev_dt=CAST(DATE_SUB(TO_DATE('${date}'),1) AS STRING)
            OR (p.prev_dt='2026-10-18' AND '${date}' BETWEEN '2026-10-19' AND '2026-10-25')
            THEN 1 ELSE 0 END AS continuity_ok
FROM w_daily_prev_partition p LEFT JOIN dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h ON h.dt=p.prev_dt
GROUP BY p.prev_dt
),
w_identity_current AS (
SELECT CAST(order_id AS STRING) AS order_id,
       MIN(CAST(start_class_dt AS STRING)) AS start_class_dt,
       COUNT(DISTINCT CAST(start_class_dt AS STRING)) AS cohort_n,
       SUM(CASE WHEN start_class_dt IS NULL OR TO_DATE(start_class_dt) IS NULL
            OR CAST(TO_DATE(start_class_dt) AS STRING)<>CAST(start_class_dt AS STRING)
            OR DAYOFWEEK(TO_DATE(start_class_dt))<>2 THEN 1 ELSE 0 END) AS bad_dates
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da WHERE dt='${date}' GROUP BY CAST(order_id AS STRING)
),
w_identity_previous AS (
SELECT CAST(a.order_id AS STRING) AS order_id,
       MIN(CAST(a.start_class_dt AS STRING)) AS start_class_dt,
       COUNT(DISTINCT CAST(a.start_class_dt AS STRING)) AS cohort_n,
       SUM(CASE WHEN a.start_class_dt IS NULL OR TO_DATE(a.start_class_dt) IS NULL
            OR CAST(TO_DATE(a.start_class_dt) AS STRING)<>CAST(a.start_class_dt AS STRING)
            OR DAYOFWEEK(TO_DATE(a.start_class_dt))<>2 THEN 1 ELSE 0 END) AS bad_dates
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da a CROSS JOIN w_daily_prev_partition p
WHERE a.dt=p.prev_dt GROUP BY CAST(a.order_id AS STRING)
),
w_previous_all_keys AS (
SELECT CAST(h.order_id AS STRING) AS order_id,MIN(CAST(h.start_class_dt AS STRING)) AS start_class_dt,
       COUNT(*) AS n
FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h CROSS JOIN w_daily_prev_partition p
WHERE h.dt=p.prev_dt GROUP BY CAST(h.order_id AS STRING)
),
w_transfer_evidence AS (
SELECT p.order_id,p.start_class_dt AS old_cohort,c.start_class_dt AS new_cohort,
       CASE WHEN p.n<>1 OR c.order_id IS NULL OR c.cohort_n<>1 OR c.bad_dates<>0
         OR c.start_class_dt<'2026-01-05'
         OR o.order_id IS NULL OR o.cohort_n<>1 OR o.bad_dates<>0
         OR o.start_class_dt<>p.start_class_dt THEN 1 ELSE 0 END AS bad_evidence
FROM w_previous_all_keys p LEFT JOIN w_identity_current c ON p.order_id=c.order_id
LEFT JOIN w_identity_previous o ON p.order_id=o.order_id
),
w_transfer_checks AS (
SELECT COUNT(*) AS checked_orders,
       COALESCE(SUM(bad_evidence),0) AS bad_evidence,
       COALESCE(SUM(CASE WHEN old_cohort<>new_cohort THEN 1 ELSE 0 END),0) AS moved_orders,
       COALESCE(SUM(CASE WHEN old_cohort<>new_cohort AND new_cohort>CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
                       THEN 1 ELSE 0 END),0) AS moved_to_unclosed
FROM w_transfer_evidence
),
w_refresh_prev_keys AS (
SELECT CAST(h.start_class_dt AS STRING) AS start_class_dt,
       CAST(h.order_id AS STRING) AS order_id,COUNT(*) AS n
FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h CROSS JOIN w_daily_prev_partition p
WHERE h.dt=p.prev_dt AND h.start_class_dt BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
GROUP BY h.start_class_dt,h.order_id
),
w_refresh_current_keys AS (
SELECT c.* FROM w00_scope_keys c CROSS JOIN w_daily_prev_partition p
WHERE c.start_class_dt<=CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE(p.prev_dt),7)) AS DATE) AS STRING)
),
w_refresh_key_check AS (
SELECT COUNT(*) AS compared_keys,
       COALESCE(SUM(CASE
          WHEN p.order_id IS NOT NULL AND (p.n<>1 OR i.order_id IS NULL
               OR i.cohort_n<>1 OR i.bad_dates<>0) THEN 1
          WHEN p.order_id IS NOT NULL AND c.order_id IS NULL
               AND i.start_class_dt=p.start_class_dt THEN 1
          WHEN c.order_id IS NOT NULL AND p.order_id IS NULL
               AND (o.order_id IS NULL OR o.cohort_n<>1 OR o.bad_dates<>0
                    OR (o.start_class_dt=c.start_class_dt
                        -- BOOTSTRAP: newest cohort may not exist in yesterday's partition yet.
                        AND c.start_class_dt<>CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE(dp.prev_dt),7)) AS DATE) AS STRING))) THEN 1
          WHEN c.order_id IS NOT NULL AND (i.order_id IS NULL OR i.cohort_n<>1
               OR i.bad_dates<>0 OR i.start_class_dt<>c.start_class_dt) THEN 1
          ELSE 0 END),0) AS bad_keys
FROM w_refresh_prev_keys p FULL OUTER JOIN w_refresh_current_keys c ON p.order_id=c.order_id
CROSS JOIN w_daily_prev_partition dp
LEFT JOIN w_identity_current i ON COALESCE(p.order_id,c.order_id)=i.order_id
LEFT JOIN w_identity_previous o ON COALESCE(p.order_id,c.order_id)=o.order_id
),
w_daily_guard AS (
SELECT CASE WHEN COALESCE('${date}' RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       AND CAST(TO_DATE('${date}') AS STRING)='${date}',FALSE)
       AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)>='2026-10-05' AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)<='2026-11-16'
       AND v.frozen_rows=173 AND v.live_rows=173 AND v.missing_rows=0 AND v.extra_rows=0
       AND c.target_n BETWEEN 1 AND 5 AND c.latest_target<=CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AND c.bad_cohort_dates=0
       AND c.expected_orders>0 AND c.expected_orders=c.unique_expected_orders AND c.invalid_scope_orders=0
       AND w.target_n=c.target_n AND w.windows_n=4*c.target_n AND w.all_windows_ok=1
       AND p.target_n=c.target_n AND p.all_present=1
       AND k.checked_orders>0 AND k.invalid_source_keys=0
       AND t.scope_orders=c.expected_orders AND t.missing_target_facts=0
       AND j.bad_keys=0 AND tr.checked_orders=z.prev_rows AND tr.bad_evidence=0
       AND z.continuity_ok=1 AND z.prev_rows>0 AND z.bad_rows=0
       AND (z.prev_dt<>'2026-10-18' OR (z.prev_rows=656968 AND z.prev_cohorts=36))
       THEN TRUE ELSE FALSE END AS allowed
FROM (SELECT COUNT(*) AS target_n,MAX(target_cohort) AS latest_target,
             SUM(expected_orders) AS expected_orders,SUM(unique_expected_orders) AS unique_expected_orders,
             SUM(invalid_scope_orders) AS invalid_scope_orders,
SUM(CASE WHEN DAYOFWEEK(TO_DATE(target_cohort))<>2 THEN 1 ELSE 0 END) AS bad_cohort_dates
FROM n00_target_calendar) c
CROSS JOIN w_window_checks w CROSS JOIN w_source_presence p CROSS JOIN w_source_coverage k
CROSS JOIN w_target_source_coverage t CROSS JOIN w_policy_counts v CROSS JOIN w_refresh_key_check j

CROSS JOIN w_daily_prev_check z

CROSS JOIN w_transfer_checks tr
)
INSERT OVERWRITE TABLE dw_conan_ads.tmp_biz1_cpa_order_settlement_policy
SELECT CASE WHEN g.allowed AND p.order_id IS NOT NULL THEN p.`target_cohort`
 ELSE CAST(assert_true(COALESCE(g.allowed AND p.order_id IS NOT NULL,FALSE)) AS DATE) END AS target_cohort,
       p.`snapshot_dt`,
       p.`source_cohort`,
       p.`order_id`,
       p.`user_id`,
       p.`order_status`,
       p.`subject`,
       p.`pay_dt`,
       p.`pay_tp`,
       p.`pay_amt`,
       p.`keyfrom`,
       p.`semester_type`,
       p.`platform_5`,
       p.`platform_5_6`,
       p.`type`,
       p.`season_order_id`,
       p.`season_refund_type`,
       p.`season_pay_dt`,
       p.`season_pay_tp`,
       p.`end_xb_dt`,
       p.`is_no_settle`,
       p.`authorid`,
       p.`contract_type`,
       p.`platform_name`,
       p.`policy_keyfrom`,
       p.`party_b`,
       p.`contract_code`,
       p.`contract_code_raw`,
       p.`ori_sign_date`,
       p.`is_normal`,
       p.`is_tmk`,
       p.`is_bollte_allowance`,
       p.`is_max_allowance`,
       p.`is_ka`,
       p.`deduction_amount`,
       p.`excluded_commission`,
       p.`policy_match_status`,
       p.`policy_candidate_count`,
       p.`candidate_platform_names`,
       p.`source_variant_count`,
       p.`source_family`,
       p.`late_renewal_cleared`
FROM w_daily_guard g LEFT JOIN bs_skill_input_present p ON TRUE;

-- STAGE 1 MUST SUCCEED BEFORE STAGE 2 IS EXECUTED.
-- DAILY ADAPTER: run earliest 08:00; business date is yesterday, any weekday.
-- Select actual closed cohorts (Monday <= date - 7); refresh ages 7..35, renewal capped at +29.
-- Generated locally; not evidence of Spark execution or release.
SET spark.sql.session.timeZone=Asia/Shanghai;
SET spark.driver.memory=16g;
SET spark.sql.maxPlanStringLength=8192;
SET spark.sql.ui.explainMode=simple;
SET spark.sql.shuffle.partitions=200;
SET spark.sql.analyzer.maxIterations=500;
SET spark.sql.sources.partitionOverwriteMode=dynamic;
SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
WITH
w00_scope_keys AS (
SELECT DISTINCT CAST(d.order_id AS STRING) AS order_id,
       CAST(d.start_class_dt AS STRING) AS start_class_dt
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
WHERE d.dt='${date}' AND CAST(d.start_class_dt AS STRING) BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
),
n00_target_calendar AS (
SELECT start_class_dt AS target_cohort,'${date}' AS snapshot_dt,
       COUNT(*) AS expected_orders,COUNT(DISTINCT order_id) AS unique_expected_orders,
       COALESCE(SUM(CASE WHEN order_id IS NULL OR LOWER(TRIM(order_id)) IN
       ('','-1','-1.0','null','none','nan','@pipe_null@','__null__') THEN 1 ELSE 0 END),0) AS invalid_scope_orders
FROM w00_scope_keys GROUP BY start_class_dt
),
n01_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n01_target_scope AS (
SELECT DISTINCT CAST(d.order_id AS STRING) AS order_id,
           CAST(d.start_class_dt AS STRING) AS start_class_dt
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n01_params p
    WHERE d.dt=p.as_of_dt AND d.start_class_dt BETWEEN p.start_dt AND p.end_dt
      AND CAST(d.start_class_dt AS STRING) IN (SELECT target_cohort FROM n00_target_calendar)
),
bs_target_scope AS (
SELECT * FROM n01_target_scope
),
n02_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n02_opening_calendar AS (
SELECT DISTINCT CAST(d.start_class_dt AS STRING) AS source_cohort
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n02_params p
    WHERE d.dt=p.as_of_dt AND d.start_class_dt<=p.end_dt
      AND TO_DATE(d.start_class_dt) IS NOT NULL
),
n02_ranked_calendar AS (
-- 已确认固定4期。窗口直接携带前3期，避免两次排名表自连接。
    SELECT source_cohort,
           COLLECT_LIST(source_cohort) OVER (
               ORDER BY source_cohort ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
           ) AS pool_cohorts
    FROM n02_opening_calendar
),
n02_cohort_windows AS (
SELECT c.source_cohort AS target_cohort,
           '${date}' AS snapshot_dt,
           EXPLODE(c.pool_cohorts) AS source_cohort
    FROM n02_ranked_calendar c CROSS JOIN n02_params p
    WHERE c.source_cohort BETWEEN p.start_dt AND p.end_dt
      AND c.source_cohort IN (SELECT target_cohort FROM n00_target_calendar)
),
bs_cohort_windows AS (
SELECT * FROM n02_cohort_windows
),
n03_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n03_opening_calendar AS (
SELECT DISTINCT CAST(d.start_class_dt AS STRING) AS source_cohort
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n03_params p
    WHERE d.dt=p.as_of_dt AND d.start_class_dt<=p.end_dt
      AND TO_DATE(d.start_class_dt) IS NOT NULL
),
n03_target_cohorts AS (
SELECT c.source_cohort AS target_cohort,
           '${date}' AS snapshot_dt
    FROM n03_opening_calendar c CROSS JOIN n03_params p
    WHERE c.source_cohort BETWEEN p.start_dt AND p.end_dt
      AND c.source_cohort IN (SELECT target_cohort FROM n00_target_calendar)
),
n03_window_snapshot_presence AS (
SELECT DISTINCT w.target_cohort,w.source_cohort
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n03_params p
    JOIN bs_cohort_windows w ON CAST(d.dt AS STRING)=w.snapshot_dt
                         AND CAST(d.start_class_dt AS STRING)=w.source_cohort
    WHERE d.dt='${date}'
),
n03_cohort_readiness AS (
SELECT t.target_cohort,t.snapshot_dt,
           COUNT(DISTINCT h.source_cohort) AS available_cohorts,
           CASE WHEN t.snapshot_dt<=p.as_of_dt
                      AND COUNT(DISTINCT h.source_cohort)=p.rate_cohort_count
                THEN 1 ELSE 0 END AS ready
    FROM n03_target_cohorts t CROSS JOIN n03_params p
    LEFT JOIN n03_window_snapshot_presence h ON t.target_cohort=h.target_cohort
    GROUP BY t.target_cohort,t.snapshot_dt,p.as_of_dt,p.rate_cohort_count
),
bs_cohort_readiness AS (
SELECT * FROM n03_cohort_readiness
),
n04_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n04_opening_calendar AS (
SELECT DISTINCT CAST(d.start_class_dt AS STRING) AS source_cohort
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n04_params p
    WHERE d.dt=p.as_of_dt AND d.start_class_dt<=p.end_dt
      AND TO_DATE(d.start_class_dt) IS NOT NULL
),
n04_target_cohorts AS (
SELECT c.source_cohort AS target_cohort,
           '${date}' AS snapshot_dt
    FROM n04_opening_calendar c CROSS JOIN n04_params p
    WHERE c.source_cohort BETWEEN p.start_dt AND p.end_dt
      AND c.source_cohort IN (SELECT target_cohort FROM n00_target_calendar)
),
n04_history_distinct AS (
SELECT DISTINCT CAST(d.order_id AS STRING) AS order_id,
           CAST(d.start_class_dt AS STRING) AS historical_start_class_dt,
           CAST(d.dt AS STRING) AS snapshot_dt,
           CAST(d.order_status AS STRING) AS order_status,
           CAST(d.pay_tp AS STRING) AS pay_tp_raw,
           CAST(d.season_order_id AS STRING) AS season_order_id_raw,
           CAST(d.season_refund_type AS STRING) AS season_refund_type,
           CAST(d.season_pay_dt AS STRING) AS season_pay_dt_raw
    FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da d
    CROSS JOIN n04_params p
    JOIN n04_target_cohorts c ON CAST(d.dt AS STRING)=c.snapshot_dt
                         AND CAST(d.start_class_dt AS STRING)=c.target_cohort
    WHERE d.dt='${date}'
      AND d.start_class_dt BETWEEN p.start_dt AND p.end_dt
),
n04_history_counted AS (
SELECT *,COUNT(*) OVER (PARTITION BY order_id,snapshot_dt) AS fact_variants
    FROM n04_history_distinct
),
n04_history_one AS (
SELECT * FROM n04_history_counted WHERE fact_variants=1
),
n04_fact_joined AS (
SELECT s.order_id,s.start_class_dt,c.snapshot_dt,
           h.order_id AS historical_order_id,h.order_status,h.pay_tp_raw,
           h.season_order_id_raw,h.season_refund_type,h.season_pay_dt_raw,
           TO_DATE(SUBSTR(h.season_pay_dt_raw,1,10)) AS season_pay_date,
           CASE WHEN h.season_order_id_raw IS NULL
                     OR LOWER(TRIM(h.season_order_id_raw)) IN
                        ('','-1','-1.0','null','none','nan','@pipe_null@')
                THEN 0 ELSE 1 END AS has_season_id
    FROM bs_target_scope s
    JOIN n04_target_cohorts c ON s.start_class_dt=c.target_cohort
    LEFT JOIN n04_history_one h ON s.order_id=h.order_id
                           AND c.snapshot_dt=h.snapshot_dt
                           AND s.start_class_dt=h.historical_start_class_dt
),
n04_order_facts AS (
SELECT start_class_dt,order_id,
           CASE WHEN historical_order_id IS NOT NULL THEN order_status END AS order_status_label,
           CASE WHEN historical_order_id IS NULL THEN CAST(NULL AS INT)
                WHEN has_season_id=0 AND season_refund_type='正常'
                     AND (season_pay_dt_raw IS NULL OR TRIM(season_pay_dt_raw)='') THEN 0
                WHEN has_season_id=0 THEN CAST(NULL AS INT)
                WHEN season_pay_date IS NULL OR season_refund_type IS NULL
                     OR season_refund_type NOT IN ('正常','退款') THEN CAST(NULL AS INT)
                WHEN season_refund_type='正常' AND season_pay_date<=LEAST(DATE_ADD(TO_DATE(start_class_dt),29),TO_DATE(snapshot_dt)) THEN 1
                ELSE 0 END AS is_renewed,
           CASE WHEN historical_order_id IS NOT NULL AND pay_tp_raw RLIKE '^[0-9]{13}$'
                THEN CAST(FROM_UNIXTIME(CAST(pay_tp_raw AS BIGINT) DIV 1000) AS TIMESTAMP)
                ELSE CAST(NULL AS TIMESTAMP) END AS pay_time
    FROM n04_fact_joined
),
bs_order_facts AS (
SELECT * FROM n04_order_facts
),
bs_explicit_estimate_holds AS (
-- Approved ANALYSIS holds, not a decision that these refunds are non-payable.
SELECT * FROM VALUES
 ('2026-04-20','2026-05-04','1086210161','REFUND_DESTINATION_UNRESOLVED'),
 ('2026-04-20','2026-05-04','1086496673','REFUND_DESTINATION_UNRESOLVED')
 AS h(target_cohort,snapshot_dt,order_id,settlement_hold_category)
),
bs_attribution_hold_evidence AS (
-- Current-partition attribution; no order-id global blacklist.
SELECT s.start_class_dt AS target_cohort,
       '${date}' AS snapshot_dt,
       s.order_id,MAX(CAST(a.user_from AS STRING)) AS historical_user_from,
       MAX(CAST(a.ad_channel AS STRING)) AS historical_ad_channel
FROM bs_target_scope s
JOIN dw_conan_dwd.dwd_trade_try_double_order_from_info_da a
 ON CAST(a.order_id AS STRING)=s.order_id
AND CAST(a.dt AS STRING)='${date}'
WHERE a.dt='${date}' AND a.dt BETWEEN '${date}' AND '${date}'
GROUP BY s.start_class_dt,s.order_id
HAVING COUNT(*)=1 AND NOT(MAX(CAST(a.user_from AS STRING)) <=> '商务合作')
),
bs_full35_input_present_raw AS (
-- Reuse the existing physical table; selected scope does not imply it was refreshed.
-- Downstream all_input_ready guard requires ALL selected four-period windows.
SELECT p.* FROM dw_conan_ads.tmp_biz1_cpa_order_settlement_policy p
WHERE CAST(p.target_cohort AS STRING) IN (SELECT target_cohort FROM n00_target_calendar)
),
bs_skill_input_present AS (
SELECT p.* FROM bs_full35_input_present_raw p
LEFT JOIN bs_attribution_hold_evidence h
 ON p.order_id=h.order_id AND CAST(p.source_cohort AS STRING)=h.target_cohort
AND CAST(p.snapshot_dt AS STRING)=h.snapshot_dt
LEFT JOIN bs_explicit_estimate_holds x
 ON p.order_id=x.order_id AND CAST(p.source_cohort AS STRING)=x.target_cohort
AND CAST(p.snapshot_dt AS STRING)=x.snapshot_dt
WHERE h.order_id IS NULL AND x.order_id IS NULL
),
n12_skill_windows AS (
SELECT DISTINCT TO_DATE(target_cohort) target_cohort,TO_DATE(snapshot_dt) snapshot_dt,
           TO_DATE(source_cohort) source_cohort FROM bs_cohort_windows
),
n12_skill_window_checks AS (
SELECT target_cohort,COUNT(*) window_count,COUNT(DISTINCT snapshot_dt) snapshot_count,
           MAX(snapshot_dt) snapshot_dt,
           SUM(CASE WHEN DATE_ADD(source_cohort,7)<=snapshot_dt THEN 0 ELSE 1 END) immature_windows
    FROM n12_skill_windows GROUP BY target_cohort
),
n12_skill_input AS (
SELECT * FROM bs_skill_input_present
    UNION ALL
    -- 保留主范围中模板/历史源缺失的目标，不把它们制造成退款或正常0成本。
    SELECT TO_DATE(t.start_class_dt),w.snapshot_dt,TO_DATE(t.start_class_dt),CAST(t.order_id AS STRING),
           CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),
           CAST(NULL AS DECIMAL(28,8)),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),
           CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS DATE),CAST(NULL AS STRING),
           LEAST(DATE_ADD(TO_DATE(t.start_class_dt),29),TO_DATE('${date}')),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),
           CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),
           CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),CAST(NULL AS STRING),
           CAST(NULL AS STRING),CAST(NULL AS DECIMAL(28,8)),CAST(NULL AS DECIMAL(28,8)),
           'historical_source_missing',0,CAST(NULL AS STRING),0,'MISSING_TARGET',0
    FROM bs_target_scope t
    LEFT JOIN n12_skill_window_checks w ON TO_DATE(t.start_class_dt)=w.target_cohort
    LEFT JOIN bs_skill_input_present p ON CAST(t.order_id AS STRING)=p.order_id AND TO_DATE(t.start_class_dt)=p.target_cohort
    WHERE p.order_id IS NULL
),
bs_skill_input AS (
SELECT * FROM n12_skill_input
),
n13_skill_known_platforms AS (
SELECT '乐知（凌泽）' AS platform_name UNION ALL SELECT '云电'
  UNION ALL SELECT '亿起发' UNION ALL SELECT '仁轩' UNION ALL SELECT '元慷文化'
  UNION ALL SELECT '八斗' UNION ALL SELECT '北极鸥' UNION ALL SELECT '千亿教育'
  UNION ALL SELECT '博学（谦受益）' UNION ALL SELECT '启睿' UNION ALL SELECT '哪吒'
  UNION ALL SELECT '墨点' UNION ALL SELECT '够玩' UNION ALL SELECT '学研星途'
  UNION ALL SELECT '尔瑞' UNION ALL SELECT '巨航' UNION ALL SELECT '微尚'
  UNION ALL SELECT '德才' UNION ALL SELECT '文荀' UNION ALL SELECT '星耀学1'
  UNION ALL SELECT '晨曦' UNION ALL SELECT '海裕' UNION ALL SELECT '湖州云梯'
  UNION ALL SELECT '玉琴' UNION ALL SELECT '网聚天下社群' UNION ALL SELECT '臻好（铭栎）'
  UNION ALL SELECT '蓝智' UNION ALL SELECT '诚学' UNION ALL SELECT '酬勤信息'
  UNION ALL SELECT '铭祺' UNION ALL SELECT '长台' UNION ALL SELECT '雅艺'
  UNION ALL SELECT '静魅' UNION ALL SELECT '馨松'
),
n13_skill_held_platforms AS (
SELECT '百杰胜' AS platform_name UNION ALL SELECT '无忧' UNION ALL SELECT '壹佰分'
  UNION ALL SELECT '胖虎' UNION ALL SELECT '佳慕' UNION ALL SELECT '优思睿'
  UNION ALL SELECT '精灵' UNION ALL SELECT '绿韵' UNION ALL SELECT '满天星（代播）'
  UNION ALL SELECT '易而购' UNION ALL SELECT '有养' UNION ALL SELECT '泰迪'
  UNION ALL SELECT '卡涵信息' UNION ALL SELECT '精微特文化' UNION ALL SELECT '晢珩电子'
  UNION ALL SELECT '富榕电子' UNION ALL SELECT '青为管理' UNION ALL SELECT '三合文化'
  UNION ALL SELECT '诚甲' UNION ALL SELECT '京渝永建' UNION ALL SELECT '开朗文化'
),
n13_skill_scenario_platforms AS (
-- Only these five held platforms have an explicitly authorized same-policy scenario.
  -- Their official hold remains; no new English test guarantee is invented.
  SELECT '胖虎' AS platform_name UNION ALL SELECT '佳慕' UNION ALL SELECT '无忧'
  UNION ALL SELECT '优思睿' UNION ALL SELECT '壹佰分'
),
n13_skill_normalized AS (
SELECT i.*,
    CASE WHEN trim(i.platform_name) IN ('开朗文化阅读','开朗文化双科') THEN '开朗文化'
         WHEN trim(i.platform_name) IN ('京渝永建英语','京渝永建双科') THEN '京渝永建'
         ELSE trim(i.platform_name) END AS pricing_platform,
    CASE WHEN trim(i.platform_name)='壹佰分' THEN
           CASE WHEN bround(CAST(i.pay_amt AS DOUBLE),2) IN (7.95,14.5) THEN '双科'
                WHEN bround(CAST(i.pay_amt AS DOUBLE),2)=19 THEN '单科' ELSE '未知价' END
         ELSE '通用' END AS pricing_subject,
    CASE WHEN (i.party_b IS NULL OR lower(trim(i.party_b)) IN ('','nan','null'))
                   AND trim(i.platform_name) IN ('悦冠','徐州向学')
         THEN '徐州向学信息科技有限公司' ELSE trim(i.party_b) END AS pricing_party,
    CASE WHEN i.season_order_id IS NOT NULL
                   AND lower(trim(CAST(i.season_order_id AS STRING))) NOT IN ('','-1','-1.0','nan','none','null','@pipe_null@')
                   AND i.season_refund_type='正常'
                   AND substr(CAST(i.season_pay_dt AS STRING),1,10)<=CAST(LEAST(date_add(i.source_cohort,29),TO_DATE(i.snapshot_dt)) AS STRING)
         THEN CAST(i.season_order_id AS STRING) END AS valid_season_id,
    CASE WHEN i.order_status='正常' THEN CAST(i.order_id AS STRING) END AS valid_child_id,
    CASE WHEN trim(i.platform_name)='壹佰分' THEN '否' ELSE trim(i.is_ka) END AS effective_ka,
    CASE WHEN trim(i.platform_name)='壹佰分' OR trim(i.platform_name) IN ('京渝永建','京渝永建双科','京渝永建英语')
         THEN '否' ELSE trim(i.is_bollte_allowance) END AS effective_guarantee_flag,
    count(*) OVER (PARTITION BY i.target_cohort,i.order_id) AS source_row_count
  FROM bs_skill_input i
),
n13_skill_rows AS (
SELECT n.*,
    CASE WHEN sp.platform_name IS NOT NULL THEN 'same_policy'
         WHEN hp.platform_name IS NOT NULL THEN 'hold'
         WHEN kp.platform_name IS NOT NULL THEN 'skill' ELSE 'hold_new' END AS price_layer,
    CASE WHEN (n.keyfrom LIKE 'yxzz-sw-sy%' OR n.keyfrom LIKE 'yxzz-sw-qt%')
                   AND lower(trim(CAST(n.is_no_settle AS STRING))) IN ('1','1.0','true','yes','是')
                   AND n.source_cohort>='2026-07-20' AND n.valid_season_id IS NOT NULL
         THEN 300 ELSE 0 END AS direct_deduction,
    CASE WHEN n.source_row_count<>1 THEN 1
         WHEN coalesce(n.policy_match_status,'')<>'matched' THEN 1
         WHEN n.order_id IS NULL OR trim(CAST(n.order_id AS STRING))='' THEN 1
         WHEN coalesce(n.order_status,'') NOT IN ('正常','退款') THEN 1
         WHEN n.keyfrom IS NULL OR trim(n.keyfrom)='' THEN 1
         WHEN CAST(n.snapshot_dt AS STRING)<>'${date}' THEN 1
         WHEN n.season_order_id IS NOT NULL AND lower(trim(CAST(n.season_order_id AS STRING))) NOT IN ('','-1','-1.0','nan','none','null','@pipe_null@')
              AND (n.season_pay_dt IS NULL OR trim(CAST(n.season_pay_dt AS STRING))='' OR coalesce(n.season_refund_type,'') NOT IN ('正常','退款')) THEN 1
         ELSE 0 END AS input_invalid
  FROM n13_skill_normalized n
  LEFT JOIN n13_skill_known_platforms kp ON n.pricing_platform=kp.platform_name
  LEFT JOIN n13_skill_held_platforms hp ON n.pricing_platform=hp.platform_name
  LEFT JOIN n13_skill_scenario_platforms sp ON n.pricing_platform=sp.platform_name
),
bs_skill_rows AS (
SELECT * FROM n13_skill_rows
),
n14_skill_group_counts AS (
SELECT target_cohort,snapshot_dt,pricing_platform,pricing_subject,
    max(price_layer) AS price_layer,
    count(DISTINCT valid_child_id) AS child_n,
    count(DISTINCT valid_season_id) AS season_n,
    count(DISTINCT pricing_party) AS party_n,
    count(DISTINCT contract_code) AS contract_n,
    max(CASE WHEN coalesce(pricing_party,'')='' OR coalesce(contract_code,'')='' THEN 1 ELSE 0 END) AS identity_missing,
    max(pricing_party) AS party_b,
    max(input_invalid) AS input_invalid,
    max(effective_ka) AS effective_ka,
    max(effective_guarantee_flag) AS effective_guarantee_flag,
    max(trim(is_max_allowance)) AS is_max_allowance,
    count(DISTINCT effective_ka) AS ka_variants,
    count(DISTINCT effective_guarantee_flag) AS guarantee_variants,
    count(DISTINCT trim(is_max_allowance)) AS subsidy_variants,
    max(coalesce(CAST(deduction_amount AS DOUBLE),0)) AS fixed_deduction,
    max(coalesce(CAST(excluded_commission AS DOUBLE),0)) AS excluded_commission,
    max(source_cohort) AS bill_end,
    max(CASE WHEN instr(keyfrom,'ss-cpa-hzyt')>0 OR instr(keyfrom,'ss-CPA-hzyt')>0 THEN 1 ELSE 0 END) AS hzyt_override,
    max(CASE WHEN instr(keyfrom,'changtaixx')>0 OR instr(pricing_platform,'changtaixx')>0 THEN 1 ELSE 0 END) AS changtai1_override,
    count(DISTINCT CASE WHEN direct_deduction=300 THEN order_id END)*300 AS all_period_direct
  FROM bs_skill_rows
  GROUP BY target_cohort,snapshot_dt,pricing_platform,pricing_subject
),
bs_skill_group_counts AS (
SELECT * FROM n14_skill_group_counts
),
n15_skill_guarantees AS (
-- Existing code is start-only unless hard_expire is explicitly true.
  -- Do NOT silently activate obsolete end_date/guaranteed_days as hard expiry.
  SELECT '杭州禧泽互联网科技发展有限公司' AS party_b, '2026-02-15' AS start_date, 0.060 AS rate_threshold, 70 AS unit_price
  UNION ALL SELECT '深圳市稻果文化传播有限公司','2026-05-25',0.065,80
  UNION ALL SELECT '滁州亿起发网络科技有限公司','2026-05-18',0.055,60
  UNION ALL SELECT '广东哪塔库信息科技有限公司','2026-05-25',0.050,50
  UNION ALL SELECT '徐州小瓶盖信息科技有限公司','2026-05-26',0.105,130
  UNION ALL SELECT '菏泽酷游网络科技有限公司','2026-06-13',0.100,120
  UNION ALL SELECT '菏泽雅览教育服务有限公司','2026-06-26',0.100,120
  UNION ALL SELECT '菏泽市曹县辰锦网络科技有限公司','2026-06-09',0.065,75
  UNION ALL SELECT '湖北停云电子科技有限公司','2026-06-01',0.090,110
  UNION ALL SELECT '湖州云梯科技有限公司','2099-01-01',0.095,120
  UNION ALL SELECT '杭州优投智数科技有限公司','2026-04-20',0.060,70
  UNION ALL SELECT '郴州目标信息咨询有限公司','2026-05-27',0.065,80
  UNION ALL SELECT '上海优思睿信息科技有限公司','2026-06-01',0.065,70
  UNION ALL SELECT '宁波铭栎智能科技有限公司','2025-04-26',0.070,100
  UNION ALL SELECT '深圳市高八斗科技有限公司','2026-05-18',0.065,80
  UNION ALL SELECT '固镇县墨点科技有限公司','2026-06-01',0.065,70
  UNION ALL SELECT '深圳尔瑞信息技术有限公司','2026-06-01',0.065,70
  UNION ALL SELECT '广州市廷嘉科技有限公司','2026-06-01',0.065,70
  UNION ALL SELECT '山西德才教育科技有限公司','2026-06-01',0.065,70
  UNION ALL SELECT '南昌春夏文化传媒有限公司','2026-05-15',0.050,50
  UNION ALL SELECT '泉州市静魅文化传媒有限公司','2026-05-25',0.065,80
  UNION ALL SELECT '宁波臻好信息技术有限公司','2026-04-01',0.070,100
  UNION ALL SELECT '广州云岛科技有限公司','2026-06-10',0.055,55
  UNION ALL SELECT '徐州向学信息科技有限公司','2026-05-25',0.055,60
  UNION ALL SELECT '北京晨鑫益晟家政服务有限公司','2026-04-20',0.055,60
  UNION ALL SELECT '菏泽晨曦文化传媒有限公司','2026-05-20',0.050,55
  UNION ALL SELECT '菏泽市牡丹区绿韵电子商务有限公司','2026-06-12',0.100,120
  UNION ALL SELECT '江西慎思之信息科技有限公司','2026-03-01',0.070,100
  UNION ALL SELECT '童画（广州）网络科技有限公司','2026-06-22',0.065,80
  UNION ALL SELECT '邯郸酬信科技有限公司','2026-03-01',0.070,100
  UNION ALL SELECT '北京乐知科技有限公司','2026-01-01',0.070,100
  UNION ALL SELECT '杭州全科墙网络有限公司','2026-01-01',0.070,100
  UNION ALL SELECT '深圳楚航信息科技有限公司','2026-01-13',0.070,100
  UNION ALL SELECT '北京燃势网络科技有限公司','2026-03-23',0.050,75
  UNION ALL SELECT '山西潇沐网络科技有限公司','2026-04-01',0.050,55
  UNION ALL SELECT '杭州长台网络科技有限公司','2026-04-01',0.065,80
),
n15_skill_tiers AS (
-- Bounds are thousandths AFTER Python-compatible truncation, lower inclusive.
  SELECT 50 AS lo,55 AS hi,55 AS ordinary_price,75 AS ka_price,50 AS bpo_price,40 AS english_price,55 AS short_price
  UNION ALL SELECT 55,60,63,83,58,50,63
  UNION ALL SELECT 60,65,70,90,65,65,70
  UNION ALL SELECT 65,70,80,100,75,75,80
  UNION ALL SELECT 70,75,87,110,82,90,87
  UNION ALL SELECT 75,80,93,118,88,100,93
  UNION ALL SELECT 80,85,100,125,95,110,100
  UNION ALL SELECT 85,90,107,135,100,120,107
  UNION ALL SELECT 90,95,115,145,110,135,115
  UNION ALL SELECT 95,100,122,152,117,145,122
  UNION ALL SELECT 100,105,130,160,125,155,130
  UNION ALL SELECT 105,110,140,170,135,165,130
  UNION ALL SELECT 110,115,150,180,145,175,130
  UNION ALL SELECT 115,120,158,188,153,180,130
  UNION ALL SELECT 120,125,165,195,160,190,130
  UNION ALL SELECT 125,130,176,206,171,200,130
  UNION ALL SELECT 130,CAST(NULL AS INT),185,215,180,200,130
),
n15_skill_period_counts AS (
SELECT target_cohort,pricing_platform,pricing_subject,source_cohort,
    count(DISTINCT valid_child_id) AS child_n,
    count(DISTINCT valid_season_id) AS season_n
  FROM bs_skill_rows
  GROUP BY target_cohort,pricing_platform,pricing_subject,source_cohort
),
n15_skill_period_subsidies AS (
SELECT p.*,
    CASE WHEN g.pricing_platform<>'壹佰分' AND g.is_max_allowance='是'
                   AND p.child_n>=2500 AND CAST(p.season_n AS DOUBLE)/p.child_n>=0.05
         THEN CASE WHEN p.child_n>=3500 THEN 10 ELSE 5 END ELSE 0 END AS unit_subsidy
  FROM n15_skill_period_counts p JOIN bs_skill_group_counts g
    ON p.target_cohort=g.target_cohort AND p.pricing_platform=g.pricing_platform AND p.pricing_subject=g.pricing_subject
),
n15_skill_subsidy_totals AS (
SELECT target_cohort,pricing_platform,pricing_subject,
    sum(child_n*unit_subsidy) AS all_period_subsidy,
    max(CASE WHEN source_cohort=target_cohort THEN unit_subsidy ELSE 0 END) AS target_unit_subsidy
  FROM n15_skill_period_subsidies GROUP BY target_cohort,pricing_platform,pricing_subject
),
n15_skill_group_rates AS (
SELECT g.*,s.all_period_subsidy,s.target_unit_subsidy,
    CASE WHEN child_n>0 THEN CAST(CAST(season_n AS DOUBLE)/CAST(child_n AS DOUBLE)*1000 AS BIGINT) ELSE 0 END AS rate_milli,
    CASE WHEN g.pricing_platform='网聚天下bpo' THEN 'bpo'
         WHEN g.pricing_platform IN ('优思睿','墨点','尔瑞','廷嘉','德才') THEN 'english'
         WHEN effective_ka='是' THEN 'ka'
         WHEN g.pricing_platform IN ('潇沐','破晓','巨航','悦冠','徐州向学','昆紫','星耀学1','奇趣') THEN 'short'
         ELSE 'ordinary' END AS tier_family,
    CASE WHEN g.pricing_platform='壹佰分' THEN CASE WHEN g.pricing_subject='双科' THEN '2026-06-03' WHEN g.pricing_subject='单科' THEN '2026-05-25' END
         WHEN g.party_b='湖州云梯科技有限公司' AND hzyt_override=1 THEN '2026-07-29'
         WHEN g.party_b='杭州长台网络科技有限公司' AND changtai1_override=1 THEN '2026-06-22'
         ELSE c.start_date END AS guarantee_start,
    CASE WHEN g.party_b='湖州云梯科技有限公司' AND hzyt_override=1 THEN '2026-10-28' ELSE NULL END AS guarantee_hard_end,
    CASE WHEN g.pricing_platform='壹佰分' THEN CASE WHEN g.pricing_subject='双科' THEN 0.055 WHEN g.pricing_subject='单科' THEN 0.09 END
         WHEN g.party_b='杭州长台网络科技有限公司' AND changtai1_override=1 THEN 0.10 ELSE c.rate_threshold END AS guarantee_threshold,
    CASE WHEN g.pricing_platform='壹佰分' THEN CASE WHEN g.pricing_subject='双科' THEN 60 WHEN g.pricing_subject='单科' THEN 110 END
         WHEN g.party_b='杭州长台网络科技有限公司' AND changtai1_override=1 THEN 130 ELSE c.unit_price END AS guarantee_unit
  FROM bs_skill_group_counts g
  JOIN n15_skill_subsidy_totals s ON g.target_cohort=s.target_cohort AND g.pricing_platform=s.pricing_platform AND g.pricing_subject=s.pricing_subject
  LEFT JOIN n15_skill_guarantees c ON g.party_b=c.party_b
),
n15_skill_group_units AS (
SELECT g.*,
    CASE WHEN bill_end>=guarantee_start AND (guarantee_hard_end IS NULL OR bill_end<=guarantee_hard_end)
                   AND CAST(rate_milli AS DOUBLE)/1000<CAST(guarantee_threshold AS DOUBLE)
         THEN 1 ELSE 0 END AS guarantee_applied,
    CASE WHEN rate_milli<50 THEN
           CASE WHEN tier_family='bpo' THEN 50 WHEN tier_family='english' THEN 40
                WHEN effective_guarantee_flag='0.07' AND effective_ka='是' THEN 100
                WHEN effective_guarantee_flag IN ('0.05','否') AND effective_ka='是' THEN 75 ELSE 55 END
         WHEN tier_family='bpo' THEN t.bpo_price WHEN tier_family='english' THEN t.english_price
         WHEN tier_family='ka' THEN t.ka_price WHEN tier_family='short' THEN t.short_price ELSE t.ordinary_price END AS tier_unit,
    CASE WHEN rate_milli>=50 THEN 0
         WHEN tier_family IN ('bpo','english') THEN 1
         WHEN effective_guarantee_flag='0.05' AND effective_ka IN ('是','否') THEN 0
         WHEN effective_guarantee_flag='0.07' AND effective_ka='是' THEN 0 ELSE 1 END AS reduction_applied
  FROM n15_skill_group_rates g
  LEFT JOIN n15_skill_tiers t ON g.rate_milli>=t.lo AND (g.rate_milli<t.hi OR t.hi IS NULL)
),
n15_skill_group_amounts AS (
SELECT g.*,
    CASE WHEN guarantee_applied=1 THEN guarantee_unit*child_n
         WHEN reduction_applied=1 THEN tier_unit*season_n*20
         ELSE tier_unit*child_n END AS base_pool_amount
  FROM n15_skill_group_units g
),
n15_skill_pricing_groups AS (
SELECT g.*,
    CASE WHEN price_layer='hold' THEN '原合同/政策暂挂未解除'
         WHEN price_layer='hold_new' THEN '非已批准平台；未知或新增规则保持待算'
         WHEN input_invalid=1 THEN '源映射/字段/重复/日期异常，不能完整还原计价池'
         WHEN identity_missing=1 OR party_n<>1 OR contract_n<>1 THEN '四期计价池跨合同或主体/身份缺失；不猜合同笔误'
         WHEN ka_variants<>1 OR guarantee_variants<>1 OR subsidy_variants<>1 THEN '同池政策标记不唯一，不能按任意行顺序选择'
         WHEN fixed_deduction<>0 OR excluded_commission<>0 THEN '非零月度固定扣费未获滚动分摊授权'
         WHEN pricing_subject='未知价' THEN '壹佰分支付金额未对应已定义单双科价组'
         WHEN child_n=0 THEN '无有效体验课子单；原引擎不产出费用组件'
         WHEN pricing_platform='壹佰分' AND base_pool_amount-all_period_direct<=0 THEN '壹佰分组净额不大于0，原引擎未产费用组件，继续待估'
         WHEN base_pool_amount+all_period_subsidy-all_period_direct<0 THEN '计价池总净额为负，原引擎待决，不擅自出价'
         ELSE NULL END AS group_pending_reason
  FROM n15_skill_group_amounts g
),
bs_skill_pricing_groups AS (
SELECT * FROM n15_skill_pricing_groups
),
n16_skill_target_calculated AS (
SELECT r.target_cohort,r.order_id,g.price_layer,g.group_pending_reason,
    CASE WHEN g.group_pending_reason IS NULL THEN
      CAST((CASE WHEN r.order_status='正常' THEN CAST(g.base_pool_amount AS DOUBLE)/g.child_n+g.target_unit_subsidy ELSE 0 END)
           -r.direct_deduction AS DECIMAL(38,12)) END AS calculated_amount
  FROM bs_skill_rows r JOIN bs_skill_pricing_groups g
    ON r.target_cohort=g.target_cohort AND r.pricing_platform=g.pricing_platform AND r.pricing_subject=g.pricing_subject
  WHERE r.source_cohort=r.target_cohort AND r.source_row_count=1
),
n16_skill_prices AS (
SELECT t.start_class_dt AS target_cohort,t.order_id,
    CASE WHEN x.price_layer='skill' THEN x.calculated_amount END AS skill_amount,
    CASE WHEN x.price_layer='same_policy' THEN x.calculated_amount END AS same_policy_amount,
    CASE WHEN x.order_id IS NULL THEN '历史完整四期模板未唯一返回目标订单；不借未来状态或价格'
         ELSE x.group_pending_reason END AS pending_reason
  FROM bs_target_scope t LEFT JOIN n16_skill_target_calculated x
    ON t.start_class_dt=x.target_cohort AND t.order_id=x.order_id
),
bs_skill_prices AS (
SELECT * FROM n16_skill_prices
),
n17_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n17_sku_target_snapshots AS (
SELECT target_cohort, MAX(snapshot_dt) AS snapshot_dt,
         COUNT(DISTINCT snapshot_dt) AS snapshot_variants
  FROM bs_cohort_windows GROUP BY target_cohort
),
n17_sku_targets AS (
SELECT s.order_id, s.start_class_dt AS target_cohort,
         w.snapshot_dt, w.snapshot_variants, COUNT(*) AS scope_rows
  FROM bs_target_scope s
  LEFT JOIN n17_sku_target_snapshots w ON s.start_class_dt=w.target_cohort
  GROUP BY s.order_id,s.start_class_dt,w.snapshot_dt,w.snapshot_variants
),
n17_sku_dwd AS (
SELECT t.target_cohort,t.order_id,t.snapshot_dt,COUNT(*) AS dwd_order_rows,
         MAX(CAST(a.parent_order_id AS STRING)) AS parent_order_id,
         MAX(CAST(a.user_id AS STRING)) AS native_user_id_raw,
         MAX(CAST(a.order_status AS STRING)) AS order_status,
         MAX(CAST(a.subject_id AS STRING)) AS subject_id,
         MAX(CAST(a.subject_name AS STRING)) AS subject_name,
         MAX(CAST(a.semester_type AS STRING)) AS semester_type,
         MAX(CAST(a.enrollment_id AS STRING)) AS enrollment_id,
         MAX(CAST(a.specification_id AS STRING)) AS specification_id,
         MAX(CAST(a.keyfrom AS STRING)) AS keyfrom
  FROM dw_conan_dwd.dwd_eng_order_course_detail_da a
  JOIN n17_sku_targets t ON CAST(a.order_id AS STRING)=t.order_id AND a.dt=t.snapshot_dt
  CROSS JOIN n17_params cfg
  WHERE a.dt='${date}'
  GROUP BY t.target_cohort,t.order_id,t.snapshot_dt
),
bs_sku_dwd AS (
SELECT * FROM n17_sku_dwd
),
n18_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n18_sku_target_snapshots AS (
SELECT target_cohort, MAX(snapshot_dt) AS snapshot_dt,
         COUNT(DISTINCT snapshot_dt) AS snapshot_variants
  FROM bs_cohort_windows GROUP BY target_cohort
),
n18_sku_targets AS (
SELECT s.order_id, s.start_class_dt AS target_cohort,
         w.snapshot_dt, w.snapshot_variants, COUNT(*) AS scope_rows
  FROM bs_target_scope s
  LEFT JOIN n18_sku_target_snapshots w ON s.start_class_dt=w.target_cohort
  GROUP BY s.order_id,s.start_class_dt,w.snapshot_dt,w.snapshot_variants
),
n18_sku_needed_ods AS (
SELECT order_id,snapshot_dt FROM n18_sku_targets
  UNION
  SELECT parent_order_id AS order_id,snapshot_dt FROM bs_sku_dwd
),
n18_sku_ods AS (
SELECT t.order_id,t.snapshot_dt,COUNT(*) AS ods_order_rows,
         MAX(CAST(a.enrollmentid AS STRING)) AS enrollment_id,
         MAX(CAST(a.specificationid AS STRING)) AS specification_id,
         MAX(GET_JSON_OBJECT(a.property,'$.noPost')) AS no_post
  FROM dw_conan_ods.ods_conan_trade_t_order_da a
  JOIN n18_sku_needed_ods t ON CAST(a.orderid AS STRING)=t.order_id AND a.dt=t.snapshot_dt
  CROSS JOIN n18_params cfg
  WHERE a.dt='${date}'
  GROUP BY t.order_id,t.snapshot_dt
),
bs_sku_ods AS (
SELECT * FROM n18_sku_ods
),
n19_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n19_sku_target_snapshots AS (
SELECT target_cohort, MAX(snapshot_dt) AS snapshot_dt,
         COUNT(DISTINCT snapshot_dt) AS snapshot_variants
  FROM bs_cohort_windows GROUP BY target_cohort
),
n19_sku_targets AS (
SELECT s.order_id, s.start_class_dt AS target_cohort,
         w.snapshot_dt, w.snapshot_variants, COUNT(*) AS scope_rows
  FROM bs_target_scope s
  LEFT JOIN n19_sku_target_snapshots w ON s.start_class_dt=w.target_cohort
  GROUP BY s.order_id,s.start_class_dt,w.snapshot_dt,w.snapshot_variants
),
n19_sku_order_from AS (
SELECT t.target_cohort,t.order_id,t.snapshot_dt,COUNT(*) AS order_from_rows,
         MAX(CAST(a.buy_way_tg AS STRING)) AS buy_way_tg,
         MAX(CAST(a.user_from AS STRING)) AS user_from,
         MAX(CAST(a.ad_channel AS STRING)) AS ad_channel
  FROM dw_conan_dwd.dwd_trade_try_double_order_from_info_da a
  JOIN n19_sku_targets t ON CAST(a.order_id AS STRING)=t.order_id AND a.dt=t.snapshot_dt
  CROSS JOIN n19_params cfg
  WHERE a.dt='${date}'
  GROUP BY t.target_cohort,t.order_id,t.snapshot_dt
),
n19_sku_joined AS (
SELECT t.*,d.dwd_order_rows,d.parent_order_id,d.order_status,d.subject_id,d.subject_name,d.native_user_id_raw,
         d.semester_type,d.enrollment_id,d.specification_id,d.keyfrom,
         f.order_from_rows,f.buy_way_tg,f.user_from,f.ad_channel,
         o.ods_order_rows,o.enrollment_id AS ods_enrollment_id,
         o.specification_id AS ods_specification_id,o.no_post,
         p.ods_order_rows AS parent_ods_order_rows,p.no_post AS parent_no_post,
         CASE WHEN f.buy_way_tg='联报-英语+思维' THEN '英思'
              WHEN f.buy_way_tg='非联报' THEN
                CASE d.subject_id WHEN '1' THEN '英语' WHEN '2' THEN '思维' WHEN '3' THEN '阅读' END
              WHEN f.buy_way_tg IS NOT NULL AND TRIM(f.buy_way_tg) NOT IN
                ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N')
                THEN f.buy_way_tg END AS purchase_group
  FROM n19_sku_targets t
  LEFT JOIN bs_sku_dwd d ON t.target_cohort=d.target_cohort AND t.order_id=d.order_id
  LEFT JOIN n19_sku_order_from f ON t.target_cohort=f.target_cohort AND t.order_id=f.order_id
  LEFT JOIN bs_sku_ods o ON t.order_id=o.order_id AND t.snapshot_dt=o.snapshot_dt
  LEFT JOIN bs_sku_ods p ON d.parent_order_id=p.order_id AND t.snapshot_dt=p.snapshot_dt
),
n19_sku_checked AS (
SELECT *,CONCAT_WS('；',
    CASE WHEN scope_rows<>1 OR snapshot_variants<>1 OR snapshot_dt IS NULL THEN '目标范围或快照不唯一' END,
    CASE WHEN COALESCE(dwd_order_rows,0)<>1 THEN 'dwd_order_rows不唯一或缺失' END,
    CASE WHEN COALESCE(order_from_rows,0)<>1 THEN 'order_from_rows不唯一或缺失' END,
    CASE WHEN COALESCE(ods_order_rows,0)<>1 THEN 'ods_order_rows不唯一或缺失' END,
    CASE WHEN COALESCE(parent_ods_order_rows,0)<>1 THEN 'parent_ods_order_rows不唯一或缺失' END,
    CASE WHEN enrollment_id IS NULL OR TRIM(enrollment_id) IN
      ('','0','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N') THEN 'enrollment_id缺失或占位' END,
    CASE WHEN specification_id IS NULL OR TRIM(specification_id) IN
      ('','0','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N') THEN 'specification_id缺失或占位' END,
    CASE WHEN NOT(enrollment_id <=> ods_enrollment_id) THEN 'enrollment_id的DWD/ODS不一致' END,
    CASE WHEN NOT(specification_id <=> ods_specification_id) THEN 'specification_id的DWD/ODS不一致' END,
    CASE WHEN no_post IS NULL OR no_post NOT IN ('true','false') THEN '随材标志缺失' END,
    CASE WHEN NOT(no_post <=> parent_no_post) THEN '父子随材标志不一致' END,
    CASE WHEN NOT(semester_type <=> 'try_double') THEN '非双周课或历史缺失' END,
    CASE WHEN NOT((buy_way_tg='非联报') <=> (order_id=parent_order_id)) THEN '购买组合与父子关系不一致' END,
    CASE WHEN purchase_group IS NULL THEN '购买商品未确认' END,
    CASE WHEN dwd_order_rows=1 AND (order_status IS NULL OR order_status NOT IN ('2','3')) THEN '历史订单状态未知' END,
    CASE WHEN dwd_order_rows=1 AND LOWER(keyfrom) LIKE 'yxzz-bd-%' THEN 'BD不适用本商务一组口径' END
  ) AS sku_reason
  FROM n19_sku_joined
),
n19_sku_candidates AS (
SELECT *,CASE WHEN sku_reason='' THEN
       TO_JSON(ARRAY(semester_type,buy_way_tg,enrollment_id,specification_id,no_post)) END AS candidate_sku_key
  FROM n19_sku_checked
),
bs_sku_candidates AS (
SELECT * FROM n19_sku_candidates
),
n20_sku_subject_check AS (
SELECT c.*,
       CASE WHEN c.candidate_sku_key IS NOT NULL THEN
         CAST(SIZE(COLLECT_SET(c.subject_id) OVER (
           PARTITION BY c.target_cohort,c.candidate_sku_key
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
         )) AS BIGINT)
       ELSE CAST(NULL AS BIGINT) END AS child_subject_variants
FROM bs_sku_candidates c
),
n20_sku_facts AS (
SELECT c.target_cohort,c.order_id,c.snapshot_dt,
         CASE WHEN c.dwd_order_rows=1 AND TRIM(c.native_user_id_raw) RLIKE '^[1-9][0-9]*$'
              THEN TRIM(c.native_user_id_raw) END AS native_user_id,
         c.user_from AS historical_user_from,
         CASE WHEN c.dwd_order_rows=1 AND h.order_id IS NULL THEN TRUE ELSE FALSE END AS pricing_eligible,
         CASE WHEN h.order_id IS NOT NULL THEN CONCAT('结课日历史归因为',COALESCE(h.historical_user_from,'NULL'),'/',
                   COALESCE(h.historical_ad_channel,'NULL'),'，非商务合作；全部预估来源暂挂')
              WHEN COALESCE(c.dwd_order_rows,0)<>1 THEN '目标结课日历史事实缺失或冲突' END AS pricing_ineligible_reason,
         CASE WHEN x.order_id IS NOT NULL THEN TRUE ELSE FALSE END AS settlement_hold,
         x.settlement_hold_category,
         CASE WHEN x.order_id IS NOT NULL THEN '退款去向未确认；仅分析暂挂，不确认正式不结算' END AS settlement_hold_reason,
         CASE WHEN c.child_subject_variants=1 THEN c.candidate_sku_key END AS sku_key,
         COALESCE(c.purchase_group,'历史商品缺失') AS purchase_group,
         COALESCE(c.dwd_order_rows=1,FALSE) AS historical_present,
         CASE WHEN c.dwd_order_rows=1 THEN c.order_status END AS order_status,
         c.parent_order_id,c.subject_id,c.subject_name,c.keyfrom,c.ad_channel,
         c.buy_way_tg,c.semester_type,c.enrollment_id,c.specification_id,c.no_post,
         CASE WHEN c.child_subject_variants>1 THEN CONCAT_WS('；',c.sku_reason,'同SKU跨授课学科冲突') ELSE c.sku_reason END AS sku_reason
  FROM n20_sku_subject_check c
  LEFT JOIN bs_attribution_hold_evidence h
    ON c.order_id=h.order_id AND c.target_cohort=h.target_cohort AND c.snapshot_dt=h.snapshot_dt
  LEFT JOIN bs_explicit_estimate_holds x
    ON c.order_id=x.order_id AND c.target_cohort=x.target_cohort AND c.snapshot_dt=x.snapshot_dt
),
bs_sku_facts AS (
SELECT * FROM n20_sku_facts
),
n21_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n21_mk_quality_raw AS (
SELECT w.target_cohort,w.snapshot_dt,CAST(q.start_class_dt AS STRING) AS source_cohort,
         CAST(q.order_id AS STRING) AS order_id,CAST(q.parent_order_id AS STRING) AS parent_order_id,
         CAST(q.user_id AS STRING) AS user_id,CAST(q.subject_id AS STRING) AS subject_id,
         COALESCE(CAST(q.subject_comb AS STRING),'@pipe_null@') AS subject_comb,
         CAST(q.keyfrom AS STRING) AS keyfrom,CAST(q.ad_channel AS STRING) AS ad_channel,
         CAST(q.buy_way_tg AS STRING) AS buy_way_tg,CAST(q.pay_amt AS DECIMAL(38,18)) AS pay_amt,
         CAST(q.order_status AS STRING) AS order_status,CAST(q.is_renewal AS STRING) AS is_renewal,
         CAST(q.renewal_order_id AS STRING) AS renewal_order_id,
         CAST(q.renewal_order_pay_dt AS STRING) AS renewal_order_pay_dt,
         CAST(LEAST(DATE_ADD(TO_DATE(q.start_class_dt),cfg.renewal_days),TO_DATE(w.snapshot_dt)) AS STRING) AS renewal_cutoff,
         COUNT(*) OVER(PARTITION BY w.target_cohort,CAST(q.order_id AS STRING)) AS quality_order_rows
  FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da q
  JOIN bs_cohort_windows w ON q.dt=w.snapshot_dt AND q.start_class_dt=w.source_cohort
  CROSS JOIN n21_params cfg
  WHERE q.dt='${date}'
    AND q.user_from='商务合作'
),
bs_mk_quality_raw AS (
SELECT * FROM n21_mk_quality_raw
),
n22_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n22_mk_needed_ods AS (
SELECT DISTINCT snapshot_dt,order_id FROM bs_mk_quality_raw
),
n22_mk_ods AS (
SELECT t.snapshot_dt,t.order_id,COUNT(*) AS ods_order_rows,
         MAX(GET_JSON_OBJECT(o.property,'$.noPost')) AS no_post,
         COUNT(DISTINCT GET_JSON_OBJECT(o.property,'$.noPost')) AS no_post_variants
  FROM dw_conan_ods.ods_conan_trade_t_order_da o
  JOIN n22_mk_needed_ods t ON o.dt=t.snapshot_dt AND CAST(o.orderid AS STRING)=t.order_id
  CROSS JOIN n22_params cfg
  WHERE o.dt='${date}'
  GROUP BY t.snapshot_dt,t.order_id
),
n22_mk_classified AS (
SELECT q.*,o.ods_order_rows,o.no_post_variants,COALESCE(o.no_post,'__NULL__') AS no_post,
    CASE WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-ss-cpa-bjssq%' THEN '书商'
         WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-ss-%' THEN '公转私'
         WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-sq-%' THEN '电销'
         WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-jz-%' THEN '讲座'
         WHEN LOWER(q.keyfrom)='yxzz-wx-cpa-bmsjzxxd' THEN '视频号'
         WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-sy-%' THEN '私域'
         WHEN q.ad_channel='商务私域' THEN '私域'
         WHEN LOWER(q.keyfrom) LIKE 'yxzz-sw-qt-%' THEN '营销其他'
         ELSE '其他未匹配' END AS channel_type,
    CASE WHEN q.buy_way_tg='联报-英语+思维' THEN '英思'
         WHEN q.buy_way_tg='非联报' AND
              (q.subject_comb IS NULL OR TRIM(q.subject_comb) IN ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N'))
              AND q.subject_id IN ('1','2') AND q.parent_order_id=q.order_id THEN CASE q.subject_id WHEN '1' THEN '英语' WHEN '2' THEN '思维' END
         WHEN q.buy_way_tg='非联报' AND (q.subject_comb='阅读' OR q.subject_id='3') THEN
           CASE WHEN q.subject_comb IN ('阅读','','__NULL__','@pipe_null@') THEN '阅读' ELSE '购买/服务学科冲突待核' END
         WHEN q.buy_way_tg='非联报' AND q.subject_comb IN ('英语','思维') THEN q.subject_comb
         WHEN q.buy_way_tg<>'非联报' AND q.buy_way_tg IS NOT NULL AND TRIM(q.buy_way_tg) NOT IN
           ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N') THEN q.buy_way_tg
         ELSE '其他待分类' END AS purchase_group,
    CASE WHEN q.buy_way_tg='非联报' AND
              (q.subject_comb IS NULL OR TRIM(q.subject_comb) IN ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N'))
              AND q.subject_id IN ('1','2') AND q.parent_order_id=q.order_id THEN 1 ELSE 0 END AS purchase_group_recovered,
    CASE WHEN q.is_renewal='1' AND q.renewal_order_id IS NOT NULL
               AND TRIM(q.renewal_order_id) NOT IN ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N')
               AND q.renewal_order_pay_dt IS NOT NULL
               AND TRIM(q.renewal_order_pay_dt) NOT IN ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N')
               AND q.renewal_order_pay_dt<=q.renewal_cutoff THEN q.renewal_order_id END AS valid_renewal_id,
    CASE WHEN q.user_id IS NOT NULL AND TRIM(q.user_id) NOT IN
           ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N') THEN q.user_id END AS valid_user_id,
    CASE WHEN q.parent_order_id IS NOT NULL AND TRIM(q.parent_order_id) NOT IN
           ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N') THEN q.parent_order_id END AS valid_parent_id
  FROM bs_mk_quality_raw q LEFT JOIN n22_mk_ods o ON q.snapshot_dt=o.snapshot_dt AND q.order_id=o.order_id
),
n22_marketing_input AS (
SELECT q.*,s.order_id AS native_order_id,s.historical_present AS native_historical_present,
         s.order_status AS native_order_status,s.purchase_group AS native_purchase_group,s.keyfrom AS native_keyfrom,
         TO_JSON(ARRAY(q.channel_type,q.purchase_group,CAST(q.pay_amt AS STRING),q.no_post)) AS policy_pool_key,
         s.pricing_eligible AS native_pricing_eligible,s.settlement_hold AS native_settlement_hold,
         CASE WHEN q.order_status='2'
              AND (q.source_cohort<>q.target_cohort OR s.order_id IS NULL OR
                   (s.historical_present=TRUE AND s.pricing_eligible=TRUE AND s.settlement_hold=FALSE)) AND
              (q.source_cohort<>q.target_cohort OR s.order_id IS NULL OR s.order_status='2') THEN 1 ELSE 0 END AS effective_child
  FROM n22_mk_classified q
  LEFT JOIN bs_sku_facts s ON q.source_cohort=q.target_cohort AND q.target_cohort=s.target_cohort AND q.order_id=s.order_id
),
bs_marketing_input AS (
SELECT * FROM n22_marketing_input
),
n23_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n23_mk_tiers AS (
SELECT * FROM VALUES
    (50,55,75),(55,63,83),(60,70,90),(65,80,100),(70,87,110),
    (75,93,118),(80,100,125),(85,107,135),(90,115,145),(95,122,152),
    (100,130,160),(105,140,170),(110,150,180),(115,158,188),
    (120,165,195),(125,176,206),(130,185,215)
  AS t(min_per_thousand,regular_price,ka_price)
),
n23_mk_window_check AS (
SELECT w.target_cohort,COUNT(*) AS window_rows,COUNT(DISTINCT w.source_cohort) AS source_cohorts,
         COUNT(DISTINCT w.snapshot_dt) AS snapshot_variants,
         SUM(CASE WHEN w.snapshot_dt='${date}'
                   AND w.source_cohort<=w.target_cohort THEN 0 ELSE 1 END) AS invalid_window_rows,
         MAX(cfg.rate_cohort_count) AS expected_cohorts
  FROM bs_cohort_windows w CROSS JOIN n23_params cfg GROUP BY w.target_cohort
),
n23_mk_source_check AS (
SELECT target_cohort,COUNT(*) AS source_rows,
    COUNT(DISTINCT source_cohort) AS observed_source_cohorts,
    -- Structural errors are checked BEFORE a known held target is excluded.
    SUM(CASE WHEN quality_order_rows<>1 OR COALESCE(ods_order_rows,0)<>1
                   OR no_post_variants>1 OR pay_amt IS NULL OR keyfrom IS NULL
                   OR LOWER(keyfrom) LIKE 'yxzz-bd-%'
                   OR order_status IS NULL OR order_status NOT IN ('2','3')
                   OR (buy_way_tg='非联报' AND subject_id IN ('1','2')
                       AND (subject_comb IS NULL OR TRIM(subject_comb) IN
                         ('','NULL','null','None','@pipe_null@','__NULL__','unset',CHR(92)||'N'))
                       AND NOT(parent_order_id <=> order_id)) THEN 1
             WHEN native_order_id IS NOT NULL AND
                  (native_pricing_eligible=FALSE OR native_settlement_hold=TRUE OR native_historical_present=FALSE) THEN 0
             WHEN native_order_id IS NOT NULL AND
                       (native_order_status IS NULL OR native_order_status NOT IN ('2','3')
                        OR NOT(purchase_group <=> native_purchase_group) OR NOT(keyfrom <=> native_keyfrom))
             THEN 1 ELSE 0 END) AS source_error_rows
  FROM bs_marketing_input GROUP BY target_cohort
),
n23_mk_target_guard AS (
SELECT w.target_cohort,
         CASE WHEN w.window_rows<>w.expected_cohorts OR w.source_cohorts<>w.expected_cohorts
                   OR w.snapshot_variants<>1 OR w.invalid_window_rows>0 THEN '四期窗口配置异常'
              WHEN COALESCE(s.source_rows,0)=0 THEN '历史营销统计池为空'
              WHEN s.observed_source_cohorts<>w.expected_cohorts THEN '实际营销源未覆盖全部四期，不允许不完整续报池计价'
              WHEN s.source_error_rows>0 THEN '营销源重复/映射/商品事实异常；不得删异常行后继续定阶梯'
              ELSE '' END AS source_gate_reason
  FROM n23_mk_window_check w LEFT JOIN n23_mk_source_check s ON w.target_cohort=s.target_cohort
),
n23_mk_effective_rows AS (
SELECT * FROM bs_marketing_input WHERE quality_order_rows=1 AND effective_child=1
),
n23_mk_pool_counts AS (
SELECT target_cohort,policy_pool_key,MAX(channel_type) AS channel_type,
         MAX(purchase_group) AS purchase_group,MAX(pay_amt) AS pay_amt,MAX(no_post) AS no_post,
         COUNT(DISTINCT order_id) AS child_count,COUNT(DISTINCT valid_renewal_id) AS renewal_count,
         COUNT(DISTINCT valid_parent_id) AS parent_count,COUNT(DISTINCT valid_user_id) AS user_count,
         SUM(CASE WHEN valid_user_id IS NULL THEN 1 ELSE 0 END) AS missing_user_rows,
         SUM(CASE WHEN valid_parent_id IS NULL THEN 1 ELSE 0 END) AS missing_parent_rows
  FROM n23_mk_effective_rows GROUP BY target_cohort,policy_pool_key
),
n23_mk_pool_tiers AS (
SELECT p.*,t.min_per_thousand,t.regular_price,t.ka_price
  FROM n23_mk_pool_counts p LEFT JOIN n23_mk_tiers t
    ON p.renewal_count*1000>=p.child_count*t.min_per_thousand
   AND (t.min_per_thousand=130 OR p.renewal_count*1000<p.child_count*(t.min_per_thousand+5))
),
n23_mk_pool_decisions AS (
SELECT *,
    CASE WHEN purchase_group NOT IN ('英语','英思','思维') THEN NULL
         WHEN channel_type='书商' AND missing_user_rows=0 THEN 'USER120'
         WHEN channel_type='讲座' THEN 'CHILD80'
         WHEN channel_type='电销' AND renewal_count*1000<child_count*65 THEN 'CHILD100'
         WHEN channel_type='电销' AND ka_price IS NOT NULL THEN 'KA'
         WHEN channel_type IN ('私域','营销其他') AND renewal_count*20<child_count THEN 'REGULAR_PROPORTIONAL'
         WHEN channel_type IN ('私域','营销其他') AND regular_price IS NOT NULL THEN 'REGULAR'
         WHEN channel_type='视频号' AND ka_price IS NOT NULL THEN 'KA'
         WHEN channel_type='公转私' AND missing_user_rows=0 AND missing_parent_rows=0
              AND renewal_count*10<parent_count THEN 'USER120'
         WHEN channel_type='公转私' AND missing_user_rows=0 AND missing_parent_rows=0
              AND renewal_count*10>parent_count AND regular_price IS NOT NULL THEN 'REGULAR'
         END AS price_mode,
    CASE WHEN purchase_group NOT IN ('英语','英思','思维') THEN '特殊购买/学科标签未纳入既有放宽政策'
         WHEN channel_type='书商' AND missing_user_rows>0 THEN '书商用户ID缺失'
         WHEN channel_type='公转私' AND (missing_user_rows>0 OR missing_parent_rows>0) THEN '公转私父单或用户ID缺失'
         WHEN channel_type='公转私' AND renewal_count*10=parent_count THEN '公转私父单转化率恰10%，边界未确认'
         WHEN channel_type='公转私' AND renewal_count*10>parent_count AND regular_price IS NULL THEN '公转私父单>10%但子单<5%，不增核减兜底'
         WHEN channel_type='视频号' AND ka_price IS NULL THEN '视频号子单转化率<5%，未采用KA核减公式'
         WHEN channel_type NOT IN ('书商','讲座','电销','私域','营销其他','公转私','视频号') THEN '渠道类型未识别'
         END AS policy_pending_reason
  FROM n23_mk_pool_tiers
),
n23_mk_target_user_counts AS (
-- Only the target cohort: never divide USER120 by a four-cohort user's children.
  SELECT target_cohort,policy_pool_key,valid_user_id,COUNT(DISTINCT order_id) AS target_user_child_count
  FROM n23_mk_effective_rows WHERE source_cohort=target_cohort
  GROUP BY target_cohort,policy_pool_key,valid_user_id
),
n23_mk_target_leaves AS (
SELECT r.*,p.child_count,p.renewal_count,p.parent_count,p.user_count,p.price_mode,
         p.regular_price,p.ka_price,p.policy_pending_reason,u.target_user_child_count,
         CASE p.price_mode WHEN 'USER120' THEN CAST(120 AS BIGINT)
              WHEN 'CHILD80' THEN CAST(80 AS BIGINT) WHEN 'CHILD100' THEN CAST(100 AS BIGINT)
              WHEN 'REGULAR' THEN CAST(p.regular_price AS BIGINT) WHEN 'KA' THEN CAST(p.ka_price AS BIGINT)
              WHEN 'REGULAR_PROPORTIONAL' THEN CAST(1100*p.renewal_count AS BIGINT) END AS amount_num,
         CASE p.price_mode WHEN 'USER120' THEN u.target_user_child_count
              WHEN 'REGULAR_PROPORTIONAL' THEN p.child_count
              WHEN 'CHILD80' THEN CAST(1 AS BIGINT) WHEN 'CHILD100' THEN CAST(1 AS BIGINT)
              WHEN 'REGULAR' THEN CAST(1 AS BIGINT) WHEN 'KA' THEN CAST(1 AS BIGINT) END AS amount_den
  FROM bs_marketing_input r
  LEFT JOIN n23_mk_pool_decisions p ON r.target_cohort=p.target_cohort AND r.policy_pool_key=p.policy_pool_key
  LEFT JOIN n23_mk_target_user_counts u ON r.target_cohort=u.target_cohort AND r.policy_pool_key=u.policy_pool_key
                                  AND r.valid_user_id=u.valid_user_id
  WHERE r.source_cohort=r.target_cohort AND r.quality_order_rows=1
),
n23_mk_output_precheck AS (
SELECT s.target_cohort,s.order_id,s.snapshot_dt,s.purchase_group,s.order_status,
         l.channel_type,l.policy_pool_key,l.child_count,l.renewal_count,l.parent_count,l.user_count,
         l.price_mode,l.amount_num,l.amount_den,l.target_user_child_count,
         CASE WHEN NOT s.historical_present THEN '目标历史订单事实缺失'
              WHEN NOT s.pricing_eligible THEN s.pricing_ineligible_reason
              WHEN s.settlement_hold THEN s.settlement_hold_reason
              WHEN s.order_status='3' THEN '退款获客费用未确认，保留NULL不当作0'
              WHEN s.order_status IS NULL OR s.order_status<>'2' THEN '历史订单状态未知'
              WHEN g.source_gate_reason IS NULL OR g.source_gate_reason<>'' THEN COALESCE(g.source_gate_reason,'窗口/营销来源缺失')
              WHEN l.order_id IS NULL THEN '目标订单没有唯一营销质量表记录'
              WHEN l.order_status<>'2' OR l.effective_child<>1 THEN '非正常体验订单不计入营销有效统计池'
              WHEN l.policy_pending_reason IS NOT NULL THEN l.policy_pending_reason
              WHEN l.amount_num IS NULL OR l.amount_den IS NULL OR l.amount_den<=0 THEN '没有可用营销计价分支'
              END AS pending_reason
  FROM bs_sku_facts s
  LEFT JOIN n23_mk_target_leaves l ON s.target_cohort=l.target_cohort AND s.order_id=l.order_id
  LEFT JOIN n23_mk_target_guard g ON s.target_cohort=g.target_cohort
),
n23_marketing_prices AS (
SELECT target_cohort,order_id,
         CASE WHEN pending_reason IS NULL THEN
           CAST(CAST(amount_num AS DECIMAL(28,12))/CAST(amount_den AS DECIMAL(10,0)) AS DECIMAL(28,12)) END AS amount,
         pending_reason,channel_type,purchase_group,policy_pool_key,child_count,renewal_count,parent_count,user_count,
         price_mode,target_user_child_count,
         CASE WHEN pending_reason IS NULL THEN amount_num END AS amount_num,
         CASE WHEN pending_reason IS NULL THEN amount_den END AS amount_den,
         '冻结营销渠道放宽暂估；普通<5%核减为既有假设，公转私父单10%判支；无新增补贴或固定扣款' AS price_basis
  FROM n23_mk_output_precheck
),
bs_marketing_prices AS (
SELECT * FROM n23_marketing_prices
),
n24_estimate_candidates AS (
SELECT t.start_class_dt,t.order_id,s.sku_key,s.historical_present,s.order_status,
           c.ready,s.pricing_eligible,s.pricing_ineligible_reason,s.settlement_hold,
           s.settlement_hold_reason,s.settlement_hold_category,
           CASE WHEN s.historical_present AND s.pricing_eligible AND NOT s.settlement_hold AND c.ready=1 THEN
                COALESCE(k.skill_amount,k.same_policy_amount,
                         CASE WHEN s.order_status<>'3' THEN m.amount END)
                END AS base_cost,
           CASE WHEN NOT COALESCE(s.historical_present,FALSE) THEN '结课日历史事实缺失或冲突'
                WHEN NOT s.pricing_eligible OR s.settlement_hold THEN '待估'
                WHEN COALESCE(c.ready,0)<>1 THEN '未结课或历史四期数据不完整'
                WHEN k.skill_amount IS NOT NULL THEN 'skill测算'
                WHEN k.same_policy_amount IS NOT NULL THEN '同政策情景暂估'
                WHEN s.order_status<>'3' AND m.amount IS NOT NULL THEN '石墨政策暂估'
                ELSE '待估' END AS base_source,
           CASE WHEN NOT s.pricing_eligible THEN s.pricing_ineligible_reason
                WHEN s.settlement_hold THEN s.settlement_hold_reason
                ELSE COALESCE(k.pending_reason,m.pending_reason) END AS pending_reason
    FROM bs_target_scope t
    LEFT JOIN bs_sku_facts s ON t.order_id=s.order_id AND t.start_class_dt=s.target_cohort
    LEFT JOIN bs_skill_prices k ON t.order_id=k.order_id AND t.start_class_dt=k.target_cohort
    LEFT JOIN bs_marketing_prices m ON t.order_id=m.order_id AND t.start_class_dt=m.target_cohort
    LEFT JOIN bs_cohort_readiness c ON t.start_class_dt=c.target_cohort
),
bs_estimate_candidates AS (
SELECT * FROM n24_estimate_candidates
),
n25_params AS (
SELECT GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AS start_dt, CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS end_dt,
       '${date}' AS as_of_dt, 29 AS renewal_days,
       4 AS rate_cohort_count, 3 AS mean_threshold_pct
),
n25_cohort_window AS (
SELECT e.*,
           COUNT(*) OVER (
               PARTITION BY start_class_dt
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS total_orders,
           SUM(CASE WHEN base_cost IS NULL THEN 1 ELSE 0 END) OVER (
               PARTITION BY start_class_dt
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS missing_before_mean
    FROM bs_estimate_candidates e
),
n25_sku_window AS (
SELECT e.*,
           COUNT(CASE WHEN base_cost IS NOT NULL AND sku_key IS NOT NULL AND sku_key<>''
                      THEN 1 END) OVER (
               PARTITION BY start_class_dt,sku_key
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS donor_orders_raw,
           -- Same AVG input type as the original grouped aggregate.
           -- Do not use DOUBLE, SUM/COUNT, ROUND, or a narrower intermediate cast.
           AVG(CASE WHEN base_cost IS NOT NULL AND sku_key IS NOT NULL AND sku_key<>''
                    THEN CAST(base_cost AS DECIMAL(28,12)) END) OVER (
               PARTITION BY start_class_dt,sku_key
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS donor_mean,
           MIN(CASE WHEN base_cost IS NOT NULL AND sku_key IS NOT NULL AND sku_key<>''
                    THEN CASE WHEN base_source IN ('skill测算','同政策情景暂估') THEN 1 ELSE 0 END
               END) OVER (
               PARTITION BY start_class_dt,sku_key
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS donor_tax_inclusive
    FROM n25_cohort_window e
),
n25_sku_window_nulls AS (
SELECT e.*,
           -- No qualifying donor group previously meant a missing LEFT JOIN row,
           -- so the public donor_orders value must be NULL, not numeric zero.
           CASE WHEN donor_orders_raw>0 THEN donor_orders_raw
                ELSE CAST(NULL AS BIGINT) END AS donor_orders
    FROM n25_sku_window e
),
n25_estimated_costs AS (
-- Explicit original e.* list: do not leak any new window helper columns.
    SELECT e.start_class_dt,e.order_id,e.sku_key,e.historical_present,e.order_status,
           e.ready,e.base_cost,e.base_source,e.pending_reason,e.pricing_eligible,e.pricing_ineligible_reason,
           e.settlement_hold,e.settlement_hold_reason,e.settlement_hold_category,
           CASE WHEN e.base_cost IS NOT NULL THEN CAST(e.base_cost AS DECIMAL(28,12))
                WHEN e.historical_present AND e.pricing_eligible AND NOT e.settlement_hold AND e.ready=1
                     AND e.donor_orders>0 THEN CAST(e.donor_mean AS DECIMAL(28,12))
                END AS estimated_settlement_cost,
           CASE WHEN e.base_cost IS NOT NULL THEN e.base_source
                WHEN e.historical_present AND e.pricing_eligible AND NOT e.settlement_hold AND e.ready=1
                     AND e.donor_orders>0 THEN '同期开课同SKU均值补估'
                ELSE '待估' END AS cost_source,
           e.missing_before_mean,e.total_orders,e.donor_orders,
           CASE WHEN e.base_cost IS NOT NULL
                THEN CASE WHEN e.base_source IN ('skill测算','同政策情景暂估') THEN 1 ELSE 0 END
                ELSE COALESCE(e.donor_tax_inclusive,0)
                END AS estimate_tax_inclusive
    FROM n25_sku_window_nulls e CROSS JOIN n25_params p
    -- The original inner join e.start_class_dt=g.start_class_dt discarded NULL
    -- dates (ordinary equality, not null-safe equality). Retain that behavior.
    WHERE e.start_class_dt IS NOT NULL
),
bs_estimated_costs AS (
SELECT * FROM n25_estimated_costs
),
bs_frozen_policy_tax AS (
SELECT * FROM VALUES
(2,'静魅','yxzz-sw-sq-cpa-jingmei',CAST(0.01 AS DECIMAL(10,6))),
(3,'学研星途','yxzz-sw-sq-cpa-xyxt',CAST(0.01 AS DECIMAL(10,6))),
(4,'学研星途','yxzz-sw-sy-cpa-xyxt',CAST(0.01 AS DECIMAL(10,6))),
(6,'时光学','yxzz-sw-sq-cpa-shiguangxue',CAST(NULL AS DECIMAL(10,6))),
(12,'佳效','yxzz-sw-sq-cpa-jiaxiao',CAST(NULL AS DECIMAL(10,6))),
(13,'新动力','yxzz-sw-sq-cpa-xdl',CAST(NULL AS DECIMAL(10,6))),
(14,'优优','yxzz-sw-sq-cpa-youyou',CAST(NULL AS DECIMAL(10,6))),
(15,'阳明（学为先）','yxzz-sw-sq-cpa-xueweixian',CAST(NULL AS DECIMAL(10,6))),
(16,'阳明（学为先）','yxzz-sw-sq-cpa-ncym',CAST(NULL AS DECIMAL(10,6))),
(17,'擎拓','yxzz-sw-sq-cpa-qingtuo',CAST(NULL AS DECIMAL(10,6))),
(19,'精厚','yxzz-sw-sq-cpa-jinghou',CAST(NULL AS DECIMAL(10,6))),
(20,'中轶','yxzz-sw-sq-cpa-zhongyixx',CAST(NULL AS DECIMAL(10,6))),
(22,'网聚天下社群','yxzz-sw-sq-cpa-syabl',CAST(0.06 AS DECIMAL(10,6))),
(23,'网聚天下bpo','yxzz-sw-tmk-cpa-bpowjtx',CAST(0.06 AS DECIMAL(10,6))),
(24,'酬勤信息','yxzz-sw-dt-cpa-cqxx',CAST(0.06 AS DECIMAL(10,6))),
(25,'酬勤信息','yxzz-sw-sq-cpa-cqxx',CAST(0.06 AS DECIMAL(10,6))),
(40,'元慷文化','yxzz-sw-sq-cpa-yuankang',CAST(0.01 AS DECIMAL(10,6))),
(41,'元慷文化','yxzz-sw-sq-cpa-yuankangwh',CAST(0.01 AS DECIMAL(10,6))),
(42,'元慷文化','yxzz-sw-qt-cpa-ykwh',CAST(0.01 AS DECIMAL(10,6))),
(43,'元慷文化','yxzz-sw-sy-cpa-ykwh',CAST(0.01 AS DECIMAL(10,6))),
(44,'奇趣','yxzz-sw-ss-cpa-qiqu',CAST(0.01 AS DECIMAL(10,6))),
(45,'新服','yxzz-sw-sq-cpa-xinfu',CAST(NULL AS DECIMAL(10,6))),
(46,'褚岩（吾醒）','yxzz-sw-sq-cpa-wuxing',CAST(NULL AS DECIMAL(10,6))),
(47,'幸树','yxzz-sw-sq-cpa-xingshu',CAST(NULL AS DECIMAL(10,6))),
(48,'路迦','yxzz-sw-sq-cpa-lujia',CAST(NULL AS DECIMAL(10,6))),
(49,'保定佳学','yxzz-sw-sq-cpa-bdjiaxue',CAST(NULL AS DECIMAL(10,6))),
(50,'碟塔','yxzz-sw-sq-cpa-dieta',CAST(NULL AS DECIMAL(10,6))),
(51,'盛和文（茂密文化）','yxzz-sw-sq-cpa-shmiwen',CAST(NULL AS DECIMAL(10,6))),
(52,'茂密文化','yxzz-sw-sq-cpa-mw',CAST(NULL AS DECIMAL(10,6))),
(53,'云梯','yxzz-sw-sq-cpa-yunti',CAST(0.06 AS DECIMAL(10,6))),
(54,'有大志','yxzz-sw-sq-cpa-youdazhi',CAST(NULL AS DECIMAL(10,6))),
(55,'铭栎（臻好）','yxzz-sw-sq-cpa-nbzhenhao',CAST(0.06 AS DECIMAL(10,6))),
(56,'够玩','yxzz-sw-sy-cpa-gzgouwan',CAST(0.06 AS DECIMAL(10,6))),
(57,'够玩','yxzz-sw-sq-cpa-gzgouwan',CAST(0.06 AS DECIMAL(10,6))),
(58,'神州鹰','yxzz-sw-sq-cpa-shenzhouying',CAST(NULL AS DECIMAL(10,6))),
(59,'脉点','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(60,'中云','yxzz-sw-sq-cpa-zhongyun',CAST(NULL AS DECIMAL(10,6))),
(61,'三云','yxzz-sw-sq-cpa-sanyun',CAST(NULL AS DECIMAL(10,6))),
(62,'雅艺','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(63,'怡彩','yxzz-sw-sq-cpa-yicai',CAST(NULL AS DECIMAL(10,6))),
(64,'千亿教育','yxzz-sw-sq-cpa-qyjy',CAST(0.06 AS DECIMAL(10,6))),
(65,'千亿教育','yxzz-sw-sy-cpa-qyjy',CAST(0.06 AS DECIMAL(10,6))),
(66,'涵科','yxzz-sw-sq-cpa-hanke',CAST(NULL AS DECIMAL(10,6))),
(67,'嘉宝','yxzz-sw-sq-cpa-szjiabao',CAST(NULL AS DECIMAL(10,6))),
(68,'乐知（凌泽）','yxzz-sw-sq-cpa-lingze',CAST(0.01 AS DECIMAL(10,6))),
(69,'臻好（铭栎）','yxzz-sw-sq-cpa-mingli',CAST(0.06 AS DECIMAL(10,6))),
(70,'书纽','yxzz-sw-ss-cpa-shuniu',CAST(NULL AS DECIMAL(10,6))),
(71,'书纽','yxzz-sw-sq-cpa-shuniu',CAST(NULL AS DECIMAL(10,6))),
(72,'时科','yxzz-sw-sq-cpa-shike',CAST(NULL AS DECIMAL(10,6))),
(73,'铭祺','yxzz-sw-sy-cpa-mingqi',CAST(0.01 AS DECIMAL(10,6))),
(74,'铭祺','yxzz-sw-sq-cpa-mingqi',CAST(0.01 AS DECIMAL(10,6))),
(75,'满天星（代播）','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(76,'满天星（代播）','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(77,'乐学科技','yxzz-sw-sq-cpa-lexuekj',CAST(0.01 AS DECIMAL(10,6))),
(78,'蓝智（怡乐）','yxzz-sw-sy-cpa-yile',CAST(0.06 AS DECIMAL(10,6))),
(79,'蓝智（怡乐）','yxzz-sw-sq-cpa-yile',CAST(0.06 AS DECIMAL(10,6))),
(80,'蓝智','yxzz-sw-sy-cpa-lanzhi1',CAST(0.06 AS DECIMAL(10,6))),
(81,'满天星（代播）','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(83,'博学（谦受益）','yxzz-sw-sq-cpa-qsy',CAST(0.01 AS DECIMAL(10,6))),
(84,'满天星（代播）','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(85,'黑木','yxzz-sw-sq-cpa-heimu',CAST(NULL AS DECIMAL(10,6))),
(86,'茂密','yxzz-sw-sq-cpa-maomi',CAST(NULL AS DECIMAL(10,6))),
(87,'启睿','yxzz-sw-sy-cpa-qirui',CAST(0.01 AS DECIMAL(10,6))),
(88,'启睿','yxzz-sw-sq-cpa-qirui',CAST(0.01 AS DECIMAL(10,6))),
(89,'湖州云梯','yxzz-sw-sq-cpa-hzyt',CAST(0.06 AS DECIMAL(10,6))),
(90,'湖州云梯','yxzz-sw-ss-cpa-hzyt',CAST(0.06 AS DECIMAL(10,6))),
(93,'优考','yxzz-sw-sq-cpa-youkao',CAST(0.01 AS DECIMAL(10,6))),
(94,'童趣','yxzz-sw-sq-cpa-dyfx',CAST(0.01 AS DECIMAL(10,6))),
(95,'禧泽（长台）','yxzz-sw-jz-cpa-xize',CAST(0.01 AS DECIMAL(10,6))),
(96,'禧泽（长台）','yxzz-sw-sq-cpa-xize',CAST(0.01 AS DECIMAL(10,6))),
(97,'逗爸','yxzz-sw-sq-cpa-sphfx',CAST(0.01 AS DECIMAL(10,6))),
(98,'百杰胜','yxzz-sw-ss-cpa-bjssq',CAST(0.01 AS DECIMAL(10,6))),
(99,'京渝永建双科','yxzz-sw-sq-cpa-jyyj',CAST(0.01 AS DECIMAL(10,6))),
(100,'北极鸥','yxzz-sw-sy-cpa-bjojy',CAST(0.01 AS DECIMAL(10,6))),
(101,'全商','yxzz-sw-sy-cpa-quanshang',CAST(0.01 AS DECIMAL(10,6))),
(102,'全商','yxzz-sw-sq-cpa-quanshang',CAST(0.01 AS DECIMAL(10,6))),
(103,'满天星（代播）','yxzz-sw-sq-cpa-dyfx',CAST(NULL AS DECIMAL(10,6))),
(104,'海裕','yxzz-sw-sy-cpa-haiyu',CAST(0.01 AS DECIMAL(10,6))),
(105,'海裕','yxzz-sw-sq-cpa-haiyu',CAST(0.01 AS DECIMAL(10,6))),
(106,'坚壳','yxzz-sw-sq-cpa-jianke',CAST(0.06 AS DECIMAL(10,6))),
(107,'精灵','yxzz-sw-sy-cpa-htjl',CAST(0.01 AS DECIMAL(10,6))),
(108,'精灵','yxzz-sw-sq-cpa-htjl',CAST(0.01 AS DECIMAL(10,6))),
(109,'哪吒','yxzz-sw-sy-cpa-nezha',CAST(0.06 AS DECIMAL(10,6))),
(110,'哪吒','yxzz-sw-ss-cpa-nezha19',CAST(0.06 AS DECIMAL(10,6))),
(111,'哪吒','yxzz-sw-ss-cpa-nezha',CAST(0.06 AS DECIMAL(10,6))),
(112,'仁轩','yxzz-sw-sq-cpa-renxuan',CAST(0.01 AS DECIMAL(10,6))),
(113,'仁轩','yxzz-sw-sy-cpa-renxuan',CAST(0.01 AS DECIMAL(10,6))),
(114,'稻果','yxzz-sw-jz-cpa-daoguowh',CAST(0.01 AS DECIMAL(10,6))),
(115,'燃势网络','yxzz-dy-cpa-bmzx',CAST(0.06 AS DECIMAL(10,6))),
(116,'潇沐','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(117,'诚学','yxzz-sw-sy-cpa-chengxue',CAST(0.01 AS DECIMAL(10,6))),
(118,'玉琴','yxzz-mr-sy-cpa-yuqin',CAST(0.01 AS DECIMAL(10,6))),
(119,'星耀学1','yxzz-mr-sy-cpa-xingyaoxue',CAST(0.01 AS DECIMAL(10,6))),
(120,'长台','yxzz-sw-jz-cpa-changtai',CAST(0.01 AS DECIMAL(10,6))),
(121,'昆紫','yxzz-sw-sy-cpa-kunzi',CAST(0.06 AS DECIMAL(10,6))),
(122,'胖虎','yxzz-sw-ss-cpa-panghu',CAST(0.01 AS DECIMAL(10,6))),
(123,'破晓','yxzz-sw-ss-cpa-poxiao',CAST(0.01 AS DECIMAL(10,6))),
(124,'悦冠','yxzz-sw-ss-cpa-yueguan',CAST(0.06 AS DECIMAL(10,6))),
(125,'巨航','yxzz-sw-ss-cpa-juhang',CAST(0.01 AS DECIMAL(10,6))),
(126,'乐学1','yxzz-sw-sy-cpa-lexu',CAST(0.01 AS DECIMAL(10,6))),
(127,'文荀','yxzz-sw-sy-cpa-wenxun',CAST(0.01 AS DECIMAL(10,6))),
(128,'元昔','yxzz-sw-sy-cpa-yuanxi',CAST(0.01 AS DECIMAL(10,6))),
(130,'乐都','yxzz-sw-sy-cpa-ledou',CAST(0.01 AS DECIMAL(10,6))),
(131,'雅艺','yxzz-sw-sy-cpa-yayi',CAST(0.06 AS DECIMAL(10,6))),
(132,'目标','yxzz-sw-jz-cpa-mubiao',CAST(0.01 AS DECIMAL(10,6))),
(133,'馨松','yxzz-sw-sy-cpa-xinsong1',CAST(0.06 AS DECIMAL(10,6))),
(134,'八斗','yxzz-sw-jz-cpa-badou',CAST(0.03 AS DECIMAL(10,6))),
(135,'静魅','yxzz-sw-jz-cpa-jingmeiqz',CAST(0.01 AS DECIMAL(10,6))),
(136,'清之意','yxzz-sw-qt-cpa-qzy',CAST(0.01 AS DECIMAL(10,6))),
(137,'文化','yxzz-sw-sy-cpa-wenhua',CAST(0.01 AS DECIMAL(10,6))),
(138,'盈推','yxzz-sw-sy-cpa-yingwei',CAST(0.01 AS DECIMAL(10,6))),
(139,'云电','yxzz-sw-sy-cpa-yundian',CAST(0.01 AS DECIMAL(10,6))),
(140,'优投','yxzz-sw-sq-cpa-youtou',CAST(0.01 AS DECIMAL(10,6))),
(141,'春夏','yxzz-wx-cpa-bmsjzxxd',CAST(0.01 AS DECIMAL(10,6))),
(142,'春夏','yxzz-wx-cpa-bmsjzxxd',CAST(0.01 AS DECIMAL(10,6))),
(143,'春夏','yxzz-wx-cpa-bmsjzxxd',CAST(0.01 AS DECIMAL(10,6))),
(144,'春夏','yxzz-wx-cpa-bmsjzxxd',CAST(0.01 AS DECIMAL(10,6))),
(145,'春夏','yxzz-wx-cpa-bmsjzxxd',CAST(0.01 AS DECIMAL(10,6))),
(146,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(147,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(148,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(149,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(150,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(151,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(152,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(153,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(154,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(155,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(156,'春夏','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(157,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(158,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(159,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(160,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(161,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(162,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(163,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(164,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(165,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(166,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(167,'春夏','yxzz-dy-bmtsypd',CAST(0.01 AS DECIMAL(10,6))),
(168,'亿起发','yxzz-sw-ss-cpa-yiqifa',CAST(0.01 AS DECIMAL(10,6))),
(169,'微尚','yxzz-sw-ss-cpa-weishang',CAST(0.01 AS DECIMAL(10,6))),
(170,'壹佰分','yxzz-sw-ss-cpa-yibaifen',CAST(0.03 AS DECIMAL(10,6))),
(171,'壹佰分','yxzz-sw-sy-cpa-beijixing',CAST(0.03 AS DECIMAL(10,6))),
(172,'壹佰分','yxzz-sw-ss-cpa-yibaifenyy',CAST(0.03 AS DECIMAL(10,6))),
(173,'晨曦','yxzz-sw-ss-cpa-chenxi',CAST(0.03 AS DECIMAL(10,6))),
(174,'温老师','yxzz-sw-ss-cpa-wenlaoshi',CAST(0.01 AS DECIMAL(10,6))),
(175,'小瓶盖','yxzz-sw-ss-cpa-xiaopinggai',CAST(0.03 AS DECIMAL(10,6))),
(176,'绿韵','yxzz-sw-ss-cpa-lvyun',CAST(0.01 AS DECIMAL(10,6))),
(177,'酷游','yxzz-sw-ss-cpa-kuyou',CAST(0.01 AS DECIMAL(10,6))),
(178,'云岛','yxzz-sw-sy-cpa-yundao',CAST(0.01 AS DECIMAL(10,6))),
(179,'雅览','yxzz-sw-ss-cpa-yalan',CAST(0.01 AS DECIMAL(10,6))),
(180,'廷嘉','yxzz-bd-jx-cpa-tingjia',CAST(0.03 AS DECIMAL(10,6))),
(181,'优思睿','yxzz-bd-jx-cpa-yousirui',CAST(0.01 AS DECIMAL(10,6))),
(182,'尔瑞','yxzz-bd-jx-cpa-errui',CAST(0.01 AS DECIMAL(10,6))),
(183,'墨点','yxzz-bd-jx-cpa-modian',CAST(0.06 AS DECIMAL(10,6))),
(184,'德才','yxzz-bd-jx-cpa-decai',CAST(0.01 AS DECIMAL(10,6))),
(185,'开朗文化阅读','yxzz-sw-sq-cpa-klwh',CAST(0.01 AS DECIMAL(10,6))),
(186,'童画','yxzz-sw-jz-cpa-tonghua',CAST(0.01 AS DECIMAL(10,6))),
(187,'馨松','yxzz-wx-cpa-bmsjzxxd',CAST(0.06 AS DECIMAL(10,6))),
(188,'馨松','yxzz-wx-cpa-bmsjzxxd',CAST(0.06 AS DECIMAL(10,6))),
(189,'馨松','yxzz-wx-cpa-bmsjzxxd',CAST(0.06 AS DECIMAL(10,6))),
(190,'廷嘉','yxzz-sw-jz-cpa-tingjia',CAST(0.03 AS DECIMAL(10,6))),
(191,'优思睿','yxzz-sw-jz-cpa-yousirui',CAST(0.01 AS DECIMAL(10,6))),
(192,'尔瑞','yxzz-sw-jz-cpa-errui',CAST(0.01 AS DECIMAL(10,6))),
(193,'墨点','yxzz-sw-jz-cpa-modian',CAST(0.06 AS DECIMAL(10,6))),
(194,'德才','yxzz-sw-jz-cpa-decai',CAST(0.01 AS DECIMAL(10,6))),
(195,'长台1','yxzz-sw-jz-cpa-changtaixx',CAST(0.01 AS DECIMAL(10,6))),
(196,'无忧','yxzz-sw-jz-cpa-wuyou',CAST(0.01 AS DECIMAL(10,6))),
(197,'萌宝1','yxzz-sw-sy-cpa-mengbao1',CAST(0.01 AS DECIMAL(10,6))),
(205,'晢珩电子','yxzz-sw-sy-cpa-zhdz002',CAST(0.01 AS DECIMAL(10,6))),
(206,'晢珩电子','yxzz-sw-sy-cpa-zhdz',CAST(0.01 AS DECIMAL(10,6))),
(207,'网聚天下社群','yxzz-jd-kecheng-sw',CAST(0.06 AS DECIMAL(10,6))),
(208,'胖虎','yxzz-sw-ss-cpa-panghuyy',CAST(0.01 AS DECIMAL(10,6))),
(209,'佳慕','yxzz-sw-ss-cpa-jiamuyy',CAST(0.03 AS DECIMAL(10,6))),
(210,'诚甲','yxzz-sw-jz-cpa-chengjia',CAST(0.01 AS DECIMAL(10,6))),
(211,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(212,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(213,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(214,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(215,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(216,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(217,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(218,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(219,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(220,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(221,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(222,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(223,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(224,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(225,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(226,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(227,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(228,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(229,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(230,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(231,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(232,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(233,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(234,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6))),
(235,'精微特文化','yxzz-dy-cpa-bmzx',CAST(0.01 AS DECIMAL(10,6)))
AS p(source_row,platform_name,policy_keyfrom,tax_rate)
),
bs_bill_params AS (
-- Bind this one-row SELECT as bs_bill_params. Change only this date for a new snapshot.
SELECT '${date}' AS as_of_dt
),
bs_bill_selected AS (
-- Input: bs_target_scope(order_id, start_class_dt), bs_bill_params(as_of_dt).
-- Bind output as bs_bill_selected. This selects bill IDs, never the allocation denominator.
SELECT DISTINCT CAST(l.billid AS STRING) AS bill_id
FROM dw_conan_ods.ods_conan_terra_marketing_bill_lesson_order_da l
JOIN bs_target_scope s ON CAST(l.orderid AS STRING)=CAST(s.order_id AS STRING)
  AND TO_DATE(l.classstarttime)=TO_DATE(s.start_class_dt)
CROSS JOIN bs_bill_params p
WHERE l.dt=p.as_of_dt AND l.paymentmodel='CPA' AND l.semestertype='try_double'
  AND l.billid IS NOT NULL
  AND LOWER(TRIM(CAST(l.billid AS STRING))) NOT IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n'))
),
bs_bill_lessons AS (
-- Bind output as bs_bill_lessons. All rows of every selected bill are retained.
-- Do not DISTINCT, filter target dates, or filter refunds before these duplicate checks.
SELECT TRIM(CAST(l.id AS STRING)) AS lesson_id, CAST(l.billid AS STRING) AS bill_id,
       TRIM(CAST(l.orderid AS STRING)) AS order_id, CAST(l.orderstatus AS STRING) AS order_status,
       CAST(l.paymentmodel AS STRING) AS payment_model, CAST(l.semestertype AS STRING) AS semester_type,
       TRIM(CAST(l.keyfrom AS STRING)) AS keyfrom, TO_DATE(l.classstarttime) AS start_class_dt,
       COUNT(*) OVER(PARTITION BY TRIM(CAST(l.id AS STRING))) AS lesson_id_rows,
       COUNT(*) OVER(PARTITION BY l.billid,TRIM(CAST(l.orderid AS STRING))) AS bill_order_rows
FROM dw_conan_ods.ods_conan_terra_marketing_bill_lesson_order_da l
JOIN bs_bill_selected s ON CAST(l.billid AS STRING)=s.bill_id
CROSS JOIN bs_bill_params p
WHERE l.dt=p.as_of_dt
),
n30_header_stats AS (
SELECT s.bill_id,COUNT(b.id) AS header_rows,
         MAX(CAST(b.totalamount AS DECIMAL(28,12))) AS bill_total_amount
  FROM bs_bill_selected s CROSS JOIN bs_bill_params p
  LEFT JOIN dw_conan_ods.ods_conan_terra_marketing_bill_da b
    ON CAST(b.id AS STRING)=s.bill_id AND b.dt=p.as_of_dt
  GROUP BY s.bill_id
),
n30_item_raw AS (
SELECT CAST(i.billid AS STRING) AS bill_id,CAST(i.id AS STRING) AS item_id,
         CAST(i.paymentmodel AS STRING) AS payment_model,CAST(i.coursetype AS STRING) AS course_type,
         TRIM(CAST(i.keyfroms AS STRING)) AS keyfroms,
         CAST(i.payableamount AS DECIMAL(28,12)) AS payable_amount,
         CAST(i.subsidyamount AS DECIMAL(28,12)) AS subsidy_amount,
         CAST(i.deductionamount AS DECIMAL(28,12)) AS deduction_amount,
         CAST(i.actualamount AS DECIMAL(28,12)) AS actual_amount,
         CAST(i.suborderquantity AS DECIMAL(28,12)) AS suborder_quantity,
         TO_DATE(i.chargingstart) AS charging_start,TO_DATE(i.chargingend) AS charging_end,
         COUNT(*) OVER(PARTITION BY TRIM(CAST(i.id AS STRING))) AS item_id_rows
  FROM dw_conan_ods.ods_conan_terra_marketing_bill_item_da i
  JOIN bs_bill_selected s ON CAST(i.billid AS STRING)=s.bill_id
  CROSS JOIN bs_bill_params p WHERE i.dt=p.as_of_dt
),
n30_item_stats AS (
SELECT bill_id,COUNT(*) AS item_rows,
         SUM(CASE WHEN item_id IS NULL OR LOWER(TRIM(item_id)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n')) OR item_id_rows<>1 THEN 1 ELSE 0 END) AS invalid_item_ids,
         MAX(payment_model) AS payment_model,MAX(course_type) AS course_type,MAX(keyfroms) AS keyfroms,
         MAX(payable_amount) AS payable_amount,MAX(subsidy_amount) AS subsidy_amount,
         MAX(deduction_amount) AS deduction_amount,MAX(actual_amount) AS actual_amount,
         MAX(suborder_quantity) AS suborder_quantity,
         MAX(charging_start) AS charging_start,MAX(charging_end) AS charging_end
  FROM n30_item_raw GROUP BY bill_id
),
n30_lesson_stats AS (
SELECT bill_id,COUNT(*) AS lesson_rows,
         SUM(CASE WHEN lesson_id IS NULL OR LOWER(TRIM(lesson_id)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n'))
                       OR order_id IS NULL OR LOWER(TRIM(order_id)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n'))
                       OR lesson_id_rows<>1 OR bill_order_rows<>1 THEN 1 ELSE 0 END) AS invalid_lesson_rows,
         COUNT(DISTINCT CASE WHEN payment_model='CPA' AND semester_type='try_double' AND order_status='2'
                             THEN order_id END) AS full_normal_orders,
         SUM(CASE WHEN payment_model='CPA' AND semester_type='try_double'
                       AND (order_status IS NULL OR order_status NOT IN ('2','3')) THEN 1 ELSE 0 END) AS unknown_try_status_rows
  FROM bs_bill_lessons GROUP BY bill_id
),
n30_coverage_stats AS (
SELECT i.bill_id,
         SUM(CASE WHEN l.payment_model='CPA' AND l.semester_type='try_double'
                       AND (l.keyfrom IS NULL OR i.keyfroms IS NULL
                         OR LOWER(TRIM(l.keyfrom)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n'))
                         OR LOWER(TRIM(i.keyfroms)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n'))
                         OR ARRAY_CONTAINS(SPLIT(i.keyfroms,'#'),l.keyfrom)=FALSE)
                  THEN 1 ELSE 0 END) AS keyfrom_mismatch_rows,
         SUM(CASE WHEN l.payment_model='CPA' AND l.semester_type='try_double'
                       AND (i.charging_start IS NULL OR i.charging_end IS NULL
                         OR i.charging_start>i.charging_end OR l.start_class_dt IS NULL
                         OR l.start_class_dt<i.charging_start OR l.start_class_dt>i.charging_end)
                  THEN 1 ELSE 0 END) AS charging_mismatch_rows
  FROM n30_item_stats i JOIN bs_bill_lessons l ON i.bill_id=l.bill_id GROUP BY i.bill_id
),
n30_checked AS (
SELECT s.bill_id,h.header_rows,h.bill_total_amount,i.item_rows,
         l.lesson_rows,l.full_normal_orders,i.suborder_quantity,
         CONCAT_WS(';',
           CASE WHEN h.header_rows<>1 THEN 'MISSING_OR_DUPLICATE_BILL_HEADER' END,
           CASE WHEN h.bill_total_amount IS NULL THEN 'MISSING_BILL_AMOUNT' END,
           CASE WHEN i.item_rows IS NULL OR i.item_rows<>1 THEN 'MULTIPLE_OR_MISSING_ITEMS' END,
           CASE WHEN i.invalid_item_ids IS NULL OR i.invalid_item_ids<>0 THEN 'MISSING_OR_DUPLICATE_ITEM_ID' END,
           CASE WHEN i.payment_model IS NULL OR i.payment_model<>'CPA' OR i.course_type IS NULL
                     OR i.course_type<>'BI_WEEKLY_LESSON' THEN 'UNSUPPORTED_ITEM_TYPE' END,
           CASE WHEN i.payable_amount IS NULL OR i.subsidy_amount IS NULL OR i.deduction_amount IS NULL
                     OR i.actual_amount IS NULL OR i.suborder_quantity IS NULL THEN 'MISSING_ITEM_AMOUNT_OR_QUANTITY' END,
           CASE WHEN i.payable_amount+i.subsidy_amount-i.deduction_amount<>i.actual_amount
                     OR h.bill_total_amount<>i.actual_amount THEN 'BILL_ITEM_AMOUNT_DOES_NOT_RECONCILE' END,
           CASE WHEN l.lesson_rows IS NULL OR l.lesson_rows=0 THEN 'MISSING_FULL_BILL_LESSONS' END,
           CASE WHEN l.invalid_lesson_rows IS NULL OR l.invalid_lesson_rows<>0 THEN 'MISSING_OR_DUPLICATE_LESSON_ORDER_ID' END,
           CASE WHEN l.unknown_try_status_rows IS NULL OR l.unknown_try_status_rows<>0 THEN 'UNKNOWN_FULL_BILL_TRY_ORDER_STATUS' END,
           CASE WHEN l.full_normal_orders IS NULL OR l.full_normal_orders=0 THEN 'ZERO_NORMAL_ORDER_DENOMINATOR' END,
           CASE WHEN i.suborder_quantity<>l.full_normal_orders THEN 'FULL_BILL_SUBORDER_DENOMINATOR_MISMATCH' END,
           CASE WHEN c.keyfrom_mismatch_rows IS NULL OR c.keyfrom_mismatch_rows<>0 THEN 'ITEM_KEYFROM_MISMATCH' END,
           CASE WHEN c.charging_mismatch_rows IS NULL OR c.charging_mismatch_rows<>0 THEN 'ITEM_CHARGING_RANGE_MISMATCH' END
         ) AS bill_hold_reason
  FROM bs_bill_selected s LEFT JOIN n30_header_stats h ON s.bill_id=h.bill_id
  LEFT JOIN n30_item_stats i ON s.bill_id=i.bill_id
  LEFT JOIN n30_lesson_stats l ON s.bill_id=l.bill_id
  LEFT JOIN n30_coverage_stats c ON s.bill_id=c.bill_id
),
bs_bill_controls AS (
SELECT *,CASE WHEN bill_hold_reason='' THEN 1 ELSE 0 END AS bill_cost_available,
       CASE WHEN bill_hold_reason='' THEN CAST(bill_total_amount/full_normal_orders AS DECIMAL(28,12)) END AS bill_gross_unit_cost
FROM n30_checked
),
n31_relation_raw AS (
SELECT CAST(r.id AS STRING) AS relation_id,CAST(r.outerid AS STRING) AS bill_id,
         CAST(r.paymentapplicationid AS STRING) AS application_id,
         COUNT(*) OVER(PARTITION BY r.id) AS relation_id_rows,
         COUNT(*) OVER(PARTITION BY r.outerid,r.paymentapplicationid) AS relation_pair_rows
  FROM dw_conan_ods.ods_conan_terra_purchase_order_application_relation_da r
  JOIN bs_bill_selected s ON CAST(r.outerid AS STRING)=s.bill_id
  CROSS JOIN bs_bill_params p WHERE r.dt=p.as_of_dt AND r.paymenttype='MARKETING'
),
n31_selected_applications AS (
SELECT DISTINCT application_id FROM n31_relation_raw WHERE application_id IS NOT NULL
),
n31_application_raw AS (
SELECT CAST(a.id AS STRING) AS application_id,CAST(a.paystatus AS STRING) AS pay_status,
         CAST(a.paymenttaxratename AS STRING) AS tax_name,
         COUNT(*) OVER(PARTITION BY a.id) AS application_id_rows
  FROM dw_conan_ods.ods_conan_terra_purchase_payment_application_da a
  JOIN n31_selected_applications s ON CAST(a.id AS STRING)=s.application_id
  CROSS JOIN bs_bill_params p WHERE a.dt=p.as_of_dt
),
n31_evidence AS (
SELECT r.*,a.application_id AS found_application_id,a.application_id_rows,a.pay_status,a.tax_name,
         CASE a.tax_name WHEN '固定资产13%' THEN CAST(0.13 AS DECIMAL(8,6))
           WHEN '固定资产3%' THEN CAST(0.03 AS DECIMAL(8,6))
           WHEN '零税率0%' THEN CAST(0 AS DECIMAL(8,6))
           WHEN '非固定资产1%' THEN CAST(0.01 AS DECIMAL(8,6))
           WHEN '非固定资产3%' THEN CAST(0.03 AS DECIMAL(8,6))
           WHEN '非固定资产6%' THEN CAST(0.06 AS DECIMAL(8,6)) END AS tax_rate
  FROM n31_relation_raw r LEFT JOIN n31_application_raw a ON r.application_id=a.application_id
),
n31_stats AS (
SELECT bill_id,COUNT(*) AS application_evidence_rows,
         SUM(CASE WHEN relation_id IS NULL OR LOWER(TRIM(relation_id)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n')) OR relation_id_rows<>1
                       OR relation_pair_rows<>1 OR application_id IS NULL
                       OR LOWER(TRIM(application_id)) IN ('','@pipe_null@','__null__','null','none',CONCAT(CHR(92),'n')) OR found_application_id IS NULL
                       OR application_id_rows<>1 THEN 1 ELSE 0 END) AS invalid_evidence_rows,
         SUM(CASE WHEN tax_rate IS NULL THEN 1 ELSE 0 END) AS unknown_tax_rows,
         COUNT(DISTINCT tax_rate) AS all_tax_variants,MAX(tax_rate) AS single_all_tax,
         SUM(CASE WHEN pay_status='SUCCESS' THEN 1 ELSE 0 END) AS success_rows,
         SUM(CASE WHEN pay_status='SUCCESS' AND tax_rate IS NULL THEN 1 ELSE 0 END) AS unknown_success_tax_rows,
         COUNT(DISTINCT CASE WHEN pay_status='SUCCESS' THEN tax_rate END) AS success_tax_variants,
         MAX(CASE WHEN pay_status='SUCCESS' THEN tax_rate END) AS single_success_tax
  FROM n31_evidence GROUP BY bill_id
),
n31_selected AS (
SELECT s.bill_id,t.application_evidence_rows,t.invalid_evidence_rows,t.unknown_tax_rows,
         t.all_tax_variants,t.single_all_tax,t.success_rows,t.unknown_success_tax_rows,
         t.success_tax_variants,t.single_success_tax,
         CASE WHEN t.invalid_evidence_rows=0 AND t.unknown_tax_rows=0 AND t.all_tax_variants=1
                THEN t.single_all_tax
              WHEN t.invalid_evidence_rows=0 AND t.success_rows>0 AND t.unknown_success_tax_rows=0
                AND t.success_tax_variants=1 THEN t.single_success_tax END AS bill_tax_rate,
         CASE WHEN t.bill_id IS NULL THEN 'NO_APPLICATION_TAX_EVIDENCE'
              WHEN t.invalid_evidence_rows<>0 THEN 'INVALID_OR_DUPLICATE_APPLICATION_EVIDENCE'
              WHEN t.unknown_tax_rows=0 AND t.all_tax_variants=1 THEN 'ALL_APPLICATION_TAX_RATES_AGREE'
              WHEN t.success_rows>0 AND t.unknown_success_tax_rows=0 AND t.success_tax_variants=1
                THEN 'UNIQUE_SUCCESS_TAX_RATE_RESOLVES_CONFLICT'
              ELSE 'APPLICATION_TAX_RATE_CONFLICT_OR_UNKNOWN' END AS bill_tax_basis
  FROM bs_bill_selected s LEFT JOIN n31_stats t ON s.bill_id=t.bill_id
),
bs_bill_tax AS (
SELECT bill_id,bill_tax_rate,bill_tax_basis,application_evidence_rows,
       invalid_evidence_rows,all_tax_variants,unknown_tax_rows,success_rows,success_tax_variants
FROM n31_selected
),
n32_scope_pairs AS (
SELECT CAST(order_id AS STRING) AS order_id,TO_DATE(start_class_dt) AS start_class_dt,
         COUNT(*) AS scope_pair_rows
  FROM bs_target_scope GROUP BY CAST(order_id AS STRING),TO_DATE(start_class_dt)
),
n32_scope_ids AS (
SELECT CAST(order_id AS STRING) AS order_id,COUNT(*) AS scope_id_rows
  FROM bs_target_scope GROUP BY CAST(order_id AS STRING)
),
n32_matches AS (
SELECT s.order_id,s.start_class_dt,s.scope_pair_rows,i.scope_id_rows,
         COUNT(l.bill_id) AS matched_lesson_rows,COUNT(DISTINCT l.bill_id) AS matched_bill_count,
         MAX(l.bill_id) AS candidate_bill_id,MAX(l.order_status) AS terra_order_status
  FROM n32_scope_pairs s LEFT JOIN n32_scope_ids i ON s.order_id=i.order_id
  LEFT JOIN bs_bill_lessons l ON s.order_id=l.order_id AND s.start_class_dt=l.start_class_dt
    AND l.payment_model='CPA' AND l.semester_type='try_double'
  GROUP BY s.order_id,s.start_class_dt,s.scope_pair_rows,i.scope_id_rows
),
n32_joined AS (
SELECT m.*,CASE WHEN matched_bill_count=1 THEN candidate_bill_id END AS bill_id,
         c.bill_total_amount,c.full_normal_orders,c.bill_cost_available,c.bill_hold_reason,
         CASE WHEN matched_bill_count=1 THEN t.bill_tax_rate END AS bill_tax_rate,
         CASE WHEN matched_bill_count=1 THEN t.bill_tax_basis ELSE 'NO_UNIQUE_BILL_TAX_EVIDENCE' END AS bill_tax_basis,
         CASE WHEN m.order_id IS NOT NULL AND TRIM(m.order_id)<>'' AND m.start_class_dt IS NOT NULL
                   AND scope_pair_rows=1 AND scope_id_rows=1 AND matched_bill_count=1 AND matched_lesson_rows=1
                   AND c.bill_cost_available=1 AND terra_order_status IN ('2','3')
              THEN CASE WHEN terra_order_status='3' THEN CAST(0 AS DECIMAL(28,12)) ELSE c.bill_gross_unit_cost END
         END AS bill_gross_allocated_cost
  FROM n32_matches m LEFT JOIN bs_bill_controls c ON m.matched_bill_count=1 AND m.candidate_bill_id=c.bill_id
  LEFT JOIN bs_bill_tax t ON m.matched_bill_count=1 AND m.candidate_bill_id=t.bill_id
),
bs_bill_costs AS (
SELECT order_id,start_class_dt,bill_id,matched_bill_count,matched_lesson_rows,terra_order_status,
       bill_total_amount,full_normal_orders,bill_cost_available,bill_hold_reason,
       bill_gross_allocated_cost,bill_tax_rate,bill_tax_basis,
       CASE WHEN bill_tax_rate IS NOT NULL AND bill_gross_allocated_cost IS NOT NULL
            THEN CAST(bill_gross_allocated_cost/(1+bill_tax_rate) AS DECIMAL(28,12)) END AS bill_net_allocated_cost,
       CASE WHEN order_id IS NULL OR TRIM(order_id)='' OR start_class_dt IS NULL OR scope_pair_rows<>1 OR scope_id_rows<>1 THEN 'INVALID_TARGET_SCOPE'
            WHEN matched_bill_count=0 THEN 'NO_BILL_LESSON_MATCH'
            WHEN matched_bill_count<>1 THEN 'MULTIPLE_BILLS'
            WHEN matched_lesson_rows<>1 THEN 'DUPLICATE_BILL_LESSON_MATCH'
            WHEN COALESCE(bill_cost_available,0)<>1 THEN CONCAT('HELD_BILL:',COALESCE(bill_hold_reason,'MISSING_BILL_CONTROLS'))
            WHEN bill_tax_rate IS NULL THEN 'BILL_ALLOCATABLE_TAX_UNRESOLVED'
            ELSE 'BILL_ALLOCATED_NET' END AS bill_match_status
FROM n32_joined
),
n33_mapped_platform AS (
SELECT target_cohort,order_id,MAX(pricing_platform) AS platform_name
  FROM bs_skill_rows WHERE source_cohort=target_cohort AND source_row_count=1
  GROUP BY target_cohort,order_id
  HAVING COUNT(DISTINCT pricing_platform)=1
),
n33_tax_policy AS (
SELECT source_row,policy_keyfrom,tax_rate,
    CASE WHEN platform_name IN ('京渝永建英语','京渝永建双科') THEN '京渝永建'
         WHEN platform_name IN ('开朗文化阅读','开朗文化双科') THEN '开朗文化'
         ELSE platform_name END AS platform_name
  FROM bs_frozen_policy_tax
),
n33_inputs AS (
SELECT e.*,s.parent_order_id,s.subject_id,s.subject_name,s.purchase_group,s.keyfrom,s.snapshot_dt,
         n.platform_name,f.order_status_label,
         b.bill_id,b.bill_gross_allocated_cost,b.bill_net_allocated_cost,b.bill_tax_rate,
         b.bill_tax_basis,b.bill_match_status,b.matched_bill_count
  FROM bs_estimated_costs e
  LEFT JOIN bs_sku_facts s ON e.order_id=s.order_id AND e.start_class_dt=s.target_cohort
  LEFT JOIN n33_mapped_platform n ON e.order_id=n.order_id AND e.start_class_dt=n.target_cohort
  LEFT JOIN bs_order_facts f ON e.order_id=f.order_id AND e.start_class_dt=f.start_class_dt
  LEFT JOIN bs_bill_costs b ON e.order_id=b.order_id AND TO_DATE(e.start_class_dt)=b.start_class_dt
),
n33_sku_tax_key_window AS (
SELECT target_cohort,order_id,keyfrom,
           MAX(CASE WHEN historical_present=TRUE THEN 1 ELSE 0 END)
             OVER(PARTITION BY target_cohort,order_id) AS has_historical_true
    FROM bs_sku_facts
),
n33_tax_input_keys AS (
SELECT DISTINCT t.order_id,t.start_class_dt,s.keyfrom,n.platform_name
    FROM bs_target_scope t
    JOIN n33_sku_tax_key_window s
      ON t.order_id=s.order_id AND t.start_class_dt=s.target_cohort
     AND s.has_historical_true=1
    LEFT JOIN n33_mapped_platform n
      ON t.order_id=n.order_id AND t.start_class_dt=n.target_cohort
    WHERE t.start_class_dt IS NOT NULL
),
n33_policy_candidates AS (
SELECT i.order_id,i.start_class_dt,p.source_row,p.tax_rate,
           CASE WHEN i.platform_name=p.platform_name AND
                     (LOWER(i.keyfrom)=p.policy_keyfrom OR
                      SUBSTR(LOWER(i.keyfrom),1,LENGTH(p.policy_keyfrom)+1)=CONCAT(p.policy_keyfrom,'-'))
                THEN 1
                WHEN i.platform_name=p.platform_name THEN 2 ELSE 3 END AS priority
    FROM n33_tax_input_keys i JOIN n33_tax_policy p
      ON i.platform_name=p.platform_name OR
         ((i.platform_name IS NULL OR TRIM(i.platform_name)='') AND
          (LOWER(i.keyfrom)=p.policy_keyfrom OR
           SUBSTR(LOWER(i.keyfrom),1,LENGTH(p.policy_keyfrom)+1)=CONCAT(p.policy_keyfrom,'-')))
),
n33_candidate_ranked AS (
SELECT *,MIN(priority) OVER(PARTITION BY order_id,start_class_dt) AS best_priority
  FROM n33_policy_candidates
),
n33_policy_rate AS (
SELECT order_id,start_class_dt,MIN(priority) AS tax_policy_priority,
         CASE WHEN COUNT(*)=COUNT(tax_rate) AND COUNT(DISTINCT tax_rate)=1 THEN MAX(tax_rate) END AS policy_tax_rate
  FROM n33_candidate_ranked WHERE priority=best_priority GROUP BY order_id,start_class_dt
),
n33_tax_evidence AS (
SELECT i.*,
         CASE WHEN i.bill_tax_rate IS NOT NULL THEN i.bill_tax_rate
              WHEN COALESCE(i.matched_bill_count,0)<=1 AND
                   COALESCE(i.bill_tax_basis,'NO_APPLICATION_TAX_EVIDENCE') NOT IN
                     ('INVALID_OR_DUPLICATE_APPLICATION_EVIDENCE','APPLICATION_TAX_RATE_CONFLICT_OR_UNKNOWN')
                   THEN p.policy_tax_rate END AS evidence_tax_rate,
         CASE WHEN i.bill_tax_rate IS NOT NULL THEN CONCAT('账单税率:',i.bill_tax_basis)
              WHEN COALESCE(i.matched_bill_count,0)>1 OR i.bill_tax_basis IN
                     ('INVALID_OR_DUPLICATE_APPLICATION_EVIDENCE','APPLICATION_TAX_RATE_CONFLICT_OR_UNKNOWN') THEN '账单税率证据冲突，禁止政策兜底'
              WHEN p.policy_tax_rate IS NOT NULL THEN CONCAT('冻结政策税率20261013，候选层级',CAST(p.tax_policy_priority AS STRING))
              ELSE '税率未确认' END AS evidence_tax_source
  FROM n33_inputs i LEFT JOIN n33_policy_rate p ON i.order_id=p.order_id AND i.start_class_dt=p.start_class_dt
),
n33_tax_windowed AS (
SELECT e.*,
       CASE WHEN e.sku_key IS NOT NULL AND e.sku_key<>''
            THEN AVG(e.evidence_tax_rate) OVER (PARTITION BY e.start_class_dt,e.sku_key) END AS mean_sku_tax,
       CASE WHEN e.sku_key IS NOT NULL AND e.sku_key<>''
            THEN COUNT(e.evidence_tax_rate) OVER (PARTITION BY e.start_class_dt,e.sku_key) END AS n_sku,
       AVG(e.evidence_tax_rate) OVER (PARTITION BY e.start_class_dt) AS mean_tax,
       COUNT(e.evidence_tax_rate) OVER (PARTITION BY e.start_class_dt) AS n_cohort
  FROM n33_tax_evidence e
),
n33_tax_joined AS (
SELECT w.*,
       COALESCE(w.evidence_tax_rate,w.mean_sku_tax,w.mean_tax) AS estimated_tax_rate,
       CASE WHEN w.evidence_tax_rate IS NOT NULL THEN w.evidence_tax_source
            WHEN w.mean_sku_tax IS NOT NULL THEN CONCAT('同期限同SKU均值税率(n=',CAST(w.n_sku AS STRING),')')
            WHEN w.mean_tax IS NOT NULL THEN CONCAT('同期限整期均值税率(n=',CAST(w.n_cohort AS STRING),')')
            ELSE '税率未确认' END AS tax_rate_source,
       CASE WHEN w.evidence_tax_rate IS NULL
                 AND COALESCE(w.mean_sku_tax,w.mean_tax) IS NOT NULL THEN TRUE ELSE FALSE END AS tax_fallback
  FROM n33_tax_windowed w
),
bs_final_detail AS (
SELECT CAST(order_id AS STRING) AS order_id,
       CAST(order_status_label AS STRING) AS order_status,
       CASE WHEN estimated_settlement_cost IS NOT NULL AND estimated_tax_rate IS NOT NULL
                  AND (estimate_tax_inclusive=1 OR estimated_settlement_cost=0 OR tax_fallback)
            THEN CAST(CAST(estimated_settlement_cost AS DECIMAL(28,8))/(1+CAST(estimated_tax_rate AS DECIMAL(10,6))) AS DECIMAL(28,8)) END AS skill_estimated_settlement_amount,
       CAST(bill_net_allocated_cost AS DECIMAL(28,8)) AS actual_settlement_amount,
       CASE WHEN historical_present=TRUE THEN
         CASE subject_id WHEN '1' THEN '英语' WHEN '2' THEN '思维' WHEN '3' THEN '阅读'
              ELSE CAST(subject_name AS STRING) END END AS subject_name,
       CASE WHEN historical_present=TRUE THEN CAST(parent_order_id AS STRING) END AS parent_order_id,
       CASE WHEN historical_present=TRUE THEN CAST(purchase_group AS STRING) END AS purchase_group,
       CAST(cost_source AS STRING) AS estimated_cost_source,
       CAST(estimated_settlement_cost AS DECIMAL(28,8)) AS estimated_cost_gross,
       CAST(bill_gross_allocated_cost AS DECIMAL(28,8)) AS actual_cost_gross,
       CAST(estimated_tax_rate AS DECIMAL(10,6)) AS estimated_tax_rate,
       CAST(bill_tax_rate AS DECIMAL(10,6)) AS actual_tax_rate,
       CASE WHEN estimated_settlement_cost IS NULL THEN CONCAT('待估:',COALESCE(pending_reason,'无适用政策或同期同SKU无可用样本'))
            WHEN estimated_tax_rate IS NULL THEN '已有原价预估，税率未确认，未税金额留空'
            WHEN tax_fallback THEN '未税预估可用；不是正式应付'
            WHEN estimate_tax_inclusive<>1 AND estimated_settlement_cost<>0 THEN '石墨价或均值样本含税属性未确认，未税金额留空'
            ELSE '未税预估可用；不是正式应付' END AS estimated_cost_status,
       CAST(bill_match_status AS STRING) AS actual_cost_status,
       CAST(bill_id AS STRING) AS bill_id,
       CAST(tax_rate_source AS STRING) AS tax_rate_source,
       CAST(snapshot_dt AS STRING) AS fact_snapshot_dt,
       'biz1-cpa-daily-window30-transfer-v2-20261022' AS calculation_version,
       CAST(start_class_dt AS STRING) AS start_class_dt
FROM n33_tax_joined
),
bs_native_calendar_counts AS (
SELECT COUNT(*) planned_cohorts,SUM(expected_orders) expected_orders FROM n00_target_calendar
),
bs_native_scope_counts AS (
SELECT COUNT(*) target_rows,COUNT(DISTINCT order_id) unique_target_orders,
 SUM(CASE WHEN order_id IS NULL OR TRIM(order_id)='' OR start_class_dt IS NULL THEN 1 ELSE 0 END) invalid_target_rows
FROM bs_target_scope
),
bs_native_readiness_counts AS (
SELECT COUNT(*) readiness_rows,MIN(CASE WHEN ready=1 AND available_cohorts=4 THEN 1 ELSE 0 END) all_ready
FROM bs_cohort_readiness
),
bs_native_input_cohort_counts AS (
-- Final order_policy rows, not raw source UNION/policy candidates: ambiguity
-- flags remain facts for original pricing gates, not silently deleted here.
SELECT CAST(p.target_cohort AS STRING) target_cohort,COUNT(*) input_rows,
 COUNT(DISTINCT p.order_id) unique_input_orders,
 COUNT(DISTINCT p.source_cohort) source_cohorts,
 COUNT(DISTINCT p.snapshot_dt) snapshots,MAX(CAST(p.snapshot_dt AS STRING)) snapshot_dt,
 COUNT(DISTINCT w.source_cohort) matched_source_cohorts,
 SUM(CASE WHEN w.target_cohort IS NULL OR p.order_id IS NULL
           OR LOWER(TRIM(p.order_id)) IN ('','-1','-1.0','null','none','nan','@pipe_null@','__null__')
          THEN 1 ELSE 0 END) invalid_input_rows
FROM bs_full35_input_present_raw p
LEFT JOIN bs_cohort_windows w ON CAST(p.target_cohort AS STRING)=w.target_cohort
 AND CAST(p.snapshot_dt AS STRING)=w.snapshot_dt AND CAST(p.source_cohort AS STRING)=w.source_cohort
GROUP BY p.target_cohort
),
bs_native_input_counts AS (
SELECT COUNT(*) checked_cohorts,
 MIN(CASE WHEN i.input_rows>0 AND i.input_rows=i.unique_input_orders AND i.invalid_input_rows=0
           AND i.source_cohorts=4 AND i.matched_source_cohorts=4 AND i.snapshots=1
           AND i.snapshot_dt=c.snapshot_dt THEN 1 ELSE 0 END) all_input_ready
FROM n00_target_calendar c LEFT JOIN bs_native_input_cohort_counts i ON c.target_cohort=i.target_cohort
),
bs_native_checked_rows AS (
SELECT f.*,COUNT(*) OVER() final_rows,COUNT(*) OVER(PARTITION BY f.order_id) order_id_rows,
 COUNT(*) OVER(PARTITION BY f.start_class_dt) final_cohort_rows,
 t.order_id scope_order_id,c.expected_orders expected_cohort_rows,
 -- Prewrite acceptance: reuse one global window, no second final-tree evaluation.
 SUM(CASE WHEN (f.order_status IS NULL)
    OR (f.fact_snapshot_dt IS NULL)
    OR (f.fact_snapshot_dt IS NOT NULL AND f.fact_snapshot_dt<>'${date}')
    OR (f.calculation_version IS NULL OR f.calculation_version<>'biz1-cpa-daily-window30-transfer-v2-20261022')
    OR (f.skill_estimated_settlement_amount IS NOT NULL AND (f.estimated_cost_gross IS NULL OR f.estimated_tax_rate IS NULL))
    OR (f.actual_settlement_amount IS NOT NULL AND (f.actual_cost_gross IS NULL OR f.actual_tax_rate IS NULL))
    OR (f.estimated_tax_rate<0 OR f.estimated_tax_rate>1 OR f.actual_tax_rate<0 OR f.actual_tax_rate>1)
    OR (f.skill_estimated_settlement_amount IS NOT NULL AND f.estimated_cost_gross IS NOT NULL AND f.estimated_tax_rate>=0
       AND ABS(f.skill_estimated_settlement_amount-CAST(f.estimated_cost_gross/(1+f.estimated_tax_rate) AS DECIMAL(28,8)))>CAST('0.00000002' AS DECIMAL(28,8)))
    OR (f.actual_settlement_amount IS NOT NULL AND f.actual_cost_gross IS NOT NULL AND f.actual_tax_rate>=0
       AND ABS(f.actual_settlement_amount-CAST(f.actual_cost_gross/(1+f.actual_tax_rate) AS DECIMAL(28,8)))>CAST('0.00000002' AS DECIMAL(28,8)))
    OR ((f.estimated_cost_status='未税预估可用；不是正式应付' AND f.skill_estimated_settlement_amount IS NULL)
            OR (f.skill_estimated_settlement_amount IS NOT NULL AND NOT COALESCE(f.estimated_cost_status='未税预估可用；不是正式应付',FALSE)))
    OR ((f.actual_cost_status='BILL_ALLOCATED_NET' AND f.actual_settlement_amount IS NULL)
            OR (f.actual_settlement_amount IS NOT NULL AND NOT COALESCE(f.actual_cost_status='BILL_ALLOCATED_NET',FALSE)))
    OR (f.actual_settlement_amount IS NOT NULL AND (f.bill_id IS NULL OR TRIM(f.bill_id)=''))
    OR (f.estimated_cost_source='石墨政策暂估' AND f.estimated_cost_gross<>0 AND f.skill_estimated_settlement_amount IS NOT NULL AND NOT COALESCE(f.tax_rate_source LIKE '同期限%均值税率%',FALSE))
    OR (f.actual_tax_rate IS NOT NULL AND NOT(f.actual_tax_rate <=> f.estimated_tax_rate))
    OR (f.tax_rate_source='账单税率证据冲突，禁止政策兜底' AND f.estimated_tax_rate IS NOT NULL)
    OR (f.order_status IS NOT NULL AND f.order_status NOT IN ('2','3','正常','退款'))
    OR (f.estimated_cost_gross IS NOT NULL AND (CASE WHEN f.estimated_cost_source IN ('skill测算', '同政策情景暂估', '石墨政策暂估', '同期开课同SKU均值补估') THEN 1 ELSE 0 END)<>1)
    OR (f.estimated_cost_gross IS NULL AND (CASE WHEN f.estimated_cost_source IN ('skill测算', '同政策情景暂估', '石墨政策暂估', '同期开课同SKU均值补估') THEN 1 ELSE 0 END)=1)
    OR (f.estimated_cost_gross IS NOT NULL AND f.estimated_tax_rate IS NOT NULL
    AND f.estimated_cost_source IN ('skill测算','同政策情景暂估')
    AND f.skill_estimated_settlement_amount IS NULL)
    OR (f.actual_cost_gross IS NOT NULL AND f.actual_tax_rate IS NOT NULL
    AND f.actual_settlement_amount IS NULL)
    OR (f.estimated_cost_gross IS NULL
    AND NOT COALESCE(f.estimated_cost_status LIKE '待估:%',FALSE))
    OR (f.estimated_cost_gross IS NOT NULL AND f.estimated_tax_rate IS NULL
    AND NOT COALESCE(f.estimated_cost_status='已有原价预估，税率未确认，未税金额留空',FALSE))
    OR (f.estimated_tax_rate IS NOT NULL
    AND (f.tax_rate_source IS NULL OR TRIM(f.tax_rate_source)=''
      OR f.tax_rate_source IN ('税率未确认','账单税率证据冲突，禁止政策兜底')))
    OR (f.order_id IS NULL OR LOWER(TRIM(f.order_id)) IN ('','-1','-1.0','null','none','nan','@pipe_null@','__null__',CONCAT(CHR(92),'n')))
    THEN 1 ELSE 0 END) OVER() AS prewrite_error_rows
FROM bs_final_detail f
LEFT JOIN bs_target_scope t ON f.order_id=t.order_id AND f.start_class_dt=t.start_class_dt
LEFT JOIN n00_target_calendar c ON f.start_class_dt=c.target_cohort
),
w_policy_frozen_raw AS (
SELECT * FROM VALUES
 ('双周','静魅','yxzz-sw-sq-CPA-jingmei','jingmei','是','否','否','否','','','泉州市静魅文化传媒有限公司','BJ-YLJY-02-20240308-00038','2024年3月8日','否'),
 ('双周','学研星途','yxzz-sw-sq-CPA-xyxt','xyxt','是','否','否','否','','','武汉学研星途科技有限公司','BJ-YLJY-02-20250714-00066','2025年7月14日','否'),
 ('双周','学研星途','yxzz-sw-sy-CPA-xyxt','xyxt','是','否','否','否','','','武汉学研星途科技有限公司','BJ-YLJY-02-20250714-00066','2025年7月14日','否'),
 ('双周','时光学','yxzz-sw-sq-CPA-shiguangxue','shiguangxue','是','否','否','否','','','江西一学就慧文化科技有限公司青岛分公司','BJ-YLJY-02-20240220-00071','2024年1月15日','否'),
 ('双周','佳效','yxzz-sw-sq-CPA-jiaxiao','jiaxiao','是','否','否','否','','','洛阳佳效信息科技有限公司','BJ-YLJY-02-20231103-00108','2023年11月4日','否'),
 ('双周','新动力','yxzz-sw-sq-CPA-xdl','xdl','是','否','否','否','','','北京中企新动力网络科技有限公司','BJ-YLJY-02-20231103-00027','2023年11月3日','否'),
 ('双周','优优','yxzz-sw-sq-CPA-youyou','youyou','是','否','否','否','','','北京优优未来科技发展有限公司','BJ-YLJY-02-20231205-00003','2023年11月1日','否'),
 ('双周','阳明（学为先）','yxzz-sw-sq-CPA-xueweixian','xueweixian','是','否','否','否','','','南昌阳明信息技术有限公司','BJ-YLJY-02-20231204-00164、BJ-YLJY-02-20240430-00013','2023年11月1日','是'),
 ('双周','阳明（学为先）','yxzz-sw-sq-CPA-ncym','ncym','是','否','否','否','','','南昌阳明信息技术有限公司','BJ-YLJY-02-20231204-00164、BJ-YLJY-02-20240430-00013','2023年11月1日','是'),
 ('双周','擎拓','yxzz-sw-sq-CPA-qingtuo','qingtuo','是','否','否','否','','','桐城铭才信息科技有限公司','BJ-YLJY-02-20231204-00186、BJ-YLJY-02-20231205-00004、BJ-YLJY-02-20240415-00026','2023年11月1日','否'),
 ('双周','精厚','yxzz-sw-sq-CPA-jinghou','jinghou','是','否','否','否','','','精厚文化传播（河北）有限公司','BJ-YLJY-02-20231114-00068','2023年11月1日','否'),
 ('双周','中轶','yxzz-sw-sq-CPA-zhongyixx','zhongyixx','是','否','否','否','','','安徽省中轶信息咨询有限公司','BJ-YLJY-02-20231027-00003','2023年10月27日','否'),
 ('双周','网聚天下社群','yxzz-sw-sq-CPA-syabl','syabl','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20250507-00231','2025年5月7日','是'),
 ('双周','网聚天下bpo','yxzz-sw-tmk-cpa-bpowjtx','bpowjtx','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20260204-00611','2026年2月5日','否'),
 ('双周','酬勤信息','yxzz-sw-dt-CPA-cqxx','cqxx','否','否','0.07','是','','','邯郸酬信科技有限公司','BJ-YLJY-02-20250414-00247、BJ-YLJY-02-20260302-00571、BJ-YLJY-02-20260210-00892','2025年4月14日','是'),
 ('双周','酬勤信息','yxzz-sw-sq-CPA-cqxx','cqxx','否','否','0.07','是','','','邯郸酬信科技有限公司','BJ-YLJY-02-20250414-00247、BJ-YLJY-02-20260302-00571、BJ-YLJY-02-20260210-00892','2025年4月14日','是'),
 ('双周','元慷文化','yxzz-sw-sq-CPA-yuankang','yuankang','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-sq-CPA-yuankangwh','yuankangwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-qt-cpa-ykwh','ykwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','元慷文化','yxzz-sw-sy-cpa-ykwh','ykwh','是','否','否','否','','','上海元慷文化传媒有限公司','BJ-YLJY-02-20250311-00145','2025年2月8日','否'),
 ('双周','奇趣','yxzz-sw-ss-cpa-qiqu','qiqu','是','否','否','否','','','鄂州市葛店经济技术开发区奇趣电子商务工作室（个体工商户）','BJ-YLJY-02-20260403-00933','2026年4月3日','否'),
 ('双周','新服','yxzz-sw-sq-CPA-xinfu','xinfu','是','否','否','否','','','山西新服时代信息科技有限公司','BJ-YLJY-02-20230907-00006','2023年8月23日','是'),
 ('双周','褚岩（吾醒）','yxzz-sw-sq-CPA-wuxing','wuxing','是','否','否','否','','','保定褚岩网络科技有限公司','BJ-YLJY-02-20230907-00072','2023年8月22日','否'),
 ('双周','幸树','yxzz-sw-sq-CPA-xingshu','xingshu','是','否','否','否','','','安徽盈幸树信息科技有限公司','BJ-YLJY-02-20230907-00005','2023年8月22日','否'),
 ('双周','路迦','yxzz-sw-sq-cpa-lujia','lujia','是','否','否','否','','','江西阿路迦信息科技有限公司','BJ-YLJY-02-20230907-00074','2023年8月22日','否'),
 ('双周','保定佳学','yxzz-sw-sq-cpa-bdjiaxue','bdjiaxue','是','否','否','否','','','保定佳学教育科技有限公司','BJ-YLJY-02-20230907-00075','2023年8月22日','否'),
 ('双周','碟塔','yxzz-sw-sq-CPA-dieta','dieta','是','否','否','否','','','广州磐碟塔信息科技有限公司','BJ-YLJY-02-20230726-00003','2023年7月26日','否'),
 ('双周','盛和文（茂密文化）','yxzz-sw-sq-CPA-shmiwen','shmiwen','是','否','否','否','','','上海盛和文网络科技有限公司','BJ-YLJY-02-20231204-00183、BJ-YLJY-02-20231204-00184','2023年7月20日','否'),
 ('双周','茂密文化','yxzz-sw-sq-CPA-mw','mw','是','否','否','否','','','上海茂密文化传播有限公司','BJ-YLJY-02-20230720-00088、BJ-YLJY-02-20231007-00071、BJ-YLJY-02-20231113-00025','2023年7月20日','否'),
 ('双周','云梯','yxzz-sw-sq-CPA-yunti','yunti','是','否','否','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20230717-00013','2023年7月17日','否'),
 ('双周','有大志','yxzz-sw-sq-CPA-youdazhi','youdazhi','是','否','否','否','','','温州有大志网络科技有限公司','BJ-YLJY-02-20230628-00007','2023年6月29日','否'),
 ('双周','铭栎（臻好）','yxzz-sw-sq-CPA-nbzhenhao','nbzhenhao','是','否','否','否','','','宁波铭栎智能科技有限公司','BJ-YLJY-02-20250317-00036、BJ-YLJY-02-20250318-00103、BJ-YLJY-02-20250408-00039','2025年3月1日','否'),
 ('双周','够玩','yxzz-sw-sy-cpa-gzgouwan','gzgouwan','是','否','否','否','','','广州够玩网络科技有限公司','BJ-YLJY-02-20250925-00023','2025年8月1日','否'),
 ('双周','够玩','yxzz-sw-sq-CPA-gzgouwan','gzgouwan','是','否','否','否','','','广州够玩网络科技有限公司','BJ-YLJY-02-20250925-00023','2025年8月1日','否'),
 ('双周','神州鹰','yxzz-sw-sq-CPA-shenzhouying','shenzhouying','是','否','否','否','','','苏州神州鹰网络科技有限公司','BJ-YLJY-02-20241121-00036','2024年11月23日','否'),
 ('双周','脉点','yxzz-sw-sq-cpa-dyfx','61522582482','是','否','否','否','','','杭州脉点文化传媒有限公司','BJ-YLJY-02-20250224-00034','2025年2月17日','是'),
 ('双周','中云','yxzz-sw-sq-CPA-zhongyun','zhongyun','是','否','否','否','','','资溪县中云信息服务中心（个体工商户）','BJ-YLJY-02-20250224-00035','2025年2月12日','否'),
 ('双周','三云','yxzz-sw-sq-CPA-sanyun','sanyun','是','否','否','否','','','三云网络科技（广州）有限公司','BJ-YLJY-02-20250225-00016','2025年2月25日','否'),
 ('双周','雅艺','yxzz-sw-sq-cpa-dyfx','4200561827384891','是','否','否','否','','','湖北雅艺传媒有限公司','BJ-YLJY-02-20250304-00046','2025年3月1日','否'),
 ('双周','怡彩','yxzz-sw-sq-CPA-yicai','yicai','是','否','否','否','','','沙市区怡彩信息技术咨询服务中心','BJ-YLJY-02-20250331-00087','2025年2月16日','否'),
 ('双周','千亿教育','yxzz-sw-sq-CPA-qyjy','qyjy','是','否','否','否','','','湖北千亿教育科技有限公司','BJ-YLJY-02-20250317-00088','2025年3月17日','否'),
 ('双周','千亿教育','yxzz-sw-sy-CPA-qyjy','qyjy','是','否','否','否','','','湖北千亿教育科技有限公司','BJ-YLJY-02-20250317-00088','2025年3月17日','否'),
 ('双周','涵科','yxzz-sw-sq-CPA-hanke','hanke','是','否','否','否','','','蚌埠涵科科技有限公司','BJ-YLJY-02-20250318-00118','2025年3月18日','否'),
 ('双周','嘉宝','yxzz-sw-sq-CPA-szjiabao','szjiabao','是','否','否','否','','','苏州嘉宝禾信息技术有限公司','BJ-YLJY-02-20250402-00042','2025年4月2日','否'),
 ('双周','乐知（凌泽）','yxzz-sw-sq-CPA-lingze','lingze','否','是','0.07','是','','','北京乐知科技有限公司','BJ-YLJY-02-20260331-00998、BJ-YLJY-02-20260407-00677','2026年2月1日','是'),
 ('双周','臻好（铭栎）','yxzz-sw-sq-CPA-mingli','mingli','否','是','0.07','是','','','宁波臻好信息技术有限公司','BJ-YLJY-02-20260611-03068、BJ-YLJY-02-20260622-01949','2026年4月1日','是'),
 ('双周','书纽','yxzz-sw-ss-cpa-shuniu','shuniu','是','否','否','否','','','武汉书纽科技有限公司','BJ-YLJY-02-20250508-00076','2025年4月29日','否'),
 ('双周','书纽','yxzz-sw-sq-CPA-shuniu','shuniu','是','否','否','否','','','武汉书纽科技有限公司','BJ-YLJY-02-20250508-00076','2025年4月29日','否'),
 ('双周','时科','yxzz-sw-sq-CPA-shike','shike','是','否','否','否','','','北京子木时代科技有限公司','BJ-YLJY-02-20250325-00070','2025年3月25日','否'),
 ('双周','铭祺','yxzz-sw-sy-cpa-mingqi','mingqi','是','否','否','否','','','深圳市铭祺电子商务有限公司','BJ-YLJY-02-20250609-00160','2025年6月5日','否'),
 ('双周','铭祺','yxzz-sw-sq-CPA-mingqi','mingqi','是','否','否','否','','','深圳市铭祺电子商务有限公司','BJ-YLJY-02-20250609-00160','2025年6月5日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','3043886234337671','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','3087056828895051','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','乐学科技','yxzz-sw-sq-CPA-lexuekj','lexuekj','是','否','否','否','','','武汉好乐学科技有限公司','BJ-YLJY-02-20250324-00078','2025年3月24日','否'),
 ('双周','蓝智（怡乐）','yxzz-sw-sy-cpa-yile','yile','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','蓝智（怡乐）','yxzz-sw-sq-CPA-yile','yile','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','蓝智','yxzz-sw-sy-cpa-lanzhi1','lanzhi1','是','否','否','否','','','广州蓝智科技有限公司','BJ-YLJY-02-20260514-01063','2026年3月1日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','sddr','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','博学（谦受益）','yxzz-sw-sq-CPA-qsy','qsy','否','是','0.07','是','','','江西慎思之信息科技有限公司','BJ-YLJY-02-20260422-00、BJ-YLJY-02-20260428-00669、BJ-YLJY-02-20260710-01934','2026年3月1日','是'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','2791040445891170','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','黑木','yxzz-sw-sq-CPA-heimu','heimu','是','否','否','否','','','杭州黑木文化有限公司','BJ-YLJY-02-20250905-00048','2025年9月6日','否'),
 ('双周','茂密','yxzz-sw-sq-CPA-maomi','maomi','是','否','否','否','','','上海茂密文化传播有限公司','BJ-YLJY-02-20250909-00016','2025年9月10日','否'),
 ('双周','启睿','yxzz-sw-sy-cpa-qirui','qirui','是','否','否','否','','','武汉启睿优学科技有限公司','BJ-YLJY-02-20250911-00064','2025年8月5日','否'),
 ('双周','启睿','yxzz-sw-sq-CPA-qirui','qirui','是','否','否','否','','','武汉启睿优学科技有限公司','BJ-YLJY-02-20250911-00064','2025年8月5日','否'),
 ('双周','湖州云梯','yxzz-sw-sq-CPA-hzyt','hzyt','是','否','否','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20250725-00053','2025年7月26日','否'),
 ('双周','湖州云梯','yxzz-sw-ss-cpa-hzyt','hzyt','是','否','0.095','否','','','湖州云梯科技有限公司','BJ-YLJY-02-20260729-02900','2026年7月29日','否'),
 ('双周','优考','yxzz-sw-sq-CPA-youkao','youkao','是','否','否','否','','','杭州优考文化发展有限公司','BJ-YLJY-02-20250327-00035','2025年3月28日','否'),
 ('双周','童趣','yxzz-sw-sq-cpa-dyfx','1201131541503580','是','否','否','否','','','郑州童趣宝盒信息技术有限公司','BJ-YLJY-02-20250918-00150','2025年9月18日','否'),
 ('双周','禧泽（长台）','yxzz-sw-jz-cpa-xize','xize','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','禧泽（长台）','yxzz-sw-sq-CPA-xize','xize','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','逗爸','yxzz-sw-sq-cpa-sphfx','sphdujHUEzWRb6W','否','否','0.07','否','','','深圳楚航信息科技有限公司','BJ-YLJY-02-20260113-00966','2026年1月13日','是'),
 ('双周','百杰胜','yxzz-sw-ss-cpa-bjssq','bjssq','否','否','否','否','','','武汉智成杰数字科技有限公司','BJ-YLJY-02-20260320-00820、BJ-YLJY-02-20260327-00720','2026年4月1日','否'),
 ('双周','京渝永建双科','yxzz-sw-sq-CPA-jyyj','jyyj','是','否','否','否','','','重庆京渝永建科技有限公司','BJ-YLJY-02-20260616-03341','2026年6月16日','否'),
 ('双周','北极鸥','yxzz-sw-sy-cpa-bjojy','bjojy','是','否','否','否','','','青岛北极鸥教育信息咨询有限公司','BJ-YLJY-02-20251021-00691','2025年10月21日','否'),
 ('双周','全商','yxzz-sw-sy-cpa-quanshang','quanshang','是','否','否','否','','','华容县殷全商务服务站','J-YLJY-02-20251203-00518','2025年10月1日','否'),
 ('双周','全商','yxzz-sw-sq-CPA-quanshang','quanshang','是','否','否','否','','','华容县殷全商务服务站','J-YLJY-02-20251203-00518','2025年10月1日','否'),
 ('双周','满天星（代播）','yxzz-sw-sq-cpa-dyfx','280525644','否','否','否','否','','','天津聚星引力科技有限公司','BJ-YLJY-02-20250804-00049','2025年4月15日','是'),
 ('双周','海裕','yxzz-sw-sy-cpa-haiyu','haiyu','是','否','否','否','','','北京启明钰泉科技有限公司','BJ-YLJY-02-20260508-00666','2026年5月8日','否'),
 ('双周','海裕','yxzz-sw-sq-CPA-haiyu','haiyu','是','否','否','否','','','北京启明钰泉科技有限公司','BJ-YLJY-02-20260508-00666','2026年5月8日','否'),
 ('双周','坚壳','yxzz-sw-sq-CPA-jianke','jianke','是','否','否','否','','','江苏坚壳科技有限公司','BJ-YLJY-02-20250925-00241','2025年10月1日','否'),
 ('双周','精灵','yxzz-sw-sy-cpa-htjl','htjl','是','否','否','否','10000','','武汉海豚精灵网络科技有限公司','BJ-YLJY-02-20251121-00835','2025年11月22日','否'),
 ('双周','精灵','yxzz-sw-sq-CPA-htjl','htjl','是','否','否','否','','','武汉海豚精灵网络科技有限公司','BJ-YLJY-02-20251121-00835','2025年11月22日','否'),
 ('双周','哪吒','yxzz-sw-sy-cpa-nezha','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','哪吒','yxzz-sw-ss-cpa-nezha19','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','哪吒','yxzz-sw-ss-cpa-nezha','nezha','否','否','是','否','','','广东哪塔库信息科技有限公司','BJ-YLJY-02-20260309-00610','2026年3月9日','否'),
 ('双周','仁轩','yxzz-sw-sq-CPA-renxuan','renxuan','是','否','否','否','','','郑州仁轩教育科技有限公司','BJ-YLJY-02-20260107-00804、BJ-YLJY-02-20260424-00810','2026年1月12日','否'),
 ('双周','仁轩','yxzz-sw-sy-cpa-renxuan','renxuan','是','否','否','否','','','郑州仁轩教育科技有限公司','BJ-YLJY-02-20260107-00804、BJ-YLJY-02-20260424-00810','2026年1月12日','否'),
 ('双周','稻果','yxzz-sw-jz-cpa-daoguowh','daoguowh','是','否','0.06','否','','','深圳市稻果文化传播有限公司','BJ-YLJY-02-20260325-00938','2026年3月24日','否'),
 ('双周','燃势网络','yxzz-dy-cpa-bmzx','819579791613644','否','是','0.05','否','','','北京燃势网络科技有限公司','BJ-YLJY-02-20260320-00917','2026年3月23日','否'),
 ('双周','潇沐','yxzz-dy-cpa-bmzx','2709644393854711','是','否','0.05','否','','','山西潇沐网络科技有限公司','BJ-YLJY-02-20260421-00744','2026年4月1日','否'),
 ('双周','诚学','yxzz-sw-sy-cpa-chengxue','chengxue','是','否','否','否','','','武汉诚学汇科技有限公司','BJ-YLJY-02-20260506-01316','2026年4月1日','否'),
 ('双周','玉琴','yxzz-mr-sy-cpa-yuqin','yuqin','是','否','否','否','','','郑州誉景和商贸有限责任公司','BJ-YLJY-02-20260629-03144','2026年4月9日','否'),
 ('双周','星耀学1','yxzz-mr-sy-cpa-xingyaoxue','xingyaoxue1','是','否','否','否','','','北京星耀学文化传播有限公司','BJ-YLJY-02-20260410-00892','2026年4月10日','否'),
 ('双周','长台','yxzz-sw-jz-cpa-changtai','changtai','是','否','0.065','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260521-01335','2026年4月1日','否'),
 ('双周','昆紫','yxzz-sw-sy-cpa-kunzi','kunzi','是','否','否','否','','','林州昆紫信息技术有限公司','BJ-YLJY-02-20260423-01107','2026年4月21日','否'),
 ('双周','胖虎','yxzz-sw-ss-cpa-panghu','panghu','是','否','否','否','','','菏泽胖虎网络科技有限公司','BJ-YLJY-02-20260320-00965','2026年3月1日','否'),
 ('双周','破晓','yxzz-sw-ss-cpa-poxiao','poxiao','是','否','否','否','','','菏泽倍优教育科技有限公司','BJ-YLJY-02-20260327-00923','2026年3月27日','否'),
 ('双周','悦冠','yxzz-sw-ss-cpa-yueguan','yueguan','是','否','否','否','','','徐州向学信息科技有限公司','BJ-YLJY-02-20260408-00665','2026年4月8日','否'),
 ('双周','巨航','yxzz-sw-ss-cpa-juhang','juhang','是','否','否','否','','','菏泽巨航电子商务有限公司','BJ-YLJY-02-20260421-00917','2026年4月21日','否'),
 ('双周','乐学1','yxzz-sw-sy-cpa-lexu','lexu','否','否','否','否','','','海口乐学科技有限公司','BJ-YLJY-02-20260415-01157','2026年5月15日','是'),
 ('双周','文荀','yxzz-sw-sy-cpa-wenxun','wenxun','是','否','否','否','','','合肥创硕优科技有限公司','BJ-YLJY-02-20260721-02548','2026年5月1日','否'),
 ('双周','元昔','yxzz-sw-sy-cpa-yuanxi','yuanxi','是','否','否','否','','','北京攀升科技有限公司','BJ-YLJY-02-20260608-01651','2026年4月1日','否'),
 ('双周','乐都','yxzz-sw-sy-cpa-ledou','lefou','是','否','否','否','','','青海乐读文化传媒有限公司','BJ-YLJY-02-20260623-02571','2026年5月21日','否'),
 ('双周','雅艺','yxzz-sw-sy-cpa-yayi','yayi','是','否','否','否','','','湖北雅艺传媒有限公司','BJ-YLJY-02-20260623-02040','2026年6月8日','否'),
 ('双周','目标','yxzz-sw-jz-cpa-mubiao','mubiao','是','否','0.065','否','','','郴州目标信息咨询有限公司','BJ-YLJY-02-20260527-00949','2026年5月27日','否'),
 ('双周','馨松','yxzz-sw-sy-cpa-xinsong1','xinsong1','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','八斗','yxzz-sw-jz-cpa-badou','badou','是','否','0.065','否','','','深圳市高八斗科技有限公司','BJ-YLJY-02-20260521-00976','2026年5月18日','否'),
 ('双周','静魅','yxzz-sw-jz-cpa-jingmeiqz','jingmeiqz','是','否','0.065','否','','','泉州市静魅文化传媒有限公司','BJ-YLJY-02-20260525-01049','2026年5月25日','否'),
 ('双周','清之意','yxzz-sw-qt-cpa-qzy','qzy','是','否','否','否','','','贵州清之意科技有限责任公司','BJ-YLJY-02-20260519-00938','2026年5月19日','否'),
 ('双周','文化','yxzz-sw-sy-cpa-wenhua','wenhua','是','否','否','否','','','广州有点文化发展有限公司','BJ-YLJY-02-20260604-01275','2026年6月4日','否'),
 ('双周','盈推','yxzz-sw-sy-cpa-yingwei','yingwei','是','否','否','否','','','宁波盈推信息技术服务有限公司','BJ-YLJY-02-20260518-00687','2026年5月18日','否'),
 ('双周','云电','yxzz-sw-sy-cpa-yundian','yundian','是','否','0.09','否','','','湖北停云电子科技有限公司','BJ-YLJY-02-20260605-01280','2026年6月5日','否'),
 ('双周','优投','yxzz-sw-sq-CPA-youtou','youtou','是','否','0.06','否','','','杭州优投智数科技有限公司','BJ-YLJY-02-20260420-00842','2026年4月20日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphTExGDtq5100J','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphTHGqRfXXZRfG','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphQpNl8PowodqC','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphpSPyAZhAssRY','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-wx-cpa-bmsjzxxd','sphOte1cxigd56j','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','3722327016875712','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','731652064292043','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1804742529655881','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1857548839823209','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','4355612637930179','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','2332513424648508','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','132978274471588','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1628809348255993','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','4474326611661387','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','164242089867824','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-cpa-bmzx','1184589921401500','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','3722327016875712','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','731652064292043','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1804742529655881','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1857548839823209','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','4355612637930179','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','2332513424648508','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','132978274471588','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1628809348255993','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','4474326611661387','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','164242089867824','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','春夏','yxzz-dy-bmtsypd','1184589921401500','是','否','0.05','否','','','南昌春夏文化传媒有限公司','BJ-YLJY-02-20260514-01030','2026年5月15日','否'),
 ('双周','亿起发','yxzz-sw-ss-cpa-yiqifa','yiqifa','是','否','0.055','否','','','滁州亿起发网络科技有限公司','BJ-YLJY-02-20260518-01284','2026年5月18日','否'),
 ('双周','微尚','yxzz-sw-ss-cpa-weishang','weishang','是','否','0.055','否','','','北京晨鑫益晟家政服务有限公司','BJ-YLJY-02-20260616-02977','2026年4月20日','否'),
 ('双周','壹佰分','yxzz-sw-ss-cpa-yibaifen','yibaifen','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','壹佰分','yxzz-sw-sy-cpa-beijixing','beijixing','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','壹佰分','yxzz-sw-ss-cpa-yibaifenyy','yibaifenyy','否','否','0.055','否','','','武汉壹佰分教育科技有限公司','BJ-YLJY-02-20260603-01056','2026年6月3日','否'),
 ('双周','晨曦','yxzz-sw-ss-cpa-chenxi','chenxi','是','否','0.05','否','','','菏泽晨曦文化传媒有限公司','BJ-YLJY-02-20260520-00683','2026年5月20日','否'),
 ('双周','温老师','yxzz-sw-ss-cpa-wenlaoshi','wenlaoshi','是','否','0.065','否','','','菏泽市曹县辰锦网络科技有限公司','BJ-YLJY-02-20260609-01905','2026年6月9日','否'),
 ('双周','小瓶盖','yxzz-sw-ss-cpa-xiaopinggai','xiaopinggai','是','否','0.105','否','','','徐州小瓶盖信息科技有限公司','BJ-YLJY-02-20260706-02511','2026年5月26日','否'),
 ('双周','绿韵','yxzz-sw-ss-cpa-lvyun','lvyun','是','否','0.1','否','','','菏泽市牡丹区绿韵电子商务有限公司','BJ-YLJY-02-20260612-01605','2026年5月26日','否'),
 ('双周','酷游','yxzz-sw-ss-cpa-kuyou','kuyou','是','否','0.1','否','','','菏泽酷游网络科技有限公司','BJ-YLJY-02-20260526-01140','2026年6月13日','否'),
 ('双周','云岛','yxzz-sw-sy-cpa-yundao','yundao','是','否','0.055','否','','','广州云岛科技有限公司','BJ-YLJY-02-20260611-00163','2026年6月10日','否'),
 ('双周','雅览','yxzz-sw-ss-cpa-yalan','yalan','是','否','0.1','否','','','菏泽雅览教育服务有限公司','BJ-YLJY-02-20260626-03039','2026年6月26日','否'),
 ('双周','廷嘉','yxzz-bd-jx-cpa-tingjia','tingjia','是','否','0.06','否','','','广州市廷嘉科技有限公司','BJ-YLJY-02-20260528-01244','2026年6月1日','否'),
 ('双周','优思睿','yxzz-bd-jx-cpa-yousirui','yousirui','是','否','0.06','否','','','昆山优丞嘻信息技术有限公司','BJ-YLJY-02-20260529-00647、BJ-YLJY-02-20260814-0200','2026年6月1日','否'),
 ('双周','尔瑞','yxzz-bd-jx-cpa-errui','errui','是','否','0.06','否','','','深圳尔瑞信息技术有限公司','BJ-YLJY-02-20260601-00659','2026年6月1日','否'),
 ('双周','墨点','yxzz-bd-jx-cpa-modian','modian','是','否','0.06','否','','','固镇县墨点科技有限公司','BJ-YLJY-02-20260602-00801','2026年6月1日','否'),
 ('双周','德才','yxzz-bd-jx-cpa-decai','decai','是','否','0.06','否','','','山西德才教育科技有限公司','BJ-YLJY-02-20260605-01517','2026年6月1日','否'),
 ('双周','开朗文化阅读','yxzz-sw-sq-cpa-klwh','klwh','否','否','是','否','','','商丘开朗文化传播有限公司','BJ-YLJY-02-20260630-01840','2026年6月30日','否'),
 ('双周','童画','yxzz-sw-jz-cpa-tonghua','tonghua','是','否','0.065','否','','','童画（广州）网络科技有限公司','BJ-YLJY-02-20260527-01167','2026年6月1日','否'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sph8jg7SHnaMaem','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sphrIR3dvJX7XL3','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','馨松','yxzz-wx-cpa-bmsjzxxd','sphpj7ahkKSbRci','否','是','否','否','','','馨松(武汉市)信息技术服务有限责任公司','BJ-YLJY-02-20260514-00665','2026年5月14日','是'),
 ('双周','廷嘉','yxzz-sw-jz-cpa-tingjia','tingjia','是','否','0.06','否','','','广州市廷嘉科技有限公司','BJ-YLJY-02-20260528-01244','2026年6月1日','否'),
 ('双周','优思睿','yxzz-sw-jz-cpa-yousirui','yousirui','是','否','0.06','否','','','昆山优丞嘻信息技术有限公司','BJ-YLJY-02-20260529-00647、BJ-YLJY-02-20260814-02007','2026年6月1日','否'),
 ('双周','尔瑞','yxzz-sw-jz-cpa-errui','errui','是','否','0.06','否','','','深圳尔瑞信息技术有限公司','BJ-YLJY-02-20260601-00659','2026年6月1日','否'),
 ('双周','墨点','yxzz-sw-jz-cpa-modian','modian','是','否','0.06','否','','','固镇县墨点科技有限公司','BJ-YLJY-02-20260602-00801','2026年6月1日','否'),
 ('双周','德才','yxzz-sw-jz-cpa-decai','decai','是','否','0.06','否','','','山西德才教育科技有限公司','BJ-YLJY-02-20260605-01517','2026年6月1日','否'),
 ('双周','长台1','yxzz-sw-jz-cpa-changtaixx','changtaixx','是','否','0.1','否','','','杭州长台网络科技有限公司','BJ-YLJY-02-20260617-02386','2026年6月15日','否'),
 ('双周','无忧','yxzz-sw-jz-cpa-wuyou','wuyou','是','否','0.065','否','','','深圳市无忧空间传媒有限公司','BJ-YLJY-02-20260831-02094','2026年8月31日','否'),
 ('双周','萌宝1','yxzz-sw-sy-cpa-mengbao1','mengbao1','是','否','否','否','','','华容县萌宝启蒙文化传媒工作室','BJ-YLJY-02-20260717-03087','2026年7月17日','否'),
 ('双周','网聚天下社群','yxzz-jd-kecheng-sw','jd','否','否','否','否','','','沈阳网聚天下科技有限公司','BJ-YLJY-02-20250507-00231','2025年5月7日','是'),
 ('双周','胖虎','yxzz-sw-ss-cpa-panghuyy','panghuyy','是','否','是','否','','','菏泽胖虎网络科技有限公司','BJ-YLJY-02-20260902-02382','2026年8月31日','否'),
 ('双周','佳慕','yxzz-sw-ss-cpa-jiamuyy','jiamuyy','是','否','是','否','','','山东佳慕电子科技有限公司','BJ-YLJY-02-20260902-02384','2026年9月1日','否')
 AS p(`type`,`platform_name`,`platform`,`platform_5`,`is_normal`,`is_tmk`,`is_bollte_allowance`,`is_max_allowance`,`deduction_amount`,`excluded_commission`,`party_b`,`contract_code`,`ori_sign_date`,`is_ka`)
),
w_policy_frozen_policy_raw AS (
SELECT TRIM(CAST(type AS STRING)) AS contract_type,
           TRIM(CAST(platform_name AS STRING)) AS platform_name,
           TRIM(CAST(platform AS STRING)) AS policy_keyfrom,
           TRIM(CAST(platform_5 AS STRING)) AS policy_authorid,
           TRIM(CAST(party_B AS STRING)) AS party_b,
           TRIM(CAST(contract_code AS STRING)) AS contract_code_raw,
           TRIM(CAST(ori_sign_date AS STRING)) AS ori_sign_date_raw,
           TRIM(CAST(is_normal AS STRING)) AS is_normal,
           TRIM(CAST(is_tmk AS STRING)) AS is_tmk,
           TRIM(CAST(is_bollte_allowance AS STRING)) AS is_bollte_allowance,
           TRIM(CAST(is_max_allowance AS STRING)) AS is_max_allowance,
           TRIM(CAST(is_ka AS STRING)) AS is_ka,
           CASE WHEN TRIM(COALESCE(CAST(deduction_amount AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(deduction_amount AS DECIMAL(28,8)) END AS deduction_amount,
           CASE WHEN TRIM(COALESCE(CAST(excluded_commission AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(excluded_commission AS DECIMAL(28,8)) END AS excluded_commission
    FROM w_policy_frozen_raw WHERE type='双周'
),
w_policy_frozen_policy_normalized AS (
SELECT *,
           CASE WHEN platform_name='臻好（铭栎）'
                 AND contract_code_raw=CONCAT('BJ-YLJY-02-20260611-03068、',CHR(10),'BJ-YLJY-02-20260622-01949')
                THEN REPLACE(contract_code_raw,CHR(10),'') ELSE contract_code_raw END AS contract_code,
           CASE WHEN ori_sign_date_raw RLIKE '^[0-9]{4,6}$'
                THEN CONCAT(YEAR(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'年',
                            MONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'月',
                            DAYOFMONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'日')
                WHEN ori_sign_date_raw RLIKE '^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日?$'
                THEN CONCAT(CAST(REGEXP_EXTRACT(ori_sign_date_raw,'^([0-9]{4})年',1) AS INT),'年',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'年([0-9]{1,2})月',1) AS INT),'月',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'月([0-9]{1,2})',1) AS INT),'日')
                ELSE ori_sign_date_raw END AS ori_sign_date,
           CASE WHEN policy_keyfrom NOT LIKE '%dyfx%' AND policy_keyfrom NOT LIKE '%-bmzx%'
                     AND policy_keyfrom NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN policy_keyfrom LIKE '%dyfx%' OR policy_keyfrom LIKE '%bmzx%'
                     OR policy_keyfrom LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM w_policy_frozen_policy_raw
),
w_policy_live_policy_raw AS (
SELECT TRIM(CAST(type AS STRING)) AS contract_type,
           TRIM(CAST(platform_name AS STRING)) AS platform_name,
           TRIM(CAST(platform AS STRING)) AS policy_keyfrom,
           TRIM(CAST(platform_5 AS STRING)) AS policy_authorid,
           TRIM(CAST(party_B AS STRING)) AS party_b,
           TRIM(CAST(contract_code AS STRING)) AS contract_code_raw,
           TRIM(CAST(ori_sign_date AS STRING)) AS ori_sign_date_raw,
           TRIM(CAST(is_normal AS STRING)) AS is_normal,
           TRIM(CAST(is_tmk AS STRING)) AS is_tmk,
           TRIM(CAST(is_bollte_allowance AS STRING)) AS is_bollte_allowance,
           TRIM(CAST(is_max_allowance AS STRING)) AS is_max_allowance,
           TRIM(CAST(is_ka AS STRING)) AS is_ka,
           CASE WHEN TRIM(COALESCE(CAST(deduction_amount AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(deduction_amount AS DECIMAL(28,8)) END AS deduction_amount,
           CASE WHEN TRIM(COALESCE(CAST(excluded_commission AS STRING),''))='' THEN CAST(0 AS DECIMAL(28,8))
                ELSE CAST(excluded_commission AS DECIMAL(28,8)) END AS excluded_commission
    FROM temp.channel_pay_regular WHERE type='双周'
),
w_policy_live_policy_normalized AS (
SELECT *,
           CASE WHEN platform_name='臻好（铭栎）'
                 AND contract_code_raw=CONCAT('BJ-YLJY-02-20260611-03068、',CHR(10),'BJ-YLJY-02-20260622-01949')
                THEN REPLACE(contract_code_raw,CHR(10),'') ELSE contract_code_raw END AS contract_code,
           CASE WHEN ori_sign_date_raw RLIKE '^[0-9]{4,6}$'
                THEN CONCAT(YEAR(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'年',
                            MONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'月',
                            DAYOFMONTH(DATE_ADD(TO_DATE('1899-12-30'),CAST(ori_sign_date_raw AS INT))),'日')
                WHEN ori_sign_date_raw RLIKE '^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日?$'
                THEN CONCAT(CAST(REGEXP_EXTRACT(ori_sign_date_raw,'^([0-9]{4})年',1) AS INT),'年',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'年([0-9]{1,2})月',1) AS INT),'月',
                            CAST(REGEXP_EXTRACT(ori_sign_date_raw,'月([0-9]{1,2})',1) AS INT),'日')
                ELSE ori_sign_date_raw END AS ori_sign_date,
           CASE WHEN policy_keyfrom NOT LIKE '%dyfx%' AND policy_keyfrom NOT LIKE '%-bmzx%'
                     AND policy_keyfrom NOT LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_normal_branch,
           CASE WHEN policy_keyfrom LIKE '%dyfx%' OR policy_keyfrom LIKE '%bmzx%'
                     OR policy_keyfrom LIKE 'yxzz-wx%' THEN 1 ELSE 0 END AS is_author_branch
    FROM w_policy_live_policy_raw
),
w_policy_frozen_effective AS (SELECT contract_type,platform_name,policy_keyfrom,policy_authorid,party_b,contract_code,ori_sign_date,is_normal,is_tmk,is_bollte_allowance,is_max_allowance,is_ka,deduction_amount,excluded_commission FROM w_policy_frozen_policy_normalized),
w_policy_live_effective AS (SELECT contract_type,platform_name,policy_keyfrom,policy_authorid,party_b,contract_code,ori_sign_date,is_normal,is_tmk,is_bollte_allowance,is_max_allowance,is_ka,deduction_amount,excluded_commission FROM w_policy_live_policy_normalized),
w_policy_missing AS (SELECT * FROM w_policy_frozen_effective EXCEPT ALL SELECT * FROM w_policy_live_effective),
w_policy_extra AS (SELECT * FROM w_policy_live_effective EXCEPT ALL SELECT * FROM w_policy_frozen_effective),
w_policy_counts AS (
SELECT (SELECT COUNT(*) FROM w_policy_frozen_effective) AS frozen_rows,
       (SELECT COUNT(*) FROM w_policy_live_effective) AS live_rows,
       (SELECT COUNT(*) FROM w_policy_missing) AS missing_rows,
       (SELECT COUNT(*) FROM w_policy_extra) AS extra_rows
),
w_source_keys_raw AS (
SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,CAST(a.order_id AS STRING) AS order_id
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da a
JOIN bs_cohort_windows w ON a.dt=w.snapshot_dt
 AND CAST(a.start_class_dt AS STRING)=w.source_cohort
WHERE a.dt='${date}'
UNION ALL
SELECT w.target_cohort,w.snapshot_dt,w.source_cohort,CAST(a.order_id AS STRING) AS order_id
FROM dw_conan_dwd.dwd_order_course_detail_bd_try_double_try_da a
JOIN bs_cohort_windows w ON a.dt=w.snapshot_dt
 AND CAST(a.start_class_dt AS STRING)=w.source_cohort
WHERE a.dt='${date}'
),
w_source_keys AS (
SELECT target_cohort,order_id,MAX(snapshot_dt) AS snapshot_dt,
       MAX(source_cohort) AS source_cohort,
       COUNT(DISTINCT snapshot_dt) AS snapshot_variants,
       COUNT(DISTINCT source_cohort) AS cohort_variants
FROM w_source_keys_raw GROUP BY target_cohort,order_id
),
w_input_keys AS (
SELECT CAST(target_cohort AS STRING) AS target_cohort,order_id,
       MAX(CAST(snapshot_dt AS STRING)) AS snapshot_dt,
       MAX(CAST(source_cohort AS STRING)) AS source_cohort,
       COUNT(*) AS input_rows,
       COUNT(DISTINCT snapshot_dt) AS snapshot_variants,
       COUNT(DISTINCT source_cohort) AS cohort_variants,
       SUM(CASE WHEN source_variant_count IS NULL OR source_variant_count<>1
                 OR policy_match_status IN ('pool_window_incomplete','pool_source_validation_failed',
                    'source_order_conflict','source_order_id_missing','source_order_status_invalid',
                    'source_renewal_invalid') THEN 1 ELSE 0 END) AS invalid_fact_rows
FROM bs_full35_input_present_raw GROUP BY target_cohort,order_id
),
w_source_coverage AS (
SELECT COUNT(*) AS checked_orders,
       COALESCE(SUM(CASE WHEN s.order_id IS NULL OR i.order_id IS NULL
              OR LOWER(TRIM(COALESCE(s.order_id,''))) IN ('','-1','-1.0','null','none','nan','@pipe_null@','__null__')
              OR s.snapshot_variants<>1 OR s.cohort_variants<>1
              OR i.input_rows<>1 OR i.snapshot_variants<>1 OR i.cohort_variants<>1
              OR i.invalid_fact_rows<>0 OR NOT(s.snapshot_dt <=> i.snapshot_dt)
              OR NOT(s.source_cohort <=> i.source_cohort)
              OR s.target_cohort NOT BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) OR s.snapshot_dt<>'${date}'
            THEN 1 ELSE 0 END),0) AS invalid_source_keys
FROM w_source_keys s FULL OUTER JOIN w_input_keys i
 ON s.target_cohort=i.target_cohort AND s.order_id=i.order_id
),
w_target_source_coverage AS (
SELECT COUNT(*) AS scope_orders,
       COALESCE(SUM(CASE WHEN s.order_id IS NULL OR s.source_cohort<>t.start_class_dt
             OR s.snapshot_dt<>'${date}' THEN 1 ELSE 0 END),0) AS missing_target_facts
FROM w00_scope_keys t LEFT JOIN w_source_keys s
 ON t.order_id=s.order_id AND t.start_class_dt=s.target_cohort
),
w_window_checks AS (
SELECT COUNT(*) AS target_n,SUM(windows_n) AS windows_n,MIN(ok) AS all_windows_ok
FROM (
 SELECT target_cohort,COUNT(*) AS windows_n,
 CASE WHEN COUNT(*)=4 AND COUNT(DISTINCT source_cohort)=4
       AND COUNT(DISTINCT snapshot_dt)=1 AND MAX(snapshot_dt)='${date}'
       AND SUM(CASE WHEN target_cohort NOT BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
                 OR source_cohort>target_cohort OR DATE_ADD(TO_DATE(source_cohort),7)>TO_DATE('${date}')
                 THEN 1 ELSE 0 END)=0 THEN 1 ELSE 0 END AS ok
 FROM bs_cohort_windows GROUP BY target_cohort
) x
),
w_source_presence AS (
SELECT COUNT(*) AS target_n,MIN(CASE WHEN present_cohorts=4 THEN 1 ELSE 0 END) AS all_present
FROM (SELECT target_cohort,COUNT(DISTINCT source_cohort) AS present_cohorts
      FROM w_source_keys GROUP BY target_cohort) x
),
w_daily_prev_partition AS (
SELECT MAX(dt) AS prev_dt FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da
WHERE dt>='2026-10-18' AND dt<'${date}'
),
w_daily_prev_check AS (
SELECT p.prev_dt,COUNT(h.order_id) AS prev_rows,
       COUNT(DISTINCT h.start_class_dt) AS prev_cohorts,
       COALESCE(SUM(CASE WHEN h.order_id IS NULL OR h.start_class_dt IS NULL
          OR h.calculation_version IS NULL
          OR h.calculation_version NOT IN ('biz1-cpa-window30-backfill-20261018-v1','biz1-cpa-daily-window30-transfer-v2-20261022')
          OR h.fact_snapshot_dt IS NULL OR h.fact_snapshot_dt>p.prev_dt
          OR (p.prev_dt='2026-10-18' AND
              (h.calculation_version<>'biz1-cpa-window30-backfill-20261018-v1' OR h.fact_snapshot_dt<>'2026-10-18'))
          THEN 1 ELSE 0 END),0) AS bad_rows,
       CASE WHEN p.prev_dt=CAST(DATE_SUB(TO_DATE('${date}'),1) AS STRING)
            OR (p.prev_dt='2026-10-18' AND '${date}' BETWEEN '2026-10-19' AND '2026-10-25')
            THEN 1 ELSE 0 END AS continuity_ok
FROM w_daily_prev_partition p LEFT JOIN dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h ON h.dt=p.prev_dt
GROUP BY p.prev_dt
),
w_identity_current AS (
SELECT CAST(order_id AS STRING) AS order_id,
       MIN(CAST(start_class_dt AS STRING)) AS start_class_dt,
       COUNT(DISTINCT CAST(start_class_dt AS STRING)) AS cohort_n,
       SUM(CASE WHEN start_class_dt IS NULL OR TO_DATE(start_class_dt) IS NULL
            OR CAST(TO_DATE(start_class_dt) AS STRING)<>CAST(start_class_dt AS STRING)
            OR DAYOFWEEK(TO_DATE(start_class_dt))<>2 THEN 1 ELSE 0 END) AS bad_dates
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da WHERE dt='${date}' GROUP BY CAST(order_id AS STRING)
),
w_identity_previous AS (
SELECT CAST(a.order_id AS STRING) AS order_id,
       MIN(CAST(a.start_class_dt AS STRING)) AS start_class_dt,
       COUNT(DISTINCT CAST(a.start_class_dt AS STRING)) AS cohort_n,
       SUM(CASE WHEN a.start_class_dt IS NULL OR TO_DATE(a.start_class_dt) IS NULL
            OR CAST(TO_DATE(a.start_class_dt) AS STRING)<>CAST(a.start_class_dt AS STRING)
            OR DAYOFWEEK(TO_DATE(a.start_class_dt))<>2 THEN 1 ELSE 0 END) AS bad_dates
FROM dw_conan_dwd.dwd_order_course_detail_try_double_try_da a CROSS JOIN w_daily_prev_partition p
WHERE a.dt=p.prev_dt GROUP BY CAST(a.order_id AS STRING)
),
w_previous_all_keys AS (
SELECT CAST(h.order_id AS STRING) AS order_id,MIN(CAST(h.start_class_dt AS STRING)) AS start_class_dt,
       COUNT(*) AS n
FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h CROSS JOIN w_daily_prev_partition p
WHERE h.dt=p.prev_dt GROUP BY CAST(h.order_id AS STRING)
),
w_transfer_evidence AS (
SELECT p.order_id,p.start_class_dt AS old_cohort,c.start_class_dt AS new_cohort,
       CASE WHEN p.n<>1 OR c.order_id IS NULL OR c.cohort_n<>1 OR c.bad_dates<>0
         OR c.start_class_dt<'2026-01-05'
         OR o.order_id IS NULL OR o.cohort_n<>1 OR o.bad_dates<>0
         OR o.start_class_dt<>p.start_class_dt THEN 1 ELSE 0 END AS bad_evidence
FROM w_previous_all_keys p LEFT JOIN w_identity_current c ON p.order_id=c.order_id
LEFT JOIN w_identity_previous o ON p.order_id=o.order_id
),
w_transfer_checks AS (
SELECT COUNT(*) AS checked_orders,
       COALESCE(SUM(bad_evidence),0) AS bad_evidence,
       COALESCE(SUM(CASE WHEN old_cohort<>new_cohort THEN 1 ELSE 0 END),0) AS moved_orders,
       COALESCE(SUM(CASE WHEN old_cohort<>new_cohort AND new_cohort>CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
                       THEN 1 ELSE 0 END),0) AS moved_to_unclosed
FROM w_transfer_evidence
),
w_refresh_prev_keys AS (
SELECT CAST(h.start_class_dt AS STRING) AS start_class_dt,
       CAST(h.order_id AS STRING) AS order_id,COUNT(*) AS n
FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h CROSS JOIN w_daily_prev_partition p
WHERE h.dt=p.prev_dt AND h.start_class_dt BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
GROUP BY h.start_class_dt,h.order_id
),
w_refresh_current_keys AS (
SELECT c.* FROM w00_scope_keys c CROSS JOIN w_daily_prev_partition p
WHERE c.start_class_dt<=CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE(p.prev_dt),7)) AS DATE) AS STRING)
),
w_refresh_key_check AS (
SELECT COUNT(*) AS compared_keys,
       COALESCE(SUM(CASE
          WHEN p.order_id IS NOT NULL AND (p.n<>1 OR i.order_id IS NULL
               OR i.cohort_n<>1 OR i.bad_dates<>0) THEN 1
          WHEN p.order_id IS NOT NULL AND c.order_id IS NULL
               AND i.start_class_dt=p.start_class_dt THEN 1
          WHEN c.order_id IS NOT NULL AND p.order_id IS NULL
               AND (o.order_id IS NULL OR o.cohort_n<>1 OR o.bad_dates<>0
                    OR (o.start_class_dt=c.start_class_dt
                        -- BOOTSTRAP: newest cohort may not exist in yesterday's partition yet.
                        AND c.start_class_dt<>CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE(dp.prev_dt),7)) AS DATE) AS STRING))) THEN 1
          WHEN c.order_id IS NOT NULL AND (i.order_id IS NULL OR i.cohort_n<>1
               OR i.bad_dates<>0 OR i.start_class_dt<>c.start_class_dt) THEN 1
          ELSE 0 END),0) AS bad_keys
FROM w_refresh_prev_keys p FULL OUTER JOIN w_refresh_current_keys c ON p.order_id=c.order_id
CROSS JOIN w_daily_prev_partition dp
LEFT JOIN w_identity_current i ON COALESCE(p.order_id,c.order_id)=i.order_id
LEFT JOIN w_identity_previous o ON COALESCE(p.order_id,c.order_id)=o.order_id
),
w_daily_guard AS (
SELECT CASE WHEN COALESCE('${date}' RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       AND CAST(TO_DATE('${date}') AS STRING)='${date}',FALSE)
       AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)>='2026-10-05' AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)<='2026-11-16'
       AND v.frozen_rows=173 AND v.live_rows=173 AND v.missing_rows=0 AND v.extra_rows=0
       AND c.target_n BETWEEN 1 AND 5 AND c.latest_target<=CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AND c.bad_cohort_dates=0
       AND c.expected_orders>0 AND c.expected_orders=c.unique_expected_orders AND c.invalid_scope_orders=0
       AND w.target_n=c.target_n AND w.windows_n=4*c.target_n AND w.all_windows_ok=1
       AND p.target_n=c.target_n AND p.all_present=1
       AND k.checked_orders>0 AND k.invalid_source_keys=0
       AND t.scope_orders=c.expected_orders AND t.missing_target_facts=0
       AND j.bad_keys=0 AND tr.checked_orders=z.prev_rows AND tr.bad_evidence=0
       AND z.continuity_ok=1 AND z.prev_rows>0 AND z.bad_rows=0
       AND (z.prev_dt<>'2026-10-18' OR (z.prev_rows=656968 AND z.prev_cohorts=36))
       THEN TRUE ELSE FALSE END AS allowed
FROM (SELECT COUNT(*) AS target_n,MAX(target_cohort) AS latest_target,
             SUM(expected_orders) AS expected_orders,SUM(unique_expected_orders) AS unique_expected_orders,
             SUM(invalid_scope_orders) AS invalid_scope_orders,
SUM(CASE WHEN DAYOFWEEK(TO_DATE(target_cohort))<>2 THEN 1 ELSE 0 END) AS bad_cohort_dates
FROM n00_target_calendar) c
CROSS JOIN w_window_checks w CROSS JOIN w_source_presence p CROSS JOIN w_source_coverage k
CROSS JOIN w_target_source_coverage t CROSS JOIN w_policy_counts v CROSS JOIN w_refresh_key_check j

CROSS JOIN w_daily_prev_check z

CROSS JOIN w_transfer_checks tr
),
fs_current_rows AS (
SELECT
CASE WHEN g.allowed AND f.start_class_dt BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AND s.target_rows>0 AND s.target_rows=s.unique_target_orders AND s.invalid_target_rows=0
AND s.target_rows=c.expected_orders
AND r.readiness_rows=c.planned_cohorts AND r.all_ready=1
AND i.checked_cohorts=c.planned_cohorts AND i.all_input_ready=1
AND f.prewrite_error_rows=0
AND f.final_rows=s.target_rows AND f.order_id_rows=1 AND f.final_cohort_rows=f.expected_cohort_rows
AND f.order_id IS NOT NULL AND f.scope_order_id IS NOT NULL AND f.start_class_dt IS NOT NULL
AND (f.skill_estimated_settlement_amount IS NULL OR f.estimated_tax_rate IS NOT NULL)
AND (f.actual_settlement_amount IS NULL OR f.actual_tax_rate IS NOT NULL) THEN f.order_id
ELSE CAST(assert_true(COALESCE((g.allowed AND f.start_class_dt BETWEEN GREATEST('2026-09-14',CAST(DATE_SUB(TO_DATE('${date}'),35) AS STRING)) AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AND s.target_rows>0 AND s.target_rows=s.unique_target_orders AND s.invalid_target_rows=0
AND s.target_rows=c.expected_orders
AND r.readiness_rows=c.planned_cohorts AND r.all_ready=1
AND i.checked_cohorts=c.planned_cohorts AND i.all_input_ready=1
AND f.prewrite_error_rows=0
AND f.final_rows=s.target_rows AND f.order_id_rows=1 AND f.final_cohort_rows=f.expected_cohort_rows
AND f.order_id IS NOT NULL AND f.scope_order_id IS NOT NULL AND f.start_class_dt IS NOT NULL
AND (f.skill_estimated_settlement_amount IS NULL OR f.estimated_tax_rate IS NOT NULL)
AND (f.actual_settlement_amount IS NULL OR f.actual_tax_rate IS NOT NULL)),FALSE)) AS STRING) END AS order_id,
CAST(f.`order_status` AS string) AS `order_status`,
CAST(f.`skill_estimated_settlement_amount` AS decimal(28,8)) AS `skill_estimated_settlement_amount`,
CAST(f.`actual_settlement_amount` AS decimal(28,8)) AS `actual_settlement_amount`,
CAST(f.`subject_name` AS string) AS `subject_name`,
CAST(f.`parent_order_id` AS string) AS `parent_order_id`,
CAST(f.`purchase_group` AS string) AS `purchase_group`,
CAST(f.`estimated_cost_source` AS string) AS `estimated_cost_source`,
CAST(f.`estimated_cost_gross` AS decimal(28,8)) AS `estimated_cost_gross`,
CAST(f.`actual_cost_gross` AS decimal(28,8)) AS `actual_cost_gross`,
CAST(f.`estimated_tax_rate` AS decimal(10,6)) AS `estimated_tax_rate`,
CAST(f.`actual_tax_rate` AS decimal(10,6)) AS `actual_tax_rate`,
CAST(f.`estimated_cost_status` AS string) AS `estimated_cost_status`,
CAST(f.`actual_cost_status` AS string) AS `actual_cost_status`,
CAST(f.`bill_id` AS string) AS `bill_id`,
CAST(f.`tax_rate_source` AS string) AS `tax_rate_source`,
CAST(f.`fact_snapshot_dt` AS string) AS `fact_snapshot_dt`,
CAST(f.`calculation_version` AS string) AS `calculation_version`,
CAST(f.start_class_dt AS STRING) AS start_class_dt
FROM w_daily_guard g CROSS JOIN bs_native_calendar_counts c CROSS JOIN bs_native_scope_counts s
CROSS JOIN bs_native_readiness_counts r CROSS JOIN bs_native_input_counts i
LEFT JOIN bs_native_checked_rows f ON TRUE
),
fs_params AS (
SELECT '${date}' AS snapshot_dt,CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING) AS target_cohort,p.prev_dt,
       CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE(p.prev_dt),7)) AS DATE) AS STRING) AS prev_target_cohort
FROM w_daily_prev_partition p
),
fs_base_rows AS (
SELECT h.`order_id`,
       h.`order_status`,
       h.`skill_estimated_settlement_amount`,
       h.`actual_settlement_amount`,
       h.`subject_name`,
       h.`parent_order_id`,
       h.`purchase_group`,
       h.`estimated_cost_source`,
       h.`estimated_cost_gross`,
       h.`actual_cost_gross`,
       h.`estimated_tax_rate`,
       h.`actual_tax_rate`,
       h.`estimated_cost_status`,
       h.`actual_cost_status`,
       h.`bill_id`,
       h.`tax_rate_source`,
       h.`fact_snapshot_dt`,
       h.`calculation_version`,
       h.`start_class_dt`,
        SHA2(TO_JSON(NAMED_STRUCT('order_id',h.`order_id`,'order_status',h.`order_status`,'skill_estimated_settlement_amount',h.`skill_estimated_settlement_amount`,'actual_settlement_amount',h.`actual_settlement_amount`,'subject_name',h.`subject_name`,'parent_order_id',h.`parent_order_id`,'purchase_group',h.`purchase_group`,'estimated_cost_source',h.`estimated_cost_source`,'estimated_cost_gross',h.`estimated_cost_gross`,'actual_cost_gross',h.`actual_cost_gross`,'estimated_tax_rate',h.`estimated_tax_rate`,'actual_tax_rate',h.`actual_tax_rate`,'estimated_cost_status',h.`estimated_cost_status`,'actual_cost_status',h.`actual_cost_status`,'bill_id',h.`bill_id`,'tax_rate_source',h.`tax_rate_source`,'fact_snapshot_dt',h.`fact_snapshot_dt`,'calculation_version',h.`calculation_version`,'start_class_dt',h.`start_class_dt`),MAP('ignoreNullFields','false')),256) AS row_sha
 FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h
 WHERE h.dt='2026-10-18' AND h.start_class_dt<'2026-10-05'
),
fs_prev_rows AS (
SELECT h.`order_id`,
       h.`order_status`,
       h.`skill_estimated_settlement_amount`,
       h.`actual_settlement_amount`,
       h.`subject_name`,
       h.`parent_order_id`,
       h.`purchase_group`,
       h.`estimated_cost_source`,
       h.`estimated_cost_gross`,
       h.`actual_cost_gross`,
       h.`estimated_tax_rate`,
       h.`actual_tax_rate`,
       h.`estimated_cost_status`,
       h.`actual_cost_status`,
       h.`bill_id`,
       h.`tax_rate_source`,
       h.`fact_snapshot_dt`,
       h.`calculation_version`,
       h.`start_class_dt`
 FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da h
 WHERE h.dt=(SELECT prev_dt FROM w_daily_prev_partition)
),
fs_prev_shape AS (
SELECT COUNT(*) AS prev_rows,
        COALESCE(SUM(CASE WHEN h.start_class_dt IS NULL
          OR TO_DATE(h.start_class_dt) IS NULL
          OR h.start_class_dt>p.prev_target_cohort OR DAYOFWEEK(TO_DATE(h.start_class_dt))<>2
          OR h.order_id IS NULL
          OR LOWER(TRIM(h.order_id)) IN
             ('','-1','-1.0','null','none','nan','@pipe_null@','__null__',CONCAT(CHR(92),'n'))
          THEN 1 ELSE 0 END),0) AS bad_rows
 FROM fs_prev_rows h CROSS JOIN fs_params p
),
fs_history_rows AS (
-- Replace every selected recent cohort; carry older rows without changing any field.
 SELECT h.`order_id`,
       h.`order_status`,
       h.`skill_estimated_settlement_amount`,
       h.`actual_settlement_amount`,
       h.`subject_name`,
       h.`parent_order_id`,
       h.`purchase_group`,
       h.`estimated_cost_source`,
       h.`estimated_cost_gross`,
       h.`actual_cost_gross`,
       h.`estimated_tax_rate`,
       h.`actual_tax_rate`,
       h.`estimated_cost_status`,
       h.`actual_cost_status`,
       h.`bill_id`,
       h.`tax_rate_source`,
       h.`fact_snapshot_dt`,
       h.`calculation_version`,
       h.`start_class_dt`
 FROM fs_prev_rows h CROSS JOIN fs_params p
JOIN w_identity_current a ON h.order_id=a.order_id AND h.start_class_dt=a.start_class_dt
 AND a.cohort_n=1 AND a.bad_dates=0
 WHERE h.start_class_dt NOT IN (SELECT target_cohort FROM n00_target_calendar)
),
fs_base_stats AS (
 SELECT start_class_dt,COUNT(*) AS n,COUNT(DISTINCT order_id) AS unique_n,
        SUM(CAST(CONV(SUBSTR(row_sha,1,16),16,10) AS DECIMAL(38,0))) AS hash_a,
        SUM(CAST(CONV(SUBSTR(row_sha,17,16),16,10) AS DECIMAL(38,0))) AS hash_b,
        MIN(row_sha) AS hash_min,MAX(row_sha) AS hash_max
 FROM fs_base_rows
 GROUP BY start_class_dt
),
fs_base_shape AS (
 SELECT COUNT(*) AS baseline_cohorts,COALESCE(SUM(n),0) AS baseline_rows,
        COALESCE(SUM(CASE WHEN start_class_dt IS NULL
           OR start_class_dt>='2026-10-05' OR n<>unique_n OR n<=0
           THEN 1 ELSE 0 END),0) AS bad_baseline_cohorts
 FROM fs_base_stats
),
fs_previous_source_keys AS (
SELECT a.order_id,a.start_class_dt,a.cohort_n,a.bad_dates
FROM w_identity_previous a CROSS JOIN fs_params p
WHERE a.start_class_dt BETWEEN '2026-01-05' AND p.prev_target_cohort
),
fs_previous_result_keys AS (
SELECT order_id,start_class_dt,COUNT(*) AS n FROM fs_prev_rows GROUP BY order_id,start_class_dt
),
fs_previous_key_check AS (
SELECT COUNT(p.order_id) AS compared_keys,COALESCE(SUM(CASE
 WHEN a.order_id IS NULL
   -- BOOTSTRAP: newest cohort may not exist in yesterday's partition yet.
   OR (p.order_id IS NULL AND a.start_class_dt<>fp.prev_target_cohort)
   OR a.cohort_n<>1 OR a.bad_dates<>0 OR p.n<>1
 THEN 1 ELSE 0 END),0) AS bad_keys
FROM fs_previous_source_keys a FULL OUTER JOIN fs_previous_result_keys p
ON a.order_id=p.order_id AND a.start_class_dt=p.start_class_dt
CROSS JOIN fs_params fp
),
fs_current_source_keys AS (
SELECT order_id,start_class_dt,cohort_n,bad_dates FROM w_identity_current
WHERE start_class_dt BETWEEN '2026-01-05' AND CAST(CAST(DATE_TRUNC('WEEK',DATE_SUB(TO_DATE('${date}'),7)) AS DATE) AS STRING)
),
fs_planned_keys_raw AS (
SELECT order_id,start_class_dt FROM fs_history_rows
UNION ALL SELECT order_id,start_class_dt FROM w00_scope_keys
),
fs_planned_keys AS (
SELECT order_id,start_class_dt,COUNT(*) AS n FROM fs_planned_keys_raw GROUP BY order_id,start_class_dt
),
fs_current_key_check AS (
SELECT COUNT(*) AS compared_keys,COALESCE(SUM(CASE
 WHEN a.order_id IS NULL OR p.order_id IS NULL OR a.cohort_n<>1 OR a.bad_dates<>0 OR p.n<>1
 THEN 1 ELSE 0 END),0) AS bad_keys
FROM fs_current_source_keys a FULL OUTER JOIN fs_planned_keys p
ON a.order_id=p.order_id AND a.start_class_dt=p.start_class_dt
),
fs_fixed_expected AS (
SELECT h.order_id,h.start_class_dt,h.row_sha FROM fs_base_rows h
JOIN w_identity_previous a ON h.order_id=a.order_id AND h.start_class_dt=a.start_class_dt
WHERE h.start_class_dt<'2026-09-14' AND a.cohort_n=1 AND a.bad_dates=0
),
fs_fixed_carried AS (
SELECT h.order_id,h.start_class_dt,SHA2(TO_JSON(NAMED_STRUCT('order_id',h.`order_id`,'order_status',h.`order_status`,'skill_estimated_settlement_amount',h.`skill_estimated_settlement_amount`,'actual_settlement_amount',h.`actual_settlement_amount`,'subject_name',h.`subject_name`,'parent_order_id',h.`parent_order_id`,'purchase_group',h.`purchase_group`,'estimated_cost_source',h.`estimated_cost_source`,'estimated_cost_gross',h.`estimated_cost_gross`,'actual_cost_gross',h.`actual_cost_gross`,'estimated_tax_rate',h.`estimated_tax_rate`,'actual_tax_rate',h.`actual_tax_rate`,'estimated_cost_status',h.`estimated_cost_status`,'actual_cost_status',h.`actual_cost_status`,'bill_id',h.`bill_id`,'tax_rate_source',h.`tax_rate_source`,'fact_snapshot_dt',h.`fact_snapshot_dt`,'calculation_version',h.`calculation_version`,'start_class_dt',h.`start_class_dt`),MAP('ignoreNullFields','false')),256) AS row_sha
FROM fs_prev_rows h WHERE h.start_class_dt<'2026-09-14'
),
fs_fixed_missing AS (SELECT * FROM fs_fixed_expected EXCEPT ALL SELECT * FROM fs_fixed_carried),
fs_fixed_extra AS (SELECT * FROM fs_fixed_carried EXCEPT ALL SELECT * FROM fs_fixed_expected),
fs_fixed_check AS (
SELECT (SELECT COUNT(*) FROM fs_fixed_missing)+(SELECT COUNT(*) FROM fs_fixed_extra) AS bad_rows
),
fs_target_existing_cohorts AS (
 -- Dynamic overwrite does not remove unexpected partitions omitted by this run.
 SELECT DISTINCT CAST(start_class_dt AS STRING) AS start_class_dt
 FROM dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da WHERE dt='${date}'
),
fs_allowed_cohorts AS (
SELECT DISTINCT start_class_dt FROM fs_current_source_keys
),
fs_target_shape AS (
 SELECT COALESCE(SUM(CASE WHEN a.start_class_dt IS NULL THEN 1 ELSE 0 END),0)
        AS unexpected_existing_target_cohorts
 FROM fs_target_existing_cohorts t LEFT JOIN fs_allowed_cohorts a
   ON t.start_class_dt=a.start_class_dt
),
fs_backfill_expected AS (
 SELECT start_class_dt,CAST(n AS BIGINT) n,
        CAST(hash_a AS DECIMAL(38,0)) hash_a,CAST(hash_b AS DECIMAL(38,0)) hash_b,
        hash_min,hash_max
 FROM VALUES
 ('2026-01-05','11093','102629143928896641627789','102760006649998415102028','0007b7f2d41cbd92419c1c87fb6e0453dbb790e5cce121f334d7d3781c06f94e','fffb90676cccefd0259b1c171a26c983e4d6086d9d7fd8259e414ab1c840c9a0'),
 ('2026-01-12','13814','127994466161968921447035','126603204366512743445373','00045960ca3354cb5b68a3d12ad69baed5c8299935358ab02f8fd1a60978a333','fff9e1e2a16c7fba2164fcce90f11d72e401353a9fa9e0a8ed32b323fe5b6a23'),
 ('2026-01-19','14619','135281114481030147870356','135346247238804932600720','00006fd6859d2ef8048a641dec0db7a48a79361e4aeaf8499d1d55dce7e41792','fffd7e284ef23aab32ac57f226137c4b1fa9f04b93a790030c32a033c5a6b821'),
 ('2026-01-26','14955','137719789833403877715810','138040521738535830517559','000a0f916e50b2f4236c1db3114ba3f3e5399356029568f642edb6b83c74b049','fffea264cafedc30fc50594b520cd32aaa9eb743f8bbbd78e3688169775e328c'),
 ('2026-02-02','14253','131852291829743012988300','130806611929962147803549','0009d11ba24ff8c09a2647db8028d71579f2d0d6fcc460b9e6e37daa91d2edb2','ffff019ffe225bd41292c866d352cd09c3bf5cdcc3f508fc1d90931014b5b449'),
 ('2026-02-23','13767','126972583423854073546787','125558126524231391133341','00036cb5c2490ec3f3f90c2b83971eb12e087f2ced49b3bd5ecd063e36cf51a8','fffe473d83aef16d88796bdaf5f307a1df28bba5266f3a3727abb4e904798ee3'),
 ('2026-03-02','14792','135777884422035242187168','137309461828795837315284','00035d1b728b848178024f2b73a3c1b58d9aa73a989e8acc341b323fa9fabf4b','ffffbd7394835f60bdc1dc34684509d80e46feb019df5c9d6f57945be55fa061'),
 ('2026-03-09','16080','148095097421727027357523','147796676077596970907360','000050c68b9bc46706270d9336b2e1a4b01a3611c5287f5d4aa6bfd432d9ac87','fffb5947c56e860d27b6d57c4e2d9160a8ccec86e52c7c9ed5d96e37a4b62ce5'),
 ('2026-03-16','17402','160700634201556917049841','161157506547321676306878','00000ef704afa35c7d52ec21b43c8b67284e1c6a7daa75d04726b80bc175ab78','fff7de8f78f32a4c622f9895a7c1feb0a9f5a8dd1172c10e70582e7b49c919d3'),
 ('2026-03-23','19813','183146907366827055031897','182274600158723852112020','000700237b54a9a0d06debfb3987d56e06e31c250693bdf486434d62a68ca82b','fffb30db0957b71cc22f8eb7a591327e6598e5dcaad3be56ecf23ed7b4f8859c'),
 ('2026-03-30','20503','189738993963316015959130','189288337895034859273861','000cc8e5704ae7496db56063d51ddc6df52098b1c6e3b99e4d05692583922378','fffe26865c907b5289602d37b277e254b411e9984809fba9fcbee49067b20c0b'),
 ('2026-04-06','19516','178430786333417609915350','181319394794578814287974','0005f24f1e525b64a6ec8531f3992b88c7c7a4b960c5d941467ae6f546f8a5de','fffd80f01999e42f061691d006239fea5ff2afde4ffbb41d9942762854eeb65b'),
 ('2026-04-13','22803','210379326565742724546050','211463144461947992673260','000173bfc2f3c2eb6d914ec47382e9aa949a6342f3bbc23c38efb96b592c1675','ffffc7d193173943ae3f665c54466c9520c5bbc765d676561026553ad9ddcdc3'),
 ('2026-04-20','21809','201668648210248936763081','200390977040048770309534','00048b392422f7afc0456b449b8c9a2c64c6759154d8f86436b161739dda4ad6','fffcf23d8b805479f9b98bed2687b2290bb77f84eb03224b1097a61b74655c56'),
 ('2026-04-27','18385','169279313791018279036211','169264284382867769013806','0009a22983b6e467284776c9d748d2a84dfa0f42643ec944ff9622602fd5ebcb','fff1d2b649bab41d20306f4550eb6cc4c0c18c7492a916c5e90b697a3e1bc1d6'),
 ('2026-05-11','25570','235911798427812332450364','235419696852502257251728','0002a00dd094929130f9c8fd4d4d1d99ae65016b05217044ae7ca461e81b1828','ffff5fd9386973449ddd994603a6033c63f33e9f3b73371a07464e81f79e73fd'),
 ('2026-05-18','21170','195282531034788328677248','195179125386916336021929','00020d5a985b3acf7ab0c86b708482ba06a77402edf7d4bed88dbc8715359baa','fff944d055d24945f8c624939beb2ed1cd3cbb5e8b84277b266e6e708f0dd07b'),
 ('2026-05-25','18778','172670738435439622540582','172531847202792030659490','0000b111c92800afcb960d1d10102106817da4d36665566095952f3af41a65b1','fffefd6d993958f0a829e8ca746cf3762403e797cf64004e9b02689901d73794'),
 ('2026-06-01','18988','175511960243160584104952','175157258081001537077904','000518dd7461950b20bbc7135209f5565bf731226bc3653c1f350a12e104ab58','fffd960e4ce3db6937a6f525409d29318d5ed37921b2fd06b89a369c0ef3146e'),
 ('2026-06-08','16568','152303952867922068966950','152905187115067668745804','0002ec0f22fc60a5456025870bbf8def6b1846f31d0398ba73c22e3cd4367095','fffefced549f228061b0ee22a8ff7486e4581c9d423d9f6e91ee048a4ffab0af'),
 ('2026-06-15','18208','167321285902064860234501','168559811042232609324530','0004ff28943a3ee2198b85af868c9c9a6fe416eacab0de4152d0ec6b3cefb2a4','fffaee2d12d66eac26b6379bbcefd0a8e2498aef97b71935a4ba3e3222148642'),
 ('2026-06-22','20022','183775147316053567152901','185034768517595802174018','0003c6aafe77763bafad46913d899972596d58a2f7d1d50d94d1ee03df006416','ffff4dfe748163f20f730b8d3df12c5c220733728b7550300dabacd0b9f61cc9'),
 ('2026-06-29','19765','181389583224198927307306','182657221994688391464161','00028add257c488520f77ecb3672d6a1d4968989202000a08daa7f9aff49ef0c','fffc6ee6ed0361e2ad99bce9f7841674f2f5ad76b2bd2b752add3b8e9ea9b484'),
 ('2026-07-06','18093','167084239451437294664083','167204785809162721127450','000338b552b85ce42a265ae64cf53d4c40a2f9ef59709df3879b98e9b0850461','fffed557b54221cf89cf76540d901601f4ec040c6389e9a4d798db2caeb0706f'),
 ('2026-07-13','16933','156689555303552675839947','156822217227474819202739','00018a6481039a8627039312e3771b194cc0cdbe716342d6b39e50a2bb5d8994','fff79ea38d27251e3ed30439074a4719e04bc74dd62af9630f585fbff1fe2c25'),
 ('2026-07-20','17347','160626611694851193960039','161243293730645634293038','000854cf848e1fae07cd6d3bf7161d8ad86fef36433b82498ee9e40f33e99a4d','fff6a20ea8d18596fa0cbc0c25b0426dbfe9484af8f0971c6d1e97c34c8d140b'),
 ('2026-07-27','17414','160990614396795405700325','161282649070183368390185','00052b431a0c1057bca176cd8c9af656bbbfcbb308d03ada93d25564292578ff','ffff8c378009e27515420f8e906fc85a5ac2aa2cf858319de76f192f6366ab49'),
 ('2026-08-03','15622','142515651957640383272723','145132967451899214132788','00005530d9c1228fd6ee72d07b8022823a6cf2c890e7f9e2520b699e3796b07b','ffffd612db7f7416968c85084fa1c0a6ca46f233e982ac2432d524ce442182a3'),
 ('2026-08-10','15013','138907882010014379451233','139562633018376553348818','000122f4e2896f48909e457d0ec54f9866ac069931c4903b18291f43694fef7e','fffbbe22300d3a80973f50f21fa1433b5aab903376917e3f97e0435d7505cb63'),
 ('2026-08-17','15972','147734791429564043636371','146500213282343193077858','000aa4992dac677d997707e447b6485adece20da841d1ea3f5680ce335d95df1','fffdd4d5071c38d62c117a25572605143af718500e8d2fee67f996f35f6d54dd'),
 ('2026-08-24','15524','142967294025644841009845','142481074795474013450878','00012b9736b6e21dc4d9bd51b50b750489756a72a006cf0080870ffc9c71ecbd','ffff37cb4bd0b766969440b8004bc183ad6bb31f8bbaa4ad050947cdd307f27c'),
 ('2026-08-31','17075','157003602572677272783143','157382759210217579922359','0006fb4ccb849e54d6badb2c8a55e940c8d26ec0f3abc5d8fdd2bac2bb07a418','fffb0633a01d26df7ba13a7e78ea1c3cc516c842bf11eb9d286ef750709ad4e5'),
 ('2026-09-07','22604','208742161837884303281829','208923954553129678341251','00012d20a2d5905d7cbd6030a79cb40966fe0aeb71911a69b51c2c01475324e0','fffd7fe85dfb9325b6e1ca9d1d6c0a80d9ec0546b86440635ffa85aabe7350f3'),
 ('2026-09-14','21334','197096699924951016051198','196616523737609401898262','0002bd11246aaeac23763fc8f5f8ac3076af528d7c611b6167a2b550ebda1f73','fffd173bc5f6eec9c9327937e3be70865e6b79d700870acd1890863e9ca9d1d7'),
 ('2026-09-21','23906','221687110328504092794424','221932981048690779126627','0001911ac864d2d5c41705ca0366af672f275e286b71d65a3784b6d4b7556d1f','ffff33f3ff7608f03a1ff2e62d64e58763d900a304389fe1a3e8f24f9953378b')
 AS t(start_class_dt,n,hash_a,hash_b,hash_min,hash_max)
),
fs_backfill_comparison AS (
 SELECT COUNT(*) compared_cohorts,
        SUM(CASE WHEN e.start_class_dt IS NULL OR a.start_class_dt IS NULL
             OR NOT(e.n <=> a.n) OR a.n<>a.unique_n
             OR NOT(e.hash_a <=> a.hash_a) OR NOT(e.hash_b <=> a.hash_b)
             OR NOT(e.hash_min <=> a.hash_min) OR NOT(e.hash_max <=> a.hash_max)
             THEN 1 ELSE 0 END) bad_baseline_cohorts
 FROM fs_backfill_expected e FULL OUTER JOIN fs_base_stats a
 ON e.start_class_dt=a.start_class_dt
),
fs_bootstrap_last_rows AS (
SELECT h.order_id,SHA2(TO_JSON(NAMED_STRUCT('order_id',h.`order_id`,'order_status',h.`order_status`,'skill_estimated_settlement_amount',h.`skill_estimated_settlement_amount`,'actual_settlement_amount',h.`actual_settlement_amount`,'subject_name',h.`subject_name`,'parent_order_id',h.`parent_order_id`,'purchase_group',h.`purchase_group`,'estimated_cost_source',h.`estimated_cost_source`,'estimated_cost_gross',h.`estimated_cost_gross`,'actual_cost_gross',h.`actual_cost_gross`,'estimated_tax_rate',h.`estimated_tax_rate`,'actual_tax_rate',h.`actual_tax_rate`,'estimated_cost_status',h.`estimated_cost_status`,'actual_cost_status',h.`actual_cost_status`,'bill_id',h.`bill_id`,'tax_rate_source',h.`tax_rate_source`,'fact_snapshot_dt',h.`fact_snapshot_dt`,'calculation_version',h.`calculation_version`,'start_class_dt',h.`start_class_dt`),MAP('ignoreNullFields','false')),256) AS row_sha
FROM fs_prev_rows h CROSS JOIN fs_params p
WHERE p.prev_dt='2026-10-18' AND h.start_class_dt='2026-10-05'
),
fs_bootstrap_last_check AS (
SELECT CASE WHEN COUNT(*)=27458 AND COUNT(DISTINCT order_id)=27458
AND SUM(CAST(CONV(SUBSTR(row_sha,1,16),16,10) AS DECIMAL(38,0)))=CAST('254026656096580408965914' AS DECIMAL(38,0))
AND SUM(CAST(CONV(SUBSTR(row_sha,17,16),16,10) AS DECIMAL(38,0)))=CAST('251027725738097248150981' AS DECIMAL(38,0))
AND MIN(row_sha)='0002c02e43ea64d2faa933898ce280a35a699749721d46e2a0211126916f8c04' AND MAX(row_sha)='fffff49ebb444f9036fd859446dc0372d478dd84c70659011d754bd8a9396e7f'
THEN 1 ELSE 0 END AS bootstrap_ok FROM fs_bootstrap_last_rows
),
fs_history_guard AS (
SELECT CASE WHEN p.prev_dt<p.snapshot_dt AND r.prev_rows>0 AND r.bad_rows=0
        AND b.baseline_cohorts=35 AND b.baseline_rows=629510 AND b.bad_baseline_cohorts=0
        AND a.compared_cohorts=35 AND a.bad_baseline_cohorts=0
        AND v.compared_keys=r.prev_rows AND v.bad_keys=0
        AND k.compared_keys>0 AND k.bad_keys=0
        AND fx.bad_rows=0 AND t.unexpected_existing_target_cohorts=0
        AND z.continuity_ok=1 AND z.bad_rows=0
        AND tr.checked_orders=r.prev_rows AND tr.bad_evidence=0
        AND (p.prev_dt<>'2026-10-18' OR q.bootstrap_ok=1)
        THEN TRUE ELSE FALSE END AS allowed
FROM fs_params p CROSS JOIN fs_prev_shape r CROSS JOIN fs_base_shape b
CROSS JOIN fs_backfill_comparison a CROSS JOIN fs_previous_key_check v
CROSS JOIN fs_current_key_check k CROSS JOIN fs_fixed_check fx CROSS JOIN fs_target_shape t
CROSS JOIN w_daily_prev_check z CROSS JOIN fs_bootstrap_last_check q CROSS JOIN w_transfer_checks tr
),
fs_full_rows AS (
 SELECT h.`order_id`,
       h.`order_status`,
       h.`skill_estimated_settlement_amount`,
       h.`actual_settlement_amount`,
       h.`subject_name`,
       h.`parent_order_id`,
       h.`purchase_group`,
       h.`estimated_cost_source`,
       h.`estimated_cost_gross`,
       h.`actual_cost_gross`,
       h.`estimated_tax_rate`,
       h.`actual_tax_rate`,
       h.`estimated_cost_status`,
       h.`actual_cost_status`,
       h.`bill_id`,
       h.`tax_rate_source`,
       h.`fact_snapshot_dt`,
       h.`calculation_version`,
       h.`start_class_dt` FROM fs_history_rows h
 UNION ALL
 SELECT c.`order_id`,
       c.`order_status`,
       c.`skill_estimated_settlement_amount`,
       c.`actual_settlement_amount`,
       c.`subject_name`,
       c.`parent_order_id`,
       c.`purchase_group`,
       c.`estimated_cost_source`,
       c.`estimated_cost_gross`,
       c.`actual_cost_gross`,
       c.`estimated_tax_rate`,
       c.`actual_tax_rate`,
       c.`estimated_cost_status`,
       c.`actual_cost_status`,
       c.`bill_id`,
       c.`tax_rate_source`,
       c.`fact_snapshot_dt`,
       c.`calculation_version`,
       c.`start_class_dt` FROM fs_current_rows c
),
ch_channel_dedup AS (
SELECT order_id, channel_type, third_channel
FROM (
  SELECT CAST(order_id AS STRING) AS order_id,
         CAST(channel_type AS STRING) AS channel_type,
         CAST(third_channel AS STRING) AS third_channel,
         ROW_NUMBER() OVER (
           PARTITION BY CAST(order_id AS STRING)
           ORDER BY channel_type NULLS LAST, third_channel NULLS LAST
         ) AS rn
  FROM dw_conan_dwd.dwd_conan_try_double_yxzz_third_channel
  WHERE dt='${date}'
) ch_src
WHERE rn=1
)
INSERT OVERWRITE TABLE dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da PARTITION(dt='${date}',start_class_dt)
SELECT CASE WHEN g.allowed THEN x.order_id
       ELSE CAST(assert_true(COALESCE(g.allowed,FALSE)) AS STRING) END AS order_id,
       x.`order_status`,
       x.`skill_estimated_settlement_amount`,
       x.`actual_settlement_amount`,
       x.`subject_name`,
       x.`parent_order_id`,
       x.`purchase_group`,
       x.`estimated_cost_source`,
       x.`estimated_cost_gross`,
       x.`actual_cost_gross`,
       x.`estimated_tax_rate`,
       x.`actual_tax_rate`,
       x.`estimated_cost_status`,
       x.`actual_cost_status`,
       x.`bill_id`,
       x.`tax_rate_source`,
       x.`fact_snapshot_dt`,
       x.`calculation_version`,
       ch.`channel_type`,
       ch.`third_channel`,
       x.`start_class_dt`
FROM fs_history_guard g LEFT JOIN fs_full_rows x ON TRUE
LEFT JOIN ch_channel_dedup ch ON x.order_id = ch.order_id;

