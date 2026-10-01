#!/bin/bash
# 배포 폴더(-run) + DB 이전 마이그레이션 — 개발 체크아웃(~/dev/session-monitor)과 실행 체크아웃
# (~/dev/session-monitor-run)을 분리하고, DB 를 ~/.local/share/smon/sessions.db 로 옮긴다.
#
# 사용: deploy/migrate-to-run.sh            # DRY-RUN (기본) — 무엇을 할지 출력만, 아무것도 안 바꾼다
#       deploy/migrate-to-run.sh --apply    # 실행. 조용한 시간대에.
#       deploy/migrate-to-run.sh --apply --force   # RUNNING 세션이 있어도 진행
# 되돌리기: deploy/rollback-run.sh (이 스크립트가 남긴 백업 폴더를 사용)
#
# 전제: 이 PR(lib/paths.sh)이 main 에 머지되고 개발 체크아웃도 그 코드다 — 그래야 DB 를 옮기는
# 순간부터 구 경로 훅도 새 DB 를 따라간다. 멱등: 이미 끝난 단계는 확인만 하고 넘어간다.
# 비밀값(토큰 등)은 다루지도 출력하지도 않는다.
set -euo pipefail

APPLY=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $a" >&2; exit 2 ;;
  esac
done

DEV="${SMON_DEV_DIR:-$HOME/dev/session-monitor}"
RUN="${SMON_RUN_DIR:-$HOME/dev/session-monitor-run}"
DATA="$HOME/.local/share/smon"
NEWDB="${SMON_NEW_DB:-$DATA/sessions.db}"
OLDDB="$DEV/sessions.db"
TS=$(date +%Y%m%d-%H%M%S)
BK="$DATA/migrate-$TS"          # 백업·매니페스트 (rollback-run.sh 가 읽는다)
LA="$HOME/Library/LaunchAgents"
PLISTS="com.namun.smon-worker com.namun.smon-pull com.namun.smon-report com.namun.parsec-awake"
SQ=/usr/bin/sqlite3
. "$(cd "$(dirname "$0")" && pwd)/lib-dbmove.sh"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '!! 중단: %s\n' "$*" >&2; exit 1; }
# do_ <설명> <명령...> : dry-run 이면 출력만, apply 면 실행 (실패 시 set -e 로 중단)
do_()  { local d=$1; shift; if [ "$APPLY" = 1 ]; then say "  - $d"; "$@"; else say "  [dry] $d"; fi; }
bk()   { [ -e "$1" ] || return 0; mkdir -p "$BK"; cp -p "$1" "$BK/$2"; say "    백업: $BK/$2"; }
tables_counts() { $SQ -cmd '.timeout 2000' "file:$1?mode=ro" \
  "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" |
  while IFS= read -r t; do printf '%s=%s ' "$t" "$($SQ -cmd '.timeout 2000' "file:$1?mode=ro" "SELECT count(*) FROM \"$t\";")"; done; }

[ "$APPLY" = 1 ] && say "### APPLY 모드 — 실제로 변경한다 (백업: $BK)" || say "### DRY-RUN — 아무것도 바꾸지 않는다. 실행은 --apply"
say "dev=$DEV  run=$RUN  old_db=$OLDDB  new_db=$NEWDB"

# ---------------------------------------------------------------- a. preflight
step "a. preflight"
[ -d "$DEV/.git" ] || die "개발 체크아웃 없음: $DEV"
if [ ! -f "$DEV/lib/paths.sh" ]; then
  m="$DEV 에 lib/paths.sh 없음 — 경로 리팩터 PR 머지 후 git -C $DEV pull 먼저 (구 코드 훅은 DB 이동을 못 따라간다)"
  [ "$APPLY" = 1 ] && die "$m"; say "  ! $m (apply 시 중단)"
