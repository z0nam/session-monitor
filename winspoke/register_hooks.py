#!/usr/bin/env python3
"""Claude Code settings.json에 smon 훅 5종 멱등 등록 (install.ps1이 호출).
사용: register_hooks.py <python.exe 경로> <record_event.py 경로>"""
import json
import os
import sys

py, rec = sys.argv[1], sys.argv[2]
p = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
s = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
hooks = s.setdefault("hooks", {})
for ev in ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]:
    arr = hooks.setdefault(ev, [])
    if any("record_event.py" in h.get("command", "")
           or "record-event.sh" in h.get("command", "")
           for e in arr for h in e.get("hooks", [])):
        continue
    arr.append({"matcher": "", "hooks": [
        {"type": "command", "command": f'"{py}" "{rec}" {ev} claude'}]})
    print("  +", ev)
json.dump(s, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
