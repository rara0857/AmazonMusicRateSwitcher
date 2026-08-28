# Amazon Music Rate Switcher

[English](README.md) | 繁體中文

Amazon Music Windows 版內建的獨佔模式不會依照歌曲的 sample rate 變更 DAC 輸出。
Rate Switcher 會讀取歌曲格式並自動切換，盡量減少不必要的 SRC。

**Audio path：** Amazon Music Exclusive → Hi-Fi Cable → ASIO Bridge → DAC

<p align="center">
  <img src="assets/app-preview.png?v=75235f8" width="350" alt="Amazon Music Rate Changer 桌面程式">
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

Physical DAC 請在 ASIO Bridge／ASIO4ALL panel 內選擇。本工具不會選 Windows Output Device。

## 快速開始

1. 安裝 [VB-Audio Hi-Fi CABLE & ASIO Bridge](https://vb-audio.com/Cable/)
2. 安裝 DAC ASIO Driver 或 [ASIO4ALL](https://asio4all.org/about/download-asio4all/)。
3. 下載 portable release，執行 `AmazonMusicRateSwitcher.exe`。
4. 在 Hi-Fi CABLE 選好 ASIO Driver，按 **START**。

執行 Test 前，請先開始播放，並確認 queue 後面至少還有 10 首可播放歌曲。

## 注意事項

- 格式變更通常會增加約 0.5～2 秒；同格式歌曲會立即開始。
- 測試環境：Windows 11 x64、Amazon Music for Windows 9.5.2.0。

## Credit

- 部分 UI 版面與使用流程參考了 [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher)。
- 本專案針對 Amazon Music for Windows 進行獨立實作。

自行 build 說明請見[開發文件](docs/development.zh-TW.md)。
