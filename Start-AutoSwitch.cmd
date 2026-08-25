@echo off
title Amazon Music Rate Switcher
if exist "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ensure-AsioBridge.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AmazonMusicRateSwitcher.ps1" -Mode Monitor -Apply -Cdp -CdpLaunch
echo.
echo The rate switcher has stopped. Press any key to close.
pause >nul
