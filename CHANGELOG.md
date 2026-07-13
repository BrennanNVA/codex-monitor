# Changelog

## 0.2.0 - 2026-07-13

- Read the newest token record backward from large JSONL session logs, preventing refresh stalls as sessions grow.
- Report token and cache deltas since monitor launch and preserve totals when agents become inactive or counters reset.
- Display active workspace/agent counts, uptime, last token refresh, and an explicit health status.
- Surface sanitized session-read and dropped-filesystem-event warnings instead of silently showing stale or unavailable data.
- Register and account for `FileSystemWatcher` error events while retaining the five-second session recovery scan.
- Clear the dashboard before each in-place redraw so shorter views do not retain stale trailing text.
- Add deterministic SVG, PNG, and multi-size ICO branding.
- Replace legacy single-workspace screenshots with privacy-safe v0.2.0 aggregate and workspace captures.
- Add large-log, scan-diagnostic, token-lifecycle, health-state, asset, and redraw-order regression coverage.

## 0.1.1 - 2026-07-12

- Resolve active session directories to their real Git worktree roots so code metrics update for parallel worktrees.
- Display cached-input percentage using cached input tokens divided by total input tokens.
- Replace repeated full-screen clearing with in-place redraws to prevent refresh flicker.
- Refresh from Codex session-log and workspace filesystem events with approximately 100 ms display latency; retain a five-second recovery scan only for missed events.
- Display compact token totals and cache-hit percentages with two decimal places.
- Accept validated Git root and commit output directly instead of relying on fragile native pipeline exit-state behavior in Windows PowerShell 5.1.
- Start at a compact 110-column by 24-row terminal size while remaining manually resizable.

## 0.1.0 - 2026-07-12

- Initial Windows community release.
- Automatic Codex CLI session and workspace discovery.
- Parallel-agent aggregation and two-minute inactive-workspace removal.
- Filesystem, Git, commit, total-token, and cached-token metrics.
- All-workspaces and individual-workspace views.
- Keyboard-only controls and no-color mode.
