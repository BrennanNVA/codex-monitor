# Codex Monitor v0.1 Design

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

## Views and Controls

The default `All Workspaces` view aggregates metrics and lists active workspaces. Pressing `1` through `9` selects a listed workspace. `A` returns to the aggregate view. `Q` quits. These controls only change the display and never affect Codex sessions.

The dashboard uses stable rows, textual labels, symbols, and optional color. It supports `-NoColor`, truncates long paths to the terminal width, and shows `N/A` rather than inventing unavailable values.

## Metrics

- Active agents: active Codex sessions associated with a workspace.
- Created, Changed, Deleted, Renamed: accepted filesystem events observed while the monitor runs.
- `+ (N)` and `- (N)`: Git-added and Git-removed lines relative to each resolved Git worktree's baseline commit, including eligible untracked text files.
- Git commits: commits created since the workspace was first discovered.
- Tokens used: latest cumulative `total_tokens` for each active session.
- Tokens cached: latest cumulative `cached_input_tokens` for each active session. Cached tokens are a subset of input tokens; the displayed percentage is cached input divided by total input tokens.

The Codex JSONL format is an internal local format and may change. Parsing is isolated and fails closed to `N/A`.

## Distribution

The repository includes a double-click CMD launcher, PowerShell sources, tests, GitHub Actions validation, an MIT license, security and contribution guidance, and a release ZIP.
