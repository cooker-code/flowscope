-- 业务 CAC 改为读取同日订单级结果；财务 CAC、税率和净收益计算保留原口径。
-- 订单唯一性按上游粒度独立核验；清理4处重复去重和4处去重计数，保留业务聚合与匹配优先级。
-- 2026年起增长运营拆分为用增体验课费用池，系统课份额由系统课成本任务承接。
-- 第二批等价重构：财务适用区间、物料来源月单均区间、运营与CPD日均配置统一。
-- 第一批等价重构：共享月份和落表集合、复用分母、周CAC窗口分摊、服务金额统一计算。
-- 旧成本依赖移除：财务单均仅由月度总额计算；保留历史结算边界、精度和拆单规则。
with

-- 统一获客配置：TOTAL=汇总范围；NA=维度不适用；上传前必须通过配置校验。
acquisition_cost_config as
(
    select cost_type,to_date(start_dt) as start_dt,to_date(end_dt) as end_dt,
           class_mode,user_from,ad_channel,cost_project,cast(cost_amount as double) as cost_amount
    from dw_conan_temp.temp_conan_try_cac_cost
),
cpd_cost_config as
(
    select start_dt as active_start_dt,end_dt as active_end_dt,cost_amount as total_cpd_cost
    from acquisition_cost_config
    where cost_type='CPD_WEEK'
),

-- 单周/四周/素质课本地推导 stage_name_comb（上游未透传），口径与双周 user_quality 对齐
parent_stage_comb as
(
	select  parent_semester_id
	       ,case when size(subject_set) = 2 and distinct_stage_cnt = 1 then concat('S', one_stage) -- 两科同级去重
	             else                                                       concat('S', s1, s2, s3)
	        end as stage_name_comb
	from
	(
		select  parent_semester_id
		       ,collect_set(subject_name)                                                                  as subject_set
		       ,coalesce(max(if(subject_id = 1, replace(start_stage_name, 'S', ''), null)), '')            as s1
		       ,coalesce(max(if(subject_id = 2, replace(start_stage_name, 'S', ''), null)), '')            as s2
		       ,coalesce(max(if(subject_id = 3, replace(start_stage_name, 'S', ''), null)), '')            as s3
		       ,size(collect_set(replace(start_stage_name, 'S', '')))                                      as distinct_stage_cnt
		       ,coalesce(max(replace(start_stage_name, 'S', '')), '')                                      as one_stage
		from dw_conan_dim.dim_eng_semester_da
		where dt = '${date}'
			and subject_name in ('英语','思维','语文')
		group by parent_semester_id
	) t
),

