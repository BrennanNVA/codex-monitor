# Codex Monitor v0.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Codex Monitor v0.2.0 with non-blocking token reads, stable since-launch metrics, visible operational health, refreshed assets and documentation, a synchronized local installation, and a verified GitHub release.

**Architecture:** Keep JSONL parsing, token-state accounting, watcher health, and metric formatting in `src/CodexMonitor.psm1`; keep the interactive loop and rendering in `src/codex-monitor.ps1`. Add deterministic assets and release metadata at repository level, then build and verify a ZIP from the same committed files synchronized to `Desktop\codex-watcher`.

**Tech Stack:** Windows PowerShell 5.1-compatible PowerShell, .NET `FileStream` and `FileSystemWatcher`, Pester 5, Bash repository-contract checks, SVG, PNG, ICO, Git, GitHub CLI.

## Global Constraints

- Support Windows 10/11, Windows PowerShell 5.1, and PowerShell 7.
- Do not parse, display, log, or transmit prompts, responses, tool arguments, credentials, or source-file contents.
- Preserve event-driven refresh with a five-second recovery scan and approximately 100 ms display latency.
- Aggregate token deltas only from the moment the monitor first observes each session during the current process.
- Never decrease aggregate since-launch totals when a session becomes inactive or its upstream counters reset.
- Preserve keyboard controls `1-9`, `A`, and `Q`, plus `-NoColor`.
- Publish version `0.2.0` and tag `v0.2.0`.
- Keep `Start-Codex-Watcher.cmd` and its shortcut usable in `Desktop\codex-watcher`.

## File Structure

- `src/CodexMonitor.psm1`: reverse JSONL reader, scan result, token-state accounting, watcher-health helpers, workspace monitoring, formatting.
- `src/codex-monitor.ps1`: application state, watcher event consumption, health updates, dashboard rendering, keyboard loop.
- `tests/CodexMonitor.Tests.ps1`: focused Pester behavior and regression tests.
- `tests/test_repository_contract.sh`: repository, version, asset, documentation, and launcher contract.
- `assets/codex-monitor.svg`: canonical deterministic icon source.
- `assets/codex-monitor.png`: rendered application icon.
- `assets/codex-monitor.ico`: Windows multi-size application icon.
- `assets/codex-monitor-overview.png`: replacement aggregate-view screenshot.
- `assets/codex-monitor-workspace.png`: replacement workspace-view screenshot.
- `VERSION`, `README.md`, `CHANGELOG.md`, `docs/design.md`: release metadata and user-facing behavior.
- `dist/codex-monitor-v0.2.0.zip`: verified release archive, excluded from normal source history if required by `.gitignore` and attached to the GitHub release.

---

### Task 1: Efficient token record reading and scan diagnostics

**Files:**
- Modify: `tests/CodexMonitor.Tests.ps1`
- Modify: `src/CodexMonitor.psm1`

**Interfaces:**
- Produces: `Get-LatestTokenUsage -Path <string>` returning the newest complete `total_token_usage` object or `$null`.
- Produces: `Get-CodexSessionScan -CodexHome <string> -NowUtc <DateTime> -ActiveWithin <TimeSpan>` returning `{ Sessions, CompletedUtc, CandidateCount, ReadErrorCount }`.
- Preserves: `Get-CodexSessionSnapshot` as a compatibility wrapper returning only the scan's sessions.

- [ ] **Step 1: Add a failing large-log regression test**

Add a Pester fixture containing about 20 MB of irrelevant JSONL records, a complete token-count record, and a partial trailing record. Assert that `Get-LatestTokenUsage` returns `total_tokens = 7000` in less than two seconds.

```powershell
$Stopwatch = [Diagnostics.Stopwatch]::StartNew()
$Usage = Get-LatestTokenUsage -Path $LargeSessionFile
$Stopwatch.Stop()
$Usage.total_tokens | Should -Be 7000
$Stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
Invoke-Pester .\tests\CodexMonitor.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Get-LatestTokenUsage` is not exported or defined.

- [ ] **Step 3: Implement the reverse reader**

Read the file backward in 65,536-byte blocks using `FileShare.ReadWrite -bor FileShare.Delete`, assemble bytes until a newline, decode UTF-8 only after restoring byte order, ignore incomplete JSON, and stop at the newest valid `event_msg/token_count` record.

```powershell
function Get-LatestTokenUsage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Open shared FileStream, scan backward by blocks, return total_token_usage.
}
```

- [ ] **Step 4: Add scan-result diagnostics tests**

Assert that a normal fixture reports one candidate, one session, and zero read errors; assert that malformed metadata increments `ReadErrorCount` without emitting record contents.

- [ ] **Step 5: Implement `Get-CodexSessionScan` and wrapper compatibility**

Move session discovery into the scan-result function and implement the wrapper exactly as:

