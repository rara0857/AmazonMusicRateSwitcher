# Development guide

[English](development.md) | [繁體中文](development.zh-TW.md)

## Diagnostics

The GUI is the primary interface. The optional command launchers and PowerShell backend are available for diagnostics:

```powershell
.\scripts\launchers\Start-AutoSwitch.cmd direct
.\scripts\launchers\Run-AutoTest.cmd direct
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Devices
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Probe
```

## Build

Install the .NET 6 Windows Desktop SDK, then publish a self-contained x64 build:

```powershell
dotnet publish .\src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true -o .\artifacts\win-x64
```

## Repository layout

- `src`: maintainable GUI source
- `scripts`: PowerShell backend and setup scripts
- `scripts/launchers`: optional CMD launchers
- `assets`: README assets
- `artifacts`: local build output, excluded from Git
- `tools/SoundVolumeView`: downloaded locally by the setup script, excluded from Git

Runtime state, listening-derived cache entries, test reports, build output, and downloaded third-party tools are excluded from Git.

## Tested environment

- Windows 11 64-bit, build 26200
- Amazon Music Store package 9.5.2.0 / executable 9.5.2.2478
- PowerShell 5.1
- VB-Audio Hi-Fi Cable
- ASIO4ALL
