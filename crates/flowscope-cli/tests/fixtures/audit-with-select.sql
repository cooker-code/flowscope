WITH stage_summary_comm AS (
    SELECT
        userid,
        subject,
        stage_name,
        CASE
            WHEN interview_week BETWEEN 13 AND 16 THEN 12
            WHEN interview_week BETWEEN 25 AND 28 THEN 24
            WHEN interview_week BETWEEN 37 AND 40 THEN 36
        END                               AS stage_exam_week,
        SUM(coalesce(duration, 0))        AS stage_summary_duration_sec
    FROM dw_conan_dwd.dwd_conan_user_mentor_interview_season_da
    WHERE dt = date_sub(current_date, 1)
      AND communication_reasons = '21'
      AND interview_week IN (13, 14, 15, 16,
                             25, 26, 27, 28,
                             37, 38, 39, 40)
    GROUP BY
        userid,
        subject,
        stage_name,
        CASE
            WHEN interview_week BETWEEN 13 AND 16 THEN 12
            WHEN interview_week BETWEEN 25 AND 28 THEN 24
            WHEN interview_week BETWEEN 37 AND 40 THEN 36
        END
)
SELECT
    a.week_dt                                                                      AS `在课周周一`,
    a.subject_id                                                                   AS `学科`,
    regexp_replace(split(a.period_type, '-')[1], '/', '-')                         AS `开课周`,
    a.period_type                                                                  AS `期型`,
    a.stage_name                                                                   AS `阶段`,
    a.teacher_city                                                                 AS `老师城市`,
    a.user_id                                                                      AS `用户ID`,
    cast(a.stage_week_idx AS int)                                                  AS `在课周进度`,
    a.is_first_purchase_user                                                       AS `是否首购`,
    if(e.resource_id is not null, 1, 0)                                    AS `是否应参考`,
    if(e.is_finish_official_exam = '1' OR e.is_finish_makeup_exam = '1', 1, 0)     AS `是否参考`,
    if(e.is_finish_official_exam = '1', 1, 0)                                      AS `是否参与正式考`,
    if(e.is_finish_makeup_exam = '1', 1, 0)                                        AS `是否补考`,
    CASE
        WHEN cast(a.stage_week_idx AS int) = 48 THEN NULL
        WHEN c.userid IS NOT NULL             THEN 1
        ELSE 0
    END                                                                            AS `是否覆盖阶段总结沟通`,
    CASE
        WHEN cast(a.stage_week_idx AS int) = 48 THEN NULL
        ELSE coalesce(c.stage_summary_duration_sec, 0)
    END                                                                            AS `阶段总结沟通时长`
FROM dw_conan_ads.ads_course_season_user_class_week_all_info_da a
LEFT JOIN (
    SELECT
        user_id,
        semester_id,
        stage_id,
        cast(week_num AS string) AS exam_stage_week_idx,
        resource_id,
        is_finish_official_exam,
        is_finish_makeup_exam
    FROM dw_conan_dwd.dwd_conan_course_user_periodical_exam_da
    WHERE dt = date_sub(current_date, 1)
      AND exam_source_type = '2'
) e
       ON e.user_id        = a.user_id
      AND e.semester_id    = a.semester_id
      AND e.stage_id       = a.stage_id
      AND e.exam_stage_week_idx = cast(a.stage_week_idx AS string)
LEFT JOIN stage_summary_comm c
       ON c.userid          = a.user_id
      AND c.subject         = a.subject_id
      AND c.stage_name      = a.stage_name
      AND c.stage_exam_week = cast(a.stage_week_idx AS int)
WHERE a.dt = date_sub(current_date, 1)
  AND a.subject_id IN ('1','2','3')
  AND a.week_dt <= date_sub(next_day(current_date, 'MO'), 14)
  AND {{week_dt}}
  AND {{subject_id as subject}}
  AND {{cast(stage_week_idx as int) as stage_weekidx}}
;