#!/bin/bash
# 에이전트 네이티브 훅 이벤트 → 표준 이벤트 번역기.
# 사용: agent-event.sh <agent>  (stdin: 훅 JSON; hook_event_name에서 네이티브 이벤트를 읽음)
# 새 에이전트 추가 = 아래 case에 매핑 몇 줄 + 얇은 래퍼(<agent>-event.sh) + 어댑터 훅 설정.
AGENT="${1:-unknown}"
INPUT=$(cat)
NATIVE=$(printf '%s' "$INPUT" | /usr/bin/jq -r '.hook_event_name // empty' 2>/dev/null)

case "$AGENT:$NATIVE" in
  codex:SessionStart)         CANON=SessionStart ;;
  codex:UserPromptSubmit)     CANON=UserPromptSubmit ;;
  codex:Stop)                 CANON=Stop ;;
  codex:PermissionRequest)    CANON=Notification ;;   # 승인 대기 = NEEDS_ATTENTION
  # agy(Antigravity CLI) v1.1.1: hooks.json 파서가 아는 키는
  # PreToolUse/PostToolUse/PreInvocation 뿐 (문서의 PostInvocation/Stop은 미지원 —
  # strings 바이너리 확인). 턴 종료 이벤트가 없어 agy 세션은 RUNNING↔(pid reap)ENDED만
  # 오간다. PostToolUse는 작업 중 하트비트(last_event_at 갱신)로 쓴다.
  antigravity:PreInvocation)  CANON=UserPromptSubmit ;;
  antigravity:PostToolUse)    CANON=UserPromptSubmit ;;
  antigravity:PostInvocation) CANON=Stop ;;        # 향후 버전 대비
  antigravity:Stop)           CANON=SessionEnd ;;  # 향후 버전 대비
  # Hermes Agent (셸 훅; 전처리는 hermes-event.sh). on_session_end 는 이름과 달리
  # **턴마다** 발화(run_conversation 1회 = 1턴) → Stop. 진짜 세션 종료는 on_session_finalize.
  hermes:on_session_start)       CANON=SessionStart ;;
  hermes:pre_llm_call)           CANON=UserPromptSubmit ;;
  hermes:on_session_end)         CANON=Stop ;;
  hermes:pre_approval_request)   CANON=Notification ;;     # 위험 명령 승인 대기
  hermes:post_approval_response) CANON=UserPromptSubmit ;; # 승인 응답 → 다시 작업 중
  hermes:on_session_finalize)    CANON=SessionEnd ;;
  *) exit 0 ;;                                        # 모르는 이벤트는 조용히 무시
esac

printf '%s' "$INPUT" | "$HOME/dev/session-monitor/hooks/record-event.sh" "$CANON" "$AGENT"
exit 0
