set mapreduce.map.memory.mb=8192;
set mapreduce.map.java.opts='-Xmx7168M';
set mapreduce.reduce.memory.mb=8192;
set mapreduce.reduce.java.opts='-Xmx7168M';

insert overwrite table dw_conan_dwd.dwd_conan_referral_frog_di partition (dt='${date}')
select
     cast(log_dt           as string) as log_dt                      
    ,cast(log_time         as string) as log_time                      
    ,cast(page_code        as string) as page_code                      
    ,cast(action_name      as string) as action_name                      
    ,cast(action_tp        as string) as action_tp                      
    ,cast(action_stp       as string) as action_stp                      
    ,cast(product_id       as string) as product_id                      
    ,cast(url              as string) as url                      
    ,cast(device_id        as string) as device_id                      
    ,cast(vendor           as string) as vendor                      
    ,cast(user_id          as string) as user_id                      
    ,cast(keyfrom          as string) as keyfrom                      
    ,cast(subject_id       as string) as subject_id                      
    ,cast(lesson_id        as string) as lesson_id                      
    ,cast(device_type      as string) as device_type                      
    ,cast(model            as string) as model                      
    ,cast(manufacturer     as string) as manufacturer                      
    ,cast(country          as string) as country                      
    ,cast(province         as string) as province                      
    ,cast(city             as string) as city                      
    ,cast(area             as string) as area                     
    ,other
    ,cast(page_name        as string) as page_name                  
    ,cast(page_lv1_name    as string) as page_lv1_name                      
    ,cast(page_lv1_code    as string) as page_lv1_code                      
    ,cast(page_lv2_name    as string) as page_lv2_name                      
    ,cast(page_lv2_code    as string) as page_lv2_code                      
    ,cast(page_lv3_name    as string) as page_lv3_name                      
    ,cast(page_lv3_code    as string) as page_lv3_code                      
    ,cast(city_type        as string) as city_type                  
    ,cast(category         as string) as category                 
    ,cast(page_tp          as string) as page_tp    
    ,case when other['sourcename'] rlike 'posterpunch|referGift1' then '周周分享'
          when other['sourcename'] rlike 'dailyreport' then '课程日报'
          when other['sourcename'] rlike 'GiftCard' then '亲友卡'
          when other['sourcename'] rlike 'TeacherTMK' then 'TMK'
          when other['sourcename'] rlike 'BigActivity|referGift5' then '大型活动'
          when other['sourcename'] rlike 'main_button|referGift|referGift2' then '推荐有礼'
          else '其他' end as activity_name
    ,case when url in ('/event/ReferralAct/enter','/event/InvitingFriend/enter') then 'show'
          else 'share' end as action_type
    ,'' as lesson_type
from dw_dwd.dwd_eng_frog_di 
where dt = '${date}'
and url in (
               '/event/ReferralAct/enter' -- 周周分享活动页面
               ,'/event/InvitingFriend/enter' -- 推荐有礼活动页面
               ,'/event/InvitingFriend/PosterShare/sharesuccessed' -- 分享成功
               ,'/event/InvitingFriend/PosterShare/save' -- TMK-长按保存图片
           )
and category in ('event')
and page_tp in ('I','R')
and other['sourcename'] not rlike 'SendTryVIP|InviteCashBack'

union all
-- 扫码
select
     cast(log_dt           as string) as log_dt                      
    ,cast(log_time         as string) as log_time                      
    ,cast(page_code        as string) as page_code                      
    ,cast(action_name      as string) as action_name                      
    ,cast(action_tp        as string) as action_tp                      
    ,cast(action_stp       as string) as action_stp                      
    ,cast(product_id       as string) as product_id                      
    ,cast(url              as string) as url                      
    ,cast(device_id        as string) as device_id                      
    ,cast(vendor           as string) as vendor                      
    ,cast(user_id          as string) as user_id                      
    ,cast(keyfrom          as string) as keyfrom                      
    ,cast(subject_id       as string) as subject_id                      
    ,cast(lesson_id        as string) as lesson_id                      
    ,cast(device_type      as string) as device_type                      
    ,cast(model            as string) as model                      
    ,cast(manufacturer     as string) as manufacturer                      
    ,cast(country          as string) as country                      
    ,cast(province         as string) as province                      
    ,cast(city             as string) as city                      
    ,cast(area             as string) as area                     
    ,other
    ,cast(page_name        as string) as page_name                  
    ,cast(page_lv1_name    as string) as page_lv1_name                      
    ,cast(page_lv1_code    as string) as page_lv1_code                      
    ,cast(page_lv2_name    as string) as page_lv2_name                      
    ,cast(page_lv2_code    as string) as page_lv2_code                      
    ,cast(page_lv3_name    as string) as page_lv3_name                      
    ,cast(page_lv3_code    as string) as page_lv3_code                      
    ,cast(city_type        as string) as city_type                  
    ,cast(category         as string) as category                 
    ,cast(page_tp          as string) as page_tp                
    ,case when split(keyfrom,'-')[2] rlike 'posterpunch|referGift1' then '周周分享'
          when split(keyfrom,'-')[2] rlike 'BigActivity|referGift5' then '大型活动'
          when split(keyfrom,'-')[2] rlike 'main|referGift|referGift2' then '推荐有礼'
          when split(keyfrom,'-')[2] rlike 'dailyreport' then '课程日报'
          when split(keyfrom,'-')[2] rlike 'GiftCard' then '亲友卡'
          when split(keyfrom,'-')[2] rlike 'TeacherTMK' then 'TMK'
          when split(keyfrom,'-')[2] rlike 'abilityaward' then '能力奖状'
          when split(keyfrom,'-')[2] rlike 'graduationcertificate' then '毕业证书'
          else '其他' end as activity_name
    ,'scan' as action_type
    ,case when lesson_id rlike '202|280|264|10082|10084|10086|570' then '素质学科'
          when lesson_id rlike '236|240|294|246|250|304' then '基础单周课'
          when lesson_id rlike '126|122|70' then '基础双周课'
          when lesson_id rlike '20|118|46|200|282|266|560' then '系统课'
          else '其它' end as lesson_type
from dw_dwd.dwd_eng_frog_di 
where dt = '${date}'
and url in (
               '/event/ClassIntroWechat/enter' -- 访问售卖页面
           )
and category in ('event')
and page_tp in ('C')
and split(keyfrom,'-')[0] in ('referral','mgm','mgm2','TMK','GiftGrowth')
and keyfrom not rlike 'fenxg|fenxiaoguan'
and lesson_id rlike '202|280|264|10082|10084|10086|236|240|294|126|122|70|20|118|46|200|282|266|560|246|250|304'

