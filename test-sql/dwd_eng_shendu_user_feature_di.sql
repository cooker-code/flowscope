
set spark.driver.memory=16g;
set spark.driver.cores=1;
set spark.executor.memory=8g;
set spark.executor.cores=2;
INSERT OVERWRITE TABLE dw_conan_dwd.dwd_eng_shendu_user_feature_di partition(dt = '${date}')
WITH all_user AS
(select start_class_dt,
 userid,
 orderid,
 lesson_id,
	        is_age_match,
	        user_city,
	        age_buy_lesson,
	        label_stage_name,
	        stage_name,
	        semesterid,
	        user_from,
	        ad_channel,
	        refer_userid,
	        semester_tag,
	        paid_dt,
	        ldap,
	        try_tp,
 if(user_city_type='未设置',city_type,user_city_type) as user_city_type,
 if(user_city_type='未设置',city_type_2,user_city_type_2) as user_city_type_2
 from 
	(SELECT  start_class_dt,
	        user_id AS userid,
	        order_id AS orderid,
	        lesson_id,
	        is_age_match,
	        user_city,
	        age_buy_lesson,
	        concat('英语',stage_name) AS label_stage_name,
	        stage_name,
	        semester_id AS semesterid,
	        user_from,
	        ad_channel,
	        split(keyfrom,'-')[1] AS refer_userid,
	        experiment_tag AS semester_tag,
	        pay_dt AS paid_dt,
	        teacher_ldap AS ldap,
	        cast(pay_tp AS bigint) try_tp,
	        user_city_type,
     user_city,
	        CASE WHEN user_city IN ('上海','北京','黑河','黄山','鹰潭','舟山','普洱','马鞍山','宣城','恩施土家族苗族自治州','西宁','台州','哈密','湖州','钦州','张家界','杭州','贺州','广元','阳泉','鄂州','绍兴','深圳','达州','朔州') THEN 'S'
	             WHEN user_city IN ('衢州','衡水','鹤壁','苏州','扬州','天津','无锡','株洲','塔城地区','酒泉','烟台','滁州','广州','珠海','南京','青岛','自治区直辖县级行政区划','东营','新乡','温州','鄂尔多斯','泸州','安庆','德阳','宜昌','清远','宁波','哈尔滨','通辽','成都','合肥','大同','凉山彝族自治州') THEN 'A'
	             WHEN user_city IN ('延安','福州','黔南布依族苗族自治州','延边朝鲜族自治州','南通','上饶','新余','厦门','西安','武汉','金华','丽水','韶关','三亚','攀枝花','承德','白山','兰州','许昌','自贡','西双版纳傣族自治州','宿州','三明','廊坊','南平','济宁','昆明','佛山','荆州','潮州','盐城','吴忠','柳州','济南','泰州','唐山','来宾','咸宁','巴音郭楞蒙古自治州','安阳','乌兰察布','巴中','乌鲁木齐','南昌','忻州','榆林','汉中','重庆','濮阳','海口','儋州','宁德','百色','临沂','漳州','安康','吉林','湘潭','遵义','郑州','雅安','镇江','开封','乌海','咸阳','池州','吉安','喀什地区','衡阳','连云港','常州','东莞','呼和浩特','嘉兴','抚州') THEN 'B'
	             WHEN user_city IN ('石家庄','宝鸡','桂林','防城港','岳阳','蚌埠','玉溪','亳州','长春','邢台','辽源','江门','固原','迪庆藏族自治州','大庆','朝阳','本溪','绵阳','长沙','沧州','伊犁哈萨克自治州','四平','泉州','昭通','陇南','眉山','阿拉善盟','淄博','保定','大理白族自治州','六安','威海','拉萨','抚顺','德宏傣族景颇族自治州','省直辖县级行政区划','盘锦','徐州','红河哈尼族彝族自治州','中山','黔西南布依族苗族自治州','临沧','县','张家口','景德镇','大连','贵阳','邵阳','牡丹江','荆门','海西蒙古族藏族自治州','包头','阜阳','赤峰','铜川','阿坝藏族羌族自治州','驻马店','龙岩','太原','长治','洛阳','楚雄彝族自治州','周口','博尔塔拉蒙古自治州','白城','南宁','锡林郭勒盟','赣州','银川','平凉','秦皇岛','运城','汕头','南阳','芜湖','遂宁','齐齐哈尔','保山','肇庆','宿迁','资阳','黄石','晋城','绥化','佳木斯','乐山','晋中','常德','呼伦贝尔','梅州','三门峡','平顶山','惠州','和田地区','毕节','渭南','商洛','内江','焦作','曲靖','淮安','沈阳','永州','泰安','随州','克拉玛依','河池','安顺','阿勒泰地区','莆田','巴彦淖尔','滨州','六盘水','德州','中卫','信阳','吐鲁番','淮南','阿克苏地区') THEN 'C'  ELSE 'D' END AS user_city_type_2
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
	WHERE dt = '${date}'
	AND is_bundled = '单带'
	AND subject_id = 1
  and lesson_id=126
	AND ( start_class_dt = next_day(date_add('${date}', 1), 'MO') OR ( start_class_dt = next_day(date_add('${date}', 8), 'MO') AND NOT EXISTS (
	SELECT  1
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da t2
	WHERE t2.dt = '${date}'
	AND t2.is_bundled = '单带'
	AND t2.subject_id = 1
	AND t2.start_class_dt = next_day(date_add('${date}', 1), 'MO') ) ) OR ( start_class_dt = next_day(date_add('${date}', 15), 'MO') AND NOT EXISTS (
	SELECT  1
	FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da t3
	WHERE t3.dt = '${date}'
	AND t3.is_bundled = '单带'
	AND t3.subject_id = 1
	AND ( t3.start_class_dt = next_day(date_add('${date}', 1), 'MO') OR t3.start_class_dt = next_day(date_add('${date}', 8), 'MO') ) ) ) ) AND experiment_tag not LIKE '%A%')a 
  left join 
  (
    select user_id,
    CASE WHEN city IN ('上海','北京','黑河','黄山','鹰潭','舟山','普洱','马鞍山','宣城','恩施土家族苗族自治州','西宁','台州','哈密','湖州','钦州','张家界','杭州','贺州','广元','阳泉','鄂州','绍兴','深圳','达州','朔州') THEN 'S'
	             WHEN city IN ('衢州','衡水','鹤壁','苏州','扬州','天津','无锡','株洲','塔城地区','酒泉','烟台','滁州','广州','珠海','南京','青岛','自治区直辖县级行政区划','东营','新乡','温州','鄂尔多斯','泸州','安庆','德阳','宜昌','清远','宁波','哈尔滨','通辽','成都','合肥','大同','凉山彝族自治州') THEN 'A'
	             WHEN city IN ('延安','福州','黔南布依族苗族自治州','延边朝鲜族自治州','南通','上饶','新余','厦门','西安','武汉','金华','丽水','韶关','三亚','攀枝花','承德','白山','兰州','许昌','自贡','西双版纳傣族自治州','宿州','三明','廊坊','南平','济宁','昆明','佛山','荆州','潮州','盐城','吴忠','柳州','济南','泰州','唐山','来宾','咸宁','巴音郭楞蒙古自治州','安阳','乌兰察布','巴中','乌鲁木齐','南昌','忻州','榆林','汉中','重庆','濮阳','海口','儋州','宁德','百色','临沂','漳州','安康','吉林','湘潭','遵义','郑州','雅安','镇江','开封','乌海','咸阳','池州','吉安','喀什地区','衡阳','连云港','常州','东莞','呼和浩特','嘉兴','抚州') THEN 'B'
	             WHEN city IN ('石家庄','宝鸡','桂林','防城港','岳阳','蚌埠','玉溪','亳州','长春','邢台','辽源','江门','固原','迪庆藏族自治州','大庆','朝阳','本溪','绵阳','长沙','沧州','伊犁哈萨克自治州','四平','泉州','昭通','陇南','眉山','阿拉善盟','淄博','保定','大理白族自治州','六安','威海','拉萨','抚顺','德宏傣族景颇族自治州','省直辖县级行政区划','盘锦','徐州','红河哈尼族彝族自治州','中山','黔西南布依族苗族自治州','临沧','县','张家口','景德镇','大连','贵阳','邵阳','牡丹江','荆门','海西蒙古族藏族自治州','包头','阜阳','赤峰','铜川','阿坝藏族羌族自治州','驻马店','龙岩','太原','长治','洛阳','楚雄彝族自治州','周口','博尔塔拉蒙古自治州','白城','南宁','锡林郭勒盟','赣州','银川','平凉','秦皇岛','运城','汕头','南阳','芜湖','遂宁','齐齐哈尔','保山','肇庆','宿迁','资阳','黄石','晋城','绥化','佳木斯','乐山','晋中','常德','呼伦贝尔','梅州','三门峡','平顶山','惠州','和田地区','毕节','渭南','商洛','内江','焦作','曲靖','淮安','沈阳','永州','泰安','随州','克拉玛依','河池','安顺','阿勒泰地区','莆田','巴彦淖尔','滨州','六盘水','德州','中卫','信阳','吐鲁番','淮南','阿克苏地区') THEN 'C'  ELSE 'D' END AS city_type_2,
    if(city_type='unset','未设置',city_type) as city_type
    from dw_dim.dim_eng_user_subject_address_da
    where dt = '${date}'
    and address_type_cd=3
  )b on a.userid=b.user_id
) , qinyouka AS
(
	SELECT  a.userid,
	        semesterid,
	        a.start_class_dt,
	        if(b.userid is not null,1,0) AS is_same,
	        subject_num
	FROM all_user a
	LEFT JOIN
	(
		SELECT  distinct user_id AS userid
		FROM dw_conan_ads.ads_course_season_user_class_week_all_info_da
		WHERE dt = '${date}'
		AND subject_id IN (1)
		AND week_dt >= next_day(date_add('${date}', 15), 'MO') 
	)b
	ON a.refer_userid = b.userid AND a.ad_channel = '亲友卡'
	LEFT JOIN
	( -- 实际领课的用户数 据
		SELECT  user_id,
		        start_class_dt,
		        COUNT(distinct subject_id) AS subject_num
		FROM dw_conan_ads.ads_service_try_double_user_quality_detail_da
		WHERE dt = '${date}'
		AND ad_channel = '亲友卡'
		AND is_bundled = '单带'
		GROUP BY  user_id,
		          start_class_dt
	)c
	ON a.userid = c.user_id AND a.start_class_dt = c.start_class_dt AND a.ad_channel = '亲友卡'
), zhaohui AS
(
	SELECT  a.userid,
	        a.start_class_dt,
	        semesterid,
	        CASE WHEN semester_type IN ('try_double','fourweek') THEN '双周课'
	             WHEN semester_type IN ('try_refer') THEN '单周课'
	             WHEN semester_type IN ('season') THEN '系统课'
	             WHEN semester_type IN ('try')THEN '素质体验课'  ELSE '其他' END AS semester_type
	FROM
	(
		SELECT  a.userid,
		        a.start_class_dt,
		        semesterid,
		        a.paid_dt,
		        semester_type,
		        ROW_NUMBER()over(PARTITION BY a.userid,a.start_class_dt ORDER BY  b.pay_dt DESC,b.subject_id ASC) AS rk
		FROM all_user a
		LEFT JOIN
		(
			SELECT  user_id,
			        order_id,
			        semester_type,
			        pay_dt,
			        subject_name,
			        subject_id
			FROM dw_dwd.dwd_eng_order_course_detail_da
			WHERE dt = '${date}'
			AND (semester_type IN ('season', 'try_double', 'fourweek', 'try_refer') or (semester_type IN ('try') AND subject_id IN (4, 5, 7, 8)))
			AND order_status = 2 
		)b
		ON a.userid = b.user_id AND b.pay_dt < a.paid_dt AND a.user_from = '召回'
	)a
	WHERE rk = 1 
), kuoke AS
(
	SELECT  start_class_dt,
	        semesterid,
	        userid,
	        CASE WHEN ad_channel = '加赠扩科' AND user_from_desc is not null THEN concat('加赠扩科-',user_from_desc)
	             WHEN ad_channel = '加赠扩科' AND user_from_desc is null THEN '加赠扩科-其他'  ELSE ad_channel END AS user_from_desc
	FROM
	(
		SELECT  a.start_class_dt,
		        a.userid,
		        user_from_desc,
		        ad_channel,
		        semesterid,
		        ROW_NUMBER() over(PARTITION BY a.userid,a.start_class_dt ORDER BY  b.long_tp DESC) AS rk --取符合日期范围内的最后一单系统课作为赠课来源 
		FROM all_user a
		LEFT JOIN
		(
			SELECT  user_id AS userid,
			        order_id,
			        pay_dt,
			        cast(pay_tp AS bigint) long_tp
			FROM dw_dwd.dwd_eng_order_course_detail_da
			WHERE dt = '${date}'
			AND semester_type = 'season'
			AND order_status = '2' 
		) b
		ON a.userid = b.userid AND b.long_tp < a.try_tp AND (b.pay_dt BETWEEN date_sub(a.paid_dt, 7) AND a.paid_dt) AND a.ad_channel = '加赠扩科'
		LEFT JOIN
		(
			SELECT  order_id AS orderid,
			        CASE WHEN user_from_desc LIKE '长续长%' or user_from_desc LIKE '长扩长%' THEN '长续长扩科'
			             WHEN user_from_desc LIKE '体验课转化%' or user_from_desc LIKE '导流课转化%' THEN '体续长扩科'  ELSE '其他' END AS user_from_desc
			FROM dw_conan_ads.ads_conan_season_order_from_info_da
			WHERE dt = '${date}' 
		)c
		ON b.order_id = c.orderid
	)a
	WHERE rk = 1 
)
SELECT  a.start_class_dt,
        a.userid,
        a.semesterid,
        lesson_id as lessonid,
        start_stage_id as stageid,
        semester_label,
        a.stage_name,
        coalesce(a.age_buy_lesson,-1) AS age_buy_lesson,
        CASE WHEN is_age_match = 1 THEN '适龄'
             WHEN age_buy_lesson = '未设置' THEN '未设置'
             WHEN stage_name = 'S1' AND age_buy_lesson < 2 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S1' AND age_buy_lesson >= 4 THEN '高龄'
             WHEN stage_name = 'S2' AND age_buy_lesson < 4 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S2' AND age_buy_lesson >= 6 THEN '高龄'
             WHEN stage_name = 'S3' AND age_buy_lesson < 6 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S3' AND age_buy_lesson >= 8 THEN '高龄'  ELSE '未设置' END AS is_age_match,
        a.user_city,
        a.user_city_type,
        user_city_type_2,
        CASE WHEN user_from = '召回' THEN concat('召回-',semester_type)  ELSE user_from END AS user_from,
        CASE WHEN ad_channel = '亲友卡' AND is_same = 1 THEN concat('亲友卡-同科推荐-领取',subject_num,'科')
             WHEN ad_channel = '亲友卡' AND is_same = 0 THEN concat('亲友卡-非同科推荐-领取',subject_num,'科')
             WHEN ad_channel = '亲友卡' THEN '亲友卡-其他'
             WHEN ad_channel = '加赠扩科' THEN user_from_desc  ELSE ad_channel END AS ad_channel,
        MAX(if(label_category_show_name = '教育支出',label_show_name,null)) AS jiaoyu,
        MAX(if(label_category_show_name = '英语规划',label_show_name,null)) AS guihua,
        MAX(if(label_category_show_name = '英语基础',label_show_name,null)) AS jichu
