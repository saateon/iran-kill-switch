// Iran Kill Switch - single-file installer.
// Built by Build-Setup.ps1 with the C# compiler that ships with Windows; the app files are
// embedded as payload.zip. __IKS_VERSION__ is replaced with app\VERSION at build time.
//   IranKillSwitch-Setup-x.y.z.exe            window
//   IranKillSwitch-Setup-x.y.z.exe /quiet     no window; exit code 0 = installed
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Iran Kill Switch Setup")]
[assembly: AssemblyProduct("Iran Kill Switch")]
[assembly: AssemblyCompany("Mansoor")]
[assembly: AssemblyCopyright("Made by Mansoor")]
[assembly: AssemblyVersion("__IKS_VERSION__.0")]
[assembly: AssemblyFileVersion("__IKS_VERSION__.0")]
[assembly: AssemblyInformationalVersion("__IKS_VERSION__")]

public static class SetupProgram
{
    public const string Version = "__IKS_VERSION__";

    [STAThread]
    public static int Main(string[] args)
    {
        foreach (string a in args)
        {
            string s = a.ToLowerInvariant();
            if (s == "/quiet" || s == "/q" || s == "/s" || s == "-quiet") { InstallResult r = Installer.Run(); Console.WriteLine(r.Output); return r.ExitCode; }
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var f = new SetupForm();
        Application.Run(f);
        return f.ExitCode;
    }
}

public sealed class InstallResult { public int ExitCode; public string Output = ""; }

public static class Installer
{
    public static string InstalledExe { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"IranKillSwitch\IranKillSwitch.exe"); } }

    public static InstallResult Run()
    {
        var res = new InstallResult();
        string tmp = Path.Combine(Path.GetTempPath(), "IKS-Setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        try
        {
            Directory.CreateDirectory(tmp);
            string zip = Path.Combine(tmp, "payload.zip");
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (FileStream fs = File.Create(zip)) { s.CopyTo(fs); }
            string pkg = Path.Combine(tmp, "pkg");
            ZipFile.ExtractToDirectory(zip, pkg);

            // Close a running app window first (it would keep showing old code), then install.
            string script = Path.Combine(tmp, "install.ps1");
            File.WriteAllText(script,
                "$ErrorActionPreference = 'Continue'\r\n" +
                "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'IKS\\.Gui\\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\r\n" +
                "Get-Process IranKillSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq '" + InstalledExe.Replace("'", "''") + "' } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $null = $_.WaitForExit(5000) }\r\n" +
                "& '" + Path.Combine(pkg, @"app\IKS.ps1").Replace("'", "''") + "' -Action Install\r\n" +
                "exit $LASTEXITCODE\r\n");
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var si = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = tmp };
            using (Process p = Process.Start(si))
            {
                string err = "";
                var t = new Thread(() => { err = p.StandardError.ReadToEnd(); }); t.Start();
                res.Output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(); t.Join();
                res.ExitCode = p.ExitCode;
                if (err.Trim().Length > 0) res.Output += "\r\n" + err;
            }
        }
        catch (Exception ex) { res.ExitCode = 1; res.Output = ex.Message; }
        finally { try { Directory.Delete(tmp, true); } catch { } }
        res.Output = res.Output.Trim();
        return res;
    }
}

// Dark window in the app's design: same colours, ring mark, rounded corners.
public sealed class SetupForm : Form
{
    static readonly Color Bg = ColorTranslator.FromHtml("#0E1014"), Surface = ColorTranslator.FromHtml("#161A21"),
        Surface2 = ColorTranslator.FromHtml("#1C212A"), Line = ColorTranslator.FromHtml("#262C36"), Text1 = ColorTranslator.FromHtml("#E9ECF1"),
        Muted = ColorTranslator.FromHtml("#8A93A3"), Green = ColorTranslator.FromHtml("#34D399"), Red = ColorTranslator.FromHtml("#F87171"),
        Off = ColorTranslator.FromHtml("#4B5563"), Accent = ColorTranslator.FromHtml("#60A5FA");

