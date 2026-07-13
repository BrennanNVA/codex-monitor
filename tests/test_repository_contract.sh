#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$root/src/CodexMonitor.psm1"
app="$root/src/codex-monitor.ps1"
launcher="$root/Start-Codex-Monitor.cmd"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
require_file() { [[ -f "$root/$1" ]] || fail "$1 exists"; pass "$1 exists"; }
require_text() { grep -Fq -- "$2" "$root/$1" || fail "$1 contains $2"; pass "$1 contains $2"; }

for file in src/CodexMonitor.psm1 src/codex-monitor.ps1 Start-Codex-Monitor.cmd README.md LICENSE SECURITY.md CONTRIBUTING.md CHANGELOG.md VERSION assets/codex-monitor.svg assets/codex-monitor.png assets/codex-monitor.ico assets/codex-monitor-overview.png assets/codex-monitor-workspace.png tests/CodexMonitor.Tests.ps1 .github/workflows/test.yml; do
  require_file "$file"
done

require_text src/CodexMonitor.psm1 'Resolve-CodexHome'
require_text src/CodexMonitor.psm1 'CODEX_HOME'
require_text src/CodexMonitor.psm1 "'.codex'"
require_text src/CodexMonitor.psm1 "Join-Path \$CodexHome 'sessions'"
require_text src/CodexMonitor.psm1 'Get-CodexSessionSnapshot'
require_text src/CodexMonitor.psm1 'Get-ActiveWorkspaceSnapshot'
require_text src/CodexMonitor.psm1 '[TimeSpan]::FromMinutes(2)'
require_text src/CodexMonitor.psm1 "'session_meta'"
require_text src/CodexMonitor.psm1 "'token_count'"
require_text src/CodexMonitor.psm1 'cached_input_tokens'
require_text src/CodexMonitor.psm1 'input_tokens'
require_text src/CodexMonitor.psm1 "Join-Path \$Current.FullName '.git'"
require_text src/CodexMonitor.psm1 'System.IO.FileSystemWatcher'
require_text src/CodexMonitor.psm1 'diff --numstat'
require_text src/CodexMonitor.psm1 'rev-list --count'

require_text src/codex-monitor.ps1 '[switch]$NoColor'
require_text src/codex-monitor.ps1 "'All Workspaces'"
require_text src/codex-monitor.ps1 "KeyChar -match '^[1-9]$'"
require_text src/codex-monitor.ps1 "KeyChar -match '^[aA]$'"
require_text src/codex-monitor.ps1 "KeyChar -match '^[qQ]$'"
require_text src/codex-monitor.ps1 '[1-9] View Workspace   [A] View All   [Q] Quit'
require_text src/codex-monitor.ps1 'Format-CacheRate $TokenTotals.TokensCached $TokenTotals.InputTokens'
require_text src/codex-monitor.ps1 'Tokens Since Launch'
require_text src/codex-monitor.ps1 'Token Refresh:'
require_text src/codex-monitor.ps1 'Status:'
require_text src/codex-monitor.ps1 '[Console]::SetCursorPosition(0, 0)'
require_text src/codex-monitor.ps1 '[Console]::CursorVisible = $false'
require_text src/codex-monitor.ps1 '$SessionWatcher = New-Object System.IO.FileSystemWatcher'
require_text src/codex-monitor.ps1 "'Created','Changed','Renamed','Error'"
require_text src/codex-monitor.ps1 '$DiscoveryDirty = $true'
require_text src/codex-monitor.ps1 '[TimeSpan]::FromMilliseconds(100)'
require_text src/codex-monitor.ps1 '[TimeSpan]::FromSeconds(5)'
require_text src/codex-monitor.ps1 'Start-Sleep -Milliseconds 50'
require_text src/CodexMonitor.psm1 "ToString('0.00'"
if grep -Fq '$LASTEXITCODE' "$root/src/CodexMonitor.psm1"; then fail 'module avoids fragile native pipeline exit-state checks'; fi
pass 'module avoids fragile native pipeline exit-state checks'
require_text Start-Codex-Monitor.cmd '-ExecutionPolicy Bypass'
require_text Start-Codex-Monitor.cmd 'mode con: cols=110 lines=24'
require_text README.md 'Privacy'
require_text README.md 'two minutes'
require_text README.md '0.2.0'
require_text VERSION '0.2.0'
require_text SECURITY.md 'session'
require_text .github/workflows/test.yml 'windows-latest'

require_text src/codex-monitor.ps1 'Format-ConsoleFrame -Lines'
require_text src/codex-monitor.ps1 '[Console]::Write($Frame)'
if grep -Fq '[Console]::Write("$([char]27)[0J")' "$root/src/codex-monitor.ps1"; then fail 'dashboard avoids clearing the screen before rendering'; fi
pass 'dashboard avoids clearing the screen before rendering'

printf 'All repository contract tests passed.\n'
