select
    '分销' as `一级`
    ,'分销-B端-CPA' as `二级渠道`
    ,'体验会员' as `cpa类型`
    ,period_monday as `周一`
    ,date_add(period_monday, 6) as `周日`
    ,business_channel as `渠道类型`
    ,channel_4 as `渠道名称`
    ,coalesce(round(sum(cpa_cost_per_order), 2), 0) as `每周成本`
    ,count(distinct user_id) as `每周成单UV`
    ,count(distinct if(is_season = 1, user_id, null)) as `每周转化UV`
    ,coalesce(round(sum(season_ltv) / count(distinct if(is_season = 1, user_id, null)), 0), 0) as `eLTV`
from A
