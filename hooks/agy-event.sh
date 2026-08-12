#!/bin/bash
# Antigravity CLI hooks.json용 인자 없는 래퍼.
# 주의: agy 1.1.1은 계정 게이트(enable_json_hooks OFF)로 훅을 로드만 하고 실행하지 않음 —
# 실제 수집은 worker의 agy_sync(transcript 폴링)가 담당. 게이트가 열리면 이 경로가 살아난다.
exec "$HOME/dev/session-monitor/hooks/agent-event.sh" antigravity
