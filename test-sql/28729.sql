--用户粒度课前是否退费、是否被1v1覆盖、参课沟通时长 
--是否被参课沟通、是否被1v1覆盖拆成「建课」和「有效」两个
WITH refund_base AS
(
	SELECT  a.userid,
	        a.orderid,
	        start_class_dt,
	        semesterid,
	        classid,
	        teacherid,
	        ldap,
	        refund_dt,
	        refund_tp,
	        is_finish_end_class,
	        is_attend_first_day
	FROM
	(
		SELECT  a.userid,
		        a.orderid,
		        start_class_dt,
		        semesterid,
		        classid,
		        teacherid,
		        ldap,
		        refund_dt,
		        refund_tp,
		        is_finish_end_class,
		        is_attend_first_day,
		        dt,
		        ROW_NUMBER()over(PARTITION BY a.orderid ORDER BY  dt DESC) AS rk
		FROM
		(
			SELECT  userid,
			        orderid,
			        start_class_dt,
			        semesterid,
			        classid,
			        teacherid,
			        ldap,
			        refund_dt,
			        refund_tp
			FROM
			(
				SELECT  a.userid,
				        a.orderid,
				        a.start_class_dt,
				        a.semesterid,
				        classid,
				        teacherid,
				        ldap,
				        if(b.refund_dt is not null,b.refund_dt,null) AS refund_dt,
				        if(b.refund_tp is not null,b.refund_tp,null) AS refund_tp,
				        ROW_NUMBER()over(PARTITION BY a.userid,a.start_class_dt ORDER BY  coalesce(b.refund_dt,9999999999999) DESC) AS rk
				FROM
				(
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
						AND lessonid IN ('800')
						AND type = 1
						AND status <> 3
						AND {{from_unixtime(int(startclasstime / 1000), 'yyyy-MM-dd') AS start_class_dt}} 
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
				)a
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
				) b
				ON a.orderid = b.order_id
			)a
			WHERE rk = 1
			AND refund_tp is not null 
		)a
		LEFT JOIN
		(
			SELECT  user_id AS userid,
			        order_id AS orderid,
			        if(received_mission_num = 8 AND received_mission_num = end_finished_mission_num,1,0) AS is_finish_end_class,
			        is_attend_first_day,
			        dt
			FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
			WHERE dt BETWEEN start_class_dt AND end_class_dt
			AND {{start_class_dt}} 
			AND semester_label != '虚拟'
		) d
		ON a.orderid = d.orderid AND d.dt <= a.refund_dt
	) a
	WHERE rk = 1 
) , detail AS
(
	SELECT  a.*,
	        third_channel
	FROM
	(
		SELECT  '未退费' AS user_type,
		        a.start_class_dt,
		        stage_name,
		        a.userid,
		        a.order_id,
		        a.teacher_ldap AS ldap,
		        is_canke,
		        is_canke_valid,
		        canke_duration,
		        SUM(valid_watch_time) AS valid_watch_time,
		        MAX(if(b.user_id is not null,1,0)) AS is_send_1v1,
		        MAX(if(b.user_id is not null AND CAST(b.first_enter_time AS BIGINT) > 0 AND CAST(b.valid_watch_time AS BIGINT) > 0,1,0)) AS is_enter_1v1,
		        MAX(is_renewal) AS is_renewal,
		        MAX(is_attend_first_day) AS is_attend_first_day,
		        MAX(is_finish_end_class) AS is_finish_end_class
		FROM
		(
			SELECT  start_class_dt,
			        user_id AS userid,
			        stage_name,
			        semester_id,
			        teacher_ldap,
			        order_id,
			        is_renewal,
			        is_attend_first_day,
			        is_finish_end_class
			FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
			WHERE dt = date_sub(current_date, 1)
			AND subject_id = 1
			AND lesson_id = 800
			AND is_bundled = '单带'
			AND {{start_class_dt}} 
			AND semester_label != '虚拟'
		)a
		LEFT JOIN
		(
			SELECT  user_id,
			        teacher_ldap,
			        first_enter_time,
			        valid_watch_time,
			        from_unixtime(int(start_time/1000),'yyyy-MM-dd') AS start_dt,
			        sky_episode_business_type
			FROM dw_conan_dwd.dwd_service_live_user_class_da
			WHERE dt = date_sub(current_date, 1)
			AND sky_episode_business_type IN ('2', '7') 
		)b
		ON a.userid = b.user_id AND a.teacher_ldap = b.teacher_ldap AND b.start_dt >= date_sub(a.start_class_dt, 28) AND b.start_dt <= date_add(a.start_class_dt, 14)
		LEFT JOIN
		(
			SELECT  userid AS user_id,
			        semesterid,
			        MAX(if(communication_reasons_desc = '参课沟通',1,0)) AS is_canke,
			        MAX(if(communication_reasons_desc = '参课沟通' AND validation = 1,1,0)) AS is_canke_valid,
			        SUM(if(communication_reasons_desc = '参课沟通',duration,0)) AS canke_duration
			FROM dw_dwd.dwd_conan_user_mentor_interview_try_da
			WHERE dt = date_sub(current_date, 1)
			GROUP BY  userid,
			          semesterid
		)c
		ON a.userid = c.user_id AND a.semester_id = c.semesterid
		GROUP BY  a.start_class_dt,
		          a.userid,
		          a.order_id,
		          a.teacher_ldap,
		          stage_name,
		          is_canke,
		          is_canke_valid,
		          canke_duration
		UNION ALL
		SELECT  CASE WHEN refund_dt <= date_sub(a.start_class_dt,8) THEN 'W-1之前'
		             WHEN refund_dt = date_sub(a.start_class_dt,7) THEN 'W0D1'
		             WHEN refund_dt = date_sub(a.start_class_dt,6) THEN 'W0D2'
		             WHEN refund_dt = date_sub(a.start_class_dt,5) THEN 'W0D3'
		             WHEN refund_dt = date_sub(a.start_class_dt,4) THEN 'W0D4'
		             WHEN refund_dt = date_sub(a.start_class_dt,3) THEN 'W0D5'
		             WHEN refund_dt = date_sub(a.start_class_dt,2) THEN 'W0D6'
		             WHEN refund_dt = date_sub(a.start_class_dt,1) THEN 'W0D7'
		             WHEN refund_dt = date_sub(a.start_class_dt,0) THEN 'W1D1'
		             WHEN refund_dt = date_add(a.start_class_dt,1) THEN 'W1D2'
		             WHEN refund_dt = date_add(a.start_class_dt,2) THEN 'W1D3'
		             WHEN refund_dt = date_add(a.start_class_dt,3) THEN 'W1D4'
		             WHEN refund_dt = date_add(a.start_class_dt,4) THEN 'W1D5'
		             WHEN refund_dt = date_add(a.start_class_dt,5) THEN 'W1D6'
		             WHEN refund_dt = date_add(a.start_class_dt,6) THEN 'W1D7'
		             WHEN refund_dt >= date_add(a.start_class_dt,7) THEN 'W2之后' END AS user_type,
		        a.start_class_dt,
		        stage_name,
		        a.userid,
		        a.orderid AS order_id,
		        a.ldap,
		        MAX(if(is_canke = 1,1,0)) AS is_canke,
		        MAX(if(is_canke_valid = 1,1,0)) AS is_canke_valid,
		        SUM(if(canke_duration > 0,canke_duration,0)) AS canke_duration,
		        MAX(if(valid_watch_time > 0,canke_duration,0) ) AS valid_watch_time,
		        MAX(if(is_send_1v1 = 1,1,0)) AS is_send_1v1,
		        MAX(if(is_enter_1v1 = 1,1,0)) AS is_enter_1v1,
		        MAX(if(n.user_id is not null,1,0)) AS is_renewal,
		        MAX(is_attend_first_day) AS is_attend_first_day,
		        MAX(is_finish_end_class) AS is_finish_end_class
		FROM refund_base a
		LEFT JOIN
		(
			SELECT  semester_id,
			        start_stage_name AS stage_name,
			        end_class_dt
			FROM dw_dim.dim_eng_semester_da
			WHERE dt = date_sub(current_date, 1)
			AND subject_id = 1
			AND lesson_id = 800 
		) s
		ON a.semesterid = s.semester_id
		LEFT JOIN
		(
			SELECT  userid,
			        ldap,
			        from_unixtime(int(created_time/1000),'yyyy-MM-dd') AS create_dt,
			        MAX(if(communication_reasons_desc = '参课沟通',1,0)) AS is_canke,
			        MAX(if(communication_reasons_desc = '参课沟通' AND validation = 1,1,0)) AS is_canke_valid,
			        SUM(if(communication_reasons_desc = '参课沟通',duration,0)) AS canke_duration
			FROM dw_dwd.dwd_conan_user_mentor_interview_try_da
			WHERE dt = date_sub(current_date, 1)
			AND subject = 1
			GROUP BY  userid,
			          ldap,
			          from_unixtime(int(created_time/1000),'yyyy-MM-dd')
		)e
		ON a.userid = e.userid AND a.ldap = e.ldap AND e.create_dt <= a.refund_dt AND create_dt >= date_sub(a.start_class_dt, 14)
		LEFT JOIN
		(
			SELECT  a.userid,
			        a.start_class_dt,
			        SUM(valid_watch_time) AS valid_watch_time,
			        MAX(if(b.user_id is not null,1,0)) AS is_send_1v1,
			        MAX(if(b.user_id is not null AND CAST(b.first_enter_time AS BIGINT) > 0 AND CAST(b.valid_watch_time AS BIGINT) > 0,1,0)) AS is_enter_1v1
			FROM refund_base a
			JOIN
			(
				SELECT  user_id,
				        teacher_ldap,
				        from_unixtime(int(start_time/1000),'yyyy-MM-dd') AS start_dt,
				        first_enter_time,
				        valid_watch_time
				FROM dw_conan_dwd.dwd_service_live_user_class_da
				WHERE dt = date_sub(current_date, 1)
				AND sky_episode_business_type IN ('2', '7') 
			)b
			ON a.userid = b.user_id AND a.ldap = b.teacher_ldap AND b.start_dt >= date_sub(a.start_class_dt, 28) AND b.start_dt <= a.refund_dt
			GROUP BY  a.userid,
			          a.start_class_dt
		)f
		ON a.userid = f.userid AND a.start_class_dt = f.start_class_dt
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
		ON a.userid = t.userid AND a.classid = t.classid
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
				AND subject_id = 1 
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
		ON a.userid = n.user_id AND n.pay_tp < a.refund_tp AND n.pay_tp > t.enter_class_time AND n.pay_dt <= date_add(s.end_class_dt, 7) AND (n.first_refund_tp is null or n.refund_related_weekcount <= 0 or n.first_refund_dt > date_add(s.end_class_dt, 14))
		GROUP BY  CASE WHEN refund_dt <= date_sub(a.start_class_dt,8) THEN 'W-1之前'
		             WHEN refund_dt = date_sub(a.start_class_dt,7) THEN 'W0D1'
		             WHEN refund_dt = date_sub(a.start_class_dt,6) THEN 'W0D2'
		             WHEN refund_dt = date_sub(a.start_class_dt,5) THEN 'W0D3'
		             WHEN refund_dt = date_sub(a.start_class_dt,4) THEN 'W0D4'
		             WHEN refund_dt = date_sub(a.start_class_dt,3) THEN 'W0D5'
		             WHEN refund_dt = date_sub(a.start_class_dt,2) THEN 'W0D6'
		             WHEN refund_dt = date_sub(a.start_class_dt,1) THEN 'W0D7'
		             WHEN refund_dt = date_sub(a.start_class_dt,0) THEN 'W1D1'
		             WHEN refund_dt = date_add(a.start_class_dt,1) THEN 'W1D2'
		             WHEN refund_dt = date_add(a.start_class_dt,2) THEN 'W1D3'
		             WHEN refund_dt = date_add(a.start_class_dt,3) THEN 'W1D4'
		             WHEN refund_dt = date_add(a.start_class_dt,4) THEN 'W1D5'
		             WHEN refund_dt = date_add(a.start_class_dt,5) THEN 'W1D6'
		             WHEN refund_dt = date_add(a.start_class_dt,6) THEN 'W1D7'
		             WHEN refund_dt >= date_add(a.start_class_dt,7) THEN 'W2之后' END,
		          a.start_class_dt,
		          a.userid,
		          a.orderid,
		          a.ldap,
		          stage_name
	) a
	LEFT JOIN
	(
		SELECT  order_id,
		        third_channel
		FROM dw_conan_dwd.dwd_conan_try_double_ds_third_channel
		WHERE dt = date_sub(current_date, 1) 
	)b
	ON a.order_id = b.order_id
)
SELECT  a.start_class_dt,
        a.stage_name,
        a.third_channel,
        a.user_type,
        int(b.user_ldap) AS user_ldap,
        int(c.user_ldap) AS user_ldap_real,
        user_cnt,
        is_canke,
        is_canke_valid,
        is_canke_duration,
        canke_duration,
        valid_watch_time,
        is_send_1v1,
        is_enter_1v1,
        1v1_renewal,
        is_renewal,
        is_attend_first_day,
        is_finish_end_class,
        fin_renewal
