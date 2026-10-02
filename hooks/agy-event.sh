#!/bin/bash
# Antigravity CLI hooks.json용 인자 없는 래퍼.
# 주의: agy 1.1.1은 계정 게이트(enable_json_hooks OFF)로 훅을 로드만 하고 실행하지 않음 —
# 실제 수집은 worker의 agy_sync(transcript 폴링)가 담당. 게이트가 열리면 이 경로가 살아난다.
# 경로 해석(SMON_HOME·SMON_DB) — lib/paths.sh. 심링크로 불릴 때만 readlink 1회(평소 0 fork).
_s=${BASH_SOURCE[0]}; [ -L "$_s" ] && _s=$(readlink -f "$_s" 2>/dev/null || readlink "$_s")
case $_s in */*) ;; *) _s=./$_s ;; esac
. "${_s%/*}/../lib/paths.sh"
exec "$SMON_HOME/hooks/agent-event.sh" antigravity
