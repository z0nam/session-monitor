---
name: smon
description: >
  이 맥에서 돌아가는 모든 AI 코딩 에이전트 세션(Claude Code·Codex·Antigravity)의
  상태 보드 CLI. 사용자가 "나 뭐 하고 있었지 / 뭐 하다 말았지", "떠 있는 세션 뭐 있지",
  "방치된/입력 기다리는 세션", "세션 현황·요약" 류를 물으면 셸 명령 `smon`(PATH)을
  실행해 보드를 읽고 답한다. 각 세션에 로컬 LLM 한 줄 요약이 붙어 있다.
---

# smon — AI 에이전트 세션 모니터 (Claude Code · Codex · Antigravity)

어느 폴더·어느 에이전트에서든 PATH의 셸 명령 `smon`으로 실행한다.
데이터는 훅이 SQLite(`~/dev/session-monitor/sessions.db`)에 결정론적으로 쌓은 것
(상태 판정에 LLM 추측 없음). 요약(SUMMARY)만 로컬 Ollama가 2분 주기로 생성.

## 명령

```
smon                  # 활성 보드 (기본; 정렬 빨강>파랑>초록>작업중, PH열 B/G)
smon all              # 오늘 활동 전체 (ENDED 포함)
smon find <검색어>     # 전 머신 세션 검색 (요약 한 줄·프로젝트·세션ID만)
smon grep <검색어> [-n N]  # 세션 전사(대화 원문) 전문검색 — 로컬 전사만. 스니펫·HITS 포함
smon report            # 아침 리포트 재료: 완료(done)·빈요약 제외, 프로젝트별 그룹 (launchd 07:50 자동 서술→Slack DM)
smon tail <sid앞자리>  # 해당 세션 이벤트 이력
smon done [sid]       # 명시적 완료 사인 (→초록). 인자 없으면 자기 세션 자동 특정
smon dir [sid]        # 일단락·지침 대기 사인 (→파랑)
smon ack <sid앞자리>   # 초록 확인하고 끄기
smon model [이름]      # 요약 모델 조회/교체 (ollama 모델명)
smon work             # 요약 워커 즉시 1패스
smon repaint          # cmux 재시작/업그레이드로 탭 색 날아갔을 때 전량 재적용
smon backfill         # pid 미확인('?') 세션 ↔ 프로세스 재대조
smon prune            # 7일 지난 ENDED 정리
```

## 보드 읽는 법 (사용자에게 답할 때)

- **NEEDS_ATTENTION** = 권한 승인 등 사용자 입력을 기다리다 방치된 세션.
  "뭐 하다 말았지"의 답은 대부분 여기 — SUMMARY와 함께 짚어줄 것.
- **"그거 어느 세션이었지"** 류 질문: 먼저 `smon find`(요약 한 줄만 인덱싱)로 시도하고,
  안 잡히면 `smon grep <키워드>`로 **전사 원문**을 뒤진다. 논의됐지만 요약에 안 남은
  주제(파일명·경로·고유명사 등)는 grep이라야 걸린다. grep은 이 머신 로컬 전사만 본다.
- RUNNING = 턴 진행 중, WAITING_INPUT = 턴 끝나고 대기, ENDED = 종료.
- AGENT 열 = 어느 에이전트의 세션인지 (claude / codex / antigravity).
- LAST = 마지막 이벤트 경과시간. 오래됐어도 프로세스가 살아 있으면 죽은 게 아니라
  "밀린 세션"이다 (죽은 세션은 보드가 자동으로 걷어냄).
- state 뒤 `?` = 소유 프로세스 미확정(생존 판정 불가). 거슬리면 `smon backfill`.
- SUMMARY는 2분 주기라 방금 활동은 비어 있거나 한 박자 늦을 수 있음.

## 주의

- 읽기는 자유. `prune`/`model` 등 상태를 바꾸는 명령은 사용자가 원할 때만.
- SUMMARY 생성엔 로컬 Ollama(launchd `com.namun.ollama`, 모델은 외장 Dev_1T)가
  필요 — 요약이 계속 빈다면 `curl -s localhost:11434/api/version`으로 서버 확인.
