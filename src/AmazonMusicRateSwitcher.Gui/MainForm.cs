using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AmazonMusicRateSwitcher.Gui;

internal enum OutputMode
{
    Asio,
    Direct
}

internal sealed record TrackMetadata(
    string Asin,
    string Title,
    string Artist,
    string Album,
    string ArtworkUrl);

internal static class ProjectRoot
{
    public static string Find()
    {
        var candidates = new List<string>();
        var current = AppContext.BaseDirectory;
        while (!string.IsNullOrWhiteSpace(current))
        {
            candidates.Add(current);
            var parent = Directory.GetParent(current)?.FullName;
            if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
                break;
            current = parent ?? string.Empty;
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(Path.Combine(candidate, "scripts", "AmazonMusicRateSwitcher.ps1")))
                return candidate;
        }

        // This also makes a published GUI usable when it is copied into the
        // project directory, without relying on the current working directory.
        var fallback = Directory.GetCurrentDirectory();
        if (File.Exists(Path.Combine(fallback, "scripts", "AmazonMusicRateSwitcher.ps1")))
            return fallback;

        throw new InvalidOperationException(
            "Could not locate the AmazonMusicRateSwitcher project folder. " +
            "Place the GUI next to the scripts folder.");
    }
}

internal sealed class MainForm : Form
{
    private readonly string _projectRoot;
    private readonly ComboBox _mode = new();
    private readonly NumericUpDown _testTracks = new();
    private readonly Button _start = new();
    private readonly Button _stop = new();
    private readonly Button _autoTest = new();
    private readonly Button _testStop = new();
    private readonly Button _nowPlayingTab = new();
    private readonly Button _autoTestTab = new();
    private readonly Label _status = new();
    private readonly Label _statusDetail = new();
    private readonly Label _trackTitle = new();
    private readonly Label _trackArtist = new();
    private readonly Label _trackFormat = new();
    private readonly Label _trackFormatDetail = new();
    private readonly Label _testSummary = new();
    private readonly Label _testMode = new();
    private readonly PictureBox _artwork = new();
    private readonly Panel _nowPlayingPage = new();
    private readonly Panel _autoTestPage = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _processGate = new();
    private static readonly HttpClient ArtworkClient = CreateArtworkClient();
    private Process? _backend;
    private bool _isAsioSession;
    private bool _closing;
    private bool _allowClose;
    private bool _autoTestResultShown;
    private int _artworkRequestVersion;
    private int _trackDisplayVersion;
    private string _currentAsin = string.Empty;
    private string _latestFormatAsin = string.Empty;
    private string _latestFormatText = string.Empty;

    public MainForm(string projectRoot)
    {
        _projectRoot = projectRoot;
        Text = "Amazon Music Rate Switcher";
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(560, 822);
        MinimumSize = Size;
        MaximumSize = Size;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(28, 30, 34);
        ForeColor = Color.FromArgb(235, 238, 242);

        BuildLayout();
        SetRunning(false);
        AppendLog("Ready. Start playback to show track information.");
        Shown += (_, _) => ShowPage(false);
    }

