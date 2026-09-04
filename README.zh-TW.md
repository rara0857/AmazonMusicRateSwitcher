# Amazon Music Rate Switcher

[English](README.md) | 繁體中文

Amazon Music Windows 版內建的獨佔模式不會依照歌曲的 sample rate/bit depth變更 DAC 輸出格式。

Rate Switcher 會讀取歌曲格式並自動切換，盡量減少不必要的 SRC。

**Audio path： Amazon Music Exclusive → Hi-Fi Cable → ASIO Bridge → DAC**

<p align="center">
  <img src="assets/app-preview.png?v=75235f8" width="350" alt="Amazon Music Rate Switcher 桌面程式">
</p>

<p align="center">
  <img src="assets/process.gif?v=20260828" width="640" alt="Amazon Music Rate Switcher 實際操作畫面">
</p>

## Features

- 依照每首歌自動切換 bit depth 與 sample rate。
- Amazon WASAPI Exclusive 透過 Hi-Fi Cable 輸出。
- ASIO Bridge 支援原生 ASIO driver 或 ASIO4ALL。
- GUI 顯示歌名、歌手、封面、format 與切換狀態。

## Output path

```mermaid
%%{init: {"themeVariables": {"fontSize": "22px"}}}%%
flowchart LR
  A[Amazon Music<br/>Exclusive] --> B[Hi-Fi Cable]
  B --> C[ASIO Bridge]
  C --> D[ASIO Driver<br/>or ASIO4ALL]
  D --> E[DAC]
```

## 快速開始

1. 安裝官方 Amazon Music for Windows 桌面版並登入。
2. 安裝 [VB-Audio Hi-Fi CABLE & ASIO Bridge](https://vb-audio.com/Cable/)
3. 安裝 DAC ASIO Driver 或 [ASIO4ALL](https://asio4all.org/about/download-asio4all/)。
4. 下載並完整解壓縮 [latest release](https://github.com/rara0857/AmazonMusicRateSwitcher/releases)，保持 EXE、`config.json` 與 `scripts` 資料夾位於同一層，再執行 `AmazonMusicRateSwitcher.exe`。
5. 在 ASIO Bridge 選好 ASIO Driver，按 **START**。

執行 Test 前，請先開始播放，並確認 queue 後面至少還有 10 首可播放歌曲。

## 注意事項

- 格式變更通常會增加約 0.5～2 秒。同格式歌曲不會增加端點切換時間，但 Amazon 本身的播放啟動時間仍可能波動。
- 有可用的 Debug／CDP 連線時會直接沿用；沒有時，程式可能會關閉並重新開啟 Amazon Music 一次以建立連線。
- 首次設定會下載核准的 SoundVolumeView v2.53，並在安裝前驗證 SHA-256。
- 測試環境：Windows 11 x64、Amazon Music for Windows 9.5.2.0。

## Credit

- 部分 UI 版面與使用流程參考了 [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher)。
- 本專案針對 Amazon Music for Windows 進行獨立實作。

自行 build 說明請見[開發文件](docs/development.zh-TW.md)。
