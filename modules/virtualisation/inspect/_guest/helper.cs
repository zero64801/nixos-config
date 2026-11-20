// The part of the guest tools that runs in a Windows guest, built there by the compiler Windows brings along.
// The agent starts programs as the system account in a session that has no desktop.
// Starting one as the user who is logged in, on their desktop, takes that user's token, which a script cannot get at.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class Helper
{
    const int Failed = 125;

    [StructLayout(LayoutKind.Sequential)]
    struct WTS_SESSION_INFO { public int SessionId; public IntPtr Station; public int State; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    delegate bool EachWindow(IntPtr window, IntPtr unused);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WTSQuerySessionInformation(IntPtr server, int session, int kind, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQueryUserToken(int session, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int kind, out IntPtr value, int size, out int needed);
    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr token, string program, StringBuilder line, IntPtr processRules, IntPtr threadRules,
        bool inherit, int flags, IntPtr environment, string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION made);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string program, StringBuilder line, IntPtr processRules, IntPtr threadRules,
        bool inherit, int flags, IntPtr environment, string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION made);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")]
    static extern bool SetHandleInformation(IntPtr handle, int mask, int flags);
    [DllImport("kernel32.dll")]
    static extern int WaitForSingleObject(IntPtr handle, int milliseconds);
    [DllImport("kernel32.dll")]
    static extern bool GetExitCodeProcess(IntPtr process, out int code);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int ResumeThread(IntPtr thread);
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EachWindow each, IntPtr unused);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr window, StringBuilder text, int most);
    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr window, out RECT place);
    [DllImport("user32.dll")]
    static extern int GetWindowThreadProcessId(IntPtr window, out int process);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int which);
    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr window, int which, out int value, int size);
    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr window, int which, out RECT value, int size);
    [DllImport("user32.dll")]
    static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr window, int how);
    [DllImport("user32.dll")]
    static extern bool PrintWindow(IntPtr window, IntPtr device, int flags);

    // The console's own writer would use the code page of a console, which mangles a window's title.
    static readonly TextWriter Said = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };

    sealed class Asked
    {
        public bool Desktop, Elevated, Gone, Feed, Detached, Suspended;
        public string User, Directory, Job, Title, Process, File, Out, Crop;
        public long Handle, From;
        public double Seconds = 60;
        public List<string> Grant = new List<string>(), Delete = new List<string>(), Set = new List<string>(), Rest = new List<string>();
    }

    static int Main(string[] args)
    {
        try
        {
            Asked asked = Read(args);
            switch (args.Length > 0 ? args[0] : "")
            {
                case "run": return Run(asked);
                case "find": return Find(asked);
                case "windows": return Windows(asked);
                case "shot": return Shot(asked);
                case "wait": return Wait(asked);
                case "tell": return Tell(asked);
                case "read": return Given(asked.File, asked);
                default: throw new ArgumentException("this is started with run, find, windows, shot, wait, tell or read");
            }
        }
        catch (Exception e)
        {
            byte[] said = Encoding.UTF8.GetBytes(e.Message + "\r\n");
            Console.OpenStandardError().Write(said, 0, said.Length);
            return Failed;
        }
    }

    static Asked Read(string[] args)
    {
        var asked = new Asked();
        int at = 1;
        for (; at < args.Length && args[at].StartsWith("--"); at++)
        {
            string name = args[at];
            if (name == "--desktop") asked.Desktop = true;
            else if (name == "--elevated") asked.Elevated = true;
            else if (name == "--gone") asked.Gone = true;
            else if (name == "--feed") asked.Feed = true;
            else if (name == "--detached") asked.Detached = true;
            else if (name == "--suspended") asked.Suspended = true;
            else if (at + 1 >= args.Length) throw new ArgumentException(name + " takes a value");
            else if (name == "--user") asked.User = args[++at];
            else if (name == "--cwd") asked.Directory = args[++at];
            else if (name == "--job") asked.Job = args[++at];
            else if (name == "--title") asked.Title = args[++at];
            else if (name == "--process") asked.Process = args[++at];
            else if (name == "--file") asked.File = args[++at];
            else if (name == "--out") asked.Out = args[++at];
            else if (name == "--crop") asked.Crop = args[++at];
            else if (name == "--handle") asked.Handle = long.Parse(args[++at], System.Globalization.CultureInfo.InvariantCulture);
            else if (name == "--from") asked.From = long.Parse(args[++at], System.Globalization.CultureInfo.InvariantCulture);
            else if (name == "--seconds") asked.Seconds = double.Parse(args[++at], System.Globalization.CultureInfo.InvariantCulture);
            else if (name == "--grant") asked.Grant.Add(args[++at]);
            else if (name == "--delete") asked.Delete.Add(args[++at]);
            else if (name == "--env") asked.Set.Add(args[++at]);
            else throw new ArgumentException("there is no " + name);
        }
        for (; at < args.Length; at++) asked.Rest.Add(args[at]);
        return asked;
    }

    static Exception Problem(string what)
    {
        return new InvalidOperationException(what + ": " + new Win32Exception(Marshal.GetLastWin32Error()).Message);
    }

    // The token of the account that was asked for, or none when the helper's own account is meant.
    static IntPtr TokenFor(Asked asked)
    {
        if (!asked.Desktop && asked.User == null) return IntPtr.Zero;
        IntPtr sessions, token = IntPtr.Zero;
        int count;
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out sessions, out count)) throw Problem("the sessions could not be listed");
        try
        {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int n = 0; n < count && token == IntPtr.Zero; n++)
            {
                var session = (WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(sessions, n * size), typeof(WTS_SESSION_INFO));
                string name = NameOf(session.SessionId);
                // State 0 is the session someone is working in.
                bool meant = asked.User == null ? session.State == 0 : name.Equals(asked.User, StringComparison.OrdinalIgnoreCase);
                if (name.Length > 0 && meant && !WTSQueryUserToken(session.SessionId, out token)) throw Problem("the session of " + name + " gave no token");
            }
        }
        finally
        {
            WTSFreeMemory(sessions);
        }
        if (token == IntPtr.Zero) throw new InvalidOperationException(asked.User == null ? "nobody is logged in at the guest's desktop" : asked.User + " is not logged in");
        return asked.Elevated ? Elevated(token) : token;
    }

    static string NameOf(int session)
    {
        IntPtr buffer;
        int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, 5, out buffer, out bytes)) return "";
        string name = Marshal.PtrToStringUni(buffer) ?? "";
        WTSFreeMemory(buffer);
        return name;
    }

    // An administrator who is logged in holds two tokens, and a session hands out the one without the rights.
    static IntPtr Elevated(IntPtr token)
    {
        IntPtr kind, full;
        int needed;
        if (GetTokenInformation(token, 18, out kind, 4, out needed) && kind.ToInt64() == 3)
        {
            if (!GetTokenInformation(token, 19, out full, IntPtr.Size, out needed)) throw Problem("the user's elevated side could not be taken");
            CloseHandle(token);
            return full;
        }
        using (var user = new WindowsIdentity(token))
            if (!new WindowsPrincipal(user).IsInRole(WindowsBuiltInRole.Administrator)) throw new InvalidOperationException("this user is no administrator");
        return token;
    }

    static Dictionary<string, string> Variables(IntPtr block)
    {
        var found = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (block == IntPtr.Zero)
        {
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) found[(string)entry.Key] = (string)entry.Value;
            return found;
        }
        for (IntPtr at = block; ;)
        {
            string entry = Marshal.PtrToStringUni(at);
            if (entry.Length == 0) return found;
            int split = entry.IndexOf('=', 1);
            if (split > 0) found[entry.Substring(0, split)] = entry.Substring(split + 1);
            at = IntPtr.Add(at, (entry.Length + 1) * 2);
        }
    }

    static Dictionary<string, string> VariablesOf(IntPtr token, out IntPtr block)
    {
        block = IntPtr.Zero;
        if (token != IntPtr.Zero && !CreateEnvironmentBlock(out block, token, false)) throw Problem("the user's environment could not be read");
        return Variables(block);
    }

    // Windows looks a program up on the path of whoever starts it, which here is not the one it is started for.
    static string OnPath(string program, Dictionary<string, string> variables, bool real)
    {
        if (program.IndexOfAny(new[] { '\\', '/', ':' }) >= 0) return program;
        string[] endings = Path.HasExtension(program) ? new[] { "" } : new[] { ".exe", ".com" };
        string folders;
        variables.TryGetValue("PATH", out folders);
        foreach (string folder in (folders ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            foreach (string ending in endings)
                try
                {
                    var candidate = new FileInfo(Path.Combine(folder.Trim('"'), program + ending));
                    // The store puts empty files on a user's path that only open the store.
                    if (candidate.Exists && (!real || candidate.Length > 0)) return candidate.FullName;
                }
                catch (ArgumentException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
        return null;
    }

    static List<string> Matching(string pattern)
    {
        string[] parts = pattern.Split('\\');
        var found = new List<string> { parts[0] + "\\" };
        for (int n = 1; n < parts.Length; n++)
        {
            var next = new List<string>();
            foreach (string folder in found)
                try
                {
                    next.AddRange(n < parts.Length - 1 ? Directory.GetDirectories(folder, parts[n]) : Directory.GetFiles(folder, parts[n]));
                }
                catch (ArgumentException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            found = next;
        }
        return found;
    }

    // find [--desktop | --user NAME] PROGRAM [PATTERN...]: the program on that account's path, or else the newest file of the first pattern that has any.
    static int Find(Asked asked)
    {
        if (asked.Rest.Count == 0) throw new ArgumentException("find takes a program and the places to look for it");
        IntPtr block;
        Dictionary<string, string> variables = VariablesOf(TokenFor(asked), out block);
        string best = OnPath(asked.Rest[0], variables, true);
        for (int n = 1; n < asked.Rest.Count && best == null; n++)
        {
            string pattern = Regex.Replace(asked.Rest[n], "%([^%]+)%", m => variables.ContainsKey(m.Groups[1].Value) ? variables[m.Groups[1].Value] : m.Value);
            Version newest = null;
            foreach (string file in Matching(pattern))
            {
                FileVersionInfo told = FileVersionInfo.GetVersionInfo(file);
                var version = new Version(told.FileMajorPart, told.FileMinorPart, told.FileBuildPart, told.FilePrivatePart);
                if (best == null || version > newest)
                {
                    best = file;
                    newest = version;
                }
            }
        }
        if (best == null) return 1;
        Said.WriteLine(best);
        return 0;
    }

    // run [--desktop | --user NAME] [--elevated] [--cwd DIR] [--env NAME=VALUE]... [--grant FILE]... [--delete FILE]... [--job PREFIX [--feed]] PROGRAM LINE: starts a program and waits for it.
    // A job writes what it prints to PREFIX.log and how it ended to PREFIX.exit.
    // One that is fed also reads what is added to PREFIX.in, and keeps what it answers in PREFIX.out apart from what it complains of.
    static int Run(Asked asked)
    {
        if (asked.Rest.Count != 2) throw new ArgumentException("run takes a program and its command line");
        if (asked.Job == null) return Started(asked, null, null);
        if (!asked.Detached) return Detach(asked);
        File.WriteAllText(asked.Job + ".pid", Process.GetCurrentProcess().Id.ToString());
        File.Delete(asked.Job + ".exit");
        int code;
        using (FileStream log = Kept(asked.Job + ".log"), answers = asked.Feed ? Kept(asked.Job + ".out") : null)
        {
            try
            {
                code = Started(asked, answers ?? log, log);
            }
            catch (Exception e)
            {
                byte[] said = Encoding.UTF8.GetBytes(e.Message + "\r\n");
                log.Write(said, 0, said.Length);
                code = Failed;
            }
        }
        File.WriteAllText(asked.Job + ".exit", code.ToString());
        return code;
    }

    // The guest's agent keeps each program it started until asked how it ended, and finds it by a number Windows soon gives to another program.
    // So a job runs in a copy of this helper of its own, and the one the agent started ends as soon as the job has begun, to be asked at once.
    static int Detach(Asked asked)
    {
        string line = Environment.CommandLine.TrimStart();
        int skip = line.StartsWith("\"") ? line.IndexOf('"', 1) + 1 : line.IndexOf(' ');
        string rest = line.Substring(skip).TrimStart();
        if (!rest.StartsWith("run ")) throw new ArgumentException("run comes first");
        var copy = new StringBuilder("\"" + Process.GetCurrentProcess().MainModule.FileName + "\" run --detached " + rest.Substring(4));
        File.Delete(asked.Job + ".pid");
        var startup = new STARTUPINFO();
        startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION made;
        // 0x01000000 leaves a job object the agent may have put its programs in, which some refuse, and 0x08000000 gives no window.
        if (!CreateProcess(null, new StringBuilder(copy.ToString()), IntPtr.Zero, IntPtr.Zero, false, 0x09000000, IntPtr.Zero, null, ref startup, out made)
            && !CreateProcess(null, copy, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref startup, out made))
            throw Problem("the job could not be started");
        CloseHandle(made.hThread);
        CloseHandle(made.hProcess);
        for (int tries = 0; tries < 200 && !File.Exists(asked.Job + ".pid"); tries++) System.Threading.Thread.Sleep(25);
        return File.Exists(asked.Job + ".pid") ? 0 : Failed;
    }

    static FileStream Kept(string path)
    {
        return new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete | FileShare.Inheritable);
    }

    static int Started(Asked asked, FileStream output, FileStream errors)
    {
        string program = null, directory = asked.Directory;
        IntPtr token = TokenFor(asked), environment = IntPtr.Zero;
        var startup = new STARTUPINFO();
        startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        startup.dwFlags = 0x100;
        if (token != IntPtr.Zero)
        {
            using (var user = new WindowsIdentity(token))
                foreach (string path in asked.Grant)
                {
                    FileSecurity rules = File.GetAccessControl(path);
                    rules.AddAccessRule(new FileSystemAccessRule(user.User, FileSystemRights.ReadAndExecute, AccessControlType.Allow));
                    File.SetAccessControl(path, rules);
                }
            Dictionary<string, string> variables = VariablesOf(token, out environment);
            if (asked.Set.Count > 0)
            {
                foreach (string pair in asked.Set) variables[pair.Split('=')[0]] = pair.Substring(pair.IndexOf('=') + 1);
                var names = new List<string>(variables.Keys);
                names.Sort(StringComparer.OrdinalIgnoreCase);
                var block = new StringBuilder();
                foreach (string name in names) block.Append(name).Append('=').Append(variables[name]).Append('\0');
                environment = Marshal.StringToHGlobalUni(block.Append('\0').ToString());
            }
            program = OnPath(asked.Rest[0], variables, false);
            if (program == null) throw new FileNotFoundException(asked.Rest[0] + " is not on the user's path");
            if (directory == null) variables.TryGetValue("USERPROFILE", out directory);
            startup.lpDesktop = "winsta0\\default";
        }
        else
        {
            foreach (string pair in asked.Set) Environment.SetEnvironmentVariable(pair.Split('=')[0], pair.Substring(pair.IndexOf('=') + 1));
        }
        AnonymousPipeServerStream feed = null;
        if (output != null)
        {
            startup.hStdOutput = output.SafeFileHandle.DangerousGetHandle();
            startup.hStdError = errors.SafeFileHandle.DangerousGetHandle();
            if (asked.Feed)
            {
                feed = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
                startup.hStdInput = feed.ClientSafePipeHandle.DangerousGetHandle();
            }
        }
        else
        {
            startup.hStdInput = Passed(-10);
            startup.hStdOutput = Passed(-11);
            startup.hStdError = Passed(-12);
        }
        var line = new StringBuilder(asked.Rest[1]);
        PROCESS_INFORMATION made;
        if (asked.Suspended && asked.Job == null) throw new ArgumentException("--suspended goes with --job");
        // 0x08000000 gives a console program a console without a window, 0x400 says the environment is wide text, 0x4 holds its first thread.
        int held = asked.Suspended ? 0x4 : 0;
        bool started = token != IntPtr.Zero
            ? CreateProcessAsUser(token, program, line, IntPtr.Zero, IntPtr.Zero, true, 0x08000400 | held, environment, directory, ref startup, out made)
            : CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, true, 0x08000000 | held, IntPtr.Zero, directory, ref startup, out made);
        if (!started) throw Problem(asked.Rest[0] + " could not be started");
        if (asked.Job != null) File.WriteAllText(asked.Job + ".program", made.dwProcessId.ToString());
        // A program started held waits for guest-job resume, which leaves a file beside the job's.
        if (asked.Suspended)
        {
            while (!File.Exists(asked.Job + ".resume")) System.Threading.Thread.Sleep(100);
            ResumeThread(made.hThread);
        }
        CloseHandle(made.hThread);
        if (feed != null)
        {
            feed.DisposeLocalCopyOfClientHandle();
            Fed(asked.Job + ".in", feed);
        }
        WaitForSingleObject(made.hProcess, -1);
        int code;
        GetExitCodeProcess(made.hProcess, out code);
        foreach (string path in asked.Delete)
            try
            {
                File.Delete(path);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        return code;
    }

    // Whatever gets added to a file goes on to the program as what it reads, for as long as the program runs.
    static void Fed(string path, Stream program)
    {
        var worker = new Thread(() =>
        {
            try
            {
                using (var added = new FileStream(path, FileMode.OpenOrCreate, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var buffer = new byte[65536];
                    while (true)
                    {
                        int count = added.Read(buffer, 0, buffer.Length);
                        if (count == 0)
                        {
                            Thread.Sleep(5);
                            continue;
                        }
                        program.Write(buffer, 0, count);
                        program.Flush();
                    }
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        });
        worker.IsBackground = true;
        worker.Start();
    }

    static IntPtr Passed(int which)
    {
        IntPtr handle = GetStdHandle(which);
        if (handle != IntPtr.Zero && handle != new IntPtr(-1)) SetHandleInformation(handle, 1, 1);
        return handle;
    }

    static string TitleOf(IntPtr window)
    {
        var text = new StringBuilder(512);
        GetWindowText(window, text, text.Capacity);
        return Regex.Replace(text.ToString(), "\\s", " ");
    }

    // The windows someone at the desktop would call open, the topmost first.
    static List<IntPtr> Shown(string title)
    {
        var found = new List<IntPtr>();
        EnumWindows((window, unused) =>
        {
            int hidden;
            string text = TitleOf(window);
            // A window of a suspended store program counts as visible and is drawn nowhere.
            bool drawn = IsWindowVisible(window) && text.Length > 0 && !(DwmGetWindowAttribute(window, 14, out hidden, 4) == 0 && hidden != 0);
            if (drawn && (title == null || text.IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0)) found.Add(window);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // windows [--title TEXT] [--seconds N]: the windows on the desktop this runs on, one a line, after the screen's size.
    // With a title it waits up to that long for one that has the text in it.
    static int Windows(Asked asked)
    {
        SetProcessDPIAware();
        DateTime until = DateTime.UtcNow.AddSeconds(asked.Title == null ? 0 : asked.Seconds);
        while (true)
        {
            List<IntPtr> found = Shown(asked.Title);
            if (found.Count > 0 || asked.Title == null || DateTime.UtcNow >= until)
            {
                IntPtr front = GetForegroundWindow();
                Said.WriteLine(string.Join("\t", "screen", GetSystemMetrics(0), GetSystemMetrics(1)));
                foreach (IntPtr window in found)
                {
                    RECT place;
                    int process;
                    GetWindowRect(window, out place);
                    GetWindowThreadProcessId(window, out process);
                    string program;
                    try
                    {
                        using (Process owner = Process.GetProcessById(process)) program = owner.ProcessName;
                    }
                    catch (Exception)
                    {
                        program = "?";
                    }
                    string state = window == front ? "front" : IsIconic(window) ? "minimized" : "-";
                    Said.WriteLine(string.Join("\t", window.ToInt64(), process, program, place.Left, place.Top, place.Right - place.Left, place.Bottom - place.Top, state, TitleOf(window)));
                }
                return found.Count > 0 || asked.Title == null ? 0 : 1;
            }
            Thread.Sleep(200);
        }
    }

    // shot (--title TEXT | --handle N) [--crop X,Y,W,H] --out FILE: one window as it is drawn, covered or not, written as a size and rows of blue, green and red.
    static int Shot(Asked asked)
    {
        SetProcessDPIAware();
        if (asked.Out == null) throw new ArgumentException("shot takes a file to write to");
        List<IntPtr> found = asked.Handle != 0 ? new List<IntPtr> { new IntPtr(asked.Handle) } : Shown(asked.Title);
        if (found.Count == 0 || !IsWindow(found[0])) throw new InvalidOperationException("there is no such window");
        IntPtr window = found[0];
        bool minimized = IsIconic(window);
        // A minimized window draws nothing, so it is shown for the moment, without taking the keyboard from what has it.
        if (minimized)
        {
            ShowWindow(window, 4);
            Thread.Sleep(300);
        }
        try
        {
            RECT place, seen;
            GetWindowRect(window, out place);
            // Windows counts a border nobody sees as part of a window.
            if (DwmGetWindowAttribute(window, 9, out seen, 16) != 0) seen = place;
            int width = place.Right - place.Left, height = place.Bottom - place.Top;
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384) throw new InvalidOperationException("the window has no size that can be drawn");
            using (var picture = new Bitmap(width, height, PixelFormat.Format24bppRgb))
            {
                using (Graphics canvas = Graphics.FromImage(picture))
                {
                    IntPtr device = canvas.GetHdc();
                    // 2 asks for what the window composes on the graphics card as well.
                    bool done = PrintWindow(window, device, 2);
                    canvas.ReleaseHdc(device);
                    if (!done) throw new InvalidOperationException("the window could not be drawn");
                }
                var part = new Rectangle(seen.Left - place.Left, seen.Top - place.Top, seen.Right - seen.Left, seen.Bottom - seen.Top);
                if (asked.Crop != null)
                {
                    string[] box = asked.Crop.Split(',');
                    part.Intersect(new Rectangle(part.Left + int.Parse(box[0]), part.Top + int.Parse(box[1]), int.Parse(box[2]), int.Parse(box[3])));
                }
                part.Intersect(new Rectangle(0, 0, width, height));
                if (part.Width <= 0 || part.Height <= 0) throw new InvalidOperationException("that part lies outside the window");
                BitmapData rows = picture.LockBits(part, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try
                {
                    using (var file = new FileStream(asked.Out, FileMode.CreateNew, FileAccess.Write))
                    {
                        file.Write(Encoding.ASCII.GetBytes("VMSHOT\0\0"), 0, 8);
                        file.Write(BitConverter.GetBytes(part.Width), 0, 4);
                        file.Write(BitConverter.GetBytes(part.Height), 0, 4);
                        var row = new byte[part.Width * 3];
                        for (int y = 0; y < part.Height; y++)
                        {
                            Marshal.Copy(IntPtr.Add(rows.Scan0, y * rows.Stride), row, 0, row.Length);
                            file.Write(row, 0, row.Length);
                        }
                    }
                }
                finally
                {
                    picture.UnlockBits(rows);
                }
            }
            Said.WriteLine(TitleOf(window));
        }
        finally
        {
            if (minimized) ShowWindow(window, 7);
        }
        return 0;
    }

    // tell --job PREFIX [--from N] [--seconds S] [LINE]: hands a fed job a line to read, then gives what the job has answered from a place on, waiting that long for there to be something.
    static int Tell(Asked asked)
    {
        if (asked.Job == null) throw new ArgumentException("tell takes the job to talk to");
        if (asked.Rest.Count > 0)
        {
            byte[] line = Encoding.UTF8.GetBytes(asked.Rest[0] + "\n");
            using (var read = new FileStream(asked.Job + ".in", FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) read.Write(line, 0, line.Length);
        }
        return Given(asked.Job + ".out", asked);
    }

    // read --file PATH [--from N] [--seconds S]: a file from a place on, or its last bytes for a place below nothing.
    // The agent cannot open a file that a program is still writing, and this can.
    static int Given(string path, Asked asked)
    {
        if (path == null) throw new ArgumentException("read takes a file");
        DateTime until = DateTime.UtcNow.AddSeconds(asked.Seconds);
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            long from = asked.From < 0 ? Math.Max(0, file.Length + asked.From) : asked.From;
            while (file.Length <= from && DateTime.UtcNow < until) Thread.Sleep(4);
            // A moment for the rest of an answer that is being written, so that it mostly comes in one piece.
            if (file.Length > from && asked.Seconds > 0) Thread.Sleep(10);
            file.Seek(from, SeekOrigin.Begin);
            Stream given = Console.OpenStandardOutput();
            var buffer = new byte[65536];
            long left = 8 << 20;
            int count;
            while (left > 0 && (count = file.Read(buffer, 0, (int)Math.Min(buffer.Length, left))) > 0)
            {
                given.Write(buffer, 0, count);
                left -= count;
            }
            given.Flush();
        }
        return 0;
    }

    // wait (--process NAME | --file PATH) [--gone] [--seconds N]: until the process runs or the file is there, or with --gone until it is not.
    static int Wait(Asked asked)
    {
        if ((asked.Process == null) == (asked.File == null)) throw new ArgumentException("wait takes a process or a file");
        string name = asked.Process != null && asked.Process.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? asked.Process.Substring(0, asked.Process.Length - 4) : asked.Process;
        DateTime until = DateTime.UtcNow.AddSeconds(asked.Seconds);
        while (true)
        {
            bool there;
            if (name != null)
            {
                Process[] found = Process.GetProcessesByName(name);
                there = found.Length > 0;
                foreach (Process one in found) one.Dispose();
            }
            else
            {
                there = File.Exists(asked.File) || Directory.Exists(asked.File);
            }
            if (there != asked.Gone) return 0;
            if (DateTime.UtcNow >= until) return 1;
            Thread.Sleep(200);
        }
    }
}
