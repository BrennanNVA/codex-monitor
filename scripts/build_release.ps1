[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $RepositoryRoot 'dist' }
$Version = (Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'VERSION')).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid VERSION value: $Version" }

$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-monitor-release-{0}" -f [Guid]::NewGuid())
$ReleaseName = "codex-monitor-v$Version"
$StagingRoot = Join-Path $TemporaryRoot $ReleaseName
$ArchivePath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "$ReleaseName.zip"

try {
    New-Item -ItemType Directory -Path $StagingRoot,$OutputDirectory -Force | Out-Null
    foreach ($File in @('Start-Codex-Monitor.cmd','README.md','CHANGELOG.md','VERSION','LICENSE','SECURITY.md')) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot $File) -Destination $StagingRoot -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src') -Destination $StagingRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'assets') -Destination $StagingRoot -Recurse

    if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
    Compress-Archive -LiteralPath $StagingRoot -DestinationPath $ArchivePath -CompressionLevel Optimal
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot -PathType Container) {
        $ResolvedTemporaryRoot = (Resolve-Path -LiteralPath $TemporaryRoot).Path
        $SystemTemporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if (-not $ResolvedTemporaryRoot.StartsWith($SystemTemporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove staging path outside the temporary directory: $ResolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}

Write-Output $ArchivePath
