@echo off
chcp 65001 >nul
title Amazon Music Rate Switcher - AutoTest
cd /d "%~dp0..\.."

if not "%~1"=="" (
    echo This release uses one output path: Amazon Exclusive -^> Hi-Fi Cable -^> ASIO.
    echo Select the physical DAC in ASIO Bridge or ASIO4ALL instead.
    echo.
    pause
    exit /b 2
)

set "ROOT=%~dp0..\.."
set "TOOL=%ROOT%\tools\SoundVolumeView\SoundVolumeView.exe"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\AmazonMusicRateSwitcher.ps1" -CheckInstance
if errorlevel 1 goto already_running

if not exist "%TOOL%" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\setup.ps1"
if errorlevel 1 goto setup_failed

rem Keep Amazon on Hi-Fi Cable Input; the ASIO driver owns physical output.
"%TOOL%" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\Ensure-AsioBridge.ps1"
if errorlevel 1 goto bridge_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\AmazonMusicRateSwitcher.ps1" -Mode AutoTest -TestTracks 10 -Cdp -CdpLaunch -AsioExclusive
set "EXIT_CODE=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\Ensure-AsioBridge.ps1" -Stop
goto end

:already_running
echo.
echo Amazon Music Rate Switcher is already running.
set "EXIT_CODE=3"
goto end

:setup_failed
echo.
echo Dependency setup failed. Check the network connection and try again.
set "EXIT_CODE=1"
goto end

:bridge_failed
echo.
echo ASIO Bridge could not be started. Check the ASIO Bridge installation.
set "EXIT_CODE=1"
goto end

:end
echo.
echo AutoTest has stopped. Press any key to close.
pause
exit /b %EXIT_CODE%
