#!/bin/bash
# session-monitor 훅 디스패처 (에이전트 중립).
# 사용: record-event.sh <표준이벤트> [에이전트]
#   표준이벤트: SessionStart | UserPromptSubmit | Stop | Notification | SessionEnd
#   에이전트:   claude(기본) | codex | antigravity | ... — 어댑터 훅 설정이 자기
#              네이티브 이벤트를 표준이벤트로 번역해 호출한다 (예: codex의
#              PermissionRequest → Notification, agy의 PostInvocation → Stop).
# stdin: 훅 JSON (세 에이전트 모두 session_id/cwd/transcript_path 공통).
# 어떤 실패든 exit 0 (세션 방해 금지). 대화 내용 필드는 DB에 저장하지 않는다.
DB="$HOME/dev/session-monitor/sessions.db"
EVENT="${1:-Unknown}"
AGENT="${2:-claude}"
# pid 탐색에서 인정할 에이전트 실행파일 basename (새 에이전트 추가 시 여기+smon)
AGENT_BINS="claude|codex|agy"

{
  INPUT=$(cat)

  # jq 한 번에 세 줄로 추출: session_id / cwd / 정제된 payload(jq가 한 줄 JSON으로 출력)
  PARSED=$(printf '%s' "$INPUT" | /usr/bin/jq -r \
    '(.session_id // ""), (.cwd // ""), (.notification_type // ""),
     (del(.prompt, .last_assistant_message, ."last-assistant-message",
          .input_messages, ."input-messages") | tojson)') || exit 0
  { IFS= read -r SESSION_ID; IFS= read -r CWD; IFS= read -r NTYPE; IFS= read -r PAYLOAD; } <<< "$PARSED"
  [ -n "$SESSION_ID" ] || exit 0

  NOW=$(date +%s)

  # 에이전트 프로세스 PID: 조상 중 실행파일 basename이 AGENT_BINS인 첫 프로세스(최대 6단계).
  # 주의: 부분문자열 매칭 금지 — 래퍼 셸 커맨드에 .claude/ 같은 경로가 들어와 오탐한다.
  PID= P=$PPID
  for _ in 1 2 3 4 5 6; do
    [ -n "$P" ] && [ "$P" -gt 1 ] || break
    CMD=$(ps -p "$P" -o command= 2>/dev/null) || break
    BASE=${CMD%% *}; BASE=${BASE##*/}
    if printf '%s' "$BASE" | grep -qxE "$AGENT_BINS"; then PID=$P; break; fi
    P=$(ps -p "$P" -o ppid= 2>/dev/null | tr -d ' ')
  done
  PID_SQL=${PID:-NULL}

  case "$EVENT" in
    # SessionStart(=startup/resume 직후)는 입력 프롬프트 대기 상태다 — RUNNING은
    # UserPromptSubmit부터. (cmux 재시작이 전 세션 resume을 쏘면 가짜 RUNNING이 되는 문제)
    SessionStart)      STATE=WAITING_INPUT ;;
    UserPromptSubmit)  STATE=RUNNING ;;
    Stop)              STATE=WAITING_INPUT ;;
    Notification)      STATE=NEEDS_ATTENTION ;;
    SessionEnd)        STATE=ENDED ;;
    *)                 STATE= ;;
  esac
  # idle 알림("입력 기다리는 중")은 주의 요청이 아니다 — 상태 유지, 기록만.
  # 진짜 NEEDS_ATTENTION은 permission_prompt 등 idle 아닌 Notification뿐.
  [ "$EVENT" = Notification ] && [ "$NTYPE" = idle_prompt ] && STATE=

  # branch/source는 SessionStart 또는 첫 이벤트에서만 (50ms 예산 보호).
  # 첫 이벤트 조건은 SessionStart가 없는 에이전트(agy) 때문에 필요.
  BRANCH= SRC= NEW=
  [ "$EVENT" = SessionStart ] || NEW=$(/usr/bin/sqlite3 "$DB" \
    "SELECT 1 FROM sessions WHERE session_id='$(printf "%s" "$SESSION_ID" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null)
  if [ "$EVENT" = SessionStart ] || [ -z "$NEW" ]; then
    [ -n "$CWD" ] && BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$CMUX_WORKSPACE_ID$CMUX_SESSION_ID" ]; then SRC=cmux
    elif [ -n "$TMUX" ]; then SRC=tmux
    else SRC="${TERM_PROGRAM:-unknown}"
    fi
  fi

  sq() { printf "%s" "$1" | sed "s/'/''/g"; }

  # cmux 워크스페이스 ID — 훅이 에이전트 프로세스의 env를 물려받으므로 그냥 읽힌다
  WS="$CMUX_WORKSPACE_ID"

  ENDED_SQL=
  [ "$EVENT" = SessionEnd ] && ENDED_SQL=", ended_at=$NOW"

  /usr/bin/sqlite3 "$DB" >/dev/null <<SQL
PRAGMA busy_timeout=200;
BEGIN;
INSERT INTO sessions (session_id, agent, project_path, git_branch, source, cmux_ws, started_at, last_event_at, state, pid)
  VALUES ('$(sq "$SESSION_ID")', '$(sq "$AGENT")', '$(sq "$CWD")', $( [ -n "$BRANCH" ] && echo "'$(sq "$BRANCH")'" || echo NULL ),
          $( [ -n "$SRC" ] && echo "'$(sq "$SRC")'" || echo NULL ),
          $( [ -n "$WS" ] && echo "'$(sq "$WS")'" || echo NULL ), $NOW, $NOW, '${STATE:-RUNNING}', $PID_SQL)
  ON CONFLICT(session_id) DO UPDATE SET
    last_event_at=$NOW,
    $( [ -n "$WS" ] && echo "cmux_ws='$(sq "$WS")'," )
    -- SessionStart(새 프로세스/resume)는 pid 갱신, 그 외 이벤트는 비어 있을 때만 백필
    pid=$( [ "$EVENT" = SessionStart ] && echo "$PID_SQL" || echo "COALESCE(pid, $PID_SQL)" )
    $( [ -n "$STATE" ] && echo ", state='$STATE'" )
    $ENDED_SQL
    $( [ "$EVENT" = SessionStart ] && echo ", project_path='$(sq "$CWD")', started_at=$NOW, ended_at=NULL" )
    $( [ -n "$BRANCH" ] && echo ", git_branch='$(sq "$BRANCH")'" )
    $( [ -n "$SRC" ] && echo ", source='$(sq "$SRC")'" )
    $( [ "$STATE" = RUNNING ] && echo ", phase=''" );
INSERT INTO events (session_id, event_type, payload_json, created_at)
  VALUES ('$(sq "$SESSION_ID")', '$(sq "$EVENT")', '$(sq "$PAYLOAD")', $NOW);
COMMIT;
SQL

  # smon-tint v2.1 (reconcile 방식): 원하는 색(tab_want)만 기록하고, 밀린 적용은
  # 세션 컨텍스트인 여기서 동기 처리. detached/launchd 적용은 신뢰 불가 (broken pipe,
  # 프로세스 그룹 정리) — 실측으로 확인된 제약. 이벤트가 상시 흐르므로 수 초 내 수렴.
  ROW=$(/usr/bin/sqlite3 "$DB" "SELECT state || '|' || COALESCE(phase,'') || '|' ||
        COALESCE(cmux_ws,'') FROM sessions WHERE session_id='$(sq "$SESSION_ID")';")
  { IFS='|' read -r CUR_STATE CUR_PHASE CUR_WS; } <<< "$ROW"
  DESIRED=
  case "$CUR_STATE:$CUR_PHASE" in
    NEEDS_ATTENTION:*)       DESIRED=Red ;;
    WAITING_INPUT:done)      DESIRED=Green ;;
    WAITING_INPUT:direction) DESIRED=Blue ;;
  esac
  FORCE=
  { [ "$EVENT" = SessionStart ] || [ -z "$NEW" ]; } && FORCE=1
  if [ -n "$CUR_WS" ]; then
    # FORCE(새 세션/재시작)면 tab_color를 '?'로 — 수동색 등 미지 상태를 강제 재적용
    /usr/bin/sqlite3 "$DB" "PRAGMA busy_timeout=200;
      UPDATE sessions SET tab_want='$DESIRED'$( [ -n "$FORCE" ] && echo ", tab_color='?'" )
      WHERE session_id='$(sq "$SESSION_ID")';"
  fi
  # reconcile: 자기 것 우선 + 밀린 것 포함 최대 3건, 건당 3초 상한
  /usr/bin/sqlite3 -separator '|' "$DB" "
    SELECT session_id, COALESCE(tab_want,''), cmux_ws FROM sessions
    WHERE cmux_ws IS NOT NULL AND cmux_ws != ''
      AND COALESCE(tab_want,'') != COALESCE(tab_color,'')
    ORDER BY CASE WHEN session_id='$(sq "$SESSION_ID")' THEN 0 ELSE 1 END
    LIMIT 3;" | while IFS='|' read -r RSID RWANT RWS; do
    if "$HOME/dev/session-monitor/hooks/apply-color.sh" "$RWS" "$RWANT"; then
      /usr/bin/sqlite3 "$DB" "PRAGMA busy_timeout=200;
        UPDATE sessions SET tab_color='$RWANT' WHERE session_id='$RSID';"
    fi
  done
} >/dev/null 2>&1
# stdout은 반드시 비운다: sqlite3 CLI의 `PRAGMA busy_timeout=N;`이 설정값 N을 결과행으로
# 출력하는데(라인 115/127 미리다이렉트분), Codex Stop 훅은 stdout이 비었거나 유효 JSON일
# 때만 허용해 "invalid stop hook JSON output"으로 거부한다. 이 훅은 기록기이므로 stdout 불필요.
exit 0
