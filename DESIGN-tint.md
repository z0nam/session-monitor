# smon-tint — 세션 상태를 cmux 탭 색으로 (resume-cards 색-즉시성 대체)

**상태:** v2 설계 확정(2026-07-14, 3색 확장) — 구현 진행. v1(빨강 단색) 확정분은 아래 그대로,
v2 변경은 이 블록이 우선한다.

## v2 확정 (2026-07-14, 사용자)

- **팔레트 = {Red, Blue, Green, 없음}.** "빨강 = 오직 attention" 불변식은 유지.
- **신호 원천 2계층**: Red = 훅 결정론(즉시·100% 신뢰). Blue/Green = 요약 워커의
  LLM 분류(≤2분, best-effort). 분류가 틀려도 빨강은 안 틀린다는 계약.
- 색 규칙 v2:
  ```
  state == NEEDS_ATTENTION                    → Red    (훅 즉시)
  state == WAITING_INPUT and phase == done    → Green  (진짜 완료 — smon ack 로 끔)
  state == WAITING_INPUT and phase == direction → Blue (일단락/지침 대기)
  그 외 (RUNNING, ENDED, phase 없음·acked)     → clear
  ```
- `sessions.phase` TEXT: ''|direction|done|acked. 워커가 요약과 같은 LLM 호출로 분류
  (done 은 보수적으로 — 목표 달성이 명시적일 때만). RUNNING 전이(턴 시작) 때 '' 리셋.
- 알림은 v1 그대로 Red 만 (배너+소리). Blue/Green 은 색·보드만.
- `smon ack <sid앞자리>`: phase='acked' + 색 clear — 초록 확인 후 끄기.
- 보드: SUMMARY 앞에 PH 열(-, B, G) + 정렬 우선순위 Red > Blue > Green > RUNNING > 나머지.
- 원격 머신: 색은 cmux(studio)만, phase 는 export/pull 로 보드에 전파.
**맥락:** resume-cards(문패 텍스트 자동기록)는 07-08 이후 정지(hang 격리실험).
그 "탭만 봐도 상태 안다"는 가치를, **텍스트 없이 네이티브 탭 색**으로 이식한다.
소스는 smon의 결정론적 세션 상태(SQLite). cmux 사이드바에 **텍스트를 안 쓰므로**
resume-cards가 의심받던 SwiftUI 레이아웃 hang 경로를 안 탄다.

## 확정된 결정 (사용자)

- **색 소유권 = 자동 완전소유.** 자동 시스템이 cmux 에이전트 탭의 색 채널을 소유한다.
  기존 수동 색(초록 `#196F3D`·빨강 `#C0392B` 등)은 보존하지 않는다 — 각 세션 첫 이벤트에
  clear 로 정리된다. **이유(correctness):** 수동 빨강과 attention 빨강이 구분 불가하므로,
  non-attention 탭의 색을 밀어 **"빨강 = 오직 attention"** 불변식을 강제한다.
- **팔레트 = `{Red, 없음}` 둘뿐.** NEEDS_ATTENTION 만 색을 받는다. WAITING_INPUT 유휴색 없음.

## 색 규칙

```
state == NEEDS_ATTENTION  → Red (named color)
그 외 전부                 → clear-color (색 없음)
```

## 전이 로직 (dedup 내장 — churn 최소)

`sessions` 에 `tab_color` 컬럼(자동이 마지막으로 칠한 색: `'Red'` | `''`).
매 훅 이벤트에서:

```
desired = "Red" if state == NEEDS_ATTENTION else ""     # "" = clear
if desired != tab_color:        # 바뀔 때만 cmux 호출
    apply(desired); persist tab_color = desired
else:
    no-op                       # RUNNING↔WAITING 매 턴 반복 = no-op
```

- 예상 cmux 호출량: 세션당 **첫 이벤트에 clear 1회**(수동색 정리) + attention **진입/해제 각 1회**.
  그 외 전부 no-op → `set-color` 폭주 없음 = hang 경로 무부담.
- **버킷만 비교**: RUNNING/WAITING/SessionStart 는 전부 `desired=""` 버킷이라 서로 전이해도
  tab_color 가 이미 `''` 면 no-op.

## 배선 (non-blocking / hang-safe)