fi
for c in /usr/bin/jq /usr/bin/python3 git launchctl; do command -v "$c" >/dev/null || die "$c 없음"; done
CURDB=$OLDDB; [ -f "$NEWDB" ] && CURDB=$NEWDB
[ -f "$CURDB" ] || die "DB 를 찾을 수 없음 ($OLDDB / $NEWDB)"
NRUN=$($SQ -cmd '.timeout 2000' "file:$CURDB?mode=ro" "SELECT count(*) FROM sessions WHERE state='RUNNING';")
if [ "$NRUN" -gt 0 ]; then
  say "  ! RUNNING 세션 $NRUN 개 (이 머신):"
  $SQ -cmd '.timeout 2000' "file:$CURDB?mode=ro" "SELECT '    '||agent||' '||session_id||' '||project_path FROM sessions WHERE state='RUNNING';"
  [ "$FORCE" = 1 ] || { [ "$APPLY" = 1 ] && die "RUNNING 세션 있음 — 조용할 때 다시, 또는 --force"; say "  (apply 시 --force 필요)"; }
else
  say "  RUNNING 세션 없음"
fi
[ -z "$(git -C "$DEV" status --porcelain)" ] || die "개발 체크아웃이 깨끗하지 않음: git -C $DEV status"
if [ -d "$RUN/.git" ]; then
  [ -z "$(git -C "$RUN" status --porcelain)" ] || die "실행 체크아웃이 깨끗하지 않음: git -C $RUN status"
fi
say "  체크아웃 깨끗함"
ORIGIN=$(git -C "$DEV" remote get-url origin)

# ---------------------------------------------------------------- b. run 체크아웃
step "b. 실행 체크아웃 $RUN"
if [ -d "$RUN/.git" ]; then
  do_ "git -C $RUN pull --ff-only" git -C "$RUN" pull --ff-only -q
elif [ -e "$RUN" ]; then
  die "$RUN 이 있는데 git 체크아웃이 아님"
else
  do_ "git clone $ORIGIN $RUN" git clone -q "$ORIGIN" "$RUN"
fi
if [ "$APPLY" = 1 ]; then
  [ -f "$RUN/lib/paths.sh" ] || die "$RUN 에 lib/paths.sh 없음 (main 에 머지 전?)"
  [ "$(git -C "$RUN" branch --show-current)" = main ] || die "$RUN 이 main 이 아님"
  mkdir -p "$RUN/report/logs"
fi

# ---------------------------------------------------------------- c. DB 이동
step "c. DB 이동 $OLDDB -> $NEWDB"
if [ -f "$NEWDB" ] && [ ! -f "$OLDDB" ]; then
  say "  이미 이동됨 (새 DB 만 있음) — 건너뜀"
elif [ -f "$NEWDB" ] && [ -f "$OLDDB" ]; then
  # 앞선 실행이 배수 중 중단된 경우: 그 기준본으로 배수만 이어간다 (멱등)
  PREV=$(ls -1d "$DATA"/migrate-*/ 2>/dev/null | while IFS= read -r d; do
           [ -f "$d/base.db" ] && ! grep -q '^MIGRATED=' "$d/manifest" 2>/dev/null && echo "${d%/}"; done | tail -1)
  [ -n "$PREV" ] || die "두 위치에 모두 DB 가 있는데 중단된 이전 기록이 없음 — 수동 확인 필요"
  say "  이전 실행이 배수 중 중단됨 ($PREV) — 배수 재개"
  if [ "$APPLY" = 1 ]; then
    trap 'dbm_resume_launchd' EXIT
    dbm_pause_launchd $PLISTS
    dbm_drain "$OLDDB" "$NEWDB" "$PREV/base.db" "$PREV" || die "옛 DB 가 계속 바뀜 — 조용할 때 다시"
    $SQ -cmd '.timeout 5000' "$OLDDB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
    for s in "" -wal -shm; do [ -e "$OLDDB$s" ] && mv "$OLDDB$s" "$DEV/sessions.db.migrated-$TS$s"; done
    echo "OLDDB=$OLDDB" >> "$PREV/manifest"; echo "MIGRATED=$DEV/sessions.db.migrated-$TS" >> "$PREV/manifest"
    BK=$PREV
    say "  - 구 DB → $DEV/sessions.db.migrated-$TS"
  fi
