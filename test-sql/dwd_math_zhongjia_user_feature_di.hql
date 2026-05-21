set spark.sql.hive.convertMetastoreOrc=true;
set spark.driver.memory=16g;
set spark.driver.cores=1;
set spark.executor.memory=8g;
set spark.executor.cores=2;
INSERT OVERWRITE TABLE dw_conan_dwd.dwd_math_zhongjia_user_feature_di partition(dt = '${date}')
WITH user_info AS
(
	SELECT  start_class_dt,
	        user_id AS userid,
	        order_id AS orderid,
	        renewal_order_id AS renewal_orderid,
	        teacher_ldap AS ldap,
	        is_age_match,
	        pay_dt AS paid_dt,
	        pay_tp AS paidtime,
	        user_city,
	        age_buy_lesson,
	        concat('思维',stage_name) AS label_stage_name,
	        is_add_wechat_before_class,
	        is_active_before_class,
  case when ad_channel in ('电商中价') and keyfrom LIKE 'tansuo2-dyxd%' THEN '抖音中价'
  when ad_channel in ('电商中价') and keyfrom LIKE 'tansuo2-tencent-zj%' THEN '腾讯中价'
  when ad_channel in ('电商中价') THEN '抖音中价' else ad_channel end as ad_channel,
	        stage_name,
	        semester_id AS semesterid
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
	WHERE dt = '${date}'
	AND is_bundled = '单带'
  and semester_label!='虚拟'
	AND subject_id = 2
	AND ad_channel IN ('抖音中价', '腾讯中价', '其他中价','电商中价')
	AND ( start_class_dt = next_day(date_add('${date}', 1), 'MO') OR ( start_class_dt = next_day(date_add('${date}', 8), 'MO') AND NOT EXISTS (
	SELECT  1
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da t2
	WHERE t2.dt = '${date}'
	AND t2.is_bundled = '单带'
	AND t2.subject_id = 2
      and t2.semester_label!='虚拟'
	AND t2.start_class_dt = next_day(date_add('${date}', 1), 'MO') ) ) OR ( start_class_dt = next_day(date_add('${date}', 15), 'MO') AND NOT EXISTS (
	SELECT  1
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da t3
	WHERE t3.dt = '${date}'
	AND t3.is_bundled = '单带'
      and t3.semester_label!='虚拟'
	AND t3.subject_id = 2
	AND ( t3.start_class_dt = next_day(date_add('${date}', 1), 'MO') OR t3.start_class_dt = next_day(date_add('${date}', 8), 'MO') ) ) ) ) 
), past_order AS
(
	SELECT  user_id,
	        order_id,
	        semester_type,
	        pay_dt,
	        subject_name,
	        subject_id,
	        stage_name
	FROM dw_dwd.dwd_eng_order_course_detail_da
	WHERE dt = '${date}'
	AND semester_type IN ('season', 'try_double', 'fourweek')
	AND order_status = 2 
), past_performance AS
(
	SELECT  semester_type,
	        a.order_id,
	        a.user_id,
	        MAX(end_class_dt) AS end_class_dt,
	        MAX(is_renewal) AS is_renewal,
	        SUM(rec_cnt) AS rec_cnt,
	        SUM(fin_cnt)/SUM(rec_cnt) AS fin_rate,
	        SUM(week_fin_cnt)/SUM(fin_cnt) AS week_fin_rate,
	        SUM(day_fin_cnt)/SUM(fin_cnt) AS day_fin_rate
	FROM
	(
		SELECT  'try_double' AS semester_type,
		        order_id,
		        user_id,
		        semester_id,
		        MAX(end_class_dt) AS end_class_dt,
		        MAX(is_renewal) AS is_renewal
		FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
		WHERE dt = '${date}'
		GROUP BY  order_id,
		          user_id,
		          semester_id
		UNION ALL
		SELECT  'season' AS semester_type,
		        order_id,
		        user_id,
		        semester_id,
		        MAX(end_class_dt) AS end_class_dt,
		        MAX(is_conan_renewed) AS is_renewal
		FROM dw_conan_ads.ads_course_season_user_class_week_all_info_da
		WHERE dt = '${date}'
		GROUP BY  order_id,
		          user_id,
		          semester_id
		UNION ALL
		SELECT  'fourweek' AS semester_type,
		        order_id,
		        user_id,
		        semester_id,
		        MAX(end_class_dt) AS end_class_dt,
		        MAX(is_renewal) AS is_renewal
		FROM dw_conan_ads.ads_service_fourweek_user_quality_detail_da
		WHERE dt = '${date}'
		GROUP BY  order_id,
		          user_id,
		          semester_id
	)a
	LEFT JOIN
	(
		SELECT  user_id,
		        semester_id,
		        COUNT(distinct mission_id) AS rec_cnt,
		        COUNT(distinct if(is_finished = 1,mission_id,null)) AS fin_cnt,
		        COUNT(distinct if(is_finished_cur_week = 1,mission_id,null)) AS week_fin_cnt,
		        COUNT(distinct if(is_finished_cur_day = 1,mission_id,null)) AS day_fin_cnt
		FROM dw_dwd.dwd_eng_course_user_mission_finish_data_da
		WHERE dt = '${date}'
		GROUP BY  user_id,
		          semester_id
	)b
	ON a.user_id = b.user_id AND a.semester_id = b.semester_id
	GROUP BY  semester_type,
	          a.order_id,
	          a.user_id
), dim_semester AS
(
	SELECT  semester_id,
	        lesson_id,
	        start_stage_id,
	        semester_label
	FROM dw_dim.dim_eng_semester_da
	WHERE dt = '${date}' 
), user_city AS
(
	SELECT  user_id,
	        if(city = 1 or city is null,'其他',city) AS city,
	        city_type AS recent_city_type
	FROM
	(
		SELECT  user_id,
		        city,
		        city_type,
		        address_update_stp,
		        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY  address_update_stp DESC ) AS rn
		FROM dw_dim.dim_eng_user_subject_address_da
		WHERE dt = '${date}'
		AND subject_id IN (0, 2) 
	) t
	WHERE rn = 1 
), user_device AS
(
	SELECT  a.userid,
	        d3.device_cnt,
	        MAX(IF(rn = 1 AND d1.fst_active_tp IS NOT NULL,1,0)) AS is_active,
	        MAX(IF(rn = 1 AND d1.fst_active_tp IS NOT NULL AND d1.fst_active_tp < paidtime,1,0)) AS is_active_before,
	        MAX(IF(rn = 1 AND d1.fst_active_tp IS NOT NULL AND d1.fst_active_tp >= paidtime,(d1.fst_active_tp-paidtime)/1000/60/60,NULL)) AS active_to_buy_dourdiff,
	        MAX(IF(rn = 1 AND d1.fst_active_tp IS NOT NULL AND (d1.fst_active_tp-paidtime)/1000/60 <= 30,1,0)) AS is_active_to_buy_in30min,
	        MAX(IF(rn = 1,download_type,NULL)) AS download_type,
	        MAX(IF(rn = 1,download_vendor,NULL)) AS download_vendor,
	        MAX(IF(rn = 1,manu,NULL)) AS manu,
	        MAX(IF(rn = 1,model_new,NULL)) AS model_new,
	        MAX(IF(desc_rn = 1,download_type,NULL)) AS recently_download_type,
	        MAX(IF(desc_rn = 1,download_vendor,NULL)) AS recently_download_vendor,
	        MAX(IF(desc_rn = 1,manu,NULL)) AS recently_manu,
	        MAX(IF(desc_rn = 1,model_new,NULL)) AS recently_model_new
	FROM user_info a
	JOIN
	(
		SELECT  userid,
		        deviceid,
		        fst_active_tp,
		        min_device_active_dt AS fst_active_dt,
		        download_type,
		        download_vendor -- 下载的商店
		FROM dw_dwd.dwd_eng_device_active_user_label_da
		WHERE dt = '${date}' 
	) d1
	ON a.userid = d1.userid
	LEFT JOIN
	(
		SELECT  deviceid,
		        userid,
		        manu,
		        model_new
		FROM dw_conan_dwd.dwd_conan_user_device_type_da
		WHERE dt = '${date}' 
	) d2
	ON d1.deviceid = d2.deviceid AND d1.userid = d2.userid
	JOIN
	(
		SELECT  userid,
		        COUNT(distinct deviceid) AS device_cnt
		FROM dw_dwd.dwd_eng_device_active_user_label_da
		WHERE dt = '${date}'
		GROUP BY  userid
	) d3
	ON a.userid = d3.userid
	CROSS JOIN
	(
		SELECT  userid,
		        fst_active_tp,
		        ROW_NUMBER() OVER (PARTITION BY userid ORDER BY  fst_active_tp ASC) AS rn,
		        ROW_NUMBER() OVER (PARTITION BY userid ORDER BY fst_active_tp DESC) AS desc_rn
		FROM dw_dwd.dwd_eng_device_active_user_label_da
		WHERE dt = '${date}' 
	) d4
	ON d1.userid = d4.userid AND d1.fst_active_tp = d4.fst_active_tp
	WHERE rn = 1 or desc_rn = 1
	GROUP BY  a.userid,
	          d3.device_cnt
), user_login AS
(
	SELECT  a.userid,
	        MAX(if(rn = 1,page_type,null)) AS early_page_type,
	        MAX(if(rn = 1,channel_id,null)) AS early_channel_id,
	        MAX(if(rn = 1,model,null)) AS early_model,
	        MAX(if(desc_rn = 1,page_type,null)) AS recently_page_type,
	        MAX(if(desc_rn = 1,channel_id,null)) AS recently_channel_id,
	        MAX(if(desc_rn = 1,model,null)) AS recently_model
	FROM user_info a
	INNER JOIN
	(
		SELECT  dt,
		        user_id,
		        action_tp,
		        other['pagetype'] AS page_type,-- 登录方式，0-普通验证码登录 1-一键登录
		        other['channelid'] AS channel_id,-- 登录入口, 5-学习tab 7-我的tab斑马币 8-我的tab 28-多设备互踢 30-我的tab自动唤起 31-我的课程tab自动唤起 35-首页 Tab 登录条 210-引导登录 211-引导登录取号失败
		        CASE WHEN other['model'] LIKE 'iPhone%' AND other['model'] RLIKE '<' THEN REGEXP_EXTRACT(other['model'],'<([^\\s]+)>',1)  ELSE other['model'] END AS model,
		        other['ip'] AS ip,
		        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY  action_tp ASC ) AS rn,
		        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY action_tp DESC ) AS desc_rn
		FROM dw_dwd.dwd_eng_frog_di
		WHERE dt BETWEEN date_sub('${date}', 14) AND '${date}'
		AND default.time2dt(action_tp) = dt -- -- 登录成功
		AND url IN ('/event/LoginPage/loginSuccess')
		AND page_code IN ('LoginPage') 
	) b
	ON a.userid = b.user_id AND b.dt >= a.paid_dt
	WHERE rn = 1 or desc_rn = 1
	GROUP BY  a.userid
), user_behavior_pv AS
(
	SELECT  b.user_id,
	        COUNT(distinct if(high_acitve_type = '点击首页',action_tp,null)) AS click_main_page_pv,
	        COUNT(distinct if(high_acitve_type = '点击我的tab',action_tp,null)) AS click_my_page_pv,
	        COUNT(distinct if(high_acitve_type = '点击学习tab',action_tp,null)) AS click_study_page_pv,
	        COUNT(distinct if(high_acitve_type = '学习-全部tab-切换学科-点击了解学习内容（无学习卡片时）',action_tp,null)) AS click_study_content_pv,
	        COUNT(distinct if(high_acitve_type = '首页-点击顶部tab',action_tp,null)) AS click_top_button_pv,
	        COUNT(distinct if(high_acitve_type = '学习-（全部tab）-点击进入家长准备课页面',action_tp,null)) AS click_parent_prepare_pv,
	        COUNT(distinct if(high_acitve_type = '点击“关注公众号”按钮',action_tp,null)) AS click_gzh_pv,
	        COUNT(distinct if(high_acitve_type = '点击填写宝贝信息环节',action_tp,null)) AS click_info_pv,
	        COUNT(distinct if(high_acitve_type = '点击“添加老师微信”按钮',action_tp,null)) AS click_wx_pv,
	        COUNT(distinct if(high_acitve_type = '点击“推荐有礼”按钮',action_tp,null)) AS click_tjyl_pv,
	        COUNT(distinct if(high_acitve_type = '点击拓展tab',action_tp,null)) AS click_extension_page_pv,
	        COUNT(distinct if(high_acitve_type = '首页-(点击顶部学科tab/全部tab往下划)-点击课程/推荐卡片 ',action_tp,null)) AS click_recommend_card_pv
	FROM user_info a
	INNER JOIN
	(
		SELECT  user_id,
		        CASE WHEN url = '/event/homepage/diamond/enter' then'点击首页'
		             WHEN url = '/event/PersonalHomepage/enter' then'点击我的tab'
		             WHEN url = '/event/MissionList/Outline/enter' then'点击学习tab'
		             WHEN url = '/event/ClassIntroWechat/enter' then'学习-全部tab-切换学科-点击了解学习内容（无学习卡片时）'
		             WHEN url = '/click/LessonList/Toptab' then'首页-点击顶部tab'
		             WHEN url = '/event/ClassMission/enter' then'学习-（全部tab）-点击进入家长准备课页面'
		             WHEN url = '/click/ClassMission/followAccount' THEN '点击“关注公众号”按钮'
		             WHEN url = '/click/ClassMission/infoButton' THEN '点击填写宝贝信息环节'
		             WHEN url = '/click/ClassMission/addwechatButton' THEN '点击“添加老师微信”按钮'
		             WHEN url = '/click/ClassMission/InvitingFriend' THEN '点击“推荐有礼”按钮'
		             WHEN url = '/click/ExtensiveStudying/button' then'点击拓展tab'
		             WHEN url = '/click/CourseCard/entrance' then'首页-(点击顶部学科tab/全部tab往下划)-点击课程/推荐卡片 ' END AS high_acitve_type,
		        action_tp,
		        dt
		FROM dw_dwd.dwd_eng_frog_di
		WHERE dt BETWEEN date_sub('${date}', 14) AND '${date}'
		AND category IN ('click', 'event')
		AND page_tp IN ('h', 'P', 'M', 'C', 'L', 'E')
		AND url IN ( -- 高频行 为
 '/event/homepage/diamond/enter' , '/event/PersonalHomepage/enter' , '/event/MissionList/Outline/enter' , '/event/ClassIntroWechat/enter' , '/click/LessonList/Toptab' , '/event/ClassMission/enter' , '/click/ExtensiveStudying/button' , '/click/CourseCard/entrance' , '/click/ClassMission/followAccount', '/click/ClassMission/infoButton', '/click/ClassMission/addwechatButton', '/click/ClassMission/InvitingFriend' ) 
	) b
	ON a.userid = b.user_id AND b.dt >= a.paid_dt
	GROUP BY  b.user_id
), user_label AS
(
	SELECT  user_id,
	        label_one_class_show_name,
	        label_second_class_show_name,
	        label_category_show_name,
	        label_show_name
	FROM
	(
		SELECT  user_id,
		        top_label_show_name AS label_one_class_show_name,
		        second_label_show_name AS label_second_class_show_name,
		        third_label_show_name AS label_category_show_name,
		        fourth_label_show_name AS label_show_name,
		        ROW_NUMBER()over(PARTITION BY user_id,second_label_show_name,third_label_show_name ORDER BY  create_time DESC )as rk
		FROM dw_conan_dwd.dwd_conan_service_peace_task_user_label_new_da
		WHERE dt = '${date}'
		AND is_fourth_valid = '1'
		AND is_third_valid = '1'
		AND is_second_valid = '1'
		AND lesson_type = 'experience'
		AND top_label_show_name != '转化影响因素'
		AND third_label_show_name IN ('教育支出', '思维规划', '年级', '辅导类型') 
	) a
	WHERE rk = 1 
), user_other AS
(
	SELECT  userid,
	        count AS view_count
	FROM dw_ads.ads_eng_pipe2mentor_course_purchase_page_view_count_da
	WHERE dt = '${date}'
	AND lessonid = '46' 
), user_pay AS
(
	SELECT  userid,
	        SUM(pay_amt) AS pay_amt,
	        SUM(if(lesson_id IN ('70','46'),pay_amt,0)) AS math_pay_amt,
	        SUM(if(lesson_id IN ('70','46'),pay_amt,0))/COUNT(distinct if(lesson_id IN ('70','46'),order_id,null)) AS avg_math_pay_amt
	FROM user_info a
	JOIN
	(
		SELECT  user_id,
		        order_id,
		        lesson_id,
		        pay_amt,
		        pay_dt
		FROM dw_dwd.dwd_eng_order_course_detail_da
		WHERE dt = '${date}'
		AND order_status >= 2 
	)b
	ON a.userid = b.user_id AND b.pay_dt < a.paid_dt
	GROUP BY  userid
), user_wechat AS
(
	SELECT  user_id,
	        teacher_ldap AS ldap,
	        MAX(if(wecom_add_type = '2' or wecom_add_source = '内部成员分享',1,0)) AS is_zhudong_add
	FROM dw_dwd.dwd_conan_service_user_teacher_wechat_relation_da
	WHERE dt = '${date}'
	AND wecom_add_status = '1'
	GROUP BY  user_id,
	          teacher_ldap
)
SELECT  start_class_dt,
        semesterid,
        lesson_id AS lessonid,
        start_stage_id AS stageid,
        semester_label,
        is_age_match,
        age_buy_lesson,
        userid,
        ad_channel,
        coalesce(city,'未知') AS city,
        coalesce(recent_city_type,'unset') AS recent_city_type,
        coalesce(jiaoyu_label,'未知') AS jiaoyu_label,
        coalesce(guihua_label,'未知') AS guihua_label,
        coalesce(fudao_label,'未知') AS fudao_label,
        coalesce(nianji_label,'未知') AS nianji_label,
        coalesce(download_type,'未知') AS download_type,
        coalesce(download_vendor,'未知') AS download_vendor,
        coalesce(device_cnt,0) AS device_cnt,
        coalesce(manu,'未知') AS manu,
        coalesce(model_new,'未知') AS model_new,
        coalesce(recently_download_type,'未知') AS recently_download_type,
        coalesce(recently_download_vendor,'未知') AS recently_download_vendor,
        coalesce(recently_manu,'未知') AS recently_manu,
        coalesce(recently_model_new,'未知') AS recently_model_new,
        coalesce(is_active,0) AS is_active,
        coalesce(is_active_before,0) AS is_active_before,
        coalesce(is_active_to_buy_in30min,0) AS is_active_to_buy_in30min,
        coalesce(active_to_buy_dourdiff,0) AS active_to_buy_dourdiff,
        coalesce(early_page_type,'未知') AS early_page_type,
        coalesce(early_channel_id,'未知') AS early_channel_id,
        coalesce(early_model,'未知') AS early_model,
        coalesce(recently_page_type,'未知') AS recently_page_type,
        coalesce(recently_channel_id,'未知') AS recently_channel_id,
        coalesce(recently_model,'未知') AS recently_model,
        coalesce(is_add_wechat_before_class,0) AS is_add_wechat_before_class,
        coalesce(is_zhudong_add,0) AS is_zhudong_add,
        coalesce(view_count,0) AS view_count,
        coalesce(pay_amt,0) AS pay_amt,
        coalesce(math_pay_amt,0) AS math_pay_amt,
        coalesce(avg_math_pay_amt,0) AS avg_math_pay_amt,
        coalesce(click_main_page_pv,0) AS click_main_page_pv,
        coalesce(click_my_page_pv,0) AS click_my_page_pv,
        coalesce(click_study_page_pv,0) AS click_study_page_pv,
        coalesce(click_study_content_pv,0) AS click_study_content_pv,
        coalesce(click_top_button_pv,0) AS click_top_button_pv,
        coalesce(click_parent_prepare_pv,0) AS click_parent_prepare_pv,
        coalesce(click_gzh_pv,0) AS click_gzh_pv,
        coalesce(click_info_pv,0) AS click_info_pv,
        coalesce(click_wx_pv,0) AS click_wx_pv,
        coalesce(click_tjyl_pv,0) AS click_tjyl_pv,
        coalesce(click_extension_page_pv,0) AS click_extension_page_pv,
        coalesce(click_recommend_card_pv,0) AS click_recommend_card_pv,
        coalesce(label_cnt,0) AS label_cnt,
        CASE WHEN END_class_dt_1 is null or END_class_dt_1 = '' THEN '新用户'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) BETWEEN 30 AND 60 THEN '断课1-2个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) BETWEEN 60 AND 90 THEN '断课2-3个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) BETWEEN 90 AND 180 THEN '断课3-6个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) BETWEEN 180 AND 365 THEN '断课6-12个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) BETWEEN 365 AND 365*2 THEN '断课1-2年'
             WHEN DATEDIFF(paid_dt,end_class_dt_1) > 365*2 THEN '断课2年以上'  ELSE '其他' END AS duanke_type_1,
        coalesce(is_renewal_1,0) AS duanke_renewal_1,
        coalesce(fin_rate_1,0) AS duanke_fin_1,
        coalesce(week_fin_rate_1,0) AS duanke_week_fin_1,
        coalesce(day_fin_rate_1,0) AS duanke_day_fin_1,
        CASE WHEN END_class_dt_2 is null or END_class_dt_2 = '' THEN '新用户'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) BETWEEN 30 AND 60 THEN '断课1-2个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) BETWEEN 60 AND 90 THEN '断课2-3个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) BETWEEN 90 AND 180 THEN '断课3-6个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) BETWEEN 180 AND 365 THEN '断课6-12个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) BETWEEN 365 AND 365*2 THEN '断课1-2年'
             WHEN DATEDIFF(paid_dt,end_class_dt_2) > 365*2 THEN '断课2年以上'  ELSE '其他' END AS duanke_type_2,
        coalesce(is_renewal_2,0) AS duanke_renewal_2,
        coalesce(fin_rate_2,0) AS duanke_fin_2,
        coalesce(week_fin_rate_2,0) AS duanke_week_fin_2,
        coalesce(day_fin_rate_2,0) AS duanke_day_fin_2,
        CASE WHEN END_class_dt_3 is null or END_class_dt_3 = '' THEN '新用户'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) BETWEEN 30 AND 60 THEN '断课1-2个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) BETWEEN 60 AND 90 THEN '断课2-3个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) BETWEEN 90 AND 180 THEN '断课3-6个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) BETWEEN 180 AND 365 THEN '断课6-12个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) BETWEEN 365 AND 365*2 THEN '断课1-2年'
             WHEN DATEDIFF(paid_dt,end_class_dt_3) > 365*2 THEN '断课2年以上'  ELSE '其他' END AS duanke_type_3,
        coalesce(is_renewal_3,0) AS duanke_renewal_3,
        coalesce(fin_rate_3,0) AS duanke_fin_3,
        coalesce(week_fin_rate_3,0) AS duanke_week_fin_3,
        coalesce(day_fin_rate_3,0) AS duanke_day_fin_3,
        CASE WHEN END_class_dt_4 is null or END_class_dt_4 = '' THEN '新用户'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) BETWEEN 30 AND 60 THEN '断课1-2个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) BETWEEN 60 AND 90 THEN '断课2-3个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) BETWEEN 90 AND 180 THEN '断课3-6个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) BETWEEN 180 AND 365 THEN '断课6-12个月'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) BETWEEN 365 AND 365*2 THEN '断课1-2年'
             WHEN DATEDIFF(paid_dt,end_class_dt_4) > 365*2 THEN '断课2年以上'  ELSE '其他' END AS duanke_type_4,
        coalesce(is_renewal_4,0) AS duanke_renewal_4,
        coalesce(fin_rate_4,0) AS duanke_fin_4,
        coalesce(week_fin_rate_4,0) AS duanke_week_fin_4,
        coalesce(day_fin_rate_4,0) AS duanke_day_fin_4
