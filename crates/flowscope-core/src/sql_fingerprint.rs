//! Conservative SQL template identity, computed before lossy Hive preprocessing.
//!
//! This deliberately canonicalizes tokens rather than claiming SQL equivalence:
//! literals, map keys, identifier quoting, statement/file order and hints survive.
//! Runtime values are never inferred from arbitrary literals. Callers must send
//! the unrendered template; rendered SQL and dynamic object bindings are separate
//! provenance. Keep this independent of node IDs and release/version identities.

use crate::types::{AnalyzeRequest, CaseSensitivity, Dialect};
use regex::Regex;
use sha2::{Digest, Sha256};
use sqlparser::tokenizer::{Token, Tokenizer, Whitespace};
use std::collections::HashMap;
use std::sync::OnceLock;

pub(crate) const VERSION: &str = "flowscope-sql-v1";
const MAX_INPUT_BYTES: usize = 10 * 1024 * 1024;

pub(crate) fn compute(request: &AnalyzeRequest) -> Option<String> {
    // Match collect_statements: files in caller order, followed by inline SQL.
    let inputs: Vec<&str> = request
        .files
        .iter()
        .flatten()
        .map(|file| file.content.as_str())
        .chain(std::iter::once(request.sql.as_str()))
        .collect();
    let length = inputs
        .iter()
        .try_fold(0usize, |sum, sql| sum.checked_add(sql.len()))?;
    if length > MAX_INPUT_BYTES {
        return None;
    }

    let mut digest = Sha256::new();
    frame(&mut digest, VERSION);
    frame(&mut digest, &format!("{:?}", request.dialect));
    let dialect = request.dialect.to_sqlparser_dialect();
    let mut has_statements = false;
    let mut parameters = Parameters::default();
    for sql in inputs {
        let tokens = Tokenizer::new(dialect.as_ref(), sql)
            .with_unescape(false)
            .tokenize()
            .ok()?;
        // Ordinary comments/whitespace disappear, executable comments and
        // optimizer hints remain. Tokenization protects quoted semicolons.
        let tokens: Vec<Token> = tokens
            .into_iter()
            .filter(|token| match token {
                Token::Whitespace(Whitespace::MultiLineComment(body)) => {
                    body.starts_with('+') || body.starts_with('!')
                }
                Token::Whitespace(_) | Token::EOF => false,
                _ => true,
            })
            .collect();
        let mut source_started = false;
        for statement in tokens.split(|token| matches!(token, Token::SemiColon)) {
            if statement.is_empty() || is_resource_setting(statement, request.dialect) {
                continue;
            }
            if !source_started {
                frame(&mut digest, "source");
                source_started = true;
            }
            frame(&mut digest, "statement");
            has_statements = true;
            let mut index = 0;
            while index < statement.len() {
                if let Some((name, consumed)) = bare_parameter(&statement[index..]) {
                    frame(&mut digest, "parameter");
                    frame(&mut digest, &parameters.id(&name));
                    index += consumed;
                    continue;
                }
                canonical_token(
                    &statement[index],
                    request.dialect,
                    &mut parameters,
                    &mut digest,
                );
                index += 1;
            }
        }
    }
    has_statements.then(|| format!("{:x}", digest.finalize()))
}

fn frame(digest: &mut Sha256, value: &str) {
    // Length framing avoids collisions caused by concatenation/token boundaries.
    digest.update((value.len() as u64).to_be_bytes());
    digest.update(value.as_bytes());
}

#[derive(Default)]
struct Parameters {
    names: HashMap<String, usize>,
}

impl Parameters {
    fn id(&mut self, name: &str) -> String {
        let next = self.names.len();
        self.names
            .entry(name.to_owned())
            .or_insert(next)
            .to_string()
    }

