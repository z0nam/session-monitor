#!/bin/bash
# session-monitor 멱등 설치 (로컬/원격 공용).
# 사용: ./install.sh [--with-worker] [--with-report]
#   --with-worker: 요약 워커 launchd 등록 (Ollama 있는 머신에서만)
#   --with-report: 아침 smon 리포트 launchd 등록 (매일 07:50). 설정은 report/README.md
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# DB 경로는 lib/paths.sh 규칙 (SMON_DB > ~/.local/share/smon/sessions.db > 레거시 레포 경로).
# 신규 설치(어디에도 DB 없음)면 새 기본 위치 ~/.local/share/smon 에 만든다.
_env_db=${SMON_DB:-}
. "$DIR/lib/paths.sh"
if [ ! -f "$SMON_DB" ] && [ -z "$_env_db" ]; then
  mkdir -p "$SMON_DATA_DIR"
  SMON_DB="$SMON_DATA_DIR/sessions.db"
fi
echo "== schema (idempotent) -> $SMON_DB"
mkdir -p "$(dirname "$SMON_DB")"
/usr/bin/sqlite3 "$SMON_DB" < "$DIR/schema.sql"

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

echo "== Codex/Antigravity/Hermes 어댑터 (있는 것만)"
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
if command -v hermes >/dev/null 2>&1; then
  # config.yaml 은 사용자 설정이 섞여 있어 덮어쓰지 않고 hooks 키만 교체.
  # 주의: 다른 용도의 Hermes 셸 훅이 생기면 여기서 지워진다 — 그때는 병합 로직으로 바꿀 것.
  H_HOOKS=$(grep -v '^#' "$DIR/adapters/hermes-hooks.yaml" | sed "s#__REPO__#$DIR#g")
  hermes config set --force hooks "$H_HOOKS" >/dev/null && echo "  hermes hooks ok"
  # 셸 훅 consent 를 비대화식으로 기록 (없으면 첫 TUI 실행 때 이벤트마다 승인 프롬프트)
  /usr/bin/python3 - "${HERMES_HOME:-$HOME/.hermes}/shell-hooks-allowlist.json" "$DIR/hooks/hermes-event.sh" <<'PY'
import json, os, sys, datetime
p, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(p)) if os.path.exists(p) else {}
ap = d.setdefault("approvals", [])
have = {(a.get("event"), a.get("command")) for a in ap}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
for ev in ("on_session_start", "pre_llm_call", "on_session_end", "on_session_finalize",
           "pre_approval_request", "post_approval_response"):
    if (ev, cmd) not in have:
        ap.append({"approved_at": now, "command": cmd, "event": ev})
json.dump(d, open(p, "w"), indent=2)
PY
  echo "  hermes consent ok — 이미 떠 있는 Hermes 세션엔 소급 안 됨(재시작 필요)"
fi

WITH_WORKER=0; WITH_REPORT=0
for a in "$@"; do
  case "$a" in
    --with-worker) WITH_WORKER=1 ;;
    --with-report) WITH_REPORT=1 ;;
    *) echo "알 수 없는 옵션: $a" >&2; exit 2 ;;
  esac
done

if [ "$WITH_WORKER" = "1" ]; then
  echo "== 요약 워커 launchd"
  cp "$DIR/worker/com.namun.smon-worker.plist" "$HOME/Library/LaunchAgents/"
  launchctl unload "$HOME/Library/LaunchAgents/com.namun.smon-worker.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.namun.smon-worker.plist"
fi

if [ "$WITH_REPORT" = "1" ]; then
  echo "== 아침 리포트 launchd (매일 07:50)"
  CFG="${SMON_REPORT_CONFIG:-$HOME/.config/smon-report/config}"
  if [ ! -r "$CFG" ]; then
    echo "  ! 설정 없음: $CFG"
    echo "    cp $DIR/report/config.example $CFG  후 SLACK_SELF 를 채우세요 (report/README.md)"
  elif ! /usr/bin/grep -qE '^[[:space:]]*SLACK_SELF=["'"'"']?U' "$CFG"; then
    echo "  ! $CFG 에 SLACK_SELF(U…) 가 비어 있습니다"
  fi
  if [ ! -s "$HOME/.config/smon-report/slack-bot-token" ] \
     && [ ! -s "$HOME/.config/calendar-worklog/slack-bot-token" ] \
     && [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    echo "  ! Slack 봇 토큰을 못 찾았습니다 — ~/.config/smon-report/slack-bot-token 에 저장(chmod 600)"
    echo "    본인 계정 토큰으로 보내려면 report/README.md 의 'user 경로' 참고"
  fi
  mkdir -p "$DIR/report/logs"
  sed "s#__REPO__#$DIR#g" "$DIR/deploy/com.namun.smon-report.plist" \
    > "$HOME/Library/LaunchAgents/com.namun.smon-report.plist"
  launchctl unload "$HOME/Library/LaunchAgents/com.namun.smon-report.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.namun.smon-report.plist"
  echo "  등록됨 — 먼저 한 번 돌려보려면: $DIR/report/run-report.sh"
fi

echo "done — 새로 뜨는 에이전트 세션부터 기록됩니다"