-- 整体用户信息
user_base as
(	
	-- 双周课
	select
	    case
	        when subject_comb = '英思' and service_mode = '快转' then '英思联带快转'
	        when subject_comb = '英思' then '英思联带服务'
	        when subject_comb = '思阅' then '思阅联带'
	        when service_mode = '中价' then concat(subject_comb, '中价')
			when subject_comb = '英语'
				and service_mode = '深度'
				and coalesce(a.experiment_tag, '') like '%实验A组%'
				and a.start_class_dt >= '2026-09-14'
			then '英语单带三周实验A组'
			when service_mode = '深度' then concat(subject_comb, '单带三周')
			when subject_comb = '英语' then case
				when service_mode = '标准' then '英语单带双周'
				else '英语单带' end
	        when subject_comb in ('思维','阅读') then concat(subject_comb, '单带')
	    end as teacher_mode_key -- 人效保留线上历史分组桶；财务和旧CAC映射暂沿用此键，避免引入口径变化
	    ,subject_comb as class_mode
	    ,case
	        when subject_comb='英语'
  				 and service_mode='深度'
	             and coalesce(a.experiment_tag,'') like '%实验A组%'
	             and a.start_class_dt>='2026-09-14' then '英语深度实验A组'
	        else concat(subject_comb,service_mode)
	     end as class_mode_detail
	    ,start_class_dt
	    ,end_class_dt
	    ,if(end_class_dt<='${date}',1,0) as is_end
	    ,user_id as userid
	    ,a.order_id as orderid
	    ,cast(a.subject_id as string) as child_subject_id
	    ,cast(a.parent_order_id as string) as parent_orderid
	    ,case when a.user_from in ('商务合作','商务二组') then 1 else 0 end as is_business_fin -- 原渠道识别，先于WPS/电商展示兜底
	    ,a.pay_dt as pay_dt
	    ,teacher_ldap as ldap
	    ,pay_amt as try_paidfee

	    -- 渠道特殊兜底（一级 / 二级）
	    ,case
	    	when is_douyinhezi=1 then '电商探索'
	    	when keyfrom like 'yxzz-sw-sq-CPA-wps%' then '商务合作无成本'
	    	else user_from
	    end as user_from
	    ,case
	    	when is_douyinhezi=1 then '抖音盒子'
	    	when keyfrom like 'tg-waibu-dy-ztss%' then '抖音速算'
	    	when keyfrom rlike 'GiftCardActivity' then '亲友卡大型活动'
	    	else ad_channel
	    end as ad_channel

	    ,if(is_renewal='1' and renewal_order_pay_dt<=end_class_dt,1,0) as is_renewal_w2
	    ,if(is_renewal='1',renewal_order_id,null) as renewal_orderid

	    ,greatest(coalesce(size(split(split(buy_way_tg,'-')[1],'\\+')),1),1) as buy_bundled_num -- 售卖组合按+分隔的学科数；空值或不足1统一按1
		,if(is_bundled='联带',2,1) as teacher_bundled_num -- 老师成本分摊子订单数；指定虚拟订单固定成本在最外层单独覆盖
	    ,if(noPost='true',0,1) as is_having_trybook
		,if(is_bundled='联带',2,1) as book_bundled_num
	    ,if(buy_way_tg='非联报','单科售卖','多科售卖') as buy_way
	    ,stage_name

	    -- 模式字段：双周课透传上游
	    ,subject_comb
	    ,stage_name_comb
	    ,lesson_desc
	    ,service_mode
	    ,case
	    	when subject_comb='英语'
	    		and service_mode='虚拟'
	    		and a.district_leader_ldap='bairuxue'
	    	then cast(30 as double)
	    	else cast(null as double)
	    end as fixed_teacher_cost -- 双周英语虚拟且分部主管为 bairuxue：每笔子订单固定服务成本 30
	from
	(
		select *
		from dw_conan_ads.ads_service_try_double_user_quality_detail_da
		where dt='${date}'
	) a
	left join 
    (	-- 从供应链表判断双周课订单是否发随材
    	select orderid,get_json_object(property,'$.noPost') as noPost
		from dw_conan_ods.ods_conan_trade_t_order_da
		where dt='${date}'
	)d on a.order_id=d.orderid
	left join
	(	-- 兜底电商用商务店铺的情况
		select order_id,if(keyfrom like 'yxzz-sw-sq-cpa-dyfx%' and goods_id in ('3685898894488764490','3685900470792093727') and pay_dt<='2024-06-03',1,0) as is_douyinhezi
		from dw_conan_dwd.dwd_eng_order_course_detail_da
		where dt='${date}' and semester_type='try_double' and subject_id in (1,2)
	) b on a.order_id=b.order_id

    -- 单周课
	union all
	select
		if(c.is_virtual_class='1','单周虚拟','单周真实') as teacher_mode_key
		,'单周' as class_mode
		,if(c.is_virtual_class='1','单周虚拟','单周') as class_mode_detail
		,c.start_class_dt
		,c.end_class_dt
		,if(c.end_class_dt<='${date}',1,0) as is_end
		,c.user_id as userid
		,c.order_id as orderid
	    ,cast(c.subject_id as string) as child_subject_id
		,cast(c.parent_order_id as string) as parent_orderid
		,0 as is_business_fin
		,c.pay_dt as pay_dt
		,c.teacher_ldap as ldap
		,c.pay_amt as try_paidfee
		,c.order_from as user_from
		,c.ad_channel
		,if(c.is_buy_long=1,1,0) as is_renewal_w2
		,c.buy_long_order_id as renewal_orderid
		,3 as buy_bundled_num
		,3 as teacher_bundled_num
		,0 as is_having_trybook
		,3 as book_bundled_num
		,'多科售卖' as buy_way
		,c.stage_name

		-- 模式字段：单周课本地推导（英思阅三科联报试听课）
		,'英思阅' as subject_comb
		,p.stage_name_comb
		,'联带' as lesson_desc
		,if(c.is_virtual_class='1','虚拟','标准') as service_mode
		,cast(null as double) as fixed_teacher_cost
	from dw_conan_dws.dws_conan_user_try_refer_user_quality_detail_da c
	left join parent_stage_comb p on c.parent_semester_id = p.parent_semester_id
	where c.dt='${date}' and c.class_type='联带'
		and c.start_class_dt<='2025-07-14'

	-- 四周课
	union all
	select
		'思维四周' as teacher_mode_key
		,'思维四周' as class_mode
		,'思维四周' as class_mode_detail
		,start_class_dt
		,end_class_dt
		,if(end_class_dt<='${date}',1,0) as is_end
		,user_id as userid
		,order_id as orderid
	    ,cast(subject_id as string) as child_subject_id
		,cast(parent_order_id as string) as parent_orderid
	    ,0 as is_business_fin
		,pay_dt as pay_dt
		,teacher_ldap as ldap
		,pay_amt as try_paidfee
		,user_from as user_from
		,ad_channel
		,if(is_renewal=1 and renewal_order_pay_dt<=end_class_dt,1,0) as is_renewal_w2
		,if(is_renewal=1, renewal_order_id, null) as renewal_orderid
		,1 as buy_bundled_num
		,1 as teacher_bundled_num
		,1 as is_having_trybook
		,1 as book_bundled_num
		,'单科售卖' as buy_way
		,stage_name

		-- 模式字段：四周课本地推导
		,'思维' as subject_comb
		,cast(null as string) as stage_name_comb
		,'单带' as lesson_desc
		,'标准' as service_mode
		,cast(null as double) as fixed_teacher_cost
	from dw_conan_ads.ads_service_fourweek_user_quality_detail_da
	where dt='${date}' and subject_id='2'

	-- 素质课
	union all
	select
	    subject_name as teacher_mode_key
	    ,subject_name as class_mode
	    ,subject_name as class_mode_detail
	    ,start_class_monday as start_class_dt
	    ,jx_end_dt as end_class_dt
	    ,if(jx_end_dt<='${date}',1,0) as is_end
	    ,user_id as userid
	    ,order_id as orderid
	    ,cast(subject_id as string) as child_subject_id
	    ,cast(parent_order_id as string) as parent_orderid
	    ,0 as is_business_fin
	    ,pay_dt as pay_dt
	    ,teacher_ldap as ldap
	    ,pay_amt as try_paidfee
	    ,user_from
	    ,ad_channel
	    ,if(is_renewal=1,1,0) as is_renewal_w2
	    ,renewal_order_id as renewal_orderid
	    ,1 as buy_bundled_num
	    ,1 as teacher_bundled_num
	    ,case when is_decoupling='1' then 0 else 1 end as is_having_trybook -- 素质课承接上游：解耦模式无随材，科学保留有材
	    ,1 as book_bundled_num
	    ,'单科售卖' as buy_way
	    ,stage_name

	    -- 模式字段：素质课本地推导（subject_comb 主枚举无对应值，统一归 '其他'，细分仍通过 class_mode 区分）
	    ,'其他' as subject_comb
	    ,cast(null as string) as stage_name_comb
	    ,'单带' as lesson_desc
	    ,'标准' as service_mode
	    ,cast(null as double) as fixed_teacher_cost
	from dw_conan_ads.ads_service_art_try_user_quality_detail_da
	where dt='${date}'
),

-- 单双体验课重叠的转化订单id
overlap_order as 
(
	select distinct 
		a.renewal_orderid as overlap_orderid
	from
	(	-- 单周
		select buy_long_order_id as renewal_orderid
		from dw_conan_dws.dws_conan_user_try_refer_user_quality_detail_da
		where dt='${date}' and buy_long_order_id is not null
			and start_class_dt<='2025-07-14'
	) a

	join
	(	-- 双周
		select renewal_order_id as renewal_orderid
		from dw_conan_ads.ads_service_try_double_user_quality_detail_da
		where dt='${date}' and renewal_order_id is not null
	) b on a.renewal_orderid=b.renewal_orderid
),

-- 财务统一入口与日均：按费用类型保留过滤政策，再生成结算区间
finance_monthly_source as
(
    select stat_month,category,channel,cast(cost_amount as double) as cost_total
        ,case when category='运营' and channel in (
             '市场/电商/英语体验课','市场/电商/思维体验课','市场/电商/阅读体验课',
             '市场/电商/系统课','市场/投放','市场/商务一组/体验课',
             '市场/商务二组/体验课','市场/商务/系统课','用增/体验课') then 1 else 0 end as is_split_market_pool
    from dw_conan_temp.temp_conan_finance_monthly_data
    where cost_type='total'
),
finance_daily_config as
(
    select stat_month,category,channel,cost_total
    from finance_monthly_source
    where (category='推广' and channel='应用商店')
        or (category='运营' and channel is not null
            and (is_split_market_pool=0
                 or (stat_month>='2026-01' and cost_total is not null)))
),
finance_daily_data as
(
    select category,channel,stat_month,cost_total
        ,concat(stat_month,'-01') as start_stat_dt
        ,lead(concat(stat_month,'-01'),1,'9999-12-31')
            over(partition by category,channel order by stat_month) as next_stat_dt
        ,cost_total/day(last_day(to_date(concat(stat_month,'-01')))) as daily_cost
    from finance_daily_config
),

