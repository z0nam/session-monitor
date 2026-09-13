# session-monitor

이 머신에서 돌아가는 **AI 코딩 에이전트 세션 전부**(Claude Code · Codex · Antigravity CLI)의
상태를 **각 에이전트의 hooks → SQLite**로 기록하는 모니터. cmux/tmux/일반 터미널 어디서
떠도 동일하게 동작한다(특정 UI 비의존). 상태 판정은 훅 이벤트로만 — 결정론적, LLM 추측 없음.

## 멀티 에이전트 어댑터 구조

디스패처(`hooks/record-event.sh`)는 **표준 이벤트 5종**(SessionStart/UserPromptSubmit/
Stop/Notification/SessionEnd)만 안다. 에이전트별 어댑터가 네이티브 이벤트를 표준으로
번역(`hooks/agent-event.sh` + 인자 없는 래퍼 `<agent>-event.sh`). **새 에이전트 추가 =**
① agent-event.sh case에 매핑 추가 ② 래퍼 1개 ③ `adapters/<agent>-hooks.json` 작성·심링크
④ `AGENT_BINS`(record-event.sh, bin/smon 상단)에 실행파일 basename 추가.

| 표준 이벤트 | Claude Code | Codex | Antigravity(agy) |
|---|---|---|---|
| SessionStart | SessionStart | SessionStart | (없음 — 첫 이벤트가 세션 생성) |
| UserPromptSubmit | UserPromptSubmit | UserPromptSubmit | PreInvocation |
| Stop | Stop | Stop | PostInvocation |
| Notification | Notification | PermissionRequest | (없음) |
| SessionEnd | SessionEnd | (없음 — pid reap이 커버) | Stop |

어댑터 설치(SSOT는 repo, 설정 위치엔 심링크):
- Codex: `~/.codex/hooks.json` → `adapters/codex-hooks.json`.
  **주의**: Codex는 훅 신뢰(trust)를 요구 — TUI에서 `/hooks`로 1회 승인해야 발화
  (해시 기반이라 훅 스크립트 수정 시 재승인).
- Antigravity: `~/.gemini/antigravity-cli/hooks.json` → `adapters/antigravity-hooks.json`.
  **그러나 agy 1.1.1은 계정 게이트(`enable_json_hooks` OFF)로 훅을 로드만 하고 실행하지
  않는다** (codevibe 플러그인도 같은 이유로 transcript 감시로 우회 중). 그래서 agy 수집은
  워커의 `agy_sync()`가 담당: `~/.gemini/antigravity-cli/brain/<uuid>/…/transcript.jsonl`
  폴링 — mtime 3분 내 RUNNING, 이후 WAITING_INPUT, 24h 경과·agy 프로세스 전멸 시 ENDED
  (**agy만 시간 휴리스틱** — pid 연결 불가). 첫 USER_REQUEST 한 줄을 summary로,
  file:// URI에서 프로젝트 경로를 best-effort 추정. 게이트가 열리면 훅 경로가 대체한다.

## 구성

```
schema.sql              # DB 스키마 (sessions, events; WAL)
hooks/record-event.sh   # 단일 훅 디스패처 — 이벤트명을 $1로 받음
bin/smon                # 조회 CLI (~/.local/bin/smon 심링크)
sessions.db             # 데이터 (gitignore)
```

훅은 `~/.claude/settings.json`(user level)에 이벤트별로 등록되어 있다.
새로 뜨는 세션부터 적용 (이미 떠 있는 세션엔 소급 안 됨).

아침 리포트(매일 07:50, Slack Canvas + DM)는 `report/` — 설치는 **[report/README.md](report/README.md)**,
등록은 `./install.sh --with-report`.

## 훅 ↔ 상태 매핑

| Hook 이벤트 | state 전이 | 비고 |
|---|---|---|
| SessionStart | RUNNING | upsert; started_at, git_branch, source(터미널 추정), pid 기록 |
| UserPromptSubmit | RUNNING | |
| Stop | WAITING_INPUT | 턴 종료 = 입력 대기 |
| Notification | NEEDS_ATTENTION | 권한 요청·유휴 등; `notification_type` 보존 |
| SessionEnd | ENDED | ended_at 기록 |

모든 이벤트는 `events` 테이블에도 append (payload_json, `processed=0`).

