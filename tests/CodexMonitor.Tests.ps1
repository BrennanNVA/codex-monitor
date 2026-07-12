BeforeAll {
    Import-Module "$PSScriptRoot\..\src\CodexMonitor.psm1" -Force
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-monitor-tests-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
}

AfterAll { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Resolve-CodexHome' {
    It 'prefers an explicit path' {
        Resolve-CodexHome -ExplicitPath $script:TempRoot | Should -Be ([IO.Path]::GetFullPath($script:TempRoot))
    }
}

Describe 'Codex session discovery' {
    BeforeEach {
        $CodexHome = Join-Path $script:TempRoot ([Guid]::NewGuid().ToString())
        $Sessions = Join-Path $CodexHome 'sessions\2026\07\12'
        $Workspace = Join-Path $script:TempRoot ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $Sessions,$Workspace -Force | Out-Null
        $SessionFile = Join-Path $Sessions 'session.jsonl'
        $Meta = @{ type='session_meta'; payload=@{ id='session-1'; cwd=$Workspace } } | ConvertTo-Json -Compress
        $Usage = @{ type='event_msg'; payload=@{ type='token_count'; info=@{ total_token_usage=@{ total_tokens=1500000; input_tokens=1200000; cached_input_tokens=300000 } } } } | ConvertTo-Json -Compress -Depth 8
        Set-Content -LiteralPath $SessionFile -Value @($Meta,$Usage) -Encoding UTF8
    }

    It 'extracts workspace and token totals from an active session' {
        $Result = @(Get-CodexSessionSnapshot -CodexHome $CodexHome -NowUtc ([DateTime]::UtcNow))
        $Result.Count | Should -Be 1
        $Result[0].Workspace | Should -Be ([IO.Path]::GetFullPath($Workspace).TrimEnd('\','/'))
        $Result[0].TokensUsed | Should -Be 1500000
        $Result[0].TokensCached | Should -Be 300000
        $Result[0].InputTokens | Should -Be 1200000
    }

    It 'expires a session after the two-minute grace period' {
        (Get-Item $SessionFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
        @(Get-CodexSessionSnapshot -CodexHome $CodexHome -NowUtc ([DateTime]::UtcNow -ActiveWithin ([TimeSpan]::FromMinutes(2))).Count | Should -Be 0
    }
}

Describe 'Workspace aggregation' {
    It 'groups parallel agents and sums their tokens' {
        $Now=[DateTime]::UtcNow
        $Sessions=@(
            [PSCustomObject]@{Workspace='C:\repo';LastActivityUtc=$Now;TokensUsed=100;InputTokens=80;TokensCached=20;HasTokenUsage=$true},
            [PSCustomObject]@{Workspace='C:\repo';LastActivityUtc=$Now;TokensUsed=200;InputTokens=160;TokensCached=30;HasTokenUsage=$true}
        )
        $Result=@(Get-ActiveWorkspaceSnapshot -Sessions $Sessions)
        $Result.Count | Should -Be 1
        $Result[0].AgentCount | Should -Be 2
        $Result[0].TokensUsed | Should -Be 300
        $Result[0].TokensCached | Should -Be 50
        $Result[0].InputTokens | Should -Be 240
    }
}

Describe 'Metric formatting' {
    It 'formats large values compactly' {
        Format-CompactNumber 1500000 | Should -Be '1.50m'
        Format-CompactNumber 3000 | Should -Be '3.00k'
    }

    It 'calculates cache rate from input tokens' {
        Format-CacheRate -Cached 300000 -InputTokens 1200000 | Should -Be '25.00%'
    }
}
