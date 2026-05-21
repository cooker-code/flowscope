select distinct a.user_id as user_id
		,a.ped_status as ped_status
		,case when b.user_id is not null then '已购买'
		else '未购买' end as is_buy
		,c.externaluserid as externaluserid
from 
	(select distinct a.user_id,coalesce(b.ped_status,'未购用户') as ped_status
	from 
		(select substr(dbctime,1,10) as reserve_dt,user_id
		from dw_conan_ods.ods_conan_pedia_growth_user_pre_order_record_da
		where dt= date_sub(current_date,1)
		and pre_order_sale_id='{{{pre_order_sale_id}}}'
		and substr(dbctime,1,10) between '{{{reserve_start_dt}}}' and '{{{reserve_end_dt}}}'
		group by substr(dbctime,1,10),user_id
		) a 
	left join 
		(SELECT distinct dt,user_id,ped_status,curr_vip_type
		FROM dw_conan_dim.dim_conan_user_pedia_user_da
		where dt between date_sub('{{{reserve_start_dt}}}',1) and date_sub('{{{reserve_end_dt}}}',1)
		) b 
	on a.user_id=b.user_id
	and datediff(a.reserve_dt,b.dt)=1
	) a 
left join 
 	(-- 成单
	        select
	            user_id
	            ,pay_tp
	            ,pay_dt
	            ,date_sub(next_day(pay_dt,'MO'),7)as pay_zhou
	            ,spuname
	            ,spuid
	            ,if(keyfrom=''or keyfrom is null,'zebra-mall',keyfrom)as keyfrom     -- 斑马商城回填统一keyfrom
	        from dw_conan_dwd.dwd_pedia_derivative_order_info_da
	        where dt = date_sub(current_date,1)
	        and is_test_user = 0
	        and (pay_amt >0 or (pay_amt=0 and keyfrom is null )
	                        or (pay_amt=0 and keyfrom not like '%tansuo2%' ))                                                                    
	        and order_status_cd=2          
	        and refund_dt is null
	        and spuname like '%{{{spuname}}}%'                
	)b on a.user_id=b.user_id
left join 
	(--externaluserid
	SELECT DISTINCT a1.dt 
            	,coalesce(a3.userid, a4.userid, '未知') AS userid, externaluserid
                , DEFAULT.time2dt(addedtime) AS addedtime, addedtime AS addtp
                , a1.unionid, split(state, '-')[2] AS channelid
                , a1.vid, a1.remoteid 
            FROM (
                SELECT dt, externaluserid, userid AS add_userid, addedtime, remoteid
                    , unionid, state, vid 
                FROM dw_ods.ods_dora_emon_customer_customer_da_da
                WHERE dt = date_sub(current_date,1)
                    AND status = 1
            ) a1
                LEFT JOIN (
                    SELECT DISTINCT dt,union_id AS unionid, user_id AS userid
                    FROM dw_conan_ods.ods_conan_fenbi_weixin_app_profile_da
                    WHERE dt = date_sub(current_date,1)
                        AND union_id IS NOT NULL
                        AND union_id NOT IN ('', ' ', '0')
                        AND user_id IS NOT NULL
                        AND app_id IN ('wx08a38e2646380ba2', 'wx354444248884b9fb')
                        AND user_id != '0'
                ) a3
                ON a1.unionid = a3.unionid
                LEFT JOIN (
                    SELECT userwechatid, userid
                    FROM dw_ori.conan_mentor_work_efficiency_teacher_user_class_relation_da
                ) a4
                ON a1.externaluserid = a4.userwechatid
	) c 
on a.user_id=c.userid