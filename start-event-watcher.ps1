# Copyright (c) 2026 Cartmill Technologies LLC. All rights reserved.
# Start Event Watcher
# Serves event-watcher.html at http://localhost:8787/, fetches the broadcast
# calendar feed for it at /feed, and reads the day's closure log for it at
# /closures?date=MMDDYYYY, and the card/port .txt file in this folder at
# /cardport. Browsers block a page opened from a file from
# reading these directly; going through this helper avoids that.
# Keep this window open while you use the watcher. Close it to stop.

$port = 8787
$feedUrl = "https://broadcastcalendarapi.learfield.net/api/Link/GetData?hash=6F628624BB4F4C5D88DCDAB31288FD0A"
# Folder holding the closure logs, named closures-MMDDYYYY.txt
$closureFolder = "I:\Closure Logs"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$page = Join-Path $root "event-watcher.html"
# FFmpeg, for level meters on every live stream: ffmpeg-64\bin\ffmpeg.exe in
# the same folder as Start Event Watcher.bat
$ffmpegPath = Join-Path $root "ffmpeg-64\bin\ffmpeg.exe"
# Card/port file: a tab-delimited .txt in this same folder (MikeIsGreat.txt). Put its name here
# to always use that file; leave it empty to use the newest card/port .txt.
$cardPortName = "MikeIsGreat.txt"

# Finds the card/port file in this folder: the named one, or else the newest
# .txt whose rows are tab-delimited with at least 10 columns.
function Find-CardPort {
    if ($cardPortName) {
        $f = Join-Path $root $cardPortName
        if (Test-Path -LiteralPath $f) { return Get-Item -LiteralPath $f }
        return $null
    }
    foreach ($f in (Get-ChildItem -LiteralPath $root -Filter *.txt -File | Sort-Object LastWriteTime -Descending)) {
        try {
            $first = Get-Content -LiteralPath $f.FullName -TotalCount 5 | Where-Object { $_.Trim() } | Select-Object -First 1
            if ($first -and ($first -split "`t").Count -ge 10) { return $f }
        } catch {}
    }
    return $null
}

