# session-monitor Windows spoke installer (idempotent).
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1
# Prereq: repo copied to %USERPROFILE%\dev\session-monitor, Python 3 installed.
# NOTE: keep this file ASCII-only — PowerShell 5 reads BOM-less files as ANSI(CP949).
$ErrorActionPreference = "Stop"
$root = Join-Path $env:USERPROFILE "dev\session-monitor"
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) { Write-Error "Python 3 required"; exit 1 }

Write-Host "== schema (idempotent)"
& $py -c "import sqlite3,os; db=sqlite3.connect(os.path.join(r'$root','sessions.db')); db.executescript(open(os.path.join(r'$root','schema.sql'),encoding='utf-8').read()); db.close()"

Write-Host "== register Claude Code hooks (~/.claude/settings.json)"
$rec = Join-Path $root "winspoke\record_event.py"
& $py (Join-Path $root "winspoke\register_hooks.py") $py $rec

if (Test-Path (Join-Path $env:USERPROFILE ".codex")) {
  Write-Host "== codex hooks.json (copy; symlink needs admin on Windows)"
  $cmd = "`"$py`" `"$rec`" native codex"
  $entry = @{ hooks = @(@{ type = "command"; command = $cmd; timeout = 10 }) }
  $cfg = @{ hooks = @{ SessionStart = @($entry); UserPromptSubmit = @($entry);
                       Stop = @($entry); PermissionRequest = @($entry) } }
  $cfg | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $env:USERPROFILE ".codex\hooks.json")
  Write-Host "  codex ok - NOTE: approve via /hooks in codex TUI"
}

Write-Host "done - new agent sessions will be recorded"