else
  say "  현재 행수: $(tables_counts "$OLDDB")"
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$DATA" "$BK"
    # 멈출 수 있는 쓰기(launchd 워커·pull·리포트)는 멈춘다. 실패로 중단돼도 되살린다.
    trap 'dbm_resume_launchd' EXIT
    dbm_pause_launchd $PLISTS
    dbm_check_tables "$OLDDB" || die "스키마에 병합 규칙 없는 테이블 — 이전 중단"
    # 1) 일관 스냅샷을 새 위치에 놓아 쓰기 대상을 전환 (paths.sh 는 새 파일이 생긴 순간부터 그쪽을 고른다)
    dbm_snapshot "$OLDDB" "$NEWDB.tmp" || die ".backup/integrity 실패"
    cp -p "$NEWDB.tmp" "$BK/base.db"
    mv "$NEWDB.tmp" "$NEWDB"
    say "  - 스냅샷 → $NEWDB (쓰기 대상 전환), 기준본 $BK/base.db"
    # 2) 전환 직전에 경로를 해석한 훅의 늦은 쓰기를 병합 — 옛 DB 가 조용해질 때까지
    say "  - 배수: ${DRAIN_GRACE}s 간격 최대 ${DRAIN_ROUNDS}회 (행수가 아니라 덤프 해시로 변화 감지, UPDATE 포함)"
    dbm_drain "$OLDDB" "$NEWDB" "$BK/base.db" "$BK" || die "옛 DB 가 계속 바뀜 — 구 경로 훅이 아직 해석 중? 새 DB 는 유지됨. 조용할 때 다시(멱등) 또는 rollback"
    [ "$($SQ "$NEWDB" 'PRAGMA integrity_check;')" = ok ] || die "병합 후 integrity_check 실패 ($NEWDB)"
    # 3) 조용해진 뒤에만 옛 파일을 보관 이름으로 (삭제 안 함)
    $SQ -cmd '.timeout 5000' "$OLDDB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
    for s in "" -wal -shm; do
      [ -e "$OLDDB$s" ] && mv "$OLDDB$s" "$DEV/sessions.db.migrated-$TS$s"
    done
    echo "OLDDB=$OLDDB" >> "$BK/manifest"; echo "MIGRATED=$DEV/sessions.db.migrated-$TS" >> "$BK/manifest"
    say "  - 구 DB → $DEV/sessions.db.migrated-$TS (+wal/shm). 행수: $(tables_counts "$NEWDB")"
  else
    say "  [dry] launchd 쓰기 작업 일시정지 → .backup 스냅샷을 NEW 로 (쓰기 대상 전환) + 기준본 보관"
    say "  [dry] 배수: ${DRAIN_GRACE}s마다 OLD 재스냅샷 → 덤프 해시가 기준본과 같아질 때까지 변경분을 NEW 로 병합 (최대 ${DRAIN_ROUNDS}회)"
    say "  [dry] 조용해지면 OLD{,-wal,-shm} → sessions.db.migrated-$TS{,-wal,-shm} (삭제 안 함), launchd 재개"
  fi
fi

# ---------------------------------------------------------------- d. 훅 명령 경로
step "d. 에이전트 훅 경로 $DEV/ -> $RUN/"
CS="$HOME/.claude/settings.json"
if [ -f "$CS" ]; then
  N=$(grep -c "$DEV/hooks/" "$CS" || true)
  say "  claude settings.json: 구 경로 $N 건"
  if [ "$N" -gt 0 ]; then
    [ "$APPLY" = 1 ] && bk "$CS" claude-settings.json
    do_ "claude settings.json 훅 command 치환 (python json)" /usr/bin/python3 - "$CS" "$DEV/" "$RUN/" <<'PY'
