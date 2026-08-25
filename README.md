# Amazon Music Rate Switcher

English | [繁體中文（台灣）](README.zh-TW.md)

Automatically changes the Windows render format to match the current Amazon Music track (bit depth and sample rate). It uses Amazon CDP playback state when available, with AmazonMusic.log as a fallback.

Amazon Music's Windows Exclusive Mode does not automatically change the sample rate per track. If every track uses one fixed output format, tracks with a different native format may go through SRC. This tool follows the track format and switches the endpoint to reduce unnecessary conversion; it is not a guarantee of bit-perfect output.

Audio paths:

- ASIO mode: `Amazon Music → Hi-Fi Cable → ASIO driver/ASIO4ALL → DAC`
- Direct mode: `Amazon Music → Windows output device → DAC`

The default launcher uses ASIO mode, which is effectively a global ASIO path; avoid playing YouTube, system sounds, or other audio sources through the same ASIO/Hi-Fi Cable route. Direct mode sends Amazon to the Windows default output device and does not require ASIO.

This is an experimental Windows helper, not an official Amazon API.

## Features

- Queue-safe same-track replay after a format change.
- No interruption when the new track already matches the endpoint.
- ASIN/format verification and a local verified-format cache.
- Optional VB-Audio Hi-Fi Cable, ASIO Bridge, or ASIO4ALL routing.
- AutoTest reports with per-stage timing and average latency.

## Related projects

This project follows the same high-level idea as [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) and [Windows Lossless Switcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher): read the currently playing Apple Music track format and change the system output format to match it.

The implementation here is Amazon Music-specific. It uses Amazon ASIN metadata, CDP/player state, AmazonMusic.log, and queue-safe same-track replay.

## Tested environment

- Windows 11 64-bit, build 26200
- Amazon Music Store package 9.5.2.0
- Amazon Music executable 9.5.2.2478
- Windows PowerShell 5.1
- VB-Audio Hi-Fi Cable + ASIO4ALL

Other versions and audio drivers may require different device names or CDP behavior.

## Requirements

- Amazon Music for Windows, signed in and playing.
- Windows PowerShell 5.1.
- Internet access during initial setup (downloads SoundVolumeView locally).
- Optional: VB-Audio Hi-Fi Cable, ASIO Bridge, or ASIO4ALL.

## Install

Run once from this directory:

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\setup.ps1
~~~

`scripts\setup.ps1` downloads SoundVolumeView into the local `tools` folder. Runtime state, listening history, test reports, device backups, and downloaded third-party files are excluded from Git.

## Quick start

For normal use, double-click `Start-AutoSwitch.cmd`. It starts the ASIO path:

`Amazon Music → Hi-Fi Cable → ASIO driver/ASIO4ALL → DAC`

For direct output without ASIO, set the desired DAC/speakers as the Windows default, then run this from the project folder:

~~~powershell
.\Start-AutoSwitch.cmd direct
~~~

`Run-AutoTest.cmd` is optional and runs the queue test. For one-shot diagnostics, use `-Mode Probe` or `-Mode Devices` with the PowerShell script.

When AutoTest finishes, the console prints average latency. Detailed per-track results remain in `state/auto-test-latest.json`; the aggregate is written to `state/auto-test-summary.json`.

## AutoTest

Before running `Run-AutoTest.cmd`, sign in to Amazon Music, start playback, enable autoplay, and leave enough playable tracks after the current queue position. Do not operate Amazon Music or play another source through the same ASIO path during the test.

AutoTest uses NextTrack. If the queue runs out, a next-track timeout indicates a playback setup problem, not a sample-rate switch failure. CDP launch mode may restart Amazon and reset its queue; an existing process is reused when a usable CDP port is already available.

## Configuration

Most users can leave `config.json` unchanged. Advanced settings include the target endpoint (`deviceId` or `deviceNamePattern`), track polling interval, Amazon rebuild timeout, and `showDetailedTiming`.

## Audio flow

~~~text
Amazon Music
    ├── Direct mode ───────────────────────────────► Windows output device / DAC
    │
    └── ASIO mode
            │
            ▼
        Hi-Fi Cable Input
            │
            ▼
        ASIO output layer
            ├── Native hardware ASIO driver ──► DAC / audio device
            └── ASIO4ALL WDM wrapper ─────────► DAC / audio device

Rate Switcher ── changes bit depth and sample rate ──► selected Windows render endpoint
~~~

### Native ASIO vs ASIO4ALL

Prefer the manufacturer's native ASIO driver when the hardware provides one. It normally has a shorter path, better device-specific control, and more predictable buffering.

ASIO4ALL is a compatibility layer that exposes WDM devices through an ASIO interface. It is useful when no native driver exists, but it adds a translation layer and may resample if the WDM device or its settings do not support the requested format. ASIO4ALL does not by itself guarantee bit-perfect output.

If Amazon is still feeding Hi-Fi Cable through Windows shared mode, replacing ASIO4ALL with a native driver improves the bridge-to-device side only. It does not turn Amazon's own output into native ASIO or automatically make the whole path exclusive.

## Limitations

- Amazon Exclusive Mode is not used.
- Shared-mode Windows audio can still mix or process audio; endpoint format alone is not proof of bit-perfect delivery.
- A format switch typically adds about 0.5–1.5 seconds while Amazon rebuilds its stream.
- ASIO4ALL is a WDM wrapper, not a native hardware ASIO driver, and may resample on unsupported devices.
- Amazon updates may change its private CDP/player structure.

## Restore

~~~powershell
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Restore
~~~

The project uses only relative project paths and `%LOCALAPPDATA%`; copy the folder to another Windows computer and run `scripts\setup.ps1` again.
