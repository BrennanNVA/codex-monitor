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

function Fit-Text { param([string]$Text,[int]$Width) if ($Text.Length -le $Width) { return $Text }; if ($Width -le 3) { return $Text.Substring(0,$Width) }; return $Text.Substring(0,$Width-3)+'...' }
function Format-UiText {
    param([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray)
    if ($NoColor) { return $Text }
    $Code = switch ($Color.ToString()) {
        'Black' {'30'} 'DarkBlue' {'34'} 'DarkGreen' {'32'} 'DarkCyan' {'36'}
        'DarkRed' {'31'} 'DarkMagenta' {'35'} 'DarkYellow' {'33'} 'Gray' {'37'}
        'DarkGray' {'90'} 'Blue' {'94'} 'Green' {'92'} 'Cyan' {'96'}
        'Red' {'91'} 'Magenta' {'95'} 'Yellow' {'93'} 'White' {'97'}
        default {'37'}
    }
    $Escape = [char]27
    return "${Escape}[${Code}m${Text}${Escape}[0m"
}

function Show-Dashboard {
    param([object[]]$Workspaces)
    $Width=100; $Height=30; try { $Width=$Host.UI.RawUI.WindowSize.Width; $Height=$Host.UI.RawUI.WindowSize.Height } catch { }
    $LineWidth = [Math]::Max(1,$Width-1)
    $Lines = New-Object 'System.Collections.Generic.List[string]'
    $Ordered=@($Workspaces | Sort-Object Path); $Visible=@($Ordered | Select-Object -First 9)
    $Title = if ($null -eq $SelectedPath) { 'All Workspaces' } else { $SelectedPath }
    [void]$Lines.Add((Format-UiText 'CODEX MONITOR' Cyan))
    [void]$Lines.Add((Format-UiText (Fit-Text $Title $LineWidth) White))
    $AgentCount = [long](($Ordered | Measure-Object AgentCount -Sum).Sum)
    $Uptime = [Math]::Max(0, [int]([DateTime]::UtcNow - $StartedUtc).TotalMinutes)
    $ActivityText = "Active Workspaces: $($Ordered.Count)   Active Agents: $AgentCount   Uptime: ${Uptime}m"
    [void]$Lines.Add((Format-UiText (Fit-Text $ActivityText $LineWidth) DarkGray))

    $Targets = if ($null -eq $SelectedPath) { $Ordered } else { @($Ordered | Where-Object Path -eq $SelectedPath) }
    $Created=0;$Changed=0;$Deleted=0;$Renamed=0;$CodeIn=[long]0;$CodeOut=[long]0;$Commits=[long]0;$GitAvailable=$false
    foreach ($Workspace in $Targets) {
        $Monitor=$Monitors[$Workspace.Path]; if ($null -eq $Monitor) { continue }
        $Created += $Monitor.Counters.Created; $Changed += $Monitor.Counters.Changed; $Deleted += $Monitor.Counters.Deleted; $Renamed += $Monitor.Counters.Renamed
        if ($Monitor.Git.Available) { $GitAvailable=$true;$CodeIn += $Monitor.Git.CodeIn;$CodeOut += $Monitor.Git.CodeOut;$Commits += $Monitor.Git.Commits }
    }
    $ChangeLine = (Format-UiText "($Deleted) Deleted" Red) + (Format-UiText "   ($Changed) Changed" Yellow) + (Format-UiText "   ($Created) Created" Green) + (Format-UiText "   ($Renamed) Renamed" Magenta)
    [void]$Lines.Add($ChangeLine)
    if ($GitAvailable) {
        $GitLine = (Format-UiText "+ ($($CodeIn.ToString('N0')))" Green) + (Format-UiText "   - ($($CodeOut.ToString('N0')))" Red) + (Format-UiText "   ($Commits) Git Commits" Cyan)
    } else { $GitLine = Format-UiText '+ (N/A)   - (N/A)   (N/A) Git Commits' DarkGray }
    [void]$Lines.Add($GitLine)
    $TokenTotals = if ($null -eq $SelectedPath) { Get-SinceLaunchTokenTotals -State $SessionTokenState } else { Get-SinceLaunchTokenTotals -State $SessionTokenState -Workspace $SelectedPath }
    if ($TokenTotals.HasTokenUsage) { $TokenText = "Tokens Since Launch: $(Format-CompactNumber $TokenTotals.TokensUsed)   Cached: $(Format-CompactNumber $TokenTotals.TokensCached) / $(Format-CacheRate $TokenTotals.TokensCached $TokenTotals.InputTokens)"; $TokenColor = [ConsoleColor]::Cyan } else { $TokenText = 'Tokens Since Launch: N/A   Cached: N/A / N/A'; $TokenColor = [ConsoleColor]::DarkGray }
    [void]$Lines.Add((Format-UiText (Fit-Text $TokenText $LineWidth) $TokenColor))
    $RefreshText = if ($MonitorHealth.LastRefreshUtc -eq [DateTime]::MinValue) { 'Never' } else { $MonitorHealth.LastRefreshUtc.ToLocalTime().ToString('HH:mm:ss') }
    $Warnings = New-Object System.Collections.ArrayList
    if ($MonitorHealth.ReadErrorCount -gt 0) { [void]$Warnings.Add("$($MonitorHealth.ReadErrorCount) session read failure(s)") }
    if ($MonitorHealth.DroppedEventCount -gt 0) { [void]$Warnings.Add("filesystem events may have been dropped ($($MonitorHealth.DroppedEventCount))") }
    if ($Warnings.Count -eq 0) { $StatusText = "Token Refresh: $RefreshText   Status: OK"; $StatusColor = [ConsoleColor]::Green } else { $StatusText = "Token Refresh: $RefreshText   Status: WARNING - $($Warnings -join '; ')"; $StatusColor = [ConsoleColor]::Yellow }
    [void]$Lines.Add((Format-UiText (Fit-Text $StatusText $LineWidth) $StatusColor))
    [void]$Lines.Add((Format-UiText ('-' * [Math]::Max(20,[Math]::Min(100,$Width-1))) DarkGray))

    if ($null -eq $SelectedPath) {
        if ($Visible.Count -eq 0) { [void]$Lines.Add((Format-UiText (Fit-Text "Waiting for active Codex CLI sessions in $ResolvedHome ..." $LineWidth) DarkGray)) }
        for ($i=0;$i -lt $Visible.Count;$i++) { $W=$Visible[$i]; $Age=[Math]::Max(0,[int]([DateTime]::UtcNow-$W.LastActivityUtc).TotalSeconds); $WorkspaceText=Fit-Text "$($W.Path)   $($W.AgentCount) agent(s)   ${Age}s ago" ([Math]::Max(1,$Width-13)); [void]$Lines.Add((Format-UiText "[$($i+1)] ACTIVE  " Green) + $WorkspaceText) }
    } else {
        $Monitor=$Monitors[$SelectedPath]; if ($null -ne $Monitor) { $Rows=[Math]::Max(1,$Height-12); $Start=[Math]::Max(0,$Monitor.EventHistory.Count-$Rows); for ($i=$Start;$i -lt $Monitor.EventHistory.Count;$i++) { [void]$Lines.Add((Fit-Text $Monitor.EventHistory[$i].Text $LineWidth)) } }
    }
    [void]$Lines.Add('')
    [void]$Lines.Add((Format-UiText '[1-9] View Workspace   [A] View All   [Q] Quit' White))

    $Frame = Format-ConsoleFrame -Lines @($Lines)
    try { [Console]::SetCursorPosition(0, 0) } catch { }
    [Console]::Write($Frame)
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