FROM
(
	SELECT  start_class_dt,
	        stage_name,
	        third_channel,
	        user_type,
	        COUNT(distinct a.userid) AS user_cnt,
	        COUNT(distinct if(is_canke = 1,a.userid,null)) AS is_canke,
	        COUNT(distinct if(is_canke_valid = 1,a.userid,null)) AS is_canke_valid,
	        COUNT(distinct if(canke_duration > 0,a.userid,null)) AS is_canke_duration,
	        SUM(canke_duration) AS canke_duration,
	        SUM(valid_watch_time) AS valid_watch_time,
	        COUNT(distinct if(is_send_1v1 = 1,a.userid,null)) AS is_send_1v1,
	        COUNT(distinct if(is_enter_1v1 = 1,a.userid,null)) AS is_enter_1v1,
	        COUNT(distinct if(is_renewal = 1 AND is_enter_1v1 = 1,a.userid,null)) AS 1v1_renewal,
	        COUNT(distinct if(is_renewal = 1,a.userid,null)) AS is_renewal,
	        COUNT(distinct if(is_attend_first_day = 1,a.userid,null)) AS is_attend_first_day,
	        COUNT(distinct if(is_finish_end_class = 1,a.userid,null)) AS is_finish_end_class,
	        COUNT(distinct if(is_renewal = 1 AND is_finish_end_class = 1,a.userid,null)) AS fin_renewal
	FROM detail a
	GROUP BY  start_class_dt,
	          stage_name,
	          third_channel,
	          user_type
) a
LEFT JOIN
(
	SELECT  start_class_dt,
	        stage_name,
	        COUNT(distinct userid)/COUNT(distinct ldap) AS user_ldap
	FROM detail
	GROUP BY  start_class_dt,
	          stage_name
)b
ON a.start_class_dt = b.start_class_dt AND a.stage_name = b.stage_name
LEFT JOIN
(
	SELECT  start_class_dt,
	        stage_name,
	        COUNT(distinct userid)/COUNT(distinct ldap) AS user_ldap
	FROM detail
	WHERE user_type = '未退费'
	GROUP BY  start_class_dt,
	          stage_name
)c
ON a.start_class_dt = c.start_class_dt AND a.stage_name = c.stage_name