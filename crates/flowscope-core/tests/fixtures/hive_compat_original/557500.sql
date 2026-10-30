/**
 * SCI 任务 B：以原生 Spark SQL 替换冻结 Python 2.7 的整段分配计算。
 * 依赖：任务 A 同账期成功；输出表、七列顺序及 dt 分区不变。
 * 兼容范围：2019-07-01 起的常规分支；无 PHP、Python UDF、外部 TRANSFORM。
 * 保留原金额求和顺序、舍入位置、零行/重复行、隔离分支和历史大纲行为。
 */
SET spark.sql.ansi.enabled=true;
SET spark.sql.analyzer.maxIterations=300;

INSERT OVERWRITE TABLE dw_conan_ads.ads_finance_sci_season_pushed_left_ma PARTITION(dt='${date}')
WITH source_input AS (
    SELECT a.user_id, a.order_list,
        a.cur_total_weekcount,a.cur_left_weekcount,a.cur_get_weekcount,a.cur_refund_weekcount,
        a.last_total_weekcount,a.last_left_weekcount,a.receipt_list,
        a.settled_weekcount,a.settled_fee,a.first_level,a.level_weeks
    FROM dw_conan_ads.ads_finance_sci_user_season_ma a WHERE a.dt='${date}'
), parsed AS (
    SELECT *,
        transform(order_list, p -> named_struct(
            'fee', CAST(element_at(split(p,'&'),1) AS DOUBLE),
            'weeks', CAST(element_at(split(p,'&'),2) AS INT),
            'sale', element_at(split(p,'&'),3),
            'goods', CASE element_at(split(p,'&'),4) WHEN '0' THEN '首单系统课' WHEN 'unset' THEN '赠课' ELSE '续报课' END
        )) AS periods,
        transform(receipt_list, c -> split(c,'&')) AS classes,
        CAST(cur_total_weekcount AS INT) - CAST(cur_left_weekcount AS INT) AS pushed_weekcount,
        CAST(last_left_weekcount AS INT) + CAST(cur_get_weekcount AS INT) + CAST(cur_refund_weekcount AS INT) AS deferred_initial,
        CAST(settled_weekcount AS INT) AS settled_weeks,
        CAST(settled_fee AS DOUBLE) AS settled_amount
    FROM source_input
), totals AS (
    SELECT *,
        aggregate(periods, 0, (a,p) -> a+p.weeks) AS total_weeks,
        aggregate(periods, 0D, (a,p) -> a+p.fee) AS total_fee,
        deferred_initial AS deferred_weeks
    FROM parsed
), balance AS (
    SELECT *, total_fee-settled_amount AS deferred_fee,
        deferred_weeks<=0 OR settled_weeks>=total_weeks AS cumulative_branch,
        cur_get_weekcount=0 AND cur_refund_weekcount=0 AND CAST(cur_total_weekcount AS INT)=CAST(last_total_weekcount AS INT) AND CAST(cur_left_weekcount AS INT)=CAST(last_left_weekcount AS INT) AS frozen_history
    FROM totals
), state AS (
    SELECT *,
        CASE WHEN cumulative_branch THEN pushed_weekcount-settled_weeks ELSE deferred_weeks-CAST(cur_left_weekcount AS INT) END AS push_before_cap,
        CASE WHEN cumulative_branch THEN total_weeks-pushed_weekcount ELSE CAST(cur_left_weekcount AS INT) END AS base_left_weeks,
        CASE WHEN cumulative_branch THEN settled_weeks ELSE CAST(last_total_weekcount AS INT)-CAST(last_left_weekcount AS INT) END AS temp_settled
    FROM balance
) , capped_state AS (
    SELECT *, CASE WHEN size(classes)>0 THEN least(push_before_cap,size(classes)) ELSE push_before_cap END AS push_cap
    FROM state WHERE CAST(deferred_fee AS BIGINT)<>0
), fee_raw AS (
    SELECT *, CASE WHEN size(classes)=0 THEN 0D
        WHEN cumulative_branch AND total_weeks=0 THEN deferred_fee
        WHEN cumulative_branch THEN total_fee/total_weeks*pushed_weekcount-settled_amount
        ELSE deferred_fee/deferred_weeks*push_cap END AS raw_push_fee
    FROM capped_state
),

