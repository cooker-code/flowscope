CREATE TABLE `dw_conan_ads.ads_eng_telesales_drop_stock_score_state_da`(
  `user_id` string COMMENT '用户ID', 
  `user_type` string COMMENT 'market用户身份', 
  `age` double COMMENT '按状态日期计算的年龄', 
  `lst_active_dt` string COMMENT '最近活跃日期', 
  `s3_plus_subject_cnt` bigint COMMENT 'S3及以上体验课科目数', 
  `season_min_pay_dt` string COMMENT '最早系统课支付日期', 
  `try_max_pay_dt` string COMMENT '最近英语体验课支付日期', 
  `is_eligible` int COMMENT '是否符合断课基础资格，冷启动分区均为1', 
  `has_valid_comm` double COMMENT '是否存在历史有效转化沟通', 
  `hist_finish_course_cnt` double COMMENT '历史体验课完课订单数', 
  `last_try_pay_dt` string COMMENT '最近体验课支付日期', 
  `hist_try_pay_channel` string COMMENT '最近体验课购买渠道', 
  `prior_try_subject_cnt` double COMMENT '历史体验课科目数', 
  `prior_try_order_cnt` double COMMENT '历史体验课订单数', 
  `app_profile_bucket` string COMMENT 'APP画像分桶', 
  `call_detail_hash` string COMMENT '近一年拨打明细原始JSON哈希，用于轻量识别拨打变化', 
  `touch_dt_array_4m` array<string> COMMENT '近4个月非AI拨打日期去重数组', 
  `connect_dt_array_4m` array<string> COMMENT '近4个月非AI接通日期去重数组', 
  `hist_touch_day_cnt_4m` bigint COMMENT '近4个月非AI拨打天数', 
  `hist_touch_connect_day_cnt_4m` bigint COMMENT '近4个月非AI接通天数', 
  `days_since_last_active` double COMMENT '评分日距最近活跃天数', 
  `days_since_last_try_pay` double COMMENT '评分日距最近体验课支付天数', 
  `p_connect` double COMMENT '校准后接通概率', 
  `p_d7_given_connect` double COMMENT '校准后接通条件下D7支付概率', 
  `p_d7_joint` double COMMENT 'D7联合概率', 
  `frequency_coef` double COMMENT '拨打频次折损系数', 
  `repeat_order_coef` double COMMENT '多购折损系数', 
  `frequency_hard_exclude_flag` int COMMENT '近4个月拨打至少3天且0接通标记', 
  `rank_score` double COMMENT '最终排序分', 
  `raw_grade` string COMMENT '频控封顶前等级', 
  `grade` string COMMENT '最终等级，含EXCLUDED', 
  `model_version` string COMMENT '模型版本', 
  `raw_feature_hash` string COMMENT '不含随日期自然变化字段的原始特征哈希', 
  `entry_type` string COMMENT '进入状态表类型', 
  `first_entry_dt` string COMMENT '首次进入本状态表日期', 
  `last_feature_update_dt` string COMMENT '最近一次原始特征更新日期', 
  `last_score_dt` string COMMENT '最近一次评分日期')
COMMENT 'BPO断课存量增量评级用户状态表'
PARTITIONED BY ( 
  `dt` string COMMENT '状态基准日期', 
  `batch_no` string COMMENT '稳定哈希分批编号0至3')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.orc.OrcSerde' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_eng_telesales_drop_stock_score_state_da'
TBLPROPERTIES (
  'transient_lastDdlTime'='1792747982')

