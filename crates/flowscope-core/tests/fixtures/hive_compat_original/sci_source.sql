CREATE EXTERNAL TABLE `dw_conan_ads.ads_finance_sci_user_season_ma`(
  `user_id` string COMMENT '用户ID', 
  `order_list` array<string> COMMENT '订单排序集合', 
  `cur_total_weekcount` string COMMENT '本月总课时', 
  `cur_left_weekcount` string COMMENT '本月剩余课时', 
  `cur_get_weekcount` string COMMENT '本月新增课时', 
  `cur_refund_weekcount` string COMMENT '本月退款课时', 
  `last_total_weekcount` string COMMENT '上月总课时', 
  `last_left_weekcount` string COMMENT '上月剩余课时', 
  `receipt_list` array<string> COMMENT '课时明细集合', 
  `settled_weekcount` string COMMENT '历史总确认课时', 
  `settled_fee` string COMMENT '历史总确认金额', 
  `first_level` string COMMENT '用户首次上课级别', 
  `level_weeks` array<string> COMMENT '用户还未完成的级别集合')
COMMENT 'AI课-科学科目系统课用户粒度财务统计月表'
PARTITIONED BY ( 
  `dt` string COMMENT '数据日期')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.orc.OrcSerde' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_finance_sci_user_season_ma'
TBLPROPERTIES (
  'last_modified_by'='bigdata', 
  'last_modified_time'='1766629353', 
  'orc.compression'='snappy', 
  'transient_lastDdlTime'='1766629353')

