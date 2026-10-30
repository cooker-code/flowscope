CREATE TABLE `dw_conan_ads.ads_eng_telesales_new_stock_rescore_delta_di`(
  `user_id` string COMMENT '用户ID', 
  `previous_grade` string COMMENT '昨日等级', 
  `new_grade` string COMMENT '今日重评等级，资格退出或输入非法时为空', 
  `previous_rank_score` double COMMENT '昨日排序分', 
  `new_rank_score` double COMMENT '今日重评排序分', 
  `rescore_reason` string COMMENT '重评或退出原因', 
  `changed_feature_list` array<string> COMMENT '发生变化的原始字段', 
  `previous_is_eligible` int COMMENT '昨日是否在新客存量状态池', 
  `new_is_eligible` int COMMENT '今日是否符合新客存量基础资格', 
  `previous_feature_hash` string COMMENT '昨日原始特征哈希', 
  `new_feature_hash` string COMMENT '今日原始特征哈希', 
  `pd` string COMMENT '从未活跃或距今3个月以上', 
  `user_type` string COMMENT 'market用户身份', 
  `aes_phone` string COMMENT '加密手机号', 
  `market_register_dt` string COMMENT 'market注册日期', 
  `user_create_dt` string COMMENT '活跃表最早创建日期', 
  `lst_active_dt` string COMMENT '最近活跃日期', 
  `birthday` string COMMENT '有效生日', 
  `age_years` double COMMENT '按评分锚点计算的年龄', 
  `call_detail_hash` string COMMENT '近一年拨打明细原始JSON哈希', 
  `touch_dt_array_4m` array<string> COMMENT '近4个月非AI拨打日期去重数组', 
  `connect_dt_array_4m` array<string> COMMENT '近4个月非AI接通日期去重数组', 
  `hist_touch_connected_day_cnt_4m` double COMMENT '近4个月非AI接通天数', 
  `hist_touch_day_cnt_4m` double COMMENT '近4个月非AI拨打天数', 
  `ip_address_update_dt` string COMMENT '最近IP更新时间', 
  `ip_province` string COMMENT 'IP省份', 
  `latest_device_manufacturer` string COMMENT '最近设备厂商', 
  `latest_device_model` string COMMENT '最近设备型号', 
  `age_bucket` string COMMENT '年龄分组', 
  `jinjuan_tag` double COMMENT '金娟标签', 
  `days_since_last_active` double COMMENT '评分锚点距最近活跃天数', 
  `register_days` double COMMENT '评分锚点距注册或创建天数', 
  `ip_address_age_days` double COMMENT '评分锚点距IP更新时间天数', 
  `p_connect` double COMMENT '校准后接通概率', 
  `p_d0_given_connect` double COMMENT '校准后接通条件下D0支付概率', 
  `frequency_coef` double COMMENT '拨打频次折损系数', 
  `frequency_hard_exclude_flag` int COMMENT '近4个月拨打至少3天且0接通标记', 
  `raw_grade` string COMMENT '频控和年龄封顶前等级', 
  `model_feature_json` string COMMENT '10个模型字段审计JSON', 
  `model_version` string COMMENT '模型版本', 
  `entry_type` string COMMENT 'NEW_ENTRY、CONTINUE、EXIT或INVALID_INPUT', 
  `first_entry_dt` string COMMENT '首次进入状态表日期', 
  `last_feature_update_dt` string COMMENT '最近一次原始特征更新日期', 
  `last_score_dt` string COMMENT '最近一次实际评分日期')
COMMENT 'BPO新客存量每日增量重评明细表'
PARTITIONED BY ( 
  `dt` string COMMENT '特征快照日期', 
  `batch_no` string COMMENT '稳定哈希分批编号0至3')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.orc.OrcSerde' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_eng_telesales_new_stock_rescore_delta_di'
TBLPROPERTIES (
  'transient_lastDdlTime'='1792914486')

