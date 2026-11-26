#!/usr/bin/env python3
"""smon pause/resume 검증 — 임시 DB·가짜 Ollama(로컬 포트)에서만 돈다. 실행: python3 tests/test_pause.py"""
import http.server
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "worker"))
import pause  # noqa: E402


class FakeOllama(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        FakeOllama.calls.append((self.path, json.loads(body)))
        out = b'{"done":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def new_db(path):
    db = sqlite3.connect(path)
    with open(os.path.join(ROOT, "schema.sql")) as f:
        db.executescript(f.read())
    return db


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.HTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        FakeOllama.calls.clear()
        self.d = tempfile.TemporaryDirectory()
        self.dbp = os.path.join(self.d.name, "sessions.db")
        self.db = new_db(self.dbp)
        # 실제 studio Ollama 를 건드리지 않도록 반드시 가짜 서버로
        self.db.executemany("INSERT OR REPLACE INTO config VALUES (?,?)",
                            [("ollama_url", self.url), ("model", "glm-4.7-flash")])
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.d.cleanup()


class ParseDuration(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(pause.parse_duration("3h"), 3 * 3600)
        self.assertEqual(pause.parse_duration("90m"), 90 * 60)
        self.assertEqual(pause.parse_duration("1h30m"), 5400)
        self.assertEqual(pause.parse_duration("45"), 45 * 60)   # 숫자만 = 분
        self.assertEqual(pause.parse_duration(" 2H "), 7200)

    def test_bad(self):
        for bad in ("", "h", "3x", "-1h", "0", "0m", "abc"):
            with self.assertRaises(ValueError, msg=bad):
                pause.parse_duration(bad)


class State(Base):
    def test_until_and_expiry(self):
        now = 1_000_000
        self.assertEqual(pause.paused_until(self.db, now), 0)
        pause.set_until(self.db, now + 60)
        self.assertEqual(pause.paused_until(self.db, now), now + 60)
        self.assertEqual(pause.paused_until(self.db, now + 61), 0)   # 만료 = 자동 재개
        self.assertIn("요약 일시정지 중", pause.status_line(self.db, now))
        self.assertEqual(pause.status_line(self.db, now + 61), "")

    def test_garbage_value_is_not_paused(self):
        self.db.execute("INSERT OR REPLACE INTO config VALUES ('pause_until','x')")
        self.assertEqual(pause.paused_until(self.db), 0)

    def test_unload_payload(self):
        ok, _ = pause.unload_model(self.db)
        self.assertTrue(ok)
        self.assertEqual(FakeOllama.calls,
                         [("/api/generate", {"model": "glm-4.7-flash", "keep_alive": 0})])

    def test_unload_unreachable_does_not_raise(self):
        self.db.execute("INSERT OR REPLACE INTO config VALUES ('ollama_url','http://127.0.0.1:1')")
        ok, msg = pause.unload_model(self.db, timeout=2)
        self.assertFalse(ok)
        self.assertIn("실패", msg)


def cli(dbp, *args):
    env = dict(os.environ, SMON_DB=dbp)
    return subprocess.run([sys.executable, os.path.join(ROOT, "worker", "pause.py"), *args],
                          env=env, capture_output=True, text=True, timeout=30)


class Cli(Base):
    def until(self):
        return int(self.db.execute("SELECT value FROM config WHERE key='pause_until'").fetchone()[0])

    def test_pause_default_and_resume(self):
        t0 = int(time.time())
        r = cli(self.dbp, "pause")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertAlmostEqual(self.until() - t0, 7200, delta=5)
        self.assertEqual(len(FakeOllama.calls), 1)          # 즉시 언로드
        self.assertIn("요약 일시정지 중", cli(self.dbp, "status").stdout)
        cli(self.dbp, "resume")
        self.assertEqual(self.until(), 0)
        self.assertEqual(cli(self.dbp, "status").stdout, "")
        self.assertEqual(cli(self.dbp, "until").stdout.strip(), "0")

    def test_bad_duration(self):
        r = cli(self.dbp, "pause", "3x")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(FakeOllama.calls, [])

    def test_sync(self):
        now = int(time.time())
        cli(self.dbp, "sync", str(now + 600))               # 허브가 정지 → 따라 정지 + 언로드
        self.assertEqual(self.until(), now + 600)
        self.assertEqual(len(FakeOllama.calls), 1)
        cli(self.dbp, "sync", str(now + 600))               # 같은 값 반복 — 재언로드 없음
        self.assertEqual(len(FakeOllama.calls), 1)
        cli(self.dbp, "sync", "0")                          # 허브가 재개 → 따라 재개
        self.assertEqual(self.until(), 0)


class WorkerSkips(Base):
    def test_summarize_pass_skips_when_paused(self):
        import summarize
        now = int(time.time())
        self.db.execute("INSERT INTO sessions (session_id, state, last_event_at) VALUES ('s1','WAITING_INPUT',?)", (now,))
        self.db.execute("INSERT INTO events (session_id, event_type, payload_json, created_at, processed)"
                        " VALUES ('s1','Stop','{\"transcript_path\":\"/nonexistent\"}',?,0)", (now,))
        pause.set_until(self.db, now + 600)
        called = []
        orig = summarize.transcript_excerpt
        summarize.transcript_excerpt = lambda p: called.append(p) or "x"
        try:
            summarize.summarize_pass(self.db)
        finally:
            summarize.transcript_excerpt = orig
        self.assertEqual(called, [])
        self.assertEqual(self.db.execute("SELECT processed FROM events").fetchone()[0], 0)  # 재개 후 처리
        self.assertEqual(FakeOllama.calls, [])


class SmonBash(Base):
    def smon(self, *args):
        env = dict(os.environ, SMON_DB=self.dbp)
        return subprocess.run(["bash", os.path.join(ROOT, "bin", "smon"), *args],
                              env=env, capture_output=True, text=True, timeout=30)

    def test_pause_board_resume_export(self):
        r = self.smon("pause", "90m")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("원격 워커에 전파", r.stdout)       # remote_hosts 없음 = 스포크
        self.assertIn("⏸  요약 일시정지 중", self.smon().stdout)
        self.smon("resume")
        self.assertNotIn("일시정지", self.smon().stdout)
        # export --pause-until: stdout 은 JSON 만, 상태는 맞춰짐
        until = int(time.time()) + 300
        r = self.smon("export", "--pause-until", str(until))
        self.assertEqual(json.loads(r.stdout), [])
        self.assertEqual(pause.paused_until(self.db), until)

    def test_pull_carries_pause_state(self):
        # 가짜 ssh: 받은 원격 명령을 기록하고 빈 export([]) 를 돌려준다
        bindir = os.path.join(self.d.name, "bin")
        os.mkdir(bindir)
        logf = os.path.join(self.d.name, "ssh.log")
        with open(os.path.join(bindir, "ssh"), "w") as f:
            f.write(f'#!/bin/sh\nfor a; do last="$a"; done\necho "$last" >> "{logf}"\necho "[]"\n')
        os.chmod(os.path.join(bindir, "ssh"), 0o755)
        self.db.execute("INSERT OR REPLACE INTO config VALUES ('remote_hosts','fakehost')")
        until = int(time.time()) + 900
        pause.set_until(self.db, until)
        env = dict(os.environ, SMON_DB=self.dbp, PATH=bindir + ":" + os.environ["PATH"])
        r = subprocess.run(["bash", os.path.join(ROOT, "bin", "smon"), "pull"],
                           env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(logf) as f:
            self.assertIn(f"export --pause-until {until}", f.read())


class MidPass(Base):
    def test_pause_during_pass_stops_and_unloads(self):
        import summarize
        now = int(time.time())
        for sid in ("s1", "s2"):
            self.db.execute("INSERT INTO sessions (session_id, state, last_event_at) VALUES (?,'WAITING_INPUT',?)", (sid, now))
            self.db.execute("INSERT INTO events (session_id, event_type, payload_json, created_at, processed)"
                            " VALUES (?,'Stop','{\"transcript_path\":\"/x\"}',?,0)", (sid, now))
        self.db.commit()
        calls = []

        def fake_summarize(model, excerpt):
            calls.append(model)
            pause.set_until(self.db, now + 600)   # 첫 요약 도중 사용자가 smon pause
            return "요약", ""
        orig = (summarize.transcript_excerpt, summarize.summarize)
        summarize.transcript_excerpt, summarize.summarize = (lambda p: "x"), fake_summarize
        try:
            summarize.summarize_pass(self.db)
        finally:
            summarize.transcript_excerpt, summarize.summarize = orig
        self.assertEqual(len(calls), 1)                       # 두 번째 세션은 건너뜀
        self.assertEqual(self.db.execute("SELECT count(*) FROM events WHERE processed=0").fetchone()[0], 1)
        self.assertEqual([c[1].get("keep_alive") for c in FakeOllama.calls], [0])  # 마지막에 다시 언로드


    def test_pause_during_failed_first_call_still_unloads(self):
        import summarize
        now = int(time.time())
        self.db.execute("INSERT INTO sessions (session_id, state, last_event_at) VALUES ('s1','WAITING_INPUT',?)", (now,))
        self.db.execute("INSERT INTO events (session_id, event_type, payload_json, created_at, processed)"
                        " VALUES ('s1','Stop','{\"transcript_path\":\"/x\"}',?,0)", (now,))
        self.db.commit()

        def fake_summarize(model, excerpt):
            pause.set_until(self.db, now + 600)   # 첫 콜 도중 정지 + 콜은 타임아웃(실패)
            return None, ""
        orig = (summarize.transcript_excerpt, summarize.summarize)
        summarize.transcript_excerpt, summarize.summarize = (lambda p: "x"), fake_summarize
        try:
            summarize.summarize_pass(self.db)
        finally:
            summarize.transcript_excerpt, summarize.summarize = orig
        self.assertEqual([c[1].get("keep_alive") for c in FakeOllama.calls], [0])


if __name__ == "__main__":
    unittest.main()
