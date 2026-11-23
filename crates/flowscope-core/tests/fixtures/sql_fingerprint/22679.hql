-- 百科用户 IP 累计：每行保留一次既有用户—IP 记录，延续昨日结果并追加当日日志，不新增去重。
-- set mapreduce.reduce.memory.mb=4096;
-- set mapreduce.map.memory.mb=2048;
-- set mapreduce.map.java.opts='-Xmx1848M';
-- set mapreduce.reduce.java.opts='-Xmx3896M';

SET mapreduce.reduce.memory.mb=4096;
SET mapreduce.map.memory.mb=2048;
SET mapreduce.map.java.opts='-Xmx1848M';
SET mapreduce.reduce.java.opts='-Xmx3896M';
SET hive.exec.parallel=true;
SET hive.exec.parallel.thread.number=5;

INSERT OVERWRITE TABLE dw_conan_dwd.dwd_conan_user_pedia_user_ip_info_da PARTITION(dt='${date}')

SELECT 
	user_id
    ,ip
-- 继承昨日累计记录，保持历史 UNION ALL 口径。
FROM dw_conan_dwd.dwd_conan_user_pedia_user_ip_info_da 
WHERE dt = date_sub('${date}',1)

UNION ALL 

SELECT 
    userid AS user_id
    ,ip
-- frog 分支继续保留既有首页、课包和任务列表等入口范围。
FROM dw_conan_ods.ods_pedia_frog 
WHERE dt = '${date}'
AND category IN ('expose','event')
AND page_tp IN ('H','L','M','c')
AND url IN ('/expose/HdHomepage/enter', '/expose/LessonList/enter','/expose/MissionList/enter','/event/conanapp/enter')
UNION ALL 
SELECT 
    userid AS user_id
    ,other['ip'] AS ip
-- request 解析表昨日已改名，仅替换物理表名，保留 userid 与 other 中的 IP。
FROM dw_conan_ods.ods_pedia_request_di
WHERE dt = '${date}'
