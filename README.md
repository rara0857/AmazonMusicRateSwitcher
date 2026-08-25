# Amazon Music Rate Switcher

English | [繁體中文（台灣）](README.zh-TW.md)

Automatically changes the Windows render format to match the current Amazon Music track (bit depth and sample rate). It uses Amazon CDP playback state when available, with AmazonMusic.log as a fallback.

Amazon Music's Windows Exclusive Mode does not automatically change the sample rate per track. If every track uses one fixed output format, tracks with a different native format may go through SRC. This tool follows the track format and switches the endpoint to reduce unnecessary conversion; it is not a guarantee of bit-perfect output.

**Audio path：Amazon Music → Hi-Fi Cable → ASIO driver/ASIO4ALL → DAC**

With the current setup, this is effectively a global ASIO path. Do not play YouTube, system sounds, or other audio sources at the same time; they may contend for the ASIO or Hi-Fi Cable stream.

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
.\setup.ps1
~~~

`setup.ps1` downloads SoundVolumeView into the local `tools` folder. Runtime state, listening history, test reports, device backups, and downloaded third-party files are excluded from Git.

## Use

~~~powershell
# Read the current Amazon format
.\AmazonMusicRateSwitcher.ps1 -Mode Probe

# List render endpoints
.\AmazonMusicRateSwitcher.ps1 -Mode Devices

# Monitor without changing the endpoint
.\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Cdp

# Monitor and apply format changes
.\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Apply -Cdp

# Run a queue-safe test
.\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 20 -Cdp
~~~

The launchers are `Start-AutoSwitch.cmd`, `Run-AutoTest.cmd`, and `Watch-DeviceFormat.cmd`.

When AutoTest finishes, the console prints average latency for successful tracks, switched tracks, and same-format tracks. Detailed per-track results remain in `state/auto-test-latest.json`; the aggregate is written to `state/auto-test-summary.json`.

## AutoTest preparation

AutoTest advances Amazon Music with NextTrack. Before starting:

1. Open Amazon Music, sign in, and start playback.
2. Enable autoplay/continuous playback.
3. Prepare at least the requested number of playable tracks from the current queue position. For a 20-track test, keep 20 or more tracks available after the current position.
4. Do not manually operate Amazon Music during the test, and do not play another audio source through the same ASIO path.

If the queue runs out, AutoTest reports a next-track timeout; that is a queue/playback setup failure, not a sample-rate switch failure. Use a smaller count when needed:

~~~powershell
.\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 5 -Cdp
~~~

CDP launch mode is used when Amazon must be started with a debugging port. A launch may open or restart Amazon Music and can reset the current queue. When an existing Amazon process and usable CDP port are found, the switcher reuses them. To avoid an unnecessary relaunch, open Amazon first and connect with -Cdp without -CdpLaunch; if no debug port is available, the script can fall back to AmazonMusic.log.

## Configuration

Edit `config.json`:

- deviceId: preferred device ID from -Mode Devices; leave empty for the default render endpoint.
- deviceNamePattern: optional wildcard fallback, such as Hi-Fi Cable Input*.
- trackPollMilliseconds: track detection interval.
- waitForRebuildSeconds: maximum wait for Amazon to rebuild the stream.
- showDetailedTiming: false keeps the console concise; set true to print every timing stage. Full timing is always saved in AutoTest JSON.

If using Hi-Fi Cable, route Amazon Music to Hi-Fi Cable Input and let ASIO4ALL/ASIO Bridge forward it to the hardware output.

## Audio flow

~~~text
Amazon Music
    │
    ▼
Hi-Fi Cable Input
    │
    ▼
ASIO output layer
    ├── Native hardware ASIO driver ──► DAC / audio device
    └── ASIO4ALL WDM wrapper ─────────► DAC / audio device

Rate Switcher ── changes bit depth and sample rate ──► Hi-Fi Cable Input
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
.\AmazonMusicRateSwitcher.ps1 -Mode Restore
~~~

The project uses only relative project paths and `%LOCALAPPDATA%`; copy the folder to another Windows computer and run `setup.ps1` again.
