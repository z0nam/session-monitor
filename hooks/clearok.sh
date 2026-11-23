#!/bin/bash
# clear 해도 되는 세션 표시 — cmux 워크스페이스 이름과 그 세션의 터미널 탭 이름 앞에 🟢 (에이전트 중립).
# 사용: clearok.sh <workspace> mark|unmark [surface]  ·  clearok.sh <workspace> find <session_id>
#   mark   : 워크스페이스 이름과(surface 를 주면) 그 탭 이름 앞에 "🟢 " 를 붙이고 원래 이름을 상태 파일에 적는다.
#   unmark : surface 의 탭 표시를 떼고, 그 워크스페이스에 표시된 탭이 더 없으면 워크스페이스 표시도 뗀다.
#            surface 없이 부르면(smon clearok --undo 의 옛 동작) 워크스페이스와 거기 표시된 탭을 모두 뗀다.
#   떼는 법: 원래 이름이 자동 이름이었고 그동안 안 바뀌었으면 clear-name(자동 이름 복귀), 아니면 "🟢 " 만 지운 이름으로 rename.
# 왜 탭에도 붙이나: 한 워크스페이스에 일꾼 탭이 여럿이면 워크스페이스 표시만으로는 어느 탭이 clear 대상인지
#   안 보인다(2026-11-23 사용자 요청).
# 왜 색이 아니라 이모지인가: 탭 색은 사이드바에서 눈에 잘 안 띈다(2026-11-19 사용자 확인).
# 상태: $SMON_DATA_DIR/clearok/<ws>          = "<custom 0|1>\t<원래 워크스페이스 이름>"
#       $SMON_DATA_DIR/clearok/tab/<surface> = "<ws>\t<원래 탭 이름>"
#   훅 핫패스(record-event.sh)는 파일 존재 검사만 해서 평소 fork 0.
#   상태 파일은 표시를 실제로 뗐거나 이미 없음을 확인한 뒤에만 지운다 — cmux 가 잠깐 실패해도 다음 입력·--undo 가 다시 시도하게.
# cmux 는 cmux 안에서 시작된 프로세스만 받는다(launchd·외부 셸은 Access denied). 호출당 상한 3초.
WS="$1" OP="$2" SURF="$3"
CMUX="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
STATE="${SMON_DATA_DIR:-$HOME/.local/share/smon}/clearok"
TABS="$STATE/tab"
MARK="🟢 "
[ -n "$WS" ] && [ -x "$CMUX" ] || exit 1
case "$WS$SURF" in */*) exit 1 ;; esac
run() { CMUX_QUIET=1 perl -e 'alarm 3; exec @ARGV' -- "$@"; }

# 모든 창에서 워크스페이스를 찾아 "custom<TAB>title" 출력
ws_info() {
  local wins
  wins=$(run "$CMUX" list-windows --json 2>/dev/null | /usr/bin/python3 -c \
    'import sys,json; [print(w["id"]) for w in json.load(sys.stdin)]' 2>/dev/null)
  for w in $wins; do
    run "$CMUX" workspace list --window "$w" --json 2>/dev/null | /usr/bin/python3 -c '
import sys, json
ws = sys.argv[1].upper()
for x in json.load(sys.stdin).get("workspaces", []):
    if x.get("id", "").upper() == ws or x.get("ref") == sys.argv[1]:
        print(("1" if x.get("has_custom_title") else "0") + "\t" + (x.get("title") or ""))
        sys.exit(0)
sys.exit(1)' "$WS" && return 0
  done
  return 1
}

# 워크스페이스의 모든 탭을 "UUID<TAB>이름" 으로 출력. cmux 조회가 하나라도 실패하면 실패.
ws_surfaces() {
  local panes p out
  panes=$(run "$CMUX" list-panes --workspace "$WS" --json 2>/dev/null | /usr/bin/python3 -c \
    'import sys,json; [print(p["id"]) for p in json.load(sys.stdin).get("panes", [])]' 2>/dev/null) || return 1
  [ -n "$panes" ] || return 1
  for p in $panes; do
    out=$(run "$CMUX" list-pane-surfaces --workspace "$WS" --pane "$p" --json 2>/dev/null | /usr/bin/python3 -c '
import sys, json
for x in json.load(sys.stdin).get("surfaces", []):
    print((x.get("id") or "").upper() + "\t" + (x.get("title") or ""))') || return 1
    printf '%s\n' "$out"
  done
}

# 탭의 현재 이름 출력. 0 = 찾음 · 1 = 조회는 됐고 그 탭이 없음(닫힘) · 2 = 조회 실패(다음에 다시)
tab_title() {
  local all line S
  S=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  all=$(ws_surfaces) || return 2
  while IFS= read -r line; do
    [ "${line%%$'\t'*}" = "$S" ] && { printf '%s\n' "${line#*$'\t'}"; return 0; }
  done <<< "$all"
  return 1
}

# 이 워크스페이스에 표시된 탭(상태 파일) 목록
marked_tabs() {
  local f
  for f in "$TABS"/*; do
    [ -f "$f" ] || continue
    [ "$(head -n1 "$f" | cut -f1)" = "$WS" ] && echo "${f##*/}"
  done
}

