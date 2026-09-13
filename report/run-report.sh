#!/bin/bash
# 아침 smon 리포트 러너 — launchd(매일 07:50)가 호출한다.
# 재료 = `smon report`(완료/노이즈 제외 활성 세션) → 헤드리스 claude 가 클러스터 서술로 정리 →
# 러너가 사용자 토큰으로 Canvas 생성 + 본인 DM 1건(post-report.py).
# 아침 브리핑(08:00, calendar-worklog)과 나란히 도는 형제 잡. 나중에 합칠 대상.
set -uo pipefail

REPO="$HOME/dev/session-monitor"
LOGDIR="$REPO/report/logs"
LOG="$LOGDIR/$(date +%Y-%m-%d).log"
TIMEOUT=420          # 7분. 브리핑보다 가볍다(외부 fetch 없음). 넘으면 죽이고 실패.
# 개인 설정은 레포에 안 박고 config에서 읽는다. report/config.example 참고.
#   기본 경로: ~/.config/smon-report/config  (SMON_REPORT_CONFIG 로 override)
CONFIG="${SMON_REPORT_CONFIG:-$HOME/.config/smon-report/config}"
# set -a: config 값들을 export 한다. post-report.py 는 자식 프로세스라 export 없이는
# REPORT_SENDER 같은 값을 못 본다(2026-09-13: 이걸 빠뜨려 user 설정인데 봇으로 나갔다).
set -a
[ -r "$CONFIG" ] && . "$CONFIG"
set +a
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

# 중복 발송 가드 1 — 담당 머신. 여러 머신에 리포트 잡을 켜면 같은 DM 이 여러 통 온다.
#   config 를 머신 간에 복사해도 이 값이 따라오므로, 담당이 아닌 머신은 스스로 빠진다.
THIS_HOST=$(hostname -s)
if [ -n "${REPORT_HOST:-}" ] && [ "$REPORT_HOST" != "$THIS_HOST" ]; then
  echo "REPORT_SKIPPED: 이 머신($THIS_HOST)은 리포트 담당이 아니다 (REPORT_HOST=$REPORT_HOST)"
  echo "=== $(date '+%F %T') 종료(담당 아님) ==="
  exit 0
fi

# 중복 발송 가드 2 — 오늘 것이 이미 갔는지 Slack 에 물어본다(머신 간 유일한 공유 상태).
#   claude 를 돌리기 전에 확인해 헛돈을 안 쓴다. exit 2 = 이미 발송됨.
if [ "${REPORT_DEDUP:-1}" = "1" ]; then
  PRE=$(SLACK_SELF="$SLACK_SELF" "$REPO/report/post-report.py" --precheck 2>&1); PRE_RC=$?
  echo "--- precheck: $PRE (rc=$PRE_RC) ---"
  if [ "$PRE_RC" -eq 2 ]; then
    echo "REPORT_SKIPPED: 오늘 리포트가 이미 발송됨"
    echo "=== $(date '+%F %T') 종료(중복 방지) ==="
    exit 0
  fi
fi

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
- 아니면 캔버스 본문(마크다운 체크리스트)을 아래 마커 사이에 **그대로만** 출력하고 끝낸다.
  Slack 에 직접 쓰지 마라 — 캔버스 생성도 DM 도 러너가 한다.

  REPORT_CANVAS_START
  (본문)
  REPORT_CANVAS_END

- 제목은 러너가 붙인다. 본문에 제목 줄을 또 넣지 마라.
- 질문·확인 게이트 없이 진행. 읽기 전용 — smon 조회 외에 아무 것도 만들거나 고치지 않는다.
- 본문을 냈으면 상태 토큰은 내지 마라. 만들 게 없으면 본문 없이 \`REPORT_SKIPPED: <사유>\`,
  진행 불가면 \`REPORT_FAILED: <사유>\` 한 줄. (성공 판정은 러너가 실제 발송 결과로 한다.)
EOF
)

ALLOWED='Bash(smon:*),Bash(date:*)'   # Slack 도구 없음 — 발송은 러너가 토큰으로 직접

# perl alarm = macOS에 timeout(1)이 없어서 쓰는 대체
OUT=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
      claude -p "$PROMPT" --allowedTools "$ALLOWED" </dev/null 2>&1)
RC=$?
echo "$OUT"
echo "--- claude rc=$RC ---"

# 판정 — 모델이 낸 것은 스킵/실패뿐이고, 성공은 "실제로 발송됐는가"로만 정한다.
KINDS=$(printf '%s\n' "$OUT" | /usr/bin/grep -oE 'REPORT_(SKIPPED|FAILED)' | sort -u)
NKINDS=$(printf '%s' "$KINDS" | /usr/bin/grep -c .)
BODY=$(printf '%s\n' "$OUT" | /usr/bin/awk '/^[[:space:]]*REPORT_CANVAS_START[[:space:]]*$/{f=1;next} /^[[:space:]]*REPORT_CANVAS_END[[:space:]]*$/{f=0} f')

DECISION=fail
if [ $RC -ne 0 ]; then
  echo "판정: claude rc=$RC"
elif printf '%s' "$KINDS" | /usr/bin/grep -q 'REPORT_FAILED'; then
  echo "판정: 모델이 REPORT_FAILED"
elif [ "$NKINDS" -gt 1 ]; then
  echo "판정: 상태 토큰 상충 ($(printf '%s' "$KINDS" | tr '\n' ','))"
elif [ -z "$BODY" ]; then
  if printf '%s' "$KINDS" | /usr/bin/grep -q 'REPORT_SKIPPED'; then
    DECISION=skipped
  else
    echo "판정: 캔버스 본문 없음 (마커 사이가 비었다)"
  fi
else
  TITLE="smon 리포트 · $(date '+%Y-%m-%d (%a)')"
  POST=$(printf '%s\n' "$BODY" | SLACK_SELF="$SLACK_SELF" "$REPO/report/post-report.py" --title "$TITLE" 2>&1)
  POST_RC=$?
  echo "--- post-report ---"; echo "$POST"; echo "--- post-report rc=$POST_RC ---"
  [ "$POST_RC" -eq 0 ] && DECISION=sent
fi

if [ "$DECISION" = "sent" ]; then
  echo "=== $(date '+%F %T') 종료: REPORT_SENT ==="
  exit 0
fi
if [ "$DECISION" = "skipped" ]; then
  echo "=== $(date '+%F %T') 종료: $(printf '%s' "$KINDS") ==="
  exit 0
fi
echo "실패 — 알림"
/usr/bin/osascript -e 'display notification "아침 smon 리포트 실패 — 로그 확인" with title "smon-report"' 2>/dev/null
echo "=== $(date '+%F %T') 실패 종료 ==="
exit 1