push_round_bits AS (
    SELECT *, raw_push_fee AS push_round_raw,
        CAST(reflect('java.lang.Double', 'doubleToLongBits', abs(raw_push_fee)) AS BIGINT) AS push_round_bits
    FROM fee_raw
), push_round_ratio AS (
    SELECT *,
        CAST(pmod(push_round_bits, 4503599627370496L) + 4503599627370496L AS DECIMAL(38,0)) * 10000 AS push_round_num,
        CASE WHEN abs(push_round_raw) >= 0.00005D AND abs(push_round_raw) < 1099511627776D THEN
            CASE WHEN 1075 - CAST(shiftrightunsigned(push_round_bits,52) AS INT) <= 62
                THEN CAST(shiftleft(1L,1075-CAST(shiftrightunsigned(push_round_bits,52) AS INT)) AS DECIMAL(38,0))
                ELSE CAST(shiftleft(1L,1070-CAST(shiftrightunsigned(push_round_bits,52) AS INT)) AS DECIMAL(38,0))*32 END
            ELSE CAST(1 AS DECIMAL(38,0)) END AS push_round_den
    FROM push_round_bits
), push_round_division AS (
    SELECT *, CASE WHEN abs(push_round_raw) >= 0.00005D AND abs(push_round_raw) < 1099511627776D
        THEN CAST(push_round_num DIV push_round_den AS DECIMAL(38,0)) ELSE CAST(0 AS DECIMAL(38,0)) END AS push_round_quot
    FROM push_round_ratio
), push_round_rounded AS (
    SELECT *, CASE
        WHEN abs(push_round_raw) < 0.00005D THEN 0D
        WHEN abs(push_round_raw) >= 1099511627776D THEN push_round_raw
        ELSE sign(push_round_raw) * CAST(
            (push_round_quot + CASE WHEN (push_round_num - push_round_quot * push_round_den) * 2 >= push_round_den THEN 1 ELSE 0 END)
            / CAST(10000 AS DECIMAL(5,0)) AS DOUBLE)
        END AS rounded_push_fee
    FROM push_round_division
),
eligible AS (
    SELECT *,
        CASE WHEN size(classes)>0 AND cumulative_branch THEN rounded_push_fee ELSE raw_push_fee END AS push_fee,
        CASE WHEN size(classes)>0 THEN push_cap ELSE push_before_cap END AS push_weeks,
        CASE WHEN size(classes)=0 AND push_before_cap<>0 THEN base_left_weeks+push_before_cap ELSE base_left_weeks END AS left_weeks
    FROM push_round_rounded
    WHERE NOT (size(classes)>0 AND frozen_history AND (
        push_before_cap>size(classes)
    ))
), checked AS (
    SELECT *,
        CASE WHEN size(periods)>0 THEN periods ELSE raise_error('SCI: empty order_list') END AS valid_periods,
        CASE WHEN size(classes)=0 THEN CAST(array() AS ARRAY<STRING>)
            WHEN push_weeks<0 THEN array_repeat(element_at(element_at(classes,-1),2), -push_weeks)
            WHEN push_weeks=0 THEN transform(classes,c -> element_at(c,2))
            ELSE transform(slice(classes,greatest(1,size(classes)-push_weeks+1),push_weeks),c -> element_at(c,2)) END AS push_levels
    FROM eligible
),

