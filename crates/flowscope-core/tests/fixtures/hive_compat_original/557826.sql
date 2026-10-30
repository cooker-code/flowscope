-- BPO断课存量每日增量重评。
-- ${date}为当前特征快照日期，读取date_sub('${date}',1)状态。
-- 单任务一次处理全部用户；按不带日期的user_id哈希动态写入batch_no=0、1、2、3分区。
-- 触发范围：昨日S/A、原始特征变化、拨打记录退出4个月窗口、当天新增体断、资格退出。
-- 只对仍符合资格且触发重评的用户解析拨打JSON和执行模型评分。

set spark.sql.sources.commitProtocolClass=com.kanyun.spark.UltimateStagingCommitProtocol;
set spark.sql.hive.convertMetastoreOrc=true;
set spark.sql.jsonGenerator.ignoreNullFields=false;
set spark.sql.adaptive.enabled=true;
set spark.sql.adaptive.coalescePartitions.enabled=true;
set spark.sql.adaptive.skewJoin.enabled=true;
set spark.sql.analyzer.maxIterations=300;
set hive.exec.dynamic.partition=true;
set hive.exec.dynamic.partition.mode=nonstrict;


with previous_state as (
    select
        *
    from dw_conan_ads.ads_eng_telesales_drop_stock_score_state_da
    where dt=date_sub('${date}',1)
)
,market_info as (
    select
        cast(userid as string) as user_id
        ,user_type
        ,case
            when birthday is null then null
            when to_date(birthday) in ('1970-01-01','1900-01-01') then null
            else round(months_between('${date}',to_date(birthday))/12,2)
        end as age
        ,call_1year_detail_json
        ,sha2(coalesce(call_1year_detail_json,'[]'),256) as call_detail_hash
    from dw_conan_dwd.dwd_market_user_info_da
    where dt='${date}'
        and user_type='体验课全断课'
)
,active_tag as (
    select
        cast(user_id as string) as user_id
        ,max(lst_active_dt) as lst_active_dt
    from dw_conan_dwd.dwd_eng_user_active_da
    where dt='${date}'
    group by cast(user_id as string)
)
,quality_tag as (
    select
        cast(user_id as string) as user_id
        ,count(distinct if(if_ocean_chi_class=0 and stage_name>='S3',subject_name,null)) as s3_plus_subject_cnt
        ,count(distinct case
            when cast(order_status as string)='2'
                and pay_tp is not null
                and cast(pay_tp as bigint)<unix_timestamp(concat(cast(date_add('${date}',1) as string),' 00:00:00'))*1000
                and end_class_dt is not null
                and to_date(end_class_dt)<date_add('${date}',1)
                and cast(is_finish_end_class as int)=1
            then case
                when parent_order_id is null or trim(cast(parent_order_id as string)) in ('','0') then cast(order_id as string)
                else cast(parent_order_id as string)
            end
            else null
        end) as hist_finish_course_cnt
    from dw_conan_ads.ads_service_try_double_user_quality_detail_da
    where dt='${date}'
    group by cast(user_id as string)
)
,eligibility_order_tag as (
    select
        cast(user_id as string) as user_id
        ,min(if(order_status=2 and semester_type='season',pay_dt,null)) as season_min_pay_dt
        ,max(if(
            order_status=2
            and ((cast(subject_id as string) in ('4','5','7','8') and semester_type='try') or semester_type='try_double')
            ,pay_dt
            ,null
        )) as try_max_pay_dt
    from dw_conan_dwd.dwd_eng_order_course_detail_da
    where dt='${date}'
        and order_status=2
        and (semester_type='season' or semester_type='try_double' or (semester_type='try' and cast(subject_id as string) in ('4','5','7','8')))
    group by cast(user_id as string)
)
,try_order_raw as (
    select
        cast(user_id as string) as user_id
        ,case
            when parent_order_id is null or trim(cast(parent_order_id as string)) in ('','0') then cast(order_id as string)
            else cast(parent_order_id as string)
        end as order_key
        ,min(cast(pay_tp as bigint)) as pay_ts
        ,min(pay_dt) as pay_dt
        ,max(cast(subject_id as string)) as subject_id
        ,min_by(coalesce(nullif(trim(cast(user_from as string)),''),'unknown'),cast(pay_tp as bigint)) as user_from
    from dw_conan_dwd.dwd_try_course_order_detail_da
    where dt='${date}'
        and order_status='2'
        and pay_tp is not null
        and cast(pay_tp as bigint)<unix_timestamp(concat(cast(date_add('${date}',1) as string),' 00:00:00'))*1000
    group by
        cast(user_id as string)
        ,case
            when parent_order_id is null or trim(cast(parent_order_id as string)) in ('','0') then cast(order_id as string)
            else cast(parent_order_id as string)
        end
)
,try_order_tag as (
    select
        user_id
        ,count(distinct order_key) as prior_try_order_cnt
        ,count(distinct subject_id) as prior_try_subject_cnt
        ,max(pay_dt) as last_try_pay_dt
        ,max_by(user_from,pay_ts) as hist_try_pay_channel
    from try_order_raw
    group by user_id
)
,valid_comm_user as (
    select distinct
        cast(userid as string) as user_id
    from dw_conan_dwd.dwd_conan_user_mentor_interview_try_da
    where dt='${date}'
        and communication_reasons_desc='转化沟通'
        and cast(validation as int)=1
        and to_date(created_date)<date_add('${date}',1)
)
,app_tag as (
    select
        cast(user_id as string) as user_id
        ,case
            when count(user_id)=0 then 'no_snapshot'
            when max(if(coalesce(competitor_app_cnt,0)>0,1,0))=1 then 'competitor_installed'
            when max(if(coalesce(education_app_cnt,0)>0,1,0))=1 then 'education_only'
            else 'no_education_app'
        end as app_profile_bucket
    from dw_conan_dwd.dwd_conan_user_device_app_profile_da
    where dt='${date}'
    group by cast(user_id as string)
)
,current_raw as (
    select
        m.user_id
        ,m.user_type
        ,m.age
        ,m.call_1year_detail_json
        ,m.call_detail_hash
        ,cast(a.lst_active_dt as string) as lst_active_dt
        ,cast(coalesce(q.s3_plus_subject_cnt,0) as bigint) as s3_plus_subject_cnt
        ,cast(o.season_min_pay_dt as string) as season_min_pay_dt
        ,cast(o.try_max_pay_dt as string) as try_max_pay_dt
        ,cast(if(v.user_id is not null,1.0,0.0) as double) as has_valid_comm
        ,cast(coalesce(q.hist_finish_course_cnt,0) as double) as hist_finish_course_cnt
        ,cast(t.last_try_pay_dt as string) as last_try_pay_dt
        ,coalesce(nullif(t.hist_try_pay_channel,'unknown'),'none') as hist_try_pay_channel
        ,cast(coalesce(t.prior_try_subject_cnt,0) as double) as prior_try_subject_cnt
        ,cast(coalesce(t.prior_try_order_cnt,0) as double) as prior_try_order_cnt
        ,coalesce(p.app_profile_bucket,'no_snapshot') as app_profile_bucket
    from market_info m
    left join active_tag a
        on m.user_id=a.user_id
    left join quality_tag q
        on m.user_id=q.user_id
    left join eligibility_order_tag o
        on m.user_id=o.user_id
    left join try_order_tag t
        on m.user_id=t.user_id
    left join valid_comm_user v
        on m.user_id=v.user_id
    left join app_tag p
        on m.user_id=p.user_id
)
,current_light as (
    select
        r.*
        ,if(
            (r.age is null or (r.age>=2 and r.age<11))
            and (r.lst_active_dt is null or to_date(r.lst_active_dt)<date_sub('${date}',2))
            and r.s3_plus_subject_cnt<3
            and r.season_min_pay_dt is null
            and (r.try_max_pay_dt is null or to_date(r.try_max_pay_dt)<date_sub('${date}',50))
            ,1
            ,0
        ) as is_eligible
    from current_raw r
)
,compare_base as (
    select
        coalesce(c.user_id,p.user_id) as user_id
        ,p.grade as previous_grade
        ,p.rank_score as previous_rank_score
        ,coalesce(p.is_eligible,0) as previous_is_eligible
        ,coalesce(c.is_eligible,0) as new_is_eligible
        ,p.raw_feature_hash as previous_feature_hash
        ,p.first_entry_dt as previous_first_entry_dt
        ,p.last_feature_update_dt as previous_last_feature_update_dt
        ,p.last_score_dt as previous_last_score_dt
        ,p.touch_dt_array_4m as previous_touch_dt_array_4m
        ,p.connect_dt_array_4m as previous_connect_dt_array_4m
        ,c.user_type
        ,c.age
        ,c.call_1year_detail_json
        ,c.call_detail_hash
        ,c.lst_active_dt
        ,c.s3_plus_subject_cnt
        ,c.season_min_pay_dt
        ,c.try_max_pay_dt
        ,c.has_valid_comm
        ,c.hist_finish_course_cnt
        ,c.last_try_pay_dt
        ,c.hist_try_pay_channel
        ,c.prior_try_subject_cnt
        ,c.prior_try_order_cnt
        ,c.app_profile_bucket
        ,filter(array(
            if(not (c.lst_active_dt<=>p.lst_active_dt),'lst_active_dt',null)
            ,if(not (c.s3_plus_subject_cnt<=>p.s3_plus_subject_cnt),'s3_plus_subject_cnt',null)
            ,if(not (c.season_min_pay_dt<=>p.season_min_pay_dt),'season_min_pay_dt',null)
            ,if(not (c.try_max_pay_dt<=>p.try_max_pay_dt),'try_max_pay_dt',null)
            ,if(not (c.has_valid_comm<=>p.has_valid_comm),'has_valid_comm',null)
            ,if(not (c.hist_finish_course_cnt<=>p.hist_finish_course_cnt),'hist_finish_course_cnt',null)
            ,if(not (c.last_try_pay_dt<=>p.last_try_pay_dt),'last_try_pay_dt',null)
            ,if(not (c.hist_try_pay_channel<=>p.hist_try_pay_channel),'hist_try_pay_channel',null)
            ,if(not (c.prior_try_subject_cnt<=>p.prior_try_subject_cnt),'prior_try_subject_cnt',null)
            ,if(not (c.prior_try_order_cnt<=>p.prior_try_order_cnt),'prior_try_order_cnt',null)
            ,if(not (c.app_profile_bucket<=>p.app_profile_bucket),'app_profile_bucket',null)
            ,if(not (c.call_detail_hash<=>p.call_detail_hash),'call_detail_hash',null)
        ),x -> x is not null) as changed_feature_list
        ,if(
            exists(p.touch_dt_array_4m,x -> to_date(x)<add_months(date_add('${date}',1),-4))
            or exists(p.connect_dt_array_4m,x -> to_date(x)<add_months(date_add('${date}',1),-4))
            ,1
            ,0
        ) as touch_expire_flag
    from previous_state p
    full outer join current_light c
        on p.user_id=c.user_id
)
,rescore_candidate as (
    select
        b.*
        ,case
            when previous_is_eligible=1 and new_is_eligible=0 then 'ELIGIBILITY_EXIT'
            when previous_is_eligible=0 and new_is_eligible=1 then 'NEW_USER'
            when previous_grade in ('S','A') then 'PREVIOUS_SA'
            when array_contains(changed_feature_list,'call_detail_hash') then 'TOUCH_CHANGE'
            when touch_expire_flag=1 then 'TOUCH_EXPIRE'
            when size(changed_feature_list)>0 then 'FEATURE_CHANGE'
            else null
        end as rescore_reason
    from compare_base b
)
,score_input as (
    select
        *
    from rescore_candidate
    where new_is_eligible=1
        and rescore_reason is not null
)
,touch_feature as (
    select
        s.*
        ,sort_array(array_distinct(transform(
            filter(
                from_json(
                    coalesce(s.call_1year_detail_json,'[]')
                    ,'array<struct<call_ts:string,call_dt:string,biz_line:string,biz_type:string,is_connected:int>>'
                )
                ,x -> to_date(x.call_dt) between add_months(date_add('${date}',1),-4) and to_date('${date}')
                    and coalesce(x.biz_type,'') not in ('内测AI','阶段测AI','其他AI')
            )
            ,x -> cast(to_date(x.call_dt) as string)
        ))) as touch_dt_array_4m
        ,sort_array(array_distinct(transform(
            filter(
                from_json(
                    coalesce(s.call_1year_detail_json,'[]')
                    ,'array<struct<call_ts:string,call_dt:string,biz_line:string,biz_type:string,is_connected:int>>'
                )
                ,x -> to_date(x.call_dt) between add_months(date_add('${date}',1),-4) and to_date('${date}')
                    and coalesce(x.biz_type,'') not in ('内测AI','阶段测AI','其他AI')
                    and coalesce(x.is_connected,0)=1
            )
            ,x -> cast(to_date(x.call_dt) as string)
        ))) as connect_dt_array_4m
    from score_input s
)
,feature_base as (
    select
        user_id
        ,previous_grade
        ,previous_rank_score
        ,rescore_reason
        ,changed_feature_list
        ,touch_expire_flag
        ,previous_is_eligible
        ,new_is_eligible
        ,previous_feature_hash
        ,previous_first_entry_dt
        ,previous_last_feature_update_dt
        ,previous_last_score_dt
        ,user_type
        ,age
        ,lst_active_dt
        ,s3_plus_subject_cnt
        ,season_min_pay_dt
        ,try_max_pay_dt
        ,has_valid_comm
        ,hist_finish_course_cnt
        ,last_try_pay_dt
        ,hist_try_pay_channel
        ,prior_try_subject_cnt
        ,prior_try_order_cnt
        ,app_profile_bucket
        ,call_detail_hash
        ,touch_dt_array_4m
        ,connect_dt_array_4m
        ,cast(size(touch_dt_array_4m) as bigint) as hist_touch_day_cnt_4m
        ,cast(size(connect_dt_array_4m) as bigint) as hist_touch_connect_day_cnt_4m
        ,cast(datediff(date_add('${date}',1),to_date(lst_active_dt)) as double) as days_since_last_active
        ,cast(datediff(date_add('${date}',1),to_date(last_try_pay_dt)) as double) as days_since_last_try_pay
    from touch_feature
)
,model_param as (
    select
        model_stage
        ,param_type
        ,feature_name
        ,feature_value
        ,effective_coefficient
        ,impute_value
        ,param_value
    from temp.tmk_bpo_tryend_model_3_1_1_a_param_da
    where dt='2026-09-02'
        and model_version='3.1.1-a-8-features-no-age-bpo-drop-stock'
)
-- 将数值系数、校准参数和等级阈值转为单行。
,model_scalar_param as (
    select
        max(if(model_stage='connect' and param_type='model_intercept',effective_coefficient,null)) as c_intercept
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='days_since_last_active',effective_coefficient,null)) as c_dla_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='days_since_last_active',cast(impute_value as double),null)) as c_dla_impute
        ,max(if(model_stage='connect' and param_type='numeric_missing_indicator' and feature_name='days_since_last_active',effective_coefficient,null)) as c_dla_missing_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='has_valid_comm',effective_coefficient,null)) as c_valid_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='has_valid_comm',cast(impute_value as double),null)) as c_valid_impute
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='hist_finish_course_cnt',effective_coefficient,null)) as c_finish_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='hist_finish_course_cnt',cast(impute_value as double),null)) as c_finish_impute
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='days_since_last_try_pay',effective_coefficient,null)) as c_dtp_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='days_since_last_try_pay',cast(impute_value as double),null)) as c_dtp_impute
        ,max(if(model_stage='connect' and param_type='numeric_missing_indicator' and feature_name='days_since_last_try_pay',effective_coefficient,null)) as c_dtp_missing_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='prior_try_subject_cnt',effective_coefficient,null)) as c_subject_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='prior_try_subject_cnt',cast(impute_value as double),null)) as c_subject_impute
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='prior_try_order_cnt',effective_coefficient,null)) as c_order_coef
        ,max(if(model_stage='connect' and param_type='numeric_feature' and feature_name='prior_try_order_cnt',cast(impute_value as double),null)) as c_order_impute
        ,max(if(model_stage='connect' and param_type='categorical_unknown_mapping' and feature_name='hist_try_pay_channel',effective_coefficient,null)) as c_channel_unknown_coef
        ,max(if(model_stage='connect' and param_type='categorical_unknown_mapping' and feature_name='app_profile_bucket',effective_coefficient,null)) as c_app_unknown_coef
        ,max(if(model_stage='connect' and param_type='calibration_coefficient',param_value,null)) as c_calibration_coef
        ,max(if(model_stage='connect' and param_type='calibration_intercept',param_value,null)) as c_calibration_intercept
        ,max(if(model_stage='connect' and param_type='calibration_clip_epsilon',param_value,null)) as c_clip_epsilon
        ,max(if(model_stage='d7_given_connect' and param_type='model_intercept',effective_coefficient,null)) as d_intercept
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='days_since_last_active',effective_coefficient,null)) as d_dla_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='days_since_last_active',cast(impute_value as double),null)) as d_dla_impute
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_missing_indicator' and feature_name='days_since_last_active',effective_coefficient,null)) as d_dla_missing_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='has_valid_comm',effective_coefficient,null)) as d_valid_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='has_valid_comm',cast(impute_value as double),null)) as d_valid_impute
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='hist_finish_course_cnt',effective_coefficient,null)) as d_finish_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='hist_finish_course_cnt',cast(impute_value as double),null)) as d_finish_impute
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='days_since_last_try_pay',effective_coefficient,null)) as d_dtp_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='days_since_last_try_pay',cast(impute_value as double),null)) as d_dtp_impute
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_missing_indicator' and feature_name='days_since_last_try_pay',effective_coefficient,null)) as d_dtp_missing_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='prior_try_subject_cnt',effective_coefficient,null)) as d_subject_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='prior_try_subject_cnt',cast(impute_value as double),null)) as d_subject_impute
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='prior_try_order_cnt',effective_coefficient,null)) as d_order_coef
        ,max(if(model_stage='d7_given_connect' and param_type='numeric_feature' and feature_name='prior_try_order_cnt',cast(impute_value as double),null)) as d_order_impute
        ,max(if(model_stage='d7_given_connect' and param_type='categorical_unknown_mapping' and feature_name='hist_try_pay_channel',effective_coefficient,null)) as d_channel_unknown_coef
        ,max(if(model_stage='d7_given_connect' and param_type='categorical_unknown_mapping' and feature_name='app_profile_bucket',effective_coefficient,null)) as d_app_unknown_coef
        ,max(if(model_stage='d7_given_connect' and param_type='calibration_coefficient',param_value,null)) as d_calibration_coef
        ,max(if(model_stage='d7_given_connect' and param_type='calibration_intercept',param_value,null)) as d_calibration_intercept
        ,max(if(model_stage='d7_given_connect' and param_type='calibration_clip_epsilon',param_value,null)) as d_clip_epsilon
        ,max(if(model_stage='ranking' and param_type='tier_threshold' and feature_name='S_min',param_value,null)) as s_min
        ,max(if(model_stage='ranking' and param_type='tier_threshold' and feature_name='A_min',param_value,null)) as a_min
        ,max(if(model_stage='ranking' and param_type='tier_threshold' and feature_name='B_min',param_value,null)) as b_min
        ,max(if(model_stage='ranking' and param_type='tier_threshold' and feature_name='C_min',param_value,null)) as c_min
    from model_param
)
-- 汇总购买渠道和APP画像的类别系数。
,category_param as (
    select
        feature_name
        ,feature_value
        ,max(if(model_stage='connect',effective_coefficient,null)) as connect_coef
        ,max(if(model_stage='d7_given_connect',effective_coefficient,null)) as d7_coef
    from model_param
    where param_type='categorical_mapping'
        and feature_name in ('hist_try_pay_channel','app_profile_bucket')
    group by
        feature_name
        ,feature_value
)
-- 计算接通模型和D7转化模型的线性分值。
,model_logit as (
    select /*+ broadcast(p,ch,ap) */
        f.*
        ,p.c_calibration_coef
        ,p.c_calibration_intercept
        ,p.c_clip_epsilon
        ,p.d_calibration_coef
        ,p.d_calibration_intercept
        ,p.d_clip_epsilon
        ,p.s_min
        ,p.a_min
        ,p.b_min
        ,p.c_min
        ,p.c_intercept
            +coalesce(f.days_since_last_active,p.c_dla_impute)*p.c_dla_coef
            +if(f.days_since_last_active is null,p.c_dla_missing_coef,0.0)
            +coalesce(f.has_valid_comm,p.c_valid_impute)*p.c_valid_coef
            +coalesce(f.hist_finish_course_cnt,p.c_finish_impute)*p.c_finish_coef
            +coalesce(f.days_since_last_try_pay,p.c_dtp_impute)*p.c_dtp_coef
            +if(f.days_since_last_try_pay is null,p.c_dtp_missing_coef,0.0)
            +coalesce(f.prior_try_subject_cnt,p.c_subject_impute)*p.c_subject_coef
            +coalesce(f.prior_try_order_cnt,p.c_order_impute)*p.c_order_coef
            +coalesce(ch.connect_coef,p.c_channel_unknown_coef,0.0)
            +coalesce(ap.connect_coef,p.c_app_unknown_coef,0.0) as connect_logit
        ,p.d_intercept
            +coalesce(f.days_since_last_active,p.d_dla_impute)*p.d_dla_coef
            +if(f.days_since_last_active is null,p.d_dla_missing_coef,0.0)
            +coalesce(f.has_valid_comm,p.d_valid_impute)*p.d_valid_coef
            +coalesce(f.hist_finish_course_cnt,p.d_finish_impute)*p.d_finish_coef
            +coalesce(f.days_since_last_try_pay,p.d_dtp_impute)*p.d_dtp_coef
            +if(f.days_since_last_try_pay is null,p.d_dtp_missing_coef,0.0)
            +coalesce(f.prior_try_subject_cnt,p.d_subject_impute)*p.d_subject_coef
            +coalesce(f.prior_try_order_cnt,p.d_order_impute)*p.d_order_coef
            +coalesce(ch.d7_coef,p.d_channel_unknown_coef,0.0)
            +coalesce(ap.d7_coef,p.d_app_unknown_coef,0.0) as d7_logit
    from feature_base f
    cross join model_scalar_param p
    left join category_param ch
        on ch.feature_name='hist_try_pay_channel'
        and f.hist_try_pay_channel=ch.feature_value
    left join category_param ap
        on ap.feature_name='app_profile_bucket'
        and f.app_profile_bucket=ap.feature_value
)
-- 将线性分值转换为原始概率。
,raw_probability as (
    select
        m.*
        ,1.0/(1.0+exp(-m.connect_logit)) as connect_raw_probability
        ,1.0/(1.0+exp(-m.d7_logit)) as d7_raw_probability
    from model_logit m
)
-- 对两个模型的原始概率进行校准。
,calibrated_probability as (
    select
        r.*
        ,1.0/(1.0+exp(-(
            r.c_calibration_intercept
            +r.c_calibration_coef*ln(
                greatest(r.c_clip_epsilon,least(1.0-r.c_clip_epsilon,r.connect_raw_probability))
                /(1.0-greatest(r.c_clip_epsilon,least(1.0-r.c_clip_epsilon,r.connect_raw_probability)))
            )
        ))) as p_connect
        ,1.0/(1.0+exp(-(
            r.d_calibration_intercept
            +r.d_calibration_coef*ln(
                greatest(r.d_clip_epsilon,least(1.0-r.d_clip_epsilon,r.d7_raw_probability))
                /(1.0-greatest(r.d_clip_epsilon,least(1.0-r.d_clip_epsilon,r.d7_raw_probability)))
            )
        ))) as p_d7_given_connect
    from raw_probability r
)
-- 计算联合概率、频控和多购折损系数。
,policy_score as (
    select
        p.*
        ,p.p_connect*p.p_d7_given_connect as p_d7_joint
        ,case
            when p.hist_touch_day_cnt_4m=0 then 1.00
            when p.hist_touch_day_cnt_4m=1 then 0.80
            when p.hist_touch_day_cnt_4m=2 then 0.50
            else 0.20
        end as frequency_coef
        ,if(p.prior_try_order_cnt>3,0.60,1.00) as repeat_order_coef
        ,if(p.hist_touch_day_cnt_4m>=3 and p.hist_touch_connect_day_cnt_4m=0,1,0) as frequency_hard_exclude_flag
    from calibrated_probability p
)
-- 计算用于排序的最终模型评分。
,ranked_score as (
    select
        p.*
        ,p.p_d7_joint*p.frequency_coef*p.repeat_order_coef as rank_score
    from policy_score p
)
-- 按评分阈值生成原始等级。
,raw_tier as (
    select
        r.*
        ,case
            when r.rank_score>=r.s_min then 'S'
            when r.rank_score>=r.a_min then 'A'
            when r.rank_score>=r.b_min then 'B'
            when r.rank_score>=r.c_min then 'C'
            else 'D'
        end as raw_grade
    from ranked_score r
)
-- 应用频控排除和等级封顶规则。
,final_score as (
    select
        r.*
        ,case
            when frequency_hard_exclude_flag=1 then 'EXCLUDED'
            when hist_touch_day_cnt_4m=2 and raw_grade in ('S','A') then 'B'
            when hist_touch_day_cnt_4m>=3 and hist_touch_connect_day_cnt_4m>0 and raw_grade in ('S','A','B') then 'C'
            else raw_grade
        end as grade
    from raw_tier r
)
,scored_hash as (
    select
        f.*
        ,sha2(concat_ws(
            '#@#'
            ,coalesce(f.user_type,'__NULL__')
            ,coalesce(f.lst_active_dt,'__NULL__')
            ,coalesce(cast(f.s3_plus_subject_cnt as string),'__NULL__')
            ,coalesce(cast(f.season_min_pay_dt as string),'__NULL__')
            ,coalesce(cast(f.try_max_pay_dt as string),'__NULL__')
            ,coalesce(cast(f.has_valid_comm as string),'__NULL__')
            ,coalesce(cast(f.hist_finish_course_cnt as string),'__NULL__')
            ,coalesce(cast(f.last_try_pay_dt as string),'__NULL__')
            ,coalesce(f.hist_try_pay_channel,'__NULL__')
            ,coalesce(cast(f.prior_try_subject_cnt as string),'__NULL__')
            ,coalesce(cast(f.prior_try_order_cnt as string),'__NULL__')
            ,coalesce(f.app_profile_bucket,'__NULL__')
            ,coalesce(concat_ws(',',f.touch_dt_array_4m),'__EMPTY__')
            ,coalesce(concat_ws(',',f.connect_dt_array_4m),'__EMPTY__')
        ),256) as new_feature_hash
    from final_score f
)
,scored_delta as (
    select
        user_id
        ,previous_grade
        ,grade as new_grade
        ,previous_rank_score
        ,rank_score as new_rank_score
        ,rescore_reason
        ,if(
            touch_expire_flag=1
            ,array_union(changed_feature_list,array('touch_window_expire'))
            ,changed_feature_list
        ) as changed_feature_list
        ,previous_is_eligible
        ,new_is_eligible
        ,previous_feature_hash
        ,new_feature_hash
        ,user_type
        ,age
        ,lst_active_dt
        ,cast(s3_plus_subject_cnt as bigint) as s3_plus_subject_cnt
        ,cast(season_min_pay_dt as string) as season_min_pay_dt
        ,cast(try_max_pay_dt as string) as try_max_pay_dt
        ,has_valid_comm
        ,hist_finish_course_cnt
        ,cast(last_try_pay_dt as string) as last_try_pay_dt
        ,hist_try_pay_channel
        ,prior_try_subject_cnt
        ,prior_try_order_cnt
        ,app_profile_bucket
        ,call_detail_hash
        ,touch_dt_array_4m
        ,connect_dt_array_4m
        ,hist_touch_day_cnt_4m
        ,hist_touch_connect_day_cnt_4m
        ,days_since_last_active
        ,days_since_last_try_pay
        ,p_connect
        ,p_d7_given_connect
        ,p_d7_joint
        ,frequency_coef
        ,repeat_order_coef
        ,frequency_hard_exclude_flag
        ,raw_grade
        ,'3.1.1-a-8-features-no-age-bpo-drop-stock' as model_version
        ,if(previous_is_eligible=0,'NEW_ENTRY','CONTINUE') as entry_type
        ,coalesce(previous_first_entry_dt,'${date}') as first_entry_dt
        ,case
            when previous_is_eligible=0 or size(changed_feature_list)>0 or touch_expire_flag=1 then '${date}'
            else previous_last_feature_update_dt
        end as last_feature_update_dt
        ,'${date}' as last_score_dt
    from scored_hash
)
,exit_delta as (
    select
        user_id
        ,previous_grade
        ,cast(null as string) as new_grade
        ,previous_rank_score
        ,cast(null as double) as new_rank_score
        ,rescore_reason
        ,array_union(changed_feature_list,array('eligibility')) as changed_feature_list
        ,previous_is_eligible
        ,new_is_eligible
        ,previous_feature_hash
        ,cast(null as string) as new_feature_hash
        ,user_type
        ,age
        ,lst_active_dt
        ,s3_plus_subject_cnt
        ,season_min_pay_dt
        ,try_max_pay_dt
        ,has_valid_comm
        ,hist_finish_course_cnt
        ,last_try_pay_dt
        ,hist_try_pay_channel
        ,prior_try_subject_cnt
        ,prior_try_order_cnt
        ,app_profile_bucket
        ,call_detail_hash
        ,previous_touch_dt_array_4m as touch_dt_array_4m
        ,previous_connect_dt_array_4m as connect_dt_array_4m
        ,cast(null as bigint) as hist_touch_day_cnt_4m
        ,cast(null as bigint) as hist_touch_connect_day_cnt_4m
        ,cast(null as double) as days_since_last_active
        ,cast(null as double) as days_since_last_try_pay
        ,cast(null as double) as p_connect
        ,cast(null as double) as p_d7_given_connect
        ,cast(null as double) as p_d7_joint
        ,cast(null as double) as frequency_coef
        ,cast(null as double) as repeat_order_coef
        ,cast(null as int) as frequency_hard_exclude_flag
        ,cast(null as string) as raw_grade
        ,'3.1.1-a-8-features-no-age-bpo-drop-stock' as model_version
        ,'EXIT' as entry_type
        ,previous_first_entry_dt as first_entry_dt
        ,previous_last_feature_update_dt as last_feature_update_dt
        ,previous_last_score_dt as last_score_dt
    from rescore_candidate
    where previous_is_eligible=1
        and new_is_eligible=0
)
insert overwrite table dw_conan_ads.ads_eng_telesales_drop_stock_rescore_delta_di partition(dt='${date}',batch_no)
select
    user_id
    ,previous_grade
    ,new_grade
    ,previous_rank_score
    ,new_rank_score
    ,rescore_reason
    ,changed_feature_list
    ,previous_is_eligible
    ,new_is_eligible
    ,previous_feature_hash
    ,new_feature_hash
    ,user_type
    ,age
    ,lst_active_dt
    ,s3_plus_subject_cnt
    ,season_min_pay_dt
    ,try_max_pay_dt
    ,has_valid_comm
    ,hist_finish_course_cnt
    ,last_try_pay_dt
    ,hist_try_pay_channel
    ,prior_try_subject_cnt
    ,prior_try_order_cnt
    ,app_profile_bucket
    ,call_detail_hash
    ,touch_dt_array_4m
    ,connect_dt_array_4m
    ,hist_touch_day_cnt_4m
    ,hist_touch_connect_day_cnt_4m
    ,days_since_last_active
    ,days_since_last_try_pay
    ,p_connect
    ,p_d7_given_connect
    ,p_d7_joint
    ,frequency_coef
    ,repeat_order_coef
    ,frequency_hard_exclude_flag
    ,raw_grade
    ,model_version
    ,entry_type
    ,first_entry_dt
    ,last_feature_update_dt
    ,last_score_dt
    ,cast(pmod(xxhash64(trim(cast(user_id as string))),4) as string) as batch_no