-- CPD仍分别使用激活周业务池与激活月财务池，不合并两者分母。
cpd_try_order as
(
	select
		order_id,parent_order_id,user_id,cast(pay_tp as bigint) as pay_tp
	from dw_conan_ads.ads_service_try_double_user_quality_detail_da
	where dt='${date}'
		and user_from in ('APP自助','流量池','TMK','直接购买')
		-- 分摊分母不限制开课日期，不限制是否结课或转化
),
cpd_active_order as
(
	-- 只需最早激活日期，直接min；不限制设备账号首次关联时间
	select
		a.parent_order_id
		,to_date(from_unixtime(cast(min(b.active_tp)/1000 as bigint))) as active_dt
	from cpd_try_order a
	join
	(
		select userid,cast(fst_active_tp as bigint) as active_tp
		from dw_conan_dwd.dwd_eng_device_active_user_label_da
		where dt='${date}' and download_type='投放下载'
			and deviceid is not null
			and deviceid not in ('','NULL','00000000-0000-0000-0000-000000000000')
			and cast(fst_active_tp as bigint)>0
	) b on a.user_id=b.userid
		and b.active_tp>=a.pay_tp-cast(2592000000 as bigint)
		and b.active_tp<a.pay_tp
	group by a.parent_order_id
),
cpd_parent_cost as
(
	-- 激活先归父单，再按费用池的父单数均摊
	select
		a.parent_order_id
		,total_cpd_cost / count(*) over(partition by active_start_dt,active_end_dt) as parent_cpd_cost
	from cpd_active_order a
	join cpd_cost_config b on a.active_dt between b.active_start_dt and b.active_end_dt
),
cpd_fin_parent_cost as
(
	-- 复用业务CPD选定的父单及最早激活；财务费用池按激活自然月计父单
	select
		a.parent_order_id
		,(case
			when substr(a.active_dt,1,7)=b.stat_month then b.cost_total
			else b.daily_cost * day(least(last_day(a.active_dt),to_date('${date}')))
		end) / count(*) over(partition by substr(a.active_dt,1,7)) as parent_cpd_fin_cost
	from cpd_active_order a
	left join finance_daily_data b on b.category='推广' and b.channel='应用商店'
		and concat(substr(a.active_dt,1,7),'-01')>=b.start_stat_dt
		and concat(substr(a.active_dt,1,7),'-01')<b.next_stat_dt
),
cpd_order as
(
	-- 业务与财务共用父内合格子单分母；左右费用池独立匹配，缺配置最终按0
	select
		a.order_id as cpd_try_orderid
		,b.parent_cpd_cost / count(*) over(partition by a.parent_order_id) as try_order_cpd_cost
		,c.parent_cpd_fin_cost / count(*) over(partition by a.parent_order_id) as try_order_cpd_fin_cost
	from cpd_try_order a
	left join cpd_parent_cost b on a.parent_order_id=b.parent_order_id
	left join cpd_fin_parent_cost c on a.parent_order_id=c.parent_order_id
),

-- 电商支付日：同一内部子订单取最早有效支付日期，保证关联后不放大订单、每单唯一归周
commerce_order_pay_date as
(
	select
		order_id
		,cast(min(to_date(pay_dt)) as string) as commerce_pay_dt
	from dw_conan_ads.ads_commerce_try_order_detail_wide_da_v1
	where dt='${date}'
		and order_id != 0
		and to_date(pay_dt) > '1970-01-01'
	group by order_id
),

-- 统一支付日：仅电商探索优先用电商支付日，未匹配有效日期时保留原 pay_dt
user_base_pay_date as
(
	select
		user_base.*
		,case
			when user_base.user_from='电商探索' then coalesce(commerce.commerce_pay_dt,user_base.pay_dt)
			else user_base.pay_dt
		end as effective_pay_dt
	from user_base
	left join commerce_order_pay_date commerce
		on user_base.user_from='电商探索' and user_base.orderid=commerce.order_id
),

