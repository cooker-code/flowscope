-- 由于用户wx可能会有多个，会导致一个用户可能有多行数据，如果不是count的逻辑需要注意去重添加微信的逻辑


-- WITH ralation_info AS 
-- (
--     SELECT  *
--     FROM    (
--                 -- 系统判断到用户和老师的微信添加关 系
--                 SELECT  id
--                         ,teacherwechatid AS teacher_wechatid
--                         ,userwechatid AS user_wechatid
--                         ,userid AS user_id
--                         ,deleted AS is_deleted
--                         ,source
--                         ,createdtime AS created_tp -- 添加时间
--                         ,updatedtime AS updated_tp
--                         ,ROW_NUMBER() OVER (PARTITION BY userid,teacherwechatid ORDER BY createdtime DESC ) AS rn
--                 FROM    dw_ods.ods_conan_mentor_work_efficiency_teacher_user_class_relation_da -- 包含老师个微/企微
--                 WHERE   dt = '{{{dt}}}'
--                 AND     deleted = 0 -- 未删除 
--             ) tt
--     WHERE   rn = 1 -- 取最后一条创建记录 
-- )
-- ,add_wechat_info AS 
-- (
--     SELECT  tab_teacher_user.user_id
--             ,tab_teacher_user.user_wechatid AS user_wechat_id
--             ,tab_teacher_user.mentor_ldap -- ,tab_teacher_user.teacher_wechat_id -- 老师个微id
--             -- ,MAX(case WHEN t1.id is not null THEN 1 else 0 end)                                                                      AS wechat_add_status -- 个微添加状态,0:未添加,1:已添加
--             -- ,MAX(case WHEN t1.id is not null THEN t1.created_tp end)                                                                 AS wechat_add_tp -- 个微添加成功时间
--             ,tab_teacher_user.teacher_wecom_id -- 老师企微id
--             ,MAX(CASE    WHEN t2.id IS NOT NULL THEN 1 ELSE 0 END) AS wecom_add_status -- 企微添加状态,0:未添加,1:已添加
--             ,MAX(CASE    WHEN t2.id IS NOT NULL THEN t2.created_tp END) AS wecom_add_tp -- 企微添加成功时间(1:已添加)
--     FROM    (
--                 SELECT  ticket_info.user_id
--                         ,tab_user_wechat.user_wechatid
--                         ,ticket_info.mentor_ldap
--                         ,teacher_wechat_info.teacher_wechat_id
--                         ,teacher_wechat_info.teacher_wecom_id
--                 FROM    (
--                             -- 全量用户与老师上课关 系
--                             SELECT  user_id
--                                     ,mentor_ldap
--                                                         -- FROM    dw_conan_dwd.dwd_oral_user_lesson_ticket_info_da
--                            from    dw_conan_dwd.dwd_oral_trial_user_lesson_ticket_info_da -- 替换成试听课履约表
--                             WHERE   dt = '{{{dt}}}'
--                             AND     mentor_ldap IS NOT NULL
--                             GROUP BY user_id
--                                      ,mentor_ldap
--                         ) ticket_info
--                 LEFT JOIN   (
--                                 -- 找到老师的个微/企 微
--                                 SELECT  ldapaccount AS teacher_ldap
--                                         ,MAX(CASE    WHEN wechatType = 1 THEN wechatid END) AS teacher_wechat_id -- 老师个微id
--                                         ,MAX(CASE    WHEN wechatType = 2 THEN wechatid END) AS teacher_wecom_id -- 老师企微id
--                                 FROM    dw_conan_ods.ods_conan_mentor_teacher_info_da_no_sensitive_view
--                                 WHERE   dt = '{{{dt}}}'
--                                 AND     wechatType IN ('1','2') -- 1-个人微信,2-企业微信
--                                 AND     dorabindstatus = '3' -- 已绑定
--                                 GROUP BY ldapaccount
--                             ) teacher_wechat_info
--                 ON      ticket_info.mentor_ldap = teacher_wechat_info.teacher_ldap
--                 LEFT JOIN   (
--                                 -- 用户的wechati d
--                                 SELECT  user_id
--                                         ,user_wechatid
--                                 FROM    ralation_info
--                                 GROUP BY user_id
--                                          ,user_wechatid
--                             ) tab_user_wechat
--                 ON      ticket_info.user_id = tab_user_wechat.user_id
--             ) tab_teacher_user -- LEFT JOIN ralation_info t1 -- 老师个微
--     -- ON tab_teacher_user.teacher_wechat_id = t1.teacher_wechatid AND tab_teacher_user.user_wechatid = t1.user_wechatid
--     LEFT JOIN ralation_info t2 -- 老师企微
--     ON      tab_teacher_user.teacher_wecom_id = t2.teacher_wechatid
--     AND     tab_teacher_user.user_wechatid = t2.user_wechatid
--     GROUP BY tab_teacher_user.user_id
--              ,tab_teacher_user.user_wechatid
--              ,tab_teacher_user.mentor_ldap -- ,tab_teacher_user.teacher_wechat_id -- 老师个微id
--              ,tab_teacher_user.teacher_wecom_id -- 老师企微id
-- )

