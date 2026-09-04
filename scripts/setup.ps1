$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$toolDirectory = Join-Path $projectRoot 'tools\SoundVolumeView'
$executable = Join-Path $toolDirectory 'SoundVolumeView.exe'
$downloadUri = 'https://www.nirsoft.net/utils/soundvolumeview-x64.zip'
$expectedVersion = '2.53'
$expectedExecutableSha256 = 'B5AF5BD60F7A29AF8CB4D8A566382B90F0FE07CAC97228D218CB913F3382D647'

if (Test-Path $executable) {
    $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash
    if ($installedHash -ne $expectedExecutableSha256) {
        throw "SoundVolumeView.exe failed integrity validation. Expected the approved v$expectedVersion binary."
    }
    Write-Host "SoundVolumeView v$expectedVersion already exists and passed SHA-256 validation: $executable"
    exit 0
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDirectory = [IO.Path]::GetFullPath((Join-Path $tempBase ("AmazonMusicRateSwitcher-SoundVolumeView-{0}" -f [guid]::NewGuid().ToString('N'))))
if (-not $tempDirectory.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to use a temporary directory outside the system temp path.'
}
$archive = Join-Path $tempDirectory 'soundvolumeview-x64.zip'
$stagingDirectory = Join-Path $tempDirectory 'expanded'

try {
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    Write-Host "Downloading approved SoundVolumeView v$expectedVersion from the NirSoft website..."
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $stagingDirectory -Force

    $stagedExecutable = Join-Path $stagingDirectory 'SoundVolumeView.exe'
    if (-not (Test-Path -LiteralPath $stagedExecutable)) {
        throw 'SoundVolumeView download or extraction failed.'
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedExecutable).Hash
    if ($actualHash -ne $expectedExecutableSha256) {
        throw "SoundVolumeView.exe SHA-256 mismatch. Expected $expectedExecutableSha256 but received $actualHash. The approved dependency may have changed; do not run it until the project hash is reviewed."
    }

    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    Copy-Item -LiteralPath $stagedExecutable -Destination $executable -Force

    if (-not (Test-Path -LiteralPath $executable)) {
        throw 'SoundVolumeView installation did not produce the expected executable.'
    }

    Write-Host "Setup complete: SoundVolumeView v$expectedVersion passed SHA-256 validation."
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
