# Amazon Music Rate Switcher

[English](README.md) | 繁體中文（台灣）

依照目前 Amazon Music 曲目的位元深度與取樣率，自動切換 Windows 音訊輸出格式，減少不必要的 SRC。優先使用 Amazon CDP 播放狀態，無法使用時再讀取 AmazonMusic.log。

Amazon Music Windows 版的 Exclusive Mode 不會依照每首 track 自動切換 sample rate。如果所有 track 都固定使用同一個 output format，原生格式不同的 track 可能會經過 SRC。這個工具會依照 track format 切換 endpoint，目標是盡量減少不必要的轉換，但不代表一定 bit-perfect。

**Audio path：Amazon Music → Hi-Fi Cable → ASIO driver/ASIO4ALL → DAC**

在目前設定下，這條路徑等同 global ASIO path。播放 Amazon Music 時，請不要同時播放 YouTube、system sounds 或其他 audio source，避免搶占 ASIO 或 Hi-Fi Cable stream。

這是實驗性 Windows 工具，不是 Amazon 官方 API。

## 功能

- 切換格式後，以保留 queue 的方式重建同一首歌。
- 新曲格式與目前輸出格式相同時，不靜音、不 replay。
- ASIN／format verification 與 verified format cache。
- 可搭配 VB-Audio Hi-Fi Cable、ASIO Bridge 或 ASIO4ALL。
- AutoTest 會記錄每個 track 的 timing，並計算平均延遲。

## Related projects

這個專案的概念和 [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)、[Windows Lossless Switcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher) 類似：讀取目前播放中的 Apple Music track format，再把系統 output format 切到相同規格。

本專案則是 Amazon Music 專用實作，使用 Amazon ASIN metadata、CDP／player state、AmazonMusic.log，以及 queue-safe same-track replay。

## 測試環境

- Windows 11 64 位元，build 26200
- Amazon Music Store 套件版本：9.5.2.0
- Amazon Music 執行檔版本：9.5.2.2478
- Windows PowerShell 5.1
- VB-Audio Hi-Fi Cable + ASIO4ALL

其他 Amazon 或音訊驅動程式版本，可能會有不同的裝置名稱或 CDP 行為。

## 需求

- 已登入並正在播放的 Windows 版 Amazon Music。
- Windows PowerShell 5.1。
- 第一次 setup 時需要網路連線（會自動下載 SoundVolumeView）。
- 選用：VB-Audio Hi-Fi Cable、ASIO Bridge 或 ASIO4ALL。

## 安裝

在本資料夾執行一次：

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
~~~

`setup.ps1` 會把 SoundVolumeView 下載到專案的 `tools` 資料夾。Runtime state、播放紀錄、測試報告、device backup 與下載的第三方檔案都不會加入 Git。

## 使用

~~~powershell
# 讀取目前 Amazon format
.\AmazonMusicRateSwitcher.ps1 -Mode Probe

# 列出 audio output devices
.\AmazonMusicRateSwitcher.ps1 -Mode Devices

# 只 monitor，不切換 output format
.\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Cdp

# monitor 並套用 format switch
.\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Apply -Cdp

# 執行 queue-safe AutoTest
.\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 20 -Cdp
~~~

也可以使用 `Start-AutoSwitch.cmd`、`Run-AutoTest.cmd`、`Watch-DeviceFormat.cmd`。

AutoTest 結束時，console 會顯示 successful tracks、需要切換 format 的 tracks，以及 same-format tracks 的平均 latency。每首 track 的詳細結果保留在 `state/auto-test-latest.json`，統計結果寫入 `state/auto-test-summary.json`。

## AutoTest 注意事項

AutoTest 會透過 NextTrack 讓 Amazon Music 連續播放。開始前請先確認：

1. 已開啟 Amazon Music、完成登入，並且正在播放。
2. 已開啟 autoplay／continuous playback。
3. 目前 queue 後面有足夠的可播放 track。要測 20 首時，建議目前位置後面至少準備 20 首以上。
4. 測試期間不要手動操作 Amazon Music，也不要讓同一條 ASIO path 同時播放其他音訊。

如果 queue 播完，AutoTest 會回報 next-track timeout；這代表 queue 或播放設定不足，不代表 sample-rate switch 失敗。可以自行降低測試數量：

~~~powershell
.\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 5 -Cdp
~~~

CDP launch mode 會在需要時用 debugging port 啟動 Amazon Music。啟動過程可能會開啟或重開 Amazon Music，並重置目前的 queue。若已找到正在執行的 Amazon process 和可用的 CDP port，程式會優先沿用，不主動重開。想避免不必要的 relaunch，可以先開好 Amazon，再使用 -Cdp 而不要加 -CdpLaunch；找不到 debugging port 時，程式可以退回使用 AmazonMusic.log。

## 設定

編輯 `config.json`：

- deviceId：從 -Mode Devices 取得的 device ID，優先於其他選擇方式；留空則使用 Windows default output device。
- deviceNamePattern：選用的 wildcard pattern，例如 Hi-Fi Cable Input*。
- trackPollMilliseconds：track detection interval。
- waitForRebuildSeconds：等待 Amazon rebuild stream 的最長時間。
- showDetailedTiming：預設為 false，只顯示每首 track 的 total；設為 true 才會列出所有 timing stage。完整 timing 一律保留在 AutoTest JSON。

如果使用 Hi-Fi Cable，請把 Amazon Music 的 per-app output 設為 Hi-Fi Cable Input，再由 ASIO4ALL／ASIO Bridge 轉送到 hardware output。

## Audio flow

~~~text
Amazon Music
    │
    ▼
Hi-Fi Cable Input
    │
    ▼
ASIO output layer
    ├── native hardware ASIO driver ──► DAC／audio device
    └── ASIO4ALL WDM wrapper ─────────► DAC／audio device

Rate Switcher ── 修改 bit depth 與 sample rate ──► Hi-Fi Cable Input
~~~

### Native ASIO driver 與 ASIO4ALL

如果 audio device 有原廠 native ASIO driver，優先使用它。通常 path 較短、buffer control 較完整，也比較容易維持穩定的 sample rate switch。

ASIO4ALL 是把 WDM device 包裝成 ASIO interface 的 compatibility layer，適合沒有 native ASIO driver 的裝置。它多了一層 conversion；如果 WDM device 或設定不支援指定 format，仍可能發生 SRC。使用 ASIO4ALL 不代表一定能達到 bit-perfect。

如果 Amazon 仍是透過 Windows shared mode 送進 Hi-Fi Cable，換成 native ASIO 主要改善的是「bridge 到 audio device」這一段，不會讓 Amazon 本身變成 native ASIO，也不會自動讓整條 path 變成 exclusive mode。

## 限制

- 不使用 Amazon 內建 Exclusive Mode。
- Windows shared mode 仍可能 mix 或 process audio；output format 正確不代表整條 path 一定 bit-perfect。
- 切換 format 通常會增加約 0.5–1.5 秒延遲，等待 Amazon rebuild stream。
- ASIO4ALL 是 WDM wrapper，不是 hardware native ASIO；device 不支援指定 format 時仍可能 SRC。
- Amazon 更新可能改變 private CDP／player structure。

## 還原

~~~powershell
.\AmazonMusicRateSwitcher.ps1 -Mode Restore
~~~

專案只使用相對 project path 與 `%LOCALAPPDATA%`。複製整個資料夾到另一台 Windows 電腦後，再執行一次 `setup.ps1` 即可。
