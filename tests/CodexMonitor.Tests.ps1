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

    It 'reports successful scan diagnostics' {
        $Scan = Get-CodexSessionScan -CodexHome $CodexHome -NowUtc ([DateTime]::UtcNow)
        @($Scan.Sessions).Count | Should -Be 1
        $Scan.CandidateCount | Should -Be 1
        $Scan.ReadErrorCount | Should -Be 0
        $Scan.CompletedUtc | Should -BeOfType ([DateTime])
    }

    It 'counts malformed session metadata without exposing record content' {
        Set-Content -LiteralPath $SessionFile -Value '{malformed-json' -Encoding UTF8
        $Scan = Get-CodexSessionScan -CodexHome $CodexHome -NowUtc ([DateTime]::UtcNow)
        @($Scan.Sessions).Count | Should -Be 0
        $Scan.CandidateCount | Should -Be 1
        $Scan.ReadErrorCount | Should -Be 1
        ($Scan | ConvertTo-Json -Compress) | Should -Not -Match 'malformed-json'
    }

    It 'expires a session after the two-minute grace period' {
        (Get-Item $SessionFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
        @(Get-CodexSessionSnapshot -CodexHome $CodexHome -NowUtc ([DateTime]::UtcNow) -ActiveWithin ([TimeSpan]::FromMinutes(2))).Count | Should -Be 0
    }
}

Describe 'Efficient token reading' {
    It 'finds the latest complete usage record near the end of a large JSONL file' {
        $LargeSessionFile = Join-Path $script:TempRoot ("large-session-{0}.jsonl" -f [Guid]::NewGuid())
        $Utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        $Writer = New-Object IO.StreamWriter($LargeSessionFile, $false, $Utf8WithoutBom)
        try {
            $LargePayload = 'x' * 8192
            for ($Index = 0; $Index -lt 2560; $Index++) {
                $Writer.WriteLine('{{"type":"response_item","payload":"{0}"}}' -f $LargePayload)
            }
            $Writer.WriteLine('{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":2000,"output_tokens":2000,"reasoning_output_tokens":0,"total_tokens":7000}}}}')
            $Writer.Write('{"type":"event_msg","payload":')
        }
        finally {
            $Writer.Dispose()
        }

        try {
            $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $Usage = Get-LatestTokenUsage -Path $LargeSessionFile
            $Stopwatch.Stop()
            $Usage.total_tokens | Should -Be 7000
            $Stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2
        }
        finally {
            Remove-Item -LiteralPath $LargeSessionFile -Force -ErrorAction SilentlyContinue
        }
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

Describe 'Since-launch token accounting' {
    It 'uses the first observation as a zero baseline and adds later deltas' {
        $State = @{}
        $First = [PSCustomObject]@{ SessionId='one'; Workspace='C:\repo'; TokensUsed=1000; InputTokens=800; TokensCached=500; HasTokenUsage=$true }
        $Later = [PSCustomObject]@{ SessionId='one'; Workspace='C:\repo'; TokensUsed=1250; InputTokens=1000; TokensCached=620; HasTokenUsage=$true }

        Update-SessionTokenState -State $State -Sessions @($First)
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 0
        Update-SessionTokenState -State $State -Sessions @($Later)
        $Totals = Get-SinceLaunchTokenTotals -State $State
        $Totals.TokensUsed | Should -Be 250
        $Totals.InputTokens | Should -Be 200
        $Totals.TokensCached | Should -Be 120
        $Totals.HasTokenUsage | Should -BeTrue
    }

    It 'retains accumulated totals while sessions are inactive and after they resume' {
        $State = @{}
        Update-SessionTokenState -State $State -Sessions @([PSCustomObject]@{ SessionId='one'; Workspace='C:\repo'; TokensUsed=100; InputTokens=80; TokensCached=20; HasTokenUsage=$true })
        Update-SessionTokenState -State $State -Sessions @([PSCustomObject]@{ SessionId='one'; Workspace='C:\repo'; TokensUsed=200; InputTokens=160; TokensCached=40; HasTokenUsage=$true })
        Update-SessionTokenState -State $State -Sessions @()
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 100
        $State['one'].IsActive | Should -BeFalse

        Update-SessionTokenState -State $State -Sessions @([PSCustomObject]@{ SessionId='one'; Workspace='C:\repo'; TokensUsed=260; InputTokens=210; TokensCached=55; HasTokenUsage=$true })
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 160
        $State['one'].IsActive | Should -BeTrue
    }

    It 'aggregates sessions by workspace and never subtracts after a counter rollback' {
        $State = @{}
        $Initial = @(
            [PSCustomObject]@{ SessionId='one'; Workspace='C:\repo-a'; TokensUsed=100; InputTokens=80; TokensCached=20; HasTokenUsage=$true },
            [PSCustomObject]@{ SessionId='two'; Workspace='C:\repo-b'; TokensUsed=500; InputTokens=400; TokensCached=100; HasTokenUsage=$true }
        )
        $Growth = @(
            [PSCustomObject]@{ SessionId='one'; Workspace='C:\repo-a'; TokensUsed=180; InputTokens=140; TokensCached=30; HasTokenUsage=$true },
            [PSCustomObject]@{ SessionId='two'; Workspace='C:\repo-b'; TokensUsed=620; InputTokens=490; TokensCached=130; HasTokenUsage=$true }
        )
        Update-SessionTokenState -State $State -Sessions $Initial
        Update-SessionTokenState -State $State -Sessions $Growth
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 200
        (Get-SinceLaunchTokenTotals -State $State -Workspace 'C:\repo-a').TokensUsed | Should -Be 80

        Update-SessionTokenState -State $State -Sessions @([PSCustomObject]@{ SessionId='one'; Workspace='C:\repo-a'; TokensUsed=20; InputTokens=15; TokensCached=4; HasTokenUsage=$true })
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 200
        Update-SessionTokenState -State $State -Sessions @([PSCustomObject]@{ SessionId='one'; Workspace='C:\repo-a'; TokensUsed=50; InputTokens=35; TokensCached=9; HasTokenUsage=$true })
        (Get-SinceLaunchTokenTotals -State $State).TokensUsed | Should -Be 230
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
