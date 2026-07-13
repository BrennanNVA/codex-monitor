# Codex Monitor v0.2 Design

## Goal

Create an accessible Windows terminal dashboard that automatically discovers active Codex CLI sessions, groups parallel agents by workspace, and displays live filesystem, Git, and token metrics without requiring a configured project path.

## Supported Environment

- Windows 10 and Windows 11.
- Windows PowerShell 5.1 and PowerShell 7.
- Codex CLI sessions stored under `$CODEX_HOME\sessions` or `%USERPROFILE%\.codex\sessions`.
- Git metrics when a discovered workspace belongs to a Git repository.

## Session and Workspace Lifecycle

The monitor watches the Codex sessions directory and periodically rescans it as a recovery mechanism. It parses only session metadata and token-count records. Prompts, responses, tool arguments, source contents, and credentials are neither collected nor displayed.

Sessions are grouped by their metadata working directory. Workspaces appear immediately after discovery. A workspace remains visible while at least one associated session has activity within the preceding two minutes; it disappears when all associated sessions exceed that grace period. Resumed activity makes it reappear automatically.

Session scans return sanitized diagnostics: completion time, candidate count, and read-failure count. Token records are read backward from the end of each JSONL file in fixed-size blocks so large session histories do not delay live refreshes.

## Views and Controls

The default `All Workspaces` view aggregates metrics and lists active workspaces. Pressing `1` through `9` selects a listed workspace. `A` returns to the aggregate view. `Q` quits. These controls only change the display and never affect Codex sessions.

The dashboard uses stable rows, textual labels, symbols, and optional color. It supports `-NoColor`, truncates long paths to the terminal width, and shows `N/A` rather than inventing unavailable values. It also shows process uptime, last successful token refresh, and a sanitized `OK` or `WARNING` health state.

## Metrics

- Active agents: active Codex sessions associated with a workspace.
- Created, Changed, Deleted, Renamed: accepted filesystem events observed while the monitor runs.
- `+ (N)` and `- (N)`: Git-added and Git-removed lines relative to each resolved Git worktree's baseline commit, including eligible untracked text files.
- Git commits: commits created since the workspace was first discovered.
- Tokens since launch: non-negative `total_tokens` deltas after each session's first observation during the monitor process. In-memory session state preserves totals after inactivity and across upstream counter rollback.
- Tokens cached: non-negative `cached_input_tokens` deltas since launch. Cached tokens are a subset of input tokens; the displayed percentage is cached input divided by total input tokens.
- Health: newest session scan time, transient session-read failure count, and process-lifetime dropped-filesystem-event count.

The Codex JSONL format is an internal local format and may change. Parsing is isolated, preserves last valid metrics, and fails closed with a visible sanitized warning.

Both session and workspace filesystem watchers subscribe to `Error`. A five-second session recovery scan repairs discovery after missed events; the dashboard warns when workspace activity counts may be incomplete because lost filesystem events cannot be reconstructed.

## Distribution

The repository includes a double-click CMD launcher, PowerShell sources, tests, GitHub Actions validation, an MIT license, security and contribution guidance, deterministic SVG/PNG/ICO icon assets, privacy-safe screenshots, a `VERSION` file, and a release ZIP.
