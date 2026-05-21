-- 课时制兼容版 v2.1：hist 段（display_week_dt < 2026-04-13）保留原逻辑，cur 段（>= 2026-04-13）基于 ads_new
-- 黑名单：dongxiaofei / gujingwenbj / fengmingzebj01xx / huborui
-- ⚠️ cur 段节假日延期由 ads_new.finish_next_week_mission_cnt 平台层处理，holiday_weeks/extend_weeks 仅对 hist 段生效
-- v2.1 改动：cur 段 week_idx 由 DATEDIFF/7 改为 ROW_NUMBER，自动跳过 ads_new 缺失周（如 04-27 五一放假周）

WITH 
holiday_config AS (
    SELECT 
        TRIM(hw_val) AS holiday_week,
        CAST(TRIM(ew_val) AS INT) * 7 AS extend_days
    FROM (
        SELECT POSEXPLODE(SPLIT('{{{holiday_weeks}}}', ',')) AS (pos, hw_val)
    ) hw
    JOIN (
        SELECT POSEXPLODE(SPLIT('{{{extend_weeks}}}', ',')) AS (pos, ew_val)
    ) ew ON hw.pos = ew.pos
    WHERE TRIM(hw_val) != '' AND TRIM(ew_val) != ''
)

-- ===== HIST 段（display_week_dt < 2026-04-13）=====
,hist_user_info AS (
    SELECT  *
    FROM (
        SELECT  dt, user_id, COALESCE(mentor_ldap, '未知') AS mentor_ldap,
                week_idx, level, display_week_dt, lesson_id, term_id, order_id,
                CONCAT('U', CAST(CEILING(week_idx / 2.0) AS STRING)) AS u_stage,
                MAX(IF(week_idx = 1, display_week_dt, 0)) OVER (PARTITION BY user_id, lesson_id, order_id) AS start_class_dt
        FROM    dw_conan_dwd.dwd_oral_season_user_lesson_ticket_info_da
        WHERE   dt = '{{{dt}}}'
        AND     lesson_id = '88'
        AND     display_week_dt < '2026-04-13'
        AND     display_week_dt <= DATE_SUB(NEXT_DAY('{{{dt}}}', 'MO'), 7)
    ) a
    WHERE   mentor_ldap NOT IN ('dongxiaofei','gujingwenbj','fengmingzebj01xx','huborui')
)
,hist_mission_raw AS (
    SELECT  user_id, lesson_id, term_id, level,
            INT(week_index) AS week_idx,
            mission_id,
            week_dt AS study_week,
            default.time2dt(first_finish_tp) AS finish_dt
    FROM    dw_conan_dwd.dwd_oral_user_mission_finish_data_da
    WHERE   dt = '{{{dt}}}' AND lesson_id = '88' AND week_dt < '2026-04-13'
)
,hist_mission_data AS (
    SELECT  '{{{dt}}}' AS dt, a.user_id, a.mentor_ldap, a.week_idx, a.start_class_dt, f.study_week,
            COUNT(DISTINCT f.mission_id) AS current_week_mission_cnt,
            COUNT(DISTINCT CASE 
                WHEN f.finish_dt IS NOT NULL 
                AND f.finish_dt BETWEEN f.study_week AND DATE_ADD(f.study_week, 13 + COALESCE(h.extend_days, 0)) 
                THEN f.mission_id END) AS finished_2week_mission_cnt
    FROM    hist_user_info a
    INNER JOIN hist_mission_raw f
        ON  a.user_id = f.user_id AND a.week_idx = f.week_idx
        AND a.lesson_id = f.lesson_id AND a.term_id = f.term_id AND a.level = f.level
    LEFT JOIN holiday_config h ON f.study_week = h.holiday_week
    WHERE   f.study_week <= DATE_SUB(NEXT_DAY('{{{dt}}}', 'MO'), 7)
    GROUP BY a.user_id, a.mentor_ldap, a.week_idx, a.start_class_dt, f.study_week, COALESCE(h.extend_days, 0)
)

