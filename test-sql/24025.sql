SELECT
  case 
    when url = '/event/LessonList/Banner/enter' then '曝光'
    when url = '/click/LessonList/Banner/banner' then '点击'
  end as `类型`,
  count(*) as `浏览数`,
  count(distinct device_id) as `去重设备数`,
  count(distinct user_id) as `去重用户数`
FROM
  dw_dwd.dwd_eng_frog_di
WHERE
  {{dt}}
  and {{time2dt(action_tp) as dt}}
  AND category IN ('event', 'click')
  AND page_code = 'LessonList'
  AND page_tp = 'L'
  AND url IN (
    '/event/LessonList/Banner/enter',
    '/click/LessonList/Banner/banner'
  )
  AND {{other['taskid'] as taskid}}
group by 
  case 
    when url = '/event/LessonList/Banner/enter' then '曝光'
    when url = '/click/LessonList/Banner/banner' then '点击'
  end