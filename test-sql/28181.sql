--思维中价退费情况
WITH detail AS
(
	SELECT  a.start_class_dt,
	        s.end_class_dt,
	        a.user_id,
  a.lesson_id,
	        MAX(a.stage_name) AS stage_name,
	        MAX(CASE WHEN ad_channel in ('抖音中价','腾讯中价','其他中价','电商中价') AND accountid is null or accountid = '' THEN '无账户' WHEN ad_channel in ('抖音中价','腾讯中价','其他中价','电商中价') AND accountid IN ('1822030030407690','1822027034104842','1822030131404891','1761605098022045','1761242332601421','1768215457237069','1773641570409549','1738048746778632','1786225457446027') THEN '拼接账户' WHEN ad_channel in ('抖音中价','腾讯中价','其他中价','电商中价') THEN '常规账户' ELSE '其他' END) AS account_type,
	        MAX(age_buy_lesson_type) AS age_buy_lesson_type,
	        MAX(a.pay_dt) AS pay_dt,
	        MAX(s.parent_semester_id) AS parent_semester_id,
  max(s.semester_tag) as semester_tag,
	        MAX(refund_dt) AS refund_dt,
	        MIN(if(is_finish_end = 1,1,0)) AS is_finish_end,
	        MAX(if(m.user_id is not null,1,0)) AS is_after_season,
	        MAX(if(n.user_id is not null,1,0)) AS is_before_season,
	        MAX(validation) AS validation,
	        MAX(if(is_gou = 1,1,0)) AS is_gou,
	        MAX(j.end_class_dt) AS pre_end_class_dt,
	        MAX(if(f.user_id is not null,1,0)) AS is_live
	FROM
	(
		SELECT  user_id,
		        semesterid,
      a.lesson_id,
		        start_class_dt,
		        order_id,
		        stage_name,
		        parent_order_id,
		        subject_id,
		        keyfrom,
		        refund_dt,
		        refund_tp,
		        pay_dt,
		        pay_tp,
		        age_buy_lesson_type,
		        ad_channel,
		        classid,
		        teacherid,
		        ldap,
		        is_finish_end,
		        is_season
		FROM
		(
			SELECT  user_id,
			        order_id,
          a.lesson_id,
			        stage_name,
			        pay_dt,
			        pay_tp,
			        subject_id,
			        parent_order_id,
			        keyfrom,
			        order_status,
			        start_class_dt,
			        age_buy_lesson_type,
			        ad_channel,
			        semesterid,
			        classid,
			        teacherid,
			        ldap,
			        refund_dt,
			        refund_tp,
			        is_finish_end,
			        is_season,
			        dt,
			        ROW_NUMBER()over(PARTITION BY a.order_id ORDER BY  dt DESC) AS rk
			FROM
			(
				SELECT  user_id,
				        order_id,
              a.lesson_id,
				        stage_name,
				        pay_dt,
				        pay_tp,
				        subject_id,
				        parent_order_id,
				        keyfrom,
				        order_status,
				        start_class_dt,
				        age_buy_lesson_type,
				        ad_channel,
				        semesterid,
				        classid,
				        teacherid,
				        ldap,
				        refund_dt,
				        refund_tp
				FROM
				(
					SELECT  a.user_id,
					        a.order_id,
                  a.lesson_id,
					        stage_name,
					        a.pay_dt,
					        a.pay_tp,
					        a.subject_id,
					        a.parent_order_id,
					        a.keyfrom,
					        a.order_status,
					        a.start_class_dt,
					        a.age_buy_lesson_type,
					        a.ad_channel,
					        b.semesterid,
					        classid,
					        teacherid,
					        ldap,
					        if(c.refund_dt is not null,c.refund_dt,null) AS refund_dt,
					        if(c.refund_tp is not null,c.refund_tp,null) AS refund_tp,
					        ROW_NUMBER()over(PARTITION BY a.user_id,a.start_class_dt,a.subject_id ORDER BY  coalesce(c.refund_dt,9999999999999) DESC) AS rk
					FROM
					(
						SELECT  a.user_id,
						        a.order_id,
                      a.lesson_id,
						        a.pay_dt,
						        a.pay_tp,
						        a.subject_id,
						        a.parent_order_id,
						        a.keyfrom,
						        a.order_status,
						        a.refund_related_weekcount,
						        a.start_class_dt,
						        age_buy_lesson_type,
						        ad_channel,
						        stage_name
						FROM
						(
							SELECT  user_id,
							        order_id,
							        pay_dt,
							        pay_tp,
							        subject_id,
							        parent_order_id,
							        keyfrom,
							        order_status,
							        refund_related_weekcount,
							        regexp_replace(split(period_type,'-') [1],'\\/','\\-') AS start_class_dt,
							        lesson_id,
							        stage_name
							FROM dw_dwd.dwd_eng_order_course_detail_da
							WHERE dt = DATE_SUB(CURRENT_DATE, 1)
							AND semester_type IN ('try_double')
							AND subject_id = 2
							AND {{regexp_replace(split(period_type, '-') [1], '\\/', '\\-') AS start_class_dt}} 
						)a
						JOIN
						(
							SELECT  user_id,
							        order_id,
							        CASE WHEN age_buy_lesson >= 0 AND age_buy_lesson < 2 THEN '0-2岁'
							             WHEN age_buy_lesson >= 2 AND age_buy_lesson < 3 THEN '2-3岁'
							             WHEN age_buy_lesson >= 3 AND age_buy_lesson < 4 THEN '3-4岁'
							             WHEN age_buy_lesson >= 4 AND age_buy_lesson < 5 THEN '4-5岁'
							             WHEN age_buy_lesson >= 5 AND age_buy_lesson < 6 THEN '5-6岁'
							             WHEN age_buy_lesson >= 6 AND age_buy_lesson < 7 THEN '6-7岁'
							             WHEN age_buy_lesson >= 7 AND age_buy_lesson < 8 THEN '7-8岁'
							             WHEN age_buy_lesson >= 8 AND age_buy_lesson < 9 THEN '8-9岁'
							             WHEN age_buy_lesson >= 9 THEN '9岁以上'  ELSE '未设置' END AS age_buy_lesson_type,
							        ad_channel
							FROM dw_conan_dwd.dwd_trade_try_double_order_from_info_da
							WHERE dt = date_sub(CURRENT_DATE, 1)
							AND ad_channel in ('抖音中价','腾讯中价','其他中价','电商中价')
						)b
						ON a.order_id = b.order_id
						LEFT JOIN
						(
							SELECT  parent_order_id,
							        MAX(if(subject_id = 1,1,0)) AS has_eng,
							        MAX(if(subject_id = 2,1,0)) AS has_math
							FROM dw_dwd.dwd_eng_order_course_detail_da
							WHERE dt = date_sub(CURRENT_DATE, 1)
							AND semester_type IN ('try_double')
							AND order_status >= 2
							AND order_id != parent_order_id -- 父订单和子订单不是同一个订单
							GROUP BY  parent_order_id
						)c
						ON a.parent_order_id = c.parent_order_id
						WHERE (has_eng is null or has_eng = 0) 
					) a
					LEFT JOIN
					( -- 订单 表
						SELECT  b.*,
						        orderid,
						        ldap
						FROM
						(
							SELECT  orderid,
							        userid,
							        id
							FROM dw_ods.ods_conan_fulfill_center_wares_fulfill_order_item_da
							WHERE dt = DATE_SUB(CURRENT_DATE, 1) 
						) a
						JOIN
						( -- 分班 表
							SELECT  userid,
							        semesterid,
							        classid,
							        teacherid,
							        from_unixtime(int(startclasstime / 1000),'yyyy-MM-dd') AS start_class_dt,
							        GET_JSON_OBJECT(allocateexpinfo,'$.fulfillOrderId') AS fulfill_order_id
							FROM dw_ods.ods_conan_allocate_teacher_student_allocate_sub_lesson_da
							WHERE dt = date_sub(CURRENT_DATE, 1)
							AND lessonid IN ('70','830')
							AND type = 1
							AND status <> 3 
						) b
						ON a.userid = b.userid AND b.fulfill_order_id = a.id
						LEFT JOIN
						(
							SELECT  mentor_ldap AS ldap,
							        tf.key AS teacherid
							FROM dw_dim.dim_eng_mentor_info_da lateral view explode(wechat_info) tf AS key, value
							WHERE dt = date_sub(current_date, 1) 
						)c
						ON b.teacherid = c.teacherid
					) b
					ON a.order_id = b.orderid
					LEFT JOIN
					( -- 退款 表
						SELECT  order_id,
						        from_unixtime(int(refund_tp / 1000),'yyyy-MM-dd') AS refund_dt,
						        refund_tp,
						        refundment_type_name
						FROM dw_dwd.dwd_conan_trade_refund_da
						WHERE dt = date_sub(CURRENT_DATE, 1)
						AND refund_status_code = 2 -- 成功
						AND refundment_type_name IN ('退课退款') 
					) c
					ON a.order_id = c.order_id
				)a
				WHERE rk = 1 
			)a
			LEFT JOIN
			(
				SELECT  user_id AS userid,
				        order_id AS orderid,
				        is_finish_end_class AS is_finish_end,
				        is_renewal AS is_season,
				        dt,
				        end_class_dt
				FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
				WHERE dt BETWEEN date_sub(start_class_dt, 21) AND date_add(end_class_dt, 14)
				AND {{start_class_dt}} 
              AND semester_label != '虚拟'
			) d
			ON a.order_id = d.orderid AND refund_dt is not null AND d.dt <= a.refund_dt
		)a
		WHERE rk = 1 
	)a
	LEFT JOIN
	(
		SELECT  semester_id,
		        parent_semester_id,
		        experiment_tag AS semester_tag,
		        is_bundled,
		        subject_id AS subject,
		        end_class_dt,
		        lesson_id
		FROM dw_dim.dim_eng_semester_da
		WHERE dt = date_sub(current_date, 1) 
	) s
	ON a.semesterid = s.semester_id
	LEFT JOIN
	(
		SELECT  user_id,
		        order_id,
		        pay_dt,
		        subject_id,
		        pay_tp,
		        first_refund_tp,
		        first_refund_dt,
		        refund_related_weekcount
		FROM
		(
			SELECT  user_id,
			        order_id,
			        pay_dt,
			        subject_id,
			        pay_tp,
			        first_refund_tp,
			        from_unixtime(int(first_refund_tp/1000),'yyyy-MM-dd') AS first_refund_dt,
			        refund_related_weekcount
			FROM dw_dwd.dwd_eng_order_course_detail_da
			WHERE dt = DATE_SUB(CURRENT_DATE, 1)
			AND semester_type IN ('season')
			AND order_status >= 2 
		) a
		LEFT JOIN
		(
			SELECT  renewal_order_id AS renewal_orderid
			FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
			WHERE dt = date_sub(current_date, 1)
			AND is_renewal = 1 
          AND semester_label != '虚拟'
		)b
		ON a.order_id = b.renewal_orderid
		WHERE b.renewal_orderid is null 
	)m
	ON a.user_id = m.user_id AND a.subject_id = m.subject_id AND m.pay_tp > a.refund_tp AND a.refund_tp is not null AND m.pay_dt <= date_add(s.end_class_dt, 7) AND (m.first_refund_tp is null or m.refund_related_weekcount <= 0 or m.first_refund_dt > date_add(s.end_class_dt, 14))
	LEFT JOIN
	(
		SELECT  userid,
		        classid,
		        MIN(createdtime) AS enter_class_time
		FROM dw_ods.ods_conan_receipt_user_assign_class_log_da
		WHERE dt = date_sub(current_date, 1)
		GROUP BY  userid,
		          classid
	)t
	ON a.user_id = t.userid AND a.classid = t.classid
	LEFT JOIN
	(
		SELECT  user_id,
		        order_id,
		        pay_dt,
		        subject_id,
		        pay_tp,
		        first_refund_tp,
		        first_refund_dt,
		        refund_related_weekcount
		FROM
		(
			SELECT  user_id,
			        order_id,
			        pay_dt,
			        subject_id,
			        pay_tp,
			        first_refund_tp,
			        from_unixtime(int(first_refund_tp/1000),'yyyy-MM-dd') AS first_refund_dt,
			        refund_related_weekcount
			FROM dw_dwd.dwd_eng_order_course_detail_da
			WHERE dt = DATE_SUB(CURRENT_DATE, 1)
			AND semester_type IN ('season')
			AND order_status >= 2 
		) a
		LEFT JOIN
		(
			SELECT  renewal_order_id AS renewal_orderid
			FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
			WHERE dt = date_sub(current_date, 1)
			AND is_renewal = 1 
          AND semester_label != '虚拟'
		)b
		ON a.order_id = b.renewal_orderid
		WHERE b.renewal_orderid is null 
	)n
	ON a.user_id = n.user_id AND a.subject_id = n.subject_id AND n.pay_tp < a.refund_tp AND a.refund_tp is not null AND n.pay_tp > t.enter_class_time AND n.pay_dt <= date_add(s.end_class_dt, 7) AND (n.first_refund_tp is null or n.refund_related_weekcount <= 0 or n.first_refund_dt > date_add(s.end_class_dt, 14))
	LEFT JOIN
	(
		SELECT  userid,
		        ldap,
		        from_unixtime(int(createdtime/1000),'yyyy-MM-dd') AS create_dt,
		        MAX(validation) AS validation,
		        MAX(1) AS is_gou
		FROM dw_ods.ods_conan_mentor_task_interview_da
		WHERE dt = date_sub(current_date, 1)
		GROUP BY  userid,
		          ldap,
		          from_unixtime(int(createdtime/1000),'yyyy-MM-dd')
	)e
	ON a.user_id = e.userid AND a.ldap = e.ldap AND a.refund_dt is not null AND e.create_dt <= a.refund_dt AND create_dt >= date_sub(a.start_class_dt, 14)
	LEFT JOIN
	(
		SELECT  user_id,
		        teacher_ldap,
		        from_unixtime(int(start_time/1000),'yyyy-MM-dd') AS start_dt
		FROM dw_conan_dwd.dwd_service_live_user_class_da
		WHERE dt = date_sub(current_date, 1)
		AND sky_episode_business_type IN ('2', '7')
		AND CAST(first_enter_time AS BIGINT) > 0
		AND CAST(valid_watch_time AS BIGINT) > 0 
	)f
	ON a.user_id = f.user_id AND a.ldap = f.teacher_ldap AND f.start_dt >= date_sub(a.start_class_dt, 28) AND f.start_dt <= a.refund_dt AND a.refund_dt is not null
	LEFT JOIN
	(
		SELECT  distinct outorderid,
		        outoriginorderid,
		        orderid
		FROM dw_conan_dwd.dwd_conan_growth_thirdapi_third_order_tuomin_da ---外部订单信息
		WHERE dt = date_sub(current_date, 1) 
	)g
	ON a.order_id = g.orderid
	LEFT JOIN
	(
		SELECT  toto.outerorderid,
		        adgroupid,
		        adgroupname,
		        accountid,
		        source
		FROM
		(
			SELECT  outerorderid,
			        applyaccountid
			FROM dw_ods.ods_conan_promotion_data_aggregate_ad_outer_order_da
			WHERE dt = date_sub(current_date, 1)
			GROUP BY  outerorderid,
			          applyaccountid
		)toto
		JOIN
		(
			SELECT  adgroupid,
			        adgroupname,
			        accountid,
			        source
			FROM dw_ods.ods_conan_commerce_marketing_ad_base_info_da
			WHERE dt = date_sub(current_date, 1)
			GROUP BY  adgroupid,
			          accountid,
			          source,
			          adgroupname
		)p
		ON toto.applyaccountid = p.adgroupid
	)h
	ON g.outoriginorderid = h.outerorderid
	LEFT JOIN
	(
		SELECT  user_id,
		        order_id,
		        semester_type,
		        pay_dt,
		        subject_name,
		        subject_id
		FROM dw_dwd.dwd_eng_order_course_detail_da
		WHERE dt = DATE_SUB(CURRENT_DATE, 1)
		AND semester_type IN ('season', 'try_double', 'fourweek')
		AND order_status = 2 
	)i
	ON a.user_id = i.user_id AND i.pay_dt < a.pay_dt
	LEFT JOIN
	(
		SELECT  'try_double' AS semester_type,
		        order_id,
		        user_id,
		        MAX(end_class_dt) AS end_class_dt
		FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
		WHERE dt = DATE_SUB(CURRENT_DATE, 1)
      AND semester_label != '虚拟'
		GROUP BY  order_id,
		          user_id
		UNION ALL
		SELECT  'season' AS semester_type,
		        order_id,
		        user_id,
		        MAX(end_class_dt) AS end_class_dt
		FROM dw_conan_dwd.dwd_course_season_user_lesson_receipt_da
		WHERE dt = DATE_SUB(CURRENT_DATE, 1)
		GROUP BY  order_id,
		          user_id
		UNION ALL
		SELECT  'fourweek' AS semester_type,
		        order_id,
		        user_id,
		        MAX(end_class_dt) AS end_class_dt
		FROM dw_conan_ads.ads_service_fourweek_user_quality_detail_da
		WHERE dt = DATE_SUB(CURRENT_DATE, 1)
		GROUP BY  order_id,
		          user_id
	)j
	ON i.order_id = j.order_id AND i.semester_type = j.semester_type
	GROUP BY  a.start_class_dt,
	          s.end_class_dt,
	          a.user_id,
  a.lesson_id
) 
--退费前发生有效沟通行为的占比、退费前发生老师直播行为的占比、退费用户退前的完课率、退费前续报占比（*订单维度退费发生时间和系统课退费发生时间）
SELECT  a.start_class_dt,
a.mode,
        a.stage_name,
        a.account_type,
        a.age_buy_lesson_type,
        a.duanke_type,
        refunt_dt,
        order_cnt,
        b.tui_cnt/order_cnt AS all_tui_rate,
        a.tui_cnt/order_cnt AS tui_rate,
        gou_cnt/a.tui_cnt AS gou_rate,
        valid_cnt/a.tui_cnt AS valid_rate,
        live_cnt/a.tui_cnt AS live_rate,
        finish_end_cnt/a.tui_cnt AS finish_end_rate,
        before_season_cnt/a.tui_cnt AS before_season_rate,
        after_season_cnt/a.tui_cnt AS after_season_rate
