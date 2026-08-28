@echo off
chcp 65001 >nul
title Amazon Music Rate Switcher

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

rem The Amazon side is fixed to Hi-Fi Cable Input. The physical DAC is chosen
rem in ASIO Bridge/ASIO4ALL, so no Windows Output Device selection is needed.
"%TOOL%" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\Ensure-AsioBridge.ps1"
if errorlevel 1 goto bridge_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\AmazonMusicRateSwitcher.ps1" -Mode Monitor -Apply -Cdp -CdpLaunch -AsioExclusive
set "EXIT_CODE=%ERRORLEVEL%"

rem Normal exit and the hidden Ensure-AsioBridge watcher both release the bridge.
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
echo The rate switcher has stopped. Press any key to close.
pause >nul
exit /b %EXIT_CODE%
