# Amazon Music Rate Switcher

[English](README.md) | 繁體中文

Amazon Music Windows 版的獨佔模式不會依照每首歌的原生音訊格式自動調整。這個工具會偵測目前歌曲的音訊格式，並自動調整 Windows 音訊設定，減少不必要的格式轉換。

<p align="center">
  <img src="assets/app-preview.png" width="220" alt="Amazon Music Rate Switcher 桌面程式">
</p>

## Features

- 依照目前歌曲自動切換音訊格式。
- 顯示歌名、歌手、封面、播放格式與切換狀態。
- 支援 ASIO 與 Direct 兩種輸出模式。
- 格式變更時自動重新播放目前歌曲，格式相同時不中斷播放。
- 內建 10 首歌曲的 AutoTest，提供測試結果。

## 快速開始

下載版程式是最簡單的使用方式：

1. 從[最新 GitHub Release](https://github.com/rara0857/AmazonMusicRateSwitcher/releases/latest) 下載 `AmazonMusicRateSwitcher-v1.0.0-portable.zip`。
2. 解壓縮後執行 `AmazonMusicRateSwitcher.exe`。
3. 按 **Start**。第一次使用時會自動安裝必要元件。

選 **ASIO** 會透過 Hi-Fi Cable 輸出；選 **Direct** 會使用 Windows 的一般輸出裝置。執行 AutoTest 前，請先播放音樂、開啟自動播放，並確認後面至少還有 10 首可播放歌曲。

## 使用提醒

使用 ASIO 時，其他程式的聲音可能會共用同一個 Hi-Fi Cable。播放期間請避免讓 YouTube、系統音效或其他音訊來源使用同一個裝置。

格式變更時會重新播放目前歌曲，通常增加約 0.5～1.5 秒；格式相同時不會中斷播放。

## 注意事項

- Amazon Music 更新後可能影響相容性。
- 可用的輸出裝置與音訊格式取決於 Windows 設定和音訊驅動程式。

## Credits

- 部分 UI 版面與使用流程參考了 [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher)。
- 本專案針對 Amazon Music for Windows 進行獨立實作。

開發、診斷與自行 build 的說明請見[開發文件](docs/development.zh-TW.md)。
