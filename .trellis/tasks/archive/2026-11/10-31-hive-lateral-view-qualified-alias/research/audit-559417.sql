insert overwrite table dw_conan_dwd.dwd_conan_course_pedia_attend_da partition(dt='${date}')
select 
	user_id,
	package_id,
	course_id,
	max(is_attend) as is_attend,
	max(is_finish) as is_finish,
	max(is_review) as is_review,
	min(first_attend_tp) as first_attend_tp,
	min(first_attend_dt) as first_attend_dt,
	max(last_attend_tp) as last_attend_tp,
	max(last_attend_dt) as last_attend_dt,
	min(first_review_tp) as first_review_tp,
	min(first_review_dt) as first_review_dt,
	min(first_finish_tp) as first_finish_tp,
	min(first_finish_dt) as first_finish_dt,
	collect_set(attend_dt) as attend_dt_list,
	collect_set(formal_dt) as formal_attend_dt_list, 
    from_unixtime(unix_timestamp(),'yyyy-MM-dd HH:mm:ss')   as      load_datetime
from 
	(
	select 
		user_id,
		package_id,
		course_id,
		is_attend,
		is_finish,
		is_review,
		first_attend_tp,
		first_attend_dt,
		last_attend_tp,
		last_attend_dt,
		first_review_tp,
		first_review_dt,
		first_finish_tp,
		first_finish_dt,
		concat_ws(',',attend_dt_list) as attend_dt,
		concat_ws(',',formal_attend_dt_list) as formal_dt
	from dw_conan_dwd.dwd_conan_course_pedia_attend_di
	where dt = '${date}'
	union all 
	select 
		user_id,
		package_id,
		course_id,
		is_attend,
		is_finish,
		is_review,
		first_attend_tp,
		first_attend_dt,
		last_attend_tp,
		last_attend_dt,
		first_review_tp,
		first_review_dt,
		first_finish_tp,
		first_finish_dt,
		-- attend_dt_list,
		-- formal_attend_dt_list
		attend_dt,
		formal_dt
	from dw_conan_dwd.dwd_conan_course_pedia_attend_da 
    LATERAL view posexplode(split(concat_ws(',',attend_dt_list),',')) tmp as index_1,attend_dt
    LATERAL view posexplode(split(concat_ws(',',formal_attend_dt_list),',')) tmp1 as index_1,formal_dt
	where dt = date_sub('${date}',1)
  	and tmp.index_1 = tmp1.index_1
	) res 
	group by 
		user_id,
		package_id,
		course_id