FROM
(
	SELECT  start_class_dt,
  coalesce(case when (semester_tag like '%A%' or lesson_id=830) then '独立分班' else '非独立分班' end,'total_count') AS mode,
	        coalesce(stage_name,'total_count') AS stage_name,
	        coalesce(account_type,'total_count') AS account_type,
	        coalesce(age_buy_lesson_type,'total_count') AS age_buy_lesson_type,
	        coalesce(CASE WHEN pre_end_class_dt is null or pre_end_class_dt = '' THEN '新用户' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 30 AND 60 THEN '断课1-2个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 60 AND 90 THEN '断课2-3个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 90 AND 180 THEN '断课3-6个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 180 AND 365 THEN '断课6-12个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 365 AND 365*2 THEN '断课1-2年' WHEN DATEDIFF(pay_dt,pre_end_class_dt) > 365*2 THEN '断课2年以上' ELSE '其他' END,'total_count') AS duanke_type,
	        CASE WHEN parent_semester_id is null AND refund_dt <= date_sub(start_class_dt,14) THEN 'W-1D1'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,13) THEN 'W-1D2'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,12) THEN 'W-1D3'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,11) THEN 'W-1D4'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,10) THEN 'W-1D5'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,9) THEN 'W-1D6'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,8) THEN 'W-1D7'
	             WHEN parent_semester_id is null AND refund_dt >= date_sub(start_class_dt,7) THEN '分班前-W0D1'
	             WHEN refund_dt <= date_sub(start_class_dt,7) THEN '分班后-W0D1'
	             WHEN refund_dt = date_sub(start_class_dt,6) THEN 'W0D2'
	             WHEN refund_dt = date_sub(start_class_dt,5) THEN 'W0D3'
	             WHEN refund_dt = date_sub(start_class_dt,4) THEN 'W0D4'
	             WHEN refund_dt = date_sub(start_class_dt,3) THEN 'W0D5'
	             WHEN refund_dt = date_sub(start_class_dt,2) THEN 'W0D6'
	             WHEN refund_dt = date_sub(start_class_dt,1) THEN 'W0D7'
	             WHEN refund_dt = start_class_dt THEN 'W1D1'
	             WHEN refund_dt = date_add(start_class_dt,1) THEN 'W1D2'
	             WHEN refund_dt = date_add(start_class_dt,2) THEN 'W1D3'
	             WHEN refund_dt = date_add(start_class_dt,3) THEN 'W1D4'
	             WHEN refund_dt = date_add(start_class_dt,4) THEN 'W1D5'
	             WHEN refund_dt = date_add(start_class_dt,5) THEN 'W1D6'
	             WHEN refund_dt = date_add(start_class_dt,6) THEN 'W1D7'
	             WHEN refund_dt > date_add(start_class_dt,6) AND refund_dt <= END_class_dt THEN 'W2'
	             WHEN refund_dt > END_class_dt AND refund_dt <= date_add(end_class_dt,7) THEN 'W3'
	             WHEN refund_dt > date_add(end_class_dt,7) THEN 'W4'  ELSE '其他' END AS refunt_dt,
	        COUNT(distinct if(refund_dt is not null,user_id,null)) AS tui_cnt,
	        COUNT(distinct if(is_gou = 1 AND refund_dt is not null,user_id,null)) AS gou_cnt,
	        COUNT(distinct if(validation = 1 AND refund_dt is not null,user_id,null)) AS valid_cnt,
	        COUNT(distinct if(is_live = 1 AND refund_dt is not null,user_id,null)) AS live_cnt,
	        COUNT(distinct if(is_finish_end = 1 AND refund_dt is not null,user_id,null)) AS finish_end_cnt,
	        COUNT(distinct if(is_before_season = 1 AND refund_dt is not null,user_id,null)) AS before_season_cnt,
	        COUNT(distinct if(is_after_season = 1 AND refund_dt is not null,user_id,null)) AS after_season_cnt
	FROM detail
	WHERE refund_dt is not null
	GROUP BY  start_class_dt,
	          CASE WHEN parent_semester_id is null AND refund_dt <= date_sub(start_class_dt,14) THEN 'W-1D1'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,13) THEN 'W-1D2'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,12) THEN 'W-1D3'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,11) THEN 'W-1D4'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,10) THEN 'W-1D5'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,9) THEN 'W-1D6'
	             WHEN parent_semester_id is null AND refund_dt = date_sub(start_class_dt,8) THEN 'W-1D7'
	             WHEN parent_semester_id is null AND refund_dt >= date_sub(start_class_dt,7) THEN '分班前-W0D1'
	             WHEN refund_dt <= date_sub(start_class_dt,7) THEN '分班后-W0D1'
	             WHEN refund_dt = date_sub(start_class_dt,6) THEN 'W0D2'
	             WHEN refund_dt = date_sub(start_class_dt,5) THEN 'W0D3'
	             WHEN refund_dt = date_sub(start_class_dt,4) THEN 'W0D4'
	             WHEN refund_dt = date_sub(start_class_dt,3) THEN 'W0D5'
	             WHEN refund_dt = date_sub(start_class_dt,2) THEN 'W0D6'
	             WHEN refund_dt = date_sub(start_class_dt,1) THEN 'W0D7'
	             WHEN refund_dt = start_class_dt THEN 'W1D1'
	             WHEN refund_dt = date_add(start_class_dt,1) THEN 'W1D2'
	             WHEN refund_dt = date_add(start_class_dt,2) THEN 'W1D3'
	             WHEN refund_dt = date_add(start_class_dt,3) THEN 'W1D4'
	             WHEN refund_dt = date_add(start_class_dt,4) THEN 'W1D5'
	             WHEN refund_dt = date_add(start_class_dt,5) THEN 'W1D6'
	             WHEN refund_dt = date_add(start_class_dt,6) THEN 'W1D7'
	             WHEN refund_dt > date_add(start_class_dt,6) AND refund_dt <= END_class_dt THEN 'W2'
	             WHEN refund_dt > END_class_dt AND refund_dt <= date_add(end_class_dt,7) THEN 'W3'
	             WHEN refund_dt > date_add(end_class_dt,7) THEN 'W4'  ELSE '其他' END,
	          cube(case when  (semester_tag like '%A%' or lesson_id=830)  then '独立分班' else '非独立分班' end,stage_name,account_type,age_buy_lesson_type,CASE WHEN pre_end_class_dt is null or pre_end_class_dt = '' THEN '新用户' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 30 AND 60 THEN '断课1-2个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 60 AND 90 THEN '断课2-3个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 90 AND 180 THEN '断课3-6个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 180 AND 365 THEN '断课6-12个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 365 AND 365*2 THEN '断课1-2年' WHEN DATEDIFF(pay_dt,pre_end_class_dt) > 365*2 THEN '断课2年以上' ELSE '其他' END)
)a
LEFT JOIN
(
	SELECT  start_class_dt,
  coalesce(case when  (semester_tag like '%A%' or lesson_id=830) then '独立分班' else '非独立分班' end,'total_count') AS mode,
	        coalesce(stage_name,'total_count') AS stage_name,
	        coalesce(account_type,'total_count') AS account_type,
	        coalesce(age_buy_lesson_type,'total_count') AS age_buy_lesson_type,
	        coalesce(CASE WHEN pre_end_class_dt is null or pre_end_class_dt = '' THEN '新用户' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 30 AND 60 THEN '断课1-2个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 60 AND 90 THEN '断课2-3个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 90 AND 180 THEN '断课3-6个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 180 AND 365 THEN '断课6-12个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 365 AND 365*2 THEN '断课1-2年' WHEN DATEDIFF(pay_dt,pre_end_class_dt) > 365*2 THEN '断课2年以上' ELSE '其他' END,'total_count') AS duanke_type,
	        COUNT(distinct user_id) AS order_cnt,
	        COUNT(distinct if(refund_dt is not null,user_id,null)) AS tui_cnt
	FROM detail
	GROUP BY  start_class_dt,
	          cube(case when  (semester_tag like '%A%' or lesson_id=830)  then '独立分班' else '非独立分班' end,stage_name,account_type,age_buy_lesson_type,CASE WHEN pre_end_class_dt is null or pre_end_class_dt = '' THEN '新用户' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 30 AND 60 THEN '断课1-2个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 60 AND 90 THEN '断课2-3个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 90 AND 180 THEN '断课3-6个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 180 AND 365 THEN '断课6-12个月' WHEN DATEDIFF(pay_dt,pre_end_class_dt) BETWEEN 365 AND 365*2 THEN '断课1-2年' WHEN DATEDIFF(pay_dt,pre_end_class_dt) > 365*2 THEN '断课2年以上' ELSE '其他' END)
)b
ON a.start_class_dt = b.start_class_dt and a.mode=b.mode AND a.account_type = b.account_type AND a.age_buy_lesson_type = b.age_buy_lesson_type AND a.duanke_type = b.duanke_type AND a.stage_name = b.stage_name