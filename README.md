# Codex Monitor

A lightweight Windows terminal dashboard for observing active Codex CLI workspaces, parallel agents, filesystem mutations, Git changes, commits, and token usage.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- Automatically discovers Codex CLI sessions—no project path configuration.
- Groups parallel agents by working directory.
- Shows an aggregate **All Workspaces** view and individual workspace views.
- Removes a workspace after all of its sessions have been inactive for two minutes.
- Tracks created, changed, deleted, and renamed filesystem events.
- Tracks Git line additions/removals and commits since discovery.
- Aggregates total and cached tokens across active agents.
- Refreshes from filesystem and Codex session-log events with approximately 100 ms display latency.
- Supports Windows PowerShell 5.1 and PowerShell 7.
- Offers keyboard-only controls and an optional no-color display.

## Run

Open the repository's **Code** menu, choose **Download ZIP**, extract it, and double-click `Start-Codex-Monitor.cmd`. You can also clone it with Git:

```powershell
git clone https://github.com/BrennanNVA/codex-monitor.git
cd codex-monitor
.\Start-Codex-Monitor.cmd
```

Or run the PowerShell entry point directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\codex-monitor.ps1
```

No-color mode:

```powershell
.\Start-Codex-Monitor.cmd -NoColor
```

Controls:

```text
[1-9] View Workspace   [A] View All   [Q] Quit
```

## How discovery works

The monitor resolves `CODEX_HOME` when set and otherwise uses `%USERPROFILE%\.codex`. It inspects recently updated JSONL files under the `sessions` directory, reads the session working directory and token-count records, and groups sessions by workspace. New sessions appear automatically. Workspaces disappear when every associated session has been inactive for two minutes.

Token totals include only sessions still inside that two-minute activity window. A five-second recovery scan catches rare filesystem events missed by the operating system watcher; normal updates are event-driven.

## Metrics

- `+ (N)` and `- (N)` are net Git line additions and removals relative to the commit present when the workspace was discovered. Eligible untracked text files are included as additions.
- Git commits are commits made after workspace discovery.
- Tokens used are Codex's reported cumulative total tokens.
- Tokens cached are cached input tokens and are already a subset of tokens used. The adjacent percentage is `cached_input_tokens / input_tokens`, which is the cache-hit rate relevant to input-token cost.
- `N/A` means the relevant Git or Codex data is unavailable.

## Privacy

Codex Monitor reads only the minimum local session data needed for discovery and metrics: session ID, working directory, modification time, and token-count records. It does not collect or display prompts, responses, tool arguments, credentials, or source-file contents. Nothing is transmitted by the monitor.

## Accessibility

- Keyboard-only operation.
- Labels and symbols accompany every color.
- `-NoColor` mode.
- Responsive path truncation for narrow terminals.
- Stable dashboard rows and explicit unavailable states.

## Limitations

Codex CLI's local JSONL session representation is not a documented public API and may change. The parser is isolated in `src/CodexMonitor.psm1` so compatibility fixes remain localized.

## Development

```powershell
Install-Module Pester -Scope CurrentUser -Force
Invoke-Pester .\tests\CodexMonitor.Tests.ps1
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
