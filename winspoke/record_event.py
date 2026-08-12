#!/usr/bin/env python3
"""session-monitor Windows 스포크 — 훅 디스패처 + export (bash 구현의 Python 포팅).

사용:
  record_event.py <표준이벤트> [에이전트]   # Claude 훅에서 직접 (예: SessionStart claude)
  record_event.py native <에이전트>         # codex처럼 네이티브 이벤트명 번역이 필요할 때
  record_event.py export                    # reap 후 활성 세션 JSON (허브 smon pull용)

stdin: 훅 JSON (session_id/cwd/transcript_path 공통). 어떤 실패든 exit 0 (세션 방해 금지).
대화 내용 필드는 DB에 저장하지 않는다. stdlib만 사용 (Windows pid 추적은 ctypes Toolhelp).
macOS/Linux에서도 동작하지만 그쪽 프로덕션은 아직 bash 구현(hooks/record-event.sh)이 담당.
"""
import json
import os
import sqlite3
import subprocess
import sys
import time

DB = os.path.join(os.path.expanduser("~"), "dev", "session-monitor", "sessions.db")
AGENT_EXES = ("claude", "codex", "agy")
STRIP_FIELDS = ("prompt", "last_assistant_message", "last-assistant-message",
                "input_messages", "input-messages")

STATE_MAP = {
    # SessionStart = 시작/resume 직후 입력 대기. RUNNING은 UserPromptSubmit부터.
    "SessionStart": "WAITING_INPUT", "UserPromptSubmit": "RUNNING",
    "Stop": "WAITING_INPUT", "Notification": "NEEDS_ATTENTION",
    "SessionEnd": "ENDED",
}
# 네이티브 이벤트 → 표준 이벤트 (hooks/agent-event.sh와 동일하게 유지할 것)
NATIVE_MAP = {
    ("codex", "SessionStart"): "SessionStart",
    ("codex", "UserPromptSubmit"): "UserPromptSubmit",
    ("codex", "Stop"): "Stop",
    ("codex", "PermissionRequest"): "Notification",
    ("antigravity", "PreInvocation"): "UserPromptSubmit",
    ("antigravity", "PostToolUse"): "UserPromptSubmit",
    ("antigravity", "PostInvocation"): "Stop",
    ("antigravity", "Stop"): "SessionEnd",
}


def process_table():
    """{pid: (ppid, exe소문자)} — Windows는 ctypes Toolhelp, POSIX는 ps."""
    table = {}
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class PE32(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                ("szExeFile", ctypes.c_wchar * 260),
            ]

        k32 = ctypes.windll.kernel32
        snap = k32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
        if snap == -1:
            return table
        try:
            e = PE32()
            e.dwSize = ctypes.sizeof(PE32)
            ok = k32.Process32FirstW(snap, ctypes.byref(e))
            while ok:
                exe = e.szExeFile.lower()
                exe = exe[:-4] if exe.endswith(".exe") else exe
                table[int(e.th32ProcessID)] = (int(e.th32ParentProcessID), exe)
                ok = k32.Process32NextW(snap, ctypes.byref(e))
        finally:
            k32.CloseHandle(snap)
    else:
        try:
            out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="],
                                 capture_output=True, text=True, timeout=5).stdout
            for line in out.splitlines():
                parts = line.split(None, 2)
                if len(parts) == 3:
                    table[int(parts[0])] = (int(parts[1]),
                                            os.path.basename(parts[2]).lower())
        except Exception:
            pass
    return table


def find_agent_pid(table):
    """조상 중 실행파일이 AGENT_EXES인 첫 프로세스 (최대 8단계)."""
    p = os.getppid()
    for _ in range(8):
        if p not in table or p <= 1:
            return None
        ppid, exe = table[p]
        if exe in AGENT_EXES:
            return p
        p = ppid
    return None


def record(event, agent):
    payload = json.load(sys.stdin)
    sid = payload.get("session_id") or ""
    if not sid:
        return
    cwd = payload.get("cwd") or ""
    if event == "native":
        agent, event = agent, None
        event = NATIVE_MAP.get((agent, payload.get("hook_event_name") or ""))
        if not event:
            return
    state = STATE_MAP.get(event)
    # idle 알림은 주의 요청이 아니다 — 상태 유지 (진짜 빨강은 permission 계열만)
    if event == "Notification" and payload.get("notification_type") == "idle_prompt":
        state = None
    for f in STRIP_FIELDS:
        payload.pop(f, None)
    now = int(time.time())
    pid = find_agent_pid(process_table())

    db = sqlite3.connect(DB, timeout=3)
    db.execute("PRAGMA busy_timeout=500")
    new = not db.execute("SELECT 1 FROM sessions WHERE session_id=?",
                         (sid,)).fetchone()
    branch = source = None
    if event == "SessionStart" or new:
        try:
            r = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                               capture_output=True, text=True, timeout=3)
            branch = r.stdout.strip() or None
        except Exception:
            pass
        source = os.environ.get("TERM_PROGRAM") or \
            ("windows" if os.name == "nt" else "unknown")
    db.execute("""
        INSERT INTO sessions (session_id, agent, project_path, git_branch, source,
                              started_at, last_event_at, state, pid)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          last_event_at=excluded.last_event_at,
          state=COALESCE(excluded.state, state),
          pid=CASE WHEN ?='SessionStart' THEN excluded.pid
                   ELSE COALESCE(pid, excluded.pid) END,
          ended_at=CASE WHEN ?='SessionEnd' THEN excluded.last_event_at ELSE ended_at END,
          git_branch=COALESCE(excluded.git_branch, git_branch),
          source=COALESCE(excluded.source, source)""",
               (sid, agent, cwd, branch, source, now, now,
                state or "RUNNING", pid, event, event))
    if event == "UserPromptSubmit":  # 턴 시작 = 직전 분류(phase) 무효화 (DESIGN-tint v2)
        db.execute("UPDATE sessions SET phase='' WHERE session_id=?", (sid,))
    db.execute("INSERT INTO events (session_id, event_type, payload_json, created_at) "
               "VALUES (?,?,?,?)", (sid, event, json.dumps(payload), now))
    db.commit()


def export():
    db = sqlite3.connect(DB, timeout=3)
    db.execute("PRAGMA busy_timeout=500")
    now, table = int(time.time()), process_table()
    for sid, pid in db.execute("SELECT session_id, pid FROM sessions "
                               "WHERE state != 'ENDED' AND pid IS NOT NULL"):
        if table.get(pid, (0, ""))[1] in AGENT_EXES:
            continue
        db.execute("UPDATE sessions SET state='ENDED', ended_at=? WHERE session_id=?",
                   (now, sid))
        db.execute("INSERT INTO events (session_id, event_type, payload_json, created_at)"
                   " VALUES (?, 'Reaped', ?, ?)",
                   (sid, json.dumps({"reason": f"process {pid} dead"}), now))
    db.commit()
    cols = ("session_id", "agent", "project_path", "git_branch", "state",
            "last_event_at", "pid", "summary", "cmux_ws", "phase")
    rows = db.execute(f"SELECT {','.join(cols)} FROM sessions "
                      "WHERE state != 'ENDED'").fetchall()
    print(json.dumps([dict(zip(cols, r)) for r in rows], ensure_ascii=False))


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "export":
            export()
        else:
            record(sys.argv[1] if len(sys.argv) > 1 else "Unknown",
                   sys.argv[2] if len(sys.argv) > 2 else "claude")
    except Exception:
        pass  # 훅은 세션을 방해하지 않는다
    sys.exit(0)
