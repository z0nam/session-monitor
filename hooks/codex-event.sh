#!/bin/bash
# Codex hooks.json용 인자 없는 래퍼 (command에 인자를 못 넘기는 환경 대비)
exec "$HOME/dev/session-monitor/hooks/agent-event.sh" codex
