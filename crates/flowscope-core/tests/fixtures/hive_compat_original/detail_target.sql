CREATE TABLE `dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da`(
  `order_id` string COMMENT '子订单ID', 
  `order_status` string COMMENT '事实快照下订单状态；以fact_snapshot_dt为准，历史与周度版本保留各自口径', 
  `skill_estimated_settlement_amount` decimal(28,8) COMMENT '未税完整预估：skill近4期→同政策→石墨→缺失率严格小于3%同SKU均值；税率/含税属性不明NULL', 
  `actual_settlement_amount` decimal(28,8) COMMENT '账单应付总额按整账单正常子单分摊后除税；不筛付款成功；不是支付金额', 
  `subject_name` string COMMENT '子订单实际科目：英语/思维/阅读；英思购买组合另列', 
  `parent_order_id` string COMMENT '父订单ID，仅追溯不用于子单金额再次乘2', 
  `purchase_group` string COMMENT '购买商品组合，例如英思', 
  `estimated_cost_source` string COMMENT '预估计算来源', 
  `estimated_cost_gross` decimal(28,8) COMMENT '原价预估；含石墨税基未知价格，仅追溯', 
  `actual_cost_gross` decimal(28,8) COMMENT '账单原额分摊值', 
  `estimated_tax_rate` decimal(10,6) COMMENT '预估除税所用税率，未知NULL', 
  `actual_tax_rate` decimal(10,6) COMMENT '账单关联付款申请税率，未知NULL', 
  `estimated_cost_status` string COMMENT '预估未税金额可用性及待确认原因', 
  `actual_cost_status` string COMMENT '账单分摊及除税可用性', 
  `bill_id` string COMMENT '唯一匹配账单ID', 
  `tax_rate_source` string COMMENT '预估税率证据来源', 
  `fact_snapshot_dt` string COMMENT '原计算事实分区；历史保持原值，周度新增为结课周日', 
  `calculation_version` string COMMENT '算法及冻结税率版本', 
  `channel_type` string COMMENT 'YXZZ渠道类型；源表多映射时按订单取其中一条', 
  `third_channel` string COMMENT 'YXZZ第三方渠道；源表多映射时按订单取其中一条')
COMMENT '商务一组CPA订单结算成本生产表：未税预估及账单应付分摊，不等于最终财务审批结果'
PARTITIONED BY ( 
  `dt` string COMMENT '全量归档快照日期；每次仅查询一个成功快照', 
  `start_class_dt` string COMMENT '开课日期')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_biz1_cpa_order_settlement_cost_detail_da'
TBLPROPERTIES (
  'last_modified_by'='maintain', 
  'last_modified_time'='1793183912', 
  'transient_lastDdlTime'='1793183912')

