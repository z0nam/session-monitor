# shellcheck shell=bash
# DB 이전 공용 — migrate-to-run.sh / rollback-run.sh 가 source 한다. (bash 3.2 호환)
#
# 왜 "스냅샷 + 행수 비교"가 아니라 "전환 후 배수(drain)·병합"인가 (PR #2 리뷰 반영):
#  - 에이전트 훅은 멈출 수 없다(열린 세션 수십 개가 매 턴 쓴다). launchd 워커는 멈출 수 있지만
#    훅·`smon done` 같은 쓰기는 이전 중에도 계속 들어온다.
#  - 행수는 UPDATE(요약·상태·phase)를 못 잡고, 스냅샷 이후·경로 전환 전 사이의 쓰기도 놓친다.
# 그래서:
#  1) .backup 으로 일관 스냅샷 → 새 위치(DST)에 놓아 **쓰기 대상을 전환**하고, 같은 스냅샷을 BASE 로 보관.
#  2) 전환 직전에 경로를 해석한 진행 중 훅은 옛 파일(SRC)에 쓴다 → SRC 를 다시 스냅샷(CUR)해
#     BASE 대비 바뀐 행만 DST 로 병합(reconcile). CUR 가 BASE 와 같아질 때까지(=SRC 가 조용해질 때까지) 반복.
#  3) 조용해진 뒤에야 SRC 를 보관용 이름으로 바꾼다(삭제 안 함).
# 병합 규칙(테이블별 PK 기준, 알려진 4개 테이블만 — 모르는 테이블이 있으면 중단):
#  - CUR 에서 BASE 대비 바뀐/새 행: DST 행이 없거나 BASE 와 같으면(=전환 후 안 건드림) CUR 로 덮는다.
#    DST 도 바뀌었으면 충돌 → sessions 는 last_event_at 이 큰 쪽, 나머지는 DST 유지(건수 보고).
#  - BASE 에 있었는데 CUR 에서 사라진 행(prune 등): DST 행이 BASE 와 같을 때만 지운다.
#  - events 는 id 가 자동증가라 BASE 최대 id 이하는 PK 처리, 초과분은 DST 에 새 id 로 덧붙인다.

SQ=${SQ:-/usr/bin/sqlite3}
DRAIN_GRACE=${DRAIN_GRACE:-12}   # 초. 훅 timeout(10s)보다 길게 — 진행 중 훅이 끝날 시간
DRAIN_ROUNDS=${DRAIN_ROUNDS:-8}

dbm_snapshot() {  # <src> <out> : 온라인 일관 스냅샷 + integrity
  rm -f "$2"
  "$SQ" -cmd '.timeout 5000' "$1" ".backup '$2'" || return 1
  [ "$("$SQ" "$2" 'PRAGMA integrity_check;')" = ok ] || { echo "integrity_check 실패: $2" >&2; return 1; }
}

dbm_digest() {  # 사본 전용(쓰기 열기 OK). -readonly 는 WAL 파일에 -shm 이 없으면 실패하면서 .dump 를 부분 출력한다(실측)
  local d
  d=$("$SQ" -bail "$1" .dump) || { echo "digest 실패: $1" >&2; return 1; }
  printf '%s' "$d" | /usr/bin/shasum | cut -d' ' -f1
}

dbm_check_tables() {  # 알려진 테이블만 있는지 — 스키마가 바뀌면 병합 규칙도 다시 봐야 한다
  local t
  for t in $("$SQ" -cmd ".timeout 2000" "file:$1?mode=ro" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"); do
    case "$t" in sessions|events|config|remote_sessions) ;; *) echo "알 수 없는 테이블: $t (병합 규칙 미정의)" >&2; return 1 ;; esac
  done
}

dbm_reconcile() {  # <dst> <cur> <base> : CUR 의 BASE 대비 변경분을 DST 로. stdout 에 요약 1줄
  local dst=$1 cur=$2 base=$3 sql t pk on
  sql="PRAGMA foreign_keys=OFF; ATTACH '$cur' AS cur; ATTACH '$base' AS base; BEGIN IMMEDIATE;
CREATE TEMP TABLE stat(k TEXT, n INTEGER);"
  for t in sessions config remote_sessions; do
    case $t in
      sessions)        pk="session_id"; on="m.session_id=c.session_id" ;;
      config)          pk="key";        on="m.key=c.key" ;;
      remote_sessions) pk="machine, session_id"; on="m.machine=c.machine AND m.session_id=c.session_id" ;;
    esac
    sql="$sql
CREATE TEMP TABLE chg_$t AS SELECT * FROM cur.$t EXCEPT SELECT * FROM base.$t;
CREATE TEMP TABLE gone_$t AS SELECT $pk FROM base.$t EXCEPT SELECT $pk FROM cur.$t;
CREATE TEMP TABLE ok_$t AS SELECT c.* FROM chg_$t c WHERE
  NOT EXISTS (SELECT 1 FROM main.$t m WHERE $on)
  OR EXISTS (SELECT * FROM main.$t m WHERE $on INTERSECT SELECT * FROM base.$t m WHERE $on);
INSERT INTO stat SELECT '$t.conflict', (SELECT count(*) FROM chg_$t) - (SELECT count(*) FROM ok_$t);"
    if [ $t = sessions ]; then  # 충돌: 마지막 이벤트가 더 최근인 쪽
      sql="$sql
