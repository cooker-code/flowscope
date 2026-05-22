select start_class_dt,case when business_type='8' then '投放二组'
    when business_type='9' then '投放三组'
    else '效果推广' end as tag 
,pageid
,account_name
,agent_name
,stage_name
,user_city_type
,layer_label
,count(distinct user_quality.parent_orderid) as `退款后父订单数`
,count(distinct user_quality.userid) as `退款后用户数`
,count(distinct if(user_quality.subject=1,user_quality.orderid,null)) as `退款后英语订单数`
,count(distinct if(user_quality.subject=2,user_quality.orderid,null)) as `退款后思维订单数`

,count(distinct if(is_add_cur_teacher_wechat = 1, user_quality.userid, null)) as `添加微信人数`
,count(distinct if(is_active = 1, user_quality.userid, null)) as `激活人数`

,count(distinct if(is_attend_first_day = 1, user_quality.userid, null)) as `D1到课人数`
,count(distinct if(is_attend= 1 and subject='1', user_quality.userid, null)) as `英语参课人数`
,count(distinct if(is_attend= 1 and subject='2', user_quality.userid, null)) as `思维参课人数`
,count(distinct if(is_attend_both = 1, user_quality.userid, null)) as `两科目都参课人数`
,count(distinct if(is_attend= 1, user_quality.userid, null)) as `任意科目参课人数`

,count(distinct if(is_finish= 1 and subject='1', user_quality.userid, null)) as `英语完课人数`
,count(distinct if(is_finish= 1 and subject='2', user_quality.userid, null)) as `思维完课人数`
,count(distinct if(is_finish_both = 1, user_quality.userid, null)) as `两科目完课人数`
,count(distinct if(is_finish= 1, user_quality.userid, null)) as `任意科目完课人数`

,count(distinct if(is_finish_both = 1 and is_season=1, user_quality.userid, null)) as `两科目完课且续报人数`
,count(distinct if(is_finish_both = 1 and is_season=1, user_quality.orderid, null)) as `两科目完课且续报订单数`

,count(distinct if(is_season = 1, user_quality.userid, null)) as `续报人数`
,count(distinct if(is_season = 1, user_quality.orderid, null)) as `续报系统课订单数`

    ,count(distinct if(is_season=1,orderid,null)) as `系统课订单数`
    from
    (
        select
         order_id as orderid
            ,user_Id as userid
            ,parent_order_id as parent_orderid
            ,user_city_type
            ,start_class_dt
            ,subject_id as subject
            ,stage_name
            ,is_current_active as is_active -- 是否激活
            ,is_add_wechat as is_add_cur_teacher_wechat -- 截止当前是否加过老师微信
            ,is_attend_current as is_attend -- 截止当前该学科是否参课
            ,is_finish_current as is_finish -- 截止当前该学科是否结课
            ,is_attend_first_day as is_attend_first_day
            ,is_renewal as is_season
            ,substring_index(keyfrom, '-', 4) as keyfrom_cov
            ,split(keyfrom,'-')[5] as pageid
            ,replace(replace(split(keyfrom, '-')[4], '{', ''), '}', '') as adid
            ,pay_dt as paid_dt
            ,min(is_attend_current) over(partition by parent_order_id) as is_attend_both -- 父订单下的所有学科是否都参课
            ,min(is_finish_current) over(partition by parent_order_id) as is_finish_both -- 父订单下的所有学科是否都结课
            ,min(is_attend_first_day) over(partition by parent_order_id) as is_attend_first_day_both -- 父订单下的所有学科是否都在第一天参课
            ,count(1) over(partition by parent_order_id) as cnt_per_user
      ,parent_semester_id as parent_semesterid
        from dw_conan_ads.ads_service_try_double_user_quality_detail_da
        where dt =date_sub(current_date,1)
            and subject_id in ('1','2')
            and split(keyfrom,'-')[0] in ('tg')
            and keyfrom rlike 'tg-waibu-tencent3'
            and {{start_class_dt}}
      and {{split(keyfrom,'-')[5] as pageid}}
    ) user_quality 

left join 
(
    select adid,accountid
    from dw_ods.ods_conan_commerce_marketing_ad_base_info_da
    where dt = date_sub(current_date, 1)
    group by adid,  accountid
) ad on user_quality .adid=ad.adid

left join 
(
    select accountid,business_type,account_name,agent_name
    from 
(select  account_id as accountid,account_name,agent_name, business_type,row_number()over (partition by account_id order by db_utime desc) as rk 
from dw_conan_ods.ods_conan_promotion_data_aggregate_account_agent_snapshot_da
where dt = date_sub(current_date, 1)
)a
where rk=1
)act on ad.accountid=act.accountid 

left join
(
  select
  	userid,dt,layer_label
  from dw_dwd.dwd_service_try_type_week_prediction_result_di
  where dt>='2025-01-01'
  	and layer_label!='已转化' --旧模式中，已转化用户不分配label
    and layer_label is not null
    and subject='1'
) layer on user_quality.userid=layer.userid and layer.dt=date_add(user_quality.start_class_dt,3)
group by start_class_dt,pageid,case when business_type='8' then '投放二组'
    when business_type='9' then '投放三组'
    else '效果推广' end,account_name
,agent_name
,stage_name
,user_city_type
,layer_label