    public int ExitCode = 2;   // 2 = closed without installing
    readonly Label _title, _body, _foot;
    readonly Button _primary, _secondary;
    readonly System.Windows.Forms.Timer _anim = new System.Windows.Forms.Timer { Interval = 16 };
    Color _ring = Off; float _phase; bool _busy;
    Point _drag;

    public SetupForm()
    {
        Text = "Iran Kill Switch Setup";
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(420, 300); BackColor = Bg; DoubleBuffered = true; ShowInTaskbar = true;
        Font = new Font("Segoe UI", 9.5f);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        _title = MakeLabel(new Font("Segoe UI Semibold", 15f), Text1, new Rectangle(28, 126, 364, 32), ContentAlignment.MiddleCenter);
        _body = MakeLabel(Font, Muted, new Rectangle(28, 160, 364, 56), ContentAlignment.TopCenter);
        _foot = MakeLabel(new Font("Segoe UI", 8.25f), Off, new Rectangle(28, 276, 364, 16), ContentAlignment.MiddleCenter);
        _primary = MakeButton(new Rectangle(28, 222, 176, 42));
        _secondary = MakeButton(new Rectangle(216, 222, 176, 42));
        _foot.Text = "Made by Mansoor  \u00B7  v" + SetupProgram.Version;

        var close = new Label { Text = "\uE8BB", Font = new Font("Segoe MDL2 Assets", 8f), ForeColor = Muted, Bounds = new Rectangle(388, 12, 20, 20), TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand };
        close.Click += (s, e) => { if (!_busy) Close(); };
        Controls.Add(close);

        MouseDown += (s, e) => _drag = e.Location;
        MouseMove += (s, e) => { if (e.Button == MouseButtons.Left) Location = new Point(Location.X + e.X - _drag.X, Location.Y + e.Y - _drag.Y); };
        _anim.Tick += (s, e) => { _phase += 0.06f; Invalidate(new Rectangle(150, 20, 120, 120)); };
        Shown += (s, e) => Region = new Region(Rounded(new Rectangle(0, 0, Width, Height), 18));

        bool update = File.Exists(Installer.InstalledExe);
        ShowState(update ? "Update Iran Kill Switch" : "Install Iran Kill Switch",
                  (update ? "Updates to version " : "Installs version ") + SetupProgram.Version + " in Program Files." + (update ? " Your settings are kept." : " Protection stays off until you turn it on."),
                  Off, update ? "Update" : "Install", StartInstall, "Cancel", Close);
    }

    Label MakeLabel(Font f, Color c, Rectangle r, ContentAlignment a)
    {
        var l = new Label { Font = f, ForeColor = c, BackColor = Color.Transparent, Bounds = r, TextAlign = a, AutoEllipsis = true };
        l.MouseDown += (s, e) => _drag = new Point(e.X + l.Left, e.Y + l.Top);
        l.MouseMove += (s, e) => { if (e.Button == MouseButtons.Left) Location = new Point(Location.X + e.X + l.Left - _drag.X, Location.Y + e.Y + l.Top - _drag.Y); };
        Controls.Add(l); return l;
    }

    Button MakeButton(Rectangle r)
    {
        var b = new Button { Bounds = r, FlatStyle = FlatStyle.Flat, ForeColor = Text1, BackColor = Surface2, Cursor = Cursors.Hand, Font = new Font("Segoe UI Semibold", 10f) };
        b.FlatAppearance.BorderColor = Line; b.FlatAppearance.BorderSize = 1;
        b.FlatAppearance.MouseOverBackColor = ControlPaint.Light(Surface2, 0.15f);
        b.Paint += (s, e) => { };   // keep default text rendering
        Controls.Add(b); return b;
    }

