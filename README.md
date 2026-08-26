# Amazon Music Rate Switcher

English | [繁體中文](README.zh-TW.md)

Amazon Music for Windows does not automatically follow each track's original audio format in Exclusive Mode. This tool detects the current track's audio format and adjusts the Windows audio settings to reduce unnecessary format conversion. 

<p align="center">
  <img src="assets/app-preview.png" width="220" alt="Amazon Music Rate Switcher desktop app">
</p>

## Features

- Automatically adjusts the audio format for the current track.
- Shows the track title, artist, artwork, format, and switching status.
- Supports ASIO and Direct output modes.
- Replays the current track when the format changes and keeps playback uninterrupted when it does not.
- Includes a 10-track AutoTest with test results.

## Quick start

The packaged app is the easiest way to get started:

1. Download `AmazonMusicRateSwitcher-v1.0.0-portable.zip` from the [latest GitHub Release](https://github.com/rara0857/AmazonMusicRateSwitcher/releases/latest).
2. Extract it and run `AmazonMusicRateSwitcher.exe`.
3. Select **Start**. Required components are installed automatically on first use.

Choose **ASIO** to use Hi-Fi Cable output, or **Direct** to use the regular Windows output device. Before running AutoTest, start playback, enable autoplay, and make sure at least 10 playable tracks remain.

## Usage note

With ASIO, other programs may share the same Hi-Fi Cable. Avoid sending YouTube, system sounds, or other audio sources through the same device while listening.

When the format changes, the app replays the current track, which usually adds about 0.5–1.5 seconds. Tracks with the same format continue without interruption.

## Notes

- Amazon Music updates may affect compatibility.
- Available output devices and audio formats depend on Windows settings and audio drivers.

For development, diagnostics, and self-build instructions, see the [development guide](docs/development.md).
