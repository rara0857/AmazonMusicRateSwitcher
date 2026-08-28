param(
    [ValidateSet('Probe', 'Devices', 'Once', 'Monitor', 'AutoTest', 'Restore')]
    [string] $Mode = 'Probe',

    [switch] $Apply,

    [switch] $Cdp,

    [switch] $CdpLaunch,

    [switch] $Direct,

    # Direct output plus Amazon's native WASAPI exclusive mode. The endpoint
    # format is still selected by this switcher because Amazon does not follow
    # each track's sample rate on its own.
    [switch] $Exclusive,

    # Experimental: keep the Hi-Fi Cable -> ASIO Bridge path, but ask Amazon
    # to open the virtual Hi-Fi Cable Input in its own WASAPI Exclusive mode.
    # This is deliberately separate from -Exclusive, which targets a physical
    # Direct output endpoint and releases the ASIO Bridge.
    [switch] $AsioExclusive,

    # Returns 0 when no Monitor/AutoTest backend owns the global instance
    # mutex, or 3 when another backend is already active.
    [switch] $CheckInstance,

    # Launchers pass their PID so a hidden watchdog can terminate this backend
    # even when the launcher is force-closed and normal cleanup cannot run.
    [int] $OwnerPid = 0,

    [string] $DeviceId,

    [ValidateRange(500, 5000)]
    [int] $RestartDelayMs = 0,

    [ValidateRange(1, 50)]
    [int] $TestTracks = 10
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ToolPath = Join-Path $script:ProjectRoot 'tools\SoundVolumeView\SoundVolumeView.exe'
$script:ConfigPath = Join-Path $script:ProjectRoot 'config.json'
$script:StateDirectory = Join-Path $script:ProjectRoot 'state'
$script:BackupPath = Join-Path $script:StateDirectory 'original-device-format.dat'
$script:StatePath = Join-Path $script:StateDirectory 'state.json'
$script:FormatCachePath = Join-Path $script:StateDirectory 'verified-format-cache-v4.json'
$script:AsioCableDeviceId = 'VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Input\Render'
$script:InstanceMutexName = 'Global\AmazonMusicRateSwitcher.Active.v1'
$script:InstanceMutex = $null
$script:InstanceMutexAcquired = $false

function Test-SwitcherInstanceActive {
    $mutex = [Threading.Mutex]::new($false, $script:InstanceMutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            # Force-killed owners leave an abandoned mutex. Windows transfers
            # it to this thread, so it is safe to release and reuse at once.
            $acquired = $true
        }
        return -not $acquired
    }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

if ($CheckInstance) {
    if (Test-SwitcherInstanceActive) {
        [Console]::Error.WriteLine('Amazon Music Rate Switcher is already running.')
        exit 3
    }
    exit 0
}

function Enter-SwitcherInstance {
    $mutex = [Threading.Mutex]::new($false, $script:InstanceMutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            [Console]::Error.WriteLine('Amazon Music Rate Switcher is already running. Stop the existing session before starting another one.')
            exit 3
        }
        $script:InstanceMutex = $mutex
        $script:InstanceMutexAcquired = $true
    }
    catch {
        if (-not $script:InstanceMutexAcquired) { $mutex.Dispose() }
        throw
    }
}

function Start-BackendOwnerWatchdog {
    param([int] $RequestedOwnerPid)

    $resolvedOwnerPid = $RequestedOwnerPid
    if ($resolvedOwnerPid -le 0) {
        $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
        if ($self) { $resolvedOwnerPid = [int]$self.ParentProcessId }
    }
    if ($resolvedOwnerPid -le 0 -or $resolvedOwnerPid -eq $PID) { return }

    $owner = Get-Process -Id $resolvedOwnerPid -ErrorAction SilentlyContinue
    if (-not $owner) { return }
    $ownerStartTicks = 0
    try { $ownerStartTicks = $owner.StartTime.ToUniversalTime().Ticks } catch { }

    $watcherScript = Join-Path $PSScriptRoot 'Ensure-AsioBridge.ps1'
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $watcherScript,
        '-WatchParentPid', [string]$resolvedOwnerPid,
        '-WatchParentStartTicks', [string]$ownerStartTicks,
        '-WatchBackendPid', [string]$PID
    ) | Out-Null
}

