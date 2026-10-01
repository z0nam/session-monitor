#!/bin/bash
# migrate-to-run.sh 되돌리기 — 훅 경로(d)·launchd(e)·심링크(f)를 개발 체크아웃으로, DB 를 레포 안으로.
#
# 사용: deploy/rollback-run.sh [백업폴더]            # DRY-RUN (기본)
#       deploy/rollback-run.sh [백업폴더] --apply
#   백업폴더 기본 = ~/.local/share/smon/migrate-* 중 최신 (migrate 가 남긴 것)
#
# 원칙: 재생성 파일(codex/agy hooks.json, launchd plist)은 백업에서 복원한다. 사용자 설정이 섞인
# 파일(~/.claude/settings.json, ~/.hermes/config.yaml)은 통째 복원하면 그 사이 바뀐 설정이 날아가므로
# 경로만 역치환한다(백업 파일은 그대로 남겨 둔다). 실행 체크아웃(-run)은 지우지 않는다.
set -euo pipefail

APPLY=0 BK=
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "알 수 없는 옵션: $a" >&2; exit 2 ;;
    *) BK=$a ;;
  esac
done

DEV="${SMON_DEV_DIR:-$HOME/dev/session-monitor}"
RUN="${SMON_RUN_DIR:-$HOME/dev/session-monitor-run}"
DATA="$HOME/.local/share/smon"
NEWDB="${SMON_NEW_DB:-$DATA/sessions.db}"
OLDDB="$DEV/sessions.db"
TS=$(date +%Y%m%d-%H%M%S)
LA="$HOME/Library/LaunchAgents"
PLISTS="com.namun.smon-worker com.namun.smon-pull com.namun.smon-report com.namun.parsec-awake"
SQ=/usr/bin/sqlite3
. "$(cd "$(dirname "$0")" && pwd)/lib-dbmove.sh"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '!! 중단: %s\n' "$*" >&2; exit 1; }
do_()  { local d=$1; shift; if [ "$APPLY" = 1 ]; then say "  - $d"; "$@"; else say "  [dry] $d"; fi; }
tables_counts() { $SQ -cmd '.timeout 2000' "file:$1?mode=ro" \
  "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" |
  while IFS= read -r t; do printf '%s=%s ' "$t" "$($SQ -cmd '.timeout 2000' "file:$1?mode=ro" "SELECT count(*) FROM \"$t\";")"; done; }

if [ -z "$BK" ]; then
  # shellcheck disable=SC2012  # 이름이 타임스탬프라 ls 정렬로 충분
  BK=$(ls -d "$DATA"/migrate-* 2>/dev/null | sort | tail -1 || true)
fi
[ -n "$BK" ] && [ -d "$BK" ] || { say "백업 폴더 없음 — plist/hooks.json 은 어댑터에서 재생성으로 되돌린다"; BK=; }
[ "$APPLY" = 1 ] && say "### APPLY 모드" || say "### DRY-RUN — 실행은 --apply"
say "dev=$DEV  run=$RUN  backup=${BK:-(없음)}"
if [ ! -f "$DEV/lib/paths.sh" ]; then
  [ "$APPLY" = 1 ] && die "$DEV 에 lib/paths.sh 없음"; say "  ! $DEV 에 lib/paths.sh 없음 (apply 시 중단)"
fi

# ---------------------------------------------------------------- d. 훅 경로
step "d. 에이전트 훅 경로 $RUN/ -> $DEV/"
CS="$HOME/.claude/settings.json"
if [ -f "$CS" ] && grep -q "$RUN/hooks/" "$CS"; then
  [ "$APPLY" = 1 ] && cp -p "$CS" "$CS.bak-smon-rollback-$TS"
  do_ "claude settings.json 경로 역치환" /usr/bin/python3 - "$CS" "$RUN/" "$DEV/" <<'PY'
import json, sys
p, old, new = sys.argv[1:4]
s = json.load(open(p))
for arr in s.get("hooks", {}).values():
    for e in arr:
        for h in e.get("hooks", []):
            c = h.get("command", "")
            if c.startswith(old):
                h["command"] = new + c[len(old):]
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
PY
else say "  claude: run 경로 없음 — 건너뜀"; fi
restore_json() {  # restore_json <백업이름> <어댑터> <대상>
  [ -f "$3" ] || return 0
  grep -q "$RUN/hooks/" "$3" || { say "  $3: run 경로 없음 — 건너뜀"; return 0; }
  if [ -n "$BK" ] && [ -f "$BK/$1" ]; then do_ "$3 ← 백업 $BK/$1" cp -p "$BK/$1" "$3"
  else do_ "$3 ← $2 (__REPO__=$DEV)" sh -c 'sed "s#__REPO__#$1#g" "$2" > "$3"' _ "$DEV" "$2" "$3"; fi
}
restore_json codex-hooks.json "$DEV/adapters/codex-hooks.json" "$HOME/.codex/hooks.json"
restore_json agy-hooks.json "$DEV/adapters/antigravity-hooks.json" "$HOME/.gemini/antigravity-cli/hooks.json"
HH="${HERMES_HOME:-$HOME/.hermes}"
if command -v hermes >/dev/null 2>&1 && [ -f "$HH/config.yaml" ] && grep -q "$RUN/hooks/" "$HH/config.yaml"; then
  # allowlist 는 그대로 둔다 — 구 경로 승인은 원래 있었고, 남은 run 경로 승인은 무해하다.
  if [ "$APPLY" = 1 ]; then
    H_HOOKS=$(grep -v '^#' "$DEV/adapters/hermes-hooks.yaml" | sed "s#__REPO__#$DEV#g")
    hermes config set --force hooks "$H_HOOKS" >/dev/null
    say "  - hermes hooks ← adapters/hermes-hooks.yaml (__REPO__=$DEV)"
  else say "  [dry] hermes config set --force hooks <__REPO__=$DEV>"; fi