    private void BuildLayout()
    {
        var shell = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(24, 18, 24, 20),
            BackColor = BackColor
        };
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            BackColor = BackColor
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var brand = new Label
        {
            Text = "AMAZON MUSIC SWITCHER",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            AutoEllipsis = true,
            Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold),
            ForeColor = Color.FromArgb(211, 202, 255)
        };
        _status.Text = "STOPPED";
        _status.AutoSize = true;
        _status.Anchor = AnchorStyles.Right;
        _status.Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold);
        _status.ForeColor = Color.FromArgb(140, 146, 158);
        header.Controls.Add(brand, 0, 0);
        header.Controls.Add(_status, 1, 0);

        var navigation = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            BackColor = BackColor,
            Padding = new Padding(0)
        };
        ConfigureTabButton(_nowPlayingTab, "PLAYBACK", (_, _) => ShowPage(false));
        ConfigureTabButton(_autoTestTab, "AUTO TEST", (_, _) => ShowPage(true));
        navigation.Controls.Add(_nowPlayingTab);
        navigation.Controls.Add(_autoTestTab);

        BuildNowPlayingPage();
        BuildAutoTestPage();
        var pageHost = new Panel { Dock = DockStyle.Fill, BackColor = BackColor };
        pageHost.Controls.Add(_autoTestPage);
        pageHost.Controls.Add(_nowPlayingPage);

        shell.Controls.Add(header, 0, 0);
        shell.Controls.Add(navigation, 0, 1);
        shell.Controls.Add(pageHost, 0, 2);
        Controls.Add(shell);
        ShowPage(false);
        FormClosing += FormClosingHandler;
    }

    private void BuildNowPlayingPage()
    {
        _nowPlayingPage.Dock = DockStyle.Fill;
        _nowPlayingPage.BackColor = BackColor;
        var page = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 7,
            BackColor = BackColor
        };
        page.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 55));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 94));

        var artworkRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, BackColor = BackColor };
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 286));
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        _artwork.Dock = DockStyle.Fill;
        _artwork.Margin = new Padding(5, 5, 5, 10);
        _artwork.SizeMode = PictureBoxSizeMode.Zoom;
        _artwork.BackColor = Color.FromArgb(35, 37, 45);
        _artwork.Image = CreatePlaceholderArtwork();
        artworkRow.Controls.Add(_artwork, 1, 0);

        ConfigureCenteredLabel(_trackTitle, "Waiting for Amazon Music", 15F, Color.FromArgb(242, 243, 247), true);
        ConfigureCenteredLabel(_trackArtist, "Start playback to show track information", 10.5F, Color.FromArgb(145, 150, 164), false);
        ConfigureCenteredLabel(_trackFormat, "—", 21F, Color.FromArgb(211, 202, 255), true);
        ConfigureCenteredLabel(_trackFormatDetail, "Track format", 9.5F, Color.FromArgb(112, 117, 130), false);
        ConfigureCenteredLabel(_statusDetail, "Ready", 9.5F, Color.FromArgb(155, 160, 173), false);

        var controls = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 4,
            RowCount = 2,
            Padding = new Padding(14, 10, 14, 8),
            BackColor = Color.FromArgb(38, 40, 48)
        };
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
        controls.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        controls.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var outputLabel = SmallCaption("OUTPUT PATH");
        _mode.DropDownStyle = ComboBoxStyle.DropDownList;
        _mode.Items.AddRange(new object[] { "ASIO · Hi-Fi Cable", "Direct · Windows output" });
        _mode.SelectedIndex = 0;
        _mode.Dock = DockStyle.Fill;
        _mode.FlatStyle = FlatStyle.Flat;
        _mode.BackColor = Color.FromArgb(52, 55, 65);
        _mode.ForeColor = Color.White;
        _mode.SelectedIndexChanged += (_, _) => _testMode.Text = $"Output: {_mode.SelectedItem}";
        ConfigureActionButton(_start, "START", Color.FromArgb(103, 82, 185), StartClicked);
        ConfigureActionButton(_stop, "STOP", Color.FromArgb(71, 73, 84), StopClicked);
        controls.Controls.Add(outputLabel, 0, 0);
        controls.SetColumnSpan(outputLabel, 2);
        controls.Controls.Add(_mode, 0, 1);
        controls.SetColumnSpan(_mode, 2);
        controls.Controls.Add(_start, 2, 1);
        controls.Controls.Add(_stop, 3, 1);

        page.Controls.Add(artworkRow, 0, 0);
        page.Controls.Add(_trackTitle, 0, 1);
        page.Controls.Add(_trackArtist, 0, 2);
        page.Controls.Add(_trackFormat, 0, 3);
        page.Controls.Add(_trackFormatDetail, 0, 4);
        page.Controls.Add(_statusDetail, 0, 5);
        page.Controls.Add(controls, 0, 6);
        _nowPlayingPage.Controls.Add(page);
    }

    private void BuildAutoTestPage()
    {
        _autoTestPage.Dock = DockStyle.Fill;
        _autoTestPage.BackColor = BackColor;
        var page = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 6,
            Padding = new Padding(34, 45, 34, 34),
            BackColor = BackColor
        };
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 66));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 64));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 180));
        page.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var title = new Label
        {
            Text = "Queue verification",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Font = new Font("Segoe UI Semibold", 22F, FontStyle.Bold),
            ForeColor = Color.FromArgb(242, 243, 247)
        };
        var description = new Label
        {
            Text = "Advance through the queue and verify that track, endpoint and playback formats stay aligned.",
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", 10F),
            ForeColor = Color.FromArgb(145, 150, 164)
        };
        _testMode.Text = $"Output: {_mode.SelectedItem}";
        _testMode.Dock = DockStyle.Fill;
        _testMode.ForeColor = Color.FromArgb(179, 170, 225);
        _testMode.Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold);

        var testControls = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 4,
            RowCount = 1,
            Padding = new Padding(0, 7, 0, 7),
            BackColor = BackColor
        };
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 80));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        _testTracks.Minimum = 1;
        _testTracks.Maximum = 999;
        _testTracks.Value = 10;
        _testTracks.Anchor = AnchorStyles.Left;
        _testTracks.Width = 72;
        _testTracks.Height = 30;
        _testTracks.Margin = new Padding(0);
        _testTracks.BackColor = Color.FromArgb(52, 55, 65);
        _testTracks.ForeColor = Color.White;
        ConfigureActionButton(_autoTest, "RUN TEST", Color.FromArgb(103, 82, 185), AutoTestClicked);
        ConfigureActionButton(_testStop, "STOP", Color.FromArgb(71, 73, 84), StopClicked);
        testControls.Controls.Add(new Label
        {
            Text = "Tracks",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = Color.FromArgb(200, 202, 210),
            Padding = new Padding(0, 0, 12, 0)
        }, 0, 0);
        testControls.Controls.Add(_testTracks, 1, 0);
        testControls.Controls.Add(_autoTest, 2, 0);
        testControls.Controls.Add(_testStop, 3, 0);

        _testSummary.Text = "Start playback, enable autoplay, and leave enough tracks in the queue.";
        _testSummary.Dock = DockStyle.Fill;
        _testSummary.Padding = new Padding(16);
        _testSummary.BackColor = Color.FromArgb(38, 40, 48);
        _testSummary.ForeColor = Color.FromArgb(176, 180, 191);
        _testSummary.Font = new Font("Segoe UI", 9.5F);

        page.Controls.Add(title, 0, 0);
        page.Controls.Add(description, 0, 1);
        page.Controls.Add(_testMode, 0, 2);
        page.Controls.Add(testControls, 0, 3);
        page.Controls.Add(_testSummary, 0, 4);
        _autoTestPage.Controls.Add(page);
    }

    private void ShowPage(bool autoTest)
    {
        _autoTestPage.Visible = autoTest;
        _nowPlayingPage.Visible = !autoTest;
        _autoTestPage.BringToFront();
        if (!autoTest) _nowPlayingPage.BringToFront();
        StyleSelectedTab(_autoTestTab, autoTest);
        StyleSelectedTab(_nowPlayingTab, !autoTest);
    }

    private static void ConfigureCenteredLabel(Label label, string text, float size, Color color, bool bold)
    {
        label.Text = text;
        label.Dock = DockStyle.Fill;
        label.TextAlign = ContentAlignment.MiddleCenter;
        label.AutoEllipsis = true;
        label.Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        label.ForeColor = color;
    }

    private static Label SmallCaption(string text) => new()
    {
        Text = text,
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.MiddleLeft,
        Font = new Font("Segoe UI Semibold", 8F, FontStyle.Bold),
        ForeColor = Color.FromArgb(121, 125, 138)
    };

    private static void ConfigureActionButton(Button button, string text, Color color, EventHandler handler)
    {
        button.Text = text;
        button.Dock = DockStyle.Fill;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = color;
        button.ForeColor = Color.White;
        button.Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold);
        button.Margin = new Padding(5, 2, 0, 2);
        button.Click += handler;
    }

    private static void ConfigureTabButton(Button button, string text, EventHandler handler)
    {
        button.Text = text;
        button.Width = 120;
        button.Height = 34;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = Color.Transparent;
        button.ForeColor = Color.FromArgb(130, 134, 147);
        button.Font = new Font("Segoe UI Semibold", 8.5F, FontStyle.Bold);
        button.Click += handler;
    }

    private static void StyleSelectedTab(Button button, bool selected)
    {
        button.ForeColor = selected ? Color.FromArgb(211, 202, 255) : Color.FromArgb(130, 134, 147);
        button.BackColor = selected ? Color.FromArgb(44, 42, 57) : Color.Transparent;
    }

    private bool IsRunning
    {
        get
        {
            lock (_processGate)
                return _backend is { HasExited: false };
        }
    }

    private OutputMode SelectedMode => _mode.SelectedIndex == 1 ? OutputMode.Direct : OutputMode.Asio;

    private void SetRunning(bool running)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => SetRunning(running)));
            return;
        }

        _mode.Enabled = !running;
        _testTracks.Enabled = !running;
        _start.Enabled = !running;
        _autoTest.Enabled = !running;
        _stop.Enabled = running;
        _testStop.Enabled = running;
        if (running)
        {
            _status.Text = $"RUNNING · {(SelectedMode == OutputMode.Asio ? "ASIO" : "DIRECT")}";
            _status.ForeColor = Color.FromArgb(93, 205, 137);
        }
        else if (!_autoTestResultShown)
        {
            _status.Text = "STOPPED";
            _status.ForeColor = Color.FromArgb(157, 166, 177);
            _statusDetail.Text = "Ready";
        }
    }

    private async void StartClicked(object? sender, EventArgs e)
    {
        await StartSessionAsync(autoTest: false);
    }

    private async void AutoTestClicked(object? sender, EventArgs e)
    {
        await StartSessionAsync(autoTest: true);
    }

    private async Task StartSessionAsync(bool autoTest)
    {
        if (IsRunning)
            return;

        var mode = SelectedMode;
        _autoTestResultShown = false;
        SetRunning(true);
        AppendLog($"Starting {(autoTest ? "AutoTest" : "monitor")} in {(mode == OutputMode.Asio ? "ASIO" : "Direct")} mode...");

        try
        {
            // Check before changing the app route or starting ASIO Bridge. The
            // backend owns the same OS mutex, so CMD/manual launches are also
            // protected even if they do not use this GUI.
            await RunPowerShellOnceAsync(
                "scripts\\AmazonMusicRateSwitcher.ps1",
                new[] { "-CheckInstance" },
                _lifetime.Token);

            await EnsureDependenciesAsync();

            _isAsioSession = mode == OutputMode.Asio;
            if (_isAsioSession)
            {
                await SetAmazonCableRouteAsync();
                await RunPowerShellOnceAsync(
                    "scripts\\Ensure-AsioBridge.ps1",
                    new[] { "-KeepAlivePid", Environment.ProcessId.ToString() },
                    _lifetime.Token);
            }

            var script = Path.Combine(_projectRoot, "scripts", "AmazonMusicRateSwitcher.ps1");
            var args = new List<string>
            {
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
                "-Mode", autoTest ? "AutoTest" : "Monitor",
                "-Apply", "-Cdp", "-CdpLaunch",
                "-OwnerPid", Environment.ProcessId.ToString()
            };
            if (autoTest)
            {
                args.Add("-TestTracks");
                args.Add(((int)_testTracks.Value).ToString());
            }
            if (mode == OutputMode.Direct)
                args.Add("-Direct");

            StartBackend(args);
        }
        catch (Exception ex)
        {
            AppendLog($"Startup failed: {ex.Message}");
            await CleanupAsioAsync();
            SetRunning(false);
        }
    }

    private async Task EnsureDependenciesAsync()
    {
        var tool = Path.Combine(_projectRoot, "tools", "SoundVolumeView", "SoundVolumeView.exe");
        if (File.Exists(tool))
            return;

        AppendLog("Installing the audio endpoint helper for first use...");
        await RunPowerShellOnceAsync(
            "scripts\\setup.ps1",
            Array.Empty<string>(),
            _lifetime.Token);
        if (!File.Exists(tool))
            throw new InvalidOperationException("Dependency setup completed without installing SoundVolumeView.");
    }

    private async Task SetAmazonCableRouteAsync()
    {
        var tool = Path.Combine(_projectRoot, "tools", "SoundVolumeView", "SoundVolumeView.exe");
        if (!File.Exists(tool))
        {
            AppendLog("SoundVolumeView is not installed; leaving the Amazon app route unchanged.");
            return;
        }

        AppendLog("Routing Amazon Music to Hi-Fi Cable Input...");
        await RunExecutableOnceAsync(tool, new[]
        {
            "/SetAppDefault",
            "VB-Audio Hi-Fi Cable\\Device\\Hi-Fi Cable Input\\Render",
            "all",
            "Amazon Music.exe"
        }, _lifetime.Token);
    }

    private void StartBackend(IReadOnlyList<string> arguments)
    {
        var powershell = PowerShellPath();
        var psi = new ProcessStartInfo
        {
            FileName = powershell,
            WorkingDirectory = _projectRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments)
            psi.ArgumentList.Add(argument);

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        psi.Environment["AMRS_GUI"] = "1";
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) HandleBackendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendLog("[stderr] " + e.Data); };
        process.Exited += (_, _) => BackendExited(process);

        if (!process.Start())
            throw new InvalidOperationException("Could not start the PowerShell backend.");

        lock (_processGate)
            _backend = process;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        AppendLog($"Backend started (PID {process.Id}).");
    }

    private void BackendExited(Process process)
    {
        _ = Task.Run(async () =>
        {
            try { process.WaitForExit(); } catch { }
            var code = 0;
            try { code = process.ExitCode; } catch { }
            AppendLog($"Backend exited with code {code}.");
            lock (_processGate)
            {
                if (ReferenceEquals(_backend, process))
                    _backend = null;
            }
            await CleanupAsioAsync();
            if (!_closing)
                SetRunning(false);
            process.Dispose();
        });
    }

    private async void StopClicked(object? sender, EventArgs e)
    {
        await StopBackendAsync();
    }

    private async Task StopBackendAsync()
    {
        Process? process;
        lock (_processGate) process = _backend;
        if (process is { HasExited: false })
        {
            AppendLog("Stopping backend...");
            try { process.Kill(entireProcessTree: true); }
            catch (Exception ex) { AppendLog($"Stop warning: {ex.Message}"); }
            try { await Task.Run(() => process.WaitForExit(3000)); } catch { }
        }

        await CleanupAsioAsync();
        lock (_processGate) _backend = null;
        SetRunning(false);
    }

    private async Task CleanupAsioAsync()
    {
        if (!_isAsioSession)
            return;

        try
        {
            await RunPowerShellOnceAsync(
                "scripts\\Ensure-AsioBridge.ps1",
                new[] { "-Stop" },
                CancellationToken.None);
            AppendLog("ASIO Bridge cleanup requested.");
        }
        catch (Exception ex)
        {
            AppendLog($"ASIO cleanup warning: {ex.Message}");
        }
        finally
        {
            _isAsioSession = false;
        }
    }

    private async Task<int> RunPowerShellOnceAsync(string relativeScript, IReadOnlyList<string> scriptArguments, CancellationToken token)
    {
        var script = Path.Combine(_projectRoot, relativeScript);
        var args = new List<string> { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script };
        args.AddRange(scriptArguments);
        return await RunExecutableOnceAsync(PowerShellPath(), args, token);
    }

    private async Task<int> RunExecutableOnceAsync(string fileName, IReadOnlyList<string> arguments, CancellationToken token)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = _projectRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments)
            psi.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = psi };
        if (!process.Start())
            throw new InvalidOperationException($"Could not start {Path.GetFileName(fileName)}.");

        var outputTask = DrainAsync(process.StandardOutput, false, token);
        var errorTask = DrainAsync(process.StandardError, true, token);
        await process.WaitForExitAsync(token);
        await Task.WhenAll(outputTask, errorTask);
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{Path.GetFileName(fileName)} exited with code {process.ExitCode}.");
        return process.ExitCode;
    }

    private async Task DrainAsync(StreamReader reader, bool error, CancellationToken token)
    {
        while (await reader.ReadLineAsync().WaitAsync(token) is { } line)
            AppendLog(error ? "[stderr] " + line : line);
    }

    private static string PowerShellPath()
    {
        var root = Environment.GetEnvironmentVariable("SystemRoot");
        var path = string.IsNullOrWhiteSpace(root)
            ? string.Empty
            : Path.Combine(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(path) ? path : "powershell.exe";
    }

    private void HandleBackendLine(string text)
    {
        const string formatPrefix = "@@AMRS_FORMAT@@";
        const string base64Prefix = "@@AMRS_TRACK_B64@@";
        const string legacyPrefix = "@@AMRS_TRACK@@";
        const string autoTestSummaryPrefix = "@@AMRS_AUTOTEST_SUMMARY_B64@@";
        if (text.StartsWith(autoTestSummaryPrefix, StringComparison.Ordinal))
        {
            try
            {
                var json = Encoding.UTF8.GetString(
                    Convert.FromBase64String(text[autoTestSummaryPrefix.Length..]));
                ApplyAutoTestSummary(json);
            }
            catch
            {
                AppendLog("AutoTest completed, but its UI summary could not be read.");
            }
            return;
        }

        if (text.StartsWith(formatPrefix, StringComparison.Ordinal))
        {
            var parts = text[formatPrefix.Length..].Split('|');
            if (parts.Length == 3 &&
                int.TryParse(parts[1], out var bits) &&
                int.TryParse(parts[2], out var rateHz))
            {
                ApplyTrackFormat(parts[0], bits, rateHz);
            }
            return;
        }

        if (text.StartsWith(base64Prefix, StringComparison.Ordinal) ||
            text.StartsWith(legacyPrefix, StringComparison.Ordinal))
        {
            try
            {
                var json = text.StartsWith(base64Prefix, StringComparison.Ordinal)
                    ? Encoding.UTF8.GetString(Convert.FromBase64String(text[base64Prefix.Length..]))
                    : text[legacyPrefix.Length..];
                var metadata = JsonSerializer.Deserialize<TrackMetadata>(
                    json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (metadata is not null)
                    UpdateNowPlaying(metadata);
            }
            catch
            {
                // Metadata is decorative. Playback switching must continue if
                // Amazon changes an artwork or album field.
            }
            return;
        }

        AppendLog(text);
    }

    private void ApplyAutoTestSummary(string json)
    {
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => ApplyAutoTestSummary(json))); } catch (InvalidOperationException) { }
            return;
        }

        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var requested = root.GetProperty("RequestedTracks").GetInt32();
        var completed = root.GetProperty("CompletedTracks").GetInt32();
        var passed = root.GetProperty("Passed").GetInt32();
        var failed = root.GetProperty("Failed").GetInt32();
        var allPassed = root.TryGetProperty("AllPassed", out var allPassedElement) && allPassedElement.GetBoolean();

        var lines = new List<string>();
        if (allPassed)
        {
            lines.Add($"ALL PASS  ·  {passed}/{requested} tracks");
            _status.Text = "ALL PASS";
            _status.ForeColor = Color.FromArgb(93, 205, 137);
            _statusDetail.Text = "Every requested track and endpoint format passed verification";
        }
        else
        {
            lines.Add($"{failed} FAIL  ·  {passed}/{completed} passed" +
                      (completed < requested ? $"  ·  stopped at {completed}/{requested}" : string.Empty));
            _status.Text = $"{failed} FAIL";
            _status.ForeColor = Color.FromArgb(240, 112, 112);
            _statusDetail.Text = "AutoTest completed with recorded failures";

            if (root.TryGetProperty("Failures", out var failures) && failures.ValueKind == JsonValueKind.Array)
            {
                foreach (var failure in failures.EnumerateArray().Take(4))
                {
                    var number = failure.TryGetProperty("Number", out var numberElement)
                        ? numberElement.GetInt32().ToString()
                        : "?";
                    var reason = failure.TryGetProperty("Reason", out var reasonElement)
                        ? reasonElement.GetString()
                        : "Unknown reason";
                    lines.Add($"#{number}  {reason}");
                }
                if (failed > 4)
                    lines.Add($"…and {failed - 4} more (see state/auto-test-latest.json)");
            }
        }

        lines.Add(
            $"Average latency: {ReadLatency(root, "AverageSuccessfulTrackMs")}  ·  " +
            $"switched {ReadLatency(root, "AverageSuccessfulSwitchMs")}  ·  " +
            $"same-format {ReadLatency(root, "AverageSuccessfulSameFormatMs")}");
        _testSummary.Text = string.Join(Environment.NewLine, lines);
        _autoTestResultShown = true;
    }

    private static string ReadLatency(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value) || value.ValueKind != JsonValueKind.Number)
            return "n/a";
        return $"{value.GetDouble():0.#} ms";
    }

    private void UpdateNowPlaying(TrackMetadata metadata)
    {
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => UpdateNowPlaying(metadata))); } catch (InvalidOperationException) { }
            return;
        }

        var isNewTrack = !string.Equals(_currentAsin, metadata.Asin, StringComparison.OrdinalIgnoreCase);
        _currentAsin = metadata.Asin;
        var displayVersion = Interlocked.Increment(ref _trackDisplayVersion);
        _trackTitle.Text = string.IsNullOrWhiteSpace(metadata.Title) ? "Unknown track" : metadata.Title;
        var secondary = new[] { metadata.Artist, metadata.Album }
            .Where(value => !string.IsNullOrWhiteSpace(value));
        _trackArtist.Text = string.Join("  ·  ", secondary);
        if (string.Equals(_latestFormatAsin, metadata.Asin, StringComparison.OrdinalIgnoreCase) &&
            !string.IsNullOrWhiteSpace(_latestFormatText))
        {
            _trackFormat.Text = _latestFormatText;
            _trackFormatDetail.Text = "TRACK / ENDPOINT FORMAT";
        }
        else
        {
            _trackFormat.Text = "Reading format…";
            _trackFormatDetail.Text = "WAITING FOR AMAZON";
            _ = ExpirePendingFormatAsync(metadata.Asin, displayVersion);
        }
        _statusDetail.Text = "Track detected";

        if (isNewTrack)
            SetArtwork(CreatePlaceholderArtwork(), Interlocked.Increment(ref _artworkRequestVersion));
        if (!string.IsNullOrWhiteSpace(metadata.ArtworkUrl))
            _ = LoadArtworkAsync(metadata.ArtworkUrl);
    }

    private void ApplyTrackFormat(string asin, int bits, int rateHz)
    {
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => ApplyTrackFormat(asin, bits, rateHz))); } catch (InvalidOperationException) { }
            return;
        }

        var rateText = rateHz % 1000 == 0
            ? $"{rateHz / 1000}"
            : $"{rateHz / 1000d:0.#}";
        _latestFormatAsin = asin;
        _latestFormatText = $"{bits}-bit  /  {rateText} kHz";
        if (!string.Equals(_currentAsin, asin, StringComparison.OrdinalIgnoreCase))
            return;

        Interlocked.Increment(ref _trackDisplayVersion);
        _trackFormat.Text = _latestFormatText;
        _trackFormatDetail.Text = "TRACK / ENDPOINT FORMAT";
    }

    private async Task ExpirePendingFormatAsync(string asin, int displayVersion)
    {
        try { await Task.Delay(2200, _lifetime.Token); }
        catch { return; }
        if (IsDisposed)
            return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => ExpirePendingFormat(asin, displayVersion))); } catch (InvalidOperationException) { }
            return;
        }
        ExpirePendingFormat(asin, displayVersion);
    }

    private void ExpirePendingFormat(string asin, int displayVersion)
    {
        if (displayVersion != _trackDisplayVersion ||
            !string.Equals(_currentAsin, asin, StringComparison.OrdinalIgnoreCase) ||
            !_trackFormat.Text.StartsWith("Reading", StringComparison.OrdinalIgnoreCase))
            return;

        _trackFormat.Text = "Format unavailable";
        _trackFormatDetail.Text = "TRACK CHANGED TOO QUICKLY — WAITING FOR NEXT TRACK";
        _statusDetail.Text = "Skipped incomplete track data";
    }

    private async Task LoadArtworkAsync(string artworkUrl)
    {
        var requestVersion = Interlocked.Increment(ref _artworkRequestVersion);
        if (string.IsNullOrWhiteSpace(artworkUrl))
        {
            SetArtwork(CreatePlaceholderArtwork(), requestVersion);
            return;
        }

        artworkUrl = NormalizeArtworkUrl(artworkUrl);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var bytes = await ArtworkClient.GetByteArrayAsync(artworkUrl, _lifetime.Token);
                using var stream = new MemoryStream(bytes);
                using var source = Image.FromStream(stream);
                SetArtwork(new Bitmap(source), requestVersion);
                return;
            }
            catch when (attempt < 2 && !_lifetime.IsCancellationRequested)
            {
                await Task.Delay(350 * (attempt + 1), _lifetime.Token);
            }
            catch
            {
                break;
            }
        }

        // Keep the current image. A later CDP snapshot can publish a refreshed
        // artwork URL without making the cover flash back to a placeholder.
    }

    private static string NormalizeArtworkUrl(string artworkUrl)
    {
        // Amazon frequently labels a WebP response as a .jpg URL by inserting
        // _FMwebp_ in the image transform. System.Drawing cannot decode WebP;
        // the equivalent _SX..._ URL returns an actual JPEG from the same CDN.
        return Regex.Replace(artworkUrl, "_FMwebp_", "_", RegexOptions.IgnoreCase);
    }

    private static HttpClient CreateArtworkClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 AmazonMusicRateSwitcher/1.0");
        return client;
    }

    private void SetArtwork(Image image, int requestVersion)
    {
        if (requestVersion != _artworkRequestVersion || IsDisposed)
        {
            image.Dispose();
            return;
        }
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => SetArtwork(image, requestVersion))); }
            catch (InvalidOperationException) { image.Dispose(); }
            return;
        }

        var previous = _artwork.Image;
        _artwork.Image = image;
        previous?.Dispose();
    }

    private static Bitmap CreatePlaceholderArtwork()
    {
        var bitmap = new Bitmap(560, 560);
        using var graphics = Graphics.FromImage(bitmap);
        using var background = new System.Drawing.Drawing2D.LinearGradientBrush(
            new Rectangle(0, 0, bitmap.Width, bitmap.Height),
            Color.FromArgb(48, 43, 68),
            Color.FromArgb(25, 28, 37),
            45F);
        graphics.FillRectangle(background, 0, 0, bitmap.Width, bitmap.Height);
        using var glow = new SolidBrush(Color.FromArgb(60, 156, 125, 235));
        graphics.FillEllipse(glow, 105, 115, 350, 350);
        using var bar = new SolidBrush(Color.FromArgb(215, 211, 202, 255));
        var heights = new[] { 70, 150, 225, 130, 185, 95 };
        for (var i = 0; i < heights.Length; i++)
        {
            var height = heights[i];
            graphics.FillRectangle(bar, 145 + i * 48, 280 - height / 2, 20, height);
        }
        return bitmap;
    }

    private void AppendLog(string text)
    {
        text = text.Trim();
        if (string.IsNullOrWhiteSpace(text))
            return;
        if (IsDisposed)
            return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => AppendLog(text))); } catch (InvalidOperationException) { }
            return;
        }

        UpdateStatusFromEvent(text);
    }

    private void UpdateStatusFromEvent(string text)
    {
        if (text.Contains("Switching", StringComparison.OrdinalIgnoreCase))
        {
            _status.Text = "SWITCHING";
            _status.ForeColor = Color.FromArgb(246, 193, 80);
            _statusDetail.Text = "Changing the Windows endpoint format…";
        }
        else if (text.Contains("CDP confirmed same-track rebuild", StringComparison.OrdinalIgnoreCase))
        {
            _status.Text = "RESTORED";
            _status.ForeColor = Color.FromArgb(146, 124, 232);
            _statusDetail.Text = "Amazon reopened the stream at the selected format";
        }
        else if (text.Contains("Endpoint format confirmed", StringComparison.OrdinalIgnoreCase) ||
                 text.Contains("Endpoint already matches", StringComparison.OrdinalIgnoreCase))
        {
            _status.Text = "READY";
            _status.ForeColor = Color.FromArgb(93, 205, 137);
            _statusDetail.Text = text.Contains("already matches", StringComparison.OrdinalIgnoreCase)
                ? "Endpoint already matched — no replay needed"
                : "Endpoint changed — waiting for Amazon playback";
        }
        else if (text.Contains("failed", StringComparison.OrdinalIgnoreCase) ||
                 text.Contains("error", StringComparison.OrdinalIgnoreCase))
        {
            _status.Text = "ERROR";
            _status.ForeColor = Color.FromArgb(240, 112, 112);
            _statusDetail.Text = text;
            _testSummary.Text = text;
        }
        else if (text.Contains("AutoTest started", StringComparison.OrdinalIgnoreCase) ||
                 text.Contains("AutoTest latency", StringComparison.OrdinalIgnoreCase) ||
                 text.Contains("AutoTest complete", StringComparison.OrdinalIgnoreCase) ||
                 Regex.IsMatch(text, @"AutoTest\s+\d+/\d+", RegexOptions.IgnoreCase))
        {
            _status.Text = "TESTING";
            _status.ForeColor = Color.FromArgb(121, 177, 240);
            _testSummary.Text = text;
        }
    }

    private async void FormClosingHandler(object? sender, FormClosingEventArgs e)
    {
        if (_allowClose)
            return;

        e.Cancel = true;
        if (_closing)
            return;

        _closing = true;
        _lifetime.Cancel();
        Enabled = false;
        _status.Text = "CLOSING";
        _statusDetail.Text = "Stopping the audio switcher…";

        try
        {
            var stopTask = StopBackendAsync();
            await Task.WhenAny(stopTask, Task.Delay(3000));
        }
        catch
        {
        }

        var artwork = _artwork.Image;
        _artwork.Image = null;
        artwork?.Dispose();
        _allowClose = true;
        Close();
    }
}
