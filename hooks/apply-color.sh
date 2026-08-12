#!/bin/bash
# cmux 탭 색 적용기 (에이전트 중립). 사용: apply-color.sh <workspace> <color|"">
# ""=clear. exit code = 실제 결과 (호출측 reconcile이 성공시에만 tab_color 갱신).
# 주의: launchd 컨텍스트에서는 cmux 소켓 write가 broken pipe로 실패한다 (실측) —
# 반드시 세션(훅/사용자 셸) 컨텍스트에서 부를 것. 상한 3초 (cmux hang 대비).
WS="$1" COLOR="$2"
CMUX="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
LOG="$HOME/dev/session-monitor/apply-color.log"
[ -n "$WS" ] && [ -x "$CMUX" ] || exit 1

run() { perl -e 'alarm 3; exec @ARGV' -- "$@"; }   # macOS엔 timeout(1) 없음 — perl alarm

if [ -z "$COLOR" ]; then
  ERR=$(run "$CMUX" workspace-action --workspace "$WS" --action clear-color 2>&1 >/dev/null)
else
  ERR=$(run "$CMUX" workspace-action --workspace "$WS" --action set-color --color "$COLOR" 2>&1 >/dev/null)
fi
RC=$?
[ "$RC" -ne 0 ] && echo "$(date '+%F %T') ws=$WS color='${COLOR:-clear}' rc=$RC err=${ERR:0:120}" >> "$LOG"
exit $RC