if (-not (Test-Path $page)) {
    Write-Host "event-watcher.html was not found next to this script ($root)." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

# Opens the watcher in the default browser.
function Open-Watcher {
    Start-Process "http://localhost:$port/"
}

# Level monitor: one FFmpeg per live stream, reporting its RMS level
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Runs one FFmpeg process per live stream and keeps its latest RMS level.
// Streams nobody has asked about for 20 seconds are stopped.
public static class LevelMonitor
{
    public static string Ffmpeg = "ffmpeg";

    public class Entry
    {
        public Process Proc;
        public double Db = double.NegativeInfinity;
        public DateTime LevelAt = DateTime.MinValue;
        public DateTime Wanted = DateTime.UtcNow;
        public DateTime Started = DateTime.UtcNow;
        public DateTime RetryAt = DateTime.MinValue;
        public string LastError = "";
        public string FirstError = "";
    }

    static readonly ConcurrentDictionary<string, Entry> map = new ConcurrentDictionary<string, Entry>();
    static Timer sweeper = new Timer(delegate { Sweep(); }, null, 5000, 5000);

    // What this FFmpeg build supports (builds differ, and an option it doesn't
    // know makes FFmpeg stop with "Option not found")
    public static string Version = "";
    public static string Problem = "";
    // Audio-level filter chain this build can run, and the value it prints
    static string filter = "asetnsamples=n=4410:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level";
    static string levelKey = "RMS_level=";
    static readonly string[][] Chains = new[] {
        new[] { "asetnsamples=n=4410:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level", "RMS_level=" },
        new[] { "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level", "RMS_level=" },
        new[] { "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", "RMS_level=" },
        new[] { "ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.M", "r128.M=" },
        new[] { "ebur128", " M:" }
    };

    // A short test tone to try the filter chains on
    static string TestWav()
    {
        string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "event-watcher-test.wav");
        int rate = 22050, n = rate; // 1 second
        using (var w = new System.IO.BinaryWriter(System.IO.File.Create(path)))
        {
            w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
            for (int i = 0; i < n; i++) w.Write((short)(8000 * Math.Sin(2 * Math.PI * 440 * i / rate)));
        }
        return path;
    }
    static HashSet<string> options = new HashSet<string>();
    static bool hasHttps = true;

    static string Run(string args)
    {
        var psi = new ProcessStartInfo(Ffmpeg, args);
        psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true; psi.CreateNoWindow = true;
        var p = Process.Start(psi);
        var errTask = p.StandardError.ReadToEndAsync();
        string output = p.StandardOutput.ReadToEnd();
        p.WaitForExit(15000);
        return output + "\n" + errTask.Result;
    }

    public static bool Available()
    {
        try
        {
            string v = Run("-version");
            Version = v.Split('\n')[0].Trim();
            if (!Version.StartsWith("ffmpeg")) return false;
            // Options this build knows, from its http and full help listings
            string help = Run("-hide_banner -h protocol=http") + "\n" + Run("-hide_banner -h full");
            foreach (var line in help.Split('\n'))
            {
                var t = line.TrimStart();
                if (!t.StartsWith("-")) continue;
                int sp = t.IndexOfAny(new[] { ' ', '\t' });
                options.Add(sp > 1 ? t.Substring(1, sp - 1) : t.Substring(1));
            }
            string protos = Run("-hide_banner -protocols");
            int outAt = protos.IndexOf("Output:");
            string inputs = outAt > 0 ? protos.Substring(0, outAt) : protos;
            hasHttps = inputs.Split('\n').Any(l => l.Trim() == "https");
            // Pick the first level filter chain this build can actually run
            string wav = TestWav();
            foreach (var c in Chains)
            {
                string outp = Run("-hide_banner -nostdin -nostats -loglevel info -i \"" + wav + "\" -vn -af \"" + c[0] + "\" -f null -");
                if (outp.Contains(c[1])) { filter = c[0]; levelKey = c[1]; Problem = ""; return true; }
            }
            Problem = "this FFmpeg build can't run the audio level filters (astats/ebur128)";
            return false;
        }
        catch { return false; }
    }

    public static string Describe()
    {
        var missing = new[] { "user_agent", "rw_timeout", "reconnect", "reconnect_streamed", "reconnect_delay_max", "http_proxy" }
            .Where(o => !options.Contains(o)).ToArray();
        return Version + (hasHttps ? "" : " (no https support)") + " - levels via " + filter.Split(',')[filter.StartsWith("asetnsamples") ? 1 : 0].Split('=')[0] +
            (missing.Length > 0 ? " - not using: " + string.Join(", ", missing) : "");
    }

    static string Opt(string name, string value)
    {
        return options.Contains(name) ? "-" + name + " " + value + " " : "";
    }

    public static void Want(string[] urls)
    {
        var now = DateTime.UtcNow;
        foreach (var raw in urls)
        {
            var u = (raw ?? "").Trim();
            if (u.Length == 0 || !(u.StartsWith("http://") || u.StartsWith("https://")) || u.IndexOf('"') >= 0) continue;
            var e = map.GetOrAdd(u, k => new Entry());
            e.Wanted = now;
            lock (e)
            {
                bool running = e.Proc != null && !e.Proc.HasExited;
                if (!running && now >= e.RetryAt) Start(u, e);
            }
        }
        Sweep();
    }

    static void Sweep()
    {
        var now = DateTime.UtcNow;
        foreach (var kv in map.ToArray())
        {
            if ((now - kv.Value.Wanted).TotalSeconds > 20)
            {
                Entry gone;
                if (map.TryRemove(kv.Key, out gone)) Kill(gone);
            }
        }
    }

    static void Start(string url, Entry e)
    {
        // Look like a regular player, time out stalled reads, and use the PC's
        // proxy (if it has one) the same way the browser does
        string proxy = "";
        try
        {
            var target = new Uri(url);
            var via = System.Net.WebRequest.GetSystemWebProxy().GetProxy(target);
            if (via != null && via != target && !via.Equals(target)) proxy = Opt("http_proxy", "\"http://" + via.Authority + "\"");
        }
        catch { }
        if (url.StartsWith("https://") && !hasHttps)
        {
            e.LastError = "This FFmpeg build can't open https streams; use a full build (e.g. gyan.dev release essentials)";
            e.RetryAt = DateTime.UtcNow.AddMinutes(5);
            e.Started = DateTime.UtcNow.AddMinutes(-1);
            return;
        }
        // Only options this build supports
        string args = "-hide_banner -nostdin -nostats -loglevel info " +
            Opt("user_agent", "\"Mozilla/5.0 (Windows NT 10.0; Win64; x64) EventWatcher\"") +
            Opt("rw_timeout", "15000000") + proxy +
            Opt("reconnect", "1") + Opt("reconnect_streamed", "1") + Opt("reconnect_delay_max", "5") +
            "-i \"" + url + "\" -vn " +
            "-af \"" + filter + "\" " +
            "-f null -";
        var psi = new ProcessStartInfo(Ffmpeg, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardError = true;   // levels are printed to stderr
        psi.CreateNoWindow = true;
        var p = new Process();
        p.StartInfo = psi;
        p.EnableRaisingEvents = true;
        p.Exited += delegate
        {
            e.RetryAt = DateTime.UtcNow.AddSeconds(15);
            string why = e.FirstError.Length > 0 && e.FirstError != e.LastError ? e.FirstError + " / " + e.LastError : e.LastError;
            try { Console.WriteLine(DateTime.Now.ToString("h:mm tt") + "  FFmpeg stopped for " + url + (why.Length > 0 ? ": " + why : "")); } catch { }
        };
        e.Proc = p;
        e.Started = DateTime.UtcNow;
        e.LevelAt = DateTime.MinValue;
        e.FirstError = ""; e.LastError = "";
        p.Start();
        Job.Add(p);
        // One dedicated reader thread per FFmpeg (thread-pool readers stall when
        // many streams run at once). Lines look like
        // "[Parsed_ametadata_2 @ ...] lavfi.astats.Overall.RMS_level=-21.5"
        var reader = new Thread(delegate ()
        {
            try
            {
                string line;
                while ((line = p.StandardError.ReadLine()) != null)
                {
                    int i = line.IndexOf(levelKey);
                    if (i < 0)
                    {
                        // Keep the last line that looks like a problem, for the page and the window
                        string l = line.ToLowerInvariant();
                        if (l.Contains("error") || l.Contains("failed") || l.Contains("refused") || l.Contains("timed out") ||
                            l.Contains("server returned") || l.Contains("invalid") || l.Contains("not found") || l.Contains("unable") ||
                            l.Contains("forbidden") || l.Contains("tls") || l.Contains("certificate") ||
                            l.Contains("no such") || l.Contains("option"))
                        {
                            // Keep the first problem line too: it usually names the cause
                            if (e.FirstError.Length == 0) e.FirstError = line.Trim();
                            e.LastError = line.Trim();
                        }
                        continue;
                    }
                    string v = line.Substring(i + levelKey.Length).Trim();
                    int cut = v.IndexOfAny(new[] { ' ', '\t' });
                    if (cut > 0) v = v.Substring(0, cut);
                    double d;
                    if (v.EndsWith("inf")) d = double.NegativeInfinity;
                    else if (!double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) continue;
                    e.Db = d;
                    e.LevelAt = DateTime.UtcNow;
                }
            }
            catch { }
        });
        reader.IsBackground = true;
        reader.Start();
    }

    static void Kill(Entry e)
    {
        try { if (e.Proc != null && !e.Proc.HasExited) e.Proc.Kill(); } catch { }
    }

    public static void StopAll()
    {
        foreach (var kv in map.ToArray()) { Entry gone; if (map.TryRemove(kv.Key, out gone)) Kill(gone); }
    }

    // {"url":{"status":"ok|connecting|offline","db":-21.5}}
    public static string Json(string[] urls)
    {
        var now = DateTime.UtcNow;
        var sb = new StringBuilder("{");
        bool first = true;
        foreach (var raw in urls)
        {
            var u = (raw ?? "").Trim();
            Entry e;
            if (u.Length == 0 || !map.TryGetValue(u, out e)) continue;
            string status;
            bool fresh = (now - e.LevelAt).TotalSeconds < 5;
            if (fresh) status = "ok";
            else if (e.Proc != null && !e.Proc.HasExited && (now - e.Started).TotalSeconds < 20) status = "connecting";
            else status = "offline";
            if (!first) sb.Append(',');
            first = false;
            sb.Append('"').Append(u.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append("\":{\"status\":\"").Append(status).Append("\",\"db\":");
            if (fresh && !double.IsInfinity(e.Db) && !double.IsNaN(e.Db)) sb.Append(e.Db.ToString("0.0", CultureInfo.InvariantCulture));
            else if (fresh) sb.Append("-120");
            else sb.Append("null");
            string err = e.FirstError.Length > 0 && e.FirstError != e.LastError ? e.FirstError + " / " + e.LastError : e.LastError;
            if (status != "ok" && err.Length > 0)
                sb.Append(",\"error\":\"").Append(err.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append('"');
            sb.Append('}');
        }
        return sb.Append('}').ToString();
    }

    // Windows job object so FFmpeg processes close when the helper window closes
    static class Job
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong a, b, c, d, e, f; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }

        static IntPtr handle = IntPtr.Zero;
        static readonly object gate = new object();

        public static void Add(Process p)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return;
            try
            {
                lock (gate)
                {
                    if (handle == IntPtr.Zero)
                    {
                        handle = CreateJobObject(IntPtr.Zero, null);
                        var info = new ExtendedLimits();
                        info.Basic.LimitFlags = 0x2000; // kill on job close
                        int len = Marshal.SizeOf(typeof(ExtendedLimits));
                        IntPtr ptr = Marshal.AllocHGlobal(len);
                        Marshal.StructureToPtr(info, ptr, false);
                        SetInformationJobObject(handle, 9, ptr, (uint)len);
                        Marshal.FreeHGlobal(ptr);
                    }
                    AssignProcessToJobObject(handle, p.Handle);
                }
            }
            catch { }
        }
    }
}
'@
[LevelMonitor]::Ffmpeg = $ffmpegPath
$ffmpegOk = [LevelMonitor]::Available()

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
} catch {
    Write-Host "Couldn't start on port $port. It may already be running in another window." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Open-Watcher
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "Event Watcher is running at http://localhost:$port/" -ForegroundColor Green
Write-Host "Closure logs: $closureFolder"
$cp = Find-CardPort
if ($cp) { Write-Host ("Card/port file: " + $cp.Name) } else { Write-Host ("Card/port file: " + $(if ($cardPortName) { $cardPortName } else { "none" }) + " not found in $root yet (checked every minute)") -ForegroundColor Yellow }
if ($ffmpegOk) { Write-Host "FFmpeg found: level meters on all live streams are available." -ForegroundColor Green; Write-Host ("  " + [LevelMonitor]::Describe()) }
elseif ([LevelMonitor]::Problem) { Write-Host ("FFmpeg found at $ffmpegPath, but " + [LevelMonitor]::Problem + ". The watcher will use browser meters.") -ForegroundColor Yellow }
else { Write-Host "FFmpeg not found at $ffmpegPath : the watcher will use browser meters." -ForegroundColor Yellow }
Write-Host "Keep this window open while you use it. Close the window to stop."
Open-Watcher

try {
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $res = $ctx.Response
    $path = $ctx.Request.Url.AbsolutePath.ToLower()
    try {
        if ($path -eq "/feed") {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [Text.Encoding]::UTF8
            $wc.Headers.Add("Cache-Control", "no-cache")
            $body = [Text.Encoding]::UTF8.GetBytes($wc.DownloadString($feedUrl))
            $res.ContentType = "text/xml; charset=utf-8"
            Write-Host ("{0:t}  Feed refreshed" -f (Get-Date))
        } elseif ($path -eq "/levels/status") {
            $body = [Text.Encoding]::UTF8.GetBytes('{"ffmpeg":' + $(if ($ffmpegOk) { 'true' } else { 'false' }) + '}')
            $res.ContentType = "application/json"
        } elseif ($path -eq "/levels") {
            if (-not $ffmpegOk) {
                $res.StatusCode = 503
                $body = [Text.Encoding]::UTF8.GetBytes('{"error":"ffmpeg not available"}')
            } else {
                # Body: one stream URL per line. Starts FFmpeg for new ones, returns levels.
                $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                $urls = $reader.ReadToEnd() -split "\r?\n" | Where-Object { $_ -match '^https?://' }
                $reader.Close()
                [LevelMonitor]::Want([string[]]$urls)
                $body = [Text.Encoding]::UTF8.GetBytes([LevelMonitor]::Json([string[]]$urls))
            }
            $res.ContentType = "application/json"
        } elseif ($path -eq "/closures") {
            $date = $ctx.Request.QueryString["date"]
            if ($date -notmatch '^\d{8}$') {
                $res.StatusCode = 400
                $body = [Text.Encoding]::UTF8.GetBytes("Bad date")
            } else {
                $file = [IO.Path]::Combine($closureFolder, "closures-" + $date + ".txt")  # works even when the I: drive is disconnected
                if (Test-Path -LiteralPath $file) {
                    # Read even while the log is being written; send only the
                    # first time-sync line and the "filtered!" lines
                    $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
                    try {
                        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default, $true)
                        $sb = New-Object Text.StringBuilder
                        $haveSync = $false
                        while (($line = $sr.ReadLine()) -ne $null) {
                            if ($line.Contains("filtered!")) {
                                [void]$sb.AppendLine($line)
                            } elseif (-not $haveSync -and $line -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]') {
                                [void]$sb.AppendLine($line)
                                $haveSync = $true
                            }
                        }
                        $sr.Close()
                    } finally {
                        $fs.Close()
                    }
                    $body = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
                    $res.ContentType = "text/plain; charset=utf-8"
                } else {
                    $res.StatusCode = 404
                    $body = [Text.Encoding]::UTF8.GetBytes("Not found: $file")
                }
            }
        } elseif ($path -eq "/cardport") {
            $f = Find-CardPort
            if ($f) {
                # Read even while another program has the file open
                $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                try {
                    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default, $true)
                    $text = $sr.ReadToEnd()
                    $sr.Close()
                } finally { $fs.Close() }
                $body = [Text.Encoding]::UTF8.GetBytes($text)
                $res.ContentType = "text/plain; charset=utf-8"
                $res.Headers.Add("X-File-Name", $f.Name)
                $res.Headers.Add("X-File-Time", $f.LastWriteTime.ToString("o"))
            } else {
                $res.StatusCode = 404
                $body = [Text.Encoding]::UTF8.GetBytes($(if ($cardPortName) { "$cardPortName isn't in the Event Watcher folder yet" } else { "No card/port .txt in the Event Watcher folder yet" }))
            }
        } elseif ($path -eq "/" -or $path -eq "/event-watcher.html") {
            $body = [IO.File]::ReadAllBytes($page)
            $res.ContentType = "text/html; charset=utf-8"
        } else {
            $res.StatusCode = 404
            $body = [Text.Encoding]::UTF8.GetBytes("Not found")
        }
    } catch {
        $res.StatusCode = 502
        $body = [Text.Encoding]::UTF8.GetBytes("Couldn't reach the feed: " + $_.Exception.Message)
        Write-Host ("{0:t}  Feed error: {1}" -f (Get-Date), $_.Exception.Message) -ForegroundColor Yellow
    }
    $res.Headers.Add("Cache-Control", "no-store")
    $res.ContentLength64 = $body.Length
    $res.OutputStream.Write($body, 0, $body.Length)
    $res.Close()
}
} finally {
    [LevelMonitor]::StopAll()
}
