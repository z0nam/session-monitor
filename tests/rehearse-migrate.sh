#!/bin/bash
# 가짜 HOME 에서 migrate-to-run.sh --apply → rollback-run.sh --apply 를 끝까지 돌린다.
# 그동안 "구 경로 훅"이 옛 DB 에 계속 쓰는 상황을 흉내 낸다 (리뷰 지적 재현). 실 HOME 은 건드리지 않는다.
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)      # 이 PR 의 체크아웃
LIVE=${1:?live db (읽기만)}
F=${2:?fake home}
rm -rf "$F"; mkdir -p "$F/dev" "$F/.local/bin" "$F/.claude" "$F/Library/LaunchAgents" "$F/bin"
export HOME=$F
# 원격(origin) 흉내: 이 체크아웃을 bare 로
git clone -q --bare "$SRC" "$F/origin.git"
git clone -q "$F/origin.git" "$F/dev/session-monitor"
git -C "$F/dev/session-monitor" checkout -q -B main HEAD
git -C "$F/origin.git" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
git -C "$F/dev/session-monitor" push -q origin main 2>/dev/null || true
/usr/bin/sqlite3 -cmd '.timeout 3000' "$LIVE" ".backup '$F/dev/session-monitor/sessions.db'"
D=$F/dev/session-monitor
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"%s/hooks/record-event.sh Stop"}]}]}}' "$D" > "$F/.claude/settings.json"
ln -s "$D/bin/smon" "$F/.local/bin/smon"
# launchctl/hermes 는 가짜로 (실 launchd 보호)
printf '#!/bin/sh\necho "launchctl $*" >> %s/calls.log\ncase "$1" in print) exit 1;; esac\nexit 0\n' "$F" > "$F/bin/launchctl"
printf '#!/bin/sh\necho "hermes $*" >> %s/calls.log\n' "$F" > "$F/bin/hermes"
chmod +x "$F/bin/"*
export PATH="$F/bin:$PATH"
BEFORE=$(/usr/bin/sqlite3 "$D/sessions.db" "SELECT count(*) FROM events")

# 구 경로 훅 흉내: 마이그레이션 내내 이벤트를 쏜다. 경로는 매번 paths.sh 로 해석(실제 훅과 동일)
( i=0; while [ ! -f "$F/stop-writer" ]; do i=$((i+1))
    printf '{"session_id":"race-%s","cwd":"/tmp"}' "$((i % 3))" | "$D/hooks/record-event.sh" Stop claude >/dev/null 2>&1 || true
    sleep 0.3; done; echo "$i" > "$F/writer-count" ) &
W=$!
trap 'touch "$F/stop-writer"' EXIT
sleep 1
DRAIN_GRACE=2 bash "$D/deploy/migrate-to-run.sh" --apply --force 2>&1 | sed -n '/== c\./,/== d\./p' | sed '$d'
touch "$F/stop-writer"; wait $W
N=$(cat "$F/writer-count")
NEWDB=$F/.local/share/smon/sessions.db
# 마이그레이션 동안·이후 쓴 이벤트 전부 새 DB 에 있어야 한다 (어느 쪽 파일에 쓰였든)
GOT=$(/usr/bin/sqlite3 "$NEWDB" "SELECT count(*) FROM events WHERE session_id LIKE 'race-%'")
echo "writer 이벤트 $N 건 / 새 DB 에 있는 것 $GOT 건 (원래 $BEFORE + 합성 점검 0)"
[ "$GOT" = "$N" ] || { echo "FAIL: 이벤트 유실/중복 ($N vs $GOT)"; exit 1; }
[ ! -e "$D/sessions.db" ] || { echo "FAIL: 옛 경로에 DB 가 다시 생김"; exit 1; }
ls "$D"/sessions.db.migrated-* >/dev/null || { echo "FAIL: 옛 DB 보관본 없음"; exit 1; }
echo "ok migrate: 경쟁 쓰기 $N 건 전부 보존, 옛 DB 보관"

BK=$(ls -1d "$F/.local/share/smon"/migrate-* | tail -1)
DRAIN_GRACE=2 bash "$F/dev/session-monitor-run/deploy/rollback-run.sh" --apply "$BK" 2>&1 | sed -n '/== DB/,$p' | head -8
[ -f "$D/sessions.db" ] && [ ! -f "$NEWDB" ] || { echo "FAIL: rollback 후 DB 위치"; exit 1; }
R=$(/usr/bin/sqlite3 "$D/sessions.db" "SELECT count(*) FROM events WHERE session_id LIKE 'race-%'")
[ "$R" = "$N" ] || { echo "FAIL: rollback 후 이벤트 $R vs $N"; exit 1; }
grep -q "$D/hooks/record-event.sh" "$F/.claude/settings.json" || { echo "FAIL: 훅 경로 미복원"; exit 1; }
[ "$(readlink "$F/.local/bin/smon")" = "$D/bin/smon" ] || { echo "FAIL: smon 링크 미복원"; exit 1; }
echo "ok rollback: DB·훅·링크 원위치, 이벤트 $R 건 유지"
echo "ALL PASS"