New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
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
$script:AsioExclusiveMode = [bool]$AsioExclusive
$script:ExclusiveMode = [bool]($Exclusive -or $AsioExclusive)
$script:CableCaptureFormatKey = ''
$script:DeviceNamePattern = ''
$script:ShowDetailedTiming = $false
$script:AmazonLogPath = $null

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

    public static void NextTrack(IntPtr mainWindow)
    {
        // WM_APPCOMMAND / APPCOMMAND_MEDIA_NEXTTRACK
        PostMessage(mainWindow, 0x0319, mainWindow, new IntPtr(11 << 16));
    }

    public static void PreviousTrack(IntPtr mainWindow)
    {
        // WM_APPCOMMAND / APPCOMMAND_MEDIA_PREVIOUSTRACK
        PostMessage(mainWindow, 0x0319, mainWindow, new IntPtr(12 << 16));
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
                    Write-Log "CDP connected on port $port; direct track/sample-rate switching is enabled." Green
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

$script:LastGuiTrackMetadata = ''
function Write-GuiTrackMetadata {
    param($Snapshot, [string] $Asin)

    if ($env:AMRS_GUI -ne '1' -or -not $Snapshot -or -not $Asin) { return }
    if (([string]$Snapshot.Asin).ToUpperInvariant() -ne $Asin.ToUpperInvariant()) { return }

    $metadata = [ordered]@{
        asin = $Asin.ToUpperInvariant()
        title = [string]$Snapshot.Title
        artist = [string]$Snapshot.Artist
        album = [string]$Snapshot.Album
        artworkUrl = [string]$Snapshot.ArtworkUrl
    }
    $json = $metadata | ConvertTo-Json -Compress
    if ($json -eq $script:LastGuiTrackMetadata) { return }
    $script:LastGuiTrackMetadata = $json

    # Only ASCII crosses redirected Windows PowerShell stdout. This prevents
    # Japanese and other Unicode metadata from being replaced by question marks.
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [Console]::WriteLine('@@AMRS_TRACK_B64@@' + $payload)
}

function Get-AmazonCdpSnapshot {
    $expression = @'
(()=>{const e=document.getElementById('transportContainer'),v=e&&e.__vue__,p=v&&v.$store&&v.$store.state&&v.$store.state.player,m=p&&p.model,cp=m&&m.currentPlayable,t=cp&&cp.track,a=m&&m.audioAttributes,c=m&&m.deviceCapabilities,al=(t&&t.album)||(cp&&cp.album);const asUrl=x=>{if(!x)return '';if(typeof x==='string')return x;if(Array.isArray(x)){for(const y of x){const u=asUrl(y);if(u)return u}return ''}if(typeof x==='object')return asUrl(x.url||x.href||x.src||x.image||x.imageUrl||x.coverArt);return '';};const artwork=[al&&al.image,al&&al.imageUrl,al&&al.coverArt,al&&al.cover,al&&al.images,t&&t.image,t&&t.imageUrl,cp&&cp.image,cp&&cp.imageUrl].map(asUrl).find(x=>/^https?:\/\//i.test(x))||'';return JSON.stringify({ready:!!t,asin:t&&t.asin||'',title:t&&t.title||'',artist:t&&t.artist&&t.artist.name||'',album:al&&al.name||'',artworkUrl:artwork,state:m&&m.state||'',positionMs:p&&p.progress&&p.progress.currentTime||0,track:{bits:a&&a.bestAvailableBitDepth||0,rate:a&&a.bestAvailableSampleRate||0},playing:{bits:a&&a.bitDepth||0,rate:a&&a.sampleRate||0},capability:{bits:c&&c.maxBitDepth||0,rate:c&&c.maxSampleRate||0}})})()
'@
    $data = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
    if (-not $data.ready) { return $null }
    return [pscustomobject]@{
        Process = Get-MainWindow
        Asin = [string]$data.asin
        Title = [string]$data.title
        Artist = [string]$data.artist
        Album = [string]$data.album
        ArtworkUrl = [string]$data.artworkUrl
        Track = ConvertTo-CdpFormat $data.track.bits $data.track.rate
        DeviceCapability = ConvertTo-CdpFormat $data.capability.bits $data.capability.rate
        Playing = ConvertTo-CdpFormat $data.playing.bits $data.playing.rate
        PositionMs = [int64]$data.positionMs
        State = [string]$data.state
        Raw = $data
        Source = 'Amazon CDP Player API'
    }
}

function Set-AmazonCdpOutputMode {
    param(
        [Parameter(Mandatory)] [bool] $EnableExclusive,
        [Parameter(Mandatory)] [string] $AmazonDeviceId,
        [switch] $ForceExclusiveCycle,
        [switch] $ForceOutputCycle,
        [string] $OutputCycleIntermediateId = 'default',
        [int] $TimeoutMilliseconds = 1800
    )

    if (-not $script:CdpEnabled) {
        return [pscustomobject]@{ Success=$false; Pending=$false; Exclusive=$false; Device=''; Reason='CDP is unavailable' }
    }
    if (-not $script:CdpWebSocketUrl -and -not (Initialize-AmazonCdp)) {
        return [pscustomobject]@{ Success=$false; Pending=$false; Exclusive=$false; Device=''; Reason=$script:CdpLastError }
    }

    $deviceJson = ConvertTo-Json $AmazonDeviceId -Compress
    $enabledJson = if ($EnableExclusive) { 'true' } else { 'false' }
    $forceJson = if ($ForceExclusiveCycle) { 'true' } else { 'false' }
    $forceOutputJson = if ($ForceOutputCycle) { 'true' } else { 'false' }
    $intermediateJson = ConvertTo-Json $OutputCycleIntermediateId -Compress
    $expression = @"
(async()=>{
  const desiredDevice=$deviceJson,enableExclusive=$enabledJson,forceCycle=$forceJson,forceOutputCycle=$forceOutputJson,cycleDevice=$intermediateJson,timeout=$TimeoutMilliseconds;
  const root=()=>document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
  const outputControl=()=>{
    const transport=root(),base=transport&&(transport.`$root||transport),seen=new Set();let found=null;
    const walk=v=>{if(!v||seen.has(v)||found)return;seen.add(v);if(typeof v.setOutputDevice==='function'&&Array.isArray(v.deviceList)){found=v;return}(v.`$children||[]).forEach(walk)};
    walk(base);return found;
  };
  const read=()=>{
    const v=root(),p=v&&v.`$store&&v.`$store.state&&v.`$store.state.player,m=p&&p.model,o=m&&m.outputDeviceAttributes,t=m&&m.currentPlayable&&m.currentPlayable.track;
    return {ready:!!v,hasTrack:!!t,device:o&&o.currentDevice&&String(o.currentDevice.id||'')||'',deviceName:o&&o.currentDevice&&String(o.currentDevice.displayName||'')||'',exclusive:!!(o&&o.exclusiveMode)};
  };
  const wait=async predicate=>{const deadline=Date.now()+timeout;let state=read();while(Date.now()<deadline&&!predicate(state)){await new Promise(r=>setTimeout(r,10));state=read()}return state};
  const selectDevice=async id=>{const ctl=outputControl();if(ctl){await Promise.resolve(ctl.setOutputDevice(id));return true}if(window.Native&&window.Native.Player&&typeof window.Native.Player.setOutputDevice==='function'){await Promise.resolve(window.Native.Player.setOutputDevice(id));return true}return false};
  const selectExclusive=async enabled=>{const ctl=outputControl();if(ctl&&typeof ctl.toggleExclusiveMode==='function'){if(read().exclusive!==enabled)await Promise.resolve(ctl.toggleExclusiveMode());return true}if(window.Native&&window.Native.Player&&typeof window.Native.Player.setExclusiveMode==='function'){await Promise.resolve(window.Native.Player.setExclusiveMode(enabled));return true}return false};
  const selectAndWait=async id=>{
    let state=read();
    if(state.device===id)return state;
    for(let attempt=0;attempt<2;attempt++){
      if(!await selectDevice(id))return state;
      state=await wait(s=>s.device===id);
      if(state.device===id)return state;
      await new Promise(r=>setTimeout(r,50));
      state=read();
    }
    return state;
  };
  if(!root()||(!outputControl()&&(!window.Native||!window.Native.Player||typeof window.Native.Player.setOutputDevice!=='function')))
    return JSON.stringify({ok:false,pending:false,reason:'Amazon output controls are unavailable',state:read()});
  let state=read();
  if(state.exclusive&&(forceCycle||forceOutputCycle||!enableExclusive||state.device!==desiredDevice)){
    if(!await selectExclusive(false))return JSON.stringify({ok:false,pending:false,reason:'Amazon Exclusive control is unavailable',state});
    state=await wait(s=>!s.exclusive);
  }
  if(desiredDevice&&forceOutputCycle&&cycleDevice&&desiredDevice!==cycleDevice){
    state=await selectAndWait(cycleDevice);
    if(state.device!==cycleDevice)
      return JSON.stringify({ok:false,pending:false,reason:'Amazon did not switch to the temporary output device',state});
    state=await selectAndWait(desiredDevice);
    if(state.device!==desiredDevice)
      return JSON.stringify({ok:false,pending:false,reason:'Amazon did not return to the requested output device',state});
  } else if(desiredDevice&&state.device!==desiredDevice){
    state=await selectAndWait(desiredDevice);
    if(state.device!==desiredDevice)
      return JSON.stringify({ok:false,pending:false,reason:'Amazon did not select the requested output device',state});
  }
  if(!enableExclusive)
    return JSON.stringify({ok:!state.exclusive,pending:false,reason:state.exclusive?'Amazon did not release exclusive mode':'',state});
  if(!state.hasTrack)
    return JSON.stringify({ok:false,pending:true,reason:'Exclusive mode will be armed when playback starts',state});
  if(!state.exclusive){
    if(!await selectExclusive(true))return JSON.stringify({ok:false,pending:false,reason:'Amazon Exclusive control is unavailable',state});
    state=await wait(s=>s.exclusive);
  }
  return JSON.stringify({ok:state.exclusive,pending:false,reason:state.exclusive?'':'Amazon rejected exclusive mode and fell back to shared mode',state});
})()
"@

    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        $state = $result.state
        $output = [pscustomobject]@{
            Success = [bool]$result.ok
            Pending = [bool]$result.pending
            Exclusive = [bool]$state.exclusive
            Device = [string]$state.deviceName
            Reason = [string]$result.reason
        }
        if ($env:AMRS_GUI -eq '1') {
            [Console]::WriteLine('@@AMRS_EXCLUSIVE@@' + $(if ($output.Exclusive) { 'ON' } else { 'OFF' }))
        }
        return $output
    }
    catch {
        return [pscustomobject]@{ Success=$false; Pending=$false; Exclusive=$false; Device=''; Reason=$_.Exception.Message }
    }
}

function Refresh-AmazonOutputStream {
     param(
         [Parameter(Mandatory)] [string] $AmazonDeviceId
     )

     if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) {
         return [pscustomobject]@{ Success=$true; Skipped=$true; Reason='' }
     }

     # Amazon can keep its existing audio client alive after the Windows
     # endpoint format changes.  Selecting a genuinely different endpoint and
     # immediately returning to the requested one asks Amazon's own output
     # control to create a fresh client, which is what makes the physical DAC
     # lock to the new sample rate.  This is intentionally a best-effort step:
     # a failed device refresh must never turn a valid track switch into a
     # queue failure.
     $intermediateId = ''
     $intermediateName = ''
     try {
         $decodedDevices = @(Invoke-AmazonCdpExpression -Expression @'
(()=>{const e=document.getElementById('transportContainer'),v=e&&e.__vue__,p=v&&v.$store&&v.$store.state&&v.$store.state.player,m=p&&p.model,o=m&&m.outputDeviceAttributes,ds=o&&o.devices||[];return JSON.stringify(ds.map(x=>({id:x.id||'',name:x.displayName||''})))})()
'@ | ConvertFrom-Json)
         # Windows PowerShell 5.1 can keep a JSON root array as one nested
         # object when it crosses a pipeline. Flatten that shape before looking
         # up the cable endpoint; otherwise [string]$cable.Id becomes a list of
         # every device ID and Amazon silently keeps the old stream.
         $devices = if ($decodedDevices.Count -eq 1 -and $decodedDevices[0] -is [Array]) {
             @($decodedDevices[0])
         } else {
             @($decodedDevices)
         }
         $cable = $devices | Where-Object {
             [string]$_.Name -match '(?i)Hi-Fi Cable Input' -and [string]$_.Id -ne $AmazonDeviceId
         } | Select-Object -First 1
         if ($cable) {
             $intermediateId = [string]$cable.Id
             $intermediateName = [string]$cable.Name
         } else {
             $fallback = $devices | Where-Object {
                 [string]$_.Id -and [string]$_.Id -ne 'default' -and [string]$_.Id -ne $AmazonDeviceId
             } | Select-Object -First 1
             if ($fallback) {
                 $intermediateId = [string]$fallback.Id
                 $intermediateName = [string]$fallback.Name
             }
         }
     } catch {
         return [pscustomobject]@{ Success=$false; Skipped=$false; Reason=$_.Exception.Message }
     }
     if (-not $intermediateId) {
         return [pscustomobject]@{ Success=$false; Skipped=$false; Reason='Amazon did not expose a second output endpoint' }
     }

     $deviceJson = ConvertTo-Json $AmazonDeviceId -Compress
     $intermediateJson = ConvertTo-Json $intermediateId -Compress
     $exclusiveJson = if ($script:ExclusiveMode) { 'true' } else { 'false' }
     # Do not require the Vue store's currentDevice field to change between
     # the two calls. During an audio-client teardown that field can lag even
     # though setOutputDevice has already been accepted by Amazon. The actual
     # device calls are the important part for the DAC; read-back is diagnostic.
     $expression = @"
(async()=>{
  const target=$deviceJson,temporary=$intermediateJson,exclusive=$exclusiveJson;
  const e=document.getElementById('transportContainer'),v=e&&e.__vue__,root=v&&v.`$root||v;
  const findControl=()=>{const seen=new Set();let found=null;const walk=x=>{if(!x||seen.has(x)||found)return;seen.add(x);if(typeof x.setOutputDevice==='function'&&Array.isArray(x.deviceList)){found=x;return}(x.`$children||[]).forEach(walk)};walk(root);return found};
  const p=v&&v.`$store&&v.`$store.state&&v.`$store.state.player,m=p&&p.model;
  const read=()=>{const o=m&&m.outputDeviceAttributes;return {device:o&&o.currentDevice&&String(o.currentDevice.id||'')||'',deviceName:o&&o.currentDevice&&String(o.currentDevice.displayName||'')||'',exclusive:!!(o&&o.exclusiveMode)}};
  const delay=ms=>new Promise(r=>setTimeout(r,ms));
  const errors=[];let method='';
  const select=async id=>{if(!id){errors.push('empty endpoint id');return false}let last='';for(let attempt=0;attempt<30;attempt++){try{const c=findControl();const listed=c&&Array.isArray(c.deviceList)&&c.deviceList.some(d=>String(d&&d.id||'')===id);if(c){if(listed){await Promise.resolve(c.setOutputDevice(id));method='vue';return true}last='endpoint is not listed yet'}else if(window.Native&&window.Native.Player&&typeof window.Native.Player.setOutputDevice==='function'){await Promise.resolve(window.Native.Player.setOutputDevice(id));method='native';return true}else{last='setOutputDevice unavailable'}}catch(e){last=String(e&&e.message||e)}await delay(50)}errors.push(last||'setOutputDevice unavailable');return false};
  const toggle=async()=>{let last='';for(let attempt=0;attempt<24;attempt++){try{const c=findControl();if(c&&typeof c.toggleExclusiveMode==='function'){await Promise.resolve(c.toggleExclusiveMode());return true}if(window.Native&&window.Native.Player&&typeof window.Native.Player.setExclusiveMode==='function'){await Promise.resolve(window.Native.Player.setExclusiveMode(!read().exclusive));return true}last='exclusive control unavailable'}catch(e){last=String(e&&e.message||e)}await delay(50)}errors.push(last||'exclusive control unavailable');return false};
  if(!findControl()&&!(window.Native&&window.Native.Player&&typeof window.Native.Player.setOutputDevice==='function'))return JSON.stringify({ok:false,reason:'Amazon output controls are unavailable',before:read(),after:read()});
  const before=read();let ok=true;
  if(exclusive&&before.exclusive){ok=await toggle()&&ok;await delay(45)}
  ok=await select(temporary)&&ok;await delay(75);
  ok=await select(target)&&ok;await delay(75);
  if(exclusive&&before.exclusive){ok=await toggle()&&ok;await delay(45)}
  return JSON.stringify({ok,requested:ok,method,reason:errors.join('; '),before,after:read()});
})()
"@
     try {
         $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
         if (-not $result.ok) {
             # A stream rebuild can briefly hide the Vue output control. Retry
             # once after the renderer has had one scheduling turn.
             Start-Sleep -Milliseconds 220
             $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
         }
     } catch {
         return [pscustomobject]@{ Success=$false; Skipped=$false; Reason=$_.Exception.Message }
     }
     if (-not $result.ok) {
         return [pscustomobject]@{ Success=$false; Skipped=$false; Reason=([string]$result.reason) }
     }
     $finalName = [string]$result.after.deviceName
     return [pscustomobject]@{
         Success=$true; Skipped=$false; Reason=''; Intermediate=$intermediateName; Device=$finalName; Method=[string]$result.method
     }
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

    if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) {
        return [pscustomobject]@{
            Success=$false; Mode=''; Fallback=$false; SoughtMs=0; PositionMs=0; BeforePositionMs=0; ReadyWaitMs=0
            Reason='CDP is unavailable; the queue-safe seek/Previous path cannot be confirmed.'
        }
    }

    $expectedJson = ConvertTo-Json $ExpectedAsin.ToUpperInvariant() -Compress
    $expression = @'
(async()=>{
  const expected=__EXPECTED_ASIN__;
  const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
  if(!v||typeof v.handlePreviousButton!=='function')
    return JSON.stringify({ok:false,error:'Amazon Previous control is unavailable'});
  const p=v.$store&&v.$store.state&&v.$store.state.player;
  const read=()=>{
    const m=p&&p.model||{},t=m.currentPlayable&&m.currentPlayable.track,pr=p&&p.progress||{};
    const duration=Number(m.duration)||Number(t&&t.duration||0)*1000;
    return {
      asin:String(t&&t.asin||''),position:Number(pr.currentTime||0),
      buffered:Number(pr.buffered||0),duration:duration,state:String(m.state||'')
    };
  };
  let before=read(),syncDeadline=Date.now()+1500;
  while(Date.now()<syncDeadline&&before.asin.toUpperCase()!==expected){
    await new Promise(r=>setTimeout(r,10));
    before=read();
  }
  if(before.asin.toUpperCase()!==expected)
    return JSON.stringify({ok:false,error:'The current ASIN has not synchronized before the 4.5-second seek',before});
  const target=4500;
  // The seek call queues Amazon's target position even when the paused
  // pipeline has not published a progress tick yet.  Previous uses that
  // queued position to decide whether to restart the current track, so do not
  // add a 1.2-second confirmation sleep between seek and Previous.
  let mode='';
  try{
    if(window.Native&&window.Native.Player&&typeof window.Native.Player.seek==='function'){
      await Promise.resolve(window.Native.Player.seek(target,'progress'));
      mode='native-seek';
    }else if(typeof v.dragFinished==='function'){
      if(before.duration<target)
        return JSON.stringify({ok:false,error:'Track duration is too short for the safe 4.5-second Previous gate',before});
      await Promise.resolve(v.dragFinished(Math.min(90,target/before.duration*100)));
      mode='vue-seek';
    }else{
      return JSON.stringify({ok:false,error:'No seek method is available',before});
    }
  }catch(e){
    return JSON.stringify({ok:false,error:String(e&&e.message||e),before});
  }
  // Keep the immediate post-seek snapshot for diagnostics only.  Previous is
  // intentionally invoked without waiting for this progress value to move.
  let sought=read(),readyWaitMs=0;
  if(sought.asin.toUpperCase()!==expected)
    return JSON.stringify({ok:false,error:'The track changed during the 4.5-second seek',before,sought});
  try{
    await Promise.resolve(v.handlePreviousButton());
  }catch(e){
    return JSON.stringify({ok:false,error:String(e&&e.message||e),before,sought,mode});
  }
  let after=read(),resetDeadline=Date.now()+1600;
  while(Date.now()<resetDeadline&&after.asin.toUpperCase()===expected&&after.position>1000){
    await new Promise(r=>setTimeout(r,15));
    after=read();
  }
  if(after.asin.toUpperCase()!==expected)
    return JSON.stringify({ok:false,error:'Previous selected a different track',before,sought,after,mode});
  if(after.position>1000)
    return JSON.stringify({ok:false,error:'Previous did not return to the start of the current track',before,sought,after,mode});
  return JSON.stringify({ok:true,mode:mode,soughtMs:sought.position,positionMs:after.position,beforePositionMs:before.position,readyWaitMs});
})()
'@
    $expression = $expression.Replace('__EXPECTED_ASIN__', $expectedJson)
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        return [pscustomobject]@{
            Success = [bool]$result.ok
            Mode = [string]$result.mode
            Fallback = [bool]$result.fallback
            SoughtMs = [int64]$result.soughtMs
            PositionMs = [int64]$result.positionMs
            BeforePositionMs = [int64]$result.beforePositionMs
            ReadyWaitMs = [int]$result.readyWaitMs
            Reason = [string]$result.error
        }
    } catch {
        return [pscustomobject]@{ Success=$false; Mode=''; Fallback=$false; SoughtMs=0; PositionMs=0; BeforePositionMs=0; ReadyWaitMs=0; Reason=$_.Exception.Message }
    }
}

function Seek-AmazonCdpTrackToStart {
    param(
        [Parameter(Mandatory)] [string] $ExpectedAsin,
        [int] $TimeoutMilliseconds = 2500,
        [switch] $RequireProgressBeforeSeek,
        [switch] $PipelineReady
    )

    # Amazon can publish currentPlayable before AudioPipeline has built the
    # first buffered fragment. A seek sent in that window is logged as
    # "Deferring seek; current track not yet initialized" and the first Play
    # can then resume from the beginning of the buffered fragment (often near
    # 1 second). Wait for a non-zero buffer, then issue the final seek while
    # the transport is still paused. This is different from waiting for the
    # visible progress counter, which cannot advance while paused.
    $expectedJson = ConvertTo-Json $ExpectedAsin.ToUpperInvariant() -Compress
    $requireProgressJson = if ($RequireProgressBeforeSeek) { 'true' } else { 'false' }
    $pipelineReadyJson = if ($PipelineReady) { 'true' } else { 'false' }
    $expression = @"
(async()=>{
  const expected=$expectedJson,requireProgress=$requireProgressJson,pipelineReady=$pipelineReadyJson,deadline=Date.now()+$TimeoutMilliseconds;
  const e=document.getElementById('transportContainer'),v=e&&e.__vue__;
  if(!v)return JSON.stringify({ok:false,error:'Transport component not found'});
  const p=v.`$store&&v.`$store.state&&v.`$store.state.player;
  const read=()=>{
    const m=p&&p.model||{},t=m.currentPlayable&&m.currentPlayable.track,pr=p&&p.progress||{};
    const duration=Number(m.duration)||Number(t&&t.duration||0)*1000;
    const buffered=Number(pr.buffered||0);
    return {
      asin:String(t&&t.asin||''),position:Number(pr.currentTime||0),buffered:buffered,
      duration:duration,state:String(m.state||''),isSeeking:!!m.isSeeking
    }
  };
  let state=read();
  if(state.asin.toUpperCase()!==expected)
    return JSON.stringify({ok:false,error:'The current ASIN changed before the final position reset',state});
  // When playback is kept running, wait for the first real progress tick so a
  // pre-initialization position of exactly zero is not mistaken for a seek
  // result. In the paused path below we use the buffered-fragment boundary
  // instead, because the visible progress counter cannot advance while paused.
  if(requireProgress){
    let initialized=false;
    while(Date.now()<deadline){
      state=read();
      if(state.asin.toUpperCase()!==expected)
        return JSON.stringify({ok:false,error:'The current ASIN changed while waiting for audio initialization',state});
      if(state.position>0){initialized=true;break}
      await new Promise(r=>setTimeout(r,10));
    }
    if(!initialized)
      return JSON.stringify({ok:false,error:'The new track audio pipeline was not initialized before the final seek',state});
  }
  const beforeSeekPosition=state.position;
  let method='',attempts=0,readyObserved=false,readyWaitMs=0;
  const readyStarted=Date.now();
  const issueSeek=async()=>{
    if(window.Native&&window.Native.Player&&typeof window.Native.Player.seek==='function'){
      await Promise.resolve(window.Native.Player.seek(0,'progress'));
      method='native';
    } else if(typeof v.dragFinished==='function'){
      await Promise.resolve(v.dragFinished(0));
      method='vue';
    }
    attempts++;
  };
  if(requireProgress){
    try { await issueSeek(); } catch(e) {
      return JSON.stringify({ok:false,error:String(e&&e.message||e),state,attempts});
    }
    if(!method)return JSON.stringify({ok:false,error:'No seek method is available',state,attempts});
  } else if(pipelineReady){
    readyObserved=true;
    readyWaitMs=0;
    try { await issueSeek(); } catch(e) {
      return JSON.stringify({ok:false,error:String(e&&e.message||e),state,attempts,readyWaitMs});
    }
  } else {
    // Do not accept the initial zero position as proof of success: before the
    // first fragment is buffered, Amazon reports zero even though the native
    // seek has been deferred. The seek is issued only after buffered > 0.
    while(Date.now()<deadline){
      state=read();
      if(state.asin.toUpperCase()!==expected)
        return JSON.stringify({ok:false,error:'The current ASIN changed while waiting for the audio pipeline',state,attempts});
      if(state.buffered>0){
        readyObserved=true;
        readyWaitMs=Date.now()-readyStarted;
        try { await issueSeek(); } catch(e) {
          return JSON.stringify({ok:false,error:String(e&&e.message||e),state,attempts,readyWaitMs});
        }
        break;
      }
      await new Promise(r=>setTimeout(r,20));
    }
    if(!readyObserved)
      return JSON.stringify({ok:false,error:'The new track audio pipeline did not expose a buffered fragment before the final seek',state,attempts,readyWaitMs:Date.now()-readyStarted});
    if(!method)return JSON.stringify({ok:false,error:'No seek method is available',state,attempts,readyWaitMs});
  }
  // Give the renderer one progress tick to commit the asynchronous seek before
  // declaring success. This is intentionally short; the caller supplies the
  // separate hold before Play.
  await new Promise(r=>setTimeout(r,15));
  while(Date.now()<deadline){
    state=read();
    if(state.asin.toUpperCase()!==expected)
      return JSON.stringify({ok:false,error:'The current ASIN changed during the final position reset',state,method,attempts,readyWaitMs});
    if(state.position<=50)
      return JSON.stringify({ok:true,asin:state.asin,positionMs:state.position,beforePositionMs:beforeSeekPosition,method,attempts,readyWaitMs});
    await new Promise(r=>setTimeout(r,15));
  }
  return JSON.stringify({ok:false,error:'The final seek did not settle within 50 ms of the start of the track',state,method,attempts,readyWaitMs});
})()
"@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        return [pscustomobject]@{
            Success = [bool]$result.ok
            PositionMs = [int64]$result.positionMs
            BeforePositionMs = [int64]$result.beforePositionMs
            Method = [string]$result.method
            Reason = [string]$result.error
            Attempts = [int]$result.attempts
            ReadyWaitMs = [int]$result.readyWaitMs
        }
    } catch {
        return [pscustomobject]@{ Success=$false; PositionMs=0; Method=''; Reason=$_.Exception.Message; Attempts=0; ReadyWaitMs=0 }
    }
}

function Invoke-AmazonCdpPlaybackToggle {
    if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) { return $false }

    $expression = @'
(async()=>{const e=document.getElementById('transportContainer'),v=e&&e.__vue__;if(!v)return JSON.stringify({ok:false,error:'Transport component not found'});const fn=typeof v.handlePlayButton==='function'?v.handlePlayButton:(typeof v.handlePlayback==='function'?v.handlePlayback:null);if(!fn)return JSON.stringify({ok:false,error:'Amazon playback control is unavailable'});try{await Promise.resolve(fn.call(v));return JSON.stringify({ok:true})}catch(e){return JSON.stringify({ok:false,error:String(e&&e.message||e)})}})()
'@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        return [bool]$result.ok
    } catch {
        return $false
    }
}

function Pause-AmazonPlaybackForSwitch {
    param(
        [string] $State = '',
        [switch] $AssumePlaying
    )

    $wasPlaying = if ([string]::IsNullOrWhiteSpace($State)) {
        [bool]$AssumePlaying
    } else {
        $State -notmatch '(?i)pause|stop|idle|end|finish'
    }
    if (-not $wasPlaying) {
        return [pscustomobject]@{ Success=$true; Changed=$false; WasPlaying=$false; Reason='Amazon was already paused' }
    }

    # A track-change notification can arrive while Amazon is still settling its
    # transport state.  Sending a toggle and sleeping for 15 ms is not a pause
    # barrier: the endpoint switch may begin while the decoder is still
    # advancing.  When CDP is available, use the renderer state itself as the
    # acknowledgement and fail closed if it never settles.
    if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
        $pauseState = Ensure-AmazonCdpPlaybackPaused
        if ($pauseState.Success) {
            return [pscustomobject]@{
                Success=$true; Changed=[bool]$pauseState.Changed; WasPlaying=$true
                Reason='method=CDP; state=' + [string]$pauseState.State
            }
        }
        return [pscustomobject]@{
            Success=$false; Changed=$false; WasPlaying=$true
            Reason='CDP pause was not confirmed: ' + [string]$pauseState.Reason
        }
    }

    # Non-CDP mode has no reliable playback-state acknowledgement.  Keep the
    # legacy media-key fallback for shared-output use, but do not pretend that
    # the 15 ms delay is a confirmed pause.
    try {
        [AmazonMediaCommands]::TogglePlayback((Get-MainWindow).MainWindowHandle)
        Start-Sleep -Milliseconds 40
        $method = 'MediaKey'
        return [pscustomobject]@{ Success=$true; Changed=$true; WasPlaying=$true; Reason="method=$method" }
    } catch {
        return [pscustomobject]@{ Success=$false; Changed=$false; WasPlaying=$true; Reason=$_.Exception.Message }
    }
}

function Resume-AmazonPlaybackImmediately {
    param([Parameter(Mandatory)] [bool] $WasPaused)

    if (-not $WasPaused) {
        return [pscustomobject]@{ Success=$true; Changed=$false; Method=''; Reason='Playback was not paused by the switcher' }
    }

    try {
        if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
            $playState = Ensure-AmazonCdpPlaybackPlaying
            return [pscustomobject]@{
                Success=[bool]$playState.Success; Changed=[bool]$playState.Changed
                Method='CDP'; Reason='method=CDP; state=' + [string]$playState.State +
                    $(if ($playState.Success) { '' } else { '; ' + [string]$playState.Reason })
            }
        }

        [AmazonMediaCommands]::TogglePlayback((Get-MainWindow).MainWindowHandle)
        Start-Sleep -Milliseconds 40
        return [pscustomobject]@{ Success=$true; Changed=$true; Method='MediaKey'; Reason='method=MediaKey' }
    } catch {
        return [pscustomobject]@{ Success=$false; Changed=$false; Method=''; Reason=$_.Exception.Message }
    }
}

function Ensure-AmazonCdpPlaybackPaused {
    if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) {
        return [pscustomobject]@{ Success=$false; Changed=$false; State=''; Reason='CDP is unavailable.' }
    }

    $expression = @'
(async()=>{
  const e=document.getElementById('transportContainer'),v=e&&e.__vue__,p=v&&v.$store&&v.$store.state&&v.$store.state.player;
  if(!v||!p)return JSON.stringify({ok:false,error:'Amazon player state is unavailable'});
  const fn=typeof v.handlePlayButton==='function'?v.handlePlayButton:(typeof v.handlePlayback==='function'?v.handlePlayback:null);
  if(!fn)return JSON.stringify({ok:false,error:'Amazon playback control is unavailable'});
  const read=()=>String(p.model&&p.model.state||'');
  let state=read();
  if(!state)return JSON.stringify({ok:false,error:'Amazon playback state is empty'});
  if(/pause|stop|idle|end|finish/i.test(state))return JSON.stringify({ok:true,changed:false,state});
  try{await Promise.resolve(fn.call(v));}catch(error){return JSON.stringify({ok:false,error:String(error&&error.message||error),state});}
  const deadline=Date.now()+500;
  do{
    state=read();
    if(/pause|stop|idle|end|finish/i.test(state))return JSON.stringify({ok:true,changed:true,state});
    await new Promise(r=>setTimeout(r,15));
  }while(Date.now()<deadline);
  return JSON.stringify({ok:false,changed:true,state,error:'Amazon did not settle in a paused state'});
})()
'@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        return [pscustomobject]@{
            Success = [bool]$result.ok
            Changed = [bool]$result.changed
            State = [string]$result.state
            Reason = [string]$result.error
        }
    } catch {
        return [pscustomobject]@{ Success=$false; Changed=$false; State=''; Reason=$_.Exception.Message }
    }
}

function Ensure-AmazonCdpPlaybackPlaying {
    if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) {
        return [pscustomobject]@{ Success=$false; Changed=$false; State=''; Reason='CDP is unavailable.' }
    }

    $expression = @'
(async()=>{
  const e=document.getElementById('transportContainer'),v=e&&e.__vue__,p=v&&v.$store&&v.$store.state&&v.$store.state.player;
  if(!v||!p)return JSON.stringify({ok:false,error:'Amazon player state is unavailable'});
  const fn=typeof v.handlePlayButton==='function'?v.handlePlayButton:(typeof v.handlePlayback==='function'?v.handlePlayback:null);
  if(!fn)return JSON.stringify({ok:false,error:'Amazon playback control is unavailable'});
  const read=()=>String(p.model&&p.model.state||'');
  const isPaused=state=>/pause|stop|idle|end|finish/i.test(state);
  let state=read();
  if(!state)return JSON.stringify({ok:false,error:'Amazon playback state is empty'});
  if(!isPaused(state))return JSON.stringify({ok:true,changed:false,state});
  try{await Promise.resolve(fn.call(v));}catch(error){return JSON.stringify({ok:false,error:String(error&&error.message||error),state});}
  const deadline=Date.now()+700;
  do{
    state=read();
    if(state&&!isPaused(state))return JSON.stringify({ok:true,changed:true,state});
    await new Promise(r=>setTimeout(r,15));
  }while(Date.now()<deadline);
  return JSON.stringify({ok:false,changed:true,state,error:'Amazon did not settle in a playing state'});
})()
'@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        return [pscustomobject]@{
            Success = [bool]$result.ok
            Changed = [bool]$result.changed
            State = [string]$result.state
            Reason = [string]$result.error
        }
    } catch {
        return [pscustomobject]@{ Success=$false; Changed=$false; State=''; Reason=$_.Exception.Message }
    }
}

function Resume-AmazonPlaybackAfterSwitch {
    param(
        [Parameter(Mandatory)] [bool] $WasPaused,
        [string] $ExpectedAsin = '',
        [string] $AmazonDeviceId = ''
    )

    if (-not $WasPaused) {
        return [pscustomobject]@{ Success=$true; Changed=$false; ReplaySuccess=$true; ReplayMode=''; ReplayFallback=$false; ReplayReason=''; ReplayMs=0; ReplaySoughtMs=0; ReplayPositionMs=0; ReplayReadyWaitMs=0; PauseAfterReplaySuccess=$true; PauseAfterReplayChanged=$false; PauseAfterReplayMs=0; ExclusiveSuccess=$true; ExclusiveMs=0; ExclusiveReason=''; Reason='Playback was not paused by the switcher' }
    }

    try {
        # Amazon's Previous button only restarts the current track after its
        # position has crossed the same safe threshold used by the app. Seek
        # to about 4.5 seconds while still paused, then invoke Previous so
        # Amazon resets its own playback instance and decoder cursor.
        $replayTimer = [Diagnostics.Stopwatch]::StartNew()
        $replay = Invoke-AmazonCdpFastRestartCurrentTrack -ExpectedAsin $ExpectedAsin
        $replayElapsed = [int]$replayTimer.ElapsedMilliseconds
        if (-not $replay.Success) {
            throw "Could not seek to 4.5 seconds and restart the current track: $($replay.Reason)"
        }

        # Previous normally preserves the paused state, but some Amazon builds
        # briefly resume the restarted instance. Explicitly settle it paused
        # before touching Exclusive so the final Play is the only audible start.
        $pauseAfterReplayTimer = [Diagnostics.Stopwatch]::StartNew()
        $pauseAfterReplay = Ensure-AmazonCdpPlaybackPaused
        $pauseAfterReplayElapsed = [int]$pauseAfterReplayTimer.ElapsedMilliseconds
        if (-not $pauseAfterReplay.Success) {
            throw "Amazon did not remain paused after Previous: $($pauseAfterReplay.Reason)"
        }

        # Previous can release Exclusive while Amazon creates the restarted
        # playback instance. Re-arm it only after Previous has returned to the
        # current track, immediately before the final Play.
        $exclusiveSuccess = $true
        $exclusiveReason = ''
        $exclusiveElapsed = 0
        if ($script:ExclusiveMode) {
            if (-not $AmazonDeviceId) { throw 'Amazon output device ID is required to re-arm Exclusive after Previous.' }
            $exclusiveTimer = [Diagnostics.Stopwatch]::StartNew()
            $exclusiveState = Set-AmazonCdpOutputMode -EnableExclusive $true -AmazonDeviceId $AmazonDeviceId -ForceExclusiveCycle
            $exclusiveElapsed = [int]$exclusiveTimer.ElapsedMilliseconds
            $exclusiveSuccess = [bool]$exclusiveState.Success
            $exclusiveReason = [string]$exclusiveState.Reason
            if (-not $exclusiveSuccess) {
                throw "Amazon Exclusive could not be re-armed after Previous: $exclusiveReason"
            }
            Write-Log "Amazon Exclusive active after Previous on $($exclusiveState.Device)." Green
        }

        if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
            $playState = Ensure-AmazonCdpPlaybackPlaying
            if (-not $playState.Success) {
                throw "Amazon did not settle into playback after Exclusive was armed: $($playState.Reason)"
            }
            $method = 'CDP'
        } else {
            [AmazonMediaCommands]::TogglePlayback((Get-MainWindow).MainWindowHandle)
            Start-Sleep -Milliseconds 40
            $method = 'MediaKey'
        }
        return [pscustomobject]@{
            Success=$true; Changed=$true; ReplaySuccess=$replay.Success; ReplayMode=$replay.Mode; ReplayFallback=$replay.Fallback; ReplayReason=$replay.Reason
            ReplayMs=$replayElapsed; ReplaySoughtMs=$replay.SoughtMs; ReplayPositionMs=$replay.PositionMs; ReplayReadyWaitMs=$replay.ReadyWaitMs
            PauseAfterReplaySuccess=$pauseAfterReplay.Success; PauseAfterReplayChanged=$pauseAfterReplay.Changed; PauseAfterReplayMs=$pauseAfterReplayElapsed
            ExclusiveSuccess=$exclusiveSuccess; ExclusiveMs=$exclusiveElapsed; ExclusiveReason=$exclusiveReason
            Reason="replay=$($replay.Mode); method=$method"
        }
    } catch {
        return [pscustomobject]@{ Success=$false; Changed=$false; ReplaySuccess=$false; ReplayMode=''; ReplayFallback=$false; ReplayReason=$_.Exception.Message; ReplayMs=0; ReplaySoughtMs=0; ReplayPositionMs=0; ReplayReadyWaitMs=0; PauseAfterReplaySuccess=$false; PauseAfterReplayChanged=$false; PauseAfterReplayMs=0; ExclusiveSuccess=$false; ExclusiveMs=0; ExclusiveReason=$_.Exception.Message; Reason=$_.Exception.Message }
    }
}

function Wait-AmazonCdpFormat {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)][string] $Asin,
        [int] $TimeoutMilliseconds = 5000,
        [switch] $RequireExclusive
    )
    # Wait inside Amazon's renderer in a single CDP request.  The previous
    # PowerShell loop made a full websocket round trip and rebuilt a snapshot
    # every 50 ms, adding scheduling jitter after Playing was already correct.
    $asinJson = ConvertTo-Json $Asin.ToUpperInvariant() -Compress
    $bits = [int]$Target.Bits
    $rate = [int]$Target.RateHz
    $requireExclusiveJson = if ($RequireExclusive) { 'true' } else { 'false' }
    $expression = @"
(async()=>{
  const expected=$asinJson,bits=$bits,rate=$rate,requireExclusive=$requireExclusiveJson,deadline=Date.now()+$TimeoutMilliseconds;
  while(Date.now()<deadline){
    const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
    const p=v&&v.`$store&&v.`$store.state&&v.`$store.state.player,m=p&&p.model,t=m&&m.currentPlayable&&m.currentPlayable.track,a=m&&m.audioAttributes,o=m&&m.outputDeviceAttributes;
    const playbackState=String(m&&m.state||''),active=!/pause|stop|idle|end|finish/i.test(playbackState);
    const exclusive=!!(o&&o.exclusiveMode);
    if(t&&String(t.asin||'').toUpperCase()===expected&&active&&a&&Number(a.bitDepth)===bits&&Number(a.sampleRate)===rate&&(!requireExclusive||exclusive))
      return JSON.stringify({ok:true,asin:String(t.asin||''),title:String(t.title||''),bits:Number(a.bitDepth),rate:Number(a.sampleRate),exclusive:exclusive,state:playbackState});
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

function Invoke-AmazonExclusiveRecovery {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] [string] $AmazonDeviceId
    )

    if (-not ($script:ExclusiveMode -and $script:CdpEnabled -and $script:CdpWebSocketUrl)) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=0; ExclusiveMs=0; ResumeMs=0; VerifyMs=0
            Reason='Amazon CDP Exclusive recovery is unavailable.'
        }
    }
    if (-not $AmazonDeviceId) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=0; ExclusiveMs=0; ResumeMs=0; VerifyMs=0
            Reason='Amazon output device ID is missing.'
        }
    }

    # This path runs only after a post-resume verification miss. Rebuilding the
    # stream while it is paused avoids leaving a playing shared-mode client alive
    # when Amazon's Vue Exclusive flag has gone stale.
    $pauseTimer = [Diagnostics.Stopwatch]::StartNew()
    $pause = Ensure-AmazonCdpPlaybackPaused
    $pauseMs = [int]$pauseTimer.ElapsedMilliseconds
    if (-not $pause.Success) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=$pauseMs; ExclusiveMs=0; ResumeMs=0; VerifyMs=0
            Reason='Could not pause Amazon for Exclusive recovery: ' + [string]$pause.Reason
        }
    }

    $exclusiveTimer = [Diagnostics.Stopwatch]::StartNew()
    $exclusive = Set-AmazonCdpOutputMode `
        -EnableExclusive $true `
        -AmazonDeviceId $AmazonDeviceId `
        -ForceExclusiveCycle
    $exclusiveMs = [int]$exclusiveTimer.ElapsedMilliseconds
    if (-not $exclusive.Success) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=$pauseMs; ExclusiveMs=$exclusiveMs; ResumeMs=0; VerifyMs=0
            Reason='Amazon Exclusive recovery could not re-arm the output: ' + [string]$exclusive.Reason
        }
    }

    $resumeTimer = [Diagnostics.Stopwatch]::StartNew()
    $resume = Ensure-AmazonCdpPlaybackPlaying
    $resumeMs = [int]$resumeTimer.ElapsedMilliseconds
    if (-not $resume.Success) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=$pauseMs; ExclusiveMs=$exclusiveMs; ResumeMs=$resumeMs; VerifyMs=0
            Reason='Amazon did not resume after Exclusive recovery: ' + [string]$resume.Reason
        }
    }

    $verifyTimer = [Diagnostics.Stopwatch]::StartNew()
    $verification = Wait-AmazonCdpFormat `
        -Target $Target `
        -Asin $Asin `
        -TimeoutMilliseconds 5000 `
        -RequireExclusive
    $verifyMs = [int]$verifyTimer.ElapsedMilliseconds
    if (-not $verification) {
        return [pscustomobject]@{
            Success=$false; Verification=$null; PauseMs=$pauseMs; ExclusiveMs=$exclusiveMs; ResumeMs=$resumeMs; VerifyMs=$verifyMs
            Reason='Amazon playback format or Exclusive state was still not confirmed after recovery.'
        }
    }

    return [pscustomobject]@{
        Success=$true; Verification=$verification; PauseMs=$pauseMs; ExclusiveMs=$exclusiveMs; ResumeMs=$resumeMs; VerifyMs=$verifyMs
        Reason='Amazon Exclusive was re-armed and playback format was confirmed.'
    }
}

function Resolve-AmazonLogPath {
    $candidates = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\AmazonMobileLLC.AmazonMusic_*\LocalCache\Local\Amazon Music\Logs\AmazonMusic*.log') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '(?i)Helper' } |
        Sort-Object LastWriteTime -Descending
    $latest = $candidates | Select-Object -First 1
    $script:AmazonLogPath = if ($latest) { [string]$latest.FullName } else { $null }
    return $script:AmazonLogPath
}

function Get-AmazonLogLength {
    $path = Resolve-AmazonLogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 0L }
    return [int64](Get-Item -LiteralPath $path).Length
}

function Read-AmazonLogRange {
    param([int64] $StartOffset = 0)
    $path = Resolve-AmazonLogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
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

function Get-AmazonSelectedFormat {
    param([Parameter(Mandatory)][string] $Asin)
    $length = Get-AmazonLogLength
    $text = Read-AmazonLogRange -StartOffset ([Math]::Max(0, $length - 2097152))
    $pattern = 'Fetching fragment:\s*<Track:\s*asin://' + [regex]::Escape($Asin) + ':.*?AudioQuality:\s*(?<quality>U?HD(?:44|48|88|96|176|192))'
    $matches = [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -eq 0) { return $null }
    return ConvertFrom-AmazonAudioQuality $matches[$matches.Count - 1].Groups['quality'].Value.ToUpperInvariant()
}

function Get-AmazonCompletedManifestFormat {
    param([Parameter(Mandatory)] [string] $Asin)

    $length = Get-AmazonLogLength
    $text = Read-AmazonLogRange -StartOffset ([Math]::Max(0L, $length - 8388608L))
    if (-not $text) { return $null }

    # A completed TrackBuilder instance proves that Amazon received the whole
    # manifest and all of its tiny init segments. Reusing the maximum quality
    # from that exact ASIN is safe even when a later playback instance reuses
    # the manifest and therefore does not log the init list again.
    $asinPattern = [regex]::Escape($Asin.ToUpperInvariant())
    $completed = [regex]::Matches(
        $text,
        'Track builder finished successfully for track\s*asin://' + $asinPattern + ':(?<instance>\d+):',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($completed.Count -eq 0) { return $null }

    for ($index = $completed.Count - 1; $index -ge 0; $index--) {
        $instance = $completed[$index].Groups['instance'].Value
        $trackToken = 'asin://' + $asinPattern + ':' + [regex]::Escape($instance) + ':'
        $initPattern = 'Dash fragment successfully received:\s*<Track:\s*' + $trackToken + '.*?FragmentIndex:\s*4294967295,\s*AudioQuality:\s*(?<quality>U?HD(?:44|48|88|96|176|192))'
        $initMatches = [regex]::Matches($text, $initPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($initMatches.Count -eq 0) { continue }

        $formats = @($initMatches |
            ForEach-Object { ConvertFrom-AmazonAudioQuality $_.Groups['quality'].Value.ToUpperInvariant() } |
            Where-Object { $_ })
        $format = $formats | Sort-Object RateHz, Bits -Descending | Select-Object -First 1
        if ($format) { return $format }
    }
    return $null
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
    $lastManifestSignature = ''
    $manifestStableSince = $null
    do {
        $text = Read-AmazonLogRange -StartOffset $AfterOffset
        $events = [regex]::Matches($text, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+):(?<instance>\d+):', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $event = if ($events.Count -gt 0) { $events[$events.Count - 1] } else { $null }
        # Historical occurrences of the same ASIN are not evidence for this
        # switch. Only parse the newest playback event in the range; if Amazon
        # has not logged the CDP-visible track yet, keep polling.
        if ($event -and $event.Groups['asin'].Value.ToUpperInvariant() -eq $Asin.ToUpperInvariant()) {
            $suffix = $text.Substring($event.Index + $event.Length)

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

            # The manifest loader downloads a tiny init segment for every
            # quality that this exact playback instance offers. Unlike the
            # ordinary FragmentIndex 0 selection, this list is not constrained
            # by the endpoint's current format. Group by Amazon's per-playback
            # instance id so prefetched and historical copies of the same ASIN
            # cannot contaminate the result.
            $instance = $event.Groups['instance'].Value
            $trackToken = 'asin://' + [regex]::Escape($Asin) + ':' + [regex]::Escape($instance) + ':'
            $initPattern = 'Dash fragment successfully received:\s*<Track:\s*' + $trackToken + '.*?FragmentIndex:\s*4294967295,\s*AudioQuality:\s*(?<quality>U?HD(?:44|48|88|96|176|192))'
            $initMatches = [regex]::Matches($text, $initPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($initMatches.Count -gt 0) {
                $qualities = @($initMatches | ForEach-Object { $_.Groups['quality'].Value.ToUpperInvariant() } | Sort-Object -Unique)
                $signature = $qualities -join ','
                if ($signature -ne $lastManifestSignature) {
                    $lastManifestSignature = $signature
                    $manifestStableSince = Get-Date
                }

                # A real audio fragment or TrackBuilder completion proves the
                # init list is complete. Otherwise require a short quiet window
                # so parallel init responses can all arrive before taking max.
                $audioReadyPattern = '(?:Dash fragment successfully received:\s*<Track:\s*' + $trackToken + '.*?FragmentIndex:\s*(?!4294967295\b)\d+|Track builder finished successfully for track\s*' + $trackToken + ')'
                $manifestComplete = [regex]::IsMatch($text, $audioReadyPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $manifestStable = $manifestStableSince -and ((Get-Date) - $manifestStableSince).TotalMilliseconds -ge 100
                if ($manifestComplete -or $manifestStable) {
                    $manifestFormats = @($qualities | ForEach-Object { ConvertFrom-AmazonAudioQuality $_ } | Where-Object { $_ })
                    $manifestFormat = $manifestFormats | Sort-Object RateHz, Bits -Descending | Select-Object -First 1
                    if ($manifestFormat) { return $manifestFormat }
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

function Import-VerifiedFormatCache {
    $cache = @{}
    if (-not (Test-Path -LiteralPath $script:FormatCachePath)) { return $cache }
    try {
        $document = Get-Content -LiteralPath $script:FormatCachePath -Raw | ConvertFrom-Json
        if ([int]$document.Version -ne 4) { return $cache }
        foreach ($entry in @($document.Entries)) {
            $asin = ([string]$entry.Asin).ToUpperInvariant()
            if ($asin -and [int]$entry.Bits -gt 0 -and [int]$entry.RateHz -gt 0 -and [bool]$entry.Verified) {
                $cache[$asin] = [pscustomobject]@{
                    Text = '{0} bit / {1:g} kHz' -f [int]$entry.Bits, ([double][int]$entry.RateHz / 1000)
                    Bits = [int]$entry.Bits
                    RateHz = [int]$entry.RateHz
                    Verified = $true
                    VerifiedAt = [string]$entry.VerifiedAt
                }
            }
        }
    } catch {
        Write-Log "Ignoring an invalid verified format cache: $($_.Exception.Message)" Yellow
    }
    return $cache
}

function Save-VerifiedFormatCache {
    param([Parameter(Mandatory)] [hashtable] $Cache)
    $entries = foreach ($asin in @($Cache.Keys | Sort-Object)) {
        $format = $Cache[$asin]
        [pscustomobject]@{
            Asin = $asin
            Bits = [int]$format.Bits
            RateHz = [int]$format.RateHz
            Verified = $true
            VerifiedAt = if ($format.VerifiedAt) { [string]$format.VerifiedAt } else { (Get-Date).ToString('o') }
        }
    }
    [pscustomobject]@{ Version=4; Entries=@($entries) } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $script:FormatCachePath -Encoding utf8
}

function Set-VerifiedFormatCacheEntry {
    param(
        [Parameter(Mandatory)] [hashtable] $Cache,
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] $Format
    )
    $key = $Asin.ToUpperInvariant()
    $Cache[$key] = [pscustomobject]@{
        Text = $Format.Text
        Bits = [int]$Format.Bits
        RateHz = [int]$Format.RateHz
        Verified = $true
        VerifiedAt = (Get-Date).ToString('o')
    }
    Save-VerifiedFormatCache -Cache $Cache
}

function Initialize-AmazonMutedCurrentTrackFormat {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [int] $TimeoutMilliseconds = 5000
    )
    if (-not ($script:CdpEnabled -and $script:CdpWebSocketUrl)) { return $null }

    $asinJson = ConvertTo-Json $Asin.ToUpperInvariant() -Compress
    $expression = @"
(async()=>{
  const expected=$asinJson,deadline=Date.now()+$TimeoutMilliseconds;
  const v=document.getElementById('transportContainer')&&document.getElementById('transportContainer').__vue__;
  const n=window.Native&&window.Native.Player;
  if(!v||!n||typeof n.setPaused!=='function'||typeof n.toggleMute!=='function')
    return JSON.stringify({ok:false,error:'Amazon mute/play controls are unavailable'});
  const p=v.`$store&&v.`$store.state&&v.`$store.state.player;
  const read=()=>{const m=p&&p.model||{},t=m.currentPlayable&&m.currentPlayable.track,a=m.audioAttributes||{},pr=p&&p.progress||{};return {asin:String(t&&t.asin||'').toUpperCase(),position:Number(pr.currentTime||0),state:String(m.state||''),bestBits:Number(a.bestAvailableBitDepth||0),bestRate:Number(a.bestAvailableSampleRate||0),playingBits:Number(a.bitDepth||0),playingRate:Number(a.sampleRate||0)}};
  const wasMuted=!!(n.playerSettings&&n.playerSettings.muted);let mutedByUs=false;
  try{
    if(!wasMuted){await Promise.resolve(n.toggleMute());mutedByUs=true;}
    await Promise.resolve(n.setPaused(false));
    let state=read();
    while(Date.now()<deadline){
      state=read();
      if(state.asin!==expected)return JSON.stringify({ok:false,error:'The track changed during muted initialization',state});
      if(state.position>0&&state.bestBits>0&&state.bestRate>0&&state.playingBits>0&&state.playingRate>0){
        await Promise.resolve(n.setPaused(true));
        if(typeof n.seek==='function')await Promise.resolve(n.seek(0,'progress'));
        if(mutedByUs){await Promise.resolve(n.toggleMute());mutedByUs=false;}
        return JSON.stringify({ok:true,bits:state.bestBits,rate:state.bestRate,position:state.position});
      }
      await new Promise(r=>setTimeout(r,15));
    }
    return JSON.stringify({ok:false,error:'Current-track audio attributes did not initialize before timeout',state});
  }finally{
    try{await Promise.resolve(n.setPaused(true));}catch(e){}
    if(mutedByUs){try{await Promise.resolve(n.toggleMute());}catch(e){}}
  }
})()
"@
    try {
        $result = Invoke-AmazonCdpExpression -Expression $expression | ConvertFrom-Json
        if ($result.ok) { return ConvertTo-CdpFormat $result.bits $result.rate }
        Write-Log "Muted current-track initialization did not resolve ${Asin}: $($result.error)" Yellow
    } catch {
        Write-Log "Muted current-track initialization failed for ${Asin}: $($_.Exception.Message)" Yellow
    }
    return $null
}