-- 体验课订单基础集：供旧 Bundle CAC 与新周消耗 CAC 两条路径复用
try_base as
(
	select
		teacher_mode_key
		,class_mode
		,class_mode_detail

		-- 获客成本桶（仅旧 Bundle CAC 使用）
		,case
			when teacher_mode_key = '思维四周' then '思维四周'
			when user_from in ('外部推广','电商探索','商务合作') and teacher_mode_key rlike '英思|英语|思维' and buy_way='多科售卖' then '英思'
			when teacher_mode_key like '英思%' then '英思'
			when teacher_mode_key like '思阅%' then '思阅'
			when teacher_mode_key like '单周%' then '单周课'
			when teacher_mode_key like '英语%' then '英语'
			when teacher_mode_key like '思维%' then '思维'
			when teacher_mode_key like '阅读%' then '阅读'
			else teacher_mode_key
		end as sell_subject_comb


		,start_class_dt
		,end_class_dt
		,is_end
		,userid
		,orderid
		,parent_orderid
		,is_business_fin
		,effective_pay_dt as pay_dt
        ,substr(case when is_business_fin=1 then end_class_dt else effective_pay_dt end,1,7) as finance_acquisition_month
        ,substr(end_class_dt,1,7) as end_class_month
        ,if(service_mode='虚拟',1,0) as is_virtual
		,try_paidfee
		,user_from
		,ad_channel
		,is_renewal_w2
		,renewal_orderid
		,if(overlap_order.overlap_orderid is not null, 0.5, 1) as overlap_order_factor
		,buy_bundled_num
		,teacher_bundled_num
		,book_bundled_num
		,is_having_trybook
		,stage_name

		-- 已确认电商范围0102起周分摊；0703起原三渠道条件完全保留。
		-- 非中价仅英语四渠道、阅读仅抖音中价；其他0102-0702订单保持原成本。
		,case
			when user_from='电商探索'
				and to_date(effective_pay_dt)>='2026-01-02'
				and (
				    (class_mode='英语' and ad_channel in ('低价达人','天猫','天猫合作','其他电商探索'))
				    or (class_mode='阅读' and ad_channel='抖音中价')
				    or (class_mode in ('英语','思维','英思') and ad_channel in ('抖音中价','腾讯中价','其他中价','点读版'))
				) then 1
			when user_from in ('电商探索','外部推广','小红书运营')
				and to_date(effective_pay_dt)>='2026-07-03' then 1
			else 0
		end as is_weekly_child_cac

-- 模式字段透传
		,subject_comb
		,stage_name_comb
		,case when ad_channel rlike '中价|点读' then '中价' else '低价' end as channel_price
		,lesson_desc
		,service_mode
		,fixed_teacher_cost

		-- 财务结算口径映射：将订单渠道归并到财务配置口径，用于和财务数字匹配。
		,case
			when is_business_fin=1 then '商务合作-体验课' -- 两个商务一级渠道优先，覆盖WPS和历史电商兜底
			when teacher_mode_key = '思维四周' then '直播电商-思维中价课'
			-- 2026 年 Q1 将原效果投放拆成四类，分别匹配财务单均成本
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅'
				and to_date(effective_pay_dt) >= '2026-01-01' and to_date(effective_pay_dt) < '2026-04-01'
				and user_from='小红书运营' then '小红书运营'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅'
				and to_date(effective_pay_dt) >= '2026-01-01' and to_date(effective_pay_dt) < '2026-04-01'
				and user_from='外部推广' then '外部推广'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅'
				and to_date(effective_pay_dt) >= '2026-01-01' and to_date(effective_pay_dt) < '2026-04-01'
				and user_from='产品投放' then '产品投放'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅'
				and to_date(effective_pay_dt) >= '2026-01-01' and to_date(effective_pay_dt) < '2026-04-01'
				and user_from='供应链' and ad_channel='供应链投放' then '供应链投放'
			-- Q1 以外继续合并为效果投放；供应链必须同时满足一级、二级渠道
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅'
				and (user_from in ('外部推广','产品投放','小红书运营') or (user_from='供应链' and ad_channel='供应链投放'))
			then '效果投放'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and ad_channel='地推' then '地推'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and ad_channel='图书中价' then '图书中价'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and ad_channel rlike 'BPO' then '电销BPO'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and user_from='TMK' then '电销TMK'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and user_from='商务合作' then '商务合作-体验课'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅|单周' and user_from in ('转介绍','辅导服务') then 'C端分销'
			when teacher_mode_key rlike '英语' and user_from='电商探索' and ad_channel rlike '中价' then '直播电商-英语中价课'
			when teacher_mode_key rlike '思维' and user_from='电商探索' and ad_channel rlike '中价' then '直播电商-思维中价课'
			when teacher_mode_key rlike '阅读' and user_from='电商探索' and ad_channel rlike '中价' then '直播电商-阅读中价课'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and user_from='电商探索' and ad_channel='点读版' then '直播电商-英语点读'
			when teacher_mode_key rlike '英语|思维|阅读|英思|思阅' and user_from='电商探索' then '直播电商-体验课'
			else '其他'
		end as order_channel_fin
	from user_base_pay_date user_base
	left join overlap_order on user_base.renewal_orderid=overlap_order.overlap_orderid
),

-- 商务财务：每个结课月的母单独立承接一份单均，均分到该母单当月的子订单
business_fin_parent_month as
(
    select
        end_class_month as end_month
        ,parent_orderid
        ,count(orderid) as month_child_count
    from try_base
    where is_business_fin=1
        and parent_orderid is not null and parent_orderid!=''
    group by end_class_month,parent_orderid
),

-- ============================================================================
-- 统一成本匹配：绩效月 + class_mode_detail；周CAC分母和最终落表共用
-- 配置缺失仍按线上内连接规则过滤；上线前必须核对漏配和新增订单
-- ============================================================================
try_cost_base as
(
    select b.*
        ,jx.stat_month as jx_month
        ,concat(regexp_extract(jx.stat_month,'^([0-9]{4})年',1),'-',
                lpad(regexp_extract(jx.stat_month,'年([0-9]{1,2})月$',1),2,'0')) as jx_month_key
        ,cost_data.tax_rate as config_tax_rate
        ,cost_data.book_tax_rate as config_book_tax_rate
        ,cost_data.teacher_period_cost as config_teacher_period_cost
        ,cost_data.book_cost as config_book_cost
    from try_base b
    join dw_conan_temp.temp_conan_jx_period jx
        on (case when b.class_mode='思维四周' then '四周'
                 when b.class_mode rlike '英语|思维|阅读|英思|思阅' then '双周'
                 else '单周' end)=jx.class_mode_jx
        and b.start_class_dt between jx.stat_month_start and jx.stat_month_end
    join dw_conan_temp.temp_conan_try_base_cost cost_data
        on b.class_mode_detail=cost_data.class_mode_detail and jx.stat_month=cost_data.stat_month
),

-- 人效始终按完整user_base计算，真实/虚拟分组保持原口径。
teacher_ratio as
(
    select teacher_mode_key
        ,if(service_mode='虚拟',1,0) as is_virtual
        ,start_class_dt
        ,count(distinct userid)/count(distinct ldap) as ts_ratio
    from user_base
    group by teacher_mode_key,if(service_mode='虚拟',1,0),start_class_dt
),

-- 最终落表资格与财务服务分母共用；其他费用仍使用各自的完整分摊集合。
output_orders as
(
    select b.*,coalesce(ts.ts_ratio,0) as ts_ratio
    from try_cost_base b
    join teacher_ratio ts
        on b.teacher_mode_key=ts.teacher_mode_key
        and b.is_virtual=ts.is_virtual
        and b.start_class_dt=ts.start_class_dt
    where b.start_class_dt between '2024-01-01' and '${date}'
),

-- 财务获客/老师服务总额：仅新分类参与；不改变运营、物料、CPD等已有分摊。
-- 同category+channel+stat_month必须唯一，上传前独立校验；不在SQL中聚合重复配置。
finance_total_config as
(
    select stat_month,category,channel,cost_total
    from finance_monthly_source
    where ((category='渠道获客' and channel!='其他') or (category='老师服务' and channel='全部'))
        and stat_month rlike '^[0-9]{4}-(0[1-9]|1[0-2])$'
        and stat_month<=substr('${date}',1,7)
        and cost_total is not null
),

-- 财务获客分母：完整源集合中的已支付父单，包含未来开课；不依赖成本参数是否齐全。
-- 商务按结课月，其余按现行财务支付月；最终子单拆分仍沿用原规则。
finance_acquisition_order as
(
    select orderid,parent_orderid,order_channel_fin
        ,finance_acquisition_month as stat_month
    from try_base
    where to_date(pay_dt)<=to_date('${date}') and order_channel_fin!='其他'
        and parent_orderid is not null and trim(parent_orderid)!=''
),
-- 每个渠道/月/父单一行，同时承接新商务父内拆分与月度父单分母。
finance_acquisition_parent_month as
(
    select order_channel_fin,stat_month,parent_orderid,count(orderid) as month_child_count
    from finance_acquisition_order
    group by order_channel_fin,stat_month,parent_orderid
),
finance_acquisition_month_count as
(
    select '渠道获客' as category,order_channel_fin as channel,stat_month,count(*) as order_count
    from finance_acquisition_parent_month
    group by order_channel_fin,stat_month
),

