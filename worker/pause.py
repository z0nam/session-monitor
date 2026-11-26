#!/usr/bin/env python3
"""요약 일시정지 — Ollama 를 잠깐 비워야 할 때(LLM 시뮬레이션 등) 요약 패스만 멈춘다.

상태는 config 테이블 'pause_until'(epoch 초) 한 키. 그 시각이 지나면 자동 재개다
(따로 지울 필요 없음 — 지난 값은 '정지 아님'으로 읽힌다).

  python3 worker/pause.py pause [기간]       # 기본 2h. 3h · 90m · 1h30m · 45(=분)
  python3 worker/pause.py resume
  python3 worker/pause.py status             # 정지 중이면 '요약 일시정지 중(~HH:MM까지)' 한 줄
  python3 worker/pause.py until              # pause_until 값만 (없거나 지났으면 0)
  python3 worker/pause.py sync <epoch>       # 허브가 원격에 상태를 맞출 때(smon export --pause-until)

멈춰도 알림·reap·탭 색칠·리포트·로그 순환은 그대로 돈다(summarize.py 가 요약만 건너뜀).
Ollama 서비스 자체는 내리지 않는다 — 모델만 keep_alive=0 으로 메모리에서 내린다.
stdlib 만 사용.
"""
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request

KEY = "pause_until"
DEFAULT = "2h"
DEFAULT_MODEL = "qwen3:30b-a3b"   # summarize.py 와 같은 기본값


def _resolve_db():
    if os.environ.get("SMON_DB"):
        return os.environ["SMON_DB"]
    new = os.path.expanduser("~/.local/share/smon/sessions.db")
    return new if os.path.isfile(new) else os.path.expanduser("~/dev/session-monitor/sessions.db")


def parse_duration(s):
    """'3h' '90m' '1h30m' '45s' '45'(분) → 초. 잘못된 값이면 ValueError."""
    s = (s or "").strip().lower()
    if re.fullmatch(r"\d+", s):
        sec = int(s) * 60
    else:
        m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", s)
        if not s or not m or not any(m.groups()):
            raise ValueError(f"기간 형식 오류: {s!r} (예: 3h, 90m, 1h30m)")
        h, mi, se = (int(x or 0) for x in m.groups())
        sec = h * 3600 + mi * 60 + se
    if sec <= 0:
        raise ValueError("기간은 0보다 커야 합니다")
    return sec


def _cfg(db, key, default=None):
    row = db.execute("SELECT value FROM config WHERE key=?", (key,)).fetchone()
    return row[0] if row and row[0] is not None else default


def paused_until(db, now=None):
    """정지 중이면 만료 epoch, 아니면 0."""
    now = int(time.time()) if now is None else now
    try:
        until = int(_cfg(db, KEY, "0") or 0)
    except ValueError:
        return 0
    return until if until > now else 0


def set_until(db, until):
    db.execute("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", (KEY, str(int(until))))
    db.commit()


def status_line(db, now=None):
    until = paused_until(db, now)
    if not until:
        return ""
    t = time.localtime(until)
    same_day = time.strftime("%F", t) == time.strftime("%F", time.localtime(now or time.time()))
    when = time.strftime("%H:%M" if same_day else "%m/%d %H:%M", t)
    return f"요약 일시정지 중(~{when}까지) — 재개: smon resume"


def unload_model(db, timeout=10):
    """요약 모델을 Ollama 메모리에서 내린다 (keep_alive=0). 성공 여부 반환, 실패해도 예외 없음."""
    url = _cfg(db, "ollama_url") or os.environ.get("SMON_OLLAMA_URL", "http://localhost:11434")
    model = _cfg(db, "model", DEFAULT_MODEL)
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/generate",
        json.dumps({"model": model, "keep_alive": 0}).encode(),
        {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
        return True, f"{model} 언로드 요청 완료 ({url})"
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return False, f"{model} 언로드 실패 ({url}): {e}"


def main(argv):
    if not argv:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    db = sqlite3.connect(_resolve_db(), timeout=5)
    db.execute("PRAGMA busy_timeout=3000")
    now = int(time.time())
    if cmd == "pause":
        try:
            sec = parse_duration(args[0] if args else DEFAULT)
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        set_until(db, now + sec)
        print(status_line(db, now))
        if "--no-unload" not in args:
            print(unload_model(db)[1])
    elif cmd == "resume":
        was = paused_until(db, now)
        set_until(db, 0)
        print("요약 재개" if was else "정지 상태가 아니었음 — 그대로 진행")
    elif cmd == "status":
        line = status_line(db, now)
        if line:
            print(line)
    elif cmd == "until":
        print(paused_until(db, now))
    elif cmd == "sync":
        # 허브가 준 값으로 맞춤. 늘리든 줄이든(=resume) 허브 값이 기준. 새로 정지되면 모델 언로드.
        try:
            until = int(args[0])
        except (IndexError, ValueError):
            print("usage: pause.py sync <epoch>", file=sys.stderr)
            return 2
        before = paused_until(db, now)
        if until != (before or 0) and not (until <= now and not before):
            set_until(db, until)
        if until > now and not before:
            unload_model(db)
    else:
        print(f"알 수 없는 명령: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
