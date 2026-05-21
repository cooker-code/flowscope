set spark.driver.memory=16g;
set spark.driver.cores=1;
set spark.executor.memory=10g;
set spark.executor.cores=2;

REFRESH TABLE dw_conan_ads.ads_course_user_gift_card_stat_di;

-- ============================================
-- 系统课学生列表「增长活动参与情况」字段计算
-- 需求来源：Confluence pageId=979175115
-- 计算字段：
--   1. 【近180天分享次数】：用户在最近 180 天内完成亲友卡分享的次数
--   2. 【近7天查看活动页】：用户最近 7 天内是否查看过亲友卡活动落地页
--   3~4. 【亲友卡】本周活动页访问 / 本周分享
--   5~6. 【推荐有礼】本周活动页访问 / 本周分享
--   7~8. 【通识内容】本周活动页访问 / 本周分享
-- 本周定义：本自然周（当周周一 00:00:00 至当前时间）
-- ============================================


-- 历史数据使用 dwd_eng_frog_di，当天数据使用 ods_eng_frog_di_hour（实时表）
WITH activity_logs AS (
    -- 合并所有活动相关埋点数据（分享+查看，历史+当天）
    -- 历史数据（T-1及之前）
    SELECT
        CAST(user_id AS STRING) AS user_id
        ,dt
        ,device_id
        ,log_time
        ,url
        ,CASE WHEN url = '/event/InvitingFriend/PosterShare/sharesuccessed' THEN 'share'
              WHEN url = '/event/InvitingFriend/enter' THEN 'view'
              ELSE 'other' END AS action_type
        ,CASE WHEN other['sourcename'] IN ('GiftCard', 'GiftCardActivity') THEN 'friendCard'
              WHEN other['sourcename'] IN ('main_button', 'referGift', 'referGift2') THEN 'referGift'
              WHEN other['sourcename'] = 'referResource' THEN 'referResource'
              ELSE 'other' END AS source_category
    FROM dw_dwd.dwd_eng_frog_di
    WHERE dt >= date_sub('${date}', 178)  -- 近180天（用于分享统计）
      AND dt <= '${date}'  -- 截止到昨天（不包含当天）
      AND url IN (
          '/event/InvitingFriend/PosterShare/sharesuccessed'  -- 分享成功埋点
          ,'/event/InvitingFriend/enter'  -- 查看活动页埋点
      )
      AND other['sourcename'] IN ('GiftCard', 'GiftCardActivity', 'main_button', 'referGift', 'referGift2', 'referResource')
      AND category = 'event'
      AND user_id IS NOT NULL
      AND user_id != ''

    UNION ALL

    -- 当天实时数据（从小时表获取）
    SELECT
        CAST(user_id AS STRING) AS user_id
        ,dt
        ,device_id
        ,ftime AS log_time
        ,url
        ,CASE WHEN url = '/event/InvitingFriend/PosterShare/sharesuccessed' THEN 'share'
              WHEN url = '/event/InvitingFriend/enter' THEN 'view'
              ELSE 'other' END AS action_type
        ,CASE WHEN other['sourcename'] IN ('GiftCard', 'GiftCardActivity') THEN 'friendCard'
              WHEN other['sourcename'] IN ('main_button', 'referGift', 'referGift2') THEN 'referGift'
              WHEN other['sourcename'] = 'referResource' THEN 'referResource'
              ELSE 'other' END AS source_category
    FROM dw_conan_ods.ods_eng_frog_di_hour
    WHERE dt = '${currentDate}'  -- 当天
      AND url IN (
          '/event/InvitingFriend/PosterShare/sharesuccessed'  -- 分享成功埋点
          ,'/event/InvitingFriend/enter'  -- 查看活动页埋点
      )
      AND other['sourcename'] IN ('GiftCard', 'GiftCardActivity', 'main_button', 'referGift', 'referGift2', 'referResource')
      AND user_id IS NOT NULL
      AND user_id > 0
      AND TO_DATE(FROM_UNIXTIME(CAST(tp / 1000 AS BIGINT))) = dt  -- 确保时间戳对应的日期与分区日期一致
)
,activity_metrics AS (
    SELECT
        user_id
        -- 近180天分享次数（仅亲友卡）
        ,COUNT(DISTINCT CASE
            WHEN action_type = 'share' AND source_category = 'friendCard'
            THEN CONCAT(dt, '_', device_id, '_', log_time)
            ELSE NULL
        END) AS share_count_180d
        -- 近7天查看活动页（仅亲友卡）
        ,MAX(CASE
            WHEN action_type = 'view' AND source_category = 'friendCard'
             AND dt >= date_format(date_add('${currentDate}', -6), '%Y-%m-%d')  -- 近7天
            THEN 1 ELSE 0
        END) AS has_viewed_7d
        -- 亲友卡：本周活动页访问（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'view' AND source_category = 'friendCard'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS friend_card_enter_page_this_week
        -- 亲友卡：本周分享（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'share' AND source_category = 'friendCard'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS friend_card_share_this_week
        -- 推荐有礼：本周活动页访问（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'view' AND source_category = 'referGift'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS refer_gift_enter_page_this_week
        -- 推荐有礼：本周分享（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'share' AND source_category = 'referGift'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS refer_gift_share_this_week
        -- 通识内容：本周活动页访问（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'view' AND source_category = 'referResource'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS refer_resource_enter_page_this_week
        -- 通识内容：本周分享（本自然周，周一起）
        ,MAX(CASE
            WHEN action_type = 'share' AND source_category = 'referResource'
             AND dt >= date_sub('${currentDate}', pmod(dayofweek('${currentDate}') - 2, 7))
            THEN 1 ELSE 0
        END) AS refer_resource_share_this_week
    FROM activity_logs
    GROUP BY user_id
)

INSERT OVERWRITE TABLE dw_conan_ads.ads_course_user_gift_card_stat_di PARTITION (dt = '${currentDate}')
SELECT
    CAST(user_id AS BIGINT) AS user_id
    ,share_count_180d  -- 近180天分享次数
    ,has_viewed_7d  -- 近7天查看活动页（1-已查看，0-未查看）
    ,friend_card_enter_page_this_week  -- 亲友卡本周活动页访问（1-是，0-否）
    ,friend_card_share_this_week  -- 亲友卡本周分享（1-是，0-否）
    ,refer_gift_enter_page_this_week  -- 推荐有礼本周活动页访问（1-是，0-否）
    ,refer_gift_share_this_week  -- 推荐有礼本周分享（1-是，0-否）
    ,refer_resource_enter_page_this_week  -- 通识内容本周活动页访问（1-是，0-否）
    ,refer_resource_share_this_week  -- 通识内容本周分享（1-是，0-否）
FROM activity_metrics
;