-- 与最终落表共用output_orders；虚拟班仍参与原分母。
finance_teacher_month_count as
(
    select '老师服务' as category,'全部' as channel,jx_month_key as stat_month
        ,count(orderid) as order_count
    from output_orders
    group by jx_month_key
),
finance_total_month_count as
(
    select category,channel,stat_month,order_count from finance_acquisition_month_count
    union all
    select category,channel,stat_month,order_count from finance_teacher_month_count
),

-- 历史迁移边界为固定元数据，不保存单均金额；边界之后的新实数继续按原规则承接。
-- 2026年9至12月的旧暂估均等于最近结算月；仅这些原适用区间允许沿用迁移月单均。
finance_history_policy as
(
    select category,channel,last_legacy_settled_month,legacy_carry_start_month,legacy_carry_end_month
    from values
        ('渠道获客','C端分销','2026-08','2026-09','2026-12'),
        ('渠道获客','产品投放','2026-03',cast(null as string),cast(null as string)),
        ('渠道获客','供应链投放','2026-03',cast(null as string),cast(null as string)),
        ('渠道获客','商务合作-体验课','2026-08','2026-09','2026-12'),
        ('渠道获客','图书中价','2026-08','2026-09','2026-12'),
        ('渠道获客','地推','2026-08','2026-09','2026-12'),
        ('渠道获客','外部推广','2026-03',cast(null as string),cast(null as string)),
        ('渠道获客','小红书运营','2026-03',cast(null as string),cast(null as string)),
        ('渠道获客','效果投放','2026-08','2026-09','2026-12'),
        ('渠道获客','电销BPO','2026-08','2026-09','2026-12'),
        ('渠道获客','电销TMK','2026-08','2026-09','2026-12'),
        ('渠道获客','直播电商-体验课','2026-08','2026-09','2026-12'),
        ('渠道获客','直播电商-思维中价课','2026-08','2026-09','2026-12'),
        ('渠道获客','直播电商-英语中价课','2026-08','2026-09','2026-12'),
        ('渠道获客','直播电商-英语点读','2026-06',cast(null as string),cast(null as string)),
        ('渠道获客','直播电商-阅读中价课','2026-08','2026-09','2026-12'),
        ('老师服务','全部','2026-08','2026-09','2026-12')
    as history(category,channel,last_legacy_settled_month,legacy_carry_start_month,legacy_carry_end_month)
),

-- 每个结算月总额除以该来源月分母；未来月份沿用来源月单均，不拿历史总额除本月订单。
-- 来源分母缺失/为0时单均为NULL；不再回退到旧单均配置，新结算缺分母为0且未固化。
-- 迁移来源旧单价最高8位小数；只对迁移月还原该精度，新结算月保持完整double分摊精度。
finance_total_unit as
(
    select cfg.category,cfg.channel,cfg.stat_month,cfg.cost_total,cnt.order_count
        ,legacy.last_legacy_settled_month,legacy.legacy_carry_start_month,legacy.legacy_carry_end_month
        ,date_format(add_months(to_date(concat(cfg.stat_month,'-01')),1),'yyyy-MM') as source_month_end
        ,date_format(add_months(to_date(concat(legacy.legacy_carry_end_month,'-01')),1),'yyyy-MM') as carry_month_end
        ,lead(cfg.stat_month,1,'9999-12') over(partition by cfg.category,cfg.channel order by cfg.stat_month) as next_stat_month
        ,case when cnt.order_count>0 then
                   case when cfg.stat_month<=legacy.last_legacy_settled_month
                        then cast(cast(cfg.cost_total/cnt.order_count as decimal(38,8)) as double)
                        else cfg.cost_total/cnt.order_count end
              else cast(null as double) end as cost_per_order
    from finance_total_config cfg
    left join finance_total_month_count cnt
        on cfg.category=cnt.category and cfg.channel=cnt.channel and cfg.stat_month=cnt.stat_month
    left join finance_history_policy legacy
        on cfg.category=legacy.category and cfg.channel=legacy.channel
),

-- 财务匹配统一为左闭右开区间：当月/新实数一段，历史carry另接一段。
-- 两段不重叠；即使以后carry不连续，也不会填平中间空档。
finance_total_ranges as
(
    select u.*,u.stat_month as valid_from_month
        ,case when u.stat_month>coalesce(u.last_legacy_settled_month,'0000-00')
              then u.next_stat_month else least(u.next_stat_month,u.source_month_end) end as valid_to_month
    from finance_total_unit u
    where u.cost_per_order is not null
        or u.stat_month>coalesce(u.last_legacy_settled_month,'0000-00')
    union all
    select u.*,greatest(u.source_month_end,u.legacy_carry_start_month) as valid_from_month
        ,least(u.next_stat_month,u.carry_month_end) as valid_to_month
    from finance_total_unit u
    where u.stat_month=u.last_legacy_settled_month and u.cost_per_order is not null
        and u.legacy_carry_start_month is not null and u.legacy_carry_end_month is not null
        and greatest(u.source_month_end,u.legacy_carry_start_month)<least(u.next_stat_month,u.carry_month_end)
),

-- 北京运营成本：月总额 → 费用池内父订单单均 → 池内子订单成本
-- 固定自2026-01（含）切换新八池；2025-12及以前保留原市场运营池。
-- 新池缺配成本为0、未固化；未来月份配置不得反推之前月份，不回退旧市场总池。
market_operating_switch as
(
    select '2026-01' as split_start_month
),