else say "  hermes: run 경로 없음 — 건너뜀"; fi

# ---------------------------------------------------------------- e. launchd
step "e. launchd"
for L in $PLISTS; do
  P="$LA/$L.plist"
  [ -f "$P" ] && grep -q "$RUN/" "$P" || { say "  $L: run 경로 없음 — 건너뜀"; continue; }
  if [ -n "$BK" ] && [ -f "$BK/$L.plist" ]; then do_ "$L ← 백업" cp -p "$BK/$L.plist" "$P"
  else do_ "$L: 경로 역치환" sed -i '' "s#$RUN/#$DEV/#g" "$P"; fi
  do_ "$L: launchctl bootout" sh -c 'launchctl bootout "gui/$(id -u)" "$1" 2>/dev/null || true' _ "$P"
  do_ "$L: launchctl bootstrap" launchctl bootstrap "gui/$(id -u)" "$P"
done

# ---------------------------------------------------------------- f. 심링크
step "f. 심링크"
SL="$HOME/.local/bin/smon"
case "$(readlink "$SL" 2>/dev/null || true)" in
  "$RUN/"*) do_ "ln -sfn $DEV/bin/smon $SL" ln -sfn "$DEV/bin/smon" "$SL" ;;
  *) say "  ~/.local/bin/smon: run 아님 — 건너뜀" ;;
esac
for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.hermes/skills" "$HOME/.agents/skills"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 3 -type l 2>/dev/null | while IFS= read -r l; do
    t=$(readlink "$l")
    case "$t" in "$RUN/"*) ;; *) continue ;; esac
    do_ "$l -> $DEV/${t#"$RUN/"}" ln -sfn "$DEV/${t#"$RUN/"}" "$l"
  done
done

# ---------------------------------------------------------------- DB
step "DB $NEWDB -> $OLDDB"
if [ ! -f "$NEWDB" ]; then say "  새 DB 없음 — 건너뜀"
elif [ -f "$OLDDB" ]; then die "$OLDDB 가 이미 있음 — 수동 확인 필요"
elif [ "$APPLY" = 1 ]; then
  # migrate 와 대칭: 스냅샷을 OLD 에 놓고 → NEW 를 치워 쓰기 대상을 되돌린 뒤 → NEW(치운 파일)의 늦은 쓰기를 병합.
  # paths.sh 는 NEW 파일이 있는 동안 NEW 를 고르므로, 전환 시점은 NEW 를 rename 하는 순간이다.
  WD="$DATA/rollback-$TS"; mkdir -p "$WD"
  trap 'dbm_resume_launchd' EXIT
  dbm_pause_launchd $PLISTS
  dbm_check_tables "$NEWDB" || die "스키마에 병합 규칙 없는 테이블 — 중단"
  dbm_snapshot "$NEWDB" "$OLDDB.tmp" || die ".backup/integrity 실패"
  cp -p "$OLDDB.tmp" "$WD/base.db"
  mv "$OLDDB.tmp" "$OLDDB"
  $SQ -cmd '.timeout 5000' "$NEWDB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
  PARKED="$NEWDB.rolledback-$TS"
  for s in "" -wal -shm; do [ -e "$NEWDB$s" ] && mv "$NEWDB$s" "$PARKED$s"; done
  say "  - 스냅샷 → $OLDDB, 새 위치 파일 → $PARKED (쓰기 대상 되돌림)"
  # rename 뒤에도 열린 핸들로 PARKED 에 쓰는 훅이 있을 수 있다 → 조용해질 때까지 병합
  dbm_drain "$PARKED" "$OLDDB" "$WD/base.db" "$WD" || die "치운 파일이 계속 바뀜 — 조용할 때 다시 확인 ($PARKED vs $OLDDB)"
  [ "$($SQ "$OLDDB" 'PRAGMA integrity_check;')" = ok ] || die "병합 후 integrity_check 실패"
  say "  - 복원 ok. 행수: $(tables_counts "$OLDDB")"
else
  say "  [dry] launchd 일시정지 → NEW 스냅샷을 OLD 로 → NEW{,-wal,-shm} → .rolledback-$TS (쓰기 대상 되돌림)"
  say "  [dry] 배수: 치운 파일이 조용해질 때까지 변경분을 OLD 로 병합 → launchd 재개"
fi
echo
say "끝. 실행 체크아웃 $RUN 은 남겨 둔다(필요 없으면 직접 삭제)."
