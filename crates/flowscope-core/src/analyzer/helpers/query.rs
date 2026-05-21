use sqlparser::ast::{self as ast, Expr, Query, SetExpr};

/// Classify the type of a query
pub fn classify_query_type(query: &Query) -> String {
    // `WITH ... INSERT OVERWRITE TABLE t SELECT ...` is parsed as Query { with, body: Insert }.
    // The sink is the INSERT target, so report INSERT rather than WITH.
    if matches!(query.body.as_ref(), SetExpr::Insert(_)) {
        return "INSERT".to_string();
    }
    if query.with.is_some() {
        "WITH".to_string()
    } else {
        match &*query.body {
            SetExpr::Select(_) => "SELECT".to_string(),
            SetExpr::SetOperation { op, .. } => match op {
                ast::SetOperator::Union => "UNION".to_string(),
                ast::SetOperator::Intersect => "INTERSECT".to_string(),
                ast::SetOperator::Except => "EXCEPT".to_string(),
                ast::SetOperator::Minus => "MINUS".to_string(),
            },
            SetExpr::Values(_) => "VALUES".to_string(),
            _ => "SELECT".to_string(),
        }
    }
}

/// Check if an expression is a simple column reference (no transformation)
pub fn is_simple_column_ref(expr: &Expr) -> bool {
    matches!(expr, Expr::Identifier(_) | Expr::CompoundIdentifier(_))
}