-- 运营直接使用统一日均；支付日期与各费用池分摊规则保持不变。
bjop_order_base as
(
    select
        cast(a.orderid as string) as orderid
        ,a.parent_orderid
        ,substr(a.pay_dt,1,7) as paymonth
        ,case
            when a.user_from in ('扩科','APP自助','流量池','转介绍','新客转化','直接购买','集团流量','TMK') then
                case when substr(a.pay_dt,1,7)>=switch.split_start_month then '用增/体验课' else '增长运营' end
            when substr(a.pay_dt,1,7)>=switch.split_start_month and a.user_from='电商探索' then
                case a.child_subject_id
                    when '1' then '市场/电商/英语体验课'
                    when '2' then '市场/电商/思维体验课'
                    when '3' then '市场/电商/阅读体验课'
                    else '市场/电商/未识别'
                end
            when substr(a.pay_dt,1,7)>=switch.split_start_month and a.user_from in ('外部推广','小红书运营') then '市场/投放'
            when substr(a.pay_dt,1,7)>=switch.split_start_month and a.user_from='商务合作' then '市场/商务一组/体验课'
            when substr(a.pay_dt,1,7)>=switch.split_start_month and a.user_from='商务二组' then '市场/商务二组/体验课'
            when a.user_from in ('电商探索','商务合作','外部推广','小红书运营','商务二组') then '市场运营'
            when a.user_from='供应链' and a.ad_channel='地推' then '地推运营'
            else '其他'
        end as acquisition_pool
    from user_base a
    cross join market_operating_switch switch
    where a.pay_dt<='${date}'
),

-- 辅导运营仍按全部父单；获客运营分别在各池内去重父单、统计池内子单。
bjop_parent_children as
(
    select
        paymonth
        ,parent_orderid
        ,case when grouping(acquisition_pool)=1 then '辅导运营' else acquisition_pool end as pool
        ,count(1) as child_num
    from bjop_order_base
    group by grouping sets
    (
        (paymonth,parent_orderid,acquisition_pool)
        ,(paymonth,parent_orderid)
    )
),

bjop_parent_num as
(
    select
        paymonth
        ,pool
        ,parent_orderid
        ,child_num
        ,count(1) over(partition by paymonth,pool) as parent_num
    from bjop_parent_children
    where pool<>'其他'
),

-- 新细分池：本月已结算用完整实际月总额；未结算沿用最近日均×目标月截至调度日天数。
-- 2026年起用增体验课承接独立费用池；辅导、地推及2025年旧增长/市场池维持原公式。
bjop_parent_cost as
(
    select
        a.paymonth
        ,a.parent_orderid
        ,a.pool
        ,a.child_num
        ,(case
            when (a.pool like '市场/%' or a.pool='用增/体验课') and a.paymonth=b.stat_month then b.cost_total
            else b.daily_cost * day(least(last_day(to_date(concat(a.paymonth,'-01'))),to_date('${date}')))
          end) / a.parent_num as parent_operating_cost
        ,case when a.paymonth=b.stat_month and b.cost_total is not null
              then 1 else 0 end as pool_cost_checked
    from bjop_parent_num a
    left join finance_daily_data b on b.category='运营' and a.pool=b.channel
        and concat(a.paymonth,'-01')>=b.start_stat_dt
        and concat(a.paymonth,'-01')<b.next_stat_dt
),

-- 2024年前及原不适用范围不变；未识别电商学科不冒充“其他”或已固化。
bjop_order_cost as
(
    select
        a.orderid
        ,case when a.paymonth<'2024-01' then 0 else b.parent_operating_cost / b.child_num end as bj_fin_cost_teacher
        ,case
            when a.paymonth<'2024-01' or a.acquisition_pool='其他' then 0
            else c.parent_operating_cost / c.child_num
        end as bj_fin_cost_acquisition
        ,case
            when a.paymonth<'2024-01' then 1
            when coalesce(b.pool_cost_checked,0)=1
                and (a.acquisition_pool='其他' or coalesce(c.pool_cost_checked,0)=1) then 1
            else 0
        end as bj_cost_checked
    from bjop_order_base a
    left join bjop_parent_cost b on a.paymonth=b.paymonth and a.parent_orderid=b.parent_orderid and b.pool='辅导运营'
    left join bjop_parent_cost c on a.paymonth=c.paymonth and a.parent_orderid=c.parent_orderid and a.acquisition_pool=c.pool
),

-- 财务物料：支付月×子订单学科有材池；未结算沿用本学科最近结算月单均
book_fin_order_base as
(
    select
        cast(orderid as string) as orderid
        ,substr(pay_dt,1,7) as paymonth
        ,child_subject_id
    from user_base
    where is_having_trybook=1 and pay_dt<='${date}'
        and child_subject_id in ('1','2','3','8')
),

book_fin_order_num as
(
    select paymonth,child_subject_id,count(orderid) as child_order_num
    from book_fin_order_base
    group by paymonth,child_subject_id
),

book_fin_config as
(
    select stat_month,cost_total
        ,case channel when '英语' then '1' when '思维' then '2'
                      when '阅读' then '3' when '科学' then '8' end as child_subject_id
    from finance_monthly_source
    where category='物料'
        and channel in ('英语','思维','阅读','科学')
),

book_fin_unit as
(
    select cfg.stat_month,cfg.child_subject_id
        ,lead(cfg.stat_month,1,'9999-12')
            over(partition by cfg.child_subject_id order by cfg.stat_month) as next_stat_month
        ,case when cfg.cost_total=0 then cast(0 as double)
              when cnt.child_order_num>0 then cfg.cost_total/cnt.child_order_num
              else cast(0 as double) end as book_fin_cost
        ,case when cfg.cost_total is not null
                   and (cfg.cost_total=0 or cnt.child_order_num>0)
              then 1 else 0 end as source_cost_checked
    from book_fin_config cfg
    left join book_fin_order_num cnt
        on cfg.stat_month=cnt.paymonth and cfg.child_subject_id=cnt.child_subject_id
),
book_fin_order_cost as
(
    select a.orderid,coalesce(b.book_fin_cost,0) as book_fin_cost
        ,case when a.paymonth=b.stat_month then b.source_cost_checked else 0 end as book_cost_checked
    from book_fin_order_base a
    left join book_fin_unit b
        on a.child_subject_id=b.child_subject_id
        and a.paymonth>=b.stat_month and a.paymonth<b.next_stat_month
),