-- ===== CUR 段（week_dt >= 2026-04-13）=====
,cur_lesson_week AS (
    SELECT  user_id, order_id,
            MAX(INT(week_idx)) AS last_hist_week_idx,
            MAX(display_week_dt) AS last_hist_week_dt,
            MAX(IF(INT(week_idx) = 1, display_week_dt, NULL)) AS hist_start_class_dt
    FROM    dw_conan_dwd.dwd_oral_season_user_lesson_ticket_info_da
    WHERE   dt = '{{{dt}}}' AND lesson_id = '88' AND display_week_dt < '2026-04-13'
    GROUP BY user_id, order_id
)
,cur_ads_dedup AS (
    SELECT  *
    FROM (
        SELECT  user_id, order_id, resource_order_id, week_dt,
                COALESCE(mentor_ldap, '未知') AS mentor_ldap,
                INT(mission_cnt) AS mission_cnt,
                INT(finish_next_week_mission_cnt) AS finish_next_week_cnt,
                ROW_NUMBER() OVER (PARTITION BY user_id, order_id, week_dt ORDER BY resource_order_id) AS rn
        FROM    dw_conan_ads.ads_oral_season_user_week_info_new_da
        WHERE   dt = '{{{dt}}}' AND lesson_id = '88'
        AND     week_dt IS NOT NULL AND week_dt != ''
        AND     week_dt >= '2026-04-13'
        AND     week_dt <= DATE_SUB(NEXT_DAY('{{{dt}}}', 'MO'), 7)
    ) tmp
    WHERE   rn = 1
)
,cur_mission_data AS (
    SELECT  '{{{dt}}}' AS dt, a.user_id, a.mentor_ldap,
            -- v2.1: 用 ROW_NUMBER 替代 DATEDIFF/7，自动跳过 ads_new 缺失周（如 04-27 五一放假周）
            -- 老用户：last_hist_week_idx (如 W45) + ROW_NUMBER (1,2,3...) = W46,W47,W48...
            -- 新用户：COALESCE 给 0，+ ROW_NUMBER = W1,W2,W3...
            COALESCE(c.last_hist_week_idx, 0) + ROW_NUMBER() OVER (
                PARTITION BY a.user_id, a.order_id ORDER BY a.week_dt
            ) AS week_idx,
            CASE 
                WHEN c.hist_start_class_dt IS NOT NULL THEN c.hist_start_class_dt
                WHEN c.last_hist_week_dt IS NOT NULL THEN 'pre_w1'
                ELSE CAST(MIN(a.week_dt) OVER (PARTITION BY a.user_id, a.order_id) AS STRING)
            END AS start_class_dt,
            a.week_dt AS study_week,
            a.mission_cnt AS current_week_mission_cnt,
            a.finish_next_week_cnt AS finished_2week_mission_cnt
    FROM    cur_ads_dedup a
    LEFT JOIN cur_lesson_week c ON a.user_id = c.user_id AND a.order_id = c.order_id
    WHERE   a.mentor_ldap NOT IN ('dongxiaofei','gujingwenbj','fengmingzebj01xx','huborui')
)

-- ===== 合并 HIST + CUR =====
,mission_data AS (
    SELECT  dt, user_id, mentor_ldap, week_idx, start_class_dt, study_week,
            current_week_mission_cnt, finished_2week_mission_cnt
    FROM    hist_mission_data
    UNION ALL
    SELECT  dt, user_id, mentor_ldap, week_idx, start_class_dt, study_week,
            current_week_mission_cnt, finished_2week_mission_cnt
    FROM    cur_mission_data
)
,weekly_aggregated AS (
    SELECT  mentor_ldap, week_idx, start_class_dt, study_week,
            COUNT(DISTINCT user_id) AS total_users,
            COUNT(DISTINCT CASE WHEN current_week_mission_cnt > 0 THEN user_id END) AS should_finish_users,
            COUNT(DISTINCT CASE WHEN current_week_mission_cnt > 0 AND finished_2week_mission_cnt < current_week_mission_cnt THEN user_id END) AS unfinished_users,
            COUNT(DISTINCT CASE WHEN current_week_mission_cnt > 0 AND finished_2week_mission_cnt = current_week_mission_cnt THEN user_id END) AS finished_100p_users
    FROM    mission_data
    GROUP BY mentor_ldap, week_idx, start_class_dt, study_week
)
,weekly_metrics AS (
    SELECT  mentor_ldap, week_idx, start_class_dt, study_week,
            total_users, should_finish_users, unfinished_users, finished_100p_users
    FROM    weekly_aggregated
)

SELECT  
    w.mentor_ldap AS `顾问Ldap`,
    w.study_week AS `所在周`,
    COALESCE(CAST(w.week_idx AS STRING), 'total_count') AS `W进度`,
    SUM(w.should_finish_users) AS `当周应完课用户数`,
    SUM(w.unfinished_users) AS `当周未完课用户数`,
    ROUND(SUM(w.finished_100p_users) * 1.0 / NULLIF(SUM(w.should_finish_users), 0), 4) AS `当周2周内百分百完课用户占比`,
    ROUND(SUM(t.finish_target * w.should_finish_users) / SUM(w.should_finish_users), 4) AS `当周2周内百分百完课用户占比目标值`,
    ROUND(SUM(w.finished_100p_users) * 1.0 / NULLIF(SUM(t.finish_target * w.should_finish_users / 1.0), 0), 4) AS `当周2周内百分百完课用户占比目标达成率`
FROM    weekly_metrics w
LEFT JOIN (
    SELECT  CAST(stage_week_idx AS INT) AS stage_week_idx,
            CAST(REPLACE(finish_target, '%', '') AS DOUBLE) / 100 AS finish_target
    FROM    temp.oral_finish_target_info
    WHERE   stage_week_idx RLIKE '^[0-9]+$'
) t ON w.week_idx = t.stage_week_idx
WHERE   {{w.study_week}}
GROUP BY w.mentor_ldap, w.study_week, w.week_idx
GROUPING SETS (
    (w.mentor_ldap, w.study_week, w.week_idx),
    (w.mentor_ldap, w.study_week)
)