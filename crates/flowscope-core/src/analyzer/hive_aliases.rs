//! Quote identifiers only after the grammar has assigned them an alias role.
use crate::dialect_ext::flowscope_hive::is_han;
use crate::types::{issue_codes, Issue};
use sqlparser::ast::{
    Expr, Ident, ObjectNamePart, Query, SelectItem, SetExpr, Statement, TableAlias, TableFactor,
    VisitMut, VisitorMut,
};
use sqlparser::keywords::ALL_KEYWORDS;
use std::ops::ControlFlow;

pub(super) fn normalize(
    statement: &mut Statement,
    index: usize,
    source: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    let mut visitor = AliasVisitor {
        index,
        source,
        issues,
    };
    let _ = statement.visit(&mut visitor);
}

struct AliasVisitor<'a> {
    index: usize,
    source: Option<&'a str>,
    issues: &'a mut Vec<Issue>,
}

impl AliasVisitor<'_> {
    fn ident(&mut self, ident: &mut Ident) {
        if ident.quote_style == Some('`')
            || !(ident.value.chars().any(is_han)
                || ALL_KEYWORDS
                    .binary_search(&ident.value.to_ascii_uppercase().as_str())
                    .is_ok())
        {
            return;
        }
        ident.quote_style = Some('`');
        let mut issue = Issue::warning(
            issue_codes::HIVE_ALIAS_BACKTICKS,
            format!("别名 {} 建议使用反引号，写作 {ident}。", ident.value),
        )
        .with_statement(self.index);
        if let Some(source) = self.source {
            issue = issue.with_source_name(source);
        }
        self.issues.push(issue);
    }

    fn table_alias(&mut self, alias: &mut TableAlias) {
        self.ident(&mut alias.name);
        for column in &mut alias.columns {
            self.ident(&mut column.name);
        }
    }

    fn projections(&mut self, body: &mut SetExpr) {
        match body {
            SetExpr::Select(select) => {
                for item in &mut select.projection {
                    if let SelectItem::ExprWithAlias { alias, .. } = item {
                        self.ident(alias);
                    }
                }
                for view in &mut select.lateral_views {
                    if let Some(ObjectNamePart::Identifier(alias)) =
                        view.lateral_view_name.0.last_mut()
                    {
                        self.ident(alias);
                    }
                    for alias in &mut view.lateral_col_alias {
                        self.ident(alias);
                    }
                }
                for window in &mut select.named_window {
                    self.ident(&mut window.0);
                }
            }
            SetExpr::SetOperation { left, right, .. } => {
                self.projections(left);
                self.projections(right);
            }
            _ => {} // Nested Query nodes are visited separately.
        }
    }
}

impl VisitorMut for AliasVisitor<'_> {
    type Break = ();

    fn pre_visit_statement(&mut self, statement: &mut Statement) -> ControlFlow<()> {
        if let Statement::Insert(insert) = statement {
            if let Some(alias) = &mut insert.table_alias {
                self.ident(alias);
            }
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_query(&mut self, query: &mut Query) -> ControlFlow<()> {
        if let Some(with) = &mut query.with {
            for cte in &mut with.cte_tables {
                self.table_alias(&mut cte.alias);
            }
        }
        self.projections(&mut query.body);
        ControlFlow::Continue(())
    }

    fn pre_visit_expr(&mut self, expr: &mut Expr) -> ControlFlow<()> {
        if let Expr::Named { name, .. } = expr {
            self.ident(name);
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_table_factor(&mut self, factor: &mut TableFactor) -> ControlFlow<()> {
        match factor {
            TableFactor::UNNEST {
                with_offset_alias: Some(alias),
                ..
            } => self.ident(alias),
            TableFactor::Pivot {
                aggregate_functions,
                value_source,
                ..
            } => {
                for expression in aggregate_functions {
                    if let Some(alias) = &mut expression.alias {
                        self.ident(alias);
                    }
                }
                if let sqlparser::ast::PivotValueSource::List(values) = value_source {
                    for value in values {
                        if let Some(alias) = &mut value.alias {
                            self.ident(alias);
                        }
                    }
                }
            }
            _ => {}
        }
        let alias = match factor {
            TableFactor::Table { alias, .. }
            | TableFactor::Derived { alias, .. }
            | TableFactor::TableFunction { alias, .. }
            | TableFactor::Function { alias, .. }
            | TableFactor::UNNEST { alias, .. }
            | TableFactor::JsonTable { alias, .. }
            | TableFactor::OpenJsonTable { alias, .. }
            | TableFactor::NestedJoin { alias, .. }
            | TableFactor::Pivot { alias, .. }
            | TableFactor::Unpivot { alias, .. }
            | TableFactor::MatchRecognize { alias, .. }
            | TableFactor::XmlTable { alias, .. }
            | TableFactor::SemanticView { alias, .. } => alias,
        };
        if let Some(alias) = alias {
            self.table_alias(alias);
        }
        ControlFlow::Continue(())
    }
}
