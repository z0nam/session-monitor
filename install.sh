#!/bin/bash
# session-monitor 멱등 설치 (로컬/원격 공용).
# 사용: ./install.sh [--with-worker]
#   --with-worker: 요약 워커 launchd 등록 (Ollama 있는 머신에서만)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== schema (idempotent)"
/usr/bin/sqlite3 "$DIR/sessions.db" < "$DIR/schema.sql"

echo "== smon -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sfn "$DIR/bin/smon" "$HOME/.local/bin/smon"

echo "== Claude Code 훅 등록 (~/.claude/settings.json)"
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude/settings.json" ] && cp -n "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak-smon" || true
python3 - "$DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
hooks = s.setdefault("hooks", {})
for ev in ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]:
    arr = hooks.setdefault(ev, [])
    if any("record-event.sh" in h.get("command", "")
           for e in arr for h in e.get("hooks", [])):
        continue
    arr.append({"matcher": "", "hooks": [
        {"type": "command", "command": f"{d}/hooks/record-event.sh {ev}"}]})
    print(f"  + {ev}")
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
PY

echo "== Codex/Antigravity 어댑터 (있는 것만)"
# 심링크가 아니라 __REPO__ 를 실제 레포경로($DIR)로 치환한 '실파일'을 쓴다.
# (레포 어댑터를 직접 심링크하면, 어댑터가 공개용으로 템플릿화될 때 라이브 훅이
#  존재하지 않는 경로를 가리켜 exit 127 로 깨진다 — 2026-08 실사고.)
if [ -d "$HOME/.codex" ]; then
  sed "s#__REPO__#$DIR#g" "$DIR/adapters/codex-hooks.json" > "$HOME/.codex/hooks.json"
  echo "  codex ok — 주의: codex TUI에서 /hooks 신뢰 승인 필요"
fi
if [ -d "$HOME/.gemini/antigravity-cli" ]; then
  sed "s#__REPO__#$DIR#g" "$DIR/adapters/antigravity-hooks.json" > "$HOME/.gemini/antigravity-cli/hooks.json"
  echo "  agy ok"
fi

if [ "${1:-}" = "--with-worker" ]; then
  echo "== 요약 워커 launchd"
  cp "$DIR/worker/com.namun.smon-worker.plist" "$HOME/Library/LaunchAgents/"
  launchctl unload "$HOME/Library/LaunchAgents/com.namun.smon-worker.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.namun.smon-worker.plist"
fi

echo "done — 새로 뜨는 에이전트 세션부터 기록됩니다"
