set mapreduce.reduce.memory.mb=4096;
set mapreduce.map.memory.mb=2048;
set mapreduce.map.java.opts='-Xmx4096M';
set mapreduce.reduce.java.opts='-Xmx4096M';

insert overwrite table dw_dwd.dwd_eng_frog_user_devices_detail_chapter_finish_da partition (dt = '${date}')
select
      a.user_id
     ,a.subject_id as subject
     ,collect_set(a.device_id) as device_set
     ,collect_set(a.product_id) as product_set
     ,collect_set(a.client_ip) as ip_set
     ,collect_set(a.net) as net_set
from

    (
        select
              user_id
             ,subject_id
             ,device_id
             ,client_ip
             ,other['missionid'] as mission_id
             ,product_id
             ,net
        from dw_dwd.dwd_eng_frog_di
        where dt = '${date}'
          and user_id > '0'
          and product_id in('503','513','523','543','553','573','583','593')
          and client_ip>'0'
          and subject_id>'0'
          and page_tp = 'E'
          and page_code='EpisodeChapterFinishPage'
          and url='/event/EpisodeChapterFinishPage/enter'
          and other['missionid'] is not null
    ) a

        left join
    (
        select mission_id from
            dw_dim.dim_eng_mission_da
        where dt = '${date}'
          and lesson_id in (20,46,118,200,266,282,560)

    ) b
    on a.mission_id = b.mission_id
    where b.mission_id is not null
group by a.user_id, a.subject_id;