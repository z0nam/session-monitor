#!/usr/bin/env python3
"""smon 리포트를 Slack Canvas 로 만들고 본인 DM 으로 핑한다 (표준입력 = 캔버스 마크다운).

왜 러너가 보내나 (2026-09-13)
--------------------------
예전엔 모델이 claude.ai Slack 커넥터(`mcp__claude_ai_Slack__*`)로 캔버스를 만들고 DM 을 보냈다.
그런데 커넥터의 Slack 신분은 claude.ai 계정 쪽 인증을 따라간다. 그 인증이 다른 사람 계정으로
바뀌면 "본인에게 DM"(`channel_id=<본인 UID>`)이 **그 사람과 나의 DM** 으로 해석되어 배달된다.

실측(2026-09-12~13): 수신자 설정은 정상(`SLACK_SELF`)이었는데 리포트 2건이 동료 DM 으로 갔고
발신자도 그 동료로 찍혔다. 9/11 까지는 같은 호출이 본인 DM(D09…)으로 갔다.

이제 모델은 캔버스 본문만 출력하고 러너가 이 스크립트로 직접 발송한다. 토큰은 사용자 토큰(xoxp)
이라 **발신자가 토큰 주인으로 고정**된다. 보내기 전에 auth.test 로 신분을 확인하고 대상과 다르면
아무 것도 만들지 않고 실패로 끝낸다 — 조용히 남에게 배달되는 경로를 없앤다.

토큰: 1) $SLACK_USER_TOKEN  2) $SLACK_TOKEN_ENV_FILE 의 $SLACK_TOKEN_VAR
      (기본 ~/dev/ji-slack-admin/slack-directory/.env 의 SLACK_USER_TOKEN, namun-admin-cli 앱)
필요 scope: chat:write, canvases:write (+ im:write, canvases:read 권장)

stdout: CANVAS_ID=… / CANVAS_URL=… / REPORT_DM_TS=…
종료코드: 0 성공 / 1 실패. 러너가 이 코드로 판정하므로 거짓 성공을 내지 않는다.
"""
import json
import os
import re
import sys
import urllib.request

DEFAULT_ENV_FILE = "~/dev/ji-slack-admin/slack-directory/.env"


def read_token():
    t = os.environ.get("SLACK_USER_TOKEN")
    if t:
        return t.strip()
    path = os.path.expanduser(os.environ.get("SLACK_TOKEN_ENV_FILE", DEFAULT_ENV_FILE))
    var = os.environ.get("SLACK_TOKEN_VAR", "SLACK_USER_TOKEN")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = re.match(rf"\s*{re.escape(var)}\s*=\s*(.+)", line)
            if m:
                return m.group(1).strip().strip("'\"")
    return None


def api(token, method, payload):
    req = urllib.request.Request(
        f"https://slack.com/api/{method}",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json; charset=utf-8"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def main():
    args = sys.argv[1:]
    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return default

    title = opt("--title")
    target = opt("--to") or os.environ.get("SLACK_SELF", "").strip()
    if not title:
        sys.exit("post-report: --title 없음")
    if not target:
        sys.exit("post-report: 대상 없음 (--to 또는 SLACK_SELF)")

    body = sys.stdin.read().strip()
    if not body:
        sys.exit("post-report: 캔버스 본문이 비어 있음 (stdin)")

    token = read_token()
    if not token:
        sys.exit("post-report: Slack 사용자 토큰 없음 "
                 f"($SLACK_USER_TOKEN 또는 {DEFAULT_ENV_FILE})")

    # 신분 확인 — 토큰 주인이 곧 발신자다. 대상(본인)과 다르면 남의 DM 으로 갈 수 있으므로 중단.
    try:
        who = api(token, "auth.test", {})
    except Exception as e:
        sys.exit(f"post-report: auth.test 실패 — {e}")
    if not who.get("ok"):
        sys.exit(f"post-report: 토큰 인증 실패 — {who.get('error')}")
    if who.get("user_id") != target:
        sys.exit(f"post-report: 신분 불일치 — 토큰 주인 {who.get('user_id')}"
                 f"({who.get('user')}) != 대상 {target}. 발송하지 않음.")

    try:
        c = api(token, "canvases.create", {
            "title": title,
            "document_content": {"type": "markdown", "markdown": body},
        })
    except Exception as e:
        sys.exit(f"post-report: canvases.create 호출 실패 — {e}")
    if not c.get("ok"):
        sys.exit(f"post-report: 캔버스 생성 거부 — {c.get('error')}")
    cid = c.get("canvas_id")
    url = f"{who.get('url', '').rstrip('/')}/docs/{who.get('team_id')}/{cid}"
    print(f"CANVAS_ID={cid}")
    print(f"CANVAS_URL={url}")

    try:
        m = api(token, "chat.postMessage",
                {"channel": target, "text": f":clipboard: 오늘 smon 리포트 → {url}"})
    except Exception as e:
        sys.exit(f"post-report: chat.postMessage 호출 실패 — {e} (캔버스 {cid} 는 생성됨)")
    if not m.get("ok"):
        sys.exit(f"post-report: DM 거부 — {m.get('error')} (캔버스 {cid} 는 생성됨)")
    print(f"REPORT_DM_TS={m.get('ts')}")
    print(f"REPORT_DM_CHANNEL={m.get('channel')}")


if __name__ == "__main__":
    main()
