# Amazon Music Rate Switcher

English | [繁體中文](README.zh-TW.md)

Amazon Music's built-in Exclusive mode does not change the DAC output according to each song's sample rate.
Rate Switcher reads the track format and switches automatically to minimize unnecessary SRC.

**Audio path:** Amazon Music Exclusive → Hi-Fi Cable → ASIO Bridge → DAC

<p align="center">
  <img src="assets/app-preview.png?v=75235f8" width="350" alt="Amazon Music Rate Changer desktop app">
</p>

## Features

- Automatic bit-depth and sample-rate switching per track.
- Amazon WASAPI Exclusive on Hi-Fi Cable.
- Native ASIO driver or ASIO4ALL through ASIO Bridge.
- GUI track title, artist, artwork, format, and switch status.

## Output path

```mermaid
%%{init: {"themeVariables": {"fontSize": "22px"}}}%%
flowchart LR
  A[Amazon Music<br/>Exclusive] --> B[Hi-Fi Cable]
  B --> C[ASIO Bridge]
  C --> D[ASIO Driver<br/>or ASIO4ALL]
  D --> E[DAC]
```

## Quick start

1. Install [VB-Audio Hi-Fi CABLE & ASIO Bridge](https://vb-audio.com/Cable/).
2. Install a DAC ASIO driver or [ASIO4ALL](https://asio4all.org/about/download-asio4all/).
3. Download the [latest release](https://github.com/rara0857/AmazonMusicRateSwitcher/releases) and run `AmazonMusicRateSwitcher.exe`.
4. Select the ASIO driver in ASIO Bridge, then click **START**.

Before testing, start playback and leave at least 10 playable tracks in the queue.

## Notes

- A format change usually adds about 0.5–2 seconds; same-format tracks start immediately.
- When CDP/debug mode is enabled, the app may close and reopen the Amazon Music window once to establish the control connection.
- Tested on Windows 11 x64 with Amazon Music for Windows 9.5.2.0.

## Credit

- Some UI layout and workflow details were inspired by [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher).
- This project is an independent implementation for Amazon Music for Windows.

See the [development guide](docs/development.md) for self-build instructions.
