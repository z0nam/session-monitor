#!/bin/bash
# lib-dbmove.sh 검증 — 실제 DB 사본으로 리뷰가 지적한 경쟁 상황을 재현한다. (실 DB 는 읽기만)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../deploy/lib-dbmove.sh"
T=${1:?workdir}; LIVE=${2:?live db}
SQ=/usr/bin/sqlite3; DRAIN_GRACE=1; DRAIN_ROUNDS=5
rm -rf "$T"; mkdir -p "$T"
fail() { echo "FAIL: $*"; exit 1; }
cnt() { $SQ "$1" "$2"; }

dbm_snapshot "$LIVE" "$T/old.db"                   # 실 DB 사본 = 이전 전 '옛 DB'
dbm_check_tables "$T/old.db"
S1=$(cnt "$T/old.db" "SELECT session_id FROM sessions ORDER BY last_event_at DESC LIMIT 1")
S2=$(cnt "$T/old.db" "SELECT session_id FROM sessions ORDER BY last_event_at DESC LIMIT 1 OFFSET 1")
S3=$(cnt "$T/old.db" "SELECT session_id FROM sessions WHERE state='ENDED' ORDER BY last_event_at LIMIT 1")
EV0=$(cnt "$T/old.db" "SELECT count(*) FROM events")

# 1) 스냅샷 → 새 위치 + 기준본 (마이그레이션 1단계)
dbm_snapshot "$T/old.db" "$T/new.db"; cp "$T/new.db" "$T/base.db"

# 2) 리뷰가 지적한 늦은 쓰기들 — 스냅샷 이후 옛 DB 에 들어온 것
$SQ "$T/old.db" "
 UPDATE sessions SET summary='LATE-SUMMARY', phase='done' WHERE session_id='$S1';      -- 행수 안 바뀌는 UPDATE
 INSERT INTO events(session_id,event_type,payload_json,created_at) VALUES('$S1','Stop','{}',9999999999); -- 새 이벤트
 INSERT INTO sessions(session_id,agent,state,last_event_at) VALUES('late-new','claude','RUNNING',9999999999); -- 새 세션
 UPDATE sessions SET last_event_at=1, summary='OLD-SIDE' WHERE session_id='$S2';        -- 충돌 대상(옛쪽이 더 과거)
 INSERT OR REPLACE INTO config VALUES('model','late-model');"
# 같은 시간에 새 위치에도 쓰기(전환 후 훅) — 서로 덮어쓰면 안 됨
$SQ "$T/new.db" "
 UPDATE sessions SET summary='NEW-SIDE', last_event_at=9999999999 WHERE session_id='$S2';
 INSERT INTO events(session_id,event_type,payload_json,created_at) VALUES('$S2','UserPromptSubmit','{}',9999999999);"

# 3) 배수 1회차가 병합해야 함, 2회차에 조용함
( sleep 0; ) ; dbm_drain "$T/old.db" "$T/new.db" "$T/base.db" "$T" || fail "drain 실패"

[ "$(cnt "$T/new.db" "SELECT summary||'|'||phase FROM sessions WHERE session_id='$S1'")" = "LATE-SUMMARY|done" ] || fail "UPDATE 유실"
[ "$(cnt "$T/new.db" "SELECT count(*) FROM sessions WHERE session_id='late-new'")" = 1 ] || fail "늦은 새 세션 유실"
[ "$(cnt "$T/new.db" "SELECT summary FROM sessions WHERE session_id='$S2'")" = "NEW-SIDE" ] || fail "충돌 시 최신(새쪽) 유지 실패"
[ "$(cnt "$T/new.db" "SELECT value FROM config WHERE key='model'")" = "late-model" ] || fail "config 유실"
[ "$(cnt "$T/new.db" "SELECT count(*) FROM events")" = $((EV0+2)) ] || fail "events 병합 개수 (기대 $((EV0+2)))"
[ "$(cnt "$T/new.db" "SELECT count(*) FROM events WHERE created_at=9999999999")" = 2 ] || fail "양쪽 이벤트 둘 다 보존 실패"
echo "ok 1: UPDATE·새 세션·새 이벤트·config 병합, 충돌은 최신 유지, 양쪽 이벤트 보존"

# 4) 옛 쪽 prune(삭제)은 새쪽이 안 건드렸을 때만 반영
cp "$T/new.db" "$T/base.db"; cp "$T/new.db" "$T/old.db"
$SQ "$T/old.db" "DELETE FROM events WHERE session_id='$S3'; DELETE FROM sessions WHERE session_id='$S3';"
dbm_drain "$T/old.db" "$T/new.db" "$T/base.db" "$T" || fail "drain2 실패"
[ "$(cnt "$T/new.db" "SELECT count(*) FROM sessions WHERE session_id='$S3'")" = 0 ] || fail "prune 미반영"
echo "ok 2: 옛쪽 prune 반영"

# 5) 조용하지 않으면 실패해야 함 (계속 쓰는 writer)
cp "$T/new.db" "$T/base.db"; cp "$T/new.db" "$T/old.db"
( for i in $(seq 1 40); do $SQ "$T/old.db" "INSERT INTO events(session_id,event_type,created_at) VALUES('x','Stop',$i)"; sleep 0.25; done ) &
W=$!
DRAIN_ROUNDS=3
if dbm_drain "$T/old.db" "$T/new.db" "$T/base.db" "$T"; then kill $W 2>/dev/null; fail "계속 쓰는데 조용하다고 판정"; fi
wait $W 2>/dev/null || true
echo "ok 3: 계속 쓰이면 중단(옛 파일 보관 안 함)"
[ "$($SQ "$T/new.db" 'PRAGMA integrity_check')" = ok ] || fail integrity
echo "ALL PASS"
