using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AmazonMusicRateSwitcher.Gui;

internal enum OutputMode
{
    AsioExclusive
}

internal enum CaptionButtonKind
{
    Minimize,
    Close
}

// Flat buttons show a native focus rectangle after a mouse click even when
// their border size is zero. Keep these compact controls visually borderless
// in every focus state.
internal class FocuslessButton : Button
{
    protected override bool ShowFocusCues => false;
}

internal static class RoundedUi
{
    public static System.Drawing.Drawing2D.GraphicsPath CreatePath(RectangleF bounds, float radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        var diameter = Math.Max(1F, radius * 2F);
        var arc = new RectangleF(bounds.X, bounds.Y, diameter, diameter);
        path.AddArc(arc, 180F, 90F);
        arc.X = bounds.Right - diameter;
        path.AddArc(arc, 270F, 90F);
        arc.Y = bounds.Bottom - diameter;
        path.AddArc(arc, 0F, 90F);
        arc.X = bounds.X;
        path.AddArc(arc, 90F, 90F);
        path.CloseFigure();
        return path;
    }

    public static void ApplyRegion(Control control, int radius = 7)
    {
        void UpdateRegion()
        {
            if (control.Width <= 1 || control.Height <= 1)
                return;

            using var path = CreatePath(new RectangleF(0, 0, control.Width, control.Height), radius);
            var previous = control.Region;
            control.Region = new Region(path);
            previous?.Dispose();
        }

        control.HandleCreated += (_, _) => UpdateRegion();
        control.Resize += (_, _) => UpdateRegion();
        UpdateRegion();
    }
}

internal sealed class TabButton : FocuslessButton
{
    public bool Selected { get; set; }

    public TabButton()
    {
        SetStyle(
            ControlStyles.UserPaint |
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.ResizeRedraw |
            ControlStyles.SupportsTransparentBackColor,
            true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width <= 2 || Height <= 3)
            return;

        // Keep the one-pixel frame aligned to physical pixels. AntiAlias blends
        // the cyan edge with the background and makes it look soft at 125/150% DPI.
        e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
        var parentColor = Parent?.BackColor ?? Color.FromArgb(23, 27, 30);
        e.Graphics.Clear(parentColor);

        // Use nested integer-aligned rectangles. This keeps every edge sharp
        // and avoids the clipped bottom line seen with a one-pixel pen.
        if (Selected)
        {
            using var borderFill = new SolidBrush(Color.FromArgb(168, 240, 233));
            e.Graphics.FillRectangle(borderFill, 1, 1, Width - 3, Height - 4);
            using var selectedFill = new SolidBrush(Color.FromArgb(29, 57, 59));
            e.Graphics.FillRectangle(selectedFill, 2, 2, Width - 5, Height - 6);
        }

        TextRenderer.DrawText(
            e.Graphics,
            Text,
            Font,
            ClientRectangle,
            ForeColor,
            TextFormatFlags.HorizontalCenter |
            TextFormatFlags.VerticalCenter |
            TextFormatFlags.SingleLine |
            TextFormatFlags.NoPadding |
            TextFormatFlags.NoPrefix);
    }
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
    private const float MaximumUiDpi = 144F; // 150% of the 96-DPI design size
    private const float UiFontScale = 1.40F;
    private const int DesignClientWidth = 440;
    private const int DesignClientHeight = 560;
    private const int PlaybackOutputTopPadding = 4;
    private const int PlaybackOutputLabelHeight = 18;
    private const int PlaybackOutputActionHeight = 24;
    private const int PlaybackOutputBottomSpacing = 10;
    private const int PlaybackOutputFrameHeight =
        PlaybackOutputTopPadding +
        PlaybackOutputLabelHeight +
        PlaybackOutputActionHeight +
        PlaybackOutputBottomSpacing;
    private readonly string _projectRoot;
    private readonly Label _mode = new();
    private readonly NumericUpDown _testTracks = new();
    private readonly Button _start = new FocuslessButton();
    private readonly Button _stop = new FocuslessButton();
    private readonly Button _autoTest = new FocuslessButton();
    private readonly Button _testStop = new FocuslessButton();
    private readonly TabButton _nowPlayingTab = new();
    private readonly TabButton _autoTestTab = new();
    private readonly Label _status = new();
    private readonly Label _statusDetail = new();
    private readonly Label _trackTitle = new();
    private readonly Label _trackArtist = new();
    private readonly Label _trackFormat = new();
    private readonly Label _trackFormatDetail = new();
    private readonly Label _testSummary = new();
    private readonly Label _testMode = new();
    private readonly PictureBox _artwork = new();
    private readonly PictureBox _captionIcon = new();
    private readonly Panel _captionBar = new();
    private readonly Panel _nowPlayingPage = new();
    private readonly Panel _autoTestPage = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _processGate = new();
    private readonly Dictionary<Control, Font> _baseFonts = new();
    private static readonly HttpClient ArtworkClient = CreateArtworkClient();
    private Process? _backend;
    private bool _isAsioSession;
    private bool _closing;
    private bool _allowClose;
    private bool _autoTestResultShown;
    private bool _dpiCapInitialized;
    private float _lastRawDpi = 96F;
    private float _lastEffectiveDpi = 96F;
    private float _lastGeometryScale = 1F;
    private int _artworkRequestVersion;
    private int _trackDisplayVersion;
    private string _currentAsin = string.Empty;
    private string _latestFormatAsin = string.Empty;
    private string _latestFormatText = string.Empty;

