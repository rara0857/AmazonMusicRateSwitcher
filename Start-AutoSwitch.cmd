@echo off
chcp 65001 >nul
title Amazon Music Rate Switcher
if /I "%~1"=="direct" goto direct

rem Default mode: Hi-Fi Cable -> ASIO Bridge/ASIO4ALL -> DAC
if exist "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Ensure-AsioBridge.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\AmazonMusicRateSwitcher.ps1" -Mode Monitor -Apply -Cdp -CdpLaunch
goto end

:direct
rem Direct mode: Amazon -> the current Windows default render endpoint, without ASIO
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\AmazonMusicRateSwitcher.ps1" -Mode Monitor -Apply -Cdp -CdpLaunch -Direct

:end
echo.
echo The rate switcher has stopped. Press any key to close.
pause >nul
