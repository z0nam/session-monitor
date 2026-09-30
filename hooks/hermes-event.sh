#!/bin/bash
# Hermes Agent 셸 훅(config.yaml `hooks:`)용 래퍼 — 전처리 후 agent-event.sh hermes 로 넘긴다.
# Hermes 페이로드: {hook_event_name, session_id, cwd, profile, extra{...}} (실측 2026-09-30)
#
# 다른 에이전트와 다른 점 (여기서 보정):
#  ① pid: Hermes 본체는 python3 라 basename(AGENT_BINS) 매칭이 불가 → 훅의 PPID(=Hermes 프로세스,
#     CLI면 `hermes` 런처 python, TUI면 tui_gateway.entry python)를 SMON_AGENT_PID 로 직접 넘긴다.
#  ② 승인 이벤트(pre_approval_request/post_approval_response)는 session_id 가 비어 올 수 있다
#     (session_key만 있음) → 같은 pid 의 최근 hermes 세션으로 귀속.
#  ③ delegate_task 하위 에이전트도 같은 프로세스에서 세션 훅을 쏜다 → 보드 오염 방지로 버린다
#     (on_session_start 의 extra.platform=subagent, pre_llm_call 의 extra.parent_session_id,
#      state.db 의 parent 가 compression 이 아닌 경우).
#  ④ transcript JSONL 이 없다(대화는 ~/.hermes/state.db) → transcript_path 를 `hermes-state:<원id>`
#     의사경로로 넣고, 워커(summarize.py)가 state.db 에서 읽는다.
#  ⑤ id 표기: Hermes id(YYYYMMDD_HHMMSS_hex)는 앞 8자가 날짜라 보드 SESSION 열·`smon tail <앞자리>`가
#     같은 날 세션끼리 겹친다 → smon 에는 `hex-YYYYMMDD_HHMMSS` 로 뒤집어 저장.
#     `smon done` 의 HERMES_SESSION_ID 조회도 같은 변환을 쓴다(bin/smon).
# 어떤 실패든 exit 0 + stdout 은 {} (Hermes 훅 프로토콜; 빈 출력도 허용되지만 명시).
DB="$HOME/dev/session-monitor/sessions.db"
HSTATE="${HERMES_HOME:-$HOME/.hermes}/state.db"
smon_id() { case "$1" in *_*_*) printf '%s-%s' "${1##*_}" "${1%_*}" ;; *) printf '%s' "$1" ;; esac; }
raw_id()  { case "$1" in *-*_*) printf '%s_%s' "${1#*-}" "${1%%-*}" ;; *) printf '%s' "$1" ;; esac; }
sq() { printf '%s' "$1" | sed "s/'/''/g"; }
{
  INPUT=$(cat)
  PARSED=$(printf '%s' "$INPUT" | /usr/bin/jq -r \
    '(.hook_event_name // ""), (.session_id // ""), (.cwd // ""),
     (.extra.parent_session_id // ""), (.extra.surface // ""), (.extra.platform // "")') || exit 0
  { IFS= read -r EV; IFS= read -r RAW; IFS= read -r CWD; IFS= read -r PARENT; IFS= read -r SURF; IFS= read -r PLAT; } <<< "$PARSED"

  # ③ 하위 에이전트 (1차): 시작 이벤트는 platform=subagent, 턴 이벤트는 parent_session_id 가 붙는다
  [ "$PLAT" = subagent ] && exit 0
  [ -n "$PARENT" ] && exit 0
  # smart approval(보조 LLM 자동 판정)은 사람 입력 대기가 아니다
  case "$EV" in pre_approval_request|post_approval_response) [ "$SURF" = smart ] && exit 0 ;; esac

  # ① Hermes 프로세스 pid (PID 재사용 대비 .hermes 경로 포함 여부 확인)
  HPID=
  CMD=$(ps -p "$PPID" -o command= 2>/dev/null) && case "$CMD" in *"/.hermes/"*) HPID=$PPID ;; esac

  # ② sid 보충 (smon DB 에는 뒤집힌 id 가 있으니 원 id 로 되돌린다)
  if [ -z "$RAW" ] && [ -n "$HPID" ]; then
    # 주의: `PRAGMA busy_timeout=N;` 은 N 을 결과행으로 출력한다 → .timeout 으로 설정 (실측: '200' 이 sid 로 샘)
    RAW=$(raw_id "$(/usr/bin/sqlite3 -cmd '.timeout 200' "$DB" "SELECT session_id FROM sessions
          WHERE agent='hermes' AND pid=$HPID AND state != 'ENDED'
          ORDER BY last_event_at DESC LIMIT 1;" 2>/dev/null)")
  fi
  [ -n "$RAW" ] || exit 0
  # `hermes hooks doctor/test` 의 합성 페이로드 — 보드에 올리지 않는다
  [ "$RAW" = test-session ] && exit 0

  # ③ 하위 에이전트 (2차) + 압축 회전 처리 — state.db 계보 확인
  if [ -r "$HSTATE" ]; then
    ROW=$(/usr/bin/sqlite3 -separator '|' "file:$HSTATE?mode=ro" \
      "SELECT COALESCE(s.parent_session_id,''), COALESCE(p.end_reason,'')
       FROM sessions s LEFT JOIN sessions p ON p.id = s.parent_session_id
       WHERE s.id='$(sq "$RAW")';" 2>/dev/null)
    { IFS='|' read -r PSID PEND; } <<< "$ROW"
    if [ -n "$PSID" ]; then
      [ "$PEND" = compression ] || exit 0   # 위임 자식 → 무시
      # 압축으로 세션 id 가 회전 → 옛 id 는 같은 프로세스가 새 id 로 이어가므로 보드에서 내린다
      /usr/bin/sqlite3 "$DB" "PRAGMA busy_timeout=200;
        UPDATE sessions SET state='ENDED', ended_at=strftime('%s','now'), tab_want=''
        WHERE session_id='$(sq "$(smon_id "$PSID")")' AND state != 'ENDED';" >/dev/null 2>&1
    fi
  fi

  # ④⑤ 표준 필드로 정규화해 공용 번역기로
  printf '%s' "$INPUT" | /usr/bin/jq -c --arg sid "$(smon_id "$RAW")" --arg raw "$RAW" \
    '{hook_event_name, session_id: $sid, cwd, profile, hermes_session_id: $raw,
      transcript_path: ("hermes-state:" + $raw),
      turn_exit_reason: .extra.turn_exit_reason, platform: .extra.platform,
      model: .extra.model}' \
  | SMON_AGENT_PID="$HPID" "$HOME/dev/session-monitor/hooks/agent-event.sh" hermes
} >/dev/null 2>&1
printf '{}\n'
exit 0
