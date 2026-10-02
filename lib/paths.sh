# shellcheck shell=bash
# session-monitor 경로 해석 — 모든 bash 스크립트가 source 하는 단일 지점 (SSOT).
# 훅 핫패스에서 source 되므로 프로세스를 띄우지 않는다(서브셸·python 금지, stat 1~2회뿐).
#
#   SMON_HOME : 형제 스크립트를 찾는 레포 루트. 기본 = 이 파일 위치의 상위
#               (호출측이 `. "<자기폴더>/../lib/paths.sh"` 로 source → `<자기폴더>/..`).
#               env 로 override 가능.
#   SMON_DB   : 세션 DB. 우선순위 = env SMON_DB
#               > ~/.local/share/smon/sessions.db (파일이 있으면)
#               > ~/dev/session-monitor/sessions.db (구 위치, 레거시 기본)
#               → DB 이전은 파일 이동만으로 끝난다(코드 변경 없음).
# 둘 다 export 하지 않는다 — 자식 프로세스도 같은 규칙으로 같은 값을 얻는다.
# (단 사용자가 env 로 준 값은 원래 export 돼 있으니 그대로 전파된다.)
if [ -z "${SMON_HOME:-}" ]; then
  SMON_HOME=${BASH_SOURCE[0]%/lib/paths.sh}
  case $SMON_HOME in
    "${BASH_SOURCE[0]}") SMON_HOME=. ;;         # `. lib/paths.sh` (레포 루트에서 상대 source)
    */?*/..) SMON_HOME=${SMON_HOME%/*/..} ;;   # /repo/hooks/.. → /repo (보기 좋게; 동작은 같음)
    ?*/..) SMON_HOME=. ;;                       # hooks/.. (상대 호출) → .
  esac
fi
SMON_DATA_DIR="$HOME/.local/share/smon"
if [ -z "${SMON_DB:-}" ]; then
  if [ -f "$SMON_DATA_DIR/sessions.db" ]; then
    SMON_DB="$SMON_DATA_DIR/sessions.db"
  else
    SMON_DB="$HOME/dev/session-monitor/sessions.db"
  fi
fi
