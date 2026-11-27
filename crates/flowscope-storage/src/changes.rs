//! Net business changes, excluding timestamps and internal storage objects.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeCounts {
    pub created: u64,
    pub updated: u64,
    pub deleted: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphChanges {
    pub nodes: BTreeMap<String, ChangeCounts>,
    pub relationships: BTreeMap<String, ChangeCounts>,
    pub node_totals: ChangeCounts,
    pub relationship_totals: ChangeCounts,
}

#[derive(Debug, PartialEq)]
pub(crate) struct BusinessObject {
    pub kind: String,
    pub properties: BTreeMap<String, Value>,
}

pub(crate) type BusinessObjects = BTreeMap<String, BusinessObject>;

impl GraphChanges {
    pub(crate) fn between(
        before_nodes: &BusinessObjects,
        after_nodes: &BusinessObjects,
        before_relationships: &BusinessObjects,
        after_relationships: &BusinessObjects,
    ) -> Self {
        let mut result = Self::default();
        Self::compare(
            before_nodes,
            after_nodes,
            &mut result.nodes,
            &mut result.node_totals,
        );
        Self::compare(
            before_relationships,
            after_relationships,
            &mut result.relationships,
            &mut result.relationship_totals,
        );
        result
    }

    fn compare(
        before: &BusinessObjects,
        after: &BusinessObjects,
        groups: &mut BTreeMap<String, ChangeCounts>,
        total: &mut ChangeCounts,
    ) {
        let keys: BTreeSet<_> = before.keys().chain(after.keys()).collect();
        for key in keys {
            let (kind, change) = match (before.get(key), after.get(key)) {
                (None, Some(value)) => (&value.kind, 0),
                (Some(value), None) => (&value.kind, 2),
                (Some(old), Some(new)) if old != new => (&new.kind, 1),
                _ => continue,
            };
            let group = groups.entry(kind.clone()).or_default();
            match change {
                0 => {
                    group.created += 1;
                    total.created += 1;
                }
                1 => {
                    group.updated += 1;
                    total.updated += 1;
                }
                _ => {
                    group.deleted += 1;
                    total.deleted += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn counts_net_changes_by_identity_and_business_kind() {
        fn object(value: i64) -> BusinessObject {
            BusinessObject {
                kind: "M_COL:Physical".into(),
                properties: BTreeMap::from([("value".into(), json!(value))]),
            }
        }
        let before = BTreeMap::from([
            ("same".into(), object(1)),
            ("updated".into(), object(1)),
            ("deleted".into(), object(1)),
        ]);
        let after = BTreeMap::from([
            ("same".into(), object(1)),
            ("updated".into(), object(2)),
            ("created".into(), object(1)),
        ]);
        let changes = GraphChanges::between(&before, &after, &BTreeMap::new(), &BTreeMap::new());
        assert_eq!(
            changes.node_totals,
            ChangeCounts {
                created: 1,
                updated: 1,
                deleted: 1
            }
        );
        assert_eq!(changes.nodes["M_COL:Physical"], changes.node_totals);
        assert_eq!(changes.relationship_totals, ChangeCounts::default());
    }
}