**pid와 생존 판정(reap)**: 모든 훅 이벤트에서 조상 프로세스 중 실행파일 basename이
`claude`인 PID를 찾아 기록한다 (SessionStart는 덮어쓰기 — resume 대응, 그 외는
비어 있을 때만 백필). `smon` 보드는 그리기 전에 pid가 죽은 세션을 ENDED로 강등한다
(`Reaped` 이벤트 남김). **시간 기준 아님** — 프로세스가 살아있는 한 몇 날이 지나도
보드에 남는다 (밀린 세션 ≠ 죽은 세션). state 뒤 `?`는 pid 미확인(생존 판정 불가).

**프라이버시**: 훅 페이로드 중 대화 내용 필드(`prompt`, `last_assistant_message`)는
저장 전에 제거한다. transcript는 **경로만** 저장 (내용은 DB에 흐르지 않음).

## smon

```
smon                  # 활성 보드 (ENDED 숨김; NEEDS_ATTENTION 최상단)
smon all              # 오늘 활동 전체 (ENDED 포함)
smon tail <sid앞자리>  # 해당 세션 이벤트 이력
smon prune            # 7일 지난 ENDED 세션+events 정리
smon backfill         # pid 없는 옛 세션 ↔ 실행 중 claude 프로세스 매칭 (이행용)
```

`backfill` 매칭 순서: ① `ps eww`로 프로세스 env/인자에서 session_id 정확 매칭
② 실패 시 세션 cwd에 주인 없는 claude가 있으면 보류(다음 훅 이벤트가 자동 백필)
③ 둘 다 아니면 죽은 세션으로 ENDED. cwd 비교는 NFC 정규화(iconv UTF-8-MAC) 필수 —
lsof의 한글 경로는 NFD라 그냥 비교하면 산 세션을 죽은 것으로 오판한다.
`ps eww`는 pid를 하나씩만 (여러 개 넘기면 전체 덤프 → env 물려받은 자식 오매칭).

## 설계 노트

- 훅 스크립트는 sqlite3 쓰기(단일 트랜잭션, busy_timeout=200ms)만 하고 종료.
  실측: 유휴 시 ~36ms, 활성 세션 25개 부하에서 ~120-190ms (pid 트리 탐색분은 ~25ms).
  어떤 실패든 exit 0 — 세션을 방해하지 않는다.
- git branch·source 추정은 SessionStart에서만 (매 이벤트 실행하면 예산 초과).
- 의존성: bash + /usr/bin/sqlite3 + /usr/bin/jq. 데몬 없음.

## Phase 2 — LLM 요약 워커 (Ollama)

`worker/summarize.py`(stdlib만)가 `processed=0` 이벤트가 있는 세션의 transcript
꼬리(≤6KB)를 읽어 Ollama(`localhost:11434`)로 한 줄 요약 → `sessions.summary`
갱신 후 `processed=1`. ENDED 세션은 요약 없이 마킹만. 훅 경로는 건드리지 않는다.

- 실행: launchd(`com.namun.smon-worker`, 120초 간격 1패스), 수동은 `smon work`.
  등록: `cp worker/com.namun.smon-worker.plist ~/Library/LaunchAgents/ && launchctl load ...`
  로그: `~/Library/Logs/smon-worker.log`
- **모델 교체(탐색용)**: `smon model` 조회, `smon model <이름>` 교체 — config 테이블에
  저장되고 다음 패스부터 적용. 어떤 모델이 만든 요약인지 `sessions.summary_model`에 남음.
  후보: `qwen3:30b-a3b`(MoE, 기본), `glm-4.7-flash`, `qwen3:8b`, `exaone3.5:7.8b`.
- Ollama가 죽어 있으면 이벤트를 미처리로 남기고 종료 → 다음 패스에 재시도.
- **모델 저장소는 외장 Dev_1T** (`OLLAMA_MODELS=/Volumes/Dev_1T/ollama-models`) —
  내장 디스크 여유 부족(~31GB). 서비스는 brew 대신 `worker/com.namun.ollama.plist`
  (env 포함, `~/Library/LaunchAgents/`에 복사). **주의(TCC)**: launchd로 뜬 ollama가
  이동식 볼륨을 열 때 macOS 권한이 없으면 open()에서 무한 대기(리슨은 하는데 응답 없음).
  → 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근에
  `/opt/homebrew/opt/ollama/bin/ollama`(libexec 실제 바이너리) 추가 후 에이전트 재로드.
  볼륨 언마운트 상태로 부팅하면 모델이 안 보일 뿐 서비스는 무해.
