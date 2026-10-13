using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Asenaizer Setup: the windowed face of the install. It collects the choices, runs install.ps1 (embedded in this
// exe) hidden with ASZ_DRIVER, and shows its phases and setup.ps1's steps. The install itself lives in one place:
// install.ps1 + installer\setup.ps1, the same path as the one-line install. Asenaizer installs per user, so there
// is no permission prompt anywhere on this path.
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // --shots <folder>: every page drawn to a PNG (CI looks at them; nothing is installed)
        if (args.Length == 2 && args[0] == "--shots") { SetupForm.Shots(args[1]); return; }
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new SetupForm());
    }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}

sealed class SetupForm : Form
{
    // ---------------------------------------------------------------- texts (Turkish / English)
    // Asenaizer's interface is English only; the Turkish texts stay so a language switch is one line.
    bool tr = false;
    string T(string turkish, string english) { return tr ? turkish : english; }

    // ---------------------------------------------------------------- choices
    bool startup = true, desktop = false, launch = true;

    // ---------------------------------------------------------------- install state
    enum Page { Options, Progress, Result }
    Page page = Page.Options;
    string work, phase = "", version = "", setupProgress;
    int downloadPercent; long downloadDone, downloadTotal;
    double downloadSpeed; // bytes per second, measured here from "done" over time
    readonly List<KeyValuePair<DateTime, long>> speedSamples = new List<KeyValuePair<DateTime, long>>();
    string[] steps = new string[0];
    int stepN; string stepState = "running"; int stepPercent; string stepFile;
    string resultTitle, resultBody, resultDetail, resultLog, warnTitle, warnBody;
    string[] warn = new string[0];
    bool resultOk, cancelRequested;
    Process proc;
    readonly Timer timer = new Timer { Interval = 50 };
    int tick;
    DateTime slideStart = DateTime.UtcNow;

    // ---------------------------------------------------------------- drawing
    float k = 1f; // DIPs -> pixels
    // the warm dark theme of the Asenaizer site (docs/style.css)
    static readonly Color Bg = Hex("#0f0d0b"), Surface = Hex("#181512"), Surface2 = Hex("#221e1a"), Outline = Hex("#43392f"),
        Fg = Hex("#f4eee4"), Sub = Hex("#c9bfb1"), Dim = Hex("#8e8478"), Ok = Hex("#5fd39a"), Err = Hex("#ff8a7d"),
        WarnTone = Hex("#ffb77c"), Accent = Hex("#a48bff"), AccentHover = Hex("#b6a1ff"), OnAccent = Hex("#120d24");
    readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();
    sealed class Hit { public RectangleF Rect; public string Id; public Action Click; }
    readonly List<Hit> hits = new List<Hit>();
    string hover;
    Image mark; int markPx; // the app icon in the header, picked from the frame that fits the current scale

    const float W = 760, H = 540;
    const float MarkSize = 24;
    const double SlideMs = 220;
    const double SpeedWindowSec = 3.0, SpeedMinSpanSec = 0.5;

