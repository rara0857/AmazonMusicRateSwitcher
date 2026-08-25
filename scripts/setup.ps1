$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$toolDirectory = Join-Path $projectRoot 'tools\SoundVolumeView'
$executable = Join-Path $toolDirectory 'SoundVolumeView.exe'

if (Test-Path $executable) {
    Write-Host "SoundVolumeView already exists: $executable"
    exit 0
}

New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
$archive = Join-Path ([IO.Path]::GetTempPath()) 'soundvolumeview-x64.zip'

Write-Host 'Downloading SoundVolumeView from the NirSoft website...'
Invoke-WebRequest 'https://www.nirsoft.net/utils/soundvolumeview-x64.zip' -OutFile $archive
Expand-Archive -LiteralPath $archive -DestinationPath $toolDirectory -Force

if (-not (Test-Path $executable)) {
    throw 'SoundVolumeView download or extraction failed.'
}

Write-Host "Setup complete: $executable"
