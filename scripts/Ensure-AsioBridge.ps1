param(
    [switch] $Stop,

    [int] $WatchParentPid = 0
)

$ErrorActionPreference = 'Stop'

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
if (Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue) {
    return
}

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

# Start one hidden cleanup watcher for the launcher that invoked this script.
# The launcher normally performs an explicit -Stop after the monitor exits;
# this watcher covers the hard-close/X-button case as well.
$self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
$parentPid = if ($self) { [int]$self.ParentProcessId } else { 0 }
if ($parentPid -gt 0 -and (Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-WatchParentPid', [string]$parentPid
    ) | Out-Null
}
