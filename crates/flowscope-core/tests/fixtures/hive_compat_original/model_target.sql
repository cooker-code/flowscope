CREATE TABLE `temp.tmk_bpo_new_stock_model_2_0_sql_param_da`(
  `model_version` string COMMENT '模型版本', 
  `model_stage` string COMMENT '模型阶段：connect/d7_given_connect/shared/ranking', 
  `param_type` string COMMENT '参数类型', 
  `feature_name` string COMMENT '特征名或参数名', 
  `feature_value` string COMMENT '类别原值或规则取值', 
  `mapped_value` string COMMENT '类别映射后的独热桶', 
  `raw_coefficient` double COMMENT 'sklearn变换后空间的原始系数', 
  `effective_coefficient` double COMMENT '换算到原数值尺度后的系数', 
  `impute_value` string COMMENT '缺失填充值', 
  `scale_value` double COMMENT '数值标准化除数', 
  `param_value` double COMMENT '阈值或策略数值', 
  `param_text` string COMMENT '公式、方法或策略文本', 
  `sort_order` int COMMENT '特征或类别顺序', 
  `training_start_dt` string COMMENT '训练范围开始日', 
  `training_end_dt` string COMMENT '训练范围结束日', 
  `created_at` string COMMENT '参数生成时间')
COMMENT 'BPO新客存量模型2.0 SQL每日评分参数表'
PARTITIONED BY ( 
  `dt` string COMMENT '模型发布日期')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
  'hdfs://ky01/user/hive/warehouse/temp.db/tmk_bpo_new_stock_model_2_0_sql_param_da'
TBLPROPERTIES (
  'transient_lastDdlTime'='1788949840')