mark_ws() {
  local I CUSTOM TITLE
  I=$(ws_info) || return 1
  CUSTOM=${I%%$'\t'*} TITLE=${I#*$'\t'}
  case "$TITLE" in "$MARK"*) return 0 ;; esac          # 이미 표시됨
  mkdir -p "$STATE" && printf '%s\t%s' "$CUSTOM" "$TITLE" > "$STATE/$WS"
  run "$CMUX" workspace-action --workspace "$WS" --action rename --title "$MARK$TITLE" >/dev/null
}

unmark_ws() {
  local SAVED I TITLE BARE
  [ -f "$STATE/$WS" ] || return 0
  SAVED=$(cat "$STATE/$WS")
  I=$(ws_info) || return 1
  TITLE=${I#*$'\t'}
  case "$TITLE" in "$MARK"*) ;; *) rm -f "$STATE/$WS"; return 0 ;; esac   # 사용자가 이미 지움
  BARE=${TITLE#"$MARK"}
  if [ "${SAVED%%$'\t'*}" = 0 ] && [ "$BARE" = "${SAVED#*$'\t'}" ]; then
    run "$CMUX" workspace-action --workspace "$WS" --action clear-name >/dev/null
  else
    run "$CMUX" workspace-action --workspace "$WS" --action rename --title "$BARE" >/dev/null
  fi || return 1
  rm -f "$STATE/$WS"
}

mark_tab() {
  local S="$1" TITLE
  TITLE=$(tab_title "$S") || return 1
  case "$TITLE" in "$MARK"*) return 0 ;; esac
  mkdir -p "$TABS" && printf '%s\t%s' "$WS" "$TITLE" > "$TABS/$S"
  run "$CMUX" tab-action --workspace "$WS" --tab "$S" --action rename --title "$MARK$TITLE" >/dev/null
}

unmark_tab() {
  local S="$1" TITLE BARE
  [ -f "$TABS/$S" ] || return 0
  TITLE=$(tab_title "$S"); case $? in
    1) rm -f "$TABS/$S"; return 0 ;;   # 탭이 닫혔음을 확인 — 뗄 것이 없다
    2) return 1 ;;                     # 조회 실패 — 상태를 남겨 다음 입력·--undo 가 다시 시도 (#9 Codex 리뷰)
  esac
  case "$TITLE" in "$MARK"*) ;; *) rm -f "$TABS/$S"; return 0 ;; esac
  BARE=${TITLE#"$MARK"}
  # 탭에는 "사용자가 지은 이름" 플래그가 없다 → 일단 자동 이름으로 돌리고, 원래 이름과 다르면 rename.
  run "$CMUX" tab-action --workspace "$WS" --tab "$S" --action clear-name >/dev/null || return 1
  [ "$(tab_title "$S")" = "$BARE" ] || \
    run "$CMUX" tab-action --workspace "$WS" --tab "$S" --action rename --title "$BARE" >/dev/null || return 1
  rm -f "$TABS/$S"
}

# 세션 id 로 탭(surface UUID) 찾기 — 훅이 아직 대응을 못 적은 세션용(이 기능 전부터 떠 있던 세션).
# cmux 가 탭마다 기억하는 resume 정보(checkpoint_id = 세션 id)로 찾는다.
find_surface() {
  local ref
  ref=$(run "$CMUX" list-panels --workspace "$WS" --json 2>/dev/null | /usr/bin/python3 -c '
import sys, json
sid = sys.argv[1]
for x in json.load(sys.stdin).get("surfaces", []):
    if ((x.get("resume_binding") or {}).get("checkpoint_id") or "") == sid:
        print(x.get("ref") or ""); sys.exit(0)
sys.exit(1)' "$1") || return 1
  local panes p
  panes=$(run "$CMUX" list-panes --workspace "$WS" --json 2>/dev/null | /usr/bin/python3 -c \
    'import sys,json; [print(p["id"]) for p in json.load(sys.stdin).get("panes", [])]' 2>/dev/null) || return 1
  for p in $panes; do
    run "$CMUX" list-pane-surfaces --workspace "$WS" --pane "$p" --json 2>/dev/null | /usr/bin/python3 -c '
import sys, json
for x in json.load(sys.stdin).get("surfaces", []):
    if x.get("ref") == sys.argv[1]:
        print(x.get("id") or ""); sys.exit(0)
sys.exit(1)' "$ref" && return 0
  done
  return 1
}

case "$OP" in
  find)
    find_surface "$SURF"
    ;;
  mark)
    mark_ws || exit 1
    [ -z "$SURF" ] || mark_tab "$SURF" || exit 1
    ;;
  unmark)
    if [ -n "$SURF" ]; then
      unmark_tab "$SURF" || exit 1
    else
      for t in $(marked_tabs); do unmark_tab "$t" || exit 1; done
    fi
    # 닫힌 탭의 기록은 먼저 치운다 — 안 그러면 표시된 탭이 없는데도 워크스페이스 🟢 가 남는다 (#9 Codex 리뷰)
    for t in $(marked_tabs); do tab_title "$t" >/dev/null; [ $? = 1 ] && rm -f "$TABS/$t"; done
    [ -n "$(marked_tabs)" ] || unmark_ws || exit 1    # 다른 탭이 아직 표시돼 있으면 워크스페이스 표시는 둔다
    ;;
  *) echo "usage: clearok.sh <workspace> mark|unmark [surface] | find <session_id>" >&2; exit 2 ;;
esac