-- 费用关联层：保留各费用模块的匹配、缺失与固化语义。
matched_costs as
(
	select
		try_base.class_mode

		-- 服务成本与随材成本匹配键，由user_base统一生成
		,try_base.class_mode_detail

		,try_base.start_class_dt
		,try_base.end_class_dt
		,try_base.is_end

		,if(try_base.user_from='商务合作无成本','商务合作',try_base.user_from) as user_from
		,try_base.ad_channel
		,if(cpd_order.cpd_try_orderid is not null, 1, 0) as is_try_cpd

		,try_base.userid
		,try_base.orderid
		,try_base.pay_dt
		,try_base.is_renewal_w2
		,try_base.renewal_orderid

		,coalesce(try_base.config_tax_rate, 0) as tax_rate -- 税率
		,coalesce(try_base.try_paidfee, 0) as try_paidfee -- 体验课收入

		,case when order_cac.orderid is null then cast(raise_error('Business CAC snapshot/order is missing') as double)
		      else coalesce(order_cac.cac_cost_raw, 0) end as cac_cost -- 订单级原始 CAC：旧路径拆 Bundle，新路径已直接分到子订单
		,order_cac.third_channel as third_channel -- 渠道细分：电商保留成本SKU，商务透传上游third_channel，未匹配NULL
		,coalesce(cpd_order.try_order_cpd_cost, 0) as cpd_cost -- 双周子订单CPD，不乘单双重叠系数
		,coalesce(cpd_order.try_order_cpd_fin_cost, 0) as cpd_fin_cost

		,case when try_base.fixed_teacher_cost is not null then try_base.fixed_teacher_cost
              else coalesce(if(try_base.service_mode='虚拟',0,
                               try_base.config_teacher_period_cost / try_base.teacher_bundled_num),0) / try_base.ts_ratio
         end as teacher_cost -- 业务服务金额只计算一次，raw兼容列在最终输出引用
		,try_base.ts_ratio -- 人效

		,try_base.config_book_tax_rate as try_book_factor
  		,coalesce((case 
                  when try_base.is_having_trybook=0 then 0
                  when ds_third.order_id is not null then 145 -- 299抖音点读渠道发35+110的随材
                  when try_base.class_mode='英语' and try_base.ad_channel rlike '中价' and try_base.try_paidfee=99.0 then 30.3129
                  when try_base.class_mode='思维' and try_base.ad_channel rlike '中价' and try_base.try_paidfee=99.0 then 28.8830
                  when try_base.class_mode='英语' and try_base.ad_channel rlike '中价' then 36.3861
                  when try_base.class_mode='思维' and try_base.ad_channel rlike '中价' then 37.3722
                  when try_base.class_mode='阅读' and try_base.ad_channel rlike '中价' then 28
                  when try_base.class_mode='英思' and try_base.ad_channel rlike '中价' then 76 -- 英思中价成本为英语+思维中价成本
                  when try_base.class_mode='英语' and try_base.ad_channel='点读版' and try_base.start_class_dt>='2026-03-30' then 80
                  when try_base.class_mode='英语' and try_base.ad_channel='点读版' and try_base.start_class_dt>='2026-03-02' then 116
				  when try_base.class_mode='英语' and try_base.ad_channel='点读版' and try_base.start_class_dt<'2026-03-02'  then 110
                  else try_base.config_book_cost end )/try_base.book_bundled_num, 0) as try_book_cost -- 随材成本，无随材的渠道不计算随材成本，要分摊到子订单；电商中价渠道的随材成本额外计算

		-- 无关联系统课时为0；有关联但上游缺失/收入参数缺配时保留NULL
		,case when try_base.renewal_orderid is null or try_base.renewal_orderid='' then 0
		      else season.pay_amt + season.deposit_add_amt end as season_paidfee_raw -- 系统课收款，保留加回定金后的金额口径
		,case when try_base.renewal_orderid is null or try_base.renewal_orderid='' then 0
		      else season.season_net_profit end as season_net_profit
		,try_base.overlap_order_factor

        ,coalesce(case when fin_cac_total.stat_month is not null
                              and (fin_cac_total.stat_month<=fin_cac_total.last_legacy_settled_month
                                   or fin_cac_parent.month_child_count>0)
                         then fin_cac_total.cost_per_order / case
                              when try_base.is_business_fin=1 then
                                   case when fin_cac_total.stat_month<=fin_cac_total.last_legacy_settled_month
                                        then business_fin.month_child_count else fin_cac_parent.month_child_count end
                              else try_base.buy_bundled_num end
                  end,0) as cac_fin_cost
        ,coalesce(cast(fin_teacher_total.cost_per_order as string),'0') as teacher_fin_cost -- 保留总额分摊后的实际精度，不按旧单均配置强制截断小数
        ,case when try_base.order_channel_fin='其他' then -1
              when fin_cac_total.stat_month=try_base.finance_acquisition_month
                   and fin_cac_total.cost_per_order is not null
                   and (fin_cac_total.stat_month<=fin_cac_total.last_legacy_settled_month or fin_cac_parent.month_child_count>0)
              then 1 else 0 end as cac_cost_checked
        ,case when fin_teacher_total.stat_month=try_base.jx_month_key
                   and fin_teacher_total.cost_per_order is not null
              then 1 else 0 end as teacher_cost_checked
		,try_base.stage_name

		-- 4 个新增输出字段：透传给最外层
		,try_base.stage_name_comb
		,try_base.channel_price
		,try_base.lesson_desc
		,try_base.service_mode
		,coalesce(bjop.bj_fin_cost_teacher,0) as bj_fin_cost_teacher
		,coalesce(bjop.bj_fin_cost_acquisition,0) as bj_fin_cost_acquisition
		,coalesce(book_fin.book_fin_cost,0) as book_fin_cost
		,coalesce(bjop.bj_cost_checked,0) as bj_cost_checked
		,case when try_base.is_having_trybook=0 then -1
		      else coalesce(book_fin.book_cost_checked,0)
		 end as book_cost_checked -- 无随材为不适用；有材按原始支付月、本学科财务实数判断
	from output_orders try_base

    left join business_fin_parent_month business_fin
        on try_base.is_business_fin=1
        and try_base.parent_orderid=business_fin.parent_orderid
        and try_base.end_class_month=business_fin.end_month

	-- 月度运营成本：全量支付父单分摊后，按子订单关联
	left join bjop_order_cost bjop on cast(try_base.orderid as string)=bjop.orderid

	-- 财务物料：仅有材订单进入分摊池，无材或无可用配置按0处理
	left join book_fin_order_cost book_fin on cast(try_base.orderid as string)=book_fin.orderid

	-- 同日业务CAC结果；上游未产出订单时显式失败，费用缺配的原0语义由CAC任务保留。
	left join dw_conan_ads.ads_conan_service_try_order_cac_da order_cac
		on try_base.orderid=order_cac.orderid and order_cac.dt='${date}'

    -- 新财务总额按分类/渠道承接最近结算单均，0元实数不会触发旧配置回退。
    left join finance_total_ranges fin_cac_total
        on fin_cac_total.category='渠道获客' and try_base.order_channel_fin=fin_cac_total.channel
        and try_base.finance_acquisition_month>=fin_cac_total.valid_from_month
        and try_base.finance_acquisition_month<fin_cac_total.valid_to_month
    left join finance_acquisition_parent_month fin_cac_parent
        on try_base.parent_orderid=fin_cac_parent.parent_orderid
        and try_base.order_channel_fin=fin_cac_parent.order_channel_fin
        and try_base.finance_acquisition_month=fin_cac_parent.stat_month
        and to_date(try_base.pay_dt)<=to_date('${date}')
    left join finance_total_ranges fin_teacher_total
        on fin_teacher_total.category='老师服务' and fin_teacher_total.channel='全部'
        and try_base.jx_month_key>=fin_teacher_total.valid_from_month
        and try_base.jx_month_key<fin_teacher_total.valid_to_month

	-- 同日系统课订单成本收益；税率、毛利率、退费、公摊和直售统一由上游计算
	left join dw_conan_ads.ads_conan_service_season_order_cost_da season
		on try_base.renewal_orderid=season.order_id and season.dt='${date}'

	-- CPD直接按双周user_quality中的订单ID关联，不以是否转化为条件
	left join cpd_order on try_base.orderid=cpd_order.cpd_try_orderid

	-- 通过电商三级渠道判断是否为299中价点读sku
	left join
	(	
		select
			order_id
		from dw_conan_dwd.dwd_conan_try_double_ds_third_channel
		where dt='${date}' and third_channel='299抖音中价点读'
	) ds_third on try_base.orderid=ds_third.order_id
),

