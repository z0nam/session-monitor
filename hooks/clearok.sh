#!/bin/bash
# clear 해도 되는 세션 표시 — cmux 탭 이름 앞에 🟢 (에이전트 중립).
# 사용: clearok.sh <workspace> mark|unmark
#   mark   : 이름 앞에 "🟢 " 를 붙이고, 원래 이름이 자동 이름이었는지를 상태 파일에 적는다.
#   unmark : 붙인 "🟢 " 만 떼어 낸다. 원래 자동 이름이었고 그동안 이름이 안 바뀌었으면 clear-name 으로 자동 이름 복귀.
# 왜 색이 아니라 이모지인가: 탭 색은 사이드바에서 눈에 잘 안 띈다(2026-11-19 사용자 확인).
# 상태: $SMON_DATA_DIR/clearok/<ws> = "<custom 0|1>\t<원래 이름>". unmark 는 이 파일이 있을 때만 일한다 —
#   훅 핫패스(record-event.sh)는 파일 존재 검사만 해서 평소 fork 0.
# cmux 는 cmux 안에서 시작된 프로세스만 받는다(launchd·외부 셸은 Access denied). 상한 3초.
WS="$1" OP="$2"
CMUX="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
STATE="${SMON_DATA_DIR:-$HOME/.local/share/smon}/clearok"
MARK="🟢 "
[ -n "$WS" ] && [ -x "$CMUX" ] || exit 1
run() { CMUX_QUIET=1 perl -e 'alarm 3; exec @ARGV' -- "$@"; }

# 모든 창에서 워크스페이스를 찾아 "custom<TAB>title" 출력
info() {
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

case "$OP" in
  mark)
    I=$(info) || exit 1
    CUSTOM=${I%%$'\t'*} TITLE=${I#*$'\t'}
    case "$TITLE" in "$MARK"*) exit 0 ;; esac          # 이미 표시됨
    mkdir -p "$STATE" && printf '%s\t%s' "$CUSTOM" "$TITLE" > "$STATE/$WS"
    run "$CMUX" workspace-action --workspace "$WS" --action rename --title "$MARK$TITLE" >/dev/null
    ;;
  unmark)
    [ -f "$STATE/$WS" ] || exit 0
    SAVED=$(cat "$STATE/$WS"); rm -f "$STATE/$WS"
    I=$(info) || exit 0
    TITLE=${I#*$'\t'}
    case "$TITLE" in "$MARK"*) ;; *) exit 0 ;; esac   # 사용자가 이미 지움
    BARE=${TITLE#"$MARK"}
    if [ "${SAVED%%$'\t'*}" = 0 ] && [ "$BARE" = "${SAVED#*$'\t'}" ]; then
      run "$CMUX" workspace-action --workspace "$WS" --action clear-name >/dev/null
    else
      run "$CMUX" workspace-action --workspace "$WS" --action rename --title "$BARE" >/dev/null
    fi
    ;;
  *) echo "usage: clearok.sh <workspace> mark|unmark" >&2; exit 2 ;;
esac
