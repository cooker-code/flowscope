set mapreduce.reduce.memory.mb=4096;
set mapreduce.map.memory.mb=2048;
set mapreduce.map.java.opts='-Xmx4096M';
set mapreduce.reduce.java.opts='-Xmx4096M';
set hive.auto.convert.join = true;
set hive.mapjoin.smalltable.filesize = 2500000;
SET hive.exec.parallel=true;
SET hive.exec.parallel.thread.number=20;
set hive.exec.dynamic.partition =true;


INSERT OVERWRITE TABLE dw_dwd.dwd_eng_chapter_quiz_question_report_ext_desc_all PARTITION (sub_par='new',subject)
SELECT  quiz_report.user_id
        ,episode_chapter.mission_id
        ,episode_chapter.episode_id
        ,episode_chapter.chapter_type
        ,quiz_report.quiz_id -- 和resource_id 完全一样
        ,episode_chapter.resource_id --报告侧的资源id
        ,episode_chapter.resource_type
        ,episode_chapter.chapter_report_create_dt
        ,quiz.question_num AS resource_has_question_num
        ,quiz_report.question_id
        ,info.ability_type
        ,COALESCE(info.knowledge_id,'0') AS knowledge_id
        ,info.knowledgeids AS knowledge_ids -- 废弃字段
        ,info.keypoint_id
        ,info.keypoints -- 废弃字段
        ,info.basic_point_type
        ,quiz_report.last_question_report_id
        ,'0' AS last_quiz_report_id --废弃
        ,cast(quiz_report.last_question_star_count as int) as last_question_star_count
        ,quiz_report.last_question_report_create_time
        ,question_frog.last_app_version
        ,question_frog.last_question_start_time
        ,question_frog.last_question_end_time
        ,cast(question_frog.last_question_duration as int) as last_question_duration
        ,IF(default.version2num(question_frog.last_app_version) >= default.version2num('4.22.0'),GET_JSON_OBJECT(quiz_report.useranswerpath,'$.choiceIndices'),'') AS choiceindices
        ,IF(default.version2num(question_frog.last_app_version) >= default.version2num('4.22.0'),GET_JSON_OBJECT(quiz_report.useranswerpath,'$.optionIndices'),'') AS optionindices
        ,info.skilltype
        ,info.question_type
        ,info.question_category
        ,info.source_type
        ,quiz_report.useranswerpath AS answer_path
        ,IF(info.source_type = '1' AND b.question_id IS NOT NULL,1,0) AS is_zdt_question -- 题目粒度 and 资源粒度的自适应过滤
        ,cast(episode_chapter.spent_time as int) AS chapter_spent_time
        ,episode_chapter.display_type
        ,episode_chapter.episode_resource_id -- 教研侧的资源id
        ,info.keypoint_type -- 辅导服务需要这个类型
        ,info.question_type_name
        ,info.content_text
        ,user_mission.episode_type_cd AS episode_type
        ,user_mission.mission_type_cd AS mission_type
        ,user_mission.semester_id AS semester_id
        ,user_mission.semester_type_cd AS semester_type
        ,user_mission.term_id AS term_id
        ,user_mission.stage_id AS stage_id
        ,user_mission.stage_name AS stage_name
        ,user_mission.stage_unit_idx AS stage_unit_idx
        ,user_mission.stage_week_idx AS stage_week_idx
        ,user_mission.day_idx AS day_idx
        ,user_mission.push_dt AS push_dt
        ,user_mission.week_dt AS week_dt
        ,user_mission.outline_version AS outline_version
        ,user_mission.lesson_id AS lesson_id
        ,user_mission.option_id AS option_id
        ,user_mission.period_type AS period_type
        ,episode_chapter.resource_unique_key
        ,GET_JSON_OBJECT(quiz_report.useranswerpath,'$.conversationId') AS ai_conversation_id
        ,episode_chapter.app_version
        ,episode_chapter.plat_form
        ,quiz_report.last_resource_session_id
        ,user_mission.mission_finished_day
        ,FROM_UNIXTIME(cast(quiz_report.last_question_report_create_time/1000 as bigint),'yyyy-MM-dd HH:mm:ss') as last_question_report_create_dt
        ,quiz_report.last_wrong_times
        ,user_mission.subject_id AS subject  -- 二级分区最后一列