function Resolve-AmazonCurrentTrackFormat {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] [hashtable] $VerifiedCache,
        [int64] $AfterOffset = -1,
        [int] $TimeoutMilliseconds = 5000,
        [int] $LogBudgetMilliseconds = 1000,
        [switch] $SkipInitialization
    )

    $key = $Asin.ToUpperInvariant()
    $length = Get-AmazonLogLength
    # Amazon can append well over 128 KB between its native track event and the
    # next CDP poll. Keep a 2 MB correlation window even when the monitor cursor
    # is newer; latest-event filtering prevents historical tracks from matching.
    $windowOffset = [Math]::Max(0L, $length - 2097152L)
    $tailOffset = if ($AfterOffset -ge 0) { [Math]::Min([Math]::Max(0L, $AfterOffset), $windowOffset) } else { $windowOffset }

    # A v4 entry was written only from ASIN-correlated final data and is checked
    # again after a switched playback. Put it first so repeat plays are nearly
    # free instead of rescanning the Amazon log on every track.
    if ($VerifiedCache.ContainsKey($key)) {
        return [pscustomobject]@{ Format=$VerifiedCache[$key]; Source='verified cache'; CacheHit=$true }
    }

    # A current `new track playing` boundary followed by non-zero attributes is
    # already instance-correlated and can be accepted without another wait.
    $quickOffset = [Math]::Max(0L, $length - 262144L)
    $logFormat = Wait-AmazonCorrelatedTrackFormat -Asin $key -AfterOffset $quickOffset -TimeoutMilliseconds 0
    if ($logFormat) {
        Set-VerifiedFormatCacheEntry -Cache $VerifiedCache -Asin $key -Format $logFormat
        return [pscustomobject]@{ Format=$logFormat; Source='current-track log'; CacheHit=$false }
    }

    # Amazon may reuse a manifest without emitting new init-segment records for
    # this playback instance. A previously completed manifest for the exact ASIN
    # still describes its source formats and is not endpoint-selected telemetry.
    $manifestFormat = Get-AmazonCompletedManifestFormat -Asin $key
    if ($manifestFormat) {
        Set-VerifiedFormatCacheEntry -Cache $VerifiedCache -Asin $key -Format $manifestFormat
        return [pscustomobject]@{ Format=$manifestFormat; Source='completed ASIN manifest'; CacheHit=$false }
    }

    # The current playback instance's manifest usually resolves within this
    # bounded window and is faster than initializing Vue audioAttributes. The
    # poll returns immediately once its complete quality list is available.
    $logBudget = [Math]::Min([Math]::Max(0, $LogBudgetMilliseconds), [Math]::Max(0, $TimeoutMilliseconds))
    $logFormat = Wait-AmazonCorrelatedTrackFormat -Asin $key -AfterOffset $tailOffset -TimeoutMilliseconds $logBudget
    if ($logFormat) {
        Set-VerifiedFormatCacheEntry -Cache $VerifiedCache -Asin $key -Format $logFormat
        return [pscustomobject]@{ Format=$logFormat; Source='current-track log'; CacheHit=$false }
    }

    if ($SkipInitialization) { return $null }

    $remaining = [Math]::Max(0, $TimeoutMilliseconds - $logBudget)
    $initializedFormat = if ($remaining -gt 0) {
        Initialize-AmazonMutedCurrentTrackFormat -Asin $key -TimeoutMilliseconds $remaining
    } else { $null }
    if ($initializedFormat) {
        Set-VerifiedFormatCacheEntry -Cache $VerifiedCache -Asin $key -Format $initializedFormat
        return [pscustomobject]@{ Format=$initializedFormat; Source='muted current-track initialization'; CacheHit=$false }
    }

    return $null
}

