// A fake Unity editor for the unity-slot test harness (tests\run-tests.ps1). It is not Unity: it only
// imitates what unity-slot looks at. Built with the .NET Framework compiler by tests\stub\build.ps1.
// ASCII-only source.
//
// Imitated:
//   - process name Unity.exe, found as <editorRoot>\<version>\Editor\Unity.exe
//   - -projectPath, -logFile, -standbyWorkerCount, -buildTarget, -batchMode, -parentPid
//   - Temp\UnityLockfile held without sharing while open, deleted on a clean exit, left on a crash
//   - Editor.log: command line one argument per line, a licensing line, "[Project] Loading completed"
//     and the ##utp ProjectInfo line of this process when ready
//   - main window title "<project> - <scene> - <platform> - Unity <short> (<version>) <DX12>"
//   - closing on WM_CLOSE (CloseMainWindow, same as clicking X)
//   - dialogs made of native BUTTON and STATIC controls (what unity-slot's window list reads)
//   - a scene beacon file (examples\hooks\scene-beacon.ps1 format)
//   - import workers: child Unity.exe processes with -parentPid
//
// Behaviour comes from the control file <project>\Temp\unity-stub.txt (key=value lines), read at start
// and polled while running. An editor started through WMI does not inherit the caller's environment,
// so there are no environment switches. Keys:
//   mode      normal | never-ready | dialog | slow-close | ignore-close | dirty | exit-early
//   readyMs   delay until ready (default 1200)
//   closeMs   delay between a close request and the exit (default 300; slow-close 8000)
//   exitMs    exit-early: when to end without being ready (default 1500)
//   workers   import workers to start (default 0)
//   scene     scene name in the title and beacon (default SampleScene)
//   beacon    1 = write the scene beacon (always on in dirty mode); beaconPath (default Temp\SceneBeacon.json)
//   dirty     1/0: the beacon's scene state (default 1 in dirty mode)
//   logSecret a value written after an "-accessToken" line in the log (masking checks)
//   phases    startup phase lines to write at start, e.g. engine,packages,compile (see PhaseLine)
//   dialogTitle, dialogText, dialogButtons (comma separated): the dialog mode's startup dialog
//   lifetimeSec  the stub ends by itself after this many seconds (default 600)
//   quit      a token: when it changes while running, the stub (and its workers) end by themselves
//   dismiss   a token: when it changes, the stub closes its own open dialog (never a click)
// Nothing here is killed from outside: every exit is the stub's own.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace UnitySlotTests
{
    static class Native
    {
        public const int WS_CHILD = 0x40000000;
        public const int WS_VISIBLE = 0x10000000;
        public const int WS_TABSTOP = 0x00010000;
        public const int BS_PUSHBUTTON = 0x00000000;
        public const int WM_COMMAND = 0x0111;
        public const int BN_CLICKED = 0;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
            int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    }

    class StubControl
    {
        public Dictionary<string, string> Values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public DateTime Stamp = DateTime.MinValue;
        public long Length = -1;

        public string Get(string key, string fallback)
        {
            string v;
            if (Values.TryGetValue(key, out v) && v.Length > 0) return v;
            return fallback;
        }

        public int GetInt(string key, int fallback)
        {
            int n;
            if (int.TryParse(Get(key, ""), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) return n;
            return fallback;
        }

        // true when the file changed since the last read
        public bool Reload(string file)
        {
            try
            {
                if (!File.Exists(file))
                {
                    if (Length == -1 && Stamp == DateTime.MinValue) return false;
                    Values.Clear(); Length = -1; Stamp = DateTime.MinValue;
                    return true;
                }
                var info = new FileInfo(file);
                if (info.LastWriteTimeUtc == Stamp && info.Length == Length) return false;
                string text;
                using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var sr = new StreamReader(fs, new UTF8Encoding(false)))
                    text = sr.ReadToEnd();
                var next = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var raw in text.Split('\n'))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    next[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                Values = next; Stamp = info.LastWriteTimeUtc; Length = info.Length;
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    // A small window whose content is native BUTTON / STATIC controls, like Unity's own dialogs.
    class StubDialog : Form
    {
        readonly string text;
        readonly string[] buttons;
        public Action<string> Clicked;

        public StubDialog(string title, string text, string[] buttons)
        {
            this.text = text;
            this.buttons = buttons;
            Text = title;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-30000, -30000);
            ClientSize = new Size(420, 120);
            MinimizeBox = false;
            MaximizeBox = false;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.CreateWindowEx(0, "STATIC", text, Native.WS_CHILD | Native.WS_VISIBLE, 10, 10, 400, 50,
                Handle, new IntPtr(100), IntPtr.Zero, IntPtr.Zero);
            for (int i = 0; i < buttons.Length; i++)
            {
                Native.CreateWindowEx(0, "BUTTON", buttons[i], Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_TABSTOP | Native.BS_PUSHBUTTON,
                    10 + i * 110, 75, 100, 28, Handle, new IntPtr(200 + i), IntPtr.Zero, IntPtr.Zero);
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_COMMAND)
            {
                long w = m.WParam.ToInt64();
                int id = (int)(w & 0xFFFF);
                int code = (int)((w >> 16) & 0xFFFF);
                if (code == Native.BN_CLICKED && id >= 200 && id < 200 + buttons.Length && Clicked != null)
                {
                    Clicked(buttons[id - 200]);
                    return;
                }
            }
            base.WndProc(ref m);
        }
    }

    class EditorForm : Form
    {
        readonly Stub stub;
        public bool AllowExit;

        public EditorForm(Stub stub, string title)
        {
            this.stub = stub;
            Text = title;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-30000, -30000);
            ClientSize = new Size(360, 90);
            var label = new Label();
            label.Text = "unity-slot test stub (not Unity)";
            label.AutoSize = true;
            label.Location = new Point(10, 10);
            Controls.Add(label);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!AllowExit)
            {
                e.Cancel = true;
                stub.OnCloseRequest();
                return;
            }
            base.OnFormClosing(e);
        }
    }

    class Stub
    {
        public static readonly string[] Groups = { "Android", "WebGL", "Standalone", "iOS", "tvOS", "VisionOS", "PS4", "PS5", "XboxOne",
            "GameCoreXboxSeries", "GameCoreXboxOne", "Switch", "LinuxHeadlessSimulation", "EmbeddedLinux", "QNX" };

        readonly string[] args;
        readonly Dictionary<string, string> flags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly StubControl control = new StubControl();
        readonly object logGate = new object();
        readonly int pid = Process.GetCurrentProcess().Id;

        string project, logPath, controlFile, version, mode;
        StreamWriter log;
        FileStream lockStream;
        EditorForm form;
        StubDialog dialog;
        string dialogKind = "";
        System.Windows.Forms.Timer timer;
        bool ready, closing, exiting;
        long readyAt = -1, exitAt = -1;
        string quitBaseline = "", dismissBaseline = "";
        int lastDirty = -1;
        int exitCode;
        readonly List<Process> workers = new List<Process>();

        public Stub(string[] args) { this.args = args; }

        static bool IsFlag(string a) { return a.Length > 1 && a[0] == '-' && !char.IsDigit(a[1]); }

        void ParseArgs()
        {
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (!IsFlag(a)) continue;
                string name = a.TrimStart('-');
                string value = "";
                if (i + 1 < args.Length && !IsFlag(args[i + 1])) { value = args[i + 1]; i++; }
                flags[name] = value;
            }
        }

        string Flag(string name) { string v; return flags.TryGetValue(name, out v) ? v : null; }

        void Log(string line)
        {
            lock (logGate)
            {
                if (log == null) return;
                try { log.Write(line + "\n"); } catch (IOException) { }
            }
        }

        static string Iso(double seconds) { return seconds.ToString("0.000", CultureInfo.InvariantCulture); }

        public int Run()
        {
            ParseArgs();
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            version = new DirectoryInfo(Path.GetDirectoryName(exe)).Parent.Name;   // <version>\Editor\Unity.exe
            string projectArg = Flag("projectPath");
            if (string.IsNullOrEmpty(projectArg)) return 64;
            project = Path.GetFullPath(projectArg.Replace('/', '\\'));
            controlFile = Path.Combine(project, @"Temp\unity-stub.txt");
            control.Reload(controlFile);
            quitBaseline = control.Get("quit", "");
            dismissBaseline = control.Get("dismiss", "");

            if (Flag("parentPid") != null) return RunWorker();

            string logArg = Flag("logFile");
            logPath = string.IsNullOrEmpty(logArg) ? Path.Combine(project, @"Temp\unity-stub-nolog.log") : Path.GetFullPath(logArg);
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));
            var logStream = new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            log = new StreamWriter(logStream, new UTF8Encoding(false));
            log.AutoFlush = true;

            Log("[Licensing::Module] Channel doesn't exist: \"LicenseClient-stub\"");
            Log("[Licensing::Client] Successfully resolved entitlement details");
            Log("Built from '" + version + "' branch; Version is '" + version + " (stub)'; Unity test stub");
            Log("COMMAND LINE ARGUMENTS:");
            Log(exe);
            foreach (var a in args) Log(a);
            string secret = control.Get("logSecret", "");
            if (secret.Length > 0) { Log("-accessToken"); Log(secret); }
            foreach (string phase in control.Get("phases", "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                Log(PhaseLine(phase.Trim()));
            string standby = Flag("standbyWorkerCount");
            if (standby == "0")
            {
                Log("Failed to set standby worker count to 0");
                Log("Failed to set standby worker count to 0");
            }

            try
            {
                Directory.CreateDirectory(Path.Combine(project, "Temp"));
                lockStream = new FileStream(Path.Combine(project, @"Temp\UnityLockfile"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException)
            {
                Log("[stub] It looks like another Unity instance is running with this project open (Temp\\UnityLockfile is held).");
                CloseLog(2);
                return 2;
            }

            string platform = Platform();
            mode = control.Get("mode", "normal").ToLowerInvariant();
            Log("[stub] pid " + pid + " mode " + mode + " platform " + platform);

            if (Flag("batchMode") != null) return RunBatch();

            Application.SetCompatibleTextRenderingDefault(false);
            string title = string.Format("{0} - {1} - {2} - Unity {3} ({4}) <DX12>", new DirectoryInfo(project).Name,
                control.Get("scene", "SampleScene"), TitlePlatform(platform), ShortVersion(version), version);
            form = new EditorForm(this, title);
            timer = new System.Windows.Forms.Timer();
            timer.Interval = 200;
            timer.Tick += delegate { Tick(); };
            form.Load += delegate { OnStarted(); timer.Start(); };
            Application.Run(form);
            return exitCode;
        }

        // Startup phase lines as Unity 6000.6 prints them (control key "phases", comma separated keys).
        static string PhaseLine(string key)
        {
            switch (key)
            {
                case "engine": return "Initialize engine version: 9999.0.0f1 (stub)";
                case "assemblies": return "Begin MonoManager ReloadAssembly";
                case "refresh": return "Application.AssetDatabase Initial Refresh Start";
                case "packages": return "[Package Manager] Resolving packages";
                case "compile": return "[ 12/ 40  3s] Csc Library/Bee/artifacts/Assembly-CSharp.dll";
                case "reload": return "*** Tundra build success (1.23 seconds), 12 items updated, 40 evaluated";
                case "import": return "Start importing Assets/Scenes/SampleScene.unity using Guid(00000000000000000000000000000000)";
                case "refreshed": return "Asset Pipeline Refresh (id=stub): Total: 1.234 seconds - Initiated by InitialRefresh";
                case "scene": return "Application.AssetDatabase Initial Refresh End";
                case "finishing": return "Loaded scene 'Assets/Scenes/SampleScene.unity'";
                default: return "[stub] phase " + key;
            }
        }

        static string ShortVersion(string v)
        {
            var parts = v.Split('.');
            return parts.Length >= 2 ? parts[0] + "." + parts[1] : v;
        }

        // the platform the editor opens with: -buildTarget, else Library\EditorUserBuildSettings.asset
        string Platform()
        {
            string asset = Path.Combine(project, @"Library\EditorUserBuildSettings.asset");
            string target = Flag("buildTarget");
            if (!string.IsNullOrEmpty(target))
            {
                string group = target;
                if (target.StartsWith("Standalone", StringComparison.OrdinalIgnoreCase)) group = "Standalone";
                else if (target.Equals("WebGL", StringComparison.OrdinalIgnoreCase)) group = "WebGL";
                else if (target.Equals("Android", StringComparison.OrdinalIgnoreCase)) group = "Android";
                else if (target.Equals("iOS", StringComparison.OrdinalIgnoreCase)) group = "iOS";
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(asset));
                    File.WriteAllBytes(asset, LibraryBytes(group));
                }
                catch (IOException) { }
                return group;
            }
            try
            {
                if (File.Exists(asset))
                {
                    string text = Encoding.GetEncoding(28591).GetString(File.ReadAllBytes(asset));
                    bool after = false;
                    foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(text, "[\\x20-\\x7E]{3,}"))
                    {
                        if (!after) { if (m.Value == "settings") after = true; continue; }
                        if (Array.IndexOf(Groups, m.Value) >= 0) return m.Value;
                    }
                }
            }
            catch (IOException) { }
            return "Standalone";
        }

        public static byte[] LibraryBytes(string group)
        {
            var bytes = new List<byte>(new byte[] { 0, 0, 0, 0x16, 0, 0, 0, 0 });
            bytes.AddRange(Encoding.ASCII.GetBytes("EditorUserBuildSettings"));
            bytes.AddRange(new byte[] { 0, 1, 0, 0 });
            bytes.AddRange(Encoding.ASCII.GetBytes("settings"));
            bytes.AddRange(new byte[] { 0, 0, 0, 0, 7, 0, 0, 0 });
            bytes.AddRange(Encoding.ASCII.GetBytes(group));
            bytes.AddRange(new byte[] { 0, 0, 0, 0 });
            return bytes.ToArray();
        }

        static string TitlePlatform(string group)
        {
            switch (group)
            {
                case "WebGL": return "Web";
                case "Standalone": return "Windows, Mac, Linux";
                default: return group;
            }
        }

        void OnStarted()
        {
            int count = control.GetInt("workers", 0);
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            for (int i = 0; i < count; i++)
            {
                try
                {
                    var psi = new ProcessStartInfo(exe, string.Format("\"-projectPath\" \"{0}\" -parentPid {1} -name AssetImportWorker{2} -batchMode -noUpm",
                        project.Replace('\\', '/'), pid, i));
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    workers.Add(Process.Start(psi));
                    Log("[stub] started import worker " + i);
                }
                catch (Exception ex) { Log("[stub] worker start failed: " + ex.Message); }
            }
            if (mode == "dialog")
            {
                ShowDialog("startup", control.Get("dialogTitle", "Opening Project in Non-Matching Editor Installation"),
                    control.Get("dialogText", "This project was saved with a different version of the Unity Editor."),
                    control.Get("dialogButtons", "Continue,Quit").Split(','));
            }
            else if (mode == "exit-early")
            {
                exitAt = clock.ElapsedMilliseconds + control.GetInt("exitMs", 1500);
            }
            else if (mode != "never-ready")
            {
                readyAt = clock.ElapsedMilliseconds + control.GetInt("readyMs", 1200);
            }
        }

        void ShowDialog(string kind, string title, string text, string[] buttons)
        {
            CloseDialog();
            dialogKind = kind;
            dialog = new StubDialog(title, text, buttons);
            dialog.Clicked = OnDialogClick;
            dialog.FormClosing += delegate (object s, FormClosingEventArgs e)
            {
                if (dialog == null || exiting) return;
                e.Cancel = true;
                Log("[stub] dialog button clicked: (close box)");
            };
            dialog.Show();
            Log("[stub] dialog shown: " + title);
        }

        void CloseDialog()
        {
            if (dialog == null) return;
            var d = dialog;
            dialog = null;
            dialogKind = "";
            d.Close();
            d.Dispose();
        }

        // Only a person clicks. The harness never does; it checks that no click was logged.
        void OnDialogClick(string button)
        {
            Log("[stub] dialog button clicked: " + button);
            string kind = dialogKind;
            CloseDialog();
            if (kind == "startup")
            {
                if (button.StartsWith("Quit", StringComparison.OrdinalIgnoreCase)) Exit(0, true);
                else readyAt = clock.ElapsedMilliseconds + control.GetInt("readyMs", 1200);
            }
            else if (kind == "save")
            {
                if (button.StartsWith("Save", StringComparison.OrdinalIgnoreCase)) { SetDirty(0); Exit(0, true); }
                else if (button.StartsWith("Don", StringComparison.OrdinalIgnoreCase)) Exit(0, true);
                else closing = false;
            }
        }

        int Dirty() { return control.GetInt("dirty", mode == "dirty" ? 1 : 0); }

        bool BeaconOn() { return mode == "dirty" || control.Get("beacon", "0") == "1"; }

        void SetDirty(int value)
        {
            lastDirty = value;
            WriteBeacon(value);
        }

        void WriteBeacon(int dirty)
        {
            if (!BeaconOn()) return;
            string rel = control.Get("beaconPath", @"Temp\SceneBeacon.json");
            string scene = control.Get("scene", "SampleScene");
            string json = "{\"Pid\": " + pid + ", \"IsPlaying\": false, \"Scenes\": [ { \"Path\": \"Assets/Scenes/" + scene + ".unity\", \"IsDirty\": " +
                (dirty == 1 ? "true" : "false") + " } ], \"PrefabStagePath\": \"\", \"PrefabStageDirty\": false}";
            try
            {
                string file = Path.Combine(project, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                string tmp = file + "." + pid + ".tmp";
                File.WriteAllText(tmp, json, new UTF8Encoding(false));
                if (File.Exists(file)) File.Delete(file);
                File.Move(tmp, file);
            }
            catch (IOException) { }
        }

        void BecomeReady()
        {
            ready = true;
            double load = clock.ElapsedMilliseconds / 1000.0;
            long unixMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            Log("[Project] Loading completed in " + Iso(load) + " seconds");
            Log("##utp:{\"type\":\"ProjectInfo\",\"version\":2,\"phase\":\"Immediate\",\"time\":" + unixMs + ",\"processId\":" + pid +
                ",\"projectLoad\":" + Iso(load) + ",\"projectInit\":0.050,\"assetDatabaseInit\":0.020,\"assetDatabaseRefresh\":" + Iso(load * 0.4) +
                ",\"assembliesLoad\":" + Iso(load * 0.2) + ",\"sceneOpening\":" + Iso(load * 0.1) + "}");
            if (BeaconOn()) SetDirty(Dirty());
        }

        public void OnCloseRequest()
        {
            Log("[stub] close requested");
            if (exiting) return;
            if (mode == "ignore-close") { Log("[stub] close ignored"); return; }
            if (mode == "dirty" && Dirty() == 1)
            {
                if (dialog == null)
                {
                    string scene = control.Get("scene", "SampleScene");
                    ShowDialog("save", "Scene(s) Have Been Modified",
                        "Do you want to save the changes you made in the scenes: Assets/Scenes/" + scene + ".unity",
                        new[] { "Save", "Don't Save", "Cancel" });
                }
                return;
            }
            if (closing) return;
            closing = true;
            int delay = control.GetInt("closeMs", mode == "slow-close" ? 8000 : 300);
            exitAt = clock.ElapsedMilliseconds + delay;
        }

        void Tick()
        {
            if (exiting) return;
            long now = clock.ElapsedMilliseconds;
            if (control.Reload(controlFile))
            {
                if (control.Get("quit", "") != quitBaseline) { Log("[stub] quit (control file)"); Exit(0, true); return; }
                if (control.Get("dismiss", "") != dismissBaseline)
                {
                    dismissBaseline = control.Get("dismiss", "");
                    if (dialog != null)
                    {
                        Log("[stub] dialog dismissed by the control file (no click)");
                        string kind = dialogKind;
                        CloseDialog();
                        if (kind == "startup") readyAt = now + control.GetInt("readyMs", 1200);
                    }
                }
                if (ready && BeaconOn() && Dirty() != lastDirty)
                {
                    SetDirty(Dirty());
                    if (lastDirty == 0 && dialogKind == "save") { Log("[stub] saved; save dialog closed"); CloseDialog(); }
                }
            }
            if (!ready && readyAt >= 0 && now >= readyAt && dialog == null) { readyAt = -1; BecomeReady(); }
            if (exitAt >= 0 && now >= exitAt)
            {
                if (mode == "exit-early" && !ready) { Log("[stub] exiting before ready (simulated crash)"); Exit(1, false); return; }
                Exit(0, true);
                return;
            }
            if (now > control.GetInt("lifetimeSec", 600) * 1000L) { Log("[stub] lifetime over; exiting by itself"); Exit(0, true); return; }
            if (!Directory.Exists(project)) { Exit(0, false); return; }
        }

        void Exit(int code, bool clean)
        {
            if (exiting) return;
            exiting = true;
            exitCode = code;
            if (timer != null) timer.Stop();
            CloseDialog();
            ReleaseLock(clean);
            CloseLog(code);
            if (form != null) { form.AllowExit = true; form.Close(); }
            Application.ExitThread();
        }

        void ReleaseLock(bool delete)
        {
            if (lockStream == null) return;
            try { lockStream.Dispose(); } catch (IOException) { }
            lockStream = null;
            if (delete)
            {
                try { File.Delete(Path.Combine(project, @"Temp\UnityLockfile")); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        void CloseLog(int code)
        {
            lock (logGate)
            {
                if (log == null) return;
                try { log.Write("[stub] exit " + code + "\n"); log.Dispose(); } catch (IOException) { }
                log = null;
            }
        }

        // -batchMode without -parentPid: a batch run on this clone; no window, ends on quit or lifetime.
        int RunBatch()
        {
            Log("[stub] batchmode run");
            while (true)
            {
                Thread.Sleep(200);
                if (control.Reload(controlFile) && control.Get("quit", "") != quitBaseline) { Log("[stub] quit (control file)"); break; }
                if (clock.ElapsedMilliseconds > control.GetInt("lifetimeSec", 600) * 1000L) break;
                if (!Directory.Exists(project)) break;
            }
            ReleaseLock(true);
            CloseLog(0);
            return 0;
        }

        // -parentPid: an import worker. It ends when its editor ends (or on quit, or after its lifetime).
        int RunWorker()
        {
            Process parent = null;
            int parentId;
            if (int.TryParse(Flag("parentPid"), out parentId)) { try { parent = Process.GetProcessById(parentId); } catch (ArgumentException) { } }
            while (true)
            {
                Thread.Sleep(200);
                if (parent == null || parent.HasExited) return 0;
                if (control.Reload(controlFile) && control.Get("quit", "") != quitBaseline) return 0;
                if (clock.ElapsedMilliseconds > control.GetInt("lifetimeSec", 600) * 1000L) return 0;
            }
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            return new Stub(args).Run();
        }
    }
}