import json, sys
p, old, new = sys.argv[1:4]
s = json.load(open(p))
n = 0
for arr in s.get("hooks", {}).values():
    for e in arr:
        for h in e.get("hooks", []):
            c = h.get("command", "")
            if c.startswith(old):
                h["command"] = new + c[len(old):]; n += 1
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
print(f"    {n} 건 치환")
PY
  fi
fi
regen() {  # regen <어댑터> <대상> <백업이름>
  [ -f "$2" ] || { say "  $2 없음 — 건너뜀"; return 0; }
  if grep -q "$RUN/hooks/" "$2" && ! grep -q "$DEV/hooks/" "$2"; then say "  $2 이미 run 경로"; return 0; fi
  [ "$APPLY" = 1 ] && bk "$2" "$3"
  do_ "$2 ← $1 (__REPO__=$RUN)" sh -c 'sed "s#__REPO__#$1#g" "$2" > "$3.tmp" && /usr/bin/jq -e . "$3.tmp" >/dev/null && mv "$3.tmp" "$3"' _ "$RUN" "$1" "$2"
}
regen "$RUN/adapters/codex-hooks.json" "$HOME/.codex/hooks.json" codex-hooks.json
regen "$RUN/adapters/antigravity-hooks.json" "$HOME/.gemini/antigravity-cli/hooks.json" agy-hooks.json
HH="${HERMES_HOME:-$HOME/.hermes}"
if command -v hermes >/dev/null 2>&1 && [ -f "$HH/config.yaml" ]; then
  if grep -q "$DEV/hooks/hermes-event.sh" "$HH/config.yaml"; then
    [ "$APPLY" = 1 ] && { bk "$HH/config.yaml" hermes-config.yaml; bk "$HH/shell-hooks-allowlist.json" hermes-allowlist.json; }
    # 승인(allowlist)을 먼저 — hooks 를 바꾸는 순간 새 command 가 미승인이면 프롬프트가 뜬다.
    do_ "hermes allowlist 에 $RUN/hooks/hermes-event.sh 추가" /usr/bin/python3 - "$HH/shell-hooks-allowlist.json" "$RUN/hooks/hermes-event.sh" <<'PY'
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
    if [ "$APPLY" = 1 ]; then
      H_HOOKS=$(grep -v '^#' "$RUN/adapters/hermes-hooks.yaml" | sed "s#__REPO__#$RUN#g")
      hermes config set --force hooks "$H_HOOKS" >/dev/null
      grep -q "$RUN/hooks/hermes-event.sh" "$HH/config.yaml" || die "hermes config 에 새 경로가 안 보임"
      say "  - hermes hooks ← adapters/hermes-hooks.yaml (__REPO__=$RUN)"
    else
      say "  [dry] hermes config set --force hooks <adapters/hermes-hooks.yaml, __REPO__=$RUN>"
    fi
  else
    say "  hermes: 구 경로 없음 — 건너뜀"
  fi
fi

# ---------------------------------------------------------------- e. launchd
step "e. launchd ($PLISTS)"
for L in $PLISTS; do
  P="$LA/$L.plist"
  [ -f "$P" ] || { say "  $L: plist 없음 — 건너뜀"; continue; }
  grep -q "$DEV/" "$P" || { say "  $L: 구 경로 없음 — 건너뜀"; continue; }
  # 바뀐 뒤 가리킬 경로가 run 쪽에 실제로 있는지 (예: parsec-awake/ 는 gitignore 라 clone 에 없다)
  missing=
  for f in $(grep -o "$DEV/[^<]*" "$P"); do
    rel=${f#"$DEV/"}; t="$RUN/$rel"
    case "$t" in
      *.log|*.err) [ -d "$(dirname "$t")" ] || [ "$APPLY" = 0 ] || missing="$missing $t" ;;
      *) if [ -d "$RUN/.git" ]; then [ -e "$t" ] || missing="$missing $t"
         else git -C "$DEV" cat-file -e "origin/main:$rel" 2>/dev/null || missing="$missing $t"; fi ;;  # dry-run, clone 전
    esac
  done
  if [ -n "$missing" ]; then
    say "  ! $L: run 체크아웃에 없음 →$missing — 건너뜀(개발 폴더를 계속 가리킴; 추적 안 되는 로컬 도구면 수동 이동)"
    continue
  fi
  [ "$APPLY" = 1 ] && bk "$P" "$L.plist"
  do_ "$L: 경로 치환" sed -i '' "s#$DEV/#$RUN/#g" "$P"
  do_ "$L: launchctl bootout" sh -c 'launchctl bootout "gui/$(id -u)" "$1" 2>/dev/null || true' _ "$P"
  do_ "$L: launchctl bootstrap" launchctl bootstrap "gui/$(id -u)" "$P"
