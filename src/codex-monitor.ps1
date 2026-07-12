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
    $Width=100; $Height=30; try { $Width=$Host.UI.RawUI.WindowSize.Width; $Height=$Host.UI.RawUI.WindowSize.Height } catch { }
    $Ordered=@($Workspaces | Sort-Object Path); $Visible=@($Ordered | Select-Object -First 9)
    $Title = if ($null -eq $SelectedPath) { 'All Workspaces' } else { $SelectedPath }
    Write-Ui 'CODEX MONITOR' Cyan; Write-Host; Write-Ui $Title White; Write-Host
    Write-Ui "Active Workspaces: $($Ordered.Count)   Active Agents: $(($Ordered | Measure-Object AgentCount -Sum).Sum)" DarkGray; Write-Host

    $Targets = if ($null -eq $SelectedPath) { $Ordered } else { @($Ordered | Where-Object Path -eq $SelectedPath) }
    $Created=0;$Changed=0;$Deleted=0;$Renamed=0;$CodeIn=[long]0;$CodeOut=[long]0;$Commits=[long]0;$GitAvailable=$false;$Tokens=[long]0;$InputTokens=[long]0;$Cached=[long]0;$TokenAvailable=$false
    foreach ($Workspace in $Targets) {
        $Monitor=$Monitors[$Workspace.Path]; if ($null -eq $Monitor) { continue }
        $Created += $Monitor.Counters.Created; $Changed += $Monitor.Counters.Changed; $Deleted += $Monitor.Counters.Deleted; $Renamed += $Monitor.Counters.Renamed
        if ($Monitor.Git.Available) { $GitAvailable=$true;$CodeIn += $Monitor.Git.CodeIn;$CodeOut += $Monitor.Git.CodeOut;$Commits += $Monitor.Git.Commits }
        if ($Workspace.HasTokenUsage) { $TokenAvailable=$true;$Tokens += $Workspace.TokensUsed;$InputTokens += $Workspace.InputTokens;$Cached += $Workspace.TokensCached }
    }
    Write-Ui "($Deleted) Deleted" Red -NoNewline; Write-Ui "   ($Changed) Changed" Yellow -NoNewline; Write-Ui "   ($Created) Created" Green -NoNewline; Write-Ui "   ($Renamed) Renamed" Magenta; Write-Host
    if ($GitAvailable) { Write-Ui "+ ($($CodeIn.ToString('N0')))" Green -NoNewline; Write-Ui "   - ($($CodeOut.ToString('N0')))" Red -NoNewline; Write-Ui "   ($Commits) Git Commits" Cyan } else { Write-Ui '+ (N/A)   - (N/A)   (N/A) Git Commits' DarkGray }; Write-Host
    if ($TokenAvailable) { Write-Ui "($(Format-CompactNumber $Tokens)) Tokens Used   ($(Format-CompactNumber $Cached) / $(Format-CacheRate $Cached $InputTokens)) Tokens Cached" Cyan } else { Write-Ui '(N/A) Tokens Used   (N/A / N/A) Tokens Cached' DarkGray }; Write-Host
    Write-Ui ('-' * [Math]::Max(20,[Math]::Min(100,$Width-1))) DarkGray; Write-Host

    if ($null -eq $SelectedPath) {
        if ($Visible.Count -eq 0) { Write-Ui "Waiting for active Codex CLI sessions in $ResolvedHome ..." DarkGray; Write-Host }
        for ($i=0;$i -lt $Visible.Count;$i++) { $W=$Visible[$i]; $Age=[Math]::Max(0,[int]([DateTime]::UtcNow-$W.LastActivityUtc).TotalSeconds); Write-Ui "[$($i+1)] ACTIVE  " Green -NoNewline; Write-Host (Fit-Text "$($W.Path)   $($W.AgentCount) agent(s)   ${Age}s ago" ($Width-13)) }
    } else {
        $Monitor=$Monitors[$SelectedPath]; if ($null -ne $Monitor) { $Rows=[Math]::Max(1,$Height-12); $Start=[Math]::Max(0,$Monitor.EventHistory.Count-$Rows); for ($i=$Start;$i -lt $Monitor.EventHistory.Count;$i++) { Write-Host (Fit-Text $Monitor.EventHistory[$i].Text ($Width-1)) } }
    }
    Write-Host; Write-Ui '[1-9] View Workspace   [A] View All   [Q] Quit' White; Write-Host
    [Console]::Write("$([char]27)[0J")
}

try {
    try { [Console]::CursorVisible = $false } catch { }
    while ($Running) {
        $NowUtc = [DateTime]::UtcNow

        if ($null -eq $SessionWatcher -and (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
            $SessionWatcher = New-Object System.IO.FileSystemWatcher
            $SessionWatcher.Path = $SessionRoot; $SessionWatcher.Filter = '*.jsonl'; $SessionWatcher.IncludeSubdirectories = $true
            $SessionWatcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
            foreach ($EventName in @('Created','Changed','Renamed')) { Register-ObjectEvent -InputObject $SessionWatcher -EventName $EventName -SourceIdentifier "$SessionEventPrefix.$EventName" | Out-Null }
            $SessionWatcher.EnableRaisingEvents = $true
            $DiscoveryDirty = $true; $DiscoveryDirtySinceUtc = $NowUtc
        }

        $SessionEvents = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$SessionEventPrefix.*" })
        if ($SessionEvents.Count -gt 0 -and -not $DiscoveryDirty) { $DiscoveryDirty = $true; $DiscoveryDirtySinceUtc = $NowUtc }
        foreach ($SessionEvent in $SessionEvents) { Remove-Event -EventIdentifier $SessionEvent.EventIdentifier -ErrorAction SilentlyContinue }

        if (($DiscoveryDirty -and ($NowUtc - $DiscoveryDirtySinceUtc) -ge $LiveDebounce) -or
            (($NowUtc - $LastRecoveryUtc) -ge $RecoveryInterval)) {
            $Sessions = Get-CodexSessionSnapshot -CodexHome $ResolvedHome -ActiveWithin ([TimeSpan]::FromSeconds($InactiveSeconds))
            $Workspaces = @(Get-ActiveWorkspaceSnapshot -Sessions $Sessions)
            $Active=@{}; foreach ($W in $Workspaces) { $Active[$W.Path]=$true; if (-not $Monitors.ContainsKey($W.Path)) { $Monitors[$W.Path]=New-WorkspaceMonitor -Path $W.Path } }
            foreach ($Path in @($Monitors.Keys)) { if (-not $Active.ContainsKey($Path)) { Remove-WorkspaceMonitor $Monitors[$Path]; $Monitors.Remove($Path); if ($SelectedPath -eq $Path) { $SelectedPath=$null } } }
            $DiscoveryDirty = $false; $LastRecoveryUtc = $NowUtc; $RenderDirty = $true
        }
        foreach ($Monitor in @($Monitors.Values)) {
            $AcceptedEvents = Receive-WorkspaceEvents $Monitor
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