select  a.study_date
        ,a.dt 
        ,allocate_dt
        ,coalesce(stage_name,'未知') as `斑马级别`
        ,coalesce(mentor_ldap,'未知') as `口语顾问`
        ,coalesce(user_type,'未知') as `用户来源`
        ,coalesce(teacher_city,'未知') as `斑马班主任城市`
        ,coalesce(mission_name,'未知') as `试听课主题`
        ,coalesce(lesson_name,'未知') as `商品名称`
        ,count(distinct user_id) as `约课人数`
        ,count(distinct if(is_attend_d0  = 1,user_id,null)) as `当天到课人数`
        ,count(distinct if(is_attend_d6  = 1,user_id,null)) as `7日内到课人数`
        ,count(distinct if(is_finish_d0  = 1,user_id,null)) as `当日完课人数`
        ,count(distinct if(is_finish_d6  = 1,user_id,null)) as `7日内完课人数`
        ,count(distinct if(is_finish_d13 = 1,user_id,null)) as `14日内完课人数`
        ,count(distinct if(is_finish_renew_d0 =  1,user_id,null)) as `当日完课转化人数`
        ,count(distinct if(is_finish_renew_d6 =  1,user_id,null)) as `7日内完课转化人数`
        ,count(distinct if(is_finish_renew_d13 = 1,user_id,null)) as `14日内完课转化人数`       
        ,count(distinct if(is_renew_d0  = 1,user_id,null)) as `当日转化人数`
        ,count(distinct if(is_renew_d3  = 1,user_id,null)) as `4日内转化人数`
        ,count(distinct if(is_renew_d6  = 1,user_id,null)) as `7日内转化人数`
        ,count(distinct if(is_renew_d13 = 1,user_id,null)) as `14日内转化人数`
        ,count(distinct if(is_repeat_trial = 1,user_id,null)) as `重复推课人数`    
                ,sum(cnt_canke) as `参课沟通次数`
                ,sum(cnt_canke_success) as `成功参课沟通次数`
                ,sum(sum_phone_duration_canke)/sum(cnt_phone_duration_canke) as `系统电话平均参课时长/s`
                ,sum(cnt_wanke) as `完课沟通次数`
                ,sum(cnt_wanke_success) as `成功完课沟通次数`
                ,sum(sum_phone_duration_wanke)/sum(cnt_phone_duration_wanke) as `系统电话平均完课时长/s`
                ,sum(cnt_zhuanhua) as `转化沟通次数`
                ,sum(cnt_zhuanhua_success) as `成功转化沟通次数`
                ,sum(sum_phone_duration_zhuanhua)/sum(cnt_phone_duration_zhuanhua) as `系统电话平均转化时长/s`
                ,sum(cnt_zhaohui) as `召回沟通次数`
                ,sum(cnt_zhaohui_success) as `成功召回沟通次数`
                ,sum(sum_phone_duration_zhaohui)/sum(cnt_phone_duration_zhaohui) as `系统电话平均召回时长/s`

