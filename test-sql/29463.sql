-- 周一日期	城市	学科	主管	组长	老师	进度（U）	在班人数	亲友卡领取uv	亲友卡持有uv	亲友卡页面访问uv	分享成功UV	亲友卡带leads量	带leads率	辅导专属链接亲友卡页面访问	专属链接亲友卡成功分享uv	专属链接亲友卡带leads量
select 
	date_sub(next_day('{{{dt}}}','MO'),7) as week_dt,
    nvl(teacher_city,'总计') as teacher_city,
    nvl(district_leader_ldap,'总计') as district_leader_ldap,
    nvl(team_leader_ldap,'总计') as team_leader_ldap,
    nvl(teacher_ldap,'总计') as teacher_ldap,
    nvl(subject_name,'总计') as subject_name,
    nvl(unit,'总计') as unit,
    count(distinct course_da.user_id) as user_num,
    count(distinct if(create_week = week_dt,redeem.user_id,null)) as new_redeem_num,
    count(distinct if(week_dt between create_week and expire_week,redeem.user_id,null)) as have_redeem_num,
    count(distinct activity_show) as activity_show_num,
    count(distinct share_success) as share_success_num,
    count(distinct leads.order_id) as leads_num,
    round(count(distinct leads.order_id)/count(distinct course_da.user_id),4) as leads_rate,
    count(distinct if(teacher_ldap = frog_ldap,activity_show,null)) as teacher_activity_show_num,
    count(distinct if(teacher_ldap = frog_ldap,share_success,null)) as teacher_share_success_num,
    count(distinct if(teacher_ldap = leads_ldap,leads.order_id,null)) as teacher_leads_num
from 
(
  select 
  	week_dt,
  	user_id,
  	order_id,
  	teacher_ldap,
  	teacher_city,
  	team_leader_ldap,
  	district_leader_ldap,
  	subject_name,
  	stage_name,
  	int((stage_week_idx-1)/4)+1 as unit
  	-- if(is_first_purchase_user = '0','否','是') as is_first_purchase_user
  from dw_conan_ads.ads_course_season_user_class_week_all_info_da 
  where dt = date_sub(current_date,1)
  and week_dt = date_sub(next_day('{{{week_dt}}}','MO'),7)
  and subject_id in ('1','2','3')
)course_da
left join 
(
  select 
  	user_id,
  	date_sub(next_day(create_dt,'MO'), 7) as create_week,
  	create_dt,
  	date_sub(next_day(expire_dt,'MO'), 7) as expire_week,
  	expire_dt
  from dw_conan_dwd.dwd_growth_redeem_code_detail_da
  where dt = date_sub(current_date,1)
)redeem 
on course_da.user_id = redeem.user_id
and date_sub(next_day('{{{dt}}}','MO'),7) between create_week and expire_week -- 当周持有
left join 
(
  -- 活动推荐人侧的分享相关信息
  select
      user_id
  	  ,other['channeltype'] as channeltype
  	  ,other['ldap'] as frog_ldap
  	  ,date_sub(next_day(dt,'MO'), 7) as week
      ,max(if(url = '/event/InvitingFriend/enter',user_id,null)) as activity_show -- 活动曝光uv
      ,max(if(url in ('/click/InvitingFriend/share','/click/TryRenewalGift/giftCard'),user_id,null)) as share_click -- 点击分享uv
  	  ,max(if(url in ('/event/InvitingFriend/PosterShare/sharesuccessed'
                      ,'/click/ProgramGiftCard/sendWechatFriend' 
                      ,'/click/ProgramGiftCard/saveButton'
                      ,'/click/TryRenewalGift/giftCardShare'),user_id,null)) as share_success -- 分享成功
  from dw_dwd.dwd_eng_frog_di
  where dt >= '2026-01-23'
  and url in (
      '/event/InvitingFriend/enter' -- 活动页面曝光
      ,'/click/InvitingFriend/share'
      ,'/click/GiftCardPage/sendButton' -- 点击立即赠送
      ,'/click/TryRenewalGift/giftCard' -- 入学礼包点击领取亲友卡
      ,'/event/InvitingFriend/PosterShare/sharesuccessed' -- 分享成功
      ,'/click/ProgramGiftCard/sendWechatFriend' -- 赠送微信好友：小程序端的分享成功
      ,'/click/ProgramGiftCard/saveButton' -- 保存图片：小程序端的分享成功
      ,'/click/TryRenewalGift/giftCardShare' -- 入学礼包：点击分享好友/朋友圈
      )
  and page_code in ('InvitingFriend','GiftCardPage','ProgramGiftCard','TryRenewalGift')
  and (other['sourcename'] in ('GiftCard') or page_code = 'TryRenewalGift')
  and category in ('event','click')
  and page_tp in ('I','P','G','T')
  group by user_id,other['channeltype'],date_sub(next_day(dt,'MO'), 7),other['ldap']
)share_frog 
on redeem.user_id = share_frog.user_id
and date_sub(next_day('{{{dt}}}','MO'),7) = share_frog.week
left join 
(
  -- 实际领课的用户数据
  select
      user_id
  	  ,order_id
  	  ,keyfrom
  	  ,subject_id
  	  ,date_sub(next_day(pay_dt,'MO'), 7) as pay_week
      ,split(keyfrom,'-')[1] as refer_userid
  	  ,split(keyfrom,'-')[5] as leads_ldap
  from dw_conan_ads.ads_service_try_double_user_quality_detail_da
  where dt = date_sub(current_date,1)
      and split(keyfrom,'-')[0] in ('teacher','referral')
      and keyfrom rlike 'GiftCard'
	  and pay_dt >= '2026-01-23'
  group by user_id,order_id,subject_id,split(keyfrom,'-')[1],keyfrom,date_sub(next_day(pay_dt,'MO'), 7),split(keyfrom,'-')[5]
)leads
on redeem.user_id = leads.refer_userid
and date_sub(next_day('{{{dt}}}','MO'),7) = leads.pay_week
where teacher_city is not null 
and district_leader_ldap is not null
and team_leader_ldap is not null
group by grouping sets ((date_sub(next_day('{{{dt}}}','MO'),7),teacher_city,district_leader_ldap,team_leader_ldap,teacher_ldap,subject_name,unit),
                        (date_sub(next_day('{{{dt}}}','MO'),7),teacher_city),
                        (date_sub(next_day('{{{dt}}}','MO'),7))
                       )