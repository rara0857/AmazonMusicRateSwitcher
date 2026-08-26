param(
    [switch] $Stop,

    [int] $WatchParentPid = 0,

    [int64] $WatchParentStartTicks = 0,

    # This mode watches the launcher and force-stops the backend if the GUI,
    # CMD window, or test harness disappears without running normal cleanup.
    [int] $WatchBackendPid = 0,

    # Used by the WinForms launcher. The script itself exits after ensuring
    # the bridge, while a hidden watchdog keeps it alive for this process.
    [int] $KeepAlivePid = 0
)

$ErrorActionPreference = 'Stop'

function Test-WatchedParentAlive {
    param([int] $ProcessId, [int64] $ExpectedStartTicks)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if ($ExpectedStartTicks -le 0) { return $true }
    try {
        return $process.StartTime.ToUniversalTime().Ticks -eq $ExpectedStartTicks
    } catch {
        return $false
    }
}

if ($WatchParentPid -gt 0 -and $WatchBackendPid -gt 0) {
    while ((Test-WatchedParentAlive -ProcessId $WatchParentPid -ExpectedStartTicks $WatchParentStartTicks) -and
        (Get-Process -Id $WatchBackendPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-WatchedParentAlive -ProcessId $WatchParentPid -ExpectedStartTicks $WatchParentStartTicks)) {
        Get-Process -Id $WatchBackendPid -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($WatchParentPid -gt 0) {
    # A batch file cannot reliably run its final cleanup line when its
    # console window is closed with the X button.  This hidden child watches
    # the launcher process and releases ASIO Bridge when that parent exits.
    while ((Get-Process -Id $WatchParentPid -ErrorAction SilentlyContinue) -and
        (Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 500
    }
    Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue |
        Stop-Process -ErrorAction SilentlyContinue
    exit 0
}

if ($Stop) {
    Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue |
        Stop-Process -ErrorAction SilentlyContinue
    exit 0
}

# ASIO Bridge remembers its ON/OFF state. The switcher only ensures that the
# resident process exists; it never clicks OFF/ON during a format change.
# The launcher calls -Stop after its ASIO session ends so the route is released.
$bridgeAlreadyRunning = [bool](Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue)
if ($bridgeAlreadyRunning -and $KeepAlivePid -le 0) {
    return
}

$bridgePath = $null
if (-not $bridgeAlreadyRunning) {
    $candidates = foreach ($root in @(
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
        [Environment]::GetEnvironmentVariable('ProgramFiles')
    )) {
        if ($root) {
            Join-Path $root 'VB\ASIOBridge\VBCABLE_AsioBridge.exe'
            Join-Path $root 'VB-Audio\ASIOBridge\VBCABLE_AsioBridge.exe'
        }
    }

    $bridgePath = $candidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if ($bridgePath) {
        Start-Process -FilePath $bridgePath -WindowStyle Hidden
    }
}

# Start one hidden cleanup watcher for the launcher that invoked this script.
# The launcher normally performs an explicit -Stop after the monitor exits;
# this watcher covers the hard-close/X-button case as well.
$self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
$parentPid = if ($KeepAlivePid -gt 0) {
    $KeepAlivePid
} elseif ($self) {
    [int]$self.ParentProcessId
} else {
    0
}
if ($parentPid -gt 0 -and (Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-WatchParentPid', [string]$parentPid
    ) | Out-Null
}
