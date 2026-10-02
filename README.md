# session-monitor

이 머신에서 돌아가는 **AI 코딩 에이전트 세션 전부**(Claude Code · Codex · Antigravity CLI · Hermes Agent)의
상태를 **각 에이전트의 hooks → SQLite**로 기록하는 모니터. cmux/tmux/일반 터미널 어디서
떠도 동일하게 동작한다(특정 UI 비의존). 상태 판정은 훅 이벤트로만 — 결정론적, LLM 추측 없음.

## 멀티 에이전트 어댑터 구조

디스패처(`hooks/record-event.sh`)는 **표준 이벤트 5종**(SessionStart/UserPromptSubmit/
Stop/Notification/SessionEnd)만 안다. 에이전트별 어댑터가 네이티브 이벤트를 표준으로
번역(`hooks/agent-event.sh` + 인자 없는 래퍼 `<agent>-event.sh`). **새 에이전트 추가 =**
① agent-event.sh case에 매핑 추가 ② 래퍼 1개 ③ `adapters/<agent>-hooks.json` 작성·심링크
④ `AGENT_BINS`(record-event.sh, bin/smon 상단)에 실행파일 basename 추가.

| 표준 이벤트 | Claude Code | Codex | Antigravity(agy) | Hermes |
|---|---|---|---|---|
| SessionStart | SessionStart | SessionStart | (없음 — 첫 이벤트가 세션 생성) | on_session_start |
| UserPromptSubmit | UserPromptSubmit | UserPromptSubmit | PreInvocation | pre_llm_call, post_approval_response |
| Stop | Stop | Stop | PostInvocation | on_session_end (**턴마다** 발화 — 이름과 달리) |
| Notification | Notification | PermissionRequest | (없음) | pre_approval_request (smart 자동판정 제외) |
| SessionEnd | SessionEnd | (없음 — pid reap이 커버) | Stop | on_session_finalize |

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
- Hermes: `~/.hermes/config.yaml` 의 `hooks:` 섹션 (셸 훅). YAML 이라 심링크 대신 install.sh 가
  `adapters/hermes-hooks.yaml`(한 줄 YAML flow)을 `hermes config set --force hooks` 로 적용하고,
  첫 실행 승인 프롬프트를 피하려 `~/.hermes/shell-hooks-allowlist.json` 에 consent 를 기록한다.
  **주의: hooks 키를 통째로 교체** — 다른 Hermes 셸 훅을 쓰게 되면 병합 로직으로 바꿀 것.
  전처리 래퍼 `hooks/hermes-event.sh` 가 보정하는 것 (실측 2026-09-30, Hermes 소스 확인):
  ① pid — 본체가 `~/.hermes/tools/python-*/bin/python3` 라 basename 매칭 불가 → 훅 PPID 를
  `SMON_AGENT_PID` 로 직접 전달, `smon` reap 은 경로(`*/.hermes/*python3*`)로 생존 판정.
  ② `delegate_task` 하위 에이전트도 같은 프로세스에서 훅을 쏜다 → `extra.platform=subagent`·
  `extra.parent_session_id`·state.db 계보로 걸러냄 (압축 회전은 새 id 로 잇고 옛 id 는 ENDED).
  ③ 전사 JSONL 이 없음 → `transcript_path=hermes-state:<id>` 의사경로, 워커·`smon grep` 이
  `~/.hermes/state.db` 를 읽기전용으로 조회. ④ id `YYYYMMDD_HHMMSS_hex` 는 앞 8자가 날짜라
  `hex-YYYYMMDD_HHMMSS` 로 뒤집어 저장 (`smon done` 은 `HERMES_SESSION_ID` 로 자기 세션 특정).
  이미 떠 있는 Hermes 세션엔 소급되지 않는다(재시작 필요).

## 구성

```
schema.sql              # DB 스키마 (sessions, events; WAL)
hooks/record-event.sh   # 단일 훅 디스패처 — 이벤트명을 $1로 받음
lib/paths.sh            # 경로 해석 SSOT (SMON_HOME·SMON_DB) — 모든 bash 스크립트가 source
bin/smon                # 조회 CLI (~/.local/bin/smon 심링크)
deploy/                 # launchd 템플릿, migrate-to-run.sh / rollback-run.sh
```

데이터(`sessions.db`)는 레포 밖 `~/.local/share/smon/sessions.db` 가 기본이다
(이전 전 설치는 레포 안 `sessions.db` — 아래 "배포 폴더(-run)와 DB 위치").

## 배포 폴더(-run)와 DB 위치

