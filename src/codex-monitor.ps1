[CmdletBinding()]
param(
    [switch]$NoColor,
    [ValidateRange(30,3600)][int]$InactiveSeconds = 120,
    [string]$CodexHome
)

Import-Module (Join-Path $PSScriptRoot 'CodexMonitor.psm1') -Force
$ResolvedHome = Resolve-CodexHome -ExplicitPath $CodexHome
$Monitors = @{}; $SelectedPath = $null; $Running = $true; $LastRender = [DateTime]::MinValue
$Workspaces = @(); $SessionWatcher = $null; $SessionEventPrefix = 'CodexMonitorSessions'
$SessionRoot = Join-Path $ResolvedHome 'sessions'
$DiscoveryDirty = $true; $DiscoveryDirtySinceUtc = [DateTime]::MinValue
$LiveDebounce = [TimeSpan]::FromMilliseconds(100)
$RecoveryInterval = [TimeSpan]::FromSeconds(5)
$LastRecoveryUtc = [DateTime]::MinValue; $RenderDirty = $true
$StartedUtc = [DateTime]::UtcNow; $SessionTokenState = @{}; $MonitorHealth = New-MonitorHealth
$Host.UI.RawUI.WindowTitle = 'Codex Monitor'
Clear-Host

function Write-Ui { param([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray,[switch]$NoNewline) if ($NoColor) { Write-Host $Text -NoNewline:$NoNewline } else { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline } }
function Fit-Text { param([string]$Text,[int]$Width) if ($Text.Length -le $Width) { return $Text }; if ($Width -le 3) { return $Text.Substring(0,$Width) }; return $Text.Substring(0,$Width-3)+'...' }

function Show-Dashboard {
    param([object[]]$Workspaces)
    try {
        [Console]::SetCursorPosition(0, 0)
    }
    catch {
        # Non-interactive hosts may not expose a movable console cursor.
    }
    [Console]::Write("$([char]27)[0J")
    $Width=100; $Height=30; try { $Width=$Host.UI.RawUI.WindowSize.Width; $Height=$Host.UI.RawUI.WindowSize.Height } catch { }
    $Ordered=@($Workspaces | Sort-Object Path); $Visible=@($Ordered | Select-Object -First 9)
    $Title = if ($null -eq $SelectedPath) { 'All Workspaces' } else { $SelectedPath }
    Write-Ui 'CODEX MONITOR' Cyan; Write-Host; Write-Ui $Title White; Write-Host
    $AgentCount = [long](($Ordered | Measure-Object AgentCount -Sum).Sum)
    $Uptime = [Math]::Max(0, [int]([DateTime]::UtcNow - $StartedUtc).TotalMinutes)
    Write-Ui "Active Workspaces: $($Ordered.Count)   Active Agents: $AgentCount   Uptime: ${Uptime}m" DarkGray; Write-Host

    $Targets = if ($null -eq $SelectedPath) { $Ordered } else { @($Ordered | Where-Object Path -eq $SelectedPath) }
    $Created=0;$Changed=0;$Deleted=0;$Renamed=0;$CodeIn=[long]0;$CodeOut=[long]0;$Commits=[long]0;$GitAvailable=$false
    foreach ($Workspace in $Targets) {
        $Monitor=$Monitors[$Workspace.Path]; if ($null -eq $Monitor) { continue }
        $Created += $Monitor.Counters.Created; $Changed += $Monitor.Counters.Changed; $Deleted += $Monitor.Counters.Deleted; $Renamed += $Monitor.Counters.Renamed
        if ($Monitor.Git.Available) { $GitAvailable=$true;$CodeIn += $Monitor.Git.CodeIn;$CodeOut += $Monitor.Git.CodeOut;$Commits += $Monitor.Git.Commits }
    }
    Write-Ui "($Deleted) Deleted" Red -NoNewline; Write-Ui "   ($Changed) Changed" Yellow -NoNewline; Write-Ui "   ($Created) Created" Green -NoNewline; Write-Ui "   ($Renamed) Renamed" Magenta; Write-Host
    if ($GitAvailable) { Write-Ui "+ ($($CodeIn.ToString('N0')))" Green -NoNewline; Write-Ui "   - ($($CodeOut.ToString('N0')))" Red -NoNewline; Write-Ui "   ($Commits) Git Commits" Cyan } else { Write-Ui '+ (N/A)   - (N/A)   (N/A) Git Commits' DarkGray }; Write-Host
    $TokenTotals = if ($null -eq $SelectedPath) { Get-SinceLaunchTokenTotals -State $SessionTokenState } else { Get-SinceLaunchTokenTotals -State $SessionTokenState -Workspace $SelectedPath }
    if ($TokenTotals.HasTokenUsage) { Write-Ui "Tokens Since Launch: $(Format-CompactNumber $TokenTotals.TokensUsed)   Cached: $(Format-CompactNumber $TokenTotals.TokensCached) / $(Format-CacheRate $TokenTotals.TokensCached $TokenTotals.InputTokens)" Cyan } else { Write-Ui 'Tokens Since Launch: N/A   Cached: N/A / N/A' DarkGray }; Write-Host
    $RefreshText = if ($MonitorHealth.LastRefreshUtc -eq [DateTime]::MinValue) { 'Never' } else { $MonitorHealth.LastRefreshUtc.ToLocalTime().ToString('HH:mm:ss') }
    $Warnings = New-Object System.Collections.ArrayList
    if ($MonitorHealth.ReadErrorCount -gt 0) { [void]$Warnings.Add("$($MonitorHealth.ReadErrorCount) session read failure(s)") }
    if ($MonitorHealth.DroppedEventCount -gt 0) { [void]$Warnings.Add("filesystem events may have been dropped ($($MonitorHealth.DroppedEventCount))") }
    if ($Warnings.Count -eq 0) { Write-Ui "Token Refresh: $RefreshText   Status: OK" Green } else { Write-Ui "Token Refresh: $RefreshText   Status: WARNING - $($Warnings -join '; ')" Yellow }; Write-Host
    Write-Ui ('-' * [Math]::Max(20,[Math]::Min(100,$Width-1))) DarkGray; Write-Host

    if ($null -eq $SelectedPath) {
        if ($Visible.Count -eq 0) { Write-Ui "Waiting for active Codex CLI sessions in $ResolvedHome ..." DarkGray; Write-Host }
        for ($i=0;$i -lt $Visible.Count;$i++) { $W=$Visible[$i]; $Age=[Math]::Max(0,[int]([DateTime]::UtcNow-$W.LastActivityUtc).TotalSeconds); Write-Ui "[$($i+1)] ACTIVE  " Green -NoNewline; Write-Host (Fit-Text "$($W.Path)   $($W.AgentCount) agent(s)   ${Age}s ago" ($Width-13)) }
    } else {
        $Monitor=$Monitors[$SelectedPath]; if ($null -ne $Monitor) { $Rows=[Math]::Max(1,$Height-12); $Start=[Math]::Max(0,$Monitor.EventHistory.Count-$Rows); for ($i=$Start;$i -lt $Monitor.EventHistory.Count;$i++) { Write-Host (Fit-Text $Monitor.EventHistory[$i].Text ($Width-1)) } }
    }
    Write-Host; Write-Ui '[1-9] View Workspace   [A] View All   [Q] Quit' White; Write-Host
}

try {
    try { [Console]::CursorVisible = $false } catch { }
    while ($Running) {
        $NowUtc = [DateTime]::UtcNow

        if ($null -eq $SessionWatcher -and (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
            $SessionWatcher = New-Object System.IO.FileSystemWatcher
            $SessionWatcher.Path = $SessionRoot; $SessionWatcher.Filter = '*.jsonl'; $SessionWatcher.IncludeSubdirectories = $true
            $SessionWatcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
            foreach ($EventName in @('Created','Changed','Renamed','Error')) { Register-ObjectEvent -InputObject $SessionWatcher -EventName $EventName -SourceIdentifier "$SessionEventPrefix.$EventName" | Out-Null }
            $SessionWatcher.EnableRaisingEvents = $true
            $DiscoveryDirty = $true; $DiscoveryDirtySinceUtc = $NowUtc
        }

        $SessionEvents = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$SessionEventPrefix.*" })
        foreach ($SessionEvent in $SessionEvents) {
            if ($SessionEvent.SourceIdentifier -eq "$SessionEventPrefix.Error") {
                Add-MonitorWatcherError -Health $MonitorHealth -OccurredUtc $NowUtc
                $RenderDirty = $true
            }
            elseif (-not $DiscoveryDirty) {
                $DiscoveryDirty = $true; $DiscoveryDirtySinceUtc = $NowUtc
            }
            Remove-Event -EventIdentifier $SessionEvent.EventIdentifier -ErrorAction SilentlyContinue
        }

        if (($DiscoveryDirty -and ($NowUtc - $DiscoveryDirtySinceUtc) -ge $LiveDebounce) -or
            (($NowUtc - $LastRecoveryUtc) -ge $RecoveryInterval)) {
            $Scan = Get-CodexSessionScan -CodexHome $ResolvedHome -ActiveWithin ([TimeSpan]::FromSeconds($InactiveSeconds))
            $Sessions = @($Scan.Sessions)
            Update-MonitorHealthFromScan -Health $MonitorHealth -Scan $Scan
            Update-SessionTokenState -State $SessionTokenState -Sessions $Sessions
            $Workspaces = @(Get-ActiveWorkspaceSnapshot -Sessions $Sessions)
            $Active=@{}; foreach ($W in $Workspaces) { $Active[$W.Path]=$true; if (-not $Monitors.ContainsKey($W.Path)) { $Monitors[$W.Path]=New-WorkspaceMonitor -Path $W.Path } }
            foreach ($Path in @($Monitors.Keys)) { if (-not $Active.ContainsKey($Path)) { Remove-WorkspaceMonitor $Monitors[$Path]; $Monitors.Remove($Path); if ($SelectedPath -eq $Path) { $SelectedPath=$null } } }
            $DiscoveryDirty = $false; $LastRecoveryUtc = $NowUtc; $RenderDirty = $true
        }
        foreach ($Monitor in @($Monitors.Values)) {
            $AcceptedEvents = Receive-WorkspaceEvents -Monitor $Monitor -Health $MonitorHealth
            if ($AcceptedEvents -gt 0 -or ($NowUtc - $Monitor.LastGitRefreshUtc).TotalSeconds -ge 5) {
                Update-WorkspaceGitMetrics $Monitor
                $RenderDirty = $true
            }
        }
        if ($RenderDirty -and ([DateTime]::UtcNow-$LastRender).TotalMilliseconds -ge 100) { Show-Dashboard $Workspaces; $LastRender=[DateTime]::UtcNow; $RenderDirty=$false }
        try {
            if ([Console]::KeyAvailable) {
                $Key=[Console]::ReadKey($true)
                if ($Key.KeyChar -match '^[qQ]$') { $Running=$false }
                elseif ($Key.KeyChar -match '^[aA]$') { $SelectedPath=$null; $RenderDirty=$true }
                elseif ($Key.KeyChar -match '^[1-9]$') { $Index=[int]::Parse($Key.KeyChar.ToString())-1; $List=@($Workspaces|Sort-Object Path|Select-Object -First 9); if ($Index -lt $List.Count) { $SelectedPath=$List[$Index].Path; $RenderDirty=$true } }
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    }
} finally {
    foreach ($Monitor in @($Monitors.Values)) { Remove-WorkspaceMonitor $Monitor }
    Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$SessionEventPrefix.*" } | Unregister-Event -Force -ErrorAction SilentlyContinue
    Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$SessionEventPrefix.*" } | Remove-Event -ErrorAction SilentlyContinue
    if ($null -ne $SessionWatcher) { $SessionWatcher.EnableRaisingEvents=$false; $SessionWatcher.Dispose() }
    try { [Console]::CursorVisible = $true } catch { }
}
