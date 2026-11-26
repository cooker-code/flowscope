import { describe, expect, it } from 'vitest';
import { explainGraphIngestionReason } from './graph-ingestion-reasons';

describe('graph ingestion reason explanations', () => {
  it('explains compound quality issues and preserves full table and field targets', () => {
    expect(
      explainGraphIngestionReason(
        'incomplete_analysis:ambiguous_join_scope,pending_metadata:paimon.db.orders,unknown_physical_column:hive.dw.orders.UserId,ambiguous_join_scope'
      )
    ).toEqual([
      { label: '无法确定 JOIN 两侧对应的唯一物理表' },
      { label: '缺少或尚未匹配到表结构信息', detail: 'paimon.db.orders' },
      { label: '表结构中找不到该字段', detail: 'hive.dw.orders.UserId' },
    ]);
  });
  it('keeps missing details and coarse retry causes honest', () => {
    expect(explainGraphIngestionReason(null)).toEqual([]);
    expect(explainGraphIngestionReason('   ')).toEqual([]);
    expect(explainGraphIngestionReason('incomplete_analysis:')).toEqual([
      { label: '解析或血缘检查未通过，后台未提供具体检查项。' },
    ]);
    expect(explainGraphIngestionReason('neo4j_temporarily_unavailable')[0].detail).toContain(
      '不能据此确定'
    );
  });
  it('retains unknown backend codes and every item in long reason lists', () => {
    const unknown = 'future_check:some:unrecognized:detail';
    expect(explainGraphIngestionReason(unknown)).toEqual([
      { label: '后台返回的其他原因', detail: unknown },
    ]);
    const reason =
      'incomplete_analysis:' +
      Array.from({ length: 120 }, (_, index) => `pending_metadata:hive.db.table_${index}`).join(
        ','
      );
    const issues = explainGraphIngestionReason(reason);
    expect(issues).toHaveLength(120);
    expect(issues[119].detail).toBe('hive.db.table_119');
  });
});