FROM (
    SELECT  userid
            ,mission_id
            ,subject_id
            ,episode_type_cd
            ,mission_type_cd
            ,semester_id
            ,semester_type_cd
            ,term_id
            ,stage_id
            ,stage_name
            ,stage_unit_idx
            ,coalesce(stage_week_idx,week_idx) as stage_week_idx
            ,day_idx
            ,push_dt
            ,week_dt
            ,edition_id AS outline_version
            ,lesson_id
            ,option_cd AS option_id
            ,period_type
            ,mission_finished_day
    FROM dw_dwd.dwd_eng_course_user_mission_da
   WHERE dt = '${date}'
     AND subject_id != '2'
     AND is_test = '0'
   --   and (mission_finished_day >='2024-10-01' or mission_finished_day= '1970-01-01')  -- um 的完成时间只记录首次的。所有可以用这个时间卡，单个mission不会有重复计算。 + 未完成的mission 时间是1970-01-01。 -- 不能卡时间，应为有个章节可跳过 首次完成章节时间可能在episode完成之后
) user_mission
inner JOIN(
     select user_id
        ,mission_id
        ,resource_session_id
        ,episode_id
        ,chapter_type
        ,app_version
        ,plat_form
        ,resource_id
        ,resource_type
        ,chapter_report_create_dt
        ,spent_time
        ,display_type
        ,episode_resource_id
        ,resource_unique_key
       from dw_dwd.dwd_eng_course_quiz_zsc_self_question_resource_desc_da 
      where dt = '${date}'
    --  and chapter_report_create_dt >='2024-10-01'  -- 不能卡时间，应为有个章节可跳过 首次完成章节时间可能在episode完成之后
    ) episode_chapter
ON episode_chapter.user_id = user_mission.userid
AND episode_chapter.mission_id = user_mission.mission_id
inner JOIN ( 
   SELECT  user_id 
              ,question_id
              ,quiz_id
              ,last_question_report_id
              ,last_star_count AS last_question_star_count
              ,last_createdtime AS last_question_report_create_time
              ,useranswerpath
              ,last_resource_session_id
              ,last_wrong_times
      FROM dw_dwd.dwd_eng_quiz_question_report_desc_da -- 这个表排除了自适应出题的
      WHERE dt = '${date}'
        and last_createdtime >='1727712000000' -- '2024-10-01'
  ) quiz_report
ON  quiz_report.last_resource_session_id = episode_chapter.resource_session_id -- 取首次的报告关联，应为只取mission信息，首次末次都一样
inner JOIN (
      -- 该子查询会因为题目和知识点的多对多关系造成数据量膨胀，且容易造成数据倾斜，放在最后做join处理能减少运行时间
      SELECT   question_id
              ,subject
              ,skilltype
              ,ability_type
              ,keypoints
              ,basic_point_type
              ,keypoint_id
              ,source_type
              ,question_type
              ,question_type_name
              ,question_category
              ,knowledgeids
              ,keypoint_type
              ,knowledge_id
              ,content_text
      FROM  dw_dwd.dwd_eng_course_question_keypoint_type_info_da 
      where dt = '${date}'
) info
ON quiz_report.question_id = info.question_id
LEFT JOIN (
    -- 教研资源中绑定的题目数量
    SELECT  id
            ,SIZE(json_array(questionids)) question_num
    FROM    dw_ods.ods_conan_english_quiz_quiz_da
    WHERE   dt = '${date}'
) quiz
ON episode_chapter.episode_resource_id = quiz.id
LEFT JOIN(
    SELECT  quiz_id
            ,question_id
            ,question_source_type
    FROM    dw_dwd.dwd_conan_english_quiz_expland_question -- 教研quiz 与 question的关系
    WHERE   dt = '${date}'
    AND     question_source_type = '1' -- 底层表有逻辑加工，只要教研出题
) b
ON episode_chapter.episode_resource_id = b.quiz_id -- 需要将报告中的resource_id 转为episode_resource_id 后关联，为了取自适应资源中教研出的题目
AND quiz_report.question_id = b.question_id
LEFT JOIN(
    SELECT user_id
          ,frog_report_id
          ,mission_id
          ,subject
          ,question_id
          ,last_app_version
          ,last_question_start_time
          ,last_question_end_time
          ,last_question_duration
    FROM  dw_dwd.dwd_eng_course_resource_question_frog_da
    WHERE   dt = '${date}'
) question_frog
ON  quiz_report.user_id = question_frog.user_id
AND quiz_report.question_id = question_frog.question_id
AND episode_chapter.mission_id = question_frog.mission_id
;