done

# ---------------------------------------------------------------- f. 심링크
step "f. 심링크"
SL="$HOME/.local/bin/smon"
if [ "$(readlink "$SL" 2>/dev/null || true)" = "$RUN/bin/smon" ]; then say "  ~/.local/bin/smon 이미 run"
else
  [ "$APPLY" = 1 ] && { mkdir -p "$BK"; echo "LINK=$SL|$(readlink "$SL" 2>/dev/null || true)" >> "$BK/manifest"; }
  do_ "ln -sfn $RUN/bin/smon $SL" ln -sfn "$RUN/bin/smon" "$SL"
fi
for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.hermes/skills" "$HOME/.agents/skills"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 3 -type l 2>/dev/null | while IFS= read -r l; do
    t=$(readlink "$l")
    case "$t" in "$DEV/"*) ;; *) continue ;; esac
    nt="$RUN/${t#"$DEV/"}"
    [ "$APPLY" = 1 ] && { [ -e "$nt" ] || die "대상 없음: $nt"; mkdir -p "$BK"; echo "LINK=$l|$t" >> "$BK/manifest"; }
    do_ "$l -> $nt" ln -sfn "$nt" "$l"
  done
done

# ---------------------------------------------------------------- g. 사후 점검
step "g. 사후 점검 (새 경로로 합성 이벤트 1건 → 새 DB 확인 → 삭제)"
SID="smon-migrate-check-$TS"
if [ "$APPLY" = 1 ]; then
  printf '{"session_id":"%s","cwd":"/tmp"}' "$SID" |
    env -u SMON_DB -u SMON_HOME -u CMUX_WORKSPACE_ID -u CMUX_SESSION_ID "$RUN/hooks/record-event.sh" Stop claude
  N=$($SQ -cmd '.timeout 2000' "$NEWDB" "SELECT count(*) FROM sessions WHERE session_id='$SID';")
  $SQ -cmd '.timeout 2000' "$NEWDB" "DELETE FROM events WHERE session_id='$SID'; DELETE FROM sessions WHERE session_id='$SID';"
  [ "$N" = 1 ] || die "합성 이벤트가 새 DB 에 없음 ($NEWDB) — 롤백 고려: deploy/rollback-run.sh $BK"
  [ ! -e "$OLDDB" ] || say "  ! 구 경로에 DB 파일이 다시 생겼다($OLDDB) — 구 코드 훅이 아직 도는지 확인"
  say "  ok — 새 DB 에 기록됨, 정리함"
  echo; say "완료. 백업/매니페스트: $BK"
  say "열린 에이전트 세션은 시작 시 훅 설정을 읽으므로 구 경로를 계속 부른다 — 개발 폴더 코드도 새 DB 를 따라가니 문제없다."
  say "되돌리기: $RUN/deploy/rollback-run.sh $BK"
else
  say "  [dry] echo '{\"session_id\":\"$SID\",...}' | $RUN/hooks/record-event.sh Stop claude → $NEWDB 에 1행 확인 → DELETE"
  echo; say "DRY-RUN 끝. 실행: $0 --apply"
fi