    public MainForm(string projectRoot)
    {
        _projectRoot = projectRoot;
        Text = "Rate Changer";
        StartPosition = FormStartPosition.CenterScreen;
        // The compact UI is deliberately capped at a 150% design scale. Let
        // the form apply that cap itself so 225% Windows scaling does not
        // leave the borderless window physically smaller than it is at 150%.
        AutoScaleMode = AutoScaleMode.None;
        AutoScaleDimensions = new SizeF(96F, 96F);
        ClientSize = new Size(DesignClientWidth, DesignClientHeight);
        FormBorderStyle = FormBorderStyle.None;
        MaximizeBox = false;
        MinimizeBox = false;
        Icon = CreateAppIcon();
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(23, 27, 30);
        ForeColor = Color.FromArgb(235, 238, 242);

        BuildLayout();
        CaptureBaseFonts();
        SetRunning(false);
        AppendLog("Ready. Start playback to show track information.");
        Shown += (_, _) =>
        {
            _captionBar.Height = 34;
            _captionBar.MinimumSize = new Size(0, 34);
            _captionBar.MaximumSize = new Size(0, 34);
            ApplyInitialDpiCap();
            ShowPage(false);
            BeginInvoke(new Action(SyncAllActionHeights));
        };
    }

    private static Icon CreateAppIcon()
    {
        using var bitmap = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(42, 157, 148));
        using var bars = new SolidBrush(Color.FromArgb(236, 255, 252));
        var heights = new[] { 4, 9, 13, 7, 11, 5 };
        for (var index = 0; index < heights.Length; index++)
        {
            var height = heights[index];
            graphics.FillRectangle(bars, 2 + index * 2, (16 - height) / 2, 1, height);
        }

