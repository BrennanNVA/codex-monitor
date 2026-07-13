[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ApplicationPath = Join-Path $RepositoryRoot 'src\codex-monitor.ps1'
$ScreenshotHelper = Join-Path $env:USERPROFILE '.codex\skills\screenshot\scripts\take_screenshot.ps1'
$OverviewPath = Join-Path $RepositoryRoot 'assets\codex-monitor-overview.png'
$WorkspacePath = Join-Path $RepositoryRoot 'assets\codex-monitor-workspace.png'
$DemoRoot = 'C:\Users\Public\CodexMonitorDemo'
$ProjectsRoot = 'C:\Projects'
$ApiWorkspace = Join-Path $ProjectsRoot 'api-service'
$WebWorkspace = Join-Path $ProjectsRoot 'web-client'
$CreatedProjectsRoot = -not (Test-Path -LiteralPath $ProjectsRoot)
$Process = $null

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexMonitorWindowFinder {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int width, int height, uint flags);
}
public static class CodexMonitorProcessControl {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr processHandle);
}
'@

function Get-MonitorWindowHandles {
    $Handles = New-Object System.Collections.ArrayList
    $Callback = [CodexMonitorWindowFinder+EnumWindowsProc]{
        param($Handle, $State)
        if ([CodexMonitorWindowFinder]::IsWindowVisible($Handle)) {
            $Title = New-Object Text.StringBuilder 512
            [void][CodexMonitorWindowFinder]::GetWindowText($Handle, $Title, $Title.Capacity)
            if ($Title.ToString() -eq 'Codex Monitor') { [void]$Handles.Add($Handle.ToInt64()) }
        }
        return $true
    }
    [void][CodexMonitorWindowFinder]::EnumWindows($Callback, [IntPtr]::Zero)
    return @($Handles)
}

function Get-ClientCaptureRegion {
    param([long]$WindowHandle)
    $Handle = [IntPtr]$WindowHandle
    $Rectangle = New-Object CodexMonitorWindowFinder+RECT
    $Origin = New-Object CodexMonitorWindowFinder+POINT
    if (-not [CodexMonitorWindowFinder]::GetClientRect($Handle, [ref]$Rectangle) -or
        -not [CodexMonitorWindowFinder]::ClientToScreen($Handle, [ref]$Origin)) {
        throw 'Could not determine the terminal client area.'
    }
    return "$($Origin.X),$($Origin.Y),$($Rectangle.Right-$Rectangle.Left),$($Rectangle.Bottom-$Rectangle.Top)"
}

function Write-SessionFile {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Workspace,
        [long]$TotalTokens,
        [long]$InputTokens,
        [long]$CachedTokens
    )
    $Metadata = @{ type='session_meta'; payload=@{ id=$SessionId; cwd=$Workspace } } | ConvertTo-Json -Compress
    $Usage = @{ type='event_msg'; payload=@{ type='token_count'; info=@{ total_token_usage=@{ total_tokens=$TotalTokens; input_tokens=$InputTokens; cached_input_tokens=$CachedTokens } } } } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllLines($Path, @($Metadata, $Usage), (New-Object Text.UTF8Encoding($false)))
}

function Append-Usage {
    param(
        [string]$Path,
        [long]$TotalTokens,
        [long]$InputTokens,
        [long]$CachedTokens
    )
    $Usage = @{ type='event_msg'; payload=@{ type='token_count'; info=@{ total_token_usage=@{ total_tokens=$TotalTokens; input_tokens=$InputTokens; cached_input_tokens=$CachedTokens } } } } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText($Path, $Usage + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Remove-OwnedDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $Resolved = (Resolve-Path -LiteralPath $Path).Path
    $Expected = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $Resolved.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected path: $Resolved"
    }
    Remove-Item -LiteralPath $Resolved -Recurse -Force
}

