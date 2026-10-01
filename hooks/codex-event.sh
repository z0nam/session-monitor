#!/bin/bash
# Codex hooks.json용 인자 없는 래퍼 (command에 인자를 못 넘기는 환경 대비)
# 경로 해석(SMON_HOME·SMON_DB) — lib/paths.sh. 심링크로 불릴 때만 readlink 1회(평소 0 fork).
_s=${BASH_SOURCE[0]}; [ -L "$_s" ] && _s=$(readlink -f "$_s" 2>/dev/null || readlink "$_s")
case $_s in */*) ;; *) _s=./$_s ;; esac
. "${_s%/*}/../lib/paths.sh"
exec "$SMON_HOME/hooks/agent-event.sh" codex
