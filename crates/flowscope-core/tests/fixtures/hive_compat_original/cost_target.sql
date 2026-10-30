CREATE EXTERNAL TABLE `dw_conan_ads.ads_conan_service_try_order_cost_da`(
  `class_mode` string COMMENT '学科组合', 
  `class_mode_detail` string COMMENT '学科服务模式组合（如：英语标准/英语深度）', 
  `start_class_dt` string COMMENT '开课日期', 
  `is_end` string COMMENT '是否已结课', 
  `user_from` string COMMENT '一级渠道', 
  `ad_channel` string COMMENT '二级渠道', 
  `is_try_cpd` string COMMENT '是否为CPD体验课订单（1-是、0-否）', 
  `userid` string COMMENT 'userid', 
  `orderid` string COMMENT '体验课订单id', 
  `is_renewal_w2` string COMMENT '是否在W2D7前转化', 
  `renewal_orderid` string COMMENT '转化系统课订单id', 
  `ts_ratio` string COMMENT '人效', 
  `try_pmt_raw` string COMMENT '体验课支付金额（原始，未除税）', 
  `cpd_cost_raw` string COMMENT '业务版CPD成本（原始，未除税）', 
  `cac_cost_raw` string COMMENT '业务版获客成本（原始，未除税）', 
  `teacher_cost_raw` string COMMENT '业务版服务成本（原始，兼容保留）', 
  `book_cost_raw` string COMMENT '业务版随材成本（原始，未除税）', 
  `tax_rate` string COMMENT '税率', 
  `try_cac_factor` string COMMENT '获客成本系数（已废弃）', 
  `try_teacher_factor` string COMMENT '服务成本系数（已废弃）', 
  `try_book_factor` string COMMENT '随材税率', 
  `season_paidfee_raw` string COMMENT '转化系统课订单金额', 
  `try_pmt` string COMMENT '体验课支付金额（税率后）', 
  `cac_cost` string COMMENT '业务版获客成本（税率后）', 
  `cpd_cost` string COMMENT '业务版CPD成本（税率后）', 
  `teacher_cost` string COMMENT '业务版服务成本', 
  `book_cost` string COMMENT '业务版随材成本（税率后）', 
  `season_profit` string COMMENT '转化系统课订单利润', 
  `season_profit_raw` string COMMENT '转化系统课订单利润（不分摊单双重叠）', 
  `pay_dt` string COMMENT '支付日期（电商渠道为外部实际支付日期）', 
  `cac_fin_cost` string COMMENT '财务版获客成本（税后）', 
  `teacher_cost_checked` string COMMENT '财务版服务成本是否已固化（1=已固化，0=未固化，-1=不适用）', 
  `cac_cost_checked` string COMMENT '财务版获客成本是否已固化（1=已固化，0=未固化，-1=不适用）', 
  `teacher_fin_cost` string COMMENT '财务版服务成本', 
  `bj_fin_cost` string COMMENT '财务版运营成本', 
  `stage_name` string COMMENT '学科级别', 
  `end_class_dt` string COMMENT '结课日期', 
  `stage_name_comb` string COMMENT '学科级别组合', 
  `channel_price` string COMMENT '渠道价格带（中价/低价）', 
  `lesson_desc` string COMMENT '带班形式（单带/联带/中价/专项课）', 
  `service_mode` string COMMENT '服务模式（标准/深度/中价/虚拟）', 
  `bj_fin_cost_teacher` string COMMENT '财务版辅导运营成本', 
  `bj_fin_cost_acquisition` string COMMENT '财务版获客运营成本', 
  `book_fin_cost` string COMMENT '财务版随材成本（不含电商中价特殊随材）', 
  `cpd_fin_cost` string COMMENT '财务版CPD成本', 
  `try_net_profit` string COMMENT '业务版净收益（体验课收入-获客-CPD-服务-随材-运营）', 
  `try_net_fin_profit` string COMMENT '财务版净收益（体验课收入-获客-CPD-服务-随材-运营）', 
  `bj_cost_checked` int COMMENT '财务版运营成本是否已固化（1=已固化，0=未固化）', 
  `book_cost_checked` int COMMENT '财务版随材成本是否已固化（1=已固化，0=未固化，-1=不适用）', 
  `third_channel` string COMMENT '渠道细分，电商成本SKU或商务细分，未匹配NULL，电商适用未识别UNSET')
COMMENT 'AI课-体验课订单维度成本收益明细'
PARTITIONED BY ( 
  `dt` string)
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.ql.io.orc.OrcSerde' 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.orc.OrcOutputFormat'
LOCATION
  'hdfs://ky02/user/hive/warehouse/dw_conan_ads.db/ads_conan_service_try_order_cost_da'
TBLPROPERTIES (
  'last_modified_by'='maintain', 
  'last_modified_time'='1793267995', 
  'orc.compression'='SNAPPY', 
  'orc.force.positional.evolution'='true', 
  'transient_lastDdlTime'='1793267995')

