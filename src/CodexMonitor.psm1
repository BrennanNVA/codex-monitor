Set-StrictMode -Version 2.0

$script:IgnoredPathPattern = '[\\/](?:\.git|node_modules|\.venv|__pycache__|bin|obj)(?:[\\/]|$)'
$script:TextExtensions = @('.ps1','.psm1','.psd1','.py','.js','.jsx','.ts','.tsx','.c','.cc','.cpp','.h','.hpp','.cs','.java','.go','.rs','.rb','.php','.swift','.kt','.kts','.scala','.sh','.cmd','.bat','.sql','.html','.css','.scss','.vue','.svelte','.json','.jsonl','.yaml','.yml','.toml','.ini','.cfg','.conf','.xml','.md','.rst','.txt','.csv','.tsv','.proto','.graphql','.tf','.hcl')
$script:GitRootCache = @{}

function Resolve-CodexHome {
    [CmdletBinding()]
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) { return [IO.Path]::GetFullPath($ExplicitPath) }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return [IO.Path]::GetFullPath($env:CODEX_HOME) }
    return Join-Path $env:USERPROFILE '.codex'
}

function ConvertTo-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [IO.Path]::GetFullPath($Path).TrimEnd('\','/') } catch { return $null }
}

function Resolve-GitWorkspaceRoot {
    param([string]$Path)
    if ($script:GitRootCache.ContainsKey($Path)) { return $script:GitRootCache[$Path] }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $Path }
    $GitRoot = (& git -C $Path rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($GitRoot)) { return $Path }
    $NormalizedRoot = ConvertTo-NormalizedPath $GitRoot
    if ($null -eq $NormalizedRoot) { return $Path }
    $script:GitRootCache[$Path] = $NormalizedRoot
    return $NormalizedRoot
}

