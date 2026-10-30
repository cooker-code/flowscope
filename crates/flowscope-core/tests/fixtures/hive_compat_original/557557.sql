-- set spark.driver.memory=16g;
-- set spark.driver.cores=1;
-- set spark.executor.memory=8g;
-- set spark.executor.cores=2;
 set spark.sql.sources.commitProtocolClass=com.kanyun.spark.UltimateStagingCommitProtocol; -- 支持并行重跑 & 解决重写时当前分区没数问题

-- BPO新客存量每日增量重评。
-- ${date}为当前特征快照日期，读取date_sub('${date}',1)状态。
-- 单任务一次处理全部用户，并按稳定user_id哈希动态写入batch_no=0、1、2、3。
-- 触发范围：昨日S/A、原始特征变化、拨打记录退出4个月窗口、当天新增新客、资格退出。
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

-- create table if not exists dw_conan_ads.ads_eng_telesales_new_stock_rescore_delta_di (
--     user_id string comment '用户ID'
--     ,previous_grade string comment '昨日等级'
--     ,new_grade string comment '今日重评等级，资格退出或输入非法时为空'
--     ,previous_rank_score double comment '昨日排序分'
--     ,new_rank_score double comment '今日重评排序分'
--     ,rescore_reason string comment '重评或退出原因'
--     ,changed_feature_list array<string> comment '发生变化的原始字段'
--     ,previous_is_eligible int comment '昨日是否在新客存量状态池'
--     ,new_is_eligible int comment '今日是否符合新客存量基础资格'
--     ,previous_feature_hash string comment '昨日原始特征哈希'
--     ,new_feature_hash string comment '今日原始特征哈希'
--     ,pd string comment '从未活跃或距今3个月以上'
--     ,user_type string comment 'market用户身份'
--     ,aes_phone string comment '加密手机号'
--     ,market_register_dt string comment 'market注册日期'
--     ,user_create_dt string comment '活跃表最早创建日期'
--     ,lst_active_dt string comment '最近活跃日期'
--     ,birthday string comment '有效生日'
--     ,age_years double comment '按评分锚点计算的年龄'
--     ,call_detail_hash string comment '近一年拨打明细原始JSON哈希'
--     ,touch_dt_array_4m array<string> comment '近4个月非AI拨打日期去重数组'
--     ,connect_dt_array_4m array<string> comment '近4个月非AI接通日期去重数组'
--     ,hist_touch_connected_day_cnt_4m double comment '近4个月非AI接通天数'
--     ,hist_touch_day_cnt_4m double comment '近4个月非AI拨打天数'
--     ,ip_address_update_dt string comment '最近IP更新时间'
--     ,ip_province string comment 'IP省份'
--     ,latest_device_manufacturer string comment '最近设备厂商'
--     ,latest_device_model string comment '最近设备型号'
--     ,age_bucket string comment '年龄分组'
--     ,jinjuan_tag double comment '金娟标签'
--     ,days_since_last_active double comment '评分锚点距最近活跃天数'
--     ,register_days double comment '评分锚点距注册或创建天数'
--     ,ip_address_age_days double comment '评分锚点距IP更新时间天数'
--     ,p_connect double comment '校准后接通概率'
--     ,p_d0_given_connect double comment '校准后接通条件下D0支付概率'
--     ,frequency_coef double comment '拨打频次折损系数'
--     ,frequency_hard_exclude_flag int comment '近4个月拨打至少3天且0接通标记'
--     ,raw_grade string comment '频控和年龄封顶前等级'
--     ,model_feature_json string comment '10个模型字段审计JSON'
--     ,model_version string comment '模型版本'
--     ,entry_type string comment 'NEW_ENTRY、CONTINUE、EXIT或INVALID_INPUT'
--     ,first_entry_dt string comment '首次进入状态表日期'
--     ,last_feature_update_dt string comment '最近一次原始特征更新日期'
--     ,last_score_dt string comment '最近一次实际评分日期'
-- )
-- comment 'BPO新客存量每日增量重评明细表'
-- partitioned by (
--     dt string comment '特征快照日期'
--     ,batch_no string comment '稳定哈希分批编号0至3'
-- )
-- stored as orc
-- ;
-- 


