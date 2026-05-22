WITH users AS
(
	SELECT  a.*,
	        b.*
	FROM
	(
		SELECT  user_id,
		        is_bundled,
		        start_class_dt,
		        semester_id,
		        is_renewal,
		        renewal_rhythm,
		        end_class_dt,
		        renewal_order_pay_dt,
      subject_id
		FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
		WHERE dt = date_sub(CURRENT_DATE, 1)
		AND {{start_class_dt}}
		AND ((subject_id IN (2) AND stage_name = 'S4' ) or (subject_id IN (3) AND stage_name = 'S5' ))
		AND semester_label != '虚拟'
	)a
	LEFT JOIN
	(
		SELECT  userid,
		        week_idx,
		        semester_id,
		        mission_id,
                mission_type_cd,
      push_dt
		FROM dw_dwd.dwd_eng_course_user_mission_da
		WHERE dt = date_sub(current_date, 1)
		AND is_test = '0'
		AND {{start_class_dt}}
		AND semester_type_cd = 'try_double'
		AND ((subject_id IN (2) AND stage_name = 'S4' ) or (subject_id IN (3) AND stage_name = 'S5' ))
		AND day_idx = 5
		AND mission_type_cd in('19', '4') 
	) b
	ON a.user_id = b.userid AND a.semester_id = b.semester_id
  where {{a.subject_id}}
), exam_detail AS
(
	SELECT  a.start_class_dt,
  a.subject_id,
	        is_bundled,
	        a.end_class_dt,
	        a.user_id,
	        is_renewal,
	        renewal_order_pay_dt,
	        MAX(if(week_idx = 1,exam_score,0)) AS w1_exam_score,
	        MAX(if(week_idx = 1,question_cnt,0)) AS w1_question_cnt,
	        MAX(if(week_idx = 2,exam_score,0)) AS w2_exam_score,
	        MAX(if(week_idx = 2,question_cnt,0)) AS w2_question_cnt,
	        SUM(exam_score) AS exam_score,
	        SUM(question_cnt) AS question_cnt,
	        MAX(if(week_idx = 1,show_dt,0)) AS w1_show_dt,
	        MAX(if(week_idx = 2,show_dt,0)) AS w2_show_dt,
	        MAX(if(week_idx = 1 AND attend_status > 0 AND first_enter_dt = show_dt,1,0)) AS w1_attend_cur,
	        MAX(if(week_idx = 2 AND attend_status > 0 AND first_enter_dt = show_dt,1,0)) AS w2_attend_cur,
	        MAX(if(week_idx = 1 AND attend_status > 0 AND first_enter_dt <= end_class_dt,1,0)) AS w1_attend_end,
	        MAX(if(week_idx = 2 AND attend_status > 0 AND first_enter_dt <= end_class_dt,1,0)) AS w2_attend_end,
	        MAX(if(week_idx = 1 AND finish_status > 0 AND finish_exam_dt = show_dt,1,0)) AS w1_finish_cur,
	        MAX(if(week_idx = 2 AND finish_status > 0 AND finish_exam_dt = show_dt,1,0)) AS w2_finish_cur,
	        MAX(if(week_idx = 1 AND finish_status > 0 AND finish_exam_dt <= end_class_dt,1,0)) AS w1_finish_end,
	        MAX(if(week_idx = 2 AND finish_status > 0 AND finish_exam_dt <= end_class_dt,1,0)) AS w2_finish_end
	FROM users a
	LEFT JOIN
	(
		SELECT  regexp_replace(split(period_type,'-') [1],'\\/','\\-') AS start_class_dt,
      subject_id,
		        exam_source_id,
		        user_id,
		        week_num,
		        show_dt,
		        MAX(finish_status) AS finish_status,
		        MAX(attend_status) AS attend_status,
		        MIN(first_enter_dt) AS first_enter_dt,
		        MIN(finish_exam_dt) AS finish_exam_dt,
		        MAX(exam_score) AS exam_score,
		        MAX(question_cnt) AS question_cnt
		FROM dw_dwd.dwd_eng_course_exam_report_da
		WHERE dt = date_sub(CURRENT_DATE, 1)
		AND subject_id in (2,3)
		AND {{regexp_replace(split(period_type, '-') [1], '\\/', '\\-') AS start_class_dt}}
		AND exam_type = '1001'
		AND (stage_id = '204' or stage_id = '305')
		AND exam_resource_finish_rk = 1
		GROUP BY  regexp_replace(split(period_type,'-') [1],'\\/','\\-'),
      subject_id,
		          exam_source_id,
		          user_id,
		          week_num,
		          show_dt
	)c
	ON a.start_class_dt = c.start_class_dt AND a.user_id = c.user_id AND a.mission_id = c.exam_source_id and a.mission_type_cd='19' and a.subject_id=c.subject_id
	GROUP BY  a.start_class_dt,
  a.subject_id,
	          is_bundled,
	          a.end_class_dt,
	          a.user_id,
	          is_renewal,
	          renewal_order_pay_dt
) , tv_detail AS
(
	SELECT  a.start_class_dt,
  a.subject_id,
	        is_bundled,
	        a.end_class_dt,
	        a.user_id,
	        MAX(if(week_idx = 1 AND (is_watched>0 or (is_playback>0 and play_back_dt<=a.push_dt)),1,0)) AS w1_attend_cur,
	        MAX(if(week_idx = 2 AND (is_watched>0 or (is_playback>0 and play_back_dt<=a.push_dt)),1,0)) AS w2_attend_cur,
	        MAX(if(week_idx = 1 AND (is_watched>0 or (is_playback>0 and play_back_dt<=a.end_class_dt)),1,0)) AS w1_attend_end,
	        MAX(if(week_idx = 2 AND (is_watched>0 or (is_playback>0 and play_back_dt<=a.end_class_dt)),1,0)) AS w2_attend_end
	FROM users a
	LEFT JOIN
	(
		SELECT  user_id,
      subject_id,
		        mission_id,
      room_id,
		        SUM(is_watched) AS is_watched,
      sum(is_playback) as is_playback
		FROM dw_dwd.dwd_eng_course_user_watch_tv_da
		WHERE dt = date_sub(current_date, 1)
		AND ((subject_id IN (2) AND stage_name = 'S4' ) or (subject_id IN (3) AND stage_name = 'S5' ))
		AND {{regexp_replace(split(period_type, '-') [1], '\\/', '\\-') AS start_class_dt}}
		GROUP BY user_id,
      subject_id,
		        mission_id,
      room_id
	)c
	ON a.user_id = c.user_id AND a.mission_id = c.mission_id and a.mission_type_cd='4' and a.subject_id=c.subject_id
  left join 
  (
    SELECT  userid AS user_id
    ,subject
                        ,roomid AS room_id
                        ,FROM_UNIXTIME(CAST(MIN(tp) / 1000 AS INT),'yyyy-MM-dd') AS play_back_dt
                FROM    dw_conan_dwd.dwd_conan_course_tv_playback_da
                WHERE   dt = date_sub(current_date, 1)
    and subject in (2,3)
                GROUP BY userid
    ,subject
                         ,roomid
  )d 
  on c.user_id = d.user_id AND     c.room_id = d.room_id and c.subject_id=d.subject
	GROUP BY  a.start_class_dt,
  a.subject_id,
	          is_bundled,
	          a.end_class_dt,
	          a.user_id
)
SELECT  'W1周测' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        SUM(w1_exam_score)/SUM(w1_question_cnt) AS score,
        COUNT(distinct if(w1_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w1_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w1_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w1_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        COUNT(distinct if(w1_finish_cur = 1,user_id,null)) AS finish_cur_user,
        COUNT(distinct if(w1_finish_cur = 1,user_id,null))/COUNT(distinct user_id) AS finish_cur_rate,
        COUNT(distinct if(w1_finish_end = 1,user_id,null)) AS finish_end_user,
        COUNT(distinct if(w1_finish_end = 1,user_id,null))/COUNT(distinct user_id) AS finish_end_rate,
        COUNT(distinct if(w1_finish_cur = 1 AND is_renewal = 1,user_id,null)) AS finish_cur_renew_user,
        COUNT(distinct if(w1_finish_cur = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w1_finish_cur = 1,user_id,null)) AS finish_cur_renew_rate,
        COUNT(distinct if(w1_finish_end = 1 AND is_renewal = 1,user_id,null)) AS finish_end_renew_user,
        COUNT(distinct if(w1_finish_end = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w1_finish_end = 1,user_id,null)) AS finish_end_renew_rate
FROM exam_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id
UNION ALL
SELECT  'W2周测' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        SUM(w2_exam_score)/SUM(w2_question_cnt) AS score,
        COUNT(distinct if(w2_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w2_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w2_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w2_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        COUNT(distinct if(w2_finish_cur = 1,user_id,null)) AS finish_cur_user,
        COUNT(distinct if(w2_finish_cur = 1,user_id,null))/COUNT(distinct user_id) AS finish_cur_rate,
        COUNT(distinct if(w2_finish_end = 1,user_id,null)) AS finish_end_user,
        COUNT(distinct if(w2_finish_end = 1,user_id,null))/COUNT(distinct user_id) AS finish_end_rate,
        COUNT(distinct if(w2_finish_cur = 1 AND is_renewal = 1,user_id,null)) AS finish_cur_renew_user,
        COUNT(distinct if(w2_finish_cur = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w2_finish_cur = 1,user_id,null)) AS finish_cur_renew_rate,
        COUNT(distinct if(w2_finish_end = 1 AND is_renewal = 1,user_id,null)) AS finish_end_renew_user,
        COUNT(distinct if(w2_finish_end = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w2_finish_end = 1,user_id,null)) AS finish_end_renew_rate
FROM exam_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id
UNION ALL
SELECT  'W1+W2周测' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        SUM(exam_score)/SUM(question_cnt) AS score,
        COUNT(distinct if(w1_attend_cur = 1 AND w2_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w1_attend_cur = 1 AND w2_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w1_attend_end = 1 AND w2_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w1_attend_end = 1 AND w2_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        COUNT(distinct if(w1_finish_cur = 1 AND w2_finish_cur = 1,user_id,null)) AS finish_cur_user,
        COUNT(distinct if(w1_finish_cur = 1 AND w2_finish_cur = 1,user_id,null))/COUNT(distinct user_id) AS finish_cur_rate,
        COUNT(distinct if(w1_finish_end = 1 AND w2_finish_end = 1,user_id,null)) AS finish_end_user,
        COUNT(distinct if(w1_finish_end = 1 AND w2_finish_end = 1,user_id,null))/COUNT(distinct user_id) AS finish_end_rate,
        COUNT(distinct if(w1_finish_cur = 1 AND w2_finish_cur = 1 AND is_renewal = 1,user_id,null)) AS finish_cur_renew_user,
        COUNT(distinct if(w1_finish_cur = 1 AND w2_finish_cur = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w1_finish_cur = 1 AND w2_finish_cur = 1,user_id,null)) AS finish_cur_renew_rate,
        COUNT(distinct if(w1_finish_end = 1 AND w2_finish_end = 1 AND is_renewal = 1,user_id,null)) AS finish_end_renew_user,
        COUNT(distinct if(w1_finish_end = 1 AND w2_finish_end = 1 AND is_renewal = 1,user_id,null))/COUNT(distinct if(w1_finish_end = 1 AND w2_finish_end = 1,user_id,null)) AS finish_end_renew_rate
FROM exam_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id
UNION ALL
SELECT  'W1TV课' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        0 AS score,
        COUNT(distinct if(w1_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w1_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w1_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w1_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        0 AS finish_cur_user,
        0 AS finish_cur_rate,
        0 AS finish_end_user,
        0 AS finish_end_rate,
        0 AS finish_cur_renew_user,
        0 AS finish_cur_renew_rate,
        0 AS finish_end_renew_user,
        0 AS finish_end_renew_rate
FROM tv_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id
UNION ALL
SELECT  'W2TV课' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        0 AS score,
        COUNT(distinct if(w2_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w2_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w2_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w2_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        0 AS finish_cur_user,
        0 AS finish_cur_rate,
        0 AS finish_end_user,
        0 AS finish_end_rate,
        0 AS finish_cur_renew_user,
        0 AS finish_cur_renew_rate,
        0 AS finish_end_renew_user,
        0 AS finish_end_renew_rate
FROM tv_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id
UNION ALL
SELECT  'W1+W2TV课' AS type,
        start_class_dt,
        is_bundled,
        subject_id,
        COUNT(distinct user_id) AS user_cnt,
        0 AS score,
        COUNT(distinct if(w1_attend_cur = 1 AND w2_attend_cur = 1,user_id,null)) AS attend_cur_user,
        COUNT(distinct if(w1_attend_cur = 1 AND w2_attend_cur = 1,user_id,null))/COUNT(distinct user_id) AS attend_cur_rate,
        COUNT(distinct if(w1_attend_end = 1 AND w2_attend_end = 1,user_id,null)) AS attend_end_user,
        COUNT(distinct if(w1_attend_end = 1 AND w2_attend_end = 1,user_id,null))/COUNT(distinct user_id) AS attend_end_rate,
        0 AS finish_cur_user,
        0 AS finish_cur_rate,
        0 AS finish_end_user,
        0 AS finish_end_rate,
        0 AS finish_cur_renew_user,
        0 AS finish_cur_renew_rate,
        0 AS finish_end_renew_user,
        0 AS finish_end_renew_rate
FROM tv_detail
GROUP BY  start_class_dt,
          is_bundled,
          subject_id