    fn text(&mut self, value: &str, digest: &mut Sha256) {
        // Only simple variable references are parameters. Expressions/macros
        // such as {{ ref('table') }} and {{ x + 1 }} retain their actual text.
        static VARIABLES: OnceLock<Regex> = OnceLock::new();
        let pattern = VARIABLES.get_or_init(|| {
            Regex::new(
                r"\$\{\s*([A-Za-z_][A-Za-z0-9_.:]*)\s*\}|\{\{\{\s*([A-Za-z_][A-Za-z0-9_.:]*)\s*\}\}\}|\{\{\s*([A-Za-z_][A-Za-z0-9_.:]*)\s*\}\}",
            )
            .expect("static parameter regex")
        });
        let mut end = 0;
        for captures in pattern.captures_iter(value) {
            let whole = captures.get(0).expect("whole parameter match");
            frame(digest, "text");
            frame(digest, &value[end..whole.start()]);
            frame(digest, "parameter");
            let name = captures.iter().skip(1).flatten().next().expect("name");
            frame(digest, &self.id(name.as_str()));
            end = whole.end();
        }
        frame(digest, "text");
        frame(digest, &value[end..]);
    }
}

fn canonical_token(
    token: &Token,
    dialect: Dialect,
    parameters: &mut Parameters,
    digest: &mut Sha256,
) {
    match token {
        Token::Word(word) => {
            if let Some(quote) = word.quote_style {
                if dialect == Dialect::Hive && quote == '"' {
                    frame(digest, "string");
                    parameters.text(&word.value, digest);
                    return;
                }
                frame(digest, "quoted-word");
                frame(digest, &quote.to_string());
                // A dynamic quoted identifier keeps its fixed surrounding text.
                parameters.text(&word.value, digest);
            } else {
                if word.value.contains("${") || word.value.contains("{{") {
                    frame(digest, "word-template");
                    parameters.text(&word.value, digest);
                    return;
                }
                frame(digest, "word");
                let word = match dialect.default_case_sensitivity() {
                    CaseSensitivity::Lower => word.value.to_lowercase(),
                    CaseSensitivity::Upper => word.value.to_uppercase(),
                    CaseSensitivity::Exact | CaseSensitivity::Dialect => {
                        if word.keyword == sqlparser::keywords::Keyword::NoKeyword {
                            word.value.clone()
                        } else {
                            word.value.to_uppercase()
                        }
                    }
                };
                frame(digest, &word);
            }
        }
        Token::SingleQuotedString(value) | Token::DoubleQuotedString(value) => {
            // Hive accepts both quote styles for strings. Other dialects retain
            // their token kind (double quotes often denote identifiers).
            frame(
                digest,
                if dialect == Dialect::Hive || matches!(token, Token::SingleQuotedString(_)) {
                    "string"
                } else {
                    "double-string"
                },
            );
            parameters.text(value, digest);
        }
        Token::Whitespace(Whitespace::MultiLineComment(body)) => {
            frame(digest, "executable-comment");
            frame(digest, body);
        }
        _ => {
            // Preserve numeric/business constants, operators and all other
            // literal kinds verbatim. A token display never includes trivia.
            frame(digest, "token");
            frame(digest, &token.to_string());
        }
    }
}

fn bare_parameter(tokens: &[Token]) -> Option<(String, usize)> {
    // Hive's dialect can tokenize an entire ${name} as one identifier.
    if let Some(Token::Word(word)) = tokens.first() {
        if word.quote_style.is_none() {
            if let Some(name) = simple_parameter(&word.value) {
                return Some((name.to_owned(), 1));
            }
        }
    }
    let mut name = String::new();
    let (start, closing) = match tokens.first()? {
        Token::Word(word) if word.quote_style.is_none() && word.value.starts_with("${") => {
            name.push_str(&word.value[2..]);
            if !name.is_empty() && !valid_parameter_name(&name) {
                return None;
            }
            (1, 1)
        }
        Token::Placeholder(prefix) if prefix == "$" => {
            if !matches!(tokens.get(1), Some(Token::LBrace)) {
                return None;
            }
            (2, 1)
        }
        Token::Word(word) if word.quote_style.is_none() && word.value == "$" => {
            if !matches!(tokens.get(1), Some(Token::LBrace)) {
                return None;
            }
            (2, 1)
        }
        Token::LBrace if matches!(tokens.get(1), Some(Token::LBrace)) => {
            if matches!(tokens.get(2), Some(Token::LBrace)) {
                (3, 3)
            } else {
                (2, 2)
            }
        }
        _ => return None,
    };
    let mut index = start;
    let suffix = "}".repeat(closing);
    let mut expects_word = name.is_empty();
    while let Some(token) = tokens.get(index) {
        match token {
            Token::Word(word) if word.quote_style.is_none() && expects_word => {
                // Hive identifiers may absorb the closing braces (db}}).
                if let Some(body) = word.value.strip_suffix(&suffix) {
                    name.push_str(body);
                    return valid_parameter_name(&name).then_some((name, index + 1));
                }
                name.push_str(&word.value);
                expects_word = false;
            }
            Token::Period | Token::Colon if !expects_word => {
                name.push_str(&token.to_string());
                expects_word = true;
            }
            _ => break,
        }
        index += 1;
    }
    if !valid_parameter_name(&name)
        || expects_word
        || !(0..closing).all(|offset| matches!(tokens.get(index + offset), Some(Token::RBrace)))
    {
        return None;
    }
    Some((name, index + closing))
}

