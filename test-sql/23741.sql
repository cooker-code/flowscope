select 
	coalesce(dt,'total_count')as dt,
    coalesce(appid,'total_count')as  appid,
    coalesce(resource_type,'total_count')as resource_type,
    coalesce(case when b.user_id is not null then '买过衍生品'
    else '没买过衍生品' end,'total_count')as yanshengpin_type
    ,count(distinct userid)as unt 
from 
(
	select

		case when url in ('/event/SplashScreen/enter') then '闪屏'
			when url in ('/expose/MarketingPopup/enter',
				'/event/AppPopWindow/enter') then '弹窗'
			when url in ('/expose/LessonList/banner',
	            '/expose/HdHomepage/banner',
	            '/event/LessonList/Banner/enter',
                  '/expose/LessonList/recommend/banner') then 'banner'
			when url in ('/expose/LessonList/custom',
            '/expose/LessonList/shelves',
            '/expose/HdHomepage/shelves',
            '/expose/HdHomepage/moreinfo')and appid='pedia' then '百科货架'
		
			when url in ('/expose/PediaPackagelistPage/banner',
            -- 货架
            '/expose/LessonList/custom',
            '/expose/LessonList/shelves',
            '/expose/ExtensiveStudying/card',
            '/expose/HdHomepage/shelves',
            '/expose/HdHomepage/moreinfo',
            '/expose/PediaPackagelistPage/GoodsPackage')and appid='zebra' then '斑马拓展入口'
			when url in ('/expose/HdHomepage/launchAd',
				
            '/expose/LessonList/launchAd') then '上新卡片'
			else url end as resource_type,
			a.*

		  
	from 
	(	-- 百科资源位
    select dt,action_tp,url,userid
            ,'' as buymode
            ,'' as keyfrom
            ,'' as duration
            ,'pedia' as appid
            ,productid
            ,device_type
    from dw_ods.ods_pedia_frog
    where dt between '{{{start_dt}}}' and '{{{end_dt}}}'
    and url in('/event/SplashScreen/enter',
            '/expose/MarketingPopup/enter',
            '/expose/LessonList/banner',
            '/expose/HdHomepage/banner',
            '/expose/LessonList/recommend/banner',
            -- 百科货架
            '/expose/LessonList/custom',
            '/expose/LessonList/shelves',
            '/expose/HdHomepage/shelves',
            '/expose/HdHomepage/moreinfo',

            -- 上新卡片
            '/expose/HdHomepage/launchAd',
            '/expose/LessonList/launchAd'

            )
    AND category IN ('click','event','expose')
    AND page_tp IN ('S','M','L','H','E')
    and ( {{other['taskid']}}
    		or {{other['id']}}
    	-- 弹窗
        or  {{other['popupid'] }}
        -- 货架
        or {{other['cardid']}}
        or {{other['packageid']}}
        -- 上新卡片
        or {{other['resourceid']}}
        or {{other['materialid']}}
        or {{other['bannerid'] as bkbannerid}}
        )

    -- 斑马资源位
    union all
    select dt,action_tp,url,user_id as userid
        ,'' as buymode
        ,'' as keyfrom
        ,'' as duration
        ,'zebra' as appid
        ,product_id
        ,device_type
    from dw_dwd.dwd_eng_frog_di
    where dt between '{{{start_dt}}}' and '{{{end_dt}}}'
    and url in('/event/SplashScreen/enter',
            '/event/AppPopWindow/enter',
            '/event/LessonList/Banner/enter',

            -- 拓展入口
            '/expose/PediaPackagelistPage/banner', 	-- 外部卡片

            -- 货架
            '/expose/LessonList/custom',
            '/expose/LessonList/shelves',
            '/expose/ExtensiveStudying/card',
            '/expose/HdHomepage/shelves',
            '/expose/HdHomepage/moreinfo',
            -- 老版货架
            '/event/PediaPackagelistPage/PediaPackageCard/enter',
            '/expose/PediaPackagelistPage/GoodsPackage',

            -- 上新卡片
            '/expose/HdHomepage/launchAd',
            '/expose/LessonList/launchAd'

            )
    AND category IN ('click','event','expose')
    AND page_tp IN ('S','M','L','H','A','E','P')
    and ( {{other['taskid']}} 
    		or {{other['id']}}
    	-- 弹窗
        or {{other['resourceid']}} 

        -- 拓展入口
        or {{other['bannerid']}} 
        -- 货架
        or {{other['cardid']}} 
        or {{other['packageid']}}   

        -- 上新卡片
        or {{other['resourceid']}}
        or {{other['materialid']}}
        )
	)a 
	
)detail 
left join 
(--衍生品成单
    select user_id,min(pay_tp) as shougou_tp 
    from dw_conan_dwd.dwd_pedia_derivative_order_info_da
    where dt = date_sub(current_date, 1)
    and order_status_cd = 2
    and is_test_user = 0
    group by user_id
) b 
on detail.userid=b.user_id
and detail.action_tp>b.shougou_tp
group by 
		dt,
	    appid,
	    resource_type
        ,case when b.user_id is not null then '买过衍生品'
    else '没买过衍生品' end with cube