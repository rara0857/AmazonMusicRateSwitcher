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
2. Apply 模式先給 Amazon 最多 900 ms 的格式辨識窗口，讓當前 playback instance 的 manifest 在不中斷 pipeline 的情況下完成。不同格式歌曲最多只會在這段有限時間內先出聲，之後會從零重新播放。
3. 同格式歌曲：播放與 Exclusive 都維持原狀，不執行暫停、seek、Previous、端點重建或 output-mode cycle。
4. 不同格式歌曲：暫停 → 調整 Hi-Fi Cable 格式 → 等待端點讀回 → seek 到 4.5 秒 → 立即按 Previous 回到目前歌曲開頭 → 確認仍在暫停狀態 → 重新啟用 Exclusive → 播放。seek 與 Previous 之間不再阻塞等待，只在播放前確認 Previous 後的狀態。

同格式歌曲只包含切換器的格式辨識與端點讀回成本，不會暫停或恢復播放。不同格式時間另外包含端點配對重設、Previous 重播、Exclusive 重新啟用及播放後嚴格驗證。Amazon 自身的 stream 啟動時間仍會波動，因此與切換器控制完成時間分開計算。

## AutoTest 與報告

GUI 的 `TEST & Config` 頁面可設定測試歌曲數量。AutoTest 會逐首檢查歌曲格式、端點格式、Exclusive 狀態和播放狀態，只有當前歌曲完成驗證後才進入下一首，並將結果寫入 `state/auto-test-latest.json` 與 `state/auto-test-summary.json`。

時間摘要不再混合不同語意的檢查點。`AverageSuccessfulSwitcherReadyMs` 是整體控制流程平均時間；`AverageSuccessfulSameFormatDecisionMs` 是同格式快速路徑平均時間；`AverageSuccessfulDifferentFormatMs` 是不同格式切換平均時間。`AverageSuccessfulSwitchConfirmedMs` 仍保留在 JSON 供嚴格 Playing-format 診斷使用；`AverageSuccessfulVerificationCompleteMs` 則是報告驗證完成時間。若要查看各階段，可在 `config.json` 將 `showDetailedTiming` 設為 `true`。

`state` 目錄包含裝置備份、測試結果、runtime state 與 v4 已驗證格式 cache。資料只來自與 ASIN 關聯的最終資料，不使用過期的 playback attributes。程式也能重用相同 ASIN 先前已完成 TrackBuilder instance 的完整品質列表；這和受目前端點限制的 selected fragment 不同，manifest 列表代表該歌曲實際提供的所有來源格式。兩者都沒有時，程式才會只靜音 Amazon、短暫初始化當前歌曲，再暫停並 seek 0 後保存確認結果。播放恢復後若驗證不符會自動刪除，舊版 cache 不會匯入。此目錄只保留在本機，不加入 Git。

## Build

安裝 .NET 10 Windows Desktop SDK；repository 內的 `global.json` 會選擇受支援的 SDK feature band。執行以下指令測試並建立經驗證的 self-contained x64 套件：

```powershell
dotnet test .\AmazonMusicRateSwitcher.sln -c Release
.\scripts\Build-Release.ps1
```

發版腳本會從 GUI project 讀取版本、發布單一 EXE、加入必要的 `config.json` 與三個 runtime script，並拒絕包含缺漏或額外檔案的 ZIP。GUI 執行時仍會尋找相鄰的 `scripts` 目錄，因此 binary 是單檔，但整個應用尚不是不依賴 scripts 的完全獨立封裝。

## Repository 結構

- `src`：可維護的 WinForms GUI source
- `tests`：GUI／backend typed protocol 的單元測試
- `scripts`：PowerShell backend、setup 與 ASIO Bridge 管理腳本
- `scripts/launchers`：正式啟動與 AutoTest 的 CMD launcher
- `assets`：README 使用的圖片
- `config.json`：裝置比對、輪詢與診斷設定
- `artifacts`：本機 build output，不加入 Git
- `state`：裝置備份、runtime state 與測試報告，不加入 Git
- `tools/SoundVolumeView`：由 setup script 下載到本機，不加入 Git
- `.github`：PR build、測試、相依套件更新及 release package 驗證

## 測試環境

- Windows 11 64 位元，build 26200
- Amazon Music Store package 9.5.2.0／executable 9.5.2.2478
- PowerShell 5.1
- .NET 10 Windows Desktop SDK
- VB-Audio Hi-Fi Cable
- ASIO4ALL & FiiO ASIO Driver