    public SetupForm()
    {
        Text = "Asenaizer Setup";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Bg;
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        try { this.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        timer.Tick += (s, e) => OnTick();
        timer.Start();
    }

    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ClassStyle |= 0x20000; /* CS_DROPSHADOW */ return cp; }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        k = DeviceDpi / 96f;
        ClientSize = new Size((int)(W * k), (int)(H * k));
        CenterToScreen();
        // Windows 11: rounded corners and the dark frame; Windows 10 ignores both
        int round = 2, dark = 1;
        DwmSetWindowAttribute(Handle, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, 4);
        DwmSetWindowAttribute(Handle, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref dark, 4);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x02E0 /* WM_DPICHANGED */)
        {
            k = (m.WParam.ToInt32() & 0xFFFF) / 96f;
            ClearFonts();
            var r = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
            SetBounds(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            Invalidate();
            return;
        }
        base.WndProc(ref m);
    }

    // ---------------------------------------------------------------- pages

    protected override void OnPaint(PaintEventArgs e)
    {
        Render(e.Graphics);
    }

    void Render(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Bg);
        hits.Clear();
        g.ScaleTransform(k, k);

        // header: icon, name, step dots, close
        DrawMark(g, 18, 18);
        Str(g, "Asenaizer", F(15, true), Fg, 50, 19, 300, 24);
        int dot = page == Page.Options ? 0 : page == Page.Progress ? 1 : 2;
        for (int i = 0; i < 3; i++) FillRound(g, i == dot ? Accent : Outline, W - 140 + i * 18, 26, i == dot ? 22 : 8, 8, 4);
        var close = new RectangleF(W - 52, 14, 36, 32);
        if (hover == "close") FillRound(g, Surface2, close.X, close.Y, close.Width, close.Height, 10);
        Glyph(g, "close", close, Sub);
        AddHit(close, "close", CloseClicked);

        // the page slides in from the right
        float t = (float)Math.Min(1.0, (DateTime.UtcNow - slideStart).TotalMilliseconds / SlideMs);
        float off = 28 * (1 - (1 - (1 - t) * (1 - t)));
        g.TranslateTransform(off, 0);
        if (page == Page.Options) PaintOptions(g);
        else if (page == Page.Progress) PaintProgress(g);
        else PaintResult(g);
        g.ResetTransform();
    }

    void DrawMark(Graphics g, float x, float y)
    {
        int want = (int)Math.Ceiling(MarkSize * k);
        if (mark == null || markPx != want)
        {
            if (mark != null) mark.Dispose();
            mark = LoadMark(want);
            markPx = want;
        }
        if (mark == null) { FillCircle(g, Accent, x + MarkSize / 2, y + MarkSize / 2, 6); return; }
        var oldMode = g.InterpolationMode;
        var oldOffset = g.PixelOffsetMode;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.DrawImage(mark, new RectangleF(x, y, MarkSize, MarkSize));
        g.InterpolationMode = oldMode;
        g.PixelOffsetMode = oldOffset;
    }

    void PaintOptions(Graphics g)
    {
        Str(g, T("Asenaizer'ı kur", "Install Asenaizer"), F(24, true), Fg, 40, 82, 680, 36);
        StrWrap(g, T("Taslaklarını tarayıcında, bu bilgisayarın ekran kartında çalışan bir modelle yeniden yaz.",
            "Rewrite drafts in your browser with a model that runs on this computer's GPU."), F(13), Sub, 40, 120, 680, 44);

        float y = 186;
        Str(g, T("Seçenekler", "Options"), F(13, true), Sub, 40, y, 300, 20);
        Toggle(g, "startup", T("Oturum açtığımda Asenaizer'ı başlat", "Start Asenaizer when I sign in"), 40, y + 30, startup, () => { startup = !startup; Invalidate(); });
        Toggle(g, "desktop", T("Masaüstüne kısayol ekle", "Add a desktop shortcut"), 40, y + 70, desktop, () => { desktop = !desktop; Invalidate(); });
        Toggle(g, "launch", T("Kurulum bitince Asenaizer'ı aç", "Open Asenaizer when setup finishes"), 40, y + 110, launch, () => { launch = !launch; Invalidate(); });

        Str(g, T("Yalnızca senin hesabına kurulur.", "Installs for your account only."), F(12), Dim, 40, H - 60, 480, 20);
        Button(g, "install", T("Kur", "Install"), W - 40 - 160, H - 72, 160, true, StartInstall);
    }

    void PaintProgress(Graphics g)
    {
        bool rollingBack = cancelRequested || stepState == "rollback";
        Str(g, rollingBack ? T("Geri alınıyor…", "Rolling back…") : T("Kuruluyor", "Installing"), F(24, true), Fg, 40, 82, 600, 36);
        if (version.Length > 0)
        {
            string v = char.IsDigit(version[0]) ? "v" + version : version;
            Str(g, "Asenaizer " + v, F(13), Sub, 40, 120, 600, 22);
        }
        float y = 156;
        if (steps.Length == 0)
        {
            // before setup.ps1: install.ps1's own phases
            string[] ids = { "release", "download", "verify", "extract", "stop" };
            string[] labels =
            {
                T("Son sürüm aranıyor", "Finding the latest release"), T("İndiriliyor", "Downloading"), T("Doğrulanıyor", "Verifying"),
                T("Açılıyor", "Extracting"), T("Asenaizer durduruluyor", "Stopping Asenaizer"),
            };
            int cur = Array.IndexOf(ids, phase);
            for (int i = 0; i < ids.Length; i++)
            {
                if (i > cur + 1 && i >= 4) break; // stop shows up when it can happen
                StepRow(g, y, labels[i], i < cur ? 2 : i == cur ? 1 : 0);
                if (i == cur && phase == "download")
                {
                    ProgressBar(g, 76, y + 30, 360, downloadPercent / 100f);
                    Str(g, DownloadText(), F(12), Dim, 450, y + 22, 290, 20);
                    y += 26;
                }
                y += 34;
            }
        }
        else
        {
            StepRow(g, y, T("Hazırlık", "Preparation"), 2);
            y += 30;
            for (int i = 0; i < steps.Length; i++)
            {
                int state = i + 1 < stepN || stepState == "done" ? 2 : i + 1 == stepN ? (stepState == "error" ? 3 : 1) : 0;
                StepRow(g, y, steps[i], state);
                if (state == 1)
                {
                    ProgressBar(g, 76, y + 26, 420, Math.Max(0, Math.Min(99, stepPercent)) / 100f);
                    if (!string.IsNullOrEmpty(stepFile)) Str(g, stepFile, F(11.5f), Dim, 510, y + 18, 220, 20);
                    y += 18;
                }
                y += 24;
            }
        }
        if (!cancelRequested) Button(g, "cancel", T("İptal", "Cancel"), W - 40 - 120, H - 72, 120, false, RequestCancel);
    }

    // "42%   14.0 / 33.0 MB · 5.2 MB/s"
    string DownloadText()
    {
        string s = downloadPercent + "%";
        if (downloadTotal > 0) s += string.Format("   {0:0.0} / {1:0.0} MB", downloadDone / 1048576.0, downloadTotal / 1048576.0);
        if (downloadSpeed > 0) s += string.Format(" · {0:0.0} MB/s", downloadSpeed / 1048576.0);
        return s;
    }

    void PaintResult(Graphics g)
    {
        var tone = resultOk ? Ok : Err;
        FillCircle(g, Mix(Bg, tone, 0.18f), 72, 118, 32);
        Glyph(g, resultOk ? "check" : "close", new RectangleF(52, 98, 40, 40), tone);
        Str(g, resultTitle ?? "", F(22, true), Fg, 120, 100, 600, 34);
        float y = 170;
        y = StrWrap(g, resultBody ?? "", F(13), Sub, 40, y, 680, 220) + 12;
        if (!string.IsNullOrEmpty(resultDetail)) y = StrWrap(g, resultDetail, F(12), Dim, 40, y, 680, 60) + 8;
        if (warn.Length > 0)
        {
            FillRound(g, Mix(Surface, WarnTone, 0.12f), 40, y, 680, 30 + warn.Length * 22 + 26, 16);
            Str(g, warnTitle ?? "", F(13, true), WarnTone, 56, y + 10, 640, 20);
            for (int i = 0; i < warn.Length; i++) Str(g, "•  " + warn[i], F(12.5f), Fg, 56, y + 34 + i * 22, 640, 20);
            StrWrap(g, warnBody ?? "", F(12), Dim, 56, y + 34 + warn.Length * 22, 640, 30);
        }
        if (!string.IsNullOrEmpty(resultLog)) Str(g, resultLog, F(11.5f), Dim, 40, H - 100, 560, 18);
        Button(g, "done", T("Kapat", "Close"), W - 40 - 140, H - 72, 140, true, Close);
    }

    // ---------------------------------------------------------------- controls (drawn)

    void Button(Graphics g, string id, string label, float x, float y, float w, bool primary, Action click)
    {
        bool hot = hover == id;
        var bg = primary ? (hot ? AccentHover : Accent) : (hot ? Surface2 : Surface);
        FillRound(g, bg, x, y, w, 44, 22);
        StrCenter(g, label, F(14, true), primary ? OnAccent : Fg, new RectangleF(x, y, w, 44));
        AddHit(new RectangleF(x, y, w, 44), id, click);
    }

    void Toggle(Graphics g, string id, string label, float x, float y, bool on, Action click)
    {
        var row = new RectangleF(x, y, 680, 30);
        if (hover == id) FillRound(g, Surface, row.X - 8, row.Y - 2, row.Width + 16, row.Height + 4, 12);
        FillRound(g, on ? Accent : Surface2, x, y + 4, 40, 22, 11);
        if (!on) DrawRound(g, Outline, 1.2f, x + 0.6f, y + 4.6f, 38.8f, 20.8f, 10.4f);
        FillCircle(g, on ? OnAccent : Dim, on ? x + 29 : x + 11, y + 15, on ? 8 : 6);
        Str(g, label, F(13), on ? Fg : Sub, x + 54, y + 4, 600, 22);
        AddHit(row, id, click);
    }

    // state: 0 pending, 1 running, 2 done, 3 failed
    void StepRow(Graphics g, float y, string label, int state)
    {
        float cx = 56, cy = y + 11;
        if (state == 2) { FillCircle(g, Mix(Bg, Ok, 0.22f), cx, cy, 10); Glyph(g, "check", new RectangleF(cx - 8, cy - 8, 16, 16), Ok); }
        else if (state == 3) { FillCircle(g, Mix(Bg, Err, 0.22f), cx, cy, 10); Glyph(g, "close", new RectangleF(cx - 8, cy - 8, 16, 16), Err); }
        else if (state == 1)
        {
            using (var p = new Pen(Accent, 2.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawArc(p, cx - 8, cy - 8, 16, 16, (tick * 18) % 360, 260);
        }
        else FillCircle(g, Outline, cx, cy, 3);
        Str(g, label, F(13, state == 1), state == 0 ? Dim : Fg, 76, y, 600, 22);
    }

    void ProgressBar(Graphics g, float x, float y, float w, float frac)
    {
        FillRound(g, Surface2, x, y, w, 6, 3);
        float fw = Math.Max(6, w * Math.Max(0, Math.Min(1, frac)));
        FillRound(g, Accent, x, y, fw, 6, 3);
    }

    // ---------------------------------------------------------------- input

    void AddHit(RectangleF r, string id, Action click) { hits.Add(new Hit { Rect = r, Id = id, Click = click }); }

    Hit HitAt(Point p)
    {
        float x = p.X / k, y = p.Y / k;
        for (int i = hits.Count - 1; i >= 0; i--) if (hits[i].Rect.Contains(x, y)) return hits[i];
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var h = HitAt(e.Location);
        string id = h == null ? null : h.Id;
        Cursor = h == null ? Cursors.Default : Cursors.Hand;
        if (id != hover) { hover = id; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (hover != null) { hover = null; Invalidate(); }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        var h = HitAt(e.Location);
        if (h != null) { h.Click(); return; }
        // anywhere else moves the window
        ReleaseCapture();
        SendMessage(Handle, 0xA1 /* WM_NCLBUTTONDOWN */, (IntPtr)2 /* HTCAPTION */, IntPtr.Zero);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { CloseClicked(); return true; }
        if (keyData == Keys.Enter)
        {
            if (page == Page.Options) StartInstall();
            else if (page == Page.Result) Close();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void Go(Page p)
    {
        page = p;
        slideStart = DateTime.UtcNow;
        hover = null;
        StartFrames();
    }

    // The page slide is drawn on the compositor's frame clock: the 50 ms form timer gave it four or five frames and
    // Invalidate() waited behind every other message, so page changes moved in jumps. Each frame paints at once
    // (Refresh) and then waits for the next composition pass (DwmFlush, the display's refresh); the message loop runs
    // between frames, so clicks and keys stay live.
    bool animating;
    void StartFrames()
    {
        if (animating) { Invalidate(); return; }
        animating = true;
        BeginInvoke((Action)Frame);
    }

    void Frame()
    {
        if (IsDisposed) return;
        Refresh();
        if ((DateTime.UtcNow - slideStart).TotalMilliseconds >= SlideMs + 20) { animating = false; return; }
        if (DwmFlush() != 0) System.Threading.Thread.Sleep(8); // composition off: about the same pace
        BeginInvoke((Action)Frame);
    }

    void CloseClicked()
    {
        if (page == Page.Progress) RequestCancel();
        else Close();
    }

    // ---------------------------------------------------------------- the install

    void StartInstall()
    {
        if (proc != null) return; // Enter pressed twice
        try
        {
            work = Path.Combine(Path.GetTempPath(), "asz-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(work);
            string script = Path.Combine(work, "install.ps1");
            using (var res = typeof(Program).Assembly.GetManifestResourceStream("install.ps1"))
            {
                if (res == null) throw new InvalidOperationException("install.ps1 is missing from this setup file.");
                using (var file = File.Create(script)) res.CopyTo(file);
            }
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = work,
            };
            // the environment is inherited (ASZ_PREVIEW / ASZ_SOURCE pass through); the choices are always set here
            psi.EnvironmentVariables["ASZ_DRIVER"] = work;
            Flag(psi, "ASZ_NO_STARTUP", !startup);
            Flag(psi, "ASZ_DESKTOP", desktop);
            Flag(psi, "ASZ_NO_LAUNCH", !launch);
            proc = Process.Start(psi);
            phase = "release";
            Go(Page.Progress);
        }
        catch (Exception ex)
        {
            Finish(false, T("Kurulum başlatılamadı", "Setup could not start"), ex.Message, null, null);
        }
    }

    static void Flag(ProcessStartInfo psi, string name, bool on)
    {
        if (on) psi.EnvironmentVariables[name] = "1";
        else psi.EnvironmentVariables.Remove(name);
    }

    void RequestCancel()
    {
        if (cancelRequested || work == null) return;
        cancelRequested = true;
        try { File.WriteAllText(Path.Combine(work, "cancel"), ""); } catch { }
        Invalidate();
    }

    void OnTick()
    {
        tick++;
        if (page == Page.Progress && tick % 2 == 0) Poll();
        // the slide has its own frames (Frame)
        if (page == Page.Progress && !animating) Invalidate();
    }

    void Poll()
    {
        var st = ReadJson(Path.Combine(work, "status.json"));
        if (st != null)
        {
            phase = Str(st, "phase") ?? phase;
            version = Str(st, "version") ?? version;
            downloadPercent = Int(st, "percent", downloadPercent);
            downloadDone = Long(st, "done", downloadDone);
            downloadTotal = Long(st, "total", downloadTotal);
            setupProgress = Str(st, "progress") ?? setupProgress;
            var s = Strings(st, "steps");
            if (s.Length > 0) steps = s;
            if (phase == "done" || phase == "error" || phase == "cancelled")
            {
                warnTitle = Str(st, "warnTitle");
                warnBody = Str(st, "warnBody");
                warn = Strings(st, "warn");
                resultLog = Str(st, "log");
                Finish(phase == "done", Str(st, "title") ?? (phase == "done" ? T("Kurulum tamamlandı", "Installed") : T("Kurulum yapılamadı", "Setup failed")),
                    Str(st, "body") ?? Str(st, "message"), Str(st, "detail"), resultLog);
                return;
            }
        }
        SampleSpeed();
        if (setupProgress != null)
        {
            var p = ReadJson(setupProgress);
            if (p != null)
            {
                stepN = Int(p, "n", stepN);
                stepState = Str(p, "state") ?? stepState;
                stepPercent = Int(p, "percent", stepPercent);
                stepFile = Str(p, "file");
            }
        }
        // the script ended without a result (it was killed, or PowerShell itself failed)
        if (proc != null && proc.HasExited && (st == null || st.Count == 0 || !IsFinal(Str(st, "phase"))))
        {
            System.Threading.Thread.Sleep(150);
            st = ReadJson(Path.Combine(work, "status.json"));
            if (st == null || !IsFinal(Str(st, "phase")))
                Finish(false, T("Kurulum beklenmedik şekilde durdu", "Setup stopped unexpectedly"),
                    T("Hiçbir şey yarım kalmadı; yeniden deneyebilirsin.", "Nothing was left half-done; you can try again."), "exit " + proc.ExitCode, null);
        }
    }

    // Download speed over the last few seconds of "done" samples (one per poll), so it stays steady even when
    // install.ps1 reports in bursts. A restarted download (done goes down) starts the window again.
    void SampleSpeed()
    {
        if (phase != "download") { speedSamples.Clear(); downloadSpeed = 0; return; }
        var now = DateTime.UtcNow;
        if (speedSamples.Count > 0 && downloadDone < speedSamples[speedSamples.Count - 1].Value) { speedSamples.Clear(); downloadSpeed = 0; }
        speedSamples.Add(new KeyValuePair<DateTime, long>(now, downloadDone));
        while (speedSamples.Count > 2 && (now - speedSamples[0].Key).TotalSeconds > SpeedWindowSec) speedSamples.RemoveAt(0);
        var first = speedSamples[0];
        double span = (now - first.Key).TotalSeconds;
        if (span >= SpeedMinSpanSec) downloadSpeed = Math.Max(0, (downloadDone - first.Value) / span);
    }

    static bool IsFinal(string phase) { return phase == "done" || phase == "error" || phase == "cancelled"; }

    void Finish(bool ok, string title, string body, string detail, string log)
    {
        resultOk = ok;
        resultTitle = title;
        resultBody = body;
        resultDetail = detail;
        resultLog = log;
        Go(Page.Result);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // still installing (closed from the taskbar): ask the install to roll back first
        if (page == Page.Progress && proc != null && !proc.HasExited)
        {
            RequestCancel();
            e.Cancel = true;
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Stop();
        try { if (work != null) Directory.Delete(work, true); } catch { }
        base.OnFormClosed(e);
    }

    // ---------------------------------------------------------------- screenshots (CI)

    public static void Shots(string dir)
    {
        Directory.CreateDirectory(dir);
        foreach (bool turkish in new[] { false }) // English only, like the app
        {
            string lang = turkish ? "tr" : "en";
            Shot(dir, lang + "-1-options", turkish, f => { });
            Shot(dir, lang + "-2-download", turkish, f =>
            {
                f.page = Page.Progress; f.phase = "download"; f.version = "v0.1.0";
                f.downloadPercent = 42; f.downloadDone = 96L << 20; f.downloadTotal = 228L << 20; f.downloadSpeed = 12.4 * 1048576;
            });
            Shot(dir, lang + "-3-setup", turkish, f =>
            {
                f.page = Page.Progress; f.phase = "setup"; f.version = "v0.1.0"; f.stepN = 4; f.stepPercent = 63; f.stepFile = @"app\asenaizer-tray.exe";
                f.steps = turkish
                    ? new[] { "Windows denetleniyor", "Gerekli bileşenler", "Asenaizer durduruluyor", "Dosyalar kopyalanıyor", "Kısayollar", "Oturum açılışında başlatma", "Windows'a kaydediliyor" }
                    : new[] { "Checking Windows", "Required components", "Stopping Asenaizer", "Copying files", "Shortcuts", "Start at sign-in", "Registering with Windows" };
            });
            Shot(dir, lang + "-4-done", turkish, f =>
            {
                f.page = Page.Result; f.resultOk = true;
                f.resultTitle = turkish ? "Kurulum tamamlandı" : "All set";
                f.resultBody = turkish
                    ? "Asenaizer çalışıyor; simgesi saatin yanında, bildirim alanında.\n\nKonum: %LOCALAPPDATA%\\Programs\\Asenaizer"
                    : "Asenaizer is running; its icon is in the tray, next to the clock.\n\nLocation: %LOCALAPPDATA%\\Programs\\Asenaizer";
                f.warnTitle = turkish ? "Bir parça kurulamadı" : "One part couldn't be installed";
                f.warn = new[] { "WebView2 Runtime" };
                f.warnBody = turkish ? "Asenaizer çalışıyor; ayarlar tarayıcında açılacak." : "Asenaizer works; its settings open in your browser instead.";
            });
            Shot(dir, lang + "-5-error", turkish, f =>
            {
                f.page = Page.Result; f.resultOk = false;
                f.resultTitle = turkish ? "Olmadı, ama endişelenme" : "That didn't work, but don't worry";
                f.resultBody = turkish ? "Dosyalar kopyalanıyor adımında bir sorun çıktı. Her şey eski haline döndü." : "Something went wrong while copying files. Everything was put back.";
                f.resultDetail = "Access to the path 'C:\\Users\\me\\AppData\\Local\\Programs\\Asenaizer\\asenaizer-tray.exe' is denied.";
                f.resultLog = @"C:\Users\me\AppData\Local\Temp\asenaizer-install.log";
            });
        }
    }

    static void Shot(string dir, string name, bool turkish, Action<SetupForm> setup)
    {
        using (var f = new SetupForm())
        {
            f.timer.Stop();
            f.tr = turkish;
            f.slideStart = DateTime.UtcNow.AddSeconds(-5);
            f.tick = 7;
            setup(f);
            using (var bmp = new Bitmap((int)W, (int)H))
            {
                using (var g = Graphics.FromImage(bmp)) f.Render(g);
                bmp.Save(Path.Combine(dir, name + ".png"), System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    // The header icon from the embedded asenaizer.ico: the smallest frame at least `px` wide (else the largest).
    // Frames stored as PNG are decoded directly; older BMP frames go through Icon.
    static Image LoadMark(int px)
    {
        try
        {
            byte[] d;
            using (var s = typeof(Program).Assembly.GetManifestResourceStream("asenaizer.ico"))
            {
                if (s == null) return null;
                using (var ms = new MemoryStream()) { s.CopyTo(ms); d = ms.ToArray(); }
            }
            int count = BitConverter.ToUInt16(d, 4);
            int best = -1, bestSize = 0;
            for (int i = 0; i < count; i++)
            {
                int size = d[6 + 16 * i] == 0 ? 256 : d[6 + 16 * i];
                bool better = best < 0
                    || (size >= px && (bestSize < px || size < bestSize))
                    || (size < px && bestSize < px && size > bestSize);
                if (better) { best = i; bestSize = size; }
            }
            if (best < 0) return null;
            int len = BitConverter.ToInt32(d, 6 + 16 * best + 8), off = BitConverter.ToInt32(d, 6 + 16 * best + 12);
            if (len > 8 && off + len <= d.Length && d[off] == 0x89 && d[off + 1] == 0x50 && d[off + 2] == 0x4E && d[off + 3] == 0x47)
            {
                using (var ps = new MemoryStream(d, off, len))
                using (var img = Image.FromStream(ps))
                    return new Bitmap(img);
            }
            using (var all = new MemoryStream(d))
            using (var icon = new Icon(all, bestSize, bestSize))
                return icon.ToBitmap();
        }
        catch { return null; }
    }

    static Dictionary<string, object> ReadJson(string path)
    {
        try
        {
            if (path == null || !File.Exists(path)) return null;
            string text;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var sr = new StreamReader(fs)) text = sr.ReadToEnd();
            return new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>;
        }
        catch { return null; }
    }

    static string Str(Dictionary<string, object> d, string key) { object v; return d.TryGetValue(key, out v) && v != null ? Convert.ToString(v) : null; }
    static int Int(Dictionary<string, object> d, string key, int def) { object v; try { return d.TryGetValue(key, out v) && v != null ? Convert.ToInt32(v) : def; } catch { return def; } }
    static long Long(Dictionary<string, object> d, string key, long def) { object v; try { return d.TryGetValue(key, out v) && v != null ? Convert.ToInt64(v) : def; } catch { return def; } }
    static string[] Strings(Dictionary<string, object> d, string key)
    {
        object v;
        var arr = d.TryGetValue(key, out v) ? v as object[] : null;
        if (arr == null)
        {
            // a single value: ConvertTo-Json writes a one-element array as a plain string
            var one = v as string;
            return string.IsNullOrEmpty(one) ? new string[0] : new[] { one };
        }
        var list = new List<string>();
        foreach (var o in arr) if (o != null) list.Add(Convert.ToString(o));
        return list.ToArray();
    }

    Font F(float px, bool bold = false)
    {
        string key = px + (bold ? "b" : "");
        Font f;
        if (!fonts.TryGetValue(key, out f))
        {
            string family = FontExists("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";
            if (bold && FontExists("Segoe UI Variable Display")) family = "Segoe UI Variable Display";
            fonts[key] = f = new Font(family, px, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        }
        return f;
    }

    void ClearFonts() { foreach (var f in fonts.Values) f.Dispose(); fonts.Clear(); }

    static bool? hasVariable;
    static bool FontExists(string name)
    {
        if (name.StartsWith("Segoe UI Variable") && hasVariable.HasValue) return hasVariable.Value;
        using (var fam = new InstalledFontCollection())
            foreach (var f in fam.Families) if (f.Name == name) { if (name.StartsWith("Segoe UI Variable")) hasVariable = true; return true; }
        if (name.StartsWith("Segoe UI Variable")) hasVariable = false;
        return false;
    }

    static void Str(Graphics g, string s, Font f, Color c, float x, float y, float w, float h)
    {
        using (var b = new SolidBrush(c))
        using (var fmt = new StringFormat(StringFormatFlags.NoWrap) { Trimming = StringTrimming.EllipsisCharacter })
            g.DrawString(s, f, b, new RectangleF(x, y, w, h), fmt);
    }

    // centred in r (buttons): no measuring, so nothing is cut
    static void StrCenter(Graphics g, string s, Font f, Color c, RectangleF r)
    {
        using (var b = new SolidBrush(c))
        using (var fmt = new StringFormat(StringFormatFlags.NoWrap) { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter })
            g.DrawString(s, f, b, r, fmt);
    }

    // wrapped text; returns the bottom
    static float StrWrap(Graphics g, string s, Font f, Color c, float x, float y, float w, float maxH)
    {
        var size = g.MeasureString(s, f, (int)w);
        using (var b = new SolidBrush(c)) g.DrawString(s, f, b, new RectangleF(x, y, w, Math.Min(maxH, size.Height + 2)));
        return y + Math.Min(maxH, size.Height);
    }

    // Material-like glyphs drawn as lines (no icon font needed)
    static void Glyph(Graphics g, string name, RectangleF r, Color c)
    {
        using (var p = new Pen(c, Math.Max(1.5f, r.Width / 14f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
        {
            float x = r.X, y = r.Y, w = r.Width, h = r.Height;
            if (name == "check") g.DrawLines(p, new[] { new PointF(x + w * 0.24f, y + h * 0.52f), new PointF(x + w * 0.43f, y + h * 0.70f), new PointF(x + w * 0.78f, y + h * 0.32f) });
            else if (name == "close")
            {
                float a = w * 0.32f;
                g.DrawLine(p, x + a, y + a, x + w - a, y + h - a);
                g.DrawLine(p, x + w - a, y + a, x + a, y + h - a);
            }
        }
    }

    static GraphicsPath RoundPath(float x, float y, float w, float h, float r)
    {
        var path = new GraphicsPath();
        float d = Math.Min(r * 2, Math.Min(w, h));
        if (d <= 0.5f) { path.AddRectangle(new RectangleF(x, y, w, h)); return path; }
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    static void FillRound(Graphics g, Color c, float x, float y, float w, float h, float r)
    {
        using (var b = new SolidBrush(c)) using (var p = RoundPath(x, y, w, h, r)) g.FillPath(b, p);
    }

    static void DrawRound(Graphics g, Color c, float width, float x, float y, float w, float h, float r)
    {
        using (var pen = new Pen(c, width)) using (var p = RoundPath(x, y, w, h, r)) g.DrawPath(pen, p);
    }

    static void FillCircle(Graphics g, Color c, float cx, float cy, float r)
    {
        using (var b = new SolidBrush(c)) g.FillEllipse(b, cx - r, cy - r, r * 2, r * 2);
    }

    static Color Hex(string h)
    {
        int v = Convert.ToInt32(h.TrimStart('#'), 16);
        return Color.FromArgb(255, (v >> 16) & 255, (v >> 8) & 255, v & 255);
    }

    static Color Mix(Color a, Color b, float t)
    {
        return Color.FromArgb(255, (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmFlush();
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp);
}
