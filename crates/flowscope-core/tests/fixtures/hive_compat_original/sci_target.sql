CREATE EXTERNAL TABLE `dw_conan_ads.ads_finance_sci_season_pushed_left_ma`(
  `user_id` string COMMENT '用户ID', 
  `goods_type` string COMMENT '商品类型，根据用户购课时的状态分为首单系统课和续报课', 
  `stage_level` string COMMENT '级别', 
  `sale_method` string COMMENT '售卖方式', 
  `weekcount` bigint COMMENT '周', 
  `fee` string COMMENT '金额', 
  `confirm_type` string COMMENT '数据类型，0 确认，1 剩余')
COMMENT 'AI课-科学系统课用户分月确认'
PARTITIONED BY ( 
  `dt` string COMMENT '数据日期')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.mapred.TextInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_finance_sci_season_pushed_left_ma'
TBLPROPERTIES (
  'last_modified_by'='bigdata', 
  'last_modified_time'='1766629350', 
  'transient_lastDdlTime'='1766629350')

