#!/usr/bin/env python3
"""session-monitor Phase 2 — 로컬 LLM 요약 워커 (1패스 후 종료; launchd가 주기 실행).

events.processed=0 인 세션의 transcript 꼬리를 읽어 Ollama로 한 줄 요약 →
sessions.summary 갱신, 해당 events를 processed=1 로 마킹.
모델은 config 테이블 'model' 키 (smon model <이름>으로 교체). stdlib만 사용.
"""
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

DB = os.path.expanduser("~/dev/session-monitor/sessions.db")
OLLAMA = os.environ.get("SMON_OLLAMA_URL", "http://localhost:11434")
DEFAULT_MODEL = "qwen3:30b-a3b"
EXCERPT_CHARS = 6000     # transcript 발췌 상한 (꼬리 우선)
TIMEOUT = 120            # 모델 콜드로드 포함


def log(msg):
    print(f"{time.strftime('%F %T')} {msg}", flush=True)


def _entry_role_text(entry):
    """transcript 한 줄에서 (role, text) 추출. Claude/Codex 형식 모두 지원."""
    # Claude Code: {"type":"user"|"assistant","message":{"content":...}}
    if entry.get("type") in ("user", "assistant"):
        role = entry["type"]
        content = (entry.get("message") or {}).get("content")
    # Codex rollout: {"type":"response_item","payload":{"type":"message","role":...,"content":[...]}}
    elif entry.get("type") == "response_item":
        p = entry.get("payload") or {}
        if p.get("type") != "message" or p.get("role") not in ("user", "assistant"):
            return None
        role, content = p["role"], p.get("content")
    else:
        return None
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = " ".join(b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") in
                        ("text", "input_text", "output_text"))
    else:
        return None
    return role, text.strip()


