param(
    [ValidateSet('Probe', 'Devices', 'Once', 'Monitor', 'AutoTest', 'Restore')]
    [string] $Mode = 'Probe',

    [switch] $Apply,

    [switch] $Cdp,

    [switch] $CdpLaunch,

    [string] $DeviceId,

    [ValidateRange(500, 5000)]
    [int] $RestartDelayMs = 0,

    [ValidateRange(1, 50)]
    [int] $TestTracks = 10
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ToolPath = Join-Path $PSScriptRoot 'tools\SoundVolumeView\SoundVolumeView.exe'
$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:StateDirectory = Join-Path $PSScriptRoot 'state'
$script:BackupPath = Join-Path $script:StateDirectory 'original-device-format.dat'
$script:StatePath = Join-Path $script:StateDirectory 'state.json'
$script:FormatCachePath = Join-Path $script:StateDirectory 'verified-format-cache.json'
New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
$script:LastUnmuteIssued = $true
$script:LastUnexpectedAsin = ''
$script:LastResyncSuccess = $false
$script:LastResyncTarget = ''
$script:CdpEnabled = $false
$script:CdpAllowLaunch = $false
$script:CdpPort = 0
$script:CdpWebSocketUrl = $null
$script:CdpLastError = ''
$script:CdpWasRelaunched = $false
$script:CdpFailureLogged = $false
$script:CdpLaunchAttempted = $false
$script:DeviceNamePattern = ''
$script:ShowDetailedTiming = $false
$script:AmazonLogPath = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\AmazonMobileLLC.AmazonMusic_*\LocalCache\Local\Amazon Music\Logs\AmazonMusic.log') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal sealed class MMDeviceEnumeratorComObject { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out uint state);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolume
{
    [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int GetChannelCount(out uint count);
    [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
    [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, ref Guid context);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
}

[ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPolicyConfigFormat
{
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool defaultFormat, out IntPtr format);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool defaultFormat, IntPtr defaultPeriod, IntPtr minimumPeriod);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr key, IntPtr value);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr key, IntPtr value);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool visible);
}

public static class CoreAudioEndpoint
{
    public static string GetDeviceFormat(string deviceId)
    {
        object instance = null;
        IntPtr format = IntPtr.Zero;
        try
        {
            Type type = Type.GetTypeFromCLSID(new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9"), true);
            instance = Activator.CreateInstance(type);
            int hr = ((IPolicyConfigFormat)instance).GetDeviceFormat(deviceId, false, out format);
            if (hr < 0 || format == IntPtr.Zero) Marshal.ThrowExceptionForHR(hr);
            int channels = (ushort)Marshal.ReadInt16(format, 2);
            int rate = Marshal.ReadInt32(format, 4);
            int containerBits = (ushort)Marshal.ReadInt16(format, 14);
            int cbSize = (ushort)Marshal.ReadInt16(format, 16);
            int tag = (ushort)Marshal.ReadInt16(format, 0);
            int validBits = (tag == 0xFFFE && cbSize >= 22) ? (ushort)Marshal.ReadInt16(format, 18) : containerBits;
            int bits = validBits > 0 ? validBits : containerBits;
            return String.Format("{0} Channel, {1} bit, {2} Hz", channels, bits, rate);
        }
        catch { return null; }
        finally
        {
            if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
            if (instance != null && Marshal.IsComObject(instance)) Marshal.ReleaseComObject(instance);
        }
    }

    public static bool SetMute(string deviceId, bool muted)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object instance = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr < 0 || device == null) Marshal.ThrowExceptionForHR(hr);
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 23u, IntPtr.Zero, out instance); // CLSCTX_ALL
            if (hr < 0 || instance == null) Marshal.ThrowExceptionForHR(hr);
            Guid context = Guid.Empty;
            hr = ((IAudioEndpointVolume)instance).SetMute(muted, ref context);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            return true;
        }
        catch { return false; }
        finally
        {
            if (instance != null && Marshal.IsComObject(instance)) Marshal.ReleaseComObject(instance);
            if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }
}

public static class AmazonMediaCommands
{
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    public static void TogglePlayback(IntPtr mainWindow)
    {
        // WM_APPCOMMAND / APPCOMMAND_MEDIA_PLAY_PAUSE
        PostMessage(mainWindow, 0x0319, mainWindow, new IntPtr(14 << 16));
    }

    public static void RestartCurrentTrack(IntPtr mainWindow)
    {
        // WM_APPCOMMAND / APPCOMMAND_MEDIA_PREVIOUSTRACK. When playback is a few
        // seconds into a song Amazon treats this as restart-current, not skip-back.
        PostMessage(mainWindow, 0x0319, mainWindow, new IntPtr(12 << 16));
    }

    public static void NextTrack(IntPtr mainWindow)
    {
        // WM_APPCOMMAND / APPCOMMAND_MEDIA_NEXTTRACK
        PostMessage(mainWindow, 0x0319, mainWindow, new IntPtr(11 << 16));
    }

}
'@

# Minimal Chrome DevTools Protocol client.  Amazon Music is a CEF app; its
# internal Player API is reachable only through the renderer's CDP websocket.
# Keep this client synchronous so it works in both Windows PowerShell 5.1 and
# PowerShell 7 without requiring an extra module.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class AmazonCdp
{
    private static readonly object Gate = new object();
    private static ClientWebSocket Socket;
    private static string SocketUrl;
    private static int NextId;

    private static string JsonEscape(string value)
    {
        return value.Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\r", "\\r")
            .Replace("\n", "\\n")
            .Replace("\t", "\\t");
    }

    private static void ResetSocket()
    {
        var socket = Socket;
        Socket = null;
        SocketUrl = null;
        if (socket == null) return;
        try { socket.Abort(); } catch { }
        try { socket.Dispose(); } catch { }
    }

    private static void EnsureSocket(string websocketUrl)
    {
        if (Socket != null && Socket.State == WebSocketState.Open &&
            String.Equals(SocketUrl, websocketUrl, StringComparison.Ordinal)) return;

        ResetSocket();
        var socket = new ClientWebSocket();
        // CEF 79 closes the DevTools socket when it receives .NET's default
        // keepalive ping.  The monitor's own polling is the liveness check.
        socket.Options.KeepAliveInterval = TimeSpan.Zero;
        using (var connectTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
        {
            socket.ConnectAsync(new Uri(websocketUrl), connectTimeout.Token).GetAwaiter().GetResult();
        }
        Socket = socket;
        SocketUrl = websocketUrl;
    }

    private static string ReceiveMessage(ClientWebSocket socket)
    {
        var output = new MemoryStream();
        var buffer = new byte[8192];
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            WebSocketReceiveResult result;
            // Runtime.evaluate may intentionally await Amazon's renderer for
            // up to five seconds while a DRM stream is rebuilt.  A two-second
            // receive timeout tore down a healthy socket at the slow tail,
            // forced a reconnect, and repeated the verification request.
            using (var receiveTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(7)))
            {
                result = socket.ReceiveAsync(new ArraySegment<byte>(buffer), receiveTimeout.Token)
                    .GetAwaiter().GetResult();
            }
            if (result.MessageType == WebSocketMessageType.Close)
                throw new InvalidOperationException("CDP websocket closed.");
            output.Write(buffer, 0, result.Count);
            if (result.EndOfMessage)
                return Encoding.UTF8.GetString(output.ToArray());
        }
        throw new TimeoutException("CDP did not respond.");
    }

    public static string Evaluate(string websocketUrl, string expression)
    {
        lock (Gate)
        {
            try
            {
                EnsureSocket(websocketUrl);
                var socket = Socket;
                var id = Interlocked.Increment(ref NextId);
                string request = "{\"id\":" + id + ",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" +
                    JsonEscape(expression) + "\",\"returnByValue\":true,\"awaitPromise\":true}}";
                byte[] payload = Encoding.UTF8.GetBytes(request);
                using (var sendTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
                {
                    socket.SendAsync(new ArraySegment<byte>(payload), WebSocketMessageType.Text, true, sendTimeout.Token)
                        .GetAwaiter().GetResult();
                }

                while (true)
                {
                    string message = ReceiveMessage(socket);
                    // CDP may interleave protocol events with the response.
                    // There is one outstanding call under Gate, so an exact
                    // id token is sufficient and avoids a JSON dependency in
                    // Windows PowerShell/.NET Framework.
                    if (message.IndexOf("\"id\":" + id, StringComparison.Ordinal) >= 0)
                        return message;
                }
            }
            catch
            {
                ResetSocket();
                throw;
            }
        }
    }
}
'@

# Do not use AppsFolder/COM activation for CDP relaunch: on some Store builds it
# silently drops the debug argument.  The working Store/CEF path is the same one
# used by Amazon-Music-SMTC-Bridge: stop the Amazon Music browser/renderer
# processes, then launch the packaged executable through
# Invoke-CommandInDesktopPackage with the debug argument.

function Write-Log {
    param([string] $Message, [ConsoleColor] $Color = [ConsoleColor]::Gray)
    Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message) -ForegroundColor $Color
}

function Import-VerifiedFormatCache {
    $map = @{}
    if (-not (Test-Path -LiteralPath $script:FormatCachePath)) { return $map }
    try {
        # Windows PowerShell 5.1 can preserve the JSON root array as one
        # pipeline object when ConvertFrom-Json is nested directly inside @().
        # Assign first so foreach enumerates individual cache records.
        $entries = Get-Content -LiteralPath $script:FormatCachePath -Raw | ConvertFrom-Json
        foreach ($entry in $entries) {
            $asin = ([string]$entry.Asin).ToUpperInvariant()
            $bits = [int]($entry.Bits)
            $rateHz = [int]($entry.RateHz)
            if ($asin -match '^[A-Z0-9]+$' -and $bits -in @(16, 24, 32) -and $rateHz -gt 0) {
                $map[$asin] = [pscustomobject]@{
                    Text = '{0} bit / {1:g} kHz' -f $bits, ([double]$rateHz / 1000)
                    Bits = $bits
                    RateHz = $rateHz
                    Quality = [string]$entry.Quality
                }
            }
        }
    } catch {
        Write-Log "The verified format cache could not be read; rebuilding it: $($_.Exception.Message)" Yellow
    }
    return $map
}

function Save-VerifiedFormatCacheEntry {
    param(
        [Parameter(Mandatory)] [hashtable] $Map,
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] $Format
    )
    $asinKey = $Asin.ToUpperInvariant()
    $old = if ($Map.ContainsKey($asinKey)) { $Map[$asinKey] } else { $null }
    if ($old -and [int]($old.Bits) -eq [int]($Format.Bits) -and [int]($old.RateHz) -eq [int]($Format.RateHz)) { return }

    $Map[$asinKey] = [pscustomobject]@{
        Text = [string]$Format.Text
        Bits = [int]($Format.Bits)
        RateHz = [int]($Format.RateHz)
        Quality = [string]$Format.Quality
    }
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $rows = foreach ($key in @($Map.Keys | Sort-Object)) {
        $item = $Map[$key]
        [pscustomobject]@{
            Asin = $key
            Bits = [int]($item.Bits)
            RateHz = [int]($item.RateHz)
            Quality = [string]$item.Quality
        }
    }
    $rows | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:FormatCachePath -Encoding utf8
}

function Get-MainWindow {
    $process = Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue |
        Where-Object MainWindowHandle -ne 0 |
        Select-Object -First 1
    if (-not $process) { throw 'Amazon Music main window was not found. Start the desktop app first.' }
    return $process
}

