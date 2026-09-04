param(
    [string] $Version,
    [string] $ArtifactsDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $projectRoot 'src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj'

if (-not $Version) {
    [xml]$project = Get-Content -LiteralPath $projectFile -Raw
    $Version = [string]$project.Project.PropertyGroup.Version
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "Version '$Version' is not a valid semantic version."
}

$artifactsRoot = [IO.Path]::GetFullPath($ArtifactsDirectory)
$packageName = "AmazonMusicRateSwitcher-v$Version"
$publishDirectory = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'publish'))
$packageDirectory = [IO.Path]::GetFullPath((Join-Path $artifactsRoot $packageName))
$archivePath = [IO.Path]::GetFullPath((Join-Path $artifactsRoot "$packageName-win-x64.zip"))

function Assert-ChildPath {
    param([Parameter(Mandatory)][string] $Path)
    $rootWithSeparator = $artifactsRoot.TrimEnd('\') + '\'
    if (-not $Path.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the release artifacts directory: $Path"
    }
}

foreach ($path in @($publishDirectory, $packageDirectory, $archivePath)) {
    Assert-ChildPath $path
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $publishDirectory, (Join-Path $packageDirectory 'scripts') -Force | Out-Null

& dotnet publish $projectFile `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $publishDirectory `
    --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

$executable = Join-Path $publishDirectory 'AmazonMusicRateSwitcher.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    throw 'The publish output did not contain AmazonMusicRateSwitcher.exe.'
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion
if (-not $fileVersion.StartsWith("$Version.") -and $fileVersion -ne $Version) {
    throw "Published file version '$fileVersion' does not match package version '$Version'."
}

$releaseFiles = [ordered]@{
    $executable = (Join-Path $packageDirectory 'AmazonMusicRateSwitcher.exe')
    (Join-Path $projectRoot 'config.json') = (Join-Path $packageDirectory 'config.json')
    (Join-Path $projectRoot 'scripts\AmazonMusicRateSwitcher.ps1') = (Join-Path $packageDirectory 'scripts\AmazonMusicRateSwitcher.ps1')
    (Join-Path $projectRoot 'scripts\Ensure-AsioBridge.ps1') = (Join-Path $packageDirectory 'scripts\Ensure-AsioBridge.ps1')
    (Join-Path $projectRoot 'scripts\setup.ps1') = (Join-Path $packageDirectory 'scripts\setup.ps1')
}
foreach ($entry in $releaseFiles.GetEnumerator()) {
    Copy-Item -LiteralPath $entry.Key -Destination $entry.Value -Force
}

Compress-Archive -LiteralPath $packageDirectory -DestinationPath $archivePath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $actualEntries = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
} finally {
    $archive.Dispose()
}
$expectedEntries = @(
    "$packageName/AmazonMusicRateSwitcher.exe"
    "$packageName/config.json"
    "$packageName/scripts/AmazonMusicRateSwitcher.ps1"
    "$packageName/scripts/Ensure-AsioBridge.ps1"
    "$packageName/scripts/setup.ps1"
) | Sort-Object

if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
    throw "Release archive contents differ from the approved allowlist.`nExpected:`n$($expectedEntries -join "`n")`nActual:`n$($actualEntries -join "`n")"
}

Write-Host "Release package validated: $archivePath"