        var handle = bitmap.GetHicon();
        using var temporary = Icon.FromHandle(handle);
        var icon = (Icon)temporary.Clone();
        DestroyIcon(handle);
        return icon;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr word, IntPtr lParam);

    private void ApplyInitialDpiCap()
    {
        if (_dpiCapInitialized)
            return;

        var rawDpi = Math.Max(96F, DeviceDpi);
        var effectiveDpi = Math.Min(rawDpi, MaximumUiDpi);
        var geometryScale = effectiveDpi / 96F;
        if (Math.Abs(geometryScale - 1F) > 0.001F)
            Scale(new SizeF(geometryScale, geometryScale));
        SetCappedClientSize(geometryScale);
        _lastGeometryScale = geometryScale;
        var correction = effectiveDpi / rawDpi;
        if (Math.Abs(correction - 1F) > 0.001F)
            ApplyDpiFontCorrection(correction);
        _lastRawDpi = rawDpi;
        _lastEffectiveDpi = effectiveDpi;
        _dpiCapInitialized = true;
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        var oldRawDpi = _dpiCapInitialized ? _lastRawDpi : Math.Max(96F, e.DeviceDpiOld);
        var oldEffectiveDpi = _dpiCapInitialized
            ? _lastEffectiveDpi
            : Math.Min(oldRawDpi, MaximumUiDpi);
        SuspendLayout();
        try
        {
            base.OnDpiChanged(e);
            if (!_dpiCapInitialized)
                return;

            var newRawDpi = Math.Max(96F, e.DeviceDpiNew);
            var newEffectiveDpi = Math.Min(newRawDpi, MaximumUiDpi);
            var newGeometryScale = newEffectiveDpi / 96F;
            var geometryCorrection = newGeometryScale / _lastGeometryScale;
            if (Math.Abs(geometryCorrection - 1F) > 0.001F)
                Scale(new SizeF(geometryCorrection, geometryCorrection));
            var automaticScale = newRawDpi / oldRawDpi;
            var desiredScale = newEffectiveDpi / oldEffectiveDpi;
            var correction = desiredScale / automaticScale;
            if (Math.Abs(correction - 1F) > 0.001F)
                ApplyDpiFontCorrection(correction);

            // PerMonitorV2 can resize a borderless form while it crosses a
            // monitor. Re-apply the capped design size after that automatic
            // pass so the artwork, control rows, and spacing keep one ratio.
            SetCappedClientSize(newGeometryScale);
            _lastRawDpi = newRawDpi;
            _lastEffectiveDpi = newEffectiveDpi;
            _lastGeometryScale = newGeometryScale;
            BeginInvoke(new Action(SyncAllActionHeights));
        }
        finally
        {
            ResumeLayout(true);
        }
    }

    private void SetCappedClientSize(float geometryScale)
    {
        ClientSize = new Size(
            Math.Max(1, (int)Math.Round(DesignClientWidth * geometryScale)),
            Math.Max(1, (int)Math.Round(DesignClientHeight * geometryScale)));
    }

    private void ApplyDpiFontCorrection(float correction)
    {
        var fontOwners = EnumerateControls(this)
            .Where(control => control.Parent is null || !ReferenceEquals(control.Font, control.Parent.Font))
            .Where(control => _baseFonts.ContainsKey(control))
            .ToArray();

        foreach (var control in fontOwners)
        {
            var baseFont = _baseFonts[control];
            control.Font = new Font(
                baseFont.FontFamily,
                Math.Max(1F, baseFont.SizeInPoints * correction * UiFontScale),
                baseFont.Style,
                GraphicsUnit.Point,
                baseFont.GdiCharSet,
                baseFont.GdiVerticalFont);
        }
    }

    private void CaptureBaseFonts()
    {
        foreach (var control in EnumerateControls(this))
        {
            if (control.Parent is null || !ReferenceEquals(control.Font, control.Parent.Font))
                _baseFonts[control] = (Font)control.Font.Clone();
        }
    }

    private static IEnumerable<Control> EnumerateControls(Control root)
    {
        yield return root;
        foreach (Control child in root.Controls)
        {
            foreach (var descendant in EnumerateControls(child))
                yield return descendant;
        }
    }

    private void BuildLayout()
    {
        var shell = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            // Keep a stable lower gutter for both pages.
            Padding = new Padding(24, 18, 24, 12),
            BackColor = BackColor
        };
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 50));
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            Padding = new Padding(0, 24, 0, 0),
            BackColor = BackColor
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var brand = new Label
        {
            Text = "AMAZON MUSIC",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(0),
            AutoEllipsis = true,
            Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold),
            ForeColor = Color.FromArgb(168, 240, 233)
        };
        _status.Text = "STOPPED";
        _status.AutoSize = false;
        _status.Dock = DockStyle.Fill;
        _status.TextAlign = ContentAlignment.MiddleRight;
        _status.Margin = new Padding(0);
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
        ConfigureTabButton(_autoTestTab, "TEST & Config", (_, _) => ShowPage(true));
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
        // Keep the caption outside the content layout. A nested table row can
        // be expanded by a high-DPI button's preferred height and overlap the
        // content header on 200%+ displays.
        Controls.Add(shell);
        Controls.Add(BuildCaptionBar());
        _captionBar.BringToFront();
        ShowPage(false);
        FormClosing += FormClosingHandler;
    }

    private Control BuildCaptionBar()
    {
        _captionBar.Dock = DockStyle.Top;
        _captionBar.Height = 34;
        _captionBar.AutoSize = false;
        _captionBar.Padding = new Padding(10, 0, 0, 0);
        _captionBar.BackColor = Color.FromArgb(38, 40, 48);

        _captionIcon.Dock = DockStyle.Left;
        _captionIcon.Width = 22;
        _captionIcon.SizeMode = PictureBoxSizeMode.Zoom;
        _captionIcon.Margin = new Padding(3, 9, 3, 9);
        _captionIcon.Image = Icon?.ToBitmap();
        var title = new Label
        {
            Dock = DockStyle.Fill,
            Text = "Rate Changer",
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = Color.FromArgb(185, 188, 197),
            Font = new Font("Segoe UI", 9F),
            Margin = new Padding(2, 0, 0, 0)
        };
        var actions = new Panel
        {
            Dock = DockStyle.Right,
            Width = 68,
            BackColor = Color.Transparent,
            Margin = new Padding(0)
        };
        var minimize = CreateCaptionButton(CaptionButtonKind.Minimize, "Minimize", (_, _) => WindowState = FormWindowState.Minimized);
        var close = CreateCaptionButton(CaptionButtonKind.Close, "Close", (_, _) => Close());
        minimize.Dock = DockStyle.Left;
        minimize.Width = 34;
        close.Dock = DockStyle.Left;
        close.Width = 34;
        actions.Controls.Add(close);
        actions.Controls.Add(minimize);

        _captionBar.Controls.Add(title);
        _captionBar.Controls.Add(actions);
        _captionBar.Controls.Add(_captionIcon);
        AttachCaptionDrag(_captionBar);
        AttachCaptionDrag(_captionIcon);
        AttachCaptionDrag(title);
        return _captionBar;
    }

    private static Button CreateCaptionButton(CaptionButtonKind kind, string accessibleName, EventHandler click)
    {
        var button = new Button
        {
            Text = string.Empty,
            AccessibleName = accessibleName,
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(38, 40, 48),
            ForeColor = Color.FromArgb(185, 188, 197),
            Margin = new Padding(0),
            Padding = new Padding(0),
            TabStop = false
        };
        button.FlatAppearance.BorderSize = 0;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(50, 52, 60);
        button.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var centerX = e.ClipRectangle.Left + e.ClipRectangle.Width / 2F;
            var centerY = e.ClipRectangle.Top + e.ClipRectangle.Height / 2F;
            using var pen = new Pen(button.ForeColor, 1.35F)
            {
                StartCap = System.Drawing.Drawing2D.LineCap.Square,
                EndCap = System.Drawing.Drawing2D.LineCap.Square
            };
            if (kind == CaptionButtonKind.Minimize)
            {
                e.Graphics.DrawLine(pen, centerX - 5F, centerY + 1F, centerX + 5F, centerY + 1F);
            }
            else
            {
                e.Graphics.DrawLine(pen, centerX - 5F, centerY - 5F, centerX + 5F, centerY + 5F);
                e.Graphics.DrawLine(pen, centerX + 5F, centerY - 5F, centerX - 5F, centerY + 5F);
            }
        };
        button.Click += click;
        return button;
    }

    private static void AttachCaptionDrag(Control control)
    {
        control.MouseDown += (_, e) =>
        {
            if (e.Button != MouseButtons.Left)
                return;
            var form = control.FindForm();
            if (form is null)
                return;
            ReleaseCapture();
            SendMessage(form.Handle, 0xA1, new IntPtr(2), IntPtr.Zero); // WM_NCLBUTTONDOWN / HTCAPTION
        };
    }

    private void BuildNowPlayingPage()
    {
        _nowPlayingPage.Dock = DockStyle.Fill;
        _nowPlayingPage.BackColor = BackColor;
        var page = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 6,
            // Add a deliberate top breathing room so the artwork and the
            // track/status stack sit lower beneath the tabs. The output strip
            // stays anchored at the bottom because the flexible spacer row
            // absorbs the lost height.
            Padding = new Padding(20, 24, 20, 0),
            BackColor = BackColor
        };
        // Keep the artwork slightly larger than the original layout while
        // tightening the vertical hero so the title through Exclusive status
        // are not pushed too far down.
        // Match the artwork column exactly so PictureBox.Zoom never creates
        // horizontal letterboxing around a square album cover.
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 180));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 56));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
        page.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, PlaybackOutputFrameHeight));

        var artworkRow = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 3,
            RowCount = 1,
            Margin = new Padding(0),
            BackColor = BackColor
        };
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 180));
        artworkRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        _artwork.Dock = DockStyle.Fill;
        _artwork.Margin = new Padding(4);
        _artwork.SizeMode = PictureBoxSizeMode.Zoom;
        _artwork.BackColor = Color.FromArgb(31, 42, 44);
        _artwork.Image = CreatePlaceholderArtwork();
        RoundedUi.ApplyRegion(_artwork, 8);
        artworkRow.Controls.Add(_artwork, 1, 0);

        ConfigureInfoLabel(_trackTitle, "Waiting for Amazon Music", 14.5F, Color.FromArgb(242, 247, 246), true);
        ConfigureInfoLabel(_trackArtist, "Start playback to show track information", 10F, Color.FromArgb(145, 164, 164), false);
        ConfigureInfoLabel(_trackFormat, "—", 21F, Color.FromArgb(168, 240, 233), true);
        ConfigureInfoLabel(_statusDetail, "Ready", 9F, Color.FromArgb(155, 180, 178), false);
        foreach (var label in new[] { _trackTitle, _trackArtist, _trackFormat, _statusDetail })
            label.TextAlign = ContentAlignment.MiddleCenter;

        var controls = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 3,
            RowCount = 3,
            Padding = new Padding(12, PlaybackOutputTopPadding, 12, 0),
            Margin = new Padding(0),
            BackColor = Color.FromArgb(34, 42, 44)
        };
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 56));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22));
        controls.RowStyles.Add(new RowStyle(SizeType.Absolute, PlaybackOutputLabelHeight));
        controls.RowStyles.Add(new RowStyle(SizeType.Absolute, PlaybackOutputActionHeight));
        controls.RowStyles.Add(new RowStyle(SizeType.Absolute, PlaybackOutputBottomSpacing));
        var outputLabel = SmallCaption("OUTPUT PATH");
        _mode.Text = "Exclusive mode → HiFi Cable";
        _mode.Dock = DockStyle.Fill;
        _mode.TextAlign = ContentAlignment.MiddleLeft;
        _mode.Padding = new Padding(8, 0, 8, 0);
        _mode.Margin = new Padding(0);
        _mode.BackColor = Color.FromArgb(43, 53, 55);
        _mode.ForeColor = Color.White;
        _mode.Font = new Font("Segoe UI", 9F, FontStyle.Regular);
        RoundedUi.ApplyRegion(_mode, 6);
        ConfigureActionButton(_start, "START", Color.FromArgb(42, 157, 148), StartClicked);
        ConfigureActionButton(_stop, "STOP", Color.FromArgb(71, 73, 84), StopClicked);
        _start.Dock = DockStyle.None;
        _stop.Dock = DockStyle.None;
        _start.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        _stop.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        _start.Margin = new Padding(6, 0, 0, 0);
        _stop.Margin = new Padding(6, 0, 0, 0);
        controls.Controls.Add(outputLabel, 0, 0);
        controls.SetColumnSpan(outputLabel, 3);
        controls.Controls.Add(_mode, 0, 1);
        controls.Controls.Add(_start, 1, 1);
        controls.Controls.Add(_stop, 2, 1);

        RoundedUi.ApplyRegion(controls, 8);
        controls.Layout += (_, _) => SyncPlaybackActionHeights();

        page.Controls.Add(artworkRow, 0, 0);
        page.Controls.Add(_trackTitle, 0, 1);
        page.Controls.Add(_trackArtist, 0, 2);
        page.Controls.Add(_trackFormat, 0, 3);
        page.Controls.Add(_statusDetail, 0, 4);
        page.Controls.Add(controls, 0, 6);
        _nowPlayingPage.Controls.Add(page);
    }

    private void SyncPlaybackActionHeights()
    {
        // The output label fills the complete action row. Use that row height,
        // rather than the label's one-line preferred height, so START and STOP
        // cannot collapse to half-height at 125%/150%/225% DPI.
        var targetHeight = _mode.Height > 0 ? _mode.Height : _mode.PreferredHeight;
        if (targetHeight <= 0)
            return;

        // Pin the adjacent actions to the same height and top edge so every
        // Windows DPI setting renders one compact, aligned row.
        _start.AutoSize = false;
        _stop.AutoSize = false;
        _start.MinimumSize = new Size(0, targetHeight);
        _start.MaximumSize = new Size(0, targetHeight);
        _stop.MinimumSize = new Size(0, targetHeight);
        _stop.MaximumSize = new Size(0, targetHeight);
        _start.Height = targetHeight;
        _stop.Height = targetHeight;
        _start.Top = _mode.Top;
        _stop.Top = _mode.Top;
    }

    private void SyncAllActionHeights()
    {
        SyncPlaybackActionHeights();

        var targetHeight = _testTracks.PreferredHeight;
        if (targetHeight <= 0)
            return;

        // NumericUpDown keeps AutoSize enabled by default and ignores the
        // height of a taller TableLayout cell. Use its native preferred height
        // as the shared row height so Tracks, RUN TEST and STOP line up.
        _testTracks.AutoSize = false;
        _autoTest.AutoSize = false;
        _testStop.AutoSize = false;
        _testTracks.MinimumSize = new Size(0, targetHeight);
        _testTracks.MaximumSize = new Size(0, targetHeight);
        _autoTest.MinimumSize = new Size(0, targetHeight);
        _autoTest.MaximumSize = new Size(0, targetHeight);
        _testStop.MinimumSize = new Size(0, targetHeight);
        _testStop.MaximumSize = new Size(0, targetHeight);
        _testTracks.Height = targetHeight;
        _autoTest.Height = targetHeight;
        _testStop.Height = targetHeight;
        _testTracks.Top = _autoTest.Top;
        _testStop.Top = _autoTest.Top;
    }

    private static void ConfigureInfoLabel(Label label, string text, float size, Color color, bool bold)
    {
        label.Text = text;
        label.Dock = DockStyle.Fill;
        label.TextAlign = ContentAlignment.MiddleLeft;
        label.AutoEllipsis = true;
        label.Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        label.ForeColor = color;
        label.Margin = new Padding(0);
    }

    private void BuildAutoTestPage()
    {
        _autoTestPage.Dock = DockStyle.Fill;
        _autoTestPage.BackColor = BackColor;
        var page = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 7,
            Padding = new Padding(24, 20, 24, 20),
            BackColor = BackColor
        };
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        // Leave the flexible space above the result/output frame so it sits at
        // the bottom of TEST & Config instead of floating in the middle.
        page.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        page.RowStyles.Add(new RowStyle(SizeType.Absolute, 180));
        var title = new Label
        {
            Text = "Queue verification",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Font = new Font("Segoe UI Semibold", 18F, FontStyle.Bold),
            ForeColor = Color.FromArgb(242, 243, 247)
        };
        var description = new Label
        {
            Text = "Test track switching and output format.",
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", 10F),
            ForeColor = Color.FromArgb(145, 150, 164)
        };
        _testMode.Text = "Output: Exclusive mode → HiFi Cable";
        _testMode.Dock = DockStyle.Fill;
        _testMode.ForeColor = Color.FromArgb(168, 240, 233);
        _testMode.Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold);

        var testControls = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 4,
            RowCount = 1,
            Padding = new Padding(0, 4, 0, 4),
            Margin = new Padding(0),
            BackColor = BackColor
        };
        // Keep the four controls in a predictable grid.
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 24));
        testControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 26));
        _testTracks.Minimum = 1;
        _testTracks.Maximum = 999;
        _testTracks.Value = 10;
        _testTracks.Dock = DockStyle.Fill;
        _testTracks.Margin = new Padding(5, 2, 5, 2);
        _testTracks.BackColor = Color.FromArgb(43, 53, 55);
        _testTracks.ForeColor = Color.White;
        _testTracks.TextAlign = HorizontalAlignment.Center;
        ConfigureActionButton(_autoTest, "START", Color.FromArgb(42, 157, 148), AutoTestClicked);
        ConfigureActionButton(_testStop, "STOP", Color.FromArgb(71, 73, 84), StopClicked);
        testControls.Controls.Add(new Label
        {
            Text = "Tracks",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = Color.FromArgb(200, 202, 210),
            Padding = new Padding(0, 0, 0, 8),
            // Match the vertical inset used by NumericUpDown and the action
            // buttons so the label's text sits on the same visual row.
            Margin = new Padding(5, 2, 5, 2)
        }, 0, 0);
        testControls.Controls.Add(_testTracks, 1, 0);
        testControls.Controls.Add(_autoTest, 2, 0);
        testControls.Controls.Add(_testStop, 3, 0);

        _testSummary.Text = "Choose the track count, then click START.";
        _testSummary.Dock = DockStyle.Fill;
        _testSummary.Padding = new Padding(16);
        _testSummary.BackColor = Color.FromArgb(38, 40, 48);
        _testSummary.ForeColor = Color.FromArgb(176, 180, 191);
        _testSummary.Font = new Font("Segoe UI", 9.5F);
        RoundedUi.ApplyRegion(_testSummary, 8);

        page.Controls.Add(title, 0, 0);
        page.Controls.Add(description, 0, 1);
        page.Controls.Add(_testMode, 0, 2);
        page.Controls.Add(testControls, 0, 3);
        page.Controls.Add(_testSummary, 0, 5);
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
        button.UseMnemonic = false;
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
        button.Height = 30;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.UseMnemonic = false;
        button.BackColor = Color.Transparent;
        button.ForeColor = Color.FromArgb(130, 134, 147);
        button.Font = new Font("Segoe UI Semibold", 8.5F, FontStyle.Bold);
        // Leave a couple of scaled pixels inside the navigation row so the
        // selected tab's bottom stroke cannot be clipped by FlowLayoutPanel.
        button.Margin = new Padding(3, 2, 3, 2);
        button.TabStop = false;
        button.Click += handler;
    }

    private static void StyleSelectedTab(TabButton button, bool selected)
    {
        button.Selected = selected;
        button.ForeColor = selected ? Color.FromArgb(168, 240, 233) : Color.FromArgb(130, 151, 151);
        button.BackColor = selected ? Color.FromArgb(29, 57, 59) : Color.Transparent;
        button.Invalidate();
    }

    private bool IsRunning
    {
        get
        {
            lock (_processGate)
                return _backend is { HasExited: false };
        }
    }

    private static OutputMode SelectedMode => OutputMode.AsioExclusive;

    private static string ModeName(OutputMode mode) => mode switch
    {
        _ => "ASIO+EXCLUSIVE"
    };

    private void SetRunning(bool running)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => SetRunning(running)));
            return;
        }

        _testTracks.Enabled = !running;
        _start.Enabled = !running;
        _autoTest.Enabled = !running;
        _stop.Enabled = running;
        _testStop.Enabled = running;
        if (running)
        {
            _status.Text = $"RUNNING · {ModeName(SelectedMode)}";
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
        AppendLog($"Starting {(autoTest ? "AutoTest" : "monitor")} in {ModeName(mode)} mode...");

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
            _isAsioSession = true;
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
            args.Add("-AsioExclusive");

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
        const string exclusivePrefix = "@@AMRS_EXCLUSIVE@@";
        if (text.StartsWith(exclusivePrefix, StringComparison.Ordinal))
        {
            var active = string.Equals(text[exclusivePrefix.Length..], "ON", StringComparison.OrdinalIgnoreCase);
            if (SelectedMode == OutputMode.AsioExclusive)
                SetExclusiveStatus(active);
            return;
        }

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

    private void SetExclusiveStatus(bool active)
    {
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action(() => SetExclusiveStatus(active))); } catch (InvalidOperationException) { }
            return;
        }

        _statusDetail.Text = active
            ? "Amazon WASAPI Exclusive is active"
            : "Amazon Exclusive is not active";
        _statusDetail.ForeColor = active
            ? Color.FromArgb(93, 205, 137)
            : Color.FromArgb(240, 112, 112);
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

    private async Task LoadArtworkAsync(string artworkUrl, bool retryAfterFailure = true)
    {
        var requestVersion = Interlocked.Increment(ref _artworkRequestVersion);
        if (string.IsNullOrWhiteSpace(artworkUrl))
        {
            SetArtwork(CreatePlaceholderArtwork(), requestVersion);
            return;
        }

        // Amazon can expose the same cover through a WebP transform, a resized
        // JPEG transform, or the alternate image CDN host. Try the inexpensive
        // JPEG variants before leaving the new track on the placeholder.
        foreach (var candidate in BuildArtworkCandidates(artworkUrl))
        {
            for (var attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    var bytes = await ArtworkClient.GetByteArrayAsync(candidate, _lifetime.Token);
                    using var stream = new MemoryStream(bytes);
                    using var source = Image.FromStream(stream);
                    SetArtwork(new Bitmap(source), requestVersion);
                    return;
                }
                catch when (attempt == 0 && !_lifetime.IsCancellationRequested)
                {
                    await Task.Delay(250, _lifetime.Token);
                }
                catch
                {
                    break;
                }
            }
        }

        // Keep the current image. A later CDP snapshot can publish a refreshed
        // artwork URL without making the cover flash back to a placeholder.
        // Also give a transient CDN failure one delayed retry; the retry is
        // cancelled automatically when another track increments the request
        // version.
        if (retryAfterFailure && requestVersion == _artworkRequestVersion && !_lifetime.IsCancellationRequested)
        {
            try { await Task.Delay(1000, _lifetime.Token); }
            catch { return; }
            if (requestVersion == _artworkRequestVersion && !_lifetime.IsCancellationRequested)
                _ = LoadArtworkAsync(artworkUrl, false);
        }
    }

    private static IReadOnlyList<string> BuildArtworkCandidates(string artworkUrl)
    {
        var candidates = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string? value)
        {
            if (string.IsNullOrWhiteSpace(value) ||
                !Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
                (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
                return;
            var normalized = NormalizeArtworkUrl(uri.ToString());
            if (seen.Add(normalized))
                candidates.Add(normalized);
        }

        Add(artworkUrl);
        if (!Uri.TryCreate(artworkUrl, UriKind.Absolute, out var sourceUri))
            return candidates;

        var basePath = Regex.Replace(
            sourceUri.AbsolutePath,
            @"\._[^/]+(?=\.[^./]+$)",
            string.Empty,
            RegexOptions.IgnoreCase);
        if (!string.Equals(basePath, sourceUri.AbsolutePath, StringComparison.Ordinal))
        {
            var builder = new UriBuilder(sourceUri) { Path = basePath };
            Add(builder.Uri.ToString());
        }

        if (string.Equals(sourceUri.Host, "m.media-amazon.com", StringComparison.OrdinalIgnoreCase))
        {
            var builder = new UriBuilder(sourceUri) { Host = "images-na.ssl-images-amazon.com" };
            Add(builder.Uri.ToString());
        }

        return candidates;
    }

    private static string NormalizeArtworkUrl(string artworkUrl)
    {
        // Amazon frequently labels a WebP response as a .jpg URL by inserting
        // _FMwebp_ in the image transform. System.Drawing cannot decode WebP;
        // the equivalent _SX..._ URL returns an actual JPEG from the same CDN.
        var normalized = Regex.Replace(artworkUrl, "_FMwebp_", "_", RegexOptions.IgnoreCase);
        return Regex.Replace(normalized, @"\.webp(?=$|[?#])", ".jpg", RegexOptions.IgnoreCase);
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
            Color.FromArgb(35, 67, 69),
            Color.FromArgb(20, 28, 31),
            45F);
        graphics.FillRectangle(background, 0, 0, bitmap.Width, bitmap.Height);
        using var glow = new SolidBrush(Color.FromArgb(68, 51, 190, 181));
        graphics.FillEllipse(glow, 105, 115, 350, 350);
        using var bar = new SolidBrush(Color.FromArgb(220, 205, 247, 241));
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
            _status.ForeColor = Color.FromArgb(112, 224, 211);
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