```powershell
function Get-CodexSessionSnapshot {
    [CmdletBinding()]
    param(
        [string]$CodexHome = (Resolve-CodexHome),
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [TimeSpan]$ActiveWithin = [TimeSpan]::FromMinutes(2)
    )
    return @((Get-CodexSessionScan -CodexHome $CodexHome -NowUtc $NowUtc -ActiveWithin $ActiveWithin).Sessions)
}
```

- [ ] **Step 6: Run Pester and commit**

Run Pester and expect all tests to pass, then commit:

```powershell
git add src/CodexMonitor.psm1 tests/CodexMonitor.Tests.ps1
git commit -m "fix: read large Codex session logs efficiently"
```

---

### Task 2: Stable since-launch token accounting

**Files:**
- Modify: `tests/CodexMonitor.Tests.ps1`
- Modify: `src/CodexMonitor.psm1`

**Interfaces:**
- Consumes: session objects from `Get-CodexSessionScan` containing `SessionId`, `Workspace`, `TokensUsed`, `InputTokens`, and `TokensCached`.
- Produces: `Update-SessionTokenState -State <hashtable> -Sessions <object[]>` mutating persistent per-session state.
- Produces: `Get-SinceLaunchTokenTotals -State <hashtable> [-Workspace <string>]` returning `{ TokensUsed, InputTokens, TokensCached, HasTokenUsage }`.

- [ ] **Step 1: Add failing token-state tests**

Cover first observation as a zero baseline, positive deltas on a later scan, aggregation across two sessions, totals retained when the active session array becomes empty, resumed growth, workspace filtering, and upstream counter rollback without negative totals.

```powershell
$State = @{}
Update-SessionTokenState -State $State -Sessions @($FirstObservation)
(Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 0
Update-SessionTokenState -State $State -Sessions @($LaterObservation)
(Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 250
```

- [ ] **Step 2: Run the focused tests and verify RED**

Expected: FAIL because the state functions are absent.

- [ ] **Step 3: Implement incremental state accounting**

For each known session store `Workspace`, last upstream counters, accumulated deltas, and `IsActive`. First observation sets last counters with zero accumulated values. Later observations add `max(0, current - last)` for each counter and replace last counters even after rollback.

- [ ] **Step 4: Export functions, run all Pester tests, and commit**

```powershell
git add src/CodexMonitor.psm1 tests/CodexMonitor.Tests.ps1
git commit -m "feat: track token usage since monitor launch"
```

---

### Task 3: Watcher health and dashboard status

**Files:**
- Modify: `tests/CodexMonitor.Tests.ps1`
- Modify: `tests/test_repository_contract.sh`
- Modify: `src/CodexMonitor.psm1`
- Modify: `src/codex-monitor.ps1`

**Interfaces:**
- Produces: `New-MonitorHealth` returning `{ LastRefreshUtc, ReadErrorCount, DroppedEventCount, LastWatcherErrorUtc }`.
- Produces: `Update-MonitorHealthFromScan -Health <object> -Scan <object>`.
- Produces: `Add-MonitorWatcherError -Health <object>` incrementing persistent dropped-event state.
- Extends: workspace monitor objects with `Health` and an `.Error` event source.

- [ ] **Step 1: Add failing health-state tests**

Assert that successful scans update refresh time and clear transient read errors, failed scans set read-error count, and watcher errors increment without later reset.

- [ ] **Step 2: Add failing repository-contract assertions**

Require `Tokens Since Launch`, `Token Refresh`, `Status:`, watcher `Error` registration, `VERSION`, and all three icon formats.

- [ ] **Step 3: Run Pester and contract tests to verify RED**

Run:

```powershell
Invoke-Pester .\tests\CodexMonitor.Tests.ps1 -Output Detailed
bash .\tests\test_repository_contract.sh
```

Expected: both suites fail on missing health/UI/version assets.

- [ ] **Step 4: Implement health helpers and error subscriptions**

Register `Error` alongside normal session and workspace watcher events. Consume error events without exposing exception text, update health, remove each queued event, and preserve the recovery scan.

- [ ] **Step 5: Wire since-launch totals and health into the dashboard**

Keep `$SessionTokenState` and `$MonitorHealth` for the application lifetime. After every scan, update both objects. Render active counts separately from `Tokens Since Launch`, cached totals/rate, `Token Refresh`, uptime, and either `Status: OK` or a sanitized warning count.

- [ ] **Step 6: Verify interactive startup and commit**

Launch the script with a temporary synthetic `-CodexHome`, confirm it stays alive and writes no stderr, then commit:

```powershell
git add src/CodexMonitor.psm1 src/codex-monitor.ps1 tests/CodexMonitor.Tests.ps1 tests/test_repository_contract.sh
git commit -m "feat: surface monitor refresh and watcher health"
```

---

### Task 4: Version, icon, documentation, and replacement screenshots

**Files:**
- Create: `VERSION`
- Create: `assets/codex-monitor.svg`
- Create: `assets/codex-monitor.png`
- Create: `assets/codex-monitor.ico`
- Create: `assets/codex-monitor-overview.png`
- Create: `assets/codex-monitor-workspace.png`
- Delete: `assets/codex-monitor-preview.png`
- Delete: `assets/codex-monitor-token-preview.png`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/design.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: final dashboard labels and behavior from Task 3.
- Produces: privacy-safe public assets and v0.2.0 documentation.

