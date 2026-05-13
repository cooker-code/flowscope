set mapreduce.reduce.memory.mb=4096;
set mapreduce.map.memory.mb=2048;
set mapreduce.map.java.opts='-Xmx1848M';
set mapreduce.reduce.java.opts='-Xmx3896M';


with new_device as
( -- 设备活跃要在用户和设备绑定之前
  -- 小于1%的设备有2个min_tp
  -- 这里获得的是request日志中的设备
  select a.device_id
        ,a.fst_productid
        ,a.fst_active_tp
        ,time2dt(a.fst_active_tp) as min_device_active_dt
        ,a.fst_vendor
        ,b.user_id
        ,b.dev_user_tp
        ,if(b.dev_user_tp is not null, time2dt(b.dev_user_tp), null) as min_dev_user_rela_dt
  from
  (
    select *
    from
    (
      select device_id
            ,product_id as fst_productid-- 首次激活productid
            ,if(product_id in ('503','523') and fst_vendor is null, 'appleAppStore', fst_vendor) as fst_vendor -- 首次激活渠道
            ,fst_active_tp -- 首次激活时间戳
            ,row_number() over (partition by device_id order by fst_active_tp asc) as rk
      from dw_dwd.dwd_eng_device_active_da -- device_id,product_id为唯一主键
      where dt = '${date}'
      and device_id is not null
      and device_id<>''
      and device_id <> '00000000-0000-0000-0000-000000000000'
    ) as a1
    where rk = 1
    and time2dt(fst_active_tp) between '2021-01-01' and '${date}' -- 2021年以来新增激活设备
  )a
  left join
  (
    select
      t0.*
    from
    (
     --对应userid
      select device_id
            ,user_id
            ,min(fst_rela_tp) as dev_user_tp -- 首次关联时间戳:从request里面捞出来的tp
            ,from_unixtime(cast(min(fst_rela_tp)/1000 as int), 'yyyy-MM-dd') as dev_user_dt
      from  dw_dwd.dwd_eng_user_device_rela_da -- device_id, user_id, product_id为唯一主键
      where dt = '${date}'
      and user_id rlike '[0-9]+'
      and device_id is not null
      and device_id<>''
      and device_id <> '00000000-0000-0000-0000-000000000000'
      group by device_id, user_id
    ) t0
    join
    (
      select device_id
            ,from_unixtime(cast(min(fst_active_tp)/1000 as int), 'yyyy-MM-dd') as fst_active_dt
      from dw_dwd.dwd_eng_device_active_da -- device_id,product_id为唯一主键
      where dt = '${date}'
      and device_id is not null
      and device_id<>''
      and device_id <> '00000000-0000-0000-0000-000000000000'
      group by device_id
    ) t1
    on t0.device_id=t1.device_id
    -- where t0.dev_user_dt between t1.fst_active_dt and date_add(t1.fst_active_dt,2)
  )b
  on a.device_id = b.device_id
  group by a.device_id
          ,a.fst_productid
          ,a.fst_active_tp
          ,time2dt(a.fst_active_tp)
          ,a.fst_vendor
          ,b.user_id
          ,b.dev_user_tp
          ,if(b.dev_user_tp is not null, time2dt(b.dev_user_tp), null)
)


insert overwrite table dw_conan_dwd.dwd_conan_user_order_da partition(dt='${date}')
select
     device_id
    ,fst_productid
    ,fst_active_tp
    ,min_device_active_dt
    ,fst_vendor
    ,user_id
    ,dev_user_tp
    ,min_dev_user_rela_dt
    ,b.min_paidtime
    ,if(c.reg_tp!='' and c.reg_tp is not null, c.reg_tp, 'unset') as reg_tp
    ,case when ((a.fst_active_tp < b.min_paidtime) or (b.min_paidtime is null)) then '激活时未购课账号'
          when a.fst_active_tp >= b.min_paidtime then '激活时已购课账号'
          else 'others' end as user_identifier
from new_device as a
left join
( -- 最早的0元课+1元课+体验课+系统课订单信息，包含退款
    select
         user_id as userid
        ,min(pay_tp) as min_paidtime
    from
    (
        select
             a1.user_id
            ,case when a2.orderid is not null then a2.pay_tp else a1.pay_tp end as pay_tp
        from
        (
            select
                 user_id
                ,order_id
                ,pay_tp
            from dw_dwd.dwd_eng_order_course_detail_da
            where dt = '${date}'
            and order_status >= '2'
            and (semester_type in ('try', 'try_paid', 'try_refer', 'try_refer_triple', 'try_double','fourweek', 'season')
            or semester_type like 'try_refer%')
        ) a1

        left join
        (
            select
                 cast(conan_order_id as string) as orderid
                ,cast(paidtime as bigint) as pay_tp
            from dw_conan_dwd.dwd_conan_growth_thirdapi_third_vendor_order_detail_da
            where dt = '${date}'
            and redeem_code != ''
            and conan_order_id != '0'
            and product_type = '0'
        ) a2
        on a1.order_id = a2.orderid
    ) a
    group by user_id
) b
on a.user_id = b.userid
left join
(
    select userid
          ,reg_tp
    from dw_dwd.dwd_site_user_reg_profile_da
    where dt = '${date}'
    and userid<>''
    and userid is not null
    and reg_tp is not null
    and reg_tp != ''
    group by userid, reg_tp
) c
on a.user_id = c.userid

