#!/bin/bash
# 아침 smon 리포트 러너 — launchd(매일 07:50)가 호출한다.
# 재료 = `smon report`(완료/노이즈 제외 활성 세션) → 헤드리스 claude 가 클러스터 서술로 정리 →
# Slack 본인 DM 1건. 아침 브리핑(08:00, calendar-worklog)과 나란히 도는 형제 잡. 나중에 합칠 대상.
set -uo pipefail

REPO="$HOME/dev/session-monitor"
LOGDIR="$REPO/report/logs"
LOG="$LOGDIR/$(date +%Y-%m-%d).log"
TIMEOUT=420          # 7분. 브리핑보다 가볍다(외부 fetch 없음). 넘으면 죽이고 실패.
# 개인 설정은 레포에 안 박고 config에서 읽는다. report/config.example 참고.
#   기본 경로: ~/.config/smon-report/config  (SMON_REPORT_CONFIG 로 override)
CONFIG="${SMON_REPORT_CONFIG:-$HOME/.config/smon-report/config}"
[ -r "$CONFIG" ] && . "$CONFIG"
SLACK_SELF="${SLACK_SELF:-}"   # 본인 Slack member ID (U…). config에서 지정.

# launchd 최소 env 보정 — smon(~/.local/bin)·claude(~/.local/bin)·sqlite 경로 확보.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:?HOME 미설정}"
export LANG="en_US.UTF-8"

mkdir -p "$LOGDIR"
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T %Z') smon 리포트 시작 ==="

# 브리핑과 동일한 전용 장기 토큰을 공유(있으면). 대화형 로그인이 풀려도 독립적으로 돈다.
CLAUDE_TOKEN_FILE="${CLAUDE_TOKEN_FILE:-$HOME/.config/smon-report/claude-token}"
if [ -r "$CLAUDE_TOKEN_FILE" ] && [ -s "$CLAUDE_TOKEN_FILE" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"
  echo "인증: 전용 장기 토큰 사용(대화형 로그인과 독립)"
else
  echo "인증: 전용 토큰 없음 — 기존 OAuth 세션 사용(로그인 풀리면 같이 죽음)."
fi

cd "$REPO" || { echo "FATAL: repo 없음 $REPO"; exit 1; }
[ -r report/prompt.md ] || { echo "FATAL: report/prompt.md 없음"; exit 1; }
[ -n "$SLACK_SELF" ] || { echo "REPORT_FAILED: SLACK_SELF 미설정 — $CONFIG 에 지정 (report/config.example 참고)"; echo "=== 종료(설정없음) ==="; exit 1; }

# 재료 수집: 완료/노이즈 제외된 프로젝트별 활성 세션.
MATERIAL=$(smon report 2>&1)
echo "--- smon report ---"; echo "$MATERIAL"; echo "--- /smon report ---"

# 프롬프트 조립: 워크플로 + 재료 + 실행 지시. {{SLACK_SELF}} 치환.
WORKFLOW=$(sed "s/{{SLACK_SELF}}/$SLACK_SELF/g" report/prompt.md)
PROMPT=$(cat <<EOF
$WORKFLOW

---

# 오늘 재료 — \`smon report\` 출력 (완료/노이즈 이미 제외)

\`\`\`
$MATERIAL
\`\`\`

---

# 실행 지시

- 오늘: $(date '+%Y-%m-%d (%a) %H:%M') KST. 무인 실행 — 사람이 보지 않는다.
- 재료가 비었거나 활성 프로젝트가 사실상 없으면 아무 것도 안 만들고 \`REPORT_SKIPPED: 활성 프로젝트 없음\` 한 줄로 종료.
- 아니면 위 형식대로 **Slack Canvas(체크리스트)를 생성**하고(title \`smon 리포트 · $(date '+%Y-%m-%d (%a)')\`),
  그 캔버스 링크를 본인 DM(user \`$SLACK_SELF\`)으로 **핑**한 뒤 종료.
- 질문·확인 게이트 없이 진행. 읽기 전용(smon 조회 + 캔버스 생성 + 핑 DM 외 금지).
- 마지막에 \`REPORT_SENT\` / \`REPORT_SKIPPED: <사유>\` / \`REPORT_FAILED: <사유>\` 중 정확히 하나 + 성공 시 \`CANVAS_URL=<url>\`.
EOF
)

ALLOWED='Bash(smon:*),Bash(date:*),mcp__plugin_slack_slack__slack_create_canvas,mcp__plugin_slack_slack__slack_send_message'

# perl alarm = macOS에 timeout(1)이 없어서 쓰는 대체
OUT=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
      claude -p "$PROMPT" --allowedTools "$ALLOWED" </dev/null 2>&1)
RC=$?
echo "$OUT"
echo "--- claude rc=$RC ---"

# 상태 판정 (브리핑과 동일 규칙): rc≠0 / FAILED 섞임 / 상태 2종이상 / 0종 → 실패.
KINDS=$(printf '%s\n' "$OUT" | /usr/bin/grep -oE 'REPORT_(SENT|SKIPPED|FAILED)' | sort -u)
NKINDS=$(printf '%s' "$KINDS" | /usr/bin/grep -c .)

if [ $RC -ne 0 ] || printf '%s' "$KINDS" | /usr/bin/grep -q 'REPORT_FAILED' || [ "$NKINDS" -gt 1 ] || [ "$NKINDS" -eq 0 ]; then
  echo "실패 감지 — 알림 (rc=$RC, 상태='$(printf '%s' "$KINDS" | tr '\n' ',')')"
  /usr/bin/osascript -e 'display notification "아침 smon 리포트 생성 실패 — 로그 확인" with title "smon-report"' 2>/dev/null
  echo "=== $(date '+%F %T') 실패 종료 ==="
  exit 1
fi

echo "=== $(date '+%F %T') 종료: $(printf '%s' "$KINDS") ==="
