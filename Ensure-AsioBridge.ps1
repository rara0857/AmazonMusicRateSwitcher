$ErrorActionPreference = 'Stop'

# ASIO Bridge remembers its ON/OFF state. The switcher only ensures that the
# resident process exists; it never clicks OFF/ON during a format change.
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
