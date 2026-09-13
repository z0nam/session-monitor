# 아침 smon 리포트 — 설치 안내

매일 아침 07:50, **그 머신에서 돌던 AI 세션**(Claude Code · Codex · Antigravity)을 훑어
"프로젝트별 지금 어디까지 왔고 다음에 뭘 해야 하나"를 **Slack Canvas 체크리스트**로 만들고,
그 링크를 **본인 DM으로 1건** 보낸다. 하루를 지나며 처리한 항목을 눌러 끄는 용도다.

재료는 `smon report`(완료·노이즈가 이미 빠진 활성 세션)이고, 정리는 헤드리스 `claude`가 한다.

---

## 전제

| 항목 | 확인 |
|---|---|
| macOS | launchd로 예약한다 |
| smon 설치 | 레포 루트에서 `./install.sh` — **훅이 붙어야 세션이 기록된다** |
| `claude` CLI | 로그인되어 있을 것 |
| Slack 토큰 | 봇 토큰(권장) 또는 본인 사용자 토큰 — 아래 |
| 본인 Slack 멤버 ID | Slack 프로필 → 더보기 → "멤버 ID 복사" (`U`로 시작) |

## 3단계

**1. 설정 파일**

```sh
mkdir -p ~/.config/smon-report
cp report/config.example ~/.config/smon-report/config
# SLACK_SELF="U..." 를 본인 멤버 ID로 채운다
```

**2. Slack 토큰**

```sh
# 봇 토큰(xoxb) 저장 — 관리자에게 받는다
install -m 600 /dev/null ~/.config/smon-report/slack-bot-token
pbpaste > ~/.config/smon-report/slack-bot-token   # 또는 편집기로 붙여넣기
```

worklog(calendar-worklog)를 이미 쓰고 있으면 `~/.config/calendar-worklog/slack-bot-token`을
자동으로 찾으므로 이 단계를 건너뛰어도 된다.

**3. 등록**

```sh
./install.sh --with-report      # 매일 07:50 launchd 등록
```

바로 한 번 돌려 확인:

```sh
./report/run-report.sh
tail -5 report/logs/$(date +%F).log     # 마지막 줄이 "종료: REPORT_SENT" 면 성공
```

---

## 발신 경로 — 봇이 기본, 본인 계정은 대비책

`~/.config/smon-report/config`의 `REPORT_SENDER`로 정한다. 기본 `auto`는
**봇 토큰이 있으면 봇**, 없으면 사용자 토큰이다.

| | `bot` (기본) | `user` |
|---|---|---|
| Slack에 찍히는 발신자 | 봇 이름 | **본인 이름** |
| 준비물 | 관리자가 나눠주는 봇 토큰 하나 | 본인 Slack 앱을 만들어 사용자 토큰(xoxp) 발급 |
| 필요 scope | `chat:write`, `canvases:write` | `chat:write`, `canvases:write` (+ `im:write`, `canvases:read` 권장) |
| 언제 | 원내 배포 기본 | 봇 계정이 없는 환경, 또는 본인 이름으로 받고 싶을 때 |

- **봇이 만든 캔버스는 수신자에게 기본적으로 보이지 않는다.** 그래서 생성 직후
  `canvases.access.set`으로 수신자에게 권한을 준다(`post-report.py`가 자동으로 한다).
  봇 토큰에 `canvases:write`가 없으면 링크만 오고 내용이 안 열린다.
- `user` 경로는 **토큰 주인과 수신자가 다르면 캔버스조차 만들지 않고 실패**한다.
  커넥터로 보내던 시절 신분이 바뀌어 남의 DM으로 배달된 사고가 있었다(`post-report.py` 주석).

사용자 토큰 경로를 쓸 때의 토큰 위치는 `config.example`의 `SLACK_TOKEN_ENV_FILE` 참고.

---

## 멀티 머신

허브-스포크로 묶어 쓰는 경우(README의 "멀티 머신" 절), **리포트 잡은 허브 한 대에서만** 켠다.
허브가 스포크 세션까지 끌어와 "다른 머신" 클러스터로 함께 정리하므로, 스포크에서도 켜면
같은 내용의 DM이 여러 번 온다.

## 문제 해결

로그는 `report/logs/<날짜>.log`. 실패하면 macOS 알림도 뜬다.

| 로그에 보이는 것 | 원인 · 조치 |
|---|---|
| `REPORT_FAILED: SLACK_SELF 미설정` | 1단계 설정 파일에 멤버 ID를 안 채웠다 |
| `post-report: Slack 토큰 없음` | 2단계 토큰 경로 확인 (`chmod 600`) |
| `post-report: 신분 불일치` | `user` 경로인데 토큰 주인 ≠ `SLACK_SELF`. 본인 토큰인지 확인 |
| `post-report: 캔버스 생성 거부 — missing_scope` | 토큰에 `canvases:write` 없음 → 앱 권한 추가 후 **재설치** |
| `판정: 캔버스 본문 없음` | 모델이 마커(`REPORT_CANVAS_START/END`) 없이 답했다. 로그의 원문 확인 |
| 링크는 오는데 캔버스가 안 열림 | 봇 경로에서 권한 부여 실패 — 봇 scope 확인 |
| `claude` 인증 만료로 실패 | `claude setup-token` 으로 전용 토큰 발급 후 `CLAUDE_TOKEN_FILE` 지정(`config.example`) |

리포트를 잠시 멈추려면:

```sh
launchctl unload ~/Library/LaunchAgents/com.namun.smon-report.plist
```
