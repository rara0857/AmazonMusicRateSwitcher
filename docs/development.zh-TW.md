# 開發文件

[English](development.md) | 繁體中文

## 專案架構

本專案由 WinForms GUI 與 PowerShell backend 組成。正式版本固定使用以下輸出路徑：

`Amazon Music Exclusive → Hi-Fi Cable → ASIO Bridge → DAC`

Amazon Music 固定輸出到 Hi-Fi Cable Input；實體 DAC 請在 ASIO Bridge 或 ASIO4ALL panel 內選擇。

## 診斷與啟動

一般使用以 GUI 為主。CMD launcher 與 PowerShell backend 保留給診斷和進階測試：

```powershell
.\scripts\launchers\Start-AutoSwitch.cmd
.\scripts\launchers\Run-AutoTest.cmd
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Devices
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Probe
```

兩個 launcher 不要傳入 `direct` 參數；目前 release 只使用 Exclusive → Hi-Fi Cable → ASIO 路徑。

需要直接執行 backend 時，可使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\AmazonMusicRateSwitcher.ps1 -Mode Monitor -Apply -Cdp -CdpLaunch -AsioExclusive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\AmazonMusicRateSwitcher.ps1 -Mode AutoTest -TestTracks 10 -Cdp -CdpLaunch -AsioExclusive
```

`-Mode Restore` 可還原啟動前儲存的裝置格式。`-Mode Devices` 和 `-Mode Probe` 不會套用格式變更。

## 目前切歌流程

1. 透過 CDP 監控 Amazon 的 ASIN 與歌曲格式；CDP 不可用時退回 Amazon log。
2. Apply 模式在新歌曲格式確認前先暫停，避免不同格式歌曲先播放一小段。
3. 同格式歌曲：端點已符合目標格式，重新啟用 Exclusive 後立即恢復播放，不執行 seek、Previous 或端點重建，也不阻塞等待完整 playback telemetry。
4. 不同格式歌曲：暫停 → 調整 Hi-Fi Cable 格式 → 等待端點讀回 → seek 到 4.5 秒 → 立即按 Previous 回到目前歌曲開頭 → 確認仍在暫停狀態 → 重新啟用 Exclusive → 播放。seek 與 Previous 之間不再阻塞等待，只在播放前確認 Previous 後的狀態。

不同格式切換的主要延遲通常來自 Windows audio endpoint／DAC 重建；同格式切換的 latency 則只包含格式偵測、暫停與恢復播放路徑。

## AutoTest 與報告

GUI 的 `TEST & Config` 頁面可設定測試歌曲數量。AutoTest 會逐首檢查歌曲格式、端點格式、Exclusive 狀態和播放狀態，只有當前歌曲完成驗證後才進入下一首，並將結果寫入 `state/auto-test-latest.json` 與 `state/auto-test-summary.json`。

同格式 latency 不包含等待 Amazon 完整 playback／stream telemetry 的時間；若要查看各階段時間，可在 `config.json` 將 `showDetailedTiming` 設為 `true`。

`state` 目錄包含裝置備份、測試結果、runtime state 與 v4 已驗證格式 cache。資料只來自與 ASIN 關聯的最終格式，不再取歷史最高值；若 Amazon 暫時未寫出事件，程式會只靜音 Amazon、短暫初始化當前歌曲，再暫停並 seek 0 後保存確認結果。播放恢復後若驗證不符會自動刪除，舊版 cache 不會匯入。此目錄只保留在本機，不加入 Git。

## Build

安裝 .NET 6 Windows Desktop SDK 後，執行以下指令產生 self-contained x64 portable build：

```powershell
dotnet publish .\src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o .\artifacts\rate-fix-v1.0.0 --nologo
```

輸出位於 `artifacts/rate-fix-v1.0.0/`，發布結果只有 `AmazonMusicRateSwitcher.exe`。目前 GUI 執行時仍會尋找 repository 內的 `scripts`，因此 binary 是單檔，但整個應用尚不是不依賴 scripts 的完全獨立封裝。

## Repository 結構

- `src`：可維護的 WinForms GUI source
- `scripts`：PowerShell backend、setup 與 ASIO Bridge 管理腳本
- `scripts/launchers`：正式啟動與 AutoTest 的 CMD launcher
- `assets`：README 使用的圖片
- `config.json`：裝置比對、輪詢與診斷設定
- `artifacts`：本機 build output，不加入 Git
- `state`：裝置備份、runtime state 與測試報告，不加入 Git
- `tools/SoundVolumeView`：由 setup script 下載到本機，不加入 Git

## 測試環境

- Windows 11 64 位元，build 26200
- Amazon Music Store package 9.5.2.0／executable 9.5.2.2478
- PowerShell 5.1
- .NET 6 Windows Desktop SDK
- VB-Audio Hi-Fi Cable
- ASIO4ALL & FiiO ASIO Driver
