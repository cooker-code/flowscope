import { describe, expect, it } from 'vitest';
import type { Node } from '@pondpilot/flowscope-core';
import {
  getAggregationForStatement,
  getOccurrenceSourceName,
  getOccurrenceSpan,
  scopeNodeToStatement,
} from '../src/utils/nodeOccurrences';

describe('statement-scoped aggregations', () => {
  it('clears aggregation metadata for statements explicitly marked as non-aggregated', () => {
    const node: Node = {
      id: 'column:analytics.metrics.c',
      type: 'column',
      label: 'c',
      qualifiedName: 'analytics.metrics.c',
      statementIds: [0, 1],
      aggregation: {
        isGroupingKey: false,
        function: 'COUNT',
      },
      metadata: {
        statementAggregations: {
          '0': {
            isGroupingKey: false,
            function: 'COUNT',
          },
          '1': null,
        },
      },
    };

    expect(getAggregationForStatement(node, 0)?.function).toBe('COUNT');
    expect(getAggregationForStatement(node, 1)).toBeUndefined();
    expect(scopeNodeToStatement(node, 1).aggregation).toBeUndefined();
  });

  it('prefers relation definition occurrences before consumer refs', () => {
    const consumerSpan = { start: 14, end: 22 };
    const producerSpan = { start: 0, end: 14 };
    const node: Node = {
      id: 'table:producer',
      type: 'table',
      label: 'producer',
      qualifiedName: 'producer',
      statementIds: [0, 1],
      metadata: {
        occurrenceSpans: [consumerSpan, producerSpan],
        occurrenceStatementIds: [0, 1],
        occurrenceSourceNames: ['models/consumer.sql', 'models/producer.sql'],
        definitionOccurrenceSpans: [producerSpan],
        definitionOccurrenceStatementIds: [1],
        definitionOccurrenceSourceNames: ['models/producer.sql'],
      },
    };

    expect(getOccurrenceSpan(node, 0)).toEqual(producerSpan);
    expect(getOccurrenceSourceName(node, 0)).toBe('models/producer.sql');
    expect(getOccurrenceSpan(node, 1)).toEqual(consumerSpan);
    expect(getOccurrenceSourceName(node, 1)).toBe('models/consumer.sql');

    expect(scopeNodeToStatement(node, 0).nameSpans).toEqual([consumerSpan]);
    expect(scopeNodeToStatement(node, 1).nameSpans).toEqual([producerSpan]);
  });
});
