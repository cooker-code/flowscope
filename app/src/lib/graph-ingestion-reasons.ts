export interface GraphIngestionReason {
  label: string;
  detail?: string;
}

const REASON_LABELS: Record<string, string> = {
  ambiguous_column_owner: '字段无法唯一归属到一个表',
  ambiguous_join_scope: '无法确定 JOIN 两侧对应的唯一物理表',
  pending_metadata: '缺少或尚未匹配到表结构信息',
  unknown_physical_column: '表结构中找不到该字段',
  unresolved_insert_target_mapping: '无法将写入字段映射到目标表的物理字段',
  sync_requires_explicit_external_target: '导出任务缺少明确的外部目标表',
  unqualified_table: '表名缺少数据库或目录信息',
  unqualified_source_table: '来源表缺少数据库或目录信息',
  approximate_lineage: '解析结果包含近似血缘，未达到正式入图要求',
  multiple_logical_outputs: '包含多个逻辑输出，无法确定单一目标',
  unsupported_statement_kind: '当前入图不支持该 SQL 语句类型',
  invalid_scheduled_output_id: '调度任务或模板 ID 不符合入图要求',
  unexpanded_star: 'SELECT * 尚未展开为具体字段',
  unsupported_sink: '无法确定可支持的血缘输出目标',
  missing_edge_endpoint: '血缘关系引用了缺失的节点',
  unsupported_cross_statement: '当前入图不支持该跨语句血缘关系',
  stale_source_version: '请求版本或分析版本早于当前正式血缘版本',
  current_policy_or_token_disallows_event: '写入前复核时，调用方策略或 Token 已不允许该请求',
  content_or_version_conflict: '同一事件或来源版本对应了不同内容',
  neo4j_environment_or_configuration_rejected: 'Neo4j 环境或连接配置被拒绝',
  neo4j_rejected_event: 'Neo4j 拒绝了本次入图操作',
  invalid_storage_event: '入图事件的数据不符合存储要求',
  already_current: '该版本的正式血缘已存在，无需重复更新',
};

/** Decode the backend's comma-separated issue codes without losing their targets. */
export function explainGraphIngestionReason(reason?: string | null): GraphIngestionReason[] {
  const raw = reason?.trim();
  if (!raw) return [];
  const prefix = 'incomplete_analysis:';
  const issues = raw.startsWith(prefix) ? raw.slice(prefix.length) : raw;
  if (!issues.trim()) {
    return [{ label: '解析或血缘检查未通过，后台未提供具体检查项。' }];
  }
  return [
    ...new Set(
      issues
        .split(',')
        .map((issue) => issue.trim())
        .filter(Boolean)
    ),
  ].map((issue) => {
    if (issue === 'neo4j_temporarily_unavailable') {
      return {
        label: '入图遇到可重试异常',
        detail: '后台尚未记录具体失败阶段，不能据此确定是连接、查询还是超时问题。',
      };
    }
    const separator = issue.indexOf(':');
    const code = separator < 0 ? issue : issue.slice(0, separator);
    const label = REASON_LABELS[code];
    if (!label) return { label: '后台返回的其他原因', detail: issue };
    return separator < 0 ? { label } : { label, detail: issue.slice(separator + 1) };
  });
}