function Get-CodexSessionSnapshot {
    [CmdletBinding()]
    param(
        [string]$CodexHome = (Resolve-CodexHome),
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [TimeSpan]$ActiveWithin = [TimeSpan]::FromMinutes(2)
    )

    $SessionRoot = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $SessionRoot -PathType Container)) { return @() }
    $Cutoff = $NowUtc.Subtract($ActiveWithin)
    $Results = New-Object System.Collections.ArrayList
    $Files = Get-ChildItem -LiteralPath $SessionRoot -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $Cutoff }

    foreach ($File in $Files) {
        $Metadata = $null
        try {
            foreach ($Line in (Get-Content -LiteralPath $File.FullName -TotalCount 50 -ErrorAction Stop)) {
                try { $Record = $Line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ($Record.type -eq 'session_meta') { $Metadata = $Record.payload; break }
            }
        } catch { continue }
        if ($null -eq $Metadata) { continue }
        $Workspace = ConvertTo-NormalizedPath $Metadata.cwd
        if ($null -eq $Workspace -or -not (Test-Path -LiteralPath $Workspace -PathType Container)) { continue }
        $Workspace = Resolve-GitWorkspaceRoot $Workspace

        $TotalTokens = [long]0; $InputTokens = [long]0; $CachedTokens = [long]0; $HasUsage = $false
        try {
            $Tail = @(Get-Content -LiteralPath $File.FullName -Tail 2000 -ErrorAction Stop)
            for ($Index = $Tail.Count - 1; $Index -ge 0; $Index--) {
                try { $Record = $Tail[$Index] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ($Record.type -eq 'event_msg' -and $Record.payload.type -eq 'token_count') {
                    $Usage = $Record.payload.info.total_token_usage
                    if ($null -ne $Usage -and $null -ne $Usage.total_tokens) {
                        $TotalTokens = [long]$Usage.total_tokens
                        if ($null -ne $Usage.input_tokens) { $InputTokens = [long]$Usage.input_tokens }
                        if ($null -ne $Usage.cached_input_tokens) { $CachedTokens = [long]$Usage.cached_input_tokens }
                        $HasUsage = $true
                        break
                    }
                }
            }
        } catch { }

        $SessionId = if ($null -ne $Metadata.id) { [string]$Metadata.id } else { $File.BaseName }
        [void]$Results.Add([PSCustomObject]@{
            SessionId = $SessionId; Workspace = $Workspace; LastActivityUtc = $File.LastWriteTimeUtc
            TokensUsed = $TotalTokens; InputTokens = $InputTokens; TokensCached = $CachedTokens; HasTokenUsage = $HasUsage
            SessionFile = $File.FullName
        })
    }
    return @($Results)
}

function Get-ActiveWorkspaceSnapshot {
    [CmdletBinding()]
    param([object[]]$Sessions = @())

    $Results = New-Object System.Collections.ArrayList
    foreach ($Group in ($Sessions | Group-Object -Property Workspace)) {
        $Latest = ($Group.Group | Sort-Object LastActivityUtc -Descending | Select-Object -First 1).LastActivityUtc
        $Used = [long](($Group.Group | Measure-Object TokensUsed -Sum).Sum)
        $Input = [long](($Group.Group | Measure-Object InputTokens -Sum).Sum)
        $Cached = [long](($Group.Group | Measure-Object TokensCached -Sum).Sum)
        [void]$Results.Add([PSCustomObject]@{
            Path = $Group.Name; AgentCount = $Group.Count; LastActivityUtc = $Latest
            TokensUsed = $Used; InputTokens = $Input; TokensCached = $Cached
            HasTokenUsage = [bool]($Group.Group | Where-Object HasTokenUsage | Select-Object -First 1)
        })
    }
    return @($Results | Sort-Object Path)
}

function Get-ShortHash {
    param([string]$Text)
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').Substring(0,12)) } finally { $Sha.Dispose() }
}

function New-WorkspaceMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $Normalized = ConvertTo-NormalizedPath $Path
    $Prefix = 'CodexMonitor.' + (Get-ShortHash $Normalized)
    $Watcher = New-Object System.IO.FileSystemWatcher
    $Watcher.Path = $Normalized; $Watcher.Filter = '*'; $Watcher.IncludeSubdirectories = $true
    $Watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $Watcher.InternalBufferSize = 32768
    foreach ($Name in @('Created','Changed','Deleted','Renamed')) {
        Register-ObjectEvent -InputObject $Watcher -EventName $Name -SourceIdentifier "$Prefix.$Name" | Out-Null
    }
    $Watcher.EnableRaisingEvents = $true
    $StartCommit = $null
    if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
        $StartCommit = (& git -C $Normalized rev-parse HEAD 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($StartCommit)) { $StartCommit = $null }
    }
    return [PSCustomObject]@{
        Path = $Normalized; SourcePrefix = $Prefix; Watcher = $Watcher; StartCommit = $StartCommit
        Counters = [ordered]@{ Created=0; Changed=0; Deleted=0; Renamed=0 }
        RecentEvents = @{}; EventHistory = (New-Object System.Collections.ArrayList)
        LastGitRefreshUtc = [DateTime]::MinValue
        Git = [PSCustomObject]@{ Available=$false; CodeIn=[long]0; CodeOut=[long]0; Commits=[long]0 }
    }
}

function Receive-WorkspaceEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Monitor)
    $AcceptedCount = 0
    $Events = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$($Monitor.SourcePrefix).*" })
    foreach ($Event in $Events) {
        try {
            $Args = $Event.SourceEventArgs; $FullPath = $Args.FullPath
            if ([string]::IsNullOrWhiteSpace($FullPath) -or $FullPath -match $script:IgnoredPathPattern) { continue }
            $Type = $Args.ChangeType.ToString(); $Key = "$Type|$FullPath"; $Now = [DateTime]::UtcNow.Ticks
            if ($Monitor.RecentEvents.ContainsKey($Key) -and ($Now - $Monitor.RecentEvents[$Key]) -lt [TimeSpan]::FromMilliseconds(300).Ticks) { continue }
            $Monitor.RecentEvents[$Key] = $Now; $Monitor.Counters[$Type]++
            $AcceptedCount++
            $Text = if ($Args -is [IO.RenamedEventArgs]) { "[$(Get-Date -Format 'HH:mm:ss')] $Type $($Args.OldFullPath) -> $FullPath" } else { "[$(Get-Date -Format 'HH:mm:ss')] $Type $FullPath" }
            [void]$Monitor.EventHistory.Add([PSCustomObject]@{ Type=$Type; Text=$Text })
            if ($Monitor.EventHistory.Count -gt 500) { $Monitor.EventHistory.RemoveAt(0) }
        } finally { Remove-Event -EventIdentifier $Event.EventIdentifier -ErrorAction SilentlyContinue }
    }
    return $AcceptedCount
}