from scored_delta

union all

select
    user_id
    ,previous_grade
    ,new_grade
    ,previous_rank_score
    ,new_rank_score
    ,rescore_reason
    ,changed_feature_list
    ,previous_is_eligible
    ,new_is_eligible
    ,previous_feature_hash
    ,new_feature_hash
    ,user_type
    ,age
    ,lst_active_dt
    ,s3_plus_subject_cnt
    ,season_min_pay_dt
    ,try_max_pay_dt
    ,has_valid_comm
    ,hist_finish_course_cnt
    ,last_try_pay_dt
    ,hist_try_pay_channel
    ,prior_try_subject_cnt
    ,prior_try_order_cnt
    ,app_profile_bucket
    ,call_detail_hash
    ,touch_dt_array_4m
    ,connect_dt_array_4m
    ,hist_touch_day_cnt_4m
    ,hist_touch_connect_day_cnt_4m
    ,days_since_last_active
    ,days_since_last_try_pay
    ,p_connect
    ,p_d7_given_connect
    ,p_d7_joint
    ,frequency_coef
    ,repeat_order_coef
    ,frequency_hard_exclude_flag
    ,raw_grade
    ,model_version
    ,entry_type
    ,first_entry_dt
    ,last_feature_update_dt
    ,last_score_dt
    ,cast(pmod(xxhash64(trim(cast(user_id as string))),4) as string) as batch_no
from exit_delta
;