function Test-AmazonCdpPort {
    param([Parameter(Mandatory)][int] $Port)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri ("http://127.0.0.1:{0}/json/version" -f $Port)
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Find-AmazonCdpPort {
    $files = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\AmazonMobileLLC.AmazonMusic_*\LocalCache\Local\Amazon Music\Data\App Cache\DevToolsActivePort'),
        (Join-Path $env:LOCALAPPDATA 'Amazon Music\Data\App Cache\DevToolsActivePort')
    )
    foreach ($pattern in $files) {
        foreach ($file in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
            try {
                $port = [int](Get-Content -LiteralPath $file.FullName -TotalCount 1)
                if ($port -gt 0 -and (Test-AmazonCdpPort $port)) { return $port }
            } catch {
            }
        }
    }

    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='Amazon Music.exe'" -ErrorAction SilentlyContinue)) {
        if ($process.CommandLine -match '(?i)--remote-debugging-port=(?<port>\d+)') {
            $port = [int]$Matches.port
            if ($port -gt 0 -and (Test-AmazonCdpPort $port)) { return $port }
        }
    }
    return 0
}

function Get-FreeAmazonCdpPort {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $port = Get-Random -Minimum 49152 -Maximum 65535
        $listener = $null
        try {
            $listener = New-Object -TypeName Net.Sockets.TcpListener -ArgumentList @([Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        } catch {
        } finally {
            if ($listener) { $listener.Stop() }
        }
    }
    return 9222
}

function Start-AmazonWithCdp {
    param([Parameter(Mandatory)][int] $Port)

    $script:CdpLaunchAttempted = $true
    $processes = @(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    # CEF's browser, renderer and GPU children all use this executable.  Give
    # the normal close path a short grace period, then force-stop every
    # remaining Amazon Music.exe process (the separate Amazon Music Helper is
    # intentionally left alone, matching the GitHub reference implementation).
    $deadline = (Get-Date).AddSeconds(4)
    while (@(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    $killDeadline = (Get-Date).AddSeconds(5)
    do {
        $remaining = @(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue)
        foreach ($process in $remaining) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 250 }
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $killDeadline)
    if (@(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log 'The Amazon Music process tree could not be stopped before the CDP relaunch; using the fallback path.' Yellow
        return $false
    }
    # Give the package broker one scheduling turn after the last CEF child exits;
    # otherwise Store activation may hand the debug argument to a still-closing
    # instance and silently start a normal (non-CDP) window instead.
    Start-Sleep -Milliseconds 750

    try {
        $package = Get-AppxPackage -Name AmazonMobileLLC.AmazonMusic | Select-Object -First 1
        if (-not $package) { throw 'The Microsoft Store Amazon Music package was not found.' }
        $application = (Get-AppxPackageManifest $package).Package.Applications.Application | Select-Object -First 1
        $exe = Join-Path $package.InstallLocation $application.Executable
        if (-not (Test-Path -LiteralPath $exe)) { throw "Amazon executable was not found: $exe" }

        function Quote-CommandLiteral([string] $value) {
            return "'" + ($value -replace "'", "''") + "'"
        }
        $command = @(
            'Invoke-CommandInDesktopPackage',
            '-PackageFamilyName', (Quote-CommandLiteral $package.PackageFamilyName),
            '-AppId', (Quote-CommandLiteral $application.Id),
            '-Command', (Quote-CommandLiteral $exe),
            '-Args', (Quote-CommandLiteral "--remote-debugging-port=$Port")
        ) -join ' '
        # Amazon's native AWS SDK tries to create aws_sdk_*.log in the inherited
        # working directory.  Launch from the read-only package directory instead
        # of the switcher's/output directory so those empty files are not emitted
        # beside the script.
        Push-Location -LiteralPath $package.InstallLocation
        try {
            $invokeOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1)
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            $details = ($invokeOutput | ForEach-Object { $_.ToString() }) -join ' '
            throw "Invoke-CommandInDesktopPackage exit $LASTEXITCODE`: $details"
        }
        Write-Log "Started Amazon through Store package activation; waiting for CDP port $Port." DarkGray
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            if (Test-AmazonCdpPort $Port) { return $true }
            Start-Sleep -Milliseconds 250
        }
        throw 'The CDP port did not respond within 30 seconds.'
    } catch {
        Write-Log "CDP relaunch failed: $($_.Exception.Message); using the fallback path." Yellow
        return $false
    }
}

function Restart-AmazonNormallyAfterCdpFailure {
    if (-not $script:CdpLaunchAttempted) { return }

    # Start-AmazonWithCdp closed every existing Amazon process before it
    # launched the debug instance, so it is safe to clean up that instance
    # when its renderer never mounted the web app.  This prevents a blank
    # splash window from being left behind after CDP fallback.
    foreach ($process in @(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue)) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $deadline = (Get-Date).AddSeconds(5)
    while (@(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
    }
    foreach ($process in @(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }

    try {
        $package = Get-AppxPackage -Name AmazonMobileLLC.AmazonMusic | Select-Object -First 1
        $application = (Get-AppxPackageManifest $package).Package.Applications.Application | Select-Object -First 1
        $appUri = "shell:AppsFolder\$($package.PackageFamilyName)!$($application.Id)"
        Start-Process $appUri | Out-Null
        Write-Log 'CDP launch did not complete the Amazon web app; closed the stuck instance and used normal Store activation.' Yellow
    } catch {
        Write-Log "Amazon could not be restarted after the CDP launch failed: $($_.Exception.Message)" Yellow
    }
}

function Get-AmazonCdpPageWebSocket {
    param([Parameter(Mandatory)][int] $Port)
    try {
        $targets = @(Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri ("http://127.0.0.1:{0}/json/list" -f $Port)).Content | ConvertFrom-Json
        $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl } |
            Where-Object { $_.url -match '#/' } | Select-Object -First 1)
        if (-not $page) { $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl } | Select-Object -First 1) }
        if ($page) { return [string]$page.webSocketDebuggerUrl }
    } catch {
    }
    return $null
}