- [ ] **Step 1: Add `VERSION` and deterministic icon source**

Set `VERSION` to exactly `0.2.0`. Draw a 512×512 rounded charcoal terminal tile in SVG with a cyan `>_` prompt and green activity dot; include no third-party marks or fonts.

- [ ] **Step 2: Render and validate PNG/ICO icon formats**

Render a 512×512 RGBA PNG and a multi-size ICO containing 16, 24, 32, 48, 64, 128, and 256 pixel frames. Validate dimensions, alpha, and ICO frame sizes with an image inspection command.

- [ ] **Step 3: Capture two actual privacy-safe screenshots**

Create temporary synthetic session and workspace fixtures, launch the real v0.2.0 dashboard, and capture only the terminal window. Save aggregate and workspace views under their new names. Verify that no personal username, prompt, response, tool argument, credential, or unrelated desktop content appears.

- [ ] **Step 4: Remove obsolete screenshots and update documentation**

Replace README image links, document since-launch semantics, status warnings, icon files, version, installation, privacy, and limitations. Add a dated v0.2.0 changelog section and reconcile `docs/design.md` with implemented behavior.

- [ ] **Step 5: Run contract tests and commit**

```powershell
git add VERSION README.md CHANGELOG.md docs/design.md .gitignore assets tests/test_repository_contract.sh
git commit -m "docs: prepare Codex Monitor v0.2.0"
```

---

### Task 5: Package and synchronize the local installation

**Files:**
- Create during packaging: `dist/codex-monitor-v0.2.0.zip`
- Synchronize: `C:\Users\bgonn\Desktop\codex-watcher\README.md`
- Synchronize: `C:\Users\bgonn\Desktop\codex-watcher\VERSION`
- Synchronize: release launcher, sources, icon assets, changelog, license, and security guidance.
- Modify: `C:\Users\bgonn\Desktop\codex-watcher\Start-Codex-Watcher.cmd`

**Interfaces:**
- Consumes: verified repository files from Tasks 1–4.
- Produces: release ZIP and a locally runnable v0.2.0 installation.

- [ ] **Step 1: Assemble release staging contents**

Include `Start-Codex-Monitor.cmd`, `src`, `assets/codex-monitor.{svg,png,ico}`, `README.md`, `CHANGELOG.md`, `VERSION`, `LICENSE`, and `SECURITY.md`. Exclude `.git`, tests, design artifacts, screenshots, and temporary fixture data from the ZIP.

- [ ] **Step 2: Build and inspect the ZIP**

Create `dist/codex-monitor-v0.2.0.zip`, list every archive entry, extract it into a fresh temporary directory, and run its launcher target directly long enough to confirm startup without stderr.

- [ ] **Step 3: Synchronize `Desktop\codex-watcher`**

Copy verified release files into the local folder. Rewrite `Start-Codex-Watcher.cmd` as a compatibility launcher that delegates to `Start-Codex-Monitor.cmd %*`; retain the existing `.lnk` target and legacy PowerShell file.

- [ ] **Step 4: Verify local shortcut and version**

Resolve the `.lnk` target, confirm the target exists, launch through the compatibility command, and assert local `VERSION` and README both state `0.2.0`.

---

### Task 6: Final verification, publication, and release audit

**Files:**
- Verify all tracked release files and `dist/codex-monitor-v0.2.0.zip`.

**Interfaces:**
- Produces: pushed `main`, tag `v0.2.0`, and GitHub release with the verified ZIP asset.

- [ ] **Step 1: Run the complete fresh verification suite**

Run Pester under Windows PowerShell 5.1 and PowerShell 7 when available, run the Bash repository contract, parse both PowerShell source files, validate image formats, inspect the ZIP, and smoke-test repository and Desktop launchers.

- [ ] **Step 2: Review scope and working tree**

Check `git diff --check`, inspect the full diff and deleted assets, confirm no secrets or personal fixture paths are present, and ensure only intended files are staged.

- [ ] **Step 3: Commit any final packaging metadata**

If packaging metadata changed after Task 4, commit only those files with:

```powershell
git commit -m "build: package Codex Monitor v0.2.0"
```

- [ ] **Step 4: Push main and publish the release**

```powershell
git push origin main
git tag -a v0.2.0 -m "Codex Monitor v0.2.0"
git push origin v0.2.0
gh release create v0.2.0 dist/codex-monitor-v0.2.0.zip --repo BrennanNVA/codex-monitor --title "Codex Monitor v0.2.0" --notes-file <release-notes-file>
```

- [ ] **Step 5: Audit published state**

Verify the remote default branch SHA equals local `HEAD`, the tag resolves to that commit, the GitHub release is published, and the ZIP asset is downloadable with the expected size and name.
