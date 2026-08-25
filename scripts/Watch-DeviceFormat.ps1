param(
    [ValidateRange(50, 5000)]
    [int] $IntervalMs = 100,

    [string] $DeviceId = '',

    [switch] $Once
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $projectRoot 'tools\SoundVolumeView\SoundVolumeView.exe'
if (-not (Test-Path -LiteralPath $tool)) {
    throw "SoundVolumeView.exe not found. Run: & '$PSScriptRoot\setup.ps1'"
}

$snapshotPath = Join-Path ([IO.Path]::GetTempPath()) ("amazon-device-format-{0}.json" -f [Guid]::NewGuid())

function Read-CurrentDeviceFormat {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $tool /sjson $snapshotPath | Out-Null
    $items = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
    $devices = @($items | Where-Object { $_.Type -eq 'Device' -and $_.Direction -eq 'Render' })

    if ($DeviceId) {
        $device = $devices | Where-Object { $_.'Command-Line Friendly ID' -eq $DeviceId } | Select-Object -First 1
    } else {
        $device = $devices | Where-Object { $_.'Default Multimedia' -eq 'Render' } | Select-Object -First 1
        if (-not $device) { $device = $devices | Where-Object { $_.Default -eq 'Render' } | Select-Object -First 1 }
    }
    if (-not $device) { throw 'No matching default render device was found.' }

    $formatText = [string]$device.'Default Format'
    if ($formatText -notmatch '(?i)(?<bits>\d+)\s*bit.*?(?<rate>\d+)\s*Hz') {
        throw "Cannot parse device format: $formatText"
    }
    $timer.Stop()
    [pscustomobject]@{
        Device = [string]$device.Name
        DeviceId = [string]$device.'Command-Line Friendly ID'
        Bits = [int]$Matches.bits
        SampleRate = [int]$Matches.rate
        Raw = $formatText
        ScanMs = $timer.ElapsedMilliseconds
    }
}

try {
    Write-Host "Watching the Windows default render format (poll=${IntervalMs}ms). Ctrl+C to stop."
    Write-Host 'Note: this is bit depth, not compressed-audio bitrate.'
    $lastKey = ''
    do {
        $current = Read-CurrentDeviceFormat
        $key = "$($current.DeviceId)|$($current.Bits)|$($current.SampleRate)"
        if ($key -ne $lastKey) {
            $rateKhz = $current.SampleRate / 1000
            Write-Host ("[{0}] {1}: {2} bit / {3} kHz  (scan {4} ms)" -f `
                (Get-Date -Format 'HH:mm:ss.fff'), $current.Device, $current.Bits, $rateKhz, $current.ScanMs) -ForegroundColor Cyan
            $lastKey = $key
        }
        if (-not $Once) {
            $remainingMs = [Math]::Max(0, $IntervalMs - $current.ScanMs)
            if ($remainingMs -gt 0) { Start-Sleep -Milliseconds $remainingMs }
        }
    } while (-not $Once)
} finally {
    if (Test-Path -LiteralPath $snapshotPath) {
        Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue
    }
}