function Initialize-AmazonCdp {
    if (-not $script:CdpEnabled) { return $false }
    if ($script:CdpWebSocketUrl) { return $true }

    # Reuse a live debug instance first, even when -CdpLaunch was requested.
    # Test-AmazonCdpPort verifies /json/version, so a stale DevToolsActivePort
    # file or dead process cannot suppress the relaunch.  This preserves the
    # current window, playback position and native queue on repeated starts of
    # the switcher.
    $port = Find-AmazonCdpPort
    if ($port) {
        Write-Log "Found an existing Amazon CDP port $port; reusing the current process without restarting Amazon." DarkGray
    } elseif ($script:CdpAllowLaunch -and -not $script:CdpLaunchAttempted) {
        $port = Get-FreeAmazonCdpPort
        if (-not (Start-AmazonWithCdp -Port $port)) {
        $script:CdpLastError = 'Amazon has no usable CDP port.'
            return $false
        }
        $script:CdpWasRelaunched = $true
        # The port appears as soon as the CEF renderer starts, but Amazon's
        # native bridge and Vue app mount a little later.  Attaching in that
        # window is the reproducible cause of the splash/logo lock.  Keep the
        # HTTP-only wait out of the renderer and let the app finish booting.
        Start-Sleep -Seconds 5
    } elseif (-not $script:CdpAllowLaunch) {
        $script:CdpLastError = 'No existing Amazon CDP port was found; Amazon will not be restarted automatically to avoid a Store splash-screen hang.'
        return $false
    } else {
        $script:CdpLastError = 'The Amazon CDP relaunch was attempted but no usable port was found.'
        return $false
    }

    $deadline = (Get-Date).AddSeconds(20)
    do {
        $url = Get-AmazonCdpPageWebSocket -Port $port
        if ($url) {
            try {
                # A CDP websocket can be available while Amazon's page is
                # still only its native splash.  Require the Vue transport
                # root before accepting the connection; otherwise later
                # player calls would fail against an empty document.
                $probeExpression = "JSON.stringify({ready:document.readyState,app:!!document.querySelector('#app'),transport:!!document.querySelector('#transportContainer'),bodyLength:(document.body&&document.body.innerText||'').length})"
                $probe = [AmazonCdp]::Evaluate($url, $probeExpression) | ConvertFrom-Json
                $state = $probe.result.result.value | ConvertFrom-Json
                if ($state.app -or $state.transport) {
                    $script:CdpPort = $port
                    $script:CdpWebSocketUrl = $url
                    Write-Log "CDP connected on port $port; queue-safe same-track replay is enabled." Green
                    return $true
                }
            } catch {
                $script:CdpLastError = $_.Exception.Message
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    $script:CdpLastError = 'The Amazon renderer has a CDP port, but the web app is not mounted (splash screen or native bridge initialization).'
    if ($script:CdpWasRelaunched) {
        Restart-AmazonNormallyAfterCdpFailure
    }
    return $false
}

function Invoke-AmazonCdpExpression {
    param([Parameter(Mandatory)][string] $Expression)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        if (-not (Initialize-AmazonCdp)) { throw $script:CdpLastError }
        try {
            $response = [AmazonCdp]::Evaluate($script:CdpWebSocketUrl, $Expression) | ConvertFrom-Json
            $value = $response.result.result.value
            if ($null -eq $value) {
                $description = $response.result.result.description
                throw "CDP evaluation returned no value: $description"
            }
            return $value
        } catch {
            $lastError = $_.Exception
            $script:CdpLastError = $lastError.Message
            $script:CdpWebSocketUrl = $null
            if ($attempt -eq 0) { Start-Sleep -Milliseconds 100 }
        }
    }
    throw $lastError
}

function ConvertTo-CdpFormat {
    param($Bits, $RateHz)
    if ([int]$Bits -le 0 -or [int]$RateHz -le 0) { return $null }
    return [pscustomobject]@{
        Text = '{0} bit / {1:g} kHz' -f [int]$Bits, ([double][int]$RateHz / 1000)
        Bits = [int]$Bits
        RateHz = [int]$RateHz
    }
}

function Get-AmazonCdpSnapshot {
    $expression = @'
(()=>{const e=document.getElementById('transportContainer'),v=e&&e.__vue__,p=v&&v.$store&&v.$store.state&&v.$store.state.player,m=p&&p.model,cp=m&&m.currentPlayable,t=cp&&cp.track,a=m&&m.audioAttributes,c=m&&m.deviceCapabilities;return JSON.stringify({ready:!!t,asin:t&&t.asin||'',title:t&&t.title||'',artist:t&&t.artist&&t.artist.name||'',state:m&&m.state||'',positionMs:p&&p.progress&&p.progress.currentTime||0,track:{bits:a&&a.bestAvailableBitDepth||0,rate:a&&a.bestAvailableSampleRate||0},playing:{bits:a&&a.bitDepth||0,rate:a&&a.sampleRate||0},capability:{bits:c&&c.maxBitDepth||0,rate:c&&c.maxSampleRate||0}})})()
'@
    $data = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
    if (-not $data.ready) { return $null }
    return [pscustomobject]@{
        Process = Get-MainWindow
        Asin = [string]$data.asin
        Title = [string]$data.title
        Artist = [string]$data.artist
        Track = ConvertTo-CdpFormat $data.track.bits $data.track.rate
        DeviceCapability = ConvertTo-CdpFormat $data.capability.bits $data.capability.rate
        Playing = ConvertTo-CdpFormat $data.playing.bits $data.playing.rate
        PositionMs = [int64]$data.positionMs
        State = [string]$data.state
        Raw = $data
        Source = 'Amazon CDP Player API'
    }
}

function Wait-AmazonCdpSettledTrackFormat {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [int] $TimeoutMilliseconds = 500
    )

    # currentPlayable changes before audioAttributes.  The player's first
    # positive progress update is emitted only after the fresh attributes have
    # been committed (measured on this Amazon build: ASIN about 73 ms, attributes
    # about 198 ms, progress about 238 ms).  Wait inside the renderer in one CDP
    # request: repeated PowerShell -> websocket round trips cost ~100 ms each.
    $asinJson = ConvertTo-Json $Asin.ToUpperInvariant() -Compress
    $expression = @"
(async()=>{
  const expected=$asinJson,deadline=Date.now()+$TimeoutMilliseconds;
  while(Date.now()<deadline){
    const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
    const p=v&&v.`$store&&v.`$store.state&&v.`$store.state.player,m=p&&p.model,cp=m&&m.currentPlayable,t=cp&&cp.track,a=m&&m.audioAttributes;
    const position=p&&p.progress&&p.progress.currentTime||0;
    if(t&&String(t.asin||'').toUpperCase()===expected&&position>0&&a&&a.bestAvailableBitDepth>0&&a.bestAvailableSampleRate>0&&a.bitDepth>0&&a.sampleRate>0)
      return JSON.stringify({ok:true,bits:a.bestAvailableBitDepth,rate:a.bestAvailableSampleRate});
    await new Promise(r=>setTimeout(r,10));
  }
  return JSON.stringify({ok:false});
})()
"@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        if ($result.ok) { return ConvertTo-CdpFormat $result.bits $result.rate }
    } catch {
    }
    return $null
}

function Invoke-AmazonCdpNextTrack {
    $expression = @'
(()=>{const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;if(!v)return JSON.stringify({ok:false,error:'Transport component not found'});try{const r=v.handleNextButton();return Promise.resolve(r).then(()=>JSON.stringify({ok:true})).catch(e=>JSON.stringify({ok:false,error:String(e)}))}catch(e){return JSON.stringify({ok:false,error:String(e)})}})()
'@
    $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
    if (-not $result.ok) { throw "Amazon PlayNext failed: $($result.error)" }
    return $result
}

function Invoke-AmazonCdpFastRestartCurrentTrack {
    param([Parameter(Mandatory)] [string] $ExpectedAsin)
    $expectedJson = ConvertTo-Json $ExpectedAsin.ToUpperInvariant() -Compress
    $expression = @'
(async()=>{
  const expected=__EXPECTED_ASIN__;
  const started=Date.now();
  const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
  if(!v||typeof v.dragFinished!=='function'||typeof v.handlePreviousButton!=='function')
    return JSON.stringify({ok:false,error:'Transport seek/Previous methods were not found'});
  const p=v.$store&&v.$store.state&&v.$store.state.player;
  const read=()=>{const m=p&&p.model||{},t=m.currentPlayable&&m.currentPlayable.track,d=Number(m.duration)||((Number(t&&t.duration)||0)*1000);return {asin:t&&t.asin||'',position:p&&p.progress&&p.progress.currentTime||0,duration:d,hasNext:!!v.hasNext}};
  let before=read(),readyDeadline=Date.now()+1000;
  while(Date.now()<readyDeadline&&(before.asin!==expected||before.duration<5000)){await new Promise(r=>setTimeout(r,10));before=read()}
  if(before.asin!==expected)
    return JSON.stringify({ok:false,error:'The current ASIN has not synchronized with the expected track',expected:expected,before:before});
  let now=read(),mode='seek';
  if(before.duration>=5000){
    const target=4000;
    v.dragFinished(Math.min(90,target/before.duration*100));
    let deadline=Date.now()+1200;
    while(Date.now()<deadline&&now.asin===before.asin&&now.position<3000){await new Promise(r=>setTimeout(r,15));now=read()}
    if(now.asin!==before.asin)
      return JSON.stringify({ok:false,error:'The track changed during seek',before:before,sought:now});
    if(now.position<3000)
      return JSON.stringify({ok:false,error:'Native seek did not reach the safe Previous threshold',before:before,sought:now});
  }else{
    // Some tracks publish track.duration before model.duration; read() handles
    // both.  If neither exists, progress itself is the authoritative Previous
    // gate.  The 3.5 s deadline is measured from function entry, so this does
    // not repeat the old one-second readiness wait plus another 3.5 seconds.
    mode='progress-gate';
    const safeDeadline=started+3500;
    while(Date.now()<safeDeadline&&now.asin===before.asin&&now.position<3000){await new Promise(r=>setTimeout(r,10));now=read()}
    if(now.asin!==before.asin)
      return JSON.stringify({ok:false,error:'The track changed while waiting for the safe progress threshold',before:before,sought:now});
    if(now.position<3000)
      return JSON.stringify({ok:false,error:'Track duration is unknown and playback did not reach the safe Previous threshold',before:before,sought:now});
  }
  await Promise.resolve(v.handlePreviousButton());
  let deadline=Date.now()+1600,after=read();
  while(Date.now()<deadline&&after.asin===before.asin&&after.position>1000){await new Promise(r=>setTimeout(r,15));after=read()}
  if(after.asin!==before.asin)
    return JSON.stringify({ok:false,error:'Previous selected a different track',before:before,sought:now,after:after});
  if(after.position>1000)
    return JSON.stringify({ok:false,error:'Previous did not return to the start of the track',before:before,sought:now,after:after});
  return JSON.stringify({ok:true,asin:before.asin,soughtMs:now.position,positionMs:after.position,hasNext:after.hasNext,mode:mode});
})()
'@
    $expression = $expression.Replace('__EXPECTED_ASIN__', $expectedJson)
    $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
    if (-not $result.ok) { throw "Amazon fast same-track replay failed: $($result.error)" }
    return $result
}

function Wait-AmazonCdpFormat {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)][string] $Asin,
        [int] $TimeoutMilliseconds = 5000
    )
    # Wait inside Amazon's renderer in a single CDP request.  The previous
    # PowerShell loop made a full websocket round trip and rebuilt a snapshot
    # every 50 ms, adding scheduling jitter after Playing was already correct.
    $asinJson = ConvertTo-Json $Asin.ToUpperInvariant() -Compress
    $bits = [int]$Target.Bits
    $rate = [int]$Target.RateHz
    $expression = @"
(async()=>{
  const expected=$asinJson,bits=$bits,rate=$rate,deadline=Date.now()+$TimeoutMilliseconds;
  while(Date.now()<deadline){
    const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
    const p=v&&v.`$store&&v.`$store.state&&v.`$store.state.player,m=p&&p.model,t=m&&m.currentPlayable&&m.currentPlayable.track,a=m&&m.audioAttributes;
    if(t&&String(t.asin||'').toUpperCase()===expected&&a&&Number(a.bitDepth)===bits&&Number(a.sampleRate)===rate)
      return JSON.stringify({ok:true,asin:String(t.asin||''),title:String(t.title||''),bits:Number(a.bitDepth),rate:Number(a.sampleRate)});
    await new Promise(r=>setTimeout(r,10));
  }
  return JSON.stringify({ok:false});
})()
"@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        if ($result.ok) {
            return [pscustomobject]@{
                Asin = [string]$result.asin
                Title = [string]$result.title
                Playing = ConvertTo-CdpFormat $result.bits $result.rate
            }
        }
    } catch {
    }
    return $null
}

function Get-AmazonLogLength {
    if (-not $script:AmazonLogPath -or -not (Test-Path -LiteralPath $script:AmazonLogPath)) { return 0L }
    return [int64](Get-Item -LiteralPath $script:AmazonLogPath).Length
}