- `hooks/record-event.sh`:
  1. 지금처럼 DB upsert. **단, upsert 트랜잭션에서 직전 `tab_color` 를 함께 SELECT**
     (또는 upsert 직전에 조회)해서 새 state 로 `desired` 계산.
  2. `SRC`/저장된 source 가 `cmux` 이고 `desired != tab_color` 일 때만,
     `apply-color.sh <WS> <color>` 를 **detached** 로 던지고 훅은 즉시 반환:
     ```bash
     if [ "$SRC_EFF" = cmux ] && [ "$DESIRED" != "$TAB_COLOR" ] && [ -n "$WS" ]; then
       nohup "$DIR/apply-color.sh" "$WS" "$DESIRED" >/dev/null 2>&1 &
     fi
     # tab_color 는 위 SQL UPDATE 에 " , tab_color='$DESIRED' " 로 같이 반영
     ```
     `WS` = `$CMUX_WORKSPACE_ID`(훅이 in-session이라 env 직결). cmux 아니면 스킵.
  3. **주의:** cmux 호출을 훅 동기 경로에 넣지 말 것. cmux hang 시 최대 8s 블록 → 세션 훅
     지연. 반드시 `nohup … &` 로 떼어낸다.

- `hooks/apply-color.sh` (신규, 에이전트 중립):
  ```
  인자: $1 = workspace(uuid|ref|index), $2 = color("Red" | "" =clear)
  CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux (env override 존중: CMUX_BUNDLED_CLI_PATH)
  timeout 8s.
  color 비었으면:  $CMUX workspace-action --workspace "$1" --action clear-color
  아니면:          $CMUX workspace-action --workspace "$1" --action set-color --color "$2"
  실패(returncode≠0)면 cwd 폴백은 v1 생략 가능 — 로그만(apply-color.log). 어떤 실패든 exit 0.
  ```

- **Codex 자동 커버:** #1 Codex notify 어댑터가 같은 `record-event.sh` 를 호출하면
  색도 공짜로 따라온다. 색 로직을 Claude 전용 분기에 넣지 말 것.

## 크래시 안전망 (리퍼 연동)

- `SessionEnd` → state=ENDED → desired="" → 정상 종료 시 빨강 제거(위 로직으로 자동).
- **force-quit/hang 사망**(훅이 안 뜸)으로 빨강 잔류 → **smon 보드의 리퍼**(그리기 전 죽은
  pid 를 ENDED 로 강등하는 그 로직)에서, 강등 대상이 `tab_color='Red'` 면
  `apply-color.sh <cmux_workspace_id> ""` 를 detached 로 던져 청소. 강등 후 tab_color='' 로.
  - 이걸 위해 `cmux_workspace_id` 를 SessionStart 에 저장(env `CMUX_WORKSPACE_ID`).
  - uuid 가 stale(cmux 재시작)이면 clear 실패 → 로그만. 그 탭은 이미 사라졌을 가능성 큼.

## DB 변경

```sql
ALTER TABLE sessions ADD COLUMN tab_color TEXT;          -- 'Red' | '' (자동이 칠한 현재색)
ALTER TABLE sessions ADD COLUMN cmux_workspace_id TEXT;  -- 리퍼 청소 타겟(SessionStart 저장)
```

`cmux_workspace_id` 저장: `record-event.sh` 의 SessionStart(또는 첫 이벤트) 분기에서
`$CMUX_WORKSPACE_ID` 를 upsert. (branch/source 를 저장하는 그 블록에 같이.)

## cmux CLI 사실 (실측)

- `workspace-action --action set-color --color <name|#hex>` / `--action clear-color`.
- named: Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua, Blue, Navy, Indigo,
  Purple, Magenta, Rose, Brown, Charcoal. (Red 의 hex = `#C0392B`.)
- `--workspace` 는 uuid·ref·index 다 받음. 기본값 `$CMUX_WORKSPACE_ID`.
- `workspace list --id-format both --json` 의 `custom_color` 로 현재색 확인 가능(폴백/디버그용).

## resume-cards 은퇴

- `~/.claude/cmux-resume/PAUSED` 유지(이미 정지). smon-tint 가 색-즉시성을 대체.
- Codex notify 체인의 `update-card.py` 호출은 PAUSE 가드가 이미 막으므로 무해 — 정리 시
  체인에서 제거해도 됨(선택).
- 관련 메모리 갱신: [[cmux-resume-cards]] 에 "smon-tint 로 대체, 은퇴" 한 줄.

## 검증 (end-to-end)

1. cmux 에이전트 세션에서 권한 프롬프트 유발(Notification) → 몇 초 내 그 탭이 **빨강**.
2. 응답(UserPromptSubmit) 또는 Stop → 빨강 **해제**(clear).
3. RUNNING↔WAITING 여러 턴 → set-color 로그에 추가 호출 **없음**(no-op dedup 확인).
4. 세션 강제종료(force quit) 후 `smon` 실행 → 리퍼가 그 탭 빨강 **청소**.
5. cmux 아닌 세션(ghostty)에서 attention → 색 시도 **안 함**(로그 확인).
6. cmux hang 상태에서 attention 전이 → 세션 훅이 **안 막힘**(detached 확인).
