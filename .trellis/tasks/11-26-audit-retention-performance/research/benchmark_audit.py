"""Reproducible loopback HTTP benchmark. Owns and removes its DB and servers."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import socket
import sqlite3
import statistics
import subprocess
import tempfile
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[4]
    report = {"environment": {"platform": platform.platform(), "machine": platform.machine(),
                              "build": "cargo debug, serve; loopback HTTP; warm median of 5",
                              "rows": 652188, "expiredRows": 625193, "jsonPayloadBytes": 2048},
              "phases": {}, "processes": []}
    now = dt.datetime.now(dt.timezone.utc)
    iso = lambda value: value.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    cutoff = iso(now - dt.timedelta(days=7))
    admin_token = secrets.token_urlsafe(40)
    with tempfile.TemporaryDirectory(prefix="flowscope-audit-benchmark-") as directory:
        directory = Path(directory)
        db = directory / "audit.db"
        source = (repo / "crates/flowscope-cli/src/server/audit.rs").read_text()
        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        for name in ("CREATE_TABLE_SQL", "CREATE_INDEXES_SQL"):
            conn.executescript(re.search(r"const " + name + r': &str = r#"(.*?)"#;', source, re.S)[1])
        conn.executescript("""
            CREATE TABLE audit_settings(id INTEGER PRIMARY KEY,retention_days INTEGER);
            INSERT INTO audit_settings VALUES(1,3650);
            CREATE TABLE lineage_events(id TEXT PRIMARY KEY,principal_id TEXT NOT NULL,token_id TEXT NOT NULL,
                action TEXT NOT NULL,body TEXT NOT NULL,content_hash TEXT NOT NULL,status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,next_attempt INTEGER NOT NULL DEFAULT 0,outcome TEXT,
                last_error TEXT,created_at TEXT NOT NULL);
            CREATE TABLE audit_sql_type_backfill(id INTEGER PRIMARY KEY,last_id INTEGER,upper_id INTEGER,completed INTEGER);
            INSERT INTO audit_sql_type_backfill VALUES(1,652188,652188,1);
        """)
        payload = json.dumps({"sqlType": "select", "payload": "x" * 2048})
        started = time.perf_counter()
        insert = """INSERT INTO audit_log(id,ts,client_ip,endpoint,dialect,sql_text,sql_hash,sql_len,
                    success,duration_ms,sql_type,result_json,principal_id,event_id,source_name)
                    VALUES(?,?,'127.0.0.1','/api/analyze','Hive',?,?,?,1,1,?,?,?, ?,?)"""
        for batch_start in range(1, 652189, 2000):
            values = []
            events = []
            for i in range(batch_start, min(batch_start + 2000, 652189)):
                age = (30 - 20 * i / 625193) if i <= 625193 else (6 - 5 * (i - 625193) / 26995)
                timestamp = iso(now - dt.timedelta(days=age))
                event = f"event-{i}" if i % 500 == 0 else None
                if event:
                    events.append((event, timestamp))
                sql = "SELECT id FROM sample WHERE id=" + str(i) + " /*" + "s" * 512 + "*/"
                values.append((i, timestamp, sql, str(i), len(sql),
                               ("SELECT", "INSERT INTO", "INSERT OVERWRITE")[i % 3],
                               payload, "bench", event, f"job-{i % 1000}"))
            conn.executemany(insert, values)
            conn.executemany("""INSERT INTO lineage_events(id,principal_id,token_id,action,body,
                               content_hash,status,created_at)
                               VALUES(?,'bench','bench','publish','{}','fixture','committed',?)""", events)
            conn.commit()
        report["fixtureSeconds"] = time.perf_counter() - started
        report["databaseBytes"] = db.stat().st_size
        conn.close()
        print(json.dumps({"fixtureSeconds": report["fixtureSeconds"],
                          "databaseBytes": report["databaseBytes"]}), flush=True)
        config = directory / "lineage.json"
        config.write_text(json.dumps({"stateDb": str(db), "adminTokenEnv": "AUDIT_BENCH_ADMIN",
            "neo4j": {"uri": "127.0.0.1:9", "user": "neo4j", "passwordEnv": "AUDIT_BENCH_NEO4J",
                      "database": "neo4j", "environment": "test"}}))

        def run_phase(name, binary):
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            base = f"http://127.0.0.1:{port}"
            def request(path, body=None, token=admin_token):
                headers = {"Authorization": "Bearer " + token}
                data = None if body is None else json.dumps(body).encode()
                if data:
                    headers["Content-Type"] = "application/json"
                with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers),
                                            timeout=40) as response:
                    return json.load(response)
            env = dict(os.environ, AUDIT_BENCH_ADMIN=admin_token, AUDIT_BENCH_NEO4J="isolated-unused-password")
            log = directory / f"{name}.log"
            with log.open("w") as handle:
                proc = subprocess.Popen([binary, "--serve", "--host", "127.0.0.1", "--port", str(port),
                    "--audit-log", str(db), "--lineage-config", str(config)], stdout=handle,
                    stderr=subprocess.STDOUT, env=env, cwd=directory)
            started = time.perf_counter()
            try:
                deadline = time.monotonic() + 40
                while True:
                    try:
                        request("/api/health")
                        break
                    except Exception:
                        if proc.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError(log.read_text())
                        time.sleep(0.1)
                phase = {"startupMs": (time.perf_counter() - started) * 1000, "queries": {}}
                if name == "before":
                    request("/api/lineage/policies", {"id":"bench","name":"bench","kind":"scheduler",
                            "enabled":True,"action":"publish","revision":0})
                owner_token = request("/api/lineage/tokens", {"principalId": "bench"})["token"]
                if name == "after":
                    index_started = time.perf_counter()
                    while True:
                        with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as read:
                            ready = read.execute("SELECT count(*) FROM sqlite_master WHERE name='idx_audit_sql_type_ts'").fetchone()[0]
                        if ready:
                            break
                        assert time.monotonic() < deadline, "index setup timed out"
                        time.sleep(0.1)
                    phase["indexReadyMs"] = (time.perf_counter() - index_started) * 1000
                queries = [
                    ("list", "", admin_token),
                    ("select", "&sql_type=SELECT", admin_token),
                    ("select_page_100", "&sql_type=SELECT&offset=4950", admin_token),
                    ("time", "&from=" + cutoff, admin_token),
                    ("select_time", "&sql_type=SELECT&from=" + cutoff, admin_token),
                    ("committed", "&lineage_status=committed", admin_token),
                    ("select_committed", "&sql_type=SELECT&lineage_status=committed", admin_token),
                    ("owner_select", "&sql_type=SELECT", owner_token),
                ]
                for key, query, token in queries:
                    request("/api/audit?limit=50" + query, token=token)
                    samples = []
                    for _ in range(5):
                        before = time.perf_counter()
                        body = request("/api/audit?limit=50" + query, token=token)
                        samples.append((time.perf_counter() - before) * 1000)
                    phase["queries"][key] = {"medianMs": statistics.median(samples),
                                             "samplesMs": samples, "total": body["total"],
                                             "ids": [r["id"] for r in body["records"]]}
                if name == "after":
                    cleanup_start = time.perf_counter()
                    request("/api/audit/settings", {"retentionDays": 7})
                    expected = 26995
                    samples = []
                    while True:
                        health_start = time.perf_counter()
                        request("/api/health")
                        samples.append((time.perf_counter() - health_start) * 1000)
                        page = request("/api/audit?limit=1")
                        if page["total"] == expected:
                            break
                        assert time.perf_counter() - cleanup_start < 600, "cleanup did not finish"
                        time.sleep(1)
                    phase["cleanupSeconds"] = time.perf_counter() - cleanup_start
                    phase["healthDuringCleanupMaxMs"] = max(samples)
                    phase["retainedRows"] = page["total"]
                    phase["expiredDetailStatus"] = None
                    try:
                        request("/api/audit/1")
                    except urllib.error.HTTPError as error:
                        phase["expiredDetailStatus"] = error.code
                    assert phase["expiredDetailStatus"] == 404
                    phase["afterCleanup"] = {}
                    for key, query, token in queries:
                        samples = []
                        for _ in range(5):
                            before = time.perf_counter()
                            body = request("/api/audit?limit=50" + query, token=token)
                            samples.append((time.perf_counter()-before)*1000)
                        phase["afterCleanup"][key] = {"medianMs":statistics.median(samples), "total":body["total"]}
                report["phases"][name] = phase
                print(json.dumps({"phase": name, "results": phase}), flush=True)
            finally:
                if proc.poll() is None:
                    proc.send_signal(signal.SIGINT)
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)
                report["processes"].append({"pid":proc.pid,"returncode":proc.returncode})
                print(json.dumps({"stopped":proc.pid,"returncode":proc.returncode}), flush=True)
        try:
            run_phase("before", str(Path(args.before).resolve()))
            run_phase("after", str(Path(args.after).resolve()))
            for key, before in report["phases"]["before"]["queries"].items():
                after = report["phases"]["after"]["queries"][key]
                assert before["total"] == after["total"] and before["ids"] == after["ids"], key
            report["sameDataResultsMatch"] = True
        finally:
            Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2))
    report["temporaryDatabaseRemoved"] = not db.exists()
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