left_round_bits AS (
    SELECT *, deferred_fee-push_fee AS left_round_raw,
        CAST(reflect('java.lang.Double', 'doubleToLongBits', abs(deferred_fee-push_fee)) AS BIGINT) AS left_round_bits
    FROM checked
), left_round_ratio AS (
    SELECT *,
        CAST(pmod(left_round_bits, 4503599627370496L) + 4503599627370496L AS DECIMAL(38,0)) * 10000 AS left_round_num,
        CASE WHEN abs(left_round_raw) >= 0.00005D AND abs(left_round_raw) < 1099511627776D THEN
            CASE WHEN 1075 - CAST(shiftrightunsigned(left_round_bits,52) AS INT) <= 62
                THEN CAST(shiftleft(1L,1075-CAST(shiftrightunsigned(left_round_bits,52) AS INT)) AS DECIMAL(38,0))
                ELSE CAST(shiftleft(1L,1070-CAST(shiftrightunsigned(left_round_bits,52) AS INT)) AS DECIMAL(38,0))*32 END
            ELSE CAST(1 AS DECIMAL(38,0)) END AS left_round_den
    FROM left_round_bits
), left_round_division AS (
    SELECT *, CASE WHEN abs(left_round_raw) >= 0.00005D AND abs(left_round_raw) < 1099511627776D
        THEN CAST(left_round_num DIV left_round_den AS DECIMAL(38,0)) ELSE CAST(0 AS DECIMAL(38,0)) END AS left_round_quot
    FROM left_round_ratio
), left_round_rounded AS (
    SELECT *, CASE
        WHEN abs(left_round_raw) < 0.00005D THEN 0D
        WHEN abs(left_round_raw) >= 1099511627776D THEN left_round_raw
        ELSE sign(left_round_raw) * CAST(
            (left_round_quot + CASE WHEN (left_round_num - left_round_quot * left_round_den) * 2 >= left_round_den THEN 1 ELSE 0 END)
            / CAST(10000 AS DECIMAL(5,0)) AS DOUBLE)
        END AS left_fee
    FROM left_round_division
),
start_search AS (
    SELECT *,
        aggregate(transform(valid_periods,(p,i) -> named_struct('weeks',p.weeks,'idx',i)),
            named_struct('remaining',temp_settled,'found',false,'idx',0,'capacity',element_at(valid_periods,1).weeks-temp_settled),
            (a,p) -> CASE WHEN a.found THEN a
                WHEN a.remaining<p.weeks THEN named_struct('remaining',a.remaining,'found',true,'idx',p.idx,'capacity',p.weeks-a.remaining)
                ELSE named_struct('remaining',a.remaining-p.weeks,'found',false,'idx',a.idx,'capacity',a.capacity) END
        ) AS search_state
    FROM left_round_rounded
), start_state AS (
    SELECT *,
        CASE WHEN settled_weeks=total_weeks THEN size(valid_periods)-1 WHEN settled_weeks>total_weeks THEN 0 ELSE search_state.idx END AS start_idx,
        CASE WHEN settled_weeks=total_weeks THEN element_at(valid_periods,-1).weeks WHEN settled_weeks>total_weeks THEN push_weeks ELSE search_state.capacity END AS first_capacity,
        CASE WHEN settled_weeks>total_weeks THEN reverse(valid_periods) ELSE valid_periods END AS ordered_periods
    FROM start_search
), push_orders AS (
    SELECT *, aggregate(
        transform(slice(ordered_periods,start_idx+1,size(ordered_periods)),(p,i) -> named_struct(
            'goods',p.goods,'sale',p.sale,'weeks',CASE WHEN i=0 THEN first_capacity ELSE p.weeks END)),
        named_struct('remaining',push_weeks,'done',false,'items',CAST(array() AS ARRAY<STRUCT<goods:STRING,sale:STRING,weeks:INT>>)),
        (a,p) -> CASE WHEN a.done THEN a ELSE named_struct(
            'remaining',a.remaining-p.weeks,'done',a.remaining<=p.weeks,
            'items',concat(a.items,array(named_struct('goods',p.goods,'sale',p.sale,'weeks',least(a.remaining,p.weeks))))) END
    ).items AS allocated_push_orders
    FROM start_state
), push_units AS (
    SELECT *, CASE WHEN size(classes)=0 THEN CAST(array() AS ARRAY<STRUCT<goods:STRING,level:STRING,sale:STRING,weeks:INT>>)
        ELSE aggregate(allocated_push_orders,
            named_struct('idx',0,'items',CAST(array() AS ARRAY<STRUCT<goods:STRING,level:STRING,sale:STRING,weeks:INT>>)),
            (a,p) -> named_struct(
                'idx',a.idx+greatest(0,least(p.weeks,size(push_levels)-a.idx)),
                'items',concat(a.items,CASE
                    WHEN p.weeks<0 THEN array(named_struct('goods',p.goods,'level',element_at(push_levels,1),'sale',p.sale,'weeks',p.weeks))
                    WHEN p.weeks=0 AND push_fee<>0 THEN array(named_struct('goods',p.goods,'level',element_at(push_levels,-1),'sale',p.sale,'weeks',0))
                    WHEN p.weeks>0 THEN transform(slice(push_levels,a.idx+1,greatest(0,least(p.weeks,size(push_levels)-a.idx))),
                        l -> named_struct('goods',p.goods,'level',l,'sale',p.sale,'weeks',1))
                    ELSE CAST(array() AS ARRAY<STRUCT<goods:STRING,level:STRING,sale:STRING,weeks:INT>>) END)
            )
        ).items END AS push_units,
        CASE WHEN size(classes)>0 THEN CAST(element_at(element_at(classes,-1),2) AS INT)
            ELSE CAST(first_level AS INT) END AS last_level,
        CASE WHEN size(classes)>0 THEN CAST(element_at(element_at(classes,-1),3) AS INT) ELSE 0 END AS last_weekidx,
        filter(valid_periods,p -> p.weeks>0) AS positive_periods
    FROM push_orders
), left_classified AS (
    SELECT *,
        size(classes)>0 AND left_weeks>0 AND concat_ws(',',transform(positive_periods,p -> p.sale))='gift' AS direct_gift,
        filter(transform(level_weeks,s -> split(s,'&')),s -> CAST(element_at(s,1) AS INT)>=last_level) AS syllabus
    FROM push_units
), left_states AS (
    SELECT *,
        aggregate(transform(syllabus,(s,i) -> named_struct('level',CAST(element_at(s,1) AS INT),
            'weeks',CAST(element_at(s,2) AS INT)-CASE WHEN i=0 THEN last_weekidx ELSE 0 END)),
            named_struct('remaining',greatest(left_weeks,0),'done',false,'levels',CAST(array() AS ARRAY<STRING>)),
            (a,s) -> CASE WHEN a.done THEN a ELSE named_struct(
                'remaining',greatest(a.remaining-s.weeks,0),'done',a.remaining<s.weeks,
                'levels',concat(a.levels,array_repeat(CAST(s.level AS STRING),greatest(0,least(a.remaining,s.weeks))))) END
        ) AS schedule_state,
        aggregate(reverse(positive_periods),
            named_struct('remaining',greatest(left_weeks,0),'done',false,'orders',CAST(array() AS ARRAY<STRUCT<goods:STRING,sale:STRING,weeks:INT>>)),
            (a,p) -> CASE WHEN a.done THEN a ELSE named_struct(
                'remaining',greatest(a.remaining-p.weeks,0),'done',a.remaining<=p.weeks,
                'orders',concat(a.orders,array(named_struct('goods',p.goods,'sale',p.sale,'weeks',least(a.remaining,p.weeks))))) END
        ) AS left_order_state
    FROM left_classified
), left_sequences AS (
    SELECT *, CASE
        WHEN left_weeks<=0 OR direct_gift THEN CAST(array() AS ARRAY<STRING>)
        WHEN size(classes)=0 THEN array_repeat(CAST(first_level AS STRING),left_weeks)
        WHEN size(syllabus)=0 THEN raise_error('SCI: missing syllabus')
        ELSE concat(schedule_state.levels,
            array_repeat(CAST(CAST(element_at(element_at(syllabus,-1),1) AS INT)+1 AS STRING),CAST(floor(schedule_state.remaining/32) AS INT)*32),
            array_repeat(CAST(CAST(element_at(element_at(syllabus,-1),1) AS INT)+CAST(floor(schedule_state.remaining/32) AS INT)+1 AS STRING),pmod(schedule_state.remaining,32)))
        END AS left_levels,
        flatten(transform(reverse(left_order_state.orders),p -> array_repeat(named_struct('goods',p.goods,'sale',p.sale),p.weeks))) AS left_order_units
    FROM left_states
), left_units AS (
    SELECT *, CASE
        WHEN left_weeks<=0 THEN array(named_struct('goods',element_at(valid_periods,-1).goods,'level',CAST(last_level AS STRING),'sale',element_at(valid_periods,-1).sale,'weeks',left_weeks))
        WHEN direct_gift THEN array(named_struct('goods','赠课','level',CAST(last_level AS STRING),'sale','unset','weeks',left_weeks))
        ELSE transform(left_order_units,(p,i) -> named_struct('goods',p.goods,
            'level',CASE WHEN i<size(left_levels) THEN element_at(left_levels,i+1) ELSE raise_error('SCI: insufficient level allocation') END,
            'sale',p.sale,'weeks',1)) END AS left_units
    FROM left_sequences
), grouped AS (
    SELECT *,
        transform(array_distinct(transform(push_units,u -> named_struct('goods',u.goods,'level',u.level,'sale',u.sale))),k -> named_struct(
            'goods',k.goods,'level',k.level,'sale',k.sale,
            'weeks',aggregate(filter(push_units,u -> u.goods=k.goods AND u.level=k.level AND u.sale=k.sale),0,(a,u) -> a+u.weeks)
        )) AS push_groups,
        transform(array_distinct(transform(left_units,u -> named_struct('goods',u.goods,'level',u.level,'sale',u.sale))),k -> named_struct(
            'goods',k.goods,'level',k.level,'sale',k.sale,
            'weeks',aggregate(filter(left_units,u -> u.goods=k.goods AND u.level=k.level AND u.sale=k.sale),0,(a,u) -> a+u.weeks)
        )) AS left_groups
    FROM left_units
),
dict_hashes AS (
 SELECT *,push_fee<0 AND push_weeks>0 AND exists(push_groups,g -> g.weeks<0) AS dict_special,
 CASE WHEN push_fee<0 AND push_weeks>0 AND exists(push_groups,g -> g.weeks<0)
 THEN transform(push_groups,(g,i) -> named_struct('idx',i+1,'hash',aggregate(array(CAST(pmod(CAST((aggregate(transform(array(IF(length(encode(g.goods,'UTF-8'))=0,0L,aggregate(array((aggregate(transform(sequence(1,length(encode(g.goods,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.goods,'UTF-8'),i,1)),16,10) AS BIGINT)),shiftleft(element_at(transform(sequence(1,length(encode(g.goods,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.goods,'UTF-8'),i,1)),16,10) AS BIGINT)),1),7),(x,y) -> (CAST(pmod(CAST((CAST(x AS DECIMAL(38,0))*1000003BD) AS DECIMAL(38,0))+9223372036854775808BD,18446744073709551616BD)-9223372036854775808BD AS BIGINT) ^ y)) ^ CAST(length(encode(g.goods,'UTF-8')) AS BIGINT))),CAST(0 AS BIGINT),(u,v) -> IF(v=-1L,-2L,v))),IF(length(encode(g.level,'UTF-8'))=0,0L,aggregate(array((aggregate(transform(sequence(1,length(encode(g.level,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.level,'UTF-8'),i,1)),16,10) AS BIGINT)),shiftleft(element_at(transform(sequence(1,length(encode(g.level,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.level,'UTF-8'),i,1)),16,10) AS BIGINT)),1),7),(x,y) -> (CAST(pmod(CAST((CAST(x AS DECIMAL(38,0))*1000003BD) AS DECIMAL(38,0))+9223372036854775808BD,18446744073709551616BD)-9223372036854775808BD AS BIGINT) ^ y)) ^ CAST(length(encode(g.level,'UTF-8')) AS BIGINT))),CAST(0 AS BIGINT),(u,v) -> IF(v=-1L,-2L,v))),IF(length(encode(g.sale,'UTF-8'))=0,0L,aggregate(array((aggregate(transform(sequence(1,length(encode(g.sale,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.sale,'UTF-8'),i,1)),16,10) AS BIGINT)),shiftleft(element_at(transform(sequence(1,length(encode(g.sale,'UTF-8'))),i -> CAST(conv(hex(substring(encode(g.sale,'UTF-8'),i,1)),16,10) AS BIGINT)),1),7),(x,y) -> (CAST(pmod(CAST((CAST(x AS DECIMAL(38,0))*1000003BD) AS DECIMAL(38,0))+9223372036854775808BD,18446744073709551616BD)-9223372036854775808BD AS BIGINT) ^ y)) ^ CAST(length(encode(g.sale,'UTF-8')) AS BIGINT))),CAST(0 AS BIGINT),(u,v) -> IF(v=-1L,-2L,v)))),(h,i) -> named_struct('h',h,'m',element_at(array(1000003L,1082527L,1165049L),i+1))),3430008L,(x,y) -> CAST(pmod(CAST((CAST((x ^ y.h) AS DECIMAL(38,0))*CAST(y.m AS DECIMAL(38,0))) AS DECIMAL(38,0))+9223372036854775808BD,18446744073709551616BD)-9223372036854775808BD AS BIGINT))+97531BD) AS DECIMAL(38,0))+9223372036854775808BD,18446744073709551616BD)-9223372036854775808BD AS BIGINT)),CAST(0 AS BIGINT),(u,v) -> IF(v=-1L,-2L,v))))
 ELSE CAST(array() AS ARRAY<STRUCT<idx:INT,hash:BIGINT>>) END AS hashed_groups
 FROM grouped
), dict_slots AS (
 SELECT *,aggregate(hashed_groups,array_repeat(0,8),(slots,g) ->
    aggregate(array(aggregate(array(aggregate(sequence(0,size(slots)+13),named_struct('slot',CAST((g.hash & CAST((size(slots)-1) AS BIGINT)) AS INT),'perturb',g.hash,'found',false),(p,z) -> CASE WHEN p.found THEN p WHEN element_at(slots,p.slot+1)=0 THEN named_struct('slot',p.slot,'perturb',p.perturb,'found',true) ELSE named_struct('slot',CAST(((CAST(p.slot AS BIGINT)*5L+1L+(p.perturb & CAST((size(slots)-1) AS BIGINT))) & CAST((size(slots)-1) AS BIGINT)) AS INT),'perturb',shiftrightunsigned(p.perturb,5),'found',false) END).slot),slots,(unused,pos) -> transform(slots,(v,i) -> IF(i=pos,g.idx,v)))),slots,(unused,t) -> CASE WHEN g.idx*3>=size(t)*2
      THEN aggregate(filter(t,v -> v>0),array_repeat(0,CAST(pow(2D,floor(log2(g.idx*IF(g.idx>50000,2D,4D)))+1D) AS INT)),
         (nt,ix) -> aggregate(array(aggregate(sequence(0,size(nt)+13),named_struct('slot',CAST((element_at(hashed_groups,ix).hash & CAST((size(nt)-1) AS BIGINT)) AS INT),'perturb',element_at(hashed_groups,ix).hash,'found',false),(p,z) -> CASE WHEN p.found THEN p WHEN element_at(nt,p.slot+1)=0 THEN named_struct('slot',p.slot,'perturb',p.perturb,'found',true) ELSE named_struct('slot',CAST(((CAST(p.slot AS BIGINT)*5L+1L+(p.perturb & CAST((size(nt)-1) AS BIGINT))) & CAST((size(nt)-1) AS BIGINT)) AS INT),'perturb',shiftrightunsigned(p.perturb,5),'found',false) END).slot),nt,(unused,pos) -> transform(nt,(v,i) -> IF(i=pos,element_at(hashed_groups,ix).idx,v)))) ELSE t END)) AS dict_slots
 FROM dict_hashes
), dict_ordered AS (
 SELECT *,CASE WHEN dict_special THEN transform(filter(dict_slots,v -> v>0),i -> element_at(push_groups,i)) ELSE push_groups END AS ordered_push_groups
 FROM dict_slots
), dict_prefix AS (
 SELECT *,CASE WHEN dict_special THEN slice(ordered_push_groups,1,CAST(array_position(transform(ordered_push_groups,g -> g.weeks<0),true) AS INT)) ELSE ordered_push_groups END AS output_push_groups
 FROM dict_ordered
), output_arrays AS (
    SELECT user_id, concat(
        transform(filter(output_push_groups,g -> push_weeks<>0 OR push_fee<>0),g -> named_struct('goods',g.goods,'level',g.level,'sale',g.sale,
            'weeks',CASE WHEN push_fee<0 AND g.weeks<0 AND push_weeks>0 THEN push_weeks ELSE g.weeks END,
            'fee',CASE WHEN push_fee<0 AND g.weeks<0 AND push_weeks>0 THEN push_fee
                WHEN push_weeks<>0 THEN push_fee/push_weeks*g.weeks
                WHEN push_fee<>0 THEN push_fee ELSE raise_error('SCI: Python unbound or stale zero-push output requires explicit decision') END,'kind','0')),
        transform(left_groups,g -> named_struct('goods',g.goods,'level',g.level,'sale',g.sale,'weeks',g.weeks,
            'fee',CASE WHEN left_weeks>0 THEN left_fee/aggregate(left_groups,0,(a,x) -> a+x.weeks)*g.weeks ELSE left_fee END,
            'kind',CASE WHEN left_weeks>0 THEN '1' ELSE '0' END))
    ) AS result_rows
    FROM dict_prefix
), output_raw AS (
    SELECT user_id, r.goods, r.level, r.sale, r.weeks, r.fee, r.kind
    FROM output_arrays LATERAL VIEW explode(result_rows) e AS r
),