INSERT INTO ok_$t SELECT c.* FROM chg_$t c JOIN main.$t m ON $on
  WHERE c.session_id NOT IN (SELECT session_id FROM ok_$t) AND COALESCE(c.last_event_at,0) > COALESCE(m.last_event_at,0);"
    fi
    sql="$sql
INSERT INTO stat SELECT '$t.upsert', count(*) FROM ok_$t;
INSERT OR REPLACE INTO main.$t SELECT * FROM ok_$t;
INSERT INTO stat SELECT '$t.delete', count(*) FROM gone_$t c WHERE
  EXISTS (SELECT * FROM main.$t m WHERE $on INTERSECT SELECT * FROM base.$t m WHERE $on);
DELETE FROM main.$t WHERE ($pk) IN (SELECT $pk FROM gone_$t c WHERE
  EXISTS (SELECT * FROM main.$t m WHERE $on INTERSECT SELECT * FROM base.$t m WHERE $on));"
  done
  # events: id <= base 최대치는 PK 처리, 초과분은 새 id 로 덧붙임
  sql="$sql
CREATE TEMP TABLE bmax AS SELECT COALESCE(max(id),0) AS v FROM base.events;
CREATE TEMP TABLE chg_ev AS SELECT * FROM cur.events WHERE id <= (SELECT v FROM bmax) EXCEPT SELECT * FROM base.events;
INSERT INTO stat SELECT 'events.update', count(*) FROM chg_ev c WHERE
  EXISTS (SELECT * FROM main.events m WHERE m.id=c.id INTERSECT SELECT * FROM base.events m WHERE m.id=c.id);
INSERT OR REPLACE INTO main.events SELECT c.* FROM chg_ev c WHERE
  EXISTS (SELECT * FROM main.events m WHERE m.id=c.id INTERSECT SELECT * FROM base.events m WHERE m.id=c.id);
CREATE TEMP TABLE gone_ev AS SELECT id FROM base.events EXCEPT SELECT id FROM cur.events;
INSERT INTO stat SELECT 'events.delete', count(*) FROM gone_ev c WHERE
  EXISTS (SELECT * FROM main.events m WHERE m.id=c.id INTERSECT SELECT * FROM base.events m WHERE m.id=c.id);
DELETE FROM main.events WHERE id IN (SELECT id FROM gone_ev c WHERE
  EXISTS (SELECT * FROM main.events m WHERE m.id=c.id INTERSECT SELECT * FROM base.events m WHERE m.id=c.id));
INSERT INTO stat SELECT 'events.append', count(*) FROM cur.events WHERE id > (SELECT v FROM bmax);
INSERT INTO main.events (session_id, event_type, payload_json, created_at, processed)
  SELECT session_id, event_type, payload_json, created_at, processed FROM cur.events
  WHERE id > (SELECT v FROM bmax) ORDER BY id;
COMMIT;
SELECT group_concat(k || '=' || n, ' ') FROM stat WHERE n > 0;"
  "$SQ" -cmd '.timeout 10000' "$dst" "$sql"
}

# dbm_drain <src_now> <dst> <base> <workdir> : src 가 base 와 같아질 때까지 병합 반복. 0=조용해짐
dbm_drain() {
  local src=$1 dst=$2 base=$3 wd=$4 r cur sum dc db
  for r in $(seq 1 "$DRAIN_ROUNDS"); do
    sleep "$DRAIN_GRACE"
    cur="$wd/drain-cur-$r.db"
    dbm_snapshot "$src" "$cur" || return 1
    dc=$(dbm_digest "$cur") && db=$(dbm_digest "$base") || return 1
    if [ "$dc" = "$db" ]; then
      echo "    배수 ${r}회차: 옛 DB 변화 없음 — 조용해짐"; rm -f "$cur"; return 0
    fi
    sum=$(dbm_reconcile "$dst" "$cur" "$base") || return 1
    echo "    배수 ${r}회차: 옛 DB 에 늦은 쓰기 → 병합 (${sum:-변경 없음})"
    rm -f "$base"; mv "$cur" "$base"
  done
  return 1
}

# launchd 쓰기 작업 일시정지/복귀 — 멈출 수 있는 쓰기는 멈춘다 (훅은 못 멈추므로 drain 이 담당)
DBM_PAUSED=""
dbm_pause_launchd() {  # <label...>
  local L P
  for L in "$@"; do
    P="$HOME/Library/LaunchAgents/$L.plist"
    [ -f "$P" ] || continue
    launchctl print "gui/$(id -u)/$L" >/dev/null 2>&1 || continue
    launchctl bootout "gui/$(id -u)/$L" 2>/dev/null || true
    DBM_PAUSED="$DBM_PAUSED $L"; echo "    일시정지: $L"
  done
}
dbm_resume_launchd() {  # 이미 다시 올라와 있으면 건너뜀 (e 단계가 경로를 바꿔 bootstrap 했을 수 있음)
  local L P
  for L in $DBM_PAUSED; do
    P="$HOME/Library/LaunchAgents/$L.plist"
    launchctl print "gui/$(id -u)/$L" >/dev/null 2>&1 && continue
    launchctl bootstrap "gui/$(id -u)" "$P" 2>/dev/null && echo "    재개: $L" || echo "    ! 재개 실패: $L (수동: launchctl bootstrap gui/$(id -u) $P)" >&2
  done
  DBM_PAUSED=""
}
