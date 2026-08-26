# 開發文件

[English](development.md) | 繁體中文

## 診斷

一般使用以 GUI 為主。CMD launcher 與 PowerShell backend 保留給診斷和進階測試：

```powershell
.\scripts\launchers\Start-AutoSwitch.cmd direct
.\scripts\launchers\Run-AutoTest.cmd direct
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Devices
.\scripts\AmazonMusicRateSwitcher.ps1 -Mode Probe
```

## Build

安裝 .NET 6 Windows Desktop SDK 後，執行以下指令產生 self-contained x64 版本：

```powershell
dotnet publish .\src\AmazonMusicRateSwitcher.Gui\AmazonMusicRateSwitcher.Gui.csproj -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true -o .\artifacts\win-x64
```

## Repository 結構

- `src`：可維護的 GUI source
- `scripts`：PowerShell backend 與 setup scripts
- `scripts/launchers`：選用的 CMD launcher
- `assets`：README 使用的圖片
- `artifacts`：本機 build output，不加入 Git
- `tools/SoundVolumeView`：由 setup script 下載到本機，不加入 Git

Runtime state、聆聽紀錄產生的 cache、測試報告、build output 和下載的第三方工具都不會加入 Git。

## 測試環境

- Windows 11 64 位元，build 26200
- Amazon Music Store package 9.5.2.0／executable 9.5.2.2478
- PowerShell 5.1
- VB-Audio Hi-Fi Cable
- ASIO4ALL
