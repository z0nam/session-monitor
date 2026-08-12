-- session-monitor Phase 1 schema
-- 적용: sqlite3 sessions.db < schema.sql (idempotent)
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS sessions (
  session_id    TEXT PRIMARY KEY,
  agent         TEXT DEFAULT 'claude',  -- claude | codex | antigravity | ... (어댑터가 지정)
  project_path  TEXT,
  git_branch    TEXT,
  source        TEXT,             -- 터미널 추정: TERM_PROGRAM / tmux / cmux (best-effort)
  cmux_ws       TEXT,             -- cmux 워크스페이스 ID (sid→워크스페이스 점프용; cmux 밖이면 NULL)
  started_at    INTEGER,          -- epoch sec
  last_event_at INTEGER,
  state         TEXT CHECK(state IN ('RUNNING','WAITING_INPUT','NEEDS_ATTENTION','ENDED')),
  ended_at      INTEGER,
  pid           INTEGER,          -- claude 프로세스 PID (생존 판정용; NULL = 미확인)
  summary       TEXT,             -- Phase 2: 로컬 LLM 한 줄 요약
  summary_at    INTEGER,
  summary_model TEXT,             -- 요약을 만든 모델 (모델 비교용)
  notified_at   INTEGER,          -- Phase 3: 마지막 알림 시각 (중복 방지)
  tab_color     TEXT DEFAULT '',  -- smon-tint: 실제 적용된 cmux 탭 색 ('?'=미지→강제재적용)
  tab_want      TEXT DEFAULT '',  -- smon-tint: 원하는 색. want!=color면 reconcile이 적용
  phase         TEXT DEFAULT ''   -- 워커 LLM 분류: ''|direction|done|acked (DESIGN-tint v2)
);

-- Phase 2 워커 설정 (smon model 등)
CREATE TABLE IF NOT EXISTS config (
  key   TEXT PRIMARY KEY,
  value TEXT
);

-- 멀티 머신: 허브가 smon pull(ssh)로 끌어온 다른 머신들의 세션 스냅샷.
-- 머신 단위로 통째로 교체된다 (원본 머신에서 reap 후 export되므로 생존 판정 불필요).
CREATE TABLE IF NOT EXISTS remote_sessions (
  machine       TEXT,
  session_id    TEXT,
  agent         TEXT,
  project_path  TEXT,
  git_branch    TEXT,
  state         TEXT,
  last_event_at INTEGER,
  pid           INTEGER,
  summary       TEXT,
  cmux_ws       TEXT,
  pulled_at     INTEGER,
  phase         TEXT DEFAULT '',
  PRIMARY KEY (machine, session_id)
);

CREATE TABLE IF NOT EXISTS events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT,
  event_type   TEXT,
  payload_json TEXT,              -- 훅 stdin JSON에서 대화 내용 필드(prompt, last_assistant_message) 제거본
  created_at   INTEGER,
  processed    INTEGER DEFAULT 0  -- Phase 2 LLM 워커용 플래그
);

CREATE INDEX IF NOT EXISTS idx_events_session   ON events(session_id);
CREATE INDEX IF NOT EXISTS idx_events_processed ON events(processed);
