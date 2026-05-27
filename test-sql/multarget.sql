insert overwrite table dw_dwd.dwd_eng_device_cpd_da partition(dt='${date}')
select
    if(t.cpd_channel in ('huawei','oppo') and t.oaid is not null,t.oaid,d.oaid) as oaid
    ,d.device_id
    ,d.fst_user_id
    ,d.user_id
    ,if(t.download_tp is null,null,default.time2dt(t.download_tp)) as download_dt
    ,t.download_tp
    ,d.fst_active_tp
    ,d.lst_active_tp
    ,t.cpd_channel
    ,t.adid
    ,case when d.oaid is null then '未激活'
          when t.oaid is null then '未投放'
          else d.convert_type
    end as convert_type
    ,d.users_info
from (
    select
        u.cpd_channel
        ,u.download_tp
        ,u.oaid
        ,u.adid
        ,u.oaid_md5
    from
    (
        select
            t.*
            ,row_number() over(partition by oaid order by t.download_tp) rn
        from
        (
            select
                'huawei' as cpd_channel
                ,ts as download_tp
                ,aid as adid
                ,oaid
                ,lower(md5(oaid)) as oaid_md5
            from dw_ods.ods_loghub_conan_conan_promotion_huawei_ads_callback_di t
            where dt = '${date}'
            and length(oaid)>0
            and actiontype='DOWNLOAD'

            union all

            select
                'oppo' as cpd_channel
                ,ts as download_tp
                ,cast (adid as string) as adid
                ,oaid
                ,lower(md5(oaid)) as oaid_md5
            from dw_ods.ods_loghub_conan_conan_promotion_oppo_ads_callback_di t
            where dt = '${date}'
            and length(oaid)>0

            union all

            select
                'vivo' as cpd_channel
                ,ts as download_tp
                ,cast(adid as string) as adid
                ,oaid
                ,lower(oaid) as oaid_md5
            from dw_ods.ods_loghub_conan_conan_promotion_vivo_callback_schema_di t
            where dt = '${date}'
            and length(oaid)>0

            union all

            select
                cpd_channel
                ,download_tp
                ,adid
                ,oaid
                ,lower(if(cpd_channel<>'vivo',md5(oaid),oaid)) as oaid_md5
            from dw_dwd.dwd_eng_device_cpd_da t
            where t.dt = date_add('${date}',-1)
            and download_tp > 0
            and download_dt < '${date}'
        ) t
    )u
    where u.rn = 1
) t
full outer join
(
    select
        oaid
        ,lower(md5(oaid)) as oaid_md5
        ,fst_active_tp
        ,lst_active_tp
        ,split(device_id,'#')[1] device_id
        ,split(user_id,'#')[1] user_id
        ,split(fst_user_id,'#')[1] fst_user_id
        ,case when array_contains(u.is_login,'1') and array_contains(u.is_pre_paid,'1') and not array_contains(u.is_fx,'1') then '激活前购课'
              when array_contains(u.is_login,'1') and array_contains(u.is_paid,'1') and not array_contains(u.is_fx,'1') then '激活后购课'
              when array_contains(u.is_login,'1') and not array_contains(u.is_paid,'1') then '激活未购课'
              else '激活未登录'
        end as convert_type
        ,concat('[',concat_ws(',',users),']') users_info
    from
    (
        select
            t.oaid
            ,min(t.fst_active_tp) as fst_active_tp
            ,max(t.lst_active_tp) as lst_active_tp
            ,max(concat(t.lst_active_tp,'#',device_id)) as device_id
            ,max(concat(t.lst_active_tp,'#',t.user_id)) as user_id
            ,min(concat(t.fst_active_tp,'#',t.user_id)) as fst_user_id
            ,collect_set(ext.is_login_user) as is_login
            ,collect_set(ext.is_paid_user) as is_paid
            ,collect_set(if(fst_pay_tp < t.fst_active_tp,ext.is_paid_user,null)) as is_pre_paid
            ,collect_set(ext.is_fx_user) as is_fx
            ,collect_set(toJson('user_id',t.user_id,0,'fst_active_tp',t.fst_active_tp,0)) as users
        from dw_dwd.dwd_eng_user_device_profile_da t
        left join dw_dim.dim_eng_user_extend_da ext
          on t.user_id = ext.user_id
         and ext.dt = '${date}'
         and t.user_id is not null
        where t.dt = '${date}'
        and length(t.oaid)>0
        group by t.oaid
    ) u

) d
on t.oaid_md5 = d.oaid_md5
;

