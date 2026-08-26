# Amazon Music Rate Switcher

English | [繁體中文（台灣）](README.zh-TW.md)

Amazon Music for Windows does not automatically follow each track's native sample rate in Exclusive Mode. This tool reads the active track format and switches the Windows render endpoint to reduce unnecessary sample-rate conversion (SRC). It is experimental and cannot prove that the complete audio path is bit-perfect.

<p align="center">
  <img src="assets/app-preview.png" width="420" alt="Amazon Music Rate Switcher desktop app">
</p>

## Features

- Automatically switches sample rate and bit depth for the current Amazon Music track.
- Desktop GUI with track title, artist, artwork, format, and switch status.
- ASIO Bridge/ASIO4ALL and direct Windows output modes.
- Queue-safe same-track replay after a format change; same-format tracks stay uninterrupted.
- ASIN-correlated format cache for faster repeat plays without reusing stale track data.
- Built-in 10-track AutoTest with pass/fail and average-latency reports.
- OS-level single-instance protection and forced-close cleanup prevent orphan backends.

## Quick start

The packaged EXE is the primary interface:

1. Download `AmazonMusicRateSwitcher-1.0.0-win-x64-Portable.zip` from the latest GitHub Release.
2. Extract it and run `AmazonMusicRateSwitcher.exe`.
3. Select **Start**. The small endpoint helper is installed automatically on first use.

Choose **ASIO** for the Hi-Fi Cable route or **Direct** for a regular Windows output device. AutoTest expects playback to be active, autoplay enabled, and at least 10 playable tracks remaining.

## Audio paths

- ASIO: `Amazon Music → Hi-Fi Cable → ASIO driver/ASIO4ALL → DAC`
- Direct: `Amazon Music → Windows output device → DAC`

ASIO mode is a global route. Do not send YouTube, system sounds, or another source through the same Hi-Fi Cable while listening. Prefer a manufacturer's native ASIO driver when available; ASIO4ALL is a WDM compatibility layer and is not itself a bit-perfect guarantee.

```text
Amazon Music
   ├─ Direct ──► Windows render endpoint ──► DAC
   └─ ASIO ────► Hi-Fi Cable ──► ASIO driver/ASIO4ALL ──► DAC

Rate Switcher ──► changes the selected endpoint format
```

## How it works

The switcher prefers Amazon CDP player state, then ASIN-correlated `AmazonMusic.log` data and the local verified-format cache. When a change is required, it mutes the endpoint, applies the target format, seeks the current track past Amazon's restart threshold, and uses a guarded Previous command to replay the same track. A switch normally adds about 0.5–1.5 seconds.

## Advanced use

The GUI is recommended. The CMD launchers and PowerShell backend remain available for troubleshooting:

```powershell
.\Start-AutoSwitch.cmd direct
.\Run-AutoTest.cmd direct
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Devices
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Probe
```

Runtime state, listening-derived cache entries, test reports, build output, and downloaded third-party tools are excluded from Git. The repository keeps maintainable source in `src`, backend scripts in `scripts`, and local builds in `artifacts`.

To build the self-contained EXE from source, install the .NET 6 Windows Desktop SDK and run:

```powershell
dotnet publish .\src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true -o .\artifacts\win-x64
```

Tested with Windows 11 64-bit (build 26200), Amazon Music Store package 9.5.2.0 / executable 9.5.2.2478, PowerShell 5.1, VB-Audio Hi-Fi Cable, and ASIO4ALL.

## Limitations

- Amazon updates may change its private CDP/player structure.
- Windows shared mode can still mix or process audio; a matching endpoint format alone does not prove bit-perfect output.
- Device names and available formats depend on the current Windows installation and audio driver.