from    (
            SELECT  a.study_date
                    ,a.dt
                    ,coalesce(stage_name,'未知') as stage_name
                    ,coalesce(teacher_city,'未知') as teacher_city
                    ,a.mentor_ldap
                    ,IF(d.user_id IS NOT NULL,'口语内测用户','斑马导流用户') AS user_type -- 用户来源
                    ,b.pay_dt -- 成单日期
                                        ,a.allocate_dt
                    ,a.user_id -- 约课uid
                                        ,b.lesson_name
                                        ,coalesce(episode_name,'未知') as episode_name
                                        ,coalesce(mission_name,'未知') as mission_name
                    -- ,IF(wecom_add_status = '1',1,0) AS is_add
                    -- ,FROM_UNIXTIME(CAST(wecom_add_tp / 1000 AS BIGINT)) AS add_time
                    -- ,default.time2dt(wecom_add_tp) AS add_dt
                    -- ,IF(wecom_add_status = '1' AND default.time2dt(wecom_add_tp) <= study_date,1,0) AS is_add_d0
                    ,IF(is_open = 1,enter_time,NULL) AS enter_time
                    ,IF(is_open = 1,enter_dt,NULL) AS enter_dt
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= a.study_date,1,0) AS is_attend_d0
                    ,finish_time
                    ,finish_dt
                    ,IF(finish_unix is not null AND finish_dt <= a.study_date,1,0) AS is_finish_d0 
                    -- 约课N日内到课人数
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,1),1,0)  AS  is_attend_d1
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,3),1,0)  AS  is_attend_d3
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,5),1,0)  AS  is_attend_d5
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,6),1,0)  AS  is_attend_d6
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,7),1,0)  AS  is_attend_d7 
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,13),1,0) AS is_attend_d13

                    -- 约课N日内完课人数
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,1),1,0)  AS is_finish_d1
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,3),1,0)  AS is_finish_d3
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,5),1,0)  AS is_finish_d5
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,6),1,0)  AS is_finish_d6
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,7),1,0)  AS is_finish_d7 
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,13),1,0) AS is_finish_d13

                    -- 约课N日内到课完课人数（约课日+N日已到课且完课用户）
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,0) and finish_unix is not null and finish_dt <= date_add(a.study_date,0),1,0)   as is_attend_finish_d0
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,1) and finish_unix is not null and finish_dt <= date_add(a.study_date,1),1,0)   as is_attend_finish_d1
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,3) and finish_unix is not null and finish_dt <= date_add(a.study_date,3),1,0)   as is_attend_finish_d3
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,5) and finish_unix is not null and finish_dt <= date_add(a.study_date,5),1,0)   as is_attend_finish_d5
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,6) and finish_unix is not null and finish_dt <= date_add(a.study_date,6),1,0)   as is_attend_finish_d6
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,7) and finish_unix is not null and finish_dt <= date_add(a.study_date,7),1,0)   as is_attend_finish_d7
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,13) and finish_unix is not null and finish_dt <= date_add(a.study_date,13),1,0) as is_attend_finish_d13

                    -- 约课日+N日已转化用户
                    ,season_pay_time
                    ,season_pay_dt
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,0),1,0)  AS is_renew_d0
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,1),1,0)  AS is_renew_d1
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,3),1,0)  AS is_renew_d3
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,5),1,0)  AS is_renew_d5
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,6),1,0)  AS is_renew_d6
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,7),1,0)  AS is_renew_d7
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,13),1,0) AS is_renew_d13 
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,14),1,0) AS is_renew_d14 
                    -- 约课日+N日已完课且转化用户
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,0) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,0),1,0)   as is_finish_renew_d0
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,1) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,1),1,0)   as is_finish_renew_d1
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,3) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,3),1,0)   as is_finish_renew_d3
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,5) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,5),1,0)   as is_finish_renew_d5
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,6) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,6),1,0)   as is_finish_renew_d6
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,7) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,7),1,0)   as is_finish_renew_d7
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,13) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,13),1,0) as is_finish_renew_d13

                    ,DATEDIFF(IF(is_open = 1,enter_dt,NULL),a.study_date) AS attend_to_study_daydiff
                    ,DATEDIFF(finish_dt,a.study_date) AS finish_to_study_daydiff
                    ,DATEDIFF(season_pay_dt,a.study_date) AS renew_to_study_daydiff
                    ,IF(CAST(ads_mc.mission_cnt AS INT) > 1, 1, 0) AS is_repeat_trial
                    -- ,DATEDIFF(default.time2dt(wecom_add_tp),b.pay_dt) AS add_to_trypay_daydiff
                    ,count(distinct if(communication_reasons_desc='体验课-参课沟通',interview_id,null)) as cnt_canke
                    ,count(distinct if(communication_reasons_desc='体验课-完课沟通',interview_id,null)) as cnt_wanke
                    ,count(distinct if(communication_reasons_desc='体验课-转化沟通',interview_id,null)) as cnt_zhuanhua
                    ,count(distinct if(communication_reasons_desc='体验课-召回沟通',interview_id,null)) as cnt_zhaohui
                    ,count(distinct if(communication_reasons_desc='体验课-参课沟通' and communication_status_desc = '成功',interview_id,null)) as cnt_canke_success
                    ,count(distinct if(communication_reasons_desc='体验课-完课沟通' and communication_status_desc = '成功',interview_id,null)) as cnt_wanke_success
                    ,count(distinct if(communication_reasons_desc='体验课-转化沟通' and communication_status_desc = '成功',interview_id,null)) as cnt_zhuanhua_success
                    ,count(distinct if(communication_reasons_desc='体验课-召回沟通' and communication_status_desc = '成功',interview_id,null)) as cnt_zhaohui_success
                    ,sum(if(communication_reasons_desc='体验课-参课沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),duration,0)) as sum_phone_duration_canke
                    ,sum(if(communication_reasons_desc='体验课-完课沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),duration,0)) as sum_phone_duration_wanke
                    ,sum(if(communication_reasons_desc='体验课-转化沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),duration,0)) as sum_phone_duration_zhuanhua
                    ,sum(if(communication_reasons_desc='体验课-召回沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),duration,0)) as sum_phone_duration_zhaohui
                    ,count(distinct if(communication_reasons_desc='体验课-参课沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),interview_id,null)) as cnt_phone_duration_canke
                    ,count(distinct if(communication_reasons_desc='体验课-完课沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),interview_id,null)) as cnt_phone_duration_wanke
                    ,count(distinct if(communication_reasons_desc='体验课-转化沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),interview_id,null)) as cnt_phone_duration_zhuanhua
                    ,count(distinct if(communication_reasons_desc='体验课-召回沟通' and communication_status_desc='成功' and communication_via_desc in ('系统电话','工作电话'),interview_id,null)) as cnt_phone_duration_zhaohui

            FROM    (
                        SELECT  study_date
                                ,dt
                                ,order_id
                                ,user_id
                                ,mentor_ldap
                                ,level
                                ,allocate_time
                                ,SUBSTR(allocate_time,1,10) as allocate_dt
                        -- FROM    dw_conan_dwd.dwd_oral_user_lesson_ticket_info_da
                        from    dw_conan_dwd.dwd_oral_trial_user_lesson_ticket_info_da -- 替换成试听课履约表
                        WHERE   dt = '{{{dt}}}'
                        AND     lesson_id in ('66','98') -- 试听课数据
                    ) a
            LEFT JOIN   (
                            SELECT  default.time2dt(paidtime) AS pay_dt
                                    ,FROM_UNIXTIME(CAST(paidtime / 1000 AS BIGINT)) AS pay_time
                                    ,paidtime
                                    ,lesson_name
                                    ,lesson_id
                                    ,order_id
                                    ,user_id
                            FROM    dw_conan_ods.ods_oral_trade_t_order_da
                            WHERE   dt = '{{{dt}}}'
                            AND     order_status = '2' -- 支付成功
                        ) b
            ON      a.user_id = b.user_id
            AND     a.order_id = b.order_id
            LEFT JOIN   (
                          SELECT    CAST(user_id AS STRING) AS userid
                                    ,class_id as classid
                                    ,teacher_ldap
                                    ,team_leader_ldap as teacher_leader_ldap
                                    ,district_leader_ldap
                                    ,stage_name
                                    ,stage_week_idx as stage_weekidx
                                    ,index_col as index
                                    ,week_dt
                                    ,subject_id as subject
                                    ,teacher_city
                            FROM    dw_conan_ads.ads_course_season_user_class_week_all_info_da
                            WHERE   dt = DATE_SUB(CURRENT_DATE,1)
                            AND     subject_id = 1
                            AND     week_dt <= DATE_SUB(NEXT_DAY('{{{dt}}}','MO'),7)
                            AND     week_dt >= '2024-03-03'
                            AND     stage_name IN ('S4','S5','S6')
                        ) c
            ON      a.user_id = c.userid
            AND     DATE_SUB(NEXT_DAY(b.pay_dt,'MO'),7) = c.week_dt
            LEFT JOIN   (
                            SELECT  user_id
                            FROM    temp.oral_beta_test_uid
                        ) d
            ON      a.user_id = d.user_id
            -- LEFT JOIN add_wechat_info e
            -- ON      a.user_id = e.user_id
            -- AND     a.mentor_ldap = e.mentor_ldap
            LEFT JOIN   (
                            SELECT  a.user_id
                                    ,lesson_type
                                    ,a.lesson_id
                                    ,lesson_mission_id
                                    ,episode_name
                                    ,name as mission_name
                                    ,a.week_index
                                    ,a.level
                                    ,display_date AS display_date_raw -- 课程下发日期
                                    ,CONCAT(SUBSTR(display_date,1,4),'-',SUBSTR(display_date,5,2),'-',SUBSTR(display_date,7,2)) AS display_date
                                    ,first_start_tp AS enter_unix -- 到课日期
                                    ,default.time2dt(first_start_tp) AS enter_dt
                                    ,FROM_UNIXTIME(CAST(first_start_tp / 1000 AS BIGINT)) AS enter_time
                                    ,first_finish_tp AS finish_unix -- 完课日期
                                    ,default.time2dt(first_finish_tp) AS finish_dt
                                    ,FROM_UNIXTIME(CAST(first_finish_tp / 1000 AS BIGINT)) AS finish_time
                                    ,is_open
                                    ,is_finish
                            FROM    dw_conan_ods.ods_conan_mission_oral_lesson_user_mission_da a
                            LEFT JOIN   (
                                            SELECT  a.user_id
                                                    ,b.oral_mission_id
                                                                        ,a.episode_name
                                                    ,MIN(first_start_tp) AS first_start_tp
                                                    ,MIN(first_start_dt) AS first_start_dt
                                                    ,MAX(is_open) AS is_open
                                                    ,MIN(finish_time) AS first_finish_tp
                                                    ,MAX(is_finish) AS is_finish
                                            FROM    (
                                                        SELECT  room_id
                                                                ,user_id
                                                                ,episode_id
                                                                                ,episode_name
                                                                ,room_end_time
                                                                ,room_end_dt
                                                                ,episode_room_rank
                                                                ,first_start_tp
                                                                ,first_start_dt
                                                                ,is_open
                                                                ,is_finish
                                                                ,finish_time
                                                        FROM    dw_conan_dwd.dwd_ai_oral_user_episode_room_info_da
                                                        WHERE   dt = '{{{dt}}}'
                                                    ) a
                                            LEFT JOIN   (
                                                            SELECT  user_id
                                                                    ,room_id
                                                                    ,oral_mission_id
                                                            FROM    dw_conan_ods.ods_conan_ai_oral_user_room_info_da
                                                            WHERE   dt = '{{{dt}}}'
                                                        ) b
                                            ON      a.user_id = b.user_id
                                            AND     a.room_id = b.room_id
                                            GROUP BY a.user_id
                                                     ,b.oral_mission_id
                                                                         ,a.episode_name
                                        ) b
                            ON      a.user_id = b.user_id
                            AND     a.lesson_mission_id = b.oral_mission_id
                                        left join (
                            select       distinct id
                                    ,name
                            from        dw_conan_ods.ods_conan_mission_oral_lesson_mission_da
                            where       dt = date_sub(current_date,1)
                            and         lesson_type = '2'
                            ) c on a.lesson_mission_id = c.id
                            WHERE   a.dt = '{{{dt}}}'
                        ) f
            ON      a.user_id = f.user_id
            AND     b.lesson_id = f.lesson_id
            AND     a.level = f.level
            AND     a.study_date = f.display_date
            LEFT JOIN   (
                            SELECT  default.time2dt(paidtime) AS season_pay_dt
                                    ,FROM_UNIXTIME(CAST(paidtime / 1000 AS BIGINT)) AS season_pay_time
                                    ,paidtime
                                    ,lesson_name
                                    ,lesson_id
                                    ,order_id AS season_order_id
                                    ,user_id
                            FROM    dw_conan_ods.ods_oral_trade_t_order_da
                            WHERE   dt = '{{{dt}}}'
                            AND     lesson_id = '88' -- 系统课
                            AND     order_status = '2' -- 支付成功&部分退
                        ) j
            ON      a.user_id = j.user_id
            AND     b.paidtime < j.paidtime
            LEFT JOIN   (
                            SELECT  user_id, study_date, order_id, mission_cnt
                            FROM    dw_conan_ads.ads_oral_trial_user_quality_detail_da
                            WHERE   dt = '{{{dt}}}'
                            AND     lesson_id IN ('66','98')
                        ) ads_mc
            ON      a.user_id = ads_mc.user_id AND a.order_id = ads_mc.order_id AND a.study_date = ads_mc.study_date
          LEFT JOIN   (
                          SELECT  *
                          FROM    dw_conan_dwd.dwd_oral_user_mentor_interview_trial_da a 
                          WHERE   dt = '{{{dt}}}'
                          AND     a.communication_reasons IN (1,3,9,14,10) -- 口语课体验课 
                      ) k
          ON      a.user_id = k.user_id
          AND     a.mentor_ldap = k.ldap
          AND     b.lesson_id = k.lesson_id
            GROUP BY 
                    a.study_date
                    ,a.dt
                    ,coalesce(stage_name,'未知')
                    ,coalesce(teacher_city,'未知')
                    ,a.mentor_ldap
                    ,IF(d.user_id IS NOT NULL,'口语内测用户','斑马导流用户')
                    ,b.pay_dt
                    ,a.allocate_dt
                    ,a.user_id
                    ,b.lesson_name
                    ,coalesce(episode_name,'未知')
                    ,coalesce(mission_name,'未知')
                    ,IF(is_open = 1,enter_time,NULL)
                    ,IF(is_open = 1,enter_dt,NULL)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= a.study_date,1,0)
                    ,finish_time
                    ,finish_dt
                    ,IF(finish_unix is not null AND finish_dt <= a.study_date,1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,1),1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,3),1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,5),1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,6),1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,7),1,0)
                    ,IF(is_open = 1 AND enter_unix is not null AND enter_dt <= DATE_ADD(a.study_date,13),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,1),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,3),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,5),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,6),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,7),1,0)
                    ,IF(finish_unix is not null AND finish_dt <= DATE_ADD(a.study_date,13),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,0) and finish_unix is not null and finish_dt <= date_add(a.study_date,0),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,1) and finish_unix is not null and finish_dt <= date_add(a.study_date,1),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,3) and finish_unix is not null and finish_dt <= date_add(a.study_date,3),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,5) and finish_unix is not null and finish_dt <= date_add(a.study_date,5),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,6) and finish_unix is not null and finish_dt <= date_add(a.study_date,6),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,7) and finish_unix is not null and finish_dt <= date_add(a.study_date,7),1,0)
                    ,if(is_open = 1 and enter_unix is not null and enter_dt <= date_add(a.study_date,13) and finish_unix is not null and finish_dt <= date_add(a.study_date,13),1,0)
                    ,season_pay_time
                    ,season_pay_dt
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,0),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,1),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,3),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,5),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,6),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,7),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,13),1,0)
                    ,IF(season_order_id IS NOT NULL AND season_pay_dt <= DATE_ADD(a.study_date,14),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,0) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,0),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,1) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,1),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,3) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,3),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,5) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,5),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,6) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,6),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,7) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,7),1,0)
                    ,if(finish_unix is not null and finish_dt <= date_add(a.study_date,13) and season_order_id is not null and season_pay_dt <= date_add(a.study_date,13),1,0)
                    ,DATEDIFF(IF(is_open = 1,enter_dt,NULL),a.study_date)
                    ,DATEDIFF(finish_dt,a.study_date)
                    ,DATEDIFF(season_pay_dt,a.study_date)
                    ,IF(CAST(ads_mc.mission_cnt AS INT) > 1, 1, 0)

  ) a 
  where {{a.study_date}}
  and   {{allocate_dt}}
  group by  a.study_date
            ,a.dt 
            ,allocate_dt
            ,stage_name
            ,mentor_ldap
            ,user_type
            ,teacher_city
            ,mission_name
            ,lesson_name
            
 --  grouping sets (
 --                     (study_date,dt,stage_name, mentor_ldap, user_type, teacher_city)
 --                    ,(study_date,dt,stage_name, mentor_ldap, user_type)
 --                    ,(study_date,dt,stage_name, mentor_ldap, teacher_city)
 --                    ,(study_date,dt,stage_name, user_type, teacher_city)
 --                    ,(study_date,dt,mentor_ldap, user_type, teacher_city)
 --                    ,(study_date,dt,stage_name, mentor_ldap)
 --                    ,(study_date,dt,stage_name, user_type)
 --                    ,(study_date,dt,stage_name, teacher_city)
 --                    ,(study_date,dt,mentor_ldap, user_type)
 --                    ,(study_date,dt,mentor_ldap, teacher_city)
 --                    ,(study_date,dt,user_type, teacher_city)
 --                    ,(study_date,dt,stage_name)
 --                    ,(study_date,dt,mentor_ldap)
 --                    ,(study_date,dt,user_type)
 --                    ,(study_date,dt,teacher_city)
 --                    ,(study_date,dt)
 --                )
