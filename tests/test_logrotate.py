#!/usr/bin/env python3
"""worker/logrotate.py 검증 — 임시 디렉터리에서만 돈다. 실행: python3 tests/test_logrotate.py"""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worker"))
import logrotate  # noqa: E402


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def write_lines(path, n, width=100):
    with open(path, "a") as f:
        for i in range(n):
            f.write(f"{i:08d} " + "x" * (width - 10) + "\n")


class CopyTruncate(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.d.name, "a.log")

    def tearDown(self):
        self.d.cleanup()

    def test_over_limit_rotates(self):
        write_lines(self.log, 300)                       # 30,000 B
        ino = os.stat(self.log).st_ino
        self.assertTrue(logrotate.copytruncate(self.log, max_bytes=10_000))
        self.assertEqual(os.path.getsize(self.log), 0)
        self.assertEqual(os.stat(self.log).st_ino, ino)  # 같은 inode (mv 아님)
        rot = read(self.log + ".1")
        self.assertLessEqual(len(rot), 10_000)
        self.assertTrue(rot.startswith("00000"))         # 줄 경계에서 시작
        self.assertTrue(rot.endswith("00000299 " + "x" * 90 + "\n"))  # 마지막 줄 보존
        self.assertFalse(os.path.exists(self.log + ".1.tmp"))

    def test_under_limit_untouched(self):
        write_lines(self.log, 50)                        # 5,000 B
        before = read(self.log)
        self.assertFalse(logrotate.copytruncate(self.log, max_bytes=10_000))
        self.assertEqual(read(self.log), before)
        self.assertFalse(os.path.exists(self.log + ".1"))

    def test_missing_file(self):
        self.assertFalse(logrotate.copytruncate(os.path.join(self.d.name, "none.log")))

    def test_second_rotation_overwrites_one_generation(self):
        write_lines(self.log, 300)
        logrotate.copytruncate(self.log, max_bytes=10_000)
        write_lines(self.log, 200)
        logrotate.copytruncate(self.log, max_bytes=10_000)
        files = sorted(os.listdir(self.d.name))
        self.assertEqual(files, ["a.log", "a.log.1"])    # .2 없음

    def test_open_append_handle_keeps_writing_same_file(self):
        # launchd 처럼 O_APPEND 로 열어 둔 데몬 핸들을 흉내낸다
        fd = os.open(self.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            for i in range(300):
                os.write(fd, b"before " + b"y" * 92 + b"\n")
            logrotate.copytruncate(self.log, max_bytes=10_000)
            os.write(fd, b"after-rotate\n")
        finally:
            os.close(fd)
        self.assertEqual(read(self.log, "rb"), b"after-rotate\n")        # 같은 파일, 0부터 이어짐 (구멍 없음)
        self.assertNotIn(b"after-rotate", read(self.log + ".1", "rb"))


class PruneAndSchedule(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.d.cleanup()

    def test_prune_old_only(self):
        old = os.path.join(self.d.name, "2026-01-01.log")
        new = os.path.join(self.d.name, "2026-11-25.log")
        keep = os.path.join(self.d.name, "launchd.err")
        for p in (old, new, keep):
            open(p, "w").close()
        t = time.time() - 100 * 86400
        os.utime(old, (t, t))
        os.utime(keep, (t, t))
        self.assertEqual(logrotate.prune(self.d.name, days=90), 1)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(new))
        self.assertTrue(os.path.exists(keep))            # *.log 만 대상

    def test_run_once_per_interval_and_nonfatal(self):
        home = os.path.join(self.d.name, "home")
        os.makedirs(os.path.join(home, "report", "logs"))
        big = os.path.join(home, "apply-color.log")
        write_lines(big, 300)
        stamp = os.path.join(self.d.name, "logrotate.stamp")
        msgs = []
        kw = dict(log=msgs.append, max_bytes=10_000, files=[big], dirs=[os.path.join(home, "report", "logs")])
        logrotate.run(home, stamp, **kw)
        self.assertEqual(os.path.getsize(big), 0)
        self.assertTrue(os.path.exists(stamp))
        write_lines(big, 300)
        logrotate.run(home, stamp, **kw)
        self.assertGreater(os.path.getsize(big), 10_000)  # 스탬프가 새것이라 건너뜀
        # 스탬프를 쓸 수 없어도 예외가 나가지 않는다
        logrotate.run(home, os.path.join(self.d.name, "no", "such", "stamp"), **kw)
        self.assertTrue(any("stamp failed" in m for m in msgs))


if __name__ == "__main__":
    unittest.main()