output_round_bits AS (
    SELECT *, fee AS output_round_raw,
        CAST(reflect('java.lang.Double', 'doubleToLongBits', abs(fee)) AS BIGINT) AS output_round_bits
    FROM output_raw
), output_round_ratio AS (
    SELECT *,
        CAST(pmod(output_round_bits, 4503599627370496L) + 4503599627370496L AS DECIMAL(38,0)) * 10000 AS output_round_num,
        CASE WHEN abs(output_round_raw) >= 0.00005D AND abs(output_round_raw) < 1099511627776D THEN
            CASE WHEN 1075 - CAST(shiftrightunsigned(output_round_bits,52) AS INT) <= 62
                THEN CAST(shiftleft(1L,1075-CAST(shiftrightunsigned(output_round_bits,52) AS INT)) AS DECIMAL(38,0))
                ELSE CAST(shiftleft(1L,1070-CAST(shiftrightunsigned(output_round_bits,52) AS INT)) AS DECIMAL(38,0))*32 END
            ELSE CAST(1 AS DECIMAL(38,0)) END AS output_round_den
    FROM output_round_bits
), output_round_division AS (
    SELECT *, CASE WHEN abs(output_round_raw) >= 0.00005D AND abs(output_round_raw) < 1099511627776D
        THEN CAST(output_round_num DIV output_round_den AS DECIMAL(38,0)) ELSE CAST(0 AS DECIMAL(38,0)) END AS output_round_quot
    FROM output_round_ratio
), output_round_rounded AS (
    SELECT *, CASE
        WHEN abs(output_round_raw) < 0.00005D THEN 0D
        WHEN abs(output_round_raw) >= 1099511627776D THEN output_round_raw
        ELSE sign(output_round_raw) * CAST(
            (output_round_quot + CASE WHEN (output_round_num - output_round_quot * output_round_den) * 2 >= output_round_den THEN 1 ELSE 0 END)
            / CAST(10000 AS DECIMAL(5,0)) AS DOUBLE)
        END AS rounded_fee
    FROM output_round_division
)
SELECT CAST(user_id AS STRING),CAST(goods AS STRING),CAST(level AS STRING),CAST(sale AS STRING),CAST(weeks AS BIGINT),
CAST(CAST(format_string('%.12g',rounded_fee) AS DOUBLE) AS STRING),CAST(kind AS STRING)
FROM output_round_rounded;
