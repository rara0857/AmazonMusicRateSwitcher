# Development guide

[English](development.md) | [繁體中文](development.zh-TW.md)

## Project architecture

The project consists of a WinForms GUI and a PowerShell backend. The release uses one fixed output path:

`Amazon Music Exclusive → Hi-Fi Cable → ASIO Bridge → DAC`

Amazon Music is routed to Hi-Fi Cable Input. Select the physical DAC in the ASIO Bridge or ASIO4ALL panel.

## Diagnostics and launchers

The GUI is the primary interface. The CMD launchers and PowerShell backend are available for diagnostics and advanced testing:

```powershell
.\scripts\launchers\Start-AutoSwitch.cmd
.\scripts\launchers\Run-AutoTest.cmd
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Devices
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Probe
```

Do not pass the `direct` argument to either launcher; the current release only uses the Exclusive → Hi-Fi Cable → ASIO path.

For direct backend runs, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Apply -Cdp -CdpLaunch -AsioExclusive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 10 -Cdp -CdpLaunch -AsioExclusive
```

`-Mode Restore` restores the device format saved before startup. `-Mode Devices` and `-Mode Probe` do not apply format changes.

## Current track-switch flow

1. Monitor Amazon's ASIN and track format through CDP; fall back to the Amazon log when CDP is unavailable.
2. In Apply mode, pause the new track defensively before its format is resolved so a different-format track cannot play a short fragment first.
3. Same-format track: the endpoint already matches, so re-arm Exclusive and resume immediately. No seek, Previous, endpoint rebuild, or blocking full playback-telemetry wait is used.
4. Different-format track: pause → change the Hi-Fi Cable format → wait for endpoint read-back → seek to about 5500 ms → press Previous to restart the current track → confirm it remains paused → re-arm Exclusive → play.

For different-format switches, most latency comes from rebuilding the Windows audio endpoint/DAC. Same-format latency only covers format detection, pause, and resume.

## AutoTest and reports

The GUI `TEST & Config` page selects the number of tracks. AutoTest checks each track's format, endpoint format, Exclusive state, and playback state, then writes `state/auto-test-latest.json` and `state/auto-test-summary.json`.

Same-format latency does not include waiting for Amazon's complete playback/stream telemetry. Set `showDetailedTiming` to `true` in `config.json` to log stage timings.

The `state` directory contains the device backup, format cache, test results, and runtime state. It remains local and is excluded from Git.

## Build

Install the .NET 6 Windows Desktop SDK, then publish a self-contained x64 portable build:

```powershell
dotnet publish .\src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj -c Release -r win-x64 --self-contained true -o .\artifacts\win-x64 --nologo
```

The output is written to `artifacts/win-x64/`; the main executable is `AmazonMusicRateSwitcher.exe`.

## Repository layout

- `src`: maintainable WinForms GUI source
- `scripts`: PowerShell backend, setup, and ASIO Bridge management scripts
- `scripts/launchers`: CMD launchers for normal startup and AutoTest
- `assets`: README assets
- `config.json`: device matching, polling, and diagnostic settings
- `artifacts`: local build output, excluded from Git
- `state`: runtime state, format cache, and test reports, excluded from Git
- `tools/SoundVolumeView`: downloaded locally by the setup script, excluded from Git

## Tested environment

- Windows 11 64-bit, build 26200
- Amazon Music Store package 9.5.2.0 / executable 9.5.2.2478
- PowerShell 5.1
- .NET 6 Windows Desktop SDK
- VB-Audio Hi-Fi Cable
- ASIO4ALL & FiiO ASIO Driver