FROM all_user a
LEFT JOIN qinyouka b
ON a.userid = b.userid AND a.semesterid = b.semesterid
LEFT JOIN zhaohui c
ON a.userid = c.userid AND a.semesterid = c.semesterid
LEFT JOIN kuoke d
ON a.userid = d.userid AND a.semesterid = d.semesterid
LEFT JOIN
(
	SELECT  semester_id,
	        start_stage_id,
	        semester_label
	FROM dw_dim.dim_eng_semester_da
	WHERE dt = '${date}' 
)t
ON a.semesterid = t.semester_id
LEFT JOIN
(
	SELECT  user_id,
	        top_label_show_name AS label_one_class_show_name,
	        second_label_show_name AS label_second_class_show_name,
	        third_label_show_name AS label_category_show_name,
	        fourth_label_show_name AS label_show_name
	FROM dw_conan_dwd.dwd_conan_service_peace_task_user_label_new_da
	WHERE dt = '${date}'
	AND is_fourth_valid = '1'
	AND is_third_valid = '1'
	AND is_second_valid = '1'
	AND lesson_type = 'experience'
	AND top_label_show_name != '转化影响因素'
	AND third_label_show_name IN ('教育支出', '英语规划', '英语基础') 
)j
ON a.userid = j.user_id AND (j.label_second_class_show_name = '通用' or j.label_second_class_show_name = a.label_stage_name) --对应学科展示 
GROUP BY  a.start_class_dt,
          a.userid,
          a.semesterid,
          lesson_id ,
        start_stage_id ,
        semester_label,
          a.stage_name,
          coalesce(a.age_buy_lesson,-1),
          CASE WHEN is_age_match = 1 THEN '适龄'
             WHEN age_buy_lesson = '未设置' THEN '未设置'
             WHEN stage_name = 'S1' AND age_buy_lesson < 2 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S1' AND age_buy_lesson >= 4 THEN '高龄'
             WHEN stage_name = 'S2' AND age_buy_lesson < 4 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S2' AND age_buy_lesson >= 6 THEN '高龄'
             WHEN stage_name = 'S3' AND age_buy_lesson < 6 AND age_buy_lesson >= 0 THEN '低龄'
             WHEN stage_name = 'S3' AND age_buy_lesson >= 8 THEN '高龄'  ELSE '未设置' END,
          a.user_city,
          a.user_city_type,
          user_city_type_2,
          CASE WHEN user_from = '召回' THEN concat('召回-',semester_type)  ELSE user_from END,
          CASE WHEN ad_channel = '亲友卡' AND is_same = 1 THEN concat('亲友卡-同科推荐-领取',subject_num,'科')
             WHEN ad_channel = '亲友卡' AND is_same = 0 THEN concat('亲友卡-非同科推荐-领取',subject_num,'科')
             WHEN ad_channel = '亲友卡' THEN '亲友卡-其他'
             WHEN ad_channel = '加赠扩科' THEN user_from_desc  ELSE ad_channel END
