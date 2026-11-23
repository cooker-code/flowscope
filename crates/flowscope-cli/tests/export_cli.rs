use std::process::Command;

use tempfile::tempdir;

#[test]
fn exports_csv_archive_to_file() {
    let dir = tempdir().expect("temp dir");
    let sql_path = dir.path().join("input.sql");
    let output_path = dir.path().join("lineage.csv.zip");

    std::fs::write(
        &sql_path,
        "SELECT u.id, o.total FROM users u JOIN orders o ON u.id = o.user_id",
    )
    .expect("write sql");

    let status = Command::new(env!("CARGO_BIN_EXE_flowscope"))
        .args([
            "-f",
            "csv",
            "-o",
            output_path.to_str().expect("output path"),
            sql_path.to_str().expect("sql path"),
        ])
        .status()
        .expect("run CLI");

    assert!(status.success());
    let metadata = std::fs::metadata(&output_path).expect("output exists");
    assert!(metadata.len() > 0);
}

#[cfg(not(feature = "duckdb"))]
#[test]
fn duckdb_export_requires_an_explicit_feature_without_creating_output() {
    let dir = tempdir().expect("temp dir");
    let sql_path = dir.path().join("input.sql");
    let output_path = dir.path().join("missing-output").join("lineage.duckdb");
    std::fs::write(&sql_path, "SELECT id FROM users").expect("write sql");

    let output = Command::new(env!("CARGO_BIN_EXE_flowscope"))
        .args([
            "-f",
            "duckdb",
            "-o",
            output_path.to_str().expect("output path"),
            sql_path.to_str().expect("sql path"),
        ])
        .output()
        .expect("run CLI");

    assert_eq!(output.status.code(), Some(66));
    assert!(String::from_utf8_lossy(&output.stderr).contains("--features duckdb"));
    assert!(
        !output_path.parent().expect("output parent").exists(),
        "disabled DuckDB export must not create an output directory or file"
    );
}

#[cfg(feature = "duckdb")]
#[test]
fn exports_duckdb_database_to_file_when_feature_is_enabled() {
    let dir = tempdir().expect("temp dir");
    let sql_path = dir.path().join("input.sql");
    let output_path = dir.path().join("lineage.duckdb");
    std::fs::write(&sql_path, "SELECT id FROM users").expect("write sql");

    let status = Command::new(env!("CARGO_BIN_EXE_flowscope"))
        .args([
            "-f",
            "duckdb",
            "-o",
            output_path.to_str().expect("output path"),
            sql_path.to_str().expect("sql path"),
        ])
        .status()
        .expect("run CLI");

    assert!(status.success());
    let metadata = std::fs::metadata(&output_path).expect("output exists");
    assert!(metadata.len() > 0);
}