개발 체크아웃(`~/dev/session-monitor`)이 곧 라이브 설치라, 브랜치를 바꾸거나 고치는 중인 코드가
그대로 수십 개 세션의 훅으로 돈다. 그래서 둘을 나눈다.

- **개발**: `~/dev/session-monitor` — 브랜치·PR 작업만 한다. 훅·launchd 는 여기를 가리키지 않는다.
- **실행**: `~/dev/session-monitor-run` — `git clone` 한 main 추적 체크아웃. 훅·launchd·`~/.local/bin/smon`·
  스킬 심링크가 전부 여기를 가리킨다. 직접 고치지 않는다.
- **배포 = PR 머지 후 `git -C ~/dev/session-monitor-run pull --ff-only`.** 그게 전부다
  (훅 스크립트는 다음 이벤트부터 새 코드로 돈다. 설정 경로는 그대로라 재등록 불필요).

DB 경로는 `lib/paths.sh`(파이썬은 각 워커의 `_resolve_db()`)가 정한다. 우선순위:

1. `SMON_DB` 환경변수
2. `~/.local/share/smon/sessions.db` — **파일이 있으면**
3. `~/dev/session-monitor/sessions.db` — 레거시 기본

파일이 있으면 그쪽을 고르므로 DB 이전은 파일 이동뿐이다(코드·설정 변경 없음). 형제 스크립트는
`SMON_HOME`(기본 = 스크립트 실위치의 레포 루트)에서 찾으니 어느 체크아웃에서 돌든 자기 코드를 쓴다.
`apply-color.log` 도 `~/.local/share/smon/` 이 있으면 그리로 간다. 원격 맥 `smon export` 경로는
`SMON_REMOTE_BIN` 으로 바꿀 수 있다(기본은 기존 `~/dev/session-monitor/bin/smon`).

전환은 한 번, 조용한 시간대에 한다(이 PR 머지 + 개발 체크아웃 `git pull` 이 선행 조건).

```bash
deploy/migrate-to-run.sh            # dry-run — 할 일만 출력
deploy/migrate-to-run.sh --apply    # RUNNING 세션 있으면 중단 (--force 로 무시)
deploy/rollback-run.sh [백업폴더] [--apply]   # 되돌리기 (기본 dry-run)
```

migrate 순서: 사전점검(RUNNING·체크아웃 clean) → `-run` clone/pull → DB 를 `sqlite3 .backup` 으로 복사·
`integrity_check`·행수 대조 후 구 파일은 `sessions.db.migrated-<시각>` 으로 이름만 바꿈 → 훅 경로 교체
(claude settings.json·codex/agy hooks.json·Hermes hooks+allowlist) → launchd plist 경로 교체·재적재 →
`~/.local/bin/smon`·스킬 심링크 교체 → 새 경로로 합성 이벤트 1건을 쏴 새 DB 에 들어오는지 확인 후 삭제.
바꾼 파일은 전부 `~/.local/share/smon/migrate-<시각>/` 에 백업하고, rollback 이 그걸 쓴다.

훅은 `~/.claude/settings.json`(user level)에 이벤트별로 등록되어 있다.
새로 뜨는 세션부터 적용 (이미 떠 있는 세션엔 소급 안 됨).

아침 리포트(매일 07:50, Slack Canvas + DM)는 `report/` — 설정은 **[report/README.md](report/README.md)**,
등록은 `./install.sh --with-report`.

### 범위 — 개인 도구다

session-monitor 는 **내 머신들에서 도는 AI 세션을 관측하는 개인 도구**다. 전사 배포 대상이 아니다.
리포트는 그 머신에 훅이 깔려 있고 CLI 에이전트를 실제로 써야 내용이 생기므로, 채팅 위주 사용자에겐
빈 리포트가 간다.

worklog(`calendar-worklog`)와 헷갈리기 쉬운데 경계는 이렇다.

| | session-monitor | calendar-worklog |
|---|---|---|
| 무엇 | 세션 **관측** — 훅·DB·`smon` CLI·`smon report` | 캘린더 업무기록과 **아침 브리핑** |
| 소스 | 로컬 에이전트 세션만 | 캘린더·monday·Slack·메일·GW·smon |
| 대상 | 나(그리고 CLI 를 쓰는 소수) | 원내 구성원 |

브리핑은 이미 `smon export` 로 세션 정보를 읽는다(`briefing/prompt.md` C-6). 아침 메시지를
한 통으로 합칠지는 열린 문제이고, 합친다면 **발표는 worklog, 재료는 smon** 이 경계다.

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
