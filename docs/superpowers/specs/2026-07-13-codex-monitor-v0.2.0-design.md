# Codex Monitor v0.2.0 Design

## Objective

Release Codex Monitor v0.2.0 with reliable token reads on large session logs, metrics whose timeframe is explicit and stable, visible operational health, refreshed branding and screenshots, expanded regression coverage, and a synchronized local installation under `Desktop\codex-watcher`.

## Scope

The release includes:

- an efficient reverse JSONL reader that finds the newest complete token-count record without loading thousands of earlier records;
- token totals measured from monitor launch instead of full-session lifetime totals;
- active workspace and agent counts kept separate from since-launch token totals;
- last successful session refresh time and a concise health state;
- visible warnings for session-read failures and `FileSystemWatcher` buffer overflows;
- deterministic SVG, PNG, and ICO program icons;
- two replacement screenshots captured from the real dashboard with synthetic, privacy-safe workspaces;
- version, changelog, README, design, packaging, and release updates for v0.2.0;
- a release ZIP and a synchronized `Desktop\codex-watcher` installation with compatibility launchers.

Installer, tray integration, persistent history across monitor launches, a configuration GUI, and telemetry remain out of scope.

## Runtime Architecture

### Session scanning

`CodexMonitor.psm1` will expose a scan-result boundary that contains discovered sessions and scan diagnostics. The existing session snapshot function will remain available as a compatibility wrapper for tests and callers.

Session metadata continues to come from the beginning of each active JSONL file. Token usage will be read backward from the end in fixed-size byte blocks. The reader will ignore a partially written final line and return the newest complete `event_msg/token_count` record. It opens files with read/write/delete sharing so Codex can continue appending or rotating logs.

The scan result records:

- scan completion time;
- number of candidate and successfully parsed sessions;
- count of metadata or token-read failures;
- a sanitized health summary without prompt, response, tool, credential, or source content.

### Since-launch token accounting

The application will maintain per-session token state keyed by session ID. When a session is first observed, its current counters become the baseline. Subsequent scans calculate non-negative deltas from that baseline. Existing tokens consumed before the monitor launched are therefore excluded.

Per-session state remains in memory after a session becomes inactive, so aggregate since-launch totals never decrease during a monitor run. Resumed sessions continue from their prior baseline. If counters unexpectedly move backward, the application preserves the already accumulated delta and starts a new baseline at the lower value.

The aggregate view sums all per-session deltas observed since launch. Workspace views sum the state associated with that workspace while it remains selectable. Active workspace and agent counts continue to reflect only sessions inside the configured inactivity window.

### Watcher health

Both the Codex session watcher and workspace filesystem watchers will subscribe to `Error` events. An internal buffer overflow increments a warning counter and records the most recent occurrence time. The five-second session recovery scan remains in place, but the UI will state when filesystem activity counters may have missed events because those counts cannot be reconstructed reliably.

Read and watcher failures do not terminate the dashboard. They produce a visible warning status while the last valid metrics remain displayed. A later successful scan clears transient read warnings; the dropped-event count remains visible for the lifetime of the monitor run.

## Dashboard Design

The compact terminal layout remains keyboard-first and compatible with Windows PowerShell 5.1 and PowerShell 7. The summary area will show:

```text
Active Workspaces: 2   Active Agents: 3   Uptime: 12m
Tokens Since Launch: 18.42k   Cached: 14.06k / 82.31%
Token Refresh: 14:32:08   Status: OK
```

When attention is required, the status line changes to a concise warning such as `Status: WARNING - 1 session read failed` or `Status: WARNING - filesystem events may have been dropped (1)`. Detailed session content and sensitive paths will not be included in diagnostics.

`N/A` remains reserved for data that has never been available. Temporarily idle workspaces no longer erase aggregate since-launch token totals.

## Visual Assets

The icon will be a deterministic, code-native mark: a dark charcoal rounded terminal tile, a cyan `>_` prompt, and a small green activity indicator. The source SVG will be committed alongside rendered PNG and Windows ICO variants. It will avoid external trademarks, gradients that disappear at small sizes, fine text, and unnecessary detail.

The obsolete screenshots will be deleted and replaced by:

1. an aggregate dashboard showing multiple synthetic workspaces, since-launch token metrics, refresh time, and healthy status;
2. a workspace activity view showing filesystem and Git metrics without personal paths or session content.

Screenshots will be captured from the actual v0.2.0 program using temporary synthetic session/workspace fixtures. They will be inspected for legibility, privacy, accurate labels, and absence of unrelated desktop content.

## Distribution and Local Synchronization

The repository will add a plain-text `VERSION` file containing `0.2.0`. README, changelog, design documentation, tests, and repository-contract checks will reference the new behavior and version. The release artifact will be named `codex-monitor-v0.2.0.zip` and contain the launcher, sources, version, license, security guidance, README, changelog, and required icon assets.

The verified release contents will be synchronized into `C:\Users\bgonn\Desktop\codex-watcher`. The existing `Start-Codex-Watcher.cmd` and shortcut remain usable as compatibility entry points that launch v0.2.0. The legacy watcher source will be retained unless it conflicts with launch behavior; release documentation will clearly identify the preferred entry point.

After fresh verification, the implementation will be committed to `main`, tagged `v0.2.0`, pushed to `BrennanNVA/codex-monitor`, and published as a GitHub release with the ZIP attached.

## Testing and Acceptance Criteria

Automated coverage will include:

- newest complete token record in a large JSONL file with a partial trailing line;
- multiple-session delta aggregation from launch baselines;
- stable totals after sessions become inactive;
- resumed sessions and counter rollback handling;
- scan diagnostics for malformed or unreadable token data;
- workspace and session watcher error accounting;
- existing discovery, aggregation, formatting, launcher, privacy, and repository-contract behavior;
- Windows PowerShell 5.1 and PowerShell 7 compatibility where locally available and in GitHub Actions.

Release acceptance requires:

- all Pester and repository-contract tests pass;
- the real dashboard starts and renders healthy since-launch metrics without stderr;
- large live session logs no longer stall refreshes;
- icon formats open correctly and retain readable small-size silhouettes;
- both screenshots are visually reviewed and contain only synthetic data;
- the release ZIP contents and archive integrity are verified;
- the Desktop installation launches through its existing shortcut/compatibility command;
- the GitHub default branch, tag, and release resolve to the verified commit.

## Privacy and Risk Controls

The monitor will continue reading only session ID, working directory, modification time, and token-count records. No telemetry or network transmission is added. Diagnostic messages are counts and sanitized categories, not record bodies or source content.

The principal compatibility risk is Codex JSONL schema drift. The parser remains isolated, fails closed, preserves last valid values, and surfaces a warning rather than silently appearing frozen. The release can be rolled back by using the prior `v0.1.1` commit or removing the local v0.2.0 files; no persistent data migration is introduced.
