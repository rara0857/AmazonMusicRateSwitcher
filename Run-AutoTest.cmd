@echo off
cd /d "%~dp0"
if exist "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" "%~dp0tools\SoundVolumeView\SoundVolumeView.exe" /SetAppDefault "VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render" all "Amazon Music.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ensure-AsioBridge.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AmazonMusicRateSwitcher.ps1" -Mode AutoTest -TestTracks 20 -Cdp
echo.
echo AutoTest has stopped. Press any key to close.
pause