with previous_state as (
    select
        *
    from dw_conan_ads.ads_eng_telesales_new_stock_score_state_da
    where dt=date_sub('${date}',1)
)
,market_info as (
    select
        cast(userid as string) as user_id
        ,user_type
        ,to_date(register_dt) as market_register_dt
        ,call_1year_detail_json
        ,sha2(coalesce(call_1year_detail_json,'[]'),256) as call_detail_hash
    from dw_conan_dwd.dwd_market_user_info_da
    where dt='${date}'
)
,aes_phone as (
    select
        cast(userid as string) as user_id
        ,phone as aes_phone
    from dw_conan_dwd.dwd_market_user_feature_aes_phone_da
    where dt='${date}'
)
,active_tag as (
    select
        cast(user_id as string) as user_id
        ,min(to_date(create_dt)) as user_create_dt
        ,max(to_date(lst_active_dt)) as lst_active_dt
    from dw_conan_dwd.dwd_eng_user_active_da
    where dt='${date}'
    group by cast(user_id as string)
)
,paid_user as (
    select
        cast(user_id as string) as user_id
    from dw_conan_dwd.dwd_eng_order_course_detail_da
    where dt='${date}'
        and order_status>=2
    group by cast(user_id as string)
)
,age_source as (
    select
        cast(userid as string) as user_id
        ,case
            when birthday is null or trim(cast(birthday as string))='' then null
            when to_date(birthday) in ('1970-01-01','1900-01-01') then null
            when lower(trim(coalesce(cast(defaultbirthday as string),'0'))) in ('1','true') then null
            when to_date(birthday) is null then null
            else to_date(birthday)
        end as birthday
    from dw_conan_dwd.dwd_site_user_reg_profile_da
    where dt='${date}'
)
,ip_feature as (
    select
        cast(i.user_id as string) as user_id
        ,to_date(from_unixtime(cast(i.last_action_tp/1000 as bigint))) as ip_address_update_dt
        ,coalesce(cast(i.province as string),'缺失') as ip_province
    from dw_conan_dim.dim_eng_user_req_parse_da i
    where i.dt='${date}'
        and (
            i.last_action_tp is null
            or to_date(from_unixtime(cast(i.last_action_tp/1000 as bigint)))<=to_date('${date}')
        )
)
,device_ranked as (
    select
        cast(d.user_id as string) as user_id
        ,coalesce(cast(d.manufacturer as string),'缺失') as latest_device_manufacturer
        ,coalesce(cast(d.model as string),'缺失') as latest_device_model
        ,row_number() over(
            partition by cast(d.user_id as string)
            order by to_date(d.fst_rela_dt) desc,d.device_id
        ) as rn
    from dw_conan_dwd.dwd_eng_user_device_rela_frog_da d
    where d.dt='${date}'
        and to_date(d.fst_rela_dt)<=to_date('${date}')
)
,device_feature as (
    select
        user_id
        ,latest_device_manufacturer
        ,latest_device_model
    from device_ranked
    where rn=1
)
,jinjuan_feature as (
    select distinct
        cast(j.user_id as string) as user_id
    from dw_conan_ori.ori_conan_fusion_jinjuan_data_da j
    where j.user_id is not null
        and j.dbctime is not null
        and cast(j.dbctime as timestamp)<cast(date_add(to_date('${date}'),1) as timestamp)
)
,current_raw as (
    select
        m.user_id
        ,case
            when a.lst_active_dt is null then '从未活跃'
            else '距今3个月以上'
        end as pd
        ,m.user_type
        ,p.aes_phone
        ,cast(m.market_register_dt as string) as market_register_dt
        ,cast(a.user_create_dt as string) as user_create_dt
        ,cast(a.lst_active_dt as string) as lst_active_dt
        ,cast(g.birthday as string) as birthday
        ,case
            when g.birthday is null or g.birthday>date_add(to_date('${date}'),1) then null
            else months_between(date_add(to_date('${date}'),1),g.birthday)/12
        end as age_years
        ,m.call_1year_detail_json
        ,m.call_detail_hash
        ,cast(i.ip_address_update_dt as string) as ip_address_update_dt
        ,coalesce(i.ip_province,'缺失') as ip_province
        ,coalesce(d.latest_device_manufacturer,'缺失') as latest_device_manufacturer
        ,coalesce(d.latest_device_model,'缺失') as latest_device_model
        ,case
            when g.birthday is null or g.birthday>date_add(to_date('${date}'),1) then 'age_missing'
            when months_between(date_add(to_date('${date}'),1),g.birthday)/12<2 then 'age_lt_2'
            when months_between(date_add(to_date('${date}'),1),g.birthday)/12<9 then 'age_2_8'
            when months_between(date_add(to_date('${date}'),1),g.birthday)/12<11 then 'age_9_10'
            else 'age_ge_11'
        end as age_bucket
        ,cast(if(j.user_id is null,0,1) as double) as jinjuan_tag
        ,if(
            o.user_id is null
            and (
                a.lst_active_dt is null
                or (
                    a.lst_active_dt<=add_months(date_add(to_date('${date}'),1),-3)
                    and datediff(date_add(to_date('${date}'),1),a.lst_active_dt)<=720
                )
            )
            and (
                g.birthday is null
                or g.birthday>date_add(to_date('${date}'),1)
                or months_between(date_add(to_date('${date}'),1),g.birthday)/12<10
            )
            ,1
            ,0
        ) as is_eligible
    from market_info m
    left join aes_phone p
        on m.user_id=p.user_id
    left join active_tag a
        on m.user_id=a.user_id
    left join paid_user o
        on m.user_id=o.user_id
    left join age_source g
        on m.user_id=g.user_id
    left join ip_feature i
        on m.user_id=i.user_id
    left join device_feature d
        on m.user_id=d.user_id
    left join jinjuan_feature j
        on m.user_id=j.user_id
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
        ,c.pd
        ,c.user_type
        ,c.aes_phone
        ,c.market_register_dt
        ,c.user_create_dt
        ,c.lst_active_dt
        ,c.birthday
        ,c.age_years
        ,c.call_1year_detail_json
        ,c.call_detail_hash
        ,c.ip_address_update_dt
        ,c.ip_province
        ,c.latest_device_manufacturer
        ,c.latest_device_model
        ,c.age_bucket
        ,c.jinjuan_tag
        ,filter(array(
            if(not (c.user_type<=>p.user_type),'user_type',null)
            ,if(not (c.aes_phone<=>p.aes_phone),'aes_phone',null)
            ,if(not (c.market_register_dt<=>p.market_register_dt),'market_register_dt',null)
            ,if(not (c.user_create_dt<=>p.user_create_dt),'user_create_dt',null)
            ,if(not (c.lst_active_dt<=>p.lst_active_dt),'lst_active_dt',null)
            ,if(not (c.birthday<=>p.birthday),'birthday',null)
            ,if(not (c.call_detail_hash<=>p.call_detail_hash),'call_detail_hash',null)
            ,if(not (c.ip_address_update_dt<=>p.ip_address_update_dt),'ip_address_update_dt',null)
            ,if(not (c.ip_province<=>p.ip_province),'ip_province',null)
            ,if(not (c.latest_device_manufacturer<=>p.latest_device_manufacturer),'latest_device_manufacturer',null)
            ,if(not (c.latest_device_model<=>p.latest_device_model),'latest_device_model',null)
            ,if(not (c.age_bucket<=>p.age_bucket),'age_bucket',null)
            ,if(not (c.jinjuan_tag<=>p.jinjuan_tag),'jinjuan_tag',null)
        ),x -> x is not null) as changed_feature_list
        ,if(
            exists(p.touch_dt_array_4m,x -> to_date(x)<add_months(date_add(to_date('${date}'),1),-4))
            or exists(p.connect_dt_array_4m,x -> to_date(x)<add_months(date_add(to_date('${date}'),1),-4))
            ,1
            ,0
        ) as touch_expire_flag
    from previous_state p
    full outer join current_raw c
        on p.user_id=c.user_id
    where p.user_id is not null
        or c.is_eligible=1
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
,touch_register_feature as (
    select
        s.*
        ,date_add(to_date('${date}'),1) as anchor_dt
        ,get_json_object(coalesce(s.call_1year_detail_json,'[]'),'$') as call_json
    from score_input s
)
,touch_event as (
    select
        t.user_id
        ,if(t.call_json is null or substr(t.call_json,1,1)<>'[',1,0) as touch_json_invalid_flag
        ,to_date(j.call_dt) as call_dt
        ,j.biz_type
        ,cast(j.is_connected as int) as is_connected
    from touch_register_feature t
    lateral view outer explode(
        split(
            regexp_replace(
                substr(t.call_json,2,length(t.call_json)-2)
                ,'\\G(\\{(?:[^"{}]++|"(?:[^"\\\\]++|\\\\.)*+")*+\\}|null)(?:,|\\z)'
                ,concat('$1',chr(1))
            )
            ,chr(1)
        )
    ) e as call_item_json
    lateral view json_tuple(e.call_item_json,'call_dt','biz_type','is_connected') j as call_dt,biz_type,is_connected
)
,touch_feature as (
    select
        s.*
        ,max(e.touch_json_invalid_flag) as touch_json_invalid_flag
        ,sort_array(collect_set(if(
            e.call_dt between add_months(s.anchor_dt,-4) and date_sub(s.anchor_dt,1)
            and coalesce(trim(e.biz_type),'') not in ('内测AI','阶段测AI','其他AI')
            ,cast(e.call_dt as string),null
        ))) as touch_dt_array_4m
        ,sort_array(collect_set(if(
            e.call_dt between add_months(s.anchor_dt,-4) and date_sub(s.anchor_dt,1)
            and coalesce(trim(e.biz_type),'') not in ('内测AI','阶段测AI','其他AI')
            and coalesce(e.is_connected,0)=1
            ,cast(e.call_dt as string),null
        ))) as connect_dt_array_4m
        ,size(collect_set(if(
            e.call_dt between add_months(s.anchor_dt,-4) and date_sub(s.anchor_dt,1)
            and coalesce(trim(e.biz_type),'') not in ('内测AI','阶段测AI','其他AI')
            ,e.call_dt,null
        ))) as hist_touch_day_cnt_4m
        ,size(collect_set(if(
            e.call_dt between add_months(s.anchor_dt,-4) and date_sub(s.anchor_dt,1)
            and coalesce(trim(e.biz_type),'') not in ('内测AI','阶段测AI','其他AI')
            and coalesce(e.is_connected,0)=1
            ,e.call_dt,null
        ))) as hist_touch_connected_day_cnt_4m
    from touch_register_feature s
    left join touch_event e
        on s.user_id=e.user_id
    group by
        s.user_id
        ,s.previous_grade
        ,s.previous_rank_score
        ,s.previous_is_eligible
        ,s.new_is_eligible
        ,s.previous_feature_hash
        ,s.previous_first_entry_dt
        ,s.previous_last_feature_update_dt
        ,s.previous_last_score_dt
        ,s.previous_touch_dt_array_4m
        ,s.previous_connect_dt_array_4m
        ,s.pd
        ,s.user_type
        ,s.aes_phone
        ,s.market_register_dt
        ,s.user_create_dt
        ,s.lst_active_dt
        ,s.birthday
        ,s.age_years
        ,s.call_1year_detail_json
        ,s.call_detail_hash
        ,s.ip_address_update_dt
        ,s.ip_province
        ,s.latest_device_manufacturer
        ,s.latest_device_model
        ,s.age_bucket
        ,s.jinjuan_tag
        ,s.changed_feature_list
        ,s.touch_expire_flag
        ,s.rescore_reason
        ,s.anchor_dt
        ,s.call_json
)
,feature_base as (
    select
        t.pd
        ,t.user_type
        ,t.user_id
        ,t.aes_phone
        ,t.market_register_dt
        ,t.user_create_dt
        ,t.lst_active_dt
        ,t.birthday
        ,t.call_detail_hash
        ,t.touch_dt_array_4m
        ,t.connect_dt_array_4m
        ,t.ip_address_update_dt
        ,cast(t.anchor_dt as string) as anchor_dt
        ,cast(coalesce(t.hist_touch_connected_day_cnt_4m,0) as double) as hist_touch_connected_day_cnt_4m
        ,cast(coalesce(t.hist_touch_day_cnt_4m,0) as double) as hist_touch_day_cnt_4m
        ,cast(datediff(t.anchor_dt,to_date(t.lst_active_dt)) as double) as days_since_last_active
        ,cast(
            case
                when t.user_create_dt is null and t.market_register_dt is null then null
                when t.user_create_dt is null then datediff(t.anchor_dt,to_date(t.market_register_dt))
                when t.market_register_dt is null then datediff(t.anchor_dt,to_date(t.user_create_dt))
                else datediff(t.anchor_dt,least(to_date(t.user_create_dt),to_date(t.market_register_dt)))
            end
            as double
        ) as register_days
        ,cast(datediff(t.anchor_dt,to_date(t.ip_address_update_dt)) as double) as ip_address_age_days
        ,t.ip_province
        ,t.latest_device_manufacturer
        ,t.latest_device_model
        ,t.age_bucket
        ,t.jinjuan_tag
        ,cast(t.age_years as double) as age_years
        ,t.touch_json_invalid_flag
    from touch_feature t
)
-- 固定读取已发布的SQL版模型参数，不在每日任务中取max(dt)。
,model_param_source as (
    select
        model_stage
        ,param_type
        ,coalesce(nullif(trim(feature_name),''),'__NULL__') as feature_name
        ,coalesce(nullif(trim(feature_value),''),'__NULL__') as feature_value
        ,effective_coefficient
        ,impute_value
        ,param_value
    from temp.tmk_bpo_new_stock_model_2_0_sql_param_da
    where dt='2026-09-22'
        and model_version='2.1-bpo-new-stock-lr-lr-d0-sql-v1'
        and model_stage is not null
        and param_type is not null
)
-- 431行参数一次聚合成一行；Base64参数键避免渠道/设备名称中的分隔符碰撞。
-- Hive的str_to_map返回字符串值，取值时显式转double，评分数值口径不变。
,model_param_map as (
    select
        str_to_map(concat_ws(',',collect_list(if(
            effective_coefficient is not null
            ,concat(base64(encode(concat_ws('#@#',model_stage,param_type,feature_name,feature_value),'UTF-8')),':',cast(cast(effective_coefficient as double) as string))
            ,null
        ))),',',':') as coefficient_map
        ,str_to_map(concat_ws(',',collect_list(if(
            param_type='numeric_feature' and impute_value is not null
            ,concat(base64(encode(concat_ws('#@#',model_stage,param_type,feature_name,feature_value),'UTF-8')),':',cast(cast(impute_value as double) as string))
            ,null
        ))),',',':') as impute_map
        ,str_to_map(concat_ws(',',collect_list(if(
            param_value is not null
            ,concat(base64(encode(concat_ws('#@#',model_stage,param_type,feature_name,feature_value),'UTF-8')),':',cast(cast(param_value as double) as string))
            ,null
        ))),',',':') as param_value_map
        ,assert_true(
            count(*)=431
            and count(distinct concat_ws('#@#',model_stage,param_type,feature_name,feature_value))=431
            and sum(if(model_stage='connect',1,0))=274
            and sum(if(model_stage='d0_given_connect',1,0))=132
            and sum(if(model_stage='ranking',1,0))=15
            and sum(if(model_stage='shared',1,0))=10
        ) as param_guard
    from model_param_source
)
-- 分类缺失值归一，并校验模型输入。
,feature_normalized as (
    select
        pd
        ,user_type
        ,user_id
        ,aes_phone
        ,market_register_dt
        ,user_create_dt
        ,lst_active_dt
        ,birthday
        ,call_detail_hash
        ,touch_dt_array_4m
        ,connect_dt_array_4m
        ,ip_address_update_dt
        ,anchor_dt
        ,hist_touch_connected_day_cnt_4m
        ,hist_touch_day_cnt_4m
        ,days_since_last_active
        ,register_days
        ,ip_address_age_days
        ,coalesce(ip_province,'缺失') as ip_province
        ,coalesce(latest_device_manufacturer,'缺失') as latest_device_manufacturer
        ,coalesce(latest_device_model,'缺失') as latest_device_model
        ,coalesce(age_bucket,'age_missing') as age_bucket
        ,jinjuan_tag
        ,age_years
        ,case
            when coalesce(touch_json_invalid_flag,0)=1 then 1
            when user_id is null or trim(user_id)='' then 1
            when hist_touch_day_cnt_4m<0 or hist_touch_connected_day_cnt_4m<0 then 1
            when hist_touch_connected_day_cnt_4m>hist_touch_day_cnt_4m then 1
            when cast(floor(hist_touch_day_cnt_4m) as double)<>hist_touch_day_cnt_4m then 1
            when cast(floor(hist_touch_connected_day_cnt_4m) as double)<>hist_touch_connected_day_cnt_4m then 1
            when days_since_last_active<0 or register_days<0 or ip_address_age_days<0 then 1
            when jinjuan_tag is not null and jinjuan_tag not in (0,1) then 1
            else 0
        end as model_input_invalid_flag
    from feature_base
)
,feature_with_param as (
    select /*+ MAPJOIN(p) */
        f.*
        ,p.coefficient_map
        ,p.impute_map
        ,p.param_value_map
        ,p.param_guard
    from feature_normalized f
    cross join model_param_map p
)
-- 计算接通模型10个字段、接通后D0转化模型8个字段的贡献。
,feature_contribution as (
    select
        f.*
        ,coalesce(hist_touch_connected_day_cnt_4m,cast(impute_map[base64(encode('connect#@#numeric_feature#@#hist_touch_connected_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#hist_touch_connected_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as c_hist_touch_connected
        ,coalesce(hist_touch_day_cnt_4m,cast(impute_map[base64(encode('connect#@#numeric_feature#@#hist_touch_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#hist_touch_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as c_hist_touch
        ,coalesce(days_since_last_active,cast(impute_map[base64(encode('connect#@#numeric_feature#@#days_since_last_active#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#days_since_last_active#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(days_since_last_active is null,coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_missing_indicator#@#days_since_last_active#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as c_last_active
        ,coalesce(register_days,cast(impute_map[base64(encode('connect#@#numeric_feature#@#register_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#register_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(register_days is null,coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_missing_indicator#@#register_days#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as c_register
        ,coalesce(ip_address_age_days,cast(impute_map[base64(encode('connect#@#numeric_feature#@#ip_address_age_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#ip_address_age_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(ip_address_age_days is null,coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_missing_indicator#@#ip_address_age_days#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as c_ip_age
        ,coalesce(cast(coefficient_map[base64(encode(concat('connect#@#categorical_mapping#@#ip_province#@#',ip_province),'UTF-8'))] as double),cast(coefficient_map[base64(encode('connect#@#categorical_unknown_mapping#@#ip_province#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as c_ip_province
        ,coalesce(cast(coefficient_map[base64(encode(concat('connect#@#categorical_mapping#@#latest_device_manufacturer#@#',latest_device_manufacturer),'UTF-8'))] as double),cast(coefficient_map[base64(encode('connect#@#categorical_unknown_mapping#@#latest_device_manufacturer#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as c_device_manufacturer
        ,coalesce(cast(coefficient_map[base64(encode(concat('connect#@#categorical_mapping#@#latest_device_model#@#',latest_device_model),'UTF-8'))] as double),cast(coefficient_map[base64(encode('connect#@#categorical_unknown_mapping#@#latest_device_model#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as c_device_model
        ,coalesce(cast(coefficient_map[base64(encode(concat('connect#@#categorical_mapping#@#age_bucket#@#',age_bucket),'UTF-8'))] as double),cast(coefficient_map[base64(encode('connect#@#categorical_unknown_mapping#@#age_bucket#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as c_age_bucket
        ,coalesce(jinjuan_tag,cast(impute_map[base64(encode('connect#@#numeric_feature#@#jinjuan_tag#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('connect#@#numeric_feature#@#jinjuan_tag#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as c_jinjuan
        ,coalesce(hist_touch_connected_day_cnt_4m,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#hist_touch_connected_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#hist_touch_connected_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as d_hist_touch_connected
        ,coalesce(hist_touch_day_cnt_4m,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#hist_touch_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#hist_touch_day_cnt_4m#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as d_hist_touch
        ,coalesce(days_since_last_active,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#days_since_last_active#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#days_since_last_active#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(days_since_last_active is null,coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_missing_indicator#@#days_since_last_active#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as d_last_active
        ,coalesce(register_days,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#register_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#register_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(register_days is null,coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_missing_indicator#@#register_days#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as d_register
        ,coalesce(ip_address_age_days,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#ip_address_age_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#ip_address_age_days#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +if(ip_address_age_days is null,coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_missing_indicator#@#ip_address_age_days#@#1_if_null_else_0','UTF-8'))] as double),cast(0 as double)),cast(0 as double)) as d_ip_age
        ,coalesce(cast(coefficient_map[base64(encode(concat('d0_given_connect#@#categorical_mapping#@#ip_province#@#',ip_province),'UTF-8'))] as double),cast(coefficient_map[base64(encode('d0_given_connect#@#categorical_unknown_mapping#@#ip_province#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as d_ip_province
        ,coalesce(cast(coefficient_map[base64(encode(concat('d0_given_connect#@#categorical_mapping#@#latest_device_manufacturer#@#',latest_device_manufacturer),'UTF-8'))] as double),cast(coefficient_map[base64(encode('d0_given_connect#@#categorical_unknown_mapping#@#latest_device_manufacturer#@#__unknown_or_missing__','UTF-8'))] as double),cast(0 as double)) as d_device_manufacturer
        ,coalesce(jinjuan_tag,cast(impute_map[base64(encode('d0_given_connect#@#numeric_feature#@#jinjuan_tag#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            *coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#numeric_feature#@#jinjuan_tag#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as d_jinjuan
    from feature_with_param f
)
-- 两阶段线性项、原始概率与校准后概率。
,linear_score as (
    select
        f.*
        ,coalesce(cast(coefficient_map[base64(encode('connect#@#model_intercept#@#intercept#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +c_hist_touch_connected+c_hist_touch+c_last_active+c_register+c_ip_age+c_ip_province+c_device_manufacturer+c_device_model+c_age_bucket+c_jinjuan as connect_raw_logit
        ,coalesce(cast(coefficient_map[base64(encode('d0_given_connect#@#model_intercept#@#intercept#@#__NULL__','UTF-8'))] as double),cast(0 as double))
            +d_hist_touch_connected+d_hist_touch+d_last_active+d_register+d_ip_age+d_ip_province+d_device_manufacturer+d_jinjuan as d0_raw_logit
        ,coalesce(cast(param_value_map[base64(encode('connect#@#calibration_coefficient#@#raw_probability_logit#@#__NULL__','UTF-8'))] as double),cast(1 as double)) as c_calibration_coef
        ,coalesce(cast(param_value_map[base64(encode('connect#@#calibration_intercept#@#intercept#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as c_calibration_intercept
        ,coalesce(cast(param_value_map[base64(encode('connect#@#calibration_clip_epsilon#@#probability_clip#@#__NULL__','UTF-8'))] as double),cast(0.000001 as double)) as c_clip_epsilon
        ,coalesce(cast(param_value_map[base64(encode('d0_given_connect#@#calibration_coefficient#@#raw_probability_logit#@#__NULL__','UTF-8'))] as double),cast(1 as double)) as d_calibration_coef
        ,coalesce(cast(param_value_map[base64(encode('d0_given_connect#@#calibration_intercept#@#intercept#@#__NULL__','UTF-8'))] as double),cast(0 as double)) as d_calibration_intercept
        ,coalesce(cast(param_value_map[base64(encode('d0_given_connect#@#calibration_clip_epsilon#@#probability_clip#@#__NULL__','UTF-8'))] as double),cast(0.000001 as double)) as d_clip_epsilon
    from feature_contribution f
)
,raw_probability_score as (
    select
        f.*
        ,greatest(c_clip_epsilon,least(cast(1 as double)-c_clip_epsilon,cast(1 as double)/(cast(1 as double)+exp(-connect_raw_logit)))) as connect_raw_probability
        ,greatest(d_clip_epsilon,least(cast(1 as double)-d_clip_epsilon,cast(1 as double)/(cast(1 as double)+exp(-d0_raw_logit)))) as d0_raw_probability
    from linear_score f
)
,probability_score as (
    select
        f.*
        ,greatest(
            c_clip_epsilon
            ,least(
                cast(1 as double)-c_clip_epsilon
                ,cast(1 as double)/(cast(1 as double)+exp(-(c_calibration_intercept+c_calibration_coef*ln(connect_raw_probability/(cast(1 as double)-connect_raw_probability)))))
            )
        ) as p_connect
        ,greatest(
            d_clip_epsilon
            ,least(
                cast(1 as double)-d_clip_epsilon
                ,cast(1 as double)/(cast(1 as double)+exp(-(d_calibration_intercept+d_calibration_coef*ln(d0_raw_probability/(cast(1 as double)-d0_raw_probability)))))
            )
        ) as p_d0_given_connect
    from raw_probability_score f
)
-- 接通后D0转化概率乘近4个月触达频次折损，得到最终排序分。
,rank_score_result as (
    select
        f.*
        ,case
            when coalesce(hist_touch_day_cnt_4m,0)=0 then coalesce(cast(param_value_map[base64(encode('ranking#@#frequency_coefficient#@#hist_touch_day_cnt_4m#@#0','UTF-8'))] as double),cast(1 as double))
            when hist_touch_day_cnt_4m=1 then coalesce(cast(param_value_map[base64(encode('ranking#@#frequency_coefficient#@#hist_touch_day_cnt_4m#@#1','UTF-8'))] as double),cast(0.8 as double))
            when hist_touch_day_cnt_4m=2 then coalesce(cast(param_value_map[base64(encode('ranking#@#frequency_coefficient#@#hist_touch_day_cnt_4m#@#2','UTF-8'))] as double),cast(0.5 as double))
            when hist_touch_day_cnt_4m>=3 then coalesce(cast(param_value_map[base64(encode('ranking#@#frequency_coefficient#@#hist_touch_day_cnt_4m#@#3_plus','UTF-8'))] as double),cast(0.2 as double))
            else cast(0 as double)
        end as frequency_coef
    from probability_score f
)
,raw_grade_result as (
    select
        f.*
        ,p_d0_given_connect*frequency_coef as rank_score
    from rank_score_result f
)
,policy_result as (
    select
        f.*
        ,case
            when rank_score>=cast(param_value_map[base64(encode('ranking#@#tier_threshold#@#S_min#@#__NULL__','UTF-8'))] as double) then 1
            when rank_score>=cast(param_value_map[base64(encode('ranking#@#tier_threshold#@#A_min#@#__NULL__','UTF-8'))] as double) then 2
            when rank_score>=cast(param_value_map[base64(encode('ranking#@#tier_threshold#@#B_min#@#__NULL__','UTF-8'))] as double) then 3
            when rank_score>=cast(param_value_map[base64(encode('ranking#@#tier_threshold#@#C_min#@#__NULL__','UTF-8'))] as double) then 4
            else 5
        end as raw_grade_rank
        ,if(hist_touch_day_cnt_4m>=3 and coalesce(hist_touch_connected_day_cnt_4m,0)=0,1,0) as frequency_hard_exclude_flag
        ,case
            when hist_touch_day_cnt_4m=2 then 3
            when hist_touch_day_cnt_4m>=3 and coalesce(hist_touch_connected_day_cnt_4m,0)>0 then 4
            else 1
        end as frequency_grade_cap_rank
        ,if(age_years>=9,4,1) as age_grade_cap_rank
    from raw_grade_result f
)
-- 仅整理JSON展示文本：正常值转义引号/反斜杠，含控制字符时用Unicode转义保留原值。
-- 这些辅助字段不参与模型计算；年龄分组是固定枚举，无须清洗。
,json_ready as (
    select
        f.*
        ,case
            when ip_province rlike '[\\x00-\\x1F]' then
                concat(chr(34),regexp_replace(hex(encode(ip_province,'UTF-16BE')),'(.{4})',concat(chr(92),chr(92),'u$1')),chr(34))
            else
                concat(chr(34),replace(replace(ip_province,chr(92),concat(chr(92),chr(92))),chr(34),concat(chr(92),chr(34))),chr(34))
        end as ip_province_json
        ,case
            when latest_device_manufacturer rlike '[\\x00-\\x1F]' then
                concat(chr(34),regexp_replace(hex(encode(latest_device_manufacturer,'UTF-16BE')),'(.{4})',concat(chr(92),chr(92),'u$1')),chr(34))
            else
                concat(chr(34),replace(replace(latest_device_manufacturer,chr(92),concat(chr(92),chr(92))),chr(34),concat(chr(92),chr(34))),chr(34))
        end as latest_device_manufacturer_json
        ,case
            when latest_device_model rlike '[\\x00-\\x1F]' then
                concat(chr(34),regexp_replace(hex(encode(latest_device_model,'UTF-16BE')),'(.{4})',concat(chr(92),chr(92),'u$1')),chr(34))
            else
                concat(chr(34),replace(replace(latest_device_model,chr(92),concat(chr(92),chr(92))),chr(34),concat(chr(92),chr(34))),chr(34))
        end as latest_device_model_json
    from policy_result f
)
-- 生成最终等级、原始特征哈希及状态字段。
,scored_user as (
    select
        user_id
        ,pd
        ,user_type
        ,aes_phone
        ,market_register_dt
        ,user_create_dt
        ,lst_active_dt
        ,birthday
        ,age_years
        ,call_detail_hash
        ,touch_dt_array_4m
        ,connect_dt_array_4m
        ,hist_touch_connected_day_cnt_4m
        ,hist_touch_day_cnt_4m
        ,ip_address_update_dt
        ,ip_province
        ,latest_device_manufacturer
        ,latest_device_model
        ,age_bucket
        ,jinjuan_tag
        ,days_since_last_active
        ,register_days
        ,ip_address_age_days
        ,p_connect
        ,p_d0_given_connect
        ,frequency_coef
        ,rank_score
        ,case
            when raw_grade_rank=1 then 'S'
            when raw_grade_rank=2 then 'A'
            when raw_grade_rank=3 then 'B'
            when raw_grade_rank=4 then 'C'
            else 'D'
        end as raw_grade
        ,frequency_hard_exclude_flag
        ,case
            when frequency_hard_exclude_flag=1 then 'EXCLUDED'
            when greatest(raw_grade_rank,frequency_grade_cap_rank,age_grade_cap_rank)=1 then 'S'
            when greatest(raw_grade_rank,frequency_grade_cap_rank,age_grade_cap_rank)=2 then 'A'
            when greatest(raw_grade_rank,frequency_grade_cap_rank,age_grade_cap_rank)=3 then 'B'
            when greatest(raw_grade_rank,frequency_grade_cap_rank,age_grade_cap_rank)=4 then 'C'
            else 'D'
        end as grade
        ,concat(
            '{"hist_touch_connected_day_cnt_4m":',coalesce(cast(hist_touch_connected_day_cnt_4m as string),'null')
            ,',"hist_touch_day_cnt_4m":',coalesce(cast(hist_touch_day_cnt_4m as string),'null')
            ,',"days_since_last_active":',coalesce(cast(days_since_last_active as string),'null')
            ,',"register_days":',coalesce(cast(register_days as string),'null')
            ,',"ip_address_age_days":',coalesce(cast(ip_address_age_days as string),'null')
            ,',"ip_province":',ip_province_json
            ,',"latest_device_manufacturer":',latest_device_manufacturer_json
            ,',"latest_device_model":',latest_device_model_json
            ,',"age_bucket":"',age_bucket,'"'
            ,',"jinjuan_tag":',coalesce(cast(jinjuan_tag as string),'null')
            ,'}'
        ) as model_feature_json
        ,sha2(concat_ws('#@#'
            ,coalesce(market_register_dt,'__NULL__')
            ,coalesce(user_create_dt,'__NULL__')
            ,coalesce(lst_active_dt,'__NULL__')
            ,coalesce(birthday,'__NULL__')
            ,coalesce(call_detail_hash,'__NULL__')
            ,coalesce(ip_address_update_dt,'__NULL__')
            ,coalesce(ip_province,'__NULL__')
            ,coalesce(latest_device_manufacturer,'__NULL__')
            ,coalesce(latest_device_model,'__NULL__')
            ,coalesce(age_bucket,'__NULL__')
            ,coalesce(cast(jinjuan_tag as string),'__NULL__')
        ),256) as raw_feature_hash
        ,model_input_invalid_flag
        ,param_guard
    from json_ready
)

,valid_scored_delta as (
    select
        s.user_id
        ,c.previous_grade
        ,s.grade as new_grade
        ,c.previous_rank_score
        ,s.rank_score as new_rank_score
        ,c.rescore_reason
        ,if(
            c.touch_expire_flag=1
            ,array_union(c.changed_feature_list,array('touch_window_expire'))
            ,c.changed_feature_list
        ) as changed_feature_list
        ,c.previous_is_eligible
        ,c.new_is_eligible
        ,c.previous_feature_hash
        ,s.raw_feature_hash as new_feature_hash
        ,s.pd
        ,s.user_type
        ,s.aes_phone
        ,s.market_register_dt
        ,s.user_create_dt
        ,s.lst_active_dt
        ,s.birthday
        ,s.age_years
        ,s.call_detail_hash
        ,s.touch_dt_array_4m
        ,s.connect_dt_array_4m
        ,s.hist_touch_connected_day_cnt_4m
        ,s.hist_touch_day_cnt_4m
        ,s.ip_address_update_dt
        ,s.ip_province
        ,s.latest_device_manufacturer
        ,s.latest_device_model
        ,s.age_bucket
        ,s.jinjuan_tag
        ,s.days_since_last_active
        ,s.register_days
        ,s.ip_address_age_days
        ,s.p_connect
        ,s.p_d0_given_connect
        ,s.frequency_coef
        ,s.frequency_hard_exclude_flag
        ,s.raw_grade
        ,s.model_feature_json
        ,'2.1-bpo-new-stock-lr-lr-d0-sql-v1' as model_version
        ,if(c.previous_is_eligible=0,'NEW_ENTRY','CONTINUE') as entry_type
        ,coalesce(c.previous_first_entry_dt,'${date}') as first_entry_dt
        ,case
            when c.previous_is_eligible=0 or size(c.changed_feature_list)>0 or c.touch_expire_flag=1 then '${date}'
            else c.previous_last_feature_update_dt
        end as last_feature_update_dt
        ,'${date}' as last_score_dt
    from scored_user s
    inner join rescore_candidate c
        on s.user_id=c.user_id
    where s.model_input_invalid_flag=0
        and s.param_guard is null
)
,invalid_input_delta as (
    select
        s.user_id
        ,c.previous_grade
        ,cast(null as string) as new_grade
        ,c.previous_rank_score
        ,cast(null as double) as new_rank_score
        ,'MODEL_INPUT_INVALID' as rescore_reason
        ,array_union(c.changed_feature_list,array('model_input_invalid')) as changed_feature_list
        ,c.previous_is_eligible
        ,c.new_is_eligible
        ,c.previous_feature_hash
        ,cast(null as string) as new_feature_hash
        ,s.pd
        ,s.user_type
        ,s.aes_phone
        ,s.market_register_dt
        ,s.user_create_dt
        ,s.lst_active_dt
        ,s.birthday
        ,s.age_years
        ,s.call_detail_hash
        ,s.touch_dt_array_4m
        ,s.connect_dt_array_4m
        ,s.hist_touch_connected_day_cnt_4m
        ,s.hist_touch_day_cnt_4m
        ,s.ip_address_update_dt
        ,s.ip_province
        ,s.latest_device_manufacturer
        ,s.latest_device_model
        ,s.age_bucket
        ,s.jinjuan_tag
        ,s.days_since_last_active
        ,s.register_days
        ,s.ip_address_age_days
        ,cast(null as double) as p_connect
        ,cast(null as double) as p_d0_given_connect
        ,cast(null as double) as frequency_coef
        ,cast(null as int) as frequency_hard_exclude_flag
        ,cast(null as string) as raw_grade
        ,cast(null as string) as model_feature_json
        ,'2.1-bpo-new-stock-lr-lr-d0-sql-v1' as model_version
        ,'INVALID_INPUT' as entry_type
        ,coalesce(c.previous_first_entry_dt,'${date}') as first_entry_dt
        ,c.previous_last_feature_update_dt as last_feature_update_dt
        ,c.previous_last_score_dt as last_score_dt
    from scored_user s
    inner join rescore_candidate c
        on s.user_id=c.user_id
    where s.model_input_invalid_flag=1
)
,exit_delta as (
    select
        c.user_id
        ,c.previous_grade
        ,cast(null as string) as new_grade
        ,c.previous_rank_score
        ,cast(null as double) as new_rank_score
        ,c.rescore_reason
        ,array_union(c.changed_feature_list,array('eligibility')) as changed_feature_list
        ,c.previous_is_eligible
        ,c.new_is_eligible
        ,c.previous_feature_hash
        ,cast(null as string) as new_feature_hash
        ,c.pd
        ,c.user_type
        ,c.aes_phone
        ,c.market_register_dt
        ,c.user_create_dt
        ,c.lst_active_dt
        ,c.birthday
        ,c.age_years
        ,c.call_detail_hash
        ,c.previous_touch_dt_array_4m as touch_dt_array_4m
        ,c.previous_connect_dt_array_4m as connect_dt_array_4m
        ,cast(null as double) as hist_touch_connected_day_cnt_4m
        ,cast(null as double) as hist_touch_day_cnt_4m
        ,c.ip_address_update_dt
        ,c.ip_province
        ,c.latest_device_manufacturer
        ,c.latest_device_model
        ,c.age_bucket
        ,c.jinjuan_tag
        ,cast(null as double) as days_since_last_active
        ,cast(null as double) as register_days
        ,cast(null as double) as ip_address_age_days
        ,cast(null as double) as p_connect
        ,cast(null as double) as p_d0_given_connect
        ,cast(null as double) as frequency_coef
        ,cast(null as int) as frequency_hard_exclude_flag
        ,cast(null as string) as raw_grade
        ,cast(null as string) as model_feature_json
        ,'2.1-bpo-new-stock-lr-lr-d0-sql-v1' as model_version
        ,'EXIT' as entry_type
        ,c.previous_first_entry_dt as first_entry_dt
        ,c.previous_last_feature_update_dt as last_feature_update_dt
        ,c.previous_last_score_dt as last_score_dt
    from rescore_candidate c
    where c.previous_is_eligible=1
        and c.new_is_eligible=0
)
,all_delta as (
    select * from valid_scored_delta
    union all
    select * from invalid_input_delta
    union all
    select * from exit_delta
)
insert overwrite table dw_conan_ads.ads_eng_telesales_new_stock_rescore_delta_di partition(dt='${date}',batch_no)
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
    ,pd
    ,user_type
    ,aes_phone
    ,market_register_dt
    ,user_create_dt
    ,lst_active_dt
    ,birthday
    ,age_years
    ,call_detail_hash
    ,touch_dt_array_4m
    ,connect_dt_array_4m
    ,hist_touch_connected_day_cnt_4m
    ,hist_touch_day_cnt_4m
    ,ip_address_update_dt
    ,ip_province
    ,latest_device_manufacturer
    ,latest_device_model
    ,age_bucket
    ,jinjuan_tag
    ,days_since_last_active
    ,register_days
    ,ip_address_age_days
    ,p_connect
    ,p_d0_given_connect
    ,frequency_coef
    ,frequency_hard_exclude_flag
    ,raw_grade
    ,model_feature_json
    ,model_version
    ,entry_type
    ,first_entry_dt
    ,last_feature_update_dt
    ,last_score_dt
    ,cast(pmod(crc32(trim(cast(user_id as string))),4) as string) as batch_no
from all_delta
;