    void ShowState(string title, string body, Color ring, string primary, Action onPrimary, string secondary, Action onSecondary)
    {
        _title.Text = title; _body.Text = body; _ring = ring;
        SetButton(_primary, primary, onPrimary, true);
        SetButton(_secondary, secondary, onSecondary, false);
        if (secondary == null) { _primary.Bounds = new Rectangle(28, 222, 364, 42); } else { _primary.Bounds = new Rectangle(28, 222, 176, 42); }
        Invalidate();
    }

    void SetButton(Button b, string text, Action onClick, bool primary)
    {
        b.Visible = text != null; if (text == null) return;
        b.Text = text; b.Tag = onClick;
        b.BackColor = primary ? Green : Surface2; b.ForeColor = primary ? ColorTranslator.FromHtml("#06261A") : Text1;
        b.FlatAppearance.BorderColor = primary ? Green : Line;
        b.FlatAppearance.MouseOverBackColor = primary ? ControlPaint.Light(Green, 0.2f) : ControlPaint.Light(Surface2, 0.15f);
        b.Click -= OnButton; b.Click += OnButton;
    }
    void OnButton(object s, EventArgs e) { var a = ((Button)s).Tag as Action; if (a != null && !_busy) a(); }

    void StartInstall()
    {
        _busy = true; _anim.Start();
        ShowState("Installing...", "Copying files, building the native helper and the background guard. This takes a few seconds.", Accent, null, null, null, null);
        _primary.Visible = false; _secondary.Visible = false;
        var t = new Thread(() =>
        {
            InstallResult r = Installer.Run();
            BeginInvoke((Action)(() => Finish(r)));
        });
        t.IsBackground = true; t.Start();
    }

    void Finish(InstallResult r)
    {
        _busy = false; _anim.Stop(); ExitCode = r.ExitCode;
        if (r.ExitCode == 0)
            ShowState("Installed - v" + SetupProgram.Version, "Iran Kill Switch is ready. Open it from the desktop or the Start menu at any time.", Green,
                      "Open Iran Kill Switch", () => { try { Process.Start(Installer.InstalledExe); } catch { } Close(); }, "Close", Close);
        else
        {
            string msg = r.Output; int i = msg.IndexOf("ERROR:"); if (i >= 0) msg = msg.Substring(i + 6).Trim();
            if (msg.Length > 220) msg = msg.Substring(0, 220) + "...";
            ShowState("Setup could not finish", (msg.Length > 0 ? msg : "Unknown error.") + " Nothing was turned on.", Red,
                      "Copy details", () => { try { Clipboard.SetText(r.Output); } catch { } }, "Close", Close);
        }
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        int d = radius * 2; var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure();
        return p;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var pen = new Pen(Line, 1)) g.DrawPath(pen, Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 18));
        using (var f = new Font("Segoe UI Semibold", 9.5f)) using (var b = new SolidBrush(Text1)) g.DrawString("Iran Kill Switch", f, b, 24, 13);
        // ring mark (spins while installing)
        var ring = new Rectangle(170, 30, 80, 80);
        using (var glow = new Pen(Color.FromArgb(45, _ring), 14)) g.DrawEllipse(glow, ring);
        using (var track = new Pen(Line, 8)) g.DrawEllipse(track, ring);
        using (var arc = new Pen(_ring, 8) { StartCap = LineCap.Round, EndCap = LineCap.Round })
        {
            if (_busy) g.DrawArc(arc, ring, (_phase * 180f / (float)Math.PI) % 360f, 110f); else g.DrawEllipse(arc, ring);
        }
        using (var inner = new SolidBrush(Surface)) g.FillEllipse(inner, Rectangle.Inflate(ring, -12, -12));
        using (var f = new Font("Segoe MDL2 Assets", 18f)) using (var b = new SolidBrush(_ring))
        {
            var sz = g.MeasureString("\uEA18", f); g.DrawString("\uEA18", f, b, ring.X + (ring.Width - sz.Width) / 2 + 1, ring.Y + (ring.Height - sz.Height) / 2 + 1);
        }
        base.OnPaint(e);
    }
}