function Wait-AmazonTrackPipelineInitialized {
    param(
        [Parameter(Mandatory)] [string] $Asin,
        [Parameter(Mandatory)] [int64] $AfterOffset,
        [int] $TimeoutMilliseconds = 2500
    )

    # The renderer exposes currentPlayable before the native AudioPipeline has
    # built its first track. AmazonMusic.log is the only reliable boundary for
    # that transition: the native layer emits Track Initialization Succeeded
    # immediately after the first playable fragment is assembled.
    if (-not (Resolve-AmazonLogPath)) {
        return [pscustomobject]@{ Success=$false; ElapsedMs=0; Reason='AmazonMusic.log is unavailable' }
    }
    $pattern = 'Track Initialization Succeeded:\s*track\s+asin://' + [regex]::Escape($Asin) + ':'
    $differentTrackPattern = 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)'
    $started = [Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddMilliseconds([Math]::Max(0, $TimeoutMilliseconds))
    do {
        $text = Read-AmazonLogRange -StartOffset $AfterOffset
        if ($text -and [regex]::IsMatch($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return [pscustomobject]@{ Success=$true; ElapsedMs=[int]$started.ElapsedMilliseconds; Reason='' }
        }
        # If another track has already become current, this switch is stale;
        # do not wait for an initialization event that belongs to an old ASIN.
        $events = [regex]::Matches($text, $differentTrackPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($event in $events) {
            if ($event.Groups['asin'].Value.ToUpperInvariant() -ne $Asin.ToUpperInvariant()) {
                return [pscustomobject]@{ Success=$false; ElapsedMs=[int]$started.ElapsedMilliseconds; Reason='A different track became current while waiting for initialization' }
            }
        }
        Start-Sleep -Milliseconds 40
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ Success=$false; ElapsedMs=[int]$started.ElapsedMilliseconds; Reason='Track Initialization Succeeded was not observed before the timeout' }
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
        $resolved = Resolve-AmazonCurrentTrackFormat -Asin $ActualAsin -VerifiedCache $AsinFormats -AfterOffset $AfterOffset -TimeoutMilliseconds 5000
        $actualTrackFormat = if ($resolved) { $resolved.Format } else { $null }
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

    $path = Resolve-AmazonLogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw 'AmazonMusic.log was not found. Start Amazon Music for Windows at least once.'
    }

    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
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
    try {
        # Windows PowerShell 5.1 can preserve a JSON array as one nested
        # object when it crosses a function boundary. Emit each item
        # explicitly so device filters see individual SoundVolumeView rows.
        $items = Get-Content $path -Raw | ConvertFrom-Json
        foreach ($item in @($items)) { Write-Output $item }
    }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-RenderDevices {
    foreach ($item in @(Export-SoundItems)) {
        if ($item.Type -eq 'Device' -and $item.Direction -eq 'Render') { Write-Output $item }
    }
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

function Assert-AsioExclusiveDevice {
    param([Parameter(Mandatory)] $Device)

    if (-not $script:AsioExclusiveMode) { return }
    $expectedId = $script:AsioCableDeviceId
    $actualId = [string]$Device.'Command-Line Friendly ID'
    if ($actualId -ne $expectedId) {
        throw 'ASIO + Amazon Exclusive requires the Amazon output endpoint to be Hi-Fi Cable Input.'
    }
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
        [Parameter(Mandatory)] [int] $WaitForRebuildSeconds,
        [Parameter(Mandatory)] [int] $RecoveryWaitSeconds,
        [string] $Asin = '',
        [hashtable] $AsinFormats,
        [int] $RestartDelayMilliseconds = 3500,
        [hashtable] $Timing
    )

    Assert-Tool
    if (-not $Timing) { $Timing = @{} }
    foreach ($stageName in @('PauseMs', 'ExclusiveMs', 'ReplayMs', 'ResumeMs', 'EndpointFormatMs', 'SetEndpointTotalMs')) {
        if (-not $Timing.ContainsKey($stageName)) { $Timing[$stageName] = 0 }
    }
    $setEndpointTimer = [Diagnostics.Stopwatch]::StartNew()
    $script:LastUnexpectedAsin = ''
    $script:LastResyncSuccess = $false
    $script:LastResyncTarget = ''
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $id = $Device.'Command-Line Friendly ID'
    $before = $Device.'Default Format'
    $cableRenderId = $script:AsioCableDeviceId
    $cableCaptureId = 'VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Output\Capture'
    $isAsioCable = $id -eq $cableRenderId
    $cableFormatKey = "$($Format.Bits)/$($Format.RateHz)/$Channels"

    $endpointAlreadyMatches = $before -match "(?i)\b$($Format.Bits) bit\b" -and $before -match "\b$($Format.RateHz) Hz\b"
    $cablePairNeedsSync = $isAsioCable -and $script:CableCaptureFormatKey -ne $cableFormatKey
    if ($endpointAlreadyMatches -and -not $cablePairNeedsSync -and (Test-FormatMatch $CurrentPlaying $Format)) {
        Write-Log "The endpoint is already $($Format.Bits)-bit/$($Format.RateHz) Hz; deferring Exclusive until after the 4.5-second seek and Previous restart." DarkGray
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
    # ASIO4ALL test mode: keep ASIO Bridge resident and let the driver observe
    # the paired Cable format change without an explicit OFF/ON toggle.
    try {
        # The monitor pauses the new track before entering this function and
        # resumes it only after the endpoint format is ready. Exclusive is
        # deliberately deferred until after the queue-safe Previous restart.
        if ($script:ExclusiveMode) {
            Write-Log 'Deferring Amazon Exclusive until after the queue-safe Previous restart.' DarkGray
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

        $renderMatches = $actual -match "(?i)\b$($Format.Bits) bit\b" -and $actual -match "\b$($Format.RateHz) Hz\b"
        $captureActual = $null
        $captureMatches = $true
        if ($isAsioCable -and (-not $endpointAlreadyMatches -or $cablePairNeedsSync)) {
            # ASIO Bridge consumes Hi-Fi Cable Output (Capture), while Amazon
            # opens Hi-Fi Cable Input (Render).  A Render-only read-back can
            # therefore report success even when the pair negotiated different
            # rates.  Give the capture side a short, bounded settle window and
            # only mark the in-memory endpoint pair as ready after both sides agree.
            for ($captureAttempt = 0; $captureAttempt -lt 3; $captureAttempt++) {
                $captureActual = Get-DeviceDefaultFormatFast -DeviceId $cableCaptureId
                $captureMatches = $captureActual -and
                    $captureActual -match "(?i)\b$($Format.Bits) bit\b" -and
                    $captureActual -match "\b$($Format.RateHz) Hz\b"
                if ($captureMatches) { break }
                if ($captureAttempt -lt 2) { Start-Sleep -Milliseconds 50 }
            }
        }
        $success = $renderMatches -and $captureMatches
        if (-not $success) {
            if ($isAsioCable -and -not $captureMatches) {
                Write-Log "The Hi-Fi Cable pair did not settle to the target format; Render=$actual, Capture=$captureActual." Yellow
            } else {
                Write-Log "The driver rejected the target format; read-back is still $actual. Restoring the previous format." Yellow
            }
            if (Test-Path $script:BackupPath) {
                Invoke-SoundVolumeView /LoadDeviceFormat $id $script:BackupPath
            }
            return $false
        }

        Write-Log "Endpoint format confirmed: $actual" Green
        if ($isAsioCable) { $script:CableCaptureFormatKey = $cableFormatKey }
        if (-not $endpointAlreadyMatches -or $cablePairNeedsSync) {
            if ($isAsioCable) {
                Write-Log 'ASIO4ALL remains ON; waiting for it to reopen the stream at the new format.' DarkGray
            } else {
                Write-Log 'Waiting for Amazon to reopen the selected output stream at the new format.' DarkGray
            }
        }
        $Timing['EndpointFormatMs'] = [int]$stageTimer.ElapsedMilliseconds

        if (-not $streamWasActive) {
            Write-Log 'The Amazon stream is not active; the next playback will be created at the new format.' DarkGray
            return $true
        }

        # Endpoint is ready. The caller performs the paused 4.5-second seek,
        # Previous restart, Exclusive re-arm, and final Play.
        Write-Log 'Track change prepared; waiting for the 4.5-second seek, Previous restart, and Exclusive resume.' DarkGray
        return $true
    }
    finally {
        # ASIO4ALL test mode leaves the resident Bridge untouched.
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

if ($Exclusive -and $AsioExclusive) {
    throw 'Use either -Exclusive or -AsioExclusive, not both.'
}

if ($Exclusive) {
    # Amazon exposes Exclusive through its native player bridge, which is only
    # reachable from the renderer. Exclusive therefore implies Direct + CDP.
    $Direct = $true
    $script:CdpEnabled = $true
}

if ($AsioExclusive) {
    # ASIO Exclusive uses Amazon's renderer API to select Hi-Fi Cable Input and
    # therefore always needs CDP. It intentionally leaves $Direct false so the
    # resident ASIO Bridge is not stopped by the Direct setup below.
    $script:CdpEnabled = $true
    # The ASIO-only user path never targets a physical Windows endpoint.  Keep
    # the virtual cable fixed even when an older config.json still contains a
    # physical device ID from a previous Direct/Exclusive setup.
    $DeviceId = $script:AsioCableDeviceId
}

if ($AsioExclusive -and $Mode -in @('Once', 'Monitor', 'AutoTest')) {
    # Keep the Amazon app route aligned with the single supported user path.
    # This makes direct PowerShell launches behave like the GUI and launchers,
    # even when an older per-app Windows routing choice is still configured.
    Assert-Tool
    Invoke-SoundVolumeView /SetAppDefault $script:AsioCableDeviceId all 'Amazon Music.exe'
}

$script:DirectFollowsDefault = [bool]($Direct -and -not $DeviceId)

if ($Direct) {
    Assert-Tool
    $bridgeProcesses = @(Get-Process -Name 'VBCABLE_AsioBridge' -ErrorAction SilentlyContinue)
    if ($bridgeProcesses.Count -gt 0) {
        $bridgeProcesses | Stop-Process -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 250
        Write-Log 'Direct mode: stopped the resident ASIO Bridge to release the Hi-Fi Cable path.' DarkGray
    }
    # An explicit GUI/CLI selection wins. With no DeviceId, Direct and
    # Exclusive deliberately follow the current Windows default endpoint.
    $directDevice = if ($DeviceId) {
        Resolve-Device $DeviceId
    } else {
        $candidate = Get-RenderDevices |
            Where-Object { $_.'Default Multimedia' -eq 'Render' } |
            Select-Object -First 1
        if (-not $candidate) {
            $candidate = Get-RenderDevices |
                Where-Object { $_.Default -eq 'Render' } |
                Select-Object -First 1
        }
        $candidate
    }
    if (-not $directDevice) {
        throw 'Direct mode could not resolve the requested render endpoint.'
    }
    $DeviceId = [string]$directDevice.'Command-Line Friendly ID'
    Invoke-SoundVolumeView /SetAppDefault $DeviceId all 'Amazon Music.exe'
    Write-Log ("Direct mode: Amazon output routed to {0}." -f $DeviceId) Cyan
}

try {
if ($Mode -in @('Monitor', 'AutoTest')) {
    Enter-SwitcherInstance
    Start-BackendOwnerWatchdog -RequestedOwnerPid $OwnerPid
}

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
        Assert-AsioExclusiveDevice -Device $device
        Write-Host ("Target endpoint  : {0} ({1})" -f $device.Name, $device.'Default Format')
        if (-not $Apply) {
            Write-Log 'Dry run: no format was changed. Add -Apply to perform the switch.' Yellow
            break
        }
        $delay = if ($RestartDelayMs -gt 0) { $RestartDelayMs } else { [int]$config.restartDelayMs }
        $onceSuccess = Set-EndpointFormat -Device $device -Format $snapshot.Track -CurrentPlaying $snapshot.Playing -Channels ([int]$config.channels) -WaitForRebuildSeconds ([int]$config.waitForRebuildSeconds) -RecoveryWaitSeconds ([int]$config.recoveryWaitSeconds) -Asin ([string]$snapshot.Asin) -RestartDelayMilliseconds $delay
        if ($onceSuccess -and $script:ExclusiveMode -and $script:CdpEnabled -and $script:CdpWebSocketUrl) {
            $onceExclusive = Set-AmazonCdpOutputMode -EnableExclusive $true -AmazonDeviceId ([string]$device.'Item ID') -ForceExclusiveCycle
            if (-not $onceExclusive.Success) { throw "Amazon Exclusive could not be armed after the one-shot format change: $($onceExclusive.Reason)" }
            Write-Log "Amazon Exclusive active after the one-shot format change on $($onceExclusive.Device)." Green
        }
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
                Write-Log "CDP unavailable: $script:CdpLastError; using log-based track detection." Yellow
            }
        }
        $trackPollMilliseconds = [int]$config.trackPollMilliseconds
        if ($trackPollMilliseconds -lt 50) { $trackPollMilliseconds = 50 }
        Write-Log "Monitoring Amazon playback every $trackPollMilliseconds ms. Press Ctrl+C to stop. Apply=$Apply" Cyan
        $asinFormats = Import-VerifiedFormatCache
        Write-Log "Loaded $($asinFormats.Count) instance-verified format cache entries." DarkGray
        $logCursor = Get-AmazonLogLength
        $lastAsin = ''
        $monitorDevice = Resolve-Device $DeviceId
        Assert-AsioExclusiveDevice -Device $monitorDevice
        $currentEndpointFormat = [string]$monitorDevice.'Default Format'
        if ($script:AsioExclusiveMode) {
            # The capture-pair key is process-local. Confirm both sides once at
            # startup so a fresh Rate Switcher process does not rewrite an
            # already-matching Hi-Fi Cable pair on its first track.
            try {
                $captureFormat = Get-DeviceDefaultFormatFast -DeviceId 'VB-Audio Hi-Fi Cable\Device\Hi-Fi Cable Output\Capture'
                $formatPattern = '(?i)(?<channels>\d+) Channel,\s*(?<bits>\d+) bit,\s*(?<rate>\d+) Hz'
                $renderMatch = [regex]::Match($currentEndpointFormat, $formatPattern)
                $captureMatch = [regex]::Match([string]$captureFormat, $formatPattern)
                if ($renderMatch.Success -and $captureMatch.Success -and
                    $renderMatch.Groups['channels'].Value -eq $captureMatch.Groups['channels'].Value -and
                    $renderMatch.Groups['bits'].Value -eq $captureMatch.Groups['bits'].Value -and
                    $renderMatch.Groups['rate'].Value -eq $captureMatch.Groups['rate'].Value) {
                    $script:CableCaptureFormatKey = '{0}/{1}/{2}' -f `
                        $renderMatch.Groups['bits'].Value,
                        $renderMatch.Groups['rate'].Value,
                        $renderMatch.Groups['channels'].Value
                    Write-Log "Confirmed the existing Hi-Fi Cable pair at $script:CableCaptureFormatKey." DarkGray
                }
            } catch {
                Write-Log "Could not pre-confirm the Hi-Fi Cable Capture format: $($_.Exception.Message)" Yellow
            }
        }
        if ($script:CdpEnabled -and $script:CdpWebSocketUrl) {
            if ($script:ExclusiveMode) {
                $outputMode = Set-AmazonCdpOutputMode -EnableExclusive $true -AmazonDeviceId ([string]$monitorDevice.'Item ID')
                if ($outputMode.Success) {
                    Write-Log "Amazon output selected explicitly and Exclusive is active on $($outputMode.Device)." Green
                } elseif ($outputMode.Pending) {
                    Write-Log 'Amazon output selected explicitly; Exclusive will be armed when playback starts.' DarkGray
                } else {
                    Write-Log "Amazon Exclusive initialization failed: $($outputMode.Reason)" Yellow
                }
            } else {
                $sharedAmazonDevice = if ($Direct -and -not $script:DirectFollowsDefault) {
                    [string]$monitorDevice.'Item ID'
                } else {
                    'default'
                }
                $outputMode = Set-AmazonCdpOutputMode -EnableExclusive $false -AmazonDeviceId $sharedAmazonDevice
                if (-not $outputMode.Success) {
                    Write-Log "Amazon could not return to shared/default output mode: $($outputMode.Reason)" Yellow
                }
            }
        } elseif ($script:ExclusiveMode) {
            throw 'Exclusive mode requires a working Amazon CDP connection.'
        }
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
                        UnexpectedAsin=''; ResyncSuccess=$false; ResyncTarget=''; Resumed=$false
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
                    }
                    if ($length -le $logCursor) {
                        Start-Sleep -Milliseconds $trackPollMilliseconds
                        continue
                    }

                    $chunk = Read-AmazonLogRange -StartOffset $logCursor
                    $logCursor = $length
                    $trackMatches = [regex]::Matches($chunk, 'new track playing\s*:\s*asin://(?<asin>[A-Z0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($trackMatches.Count -eq 0) { continue }
                    $asin = $trackMatches[$trackMatches.Count - 1].Groups['asin'].Value.ToUpperInvariant()
                }
                if (-not $asin) { continue }
                # The current CDP read already happened for format monitoring.
                # Republish only when title/album/artwork fields change, so a
                # late artwork URL can refresh the GUI without another query.
                Write-GuiTrackMetadata -Snapshot $cdpCurrent -Asin $asin
                if ($asin -eq $lastAsin) {
                    $logCursor = Get-AmazonLogLength
                    continue
                }
                if ($autoTest) { $autoTestWaitingForNext = $false }
                $lastAsin = $asin
                $trackTimer = [Diagnostics.Stopwatch]::StartNew()
                # Capture the log boundary as soon as CDP reports the new ASIN;
                # Track Initialization Succeeded can arrive while format and
                # endpoint work is still in progress.
                # Keep a small overlap before the monitor cursor so an event
                # written just before the CDP poll cannot fall through a race.
                $correlationStart = [Math]::Max(0L, $logCursor - 131072L)
                $timing = @{}
                $pausedForSwitch = $false
                $resumeSucceeded = $true
                $resumeResult = $null
                $resumedForSwitch = $false

                try {
                $playbackState = if ($cdpCurrent) { [string]$cdpCurrent.State } else { '' }
                $assumePlaying = $fromCdp
                if (-not $fromCdp) {
                    try { $assumePlaying = Test-AmazonSessionActive $monitorDevice } catch { $assumePlaying = $false }
                }
                $timing['PauseMs'] = 0

                # Keep the new track running for one short, bounded discovery
                # window. Amazon can then finish its manifest/audio pipeline;
                # same-format tracks avoid pause/replay entirely. A different
                # format may be audible only during this window and is restarted
                # from zero after the endpoint switch.
                $resolvedFormat = Resolve-AmazonCurrentTrackFormat `
                    -Asin $asin `
                    -VerifiedCache $asinFormats `
                    -AfterOffset $correlationStart `
                    -TimeoutMilliseconds 900 `
                    -LogBudgetMilliseconds 900 `
                    -SkipInitialization

                if (-not $resolvedFormat -and $Apply) {
                    $pauseTimer = [Diagnostics.Stopwatch]::StartNew()
                    $pauseResult = Pause-AmazonPlaybackForSwitch -State $playbackState -AssumePlaying:$assumePlaying
                    $timing['PauseMs'] = [int]$pauseTimer.ElapsedMilliseconds
                    if ($pauseResult.Changed) {
                        $pausedForSwitch = $true
                        Write-Log 'Paused Amazon after the bounded format discovery window.' DarkGray
                    } elseif (-not $pauseResult.Success) {
                        throw "Could not pause Amazon before current-track format initialization: $($pauseResult.Reason)"
                    }
                }

                if (-not $resolvedFormat) {
                    $resolvedFormat = Resolve-AmazonCurrentTrackFormat `
                        -Asin $asin `
                        -VerifiedCache $asinFormats `
                        -AfterOffset $correlationStart `
                        -TimeoutMilliseconds 4200 `
                        -LogBudgetMilliseconds 0
                }
                if ($resolvedFormat) {
                    $format = $resolvedFormat.Format
                    Write-Log "Resolved $asin as $($format.Text) from $($resolvedFormat.Source)." DarkGray
                }
                $logCursor = Get-AmazonLogLength
                if (-not $format) {
                    Write-Log "No current-instance format data for new track $asin within 5 seconds; stale attributes were rejected." Yellow
                    if ($pausedForSwitch) {
                        $resumeTimer = [Diagnostics.Stopwatch]::StartNew()
                        $resumeResult = Resume-AmazonPlaybackAfterSwitch -WasPaused $true -ExpectedAsin $asin -AmazonDeviceId ([string]$monitorDevice.'Item ID')
                        $timing['ReplayMs'] = [int]$resumeResult.ReplayMs
                        $timing['ReplaySoughtMs'] = [int64]$resumeResult.ReplaySoughtMs
                        $timing['ReplayPositionMs'] = [int64]$resumeResult.ReplayPositionMs
                        $timing['ReplayReadyWaitMs'] = [int]$resumeResult.ReplayReadyWaitMs
                        $timing['ReplayFallback'] = [bool]$resumeResult.ReplayFallback
                        $timing['PauseAfterReplayMs'] = [int]$resumeResult.PauseAfterReplayMs
                        $timing['ExclusiveMs'] = [int]$resumeResult.ExclusiveMs
                        $timing['ResumeMs'] = [int]$resumeTimer.ElapsedMilliseconds
                        $resumeSucceeded = [bool]$resumeResult.Success
                        $pausedForSwitch = $false
                    }
                    if ($autoTest) {
                        [void]$testResults.Add([pscustomobject]@{ Number=$testResults.Count+1; Asin=$asin; Target='Unknown'; Success=$false; Reason='No current-instance format data within 5 seconds'; Time=(Get-Date).ToString('o') })
                        Write-Log 'This AutoTest run failed; stopping immediately instead of advancing from the failed track.' Yellow
                        $finished = $true
                    }
                    continue
                }
                $timing['TrackEventToFormatMs'] = [int]$trackTimer.ElapsedMilliseconds

                Write-Log "Playback engine changed track: $asin -> $($format.Text)" Cyan
                if ($env:AMRS_GUI -eq '1') {
                    [Console]::WriteLine("@@AMRS_FORMAT@@$asin|$($format.Bits)|$($format.RateHz)")
                }

                # Do not compare against the format we last requested.  The
                # audio driver/ASIO bridge can reject or lag a request while
                # Amazon continues to the next track.  A fresh render read-back
                # keeps a stale endpoint request from taking the same-format fast path.
                try {
                    $freshEndpoint = Get-DeviceDefaultFormatFast `
                        -DeviceId ([string]$monitorDevice.'Command-Line Friendly ID') `
                        -CoreAudioDeviceId ([string]$monitorDevice.'Item ID')
                    if ($freshEndpoint) {
                        if ($currentEndpointFormat -and $freshEndpoint -ne $currentEndpointFormat) {
                            Write-Log "Endpoint read-back changed since the last switch: $currentEndpointFormat -> $freshEndpoint" Yellow
                        }
                        $currentEndpointFormat = [string]$freshEndpoint
                    }
                } catch {
                    Write-Log "Could not refresh the endpoint format before comparison: $($_.Exception.Message)" Yellow
                }
                $monitorDevice.'Default Format' = $currentEndpointFormat
                $before = $currentEndpointFormat
                $endpointMatches = $before -match "(?i)\b$($format.Bits) bit\b" -and $before -match "\b$($format.RateHz) Hz\b"
                if ($script:AsioExclusiveMode) {
                    $targetCableKey = "$($format.Bits)/$($format.RateHz)/$([int]$config.channels)"
                    $endpointMatches = $endpointMatches -and ($script:CableCaptureFormatKey -eq $targetCableKey)
                    if (-not $endpointMatches -and $before -match "(?i)\b$($format.Bits) bit\b" -and $before -match "\b$($format.RateHz) Hz\b") {
                        Write-Log "Render matches, but the Hi-Fi Cable Capture pair is not confirmed at $targetCableKey; repeating the endpoint set." Yellow
                    }
                }
                $success = $false
                $reason = ''
                $script:LastUnexpectedAsin = ''
                $script:LastResyncSuccess = $false
                $script:LastResyncTarget = ''
                $exclusiveReady = $true
                $exclusiveFailure = ''
                if ($endpointMatches) {
                    Write-Log 'Endpoint already matches; keeping the same-format track on the fast path.' Green

                    if ($pausedForSwitch) {
                        $sameResumeTimer = [Diagnostics.Stopwatch]::StartNew()
                        $sameResume = Resume-AmazonPlaybackImmediately -WasPaused $true
                        $timing['ResumeMs'] = [int]$sameResumeTimer.ElapsedMilliseconds
                        if (-not $sameResume.Success) {
                            throw "Could not resume the same-format Amazon track: $($sameResume.Reason)"
                        }
                        $resumedForSwitch = $true
                        $pausedForSwitch = $false
                        Write-Log "Same-format track resumed immediately ($($sameResume.Method))." DarkGray
                    } else {
                        Write-Log 'Same-format track stayed playing; no pause or replay was needed.' DarkGray
                    }

                    $timing['PlaybackCommandMs'] = [int]$trackTimer.ElapsedMilliseconds

                    $stageTimer = [Diagnostics.Stopwatch]::StartNew()
                    # Same-format tracks do not renegotiate the endpoint. The
                    # target format was already resolved for this ASIN and the
                    # endpoint read-back matches it, so do not block playback on
                    # Amazon's slower playback/stream telemetry. Switched tracks
                    # still use the strict verifier after the endpoint rebuild.
                    $verification = [pscustomobject]@{
                        Success = [bool]$exclusiveReady
                        EndpointOk = $true
                        TrackOk = $true
                        CapabilityOk = $true
                        PlayingOk = $true
                        SelectedOk = $true
                    }
                    Write-Log 'Same-format track resumed; skipped blocking playback telemetry verification.' DarkGray
                    $timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds
                    $success = $verification.Success
                    if ($success) {
                        $reason = 'Same format; no endpoint action needed'
                    } else {
                        Write-Log ("Same-format verification incomplete: endpoint={0}, track={1}, device={2}, playback={3}, stream={4}" -f `
                            $verification.EndpointOk, $verification.TrackOk, $verification.CapabilityOk, $verification.PlayingOk, $verification.SelectedOk) Yellow
                        $reason = if (-not $exclusiveReady) {
                            "Same format, but Amazon Exclusive failed: $exclusiveFailure"
                        } else {
                            'Same format, but Amazon verification was incomplete (endpoint={0}, track={1}, device={2}, playback={3}, stream={4})' -f `
                                $verification.EndpointOk, $verification.TrackOk, $verification.CapabilityOk, $verification.PlayingOk, $verification.SelectedOk
                        }
                    }
                } elseif (-not $Apply) {
                    Write-Log "Dry run: would switch to $($format.Bits)/$($format.RateHz)." Yellow
                    $success = $true
                    $reason = 'Dry run'
                } else {
                    # The bounded discovery window identified a different
                    # format. Pause only now, then switch and restart from zero.
                    if (-not $pausedForSwitch) {
                        $pauseTimer = [Diagnostics.Stopwatch]::StartNew()
                        $pauseResult = Pause-AmazonPlaybackForSwitch -State $playbackState -AssumePlaying:$assumePlaying
                        $timing['PauseMs'] = [int]$pauseTimer.ElapsedMilliseconds
                        if ($pauseResult.Changed) {
                            $pausedForSwitch = $true
                            Write-Log 'Paused Amazon after confirming a different track format.' DarkGray
                        } elseif (-not $pauseResult.Success) {
                            throw "Could not pause Amazon before the sample-rate switch: $($pauseResult.Reason)"
                        }
                    }

                    # After the format switch, seek to about 4.5 seconds and
                    # invoke Previous immediately to restart the current track,
                    # then re-arm Exclusive and resume.
                    $delay = if ($RestartDelayMs -gt 0) { $RestartDelayMs } else { [int]$config.restartDelayMs }
                    $success = Set-EndpointFormat `
                        -Device $monitorDevice `
                        -Format $format `
                        -CurrentPlaying $null `
                        -Channels ([int]$config.channels) `
                        -WaitForRebuildSeconds ([int]$config.waitForRebuildSeconds) `
                        -RecoveryWaitSeconds ([int]$config.recoveryWaitSeconds) `
                        -Asin $asin `
                        -AsinFormats $asinFormats `
                        -RestartDelayMilliseconds $delay `
                        -Timing $timing
                    if ($success) {
                        $reason = 'Sample-rate switch and one Exclusive cycle succeeded'
                    } else {
                        $reason = 'Sample-rate switch or Exclusive re-arm failed'
                    }
                    if ($success) {
                        $currentEndpointFormat = '{0} Channel, {1} bit, {2} Hz' -f [int]$config.channels, [int]$format.Bits, [int]$format.RateHz
                    } else {
                        $currentEndpointFormat = Get-DeviceDefaultFormatFast -DeviceId ([string]$monitorDevice.'Command-Line Friendly ID') -CoreAudioDeviceId ([string]$monitorDevice.'Item ID')
                    }
                }

                if ($pausedForSwitch) {
                    $resumeTimer = [Diagnostics.Stopwatch]::StartNew()
                    $resumeResult = Resume-AmazonPlaybackAfterSwitch -WasPaused $true -ExpectedAsin $asin -AmazonDeviceId ([string]$monitorDevice.'Item ID')
                    $timing['ReplayMs'] = [int]$resumeResult.ReplayMs
                    $timing['ReplaySoughtMs'] = [int64]$resumeResult.ReplaySoughtMs
                    $timing['ReplayPositionMs'] = [int64]$resumeResult.ReplayPositionMs
                    $timing['ReplayReadyWaitMs'] = [int]$resumeResult.ReplayReadyWaitMs
                    $timing['ReplayFallback'] = [bool]$resumeResult.ReplayFallback
                    $timing['PauseAfterReplayMs'] = [int]$resumeResult.PauseAfterReplayMs
                    $timing['ExclusiveMs'] = [int]$resumeResult.ExclusiveMs
                    $timing['ResumeMs'] = [int]$resumeTimer.ElapsedMilliseconds
                    if ($resumeResult.ReplaySuccess) {
                        if ($resumeResult.ReplayFallback) {
                            Write-Log "Amazon used the native start fallback after the immediate Previous path (seek check $($resumeResult.ReplayReadyWaitMs) ms)." Yellow
                        } else {
                            Write-Log "Seeked the paused Amazon track and immediately used Previous; it returned to $($resumeResult.ReplayPositionMs) ms ($($resumeResult.ReplayMode))." DarkGray
                        }
                    } else {
                        Write-Log "Could not confirm the 4.5-second seek and Previous restart before resume: $($resumeResult.ReplayReason)" Yellow
                        $resumeSucceeded = $false
                        $success = $false
                        $reason = 'Could not confirm the 4.5-second seek and Previous restart before resume'
                    }
                    if ($resumeResult.Success) {
                        Write-Log "Re-armed Exclusive after Previous and resumed Amazon ($($resumeResult.Reason))." DarkGray
                        $resumedForSwitch = $true
                        $pausedForSwitch = $false
                        $timing['PlaybackCommandMs'] = [int]$trackTimer.ElapsedMilliseconds
                    } else {
                        $resumeSucceeded = $false
                        $success = $false
                        $reason = 'Could not restart the current track with Previous and resume Amazon'
                        Write-Log "Could not resume Amazon after the switch: $($resumeResult.Reason)" Red
                    }
                }

                # The output-mode call only confirms Amazon's control flag.  A
                # new playback instance can still report stale attributes for a
                # short window, especially after a rapid track change.  Confirm
                # the active ASIN, actual Playing format, and Exclusive state
                # after the final Play before recording a successful switch.
                if ($resumedForSwitch -and $Apply -and
                    $script:CdpEnabled -and $script:CdpWebSocketUrl -and
                    ($success -or -not $exclusiveReady)) {
                    $postResume = $null
                    $recovered = $false
                    if ($exclusiveReady) {
                        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
                        # The renderer can open the new Exclusive client first
                        # and publish the final Playing attributes a little
                        # later (the observed tail is about two seconds during
                        # a 44.1 -> 96 kHz rebuild). This is a deadline, not a
                        # fixed sleep: normal switches still return immediately
                        # once the state is correct.
                        $postResume = Wait-AmazonCdpFormat `
                            -Target $format `
                            -Asin $asin `
                            -TimeoutMilliseconds 5000 `
                            -RequireExclusive:$script:ExclusiveMode
                        $timing['PlaybackFormatWaitMs'] = [int]$stageTimer.ElapsedMilliseconds
                    } else {
                        $timing['PlaybackFormatWaitMs'] = 0
                    }

                    # A Vue Exclusive=true flag can survive after the native
                    # audio client was released. Rebuild that client once on a
                    # verification miss (or on the same-format Exclusive error),
                    # then verify the actual Playing format again.
                    if (-not $postResume -and $script:ExclusiveMode) {
                        Write-Log 'Amazon Exclusive was not confirmed after resume; retrying one paused Exclusive cycle.' Yellow
                        $recovery = Invoke-AmazonExclusiveRecovery `
                            -Target $format `
                            -Asin $asin `
                            -AmazonDeviceId ([string]$monitorDevice.'Item ID')
                        $timing['ExclusiveRecoveryMs'] = [int]($recovery.PauseMs + $recovery.ExclusiveMs + $recovery.ResumeMs + $recovery.VerifyMs)
                        if ($recovery.Success) {
                            $postResume = $recovery.Verification
                            $recovered = $true
                            if (-not $success) {
                                $success = $true
                                $resumeSucceeded = $true
                                $reason = 'Same format; Exclusive recovery and playback format confirmed'
                            } elseif ($reason -eq 'Same format; no endpoint action needed') {
                                $reason = 'Same format; Exclusive recovery and playback format confirmed'
                            } elseif ($reason -eq 'Sample-rate switch and one Exclusive cycle succeeded') {
                                $reason = 'Sample-rate switch, Exclusive recovery, and playback format confirmed'
                            } else {
                                $reason = 'Playback format and Amazon Exclusive confirmed after recovery'
                            }
                            Write-Log "Amazon Exclusive recovery succeeded at $($postResume.Playing.Text)." Green
                        } else {
                            Write-Log "Amazon Exclusive recovery failed: $($recovery.Reason)" Red
                        }
                    }

                    if ($postResume) {
                        if (-not $recovered) {
                            Write-Log "Amazon playback confirmed at $($postResume.Playing.Text) with Exclusive=$script:ExclusiveMode after resume." Green
                            if ($reason -eq 'Same format; no endpoint action needed') {
                                $reason = 'Same format; Exclusive and playback format confirmed'
                            } elseif ($reason -eq 'Sample-rate switch and one Exclusive cycle succeeded') {
                                $reason = 'Sample-rate switch, Exclusive cycle, and playback format confirmed'
                            }
                        }
                    } else {
                        if ($asinFormats.ContainsKey($asin)) {
                            [void]$asinFormats.Remove($asin)
                            Save-VerifiedFormatCache -Cache $asinFormats
                            Write-Log "Invalidated the verified format cache entry for $asin after playback verification failed." Yellow
                        }
                        $success = $false
                        $resumeSucceeded = $false
                        $reason = 'Playback format or Amazon Exclusive could not be confirmed after resume'
                        Write-Log "Amazon playback verification failed after resume: expected $($format.Text), Exclusive=$script:ExclusiveMode." Red
                    }
                }

                $timing['TotalTrackMs'] = [int]$trackTimer.ElapsedMilliseconds
                if (-not $timing.ContainsKey('PlaybackCommandMs')) {
                    $timing['PlaybackCommandMs'] = $timing['TotalTrackMs']
                }
                # Switched (and fallback-paused same-format) tracks are only
                # audibly ready once strict Playing-format verification ends.
                # Same-format tracks that never paused were already playing at
                # the command checkpoint.
                $timing['PlaybackConfirmedMs'] = if ($resumedForSwitch) {
                    $timing['TotalTrackMs']
                } else {
                    $timing['PlaybackCommandMs']
                }
                if ($script:ShowDetailedTiming) {
                    Write-Log ("Stage timing ms: pause={0}, format={1}, endpoint={2}, replay={3} (readyWait={4}, sought={5}, reset={6}), pauseAfterPrevious={7}, exclusive={8}, resume={9}, playCommand={10}, playbackConfirmed={11}" -f `
                        $timing['PauseMs'], $timing['TrackEventToFormatMs'], $timing['EndpointFormatMs'], `
                        $timing['ReplayMs'], $timing['ReplayReadyWaitMs'], $timing['ReplaySoughtMs'], $timing['ReplayPositionMs'], $timing['PauseAfterReplayMs'], `
                        $timing['ExclusiveMs'], $timing['ResumeMs'], `
                        $timing['PlaybackCommandMs'], $timing['PlaybackConfirmedMs']) DarkGray
                } else {
                    Write-Log ("Track timing: play command={0} ms; playback confirmed={1} ms" -f $timing['PlaybackCommandMs'], $timing['PlaybackConfirmedMs']) DarkGray
                }

                if ($autoTest) {
                    $number = $testResults.Count + 1
                    [void]$testResults.Add([pscustomobject]@{
                        Number=$number; Asin=$asin; Target=$format.Text; Success=[bool]$success
                        UnexpectedAsin=$script:LastUnexpectedAsin; ResyncSuccess=[bool]$script:LastResyncSuccess
                        ResyncTarget=$script:LastResyncTarget; Resumed=[bool]$resumeSucceeded
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
                }
                finally {
                    if ($pausedForSwitch) {
                        $resumeResult = Resume-AmazonPlaybackAfterSwitch -WasPaused $true -ExpectedAsin $asin -AmazonDeviceId ([string]$monitorDevice.'Item ID')
                        $pausedForSwitch = $false
                        if ($resumeResult.Success) {
                            Write-Log 'Recovery resume completed after an interrupted paused switch.' Yellow
                        } else {
                            Write-Log "Recovery resume failed: $($resumeResult.Reason)" Red
                        }
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
            $successfulTrackValues = @($successfulResults | ForEach-Object { [double]$_.Timing.PlaybackConfirmedMs })
            $successfulSwitchValues = @($successfulSwitchResults | ForEach-Object { [double]$_.Timing.PlaybackConfirmedMs })
            $successfulSameFormatValues = @($successfulSameFormatResults | ForEach-Object { [double]$_.Timing.PlaybackConfirmedMs })
            $successfulCommandValues = @($successfulResults | ForEach-Object { [double]$_.Timing.PlaybackCommandMs })
            $successfulVerificationValues = @($successfulResults | ForEach-Object { [double]$_.Timing.TotalTrackMs })
            $averageSuccessfulTrackMs = if ($successfulResults.Count -gt 0) {
                [Math]::Round([double](@($successfulTrackValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulSwitchMs = if ($successfulSwitchResults.Count -gt 0) {
                [Math]::Round([double](@($successfulSwitchValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulSameFormatMs = if ($successfulSameFormatResults.Count -gt 0) {
                [Math]::Round([double](@($successfulSameFormatValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulVerificationMs = if ($successfulResults.Count -gt 0) {
                [Math]::Round([double](@($successfulVerificationValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $averageSuccessfulCommandMs = if ($successfulResults.Count -gt 0) {
                [Math]::Round([double](@($successfulCommandValues | Measure-Object -Average).Average), 1)
            } else { $null }
            $summaryPath = Join-Path $script:StateDirectory 'auto-test-summary.json'
            $failureDetails = @($testResults | Where-Object { -not $_.Success } | ForEach-Object {
                [ordered]@{
                    Number = $_.Number
                    Asin = $_.Asin
                    Target = $_.Target
                    Reason = $_.Reason
                }
            })
            $summary = [ordered]@{
                GeneratedAt = (Get-Date).ToString('o')
                RequestedTracks = $TestTracks
                CompletedTracks = $testResults.Count
                Passed = $passed
                Failed = $testResults.Count - $passed
                AllPassed = ($passed -eq $testResults.Count -and $testResults.Count -eq $TestTracks)
                AverageSuccessfulTrackMs = $averageSuccessfulTrackMs
                AverageSuccessfulSwitchMs = $averageSuccessfulSwitchMs
                AverageSuccessfulSameFormatMs = $averageSuccessfulSameFormatMs
                AverageSuccessfulPlayCommandMs = $averageSuccessfulCommandMs
                AverageSuccessfulVerificationCompleteMs = $averageSuccessfulVerificationMs
                Failures = $failureDetails
                ResultsFile = 'auto-test-latest.json'
            }
            $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
            Write-Host ''
            $testResults | Format-Table Number, Asin, Target, Success, Resumed, Reason -AutoSize
            if ($null -ne $averageSuccessfulTrackMs) {
                Write-Log ("AutoTest latency: average successful track={0} ms; switched={1} ms; same-format={2} ms." -f `
                    $averageSuccessfulTrackMs, $averageSuccessfulSwitchMs, $averageSuccessfulSameFormatMs) DarkGray
            } else {
                Write-Log 'AutoTest latency: no successful track timing was available.' Yellow
            }
            Write-Log "AutoTest complete: $passed/$($testResults.Count) PASS; report: $reportPath" $(if($passed -eq $testResults.Count){'Green'}else{'Red'})
            Write-Log "Latency summary: $summaryPath" DarkGray
            if ($env:AMRS_GUI -eq '1') {
                $summaryJson = $summary | ConvertTo-Json -Depth 5 -Compress
                $summaryPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($summaryJson))
                [Console]::WriteLine('@@AMRS_AUTOTEST_SUMMARY_B64@@' + $summaryPayload)
            }
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
}
finally {
    if ($script:InstanceMutexAcquired -and $script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
        $script:InstanceMutexAcquired = $false
    }
}