function Get-UntrackedLines {
    param([string]$Path)
    $Total = [long]0; $Allowed = @{}; foreach ($Ext in $script:TextExtensions) { $Allowed[$Ext]=$true }
    foreach ($Relative in @(& git -C $Path ls-files --others --exclude-standard 2>$null)) {
        $Full = Join-Path $Path $Relative
        if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }
        $Info = Get-Item -LiteralPath $Full -ErrorAction SilentlyContinue
        if ($null -eq $Info -or $Info.Length -gt 10MB) { continue }
        $Ext = [IO.Path]::GetExtension($Full).ToLowerInvariant(); $Name = [IO.Path]::GetFileName($Full)
        if (-not $Allowed.ContainsKey($Ext) -and $Name -notin @('Dockerfile','Makefile','Rakefile','Gemfile')) { continue }
        try { $Reader = New-Object IO.StreamReader($Full); try { while ($null -ne $Reader.ReadLine()) { $Total++ } } finally { $Reader.Dispose() } } catch { }
    }
    return $Total
}

function Update-WorkspaceGitMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Monitor)
    if ([string]::IsNullOrWhiteSpace($Monitor.StartCommit)) { $Monitor.LastGitRefreshUtc = [DateTime]::UtcNow; return }
    $Added=[long]0; $Removed=[long]0
    foreach ($Line in @(& git -C $Monitor.Path diff --numstat $Monitor.StartCommit -- . 2>$null)) {
        $Parts=$Line -split "`t"; if ($Parts.Count -ge 2 -and $Parts[0] -match '^\d+$' -and $Parts[1] -match '^\d+$') { $Added += [long]$Parts[0]; $Removed += [long]$Parts[1] }
    }
    $Added += Get-UntrackedLines $Monitor.Path
    $CommitText = (& git -C $Monitor.Path rev-list --count "$($Monitor.StartCommit)..HEAD" 2>$null | Select-Object -First 1)
    $Commits = if ($CommitText -match '^\d+$') { [long]$CommitText } else { [long]0 }
    $Monitor.Git = [PSCustomObject]@{ Available=$true; CodeIn=$Added; CodeOut=$Removed; Commits=$Commits }
    $Monitor.LastGitRefreshUtc = [DateTime]::UtcNow
}

function Remove-WorkspaceMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Monitor)
    Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$($Monitor.SourcePrefix).*" } | Unregister-Event -Force -ErrorAction SilentlyContinue
    Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$($Monitor.SourcePrefix).*" } | Remove-Event -ErrorAction SilentlyContinue
    if ($null -ne $Monitor.Watcher) { $Monitor.Watcher.EnableRaisingEvents=$false; $Monitor.Watcher.Dispose() }
}

function Format-CompactNumber {
    param([long]$Value)
    if ($Value -ge 1000000000) { return (($Value/1000000000.0).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)+'b') }
    if ($Value -ge 1000000) { return (($Value/1000000.0).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)+'m') }
    if ($Value -ge 1000) { return (($Value/1000.0).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)+'k') }
    return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-CacheRate {
    param([long]$Cached,[long]$InputTokens)
    if ($InputTokens -le 0) { return 'N/A' }
    return ((($Cached/[double]$InputTokens)*100).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)+'%')
}

Export-ModuleMember -Function Resolve-CodexHome,Get-CodexSessionSnapshot,Get-ActiveWorkspaceSnapshot,New-WorkspaceMonitor,Receive-WorkspaceEvents,Update-WorkspaceGitMetrics,Remove-WorkspaceMonitor,Format-CompactNumber,Format-CacheRate