- **프라이버시**: transcript 내용은 로컬 Ollama에만 흐른다 (DB에는 요약 한 줄만).
- **명시적 완료 사인**: `smon done`(완전 종결→초록) / `smon dir`(일단락→파랑) —
  인자 없으면 pid 조상으로 자기 세션 특정. LLM 분류보다 우선, 새 턴(RUNNING)이 해제.
  에이전트 자기신고 지침이 전역에 배선됨: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
  `~/.gemini/GEMINI.md` (agy의 GEMINI.md 로딩은 미검증 — 계층 로딩 문자열은 확인됨).
## Phase 3 — 방치 알림

워커가 매 패스 끝에 실행: `NEEDS_ATTENTION`이고 **마지막 알림 이후 새 이벤트가 있는
산 세션**(pid 생존 확인)만 골라 알림. 중복 방지는 `sessions.notified_at` +
앤티버스트(`notify_min_gap`, 기본 600초). 죽은 세션은 알리지 않는다.

- 방식은 config `notify_method`: **macos**(기본; osascript 배너, 세션당 1개·최대 5개)
  또는 **slack**(`slack_channel`/`slack_user_id` + `slack_env_file`의 SLACK_BOT_TOKEN으로
  chat.postMessage 묶음 1통).
- Slack DM 주의: 봇 앱의 App Home → Messages Tab이 꺼져 있으면 `messages_tab_disabled`.
  채널 ID를 `slack_channel`에 넣으면 채널로도 보냄.
- WAITING_INPUT 장기 방치 알림은 아직 없음 (확장 지점).

## 멀티 머신 (허브-스포크)

각 머신은 독립적으로 수집(훅→로컬 SQLite, 로컬 reap)하고, **허브가 Tailscale ssh로
스냅샷을 끌어와** 보드에 합친다 (MACHINE 열). 훅은 네트워크를 절대 타지 않는다.

- 스포크 설치: repo를 `~/dev/session-monitor`로 복사 후 `./install.sh`
  (스키마+smon+Claude 훅+codex/agy 어댑터 멱등 등록. codex는 머신마다 `/hooks` 승인 필요.)
- 허브: config `remote_hosts`('mac-mini mbp')를 두고 `smon pull`이 각 머신의
  `smon export`(JSON; export 전에 그 머신에서 reap)를 받아 `remote_sessions`를
  머신 단위로 교체. 자동화는 `worker/com.namun.smon-pull.plist`(120초).
  도달 실패 시 이전 스냅샷 유지 (머신 꺼져 있어도 마지막 상태는 보임).
- **원격 요약**: 허브 Ollama를 `tailscale serve --bg --tcp 11434 tcp://localhost:11434`로
  tailnet 전용 노출(LAN 비노출, Ollama는 localhost 바인딩 유지). 스포크 워커는 config
  `ollama_url`(`http://100.123.230.95:11434`)로 허브 모델을 호출해 자기 세션을 요약.
- **headless 스포크(mac-mini)**: 콘솔 로그인이 없으면 LaunchAgent가 안 돌아 **cron**으로
  워커 실행 (`*/2 * * * * python3 …/worker/summarize.py # smon-worker`). 잠들면 수집·pull이
  멈출 뿐 데이터는 안전 (허브는 마지막 스냅샷 유지).
- **Windows 스포크(winspoke/)**: bash 대신 `winspoke/record_event.py`(stdlib only;
  pid 추적은 ctypes Toolhelp) + `install.ps1`(스키마·Claude 훅·codex 훅 멱등 등록).
  설치: repo를 `%USERPROFILE%\dev\session-monitor`로 복사 → `install.ps1` 실행 →
  codex는 TUI `/hooks` 승인. 허브 config `remote_hosts_win`에 호스트 추가하면
  `smon pull`이 cmd/PowerShell 문법 폴백으로 export를 끌어온다.
- 한계(v1): 알림은 각 머신 로컬 화면만. Windows엔 워커 없음(요약·agy_sync 미지원).
  NATIVE_MAP은 agent-event.sh와 record_event.py 두 곳 — 수정 시 함께 (SSOT 후보:
  bash 구현을 Python으로 통일하는 것, 퍼블릭 릴리스 때).

- `sessions.cmux_ws` = cmux 워크스페이스 ID (훅이 env에서 기록; cmux 밖 세션은 NULL).
  cmux-admin의 "sid→워크스페이스 점프"(`smon go` 류)는 이 컬럼을 읽으면 된다.
- calendar-worklog 등 업무 이력 소비자는 `events`(session_id, event_type, created_at)와
  `sessions`(project_path, agent)를 **읽기 전용**으로 조인해 쓰면 된다. WAL이라 동시 읽기 안전.