function Read-AmazonLogRange {
    param([int64] $StartOffset = 0)
    if (-not $script:AmazonLogPath -or -not (Test-Path -LiteralPath $script:AmazonLogPath)) { return '' }
    $stream = [IO.File]::Open($script:AmazonLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek([Math]::Min([Math]::Max(0, $StartOffset), $stream.Length), [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function ConvertFrom-AmazonAudioQuality {
    param([string] $Quality)
    if ($Quality -notmatch '^(?<tier>U?HD)(?<rate>44|48|88|96|176|192)$') { return $null }
    $rateHz = switch ($Matches.rate) {
        '44' { 44100 }; '48' { 48000 }; '88' { 88200 }; '96' { 96000 }
        '176' { 176400 }; '192' { 192000 }
    }
    $bits = if ($Matches.tier -eq 'HD') { 16 } else { 24 }
    return [pscustomobject]@{
        Text = '{0} bit / {1:g} kHz' -f $bits, ([double]$rateHz / 1000)
        Bits = $bits
        RateHz = $rateHz
        Quality = $Quality
    }
}

function Update-AsinQualityMap {
    param([hashtable] $Map, [string] $Text)
    $matches = [regex]::Matches($Text, 'Track:\s*asin://(?<asin>[A-Z0-9]+).*?AudioQuality:\s*(?<quality>U?HD(?:44|48|88|96|176|192))', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $matches) {
        $asin = $match.Groups['asin'].Value.ToUpperInvariant()
        $format = ConvertFrom-AmazonAudioQuality $match.Groups['quality'].Value.ToUpperInvariant()
        if ($format -and (-not $Map.ContainsKey($asin) -or [int]$Map[$asin].RateHz -lt $format.RateHz -or [int]$Map[$asin].Bits -lt $format.Bits)) {
            $Map[$asin] = $format
        }
    }
}

function Get-AmazonSelectedFormat {
    param([Parameter(Mandatory)][string] $Asin)
    $length = Get-AmazonLogLength
    $text = Read-AmazonLogRange -StartOffset ([Math]::Max(0, $length - 2097152))
    $pattern = 'Fetching fragment:\s*<Track:\s*asin://' + [regex]::Escape($Asin) + ':.*?AudioQuality:\s*(?<quality>U?HD(?:44|48|88|96|176|192))'
    $matches = [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -eq 0) { return $null }
    return ConvertFrom-AmazonAudioQuality $matches[$matches.Count - 1].Groups['quality'].Value.ToUpperInvariant()
}

function Wait-AmazonCorrelatedTrackFormat {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] [int64] $AfterOffset,
        [int] $TimeoutMilliseconds = 1400
    )

    # CDP updates currentPlayable before it updates audioAttributes.  Reading
    # both properties in that short window pairs the new ASIN with the previous
    # song's format.  AmazonMusic.log gives us an ordering boundary: accept only
    # the first non-zero Audio Attributes record that occurs after this ASIN's
    # `new track playing` event and before a different track event.
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    do {
        $text = Read-AmazonLogRange -StartOffset $AfterOffset
        $events = [regex]::Matches($text, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $event = $null
        foreach ($candidate in $events) {
            if ($candidate.Groups['asin'].Value.ToUpperInvariant() -eq $Asin.ToUpperInvariant()) { $event = $candidate }
        }
        if ($event) {
            $suffix = $text.Substring($event.Index + $event.Length)
            $laterEvent = [regex]::Match($suffix, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($laterEvent.Success -and $laterEvent.Groups['asin'].Value.ToUpperInvariant() -ne $Asin.ToUpperInvariant()) {
                return $null
            }

            $pattern = 'Audio Attributes updated:.*?bit depth:\s*(?<bits>\d+),\s*sample rate:\s*(?<rate>\d+),\s*best available bit depth:\s*(?<bestBits>\d+),\s*best available sample rate:\s*(?<bestRate>\d+)'
            $attributes = [regex]::Matches($suffix, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($attribute in $attributes) {
                $bits = [int]$attribute.Groups['bestBits'].Value
                $rate = [int]$attribute.Groups['bestRate'].Value
                if ($bits -gt 0 -and $rate -gt 0) {
                    return [pscustomobject]@{
                        Text = '{0} bit / {1:g} kHz' -f $bits, ([double]$rate / 1000)
                        Bits = $bits
                        RateHz = $rate
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 40
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-AmazonFormatVerified {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [string] $Asin,
        [int] $TimeoutMilliseconds = 3500
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    # Endpoint format and the selected ASIN format are static during this short
    # verification window. Reading them once avoids repeatedly exporting every
    # device and rescanning 2 MB of log every 120 ms.
    $device = Resolve-Device $DeviceId
    $endpoint = [string]$device.'Default Format'
    $endpointOk = $endpoint -match "(?i)\b$($Target.Bits) bit\b" -and $endpoint -match "\b$($Target.RateHz) Hz\b"
    $selected = Get-AmazonSelectedFormat -Asin $Asin
    $initialSnapshot = Get-AmazonBackgroundSnapshot
    $iteration = 0
    do {
        $snapshot = Get-AmazonBackgroundSnapshot
        if (-not $selected) { $selected = Get-AmazonSelectedFormat -Asin $Asin }
        $track = if ($snapshot -and $snapshot.Track) { $snapshot.Track } else { $initialSnapshot.Track }
        $playing = if ($snapshot -and $snapshot.Playing) { $snapshot.Playing } else { $initialSnapshot.Playing }
        $capability = if ($snapshot -and $snapshot.DeviceCapability) { $snapshot.DeviceCapability } else { $initialSnapshot.DeviceCapability }
        # Amazon does not expose the ceiling fields consistently across CEF
        # builds. Unknown metadata is diagnostic, not proof that the stream is
        # wrong; endpoint + actual Playing are the hard requirements.
        $trackKnown = $null -ne $track
        $capabilityKnown = $null -ne $capability
        $trackOk = if ($trackKnown) { Test-FormatMatch $track $Target } else { $true }
        $playingOk = $playing -and (Test-FormatMatch $playing $Target)
        $capabilityOk = if ($capabilityKnown) {
            $capability.Bits -ge $Target.Bits -and $capability.RateHz -ge $Target.RateHz
        } else { $true }
        $selectedOk = Test-FormatMatch $selected $Target
        # Fragment-level selected quality can lag behind the actual playback
        # report. Once Playing matches the target, do not block on that duplicate
        # telemetry field; retain it only for diagnostics.
        if ($endpointOk -and $trackOk -and $playingOk -and $capabilityOk) {
            return [pscustomobject]@{
                Success=$true; Endpoint=$endpoint; Snapshot=$snapshot; Selected=$selected
                EndpointOk=$endpointOk; TrackOk=$trackOk; PlayingOk=$playingOk
                CapabilityOk=$capabilityOk; SelectedOk=$selectedOk
                TrackKnown=$trackKnown; CapabilityKnown=$capabilityKnown
            }
        }
        $iteration++
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{
        Success=$false; Endpoint=$endpoint; Snapshot=$snapshot; Selected=$selected
        EndpointOk=$endpointOk; TrackOk=$trackOk; PlayingOk=$playingOk; CapabilityOk=$capabilityOk; SelectedOk=$selectedOk
        TrackKnown=$trackKnown; CapabilityKnown=$capabilityKnown
    }
}

function Wait-AmazonTrackEvent {
    param(
        [Parameter(Mandatory)] [int64] $AfterOffset,
        [string] $ExpectedAsin = '',
        [string] $DifferentFromAsin = '',
        [switch] $Any,
        [int] $TimeoutMilliseconds = 2500
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    do {
        $text = Read-AmazonLogRange -StartOffset $AfterOffset
        $matches = [regex]::Matches($text, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) {
            $asin = $match.Groups['asin'].Value.ToUpperInvariant()
            if ($Any) { return $asin }
            if ($ExpectedAsin -and $asin -eq $ExpectedAsin) { return $asin }
            if ($DifferentFromAsin -and $asin -ne $DifferentFromAsin) { return $asin }
        }
        Start-Sleep -Milliseconds 60
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-AmazonSameTrackDelay {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] [int] $Milliseconds
    )
    $cursor = Get-AmazonLogLength
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $deadline) {
        $length = Get-AmazonLogLength
        if ($length -gt $cursor) {
            $text = Read-AmazonLogRange -StartOffset $cursor
            $cursor = $length
            $matches = [regex]::Matches($text, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($match in $matches) {
                $newAsin = $match.Groups['asin'].Value.ToUpperInvariant()
                if ($newAsin -ne $Asin) {
                    Write-Log "The track changed to $newAsin while waiting; canceling the stale switch for $Asin." Yellow
                    return $false
                }
            }
        }
        Start-Sleep -Milliseconds 50
    }
    return $true
}

function Sync-EndpointToActualAmazonTrack {
    param(
        [Parameter(Mandatory)] [string] $DeviceId,
        [Parameter(Mandatory)] [string] $ActualAsin,
        [Parameter(Mandatory)] [hashtable] $AsinFormats,
        [Parameter(Mandatory)] [int] $Channels,
        [Parameter(Mandatory)] [int64] $AfterOffset
    )

    try {
        # The nested replay wait reads AmazonMusic.log independently of the main
        # monitor cursor. Merge those lines into the shared index before resolving
        # the song that Amazon actually selected.
        Update-AsinQualityMap -Map $AsinFormats -Text (Read-AmazonLogRange -StartOffset $AfterOffset)
        $actualTrackFormat = $AsinFormats[$ActualAsin]
        if (-not $actualTrackFormat) {
            Write-Log "No format was found for the actual track $ActualAsin; refusing to guess or reuse another track's format." Red
            return $false
        }

        $script:LastResyncTarget = $actualTrackFormat.Text
        $device = Resolve-Device $DeviceId
        $before = [string]$device.'Default Format'
        $matches = $before -match "(?i)\b$($actualTrackFormat.Bits) bit\b" -and
            $before -match "\b$($actualTrackFormat.RateHz) Hz\b"
        if (-not $matches) {
            Write-Log "Resyncing $($device.Name): $before -> $($actualTrackFormat.Bits)-bit/$($actualTrackFormat.RateHz) Hz" Cyan
            Invoke-SoundVolumeView /SetDefaultFormat $DeviceId ([string]$actualTrackFormat.Bits) ([string]$actualTrackFormat.RateHz) ([string]$Channels)
            Start-Sleep -Milliseconds 250
            $device = Resolve-Device $DeviceId
        }

        $actual = [string]$device.'Default Format'
        $success = $actual -match "(?i)\b$($actualTrackFormat.Bits) bit\b" -and
            $actual -match "\b$($actualTrackFormat.RateHz) Hz\b"
        if ($success) {
            Write-Log "Failure cleanup completed; current track is $ActualAsin and the endpoint is $actual." Green
        } else {
            Write-Log "Failure cleanup could not resync the endpoint; read-back is $actual." Red
        }
        return $success
    } catch {
        Write-Log "Failure cleanup error: $($_.Exception.Message)" Red
        return $false
    }
}

function Get-AmazonBackgroundSnapshot {
    param([int64] $StartOffset = -1)

    if ($script:CdpEnabled) {
        try {
            $cdpSnapshot = Get-AmazonCdpSnapshot
            if ($cdpSnapshot) { return $cdpSnapshot }
        } catch {
            if (-not $script:CdpFailureLogged) {
                Write-Log "CDP read failed: $($_.Exception.Message); temporarily falling back to AmazonMusic.log." Yellow
                $script:CdpFailureLogged = $true
            }
        }
    }

    if (-not $script:AmazonLogPath -or -not (Test-Path -LiteralPath $script:AmazonLogPath)) {
        throw 'AmazonMusic.log was not found. Start Amazon Music for Windows at least once.'
    }

    $stream = [IO.File]::Open($script:AmazonLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($StartOffset -ge 0) {
            [void]$stream.Seek([Math]::Min($StartOffset, $stream.Length), [IO.SeekOrigin]::Begin)
        } else {
            [void]$stream.Seek([Math]::Max(0, $stream.Length - 262144), [IO.SeekOrigin]::Begin)
        }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }

    $detailedPattern = 'Audio Attributes updated:.*?bit depth:\s*(?<bits>\d+),\s*sample rate:\s*(?<rate>\d+),\s*best available bit depth:\s*(?<bestBits>\d+),\s*best available sample rate:\s*(?<bestRate>\d+).*?device capability:\s*\{.*?max bit depth:\s*(?<capBits>\d+),\s*max sample rate:\s*(?<capRate>\d+)'
    $detailedMatches = [regex]::Matches($text, $detailedPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($detailedMatches.Count -gt 0) {
        $match = $detailedMatches[$detailedMatches.Count - 1]
        $makeFormat = {
            param([int]$Bits, [int]$Rate)
            if ($Bits -le 0 -or $Rate -le 0) { return $null }
            [pscustomobject]@{ Text=('{0} bit / {1:g} kHz' -f $Bits, ([double]$Rate / 1000)); Bits=$Bits; RateHz=$Rate }
        }
        return [pscustomobject]@{
            Process = Get-MainWindow
            Track = & $makeFormat ([int]$match.Groups['bestBits'].Value) ([int]$match.Groups['bestRate'].Value)
            DeviceCapability = & $makeFormat ([int]$match.Groups['capBits'].Value) ([int]$match.Groups['capRate'].Value)
            Playing = & $makeFormat ([int]$match.Groups['bits'].Value) ([int]$match.Groups['rate'].Value)
            Raw = @($match.Value)
            Source = 'AmazonMusic.log'
        }
    }

    $pattern = 'UpdateAudioAttributes\s*:\s*audioQuality\s*=\s*(?<quality>[^,]+),\s*bestAvailableAudioQuality\s*=\s*(?<bestQuality>[^,]+),\s*bestAvailableBitDepth\s*=\s*(?<bestBits>\d+)\s*,\s*bestAvailableSampleRate\s*=\s*(?<bestRate>\d+)\s*,\s*bitDepth\s*=\s*(?<bits>\d+)\s*,.*?sampleRate\s*=\s*(?<rate>\d+)'
    $matches = [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -eq 0) { return $null }
    $match = $matches[$matches.Count - 1]

    $track = $null
    $playing = $null
    if ([int]$match.Groups['bestBits'].Value -gt 0 -and [int]$match.Groups['bestRate'].Value -gt 0) {
        $track = [pscustomobject]@{
            Text = '{0} bit / {1:g} kHz' -f [int]$match.Groups['bestBits'].Value, ([double][int]$match.Groups['bestRate'].Value / 1000)
            Bits = [int]$match.Groups['bestBits'].Value
            RateHz = [int]$match.Groups['bestRate'].Value
        }
    }
    if ([int]$match.Groups['bits'].Value -gt 0 -and [int]$match.Groups['rate'].Value -gt 0) {
        $playing = [pscustomobject]@{
            Text = '{0} bit / {1:g} kHz' -f [int]$match.Groups['bits'].Value, ([double][int]$match.Groups['rate'].Value / 1000)
            Bits = [int]$match.Groups['bits'].Value
            RateHz = [int]$match.Groups['rate'].Value
        }
    }
    return [pscustomobject]@{ Process = Get-MainWindow; Track = $track; DeviceCapability = $null; Playing = $playing; Raw = @($match.Value); Source = 'AmazonMusic.log' }
}

function Wait-AmazonBackgroundFormat {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [int64] $AfterOffset,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-AmazonBackgroundSnapshot -StartOffset $AfterOffset
        if ($snapshot -and (Test-FormatMatch $snapshot.Playing $Target)) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Assert-Tool {
    if (-not (Test-Path $script:ToolPath)) {
        throw "SoundVolumeView is missing. Run: & '$PSScriptRoot\setup.ps1'"
    }
}

function Invoke-SoundVolumeView {
    param([Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    # Piping makes PowerShell wait for this GUI executable while preserving each
    # argument boundary (important for device IDs containing spaces).
    & $script:ToolPath @Arguments | Out-Null
}

function Export-SoundItems {
    Assert-Tool
    $path = Join-Path ([IO.Path]::GetTempPath()) ("amazon-music-rate-switcher-{0}.json" -f [Guid]::NewGuid())
    Invoke-SoundVolumeView /sjson $path
    $deadline = (Get-Date).AddSeconds(3)
    while (-not (Test-Path $path) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $path)) { throw 'SoundVolumeView did not produce a device list.' }
    try { return @(Get-Content $path -Raw | ConvertFrom-Json) }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-RenderDevices {
    @(Export-SoundItems | Where-Object { $_.Type -eq 'Device' -and $_.Direction -eq 'Render' })
}

function Resolve-Device {
    param([string] $RequestedId)
    $devices = Get-RenderDevices
    if ($RequestedId) {
        # Item ID is an ASCII-only Core Audio GUID and is safer in config.json
        # than a localized friendly ID (for example a translated Windows name)
        # when the script is read by Windows PowerShell 5.1.
        $device = $devices | Where-Object {
            $_.'Command-Line Friendly ID' -eq $RequestedId -or $_.'Item ID' -eq $RequestedId
        } | Select-Object -First 1
        if (-not $device) { throw "The requested device was not found: $RequestedId" }
        return $device
    }

    if ($script:DeviceNamePattern) {
        $device = $devices | Where-Object {
            $_.Name -like $script:DeviceNamePattern -or
            $_.'Device Name' -like $script:DeviceNamePattern
        } | Select-Object -First 1
        if ($device) { return $device }
    }

    $device = $devices | Where-Object { $_.'Default Multimedia' -eq 'Render' } | Select-Object -First 1
    if (-not $device) { $device = $devices | Where-Object { $_.Default -eq 'Render' } | Select-Object -First 1 }
    if (-not $device) { throw 'The Windows default multimedia render endpoint was not found.' }
    return $device
}

function Get-DeviceColumnValueFast {
    param(
        [Parameter(Mandatory)] [string] $DeviceId,
        [Parameter(Mandatory)] [string] $Column
    )
    Assert-Tool
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:ToolPath
    $psi.Arguments = '/GetColumnValue "{0}" "{1}"' -f $DeviceId.Replace('"', '\"'), $Column.Replace('"', '\"')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    # SoundVolumeView is a GUI executable and writes this command's stdout as
    # UTF-16.  Reading it explicitly avoids cmd.exe/more and takes ~115 ms on
    # the test machine, versus exporting/parsing every sound item.
    $psi.StandardOutputEncoding = [Text.Encoding]::Unicode
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $value = $process.StandardOutput.ReadToEnd().Trim()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not $value) { return $null }
        return $value
    } finally {
        $process.Dispose()
    }
}

function Get-DeviceDefaultFormatFast {
    param(
        [Parameter(Mandatory)] [string] $DeviceId,
        [string] $CoreAudioDeviceId
    )
    if ($CoreAudioDeviceId) {
        $direct = [CoreAudioEndpoint]::GetDeviceFormat($CoreAudioDeviceId)
        if ($direct) { return $direct }
    }
    return Get-DeviceColumnValueFast -DeviceId $DeviceId -Column 'Default Format'
}

function Set-EndpointMuteFast {
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [bool] $Muted
    )
    $friendlyId = [string]$Device.'Command-Line Friendly ID'
    $coreAudioId = [string]$Device.'Item ID'
    if (-not $coreAudioId -and $friendlyId) {
        $coreAudioId = Get-DeviceColumnValueFast -DeviceId $friendlyId -Column 'Item ID'
    }
    if ($coreAudioId -and [CoreAudioEndpoint]::SetMute($coreAudioId, $Muted)) { return $true }

    # Keep a tested fallback for unusual drivers/endpoints that reject direct
    # IAudioEndpointVolume activation.
    if ($friendlyId) {
        Invoke-SoundVolumeView $(if ($Muted) { '/Mute' } else { '/Unmute' }) $friendlyId
        return $true
    }
    return $false
}

function Wait-DeviceDefaultFormatFast {
    param(
        [Parameter(Mandatory)] [string] $DeviceId,
        [string] $CoreAudioDeviceId,
        [Parameter(Mandatory)] [int] $Bits,
        [Parameter(Mandatory)] [int] $RateHz,
        [int] $TimeoutMilliseconds = 700
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    $last = $null
    do {
        $last = Get-DeviceDefaultFormatFast -DeviceId $DeviceId -CoreAudioDeviceId $CoreAudioDeviceId
        if ($last -and $last -match "(?i)\b$Bits bit\b" -and $last -match "\b$RateHz Hz\b") { return $last }
        Start-Sleep -Milliseconds 20
    } while ((Get-Date) -lt $deadline)
    return $last
}

function Test-AmazonSessionActive {
    param([Parameter(Mandatory)] $Device)
    $driverName = [string]$Device.'Device Name'
    $activeSession = Export-SoundItems | Where-Object {
        $_.Type -eq 'Application' -and
        $_.'Device State' -eq 'Active' -and
        $_.'Device Name' -eq $driverName -and
        $_.'Process Path' -match '(?i)Amazon Music\.exe$'
    } | Select-Object -First 1
    return $null -ne $activeSession
}

function Test-FormatMatch {
    param($Left, $Right)
    return $Left -and $Right -and
        $Left.Bits -eq $Right.Bits -and
        $Left.RateHz -eq $Right.RateHz
}

function Set-EndpointFormat {
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] $Format,
        $CurrentPlaying,
        [Parameter(Mandatory)] [int] $Channels,
        [Parameter(Mandatory)] [bool] $MuteDuringSwitch,
        [Parameter(Mandatory)] [int] $WaitForRebuildSeconds,
        [Parameter(Mandatory)] [int] $RecoveryWaitSeconds,
        [string] $Asin = '',
        [hashtable] $AsinFormats,
        [int] $RestartDelayMilliseconds = 3500,
        [bool] $PreMuted = $false,
        [hashtable] $Timing
    )

    Assert-Tool
    if (-not $Timing) { $Timing = @{} }
    foreach ($stageName in @('MuteMs', 'RestartGateMs', 'EndpointFormatMs', 'ReplayRequestMs', 'SameAsinWaitMs', 'PlaybackFormatWaitMs', 'FailureResyncMs', 'RecoveryMs', 'UnmuteCommandMs', 'SetEndpointTotalMs')) {
        $Timing[$stageName] = 0
    }
    $setEndpointTimer = [Diagnostics.Stopwatch]::StartNew()
    $script:LastUnmuteIssued = $true
    $script:LastUnexpectedAsin = ''
    $script:LastResyncSuccess = $false
    $script:LastResyncTarget = ''
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $id = $Device.'Command-Line Friendly ID'
    $before = $Device.'Default Format'
    $cableRenderId = 'VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render'
    $cableCaptureId = 'VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Output\Capture'
    $isAsioCable = $id -eq $cableRenderId
    $cableFormatKey = "$($Format.Bits)/$($Format.RateHz)/$Channels"

    $endpointAlreadyMatches = $before -match "(?i)\b$($Format.Bits) bit\b" -and $before -match "\b$($Format.RateHz) Hz\b"
    $cablePairNeedsSync = $isAsioCable -and $script:CableCaptureFormatKey -ne $cableFormatKey
    if ($endpointAlreadyMatches -and -not $cablePairNeedsSync -and (Test-FormatMatch $CurrentPlaying $Format)) {
        Write-Log "The endpoint is already $($Format.Bits)-bit/$($Format.RateHz) Hz; no switch is needed." DarkGray
        return $true
    }

    if (-not (Test-Path $script:BackupPath)) {
        Invoke-SoundVolumeView /SaveDeviceFormat $id $script:BackupPath
        @{ DeviceId = $id; OriginalFormat = $before; SavedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding utf8
    }

    # A current CDP ASIN is stronger and much cheaper evidence than exporting
    # every Windows audio session.  Avoid that full scan in the latency-critical
    # interval after a track change.
    $streamWasActive = if ($script:CdpEnabled -and $script:CdpWebSocketUrl -and $Asin) {
        $true
    } else {
        Test-AmazonSessionActive $Device
    }
    $ownsMute = $PreMuted
    # ASIO4ALL test mode: keep ASIO Bridge resident and let the driver observe
    # the paired Cable format change without an explicit OFF/ON toggle.
    try {
        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
        if (-not $PreMuted -and $streamWasActive -and $MuteDuringSwitch) {
            if (-not (Set-EndpointMuteFast -Device $Device -Muted $true)) { throw 'Could not mute the endpoint.' }
            $ownsMute = $true
            Write-Log 'Endpoint muted; Amazon transport continues playing.' DarkGray
        }
        $Timing['MuteMs'] = [int]$stageTimer.ElapsedMilliseconds

        if ($streamWasActive -and -not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) {
            # Amazon's Windows media session frequently leaves TimelineProperties
            # stale, so it cannot be trusted as a restart gate. This function is
            # entered immediately after Amazon's own `new track playing` event.
            Write-Log ("Waiting {0} ms after the Amazon track event to cross the same-track Previous threshold." -f $RestartDelayMilliseconds) DarkGray
            $stageTimer = [Diagnostics.Stopwatch]::StartNew()
            if ($Asin) {
                if (-not (Wait-AmazonSameTrackDelay -Asin $Asin -Milliseconds $RestartDelayMilliseconds)) { return $false }
            } else {
                Start-Sleep -Milliseconds $RestartDelayMilliseconds
            }
            $Timing['RestartGateMs'] = [int]$stageTimer.ElapsedMilliseconds
        }

        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
        if (-not $endpointAlreadyMatches -or $cablePairNeedsSync) {
            Write-Log "Switching $($Device.Name): $before -> $($Format.Bits)-bit/$($Format.RateHz) Hz" Cyan
            if ($isAsioCable) {
                # Change both Hi-Fi Cable sides in one SoundVolumeView process.
                # ASIO4ALL remains ON in this experiment; it may reopen the
                # stream itself when the paired format changes.
                Invoke-SoundVolumeView `
                    /SetDefaultFormat $id ([string]$Format.Bits) ([string]$Format.RateHz) ([string]$Channels) `
                    /SetDefaultFormat $cableCaptureId ([string]$Format.Bits) ([string]$Format.RateHz) ([string]$Channels)
            } else {
                Invoke-SoundVolumeView /SetDefaultFormat $id ([string]$Format.Bits) ([string]$Format.RateHz) ([string]$Channels)
            }
            $actual = Wait-DeviceDefaultFormatFast -DeviceId $id -CoreAudioDeviceId ([string]$Device.'Item ID') -Bits ([int]$Format.Bits) -RateHz ([int]$Format.RateHz)
        } else {
            Write-Log 'The endpoint already has the target format; Amazon only needs to reopen the current audio stream.' DarkGray
            $actual = $before
        }

        $success = $actual -match "(?i)\b$($Format.Bits) bit\b" -and $actual -match "\b$($Format.RateHz) Hz\b"
        if (-not $success) {
            Write-Log "The driver rejected the target format; read-back is still $actual. Restoring the previous format." Yellow
            if (Test-Path $script:BackupPath) {
                Invoke-SoundVolumeView /LoadDeviceFormat $id $script:BackupPath
            }
            return $false
        }

        Write-Log "Endpoint format confirmed: $actual" Green
        if ($isAsioCable) { $script:CableCaptureFormatKey = $cableFormatKey }
        if (-not $endpointAlreadyMatches -or $cablePairNeedsSync) {
            Write-Log 'ASIO4ALL remains ON; waiting for it to reopen the stream at the new format.' DarkGray
        }
        $Timing['EndpointFormatMs'] = [int]$stageTimer.ElapsedMilliseconds
        if (-not $streamWasActive) {
            Write-Log 'The Amazon stream is not active; the next playback will be created at the new format.' DarkGray
            return $true
        }

        if ($script:CdpEnabled -and $script:CdpWebSocketUrl -and $Asin) {
            $stageTimer = [Diagnostics.Stopwatch]::StartNew()
            try {
                Write-Log 'Using native CDP seek to 4 seconds followed by Previous: fast same-track replay while preserving the queue.' Cyan
                $replay = Invoke-AmazonCdpFastRestartCurrentTrack -ExpectedAsin $Asin
                $Timing['ReplayRequestMs'] = [int]$stageTimer.ElapsedMilliseconds
                Write-Log ("Fast replay returned to the same ASIN at the start; mode={0}, safe position={1} ms, hasNext={2}." -f $replay.mode, $replay.soughtMs, $replay.hasNext) DarkGray
                $cdpReplay = Wait-AmazonCdpFormat -Target $Format -Asin $Asin -TimeoutMilliseconds 5000
                $Timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds - $Timing['ReplayRequestMs']
                if ($cdpReplay) {
                    Write-Log "CDP confirmed same-track rebuild: $($cdpReplay.Title); playback=$($cdpReplay.Playing.Text)." Green
                    return $true
                }

                Write-Log 'The first fast replay did not align the format; retrying one queue-safe same-track replay.' Yellow
                $retryTimer = [Diagnostics.Stopwatch]::StartNew()
                [void](Invoke-AmazonCdpFastRestartCurrentTrack -ExpectedAsin $Asin)
                $retryReplay = Wait-AmazonCdpFormat -Target $Format -Asin $Asin -TimeoutMilliseconds 5000
                $Timing['RecoveryMs'] = [int]$retryTimer.ElapsedMilliseconds
                if ($retryReplay) {
                    Write-Log "The second CDP rebuild succeeded; playback=$($retryReplay.Playing.Text)." Green
                    return $true
                }
                Write-Log 'The format remained misaligned after two queue-safe replays; stopping.' Yellow
                return $false
            } catch {
                Write-Log "CDP fast same-track replay failed: $($_.Exception.Message)" Yellow

                # If playback itself never reached the Previous threshold,
                # pressing Previous after an arbitrary wall-clock delay could
                # select the prior song.  Fail this track cleanly instead of
                # turning a stalled stream into a destructive replay attempt.
                if ($_.Exception.Message -match 'safe Previous threshold') {
                    Write-Log 'Playback did not reach the safe threshold; Previous will not be pressed to avoid selecting the previous track.' Yellow
                    return $false
                }

                Write-Log 'Using the safe Previous fallback.' Yellow

                # The fast path seeks across Amazon's restart threshold before
                # pressing Previous.  If native seek is unavailable, retain the
                # conservative wall-clock gate and cancel if playback changes.
                $safeFallbackDelay = [Math]::Max(3500, $RestartDelayMilliseconds)
                Write-Log ("CDP fallback will wait {0} ms before safely replaying the current track." -f $safeFallbackDelay) DarkGray
                $fallbackGateTimer = [Diagnostics.Stopwatch]::StartNew()
                if ($Asin) {
                    if (-not (Wait-AmazonSameTrackDelay -Asin $Asin -Milliseconds $safeFallbackDelay)) {
                        $Timing['RestartGateMs'] = [int]$fallbackGateTimer.ElapsedMilliseconds
                        return $false
                    }
                } else {
                    Start-Sleep -Milliseconds $safeFallbackDelay
                }
                $Timing['RestartGateMs'] = [int]$fallbackGateTimer.ElapsedMilliseconds
            }
        }

        $logOffset = Get-AmazonLogLength
        Write-Log 'Replaying the current track once so Amazon reopens the stream at the new endpoint format.' Cyan
        $amazon = Get-MainWindow
        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
        [AmazonMediaCommands]::RestartCurrentTrack($amazon.MainWindowHandle)
        $Timing['ReplayRequestMs'] = [int]$stageTimer.ElapsedMilliseconds
        $verifySeconds = [Math]::Max(8, $WaitForRebuildSeconds + $RecoveryWaitSeconds)
        if ($Asin) {
            $stageTimer = [Diagnostics.Stopwatch]::StartNew()
            # Observe the first playback instance, including an unexpected ASIN.
            # Waiting only for the expected ASIN hid a Previous misfire for the
            # full timeout and left the endpoint configured for the wrong song.
            $rebuiltAsin = Wait-AmazonTrackEvent -AfterOffset $logOffset -Any -TimeoutMilliseconds ($verifySeconds * 1000)
            $Timing['SameAsinWaitMs'] = [int]$stageTimer.ElapsedMilliseconds
            if (-not $rebuiltAsin) {
                Write-Log "Amazon did not create a new same-track playback instance (ASIN $Asin); a 00:00 seek is not considered success." Yellow
                return $false
            }
            if ($rebuiltAsin -ne $Asin) {
                $script:LastUnexpectedAsin = $rebuiltAsin
                Write-Log "Replay selected $rebuiltAsin; resyncing the endpoint to the actual track immediately." Yellow
                $resyncTimer = [Diagnostics.Stopwatch]::StartNew()
                if ($AsinFormats) {
                    $script:LastResyncSuccess = Sync-EndpointToActualAmazonTrack `
                        -DeviceId $id -ActualAsin $rebuiltAsin -AsinFormats $AsinFormats `
                        -Channels $Channels -AfterOffset $logOffset
                }
                $Timing['FailureResyncMs'] = [int]$resyncTimer.ElapsedMilliseconds
                return $false
            }
            Write-Log "Confirmed the new same-track playback instance: $rebuiltAsin." DarkGray
        }
        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
        if (Wait-AmazonBackgroundFormat -Target $Format -AfterOffset $logOffset -TimeoutSeconds $verifySeconds) {
            $Timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds
            Write-Log "Amazon playback telemetry confirms $($Format.Text)." Green
            return $true
        }
        $Timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds

        # A real same-ASIN replay can occasionally retain the stale stream once.
        # Permit exactly one bounded replay recovery, then fail closed.
        $recoveryTimer = [Diagnostics.Stopwatch]::StartNew()
        Write-Log 'The first same-track replay retained the old stream; waiting 3.5 seconds before one recovery replay.' Yellow
        Start-Sleep -Milliseconds 3500
        $retryOffset = Get-AmazonLogLength
        [AmazonMediaCommands]::RestartCurrentTrack($amazon.MainWindowHandle)
        if ($Asin) {
            $retryAsin = Wait-AmazonTrackEvent -AfterOffset $retryOffset -Any -TimeoutMilliseconds ($verifySeconds * 1000)
            if (-not $retryAsin) {
                Write-Log 'Recovery did not create a new same-track playback instance; stopping.' Yellow
                return $false
            }
            if ($retryAsin -ne $Asin) {
                $script:LastUnexpectedAsin = $retryAsin
                Write-Log "Recovery selected $retryAsin; resyncing the endpoint to the actual track immediately." Yellow
                $resyncTimer = [Diagnostics.Stopwatch]::StartNew()
                if ($AsinFormats) {
                    $script:LastResyncSuccess = Sync-EndpointToActualAmazonTrack `
                        -DeviceId $id -ActualAsin $retryAsin -AsinFormats $AsinFormats `
                        -Channels $Channels -AfterOffset $retryOffset
                }
                $Timing['FailureResyncMs'] = [int]$resyncTimer.ElapsedMilliseconds
                return $false
            }
        }
        if (Wait-AmazonBackgroundFormat -Target $Format -AfterOffset $retryOffset -TimeoutSeconds $verifySeconds) {
            $Timing['RecoveryMs'] = [int]$recoveryTimer.ElapsedMilliseconds
            Write-Log "The second same-track replay succeeded; Amazon playback is $($Format.Text)." Green
            return $true
        }

        $Timing['RecoveryMs'] = [int]$recoveryTimer.ElapsedMilliseconds
        Write-Log 'The target format was not reported after two same-track replays; stopping to avoid an infinite loop.' Yellow
        return $false
    }
    finally {
        # ASIO4ALL test mode leaves the resident Bridge untouched.
        $unmuteTimer = [Diagnostics.Stopwatch]::StartNew()
        if ($ownsMute) {
            $script:LastUnmuteIssued = Set-EndpointMuteFast -Device $Device -Muted $false
            if ($script:LastUnmuteIssued) {
                Write-Log 'Sent the endpoint unmute command; no read-back wait.' DarkGray
            } else {
                Write-Log 'The endpoint unmute command failed.' Red
            }
        }
        $Timing['UnmuteCommandMs'] = [int]$unmuteTimer.ElapsedMilliseconds
        $Timing['SetEndpointTotalMs'] = [int]$setEndpointTimer.ElapsedMilliseconds
    }
}

function Show-Snapshot {
    param($Snapshot)
    Write-Host ''
    Write-Host ('Track quality    : {0}' -f $(if ($Snapshot.Track) { $Snapshot.Track.Text } else { 'Unknown' }))
    Write-Host ('Device capability: {0}' -f $(if ($Snapshot.DeviceCapability) { $Snapshot.DeviceCapability.Text } else { 'Unknown' }))
    Write-Host ('Amazon playback  : {0}' -f $(if ($Snapshot.Playing) { $Snapshot.Playing.Text } else { 'Unknown' }))
}

$config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
if (-not $DeviceId) { $DeviceId = [string]$config.deviceId }
$script:DeviceNamePattern = [string]$config.deviceNamePattern
$script:ShowDetailedTiming = [bool]$config.showDetailedTiming
$script:CdpEnabled = [bool]$Cdp -or ([bool]$config.cdpEnabled)
$script:CdpAllowLaunch = [bool]$CdpLaunch -or ([bool]$config.cdpAutoLaunch)

switch ($Mode) {
    'Probe' {
        $snapshot = Get-AmazonBackgroundSnapshot
        if (-not $snapshot) { throw 'Amazon playback telemetry has no audio format yet. Play a track first.' }
        Show-Snapshot $snapshot
        Write-Log ("Format source: {0}; the quality popup was not opened." -f $snapshot.Source) DarkGray
    }
    'Devices' {
        Assert-Tool
        Get-RenderDevices |
            Select-Object Name, 'Device Name', 'Default Format', 'Default', 'Default Multimedia', 'Command-Line Friendly ID' |
            Format-List
    }
    'Once' {
        Assert-Tool
        $snapshot = Get-AmazonBackgroundSnapshot
        if (-not $snapshot) { throw 'Amazon playback telemetry has no audio format yet. Play a track first.' }
        Show-Snapshot $snapshot
        if (-not $snapshot.Track) { throw 'The track format could not be determined.' }
        $device = Resolve-Device $DeviceId
        Write-Host ("Target endpoint  : {0} ({1})" -f $device.Name, $device.'Default Format')
        if (-not $Apply) {
            Write-Log 'Dry run: no format was changed. Add -Apply to perform the switch.' Yellow
            break
        }
        $delay = if ($RestartDelayMs -gt 0) { $RestartDelayMs } else { [int]$config.restartDelayMs }
        [void](Set-EndpointFormat -Device $device -Format $snapshot.Track -CurrentPlaying $snapshot.Playing -Channels ([int]$config.channels) -MuteDuringSwitch ([bool]$config.muteDuringSwitch) -WaitForRebuildSeconds ([int]$config.waitForRebuildSeconds) -RecoveryWaitSeconds ([int]$config.recoveryWaitSeconds) -Asin ([string]$snapshot.Asin) -RestartDelayMilliseconds $delay)
    }
    { $_ -in @('Monitor', 'AutoTest') } {
        Assert-Tool
        $autoTest = $Mode -eq 'AutoTest'
        if ($autoTest) { $Apply = $true }
        if ($autoTest) {
            $amazonAlreadyRunning = @(Get-Process -Name 'Amazon Music' -ErrorAction SilentlyContinue).Count -gt 0
            if ($amazonAlreadyRunning) {
                # Preserve the current playback position and queue.  A running
                # non-debug instance cannot acquire a CDP port retroactively;
                # in that case AutoTest keeps it alive and uses the existing
                # log/media-command fallback instead of restarting it.
                $script:CdpAllowLaunch = $false
                Write-Log 'AutoTest found an existing Amazon process; reusing it without restarting.' DarkGray
            } else {
                # AutoTest is often launched from its .cmd while Amazon is
                # closed.  Permit one Store/CDP launch even when the caller did
                # not explicitly pass -CdpLaunch.
                $script:CdpAllowLaunch = $true
                Write-Log 'AutoTest did not find Amazon; starting the Store app and creating a CDP port.' DarkGray
            }
        }
        if ($script:CdpEnabled) {
            if (-not (Initialize-AmazonCdp)) {
                Write-Log "CDP unavailable: $script:CdpLastError; using the log/Previous fallback." Yellow
            }
        }
        $trackPollMilliseconds = [int]$config.trackPollMilliseconds
        if ($trackPollMilliseconds -lt 50) { $trackPollMilliseconds = 50 }
        Write-Log "Monitoring Amazon playback every $trackPollMilliseconds ms. Press Ctrl+C to stop. Apply=$Apply" Cyan
        $asinFormats = @{}
        $verifiedFormats = Import-VerifiedFormatCache
        Write-Log 'Building the Amazon ASIN/best-available-format index...' DarkGray
        Update-AsinQualityMap -Map $asinFormats -Text (Read-AmazonLogRange -StartOffset 0)
        Write-Log "Index complete: $($asinFormats.Count) log formats and $($verifiedFormats.Count) verified cache entries; updating incrementally." DarkGray
        $logCursor = Get-AmazonLogLength
        $lastAsin = ''
        $monitorDevice = Resolve-Device $DeviceId
        $currentEndpointFormat = [string]$monitorDevice.'Default Format'
        $testResults = New-Object Collections.ArrayList
        $finished = $false
        $autoTestWaitingForNext = $false
        $autoTestNextDeadline = $null
        if ($autoTest) {
            Write-Log "AutoTest started: testing $TestTracks consecutive tracks. Do not operate Amazon Music during the test." Magenta
            $amazon = Get-MainWindow
            if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
                try {
                    $initialCdp = Get-AmazonCdpSnapshot
                    if ($initialCdp -and $initialCdp.Asin) { $lastAsin = $initialCdp.Asin.ToUpperInvariant() }
                } catch {
                }
            }
            if (-not (Test-AmazonSessionActive $monitorDevice)) {
                [AmazonMediaCommands]::TogglePlayback($amazon.MainWindowHandle)
                Start-Sleep -Milliseconds 300
            }
            if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
                try { [void](Invoke-AmazonCdpNextTrack) } catch { [AmazonMediaCommands]::NextTrack($amazon.MainWindowHandle) }
            } else {
                [AmazonMediaCommands]::NextTrack($amazon.MainWindowHandle)
            }
            $autoTestWaitingForNext = $true
            $autoTestNextDeadline = (Get-Date).AddSeconds(10)
        }
        while (-not $finished) {
            try {
                if ($autoTest -and $autoTestWaitingForNext -and (Get-Date) -gt $autoTestNextDeadline) {
                    Write-Log 'AutoTest timed out waiting for the next-track event; stopping and preserving the current track.' Red
                    [void]$testResults.Add([pscustomobject]@{
                        Number=$testResults.Count+1; Asin='(next)'; Target='Unknown'; Success=$false
                        UnexpectedAsin=''; ResyncSuccess=$false; ResyncTarget=''; UnmuteIssued=$false
                        Timing=@{}; Reason='Next-track event timed out (the queue may be empty or autoplay may be disabled).'; Time=(Get-Date).ToString('o')
                    })
                    $finished = $true
                    continue
                }
                $cdpCurrent = $null
                if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
                    try { $cdpCurrent = Get-AmazonCdpSnapshot } catch { }
                }
                $asin = ''
                $format = $null
                $fromCdp = $false
                if ($cdpCurrent -and $cdpCurrent.Asin) {
                    $asin = $cdpCurrent.Asin.ToUpperInvariant()
                    $fromCdp = $true
                } else {
                    $length = Get-AmazonLogLength
                    if ($length -lt $logCursor) {
                        $logCursor = 0
                        $asinFormats = @{}
                    }
                    if ($length -le $logCursor) {
                        Start-Sleep -Milliseconds $trackPollMilliseconds
                        continue
                    }

                    $chunk = Read-AmazonLogRange -StartOffset $logCursor
                    $logCursor = $length
                    Update-AsinQualityMap -Map $asinFormats -Text $chunk
                    $trackMatches = [regex]::Matches($chunk, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($trackMatches.Count -eq 0) { continue }
                    $asin = $trackMatches[$trackMatches.Count - 1].Groups['asin'].Value.ToUpperInvariant()
                }
                if (-not $asin) { continue }
                if ($asin -eq $lastAsin) { continue }
                if ($autoTest) { $autoTestWaitingForNext = $false }
                $lastAsin = $asin
                $trackTimer = [Diagnostics.Stopwatch]::StartNew()
                $timing = @{}
                $preMuted = $false

                # Eliminate the audible head of the new song.  If its cached
                # format already matches the endpoint there is no switch and no
                # need to mute.  Unknown or different formats are muted before
                # any catalog/log wait; direct Core Audio normally completes in
                # 2-4 ms after this detection point.
                if ($Apply -and [bool]$config.muteDuringSwitch) {
                    $knownFormat = if ($verifiedFormats.ContainsKey($asin)) { $verifiedFormats[$asin] } elseif ($asinFormats.ContainsKey($asin)) { $asinFormats[$asin] } else { $null }
                    $knownMatchesEndpoint = $knownFormat -and
                        $currentEndpointFormat -match "(?i)\b$($knownFormat.Bits) bit\b" -and
                        $currentEndpointFormat -match "\b$($knownFormat.RateHz) Hz\b"
                    if (-not $knownMatchesEndpoint) {
                        if (Set-EndpointMuteFast -Device $monitorDevice -Muted $true) {
                            $preMuted = $true
                            $timing['DetectionToMuteMs'] = [int]$trackTimer.ElapsedMilliseconds
                            Write-Log 'Muted the endpoint immediately after the track change.' DarkGray
                        } else {
                            $timing['DetectionToMuteMs'] = [int]$trackTimer.ElapsedMilliseconds
                            Write-Log 'Immediate endpoint mute failed; stopping this track switch.' Red
                        }
                    }
                }

                if ($fromCdp) {
                    $correlationStart = $logCursor
                    $authoritativeFormat = $null
                    if ($verifiedFormats.ContainsKey($asin)) {
                        $format = $verifiedFormats[$asin]
                        Write-Log "Verified ASIN format cache hit: $($format.Text) (no CDP/log wait)." DarkGray
                    } elseif ($asinFormats.ContainsKey($asin)) {
                        $format = $asinFormats[$asin]
                        Write-Log "Amazon log format cache hit: $($format.Text) (no CDP/log wait)." DarkGray
                    } else {
                        # Check the log once before opening a CDP wait.  On fast
                        # builds the paired Audio Attributes line is already in
                        # the file; the old order needlessly spent up to 500 ms
                        # waiting on CDP before reading it.
                        $authoritativeFormat = Wait-AmazonCorrelatedTrackFormat `
                            -Asin $asin -AfterOffset $correlationStart -TimeoutMilliseconds 0
                        if ($authoritativeFormat) {
                            Write-Log "Amazon log immediately provided the ASIN-paired format: $($authoritativeFormat.Text)." DarkGray
                        }
                    }
                    if (-not $format -and -not $authoritativeFormat) {
                        # The renderer normally publishes audioAttributes within
                        # about 200-300 ms.  Keep a bounded CDP-first wait, then
                        # use the log as the ordering-safe fallback.
                        $authoritativeFormat = Wait-AmazonCdpSettledTrackFormat -Asin $asin -TimeoutMilliseconds 350
                        if (-not $authoritativeFormat) {
                            $authoritativeFormat = Wait-AmazonCorrelatedTrackFormat `
                                -Asin $asin -AfterOffset $correlationStart -TimeoutMilliseconds 700
                        }
                        if (-not $authoritativeFormat) {
                            # AmazonMusic.log can remain buffered for several
                            # seconds immediately after a Store/CDP relaunch.
                            # The renderer attributes usually settle while the
                            # log fallback is waiting, so re-read the same ASIN
                            # once before declaring the track unknown.  This is
                            # failure-path only and adds no cost to cache hits or
                            # the normal first-CDP success path.
                            $authoritativeFormat = Wait-AmazonCdpSettledTrackFormat -Asin $asin -TimeoutMilliseconds 150
                        }
                    }
                    $newLength = Get-AmazonLogLength
                    if ($newLength -gt $correlationStart) {
                        $correlationText = Read-AmazonLogRange -StartOffset $correlationStart
                        Update-AsinQualityMap -Map $asinFormats -Text $correlationText
                        $logCursor = $newLength
                    }
                    if ($authoritativeFormat) {
                        # This is authoritative for the current playback instance;
                        # overwrite an older fragment-derived cache entry instead
                        # of retaining a stale higher value.
                        $asinFormats[$asin] = $authoritativeFormat
                        $format = $authoritativeFormat
                    } elseif (-not $format -and $asinFormats.ContainsKey($asin)) {
                        $format = $asinFormats[$asin]
                        Write-Log "CDP format is not synchronized with the new ASIN; using the existing format cache for that ASIN." DarkGray
                    } elseif (-not $format) {
                        Write-Log "CDP changed to $asin, but the format fields still belong to the previous track; ignoring unpaired data." Yellow
                    }
                }
                if (-not $format) { $format = $asinFormats[$asin] }
                if (-not $format) {
                    $deadline = (Get-Date).AddMilliseconds(900)
                    while (-not $format -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 50
                        $newLength = Get-AmazonLogLength
                        if ($newLength -gt $logCursor) {
                            $more = Read-AmazonLogRange -StartOffset $logCursor
                            $logCursor = $newLength
                            Update-AsinQualityMap -Map $asinFormats -Text $more
                            $format = $asinFormats[$asin]
                        }
                    }
                }
                if (-not $format) {
                    Write-Log "No format data for new track $asin within 0.9 seconds; the previous track's format will not be reused." Yellow
                    if ($preMuted) {
                        [void](Set-EndpointMuteFast -Device $monitorDevice -Muted $false)
                        $script:LastUnmuteIssued = $true
                    }
                    if ($autoTest) {
                        [void]$testResults.Add([pscustomobject]@{ Number=$testResults.Count+1; Asin=$asin; Target='Unknown'; Success=$false; Reason='No format data within 0.9 seconds'; Time=(Get-Date).ToString('o') })
                        Write-Log 'This AutoTest run failed; stopping immediately instead of advancing from the failed track.' Yellow
                        $finished = $true
                    }
                    continue
                }
                $timing['TrackEventToFormatMs'] = [int]$trackTimer.ElapsedMilliseconds

                Write-Log "Playback engine changed track: $asin -> $($format.Text)" Cyan
                $monitorDevice.'Default Format' = $currentEndpointFormat
                $before = $currentEndpointFormat
                $endpointMatches = $before -match "(?i)\b$($format.Bits) bit\b" -and $before -match "\b$($format.RateHz) Hz\b"
                $success = $false
                $reason = ''
                $script:LastUnmuteIssued = $true
                $script:LastUnexpectedAsin = ''
                $script:LastResyncSuccess = $false
                $script:LastResyncTarget = ''
                if ($endpointMatches) {
                    Write-Log 'Endpoint already matches; no interruption or pause.' Green
                    if ($preMuted) {
                        $unmuteTimer = [Diagnostics.Stopwatch]::StartNew()
                        $script:LastUnmuteIssued = Set-EndpointMuteFast -Device $monitorDevice -Muted $false
                        $timing['UnmuteCommandMs'] = [int]$unmuteTimer.ElapsedMilliseconds
                        $preMuted = $false
                    }
                    $stageTimer = [Diagnostics.Stopwatch]::StartNew()
                    # Same-format tracks are already audible and do not need a
                    # device switch.  The old path rescanned all five metadata
                    # fields for up to 3 seconds, which blocked the monitor
                    # from handling the next track even though no recovery was
                    # needed.  CDP's ASIN + actual audioAttributes are the two
                    # hard checks here; retain the old verifier only as a
                    # bounded fallback for transient renderer updates.
                    $verification = $null
                    if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
                        $sameFormatCdp = Wait-AmazonCdpFormat -Target $format -Asin $asin -TimeoutMilliseconds 900
                        if ($sameFormatCdp) {
                            $verification = [pscustomobject]@{
                                Success = $true
                                EndpointOk = $true
                                TrackOk = $true
                                CapabilityOk = $true
                                PlayingOk = $true
                                SelectedOk = $true
                            }
                            Write-Log 'Light same-format verification succeeded: CDP ASIN and actual playback format match.' DarkGray
                        }
                    }
                    if (-not $verification) {
                        $verification = Wait-AmazonFormatVerified -Target $format -Asin $asin -TimeoutMilliseconds 1500
                    }
                    $timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds
                    $success = $verification.Success
                    if ($success) {
                        $reason = 'Same format; playback and endpoint verified'
                    } else {
                        Write-Log ("Same-format verification incomplete: endpoint={0}, track={1}, device={2}, playback={3}, stream={4}" -f `
                            $verification.EndpointOk, $verification.TrackOk, $verification.CapabilityOk, $verification.PlayingOk, $verification.SelectedOk) Yellow
                        $reason = 'Same format, but Amazon verification was incomplete (endpoint={0}, track={1}, device={2}, playback={3}, stream={4})' -f `
                            $verification.EndpointOk, $verification.TrackOk, $verification.CapabilityOk, $verification.PlayingOk, $verification.SelectedOk
                    }
                } elseif (-not $Apply) {
                    Write-Log "Dry run: would switch to $($format.Bits)/$($format.RateHz)." Yellow
                    $success = $true
                    $reason = 'Dry run'
                } else {
                    # A seek to 00:00 is not a new Amazon playback instance and does
                    # not reliably renegotiate the stream. Use the conservative
                    # CDP uses native seek + Previous to preserve the existing
                    # queue; the non-CDP fallback still waits for the safe gate.
                    $delay = if ($RestartDelayMs -gt 0) { $RestartDelayMs } else { [int]$config.restartDelayMs }
                    $success = Set-EndpointFormat `
                        -Device $monitorDevice `
                        -Format $format `
                        -CurrentPlaying $null `
                        -Channels ([int]$config.channels) `
                        -MuteDuringSwitch ([bool]$config.muteDuringSwitch) `
                        -WaitForRebuildSeconds ([int]$config.waitForRebuildSeconds) `
                        -RecoveryWaitSeconds ([int]$config.recoveryWaitSeconds) `
                        -Asin $asin `
                        -AsinFormats $asinFormats `
                        -RestartDelayMilliseconds $delay `
                        -PreMuted $preMuted `
                        -Timing $timing
                    if ($success -and -not $script:LastUnmuteIssued) {
                        $success = $false
                        $reason = 'Endpoint unmute command was not issued'
                    }
                    if ($success) {
                        $reason = 'Switch and five verification checks succeeded'
                    } elseif ($script:LastUnexpectedAsin -and $script:LastResyncSuccess) {
                        $reason = "Replay selected $($script:LastUnexpectedAsin); endpoint resynced to $($script:LastResyncTarget)"
                    } elseif ($script:LastUnexpectedAsin) {
                        $reason = "Replay selected $($script:LastUnexpectedAsin); endpoint resync failed"
                    } elseif (-not $script:LastUnmuteIssued) {
                        $reason = 'Endpoint unmute command was not issued'
                    } else {
                        $reason = 'Verification failed after the switch'
                    }
                    if ($success) {
                        $currentEndpointFormat = '{0} Channel, {1} bit, {2} Hz' -f [int]$config.channels, [int]$format.Bits, [int]$format.RateHz
                    } else {
                        $currentEndpointFormat = Get-DeviceDefaultFormatFast -DeviceId ([string]$monitorDevice.'Command-Line Friendly ID') -CoreAudioDeviceId ([string]$monitorDevice.'Item ID')
                    }
                }

                $timing['TotalTrackMs'] = [int]$trackTimer.ElapsedMilliseconds
                if ($script:ShowDetailedTiming) {
                    Write-Log ("Stage timing ms: detect-to-mute={0}, format={1}, mute={2}, gate={3}, endpoint={4}, replay={5}, same-ASIN={6}, playback={7}, failure-resync={8}, unmute={9}, total={10}" -f `
                        $timing['DetectionToMuteMs'], $timing['TrackEventToFormatMs'], $timing['MuteMs'], $timing['RestartGateMs'], $timing['EndpointFormatMs'], `
                        $timing['ReplayRequestMs'], $timing['SameAsinWaitMs'], $timing['PlaybackFormatWaitMs'], $timing['FailureResyncMs'], `
                        $timing['UnmuteCommandMs'], $timing['TotalTrackMs']) DarkGray
                } else {
                    Write-Log ("Track timing: total={0} ms" -f $timing['TotalTrackMs']) DarkGray
                }

                # Persist only after Amazon's actual playback format and the
                # endpoint have both passed verification.  This avoids saving
                # the briefly stale previous-track attributes seen during a
                # CDP track transition.  Cache I/O is deliberately outside the
                # measured mute/switch/replay critical path.
                if ($success -and $Apply) {
                    Save-VerifiedFormatCacheEntry -Map $verifiedFormats -Asin $asin -Format $format
                }

                if ($autoTest) {
                    $number = $testResults.Count + 1
                    [void]$testResults.Add([pscustomobject]@{
                        Number=$number; Asin=$asin; Target=$format.Text; Success=[bool]$success
                        UnexpectedAsin=$script:LastUnexpectedAsin; ResyncSuccess=[bool]$script:LastResyncSuccess
                        ResyncTarget=$script:LastResyncTarget; UnmuteIssued=[bool]$script:LastUnmuteIssued
                        Timing=$timing; Reason=$reason; Time=(Get-Date).ToString('o')
                    })
                    $color = if ($success) { 'Green' } else { 'Red' }
                    Write-Log "AutoTest $number/${TestTracks}: $(if($success){'PASS'}else{'FAIL'}) - $asin $($format.Text)" $color
                    if ($number -ge $TestTracks -or -not $success) {
                        if (-not $success) {
                            Write-Log 'This AutoTest run failed; stopping immediately instead of advancing from the failed track.' Yellow
                        }
                        $finished = $true
                    } else {
                        Start-Sleep -Milliseconds 700
                        if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
                            try { [void](Invoke-AmazonCdpNextTrack) } catch { [AmazonMediaCommands]::NextTrack((Get-MainWindow).MainWindowHandle) }
                        } else {
                            [AmazonMediaCommands]::NextTrack((Get-MainWindow).MainWindowHandle)
                        }
                        $autoTestWaitingForNext = $true
                        $autoTestNextDeadline = (Get-Date).AddSeconds(10)
                    }
                }
            } catch {
                Write-Log $_.Exception.Message Red
            }
            Start-Sleep -Milliseconds $trackPollMilliseconds
        }
        if ($autoTest) {
            $reportPath = Join-Path $script:StateDirectory 'auto-test-latest.json'
            $testResults | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
            $passed = @($testResults | Where-Object Success).Count
            $completedResults = @($testResults | Where-Object {
                $_.Timing -and $null -ne $_.Timing.TotalTrackMs
            })
            $successfulResults = @($completedResults | Where-Object Success)
            $successfulSwitchResults = @($successfulResults | Where-Object {
                [int]$_.Timing.EndpointFormatMs -gt 0
            })
            $successfulSameFormatResults = @($successfulResults | Where-Object {
                [int]$_.Timing.EndpointFormatMs -le 0
            })
            $successfulTrackValues = @($successfulResults | ForEach-Object { [double]$_.Timing.TotalTrackMs })
            $successfulSwitchValues = @($successfulSwitchResults | ForEach-Object { [double]$_.Timing.TotalTrackMs })
            $successfulSameFormatValues = @($successfulSameFormatResults | ForEach-Object { [double]$_.Timing.TotalTrackMs })
            $averageSuccessfulTrackMs = if ($successfulResults.Count -gt 0) {
                [Math]::Round([double](@($successfulTrackValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulSwitchMs = if ($successfulSwitchResults.Count -gt 0) {
                [Math]::Round([double](@($successfulSwitchValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulSameFormatMs = if ($successfulSameFormatResults.Count -gt 0) {
                [Math]::Round([double](@($successfulSameFormatValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $summaryPath = Join-Path $script:StateDirectory 'auto-test-summary.json'
            [ordered]@{
                GeneratedAt = (Get-Date).ToString('o')
                RequestedTracks = $TestTracks
                CompletedTracks = $testResults.Count
                Passed = $passed
                Failed = $testResults.Count - $passed
                AverageSuccessfulTrackMs = $averageSuccessfulTrackMs
                AverageSuccessfulSwitchMs = $averageSuccessfulSwitchMs
                AverageSuccessfulSameFormatMs = $averageSuccessfulSameFormatMs
                ResultsFile = 'auto-test-latest.json'
            } | ConvertTo-Json | Set-Content -LiteralPath $summaryPath -Encoding utf8
            Write-Host ''
            $testResults | Format-Table Number, Asin, Target, Success, UnmuteIssued, Reason -AutoSize
            if ($null -ne $averageSuccessfulTrackMs) {
                Write-Log ("AutoTest latency: average successful track={0} ms; switched={1} ms; same-format={2} ms." -f `
                    $averageSuccessfulTrackMs, $averageSuccessfulSwitchMs, $averageSuccessfulSameFormatMs) DarkGray
            } else {
                Write-Log 'AutoTest latency: no successful track timing was available.' Yellow
            }
            Write-Log "AutoTest complete: $passed/$($testResults.Count) PASS; report: $reportPath" $(if($passed -eq $testResults.Count){'Green'}else{'Red'})
            Write-Log "Latency summary: $summaryPath" DarkGray
            if ($passed -ne $testResults.Count) { exit 2 }
        }
    }
    'Restore' {
        Assert-Tool
        if (-not (Test-Path $script:BackupPath) -or -not (Test-Path $script:StatePath)) {
    throw 'No original format backup is available.'
        }
        $state = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        Invoke-SoundVolumeView /LoadDeviceFormat ([string]$state.DeviceId) $script:BackupPath
    Write-Log "Restored $($state.DeviceId): $($state.OriginalFormat)" Green
    }
}