FROM
(
	SELECT  a.start_class_dt,
	        a.is_age_match,
	        a.age_buy_lesson,
	        a.userid,
	        a.semesterid,
	        t.lesson_id,
	        t.start_stage_id,
	        t.semester_label,
	        a.ad_channel,
	        a.stage_name,
	        a.paid_dt,
	        b.city,
	        b.recent_city_type,
	        download_type,
	        download_vendor,
	        manu,
	        model_new,
	        recently_download_type,
	        recently_download_vendor,
	        recently_manu,
	        recently_model_new,
	        device_cnt,
	        is_active,
	        is_active_before,
	        active_to_buy_dourdiff,
	        is_active_to_buy_in30min,
	        early_page_type,
	        early_channel_id,
	        early_model,
	        recently_page_type,
	        recently_channel_id,
	        recently_model,
	        is_add_wechat_before_class,
	        is_zhudong_add,
	        view_count,
	        pay_amt,
	        math_pay_amt,
	        avg_math_pay_amt,
	        click_main_page_pv,
	        click_my_page_pv,
	        click_study_page_pv,
	        click_study_content_pv,
	        click_top_button_pv,
	        click_parent_prepare_pv,
	        click_gzh_pv,
	        click_info_pv,
	        click_wx_pv,
	        click_tjyl_pv,
	        click_extension_page_pv,
	        click_recommend_card_pv,
	        COUNT(distinct third_label_show_name) AS label_cnt,
	        MAX(i1.end_class_dt) AS end_class_dt_1,
	        MAX(i1.is_renewal) AS is_renewal_1,
	        MAX(i1.rec_cnt) AS rec_cnt_1,
	        MAX(i1.fin_rate) AS fin_rate_1,
	        MAX(i1.week_fin_rate) AS week_fin_rate_1,
	        MAX(i1.day_fin_rate) AS day_fin_rate_1,
	        MAX(i2.end_class_dt) AS end_class_dt_2,
	        MAX(i2.is_renewal) AS is_renewal_2,
	        MAX(i2.rec_cnt) AS rec_cnt_2,
	        MAX(i2.fin_rate) AS fin_rate_2,
	        MAX(i2.week_fin_rate) AS week_fin_rate_2,
	        MAX(i2.day_fin_rate) AS day_fin_rate_2,
	        MAX(i3.end_class_dt) AS end_class_dt_3,
	        MAX(i3.is_renewal) AS is_renewal_3,
	        MAX(i3.rec_cnt) AS rec_cnt_3,
	        MAX(i3.fin_rate) AS fin_rate_3,
	        MAX(i3.week_fin_rate) AS week_fin_rate_3,
	        MAX(i3.day_fin_rate) AS day_fin_rate_3,
	        MAX(i4.end_class_dt) AS end_class_dt_4,
	        MAX(i4.is_renewal) AS is_renewal_4,
	        MAX(i4.rec_cnt) AS rec_cnt_4,
	        MAX(i4.fin_rate) AS fin_rate_4,
	        MAX(i4.week_fin_rate) AS week_fin_rate_4,
	        MAX(i4.day_fin_rate) AS day_fin_rate_4,
	        MAX(if(label_category_show_name = '教育支出',label_show_name,null)) AS jiaoyu_label,
	        MAX(if(label_category_show_name = '思维规划',label_show_name,null)) AS guihua_label,
	        MAX(if(label_category_show_name = '辅导类型',label_show_name,null)) AS fudao_label,
	        MAX(if(label_category_show_name = '年级',label_show_name,null)) AS nianji_label
	FROM user_info a -- 城市信息
	LEFT JOIN dim_semester t
	ON a.semesterid = t.semester_id
	LEFT JOIN user_city b
	ON a.userid = b.user_id
	LEFT JOIN user_wechat c
	ON a.userid = c.user_id AND a.ldap = c.ldap
	LEFT JOIN user_other f
	ON a.userid = f.userid
	LEFT JOIN user_pay g
	ON a.userid = g.userid
	LEFT JOIN user_device d
	ON a.userid = d.userid
	LEFT JOIN user_login e
	ON a.userid = e.userid
	LEFT JOIN user_label j
	ON a.userid = j.user_id AND (j.label_second_class_show_name = '通用' or j.label_second_class_show_name = a.label_stage_name)
	LEFT JOIN user_behavior_pv n
	ON a.userid = n.user_id
	LEFT JOIN
	(
		SELECT  user_id,
		        second_label_show_name AS label_second_class_show_name,
		        third_label_show_name
		FROM dw_conan_dwd.dwd_conan_service_peace_task_user_label_new_da
		WHERE dt = '${date}'
		AND is_fourth_valid = '1'
		AND is_third_valid = '1'
		AND is_second_valid = '1'
		AND lesson_type = 'experience'
		AND top_label_show_name != '转化影响因素' 
	)o
	ON a.userid = o.user_id AND (o.label_second_class_show_name = '通用' or o.label_second_class_show_name = a.label_stage_name)
	LEFT JOIN --同科同级别
	(
		SELECT  userid,
		        order_id,
		        semester_type
		FROM
		(
			SELECT  a.userid,
			        b.order_id,
			        b.semester_type,
			        ROW_NUMBER() OVER (PARTITION BY a.userid ORDER BY  b.pay_dt DESC) AS rk
			FROM user_info a
			JOIN past_order b
			ON a.userid = b.user_id AND b.pay_dt < a.paid_dt AND a.stage_name = b.stage_name AND subject_id = 2
		)
		WHERE rk = 1 
	)h1
	ON a.userid = h1.userid
	LEFT JOIN past_performance i1
	ON h1.order_id = i1.order_id AND h1.semester_type = i1.semester_type
	LEFT JOIN --同科不同级别
	(
		SELECT  userid,
		        order_id,
		        semester_type
		FROM
		(
			SELECT  a.userid,
			        b.order_id,
			        b.semester_type,
			        ROW_NUMBER() OVER (PARTITION BY a.userid ORDER BY  b.pay_dt DESC) AS rk
			FROM user_info a
			JOIN past_order b
			ON a.userid = b.user_id AND b.pay_dt < a.paid_dt AND a.stage_name != b.stage_name AND subject_id = 2
		)
		WHERE rk = 1 
	)h2
	ON a.userid = h2.userid
	LEFT JOIN past_performance i2
	ON h2.order_id = i2.order_id AND h2.semester_type = i2.semester_type
	LEFT JOIN --不同科
	(
		SELECT  userid,
		        order_id,
		        semester_type
		FROM
		(
			SELECT  a.userid,
			        b.order_id,
			        b.semester_type,
			        ROW_NUMBER() OVER (PARTITION BY a.userid ORDER BY  b.pay_dt DESC) AS rk
			FROM user_info a
			JOIN past_order b
			ON a.userid = b.user_id AND b.pay_dt < a.paid_dt AND subject_id != 2
		)
		WHERE rk = 1 
	)h3
	ON a.userid = h3.userid
	LEFT JOIN past_performance i3
	ON h3.order_id = i3.order_id AND h3.semester_type = i3.semester_type
	LEFT JOIN
	(
		SELECT  userid,
		        order_id,
		        semester_type
		FROM
		(
			SELECT  a.userid,
			        b.order_id,
			        b.semester_type,
			        ROW_NUMBER() OVER (PARTITION BY a.userid ORDER BY  b.pay_dt DESC) AS rk
			FROM user_info a
			JOIN past_order b
			ON a.userid = b.user_id AND b.pay_dt < a.paid_dt
		)
		WHERE rk = 1 
	)h4
	ON a.userid = h4.userid
	LEFT JOIN past_performance i4
	ON h4.order_id = i4.order_id AND h4.semester_type = i4.semester_type
	GROUP BY  a.start_class_dt,
	          a.is_age_match,
	          a.age_buy_lesson,
	          a.userid,
	          a.semesterid,
	          t.lesson_id,
	          t.start_stage_id,
	          t.semester_label,
	          a.ad_channel,
	          a.stage_name,
	          a.paid_dt,
	          b.city,
	          b.recent_city_type,
	          download_type,
	          download_vendor,
	          manu,
	          model_new,
	          recently_download_type,
	          recently_download_vendor,
	          recently_manu,
	          recently_model_new,
	          device_cnt,
	          is_active,
	          is_active_before,
	          active_to_buy_dourdiff,
	          is_active_to_buy_in30min,
	          early_page_type,
	          early_channel_id,
	          early_model,
	          recently_page_type,
	          recently_channel_id,
	          recently_model,
	          is_add_wechat_before_class,
	          is_zhudong_add,
	          view_count,
	          pay_amt,
	          math_pay_amt,
	          avg_math_pay_amt,
	          click_main_page_pv,
	          click_my_page_pv,
	          click_study_page_pv,
	          click_study_content_pv,
	          click_top_button_pv,
	          click_parent_prepare_pv,
	          click_gzh_pv,
	          click_info_pv,
	          click_wx_pv,
	          click_tjyl_pv,
	          click_extension_page_pv,
	          click_recommend_card_pv
)a
