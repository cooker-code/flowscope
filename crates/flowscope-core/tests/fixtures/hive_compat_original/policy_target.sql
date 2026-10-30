CREATE TABLE `dw_conan_ads.tmp_biz1_cpa_order_settlement_policy`(
  `target_cohort` date, 
  `snapshot_dt` date, 
  `source_cohort` date, 
  `order_id` string, 
  `user_id` string, 
  `order_status` string, 
  `subject` string, 
  `pay_dt` string, 
  `pay_tp` string, 
  `pay_amt` decimal(28,8), 
  `keyfrom` string, 
  `semester_type` string, 
  `platform_5` string, 
  `platform_5_6` string, 
  `type` string, 
  `season_order_id` string, 
  `season_refund_type` string, 
  `season_pay_dt` date, 
  `season_pay_tp` string, 
  `end_xb_dt` date, 
  `is_no_settle` string, 
  `authorid` string, 
  `contract_type` string, 
  `platform_name` string, 
  `policy_keyfrom` string, 
  `party_b` string, 
  `contract_code` string, 
  `contract_code_raw` string, 
  `ori_sign_date` string, 
  `is_normal` string, 
  `is_tmk` string, 
  `is_bollte_allowance` string, 
  `is_max_allowance` string, 
  `is_ka` string, 
  `deduction_amount` decimal(28,8), 
  `excluded_commission` decimal(28,8), 
  `policy_match_status` string, 
  `policy_candidate_count` bigint, 
  `candidate_platform_names` string, 
  `source_variant_count` bigint, 
  `source_family` string, 
  `late_renewal_cleared` int)
COMMENT '商务一组CPA周度生产计算中间表；同一任务串行覆盖，非用户最终结果表'
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/tmp_biz1_cpa_order_settlement_policy'
TBLPROPERTIES (
  'transient_lastDdlTime'='1792564988')