try {
    if ((Test-Path -LiteralPath $DemoRoot) -or (Test-Path -LiteralPath $ApiWorkspace) -or (Test-Path -LiteralPath $WebWorkspace)) {
        throw 'Screenshot fixture paths already exist; refusing to overwrite them.'
    }

    $SessionDirectory = Join-Path $DemoRoot 'sessions\2026\07\13'
    New-Item -ItemType Directory -Path $SessionDirectory,$ApiWorkspace,$WebWorkspace -Force | Out-Null

    foreach ($Workspace in @($ApiWorkspace,$WebWorkspace)) {
        & git -C $Workspace init --quiet
        & git -C $Workspace config user.name 'Codex Monitor Demo'
        & git -C $Workspace config user.email 'demo@example.invalid'
        $SeedPath = Join-Path $Workspace 'README.md'
        Set-Content -LiteralPath $SeedPath -Value "# $([IO.Path]::GetFileName($Workspace))" -Encoding UTF8
        & git -C $Workspace add README.md
        & git -C $Workspace commit --quiet -m 'Initial demo state'
    }

    $ApiOne = Join-Path $SessionDirectory 'api-agent-one.jsonl'
    $ApiTwo = Join-Path $SessionDirectory 'api-agent-two.jsonl'
    $WebOne = Join-Path $SessionDirectory 'web-agent-one.jsonl'
    Write-SessionFile $ApiOne 'api-agent-one' $ApiWorkspace 10000 8000 5000
    Write-SessionFile $ApiTwo 'api-agent-two' $ApiWorkspace 20000 16000 10000
    Write-SessionFile $WebOne 'web-agent-one' $WebWorkspace 30000 24000 15000

    $ExistingHandles = @(Get-MonitorWindowHandles)
    $Arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ApplicationPath,'-CodexHome',$DemoRoot)
    $Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 1

    Append-Usage $ApiOne 11200 9000 5600
    Append-Usage $ApiTwo 20800 16600 10400
    Append-Usage $WebOne 30700 24500 15300

    Add-Content -LiteralPath (Join-Path $ApiWorkspace 'README.md') -Value @('','## API','- health endpoint','- token metrics','- structured logs')
    Set-Content -LiteralPath (Join-Path $ApiWorkspace 'monitor.ps1') -Value @('param()','$status = ''healthy''','Write-Output $status') -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $WebWorkspace 'README.md') -Value @('','## Web client','- dashboard','- accessible status')
    Set-Content -LiteralPath (Join-Path $WebWorkspace 'theme.css') -Value @(':root {','  --accent: #22d3ee;','  --ok: #22c55e;','}') -Encoding UTF8
    Start-Sleep -Milliseconds 800

    $NewHandles = @(Get-MonitorWindowHandles | Where-Object { $ExistingHandles -notcontains $_ })
    if ($NewHandles.Count -ne 1) { throw "Expected one new Codex Monitor window, found $($NewHandles.Count)." }
    $WindowHandle = [long]$NewHandles[0]
    [void][CodexMonitorWindowFinder]::SetWindowPos([IntPtr]$WindowHandle, [IntPtr]::Zero, 80, 80, 1080, 680, 0x0040)
    Start-Sleep -Milliseconds 300
    $CaptureRegion = Get-ClientCaptureRegion -WindowHandle $WindowHandle

    [void][CodexMonitorProcessControl]::NtSuspendProcess($Process.Handle)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScreenshotHelper -Path $OverviewPath -Region $CaptureRegion
    if ($LASTEXITCODE -ne 0) { throw 'Aggregate screenshot capture failed.' }
    [void][CodexMonitorProcessControl]::NtResumeProcess($Process.Handle)

    $Shell = New-Object -ComObject WScript.Shell
    [void]$Shell.AppActivate('Codex Monitor')
    $Shell.SendKeys('1')
    Start-Sleep -Milliseconds 600
    $CaptureRegion = Get-ClientCaptureRegion -WindowHandle $WindowHandle
    [void][CodexMonitorProcessControl]::NtSuspendProcess($Process.Handle)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScreenshotHelper -Path $WorkspacePath -Region $CaptureRegion
    if ($LASTEXITCODE -ne 0) { throw 'Workspace screenshot capture failed.' }
    [void][CodexMonitorProcessControl]::NtResumeProcess($Process.Handle)
}
finally {
    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Kill()
        $Process.WaitForExit()
    }
    Remove-OwnedDirectory $DemoRoot
    Remove-OwnedDirectory $ApiWorkspace
    Remove-OwnedDirectory $WebWorkspace
    if ($CreatedProjectsRoot -and (Test-Path -LiteralPath $ProjectsRoot) -and @(Get-ChildItem -LiteralPath $ProjectsRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $ProjectsRoot -Force
    }
}

Write-Host $OverviewPath
Write-Host $WorkspacePath