fn simple_parameter(value: &str) -> Option<&str> {
    let name = value.strip_prefix("${")?.strip_suffix('}')?.trim();
    valid_parameter_name(name).then_some(name)
}

fn valid_parameter_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_')
        || !chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | ':'))
    {
        return false;
    }
    true
}

fn is_resource_setting(tokens: &[Token], dialect: Dialect) -> bool {
    if dialect != Dialect::Hive
        || !matches!(tokens.first(), Some(Token::Word(word)) if word.value.eq_ignore_ascii_case("set"))
    {
        return false;
    }
    let Some(equals) = tokens.iter().position(|token| matches!(token, Token::Eq)) else {
        return false;
    };
    // A missing semicolon must never let a leading SET hide the following SQL.
    if tokens[equals + 1..].iter().any(|token| {
        matches!(token, Token::Word(word) if matches!(
            word.keyword,
            sqlparser::keywords::Keyword::SELECT
                | sqlparser::keywords::Keyword::INSERT
                | sqlparser::keywords::Keyword::WITH
                | sqlparser::keywords::Keyword::CREATE
                | sqlparser::keywords::Keyword::UPDATE
                | sqlparser::keywords::Keyword::DELETE
                | sqlparser::keywords::Keyword::SET
                | sqlparser::keywords::Keyword::USE
        ))
    }) {
        return false;
    }
    let key = tokens[1..equals]
        .iter()
        .map(ToString::to_string)
        .collect::<String>()
        .to_ascii_lowercase();
    // An explicit resource-only allowlist: timezone, USE/database settings,
    // UDF registration and unknown SET directives must not be silently ignored.
    matches!(
        key.as_str(),
        "mapreduce.map.memory.mb"
            | "mapreduce.reduce.memory.mb"
            | "mapreduce.map.java.opts"
            | "mapreduce.reduce.java.opts"
            | "mapreduce.job.reduces"
            | "mapred.map.tasks"
            | "mapred.reduce.tasks"
            | "mapred.child.java.opts"
            | "spark.driver.memory"
            | "spark.driver.cores"
            | "spark.executor.memory"
            | "spark.executor.cores"
            | "spark.executor.instances"
            | "spark.executor.memoryoverhead"
            | "spark.dynamicallocation.enabled"
            | "spark.dynamicallocation.minexecutors"
            | "spark.dynamicallocation.maxexecutors"
            | "tez.task.resource.memory.mb"
            | "tez.task.resource.cpu.vcores"
            | "hive.exec.parallel"
            | "hive.exec.parallel.thread.number"
            | "hive.exec.reducers.bytes.per.reducer"
            | "hive.exec.reducers.max"
            | "spark.sql.shuffle.partitions"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_variable_spellings_are_recognized() {
        let dialect = Dialect::Hive.to_sqlparser_dialect();
        for sql in [
            "${database}",
            "{{db}}",
            "{{{count}}}",
            "${ date }",
            "{{ db }}",
        ] {
            let tokens: Vec<_> = Tokenizer::new(dialect.as_ref(), sql)
                .tokenize()
                .unwrap()
                .into_iter()
                .filter(|token| !matches!(token, Token::Whitespace(_)))
                .collect();
            assert!(bare_parameter(&tokens).is_some(), "{sql}: {tokens:?}");
        }
    }
}
