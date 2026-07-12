# Codex Monitor v0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitHub-ready Windows Codex CLI monitoring dashboard with automatic multi-workspace discovery.

**Architecture:** `CodexMonitor.psm1` contains discovery, lifecycle, metric, watcher, and rendering functions. `codex-monitor.ps1` owns the interactive loop and keyboard controls. A CMD file launches the program without changing the user's execution policy.

**Tech Stack:** Windows PowerShell 5.1-compatible PowerShell, .NET FileSystemWatcher, Git CLI, Pester 5, GitHub Actions.

## Global Constraints

- Windows 10/11 and PowerShell 5.1/7.
- Two-minute workspace inactivity grace period.
- Controls limited to 1-9, A, and Q.
- No source, prompt, response, tool argument, or credential display.
- No permanent execution-policy changes.

---

### Task 1: Repository contract

**Files:** Create `tests/test_repository_contract.sh`, then create the repository files it asserts.

- [ ] Write checks for launchers, sources, discovery, lifecycle, controls, accessibility, documentation, license, and CI.
- [ ] Run `bash tests/test_repository_contract.sh`; expect failure because sources are absent.
- [ ] Add the minimal repository structure and rerun until the contract passes.

### Task 2: Discovery and lifecycle module

**Files:** Create `src/CodexMonitor.psm1` and `tests/CodexMonitor.Tests.ps1`.

- [ ] Write Pester tests with temporary JSONL fixtures for `$CODEX_HOME`, workspace grouping, token extraction, two-minute expiration, and resumed activity.
- [ ] Implement `Resolve-CodexHome`, `Get-CodexSessionSnapshot`, and `Get-ActiveWorkspaceSnapshot`.
- [ ] Verify the module imports and Pester tests pass on Windows PowerShell and PowerShell 7 in CI.

### Task 3: Metrics and event monitoring

**Files:** Extend `src/CodexMonitor.psm1` and `tests/CodexMonitor.Tests.ps1`.

- [ ] Test Git-unavailable fallbacks, metric formatting, event counters, and watcher cleanup.
- [ ] Implement Git baselines, filesystem watcher registration, token aggregation, and `N/A` fallbacks.
- [ ] Verify all Pester tests pass.

### Task 4: Accessible interactive dashboard

**Files:** Create `src/codex-monitor.ps1` and `Start-Codex-Monitor.cmd`.

- [ ] Implement stable aggregate/workspace rendering, `-NoColor`, responsive truncation, and 1-9/A/Q controls.
- [ ] Ensure discovery and metric refresh remain automatic regardless of selected view.
- [ ] Run the contract and Pester suites.

### Task 5: Community packaging

**Files:** Create `README.md`, `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, and `.github/workflows/test.yml`.

- [ ] Document installation, privacy, metrics, limitations, accessibility, and contribution steps.
- [ ] Add Windows PowerShell 5.1 and PowerShell 7 test jobs.
- [ ] Build a release ZIP and verify its contents and archive integrity.

