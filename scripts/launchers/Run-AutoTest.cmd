@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
if /I "%~1"=="direct" goto direct

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\AmazonMusicRateSwitcher.ps1" -CheckInstance
if errorlevel 1 goto already_running
if not exist "%~dp0..\..\tools\SoundVolumeView\SoundVolumeView.exe" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\setup.ps1"
if errorlevel 1 goto setup_failed

rem Default mode: Hi-Fi Cable -> ASIO Bridge/ASIO4ALL -> DAC
if exist "%~dp0..\..\tools\SoundVolumeView\SoundVolumeView.exe" "%~dp0..\..\tools\SoundVolumeView\SoundVolumeView.exe" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Ensure-AsioBridge.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\AmazonMusicRateSwitcher.ps1" -Mode AutoTest -TestTracks 10 -Cdp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Ensure-AsioBridge.ps1" -Stop
goto end

:direct
rem Direct mode: Amazon -> the current Windows default render endpoint, without ASIO
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\AmazonMusicRateSwitcher.ps1" -CheckInstance
if errorlevel 1 goto already_running
if not exist "%~dp0..\..\tools\SoundVolumeView\SoundVolumeView.exe" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\setup.ps1"
if errorlevel 1 goto setup_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\AmazonMusicRateSwitcher.ps1" -Mode AutoTest -TestTracks 10 -Cdp -Direct
goto end

:already_running
echo.
echo Amazon Music Rate Switcher is already running.
goto end

:setup_failed
echo.
echo Dependency setup failed. Check the network connection and try again.

:end
echo.
echo AutoTest has stopped. Press any key to close.
pause