def transcript_excerpt(path):
    """transcript JSONL 꼬리에서 user/assistant 텍스트만 추출."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 256 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    parts = []
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        rt = _entry_role_text(entry)
        if not rt:
            continue
        role, text = rt
        if text and not text.startswith(("<local-command", "<command-name>",
                                         "<user_instructions>", "<environment_context>",
                                         "<recommended_plugins>")):
            parts.append(f"[{role}] {text[:800]}")
    return "\n".join(parts)[-EXCERPT_CHARS:] or None


def summarize(model, excerpt):
    """(요약, phase) 반환. phase: ''|direction|done — done은 보수적으로."""
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": (
                "다음은 한 AI 코딩 에이전트 세션의 최근 대화 발췌다.\n\n"
                f"{excerpt}\n\n"
                "두 줄로 답하라. 다른 말은 쓰지 마라.\n"
                "1줄: 이 세션의 한국어 한 줄 요약 (60자 이내, 형식: <무슨 작업> — <현재 상황>)\n"
                "2줄: 'PHASE: ' 뒤에 working|direction|done 중 하나.\n"
                "  done = 세션의 목표가 명시적으로 달성·종결됐을 때만 (예: 원인 발견·제거 성공).\n"
                "  direction = 한 단계 일단락됐고 다음 단계·후속 작업이 남아 사용자 지침을 기다림.\n"
                "    에이전트가 사용자에게 질문을 던지고 답을 기다리는 상태도 direction이다.\n"
                "  working = 진행 중이거나 판단이 애매할 때 (기본값).\n"
                "  마지막 발화가 질문·선택지 제시·확인 요청으로 끝나면 절대 done이 아니다."
            ),
        }],
        "stream": False,
        "think": False,
        "keep_alive": "10m",
        "options": {"temperature": 0.2, "num_ctx": 8192, "num_predict": 200},
    }
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(
                f"{OLLAMA}/api/chat",
                json.dumps(payload).encode(),
                {"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                content = json.load(r)["message"]["content"].strip()
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            # thinking 미지원 모델이면 think 키 빼고 1회 재시도
            if attempt == 1 and "think" in body:
                payload.pop("think", None)
                continue
            log(f"ollama http {e.code}: {body[:200]}")
            return None, ""
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f"ollama unreachable: {e}")
            return None, ""
        summary, phase = None, ""
        for line in content.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.upper().lstrip("2줄:. ").startswith("PHASE"):
                low = line.lower()
                phase = ("done" if "done" in low
                         else "direction" if "direction" in low else "")
            elif summary is None:
                summary = line.lstrip("1줄:. ").strip()[:120]
        return summary, phase
    return None, ""


AGY_BRAIN = os.path.expanduser("~/.gemini/antigravity-cli/brain")


def _agy_running():
    import subprocess
    return subprocess.run(["pgrep", "-xq", "agy"], capture_output=True).returncode == 0


def _agy_meta(transcript):
    """transcript 앞부분에서 (첫 요청 한 줄, 프로젝트 경로 추정) — best-effort."""
    title = project = None
    try:
        with open(transcript, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 60 or (title and project):
                    break
                if not title and '"USER_INPUT"' in line:
                    try:
                        c = json.loads(line).get("content", "")
                        s = c.find("<USER_REQUEST>")
                        e = c.find("</USER_REQUEST>")
                        if s >= 0 and e > s:
                            title = " ".join(c[s + 14:e].split())[:100]
                    except ValueError:
                        pass
                if not project and "file:///" in line:
                    m = line.split("file://", 1)[1]
                    cuts = [x for x in (m.find(c) for c in ('"', ")", "`", "\\",
                                                            "<", " ", "'"))
                            if x >= 0] + [len(m)]
                    path = m[:min(cuts)]
                    if path.startswith("/") and "/" in path[1:]:
                        project = os.path.dirname(path)
    except OSError:
        pass
    return title, project


def agy_sync(db):
    """Antigravity(agy) 어댑터 — 훅이 계정 게이트(enable_json_hooks OFF)로 실행되지 않아
    brain/<uuid>/transcript.jsonl 폴링으로 대체. agy만 시간+프로세스 휴리스틱:
    3분 내 갱신=RUNNING, 이후=WAITING_INPUT, 24h 경과 또는 agy 프로세스 전멸=ENDED."""
    if not os.path.isdir(AGY_BRAIN):
        return
    now, alive, n = int(time.time()), _agy_running(), 0
    for uid in os.listdir(AGY_BRAIN):
        t = os.path.join(AGY_BRAIN, uid, ".system_generated", "logs", "transcript.jsonl")
        try:
            m = int(os.path.getmtime(t))
        except OSError:
            continue
        if not alive or now - m > 86400:
            state = "ENDED"
        elif now - m < 180:
            state = "RUNNING"
        else:
            state = "WAITING_INPUT"
        title, project = _agy_meta(t)
        db.execute("""
            INSERT INTO sessions (session_id, agent, project_path, started_at,
                                  last_event_at, state, summary, summary_at, summary_model)
            VALUES (?, 'antigravity', ?, ?, ?, ?, ?, ?, 'agy-transcript')
            ON CONFLICT(session_id) DO UPDATE SET
              last_event_at=excluded.last_event_at, state=excluded.state,
              ended_at=CASE WHEN excluded.state='ENDED' THEN ? ELSE NULL END,
              project_path=COALESCE(excluded.project_path, project_path),
              summary=COALESCE(excluded.summary, summary)""",
                   (uid, project, m, m, state, title, m, now))
        n += 1
    db.commit()
    if n:
        log(f"agy_sync: {n} conversation(s)")


def tint(db, sid):
    """smon-tint v2.1: 원하는 색(tab_want)만 기록. 실제 적용(reconcile)은 세션 컨텍스트의
    훅/smon이 담당 — launchd에서 cmux 소켓 호출은 broken pipe로 실패한다 (실측)."""
    row = db.execute(
        "SELECT state, COALESCE(phase,''), COALESCE(cmux_ws,'')"
        " FROM sessions WHERE session_id=?", (sid,)).fetchone()
    if not row:
        return
    state, phase, ws = row
    desired = ("Red" if state == "NEEDS_ATTENTION"
               else "Green" if state == "WAITING_INPUT" and phase == "done"
               else "Blue" if state == "WAITING_INPUT" and phase == "direction"
               else "")
    if ws:
        db.execute("UPDATE sessions SET tab_want=? WHERE session_id=?", (desired, sid))
        db.commit()


def cfg(db, key, default=None):
    row = db.execute("SELECT value FROM config WHERE key=?", (key,)).fetchone()
    return row[0] if row else default


def _slack_token(env_file):
    try:
        for line in open(env_file):
            if line.startswith("SLACK_BOT_TOKEN"):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def _send_macos(fresh):
    """세션당 알림 배너 1개 (최대 5개). osascript 성공 여부 반환."""
    import subprocess
    ok = False
    for _sid, agent, path, summary in fresh[:5]:
        title = f"smon — [{agent}] {os.path.basename(path or '?')}"
        body = (summary or "입력 대기 중").replace('"', "'")
        scpt = (f'display notification "{body}" '
                f'with title "{title.replace(chr(34), chr(39))}" sound name "Ping"')
        r = subprocess.run(["osascript", "-e", scpt], capture_output=True, timeout=10)
        ok = ok or r.returncode == 0
    return ok


def _send_slack(db, fresh):
    """묶음 1통. 봇 앱의 Messages 탭이 켜져 있어야 DM 가능 (channel엔 채널ID도 됨)."""
    channel = cfg(db, "slack_channel") or cfg(db, "slack_user_id")
    token = _slack_token(cfg(db, "slack_env_file", ""))
    if not (channel and token):
        return False
    lines = [f"• [{a}] *{os.path.basename(p or '?')}* — {s or '(요약 대기)'}"
             for _, a, p, s in fresh]
    text = f":bell: 입력 대기 중인 에이전트 세션 {len(fresh)}건\n" + "\n".join(lines)
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        json.dumps({"channel": channel, "text": text}).encode(),
        {"Content-Type": "application/json; charset=utf-8",
         "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            resp = json.load(r)
            if not resp.get("ok"):
                log(f"slack error: {resp.get('error')}")
                return False
            return True
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        log(f"slack unreachable: {e}")
        return False


def notify_pass(db):
    """Phase 3: NEEDS_ATTENTION 중 마지막 알림 이후 새 이벤트가 생긴 산 세션을 알림.
    채널은 config notify_method: macos(기본) | slack."""
    now = int(time.time())
    burst = int(cfg(db, "notify_min_gap", "600"))
    rows = db.execute("""
        SELECT session_id, agent, project_path, summary, pid
        FROM sessions WHERE state='NEEDS_ATTENTION'
          AND (notified_at IS NULL OR (last_event_at > notified_at
                                       AND ? - notified_at > ?))""",
                      (now, burst)).fetchall()
    fresh = []
    for sid, agent, path, summary, pid in rows:
        if pid:
            try:
                os.kill(pid, 0)
            except OSError:
                continue                       # 죽은 세션은 알리지 않음 (reap 대상)
        fresh.append((sid, agent, path, summary))
    if not fresh:
        return
    method = cfg(db, "notify_method", "macos")
    if method == "macos" and sys.platform != "darwin":
        return                               # Windows 스포크: 로컬 배너 미지원 (v1)
    sent = _send_slack(db, fresh) if method == "slack" else _send_macos(fresh)
    if not sent:
        return
    db.executemany("UPDATE sessions SET notified_at=? WHERE session_id=?",
                   [(now, sid) for sid, *_ in fresh])
    db.commit()
    log(f"notified {len(fresh)} session(s) via {method}")


def summarize_pass(db):
    model = (db.execute("SELECT value FROM config WHERE key='model'").fetchone()
             or [DEFAULT_MODEL])[0]

    # 세션별 미처리 이벤트 범위와 transcript 경로(최신 이벤트 기준)
    rows = db.execute("""
        SELECT e.session_id, MAX(e.id), s.state,
               (SELECT json_extract(payload_json, '$.transcript_path') FROM events
                WHERE session_id = e.session_id AND processed = 0
                ORDER BY id DESC LIMIT 1)
        FROM events e JOIN sessions s ON s.session_id = e.session_id
        WHERE e.processed = 0
        GROUP BY e.session_id""").fetchall()
    if not rows:
        return

    done = 0
    for sid, max_id, state, transcript in rows:
        summary, phase = None, ""
        if state != "ENDED" and transcript:
            excerpt = transcript_excerpt(transcript)
            if excerpt:
                summary, phase = summarize(model, excerpt)
                if summary is None and done == 0:
                    # 첫 콜부터 실패면 Ollama 문제 — 재시도 여지 남기고 종료
                    log("first summarize failed; leaving events unprocessed")
                    return
        if summary:
            # phase는 명시 사인(smon done)·ack가 LLM 분류보다 우선 (RUNNING 리셋이 해제)
            db.execute(
                "UPDATE sessions SET summary=?, summary_at=?, summary_model=?, "
                "phase=CASE WHEN phase IN ('done','acked') THEN phase ELSE ? END "
                "WHERE session_id=?", (summary, int(time.time()), model, phase, sid))
            tint(db, sid)
            done += 1
        db.execute("UPDATE events SET processed=1 WHERE session_id=? AND id<=?",
                   (sid, max_id))
        db.commit()
    log(f"{model}: {done}/{len(rows)} sessions summarized")


def main():
    global OLLAMA
    db = sqlite3.connect(DB, timeout=5)
    db.execute("PRAGMA busy_timeout=3000")
    # 원격 머신은 config ollama_url로 허브 Ollama(tailscale serve 경유)를 쓴다
    OLLAMA = cfg(db, "ollama_url") or OLLAMA
    try:
        agy_sync(db)             # agy는 훅 대신 폴링 (계정 게이트로 훅 비활성)
    except Exception as e:       # agy 내부 포맷 변화가 요약/알림을 막으면 안 됨
        log(f"agy_sync failed: {e}")
    try:
        summarize_pass(db)
    finally:
        notify_pass(db)          # 요약 실패(Ollama 다운)여도 알림은 나가야 한다


if __name__ == "__main__":
    sys.exit(main())