-- 金额计算层：税率、收益归因、运营合计在此统一计算。
try_cost_detail as
(
select
	class_mode
	,class_mode_detail
	,start_class_dt
	,is_end
	,user_from
	,ad_channel
	,is_try_cpd
	,userid
	,orderid
	,is_renewal_w2
	,renewal_orderid
	,ts_ratio -- 真实人效

	-- 利润公式
	-- 体验课收款 / 税率
	--	- 体验课获客成本 / 税率 - CPD 成本 / 税率
	--	- 体验课基础服务成本 / 人效（指定虚拟订单固定 30）
	--	- 体验课随材成本 / 随材税率 - 北京运营成本
	--	+ 系统课净收益 * 单双重叠归因系数（系统课表已扣公摊和直售成本）

	-- 基础金额及税率；兼容系数统一在最终输出给定
	,try_paidfee as try_pmt_raw
	,cpd_cost as cpd_cost_raw
	,cac_cost as cac_cost_raw
	,try_book_cost as book_cost_raw
	,tax_rate
	,try_book_factor
	,season_paidfee_raw

	-- 全周期统一按月度金额分摊，不再使用旧运营系数
	-- cac_cost / teacher_cost 不含北京运营；bj_fin_cost 在净收益中单独扣一次
	-- 财务配置缺失或未匹配质量表订单时，两项北京运营费用按 0 兜底；补齐后重算
	,try_paidfee / tax_rate as try_pmt
	,cac_cost / tax_rate as cac_cost
	,cpd_cost / tax_rate as cpd_cost
	,teacher_cost
	,try_book_cost / try_book_factor as book_cost
	,season_net_profit * overlap_order_factor as season_profit -- 扣公摊、直售后的净收益，处理单双重叠
	,season_net_profit as season_profit_raw -- 扣费后净收益，不处理单双重叠

	,pay_dt
	,cac_fin_cost
	,teacher_cost_checked
	,cac_cost_checked
	,teacher_fin_cost
	,bj_fin_cost_teacher + bj_fin_cost_acquisition as bj_fin_cost -- 北京运营合计，在业务和财务净收益中分别单独扣一次
	,stage_name
	,end_class_dt

	-- 模式字段与上游对齐；实际物理列序由最终输出统一维护
	,stage_name_comb
	,channel_price
	,lesson_desc
	,service_mode
	,bj_fin_cost_teacher
	,bj_fin_cost_acquisition
	,book_fin_cost -- 财务物料，月总额按各学科发随材子单分摊，不重复除税或拆联带
	,cpd_fin_cost -- 财务CPD，激活月父单均摊后共用业务合格子单分母，不重复除税
	,bj_cost_checked
	,book_cost_checked
	,third_channel
from matched_costs
)

INSERT OVERWRITE TABLE dw_conan_ads.ads_conan_service_try_order_cost_da partition (dt = '${date}')
select
    d.class_mode
    ,d.class_mode_detail
    ,d.start_class_dt
    ,d.is_end
    ,d.user_from
    ,d.ad_channel
    ,d.is_try_cpd
    ,d.userid
    ,d.orderid
    ,d.is_renewal_w2
    ,d.renewal_orderid
    ,d.ts_ratio
    ,d.try_pmt_raw
    ,d.cpd_cost_raw
    ,d.cac_cost_raw
    ,d.teacher_cost as teacher_cost_raw
    ,d.book_cost_raw
    ,d.tax_rate
    ,1 as try_cac_factor -- 废弃系数仅保留输出接口
    ,1 as try_teacher_factor -- 废弃系数仅保留输出接口
    ,d.try_book_factor
    ,d.season_paidfee_raw
    ,d.try_pmt
    ,d.cac_cost
    ,d.cpd_cost
    ,d.teacher_cost
    ,d.book_cost
    ,d.season_profit
    ,d.season_profit_raw
    ,d.pay_dt
    ,d.cac_fin_cost
    ,d.teacher_cost_checked
    ,d.cac_cost_checked
    ,d.teacher_fin_cost
    ,d.bj_fin_cost
    ,d.stage_name
    ,d.end_class_dt
    ,d.stage_name_comb
    ,d.channel_price
    ,d.lesson_desc
    ,d.service_mode
    ,d.bj_fin_cost_teacher
    ,d.bj_fin_cost_acquisition
    ,d.book_fin_cost
    ,d.cpd_fin_cost
    ,d.try_pmt - d.cac_cost - d.cpd_cost - d.teacher_cost - d.book_cost - d.bj_fin_cost as try_net_profit
    ,d.try_pmt - d.cac_fin_cost - d.cpd_fin_cost - d.teacher_fin_cost - d.book_fin_cost - d.bj_fin_cost as try_net_fin_profit
    ,d.bj_cost_checked -- 运营固化状态：1当月财务实数，0暂估或缺失
    ,d.book_cost_checked -- 财务物料固化状态：1实数，0暂估或缺失，-1无随材
    ,d.third_channel -- 渠道细分：电商成本SKU或商务细分；未匹配NULL，电商适用未识别UNSET
from try_cost_detail d



-- 数据更新：
-- 1、绩效周期：每年更新
-- 2、服务/随材成本：每月更新至dw_conan_temp.temp_conan_try_base_cost
-- 3、获客成本：https://shimo.zhenguanyu.com/sheets/3O8pG2xxwbeGC0JG/L2kYj

-- 公式：
-- 业务：sum(try_net_profit + season_profit) / count(系统课订单数)
-- 财务体验课净收益：try_net_fin_profit；北京运营只在净收益公式中扣一次
-- 为每笔体验课子订单匹配体验课收入、获客成本、服务成本、随材成本及转化系统课净收益；转化窗口由原下游逻辑控制










