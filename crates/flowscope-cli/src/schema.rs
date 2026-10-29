//! Schema loading from DDL files.

use anyhow::{bail, Context, Result};
use flowscope_core::{
    analyze, AnalyzeRequest, ColumnSchema, Dialect, FileSource, SchemaMetadata, SchemaTable,
    Severity,
};
use sqlparser::ast::{HiveDistributionStyle, Statement};
use sqlparser::dialect::HiveDialect;
use sqlparser::parser::Parser;
use std::path::Path;

/// Load schema from a DDL file containing CREATE TABLE statements.
///
/// Hive DDL is parsed directly because the workload compatibility preprocessor
/// intentionally removes CREATE TABLE statements before lineage analysis.
pub fn load_schema_from_ddl(path: &Path, dialect: Dialect) -> Result<SchemaMetadata> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read schema file: {}", path.display()))?;

    parse_schema_ddl(&content, dialect)
}

/// Parse DDL content to extract schema metadata.
fn parse_schema_ddl(content: &str, dialect: Dialect) -> Result<SchemaMetadata> {
    if dialect == Dialect::Hive {
        return parse_hive_schema_ddl(content);
    }
    let request = AnalyzeRequest {
        sql: String::new(),
        files: Some(vec![FileSource {
            name: "schema.sql".to_string(),
            content: content.to_string(),
        }]),
        dialect,
        source_name: None,
        options: None,
        schema: Some(SchemaMetadata {
            allow_implied: true,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    };

    let result = analyze(&request);

    // Check for parsing errors
    if result.summary.has_errors {
        let error_messages: Vec<String> = result
            .issues
            .iter()
            .filter(|issue| issue.severity == Severity::Error)
            .map(|issue| format!("[{}] {}", issue.code, issue.message))
            .collect();

        bail!("Failed to parse schema DDL:\n{}", error_messages.join("\n"));
    }

    // Extract schema from resolved_schema
    let resolved = result
        .resolved_schema
        .context("Schema DDL produced no table definitions")?;

    let schema = SchemaMetadata {
        default_catalog: None,
        default_schema: None,
        search_path: None,
        case_sensitivity: None,
        tables: resolved
            .tables
            .into_iter()
            .map(|t| SchemaTable {
                catalog: t.catalog,
                schema: t.schema,
                name: t.name,
                columns: t
                    .columns
                    .into_iter()
                    .map(|c| ColumnSchema {
                        name: c.name,
                        data_type: c.data_type,
                        is_primary_key: c.is_primary_key,
                        foreign_key: c.foreign_key,
                    })
                    .collect(),
            })
            .collect(),
        allow_implied: false, // Don't allow further implied tables in main analysis
    };

    Ok(schema)
}

fn parse_hive_schema_ddl(content: &str) -> Result<SchemaMetadata> {
    // Prefer the upstream AST unchanged.  Its parser currently rejects a table
    // COMMENT after CREATE EXTERNAL TABLE, so only that grammar gap gets a
    // syntax-aware fallback; column definitions, partitions, locations and
    // properties stay in the original input.
    let literal_compatible = normalize_hive_escaped_quotes(content);
    let statements = match Parser::parse_sql(&HiveDialect {}, content) {
        Ok(statements) => statements,
        Err(original) => {
            let table_comment_compatible = remove_external_table_comments(content);
            let literal_and_table_comment_compatible =
                remove_external_table_comments(&literal_compatible);
            let candidates = [
                (&literal_compatible, "Hive escaped-quote normalization"),
                (&table_comment_compatible, "external-table COMMENT fallback"),
                (
                    &literal_and_table_comment_compatible,
                    "Hive escaped-quote normalization and external-table COMMENT fallback",
                ),
            ];
            let mut fallback_error = None;
            let mut parsed = None;
            for (compatible, description) in candidates {
                if compatible == content {
                    continue;
                }
                match Parser::parse_sql(&HiveDialect {}, compatible) {
                    Ok(statements) => {
                        parsed = Some(statements);
                        break;
                    }
                    Err(error) => fallback_error = Some((description, error)),
                }
            }
            parsed.ok_or_else(|| {
                if let Some((description, fallback)) = fallback_error {
                    anyhow::anyhow!(
                        "{fallback} ({description} failed after original Hive parser error: {original})"
                    )
                } else {
                    original.into()
                }
            })?
        }
    };
    let mut tables = Vec::new();
    for statement in statements {
        let Statement::CreateTable(create) = statement else {
            continue;
        };
        // Some Hive exports quote an entire qualified name, e.g. `db.table`.
        let parts: Vec<String> = create
            .name
            .to_string()
            .trim_matches('`')
            .split('.')
            .map(|part| part.trim_matches('`').to_string())
            .collect();
        let Some(name) = parts.last().cloned() else {
            continue;
        };
        let (catalog, schema) = match parts.as_slice() {
            [schema, _] => (None, Some(schema.clone())),
            [catalog, schema, _] => (Some(catalog.clone()), Some(schema.clone())),
            _ => (None, None),
        };
        let mut columns: Vec<ColumnSchema> =
            create.columns.into_iter().map(schema_column).collect();
        if let HiveDistributionStyle::PARTITIONED {
            columns: partition_columns,
        } = create.hive_distribution
        {
            for column in partition_columns.into_iter().map(schema_column) {
                if !columns
                    .iter()
                    .any(|existing| existing.name.eq_ignore_ascii_case(&column.name))
                {
                    columns.push(column);
                }
            }
        }
        tables.push(SchemaTable {
            catalog,
            schema,
            name,
            columns,
        });
    }
    if tables.is_empty() {
        bail!("Schema DDL produced no table definitions");
    }
    Ok(SchemaMetadata {
        default_catalog: None,
        default_schema: None,
        search_path: None,
        case_sensitivity: None,
        tables,
        allow_implied: false,
    })
}

/// Convert Hive's backslash-escaped single quotes inside single-quoted
/// literals to SQL's doubled-quote spelling. This only changes an odd-length
/// backslash run immediately followed by a quote; even runs close the literal
/// normally and all double-quoted identifiers/comments remain untouched.
///
/// The schema parser needs this separate compatibility path because workload
/// Hive preprocessing deliberately drops DDL before it reaches sqlparser.
fn normalize_hive_escaped_quotes(content: &str) -> String {
    let bytes = content.as_bytes();
    let mut output = String::with_capacity(content.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\'' => {
                output.push('\'');
                index += 1;
                while index < bytes.len() {
                    if bytes[index] == b'\\' {
                        let slash_start = index;
                        while bytes.get(index) == Some(&b'\\') {
                            index += 1;
                        }
                        if bytes.get(index) == Some(&b'\'') && (index - slash_start) % 2 == 1 {
                            output.push_str(&content[slash_start..index - 1]);
                            output.push_str("''");
                            index += 1;
                            continue;
                        }
                        output.push_str(&content[slash_start..index]);
                        continue;
                    }
                    if bytes[index] == b'\'' {
                        if bytes.get(index + 1) == Some(&b'\'') {
                            output.push_str("''");
                            index += 2;
                        } else {
                            output.push('\'');
                            index += 1;
                            break;
                        }
                    } else {
                        let next = bytes[index..]
                            .iter()
                            .position(|byte| matches!(*byte, b'\\' | b'\''))
                            .map_or(bytes.len(), |offset| index + offset);
                        output.push_str(&content[index..next]);
                        index = next;
                    }
                }
            }
            b'-' if bytes.get(index + 1) == Some(&b'-') => {
                let end = bytes[index..]
                    .iter()
                    .position(|byte| *byte == b'\n')
                    .map_or(bytes.len(), |offset| index + offset + 1);
                output.push_str(&content[index..end]);
                index = end;
            }
            b'/' if bytes.get(index + 1) == Some(&b'*') => {
                let end = bytes[index + 2..]
                    .windows(2)
                    .position(|window| window == b"*/")
                    .map_or(bytes.len(), |offset| index + offset + 4);
                output.push_str(&content[index..end]);
                index = end;
            }
            b'\"' | b'`' => {
                let start = index;
                let delimiter = bytes[index];
                index += 1;
                while index < bytes.len() {
                    if bytes[index] == delimiter {
                        if bytes.get(index + 1) == Some(&delimiter) {
                            index += 2;
                        } else {
                            index += 1;
                            break;
                        }
                    } else {
                        index += 1;
                    }
                }
                output.push_str(&content[start..index]);
            }
            _ => {
                let next = bytes[index..]
                    .iter()
                    .position(|byte| matches!(*byte, b'\'' | b'\"' | b'`' | b'-' | b'/'))
                    .map_or(bytes.len(), |offset| index + offset);
                if next == index {
                    output.push(bytes[index] as char);
                    index += 1;
                } else {
                    output.push_str(&content[index..next]);
                    index = next;
                }
            }
        }
    }
    output
}

fn schema_column(column: sqlparser::ast::ColumnDef) -> ColumnSchema {
    ColumnSchema {
        name: column.name.value,
        data_type: Some(column.data_type.to_string()),
        is_primary_key: None,
        foreign_key: None,
    }
}

/// Remove a table-level COMMENT only after the complete `CREATE EXTERNAL
/// TABLE (...)` column list. This is intentionally not a broad text rewrite:
/// quoted strings, quoted identifiers and comments are skipped while scanning.
fn remove_external_table_comments(content: &str) -> String {
    let bytes = content.as_bytes();
    let mut output = String::with_capacity(content.len());
    let mut copied = 0;
    let mut index = 0;
    while let Some(start) = find_word_sequence(bytes, index, b"create", b"external", b"table") {
        let Some(open) = find_code_byte(bytes, start, b'(') else {
            break;
        };
        let Some(close) = matching_parenthesis(bytes, open) else {
            break;
        };
        let comment = skip_space_and_comments(bytes, close + 1);
        if !matches_word(bytes, comment, b"comment") {
            index = close + 1;
            continue;
        }
        let quote = skip_space_and_comments(bytes, comment + b"comment".len());
        if bytes.get(quote) != Some(&b'\'') {
            index = quote;
            continue;
        }
        let Some(end) = quoted_end(bytes, quote) else {
            break;
        };
        output.push_str(&content[copied..comment]);
        copied = end + 1;
        index = copied;
    }
    if copied == 0 {
        content.to_string()
    } else {
        output.push_str(&content[copied..]);
        output
    }
}

fn find_word_sequence(
    bytes: &[u8],
    mut index: usize,
    first: &[u8],
    second: &[u8],
    third: &[u8],
) -> Option<usize> {
    while index < bytes.len() {
        index = skip_non_code(bytes, index);
        if matches_word(bytes, index, first) {
            let second_start = skip_space_and_comments(bytes, index + first.len());
            let third_start = skip_space_and_comments(bytes, second_start + second.len());
            if matches_word(bytes, second_start, second) && matches_word(bytes, third_start, third)
            {
                return Some(index);
            }
        }
        index += 1;
    }
    None
}

fn find_code_byte(bytes: &[u8], mut index: usize, wanted: u8) -> Option<usize> {
    while index < bytes.len() {
        index = skip_non_code(bytes, index);
        if bytes.get(index) == Some(&wanted) {
            return Some(index);
        }
        index += 1;
    }
    None
}

fn matching_parenthesis(bytes: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut index = open;
    while index < bytes.len() {
        index = skip_non_code(bytes, index);
        match bytes.get(index)? {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
        index += 1;
    }
    None
}

fn skip_space_and_comments(bytes: &[u8], mut index: usize) -> usize {
    loop {
        while bytes
            .get(index)
            .is_some_and(|byte| byte.is_ascii_whitespace())
        {
            index += 1;
        }
        if bytes.get(index..index + 2) == Some(b"--") {
            index = bytes[index..]
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(bytes.len(), |offset| index + offset + 1);
        } else if bytes.get(index..index + 2) == Some(b"/*") {
            let Some(offset) = bytes[index + 2..]
                .windows(2)
                .position(|window| window == b"*/")
            else {
                return bytes.len();
            };
            index += offset + 4;
        } else {
            return index;
        }
    }
}

fn skip_non_code(bytes: &[u8], index: usize) -> usize {
    match bytes.get(index) {
        Some(b'\'') | Some(b'\"') | Some(b'`') => {
            quoted_end(bytes, index).map_or(bytes.len(), |end| end + 1)
        }
        Some(b'-') if bytes.get(index + 1) == Some(&b'-') => bytes[index..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(bytes.len(), |offset| index + offset + 1),
        Some(b'/') if bytes.get(index + 1) == Some(&b'*') => bytes[index + 2..]
            .windows(2)
            .position(|window| window == b"*/")
            .map_or(bytes.len(), |offset| index + offset + 4),
        _ => index,
    }
}

fn matches_word(bytes: &[u8], start: usize, word: &[u8]) -> bool {
    bytes
        .get(start..start + word.len())
        .is_some_and(|candidate| {
            candidate.eq_ignore_ascii_case(word)
                && !bytes
                    .get(start.wrapping_sub(1))
                    .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
                && !bytes
                    .get(start + word.len())
                    .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
        })
}

fn quoted_end(bytes: &[u8], start: usize) -> Option<usize> {
    let delimiter = *bytes.get(start)?;
    let mut index = start + 1;
    while index < bytes.len() {
        if bytes[index] == b'\\' && delimiter == b'\'' {
            let slash_start = index;
            while bytes.get(index) == Some(&b'\\') {
                index += 1;
            }
            if bytes.get(index) == Some(&delimiter) && (index - slash_start) % 2 == 1 {
                index += 1;
            }
        } else if bytes[index] == delimiter {
            if bytes.get(index + 1) == Some(&delimiter) {
                index += 2;
            } else {
                return Some(index);
            }
        } else {
            index += 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_ddl() {
        let ddl = r#"
            CREATE TABLE users (
                id INT,
                name VARCHAR(100),
                email VARCHAR(255)
            );
        "#;

        let schema = parse_schema_ddl(ddl, Dialect::Generic).unwrap();
        assert!(!schema.tables.is_empty());

        let users_table = schema.tables.iter().find(|t| t.name == "users");
        assert!(users_table.is_some());

        let table = users_table.unwrap();
        assert_eq!(table.columns.len(), 3);
    }

    #[test]
    fn test_parse_multiple_tables() {
        let ddl = r#"
            CREATE TABLE users (id INT, name VARCHAR);
            CREATE TABLE orders (id INT, user_id INT, total DECIMAL);
        "#;

        let schema = parse_schema_ddl(ddl, Dialect::Generic).unwrap();
        assert!(schema.tables.len() >= 2);
    }

    #[test]
    fn test_parse_hive_external_table_with_qualified_backtick_name_and_comment() {
        let ddl = r#"
            CREATE EXTERNAL TABLE `dw_conan_dim.dim_eng_user_extend_da`(
                `user_id` string COMMENT '用户 ID',
                `name` string COMMENT '姓名'
            )
            COMMENT '用户维度'
            PARTITIONED BY (`dt` string COMMENT '日期')
            ROW FORMAT SERDE 'org.apache.hadoop.hive.ql.io.orc.OrcSerde'
            STORED AS INPUTFORMAT 'org.apache.hadoop.hive.ql.io.orc.OrcInputFormat'
            OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.orc.OrcOutputFormat'
            LOCATION 'hdfs://warehouse/dw_conan_dim.db/dim_eng_user_extend_da'
            TBLPROPERTIES ('spark.sql.sources.schema.part.0'='{"type":"struct"}');
        "#;

        let schema = parse_schema_ddl(ddl, Dialect::Hive).expect("Hive DDL should load");
        assert_eq!(schema.tables.len(), 1);
        let table = &schema.tables[0];
        assert_eq!(table.schema.as_deref(), Some("dw_conan_dim"));
        assert_eq!(table.name, "dim_eng_user_extend_da");
        assert_eq!(
            table
                .columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["user_id", "name", "dt"]
        );
    }

    #[test]
    fn test_parse_hive_column_comment_with_backslash_escaped_quotes() {
        let ddl = r#"
            CREATE EXTERNAL TABLE `dw_conan_ads.ads_oral_season_user_week_detail_da`(
                `user_id` string COMMENT 'learner \'hist\' identifier',
                `course_id` bigint COMMENT 'course key'
            )
            COMMENT 'weekly detail'
            PARTITIONED BY (`dt` string COMMENT 'partition date');
        "#;

        let schema = parse_schema_ddl(ddl, Dialect::Hive)
            .expect("escaped Hive column comments should not reject the schema");
        let table = &schema.tables[0];
        assert_eq!(
            table
                .columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["user_id", "course_id", "dt"]
        );
    }

    #[test]
    fn test_normalize_hive_escaped_quotes_preserves_even_backslashes_and_contexts() {
        let ddl = r#"
            CREATE TABLE `quoted\'name` (
                `value` string COMMENT 'nested \'hist\' and \\ path'
            );
            -- COMMENT 'comment \'hist\''
            /* COMMENT 'block \'hist\'' */
        "#;

        let normalized = normalize_hive_escaped_quotes(ddl);
        assert!(normalized.contains("COMMENT 'nested ''hist'' and \\\\ path'"));
        assert!(normalized.contains("`quoted\\'name`"));
        assert!(normalized.contains("-- COMMENT 'comment \\'hist\\''"));
        assert!(normalized.contains("/* COMMENT 'block \\'hist\\'' */"));
    }

    #[test]
    fn test_normalize_hive_escaped_quotes_leaves_plain_ddl_unchanged() {
        let ddl = "CREATE TABLE dw.example (id bigint COMMENT 'ordinary column') PARTITIONED BY (dt string);";
        assert_eq!(normalize_hive_escaped_quotes(ddl), ddl);
    }

    #[test]
    fn test_parse_hive_escaped_quote_with_unicode_preserves_partition_structure() {
        let ddl = r#"
            CREATE EXTERNAL TABLE `dw.中文表`(
                `名称` string COMMENT '包含 \'引号\' 的中文说明'
            ) PARTITIONED BY (`日期` string COMMENT '分区');
        "#;

        let schema = parse_schema_ddl(ddl, Dialect::Hive)
            .expect("Unicode Hive comment with an escaped quote should parse");
        let table = &schema.tables[0];
        assert_eq!(table.name, "中文表");
        assert_eq!(
            table
                .columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["名称", "日期"]
        );
    }

    #[test]
    fn test_parse_invalid_ddl_returns_error() {
        let ddl = "THIS IS NOT VALID SQL AT ALL ;;;";

        let result = parse_schema_ddl(ddl, Dialect::Generic);
        assert!(result.is_err());

        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("Failed to parse schema DDL"),
            "Expected error message to mention parsing failure, got: {}",
            err_msg
        );
    }
}
