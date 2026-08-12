#!/usr/bin/env python3
"""smon grep — 세션 전사(transcript) 전문검색.

`smon find`가 세션당 '한 줄 요약'만 뒤지는 것과 달리, 이 명령은 실제 대화가
통짜로 쌓인 로컬 JSONL 전사를 직접 grep 한다. "그거 어느 세션이었지"처럼
요약에 안 잡히는 키워드를 찾을 때 쓴다.

대상 전사 (이 머신 로컬만 — 원격 머신 전사는 여기 없음):
  - Claude Code : ~/.claude/projects/<slug>/<uuid>.jsonl
  - Codex       : ~/.codex/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl

찾은 uuid를 sessions.db와 조인해 상태·에이전트·프로젝트·경과·요약을 붙인다.
검색어는 고정 문자열(grep -F)·대소문자 무시로 취급한다.
"""
import os, re, sys, json, socket, sqlite3, subprocess, time

HOME = os.path.expanduser("~")
DB = os.path.join(HOME, "dev/session-monitor/sessions.db")
CLAUDE_ROOT = os.path.join(HOME, ".claude/projects")
CODEX_ROOT = os.path.join(HOME, ".codex/sessions")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
CLAUDE_NAME_RE = re.compile(r"^[0-9a-f-]{36}\.jsonl$")


def humanize(sec):
    if sec is None:
        return "-"
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec//60}m{sec%60}s"
    if sec < 86400:
        return f"{sec//3600}h{(sec%3600)//60}m"
    return f"{sec//86400}d{(sec%86400)//3600}h"


def list_matching_files(term):
    """grep -rliF 로 검색어 포함 전사 파일 목록. (files-with-matches, 대소문자무시, 고정문자열)"""
    files = []
    for root in (CLAUDE_ROOT, CODEX_ROOT):
        if not os.path.isdir(root):
            continue
        try:
            out = subprocess.run(
                ["grep", "-rliF", "--include=*.jsonl", "--", term, root],
                capture_output=True, text=True, timeout=60,
            ).stdout
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue
        for line in out.splitlines():
            if line:
                files.append(line)
    return files


def classify(path):
    """전사 파일 → (agent, session_uuid) 또는 None (대상 아님: 서브에이전트·인덱스 등)."""
    base = os.path.basename(path)
    if os.sep + ".claude" + os.sep in path:
        # 메인 세션만: <uuid>.jsonl (agent-*.jsonl 서브에이전트 제외)
        if CLAUDE_NAME_RE.match(base) and "subagents" not in path:
            return ("claude", base[:-6])
        return None
    if os.sep + ".codex" + os.sep in path:
        if not base.startswith("rollout-"):
            return None  # session_index.jsonl 등 제외
        m = UUID_RE.search(base)
        if m:
            return ("codex", m.group(0))
        return None
    return None


def count_hits(path, term):
    try:
        out = subprocess.run(["grep", "-ciF", "--", term, path],
                             capture_output=True, text=True, timeout=30).stdout
        return int(out.strip() or 0)
    except Exception:
        return 0


def first_snippet(path, term, width=64):
    """검색어가 처음 나온 줄에서 사람이 읽을 텍스트를 뽑아 앞뒤로 자른다."""
    try:
        raw = subprocess.run(["grep", "-m1", "-iF", "--", term, path],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        raw = ""
    raw = raw.strip()
    if not raw:
        return ""
    text = raw
    try:
        o = json.loads(raw)
        msg = o.get("message", o)
        c = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(c, str):
            text = c
        elif isinstance(c, list):
            parts = [x.get("text", "") for x in c
                     if isinstance(x, dict) and x.get("type") == "text"]
            if any(parts):
                text = " ".join(p for p in parts if p)
    except Exception:
        pass
    # 이중 인코딩된 JSON 문자열(툴 결과 등)에서 남은 리터럴 이스케이프 정리
    text = (text.replace("\\n", " ").replace("\\t", " ")
                .replace('\\"', '"').replace("\\/", "/"))
    text = re.sub(r"\s+", " ", text).strip()
    low = text.lower()
    i = low.find(term.lower())
    if i < 0:
        return text[:width]
    start = max(0, i - width // 3)
    seg = text[start:start + width]
    if start > 0:
        seg = "…" + seg
    return seg


def load_db(uuids):
    info = {}
    if not os.path.exists(DB) or not uuids:
        return info
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=1.0)
        qs = ",".join("?" * len(uuids))
        for row in con.execute(
            f"""SELECT session_id, state, COALESCE(agent,''), project_path,
                       last_event_at, COALESCE(summary,'')
                FROM sessions WHERE session_id IN ({qs})""", list(uuids)):
            info[row[0]] = row
        con.close()
    except sqlite3.Error:
        pass
    return info


def main():
    args = [a for a in sys.argv[1:] if a]
    limit = 25
    terms = []
    i = 0
    while i < len(args):
        if args[i] in ("-n", "--limit") and i + 1 < len(args):
            limit = int(args[i + 1]); i += 2; continue
        terms.append(args[i]); i += 1
    if not terms:
        print("usage: smon grep <검색어> [-n N]", file=sys.stderr)
        return 2
    term = " ".join(terms)

    files = list_matching_files(term)
    rows = {}  # uuid -> dict
    for path in files:
        cl = classify(path)
        if not cl:
            continue
        agent, uuid = cl
        hits = count_hits(path, term)
        if hits <= 0:
            continue
        prev = rows.get(uuid)
        if prev is None or hits > prev["hits"]:
            rows[uuid] = {
                "uuid": uuid, "agent": agent, "path": path, "hits": hits,
                "mtime": os.path.getmtime(path),
            }

    if not rows:
        print(f"(전사에서 '{term}' 못 찾음)", file=sys.stderr)
        return 0

    dbinfo = load_db(rows.keys())
    now = time.time()
    out = []
    for uuid, r in rows.items():
        d = dbinfo.get(uuid)
        if d:
            _, state, agent, proj, last_at, summary = d
            elapsed = now - last_at if last_at else None
            agent = agent or r["agent"]
        else:
            state, proj, summary = "-", os.path.dirname(r["path"]), ""
            elapsed = now - r["mtime"]
            agent = r["agent"]
        proj = os.path.basename(proj.rstrip("/")) or proj
        out.append({
            "state": state, "agent": agent, "proj": proj[:26],
            "elapsed": elapsed, "uuid": uuid, "hits": r["hits"],
            "snippet": first_snippet(r["path"], term),
        })

    out.sort(key=lambda x: (x["elapsed"] is None, x["elapsed"] or 0))
    out = out[:limit]

    header = ["STATE", "AGENT", "PROJECT", "LAST", "SESSION", "HITS", "SNIPPET"]
    table = [header]
    for x in out:
        table.append([x["state"], x["agent"], x["proj"], humanize(x["elapsed"]),
                      x["uuid"][:8], str(x["hits"]), x["snippet"]])
    widths = [max(len(row[c]) for row in table) for c in range(len(header) - 1)]
    for row in table:
        cells = [row[c].ljust(widths[c]) for c in range(len(header) - 1)]
        cells.append(row[-1])  # SNIPPET: 마지막이라 패딩 안 함
        print("  ".join(cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
