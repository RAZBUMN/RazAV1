<#
  av1_helper.ps1  -  helper and GUI for master_encode.bat  [RazAV1 1.0]

  Keep this file next to master_encode.bat, with the profiles folder beside them.
  bin, tables and vs folders next to it [the portable pack] are used before any installed copies.
  Start the GUI with "RazAV1.cmd" (or: powershell -STA -File av1_helper.ps1 -Mode gui).

  Modes
    analyze    one decode of the film: scene cuts plus a grain sample every second, grouped into segments,
               written as plan.csv [cuts.txt and noise.txt are kept so a second analysis is instant]
    summary    print a readable overview of plan.csv
    build      turn plan.csv into denoise.cmd (ffmpeg sendcmd file) and grain_timed.tbl (timed SVT-AV1 table)
    lookup     print "level iso hqdn3d-strengths table-path" for the segment at a given time (used by probes)
    table      print "path|exact, made, nearest or legacy|1 if the table matches HDR/SDR" for one ISO [made = generated now]
    tables     generate the baseline set of photon noise grain tables into -TableDir
    keyframes  write the frame numbers of the main scene cuts to -OutFile [for --force-key-frames]
    srcinfo    print size, HDR kind, Dolby Vision profile, mastering display, light levels and a suggested workflow
    audiolist  list the audio tracks and pick one (preferred language, not commentary, default flag, most channels)
    probes     choose probe start times: no intro or end credits, starting on scene cuts, every denoise level covered
    watch      background job: CPU enforcer (priority, EcoQoS, cores) plus progress and ETA in the window title
    notify     Windows notification and a short beep
    power      sleep the PC
    sendto     put a shortcut to the encoder in the right-click Send To menu
    estimate   size and time estimate from the probes, weighted by how much of the film each denoise level covers
    vpy        write the VapourSynth script [crop, scale, KNLMeansCL per-scene denoise] for one film
    vscheck    is VapourSynth there with KNLMeansCL and a source plugin?
    gputest    time KNLMeansCL on every OpenCL GPU and print the fastest device
    calibrate  v7: KNLMeansCL strength per denoise level that leaves as much grain as hqdn3d [cached per film]
    quality    v7: VMAF [or SSIM] of every probe against the source after the same crop and scale
    gui        the window

  plan.csv columns: start,end,noise,level,iso     (times in seconds)
  You can edit level (1-5) and iso (any of 100 to 6400) by hand in Notepad, then run build again.

  Grain tables are found by name: <width>x<height>-SRGB-ISO400.tbl [SDR], -PQ- [HDR10] and -HLG-.
  Older names keep working: ...ISO400.tbl for SDR, ...ISO400_HDR.tbl or -BT2020- for HDR10.
  When no table has the exact size, transfer and ISO, one is generated [photon noise model from libaom's
  photon_noise_table, BSD 2-Clause] and saved in tables\photon, so the folder grows with your library.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('analyze', 'summary', 'build', 'lookup', 'table', 'tables', 'keyframes', 'srcinfo', 'audiolist', 'probes', 'watch', 'notify', 'power', 'sendto', 'estimate', 'vpy', 'vscheck', 'gputest', 'calibrate', 'quality', 'gui')]
    [string]$Mode,
    [string]$Source = '',
    [string]$WorkDir = '',
    [string]$Crop = 'null',
    [string]$PreFilter = 'null',
    [double]$Duration = 0,
    [int]$BaseLevel = 3,
    [double]$SceneThreshold = 0.30,
    [double]$MinSeg = 12,
    [double]$MaxSeg = 90,
    [double]$SplitRatio = 1.4,
    [int]$MaxSamples = 8,
    [double]$SampleLen = 3.0,
    [double]$Gain = 3.0,
    [int]$MaxStep = 2,
    [string]$TableDir = 'C:\GrainTables',
    [int]$OutW = 1920,
    [int]$OutH = 1080,
    [double]$At = 0,
    [double]$Length = 0,
    [switch]$Rescan,
    [int]$Iso = 400,
    [int]$Hdr = 0,
    [string]$PlanDir = '',
    [string]$CutList = '',
    [string]$OutFile = '',
    [string]$PrefLang = 'eng',
    [string]$FlagFile = '',
    [string]$InfoFile = '',
    [string]$ProgressFile = '',
    [ValidateSet('max', 'normal', 'low', 'off')][string]$CpuMode = 'max',
    [string]$Title = '',
    [string]$Text = '',
    [string]$Action = '',
    [string]$Target = '',
    [string]$Fps = '24000/1001',
    [double]$NoiseEvery = 1.0,
    [int]$Level = 3,
    [int]$ScaleW = 0,
    [string]$CropBox = '',
    [int]$DeviceId = 0,
    [string]$HList = '0.40,0.60,0.80,1.10,1.45',
    [double]$ChromaH = 1.0,
    [string]$Denoiser = 'knlm',
    [string]$Vspipe = 'vspipe',
    [string]$PointsFile = '',
    [string]$ProbeDir = '',
    [double]$CreditsAt = 0,
    [int]$AudioKbps = 256,
    [double]$ProbeCs = 0,
    [int]$ProbeOk = 0,
    [double]$SpeedFactor = 1.15,
    [string]$Vpy = '',
    [int]$KnlD = 1,
    [int]$KnlA = 2,
    [double]$KnlScale = 1.0,
    [int]$Points = 6,
    [int]$BaseIso = 0,
    [double]$MinKfGap = 2.0,
    [double]$SoftThreshold = 0.12
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------------------------
# hqdn3d strengths per level: luma_spatial, chroma_spatial, luma_tmp, chroma_tmp.
# Levels 1-4 equal your static Digital / ISO 200 / ISO 400 / ISO 800 profiles, level 5 is heavier than any of them.
$LevelHq = @{
    1 = @(1.5, 1.2, 2.5, 2.0)
    2 = @(2.2, 1.8, 3.5, 2.7)
    3 = @(3.0, 2.5, 4.5, 3.5)
    4 = @(5.0, 4.0, 7.0, 5.5)
    5 = @(6.5, 5.2, 9.0, 7.0)
}

# Chapter names that mark end credits (only counted in the last 40% of the film) and intros (skipped anywhere)
$CreditsRx = '(?i)(^|[^a-z])(end\s*credits|closing\s*credits|credits|ending|outro|ed|next\s*episode|preview)([^a-z]|$)'
$IntroRx = '(?i)(^|[^a-z])(intro|opening|op|recap|previously|title\s*sequence|main\s*titles?)([^a-z]|$)'

# Set in the main block once -WorkDir is known
$planCsv = ''
$cutsFile = ''

# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
function Fmt3([double]$x) { return $x.ToString('0.000', $inv) }
function Fmt1([double]$x) { return $x.ToString('0.0', $inv) }

function Get-HqString([int]$level) {
    $v = $LevelHq[$level]
    return ((Fmt1 $v[0]) + ':' + (Fmt1 $v[1]) + ':' + (Fmt1 $v[2]) + ':' + (Fmt1 $v[3]))
}

# One denoise level = one octave of grain: 1 = 100, 2 = 200, 3 = 400, 4 = 800, 5 = 1600
function Get-IsoForLevel([int]$level) {
    $l = [math]::Min(5, [math]::Max(1, $level))
    return [int](400 * [math]::Pow(2, $l - 3))
}

# Grain ISO steps [the same ladder as BlueSwordM's photon noise sets]
$IsoLadder = @(100, 200, 260, 320, 400, 500, 600, 800, 1000, 1200, 1400, 1600, 3200, 6400)

# Nearest ladder step, measured in octaves
function Snap-Iso([double]$iso) {
    if ($iso -le 0) { return 400 }
    $best = $IsoLadder[0]
    $bd = [double]::MaxValue
    foreach ($v in $IsoLadder) {
        $d = [math]::Abs([math]::Log($iso / $v, 2))
        if ($d -lt $bd) { $bd = $d; $best = $v }
    }
    return [int]$best
}

function Get-Median([double[]]$values) {
    $s = @($values | Sort-Object)
    $n = $s.Count
    if ($n -eq 0) { return 0.0 }
    if (($n % 2) -eq 1) { return [double]$s[[int](($n - 1) / 2)] }
    $hi = [int]($n / 2)
    return (([double]$s[$hi - 1]) + ([double]$s[$hi])) / 2.0
}

function Format-Clock([double]$sec) {
    return ([timespan]::FromSeconds([math]::Max(0, $sec))).ToString('hh\:mm\:ss')
}

function Read-Tail([string]$path) {
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $start = [math]::Max(0, $len - 8192)
            $null = $fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($len - $start)
            $n = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        }
        finally { $fs.Close() }
    }
    catch { return '' }
}

# ---------------------------------------------------------------------------------------------
# Running ffmpeg / ffprobe and reading their output as UTF-8 (titles and paths with diacritics stay intact)
# ---------------------------------------------------------------------------------------------
function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Invoke-Native([string]$exe, [string[]]$argv, [string]$cwd = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    if ($cwd -ne '') { $psi.WorkingDirectory = $cwd }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    # In the window, keep it responsive while the program runs [GPU test, version checks, ...]
    if ($script:GuiPump) { while (-not $p.HasExited) { Pump-Ui; Start-Sleep -Milliseconds 40 } }
    $p.WaitForExit()
    return (New-Object PSObject -Property @{ Out = $outTask.Result; Err = $errTask.Result; Code = $p.ExitCode })
}

function Get-Tool([string]$name) { return (Get-Command $name -ErrorAction Stop).Source }

function Get-Json($result) {
    if ($null -eq $result -or $null -eq $result.Out -or $result.Out.Trim() -eq '') { return $null }
    return ($result.Out | ConvertFrom-Json)
}

# "34000/50000" -> 0.68, "1000" -> 1000, anything else -> 0
function To-Num($v) {
    if ($null -eq $v) { return 0.0 }
    $s = ([string]$v).Trim()
    if ($s -match '^(-?[0-9.]+)\s*/\s*([0-9.]+)$') {
        $d = [double]::Parse($Matches[2], $inv)
        if ($d -eq 0) { return 0.0 }
        return [double]::Parse($Matches[1], $inv) / $d
    }
    $r = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $inv, [ref]$r)) { return $r }
    return 0.0
}

function F4([double]$x) { return $x.ToString('0.0000', $inv) }

function Format-HM([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    return ('{0}h {1:00}m' -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60))
}

# Progress text for modes whose stdout is read by the batch file
function Say([string]$m) { [Console]::Error.WriteLine($m) }

function Clean-Text([string]$s) { return (($s -replace '[\|\r\n]', '/').Trim()) }

# ---------------------------------------------------------------------------------------------
# Noise estimator (C#): reads a mono y4m stream from ffmpeg and returns a robust noise estimate.
# Lower quartile of |Laplacian-of-Laplacian| over non-flat pixels. In tests it stays nearly flat
# across very different content and rises almost linearly with the amount of noise.
# Result unit: 10-bit luma levels.
# ---------------------------------------------------------------------------------------------
$noiseSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class GrainNoise
{
    public static string LastMessage = "";

    public static double Measure(string exe, string arguments)
    {
        LastMessage = "";
        ProcessStartInfo psi = new ProcessStartInfo(exe, arguments);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;

        StringBuilder err = new StringBuilder();
        Process p = new Process();
        p.StartInfo = psi;
        p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) { lock (err) { err.AppendLine(e.Data); } }
        };
        p.Start();
        p.BeginErrorReadLine();

        double sum = 0.0;
        int count = 0;
        try
        {
            Stream o = p.StandardOutput.BaseStream;
            string header = ReadLine(o);
            if (header == null || !header.StartsWith("YUV4MPEG2"))
            {
                LastMessage = "no video data from ffmpeg";
            }
            else
            {
                int w = 0;
                int h = 0;
                int bps = 1;
                string[] toks = header.Split(' ');
                for (int i = 0; i < toks.Length; i++)
                {
                    string t = toks[i];
                    if (t.Length > 1 && t[0] == 'W') { int.TryParse(t.Substring(1), out w); }
                    else if (t.Length > 1 && t[0] == 'H') { int.TryParse(t.Substring(1), out h); }
                    else if (t.StartsWith("Cmono") && t.Length > 5) { bps = 2; }
                }
                if (w < 16 || h < 16)
                {
                    LastMessage = "bad frame size in stream header";
                }
                else
                {
                    byte[] buf = new byte[w * h * bps];
                    int[] plane = new int[w * h];
                    int[] hist = new int[16 * 4095 + 2];
                    while (true)
                    {
                        string fl = ReadLine(o);
                        if (fl == null || !fl.StartsWith("FRAME")) { break; }
                        if (!ReadFully(o, buf, buf.Length)) { break; }
                        double v = Estimate(buf, plane, hist, w, h, bps);
                        if (v >= 0.0) { sum += v; count++; }
                    }
                }
            }
        }
        finally
        {
            try
            {
                if (!p.WaitForExit(15000)) { p.Kill(); }
                p.WaitForExit();
            }
            catch { }
        }

        if (count == 0)
        {
            lock (err) { LastMessage = LastMessage + " " + err.ToString(); }
            return -1.0;
        }
        return sum / count;
    }

    public static string ScanErr = "";

    // One ffmpeg run for the whole film: scene cuts arrive on stderr (showinfo), and a grey frame every
    // 1/sampleRate seconds arrives on stdout as y4m. Returns one noise value per grey frame (-1 = unusable).
    public static double[] Scan(string exe, string arguments, double sampleRate, double duration)
    {
        ScanErr = "";
        ProcessStartInfo psi = new ProcessStartInfo(exe, arguments);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        StringBuilder err = new StringBuilder();
        Process p = new Process();
        p.StartInfo = psi;
        p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) { lock (err) { err.AppendLine(e.Data); } }
        };
        p.Start();
        p.BeginErrorReadLine();
        System.Collections.Generic.List<double> vals = new System.Collections.Generic.List<double>();
        try
        {
            Stream o = p.StandardOutput.BaseStream;
            string header = ReadLine(o);
            if (header != null && header.StartsWith("YUV4MPEG2"))
            {
                int w = 0;
                int h = 0;
                int bps = 1;
                string[] toks = header.Split(' ');
                for (int i = 0; i < toks.Length; i++)
                {
                    string t = toks[i];
                    if (t.Length > 1 && t[0] == 'W') { int.TryParse(t.Substring(1), out w); }
                    else if (t.Length > 1 && t[0] == 'H') { int.TryParse(t.Substring(1), out h); }
                    else if (t.StartsWith("Cmono") && t.Length > 5) { bps = 2; }
                }
                if (w >= 16 && h >= 16)
                {
                    byte[] buf = new byte[w * h * bps];
                    int[] plane = new int[w * h];
                    int[] hist = new int[16 * 4095 + 2];
                    int lastPct = -1;
                    while (true)
                    {
                        string fl = ReadLine(o);
                        if (fl == null || !fl.StartsWith("FRAME")) { break; }
                        if (!ReadFully(o, buf, buf.Length)) { break; }
                        vals.Add(Estimate(buf, plane, hist, w, h, bps));
                        if (duration > 0)
                        {
                            int pct = (int)Math.Min(99.0, Math.Floor(100.0 * vals.Count / sampleRate / duration));
                            if (pct != lastPct)
                            {
                                lastPct = pct;
                                Console.Error.Write("\r  Scanning scene cuts and grain in one pass: " + pct + "%   ");
                            }
                        }
                    }
                }
            }
        }
        finally
        {
            try { p.WaitForExit(); } catch { }
        }
        Console.Error.WriteLine("\r  Scanning scene cuts and grain in one pass: done.      ");
        lock (err) { ScanErr = err.ToString(); }
        return vals.ToArray();
    }

    public static double Estimate(byte[] buf, int[] plane, int[] hist, int w, int h, int bps)
    {
        int n = w * h;
        if (bps == 2)
        {
            for (int i = 0; i < n; i++) { plane[i] = buf[2 * i] | (buf[2 * i + 1] << 8); }
        }
        else
        {
            for (int i = 0; i < n; i++) { plane[i] = buf[i]; }
        }
        return EstimatePlane(plane, hist, w, h);
    }

    // v7: grain clumps. The plane is averaged in 2x2 blocks [summed, so values stay integers] and measured
    // again; film grain is spatially correlated, and these coarser clumps are what costs the encoder bits.
    public static double EstimateCoarse(int[] plane, int[] coarse, int[] hist, int w, int h)
    {
        int cw = w / 2;
        int ch = h / 2;
        for (int y = 0; y < ch; y++)
        {
            int a = 2 * y * w;
            int b = a + w;
            int o = y * cw;
            for (int x = 0; x < cw; x++)
            {
                coarse[o + x] = plane[a + 2 * x] + plane[a + 2 * x + 1] + plane[b + 2 * x] + plane[b + 2 * x + 1];
            }
        }
        double v = EstimatePlane(coarse, hist, cw, ch);
        if (v < 0.0) { return -1.0; }
        return v / 2.0;
    }

    public static double EstimatePlane(int[] plane, int[] hist, int w, int h)
    {
        Array.Clear(hist, 0, hist.Length);
        long total = 0;
        for (int y = 1; y < h - 1; y++)
        {
            int row = y * w;
            for (int x = 1; x < w - 1; x++)
            {
                int c = row + x;
                int r = plane[c - w - 1] - 2 * plane[c - w] + plane[c - w + 1]
                      - 2 * plane[c - 1] + 4 * plane[c] - 2 * plane[c + 1]
                      + plane[c + w - 1] - 2 * plane[c + w] + plane[c + w + 1];
                if (r < 0) { r = -r; }
                if (r > 0 && r < hist.Length) { hist[r]++; total++; }
            }
        }
        if (total < 1000) { return -1.0; }
        double target = 0.25 * (double)total;
        double cum = 0.0;
        for (int i = 1; i < hist.Length; i++)
        {
            double cnt = (double)hist[i];
            if (cum + cnt >= target)
            {
                double frac = cnt > 0.0 ? (target - cum) / cnt : 0.0;
                double val = (i - 1) + frac + 0.5;
                return val / (0.3186 * 6.0);
            }
            cum += cnt;
        }
        return -1.0;
    }

    // v7: one noise value per frame [-1 = too flat to measure]. Reads any y4m the encoder pipeline can
    // produce [mono, 4:2:0, 4:2:2, 4:4:4, 8 to 16 bit]; only the luma plane is measured, chroma is skipped.
    // When Dual is set, MeasureFrames gives two values per frame: fine grain, then grain clumps
    public static bool Dual = false;

    public static double[] MeasureFrames(string exe, string arguments)
    {
        LastMessage = "";
        ProcessStartInfo psi = new ProcessStartInfo(exe, arguments);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        StringBuilder err = new StringBuilder();
        Process p = new Process();
        p.StartInfo = psi;
        p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) { lock (err) { if (err.Length < 20000) { err.AppendLine(e.Data); } } }
        };
        p.Start();
        p.BeginErrorReadLine();
        System.Collections.Generic.List<double> vals = new System.Collections.Generic.List<double>();
        try
        {
            Stream o = p.StandardOutput.BaseStream;
            string header = ReadLine(o);
            if (header == null || !header.StartsWith("YUV4MPEG2"))
            {
                LastMessage = "no video data";
            }
            else
            {
                int w = 0;
                int h = 0;
                string cs = "420";
                string[] toks = header.Split(' ');
                for (int i = 0; i < toks.Length; i++)
                {
                    string t = toks[i];
                    if (t.Length > 1 && t[0] == 'W') { int.TryParse(t.Substring(1), out w); }
                    else if (t.Length > 1 && t[0] == 'H') { int.TryParse(t.Substring(1), out h); }
                    else if (t.Length > 1 && t[0] == 'C') { cs = t.Substring(1); }
                }
                int bps = 1;
                System.Text.RegularExpressions.Match bm = System.Text.RegularExpressions.Regex.Match(cs, "(\\d+)$");
                if (cs.StartsWith("mono"))
                {
                    if (cs.Length > 4) { bps = 2; }
                }
                else if (cs.Contains("p") && bm.Success && int.Parse(bm.Groups[1].Value) > 8) { bps = 2; }
                long chroma = 0;
                int cw = (w + 1) / 2;
                int ch = (h + 1) / 2;
                if (cs.StartsWith("mono")) { chroma = 0; }
                else if (cs.StartsWith("444")) { chroma = 2L * w * h; }
                else if (cs.StartsWith("422")) { chroma = 2L * cw * h; }
                else { chroma = 2L * cw * ch; }
                if (w < 16 || h < 16)
                {
                    LastMessage = "bad frame size in stream header";
                }
                else
                {
                    byte[] buf = new byte[w * h * bps];
                    byte[] skip = new byte[Math.Max(1L, chroma * bps)];
                    int[] plane = new int[w * h];
                    int[] coarse = new int[(w / 2) * (h / 2)];
                    int[] hist = new int[16 * 4095 * 4 + 2];
                    while (true)
                    {
                        string fl = ReadLine(o);
                        if (fl == null || !fl.StartsWith("FRAME")) { break; }
                        if (!ReadFully(o, buf, buf.Length)) { break; }
                        if (chroma > 0 && !ReadFully(o, skip, (int)(chroma * bps))) { break; }
                        vals.Add(Estimate(buf, plane, hist, w, h, bps));
                        if (Dual) { vals.Add(EstimateCoarse(plane, coarse, hist, w, h)); }
                    }
                }
            }
        }
        finally
        {
            try
            {
                if (!p.WaitForExit(30000)) { p.Kill(); }
                p.WaitForExit();
            }
            catch { }
        }
        if (vals.Count == 0) { lock (err) { LastMessage = (LastMessage + " " + err.ToString()).Trim(); } }
        return vals.ToArray();
    }

    // v7: runs "a | b" without cmd.exe [no quoting trouble with .bat wrappers]. Returns b's stderr.
    public static int PipeCode = 0;
    public static string Pipe(string exeA, string argsA, string exeB, string argsB)
    {
        ProcessStartInfo pa = new ProcessStartInfo(exeA, argsA);
        pa.UseShellExecute = false;
        pa.RedirectStandardOutput = true;
        pa.RedirectStandardError = true;
        pa.CreateNoWindow = true;
        ProcessStartInfo pb = new ProcessStartInfo(exeB, argsB);
        pb.UseShellExecute = false;
        pb.RedirectStandardInput = true;
        pb.RedirectStandardOutput = true;
        pb.RedirectStandardError = true;
        pb.CreateNoWindow = true;
        StringBuilder errB = new StringBuilder();
        Process b = new Process();
        b.StartInfo = pb;
        b.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) { lock (errB) { if (errB.Length < 200000) { errB.AppendLine(e.Data); } } }
        };
        b.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { };
        Process a = new Process();
        a.StartInfo = pa;
        a.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { };
        b.Start();
        b.BeginErrorReadLine();
        b.BeginOutputReadLine();
        a.Start();
        a.BeginErrorReadLine();
        try
        {
            Stream src = a.StandardOutput.BaseStream;
            Stream dst = b.StandardInput.BaseStream;
            byte[] buf = new byte[1 << 20];
            while (true)
            {
                int n = src.Read(buf, 0, buf.Length);
                if (n <= 0) { break; }
                try { dst.Write(buf, 0, n); } catch { break; }
            }
            try { dst.Close(); } catch { }
        }
        finally
        {
            try { if (!a.WaitForExit(10000)) { a.Kill(); } } catch { }
            try { b.WaitForExit(); } catch { }
        }
        PipeCode = b.ExitCode;
        lock (errB) { return errB.ToString(); }
    }

    static string ReadLine(Stream s)
    {
        StringBuilder sb = new StringBuilder();
        while (sb.Length < 4096)
        {
            int b = s.ReadByte();
            if (b < 0) { return sb.Length == 0 ? null : sb.ToString(); }
            if (b == 10) { return sb.ToString(); }
            sb.Append((char)b);
        }
        return null;
    }

    static bool ReadFully(Stream s, byte[] buf, int count)
    {
        int got = 0;
        while (got < count)
        {
            int n = s.Read(buf, got, count - got);
            if (n <= 0) { return false; }
            got += n;
        }
        return true;
    }
}
'@

# ---------------------------------------------------------------------------------------------
# Photon noise grain tables. A port of generate_photon_noise() from libaom examples/photon_noise_table.c
# [Copyright (c) 2021, Alliance for Open Media, BSD 2-Clause]. Same float math, so the tables come out
# identical to the ones photon_noise_table writes [checked against 742 published tables].
# Transfer: 0 = sRGB [SDR], 1 = PQ [HDR10], 2 = HLG.
# ---------------------------------------------------------------------------------------------
$photonSource = @'
using System;
public static class PhotonNoise
{
    static float Pw(float a, float b) { return (float)Math.Pow(a, b); }
    static float SrgbTo(float x) { return x <= 0.04045f ? x / 12.92f : Pw((x + 0.055f) / 1.055f, 2.4f); }
    static float SrgbFrom(float l) { return l <= 0.0031308f ? 12.92f * l : 1.055f * Pw(l, 1f / 2.4f) - 0.055f; }
    const float M1 = 2610f / 16384f;
    const float M2 = 128f * 2523f / 4096f;
    const float C1 = 3424f / 4096f;
    const float C2 = 32f * 2413f / 4096f;
    const float C3 = 32f * 2392f / 4096f;
    static float PqTo(float p)
    {
        float q = Pw(p, 1f / M2);
        return Pw(Math.Max(0f, q - C1) / (C2 - C3 * q), 1f / M1);
    }
    static float PqFrom(float l)
    {
        float q = Pw(l, M1);
        return Pw((C1 + C2 * q) / (1f + C3 * q), M2);
    }
    const float HA = 0.17883277f;
    const float HB = 0.28466892f;
    const float HC = 0.55991073f;
    static float HlgTo(float h)
    {
        float lin = h <= 0.5f ? h * h / 3f : ((float)Math.Exp((h - HC) / HA) + HB) / 12f;
        return Pw(lin, 1.2f);
    }
    static float HlgFrom(float l)
    {
        l = Pw(l, 1f / 1.2f);
        return l <= 1f / 12f ? (float)Math.Sqrt(3f * l) : HA * (float)Math.Log(12f * l - HB) + HC;
    }
    static float To(int tf, float x) { return tf == 1 ? PqTo(x) : (tf == 2 ? HlgTo(x) : SrgbTo(x)); }
    static float From(int tf, float x) { return tf == 1 ? PqFrom(x) : (tf == 2 ? HlgFrom(x) : SrgbFrom(x)); }
    static float Mid(int tf) { return tf == 1 ? 26f / 10000f : (tf == 2 ? 26f / 1000f : 0.18f); }

    // 14 luma scaling points, as "x0 y0 x1 y1 ..."
    public static int[] Points(int width, int height, int iso, int tf)
    {
        const float photons = 11260f;
        const float qe = 0.20f;
        const float prnu = 0.005f;
        const float readNoise = 1.5f;
        float midExposure = 10f / (float)iso;
        float pixelArea = (36000f * 24000f) / (float)(width * height);
        float midElectrons = qe * photons * midExposure * pixelArea;
        float maxElectrons = midElectrons / Mid(tf);
        int[] o = new int[28];
        for (int i = 0; i < 14; i++)
        {
            float x = (float)i / 13f;
            float linear = To(tf, x);
            float electrons = maxElectrons * linear;
            float noise = (float)Math.Sqrt(readNoise * readNoise + electrons + (prnu * prnu * electrons * electrons));
            float linNoise = noise / maxElectrons;
            float a = Math.Max(0f, linear - 2f * linNoise);
            float b = Math.Min(1f, linear + 2f * linNoise);
            float slope = (From(tf, b) - From(tf, a)) / (b - a);
            float enc = linNoise * slope;
            o[2 * i] = (int)Math.Round((double)(255f * x), MidpointRounding.AwayFromZero);
            o[2 * i + 1] = (int)Math.Min(255.0, Math.Round((double)(255f * 7.88f * enc), MidpointRounding.AwayFromZero));
        }
        return o;
    }

    // The lines under the E line, exactly as aom's table writer prints them
    public static string[] Lines(int width, int height, int iso, int tf)
    {
        int[] p = Points(width, height, iso, tf);
        System.Text.StringBuilder sy = new System.Text.StringBuilder("\tsY 14 ");
        for (int i = 0; i < 28; i += 2) { sy.Append(' ').Append(p[i]).Append(' ').Append(p[i + 1]); }
        return new string[] { "\tp 0 6 0 8 0 1 0 0 0 0 0 0", sy.ToString(), "\tsCb 0", "\tsCr 0", "\tcY", "\tcCb 0", "\tcCr 0" };
    }
}
'@

$TfNames = @('SRGB', 'PQ', 'HLG')

function Get-PhotonLines([int]$w, [int]$h, [int]$iso, [int]$tf) {
    if (-not ('PhotonNoise' -as [type])) { Add-Type -TypeDefinition $photonSource -Language CSharp }
    return , ([PhotonNoise]::Lines($w, $h, $iso, $tf))
}

# Writes <dir>\<w>x<h>-<SRGB|PQ|HLG>-ISO<iso>.tbl and returns its path
function New-PhotonTable([int]$w, [int]$h, [int]$iso, [int]$tf, [string]$dir) {
    if ($w -lt 16 -or $h -lt 16 -or $iso -lt 25 -or $iso -gt 25600) { throw "Cannot make a grain table for ${w}x${h} ISO$iso." }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir ('{0}x{1}-{2}-ISO{3}.tbl' -f $w, $h, $TfNames[$tf], $iso)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('filmgrn1')
    $lines.Add('E 0 9223372036854775807 1 7391 1')
    foreach ($l in (Get-PhotonLines $w $h $iso $tf)) { $lines.Add($l) }
    # LF endings, like the tables photon_noise_table writes
    [System.IO.File]::WriteAllText($path, (($lines.ToArray() -join "`n") + "`n"))
    return $path
}

# Baseline sizes: 1080p and 720p in the common film ratios, 4K the same; HDR transfers only for 4K
$BaselineSdr = @('1920x1080', '1920x1040', '1920x960', '1920x816', '1920x804', '1920x800', '1440x1080', '1280x720', '1280x536',
    '3840x2160', '3840x2076', '3840x1920', '3840x1632', '3840x1608', '3840x1600')
$BaselineHdr = @('3840x2160', '3840x2076', '3840x1920', '3840x1632', '3840x1608', '3840x1600')

# Makes every missing baseline table; returns the number made
function New-BaselineTables([string]$tableDir) {
    $dir = Join-Path $tableDir 'photon'
    $made = 0
    $jobs = New-Object System.Collections.ArrayList
    foreach ($sz in $BaselineSdr) { [void]$jobs.Add(@($sz, 0)) }
    foreach ($sz in $BaselineHdr) { [void]$jobs.Add(@($sz, 1)); [void]$jobs.Add(@($sz, 2)) }
    foreach ($j in $jobs) {
        $wh = ([string]$j[0]).Split('x')
        foreach ($iso in $IsoLadder) {
            $p = Join-Path $dir ('{0}-{1}-ISO{2}.tbl' -f $j[0], $TfNames[[int]$j[1]], $iso)
            if (Test-Path -LiteralPath $p) { continue }
            [void](New-PhotonTable ([int]$wh[0]) ([int]$wh[1]) $iso ([int]$j[1]) $dir)
            $made++
        }
    }
    return $made
}

# ---------------------------------------------------------------------------------------------
# Plan file reading / writing
# ---------------------------------------------------------------------------------------------
function Read-Plan {
    if (-not (Test-Path -LiteralPath $planCsv)) { throw "plan.csv not found in $WorkDir. Run analyze first." }
    $rows = New-Object System.Collections.ArrayList
    $lineNo = 0
    foreach ($ln in (Get-Content -LiteralPath $planCsv)) {
        $lineNo++
        if ($lineNo -eq 1) { continue }
        if ($ln.Trim() -eq '') { continue }
        $f = $ln.Split(',')
        if ($f.Count -lt 5) { throw "plan.csv line ${lineNo}: expected 5 columns (start,end,noise,level,iso)." }
        try {
            $row = New-Object PSObject -Property @{
                Start = [double]::Parse($f[0].Trim(), $inv)
                End   = [double]::Parse($f[1].Trim(), $inv)
                Noise = [double]::Parse($f[2].Trim(), $inv)
                Level = [int]$f[3].Trim()
                Iso   = [int]$f[4].Trim()
            }
        }
        catch { throw "plan.csv line ${lineNo}: cannot read the numbers. Use a dot as decimal separator. ($($_.Exception.Message))" }
        if ($row.Level -lt 1 -or $row.Level -gt 5) { throw "plan.csv line ${lineNo}: level must be 1 to 5." }
        if ($row.Iso -lt 25 -or $row.Iso -gt 25600) { throw "plan.csv line ${lineNo}: iso must be between 25 and 25600 [the usual steps are 100 to 6400]." }
        if ($row.End -le $row.Start) { throw "plan.csv line ${lineNo}: end must be larger than start." }
        [void]$rows.Add($row)
    }
    if ($rows.Count -eq 0) { throw 'plan.csv has no data rows.' }
    for ($i = 1; $i -lt $rows.Count; $i++) {
        if ([math]::Abs($rows[$i].Start - $rows[$i - 1].End) -gt 0.01) {
            throw "plan.csv: row $($i + 1) does not start where row $i ends. Keep the rows contiguous."
        }
    }
    return , $rows
}

# ---------------------------------------------------------------------------------------------
# Grain tables
# ---------------------------------------------------------------------------------------------
# Transfer of a table, from its name: 0 = SDR, 1 = PQ [HDR10], 2 = HLG, 9 = SD gammas [never picked]
function Get-TableTf([string]$name) {
    if ($name -match '(?i)(_HDR\.tbl$|-PQ-|-BT2020-|smpte2084)') { return 1 }
    if ($name -match '(?i)(-HLG-|arib)') { return 2 }
    if ($name -match '(?i)bt470') { return 9 }
    return 0
}

$script:TableList = $null
function Get-TableList {
    if ($null -eq $script:TableList) {
        $script:TableList = @()
        if (Test-Path -LiteralPath $TableDir) {
            $script:TableList = @(Get-ChildItem -LiteralPath $TableDir -Recurse -Filter '*.tbl' -ErrorAction SilentlyContinue)
        }
    }
    return $script:TableList
}

# 1. a table with the exact size, transfer and ISO [your own tables first, then tables\photon]
# 2. otherwise one is generated for exactly this canvas
# 3. if that fails [read-only folder], the closest size, as before
# -Hdr: 0 = SDR, 1 = PQ, 2 = HLG
function Resolve-Table([int]$iso) {
    $tf = [math]::Max(0, [math]::Min(2, $Hdr))
    $rx = '(?i)^(\d+)x(\d+).*ISO(\d+)(_HDR)?\.tbl$'
    $exactOwn = $null
    $exactGen = $null
    foreach ($f in (Get-TableList)) {
        if ($f.Name -notmatch $rx) { continue }
        if ([int]$Matches[1] -ne $OutW -or [int]$Matches[2] -ne $OutH -or [int]$Matches[3] -ne $iso) { continue }
        if ((Get-TableTf $f.Name) -ne $tf) { continue }
        if ($f.DirectoryName -match '(?i)[\\/]photon$') { if ($null -eq $exactGen) { $exactGen = $f } }
        elseif ($null -eq $exactOwn) { $exactOwn = $f }
    }
    if ($null -ne $exactOwn) { return (New-Object PSObject -Property @{ Path = $exactOwn.FullName; Exact = $true; Made = $false; Legacy = $false; HdrMatch = $true }) }
    if ($null -ne $exactGen) { return (New-Object PSObject -Property @{ Path = $exactGen.FullName; Exact = $true; Made = $false; Legacy = $false; HdrMatch = $true }) }

    foreach ($dir in @((Join-Path $TableDir 'photon'), (Join-Path $env:TEMP 'av1_photon_tables'))) {
        try {
            $p = New-PhotonTable $OutW $OutH $iso $tf $dir
            $script:TableList = $null
            return (New-Object PSObject -Property @{ Path = $p; Exact = $true; Made = $true; Legacy = $false; HdrMatch = $true })
        }
        catch { }
    }

    # fallback: closest size, preferring the right transfer
    $best = $null
    $bestScore = [double]::MaxValue
    foreach ($f in (Get-TableList)) {
        if ($f.Name -notmatch $rx -or [int]$Matches[3] -ne $iso) { continue }
        $mw = [int]$Matches[1]
        $mh = [int]$Matches[2]
        $ftf = Get-TableTf $f.Name
        if ($ftf -eq 9) { continue }
        $score = [math]::Abs($mw - $OutW) * 4 + [math]::Abs($mh - $OutH)
        if ($ftf -ne $tf) { $score += 100000 }
        if ($score -lt $bestScore) { $bestScore = $score; $best = $f }
    }
    if ($null -ne $best) {
        return (New-Object PSObject -Property @{ Path = $best.FullName; Exact = ($bestScore -eq 0); Made = $false; Legacy = $false; HdrMatch = ((Get-TableTf $best.Name) -eq $tf) })
    }
    $legacy = Join-Path $TableDir ("iso{0}.tbl" -f $iso)
    if (Test-Path -LiteralPath $legacy) {
        return (New-Object PSObject -Property @{ Path = $legacy; Exact = $false; Made = $false; Legacy = $true; HdrMatch = ($tf -eq 0) })
    }
    throw "No ISO$iso grain table found in $TableDir, and none could be generated."
}

# Parameter lines (p, sY, sCb, ...) that sit under the first E line of a table.
function Get-TableParams([string]$path) {
    $out = New-Object System.Collections.Generic.List[string]
    $inEvent = $false
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^E\s') {
            if ($inEvent) { break }
            $inEvent = $true
            continue
        }
        if ($inEvent -and ($line.Trim() -ne '')) { $out.Add($line) }
    }
    if ($out.Count -eq 0) { throw "Could not read parameter lines from $path." }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------------------------
# analyze  (v5: one decode of the film gives both the scene cuts and the grain noise)
# ---------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------------------
# Scene cuts (v1). Every frame gets a scene score [scaled down, full frame rate]; candidates above
# 0.08 are kept with their score. "Motion around it" = the highest score within a second that is not
# itself a strong jump. A candidate is a cut when it is
#   - strong [>= -SceneThreshold] and clearly above the motion around it [x1.6], or
#   - weaker [>= -SoftThreshold] but at least 2.5x the motion within a second around it
#     [catches cuts between similar shots and in dark scenes that a fixed threshold misses].
# Flashes [two strong, similar jumps within 0.25 s: in and out of the flash] are dropped, and of two
# cuts closer than 0.5 s only the stronger is kept.
# ---------------------------------------------------------------------------------------------
function Get-SceneFilter([string]$crop, [bool]$sink = $true) {
    $f = "$crop,scale=320:-2:flags=fast_bilinear,select='gt(scene,0.08)',metadata=mode=print:key=lavfi.scene_score"
    if ($sink) { $f += ',nullsink' }
    return $f
}

# ffmpeg log -> list of @(time, score)
function Read-SceneScores([string]$log) {
    $out = New-Object System.Collections.ArrayList
    $t = -1.0
    foreach ($m in [regex]::Matches($log, '(?m)(pts_time:\s*(-?[0-9]+(?:\.[0-9]+)?))|(lavfi\.scene_score=([0-9]+(?:\.[0-9]+)?))')) {
        if ($m.Groups[2].Success) { $t = [double]::Parse($m.Groups[2].Value, $inv) }
        elseif ($m.Groups[4].Success -and $t -ge 0) {
            [void]$out.Add(@($t, [double]::Parse($m.Groups[4].Value, $inv)))
            $t = -1.0
        }
    }
    return , $out
}

function Select-Cuts($cand) {
    $n = $cand.Count
    $flash = New-Object bool[] $n
    $flashes = 0
    for ($i = 0; $i -lt $n - 1; $i++) {
        $a = $cand[$i]; $b = $cand[$i + 1]
        if (($b[0] - $a[0]) -le 0.25 -and $a[1] -ge $SceneThreshold * 0.6 -and $b[1] -ge $SceneThreshold * 0.6) {
            $r = [math]::Max($a[1], $b[1]) / [math]::Max([math]::Min($a[1], $b[1]), 0.001)
            if ($r -lt 2.0) { $flash[$i] = $true; $flash[$i + 1] = $true; $flashes++ }
        }
    }
    $picked = New-Object System.Collections.ArrayList
    $lo = 0
    for ($i = 0; $i -lt $n; $i++) {
        if ($flash[$i]) { continue }
        $t = $cand[$i][0]; $v = $cand[$i][1]
        while ($lo -lt $n -and $cand[$lo][0] -lt ($t - 1.0)) { $lo++ }
        $ctx = 0.0
        for ($j = $lo; $j -lt $n -and $cand[$j][0] -le ($t + 1.0); $j++) {
            if ($j -eq $i -or [math]::Abs($cand[$j][0] - $t) -lt 0.09 -or $cand[$j][1] -ge $SceneThreshold) { continue }
            if ($cand[$j][1] -gt $ctx) { $ctx = $cand[$j][1] }
        }
        $strong = ($v -ge $SceneThreshold) -and ($v -ge 1.6 * $ctx)
        $soft = ($v -ge $SoftThreshold) -and ($v -ge 2.5 * [math]::Max($ctx, 0.04))
        if ($strong -or $soft) { [void]$picked.Add(@($t, $v)) }
    }
    $final = New-Object System.Collections.ArrayList
    foreach ($c in $picked) {
        if ($final.Count -gt 0 -and ($c[0] - $final[$final.Count - 1][0]) -lt 0.5) {
            if ($c[1] -gt $final[$final.Count - 1][1]) { $final[$final.Count - 1] = $c }
            continue
        }
        [void]$final.Add($c)
    }
    if ($flashes -gt 0) { Write-Host ("  Ignored {0} flashes [two jumps within a quarter second]." -f $flashes) }
    return , $final
}

# cuts.txt: "time,score" per line [older files have the time only]
function Read-CutsFile([string]$path) {
    $out = New-Object System.Collections.ArrayList
    foreach ($ln in (Get-Content -LiteralPath $path)) {
        if ($ln.Trim() -eq '') { continue }
        $f = $ln.Split(',')
        $sc = 1.0
        if ($f.Count -ge 2) { $sc = [double]::Parse($f[1].Trim(), $inv) }
        [void]$out.Add(@([double]::Parse($f[0].Trim(), $inv), $sc))
    }
    return , $out
}

function Write-CutsFile([string]$path, $cuts) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cuts) { $lines.Add((Fmt3 $c[0]) + ',' + $c[1].ToString('0.000', $inv)) }
    [System.IO.File]::WriteAllLines($path, $lines.ToArray())
}

function Build-Segments($cuts, [double]$dur) {
    $segs = New-Object System.Collections.ArrayList
    $s = 0.0
    foreach ($c in $cuts) {
        if ($c -le $s) { continue }
        if ($c -ge $dur) { break }
        if (($c - $s) -ge $MinSeg) {
            [void]$segs.Add(@($s, [double]$c))
            $s = [double]$c
        }
    }
    if ((($dur - $s) -lt $MinSeg) -and ($segs.Count -gt 0)) {
        $last = $segs[$segs.Count - 1]
        $segs[$segs.Count - 1] = @($last[0], $dur)
    }
    else {
        [void]$segs.Add(@($s, $dur))
    }

    $out = New-Object System.Collections.ArrayList
    foreach ($sg in $segs) {
        $len = $sg[1] - $sg[0]
        if ($len -gt $MaxSeg) {
            $n = [int][math]::Ceiling($len / $MaxSeg)
            $step = $len / $n
            for ($i = 0; $i -lt $n; $i++) {
                [void]$out.Add(@(($sg[0] + $i * $step), ($sg[0] + ($i + 1) * $step)))
            }
        }
        else {
            [void]$out.Add($sg)
        }
    }
    return , $out
}

function Invoke-Analyze {
    if (($Source -eq '') -or (-not (Test-Path -LiteralPath $Source))) { throw 'Source file not found.' }
    if ($Duration -le 5) { throw 'Pass the film length in seconds with -Duration.' }
    $ffmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
    if (-not ('GrainNoise' -as [type])) { Add-Type -TypeDefinition $noiseSource -Language CSharp }

    $noiseFile = Join-Path $WorkDir 'noise.txt'
    $every = [math]::Max(0.25, $NoiseEvery)
    $rate = 1.0 / $every

    # 1. scene cuts + one grey frame per second, from a single decode [reused when both files exist]
    $cuts = @()
    $cutPairs = $null
    $samplesT = New-Object System.Collections.Generic.List[double]
    $samplesV = New-Object System.Collections.Generic.List[double]
    if ((Test-Path -LiteralPath $cutsFile) -and (Test-Path -LiteralPath $noiseFile) -and (-not $Rescan)) {
        $cutPairs = Read-CutsFile $cutsFile
        $cuts = @($cutPairs | ForEach-Object { [double]$_[0] })
        foreach ($ln in (Get-Content -LiteralPath $noiseFile)) {
            $f = $ln.Split(',')
            if ($f.Count -ge 2) { $samplesT.Add([double]::Parse($f[0], $inv)); $samplesV.Add([double]::Parse($f[1], $inv)) }
        }
        Write-Host ("  Reusing {0} scene cuts and {1} grain samples from the earlier scan (use -Rescan to scan again)." -f $cuts.Count, $samplesT.Count)
    }
    else {
        $rateText = $rate.ToString('0.####', $inv)
        $fc = "[0:v:0]split=2[sc][nz];[sc]" + (Get-SceneFilter $Crop) + ";[nz]$PreFilter,fps=$rateText,format=gray10le[out]"
        $argLine = "-hide_banner -nostdin -nostats -i `"$Source`" -filter_complex `"$fc`" -map `"[out]`" -an -sn -pix_fmt gray10le -strict -1 -f yuv4mpegpipe -"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $vals = [GrainNoise]::Scan($ffmpegPath, $argLine, $rate, $Duration)
        $sw.Stop()
        if ($vals.Count -eq 0) {
            $tailText = [GrainNoise]::ScanErr
            if ($tailText.Length -gt 1500) { $tailText = $tailText.Substring($tailText.Length - 1500) }
            throw ('The analysis pass produced no frames. ffmpeg said: ' + $tailText)
        }
        $cand = Read-SceneScores ([GrainNoise]::ScanErr)
        $cutPairs = Select-Cuts $cand
        Write-CutsFile $cutsFile $cutPairs
        $cuts = @($cutPairs | ForEach-Object { [double]$_[0] })
        $nl = New-Object System.Collections.Generic.List[string]
        for ($k = 0; $k -lt $vals.Count; $k++) {
            if ($vals[$k] -gt 0) {
                $samplesT.Add($k * $every)
                $samplesV.Add($vals[$k])
                $nl.Add((Fmt3 ($k * $every)) + ',' + (Fmt3 $vals[$k]))
            }
        }
        [System.IO.File]::WriteAllLines($noiseFile, $nl.ToArray())
        Write-Host ("  Found {0} scene cuts and {1} grain samples in {2}." -f $cuts.Count, $samplesT.Count, (Format-HM $sw.Elapsed.TotalSeconds))
    }
    if ($samplesT.Count -eq 0) { throw 'Noise measurement failed for every frame.' }

    # 2. segments
    $segs = Build-Segments $cuts $Duration
    Write-Host ("  Grouped into {0} segments (minimum {1} s, maximum {2} s)." -f $segs.Count, $MinSeg, $MaxSeg)

    # 3. noise per segment: the segment is cut into slices of about 12 s, each slice gets the median of its
    #    grain samples, and the segment is split wherever the noise jumps by SplitRatio or more between slices
    $sT = $samplesT.ToArray()
    $sV = $samplesV.ToArray()
    $ptr = 0
    $segs2 = New-Object System.Collections.ArrayList
    $noiseList = New-Object System.Collections.Generic.List[double]
    $failed = 0
    $splits = 0
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $s0 = [double]$segs[$i][0]
        $s1 = [double]$segs[$i][1]
        $len = $s1 - $s0
        while (($ptr -lt $sT.Length) -and ($sT[$ptr] -lt $s0)) { $ptr++ }
        $n = [int][math]::Min($MaxSamples, [math]::Max(1, [math]::Ceiling($len / 12.0)))
        $gStart = $s0
        $grp = New-Object System.Collections.Generic.List[double]
        $prevPos = $s0
        $q = $ptr
        for ($j = 0; $j -lt $n; $j++) {
            $a = $s0 + $len * $j / $n
            $b = $s0 + $len * ($j + 1) / $n
            $slice = New-Object System.Collections.Generic.List[double]
            while (($q -lt $sT.Length) -and ($sT[$q] -lt $b)) {
                if ($sT[$q] -ge $a) { $slice.Add($sV[$q]) }
                $q++
            }
            if ($slice.Count -eq 0) { continue }
            $v = Get-Median $slice.ToArray()
            $pos = ($a + $b) / 2.0
            if ($grp.Count -gt 0) {
                $gm = Get-Median $grp.ToArray()
                $ratio = [math]::Max($v, $gm) / [math]::Max([math]::Min($v, $gm), 0.01)
                $mid = ($prevPos + $pos) / 2.0
                if (($ratio -ge $SplitRatio) -and (($mid - $gStart) -ge $MinSeg) -and (($s1 - $mid) -ge $MinSeg)) {
                    [void]$segs2.Add(@($gStart, $mid))
                    $noiseList.Add((Get-Median $grp.ToArray()))
                    $gStart = $mid
                    $grp.Clear()
                    $splits++
                }
            }
            $grp.Add($v)
            $prevPos = $pos
        }
        [void]$segs2.Add(@($gStart, $s1))
        if ($grp.Count -gt 0) { $noiseList.Add((Get-Median $grp.ToArray())) } else { $noiseList.Add(-1.0); $failed++ }
    }
    if ($splits -gt 0) { Write-Host ("  Split {0} long segments where the noise changed inside them." -f $splits) }
    $segs = $segs2
    $noise = $noiseList.ToArray()
    $valid = @($noise | Where-Object { $_ -gt 0 })
    if ($valid.Count -eq 0) { throw 'Noise measurement failed for every segment.' }
    if ($failed -gt 0) { Write-Host ("  [WARNING] {0} segments had no grain sample and get the baseline level." -f $failed) }

    $median = Get-Median ([double[]]$valid)
    if ($median -lt 0.05) { $median = 0.05 }
    Write-Host ("  Median noise of the film: {0} (10-bit luma units)." -f (Fmt3 $median))

    # 4. noise -> level, relative to the film's own median. $lc keeps the unrounded value for the grain ISO.
    $lv = New-Object int[] $segs.Count
    $lc = New-Object double[] $segs.Count
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($noise[$i] -le 0) { $lv[$i] = $BaseLevel; $lc[$i] = $BaseLevel; continue }
        $ratio = [math]::Max($noise[$i], 0.01) / $median
        $lc[$i] = [math]::Min(5.0, [math]::Max(1.0, $BaseLevel + $Gain * [math]::Log($ratio, 2)))
        $off = [int][math]::Round($Gain * [math]::Log($ratio, 2))
        $lv[$i] = [math]::Min(5, [math]::Max(1, $BaseLevel + $off))
    }

    # 4b. grain ISO: one level = one octave, measured from the base ISO at the film's median, so the grain
    #     follows the film in small steps [100, 200, 260, 320, 400 ... 6400] instead of 200/400/800 only.
    #     One-scene blips are evened out, and between neighbouring scenes the grain moves at most one
    #     octave [two when both scenes are 20 s or longer: a real change, like a flashback on other stock].
    $isoBase = $BaseIso
    if ($isoBase -le 0) { $isoBase = Get-IsoForLevel $BaseLevel }
    $oc = New-Object double[] $segs.Count
    for ($i = 0; $i -lt $segs.Count; $i++) { $oc[$i] = $lc[$i] - $BaseLevel }
    if ($segs.Count -ge 3) {
        $sm2 = New-Object double[] $segs.Count
        for ($i = 0; $i -lt $segs.Count; $i++) { $sm2[$i] = $oc[$i] }
        for ($i = 1; $i -lt ($segs.Count - 1); $i++) {
            $da = $oc[$i] - $oc[$i - 1]
            $db = $oc[$i] - $oc[$i + 1]
            if ([math]::Abs($oc[$i - 1] - $oc[$i + 1]) -le 0.5 -and [math]::Sign($da) -eq [math]::Sign($db) -and [math]::Abs($da) -le 1.25 -and [math]::Abs($db) -le 1.25) {
                $sm2[$i] = ($oc[$i - 1] + $oc[$i + 1]) / 2.0
            }
        }
        $oc = $sm2
    }
    for ($i = 1; $i -lt $segs.Count; $i++) {
        $lim = 1.0
        if ((([double]$segs[$i][1] - [double]$segs[$i][0]) -ge 20) -and (([double]$segs[$i - 1][1] - [double]$segs[$i - 1][0]) -ge 20)) { $lim = 2.0 }
        $oc[$i] = [math]::Min($oc[$i - 1] + $lim, [math]::Max($oc[$i - 1] - $lim, $oc[$i]))
    }
    $isoOf = New-Object int[] $segs.Count
    for ($i = 0; $i -lt $segs.Count; $i++) { $isoOf[$i] = Snap-Iso ($isoBase * [math]::Pow(2, $oc[$i])) }

    # 5. smoothing: only remove one-segment flicker of a single level; real jumps of 2+ levels are kept
    if ($segs.Count -ge 3) {
        $sm = New-Object int[] $segs.Count
        for ($i = 0; $i -lt $segs.Count; $i++) { $sm[$i] = $lv[$i] }
        for ($i = 1; $i -lt ($segs.Count - 1); $i++) {
            if (($lv[$i - 1] -eq $lv[$i + 1]) -and ([math]::Abs($lv[$i] - $lv[$i - 1]) -eq 1)) {
                $sm[$i] = $lv[$i - 1]
            }
        }
        $lv = $sm
    }
    for ($i = 1; $i -lt $segs.Count; $i++) {
        $lo = $lv[$i - 1] - $MaxStep
        $hi = $lv[$i - 1] + $MaxStep
        $lv[$i] = [math]::Min($hi, [math]::Max($lo, $lv[$i]))
    }

    # 6. write plan.csv
    $out = @('start,end,noise,level,iso')
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $nz = $noise[$i]
        if ($nz -lt 0) { $nz = 0 }
        $out += ((Fmt3 $segs[$i][0]) + ',' + (Fmt3 $segs[$i][1]) + ',' + (Fmt3 $nz) + ',' + $lv[$i] + ',' + $isoOf[$i])
    }
    [System.IO.File]::WriteAllLines($planCsv, [string[]]$out)
    Write-Host "  Plan written: $planCsv"
}

# ---------------------------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------------------------
function Get-RowAt($rows, [double]$t) {
    foreach ($r in $rows) {
        if (($t -ge $r.Start) -and ($t -lt $r.End)) { return $r }
    }
    return $rows[$rows.Count - 1]
}

function Invoke-Summary {
    $rows = Read-Plan
    $first = [double]$rows[0].Start
    $last = [double]$rows[$rows.Count - 1].End
    $total = $last - $first
    $byLevel = @{ 1 = 0.0; 2 = 0.0; 3 = 0.0; 4 = 0.0; 5 = 0.0 }
    $byIso = @{}
    $changes = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $len = $rows[$i].End - $rows[$i].Start
        $byLevel[$rows[$i].Level] += $len
        $ik = [int]$rows[$i].Iso
        if (-not $byIso.ContainsKey($ik)) { $byIso[$ik] = 0.0 }
        $byIso[$ik] += $len
        if (($i -gt 0) -and ($rows[$i].Level -ne $rows[$i - 1].Level)) { $changes++ }
    }
    Write-Host ''
    Write-Host '  ADAPTIVE PLAN'
    Write-Host ("  {0} segments over {1}, {2} denoise level changes." -f $rows.Count, (Format-Clock $total), $changes)
    $parts = @()
    foreach ($k in 1, 2, 3, 4, 5) { $parts += ("L{0} {1}%" -f $k, (Fmt1 (100.0 * $byLevel[$k] / $total))) }
    Write-Host ('  Denoise levels: ' + ($parts -join '   '))
    $parts = @()
    foreach ($k in @($byIso.Keys | Sort-Object)) { $parts += ("ISO{0} {1}%" -f $k, (Fmt1 (100.0 * $byIso[$k] / $total))) }
    Write-Host ('  Grain ISO:      ' + ($parts -join '   '))
    Write-Host ''
    Write-Host '  Timeline, one digit per minute (denoise level 1-5):'
    $line = ''
    $lineStart = $first
    $t = $first + 30.0
    while ($t -lt $last) {
        if ($line.Length -eq 0) { $lineStart = $t - 30.0 }
        $line += [string](Get-RowAt $rows $t).Level
        if ($line.Length -ge 60) {
            Write-Host ('  ' + (Format-Clock $lineStart) + '  ' + $line)
            $line = ''
        }
        $t += 60.0
    }
    if ($line.Length -gt 0) { Write-Host ('  ' + (Format-Clock $lineStart) + '  ' + $line) }
    Write-Host ''
    Write-Host ("  Plan file (edit level and iso if you like): $planCsv")
}

# ---------------------------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------------------------
function Invoke-Build {
    $rows = Read-Plan

    # denoise.cmd for ffmpeg's sendcmd filter (targets the hqdn3d@dn instance)
    $cmd = New-Object System.Collections.Generic.List[string]
    $prev = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $lvl = [int]$rows[$i].Level
        if ($lvl -ne $prev) {
            $t = 0.0
            if ($i -gt 0) { $t = [double]$rows[$i].Start }
            $v = $LevelHq[$lvl]
            $cmd.Add((Fmt3 $t) + ' hqdn3d@dn luma_spatial ' + (Fmt1 $v[0]) + ', hqdn3d@dn chroma_spatial ' + (Fmt1 $v[1]) + ', hqdn3d@dn luma_tmp ' + (Fmt1 $v[2]) + ', hqdn3d@dn chroma_tmp ' + (Fmt1 $v[3]) + ';')
            $prev = $lvl
        }
    }
    $cmdPath = Join-Path $WorkDir 'denoise.cmd'
    [System.IO.File]::WriteAllLines($cmdPath, $cmd.ToArray())

    # grain_timed.tbl: one E event per run of rows with the same ISO tier
    $blocks = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if (($i -eq 0) -or ($rows[$i].Iso -ne $rows[$i - 1].Iso)) {
            $st = 0.0
            if ($i -gt 0) { $st = [double]$rows[$i].Start }
            [void]$blocks.Add((New-Object PSObject -Property @{ Start = $st; Iso = [int]$rows[$i].Iso }))
        }
    }
    $tables = @{}
    $warn = @()
    $made = @()
    foreach ($b in $blocks) {
        if (-not $tables.ContainsKey($b.Iso)) {
            $res = Resolve-Table $b.Iso
            $tables[$b.Iso] = Get-TableParams $res.Path
            if ($res.Made) { $made += ('ISO' + $b.Iso) }
            if (-not $res.Exact) { $warn += ("ISO{0}: no exact {1}x{2} table, using {3}" -f $b.Iso, $OutW, $OutH, $res.Path) }
            if (-not $res.HdrMatch) { $warn += ("ISO{0}: no table with the right transfer [HDR/SDR] found, so another one is used" -f $b.Iso) }
        }
    }
    $tbl = New-Object System.Collections.Generic.List[string]
    $tbl.Add('filmgrn1')
    for ($k = 0; $k -lt $blocks.Count; $k++) {
        $startTicks = [long][math]::Round([double]$blocks[$k].Start * 10000000.0)
        $endText = '9223372036854775807'
        if ($k -lt ($blocks.Count - 1)) {
            $endTicks = [long][math]::Round([double]$blocks[$k + 1].Start * 10000000.0)
            $endText = $endTicks.ToString($inv)
        }
        $seed = (7391 + 1013 * $k) % 65536
        $tbl.Add('E ' + $startTicks.ToString($inv) + ' ' + $endText + ' 1 ' + $seed + ' 1')
        foreach ($pl in $tables[$blocks[$k].Iso]) { $tbl.Add($pl) }
    }
    $tblPath = Join-Path $WorkDir 'grain_timed.tbl'
    [System.IO.File]::WriteAllLines($tblPath, $tbl.ToArray())

    Write-Host ("  Wrote {0} denoise changes: {1}" -f $cmd.Count, $cmdPath)
    Write-Host ("  Wrote {0} grain events:    {1}" -f $blocks.Count, $tblPath)
    if ($made.Count -gt 0) { Write-Host ("  Made new {0}x{1} grain tables for: {2} [saved in tables\photon]" -f $OutW, $OutH, ($made -join ', ')) }
    foreach ($w in $warn) { Write-Host "  [WARNING] $w" }
}

# ---------------------------------------------------------------------------------------------
# lookup  (stdout carries one line only: level iso hqdn3d-strengths table-path)
# ---------------------------------------------------------------------------------------------
function Invoke-Lookup {
    $rows = Read-Plan
    $mid = $At + ($Length / 2.0)
    $row = Get-RowAt $rows $mid
    $res = Resolve-Table ([int]$row.Iso)
    Write-Output ('{0} {1} {2} {3}' -f $row.Level, $row.Iso, (Get-HqString ([int]$row.Level)), $res.Path)
}

# ---------------------------------------------------------------------------------------------
# table
# ---------------------------------------------------------------------------------------------
function Invoke-Table {
    $r = Resolve-Table $Iso
    $kind = 'nearest'
    if ($r.Legacy) { $kind = 'legacy' } elseif ($r.Made) { $kind = 'made' } elseif ($r.Exact) { $kind = 'exact' }
    $m = 0
    if ($r.HdrMatch) { $m = 1 }
    Write-Output ('{0}|{1}|{2}' -f $r.Path, $kind, $m)
}

# ---------------------------------------------------------------------------------------------
# tables: the baseline set [every ladder ISO for the common sizes]
# ---------------------------------------------------------------------------------------------
function Invoke-Tables {
    $n = New-BaselineTables $TableDir
    Write-Host ("  Made {0} grain tables in {1}" -f $n, (Join-Path $TableDir 'photon'))
}

# ---------------------------------------------------------------------------------------------
# keyframes: frame numbers of the main scene cuts, for SvtAv1EncApp --force-key-frames.
# Uses cuts.txt from the adaptive analysis when it is there, otherwise scans the film once.
# Strongest cuts first, at least -MinKfGap seconds apart, and the list is kept short enough
# for the Windows command line [the gap grows until it fits].
# ---------------------------------------------------------------------------------------------
function Invoke-Keyframes {
    if ($OutFile -eq '') { throw '-OutFile is required.' }
    if ($WorkDir -eq '') { throw '-WorkDir is required.' }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
    $fp = $Fps.Split('/')
    $fpsN = To-Num $fp[0]
    $fpsD = 1.0
    if ($fp.Count -ge 2) { $fpsD = To-Num $fp[1] }
    if ($fpsN -le 0 -or $fpsD -le 0) { throw "Cannot read the frame rate '$Fps'." }
    $rate = $fpsN / $fpsD

    $cf = Join-Path $WorkDir 'cuts.txt'
    if ((Test-Path -LiteralPath $cf) -and -not $Rescan) {
        $cuts = Read-CutsFile $cf
        Write-Host ("  Using {0} scene cuts from the earlier scan." -f $cuts.Count)
    }
    else {
        if (($Source -eq '') -or (-not (Test-Path -LiteralPath $Source))) { throw 'Source file not found.' }
        $ffmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
        Write-Host '  Scanning the film for scene cuts [one pass, the encode starts right after]...'
        $argLine = '-hide_banner -nostdin -nostats -i "' + $Source + '" -map 0:v:0 -an -sn -vf "' + (Get-SceneFilter $Crop $false) + '" -f null -'
        $psi = New-Object System.Diagnostics.ProcessStartInfo($ffmpegPath, $argLine)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = [System.Diagnostics.Process]::Start($psi)
        $errText = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $cuts = Select-Cuts (Read-SceneScores $errText)
        Write-CutsFile $cf $cuts
        Write-Host ("  Found {0} scene cuts in {1}." -f $cuts.Count, (Format-HM $sw.Elapsed.TotalSeconds))
    }

    $byScore = $cuts.ToArray()
    if ($byScore.Length -gt 1) {
        $keys = [double[]]@($byScore | ForEach-Object { - [double]$_[1] })
        [Array]::Sort($keys, $byScore)
    }
    $gap = [math]::Max(0.5, $MinKfGap)
    $kfText = ''
    $kept = 0
    for ($round = 0; $round -lt 40; $round++) {
        $buckets = @{}
        $times = New-Object System.Collections.Generic.List[double]
        foreach ($c in $byScore) {
            $t = [double]$c[0]
            if ($t -lt 1.0) { continue }
            if ($Duration -gt 0 -and $t -gt ($Duration - 1.0)) { continue }
            $bi = [long][math]::Floor($t / $gap)
            $ok = $true
            foreach ($k in @(($bi - 1), $bi, ($bi + 1))) {
                if ($buckets.ContainsKey($k)) {
                    foreach ($u in $buckets[$k]) { if ([math]::Abs($u - $t) -lt $gap) { $ok = $false } }
                }
            }
            if (-not $ok) { continue }
            if (-not $buckets.ContainsKey($bi)) { $buckets[$bi] = New-Object System.Collections.Generic.List[double] }
            $buckets[$bi].Add($t)
            $times.Add($t)
        }
        $frames = @($times.ToArray() | Sort-Object | ForEach-Object { ([long][math]::Round($_ * $rate)).ToString($inv) + 'f' })
        $kfText = $frames -join ','
        $kept = $frames.Count
        if ($kfText.Length -le 3000) { break }
        $gap += 1.0
    }
    [System.IO.File]::WriteAllText($OutFile, $kfText)
    Write-Host ("  {0} keyframes placed on scene cuts [at least {1} s apart]." -f $kept, $gap.ToString('0.#', $inv))
}

# ---------------------------------------------------------------------------------------------
# srcinfo   (one line: W|H|KIND|DVPROFILE|DVCOMPAT|HDR10PLUS|SUGGEST|DURATION|MASTERING|CLL|TEXT)
# ---------------------------------------------------------------------------------------------
function Add-SideData($info, $list) {
    if ($null -eq $list) { return }
    foreach ($s in @($list)) {
        $t = [string]$s.side_data_type
        if ($t -match 'Mastering display') { if ($null -eq $info.Md) { $info.Md = $s } }
        elseif ($t -match 'Content light') { if ($null -eq $info.Cl) { $info.Cl = $s } }
        elseif ($t -match 'DOVI configuration') { if ($null -eq $info.Dv) { $info.Dv = $s } }
        elseif ($t -match '2094-40|HDR10\+') { $info.H10p = $true }
    }
}

function Get-SourceInfo([string]$path) {
    if (($path -eq '') -or (-not (Test-Path -LiteralPath $path))) { throw 'Source file not found.' }
    $ffprobe = Get-Tool 'ffprobe'
    $j = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-select_streams', 'v:0', '-show_streams', '-show_format', '-of', 'json', $path))
    if ($null -eq $j -or $null -eq $j.streams -or @($j.streams).Count -eq 0) { throw 'ffprobe found no video stream.' }
    $st = @($j.streams)[0]
    $w = [int]$st.width
    $h = [int]$st.height
    $trc = [string]$st.color_transfer
    $dur = 0.0
    if ($j.format) { $dur = To-Num $j.format.duration }

    $info = @{ Md = $null; Cl = $null; Dv = $null; H10p = $false }
    Add-SideData $info $st.side_data_list
    # HEVC sources carry the HDR metadata in the frames, not in the container
    $fj = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-select_streams', 'v:0', '-read_intervals', '%+#3', '-show_frames', '-of', 'json', $path))
    if ($null -ne $fj -and $null -ne $fj.frames) {
        foreach ($f in @($fj.frames)) { Add-SideData $info $f.side_data_list }
    }

    $kind = 'SDR'
    if ($trc -eq 'smpte2084') { $kind = 'HDR10' } elseif ($trc -eq 'arib-std-b67') { $kind = 'HLG' }
    $dvp = 0
    $dvc = 0
    if ($null -ne $info.Dv) {
        $dvp = [int](To-Num $info.Dv.dv_profile)
        $dvc = [int](To-Num $info.Dv.dv_bl_signal_compatibility_id)
        if ($dvc -eq 0) { $kind = 'DV5' }
        elseif ($kind -eq 'SDR' -and ($dvc -eq 1 -or $dvc -eq 6)) { $kind = 'HDR10' }
        elseif ($kind -eq 'SDR' -and $dvc -eq 4) { $kind = 'HLG' }
    }

    $mdcv = '-'
    if ($null -ne $info.Md) {
        $m = $info.Md
        $max = To-Num $m.max_luminance
        $gx = To-Num $m.green_x
        if ($max -gt 0 -and $gx -gt 0) {
            $mdcv = ('G({0},{1})B({2},{3})R({4},{5})WP({6},{7})L({8},{9})' -f (F4 $gx), (F4 (To-Num $m.green_y)), (F4 (To-Num $m.blue_x)), (F4 (To-Num $m.blue_y)), (F4 (To-Num $m.red_x)), (F4 (To-Num $m.red_y)), (F4 (To-Num $m.white_point_x)), (F4 (To-Num $m.white_point_y)), (F4 $max), (F4 (To-Num $m.min_luminance)))
        }
    }
    $cll = '-'
    if ($null -ne $info.Cl) {
        $mc = [int](To-Num $info.Cl.max_content)
        $ma = [int](To-Num $info.Cl.max_average)
        if ($mc -gt 0) { $cll = ('{0},{1}' -f $mc, $ma) }
    }

    $is4k = ($w -ge 2800) -or ($h -ge 1700)
    $sug = 1
    if ($kind -ne 'SDR') { $sug = 4 }
    elseif ($is4k) { $sug = 3 }
    elseif ($dur -gt 0 -and $dur -lt 4200) { $sug = 2 }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('{0}x{1}' -f $w, $h))
    if ($kind -eq 'DV5') { $parts.Add('Dolby Vision profile 5 [no HDR10 base layer]') }
    else {
        $parts.Add($kind)
        if ($dvp -gt 0) { $parts.Add(('Dolby Vision {0}.{1}' -f $dvp, $dvc)) }
    }
    if ($info.H10p) { $parts.Add('HDR10+') }
    if ($cll -ne '-') { $parts.Add(('MaxCLL {0} nits' -f $cll.Split(',')[0])) }
    if ($dur -gt 0) { $parts.Add((Format-HM $dur)) }
    $srcText = Clean-Text ($parts -join ', ')

    return (New-Object PSObject -Property @{ W = $w; H = $h; Kind = $kind; Dv = $dvp; Dvc = $dvc; H10p = [bool]$info.H10p; Suggest = $sug; Dur = $dur; Mdcv = $mdcv; Cll = $cll; Text = $srcText })
}


function Invoke-SrcInfo {
    $i = Get-SourceInfo $Source
    Write-Output ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $i.W, $i.H, $i.Kind, $i.Dv, $i.Dvc, ([int]$i.H10p), $i.Suggest, (Fmt3 $i.Dur), $i.Mdcv, $i.Cll, $i.Text)
}

# ---------------------------------------------------------------------------------------------
# audio and subtitle tracks
# ---------------------------------------------------------------------------------------------
function Get-AudioTracks([string]$path) {
    $ffprobe = Get-Tool 'ffprobe'
    $j = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-select_streams', 'a', '-show_streams', '-of', 'json', $path))
    $streams = @()
    if ($null -ne $j -and $null -ne $j.streams) { $streams = @($j.streams) }
    $tracks = New-Object System.Collections.ArrayList
    $best = -1
    $bestScore = -1
    for ($i = 0; $i -lt $streams.Count; $i++) {
        $s = $streams[$i]
        $lang = 'und'
        $trackTitle = ''
        if ($null -ne $s.tags) {
            if ($s.tags.language) { $lang = ([string]$s.tags.language).ToLower() }
            if ($s.tags.title) { $trackTitle = Clean-Text ([string]$s.tags.title) }
        }
        $isDefault = $false
        $isComment = ($trackTitle -match '(?i)comment')
        if ($null -ne $s.disposition) {
            if ([int]$s.disposition.default -eq 1) { $isDefault = $true }
            if ([int]$s.disposition.comment -eq 1) { $isComment = $true }
        }
        $ch = [int]$s.channels
        $score = $ch
        if ($PrefLang -ne '' -and $lang -eq $PrefLang.ToLower()) { $score += 1000 }
        if (-not $isComment) { $score += 500 }
        if ($isDefault) { $score += 100 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $i }
        $codec = [string]$s.codec_name
        if ($s.profile -and ([string]$s.profile) -ne 'unknown') { $codec = $codec + ' ' + (Clean-Text ([string]$s.profile)) }
        $disp = ('[{0}] {1}  {2}  {3} ch' -f $i, $lang, $codec, $ch)
        if ($trackTitle -ne '') { $disp += ('  "' + $trackTitle + '"') }
        if ($isDefault) { $disp += '  [default]' }
        [void]$tracks.Add((New-Object PSObject -Property @{ Index = $i; Lang = $lang; Codec = $codec; Ch = $ch; Title = $trackTitle; Default = $isDefault; Display = $disp }))
    }
    return (New-Object PSObject -Property @{ Tracks = $tracks; Pick = $best })
}

function Invoke-AudioList {
    $a = Get-AudioTracks $Source
    if ($a.Tracks.Count -eq 0) {
        Write-Output 'L|[no audio tracks]'
        Write-Output 'PICK|-1'
        return
    }
    foreach ($t in $a.Tracks) {
        $line = $t.Display
        if ($t.Index -eq $a.Pick) { $line += '   <- auto pick' }
        Write-Output ('L|' + $line)
        Write-Output ('T|{0}|{1}' -f $t.Index, $t.Lang)
    }
    Write-Output ('PICK|{0}' -f $a.Pick)
}

function Get-SubTracks([string]$path) {
    $ffprobe = Get-Tool 'ffprobe'
    $j = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-select_streams', 's', '-show_streams', '-of', 'json', $path))
    $streams = @()
    if ($null -ne $j -and $null -ne $j.streams) { $streams = @($j.streams) }
    $tracks = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $streams.Count; $i++) {
        $s = $streams[$i]
        $lang = 'und'
        $trackTitle = ''
        if ($null -ne $s.tags) {
            if ($s.tags.language) { $lang = ([string]$s.tags.language).ToLower() }
            if ($s.tags.title) { $trackTitle = Clean-Text ([string]$s.tags.title) }
        }
        $flags = ''
        if ($null -ne $s.disposition) {
            if ([int]$s.disposition.forced -eq 1) { $flags += '  [forced]' }
            if ([int]$s.disposition.default -eq 1) { $flags += '  [default]' }
        }
        $disp = ('[{0}] {1}  {2}' -f $i, $lang, [string]$s.codec_name)
        if ($trackTitle -ne '') { $disp += ('  "' + $trackTitle + '"') }
        $disp += $flags
        [void]$tracks.Add((New-Object PSObject -Property @{ Index = $i; Lang = $lang; Display = $disp }))
    }
    return , $tracks
}


# ---------------------------------------------------------------------------------------------
# probes   (writes start times to -OutFile, prints INFO|from|to|credits|notes)
# ---------------------------------------------------------------------------------------------
# End credits without a chapter: decode only the keyframes of the last part of the film and look for the
# long dark run at the very end (rolling credits on black). Returns the credits start, or -1.
function Find-Credits([string]$ffmpeg, [double]$dur) {
    $tail = [math]::Min($dur * 0.25, 1200.0)
    if ($tail -lt 60) { return -1.0 }
    $t0 = $dur - $tail
    $statName = 'credits_scan.txt'
    $statPath = Join-Path $WorkDir $statName
    if (Test-Path -LiteralPath $statPath) { Remove-Item -LiteralPath $statPath -Force }
    Say '  Looking for dark end credits in the last part of the film...'
    $vf = "$Crop,scale=256:-2,format=yuv420p,signalstats,metadata=mode=print:file=$statName"
    $null = Invoke-Native $ffmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-skip_frame', 'nokey', '-ss', (Fmt3 $t0), '-i', $Source, '-map', '0:v:0', '-an', '-sn', '-vf', $vf, '-f', 'null', '-') $WorkDir
    if (-not (Test-Path -LiteralPath $statPath)) { return -1.0 }

    $list = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($ln in [System.IO.File]::ReadAllLines($statPath)) {
        if ($ln -match 'pts_time:\s*([0-9]+(?:\.[0-9]+)?)') {
            if ($null -ne $cur) { [void]$list.Add($cur) }
            $cur = @{ T = [double]::Parse($Matches[1], $inv); Avg = -1.0; High = -1.0 }
        }
        elseif ($null -ne $cur -and $ln -match 'signalstats\.YAVG=([0-9.]+)') { $cur.Avg = [double]::Parse($Matches[1], $inv) }
        elseif ($null -ne $cur -and $ln -match 'signalstats\.YHIGH=([0-9.]+)') { $cur.High = [double]::Parse($Matches[1], $inv) }
    }
    if ($null -ne $cur) { [void]$list.Add($cur) }
    if ($list.Count -lt 5) { return -1.0 }
    # timestamps restart at 0 after the seek
    if ($list[0].T -lt ($t0 - 5)) { foreach ($x in $list) { $x.T = $x.T + $t0 } }
    $s = @($list | Sort-Object { $_.T })

    $start = -1.0
    for ($i = $s.Count - 1; $i -ge 0; $i--) {
        $x = $s[$i]
        if ($x.T -gt ($dur - 2)) { continue }
        $dark = (($x.Avg -ge 0) -and ($x.Avg -le 32)) -or (($x.High -ge 0) -and ($x.High -le 40))
        if ($dark) { $start = $x.T; continue }
        $ref = $dur
        $limit = 45.0
        if ($start -ge 0) { $ref = $start; $limit = 30.0 }
        if (($ref - $x.T) -gt $limit) { break }
    }
    if ($start -lt 0) { return -1.0 }
    $credLen = $dur - $start
    if ($credLen -lt 30 -or $credLen -gt 900) { return -1.0 }
    $inRun = @($s | Where-Object { $_.T -ge $start -and $_.T -le ($dur - 2) })
    $nDark = @($inRun | Where-Object { (($_.Avg -ge 0) -and ($_.Avg -le 32)) -or (($_.High -ge 0) -and ($_.High -le 40)) }).Count
    if ($inRun.Count -gt 0 -and ($nDark / $inRun.Count) -lt 0.6) { return -1.0 }
    return $start
}

# Nearest scene cut within 8 s of a time, from a short scan around it. Returns $null when there is none.
function Find-NearCut([string]$ffmpeg, [double]$p, [double]$lo, [double]$hi) {
    $ws = [math]::Max(0.0, $p - 8.0)
    $vf = "$Crop,scale=320:-2,select='gt(scene,$($SceneThreshold.ToString('0.00', $inv)))',showinfo"
    $r = Invoke-Native $ffmpeg @('-hide_banner', '-nostdin', '-ss', (Fmt3 $ws), '-t', '16', '-i', $Source, '-map', '0:v:0', '-an', '-sn', '-vf', $vf, '-f', 'null', '-')
    $best = $null
    foreach ($m in [regex]::Matches($r.Err, 'Parsed_showinfo[^\r\n]*?pts_time:\s*([0-9]+(?:\.[0-9]+)?)')) {
        $t = [double]::Parse($m.Groups[1].Value, $inv)
        if ($t -lt ($ws - 1)) { $t = $t + $ws }
        if ($t -lt $lo -or $t -gt $hi) { continue }
        if ([math]::Abs($t - $p) -gt 8.0) { continue }
        if ($null -eq $best -or [math]::Abs($t - $p) -lt [math]::Abs($best - $p)) { $best = $t }
    }
    return $best
}

function Invoke-Probes {
    if (($Source -eq '') -or (-not (Test-Path -LiteralPath $Source))) { throw 'Source file not found.' }
    if ($Duration -le 30) { throw 'Pass the film length in seconds with -Duration.' }
    if ($OutFile -eq '') { throw '-OutFile is required.' }
    $ffmpeg = Get-Tool 'ffmpeg'
    $ffprobe = Get-Tool 'ffprobe'
    $dur = $Duration
    $len = 15.0
    $count = [int][math]::Max(6, [math]::Round([math]::Max(1, [math]::Round($dur / 3600.0, 1)) * 6))
    $notes = New-Object System.Collections.Generic.List[string]

    # 1. chapters: end credits and intros
    $credAt = -1.0
    $credSrc = ''
    $excl = New-Object System.Collections.ArrayList
    try {
        $cj = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-show_chapters', '-of', 'json', $Source))
        if ($null -ne $cj -and $null -ne $cj.chapters) {
            foreach ($c in @($cj.chapters)) {
                $t = ''
                if ($null -ne $c.tags -and $c.tags.title) { $t = Clean-Text ([string]$c.tags.title) }
                if ($t -eq '') { continue }
                $cs = To-Num $c.start_time
                $ce = To-Num $c.end_time
                if (($t -match $CreditsRx) -and ($cs -gt ($dur * 0.6))) {
                    if (($credAt -lt 0) -or ($cs -lt $credAt)) { $credAt = $cs; $credSrc = "chapter '$t'" }
                }
                elseif (($t -match $IntroRx) -and ($ce -gt $cs)) {
                    [void]$excl.Add(@($cs, $ce))
                    $notes.Add("skips chapter '$t'")
                }
            }
        }
    }
    catch { }

    # 2. end credits without a chapter
    if ($credAt -lt 0) {
        try { $credAt = Find-Credits $ffmpeg $dur } catch { $credAt = -1.0 }
        if ($credAt -gt 0) { $credSrc = 'dark run at the end' }
    }
    if ($credAt -gt 0) { $notes.Insert(0, ('end credits from {0} [{1}]' -f (Format-Clock $credAt), $credSrc)) }
    else { $notes.Insert(0, 'no end credits found') }

    # 3. usable range
    $lo = $dur * 0.04
    $hiEnd = $dur * 0.95
    if ($credAt -gt 0) { $hiEnd = [math]::Min($hiEnd, $credAt) }
    $hi = $hiEnd - $len - 2.0
    if (($hi - $lo) -lt ($count * 20.0)) {
        $lo = $dur * 0.05
        $hi = $dur * 0.92 - $len
        $notes.Add('range too short, plain 5-92% range used')
    }
    if ($hi -le $lo) { $hi = $lo + 1.0 }

    # 4. evenly spaced targets, moved out of intro chapters
    $pts = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $count; $i++) { $pts.Add($lo + ($i + 0.5) * ($hi - $lo) / $count) }
    for ($i = 0; $i -lt $pts.Count; $i++) {
        foreach ($e in $excl) {
            $p = $pts[$i]
            if ((($p + $len) -gt $e[0]) -and ($p -lt $e[1])) {
                if (($e[1] + 1.0) -le $hi) { $pts[$i] = $e[1] + 1.0 }
                elseif (($e[0] - $len - 1.0) -ge $lo) { $pts[$i] = $e[0] - $len - 1.0 }
            }
        }
    }

    # 5. start each probe on a scene cut [from the plan's cut list when there is one, else a short scan]
    $cuts = $null
    $cutSrc = $CutList
    if ($cutSrc -eq '' -and $PlanDir -ne '') { $cutSrc = Join-Path $PlanDir 'cuts.txt' }
    if ($cutSrc -ne '' -and (Test-Path -LiteralPath $cutSrc)) {
        $cuts = @(Get-Content -LiteralPath $cutSrc | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [double]::Parse($_.Split(',')[0].Trim(), $inv) })
    }
    $snapped = 0
    for ($i = 0; $i -lt $pts.Count; $i++) {
        $p = $pts[$i]
        $near = $null
        if ($null -ne $cuts) {
            foreach ($c in $cuts) {
                if (($c -lt $lo) -or ($c -gt $hi) -or ([math]::Abs($c - $p) -gt 10.0)) { continue }
                if ($null -eq $near -or [math]::Abs($c - $p) -lt [math]::Abs($near - $p)) { $near = $c }
            }
        }
        else {
            [Console]::Error.Write(("`r  Finding scene cuts for the probes: {0}/{1}   " -f ($i + 1), $pts.Count))
            $near = Find-NearCut $ffmpeg $p $lo $hi
        }
        if ($null -ne $near) { $pts[$i] = $near + 0.02; $snapped++ }
    }
    if ($null -eq $cuts) { Say '' }
    $notes.Add(('{0} of {1} start on a scene cut' -f $snapped, $pts.Count))

    # 6. adaptive plan: make sure every denoise level that matters gets at least one probe
    $planPath = ''
    if ($PlanDir -ne '') { $planPath = Join-Path $PlanDir 'plan.csv' }
    if ($planPath -ne '' -and (Test-Path -LiteralPath $planPath)) {
        try {
            $script:planCsv = $planPath
            $rows = Read-Plan
            $share = @{}
            foreach ($r in $rows) {
                $a = [math]::Max($r.Start, $lo)
                $b = [math]::Min($r.End, $hi + $len)
                if ($b -gt $a) { $share[[int]$r.Level] = [double]$share[[int]$r.Level] + ($b - $a) }
            }
            $total = ($hi + $len) - $lo
            $covered = New-Object System.Collections.Generic.List[string]
            foreach ($lvl in @($share.Keys | Sort-Object)) {
                if ($share[$lvl] -lt [math]::Max(60.0, 0.02 * $total)) { continue }
                $have = $false
                foreach ($p in $pts) { if ([int](Get-RowAt $rows ($p + $len / 2)).Level -eq $lvl) { $have = $true; break } }
                if (-not $have) {
                    $bestRow = $null
                    $bestLen = 0.0
                    foreach ($r in $rows) {
                        if ([int]$r.Level -ne $lvl) { continue }
                        $a = [math]::Max($r.Start, $lo)
                        $b = [math]::Min($r.End, $hi + $len)
                        if (($b - $a) -gt $bestLen) { $bestLen = $b - $a; $bestRow = $r }
                    }
                    if ($null -ne $bestRow) {
                        $a = [math]::Max($bestRow.Start, $lo)
                        $cand = $a + 0.02
                        if ($bestLen -lt $len) { $cand = [math]::Max($lo, $a + $bestLen / 2 - $len / 2) }
                        if ($cand -gt $hi) { $cand = $hi }
                        # replace the nearest probe whose level already has two or more probes, else add one
                        $counts = @{}
                        foreach ($p in $pts) { $l = [int](Get-RowAt $rows ($p + $len / 2)).Level; $counts[$l] = [int]$counts[$l] + 1 }
                        $idx = -1
                        $bd = [double]::MaxValue
                        for ($k = 0; $k -lt $pts.Count; $k++) {
                            $l = [int](Get-RowAt $rows ($pts[$k] + $len / 2)).Level
                            if ([int]$counts[$l] -ge 2) {
                                $d = [math]::Abs($pts[$k] - $cand)
                                if ($d -lt $bd) { $bd = $d; $idx = $k }
                            }
                        }
                        if ($idx -ge 0) { $pts[$idx] = $cand } else { $pts.Add($cand) }
                    }
                }
                $covered.Add([string]$lvl)
            }
            if ($covered.Count -gt 0) { $notes.Add('denoise levels covered: ' + ($covered -join ',')) }
        }
        catch { $notes.Add('plan coverage skipped') }
    }

    # 7. sort, drop overlaps, write
    $final = New-Object System.Collections.Generic.List[double]
    foreach ($p in @($pts | Sort-Object)) {
        if ($final.Count -eq 0 -or ($p - $final[$final.Count - 1]) -ge ($len + 3.0)) { $final.Add($p) }
    }
    $fr = Get-FpsPair $Fps
    $lines = @($final | ForEach-Object { (Fmt3 $_) + ' ' + [string][long][math]::Round($_ * $fr[0] / $fr[1]) })
    [System.IO.File]::WriteAllLines($OutFile, [string[]]$lines)
    $cr = $dur
    if ($credAt -gt 0) { $cr = $credAt }
    Write-Output ('INFO|{0}|{1}|{2}|{3}' -f (Fmt3 $lo), (Fmt3 $hi), (Fmt3 $cr), (Clean-Text ($notes -join '; ')))
}

# ---------------------------------------------------------------------------------------------
# watch   (background: CPU enforcer + progress in the window title, ends when the flag file goes away)
# ---------------------------------------------------------------------------------------------
$powerSource = @'
using System;
using System.Runtime.InteropServices;
public static class Win32Power
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }
    private const int ProcessPowerThrottling = 4;
    private const uint CURRENT_VERSION = 1;
    private const uint EXECUTION_SPEED = 1;
    private const uint PROCESS_SET_INFORMATION = 0x0200;
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(IntPtr hProc, int infoClass, ref PROCESS_POWER_THROTTLING_STATE info, uint size);

    // Opts the process out of EcoQoS: Windows may no longer push it to efficiency cores or lower clocks
    public static bool StripEcoQoS(int pid)
    {
        IntPtr h = OpenProcess(PROCESS_SET_INFORMATION, false, pid);
        if (h == IntPtr.Zero) { return false; }
        try
        {
            PROCESS_POWER_THROTTLING_STATE s = new PROCESS_POWER_THROTTLING_STATE();
            s.Version = CURRENT_VERSION;
            s.ControlMask = EXECUTION_SPEED;
            s.StateMask = 0;
            return SetProcessInformation(h, ProcessPowerThrottling, ref s, (uint)Marshal.SizeOf(s));
        }
        finally { CloseHandle(h); }
    }
}
'@

function Invoke-Watch {
    if ($FlagFile -eq '') { throw '-FlagFile is required.' }
    $parentPid = 0
    try { $parentPid = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch { }

    $stripEco = ($CpuMode -eq 'max') -or ($CpuMode -eq 'normal')
    if ($stripEco -and -not ('Win32Power' -as [type])) { Add-Type -TypeDefinition $powerSource -Language CSharp }
    $prio = $null
    if ($CpuMode -eq 'max') { $prio = [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
    elseif ($CpuMode -eq 'low') { $prio = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    # All logical processors, worked out for this PC [the old enforcer had 24 cores hard-coded]
    $mask = [long]0
    $n = [Environment]::ProcessorCount
    if ($CpuMode -eq 'max' -and $n -lt 63) { $mask = ([long]1 -shl $n) - 1 }

    $enc = [System.Text.Encoding]::Default
    try { $enc = [System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage) } catch { }
    $warned = $false
    $etaName = ''
    $etaT0 = Get-Date
    $etaO0 = 0.0

    while (Test-Path -LiteralPath $FlagFile) {
        if ($parentPid -gt 0 -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }

        if ($CpuMode -ne 'off') {
            foreach ($p in @(Get-Process -Name 'ffmpeg', 'SvtAv1EncApp' -ErrorAction SilentlyContinue)) {
                try {
                    # the crop scan starts and ends short ffmpeg runs all the time: skip ones that are already gone
                    if ($p.HasExited) { continue }
                    if ($stripEco) { [void][Win32Power]::StripEcoQoS($p.Id) }
                    if ($null -ne $prio -and $p.PriorityClass -ne $prio) { $p.PriorityClass = $prio }
                    if ($mask -ne 0 -and $null -ne $p.ProcessorAffinity -and $p.ProcessorAffinity.ToInt64() -ne $mask) { $p.ProcessorAffinity = [IntPtr]$mask }
                }
                catch {
                    if ($p.HasExited) { continue }
                    if (-not $warned) { Say ('[CPU] Could not tune ' + $p.ProcessName + ': ' + $_.Exception.Message); $warned = $true }
                }
            }
        }

        try {
            if (($ProgressFile -ne '') -and ($InfoFile -ne '') -and (Test-Path -LiteralPath $ProgressFile) -and (Test-Path -LiteralPath $InfoFile)) {
                $info = ([System.IO.File]::ReadAllText($InfoFile, $enc)).Trim().Split('|')
                $tail = Read-Tail $ProgressFile
                $ms = [regex]::Matches($tail, 'out_time_us=(\d+)')
                $ended = ($tail -match 'progress=end\s*$')
                if ($info.Count -ge 3 -and $ms.Count -gt 0 -and -not $ended) {
                    $name = $info[1]
                    $durS = To-Num $info[2]
                    $o = [double]$ms[$ms.Count - 1].Groups[1].Value / 1000000.0
                    if ($durS -gt 0) {
                        $pct = [math]::Min(99.9, 100.0 * $o / $durS)
                        if ($name -ne $etaName) { $etaName = $name; $etaT0 = Get-Date; $etaO0 = $o }
                        $eta = ''
                        $el = ((Get-Date) - $etaT0).TotalSeconds
                        if ($el -gt 20 -and $o -gt $etaO0) { $eta = ' | ETA ' + (Format-HM (($durS - $o) / (($o - $etaO0) / $el))) }
                        $Host.UI.RawUI.WindowTitle = ('{0}%{1} | [{2}] {3} | AV1 encoder' -f $pct.ToString('0.0', $inv), $eta, $info[0], $name)
                    }
                }
            }
        }
        catch { }

        Start-Sleep -Seconds 3
    }
}

# ---------------------------------------------------------------------------------------------
# notify, power, sendto
# ---------------------------------------------------------------------------------------------
function Invoke-Notify {
    $shown = $false
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [System.Security.SecurityElement]::Escape($Title)
        $b = [System.Security.SecurityElement]::Escape($Text)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
        $shown = $true
    }
    catch { }
    if (-not $shown) {
        try {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Icon = [System.Drawing.SystemIcons]::Information
            $ni.BalloonTipTitle = $Title
            $ni.BalloonTipText = $Text
            $ni.Visible = $true
            $ni.ShowBalloonTip(8000)
            Start-Sleep -Seconds 8
            $ni.Dispose()
        }
        catch { }
    }
    try { [Console]::Beep(880, 250); [Console]::Beep(1175, 350) } catch { }
}

function Invoke-Power {
    if ($Action -ne 'sleep') { throw 'Only -Action sleep is supported.' }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)
}

function Invoke-SendTo {
    if (($Target -eq '') -or (-not (Test-Path -LiteralPath $Target))) { throw 'Target script not found.' }
    $dir = [Environment]::GetFolderPath('SendTo')
    $lnk = Join-Path $dir 'RazAV1.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $Target
    $s.WorkingDirectory = Split-Path -Parent $Target
    $s.Description = 'Encode the selected videos with RazAV1'
    $s.Save()
    Write-Host "Added to Send To: $lnk"
    Write-Host 'Right-click one or more videos, or a folder, then Send to > RazAV1.'
}


# ---------------------------------------------------------------------------------------------
# Shared small things for v5: frame rate, config, profiles
# ---------------------------------------------------------------------------------------------
# "24000/1001" -> @(24000, 1001)
function Get-FpsPair([string]$f) {
    $n = 24000.0
    $d = 1001.0
    if ($f -match '^\s*([0-9.]+)\s*/\s*([0-9.]+)\s*$') {
        $n = [double]::Parse($Matches[1], $inv)
        $d = [double]::Parse($Matches[2], $inv)
    }
    elseif ($f -match '^\s*([0-9.]+)\s*$') {
        $n = [double]::Parse($Matches[1], $inv)
        $d = 1.0
    }
    if ($n -le 0 -or $d -le 0) { $n = 24000.0; $d = 1001.0 }
    return @($n, $d)
}

function Read-KeyValueFile([string]$path) {
    $h = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path)) { return $h }
    foreach ($ln in [System.IO.File]::ReadAllLines($path)) {
        $t = $ln.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $k = $t.IndexOf('=')
        if ($k -lt 1) { continue }
        $h[$t.Substring(0, $k).Trim()] = $t.Substring($k + 1).Trim()
    }
    return $h
}

$ConfigDefaults = [ordered]@{
    SVT_EXE         = 'C:\GrainTables\SvtAv1EncApp.exe'
    DIR_TABLES      = 'C:\GrainTables'
    VSPIPE          = 'vspipe'
    KNLM_DEVICE     = '0'
    PREF_LANG       = 'eng'
    AUTO_WAIT       = '60'
    DEFAULT_PROFILE = 'RAZ Triangle'
    SVT_LAST_CHECK  = ''
    UPDATE_LAST_CHECK = ''
    SETUP_SHOWN     = ''
    FFMPEG_BUILD    = ''
    VS_VERSION      = ''
    SVT_BUILT       = ''
    QUALITY         = '1'
    GUI_CONSOLE     = '0'
    UI_SCALE        = 'auto'
    UI_LAYOUT       = ''
    UI_SIMPLE       = '0'
    FIRST_CHOICE    = ''
    UI_COLS         = ''
    DEF_AUDIO_FORMAT   = 'opus'
    DEF_AUDIO_CHANNELS = 'auto'
    DEF_AUDIO_NORM     = '1'
    DEF_CROP           = 'auto'
    DEF_OUT_DIR        = ''
    DEF_OUT_NAME       = '{name}_AV1_{res}_{grain}'
    DEF_OUT_EXISTS     = 'number'
    UI_LANG            = 'en'
}

# Every profile key with the value used when a profile leaves it out [these equal the v4.3 behaviour]
$ProfileDefaults = [ordered]@{
    name              = 'Unnamed'
    description       = ''
    preset            = '5'
    crf               = '30'
    crf_tv            = '26'
    mode              = '2'
    grain             = '3'
    denoiser          = 'hqdn3d'
    knlm_h            = '0.40,0.60,0.80,1.10,1.45'
    knlm_chroma       = '1.0'
    knlm_d            = '1'
    knlm_a            = '2'
    knlm_scale        = '1.0'
    luma_bias         = '0'
    enable_qm         = '0'
    qm_min            = '8'
    sharpness         = '0'
    vb_strength       = '2'
    audio_51_kbps     = '256'
    subs              = '0'
    encoder           = 'mainline'
    stock             = '0'
    crop              = ''
    keyint            = ''
    svt_params        = ''
    resize            = ''
    tune              = ''
    vboost            = ''
    film_grain        = ''
    grain_iso         = ''
    scene_kf          = '0'
    audio_format      = ''
    audio_channels    = ''
    audio_kbps        = ''
    audio_norm        = ''
    out_dir           = ''
    out_name          = ''
    out_exists        = ''
}

# v1: the encoders the app can build and use. Mainline lives in bin [as before], forks in their own folders.
$EncoderDefs = [ordered]@{
    mainline  = @{ Id = 'mainline'; Name = 'SVT-AV1'; Short = 'SVT-AV1'; Repo = 'AOMediaCodec/SVT-AV1'; TagRx = '^v(\d+\.\d+\.\d+)$'; Dir = 'bin'; Bk = 'svt'; Cfg = 'SVT_BUILT'
        About = 'The official encoder from the Alliance for Open Media.' }
    essential = @{ Id = 'essential'; Name = 'SVT-AV1-Essential'; Short = 'Essential'; Repo = 'nekotrix/SVT-AV1-Essential'; TagRx = '^v(\d+\.\d+\.\d+)-Essential$'; Dir = 'bin\essential'; Bk = 'svt-essential'; Cfg = 'ESSENTIAL_BUILT'
        About = 'Fork by nekotrix with sensible defaults and quality-of-life options [--speed, --quality]. Its defaults are slower than mainline.' }
    hdr       = @{ Id = 'hdr'; Name = 'SVT-AV1-HDR'; Short = 'HDR'; Repo = 'juliobbv-p/svt-av1-hdr'; TagRx = '^v(\d+\.\d+\.\d+)$'; Dir = 'bin\hdr'; Bk = 'svt-hdr'; Cfg = 'HDR_BUILT'
        About = 'Fork by juliobbv, the continuation of SVT-AV1-PSY: perceptual tuning for HDR and SDR, strong on film grain [--tune grain].' }
}

function Get-EncoderDef([string]$id) {
    if ($id -ne '' -and $EncoderDefs.Contains($id)) { return $EncoderDefs[$id] }
    return $EncoderDefs['mainline']
}

function Get-Config([string]$dir) {
    $c = [ordered]@{}
    foreach ($k in $ConfigDefaults.Keys) { $c[$k] = $ConfigDefaults[$k] }
    $f = Read-KeyValueFile (Join-Path $dir 'av1_config.ini')
    foreach ($k in $f.Keys) { $c[$k] = $f[$k] }
    return $c
}

# What the portable pack folders next to the program contain. Anything found here is used first.
function Get-Bundle([string]$dir) {
    $b = New-Object PSObject -Property @{ Bin = (Join-Path $dir 'bin'); Tables = (Join-Path $dir 'tables'); Vs = (Join-Path $dir 'vs'); Ffmpeg = ''; Ffprobe = ''; Svt = ''; TableCount = 0; Vspipe = '' }
    foreach ($t in @('ffmpeg', 'ffprobe')) {
        $p = Join-Path $b.Bin ($t + '.exe')
        if (Test-Path -LiteralPath $p) { if ($t -eq 'ffmpeg') { $b.Ffmpeg = $p } else { $b.Ffprobe = $p } }
    }
    $svt = Join-Path $b.Bin 'SvtAv1EncApp.exe'
    if (Test-Path -LiteralPath $svt) { $b.Svt = $svt }
    if (Test-Path -LiteralPath $b.Tables) { $b.TableCount = @(Get-ChildItem -LiteralPath $b.Tables -Recurse -Filter '*.tbl' -ErrorAction SilentlyContinue).Count }
    foreach ($v in @('vspipe.bat', 'vspipe.exe')) {
        $p = Join-Path $b.Vs $v
        if (Test-Path -LiteralPath $p) { $b.Vspipe = $p }
    }
    return $b
}

# The values actually used: the config, with the portable pack folders taking over where they have files
function Get-EffectiveConfig([string]$dir) {
    $c = Get-Config $dir
    $b = Get-Bundle $dir
    if ($b.Ffmpeg -ne '' -and ($env:PATH -notlike ($b.Bin + ';*'))) { $env:PATH = $b.Bin + ';' + $env:PATH }
    if ($b.Svt -ne '') { $c['SVT_EXE'] = $b.Svt }
    if ($b.TableCount -gt 0) { $c['DIR_TABLES'] = $b.Tables }
    if ($b.Vspipe -ne '') { $c['VSPIPE'] = $b.Vspipe }
    return $c
}

function Save-Config([string]$dir, $c) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# RazAV1 settings. The GUI writes this file; the .bat reads it.')
    foreach ($k in $c.Keys) { $lines.Add(('{0}={1}' -f $k, $c[$k])) }
    [System.IO.File]::WriteAllLines((Join-Path $dir 'av1_config.ini'), $lines.ToArray())
}

function Get-Profiles([string]$dir) {
    $list = New-Object System.Collections.ArrayList
    $pdir = Join-Path $dir 'profiles'
    if (Test-Path -LiteralPath $pdir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pdir -Filter '*.profile' | Sort-Object Name)) {
            $p = [ordered]@{}
            foreach ($k in $ProfileDefaults.Keys) { $p[$k] = $ProfileDefaults[$k] }
            $p['name'] = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $kv = Read-KeyValueFile $f.FullName
            foreach ($k in $kv.Keys) { $p[$k] = $kv[$k] }
            [void]$list.Add($p)
        }
    }
    if ($list.Count -eq 0) {
        $p = [ordered]@{}
        foreach ($k in $ProfileDefaults.Keys) { $p[$k] = $ProfileDefaults[$k] }
        $p['name'] = 'Built-in defaults'
        [void]$list.Add($p)
    }
    return , $list
}

# ---------------------------------------------------------------------------------------------
# estimate   (prints GB|time text|method)
# Size: each probe's bitrate counts for the share of the film its denoise level covers in the plan,
#       end credits count at a quarter rate. Time: probe speed, corrected for the start-up cost of
#       short clips that the full encode only pays once.
# ---------------------------------------------------------------------------------------------
function Invoke-Estimate {
    $fr = Get-FpsPair $Fps
    $fpsV = $fr[0] / $fr[1]
    $dur = $Duration
    $cr = $CreditsAt
    if ($cr -le 0 -or $cr -gt $dur) { $cr = $dur }

    $pts = @()
    if ($PointsFile -ne '' -and (Test-Path -LiteralPath $PointsFile)) {
        $pts = @(Get-Content -LiteralPath $PointsFile | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [double]::Parse(($_.Trim() -split '\s+')[0], $inv) })
    }
    $probes = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $ProbeDir -Filter 'p_*.ivf' -ErrorAction SilentlyContinue)) {
        if ($f.Length -le 0) { continue }
        if ($f.Name -match '^p_(\d+)\.ivf$') {
            $n = [int]$Matches[1]
            $t = -1.0
            if ($n -ge 1 -and $n -le $pts.Count) { $t = $pts[$n - 1] }
            [void]$probes.Add(@($t, ($f.Length / 15.0)))
        }
    }
    $gb = 'N/A'
    $method = 'plain'
    if ($probes.Count -gt 0) {
        $all = 0.0
        foreach ($p in $probes) { $all += $p[1] }
        $mean = $all / $probes.Count
        $vid = $mean * $cr
        $planPath = ''
        if ($PlanDir -ne '') { $planPath = Join-Path $PlanDir 'plan.csv' }
        if ($planPath -ne '' -and (Test-Path -LiteralPath $planPath)) {
            try {
                $script:planCsv = $planPath
                $rows = Read-Plan
                $byLevel = @{}
                foreach ($p in $probes) {
                    if ($p[0] -lt 0) { continue }
                    $l = [int](Get-RowAt $rows ($p[0] + 7.5)).Level
                    if (-not $byLevel.ContainsKey($l)) { $byLevel[$l] = New-Object System.Collections.Generic.List[double] }
                    $byLevel[$l].Add($p[1])
                }
                $vid = 0.0
                foreach ($r in $rows) {
                    $a = [math]::Max(0.0, $r.Start)
                    $b = [math]::Min($cr, $r.End)
                    if ($b -le $a) { continue }
                    $rate = $mean
                    $l = [int]$r.Level
                    if ($byLevel.ContainsKey($l)) {
                        $sum = 0.0
                        foreach ($v in $byLevel[$l]) { $sum += $v }
                        $rate = $sum / $byLevel[$l].Count
                    }
                    $vid += $rate * ($b - $a)
                }
                $method = 'weighted by denoise level'
            }
            catch { $vid = $mean * $cr }
        }
        $vid += 0.25 * $mean * ($dur - $cr)
        $aud = $AudioKbps * 1000.0 / 8.0 * $dur
        $gb = [math]::Round(($vid + $aud) / 1GB, 2).ToString($inv)
    }
    $eta = 'N/A'
    if ($ProbeCs -gt 0 -and $ProbeOk -gt 0) {
        $speed = ($ProbeOk * 15.0 * $fpsV) / ($ProbeCs / 100.0) * $SpeedFactor
        $sec = ($dur * $fpsV) / $speed
        $eta = ('{0} at about {1} fps' -f (Format-HM $sec), [math]::Round($speed, 1).ToString($inv))
    }
    Write-Output ('{0}|{1}|{2}' -f $gb, $eta, $method)
}

# ---------------------------------------------------------------------------------------------
# VapourSynth: KNLMeansCL denoise on the GPU
# ---------------------------------------------------------------------------------------------
function PyStr([string]$s) { return "'" + $s.Replace('\', '\\').Replace("'", "\'") + "'" }

# The part every generated script shares: source, crop, scale, 16-bit working format
$VpyHead = @'
# Generated by av1_helper.ps1 for RazAV1. Safe to delete.
import vapoursynth as vs
core = vs.core

SRC = {{SRC}}
FPS_NUM = {{FPSN}}
FPS_DEN = {{FPSD}}
CROP = {{CROP}}          # (width, height, x, y) or None
SCALE_W = {{SCALEW}}     # 0 keeps the size
DEVICE_ID = {{DEVICE}}
KNL_D = {{KNLD}}         # temporal radius [frames before and after]
KNL_A = {{KNLA}}         # search radius


def arg(name, default=None):
    v = globals().get(name, default)
    if isinstance(v, bytes):
        v = v.decode('utf-8')
    return v


def load(path):
    if hasattr(core, 'lsmas'):
        return core.lsmas.LWLibavSource(path, fpsnum=FPS_NUM, fpsden=FPS_DEN)
    if hasattr(core, 'bs'):
        return core.bs.VideoSource(path, fpsnum=FPS_NUM, fpsden=FPS_DEN)
    if hasattr(core, 'ffms2'):
        return core.ffms2.Source(path, fpsnum=FPS_NUM, fpsden=FPS_DEN)
    raise vs.Error('No source plugin found. Install L-SMASH Works, BestSource or FFMS2.')


clip = load(SRC)
if CROP:
    w, h, x, y = CROP
    clip = core.std.Crop(clip, left=x, right=clip.width - x - w, top=y, bottom=clip.height - y - h)
if SCALE_W and SCALE_W != clip.width:
    nh = int(round(clip.height * SCALE_W / clip.width / 2.0)) * 2
    clip = core.resize.Lanczos(clip, width=SCALE_W, height=nh)
clip = core.resize.Point(clip, format=clip.format.replace(bits_per_sample=16, sample_type=vs.INTEGER).id)
n = clip.num_frames
'@

$VpyTemplate = $VpyHead + @'

DENOISE = {{DENOISE}}
H = [{{HLIST}}]          # KNLMeansCL strength for denoise levels 1-5
CHROMA_H = {{CHROMAH}}   # chroma strength = luma strength * this
STATIC_LEVEL = {{LEVEL}}
PLAN = {{PLAN}}          # plan.csv for per-scene levels, or None


def knl(c, level):
    h = H[level - 1]
    c = core.knlm.KNLMeansCL(c, d=KNL_D, a=KNL_A, s=4, h=h, channels='Y', device_type='gpu', device_id=DEVICE_ID)
    if CHROMA_H > 0:
        c = core.knlm.KNLMeansCL(c, d=KNL_D, a=KNL_A, s=4, h=h * CHROMA_H, channels='UV', device_type='gpu', device_id=DEVICE_ID)
    return c


r0 = int(arg('start', 0) or 0)
r1 = int(arg('end', n - 1) or (n - 1))

if arg('raw'):
    out = clip      # the reference for the quality score: same crop and scale, no denoise
elif not DENOISE:
    out = clip
elif PLAN is None:
    out = knl(clip, STATIC_LEVEL)
else:
    rows = []
    with open(PLAN, 'r') as fh:
        for i, line in enumerate(fh):
            p = line.strip().split(',')
            if i == 0 or len(p) < 4:
                continue
            rows.append((float(p[0]), float(p[1]), int(p[3])))
    fps = FPS_NUM / float(FPS_DEN)
    cache = {}
    pieces = []
    f0 = 0
    for k, (s, e, lvl) in enumerate(rows):
        f1 = n if k == len(rows) - 1 else min(n, int(round(e * fps)))
        if f1 <= f0:
            continue
        if f1 - 1 < r0 or f0 > r1:
            src = clip      # outside the frames being encoded [probes]: no need to denoise
        else:
            if lvl not in cache:
                cache[lvl] = knl(clip, lvl)
            src = cache[lvl]
        pieces.append(src[f0:f1])
        f0 = f1
        if f0 >= n:
            break
    if f0 < n:
        pieces.append(clip[f0:n])
    out = pieces[0] if len(pieces) == 1 else core.std.Splice(pieces)

out = core.resize.Point(out, format=out.format.replace(bits_per_sample=10).id, dither_type='error_diffusion')

progress = arg('progress')
if progress:
    def report(n, f):
        if n % 24 == 0:
            try:
                with open(progress, 'w') as fh:
                    fh.write('out_time_us=%d\n' % int(n * FPS_DEN * 1000000.0 / FPS_NUM))
            except Exception:
                pass
        return f
    out = core.std.ModifyFrame(out, out, report)

out.set_output()
'@

# v7 calibration: short chunks of the film, each run through KNLMeansCL at a ladder of strengths.
# Only luma comes out [10-bit grey], in the order: strength, then chunk, then frame.
$CalTemplate = $VpyHead + @'

POINTS = [{{POINTS}}]    # first frame of each chunk
LEN = {{LEN}}
SKIP = {{SKIP}}          # frames dropped at the start of each chunk [temporal filters settle first]
HGRID = [{{HGRID}}]      # 0 = no denoise [the source itself]

chunks = [clip[p:p + LEN] for p in POINTS if p >= 0 and p + LEN <= n]
allc = chunks[0] if len(chunks) == 1 else core.std.Splice(chunks)
END = LEN - KNL_D        # the last frames of a chunk would look into the next chunk, so they are left out
parts = []
for hv in HGRID:
    # one KNLMeansCL instance per strength [each one sets up OpenCL once]
    x = allc if hv <= 0 else core.knlm.KNLMeansCL(allc, d=KNL_D, a=KNL_A, s=4, h=hv, channels='Y', device_type='gpu', device_id=DEVICE_ID)
    for i in range(len(chunks)):
        parts.append(x[i * LEN + SKIP:i * LEN + END])
out = parts[0] if len(parts) == 1 else core.std.Splice(parts)
out = core.std.ShufflePlanes(out, 0, vs.GRAY)
out = core.resize.Point(out, format=vs.GRAY10, dither_type='error_diffusion')
out.set_output()
'@

function Get-CropPy([string]$box) {
    if ($box -match '^(\d+):(\d+):(\d+):(\d+)$') {
        $cw = [int]$Matches[1]; $ch = [int]$Matches[2]; $cx = [int]$Matches[3]; $cy = [int]$Matches[4]
        # 4:2:0 needs even crop values
        $cx = $cx - ($cx % 2); $cy = $cy - ($cy % 2); $cw = $cw - ($cw % 2); $ch = $ch - ($ch % 2)
        return ('({0}, {1}, {2}, {3})' -f $cw, $ch, $cx, $cy)
    }
    return 'None'
}

function Fill-VpyHead([string]$t) {
    $fr = Get-FpsPair $Fps
    $t = $t.Replace('{{SRC}}', (PyStr $Source)).Replace('{{FPSN}}', ([long]$fr[0]).ToString($inv)).Replace('{{FPSD}}', ([long]$fr[1]).ToString($inv))
    $t = $t.Replace('{{CROP}}', (Get-CropPy $CropBox)).Replace('{{SCALEW}}', $ScaleW.ToString($inv)).Replace('{{DEVICE}}', $DeviceId.ToString($inv))
    $t = $t.Replace('{{KNLD}}', ([math]::Min(3, [math]::Max(0, $KnlD))).ToString($inv)).Replace('{{KNLA}}', ([math]::Min(4, [math]::Max(1, $KnlA))).ToString($inv))
    return $t
}

function Invoke-Vpy {
    if ($OutFile -eq '') { throw '-OutFile is required.' }
    $hv = @($HList.Split(',') | ForEach-Object { (To-Num $_).ToString('0.###', $inv) })
    while ($hv.Count -lt 5) { $hv += $hv[$hv.Count - 1] }
    $plan = 'None'
    if ($PlanDir -ne '') {
        $pp = Join-Path $PlanDir 'plan.csv'
        if (Test-Path -LiteralPath $pp) { $plan = PyStr $pp }
    }
    $den = 'True'
    if ($Denoiser -ne 'knlm') { $den = 'False' }
    $lvl = [math]::Min(5, [math]::Max(1, $Level))
    $t = Fill-VpyHead $VpyTemplate
    $t = $t.Replace('{{DENOISE}}', $den)
    $t = $t.Replace('{{HLIST}}', ($hv[0..4] -join ', ')).Replace('{{CHROMAH}}', $ChromaH.ToString('0.###', $inv))
    $t = $t.Replace('{{LEVEL}}', $lvl.ToString($inv)).Replace('{{PLAN}}', $plan)
    [System.IO.File]::WriteAllText($OutFile, $t, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'OK'
}

# ---------------------------------------------------------------------------------------------
# calibrate  (v7)   prints OK|h1,h2,h3,h4,h5|text   or   FAIL|reason
# Finds the KNLMeansCL strength that leaves as much grain as each hqdn3d level does, on chunks of this
# film. hqdn3d is the reference because its levels are what the plan, the grain tables and the estimates
# were tuned for; KNLMeansCL then removes the same amount of grain but keeps edges and texture better.
# The result is cached in the plan folder and reused until the crop, scale or KNLMeansCL radius change.
# ---------------------------------------------------------------------------------------------
$CalGrid = @(0.0, 0.15, 0.2, 0.27, 0.36, 0.48, 0.64, 0.85, 1.13, 1.5, 2.0, 2.7, 3.6, 4.8, 6.4)
$CalLen = 20
$CalSkip = 6

function Get-MeanValid([double[]]$v, [int]$from, [int]$count) {
    $sum = 0.0
    $k = 0
    for ($i = $from; $i -lt ($from + $count) -and $i -lt $v.Count; $i++) {
        if ($v[$i] -gt 0) { $sum += $v[$i]; $k++ }
    }
    if ($k -eq 0) { return -1.0 }
    return $sum / $k
}

# Mean noise of the measured frames: frames $skip to $end-1 of every chunk [the same frames KNLMeansCL is measured on]
function Get-ChunkMean([double[]]$v, [int]$chunks, [int]$len, [int]$skip, [int]$end) {
    if ($v.Count -ne ($chunks * $len)) { return (Get-MeanValid $v 0 $v.Count) }
    $sum = 0.0
    $k = 0
    for ($c = 0; $c -lt $chunks; $c++) {
        for ($i = $skip; $i -lt $end; $i++) {
            $x = $v[$c * $len + $i]
            if ($x -gt 0) { $sum += $x; $k++ }
        }
    }
    if ($k -eq 0) { return -1.0 }
    return $sum / $k
}

# Strength on the ladder that leaves $target noise. $curve[0] is the source [strength 0].
# Returns @(h, capped)
function Solve-Strength([double[]]$grid, [double[]]$curve, [double]$target) {
    $m = $grid.Count - 1
    if ($target -ge $curve[0]) { return @(0.05, $false) }
    if ($target -ge $curve[1]) {
        $d = $curve[0] - $curve[1]
        $h = $grid[1]
        if ($d -gt 1e-9) { $h = $grid[1] * ($curve[0] - $target) / $d }
        return @([math]::Max(0.05, $h), $false)
    }
    for ($k = 1; $k -lt $m; $k++) {
        if ($curve[$k] -ge $target -and $target -ge $curve[$k + 1]) {
            $d = $curve[$k] - $curve[$k + 1]
            $f = 0.0
            if ($d -gt 1e-9) { $f = ($curve[$k] - $target) / $d }
            $lh = [math]::Log($grid[$k]) + $f * ([math]::Log($grid[$k + 1]) - [math]::Log($grid[$k]))
            return @([math]::Exp($lh), $false)
        }
    }
    return @($grid[$m], $true)
}

function Get-CalPoints([double]$dur, [double]$fpsV, [int]$count, [string]$cutsPath) {
    $cuts = @()
    if ($cutsPath -ne '' -and (Test-Path -LiteralPath $cutsPath)) {
        $cuts = @(Get-Content -LiteralPath $cutsPath | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [double]::Parse($_.Split(',')[0].Trim(), $inv) } | Sort-Object)
    }
    $span = ($CalLen + 2) / $fpsV
    $frames = New-Object System.Collections.Generic.List[long]
    for ($i = 0; $i -lt $count; $i++) {
        $t = $dur * (0.10 + 0.75 * ($i + 0.5) / $count)
        # Start just after a nearby scene cut, so no chunk runs across a cut [temporal filters behave differently there]
        $best = -1.0
        for ($k = 0; $k -lt $cuts.Count; $k++) {
            $c = $cuts[$k]
            if ([math]::Abs($c - $t) -gt 20) { continue }
            $next = $dur
            if ($k + 1 -lt $cuts.Count) { $next = $cuts[$k + 1] }
            if (($next - $c) -lt ($span + 0.6)) { continue }
            if ($best -lt 0 -or [math]::Abs($c - $t) -lt [math]::Abs($best - $t)) { $best = $c }
        }
        if ($best -ge 0) { $t = $best + 0.3 }
        $frames.Add([long][math]::Round($t * $fpsV))
    }
    return , $frames
}

function Invoke-Calibrate {
    if (($Source -eq '') -or (-not (Test-Path -LiteralPath $Source))) { throw 'Source file not found.' }
    if ($Duration -lt 120) { throw 'The film is too short to calibrate.' }
    if ($WorkDir -eq '') { throw '-WorkDir is required.' }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $scale = [math]::Min(3.0, [math]::Max(0.3, $KnlScale))
    $cache = Join-Path $WorkDir 'knlm_calibration.txt'
    $key = ('cal3|d={0}|a={1}|crop={2}|scale={3}|pre={4}|size={5}' -f $KnlD, $KnlA, $CropBox, $ScaleW, $PreFilter, (Get-Item -LiteralPath $Source).Length)
    if (Test-Path -LiteralPath $cache) {
        $kv = Read-KeyValueFile $cache
        if ([string]$kv['key'] -eq $key -and [string]$kv['h'] -match '^[0-9.]+(,[0-9.]+){4}$') {
            $hs = @($kv['h'].Split(',') | ForEach-Object { ((To-Num $_) * $scale).ToString('0.###', $inv) })
            Write-Output ('OK|{0}|reused the calibration for this film: {1}' -f ($hs -join ','), $kv['info'])
            return
        }
    }
    $exe = Resolve-Vspipe $Vspipe
    if ($exe -eq '') { throw 'vspipe was not found.' }
    $ffmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
    if (-not ('GrainNoise' -as [type])) { Add-Type -TypeDefinition $noiseSource -Language CSharp }
    $fr = Get-FpsPair $Fps
    $fpsV = $fr[0] / $fr[1]
    $cutsPath = Join-Path $WorkDir 'cuts.txt'
    if ($PlanDir -ne '') { $cutsPath = Join-Path $PlanDir 'cuts.txt' }
    $pts = Get-CalPoints $Duration $fpsV ([math]::Max(3, [math]::Min(12, $Points))) $cutsPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # 1. KNLMeansCL ladder on the GPU [one vspipe run]
    Say ('  Calibrating KNLMeansCL: {0} strengths on {1} chunks of the film [the first run also indexes the source]...' -f ($CalGrid.Count - 1), $pts.Count)
    $vpyPath = Join-Path $WorkDir 'calibrate.vpy'
    $gridText = (@($CalGrid | ForEach-Object { $_.ToString('0.###', $inv) }) -join ', ')
    $t = Fill-VpyHead $CalTemplate
    $t = $t.Replace('{{POINTS}}', (($pts | ForEach-Object { $_.ToString($inv) }) -join ', ')).Replace('{{LEN}}', [string]$CalLen).Replace('{{SKIP}}', [string]$CalSkip).Replace('{{HGRID}}', $gridText)
    [System.IO.File]::WriteAllText($vpyPath, $t, (New-Object System.Text.UTF8Encoding($false)))
    # every frame gives two values: fine grain and grain clumps [2x2 blocks]
    [GrainNoise]::Dual = $true
    $vals = [GrainNoise]::MeasureFrames($exe, ('-c y4m "' + $vpyPath + '" -'))
    $dClamp = [math]::Min(3, [math]::Max(0, $KnlD))
    $calEnd = $CalLen - $dClamp
    $per = $calEnd - $CalSkip
    $nv = [int]($vals.Count / 2)
    if ($nv -eq 0 -or ($nv % ($CalGrid.Count * $per)) -ne 0) {
        throw ('vspipe gave {0} frames for the calibration. {1}' -f $nv, (Clean-Text ([GrainNoise]::LastMessage)))
    }
    $fine = New-Object double[] $nv
    $clump = New-Object double[] $nv
    for ($i = 0; $i -lt $nv; $i++) { $fine[$i] = $vals[2 * $i]; $clump[$i] = $vals[2 * $i + 1] }
    $chunks = [int]($nv / ($CalGrid.Count * $per))
    $curveF = New-Object double[] $CalGrid.Count
    $curveC = New-Object double[] $CalGrid.Count
    for ($gi = 0; $gi -lt $CalGrid.Count; $gi++) {
        $curveF[$gi] = Get-MeanValid $fine ($gi * $chunks * $per) ($chunks * $per)
        $curveC[$gi] = Get-MeanValid $clump ($gi * $chunks * $per) ($chunks * $per)
        if ($curveF[$gi] -le 0 -or $curveC[$gi] -le 0) { throw 'The calibration chunks are too flat or dark to measure.' }
        # The curves can only go down as the strength goes up; this irons out measuring noise
        if ($gi -gt 0 -and $curveF[$gi] -gt $curveF[$gi - 1]) { $curveF[$gi] = $curveF[$gi - 1] }
        if ($gi -gt 0 -and $curveC[$gi] -gt $curveC[$gi - 1]) { $curveC[$gi] = $curveC[$gi - 1] }
    }

    # 2. hqdn3d at each level on the same chunks [ffmpeg, CPU]
    $targetF = New-Object double[] 6
    $targetC = New-Object double[] 6
    $inArgs = ''
    $fc = ''
    $cat = ''
    for ($c = 0; $c -lt $pts.Count; $c++) {
        $ss = ($pts[$c] / $fpsV).ToString('0.######', $inv)
        $inArgs += ('-ss {0} -i "{1}" ' -f $ss, $Source)
        $fc += ('[{0}:v:0]trim=end_frame={1},setpts=PTS-STARTPTS[c{0}];' -f $c, $CalLen)
        $cat += ('[c{0}]' -f $c)
    }
    for ($L = 1; $L -le 5; $L++) {
        Say ('  Calibrating: hqdn3d level {0} for comparison...' -f $L)
        $graph = $fc + $cat + ('concat=n={0}:v=1:a=0,{1},hqdn3d={2},extractplanes=y[o]' -f $pts.Count, $PreFilter, (Get-HqString $L))
        $argLine = '-hide_banner -nostdin -v error ' + $inArgs + '-filter_complex "' + $graph + '" -map "[o]" -pix_fmt gray10le -strict -1 -f yuv4mpegpipe -'
        $hv = [GrainNoise]::MeasureFrames($ffmpegPath, $argLine)
        $hn = [int]($hv.Count / 2)
        if ($hn -eq 0) { throw ('ffmpeg failed on hqdn3d level {0}: {1}' -f $L, (Clean-Text ([GrainNoise]::LastMessage))) }
        $hf = New-Object double[] $hn
        $hc = New-Object double[] $hn
        for ($i = 0; $i -lt $hn; $i++) { $hf[$i] = $hv[2 * $i]; $hc[$i] = $hv[2 * $i + 1] }
        $targetF[$L] = Get-ChunkMean $hf $pts.Count $CalLen $CalSkip $calEnd
        $targetC[$L] = Get-ChunkMean $hc $pts.Count $CalLen $CalSkip $calEnd
        if ($targetF[$L] -le 0 -or $targetC[$L] -le 0) { throw 'The hqdn3d comparison could not be measured.' }
    }
    [GrainNoise]::Dual = $false

    # 3. match every level: KNLMeansCL must leave no more fine grain AND no more grain clumps than hqdn3d,
    #    so each level takes the stronger of the two matches
    $hs = New-Object double[] 5
    $capped = 0
    $byClump = 0
    for ($L = 1; $L -le 5; $L++) {
        $rf = Solve-Strength $CalGrid $curveF $targetF[$L]
        $rc = Solve-Strength $CalGrid $curveC $targetC[$L]
        $hs[$L - 1] = [math]::Max([double]$rf[0], [double]$rc[0])
        if ([double]$rc[0] -gt [double]$rf[0]) { $byClump++ }
        if ($rf[1] -or $rc[1]) { $capped++ }
        if ($L -gt 1 -and $hs[$L - 1] -lt $hs[$L - 2]) { $hs[$L - 1] = $hs[$L - 2] }
    }
    $sw.Stop()
    $hText = (@($hs | ForEach-Object { $_.ToString('0.###', $inv) }) -join ',')
    $tF = (@(1..5 | ForEach-Object { $targetF[$_].ToString('0.00', $inv) }) -join '/')
    $tC = (@(1..5 | ForEach-Object { $targetC[$_].ToString('0.00', $inv) }) -join '/')
    $info = ('source grain {0} fine / {1} clumps; hqdn3d leaves {2} fine and {3} clumps; matched with h {4} [{5} of 5 set by the clumps] on {6} chunks in {7} s' -f $curveF[0].ToString('0.00', $inv), $curveC[0].ToString('0.00', $inv), $tF, $tC, ($hText.Replace(',', '/')), $byClump, $chunks, [math]::Round($sw.Elapsed.TotalSeconds))
    if ($capped -gt 0) { $info += (' [{0} of the levels needed the strongest setting tried]' -f $capped) }
    $curve = $curveF
    $lines = @(('key=' + $key), ('h=' + $hText), ('info=' + $info), ('curve_fine=' + ((@($curveF | ForEach-Object { $_.ToString('0.000', $inv) })) -join ',')), ('curve_clumps=' + ((@($curveC | ForEach-Object { $_.ToString('0.000', $inv) })) -join ',')))
    [System.IO.File]::WriteAllLines($cache, [string[]]$lines)
    $out = @($hs | ForEach-Object { ($_ * $scale).ToString('0.###', $inv) })
    $sc = ''
    if ([math]::Abs($scale - 1.0) -gt 0.001) { $sc = (' [x{0} from the profile]' -f $scale.ToString('0.##', $inv)) }
    Write-Output ('OK|{0}|{1}{2}' -f ($out -join ','), $info, $sc)
}

# ---------------------------------------------------------------------------------------------
# quality  (v7)   prints OK|VMAF|mean|worst|count   or   FAIL|reason
# Scores every probe against the source after the same crop and scale [no denoise]. Film grain synthesis
# is left out of the decoded probe, so the score shows what the encoder and the denoiser kept.
# ---------------------------------------------------------------------------------------------
# "a | b" through cmd.exe, exactly like the encode pipes vspipe into SVT-AV1. A pipe opened by .NET
# would start with a UTF-8 byte order mark after chcp 65001, which breaks the y4m stream. Returns stderr.
function Invoke-CmdPipe([string]$line) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c "' + $line + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return ([string]$errTask.Result + "`n" + [string]$outTask.Result)
}

function Invoke-Quality {
    if ($ProbeDir -eq '' -or -not (Test-Path -LiteralPath $ProbeDir)) { throw 'Probe folder not found.' }
    $ffmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
    if (-not ('GrainNoise' -as [type])) { Add-Type -TypeDefinition $noiseSource -Language CSharp }
    $filters = Invoke-Native $ffmpegPath @('-hide_banner', '-filters')
    $kind = 'SSIM'
    if ($filters.Out -match '\slibvmaf\s') { $kind = 'VMAF' }
    $fr = Get-FpsPair $Fps
    $p15 = [long][math]::Floor(15 * $fr[0] / $fr[1])
    $lines = @()
    if ($PointsFile -ne '' -and (Test-Path -LiteralPath $PointsFile)) { $lines = @(Get-Content -LiteralPath $PointsFile | Where-Object { $_.Trim() -ne '' }) }
    $vsExe = ''
    if ($Vpy -ne '' -and (Test-Path -LiteralPath $Vpy)) { $vsExe = Resolve-Vspipe $Vspipe }
    $threads = [math]::Max(2, [Environment]::ProcessorCount)
    $metric = 'ssim'
    if ($kind -eq 'VMAF') {
        $model = ''
        if ($OutW -ge 2560) { $model = 'model=version=vmaf_4k_v0.6.1:' }
        $metric = ('libvmaf={0}n_subsample=3:n_threads={1}' -f $model, $threads)
    }
    $scores = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $n = $i + 1
        $ivf = Join-Path $ProbeDir ('p_' + $n + '.ivf')
        if (-not (Test-Path -LiteralPath $ivf) -or (Get-Item -LiteralPath $ivf).Length -le 0) { continue }
        $f = $lines[$i].Trim() -split '\s+'
        $sec = (To-Num $f[0])
        $dist = '[0:v]setpts=PTS-STARTPTS,settb=AVTB,format=yuv420p10le[d];'
        $err = ''
        if ($vsExe -ne '') {
            $f0 = [long][math]::Floor($sec * $fr[0] / $fr[1])
            if ($f.Count -ge 2) { $f0 = [long](To-Num $f[1]) }
            $f1 = $f0 + $p15 - 1
            $graph = $dist + '[1:v]setpts=PTS-STARTPTS,settb=AVTB,format=yuv420p10le[r];[d][r]' + $metric
            $a = ('-c y4m -s {0} -e {1} -a raw=1 "{2}" -' -f $f0, $f1, $Vpy)
            $b = '-hide_banner -nostats -export_side_data film_grain -i "' + $ivf + '" -f yuv4mpegpipe -i - -lavfi "' + $graph + '" -f null -'
            $err = Invoke-CmdPipe ('"' + $vsExe + '" ' + $a + ' | "' + $ffmpegPath + '" ' + $b)
        }
        else {
            $ss = $sec.ToString('0.###', $inv)
            $graph = $dist + '[1:v:0]' + $PreFilter + ',setpts=PTS-STARTPTS,settb=AVTB,format=yuv420p10le[r];[d][r]' + $metric
            $r = Invoke-Native $ffmpegPath @('-hide_banner', '-nostdin', '-nostats', '-export_side_data', 'film_grain', '-i', $ivf, '-ss', $ss, '-t', '15', '-i', $Source, '-lavfi', $graph, '-f', 'null', '-')
            $err = $r.Err
        }
        $v = -1.0
        if ($kind -eq 'VMAF') {
            $m = [regex]::Match($err, 'VMAF score[:=\s]+([0-9.]+)')
            if ($m.Success) { $v = [double]::Parse($m.Groups[1].Value, $inv) }
        }
        else {
            $m = [regex]::Match($err, 'SSIM[^\r\n]*All:([0-9.]+)')
            if ($m.Success) { $v = [double]::Parse($m.Groups[1].Value, $inv) }
        }
        if ($v -lt 0) {
            $tail = Clean-Text $err
            if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
            Say ('    Probe {0}: no score [{1}]' -f $n, $tail)
            continue
        }
        $scores.Add($v)
        if ($kind -eq 'VMAF') { Say ('    Probe {0}: VMAF {1}' -f $n, $v.ToString('0.0', $inv)) }
        else { Say ('    Probe {0}: SSIM {1}' -f $n, $v.ToString('0.0000', $inv)) }
    }
    if ($scores.Count -eq 0) { Write-Output 'FAIL|no probe could be scored'; return }
    $mean = 0.0
    $worst = [double]::MaxValue
    foreach ($v in $scores) { $mean += $v; if ($v -lt $worst) { $worst = $v } }
    $mean = $mean / $scores.Count
    $fmt = '0.0'
    if ($kind -ne 'VMAF') { $fmt = '0.0000' }
    Write-Output ('OK|{0}|{1}|{2}|{3}' -f $kind, $mean.ToString($fmt, $inv), $worst.ToString($fmt, $inv), $scores.Count)
}

function Resolve-Vspipe([string]$v) {
    $p = ''
    if ($v -ne '' -and (Test-Path -LiteralPath $v)) { $p = (Resolve-Path -LiteralPath $v).Path }
    else {
        $c = Get-Command $v -ErrorAction SilentlyContinue
        if ($null -ne $c) { $p = $c.Source }
    }
    if ($p -ne '') { $p = Get-QuietWrapper $p }
    return $p
}

# Portable VapourSynth starts vspipe through vspipe.bat. A batch file that echoes its own commands would
# push that text into the video pipe, so when the first line is not silent, a silent wrapper is put around it.
function Get-QuietWrapper([string]$p) {
    if ($p -notmatch '\.(bat|cmd)$') { return $p }
    $first = ''
    foreach ($ln in [System.IO.File]::ReadAllLines($p)) { if ($ln.Trim() -ne '') { $first = $ln.Trim(); break } }
    if ($first.StartsWith('@')) { return $p }
    $q = Join-Path (Split-Path -Parent $p) 'vspipe_quiet.bat'
    try {
        [System.IO.File]::WriteAllLines($q, [string[]]@('@echo off', ('call "%~dp0' + [System.IO.Path]::GetFileName($p) + '" %*')))
        return $q
    }
    catch { return $p }
}

# Is VapourSynth there, with KNLMeansCL and a source plugin? Prints OK|path or NO|reason.
function Test-VapourSynth([string]$v) {
    $exe = Resolve-Vspipe $v
    if ($exe -eq '') { return @($false, 'vspipe was not found. Install VapourSynth or set its path in Settings.') }
    $tmp = Join-Path $env:TEMP ('av1_vscheck_' + $PID + '.vpy')
    $code = @'
import vapoursynth as vs
core = vs.core
missing = []
if not hasattr(core, 'knlm'):
    missing.append('KNLMeansCL')
if not (hasattr(core, 'lsmas') or hasattr(core, 'bs') or hasattr(core, 'ffms2')):
    missing.append('L-SMASH Works [or BestSource / FFMS2]')
if missing:
    raise vs.Error('Missing VapourSynth plugins: ' + ', '.join(missing))
core.std.BlankClip(width=64, height=64, length=1).set_output()
'@
    [System.IO.File]::WriteAllText($tmp, $code, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $r = Invoke-Native $exe @('--info', $tmp)
        if ($r.Code -ne 0) {
            $m = [regex]::Match($r.Err, 'Missing VapourSynth plugins:[^\r\n]*')
            if ($m.Success) { return @($false, $m.Value) }
            return @($false, ('vspipe failed: ' + (Clean-Text $r.Err)))
        }
        return @($true, $exe)
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Invoke-VsCheck {
    $t = Test-VapourSynth $Vspipe
    if ($t[0]) { Write-Output ('OK|' + $t[1]) } else { Write-Output ('NO|' + (Clean-Text $t[1])) }
}

# Times KNLMeansCL on each OpenCL GPU so the encoder uses the fast card, not an integrated one
function Get-GpuSpeeds([string]$v) {
    $exe = Resolve-Vspipe $v
    $res = New-Object System.Collections.ArrayList
    if ($exe -eq '') { return , $res }
    for ($id = 0; $id -le 3; $id++) {
        $tmp = Join-Path $env:TEMP ('av1_gputest_' + $PID + '_' + $id + '.vpy')
        $code = @'
import vapoursynth as vs
core = vs.core
c = core.std.BlankClip(width=1920, height=1080, format=vs.YUV420P16, length=240)
c = core.knlm.KNLMeansCL(c, d=1, a=2, s=4, h=0.8, channels='Y', device_type='gpu', device_id={{ID}})
c = core.knlm.KNLMeansCL(c, d=1, a=2, s=4, h=0.8, channels='UV', device_type='gpu', device_id={{ID}})
c.set_output()
'@
        [System.IO.File]::WriteAllText($tmp, $code.Replace('{{ID}}', [string]$id), (New-Object System.Text.UTF8Encoding($false)))
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Native $exe @($tmp, '.')
            $sw.Stop()
            if ($r.Code -eq 0) { [void]$res.Add(@($id, [math]::Round(240.0 / [math]::Max(0.01, $sw.Elapsed.TotalSeconds), 1))) }
        }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return , $res
}

function Invoke-GpuTest {
    $s = Get-GpuSpeeds $Vspipe
    $best = -1
    $bestFps = 0.0
    foreach ($x in $s) {
        Write-Output ('DEV|{0}|{1}' -f $x[0], $x[1].ToString($inv))
        if ($x[1] -gt $bestFps) { $bestFps = $x[1]; $best = $x[0] }
    }
    Write-Output ('BEST|{0}' -f $best)
}

# ---------------------------------------------------------------------------------------------
# v6: portable pack builder and SVT-AV1 updates
# ---------------------------------------------------------------------------------------------
function Pump-Ui {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Starts a program in its own visible window and keeps this window responsive until it ends
function Run-AndWait([string]$file, [string]$argLine, [string]$cwd) {
    if ($cwd -eq '') { $cwd = $env:TEMP }
    if ($argLine -eq '') { $p = Start-Process -FilePath $file -WorkingDirectory $cwd -PassThru }
    else { $p = Start-Process -FilePath $file -ArgumentList $argLine -WorkingDirectory $cwd -PassThru }
    while (-not $p.HasExited) { Pump-Ui; Start-Sleep -Milliseconds 200 }
    $p.WaitForExit()
    return $p.ExitCode
}

function Get-PackStatus([string]$dir) {
    $b = Get-Bundle $dir
    $parts = @()
    $bin = @()
    if ($b.Ffmpeg -ne '') { $bin += 'ffmpeg' }
    if ($b.Ffprobe -ne '') { $bin += 'ffprobe' }
    if ($b.Svt -ne '') {
        $v = Get-SvtVersion $b.Svt
        if ($v -ne '') { $bin += ('SVT-AV1 ' + $v) } else { $bin += 'SVT-AV1' }
    }
    if ($bin.Count -gt 0) { $parts += ('bin: ' + ($bin -join ', ')) } else { $parts += 'bin: empty' }
    $parts += ('tables: {0} grain tables' -f $b.TableCount)
    if ($b.Vspipe -ne '') { $parts += 'vs: portable VapourSynth' } else { $parts += 'vs: not built' }
    return ($parts -join '   |   ')
}

function Copy-TreeFiles([string]$src, [string]$dst, [string]$filter) {
    $n = 0
    $root = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter $filter -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $to = Join-Path $dst $rel
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Force -Path $toDir | Out-Null }
        if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $f.FullName -Destination $to; $n++ }
    }
    return $n
}


# Gathers everything this PC already uses into bin, tables and vs next to the program.
# Afterwards the whole folder can be zipped and run on another PC with nothing to install.
function Build-PortablePack {
    $here = $G.Here
    $raw = Get-Config $here
    $log = New-Object System.Collections.Generic.List[string]
    $b = Get-Bundle $here
    New-Item -ItemType Directory -Force -Path $b.Bin | Out-Null

    # 1. ffmpeg and ffprobe [plus their dlls when it is a shared build]
    foreach ($t in @('ffmpeg', 'ffprobe')) {
        $dst = Join-Path $b.Bin ($t + '.exe')
        if (Test-Path -LiteralPath $dst) { $log.Add(('{0}: already in bin' -f $t)); continue }
        $c = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $c) { $log.Add(('{0}: not found, copy {0}.exe into bin yourself' -f $t)); continue }
        Copy-Item -LiteralPath $c.Source -Destination $dst
        foreach ($d in @(Get-ChildItem -LiteralPath (Split-Path -Parent $c.Source) -Filter '*.dll' -ErrorAction SilentlyContinue)) {
            $dd = Join-Path $b.Bin $d.Name
            if (-not (Test-Path -LiteralPath $dd)) { Copy-Item -LiteralPath $d.FullName -Destination $dd }
        }
        $log.Add(('{0}: copied from {1}' -f $t, $c.Source))
    }

    # 2. SVT-AV1 [exe and the dlls next to it]
    $svtDst = Join-Path $b.Bin 'SvtAv1EncApp.exe'
    if (Test-Path -LiteralPath $svtDst) { $log.Add('SVT-AV1: already in bin') }
    elseif (Test-Path -LiteralPath $raw['SVT_EXE']) {
        Copy-Item -LiteralPath $raw['SVT_EXE'] -Destination $svtDst
        foreach ($d in @(Get-ChildItem -LiteralPath (Split-Path -Parent $raw['SVT_EXE']) -Filter '*.dll' -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $b.Bin $d.Name) -Force
        }
        $log.Add('SVT-AV1: copied from ' + $raw['SVT_EXE'])
    }
    else { $log.Add('SVT-AV1: not found at ' + $raw['SVT_EXE'] + ', copy SvtAv1EncApp.exe into bin yourself') }

    # 3. grain tables
    New-Item -ItemType Directory -Force -Path $b.Tables | Out-Null
    if ($b.TableCount -gt 0) { $log.Add(('tables: already {0} in tables' -f $b.TableCount)) }
    elseif (Test-Path -LiteralPath $raw['DIR_TABLES']) {
        $n = Copy-TreeFiles $raw['DIR_TABLES'] $b.Tables '*.tbl'
        $log.Add(('tables: copied {0} grain tables from {1}' -f $n, $raw['DIR_TABLES']))
    }
    else { $log.Add('tables: put your .tbl files into the tables folder') }

    # 4. portable VapourSynth, assembled by setup.cmd [see Setup and updates]
    if ($b.Vspipe -eq '') {
        try { Install-VapourSynth; $log.Add('vs: portable VapourSynth ready') }
        catch { $log.Add('vs: ' + $_.Exception.Message) }
    }
    else { $log.Add('vs: already there') }
    return ($log -join "`n")
}

# ---- SVT-AV1 ----
function Get-SvtVersion([string]$exe) {
    if ($exe -eq '' -or -not (Test-Path -LiteralPath $exe)) { return '' }
    try {
        $r = Invoke-Native $exe @('--version')
        $m = [regex]::Match(($r.Out + ' ' + $r.Err), 'v?(\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    catch { }
    return ''
}


function Test-Newer([string]$a, [string]$b) {
    try { return ([version]$b -gt [version]$a) } catch { return $false }
}

# A two second encode through the given SVT-AV1 build: proves the exe and its dlls work before it is used
function Test-SvtExe([string]$exe) {
    $ff = Get-Tool 'ffmpeg'
    $out = Join-Path $env:TEMP ('svt_test_' + $PID + '.ivf')
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $cmd = '"' + $ff + '" -v error -f lavfi -i testsrc2=s=640x360:d=2 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | "' + $exe + '" -i stdin --preset 12 --crf 40 -b "' + $out + '"'
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/c "' + $cmd + '"') -WindowStyle Hidden -PassThru
    while (-not $p.HasExited) { Pump-Ui; Start-Sleep -Milliseconds 100 }
    $p.WaitForExit()
    $ok = ($p.ExitCode -eq 0) -and (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0)
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    return $ok
}

function Install-SvtBuild {
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = 'Pick the new SvtAv1EncApp.exe, or a zip that contains it'
    $d.Filter = 'SVT-AV1 build|SvtAv1EncApp*.exe;*.zip'
    if ($d.ShowDialog() -ne $true) { return 'Nothing installed.' }
    $exe = $d.FileName
    if ($exe -match '\.zip$') {
        $tmp = New-WorkDir 'svtzip'
        Expand-Zip $exe (Join-Path $tmp 'x')
        $found = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Recurse -Filter 'SvtAv1EncApp.exe' | Select-Object -First 1)
        if ($found.Count -eq 0) { return 'The zip has no SvtAv1EncApp.exe inside.' }
        $exe = $found[0].FullName
    }
    try { $v = Install-SvtExe $exe 'installed by hand' }
    catch { return $_.Exception.Message }
    return ('SVT-AV1 ' + $v + ' installed in bin and tested. The previous one is kept for Roll back.')
}

function Restore-SvtBackup { return (Restore-Backup 'svt') }

# Once a day at most, quietly: is there a newer SVT-AV1 release than the one in use?
function Check-SvtQuietly {
    try {
        $raw = Get-Config $G.Here
        $last = [string]$raw['SVT_LAST_CHECK']
        $today = Get-Date -Format 'yyyy-MM-dd'
        if ($last -eq $today) { return }
        $raw['SVT_LAST_CHECK'] = $today
        Save-Config $G.Here $raw
        $cur = Get-SvtVersion $G.Cfg['SVT_EXE']
        $rel = Get-LatestSvt
        if ($cur -ne '' -and (Test-Newer $cur $rel.Version)) {
            $G.UpdateNote = ('   |   SVT-AV1 ' + $rel.Version + ' is available [you have ' + $cur + '], see Settings')
            Update-Empty
        }
    }
    catch { }
}

# ---------------------------------------------------------------------------------------------
# v6.1: setup and updates. Everything goes into bin, vs [and tables, by hand] next to the program.
#   ffmpeg      BtbN automatic Windows builds on GitHub [newest release branch, GPL, static]
#   VapourSynth assembled by setup.cmd: VapourSynth portable [+ Python embeddable], KNLMeansCL, L-SMASH Works
#   SVT-AV1     compiled here from the official source [GitHub, GitLab as fallback] [Visual Studio Build Tools via winget; Clang on VS 2022 and newer]
# Every new piece is tested before it replaces the old one, and the old one is kept for rollback.
# ---------------------------------------------------------------------------------------------
function Write-LogFile([string]$name, [string]$m) {
    try {
        $dir = Join-Path $G.Here 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $dir $name), ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m + "`r`n"))
    }
    catch { }
}

function Setup-Log([string]$m) {
    Write-LogFile 'setup.log' $m
    if ($null -ne $G.U_tbLog) {
        $G.U_tbLog.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $m + "`r`n")
        $G.U_tbLog.ScrollToEnd()
    }
    Pump-Ui
}


# Downloads without freezing the window, showing megabytes as they arrive

$BgSource = @'
using System;
using System.IO;
using System.Threading.Tasks;
public static class Av1Bg
{
    public static Task Unzip(string zip, string dest)
    {
        return Task.Run(() => System.IO.Compression.ZipFile.ExtractToDirectory(zip, dest));
    }

    // Any crash on any thread leaves its reason in a file next to the program
    static string crashFile = "";
    public static void InstallCrashLog(string path)
    {
        crashFile = path;
        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
        {
            try { File.AppendAllText(crashFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  CRASH  " + e.ExceptionObject.ToString() + Environment.NewLine); } catch { }
        };
    }
}
'@

# v7: runs the engine with its output captured for the window. Standard input is NOT redirected: the engine
# shares the window's hidden console, so choice and timeout keep working. Lines ending in a lone CR are
# progress updates [SVT-AV1, ffmpeg -stats] and come out as "P" items, the rest as "L" items.
$ProcSource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public class Av1Proc
{
    public Process P;
    public ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
    StreamWriter log;
    readonly object logLock = new object();
    int open = 0;

    public static Av1Proc Start(string file, string args, string logPath)
    {
        Av1Proc r = new Av1Proc();
        ProcessStartInfo psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = false;
        psi.CreateNoWindow = false;
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        psi.StandardErrorEncoding = new UTF8Encoding(false);
        if (logPath != null && logPath.Length > 0)
        {
            try { r.log = new StreamWriter(logPath, true, new UTF8Encoding(false)); r.log.AutoFlush = true; } catch { r.log = null; }
        }
        r.P = Process.Start(psi);
        r.open = 2;
        r.Pump(r.P.StandardOutput.BaseStream);
        r.Pump(r.P.StandardError.BaseStream);
        return r;
    }

    public bool Done { get { try { return P.HasExited && open <= 0; } catch { return true; } } }
    public bool Exited { get { try { return P.HasExited; } catch { return true; } } }
    public int Code { get { try { return P.ExitCode; } catch { return -1; } } }

    void Emit(string kind, string text)
    {
        Q.Enqueue(kind + text);
        if (kind == "L" && log != null)
        {
            lock (logLock) { try { log.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  " + text); } catch { } }
        }
    }

    void Pump(Stream s)
    {
        Thread th = new Thread(() =>
        {
            Decoder dec = new UTF8Encoding(false).GetDecoder();
            byte[] buf = new byte[8192];
            char[] cb = new char[8192 + 8];
            StringBuilder cur = new StringBuilder();
            bool cr = false;
            int esc = 0;
            string lastP = "";
            DateTime lastPartial = DateTime.MinValue;
            try
            {
                while (true)
                {
                    int n = s.Read(buf, 0, buf.Length);
                    if (n <= 0) { break; }
                    int m = dec.GetChars(buf, 0, n, cb, 0);
                    for (int i = 0; i < m; i++)
                    {
                        char c = cb[i];
                        // colour codes [ESC [ ... letter], as SVT-AV1 4.x prints them, are dropped
                        if (esc == 1) { esc = (c == '[') ? 2 : 0; continue; }
                        if (esc == 2) { if (c >= '@' && c <= '~') { esc = 0; } continue; }
                        if (c == '\x1b') { esc = 1; continue; }
                        if (c == '\n')
                        {
                            Emit("L", cur.ToString());
                            cur.Clear();
                            cr = false;
                            lastP = "";
                        }
                        else if (c == '\r')
                        {
                            cr = true;
                        }
                        else
                        {
                            if (cr)
                            {
                                // a lone CR: the text before it was a progress line that is now overwritten
                                string t = cur.ToString();
                                if (t.Length > 0 && t != lastP) { Emit("P", t); lastP = t; }
                                cur.Clear();
                                cr = false;
                            }
                            if (c == '\f' || c == '\b' || c == '\a') { continue; }
                            cur.Append(c);
                        }
                    }
                    // Progress lines [and prompts without a line end] show up without waiting for the next character
                    if (cur.Length > 0 && (cr || (DateTime.Now - lastPartial).TotalMilliseconds > 500))
                    {
                        string t = cur.ToString();
                        if (t != lastP) { Emit("P", t); lastP = t; lastPartial = DateTime.Now; }
                    }
                }
                if (cur.Length > 0) { Emit("L", cur.ToString()); }
            }
            catch { }
            Interlocked.Decrement(ref open);
        });
        th.IsBackground = true;
        th.Start();
    }

    // Stops the engine and everything it started [ffmpeg, vspipe, SVT-AV1, the audio worker]
    public void Kill()
    {
        try
        {
            ProcessStartInfo k = new ProcessStartInfo("taskkill.exe", "/T /F /PID " + P.Id);
            k.UseShellExecute = false;
            k.CreateNoWindow = true;
            Process.Start(k).WaitForExit(15000);
        }
        catch { }
        try { if (!P.HasExited) { P.Kill(); } } catch { }
    }

    public void CloseLog()
    {
        lock (logLock) { try { if (log != null) { log.Dispose(); log = null; } } catch { } }
    }
}
'@

function Ensure-Proc {
    if (-not ('Av1Proc' -as [type])) { Add-Type -TypeDefinition $ProcSource -Language CSharp }
}

function Ensure-Bg {
    if (-not ('Av1Bg' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -TypeDefinition $BgSource -Language CSharp -ReferencedAssemblies @('System.IO.Compression', 'System.IO.Compression.FileSystem')
    }
}


function Set-ConfigValue([string]$key, [string]$value) {
    $raw = Get-Config $G.Here
    $raw[$key] = $value
    Save-Config $G.Here $raw
}

function New-WorkDir([string]$name) {
    $d = Join-Path $env:TEMP ('av1me_' + $name + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Moves the current files into bin\backup\<what>_<version>_<time> so Roll back can bring them back
function Backup-Files([string]$what, [string]$version, [string[]]$files) {
    $have = @($files | Where-Object { Test-Path -LiteralPath $_ })
    if ($have.Count -eq 0) { return }
    if ($version -eq '') { $version = 'unknown' }
    $bk = Join-Path $G.Here ('bin\backup\' + $what + '_' + ($version -replace '[^\w\.\-]', '_') + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $bk | Out-Null
    foreach ($f in $have) { Copy-Item -LiteralPath $f -Destination $bk -Force }
}

# ---- ffmpeg ----


# ---- VapourSynth ----



# ---- SVT-AV1: build tools, source, Clang build ----
# ---------------------------------------------------------------------------------------------
# v6.1.3: version lookups read small JSON files through curl.exe; downloads happen in setup.cmd.
function Get-WebJson([string]$url) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { throw 'curl.exe is missing [Windows 10 1803 or newer has it].' }
    $r = Invoke-Native $curl @('-sL', '--max-time', '20', '-A', 'RazAV1', $url)
    if ($r.Code -ne 0 -or $r.Out.Trim() -eq '') { throw ('Could not read ' + $url) }
    return ($r.Out | ConvertFrom-Json)
}



# Uses a matching file that is already in Downloads, or opens the link in the browser and waits for it

# Unpacks with tar.exe, which is built into Windows, into a fresh folder. Falls back to .NET for zips.
function Expand-Zip([string]$zip, [string]$dest) {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ($null -ne $G -and $null -ne $G.U_txtBusy) { $G.U_txtBusy.Text = 'Unpacking ' + [System.IO.Path]::GetFileName($zip) + ' ...' }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        $p = Start-Process -FilePath $tar -ArgumentList ('-xf "' + $zip + '" -C "' + $dest + '"') -WindowStyle Hidden -PassThru
        while (-not $p.HasExited) { Pump-Ui; Start-Sleep -Milliseconds 100 }
        $p.WaitForExit()
        if ($p.ExitCode -eq 0 -and @(Get-ChildItem -LiteralPath $dest -Force).Count -gt 0) { return }
    }
    if ($zip -notmatch '\.(zip|whl)$') { throw ('Could not unpack ' + [System.IO.Path]::GetFileName($zip) + '. Unpack it with Explorer or 7-Zip into a folder next to it, then try again.') }
    Ensure-Bg
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    $task = [Av1Bg]::Unzip($zip, $dest)
    while (-not $task.IsCompleted) { Pump-Ui; Start-Sleep -Milliseconds 100 }
    if ($task.IsFaulted) { throw ('Unpacking failed: ' + $task.Exception.InnerException.Message) }
}

# ---- version lookups ----
function Get-LatestSvt {
    # SVT-AV1 moved its home back to GitHub in November 2026 (4.3.1 and newer are only there);
    # the old GitLab project is archived at 4.3.0 and is only asked when GitHub cannot be reached.
    try {
        $rel = Get-WebJson 'https://api.github.com/repos/AOMediaCodec/SVT-AV1/releases/latest'
        $m = [regex]::Match([string]$rel.tag_name, '(\d+\.\d+\.\d+)')
        if ($m.Success) {
            $date = ''
            if ($rel.published_at) { $date = ([string]$rel.published_at).Substring(0, 10) }
            return (New-Object PSObject -Property @{ Version = $m.Groups[1].Value; Date = $date; Url = 'https://github.com/AOMediaCodec/SVT-AV1/releases' })
        }
    }
    catch { }
    $r = Get-WebJson 'https://gitlab.com/api/v4/projects/AOMediaCodec%2FSVT-AV1/releases?per_page=1'
    $rel = @($r)[0]
    $m = [regex]::Match([string]$rel.tag_name, '(\d+\.\d+\.\d+)')
    $date = ''
    if ($rel.released_at) { $date = ([string]$rel.released_at).Substring(0, 10) }
    return (New-Object PSObject -Property @{ Version = $m.Groups[1].Value; Date = $date; Url = 'https://gitlab.com/AOMediaCodec/SVT-AV1/-/releases' })
}

# Newest release tag of an encoder, from its GitHub tags. Returns Version and Tag.
function Get-LatestEncoder([string]$id) {
    $d = Get-EncoderDef $id
    if ($d.Id -eq 'mainline') {
        $r = Get-LatestSvt
        return (New-Object PSObject -Property @{ Version = $r.Version; Tag = ('v' + $r.Version); Url = $r.Url })
    }
    $tags = @(Get-WebJson ('https://api.github.com/repos/' + $d.Repo + '/tags?per_page=100'))
    $best = $null
    $bestV = $null
    foreach ($t in $tags) {
        $m = [regex]::Match([string]$t.name, $d.TagRx)
        if (-not $m.Success) { continue }
        $v = [version]$m.Groups[1].Value
        if ($null -eq $bestV -or $v -gt $bestV) { $bestV = $v; $best = [string]$t.name }
    }
    if ($null -eq $best) { throw ('No release tag found for ' + $d.Name + '.') }
    return (New-Object PSObject -Property @{ Version = $bestV.ToString(); Tag = $best; Url = ('https://github.com/' + $d.Repo) })
}

# The fork's own Windows build, used only if compiling it fails on this PC. Returns @(url, ext) or $null.
function Get-EncoderBinary([string]$id, [string]$tag) {
    try {
        if ($id -eq 'essential') {
            $rel = Get-WebJson ('https://api.github.com/repos/nekotrix/SVT-AV1-Essential/releases/tags/' + $tag)
            foreach ($a in @($rel.assets)) { if ([string]$a.name -match 'Windows_Generic\.zip$') { return @([string]$a.browser_download_url, 'zip') } }
        }
        elseif ($id -eq 'hdr') {
            $rel = Get-WebJson 'https://api.github.com/repos/juliobbv-p/svt-av1-hdr/releases/latest'
            foreach ($a in @($rel.assets)) { if ([string]$a.name -match '^Windows_x86-64_x86-64-v3.*\.tar\.xz$') { return @([string]$a.browser_download_url, 'tar.xz') } }
        }
    }
    catch { }
    return $null
}

function Get-EncoderExe([string]$id) {
    $d = Get-EncoderDef $id
    if ($d.Id -eq 'mainline') {
        $p = Join-Path $G.Here 'bin\SvtAv1EncApp.exe'
        if (Test-Path -LiteralPath $p) { return $p }
        if (Test-Path -LiteralPath ([string]$G.Cfg['SVT_EXE'])) { return [string]$G.Cfg['SVT_EXE'] }
        return ''
    }
    $p = Join-Path (Join-Path $G.Here $d.Dir) 'SvtAv1EncApp.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return ''
}

function Get-LatestFfmpeg {
    $r = Get-WebJson 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest'
    $best = $null
    $bestVer = [version]'0.0'
    foreach ($a in @($r.assets)) {
        if ([string]$a.name -match '^ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-\d+\.\d+\.zip$') {
            $v = [version]($Matches[1] + '.' + $Matches[2])
            if ($v -gt $bestVer) { $bestVer = $v; $best = $a }
        }
    }
    if ($null -eq $best) { $best = @($r.assets | Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-gpl.zip' })[0] }
    if ($null -eq $best) { throw 'No Windows ffmpeg build found in the BtbN release list.' }
    return (New-Object PSObject -Property @{ Name = [string]$best.name; Url = [string]$best.browser_download_url; Version = ('n' + $bestVer.ToString()) })
}

function Get-LatestVs {
    $r = Get-WebJson 'https://api.github.com/repos/vapoursynth/vapoursynth/releases/latest'
    return (New-Object PSObject -Property @{ Tag = [string]$r.tag_name; Url = '' })
}

# ---- ffmpeg ----

# ---- VapourSynth, assembled from four browser downloads ----
#   Python embeddable [python.org] + VapourSynth portable [GitHub] + the vapoursynth wheel inside it,
#   unpacked into Lib\site-packages, + KNLMeansCL and L-SMASH Works dlls in the autoload plugin folder.



# ---- the install steps: setup.cmd does the downloading [curl.exe] and unpacking [tar.exe] in its own
#      window, so nothing in this window downloads and a stopped step can never take the window down ----
function Clean-Tag([string]$s) { return ($s -replace '[^\w\.\-]', '_') }

function Invoke-SetupCmd([string]$step) {
    $cmd = Join-Path $G.Here 'setup.cmd'
    if (-not (Test-Path -LiteralPath $cmd)) { throw 'setup.cmd is missing next to the program.' }
    $res = Join-Path $G.Here 'logs\setup_result.txt'
    Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
    Setup-Log ('Running the ' + $step + ' step in its own window...')
    [void](Run-AndWait $env:ComSpec ('/c ""' + $cmd + '" ' + $step + '"') $G.Here)
    if (-not (Test-Path -LiteralPath $res)) { throw ('The ' + $step + ' setup window closed before it finished. If your antivirus reported something, send its message.') }
    $r = ([System.IO.File]::ReadAllText($res)).Trim()
    if ($r.StartsWith('OK|')) { return $r.Substring(3) }
    throw ($r -replace '^FAIL\|', '')
}

function Install-Ffmpeg {
    $name = 'ffmpeg-master-latest-win64-gpl.zip'
    $url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/' + $name
    try { $rel = Get-LatestFfmpeg; $url = $rel.Url; $name = $rel.Name }
    catch { Setup-Log ('ffmpeg: could not read the newest release branch, using the master build. ' + $_.Exception.Message) }
    $env:AV1_FF_URL = $url
    $env:AV1_FF_NAME = $name
    $env:AV1_FF_OLD = Clean-Tag ([string](Get-Config $G.Here)['FFMPEG_BUILD'])
    $m = Invoke-SetupCmd 'ffmpeg'
    Set-ConfigValue 'FFMPEG_BUILD' $name
    $bin = Join-Path $G.Here 'bin'
    if ($env:PATH -notlike ($bin + ';*')) { $env:PATH = $bin + ';' + $env:PATH }
    Setup-Log $m
}

function Install-VapourSynth {
    $tag = 'R82'
    try { $tag = (Get-LatestVs).Tag } catch { Setup-Log ('VapourSynth: could not read the newest version, using R82. ' + $_.Exception.Message) }
    $env:AV1_VS_TAG = $tag
    $env:AV1_VS_URL = 'https://github.com/vapoursynth/vapoursynth/releases/download/' + $tag + '/VapourSynth64-Portable-' + $tag + '.zip'
    $env:AV1_PY_URL = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    $kn = Get-WebJson 'https://pypi.org/pypi/vapoursynth-knlmeanscl/json'
    $w = @($kn.urls | Where-Object { [string]$_.filename -like '*win_amd64.whl' })[0]
    if ($null -eq $w) { throw 'No Windows KNLMeansCL build was found on PyPI.' }
    $env:AV1_KN_URL = [string]$w.url
    $ls = Get-WebJson 'https://api.github.com/repos/HomeOfAviSynthPlusEvolution/L-SMASH-Works/releases/latest'
    $assets = @($ls.assets)
    $a = @($assets | Where-Object { [string]$_.name -match '\.zip$' -and [string]$_.name -notmatch '(?i)(x86|win32|arm)' })[0]
    if ($null -eq $a) { $a = @($assets | Where-Object { [string]$_.name -match '\.(zip|7z)$' })[0] }
    if ($null -eq $a) { throw 'No L-SMASH Works download was found on GitHub.' }
    $env:AV1_LS_URL = [string]$a.browser_download_url
    $env:AV1_LS_NAME = [string]$a.name
    # a .7z needs 7-Zip when the Windows tar cannot open it: install it once through winget
    if ($env:AV1_LS_NAME -match '\.7z$' -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles '7-Zip\7z.exe'))) {
        $wg = Get-Command winget -ErrorAction SilentlyContinue
        if ($null -ne $wg) {
            Setup-Log 'L-SMASH Works comes as .7z: installing 7-Zip with winget, in case Windows tar cannot open it.'
            [void](Run-AndWait $wg.Source 'install --id 7zip.7zip -e --accept-package-agreements --accept-source-agreements' '')
        }
    }
    $m = Invoke-SetupCmd 'vs'
    Set-ConfigValue 'VS_VERSION' $tag
    Setup-Log $m
    $vsb = Join-Path $G.Here 'vs\vspipe.bat'
    $s = Get-GpuSpeeds $vsb
    if ($s.Count -gt 0) {
        $best = $s[0]
        foreach ($x in $s) { if ($x[1] -gt $best[1]) { $best = $x } }
        Set-ConfigValue 'KNLM_DEVICE' ([string]$best[0])
        Setup-Log ('VapourSynth: fastest GPU for KNLMeansCL is device ' + $best[0] + ' [' + $best[1] + ' fps on the test].')
    }
}

function Build-Svt([string]$id = 'mainline', [bool]$officialBin = $false) {
    $d = Get-EncoderDef $id
    $rel = Get-LatestEncoder $d.Id
    $tag = $rel.Tag
    Assert-FreeSpace $G.Here 2 ('building ' + $d.Name)
    $env:AV1_SVT_FORCEBIN = ''
    if ($officialBin) {
        $bin0 = Get-EncoderBinary $d.Id $tag
        if ($null -eq $bin0) { throw ('No official Windows build of ' + $d.Name + ' was found on its release page.') }
        Setup-Log ($d.Name + ': installing its official Windows build [' + $tag + ']')
        $env:AV1_SVT_FORCEBIN = '1'
        $t = New-Object PSObject -Property @{ VsPath = ''; VsMajor = 0; Clang = $false; Cmake = ''; Nasm = '' }
    }
    else {
        Setup-Log ($d.Name + ': building ' + $tag + ' from github.com/' + $d.Repo)
        $t = Install-BuildTools
    }
    $gen = 'Visual Studio 17 2022'
    if ($t.VsMajor -eq 16) { $gen = 'Visual Studio 16 2019' }
    elseif ($t.VsMajor -ge 18) { $gen = 'Visual Studio 18 2026' }
    $env:AV1_SVT_TAG = $tag
    $env:AV1_GEN = $gen
    $env:AV1_VSPATH = $t.VsPath
    # Clang only matters for Visual Studio 2022 17.8 and newer [their MSVC miscompiles the AVX-512 code].
    # Visual Studio 2019 builds SVT-AV1 correctly with its own compiler.
    # Clang on Windows cannot compile SVT-AV1's AVX-512 code [4.3 and newer], so it is built without it:
    # AVX2 is used instead, the same path as on CPUs without AVX-512.
    $env:AV1_TOOLSET = ''
    $env:AV1_CMAKE_EXTRA = ''
    if ($officialBin) { }
    elseif ($t.VsMajor -ge 17) {
        if ($t.Clang) { $env:AV1_TOOLSET = ' -T ClangCL'; $env:AV1_CMAKE_EXTRA = '-DENABLE_AVX512=OFF'; Setup-Log ('Compiler: Clang [Visual Studio ' + $t.VsMajor + ', AVX-512 code off, AVX2 used]') }
        else { Setup-Log ('Compiler: MSVC [Visual Studio ' + $t.VsMajor + ', Clang is not installed; AVX-512 code paths may be slower or unsafe on some CPUs]') }
    }
    else { Setup-Log ('Compiler: MSVC from Visual Studio ' + $t.VsMajor + ' [not affected by the AVX-512 bug, Clang not needed]') }
    $env:AV1_NASM_FWD = ''
    $env:AV1_CMAKE = $t.Cmake
    $env:AV1_NASM = $t.Nasm
    $env:AV1_NASM_FWD = $t.Nasm.Replace('\', '/')
    $env:AV1_FFMPEG = Get-Tool 'ffmpeg'
    $dest = Join-Path $G.Here $d.Dir
    $env:AV1_SVT_REPO = $d.Repo
    $env:AV1_SVT_DEST = $dest
    $env:AV1_SVT_BK = $d.Bk
    $env:AV1_SVT_NAME = $d.Name
    $env:AV1_SVT_BINURL = ''
    $env:AV1_SVT_BINEXT = ''
    $bin = Get-EncoderBinary $d.Id $tag
    if ($null -ne $bin) { $env:AV1_SVT_BINURL = $bin[0]; $env:AV1_SVT_BINEXT = $bin[1] }
    $env:AV1_SVT_OLD = Clean-Tag (Get-SvtVersion (Join-Path $dest 'SvtAv1EncApp.exe'))
    $m = Invoke-SetupCmd 'svt'
    $v = Get-SvtVersion (Join-Path $dest 'SvtAv1EncApp.exe')
    $how = 'built here'
    if ($m -match 'official Windows build') { $how = 'official Windows build' }
    $feat = ''
    $fm = [regex]::Match($m, 'Dolby Vision/HDR10\+: (yes|no)')
    if ($fm.Success) { $feat = ', DV/HDR10+ ' + $fm.Groups[1].Value }
    Set-ConfigValue $d.Cfg ($v + ' ' + $how + ' ' + (Get-Date -Format 'yyyy-MM-dd') + $feat)
    Setup-Log $m
}

function Find-BuildTools {
    $o = New-Object PSObject -Property @{ VsPath = ''; VsMajor = 0; Clang = $false; Cmake = ''; Nasm = ''; Winget = '' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $r = Invoke-Native $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json')
        $j = $null
        try { $j = @($r.Out | ConvertFrom-Json) } catch { }
        if ($null -ne $j -and $j.Count -gt 0 -and $j[0].installationPath) {
            $o.VsPath = [string]$j[0].installationPath
            $o.VsMajor = [int]([string]$j[0].installationVersion).Split('.')[0]
            $r2 = Invoke-Native $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset', '-property', 'installationPath')
            $o.Clang = ($r2.Out.Trim() -ne '')
        }
    }
    foreach ($c in @((Get-Command cmake -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1), (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'))) {
        if ($null -eq $c) { continue }
        $p = [string]$c
        if ($c -is [System.Management.Automation.CommandInfo]) { $p = $c.Source }
        if (Test-Path -LiteralPath $p) { $o.Cmake = $p; break }
    }
    foreach ($c in @((Get-Command nasm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1), (Join-Path $env:ProgramFiles 'NASM\nasm.exe'), (Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe'))) {
        if ($null -eq $c) { continue }
        $p = [string]$c
        if ($c -is [System.Management.Automation.CommandInfo]) { $p = $c.Source }
        if (Test-Path -LiteralPath $p) { $o.Nasm = $p; break }
    }
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -ne $w) { $o.Winget = $w.Source }
    return $o
}

function Get-ToolsText {
    $t = Find-BuildTools
    $parts = @()
    if ($t.VsPath -ne '') {
        if ($t.Clang) { $parts += ('C++ build tools [VS ' + $t.VsMajor + '] with Clang: yes') }
        elseif ($t.VsMajor -lt 17) { $parts += ('C++ build tools [VS ' + $t.VsMajor + ']: yes, Clang not needed') }
        else { $parts += ('C++ build tools [VS ' + $t.VsMajor + ']: yes, Clang missing') }
    }
    else { $parts += 'C++ build tools: no' }
    if ($t.Cmake -ne '') { $parts += 'CMake: yes' } else { $parts += 'CMake: no' }
    if ($t.Nasm -ne '') { $parts += 'NASM: yes' } else { $parts += 'NASM: no' }
    return ('Build tools - ' + ($parts -join ',  '))
}

# Stops with a plain message when a drive is too full for the next step
function Assert-FreeSpace([string]$path, [double]$needGB, [string]$what) {
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace / 1GB
        if ($free -lt $needGB) { throw ('Not enough free space on ' + $root + ' for ' + $what + ': ' + [math]::Round($free, 1) + ' GB free, about ' + $needGB + ' GB needed.') }
    }
    catch [System.ArgumentException] { }
}

function Install-BuildTools {
    $t = Find-BuildTools
    $needClang = ($t.VsPath -eq '' -or $t.VsMajor -ge 17)
    if ($t.VsPath -ne '' -and ($t.Clang -or -not $needClang) -and $t.Cmake -ne '' -and $t.Nasm -ne '') { return $t }
    $missing = @()
    if ($t.VsPath -eq '') { $missing += "Microsoft C++ Build Tools [about 5 GB; the compiler only, this is not Visual Studio Code]" }
    elseif ($needClang -and -not $t.Clang) { $missing += 'Clang for your Visual Studio 2022 Build Tools [about 1 GB]' }
    if ($t.Cmake -eq '') { $missing += 'CMake [about 100 MB]' }
    if ($t.Nasm -eq '') { $missing += 'NASM [a few MB]' }
    if ($t.Winget -eq '') {
        $r = Show-Ask 'Build tools needed' ("SVT-AV1 is compiled on this PC from its official source. That needs:`n`n - " + ($missing -join "`n - ") + "`n`nThey are installed with winget, which is part of 'App Installer' from the Microsoft Store, and it is missing on this PC. Install App Installer, then press Build latest again.") @('Open Microsoft Store', 'Close')
        if ($r -eq 'Open Microsoft Store') { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' }
        throw 'winget [App Installer] is missing, so the build tools could not be installed.'
    }
    $r = Show-Ask 'Build tools needed' ("SVT-AV1 is compiled on this PC from its official source, so it is built exactly for your CPU. That needs, once:`n`n - " + ($missing -join "`n - ") + "`n`nThey come straight from Microsoft, Kitware and the NASM project through winget. Windows asks for permission once. Install them now?") @('Install', 'Not now')
    if ($r -ne 'Install') { throw 'Not installed: the build tools are needed to compile SVT-AV1. The forks can use their official Windows build instead.' }
    Assert-FreeSpace $env:SystemDrive 8 'the build tools'
    $agree = '--accept-package-agreements --accept-source-agreements'
    if ($t.Cmake -eq '') {
        Setup-Log 'Build tools: installing CMake with winget...'
        [void](Run-AndWait $t.Winget ('install --id Kitware.CMake -e ' + $agree) '')
    }
    if ($t.Nasm -eq '') {
        Setup-Log 'Build tools: installing NASM with winget...'
        [void](Run-AndWait $t.Winget ('install --id NASM.NASM -e ' + $agree) '')
    }
    $components = '--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset --includeRecommended'
    if ($t.VsPath -eq '') {
        Setup-Log 'Build tools: installing Visual Studio Build Tools with C++ and Clang. This is a few GB; Windows will ask to allow it.'
        [void](Run-AndWait $t.Winget ('install --id Microsoft.VisualStudio.2022.BuildTools -e ' + $agree + ' --override "--wait --passive --norestart ' + $components + '"') '')
    }
    elseif ($needClang -and -not $t.Clang) {
        Setup-Log 'Build tools: adding Clang to your Visual Studio Build Tools. Windows will ask to allow it.'
        $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        [void](Run-AndWait $setup ('modify --installPath "' + $t.VsPath + '" --passive --norestart ' + $components) '')
    }
    $t = Find-BuildTools
    if ($t.VsPath -eq '' -or $t.Cmake -eq '' -or $t.Nasm -eq '') { throw ('The build tools are not complete yet. ' + (Get-ToolsText) + '. If an installer asked for a restart, restart and try again.') }
    return $t
}

# Tests a new SvtAv1EncApp.exe, keeps the current one in bin\backup, then installs the new one
function Install-SvtExe([string]$exe, [string]$label) {
    $newVer = Get-SvtVersion $exe
    if (-not (Test-SvtExe $exe)) { throw ('SVT-AV1 ' + $newVer + ' failed the two second test encode, so nothing was changed.') }
    $bin = Join-Path $G.Here 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $cur = Join-Path $bin 'SvtAv1EncApp.exe'
    $old = @($cur) + @(Get-ChildItem -LiteralPath $bin -Filter 'SvtAv1Enc*.dll' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Backup-Files 'svt' (Get-SvtVersion $cur) $old
    Copy-Item -LiteralPath $exe -Destination $cur -Force
    foreach ($f in @(Get-ChildItem -LiteralPath (Split-Path -Parent $exe) -Filter 'SvtAv1Enc*.dll' -ErrorAction SilentlyContinue)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $bin $f.Name) -Force }
    Set-ConfigValue 'SVT_BUILT' ($newVer + ' ' + $label)
    return $newVer
}


function Restore-Backup([string]$what, [string]$destDir = 'bin') {
    $root = Join-Path $G.Here 'bin\backup'
    # 'svt_*' does not match 'svt-essential_*' or 'svt-hdr_*', so every encoder only gets its own backups
    $bks = @(Get-ChildItem -LiteralPath $root -Directory -Filter ($what + '_*') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($bks.Count -eq 0) { return ('There is no earlier ' + $what + ' to go back to.') }
    $bin = Join-Path $G.Here $destDir
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $bks[0].FullName -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $bin $f.Name) -Force }
    $name = $bks[0].Name
    Remove-Item -LiteralPath $bks[0].FullName -Recurse -Force
    return ('Restored ' + $name + '.')
}

# ---- status and update check ----
function Get-ComponentStatus {
    $raw = Get-Config $G.Here
    $b = Get-Bundle $G.Here
    $o = New-Object PSObject -Property @{ Ffmpeg = ''; Vs = ''; Svt = ''; Ess = ''; Hdr = ''; Tables = ''; Complete = $false }
    foreach ($id in @('essential', 'hdr')) {
        $d = Get-EncoderDef $id
        $exe = Join-Path (Join-Path $G.Here $d.Dir) 'SvtAv1EncApp.exe'
        $txt = 'Not built yet [optional]'
        if (Test-Path -LiteralPath $exe) { $txt = 'In ' + $d.Dir + ': ' + (Get-SvtVersion $exe) + '  [' + [string]$raw[$d.Cfg] + ']' }
        if ($id -eq 'essential') { $o.Ess = $txt } else { $o.Hdr = $txt }
    }
    if ($b.Ffmpeg -ne '') { $o.Ffmpeg = 'In bin: ' + [string]$raw['FFMPEG_BUILD'] } else { $o.Ffmpeg = 'Not in bin yet' }
    if ($b.Vspipe -ne '') { $o.Vs = 'In vs: VapourSynth ' + [string]$raw['VS_VERSION'] } else { $o.Vs = 'Not set up yet' }
    if ($b.Svt -ne '') { $o.Svt = 'In bin: ' + (Get-SvtVersion $b.Svt) + '  [' + [string]$raw['SVT_BUILT'] + ']' } else { $o.Svt = 'Not in bin yet' }
    $o.Tables = ('{0} grain tables in the tables folder; missing sizes are made during encodes' -f $b.TableCount)
    $o.Complete = ($b.Ffmpeg -ne '' -and $b.Vspipe -ne '' -and $b.Svt -ne '')
    return $o
}

function Get-Updates {
    $raw = Get-Config $G.Here
    $b = Get-Bundle $G.Here
    $list = New-Object System.Collections.Generic.List[string]
    try {
        if ($b.Ffmpeg -ne '') {
            $f = Get-LatestFfmpeg
            if ($f.Name -ne [string]$raw['FFMPEG_BUILD']) { $list.Add('ffmpeg ' + $f.Version) }
        }
    }
    catch { }
    try {
        if ($b.Vspipe -ne '') {
            $v = Get-LatestVs
            if ($v.Tag -ne '' -and $v.Tag -ne [string]$raw['VS_VERSION']) { $list.Add('VapourSynth ' + $v.Tag) }
        }
    }
    catch { }
    try {
        $cur = Get-SvtVersion $G.Cfg['SVT_EXE']
        $s = Get-LatestSvt
        if ($cur -ne '' -and (Test-Newer $cur $s.Version)) { $list.Add('SVT-AV1 ' + $s.Version) }
    }
    catch { }
    foreach ($id in @('essential', 'hdr')) {
        try {
            $d = Get-EncoderDef $id
            $exe = Join-Path (Join-Path $G.Here $d.Dir) 'SvtAv1EncApp.exe'
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $cur = Get-SvtVersion $exe
            $r = Get-LatestEncoder $id
            if ($cur -ne '' -and (Test-Newer $cur $r.Version)) { $list.Add($d.Name + ' ' + $r.Version) }
        }
        catch { }
    }
    return , $list
}

# ---- Setup and updates window ----
$SetupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Setup and updates" Width="780" SizeToContent="Height" MaxHeight="960" WindowStartupLocation="CenterOwner"
        Background="#000000" Foreground="#D6DAE1" FontFamily="Segoe UI" FontSize="13" ResizeMode="NoResize">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto">
  <StackPanel Margin="20">
    <TextBlock Text="SETUP AND UPDATES" FontSize="18" FontWeight="Bold" Foreground="#5B9BF0"/>
    <TextBlock TextWrapping="Wrap" Foreground="#8A919C" Margin="0,4,0,0"
               Text="Downloads and sets up everything the encoder needs in the folders next to it, so this folder works on any PC. Each step runs in its own small window [curl and tar, built into Windows]. Only your grain tables go into the tables folder by hand. Every update is tested first and the previous version is kept."/>

    <TextBlock Style="{StaticResource Head}" Text="FFMPEG + FFPROBE  [BtbN builds on GitHub, newest release branch]"/>
    <DockPanel><Button x:Name="btnFf" DockPanel.Dock="Right" Content="Download / update" Margin="8,0,0,0"/><TextBlock x:Name="txtFf" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>

    <TextBlock Style="{StaticResource Head}" Text="VAPOURSYNTH + KNLMEANSCL + L-SMASH WORKS  [official portable release]"/>
    <DockPanel><Button x:Name="btnVsSet" DockPanel.Dock="Right" Content="Download / update" Margin="8,0,0,0"/><TextBlock x:Name="txtVsSet" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>

    <TextBlock Style="{StaticResource Head}" Text="SVT-AV1  [official encoder, compiled here from github.com/AOMediaCodec/SVT-AV1]"/>
    <DockPanel><Button x:Name="btnSvtBuild" DockPanel.Dock="Right" Content="Build latest" Margin="8,0,0,0"/><TextBlock x:Name="txtSvtSet" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>

    <TextBlock Style="{StaticResource Head}" Text="SVT-AV1-ESSENTIAL  [optional fork by nekotrix, compiled here]"/>
    <DockPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btnEssBuild" Content="Build latest" Margin="8,0,0,0"/><Button x:Name="btnEssBin" Content="Official build" Margin="8,0,0,0" ToolTip="Install the fork's own Windows build instead of compiling it here [no build tools needed]."/><Button x:Name="btnBackEss" Content="Roll back" Margin="8,0,0,0"/></StackPanel><TextBlock x:Name="txtEssSet" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>

    <TextBlock Style="{StaticResource Head}" Text="SVT-AV1-HDR  [optional fork by juliobbv, compiled here]"/>
    <DockPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btnHdrBuild" Content="Build latest" Margin="8,0,0,0"/><Button x:Name="btnHdrBin" Content="Official build" Margin="8,0,0,0" ToolTip="Install the fork's own Windows build instead of compiling it here [no build tools needed]."/><Button x:Name="btnBackHdr" Content="Roll back" Margin="8,0,0,0"/></StackPanel><TextBlock x:Name="txtHdrSet" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>
    <TextBlock Foreground="#8A919C" TextWrapping="Wrap" Margin="0,6,0,0" Text="The forks are compiled with the same tools as SVT-AV1; if that fails, their official Windows build is used instead. Official build skips compiling altogether. Builds compiled here have Dolby Vision / HDR10+ metadata support only if their extra libraries were found; the status line says which."/>
    <TextBlock x:Name="txtTools" Foreground="#8A919C" TextWrapping="Wrap" Margin="0,6,0,0"/>

    <TextBlock Style="{StaticResource Head}" Text="GRAIN TABLES  [by hand]"/>
    <DockPanel><Button x:Name="btnTablesOpen" DockPanel.Dock="Right" Content="Open tables folder" Margin="8,0,0,0"/><Button x:Name="btnTablesMake" DockPanel.Dock="Right" Content="Make grain tables" Margin="8,0,0,0" ToolTip="Every ISO step from 100 to 6400 for the common 1080p, 720p and 4K sizes [SDR, and HDR10/HLG for 4K]. Any other size is made automatically when an encode needs it."/><TextBlock x:Name="txtTablesSet" VerticalAlignment="Center" TextWrapping="Wrap"/></DockPanel>

    <WrapPanel Margin="0,20,0,0">
      <Button x:Name="btnAll" Style="{StaticResource AccentButton}" Content="Set up everything" Margin="0,0,8,8"/>
      <Button x:Name="btnCheckUpd" Content="Check for updates" Margin="0,0,8,8"/>
      <Button x:Name="btnBackFf" Content="Roll back ffmpeg" Margin="0,0,8,8"/>
      <Button x:Name="btnBackSvt" Content="Roll back SVT-AV1" Margin="0,0,8,8"/>
      <Button x:Name="btnCloseSet" Content="Close" Margin="0,0,8,8"/>
    </WrapPanel>
    <DockPanel Margin="0,4,0,0">
      <Button x:Name="btnCancelWait" DockPanel.Dock="Right" Content="Stop waiting" Visibility="Collapsed" Margin="8,0,0,0"/>
      <TextBlock x:Name="txtBusy" Foreground="#5B9BF0" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </DockPanel>
    <TextBlock Style="{StaticResource Head}" Text="LOG"/>
    <TextBox x:Name="tbLog" Height="190" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
  </StackPanel>
  </ScrollViewer>
</Window>
'@

function Refresh-SetupStatus {
    $s = Get-ComponentStatus
    $G.U_txtFf.Text = $s.Ffmpeg
    $G.U_txtVsSet.Text = $s.Vs
    $G.U_txtSvtSet.Text = $s.Svt
    $G.U_txtEssSet.Text = $s.Ess
    $G.U_txtHdrSet.Text = $s.Hdr
    $G.U_txtTablesSet.Text = $s.Tables
    $G.U_txtTools.Text = Get-ToolsText
}

function Set-SetupBusy([bool]$on) {
    foreach ($n in @('btnFf', 'btnVsSet', 'btnSvtBuild', 'btnEssBuild', 'btnHdrBuild', 'btnEssBin', 'btnHdrBin', 'btnBackEss', 'btnBackHdr', 'btnAll', 'btnCheckUpd', 'btnBackFf', 'btnBackSvt', 'btnCloseSet')) { $G['U_' + $n].IsEnabled = -not $on }
    if (-not $on) { $G.U_txtBusy.Text = '' }
}

# Runs one setup step with the buttons locked, logging any error instead of stopping the window
function Invoke-SetupStep([string]$name, [scriptblock]$step) {
    Set-SetupBusy $true
    $G.U_txtBusy.Text = $name + '...'
    $ok = $true
    try { & $step }
    catch {
        $ok = $false
        Setup-Log ('[ERROR] ' + $name + ': ' + $_.Exception.Message)
        Write-LogFile 'errors.log' ($name + ': ' + $_.Exception.ToString() + "`r`n" + $_.InvocationInfo.PositionMessage)
    }
    Refresh-SetupStatus
    Set-SetupBusy $false
    return $ok
}

function Show-Setup {
    $w = Load-Xaml $SetupXaml
    $w.Owner = $G.Win
    $G.UW = $w
    foreach ($n in @('btnFf', 'txtFf', 'btnVsSet', 'txtVsSet', 'btnSvtBuild', 'txtSvtSet', 'btnEssBuild', 'btnEssBin', 'btnBackEss', 'txtEssSet', 'btnHdrBuild', 'btnHdrBin', 'btnBackHdr', 'txtHdrSet', 'txtTools', 'btnTablesOpen', 'btnTablesMake', 'txtTablesSet', 'btnAll', 'btnCheckUpd', 'btnBackFf', 'btnBackSvt', 'btnCloseSet', 'txtBusy', 'tbLog', 'btnCancelWait')) { $G['U_' + $n] = $w.FindName($n) }
    $G.U_btnCancelWait.Add_Click({ $G.CancelWait = $true })
    Refresh-SetupStatus
    New-Item -ItemType Directory -Force -Path (Join-Path $G.Here 'tables') | Out-Null

    $G.U_btnFf.Add_Click({ [void](Invoke-SetupStep 'ffmpeg' { Install-Ffmpeg }) })
    $G.U_btnVsSet.Add_Click({ [void](Invoke-SetupStep 'VapourSynth' { Install-VapourSynth }) })
    $G.U_btnSvtBuild.Add_Click({ [void](Invoke-SetupStep 'SVT-AV1' { Build-Svt 'mainline' }) })
    $G.U_btnEssBuild.Add_Click({ [void](Invoke-SetupStep 'SVT-AV1-Essential' { Build-Svt 'essential' }) })
    $G.U_btnHdrBuild.Add_Click({ [void](Invoke-SetupStep 'SVT-AV1-HDR' { Build-Svt 'hdr' }) })
    $G.U_btnEssBin.Add_Click({ [void](Invoke-SetupStep 'SVT-AV1-Essential' { Build-Svt 'essential' $true }) })
    $G.U_btnHdrBin.Add_Click({ [void](Invoke-SetupStep 'SVT-AV1-HDR' { Build-Svt 'hdr' $true }) })
    $G.U_btnBackEss.Add_Click({ Setup-Log (Restore-Backup 'svt-essential' 'bin\essential'); Refresh-SetupStatus })
    $G.U_btnBackHdr.Add_Click({ Setup-Log (Restore-Backup 'svt-hdr' 'bin\hdr'); Refresh-SetupStatus })
    $G.U_btnTablesMake.Add_Click({
            [void](Invoke-SetupStep 'Grain tables' { $n = New-BaselineTables (Join-Path $G.Here 'tables'); Setup-Log ('Grain tables: made ' + $n + ' new [tables\photon]. Other sizes are made when an encode needs them.') })
        })
    $G.U_btnTablesOpen.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $G.Here 'tables') + '"') })
    $G.U_btnAll.Add_Click({
            Setup-Log 'Setting up everything: ffmpeg, VapourSynth, then SVT-AV1.'
            $b = Get-Bundle $G.Here
            if ($b.Ffmpeg -eq '') { [void](Invoke-SetupStep 'ffmpeg' { Install-Ffmpeg }) } else { Setup-Log 'ffmpeg: already in bin.' }
            if ($b.Vspipe -eq '') { [void](Invoke-SetupStep 'VapourSynth' { Install-VapourSynth }) } else { Setup-Log 'VapourSynth: already in vs.' }
            if ($b.Svt -eq '') { [void](Invoke-SetupStep 'SVT-AV1' { Build-Svt 'mainline' }) } else { Setup-Log 'SVT-AV1: already in bin. Use Build latest to compile a new version.' }
            [void](Invoke-SetupStep 'Grain tables' { $n = New-BaselineTables (Join-Path $G.Here 'tables'); if ($n -gt 0) { Setup-Log ('Grain tables: made ' + $n + ' [ISO 100-6400 for the common sizes].') } })
            $G.Cfg = Get-EffectiveConfig $G.Here
            $vs = Test-VapourSynth $G.Cfg['VSPIPE']
            $G.HasVs = $vs[0]
            $G.VsNote = $vs[1]
            $st = Get-ComponentStatus
            Setup-Log '---- Summary ----'
            Setup-Log ('ffmpeg:            ' + $st.Ffmpeg)
            Setup-Log ('VapourSynth:       ' + $st.Vs)
            Setup-Log ('SVT-AV1:           ' + $st.Svt)
            Setup-Log ('SVT-AV1-Essential: ' + $st.Ess)
            Setup-Log ('SVT-AV1-HDR:       ' + $st.Hdr)
            Setup-Log ('Grain tables:      ' + $st.Tables)
            if ($st.Complete) { Setup-Log 'Ready to encode. The forks are optional: build them here whenever you want them.' }
            else { Setup-Log 'Something is still missing [see above]. Press its button to try again; the log explains what went wrong.' }
        })
    $G.U_btnCheckUpd.Add_Click({
            Set-SetupBusy $true
            $G.U_txtBusy.Text = 'Checking for updates...'
            $u = Get-Updates
            Set-SetupBusy $false
            if ($u.Count -eq 0) { Setup-Log 'Everything is up to date.' } else { Setup-Log ('Updates available: ' + ($u -join ', ') + '. Press Download / update or Build latest for each.') }
            Set-ConfigValue 'UPDATE_LAST_CHECK' (Get-Date -Format 'yyyy-MM-dd')
        })
    $G.U_btnBackFf.Add_Click({ Setup-Log (Restore-Backup 'ffmpeg'); Refresh-SetupStatus })
    $G.U_btnBackSvt.Add_Click({ Setup-Log (Restore-Backup 'svt'); Refresh-SetupStatus })
    $G.U_btnCloseSet.Add_Click({ $G.UW.Close() })
    $w.Add_Closed({
            Set-ConfigValue 'SETUP_SHOWN' '1'
            $G.Cfg = Get-EffectiveConfig $G.Here
            $vs = Test-VapourSynth $G.Cfg['VSPIPE']
            $G.HasVs = $vs[0]
            $G.VsNote = $vs[1]
            foreach ($it in $G.Queue) { Normalize-Item $it }
            $G.HelpCache = @{}
            Fill-Encoders
            $G.lvQueue.Items.Refresh()
            Show-Details
        })
    [void]$w.ShowDialog()
}

# Once a day at most, quietly: are there newer versions of what is in bin and vs?
function Check-UpdatesQuietly {
    try {
        $raw = Get-Config $G.Here
        $today = Get-Date -Format 'yyyy-MM-dd'
        if ([string]$raw['UPDATE_LAST_CHECK'] -eq $today) { return }
        Set-ConfigValue 'UPDATE_LAST_CHECK' $today
        $u = Get-Updates
        $app = Get-AppUpdate
        if ($app -ne '') { $u.Insert(0, ('RazAV1 ' + $app + ' [see About]')) }
        if ($u.Count -gt 0) {
            $G.UpdateNote = ('   |   Updates: ' + ($u -join ', ') + ' - open Setup and updates')
            Update-Empty
        }
    }
    catch { }
}

# ---------------------------------------------------------------------------------------------
# gui   (WPF window: queue, per-file settings, profiles, start, progress, approval)
# ---------------------------------------------------------------------------------------------
$WfNames = @(
    '1. 1080p Movie',
    '2. 1080p TV Episode',
    '3. 4K SDR to 1080p  [Lanczos downscale]',
    '4. 4K HDR / Dolby Vision to 1080p SDR  [Hable tonemap]',
    '5. Anime  [no denoise, 10 s keyint, VB 1]',
    '6. 4K SDR to 4K SDR  [native resolution]',
    '7. 4K HDR to 4K HDR10  [HDR10 kept, DV layer dropped]'
)
$WfShort = @('', '1080p Movie', '1080p TV', '4K to 1080p', '4K HDR to SDR', 'Anime', '4K SDR', '4K HDR10')
$GrainStatic = @('None  [digital clean, no grain table]', 'ISO 200  [clean digital sensor noise]', 'ISO 400  [standard 35mm]', 'ISO 800  [gritty 16mm, high noise]')
$GrainAdaptive = @('Light  [modern digital, baseline level 2]', 'Medium  [typical 35mm, baseline level 3]', 'Heavy  [16mm or old film, baseline level 4]')
$CpuValues = @('max', 'normal', 'low')
$CpuNames = @('Max  [AboveNormal, EcoQoS off, all cores]', 'Normal  [EcoQoS off]', 'Low  [BelowNormal, PC stays smooth]')
$DoneValues = @('none', 'sleep', 'shutdown')
$DoneNames = @('Nothing', 'Sleep', 'Shut down')

$script:GuiPump = $false

$GuiResources = @'
<SolidColorBrush x:Key="BrBg" Color="#000000"/>
<SolidColorBrush x:Key="BrCard" Color="#0B0D10"/>
<SolidColorBrush x:Key="BrField" Color="#14171C"/>
<SolidColorBrush x:Key="BrLine" Color="#232830"/>
<SolidColorBrush x:Key="BrFg" Color="#D6DAE1"/>
<SolidColorBrush x:Key="BrDim" Color="#8A919C"/>
<SolidColorBrush x:Key="BrAccent" Color="#1F5FBF"/>
<SolidColorBrush x:Key="BrAccentHi" Color="#2B74E0"/>
<SolidColorBrush x:Key="BrAccentText" Color="#5B9BF0"/>
<SolidColorBrush x:Key="BrLog" Color="#050607"/>
<SolidColorBrush x:Key="BrHover" Color="#1A1F27"/>
<SolidColorBrush x:Key="BrSelect" Color="#12284A"/>
<Style x:Key="Card" TargetType="Border">
  <Setter Property="Background" Value="{StaticResource BrCard}"/>
  <Setter Property="BorderBrush" Value="{StaticResource BrLine}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CornerRadius" Value="10"/>
  <Setter Property="Padding" Value="12"/>
</Style>
<Style x:Key="Head" TargetType="TextBlock">
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Foreground" Value="{StaticResource BrDim}"/>
  <Setter Property="Margin" Value="0,10,0,4"/>
</Style>
<Style TargetType="Button">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="Background" Value="{StaticResource BrField}"/>
  <Setter Property="BorderBrush" Value="{StaticResource BrLine}"/>
  <Setter Property="Padding" Value="11,5"/>
  <Setter Property="Margin" Value="0,0,8,0"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrAccentHi}"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.55"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
  <Setter Property="Background" Value="{StaticResource BrAccent}"/>
  <Setter Property="BorderBrush" Value="{StaticResource BrAccent}"/>
  <Setter Property="Foreground" Value="#E8EEF8"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource BrAccentHi}"/></Trigger>
  </Style.Triggers>
</Style>
<Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
  <Setter Property="Foreground" Value="#E8A0A0"/>
  <Setter Property="BorderBrush" Value="#4A2228"/>
</Style>
<Style x:Key="Stat" TargetType="TextBlock">
  <Setter Property="FontSize" Value="18"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Foreground" Value="#D6DAE1"/>
</Style>
<Style x:Key="StatLabel" TargetType="TextBlock">
  <Setter Property="FontSize" Value="10.5"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Foreground" Value="#6E7580"/>
  <Setter Property="Margin" Value="0,0,0,2"/>
</Style>
<Style x:Key="StatSub" TargetType="TextBlock">
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
  <Setter Property="Foreground" Value="#8A919C"/>
  <Setter Property="Margin" Value="0,1,0,0"/>
</Style>
<Style x:Key="Tile" TargetType="Border">
  <Setter Property="Background" Value="#07080A"/>
  <Setter Property="BorderBrush" Value="#1A1E25"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CornerRadius" Value="8"/>
  <Setter Property="Padding" Value="10,6"/>
  <Setter Property="Margin" Value="0,0,8,8"/>
  <Setter Property="MinWidth" Value="0"/>
</Style>
<Style TargetType="TextBox">
  <Setter Property="Background" Value="{StaticResource BrField}"/>
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="BorderBrush" Value="{StaticResource BrLine}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="CaretBrush" Value="{StaticResource BrFg}"/>
  <Setter Property="SelectionBrush" Value="{StaticResource BrAccent}"/>
  <Setter Property="Padding" Value="6,5"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" SnapsToDevicePixels="True">
          <ScrollViewer x:Name="PART_ContentHost" Focusable="False"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrAccentHi}"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrAccent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ComboBoxItem">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="Bd" Background="Transparent" Padding="10,6">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrHover}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{StaticResource BrDim}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ComboBox">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="MinHeight" Value="28"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
            <ToggleButton.Template>
              <ControlTemplate TargetType="ToggleButton">
                <Border x:Name="Bd" Background="{StaticResource BrField}" BorderBrush="{StaticResource BrLine}" BorderThickness="1" CornerRadius="6">
                  <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" Data="M0,0 L4,4 L8,0" Stroke="{StaticResource BrDim}" StrokeThickness="1.6"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrAccentHi}"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter IsHitTestVisible="False" Margin="10,5,30,5" VerticalAlignment="Center" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
          <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="{StaticResource BrField}" BorderBrush="{StaticResource BrLine}" BorderThickness="1" CornerRadius="6" MaxHeight="320" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
              </ScrollViewer>
            </Border>
          </Popup>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="GridViewColumnHeader">
  <Setter Property="Foreground" Value="{StaticResource BrDim}"/>
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="GridViewColumnHeader">
        <Grid>
          <Border Background="{StaticResource BrCard}" BorderBrush="{StaticResource BrLine}" BorderThickness="0,0,0,1" Padding="6,6">
            <ContentPresenter HorizontalAlignment="Left"/>
          </Border>
          <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="9" Margin="0,0,-5,0" Cursor="SizeWE" ToolTip="Drag to resize the column">
            <Thumb.Template>
              <ControlTemplate TargetType="Thumb">
                <Border Background="Transparent"><Rectangle Width="1" Margin="0,5" Fill="#232830" HorizontalAlignment="Center"/></Border>
              </ControlTemplate>
            </Thumb.Template>
          </Thumb>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListViewItem">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListViewItem">
        <Border x:Name="Bd" Background="Transparent" BorderBrush="{StaticResource BrLine}" BorderThickness="0,0,0,1" Padding="0,7">
          <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrHover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrSelect}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListBox">
  <Setter Property="Background" Value="{StaticResource BrField}"/>
  <Setter Property="BorderBrush" Value="{StaticResource BrLine}"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBox">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="1">
          <ScrollViewer Focusable="False" Padding="{TemplateBinding Padding}"><ItemsPresenter/></ScrollViewer>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListView">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListView">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
          <ScrollViewer Style="{DynamicResource {x:Static GridView.GridViewScrollViewerStyleKey}}" Focusable="False"><ItemsPresenter/></ScrollViewer>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.55"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Style.Triggers>
    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
  </Style.Triggers>
</Style>
<Style TargetType="TabControl">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding" Value="0"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TabControl">
        <DockPanel>
          <Border DockPanel.Dock="Top" BorderBrush="#232830" BorderThickness="0,0,0,1" Margin="0,0,0,10">
            <WrapPanel IsItemsHost="True"/>
          </Border>
          <ContentPresenter ContentSource="SelectedContent"/>
        </DockPanel>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="TabItem">
  <Setter Property="Foreground" Value="#8A919C"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TabItem">
        <Border x:Name="bd" Padding="10,7" Margin="0,0,2,-1" BorderThickness="0,0,0,2" BorderBrush="Transparent" Background="Transparent" Cursor="Hand">
          <ContentPresenter ContentSource="Header" RecognizesAccessKey="False"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Foreground" Value="#D6DAE1"/>
          </Trigger>
          <Trigger Property="IsSelected" Value="True">
            <Setter TargetName="bd" Property="BorderBrush" Value="#2B74E0"/>
            <Setter Property="Foreground" Value="#E8EEF8"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter Property="Opacity" Value="0.45"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListBoxItem">
  <Setter Property="Foreground" Value="{StaticResource BrFg}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="Bd" Background="Transparent" Padding="8,5">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrHover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrSelect}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="SbThumb" TargetType="Thumb">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Thumb">
        <Border x:Name="Bd" Background="#3A414C" CornerRadius="4" Margin="2" MinHeight="20" MinWidth="20"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#555E6B"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource BrAccent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="SbPage" TargetType="RepeatButton">
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ScrollBar">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Width" Value="11"/>
  <Setter Property="MinWidth" Value="11"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
          <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
          <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Height" Value="11"/>
      <Setter Property="MinHeight" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="False">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>
<Style TargetType="ToolTip">
  <Setter Property="Background" Value="#0B0D10"/>
  <Setter Property="Foreground" Value="#D6DAE1"/>
  <Setter Property="BorderBrush" Value="#232830"/>
</Style>
<Style TargetType="ProgressBar">
  <Setter Property="Foreground" Value="{StaticResource BrAccent}"/>
  <Setter Property="Background" Value="{StaticResource BrField}"/>
  <Setter Property="BorderThickness" Value="0"/>
</Style>
<Style x:Key="SplitRows" TargetType="GridSplitter">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="GridSplitter">
        <Border Background="Transparent"><Border Width="46" Height="4" CornerRadius="2" Background="#3A414C" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="SplitCols" TargetType="GridSplitter">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="GridSplitter">
        <Border Background="Transparent"><Border Width="4" Height="46" CornerRadius="2" Background="#3A414C" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$GuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RazAV1" Width="1380" Height="900" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#000000" Foreground="#D6DAE1"
        FontFamily="Segoe UI" FontSize="13" AllowDrop="True" UseLayoutRounding="True">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="btnSimple" Content="Simple view" ToolTip="Switch between the simple view [encoder and quality only] and every setting."/>
        <Button x:Name="btnHistory" Content="History"/>
        <Button x:Name="btnSetup" Content="Setup and updates"/>
        <Button x:Name="btnSettings" Content="Settings"/>
        <Button x:Name="btnAbout" Content="About" Margin="0"/>
      </StackPanel>
      <StackPanel>
        <TextBlock Text="RazAV1" FontSize="22" FontWeight="Bold" Foreground="#5B9BF0"/>
        <TextBlock x:Name="txtSub" Foreground="#8A919C" Margin="0,2,0,0" Text="1.0"/>
      </StackPanel>
    </DockPanel>

    <TabControl x:Name="tabPages" Grid.Row="1">
     <TabItem x:Name="tabFiles">
      <TabItem.Header><TextBlock x:Name="hdrFiles" Text="FILES" FontSize="14"/></TabItem.Header>
      <DockPanel>
       <Border x:Name="bdStrip" DockPanel.Dock="Top" Style="{StaticResource Card}" Padding="12,6" Margin="0,0,0,10" Visibility="Collapsed" Cursor="Hand"
               ToolTip="Click to open the Encoding page">
         <DockPanel>
           <TextBlock x:Name="txtStripPct" DockPanel.Dock="Right" FontWeight="SemiBold" Foreground="#5B9BF0" Margin="12,0,0,0"/>
           <ProgressBar x:Name="pbStrip" DockPanel.Dock="Bottom" Height="4" Minimum="0" Maximum="100" Margin="0,5,0,0"/>
           <TextBlock x:Name="txtStrip" TextTrimming="CharacterEllipsis"/>
         </DockPanel>
       </Border>
    <Grid x:Name="gridWork">
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="colLeft" Width="*" MinWidth="420"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition x:Name="colRight" Width="400" MinWidth="320"/>
      </Grid.ColumnDefinitions>
      <GridSplitter Grid.Column="1" Width="12" HorizontalAlignment="Center" VerticalAlignment="Stretch" Style="{StaticResource SplitCols}"
                    ResizeDirection="Columns" ResizeBehavior="PreviousAndNext" ShowsPreview="False" Cursor="SizeWE" ToolTip="Drag to make the queue or the settings wider"/>

      <Border x:Name="cardQueue" Grid.Column="0" Style="{StaticResource Card}">
        <DockPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,2">
            <WrapPanel x:Name="spQueueTools">
              <Button x:Name="btnAddFiles" Content="Add files" Margin="0,0,6,8"/>
              <Button x:Name="btnAddFolder" Content="Add folder" Margin="0,0,6,8"/>
              <Button x:Name="btnRemove" Content="Remove" Margin="0,0,6,8"/>
              <Button x:Name="btnClear" Content="Clear" Margin="0,0,6,8"/>
              <Button x:Name="btnSelectAll" Content="Select all" Margin="0,0,6,8"/>
              <Button x:Name="btnUp" Content="Up" Padding="10,7" Margin="0,0,6,8" ToolTip="Move the selected files earlier in the queue"/>
              <Button x:Name="btnDown" Content="Down" Padding="10,7" Margin="0,0,16,8" ToolTip="Move the selected files later in the queue"/>
            </WrapPanel>
            <WrapPanel x:Name="spPlanTools">
              <Button x:Name="btnAnalyse" Content="Analyse plan" Margin="0,0,6,8" ToolTip="Runs only the crop scan and the adaptive grain analysis for the selected files, so you can edit the plan before encoding."/>
              <Button x:Name="btnPlan" Content="Edit grain plan" Margin="0,0,6,8" ToolTip="Timeline of the adaptive plan: change the denoise level and grain ISO of any scene."/>
            </WrapPanel>
          </WrapPanel>
          <TextBlock DockPanel.Dock="Bottom" Foreground="#8A919C" Margin="0,8,0,0" TextWrapping="Wrap"
                     Text="Select several files to change them together. Audio and subtitle tracks are picked one file at a time."/>
          <Grid>
            <ListView x:Name="lvQueue" SelectionMode="Extended" Background="Transparent" BorderThickness="0" Foreground="#D6DAE1">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="FILE" Width="230" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="WORKFLOW" Width="96" DisplayMemberBinding="{Binding WfText}"/>
                  <GridViewColumn Header="GRAIN" Width="122" DisplayMemberBinding="{Binding GrainText}"/>
                  <GridViewColumn Header="ENCODER" Width="76" DisplayMemberBinding="{Binding EncText}"/>
                  <GridViewColumn Header="CRF" Width="44" DisplayMemberBinding="{Binding CrfText}"/>
                  <GridViewColumn Header="DENOISE" Width="76" DisplayMemberBinding="{Binding DnText}"/>
                  <GridViewColumn Header="AUDIO" Width="66" DisplayMemberBinding="{Binding AudioText}"/>
                  <GridViewColumn Header="QUALITY" Width="92" DisplayMemberBinding="{Binding Quality}"/>
                  <GridViewColumn Header="STATUS" Width="120" DisplayMemberBinding="{Binding Status}"/>
                </GridView>
              </ListView.View>
            </ListView>
            <TextBlock x:Name="txtEmpty" Text="Drop films or folders here" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="18" Foreground="#3A3F47" IsHitTestVisible="False"/>
          </Grid>
        </DockPanel>
      </Border>

      <Border x:Name="cardDetails" Grid.Column="2" Style="{StaticResource Card}">
        <DockPanel x:Name="spDetails">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Style="{StaticResource Head}" Text="SOURCE" Margin="0,0,0,6"/>
            <TextBlock x:Name="txtSource" TextWrapping="Wrap" Text="No file selected"/>
            <TextBlock x:Name="txtNote" TextWrapping="Wrap" Foreground="#5B9BF0" Margin="0,4,0,0" Visibility="Collapsed"/>
            <TextBlock x:Name="txtWarn" TextWrapping="Wrap" Foreground="#E0B070" Margin="0,4,0,0" Visibility="Collapsed"/>
          </StackPanel>
          <TabControl x:Name="tabDetails" Margin="0,8,0,0">

            <TabItem x:Name="tabVideo" Header="Video">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,6,0">
                  <StackPanel>
                    <TextBlock Style="{StaticResource Head}" Text="PROFILE" Margin="0,0,0,4"/>
                    <DockPanel>
                      <Button x:Name="btnSaveProfile" Tag="adv" DockPanel.Dock="Right" Content="Save as..." Margin="8,0,0,0"
                              ToolTip="Saves the settings of this file [every tab] as a new profile, so you can pick them again with one click."/>
                      <ComboBox x:Name="cbProfile"/>
                    </DockPanel>
                    <TextBlock x:Name="txtProfile" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,4,0,0"/>
                    <TextBlock x:Name="txtProfileSum" TextWrapping="Wrap" Foreground="#5B9BF0" Margin="0,4,0,0"
                               ToolTip="What this file will get, with the profile and any changes made in the tabs."/>
                  </StackPanel>
                  <WrapPanel Margin="0,2,0,0">
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="ENCODER"/>
                      <ComboBox x:Name="cbEncoder"/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="simple">
                      <TextBlock Style="{StaticResource Head}" Text="QUALITY"/>
                      <ComboBox x:Name="cbSimpleQ" ToolTip="Smaller saves the most space. Better keeps more detail and makes bigger files. Balanced is the middle. Everything else follows the profile."/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="adv">
                      <TextBlock Style="{StaticResource Head}" Text="WORKFLOW"/>
                      <ComboBox x:Name="cbWorkflow" ToolTip="Picked from the source when the file is added: film or episode, 1080p or 4K, SDR or HDR."/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="adv">
                      <TextBlock Style="{StaticResource Head}" Text="RESOLUTION"/>
                      <ComboBox x:Name="cbResize"/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="adv">
                      <TextBlock Style="{StaticResource Head}" Text="CROP"/>
                      <ComboBox x:Name="cbCrop" ToolTip="Auto removes black bars after checking the whole film, so scenes in a taller ratio keep their full picture."/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="adv">
                      <TextBlock Style="{StaticResource Head}" Text="QUALITY  [CRF]"/>
                      <DockPanel>
                        <TextBox x:Name="tbCrf" DockPanel.Dock="Right" Width="48" Margin="6,0,0,0" ToolTip="CRF 1-63: lower is better quality and a bigger file. Blank uses the encoder's default."/>
                        <ComboBox x:Name="cbCrfPick" ToolTip="Ready-made choices for this kind of source. Type any number in the box for your own."/>
                      </DockPanel>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0" Tag="adv">
                      <TextBlock Style="{StaticResource Head}" Text="SPEED  [PRESET]"/>
                      <StackPanel Orientation="Horizontal">
                        <TextBox x:Name="tbPreset" Width="48" ToolTip="Preset -1 to 13: lower is slower and a little smaller. Blank uses the encoder's default."/>
                        <TextBlock Text="lower = slower, a little smaller" VerticalAlignment="Center" Foreground="#8A919C" Margin="6,0,0,0"/>
                      </StackPanel>
                    </StackPanel>
                  </WrapPanel>
                  <TextBlock x:Name="txtEncoder" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,6,0,0"/>
                  <Button x:Name="btnResetVideo" Tag="adv" Content="Reset this tab to the profile" HorizontalAlignment="Left" Margin="0,10,0,0"
                          ToolTip="Encoder, CRF, preset, resolution and crop go back to what the profile says."/>
                </StackPanel>
              </ScrollViewer>
            </TabItem>

            <TabItem x:Name="tabGrain" Header="Denoise and grain">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,6,0">
                  <WrapPanel>
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="GRAIN" Margin="0,0,0,4"/>
                      <ComboBox x:Name="cbMode"/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="AMOUNT" Margin="0,0,0,4"/>
                      <ComboBox x:Name="cbGrain"/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="GRAIN ISO"/>
                      <ComboBox x:Name="cbGrainIso" ToolTip="Strength of the grain put back. Auto follows the amount [200, 400 or 800]. With the adaptive plan this is the ISO at the film's typical grain; scenes go up or down from it."/>
                    </StackPanel>
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="DENOISER"/>
                      <ComboBox x:Name="cbDenoiser"/>
                    </StackPanel>
                  </WrapPanel>
                  <TextBlock x:Name="txtPlan" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,6,0,0"/>
                  <TextBlock x:Name="txtDnNote" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,4,0,0"/>
                  <StackPanel x:Name="spKnlm">
                    <TextBlock Style="{StaticResource Head}" Text="GPU DENOISE  [KNLMeansCL]"/>
                    <WrapPanel>
                      <StackPanel Width="230" Margin="0,0,12,0">
                        <ComboBox x:Name="cbKnlmScale" ToolTip="Multiplies the measured [or fixed] strengths. Lower keeps more of the film's own grain and texture; higher removes more and makes smaller files."/>
                      </StackPanel>
                      <CheckBox x:Name="chkKnlmAuto" Content="Measure it on each film  [calibration]" VerticalAlignment="Center" Margin="0,4,0,4"
                                ToolTip="Before the encode, KNLMeansCL is tuned on this film so every denoise level removes as much grain as the hqdn3d levels do. Off: fixed strengths 0.70 to 2.20 [or the profile's own list]."/>
                    </WrapPanel>
                  </StackPanel>
                  <Button x:Name="btnResetGrain" Content="Reset this tab to the profile" HorizontalAlignment="Left" Margin="0,10,0,0"
                          ToolTip="Grain, grain ISO, denoiser and GPU strength go back to what the profile says."/>
                </StackPanel>
              </ScrollViewer>
            </TabItem>

            <TabItem x:Name="tabAudio" Header="Audio">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,6,0">
                  <TextBlock Style="{StaticResource Head}" Text="AUDIO TRACK" Margin="0,0,0,4"/>
                  <ComboBox x:Name="cbAudio" ToolTip="Picked when the file is added: your language, not commentary, the most channels."/>
                  <WrapPanel Margin="0,2,0,0">
                    <StackPanel Width="230" Margin="0,0,12,0">
                      <TextBlock Style="{StaticResource Head}" Text="FORMAT"/>
                      <ComboBox x:Name="cbAudFormat"/>
                    </StackPanel>
                    <WrapPanel x:Name="spAudOpus">
                      <StackPanel Width="230" Margin="0,0,12,0">
                        <TextBlock Style="{StaticResource Head}" Text="CHANNELS"/>
                        <ComboBox x:Name="cbAudChannels"/>
                      </StackPanel>
                      <StackPanel Width="230" Margin="0,0,12,0">
                        <TextBlock Style="{StaticResource Head}" Text="BITRATE"/>
                        <StackPanel Orientation="Horizontal">
                          <TextBox x:Name="tbAudKbps" Width="60" ToolTip="kb/s. Blank = by channel count: stereo 160, 5.1 256 [or the profile's], 6.1 320, 7.1 384."/>
                          <TextBlock Text="kb/s  [blank = automatic]" VerticalAlignment="Center" Foreground="#8A919C" Margin="6,0,0,0"/>
                        </StackPanel>
                      </StackPanel>
                      <StackPanel Width="230" Margin="0,0,12,0">
                        <TextBlock Style="{StaticResource Head}" Text="LOUDNESS"/>
                        <CheckBox x:Name="chkAudNorm" Content="Even it out  [EBU R128]" Margin="0,5,0,0"
                                  ToolTip="Quiet dialogue comes up, loud explosions come down, every film plays at the same level. Off: the level stays exactly as on the disc."/>
                      </StackPanel>
                    </WrapPanel>
                  </WrapPanel>
                  <TextBlock x:Name="txtAudNote" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,6,0,0"/>
                  <Button x:Name="btnResetAudio" Content="Reset this tab to the profile" HorizontalAlignment="Left" Margin="0,10,0,0"
                          ToolTip="Format, channels, bitrate and loudness go back to what the profile [or Settings > Defaults] says."/>
                </StackPanel>
              </ScrollViewer>
            </TabItem>

            <TabItem x:Name="tabSubs" Header="Subtitles">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource Head}" Text="SUBTITLES  [kept tracks go into the file in this order; fonts come along]" Margin="0,0,0,4"/>
                <WrapPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
                  <Button x:Name="btnSubToggle" Content="Keep / drop" Margin="0,0,6,6" ToolTip="Keep the selected track, or drop it. Double-click a track does the same."/>
                  <Button x:Name="btnSubUp" Content="Up" Margin="0,0,6,6" ToolTip="Move the selected kept track earlier"/>
                  <Button x:Name="btnSubDown" Content="Down" Margin="0,0,16,6" ToolTip="Move the selected kept track later"/>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                    <TextBlock Text="On by default" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
                    <ComboBox x:Name="cbSubDefault" Width="230" ToolTip="Which subtitle the player switches on by itself. Forced tracks [signs, foreign dialogue] keep their forced flag."/>
                  </StackPanel>
                </WrapPanel>
                <ListBox x:Name="lbSubs" SelectionMode="Single" MinHeight="90"/>
              </DockPanel>
            </TabItem>

            <TabItem x:Name="tabOutput" Header="Output">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,6,0">
                  <TextBlock Style="{StaticResource Head}" Text="FOLDER" Margin="0,0,0,4"/>
                  <ComboBox x:Name="cbOutWhere" Width="300" HorizontalAlignment="Left"/>
                  <DockPanel x:Name="dpOutDir" Margin="0,6,0,0">
                    <Button x:Name="btnOutBrowse" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
                    <TextBox x:Name="tbOutDir" ToolTip="The folder is created if it does not exist. The grain plan, preview reel and log go here too."/>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Head}" Text="FILE NAME"/>
                  <TextBox x:Name="tbOutName" FontFamily="Consolas"/>
                  <TextBlock TextWrapping="Wrap" Foreground="#8A919C" Margin="0,4,0,0"
                             Text="{}{name} source file name, {res} workflow and size, {grain} grain, {encoder}, {crf}. .mkv is added."/>
                  <TextBlock x:Name="txtOutPreview" TextWrapping="Wrap" Foreground="#5B9BF0" Margin="0,4,0,0"/>
                  <TextBlock Style="{StaticResource Head}" Text="IF THE FILE ALREADY EXISTS"/>
                  <ComboBox x:Name="cbOutExists" Width="300" HorizontalAlignment="Left"/>
                  <Button x:Name="btnResetOutput" Content="Reset this tab to the profile" HorizontalAlignment="Left" Margin="0,12,0,0"
                          ToolTip="Folder, name and the existing-file rule go back to what the profile [or Settings > Defaults] says."/>
                </StackPanel>
              </ScrollViewer>
            </TabItem>

            <TabItem x:Name="tabSource" Header="Source" Tag="adv">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource Head}" Text="WHAT IS IN THE FILE  [read only]" Margin="0,0,0,4"/>
                <TextBox x:Name="tbSrcInfo" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#050607" BorderBrush="#1A1E25"/>
              </DockPanel>
            </TabItem>

            <TabItem x:Name="tabAdv" Header="Advanced">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,6,0">
                  <TextBlock Style="{StaticResource Head}" Text="ENCODER OPTIONS  [blank = profile or encoder default]" Margin="0,0,0,6"/>
                  <WrapPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,14,6">
                      <TextBlock Text="Keyframes" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,6,0"/>
                      <TextBox x:Name="tbKeyint" Width="56" ToolTip="Frames between keyframes [240], or seconds [10s]. Blank uses the workflow's or the encoder's default."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,14,6">
                      <TextBlock Text="Tune" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,6,0"/>
                      <TextBox x:Name="tbTune" Width="40" ToolTip="--tune: 0 = visual quality, 1 = PSNR, 2 = SSIM [forks add more, see their docs]. Blank = profile or encoder default."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,14,6">
                      <TextBlock Text="Variance boost" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,6,0"/>
                      <TextBox x:Name="tbVboost" Width="40" ToolTip="0 = off, 1-4 = more bits for flat, low-contrast areas [skin, skies, dark scenes]. Blank = profile or encoder default."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                      <TextBlock Text="Synthetic grain" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,6,0"/>
                      <TextBox x:Name="tbFilmGrain" Width="40" ToolTip="0-50: SVT-AV1's own film grain, only used when no grain table is chosen. Blank or 0 = off."/>
                    </StackPanel>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Head}" Text="SWITCHES"/>
                  <CheckBox x:Name="chkDarkTune" Content="Dark-scene tuning  [more bits for dark frames, smoother gradients]"
                            ToolTip="--luminance-qp-bias and quantisation matrices [--enable-qm], as in RAZ Triangle. Works with every encoder."/>
                  <CheckBox x:Name="chkSceneKf" Content="Keyframes on scene cuts  [experimental]" Margin="0,8,0,0"
                            ToolTip="Puts keyframes on the main scene cuts [--force-key-frames], at least 2 s apart. Better seeking and no quality dip right after a cut, a slightly bigger file. Uses the scan of the adaptive plan, or scans the film once before the encode."/>
                  <TextBlock Text="Extra options, passed to the encoder as typed" Foreground="#8A919C" Margin="0,14,0,4"/>
                  <TextBox x:Name="tbSvtParams" FontFamily="Consolas" TextWrapping="Wrap" MinHeight="44" AcceptsReturn="False"
                           ToolTip="For example: --tune 2 --enable-tf 0. They come last, so they override anything the profile sets. Checked against this encoder's --help when you press Start."/>
                  <TextBlock x:Name="txtParams" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,4,0,0"/>
                  <Button x:Name="btnResetAdv" Content="Reset this tab to the profile" HorizontalAlignment="Left" Margin="0,14,0,0"
                          ToolTip="Keyframes, tune, variance boost, synthetic grain, the switches and the extra options go back to what the profile says."/>
                </StackPanel>
              </ScrollViewer>
            </TabItem>
            <TabItem x:Name="tabCommand" Header="Command" Tag="adv">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
                  <Button x:Name="btnCopyCmd" DockPanel.Dock="Right" Content="Copy" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Head}" Text="WHAT THE ENGINE RUNS FOR THIS FILE  [read only]" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </DockPanel>
                <TextBox x:Name="tbCmd" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" Background="#050607" BorderBrush="#1A1E25"/>
              </DockPanel>
            </TabItem>
          </TabControl>
        </DockPanel>
      </Border>
    </Grid>

      </DockPanel>
     </TabItem>
     <TabItem x:Name="tabEncoding">
      <TabItem.Header><TextBlock x:Name="hdrEncoding" Text="ENCODING" FontSize="14"/></TabItem.Header>
    <Grid x:Name="gridRun">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Style="{StaticResource Card}">
      <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="420">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="20"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <DockPanel>
            <TextBlock x:Name="txtPct" DockPanel.Dock="Right" FontSize="15" FontWeight="SemiBold" Foreground="#5B9BF0"/>
            <TextBlock x:Name="txtNow" Text="Idle" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <TextBlock x:Name="txtStage" Text="Add files, check the settings, then press Start." Foreground="#8A919C" Margin="0,2,0,8" TextWrapping="Wrap"/>
          <ProgressBar x:Name="pb" Height="8" Minimum="0" Maximum="100" Value="0"/>
          <UniformGrid x:Name="wpStats" Rows="1" Margin="0,10,0,0">
            <Border Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource StatLabel}" Text="ESTIMATED SIZE"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="stSize" Style="{StaticResource Stat}" Text="-"/></Viewbox><TextBlock x:Name="stSizeSub" Style="{StaticResource StatSub}"/></StackPanel></Border>
            <Border Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource StatLabel}" Text="TIME LEFT"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="stEta" Style="{StaticResource Stat}" Text="-"/></Viewbox><TextBlock x:Name="stEtaSub" Style="{StaticResource StatSub}"/></StackPanel></Border>
            <Border Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource StatLabel}" Text="AVERAGE SPEED"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="stSpeed" Style="{StaticResource Stat}" Text="-"/></Viewbox><TextBlock x:Name="stSpeedSub" Style="{StaticResource StatSub}"/></StackPanel></Border>
            <Border Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource StatLabel}" Text="BITRATE"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="stRate" Style="{StaticResource Stat}" Text="-"/></Viewbox><TextBlock x:Name="stRateSub" Style="{StaticResource StatSub}"/></StackPanel></Border>
            <Border Style="{StaticResource Tile}"><StackPanel><TextBlock Style="{StaticResource StatLabel}" Text="FRAMES"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="stFrames" Style="{StaticResource Stat}" Text="-"/></Viewbox><TextBlock x:Name="stFramesSub" Style="{StaticResource StatSub}"/></StackPanel></Border>
          </UniformGrid>
        </StackPanel>
        <StackPanel Grid.Column="2" MinWidth="300" MaxWidth="460">
          <TextBlock x:Name="txtEstimate" Margin="0,0,0,6" TextWrapping="Wrap"/>
          <TextBlock x:Name="txtQuality" Margin="0,0,0,10" TextWrapping="Wrap" Foreground="#8A919C"/>
          <WrapPanel>
            <Button x:Name="btnReel" Content="Open preview reel" IsEnabled="False" Margin="0,0,8,8"/>
            <Button x:Name="btnApprove" Style="{StaticResource AccentButton}" Content="Encode" IsEnabled="False" Margin="0,0,8,8"/>
            <Button x:Name="btnHold" Content="Wait, I am watching" IsEnabled="False" Margin="0,0,8,8"/>
            <Button x:Name="btnSkip" Content="Skip file" IsEnabled="False" Margin="0,0,8,8"/>
            <Button x:Name="btnOpenOut" Content="Open folder" Visibility="Collapsed" Margin="0,0,8,8" ToolTip="Opens the folder of the last finished file"/>
            <Button x:Name="btnPlayOut" Content="Play result" Visibility="Collapsed" Margin="0,0,8,8" ToolTip="Plays the last finished file"/>
          </WrapPanel>
          <DockPanel x:Name="dpDone" Visibility="Collapsed" Margin="0,4,0,0">
            <Button x:Name="btnDoneCancel" DockPanel.Dock="Right" Content="Cancel" Margin="8,0,0,0"/>
            <TextBlock x:Name="txtDone" VerticalAlignment="Center" Foreground="#5B9BF0" TextWrapping="Wrap"/>
          </DockPanel>
        </StackPanel>
      </Grid>
      </ScrollViewer>
    </Border>

    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="12,8" Margin="0,10,0,0">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <CheckBox x:Name="chkFollow" Content="Follow" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Button x:Name="btnDiag" Content="Copy diagnostics" Padding="10,3" ToolTip="Copies versions, settings and the latest log lines, ready to paste into a GitHub issue."/>
            <Button x:Name="btnCopyLog" Content="Copy" Padding="10,3"/>
            <Button x:Name="btnClearLog" Content="Clear" Padding="10,3"/>
            <Button x:Name="btnLogs" Content="Open logs folder" Padding="10,3" Margin="0"/>
          </StackPanel>
          <TextBlock Text="ENGINE OUTPUT" Style="{StaticResource Head}" Margin="0,3,0,0"/>
        </DockPanel>
        <Border Background="#050607" BorderBrush="#1A1E25" BorderThickness="1" CornerRadius="6">
          <DockPanel>
            <Border DockPanel.Dock="Bottom" BorderBrush="#1A1E25" BorderThickness="0,1,0,0" Padding="8,3">
              <TextBlock x:Name="txtLive" FontFamily="Consolas" FontSize="12" Foreground="#5B9BF0" TextTrimming="CharacterEllipsis" Text=" "/>
            </Border>
            <TextBox x:Name="tbLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Background="Transparent" Foreground="#B9BFC9"
                     BorderThickness="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" Padding="4"/>
          </DockPanel>
        </Border>
      </DockPanel>
    </Border>
    </Grid>
     </TabItem>
    </TabControl>

    <Border x:Name="cardControl" Grid.Row="2" Style="{StaticResource Card}" Padding="14,8" Margin="0,10,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <WrapPanel x:Name="wpGlobal" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,12,0">
          <StackPanel Orientation="Horizontal" Margin="0,4,16,4">
            <TextBlock Text="CPU" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
            <ComboBox x:Name="cbCpu" Width="230"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,4,16,4">
            <TextBlock Text="When done" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
            <ComboBox x:Name="cbDone" Width="110"/>
          </StackPanel>
          <CheckBox x:Name="chkApprove" Content="Pause after the preview so I can approve it" VerticalAlignment="Center" IsChecked="True" Margin="0,4,0,4"/>
        </WrapPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnStop" Content="Stop after this file" IsEnabled="False" MinHeight="36"/>
          <Button x:Name="btnAbort" Style="{StaticResource DangerButton}" Content="Abort now" IsEnabled="False" MinHeight="36" MinWidth="100"
                  ToolTip="Stops the encoder at once. A finished video stream is kept for resume; a half-done one is lost."/>
          <Button x:Name="btnStart" Style="{StaticResource AccentButton}" Content="START ENCODING" Margin="0" Padding="22,8" MinHeight="36"/>
        </StackPanel>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

# v7 plan editor: timeline of the adaptive plan, coloured by denoise level
$PlanXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Grain plan" Width="1220" Height="820" MinWidth="980" MinHeight="620" WindowStartupLocation="CenterOwner"
        Background="#000000" Foreground="#D6DAE1" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock Text="GRAIN PLAN" FontSize="18" FontWeight="Bold" Foreground="#5B9BF0"/>
      <TextBlock x:Name="txtFile" Foreground="#8A919C" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,12,0,12" Padding="12,10">
      <StackPanel>
        <DockPanel Margin="0,0,0,6">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" x:Name="spLegend"/>
          <TextBlock Text="TIMELINE  [bar height and colour = denoise level; click a scene, shift-click for a range, drag across to select many]" Style="{StaticResource Head}" Margin="0"/>
        </DockPanel>
        <Border x:Name="bdCanvas" Height="110" Background="#050607" BorderBrush="#1A1E25" BorderThickness="1" CornerRadius="6" ClipToBounds="True">
          <Canvas x:Name="cvTime" Background="Transparent" Cursor="Hand"/>
        </Border>
        <Canvas x:Name="cvTicks" Height="18" Margin="0,2,0,0"/>
        <TextBlock x:Name="txtShare" Foreground="#8A919C" Margin="0,4,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="420"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" Style="{StaticResource Card}" Padding="8">
        <ListView x:Name="lvSeg" SelectionMode="Extended" Background="Transparent" BorderThickness="0" Foreground="#D6DAE1">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="#" Width="48" DisplayMemberBinding="{Binding N}"/>
              <GridViewColumn Header="START" Width="92" DisplayMemberBinding="{Binding StartText}"/>
              <GridViewColumn Header="END" Width="92" DisplayMemberBinding="{Binding EndText}"/>
              <GridViewColumn Header="LENGTH" Width="74" DisplayMemberBinding="{Binding LenText}"/>
              <GridViewColumn Header="GRAIN" Width="70" DisplayMemberBinding="{Binding NoiseText}"/>
              <GridViewColumn Header="LEVEL" Width="62" DisplayMemberBinding="{Binding Level}"/>
              <GridViewColumn Header="ISO" Width="62" DisplayMemberBinding="{Binding Iso}"/>
              <GridViewColumn Header="" Width="90" DisplayMemberBinding="{Binding Changed}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </Border>
      <Border Grid.Column="2" Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Style="{StaticResource Head}" Text="FRAME FROM THE MIDDLE OF THE SCENE" Margin="0,0,0,6"/>
          <Border Background="#050607" BorderBrush="#1A1E25" BorderThickness="1" CornerRadius="6" Height="216">
            <Grid>
              <Image x:Name="imgThumb" Stretch="Uniform"/>
              <TextBlock x:Name="txtThumb" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#3A3F47" Text="Select a scene"/>
            </Grid>
          </Border>
          <TextBlock x:Name="txtSel" TextWrapping="Wrap" Margin="0,8,0,0"/>
          <TextBlock Style="{StaticResource Head}" Text="SET THE SELECTED SCENES TO"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Level" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
            <ComboBox x:Name="cbLevel" Width="70" Margin="0,0,14,0"/>
            <TextBlock Text="ISO" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
            <ComboBox x:Name="cbIso" Width="80" Margin="0,0,14,0"/>
            <Button x:Name="btnApply" Style="{StaticResource AccentButton}" Content="Apply" Margin="0"/>
          </StackPanel>
          <CheckBox x:Name="chkIsoFollow" Content="ISO follows the level [1 = 100, 2 = 200, 3 = 400, 4 = 800, 5 = 1600]" IsChecked="True" Margin="0,8,0,0"/>
          <TextBlock TextWrapping="Wrap" Foreground="#8A919C" Margin="0,10,0,0"
                     Text="Keys in the list: 1-5 set the level, Ctrl+A selects all. Level 1 is the lightest denoise, 5 the strongest. The ISO tier picks the grain table that is put back on top."/>
          <WrapPanel Margin="0,14,0,0">
            <Button x:Name="btnPlus" Content="All one level stronger" Margin="0,0,8,8"/>
            <Button x:Name="btnMinus" Content="All one level lighter" Margin="0,0,8,8"/>
            <Button x:Name="btnRevert" Content="Back to the analysed plan" Margin="0,0,8,8"/>
          </WrapPanel>
        </StackPanel>
      </Border>
    </Grid>
    <DockPanel Grid.Row="3" Margin="0,12,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="btnPlanClose" Content="Close"/>
        <Button x:Name="btnPlanSave" Style="{StaticResource AccentButton}" Content="Save plan" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="txtPlanStatus" VerticalAlignment="Center" Foreground="#8A919C" TextWrapping="Wrap"/>
    </DockPanel>
  </Grid>
</Window>
'@

$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="660" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        Background="#000000" Foreground="#D6DAE1" FontFamily="Segoe UI" FontSize="13" ResizeMode="NoResize" MaxHeight="940">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto">
  <StackPanel Margin="20">
    <TextBlock Text="SETTINGS" FontSize="18" FontWeight="Bold" Foreground="#5B9BF0"/>
    <TextBlock Style="{StaticResource Head}" Text="PORTABLE PACK  [bin, tables and vs next to this program are used first]"/>
    <TextBlock x:Name="txtPack" TextWrapping="Wrap"/>
    <WrapPanel Margin="0,8,0,0">
      <Button x:Name="btnPack" Content="Build portable pack" Margin="0,0,8,8"/>
      <Button x:Name="btnSvtCheck" Content="Check SVT-AV1 update" Margin="0,0,8,8"/>
      <Button x:Name="btnSvtInstall" Content="Install SVT-AV1 build" Margin="0,0,8,8"/>
      <Button x:Name="btnSvtBack" Content="Roll back SVT-AV1" Margin="0,0,8,8"/>
    </WrapPanel>
    <TextBlock x:Name="hdSvt" Style="{StaticResource Head}" Text="SVTAV1ENCAPP.EXE"/>
    <DockPanel><Button x:Name="btnSvt" DockPanel.Dock="Right" Content="Browse" Margin="8,0,0,0"/><TextBox x:Name="tbSvt"/></DockPanel>
    <TextBlock x:Name="hdTables" Style="{StaticResource Head}" Text="GRAIN TABLES FOLDER"/>
    <DockPanel><Button x:Name="btnTables" DockPanel.Dock="Right" Content="Browse" Margin="8,0,0,0"/><TextBox x:Name="tbTables"/></DockPanel>
    <TextBlock x:Name="hdVs" Style="{StaticResource Head}" Text="VSPIPE.EXE  [VapourSynth - leave as vspipe when it is in PATH]"/>
    <DockPanel><Button x:Name="btnVs" DockPanel.Dock="Right" Content="Browse" Margin="8,0,0,0"/><TextBox x:Name="tbVs"/></DockPanel>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
      <Button x:Name="btnCheckVs" Content="Check VapourSynth"/>
      <Button x:Name="btnGpu" Content="Find the fastest GPU"/>
    </StackPanel>
    <TextBlock x:Name="txtVsResult" TextWrapping="Wrap" Foreground="#8A919C" Margin="0,8,0,0"/>
    <TextBlock Style="{StaticResource Head}" Text="KNLMEANSCL GPU DEVICE  [set by Find the fastest GPU]"/>
    <TextBox x:Name="tbDevice" Width="70" HorizontalAlignment="Left"/>
    <TextBlock Style="{StaticResource Head}" Text="PREFERRED AUDIO LANGUAGE  [eng, rum, jpn, ...]"/>
    <TextBox x:Name="tbLang" Width="90" HorizontalAlignment="Left"/>
    <TextBlock Style="{StaticResource Head}" Text="SECONDS BEFORE A QUESTION CONTINUES BY ITSELF"/>
    <TextBox x:Name="tbWait" Width="90" HorizontalAlignment="Left"/>
    <TextBlock Style="{StaticResource Head}" Text="DEFAULT PROFILE FOR NEW FILES"/>
    <ComboBox x:Name="cbDefProfile"/>
    <TextBlock Style="{StaticResource Head}" Text="EXTRAS"/>
    <CheckBox x:Name="chkQuality" Content="Score every probe against the source [VMAF, or SSIM when ffmpeg has no libvmaf]"/>
    <CheckBox x:Name="chkConsole" Content="Run the engine in its own console window instead of showing its output in the main window" Margin="0,8,0,0"/>
    <TextBlock Style="{StaticResource Head}" Text="APPEARANCE  [applies at once]"/>
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="UI size" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
      <ComboBox x:Name="cbScale" Width="210" Margin="0,0,18,0"/>
      <TextBlock Text="Language" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0"/>
      <ComboBox x:Name="cbLang" Width="170" ToolTip="Files in the lang folder. A new language: copy lang\en.txt, see lang\README.txt."/>
    </StackPanel>
    <TextBlock Style="{StaticResource Head}" Text="DEFAULTS FOR EVERY PROFILE  [crop, audio and output, used when a profile leaves them blank, like the stock ones]"/>
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="Audio" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0" Width="60"/>
      <ComboBox x:Name="cbDefAudFormat" Width="180" Margin="0,0,10,0"/>
      <ComboBox x:Name="cbDefAudCh" Width="220"/>
    </StackPanel>
    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="" Width="60" Margin="0,0,8,0"/>
      <CheckBox x:Name="chkDefAudNorm" Content="Even out the loudness  [EBU R128]" VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="Crop" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0" Width="60"/>
      <ComboBox x:Name="cbDefCrop" Width="180"/>
    </StackPanel>
    <DockPanel Margin="0,8,0,0">
      <TextBlock Text="Output" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0" Width="60"/>
      <TextBox x:Name="tbDefOutDir" ToolTip="Folder for finished files. Blank = next to the source."/>
    </DockPanel>
    <DockPanel Margin="0,8,0,0">
      <TextBlock Text="Name" VerticalAlignment="Center" Foreground="#8A919C" Margin="0,0,8,0" Width="60"/>
      <ComboBox x:Name="cbDefOutExists" DockPanel.Dock="Right" Width="190" Margin="8,0,0,0" ToolTip="When the file already exists"/>
      <TextBox x:Name="tbDefOutName" FontFamily="Consolas" ToolTip="{}{name} {res} {grain} {encoder} {crf}"/>
    </DockPanel>
    <TextBlock TextWrapping="Wrap" Foreground="#8A919C" Margin="0,6,0,0"
               Text="Picture tuning [denoise, grain, dark scenes] stays with each profile. These are about the file, so a stock profile gets them too. Files already in the queue keep what they have; Reset this tab picks up the new defaults."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="btnCancel" Content="Cancel"/>
      <Button x:Name="btnSave" Style="{StaticResource AccentButton}" Content="Save" Margin="0"/>
    </StackPanel>
  </StackPanel>
  </ScrollViewer>
</Window>
'@

# Graphite theme: every window is written in the original OLED colours, swapped for these when it loads.
$ThemeMaps = @{
    graphite = [ordered]@{
        '#000000' = '#17191C'; '#0B0D10' = '#1F2125'; '#14171C' = '#282B30'; '#232830' = '#363A41'
        '#D6DAE1' = '#E6E8EB'; '#8A919C' = '#A7ACB5'; '#1F5FBF' = '#525D6C'; '#2B74E0' = '#667386'
        '#5B9BF0' = '#B4BDC9'; '#12284A' = '#36404D'; '#1A1F27' = '#2D3137'; '#050607' = '#141619'
        '#07080A' = '#1B1D21'; '#1A1E25' = '#2E3238'; '#6E7580' = '#959BA4'; '#3A3F47' = '#4D525A'
        '#262B33' = '#3C4048'; '#3A414C' = '#545A63'; '#B9BFC9' = '#C3C6CC'; '#E8EEF8' = '#F0F1F3'
    }
}
$script:UiTheme = 'graphite'
$script:UiScale = 1.0
$script:UiScaleMode = 'fixed'

function Theme-Hex([string]$hex) {
    $map = $ThemeMaps[[string]$script:UiTheme]
    if ($null -ne $map -and $map.Contains($hex.ToUpperInvariant())) { return $map[$hex.ToUpperInvariant()] }
    return $hex
}

# ---- languages ----
# lang\en.txt lists every window text as "key = text". Another file [ro.txt, es.txt...] gives the same keys
# in its language; a key it leaves out stays English. Texts are matched by their English wording, so the
# code only ever deals with English. Engine output and logs always stay English [for bug reports].
$script:Tr = $null

function Read-LangFile([string]$path) {
    $d = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path)) { return $d }
    foreach ($ln in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $l = $ln.TrimStart()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf(' = ')
        if ($i -lt 1) { continue }
        $d[$l.Substring(0, $i).Trim()] = $l.Substring($i + 3).Replace('\n', "`n")
    }
    return $d
}

function Get-Languages {
    $out = New-Object System.Collections.ArrayList
    $dir = Join-Path $PSScriptRoot 'lang'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' | Where-Object { $_.Name -ne 'README.txt' } | Sort-Object Name)) {
            $name = $f.BaseName
            foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
                if ($ln -match '^\s*language\.name\s*=\s*(.+)$') { $name = $Matches[1].Trim(); break }
            }
            [void]$out.Add(@($f.BaseName, $name))
        }
    }
    if ($out.Count -eq 0) { [void]$out.Add(@('en', 'English')) }
    return , $out
}

function Load-Language([string]$code) {
    $script:Tr = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    if ($code -eq '' -or $code -eq 'en') { return }
    $en = Read-LangFile (Join-Path $PSScriptRoot 'lang\en.txt')
    $tr = Read-LangFile (Join-Path $PSScriptRoot ('lang\' + $code + '.txt'))
    foreach ($k in $en.Keys) {
        if ($k.StartsWith('language.')) { continue }
        if ($tr.Contains($k) -and ([string]$tr[$k]).Trim() -ne '' -and -not $script:Tr.ContainsKey($en[$k])) { $script:Tr[$en[$k]] = [string]$tr[$k] }
    }
}

# The text in the chosen language [the English text when there is no translation]
function T([string]$s) {
    if ($null -ne $script:Tr -and $null -ne $s -and $script:Tr.ContainsKey($s)) { return $script:Tr[$s] }
    return $s
}

function Translate-Xaml([string]$t) {
    if ($null -eq $script:Tr -or $script:Tr.Count -eq 0) { return $t }
    $ev = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $v = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        if ($v.StartsWith('{}')) { $v = $v.Substring(2) }
        if (-not $script:Tr.ContainsKey($v)) { return $m.Value }
        $enc = [System.Security.SecurityElement]::Escape($script:Tr[$v]).Replace("`n", '&#10;')
        if ($enc.StartsWith('{')) { $enc = '{}' + $enc }
        return ($m.Groups[1].Value + '="' + $enc + '"')
    }
    return [regex]::Replace($t, '\b(Text|Content|ToolTip|Header|Title|Description)="([^"]*)"', $ev)
}

function Load-Xaml([string]$x) {
    $t = Translate-Xaml ($x.Replace('{{RES}}', $GuiResources))
    $map = $ThemeMaps[[string]$script:UiTheme]
    if ($null -ne $map) { foreach ($k in $map.Keys) { $t = $t.Replace($k, $map[$k]) } }
    $xml = [xml]$t
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $w = [Windows.Markup.XamlReader]::Load($reader)
    # the corner between two scrollbars uses the Windows control colour [white]: make it dark
    try {
        $corner = '#0B0D10'
        if ($null -ne $map -and $map.Contains('#0B0D10')) { $corner = $map['#0B0D10'] }
        $cb = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($corner))
        # .BaseObject: hand WPF the brush itself, not PowerShell's wrapper around it
        $w.Resources.Add([System.Windows.SystemColors]::ControlBrushKey, $cb.psobject.BaseObject)
    }
    catch { }
    if ($null -ne $script:AppIcon -and $w -is [System.Windows.Window]) { try { $w.Icon = $script:AppIcon } catch { } }
    # UI size: everything inside the window is scaled; the window grows with it [within the screen]
    $sc = [double]$script:UiScale
    if ([math]::Abs($sc - 1.0) -gt 0.01 -and $w -is [System.Windows.Window]) {
        if ($w.Content -is [System.Windows.FrameworkElement]) { $w.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($sc, $sc) }
        $wa = [System.Windows.SystemParameters]::WorkArea
        if (-not [double]::IsNaN($w.Width)) { $w.Width = [math]::Min($wa.Width, $w.Width * $sc) }
        if ($w.SizeToContent -eq 'Manual' -and -not [double]::IsNaN($w.Height)) { $w.Height = [math]::Min($wa.Height, $w.Height * $sc) }
        if ($w.MinWidth -gt 0) { $w.MinWidth = [math]::Min($wa.Width, $w.MinWidth * $sc) }
        if ($w.MinHeight -gt 0) { $w.MinHeight = [math]::Min($wa.Height, $w.MinHeight * $sc) }
    }
    return $w
}

function Gui-Pump {
    $G.Win.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Themed message and question box [the Windows one is always light grey]
$AskXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RazAV1" Width="520" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#000000" Foreground="#D6DAE1" FontFamily="Segoe UI" FontSize="13" ShowInTaskbar="False" UseLayoutRounding="True">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <Border Style="{StaticResource Card}" Margin="12">
    <StackPanel>
      <TextBlock x:Name="txtAskTitle" FontSize="15" FontWeight="SemiBold" Foreground="#5B9BF0" Margin="0,0,0,8"/>
      <TextBlock x:Name="txtAskText" TextWrapping="Wrap" LineHeight="19"/>
      <TextBox x:Name="tbAsk" Margin="0,12,0,0" Visibility="Collapsed"/>
      <WrapPanel x:Name="wpAsk" HorizontalAlignment="Right" Margin="0,16,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@

function Get-TopWindow {
    foreach ($w in @($G.AskWin, $G.PE.Win, $G.SW, $G.UW)) {
        if ($null -ne $w) { try { if ($w.IsVisible) { return $w } } catch { } }
    }
    return $G.Win
}

# Returns the text of the button pressed [the last one when the window is closed]; with -Input, $G.AskText holds the typed text
function Show-Ask([string]$title, [string]$text, [string[]]$buttons, $inputDefault = $null) {
    $owner = Get-TopWindow
    $w = Load-Xaml $AskXaml
    try { if ($null -ne $owner -and $owner.IsVisible) { $w.Owner = $owner } else { $w.WindowStartupLocation = 'CenterScreen' } } catch { }
    $w.Title = (T $title)
    $w.FindName('txtAskTitle').Text = (T $title)
    $w.FindName('txtAskText').Text = (T $text)
    $tb = $w.FindName('tbAsk')
    if ($null -ne $inputDefault) { $tb.Visibility = 'Visible'; $tb.Text = $inputDefault; $tb.SelectAll() }
    $wp = $w.FindName('wpAsk')
    $G.AskResult = $buttons[$buttons.Count - 1]
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = (T $buttons[$i])
        $b.Tag = $buttons[$i]
        $b.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        if ($i -eq 0) { $b.Style = $w.FindResource('AccentButton'); $b.IsDefault = $true }
        if ($i -eq $buttons.Count - 1 -and $buttons.Count -gt 1) { $b.IsCancel = $true }
        $b.Add_Click({ param($s, $e) $G.AskResult = [string]$s.Tag; $G.AskText = $G.AskWin.FindName('tbAsk').Text; $G.AskWin.Close() })
        [void]$wp.Children.Add($b)
    }
    $prev = $G.AskWin
    $G.AskWin = $w
    $w.Add_ContentRendered({ if ($G.AskWin.FindName('tbAsk').Visibility -eq 'Visible') { [void]$G.AskWin.FindName('tbAsk').Focus() } })
    [void]$w.ShowDialog()
    $G.AskWin = $prev
    return $G.AskResult
}

function Gui-Msg([string]$text) {
    [void](Show-Ask 'RazAV1' $text @('OK'))
}

function Get-ProfileByName([string]$name) {
    foreach ($p in $G.Profiles) { if ($p['name'] -eq $name) { return $p } }
    return $G.Profiles[0]
}

function Get-ProfileCrf($p, [int]$wf) {
    # blank = 0 = the encoder's own default
    $v = [string]$p['crf']
    if ($wf -eq 2 -or $wf -eq 5) { if ([string]$p['crf_tv'] -ne '') { $v = [string]$p['crf_tv'] } }
    if ($v.Trim() -eq '') { return 0 }
    return [int](To-Num $v)
}

function Apply-ProfileToItem($it, $p) {
    $it.Profile = $p['name']
    $it.Mode = [int](To-Num $p['mode'])
    $it.Grain = [int](To-Num $p['grain'])
    $it.Crf = Get-ProfileCrf $p $it.Workflow
    $it.Denoiser = [string]$p['denoiser']
    $it.Encoder = [string]$p['encoder']
    $it.Crop = Get-AppDefault $p 'crop' 'DEF_CROP' 'auto'
    $it.Preset = ([string]$p['preset']).Trim()
    $it.Keyint = ([string]$p['keyint']).Trim()
    $it.SvtParams = ([string]$p['svt_params']).Trim()
    $it.Resize = ([string]$p['resize']).Trim()
    $it.Tune = ([string]$p['tune']).Trim()
    $it.VBoost = ([string]$p['vboost']).Trim()
    $it.FilmGrain = ([string]$p['film_grain']).Trim()
    $it.GrainIso = ([string]$p['grain_iso']).Trim()
    $it.SceneKf = ([string]$p['scene_kf']).Trim()
    if ([string]$p['knlm_h'] -eq 'auto') { $it.KnlmAuto = '1' } else { $it.KnlmAuto = '0' }
    $it.KnlmScale = To-Num $p['knlm_scale']
    if ((To-Num $p['luma_bias']) -ne 0 -or [string]$p['enable_qm'] -eq '1') { $it.DarkTune = '1' } else { $it.DarkTune = '0' }
    # file handling: the profile's value, or the app default from Settings when the profile leaves it blank
    $it.AudFormat = Get-AppDefault $p 'audio_format' 'DEF_AUDIO_FORMAT' 'opus'
    $it.AudChannels = Get-AppDefault $p 'audio_channels' 'DEF_AUDIO_CHANNELS' 'auto'
    $it.AudNorm = Get-AppDefault $p 'audio_norm' 'DEF_AUDIO_NORM' '1'
    $it.AudKbps = ([string]$p['audio_kbps']).Trim()
    $it.OutDir = Get-AppDefault $p 'out_dir' 'DEF_OUT_DIR' ''
    $it.OutName = Get-AppDefault $p 'out_name' 'DEF_OUT_NAME' '{name}_AV1_{res}_{grain}'
    $it.OutExists = Get-AppDefault $p 'out_exists' 'DEF_OUT_EXISTS' 'number'
    $keep = @()
    if ($p['subs'] -eq '1') { for ($k = 0; $k -lt $it.SubTracks.Count; $k++) { $keep += $k } }
    $it.SubKeep = $keep
    Normalize-Item $it
}

function Normalize-Item($it) {
    if ($it.Workflow -lt 1 -or $it.Workflow -gt 7) { $it.Workflow = 1 }
    if ($it.Mode -ne 2) { $it.Mode = 1 }
    if ($it.Workflow -eq 5) { $it.Mode = 1 }
    if ($it.Grain -lt 1 -or $it.Grain -gt 4) { $it.Grain = 3 }
    if ($it.Mode -eq 2 -and $it.Grain -eq 1) { $it.Grain = 2 }
    if ($it.Denoiser -ne 'knlm' -and $it.Denoiser -ne 'none') { $it.Denoiser = 'hqdn3d' }
    if ($it.Denoiser -eq 'knlm' -and -not $G.HasVs) { $it.Denoiser = 'hqdn3d' }
    # the adaptive plan changes the denoise strength per scene, so it needs a denoiser
    if ($it.Denoiser -eq 'none') { $it.Mode = 1 }
    if ($it.Crf -lt 0 -or $it.Crf -gt 63) { $it.Crf = 30 }
    if (-not $EncoderDefs.Contains([string]$it.Encoder)) { $it.Encoder = 'mainline' }
    if ($it.Crop -ne 'off') { $it.Crop = 'auto' }
    if ($it.AudFormat -ne 'copy') { $it.AudFormat = 'opus' }
    if (@('auto', 'keep', 'stereo') -notcontains [string]$it.AudChannels) { $it.AudChannels = 'auto' }
    if ([string]$it.AudNorm -ne '0') { $it.AudNorm = '1' }
    if (@('number', 'skip', 'replace') -notcontains [string]$it.OutExists) { $it.OutExists = 'number' }
    if ([string]$it.OutName -eq '' -or -not (Test-OutName $it.OutName)) { $it.OutName = '{name}_AV1_{res}_{grain}' }
    $ak = 0
    if (-not ([int]::TryParse([string]$it.AudKbps, [ref]$ak) -and $ak -ge 32 -and $ak -le 1024)) { $it.AudKbps = '' }
    if ($it.Resize -ne '1920' -and $it.Resize -ne '1280') { $it.Resize = '' }
    $gi = 0
    if (-not ([int]::TryParse([string]$it.GrainIso, [ref]$gi) -and $gi -ge 25 -and $gi -le 25600)) { $it.GrainIso = '' }
    if ([string]$it.SceneKf -ne '1') { $it.SceneKf = '0' }
    if ([string]$it.KnlmAuto -ne '0') { $it.KnlmAuto = '1' }
    if ([string]$it.DarkTune -ne '1') { $it.DarkTune = '0' }
    $ks = To-Num $it.KnlmScale
    if ($ks -lt 0.3 -or $ks -gt 3.0) { $ks = 1.0 }
    $it.KnlmScale = $ks
    Update-ItemText $it
}

function Update-ItemText($it) {
    $it.WfText = $WfShort[$it.Workflow]
    if ($it.Mode -eq 2) {
        $it.GrainText = 'Adaptive ' + @('', '', 'light', 'medium', 'heavy')[$it.Grain]
        if ($it.GrainIso -ne '') { $it.GrainText = 'Adaptive ~ISO' + $it.GrainIso }
    }
    else {
        $it.GrainText = 'Static ' + @('', 'none', 'ISO200', 'ISO400', 'ISO800')[$it.Grain]
        if ($it.GrainIso -ne '' -and $it.Grain -gt 1) { $it.GrainText = 'Static ISO' + $it.GrainIso }
    }
    $it.EncText = (Get-EncoderDef $it.Encoder).Short
    if ($it.Crf -eq 0) { $it.CrfText = 'default' } else { $it.CrfText = [string]$it.Crf }
    if ($it.Workflow -eq 5 -or $it.Denoiser -eq 'none') { $it.DnText = 'none' }
    elseif ($it.Denoiser -eq 'knlm' -and $it.Workflow -ne 4) { $it.DnText = 'KNLM GPU' }
    else { $it.DnText = 'hqdn3d' }
    $it.AudioText = 'none'
    foreach ($t in $it.AudioTracks) { if ($t.Index -eq $it.AudioIdx) { $it.AudioText = ('{0} {1}ch' -f $t.Lang, $t.Ch) } }
    if ($it.AudFormat -eq 'copy' -and $it.AudioText -ne 'none') { $it.AudioText += ' copy' }
}

function Get-WfNote($it) {
    $k = [string]$it.Info.Kind
    $wf = $it.Workflow
    $n = ''
    if ($wf -ne $it.Info.Suggest) { $n = ('Suggested for this file: workflow {0}. ' -f $it.Info.Suggest) }
    if ($k -eq 'SDR') {
        if ($wf -eq 4) { $n += 'The source is SDR, so workflow 4 runs as 3.' }
        if ($wf -eq 7) { $n += 'The source is SDR, so workflow 7 runs as 6.' }
    }
    else {
        if ($wf -eq 3) { $n += 'The source is HDR, so workflow 3 runs as 4.' }
        if ($wf -eq 6 -and $k -ne 'DV5') { $n += 'The source is HDR, so workflow 6 runs as 7.' }
        if (@(1, 2, 5) -contains $wf) { $n += 'HDR source in an SDR workflow: colours will look washed out.' }
        if ($k -eq 'DV5' -and ($wf -eq 7 -or $wf -eq 6)) { $n += 'Dolby Vision profile 5 cannot be kept as HDR10. Use workflow 4.' }
        if ($k -eq 'DV5' -and $wf -eq 4) { $n += 'Dolby Vision profile 5: the tonemap may give a colour tint.' }
    }
    return $n.Trim()
}

function New-QueueItem([string]$path) {
    $info = Get-SourceInfo $path
    $aud = Get-AudioTracks $path
    $subs = Get-SubTracks $path
    $it = New-Object PSObject -Property ([ordered]@{
            Path = $path; Name = [System.IO.Path]::GetFileName($path); Info = $info
            AudioTracks = $aud.Tracks; AudioIdx = [int]$aud.Pick; SubTracks = $subs; SubKeep = @(); SubDefault = -2
            Profile = ''; Workflow = [int]$info.Suggest; Mode = 1; Grain = 3; Crf = 30; Denoiser = 'hqdn3d'
            Encoder = 'mainline'; Crop = 'auto'; Preset = ''; Keyint = ''; SvtParams = ''; Resize = ''; Tune = ''; VBoost = ''; FilmGrain = ''; GrainIso = ''; SceneKf = '0'
            KnlmAuto = '1'; KnlmScale = 1.0; DarkTune = '0'
            AudFormat = 'opus'; AudChannels = 'auto'; AudKbps = ''; AudNorm = '1'
            OutDir = ''; OutName = '{name}_AV1_{res}_{grain}'; OutExists = 'number'; SrcInfo = ''
            Status = 'Ready'; WfText = ''; GrainText = ''; DnText = ''; AudioText = ''; Quality = ''; EncText = ''; CrfText = ''
            SrcGB = 0.0; OutPath = ''; Logged = $false
        })
    try { $it.SrcGB = (Get-Item -LiteralPath $path).Length / 1GB } catch { }
    Apply-ProfileToItem $it (Get-ProfileByName $G.Cfg['DEFAULT_PROFILE'])
    return $it
}

function Update-Empty {
    if ($G.Queue.Count -eq 0) { $G.txtEmpty.Visibility = 'Visible' } else { $G.txtEmpty.Visibility = 'Collapsed' }
    if ($null -ne $G.hdrFiles) { Update-Strip }
    $saved = ''
    if ([double]$G.TotalSaved -gt 0.05) { $saved = '  -  saved so far: ' + (Format-Size $G.TotalSaved) }
    $G.txtSub.Text = ($AppVersion + '  -  {0} file(s) in the queue  -  drop films or folders onto the list' -f $G.Queue.Count) + $saved + [string]$G.UpdateNote
}

function Add-Paths([string[]]$paths) {
    $exts = @('.mkv', '.mp4', '.m4v', '.m2ts', '.ts', '.mov', '.avi', '.webm')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $p -File | Sort-Object Name)) {
                if (($exts -contains $f.Extension.ToLower()) -and ($f.Name -notmatch '_preview_reel|_temp_raw|_v[45]\.|_v\d+(\.\d+)*_(1080p|TVShow|4Kto1080p|HDRtoSDR|Anime|4K_)|_AV1_(1080p|TVShow|4Kto1080p|HDRtoSDR|Anime|4K_)')) { $files.Add($f.FullName) }
            }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $p).Path) }
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.ArrayList
    $k = 0
    foreach ($f in $files) {
        $k++
        if ($f.Contains('!')) { $problems.Add([System.IO.Path]::GetFileName($f) + '  [exclamation marks in names are not supported]'); continue }
        $dupe = $false
        foreach ($q in $G.Queue) { if ($q.Path -eq $f) { $dupe = $true } }
        if ($dupe) { continue }
        $G.txtStage.Text = ('Reading file {0} of {1}: {2}' -f $k, $files.Count, [System.IO.Path]::GetFileName($f))
        Gui-Pump
        try {
            $it = New-QueueItem $f
            $G.Queue.Add($it)
            [void]$added.Add($it)
        }
        catch { $problems.Add([System.IO.Path]::GetFileName($f) + '  [' + $_.Exception.Message + ']') }
    }
    $G.txtStage.Text = 'Check the settings on the right, then press Start.'
    Update-Empty
    if ($added.Count -gt 0) {
        $G.lvQueue.SelectedItems.Clear()
        foreach ($a in $added) { [void]$G.lvQueue.SelectedItems.Add($a) }
    }
    if ($problems.Count -gt 0) { Gui-Msg ("These files were not added:`n`n" + ($problems -join "`n")) }
}

# ---------------------------------------------------------------------------------------------
# v1.0 stage 4: simple view, results, history, queue memory, diagnostics, About, app updates
# ---------------------------------------------------------------------------------------------
$AppVersion = '1.0.0'
# The GitHub repository of this app, as owner/name [for example RAZBUMN/RazAV1].
# When set, the window checks it once a day for a newer release.
$AppRepo = 'RAZBUMN/RazAV1'

# Quick quality choices of the simple view: CRF for Smaller / Balanced / Better
function Get-SimpleCrf([int]$wf, [int]$idx) {
    $films = @(34, 30, 26)
    $tv = @(30, 26, 22)
    if ($wf -eq 2 -or $wf -eq 5) { return $tv[$idx] }
    return $films[$idx]
}

# Simple view: only the Video tab [file, encoder, quality level], Audio and Subtitles.
# Panels tagged "adv" show in Advanced view only, "simple" in Simple view only.
function Set-TaggedVisibility($node, [bool]$simple) {
    foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
        if ($c -isnot [System.Windows.DependencyObject]) { continue }
        if ($c -is [System.Windows.FrameworkElement]) {
            if ([string]$c.Tag -eq 'adv') { if ($simple) { $c.Visibility = 'Collapsed' } else { $c.Visibility = 'Visible' } }
            elseif ([string]$c.Tag -eq 'simple') { if ($simple) { $c.Visibility = 'Visible' } else { $c.Visibility = 'Collapsed' } }
        }
        Set-TaggedVisibility $c $simple
    }
}

function Apply-ViewMode {
    $simple = [bool]$G.Simple
    Set-TaggedVisibility $G.tabDetails $simple
    foreach ($t in @($G.tabGrain, $G.tabAdv)) { if ($simple) { $t.Visibility = 'Collapsed' } else { $t.Visibility = 'Visible' } }
    if ($null -ne $G.tabDetails.SelectedItem -and $G.tabDetails.SelectedItem.Visibility -ne 'Visible') { $G.tabDetails.SelectedItem = $G.tabVideo }
    if ($simple) { $G.spPlanTools.Visibility = 'Collapsed'; $G.btnSimple.Content = (T 'Advanced view') }
    else { $G.spPlanTools.Visibility = 'Visible'; $G.btnSimple.Content = (T 'Simple view') }
}

# ---- tabs: which settings differ from the profile, and putting a tab back ----
$SectionKeys = @{
    video = @('Encoder', 'Crf', 'Preset', 'Resize', 'Crop')
    grain = @('Mode', 'Grain', 'GrainIso', 'Denoiser', 'KnlmAuto', 'KnlmScale')
    adv   = @('Keyint', 'Tune', 'VBoost', 'FilmGrain', 'SceneKf', 'DarkTune', 'SvtParams')
    audio = @('AudFormat', 'AudChannels', 'AudKbps', 'AudNorm')
    output = @('OutDir', 'OutName', 'OutExists')
}

# The item as its profile would set it [a copy; the item itself is not touched]
function Get-ProfileTwin($it) {
    $twin = $it.PSObject.Copy()
    Apply-ProfileToItem $twin (Get-ProfileByName $it.Profile)
    return $twin
}

function Get-ChangedSections($it) {
    $out = @{ video = $false; grain = $false; adv = $false; audio = $false; output = $false }
    if ($null -eq $it) { return $out }
    $twin = Get-ProfileTwin $it
    foreach ($sec in @($SectionKeys.Keys)) {
        foreach ($k in $SectionKeys[$sec]) { if ([string]$it.$k -ne [string]$twin.$k) { $out[$sec] = $true } }
    }
    return $out
}

function Update-TabMarks($it) {
    $ch = Get-ChangedSections $it
    $names = @{ video = @($G.tabVideo, 'Video'); grain = @($G.tabGrain, 'Denoise and grain'); adv = @($G.tabAdv, 'Advanced'); audio = @($G.tabAudio, 'Audio'); output = @($G.tabOutput, 'Output') }
    foreach ($sec in @($names.Keys)) {
        $tab = $names[$sec][0]
        if ($ch[$sec]) { $tab.Header = (T $names[$sec][1]) + '  *'; $tab.ToolTip = (T 'Changed from the profile') + ' [' + $it.Profile + ']' }
        else { $tab.Header = (T $names[$sec][1]); $tab.ToolTip = $null }
    }
}

function Reset-Section([string]$sec) {
    Edit-Selected {
        param($it)
        $twin = Get-ProfileTwin $it
        foreach ($k in $SectionKeys[$sec]) { $it.$k = $twin.$k }
    }
}

function Get-ItemWarnings($it) {
    $w = @()
    if ($it.Crf -gt 45) { $w += 'CRF above 45 gives visibly low quality.' }
    $wf = [int]$it.Workflow
    $kind = [string]$it.Info.Kind
    if ($kind -ne '' -and $kind -ne 'SDR' -and $wf -ne 4 -and $wf -ne 7) { $w += 'HDR source on an SDR workflow: colours will look washed out. Use 4K HDR to SDR or 4K HDR10.' }
    if ($kind -eq 'SDR' -and ($wf -eq 4 -or $wf -eq 7)) { $w += 'This source is SDR; an HDR workflow does not fit it.' }
    if ([int]$it.Info.W -gt 0 -and [int]$it.Info.W -le 1920 -and ($wf -eq 3 -or $wf -eq 4 -or $wf -eq 6 -or $wf -eq 7)) { $w += 'This source is not 4K; a 4K workflow does not fit it.' }
    if ($it.GrainIso -ne '' -and $it.Mode -ne 2 -and $it.Grain -eq 1) { $w += 'Grain ISO has no effect while grain is set to none.' }
    $pp = Get-ProfileByName $it.Profile
    if ($null -ne $pp -and [string]$pp['stock'] -eq '1' -and $it.Denoiser -ne 'none') { $w += 'Stock profile with a denoiser: no longer the plain encoder defaults.' }
    $pv = 0
    if ([int]::TryParse([string]$it.Preset, [ref]$pv) -and $pv -lt 2) { $w += 'Presets below 2 are extremely slow: many hours for one film on most PCs.' }
    if ($it.Encoder -ne 'mainline' -and (Get-EncoderExe $it.Encoder) -eq '') { $w += (Get-EncoderDef $it.Encoder).Name + ' is not installed yet [Setup and updates].' }
    if ([string]$it.SvtParams -ne '' -and (Test-UnsafeParams $it.SvtParams)) { $w += 'The extra options contain characters the engine cannot pass on.' }
    return ($w -join '  ')
}

# ---- history [logs\history.tsv, one line per finished file] ----
function Get-HistoryPath { return (Join-Path (Join-Path $G.Here 'logs') 'history.tsv') }

function Add-History($it, [double]$outGB, [string]$took, [string]$quality, [string]$outPath) {
    try {
        $hp = Get-HistoryPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hp) | Out-Null
        if (-not (Test-Path -LiteralPath $hp)) { [System.IO.File]::WriteAllText($hp, "date`tfile`tsource_gb`toutput_gb`tsaved_pct`ttime`tquality`tencoder`tprofile`toutput`r`n") }
        $srcGB = [double]$it.SrcGB
        $pct = 0
        if ($srcGB -gt 0) { $pct = [math]::Round(100.0 * (1.0 - $outGB / $srcGB)) }
        $line = @((Get-Date -Format 'yyyy-MM-dd HH:mm'), $it.Name, $srcGB.ToString('0.00', $inv), $outGB.ToString('0.00', $inv), [string]$pct, $took, $quality, (Get-EncoderDef $it.Encoder).Name, $it.Profile, $outPath) -join "`t"
        [System.IO.File]::AppendAllText($hp, $line + "`r`n")
    }
    catch { Write-LogFile 'errors.log' ('history: ' + $_.Exception.Message) }
}

function Read-History {
    $rows = New-Object System.Collections.Generic.List[object]
    $hp = Get-HistoryPath
    if (-not (Test-Path -LiteralPath $hp)) { return , $rows }
    $lines = [System.IO.File]::ReadAllLines($hp)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $f = $lines[$i].Split("`t")
        if ($f.Count -lt 10) { continue }
        $srcGB = To-Num $f[2]; $outGB = To-Num $f[3]
        $rows.Add((New-Object PSObject -Property ([ordered]@{
                        Date = $f[0]; File = $f[1]; SrcText = $srcGB.ToString('0.00', $inv) + ' GB'; OutText = $outGB.ToString('0.00', $inv) + ' GB'
                        SavedText = $f[4] + ' %'; Time = $f[5]; Quality = $f[6]; Encoder = $f[7]; Profile = $f[8]; Output = $f[9]; SavedGB = ($srcGB - $outGB)
                    })))
    }
    return , $rows
}

function Format-Size([double]$gb) {
    if ($gb -ge 1024) { return ($gb / 1024).ToString('0.00', $inv) + ' TB' }
    return $gb.ToString('0.0', $inv) + ' GB'
}

function Get-TotalSaved {
    $t = 0.0
    foreach ($r in (Read-History)) { $t += [double]$r.SavedGB }
    return $t
}

$HistoryXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="History" Width="1100" Height="640" MinWidth="760" MinHeight="400" WindowStartupLocation="CenterOwner"
        Background="#000000" Foreground="#D6DAE1" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
{{RES}}
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel>
      <TextBlock Text="HISTORY" FontSize="18" FontWeight="Bold" Foreground="#5B9BF0"/>
      <TextBlock x:Name="txtHistTotal" Foreground="#8A919C" Margin="0,2,0,12" TextWrapping="Wrap"/>
    </StackPanel>
    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="8">
      <ListView x:Name="lvHist" SelectionMode="Single" Background="Transparent" BorderThickness="0" Foreground="#D6DAE1">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="DATE" Width="120" DisplayMemberBinding="{Binding Date}"/>
            <GridViewColumn Header="FILE" Width="300" DisplayMemberBinding="{Binding File}"/>
            <GridViewColumn Header="SOURCE" Width="80" DisplayMemberBinding="{Binding SrcText}"/>
            <GridViewColumn Header="AV1" Width="80" DisplayMemberBinding="{Binding OutText}"/>
            <GridViewColumn Header="SAVED" Width="64" DisplayMemberBinding="{Binding SavedText}"/>
            <GridViewColumn Header="TIME" Width="70" DisplayMemberBinding="{Binding Time}"/>
            <GridViewColumn Header="QUALITY" Width="100" DisplayMemberBinding="{Binding Quality}"/>
            <GridViewColumn Header="ENCODER" Width="120" DisplayMemberBinding="{Binding Encoder}"/>
            <GridViewColumn Header="PROFILE" Width="130" DisplayMemberBinding="{Binding Profile}"/>
          </GridView>
        </ListView.View>
      </ListView>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="btnHistOpen" Content="Open folder"/>
      <Button x:Name="btnHistPlay" Content="Play"/>
      <Button x:Name="btnHistClose" Style="{StaticResource AccentButton}" Content="Close" Margin="0"/>
    </StackPanel>
  </Grid>
</Window>
'@

function Show-History {
    $w = Load-Xaml $HistoryXaml
    $w.Owner = $G.Win
    $G.HW = $w
    $rows = Read-History
    $rows.Reverse()
    $w.FindName('lvHist').ItemsSource = $rows
    $tot = 0.0
    foreach ($r in $rows) { $tot += [double]$r.SavedGB }
    $w.FindName('txtHistTotal').Text = ('{0} files encoded, {1} saved in total.' -f $rows.Count, (Format-Size $tot))
    $w.FindName('btnHistOpen').Add_Click({
            $r = $G.HW.FindName('lvHist').SelectedItem
            if ($null -ne $r -and (Test-Path -LiteralPath $r.Output)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $r.Output + '"') }
        })
    $w.FindName('btnHistPlay').Add_Click({
            $r = $G.HW.FindName('lvHist').SelectedItem
            if ($null -ne $r -and (Test-Path -LiteralPath $r.Output)) { Start-Process -FilePath $r.Output }
        })
    $w.FindName('btnHistClose').Add_Click({ $G.HW.Close() })
    [void]$w.ShowDialog()
}

# ---- queue memory [queue.json next to the program] ----
$QueueKeys = @('Path', 'Profile', 'Workflow', 'Mode', 'Grain', 'Crf', 'Denoiser', 'Encoder', 'Crop', 'Preset', 'Keyint', 'SvtParams', 'Resize', 'Tune', 'VBoost', 'FilmGrain', 'GrainIso', 'SceneKf', 'KnlmAuto', 'KnlmScale', 'DarkTune', 'AudFormat', 'AudChannels', 'AudKbps', 'AudNorm', 'SubDefault', 'OutDir', 'OutName', 'OutExists', 'AudioIdx')

function Save-Queue {
    try {
        $list = @()
        foreach ($it in $G.Queue) {
            if ($it.Status -like 'Done*') { continue }
            $o = [ordered]@{}
            foreach ($k in $QueueKeys) { $o[$k] = $it.$k }
            $o['SubKeep'] = (@($it.SubKeep) -join ',')
            $list += (New-Object PSObject -Property $o)
        }
        $qp = Join-Path $G.Here 'queue.json'
        if ($list.Count -eq 0) { Remove-Item -LiteralPath $qp -Force -ErrorAction SilentlyContinue; return }
        [System.IO.File]::WriteAllText($qp, (ConvertTo-Json -InputObject @($list) -Depth 3))
    }
    catch { Write-LogFile 'errors.log' ('queue save: ' + $_.Exception.Message) }
}

function Restore-Queue {
    $qp = Join-Path $G.Here 'queue.json'
    if (-not (Test-Path -LiteralPath $qp)) { return }
    try {
        $saved = @(ConvertFrom-Json ([System.IO.File]::ReadAllText($qp)))
        $n = 0
        foreach ($o in $saved) {
            if (-not (Test-Path -LiteralPath ([string]$o.Path))) { continue }
            $G.txtNow.Text = 'Restoring the queue from last time...'
            Gui-Pump
            $it = New-QueueItem ([string]$o.Path)
            foreach ($k in $QueueKeys) { if ($k -ne 'Path' -and $null -ne $o.$k) { $it.$k = $o.$k } }
            $it.SubKeep = @(([string]$o.SubKeep).Split(',') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
            Normalize-Item $it
            $G.Queue.Add($it)
            $n++
        }
        if ($n -gt 0) { $G.txtNow.Text = ('Restored {0} file(s) from last time' -f $n) } else { $G.txtNow.Text = 'Idle' }
        Update-Empty
    }
    catch { Write-LogFile 'errors.log' ('queue restore: ' + $_.Exception.Message) }
}

function Move-Selected([int]$dir) {
    $sel = @($G.lvQueue.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $idx = @($sel | ForEach-Object { $G.Queue.IndexOf($_) } | Sort-Object)
    if ($dir -gt 0) { [array]::Reverse($idx) }
    foreach ($i in $idx) {
        $j = $i + $dir
        if ($j -lt 0 -or $j -ge $G.Queue.Count) { continue }
        if ($sel -contains $G.Queue[$j]) { continue }
        $G.Queue.Move($i, $j)
    }
    foreach ($x in $sel) { [void]$G.lvQueue.SelectedItems.Add($x) }
}

# ---- free space: final file + temporary video and audio, per output drive ----
function Test-QueueSpace($items) {
    $need = @{}
    foreach ($it in $items) {
        try {
            $root = [System.IO.Path]::GetPathRoot($it.Path)
            $gb = (Get-Item -LiteralPath $it.Path).Length / 1GB
            if (-not $need.ContainsKey($root)) { $need[$root] = 2.0 }
            $need[$root] += $gb * 0.35
        }
        catch { }
    }
    $msgs = @()
    foreach ($root in $need.Keys) {
        try {
            $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace / 1GB
            if ($free -lt $need[$root]) { $msgs += ('{0} has {1} GB free; these encodes may need about {2} GB.' -f $root, [math]::Round($free, 1), [math]::Round($need[$root], 1)) }
        }
        catch { }
    }
    return ($msgs -join "`n")
}

# ---- diagnostics for bug reports ----
function Get-Diagnostics {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('RazAV1 ' + $AppVersion + ' diagnostics, ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    try { [void]$sb.AppendLine('Windows: ' + [System.Environment]::OSVersion.VersionString + ', PowerShell ' + $PSVersionTable.PSVersion) } catch { }
    try { [void]$sb.AppendLine('CPU: ' + (Get-CimInstance Win32_Processor | Select-Object -First 1).Name + ', ' + [Environment]::ProcessorCount + ' threads') } catch { }
    try { foreach ($v in @(Get-CimInstance Win32_VideoController)) { [void]$sb.AppendLine('GPU: ' + $v.Name + ' [driver ' + $v.DriverVersion + ']') } } catch { }
    $st = Get-ComponentStatus
    [void]$sb.AppendLine('ffmpeg: ' + $st.Ffmpeg)
    [void]$sb.AppendLine('VapourSynth: ' + $st.Vs + ' | ready: ' + $G.HasVs + ' ' + $G.VsNote)
    [void]$sb.AppendLine('SVT-AV1: ' + $st.Svt)
    [void]$sb.AppendLine('SVT-AV1-Essential: ' + $st.Ess)
    [void]$sb.AppendLine('SVT-AV1-HDR: ' + $st.Hdr)
    [void]$sb.AppendLine('Grain tables: ' + $st.Tables)
    [void]$sb.AppendLine('Build tools: ' + (Get-ToolsText))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Settings:')
    # the values in use: portable bin, vs and tables folders replace what config.txt says
    $eff = Get-EffectiveConfig $G.Here
    $raw = Get-Config $G.Here
    foreach ($k in $raw.Keys) {
        if ($k -match 'LAYOUT') { continue }
        $v = [string]$raw[$k]
        if ($eff.Contains($k) -and [string]$eff[$k] -ne $v) { $v = [string]$eff[$k] + '   [config.txt says ' + $raw[$k] + ', not used]' }
        [void]$sb.AppendLine('  ' + $k + '=' + $v)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Queue:')
    foreach ($it in $G.Queue) { [void]$sb.AppendLine(('  {0} | {1} | {2} | {3} | CRF {4} | {5} | {6}' -f $it.Name, (Get-EncoderDef $it.Encoder).Name, $it.Profile, $it.WfText, $it.CrfText, $it.DnText, $it.Status)) }
    $selNow = @($G.lvQueue.SelectedItems)
    if ($selNow.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Command for the selected file:')
        try { foreach ($ln in (Get-CommandText $selNow[0]).Split("`n")) { [void]$sb.AppendLine('  ' + $ln.TrimEnd()) } } catch { }
    }
    foreach ($lf in @(@('Engine output', $G.EngineLog, 60), @('setup.log', (Join-Path $G.Here 'logs\setup.log'), 30), @('errors.log', (Join-Path $G.Here 'logs\errors.log'), 30))) {
        if ([string]$lf[1] -ne '' -and (Test-Path -LiteralPath $lf[1])) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('Last lines of ' + $lf[0] + ':')
            foreach ($l in @(Get-Content -LiteralPath $lf[1] -Tail ([int]$lf[2]))) { [void]$sb.AppendLine('  ' + $l) }
        }
    }
    return $sb.ToString()
}

# ---- About and app updates ----
function Show-About {
    $repo = 'not published yet'
    if ($AppRepo -ne '') { $repo = 'github.com/' + $AppRepo }
    $t = "Version $AppVersion`n`nEncodes films and series to AV1 with SVT-AV1 and its forks, with GPU denoising, grain plans and quality scores.`n`n" +
    "Licence: MIT. The encoders, ffmpeg, VapourSynth and the plugins are separate programs by their own authors, downloaded from their official sources; see THIRD_PARTY_NOTICES.md. Grain tables: generator ported from libaom [BSD], tuned with AV1 - The Super Doc by BlueSwordM [github.com/BlueSwordM/AV1-The-Super-Doc].`n`nRepository: $repo"
    $btns = @('Credits', 'Close')
    if ($AppRepo -ne '') { $btns = @('Open repository', 'Credits', 'Close') }
    $newVer = ''
    if ($AppRepo -ne '') {
        $newVer = Get-AppUpdate
        if ($newVer -ne '') { $t += "`n`nVersion $newVer is out."; $btns = @('Update now') + $btns }
        else { $t += "`n`nThis is the newest version." }
    }
    $r = Show-Ask 'About RazAV1' $t $btns
    if ($r -eq 'Update now') { Update-App }
    elseif ($r -eq 'Open repository') { Start-Process ('https://github.com/' + $AppRepo) }
    elseif ($r -eq 'Credits') {
        $n = Join-Path $G.Here 'THIRD_PARTY_NOTICES.md'
        if (Test-Path -LiteralPath $n) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $n + '"') }
    }
}

function Get-AppUpdate {
    if ($AppRepo -eq '') { return '' }
    try {
        $rel = Get-WebJson ('https://api.github.com/repos/' + $AppRepo + '/releases/latest')
        $m = [regex]::Match([string]$rel.tag_name, '(\d+\.\d+\.\d+)')
        if ($m.Success -and (Test-Newer $AppVersion $m.Groups[1].Value)) { return $m.Groups[1].Value }
    }
    catch { }
    return ''
}

# ---- self-update [only when $AppRepo is set] ----
# Downloads the newest release zip, checks it, then a small cmd script waits for this window to close,
# backs up the program files, copies the new ones over them and starts the program again.
# Never touched: bin, vs, tables, logs, settings [av1_config.ini], queue.json, your own profiles.
# The built-in profiles are replaced [the old ones are in the backup]; save your changes under your own name.
function Update-App {
    if ($G.Running) { Gui-Msg 'Update after the encode has finished.'; return }
    try {
        $rel = Get-WebJson ('https://api.github.com/repos/' + $AppRepo + '/releases/latest')
        $ver = ([regex]::Match([string]$rel.tag_name, '(\d+\.\d+\.\d+)')).Groups[1].Value
        $asset = $null
        foreach ($a in @($rel.assets)) { if ([string]$a.name -match '(?i)\.zip$') { $asset = $a; break } }
        if ($null -eq $asset) { throw 'The release has no .zip file attached.' }
        $notes = ([string]$rel.body).Trim()
        if ($notes.Length -gt 1500) { $notes = $notes.Substring(0, 1500) + ' ...' }
        if ($notes -eq '') { $notes = '[no release notes]' }
        $ans = Show-Ask ('Update to ' + $ver) ("What is new:`n`n" + $notes + "`n`nThe program closes, updates itself and opens again. Your encoders, VapourSynth, grain tables, settings, queue and your own profiles stay. A backup of the old version goes into the _update_backup folder.") @('Update', 'Cancel')
        if ($ans -ne 'Update') { return }
        $tmp = Join-Path $env:TEMP ('av1me_update_' + (Get-Random))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp ([string]$asset.name)
        $G.txtNow.Text = 'Downloading ' + $ver + ' ...'
        Gui-Pump
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $r = Invoke-Native $curl @('-sL', '--fail', '--max-time', '300', '-A', 'RazAV1', '-o', $zip, [string]$asset.browser_download_url)
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw 'The download failed.' }
        $x = Join-Path $tmp 'x'
        Expand-Zip $zip $x
        $root = $null
        foreach ($c in @($x) + @(Get-ChildItem -LiteralPath $x -Directory | ForEach-Object { $_.FullName })) {
            if ((Test-Path -LiteralPath (Join-Path $c 'av1_helper.ps1')) -and (Test-Path -LiteralPath (Join-Path $c 'master_encode.bat')) -and (Test-Path -LiteralPath (Join-Path $c 'RazAV1.cmd'))) { $root = $c; break }
        }
        if ($null -eq $root) { throw 'The zip does not contain the program files.' }
        $bk = Join-Path $G.Here ('_update_backup\' + $AppVersion + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $cmdPath = Join-Path $tmp 'update.cmd'
        $lines = @(
            '@echo off',
            'title Updating RazAV1 to ' + $ver,
            'echo Updating RazAV1 to ' + $ver + ' - waiting for the window to close...',
            ':wait',
            ('tasklist /fi "PID eq {0}" 2>nul | find "{0}" >nul && (timeout /t 1 /nobreak >nul & goto :wait)' -f $PID),
            'echo Backing up the current version...',
            ('robocopy "{0}" "{1}" /E /XD bin vs logs tables _work _update_backup /XF av1_config.ini queue.json /NFL /NDL /NJH /NJS >nul' -f $G.Here, $bk),
            'echo Copying the new version...',
            ('robocopy "{0}" "{1}" /E /XD bin vs logs _work /XF av1_config.ini queue.json *.tbl /NFL /NDL /NJH /NJS' -f $root, $G.Here),
            'if errorlevel 8 goto :failed',
            'echo Done.',
            ('start "" "{0}"' -f (Join-Path $G.Here 'RazAV1.cmd')),
            'exit /b 0',
            ':failed',
            'echo The copy failed. Putting the old version back...',
            ('robocopy "{0}" "{1}" /E /NFL /NDL /NJH /NJS' -f $bk, $G.Here),
            'pause'
        )
        [System.IO.File]::WriteAllLines($cmdPath, [string[]]$lines)
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/c "' + $cmdPath + '"') -WindowStyle Minimized
        $G.Win.Close()
    }
    catch { Gui-Msg ('The update did not work: ' + $_.Exception.Message + "`n`nYou can download it yourself from github.com/" + $AppRepo + '/releases.') }
}

# ---- window icon, drawn at start [no icon file needed] ----
function New-AppIcon {
    try {
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString((Theme-Hex '#1F5FBF')))
        $dc.DrawRoundedRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, 64, 64)), 14, 14)
        $tf = New-Object System.Windows.Media.Typeface('Segoe UI Black')
        $ft = New-Object System.Windows.Media.FormattedText('AV1', [System.Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, $tf, 26, [System.Windows.Media.Brushes]::White)
        $dc.DrawText($ft, (New-Object System.Windows.Point(((64 - $ft.Width) / 2), ((64 - $ft.Height) / 2))))
        $dc.Close()
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($dv)
        $bmp.Freeze()
        return $bmp
    }
    catch { return $null }
}

# Saves the first selected file's settings as a new .profile, based on its current profile
# File handling [crop, audio]: a profile can set it; when it leaves it blank, Settings > Defaults decides.
function Get-AppDefault($p, [string]$key, [string]$cfgKey, [string]$fallback) {
    $v = ([string]$p[$key]).Trim()
    if ($v -ne '') { return $v }
    $c = ''
    if ($null -ne $G -and $null -ne $G.Cfg) { $c = ([string]$G.Cfg[$cfgKey]).Trim() }
    if ($c -ne '') { return $c }
    return $fallback
}

# CRF choices for the file's kind of source, plus Custom
function Fill-CrfPick($it) {
    $G.cbCrfPick.Items.Clear()
    $wf = [int]$it.Workflow
    $vals = @((Get-SimpleCrf $wf 2), (Get-SimpleCrf $wf 1), (Get-SimpleCrf $wf 0))
    $kind = 'films'
    if ($wf -eq 2 -or $wf -eq 5) { $kind = 'series and anime' }
    # [T 'films'] [T 'series and anime']
    $G.CrfVals = @($vals[0], $vals[1], $vals[2], -1)
    [void]$G.cbCrfPick.Items.Add(((T '{0} - more detail') -f $vals[0]))
    [void]$G.cbCrfPick.Items.Add(((T '{0} - recommended for {1}') -f $vals[1], (T $kind)))
    [void]$G.cbCrfPick.Items.Add(((T '{0} - smaller files') -f $vals[2]))
    [void]$G.cbCrfPick.Items.Add((T 'Custom  [type a number]'))
    $i = [array]::IndexOf([int[]]$vals, [int]$it.Crf)
    if ($i -lt 0) { $i = 3 }
    $G.cbCrfPick.SelectedIndex = $i
}

# Source and Command are filled only when their tab is open [ffprobe and the log cost a moment]
function Fill-LazyTab($it) {
    if ($null -eq $it) { return }
    if ($G.tabDetails.SelectedItem -eq $G.tabSource) { $G.tbSrcInfo.Text = Get-SourceDetails $it }
    if ($G.tabDetails.SelectedItem -eq $G.tabCommand) { $G.tbCmd.Text = Get-CommandText $it }
}

# ---- Output tab ----
function Test-OutName([string]$n) {
    if ($n.Trim() -eq '') { return $false }
    return ($n -notmatch '[\\/:*?"<>|%!^&]')
}

# The engine's own name tags, so the preview matches the real file name
function Get-OutTags($it) {
    $res = @('', '1080p', 'TVShow', '4Kto1080p', 'HDRtoSDR_4Kto1080p', 'Anime', '4K_SDR', '4K_HDR10')[[int]$it.Workflow]
    if ([string]$it.Info.Kind -eq 'HLG' -and $it.Workflow -eq 7) { $res = '4K_HLG' }
    $w = [int]$it.Info.W
    if ($it.Resize -eq '1280' -and $w -gt 1280 -and $it.Workflow -ne 4) { $res += '_720p' }
    if ($it.Resize -eq '1920' -and $w -gt 1920 -and $it.Workflow -ne 4 -and $it.Workflow -ne 3) { $res += '_1080p' }
    $grain = 'Digital'
    if ($it.Grain -ge 2) {
        $grain = 'ISO' + @(0, 0, 200, 400, 800)[[int]$it.Grain]
        if ($it.GrainIso -ne '') { $grain = 'ISO' + $it.GrainIso }
    }
    elseif ([string]$it.FilmGrain -ne '' -and [string]$it.FilmGrain -ne '0') { $grain = 'FG' + $it.FilmGrain }
    if ($it.Mode -eq 2 -and $it.Grain -ge 2 -and $it.Workflow -ne 5 -and $it.Denoiser -ne 'none') { $grain += '-Adaptive' }
    return @($res, $grain)
}

function Get-OutPreview($it) {
    $t = Get-OutTags $it
    $n = [string]$it.OutName
    $n = $n.Replace('{name}', [System.IO.Path]::GetFileNameWithoutExtension($it.Path)).Replace('{res}', $t[0]).Replace('{grain}', $t[1])
    $n = $n.Replace('{encoder}', (Get-EncoderDef $it.Encoder).Name).Replace('{crf}', [string]$it.Crf)
    $dir = [string]$it.OutDir
    if ($dir -eq '') { $dir = [System.IO.Path]::GetDirectoryName($it.Path) }
    return (Join-Path $dir ($n + '.mkv'))
}

# ---- Source tab: one ffprobe call per file, kept on the item ----
function Get-SourceDetails($it) {
    if ([string]$it.SrcInfo -ne '') { return $it.SrcInfo }
    $ffprobe = Get-Tool 'ffprobe'
    $j = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-show_format', '-show_streams', '-of', 'json', $it.Path))
    $sb = New-Object System.Text.StringBuilder
    if ($null -eq $j) { return 'ffprobe could not read this file.' }
    $fm = $j.format
    $dur = To-Num $fm.duration
    [void]$sb.AppendLine(('File:      {0}' -f $it.Path))
    [void]$sb.AppendLine(('Container: {0}' -f [string]$fm.format_long_name))
    [void]$sb.AppendLine(('Length:    {0}   size {1}   overall {2:0} kb/s' -f (Format-Dur $dur), (Format-Size ((To-Num $fm.size) / 1GB)), ((To-Num $fm.bit_rate) / 1000)))
    [void]$sb.AppendLine('')
    foreach ($st in @($j.streams)) {
        $lang = ''
        $title = ''
        $bps = To-Num $st.bit_rate
        if ($null -ne $st.tags) {
            if ($st.tags.language) { $lang = [string]$st.tags.language }
            if ($st.tags.title) { $title = Clean-Text ([string]$st.tags.title) }
            if ($bps -le 0 -and $st.tags.BPS) { $bps = To-Num $st.tags.BPS }
            if ($bps -le 0 -and $st.tags.'BPS-eng') { $bps = To-Num $st.tags.'BPS-eng' }
        }
        $line = ('#{0,-2} {1,-10} {2,-12}' -f [int]$st.index, [string]$st.codec_type, [string]$st.codec_name)
        if ($st.codec_type -eq 'video') {
            $line += (' {0}x{1}  {2}  {3}  {4}/{5}/{6}' -f $st.width, $st.height, [string]$st.pix_fmt, [string]$st.r_frame_rate, [string]$st.color_primaries, [string]$st.color_transfer, [string]$st.color_space)
            if ($null -ne $st.side_data_list) {
                foreach ($sd in @($st.side_data_list)) {
                    if ([string]$sd.side_data_type -match 'DOVI') { $line += ('  Dolby Vision profile ' + [string]$sd.dv_profile) }
                }
            }
        }
        elseif ($st.codec_type -eq 'audio') { $line += (' {0} ch {1}  {2} Hz' -f $st.channels, [string]$st.channel_layout, [string]$st.sample_rate) }
        if ($lang -ne '') { $line += ('  [' + $lang + ']') }
        if ($bps -gt 0) { $line += ('  {0:0} kb/s' -f ($bps / 1000)) }
        if ($title -ne '') { $line += ('  "' + $title + '"') }
        if ($null -ne $st.disposition) {
            if ([int]$st.disposition.default -eq 1) { $line += '  default' }
            if ([int]$st.disposition.forced -eq 1) { $line += '  forced' }
        }
        [void]$sb.AppendLine($line)
    }
    # HDR10 mastering data sits on the first frame
    try {
        $fj = Get-Json (Invoke-Native $ffprobe @('-v', 'error', '-select_streams', 'v:0', '-read_intervals', '%+#1', '-show_frames', '-show_entries', 'frame=side_data_list', '-of', 'json', $it.Path))
        if ($null -ne $fj -and $null -ne $fj.frames) {
            foreach ($fr in @($fj.frames)) {
                foreach ($sd in @($fr.side_data_list)) {
                    if ([string]$sd.side_data_type -match 'Mastering') { [void]$sb.AppendLine(''); [void]$sb.AppendLine(('HDR10 mastering: max {0} min {1} nits' -f [string]$sd.max_luminance, [string]$sd.min_luminance)) }
                    if ([string]$sd.side_data_type -match 'Content light') { [void]$sb.AppendLine(('HDR10 light level: MaxCLL {0}  MaxFALL {1}' -f [string]$sd.max_content, [string]$sd.max_average)) }
                    if ([string]$sd.side_data_type -match 'HDR10\+|HDR Dynamic') { [void]$sb.AppendLine('HDR10+ dynamic metadata present') }
                }
            }
        }
    }
    catch { }
    $it.SrcInfo = $sb.ToString()
    return $it.SrcInfo
}

# ---- Command tab: what the engine will run, built from the file's settings ----
function Get-CommandText($it) {
    $p = Get-ProfileByName $it.Profile
    $d = Get-EncoderDef $it.Encoder
    $o = @()
    if ([string]$it.Preset -ne '') { $o += ('--preset ' + $it.Preset) }
    if ($it.Crf -gt 0) { $o += ('--crf ' + $it.Crf) }
    $stock = ([string]$p['stock'] -eq '1')
    if ($it.Tune -ne '') { $o += ('--tune ' + $it.Tune) } elseif (-not $stock) { $o += '--tune 0' }
    if ($it.Keyint -ne '') { $o += ('--keyint ' + $it.Keyint) } elseif (-not $stock) { $o += '--keyint [workflow default]' }
    if (-not $stock) { $o += '--enable-overlays 1' }
    if ($it.VBoost -eq '0') { $o += '--enable-variance-boost 0' }
    elseif ($it.VBoost -ne '') { $o += ('--enable-variance-boost 1 --variance-boost-strength ' + $it.VBoost) }
    elseif (-not $stock) { $o += '--enable-variance-boost 1 --variance-boost-strength [profile]' }
    if (-not $stock) { $o += '--scd 1 --tile-columns 1 --tile-rows 0 --lp 0' }
    $o += '[colour and HDR flags read from the source]'
    $dt = Get-DarkTuneValues $it $p
    if ($dt[0] -ne '0') { $o += ('--luminance-qp-bias ' + $dt[0]) }
    if ($dt[1] -eq '1') { $o += ('--enable-qm 1 --qm-min ' + $dt[2]) }
    if ([string]$p['sharpness'] -ne '' -and [string]$p['sharpness'] -ne '0') { $o += ('--sharpness ' + $p['sharpness']) }
    if ($it.SvtParams -ne '') { $o += $it.SvtParams }
    if ($it.Grain -ge 2) {
        if ($it.Mode -eq 2) { $o += '--film-grain 1 --film-grain-denoise 0 --fgs-table "[timed table from the grain plan]"' }
        else { $o += ('--film-grain 1 --film-grain-denoise 0 --fgs-table "[photon noise table, ' + (Get-OutTags $it)[1] + ' for the output size]"') }
    }
    elseif ([string]$it.FilmGrain -ne '' -and [string]$it.FilmGrain -ne '0') { $o += ('--film-grain ' + $it.FilmGrain) }
    if ($it.SceneKf -eq '1') { $o += '--force-key-frames [scene cut frames]' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('VIDEO  ' + $d.Name)
    [void]$sb.AppendLine('  ' + (Get-EncoderExe $it.Encoder) + ' -i stdin [y4m, 10-bit] -b out.ivf')
    [void]$sb.AppendLine('  ' + ($o -join ' '))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('PICTURE')
    $crop = 'crop: none'
    if ($it.Crop -ne 'off') { $crop = 'crop: found by scanning the whole film' }
    $dn = 'denoise: none'
    if ($it.Denoiser -eq 'knlm') {
        if ($it.KnlmAuto -eq '1') { $dn = 'denoise: VapourSynth KNLMeansCL on the GPU, strengths measured on the film x' + ([double]$it.KnlmScale).ToString('0.0#', $inv) }
        else { $dn = 'denoise: VapourSynth KNLMeansCL on the GPU, h ' + (Scale-HList (Get-KnlmFixed $p) ([double]$it.KnlmScale)) }
    }
    elseif ($it.Denoiser -ne 'none') { $dn = 'denoise: ffmpeg hqdn3d [CPU], strength by grain level' }
    if ($it.Mode -eq 2 -and $it.Grain -ge 2) { $dn += ', per scene from the grain plan' }
    [void]$sb.AppendLine('  ' + $crop)
    [void]$sb.AppendLine('  ' + $dn)
    if ($it.Resize -ne '') { [void]$sb.AppendLine('  scale down to ' + $it.Resize + ' wide [lanczos]') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('AUDIO  track ' + $it.AudioIdx)
    if ($it.AudFormat -eq 'copy') { [void]$sb.AppendLine('  ffmpeg -map 0:a:' + $it.AudioIdx + ' -c:a copy') }
    else {
        $lay = @{ auto = '5.1 [or the source layout when smaller]'; keep = 'the source layout'; stereo = 'stereo' }[[string]$it.AudChannels]
        $br = 'automatic by channels'
        if ($it.AudKbps -ne '') { $br = $it.AudKbps + 'k' }
        $af = 'aformat=channel_layouts=' + $lay
        if ($it.AudNorm -eq '1') { $af += ',loudnorm=I=-16:LRA=11:TP=-1.5' }
        [void]$sb.AppendLine('  ffmpeg -map 0:a:' + $it.AudioIdx + ' -c:a libopus -b:a ' + $br + ' -vbr on -frame_duration:a 10 -af "' + $af + ',aresample=48000"')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('FILE')
    [void]$sb.AppendLine('  ffmpeg mux: video + audio + chapters' + @('', ' + subtitles and fonts')[[int](@($it.SubKeep).Count -gt 0)])
    [void]$sb.AppendLine('  ' + (Get-OutPreview $it))
    $last = ''
    if ([string]$it.OutPath -ne '') { $last = [System.IO.Path]::ChangeExtension($it.OutPath, '.log') }
    if ($last -ne '' -and (Test-Path -LiteralPath $last)) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('LAST ENCODE  [from ' + $last + ']')
        foreach ($ln in [System.IO.File]::ReadAllLines($last)) {
            if ($ln -match '^(SVT-AV1|Encoder|Denoise|Audio|Video|Grain|Crop):') { [void]$sb.AppendLine('  ' + $ln) }
        }
    }
    else {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Values in [brackets] are decided during the encode. After it, the exact settings from the log are shown here.')
    }
    return $sb.ToString()
}

# One line that says what a profile [as set on this file] does
function Get-ProfileSummary($it) {
    $parts = @()
    $parts += (Get-EncoderDef $it.Encoder).Name
    $q = @()
    if ($it.Crf -gt 0) { $q += ('CRF ' + $it.Crf) } else { $q += 'CRF default' }
    if ([string]$it.Preset -ne '') { $q += ('preset ' + $it.Preset) } else { $q += 'preset default' }
    $parts += ($q -join ', ')
    if ($it.Denoiser -eq 'knlm') {
        $d = 'GPU denoise'
        if ($it.KnlmAuto -eq '1') { $d += ' calibrated' } else { $d += ' fixed' }
        if ([double]$it.KnlmScale -ne 1.0) { $d += ' x' + ([double]$it.KnlmScale).ToString('0.0#', $inv) }
        $parts += $d
    }
    elseif ($it.Denoiser -eq 'none') { $parts += 'no denoise' }
    else { $parts += 'CPU denoise' }
    $parts += ('grain ' + $it.GrainText.ToLower())
    if ($it.DarkTune -eq '1') { $parts += 'dark-scene tuning' }
    if ($it.Crop -eq 'off') { $parts += 'no crop' } else { $parts += 'auto crop' }
    if ($it.AudFormat -eq 'copy') { $parts += 'audio kept as it is' }
    else {
        $a = 'Opus ' + @{ auto = 'up to 5.1'; keep = 'same channels'; stereo = 'stereo' }[[string]$it.AudChannels]
        if ($it.AudKbps -ne '') { $a += ' ' + $it.AudKbps + 'k' }
        if ($it.AudNorm -eq '1') { $a += ', even loudness' }
        $parts += $a
    }
    return ($parts -join '  |  ')
}

# ---- v1 switches: GPU denoise calibration and strength, dark-scene tuning ----
$KnlmDefaultFixed = '0.70,1.00,1.30,1.70,2.20'
$KnlmScales = @(0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.75, 2.0)

# Fixed KNLMeansCL strengths [levels 1-5] when calibration is off: the profile's list, or the standard one
function Get-KnlmFixed($p) {
    $h = ([string]$p['knlm_h']).Trim()
    if ($h -eq '' -or $h -eq 'auto') { return $KnlmDefaultFixed }
    return $h
}

function Scale-HList([string]$h, [double]$k) {
    return ((@($h.Split(',') | ForEach-Object { ([math]::Round((To-Num $_) * $k, 2)).ToString('0.00', $inv) })) -join ',')
}

# @(luma_bias, enable_qm, qm_min) for an item: the profile's values when it has them, otherwise the RAZ ones
function Get-DarkTuneValues($it, $p) {
    if ($it.DarkTune -ne '1') { return @('0', '0', [string]$p['qm_min']) }
    $lb = [string]$p['luma_bias']
    if ((To-Num $lb) -eq 0) { $lb = '10' }
    $qmMin = '2'
    if ([string]$p['enable_qm'] -eq '1') { $qmMin = [string]$p['qm_min'] }
    return @($lb, '1', $qmMin)
}

function Save-ItemAsProfile {
    $sel = @($G.lvQueue.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $it = $sel[0]
    $r = Show-Ask 'Save as profile' 'Name for the new profile. It is saved in the profiles folder and appears in the profile list.' @('Save', 'Cancel') ($it.Profile + ' custom')
    if ($r -ne 'Save') { return }
    $name = (([string]$G.AskText) -replace '[\\/:*?"<>|!%&()^=\[\]]', '').Trim()
    if ($name -eq '') { Gui-Msg 'That name has no usable characters.'; return }
    $path = Join-Path (Join-Path $G.Here 'profiles') ($name + '.profile')
    if (Test-Path -LiteralPath $path) {
        if ((Show-Ask 'Save as profile' ('A profile called "' + $name + '" already exists. Replace it?') @('Replace', 'Cancel')) -ne 'Replace') { return }
    }
    $p = Get-ProfileByName $it.Profile
    $v = [ordered]@{}
    foreach ($k in $ProfileDefaults.Keys) { if ($k -ne 'name') { $v[$k] = [string]$p[$k] } }
    $v['description'] = ('Saved from the window on ' + (Get-Date -Format 'yyyy-MM-dd') + ', based on ' + $it.Profile + '.')
    $v['encoder'] = $it.Encoder; $v['denoiser'] = $it.Denoiser; $v['mode'] = [string]$it.Mode; $v['grain'] = [string]$it.Grain
    $v['crop'] = $it.Crop; $v['preset'] = $it.Preset; $v['keyint'] = $it.Keyint; $v['svt_params'] = $it.SvtParams
    $v['resize'] = $it.Resize; $v['tune'] = $it.Tune; $v['vboost'] = $it.VBoost; $v['film_grain'] = $it.FilmGrain
    $v['grain_iso'] = $it.GrainIso; $v['scene_kf'] = $it.SceneKf
    if ($it.KnlmAuto -eq '1') { $v['knlm_h'] = 'auto' } elseif ([string]$p['knlm_h'] -eq 'auto') { $v['knlm_h'] = $KnlmDefaultFixed }
    $v['knlm_scale'] = ([double]$it.KnlmScale).ToString('0.0##', $inv)
    $dt = Get-DarkTuneValues $it $p
    $v['luma_bias'] = $dt[0]; $v['enable_qm'] = $dt[1]; $v['qm_min'] = $dt[2]
    $v['audio_format'] = $it.AudFormat; $v['audio_channels'] = $it.AudChannels; $v['audio_kbps'] = $it.AudKbps; $v['audio_norm'] = $it.AudNorm
    $v['out_dir'] = $it.OutDir; $v['out_name'] = $it.OutName; $v['out_exists'] = $it.OutExists
    $crf = ''
    if ($it.Crf -gt 0) { $crf = [string]$it.Crf }
    if ($it.Workflow -eq 2 -or $it.Workflow -eq 5) { $v['crf_tv'] = $crf } else { $v['crf'] = $crf }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Saved by RazAV1. Edit any value in Notepad; lines starting with # are ignored.')
    foreach ($k in $v.Keys) { $lines.Add($k + '=' + $v[$k]) }
    [System.IO.File]::WriteAllLines($path, $lines.ToArray())
    $G.Profiles = Get-Profiles $G.Here
    $G.Loading = $true
    try {
        $G.cbProfile.Items.Clear()
        foreach ($pp in $G.Profiles) { [void]$G.cbProfile.Items.Add($pp['name']) }
    }
    finally { $G.Loading = $false }
    foreach ($x in $sel) { $x.Profile = $name }
    Show-Details
    Gui-Msg ('Saved as "' + $name + '". Pick it from the profile list for any file, or make it the default in Settings.')
}

# First start of a new install: plain AV1 or the tuned pipeline as the default profile
function Ask-FirstChoice {
    $raw = Get-Config $G.Here
    if ([string]$raw['FIRST_CHOICE'] -ne '' -or [string]$raw['SETUP_SHOWN'] -eq '1') { return }
    $txt = "How should new files be set up? You can change this any time [Settings > Default profile], and every file can still be changed on its own.`n`n" +
    "Tuned: RAZ Triangle. Crop scan, per-scene denoising on the GPU, grain tables, extra bits for dark scenes. Best for grainy Blu-ray films.`n`n" +
    "Plain: SVT-AV1 with its own defaults. Nothing added, nothing removed."
    $r = Show-Ask 'Welcome to RazAV1' $txt @('Tuned [RAZ Triangle]', 'Plain AV1 [SVT-AV1 stock]')
    $prof = 'RAZ Triangle'
    if ($r -like 'Plain*') { $prof = 'SVT-AV1 stock' }
    Set-ConfigValue 'DEFAULT_PROFILE' $prof
    Set-ConfigValue 'FIRST_CHOICE' $prof
    if ($prof -eq 'SVT-AV1 stock') { Set-ConfigValue 'UI_SIMPLE' '1'; $G.Simple = $true; Apply-ViewMode }
    $G.Cfg['DEFAULT_PROFILE'] = $prof
}

# Encoder dropdown: every known encoder, with its installed version or 'not installed'
function Fill-Encoders {
    $G.Loading = $true
    try {
        $G.cbEncoder.Items.Clear()
        foreach ($id in $EncoderDefs.Keys) {
            $d = $EncoderDefs[$id]
            $exe = Get-EncoderExe $id
            $v = 'not installed'
            if ($exe -ne '') { $v = Get-SvtVersion $exe; if ($v -eq '') { $v = 'installed' } }
            [void]$G.cbEncoder.Items.Add(('{0}  [{1}]' -f $d.Name, $v))
        }
    }
    finally { $G.Loading = $false }
}

function Fill-Grain([int]$mode) {
    $G.cbGrain.Items.Clear()
    $src = $GrainStatic
    if ($mode -eq 2) { $src = $GrainAdaptive }
    foreach ($grainName in $src) { [void]$G.cbGrain.Items.Add((T $grainName)) }
}

# ---- Subtitles tab: kept tracks first, in the chosen order, then the dropped ones ----
function Fill-Subs($it, [int]$selectSrc, [bool]$withDefault = $true) {
    $G.SubRows = @()
    $G.lbSubs.Items.Clear()
    $kept = @($it.SubKeep)
    $n = 0
    foreach ($k in $kept) {
        $t = $null
        foreach ($x in $it.SubTracks) { if ($x.Index -eq $k) { $t = $x } }
        if ($null -eq $t) { continue }
        $n++
        $line = ('KEEP {0,2}.  {1}' -f $n, $t.Display)
        if ([int]$it.SubDefault -eq [int]$k) { $line += '   <- on by default' }
        [void]$G.lbSubs.Items.Add($line)
        $G.SubRows += [int]$k
    }
    foreach ($t in $it.SubTracks) {
        if ($kept -contains $t.Index) { continue }
        [void]$G.lbSubs.Items.Add(('drop      ' + $t.Display))
        $G.SubRows += [int]$t.Index
    }
    if ($selectSrc -ge 0) { $G.lbSubs.SelectedIndex = [array]::IndexOf([int[]]$G.SubRows, $selectSrc) }
    if (-not $withDefault) { return }
    $G.cbSubDefault.Items.Clear()
    [void]$G.cbSubDefault.Items.Add((T 'As on the disc'))
    [void]$G.cbSubDefault.Items.Add((T 'None  [off until you turn one on]'))
    $G.SubDefRows = @(-2, -1)
    foreach ($k in $kept) {
        foreach ($x in $it.SubTracks) {
            if ($x.Index -eq $k) { [void]$G.cbSubDefault.Items.Add($x.Display); $G.SubDefRows += [int]$k }
        }
    }
    $di = [array]::IndexOf([int[]]$G.SubDefRows, [int]$it.SubDefault)
    if ($di -lt 0) { $di = 0 }
    $G.cbSubDefault.SelectedIndex = $di
}

function Edit-Subs([scriptblock]$change) {
    $sel = @($G.lvQueue.SelectedItems)
    if ($sel.Count -ne 1 -or $G.lbSubs.SelectedIndex -lt 0) { return }
    $it = $sel[0]
    $src = [int]$G.SubRows[$G.lbSubs.SelectedIndex]
    $list = New-Object System.Collections.ArrayList
    foreach ($k in @($it.SubKeep)) { [void]$list.Add([int]$k) }
    & $change $list $src
    $it.SubKeep = @($list.ToArray() | ForEach-Object { [int]$_ })
    if ([int]$it.SubDefault -ge 0 -and -not (@($it.SubKeep) -contains [int]$it.SubDefault)) { $it.SubDefault = -1 }
    $G.Loading = $true
    try { Fill-Subs $it $src } finally { $G.Loading = $false }
    Update-TabMarks $it
}

function Show-Details {
    $sel = @($G.lvQueue.SelectedItems)
    $G.Loading = $true
    try {
        if ($sel.Count -eq 0) {
            $G.spDetails.IsEnabled = $false
            $G.txtSource.Text = 'No file selected'
            $G.txtWarn.Text = ''
            $G.txtNote.Text = ''
            $G.txtPlan.Text = ''
            $G.btnPlan.IsEnabled = $false
            Update-TabMarks $null
            return
        }
        $G.spDetails.IsEnabled = (-not $G.Running)
        $it = $sel[0]
        $det = 'Detected as: ' + ($WfShort[[int]$it.Info.Suggest]) + '.'
        if ($sel.Count -gt 1) { $G.txtSource.Text = ('{0} files selected - changes apply to all of them.  First: {1}' -f $sel.Count, $it.Info.Text) }
        else { $G.txtSource.Text = $it.Info.Text + '  ' + $det }
        $G.txtWarn.Text = Get-ItemWarnings $it
        $qi = -1
        for ($q = 0; $q -lt 3; $q++) { if ($it.Crf -eq (Get-SimpleCrf $it.Workflow $q)) { $qi = $q } }
        $G.cbSimpleQ.SelectedIndex = $qi
        $G.txtNote.Text = Get-WfNote $it
        $G.cbProfile.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]@($G.Profiles | ForEach-Object { $_['name'] }), [string]$it.Profile))
        $p = Get-ProfileByName $it.Profile
        $G.txtProfile.Text = [string]$p['description']
        $ids = @($EncoderDefs.Keys)
        $G.cbEncoder.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]$ids, [string]$it.Encoder))
        $ed = Get-EncoderDef $it.Encoder
        $et = $ed.About
        if ((Get-EncoderExe $ed.Id) -eq '') { $et = 'Not installed yet: Setup and updates > Build latest.  ' + $et }
        if ([string]$p['stock'] -eq '1') { $et += '  This profile passes only what you set here; the encoder decides the rest.' }
        $G.txtEncoder.Text = $et
        $G.cbCrop.SelectedIndex = [int]($it.Crop -eq 'off')
        $G.cbResize.SelectedIndex = [array]::IndexOf([string[]]@('', '1920', '1280'), [string]$it.Resize)
        $G.cbResize.IsEnabled = ($it.Workflow -ne 4)
        $G.cbWorkflow.SelectedIndex = $it.Workflow - 1
        $G.cbMode.SelectedIndex = $it.Mode - 1
        $G.cbMode.IsEnabled = ($it.Workflow -ne 5 -and $it.Denoiser -ne 'none')
        Fill-Grain $it.Mode
        if ($it.Mode -eq 2) { $G.cbGrain.SelectedIndex = $it.Grain - 2 } else { $G.cbGrain.SelectedIndex = $it.Grain - 1 }
        $G.txtPlan.Text = Get-PlanText $it
        $G.btnPlan.IsEnabled = (Test-Path -LiteralPath (Join-Path (Get-PlanDir $it) 'plan.csv'))
        $G.btnAnalyse.IsEnabled = ($it.Workflow -ne 5)
        if ($it.Denoiser -eq 'knlm') { $G.cbDenoiser.SelectedIndex = 0 } elseif ($it.Denoiser -eq 'none') { $G.cbDenoiser.SelectedIndex = 2 } else { $G.cbDenoiser.SelectedIndex = 1 }
        $G.cbDenoiser.IsEnabled = ($it.Workflow -ne 5)
        if ($it.Denoiser -eq 'none') { $G.txtDnNote.Text = 'No denoising. Static mode only; the grain choice then just picks a grain table [or none].' }
        elseif (-not $G.HasVs) { $G.txtDnNote.Text = 'VapourSynth is not ready, so KNLMeansCL is not available. ' + $G.VsNote }
        elseif ($it.Workflow -eq 4) { $G.txtDnNote.Text = 'The HDR to SDR tonemap workflow uses hqdn3d [the tonemap runs in ffmpeg].' }
        elseif ($it.Workflow -eq 5) { $G.txtDnNote.Text = 'Anime gets no denoising.' }
        elseif ($it.Denoiser -eq 'knlm') {
            if ($it.KnlmAuto -eq '1') { $G.txtDnNote.Text = 'Runs on your GPU. Calibrated on each film to remove as much grain as hqdn3d, while keeping edges and texture.' }
            else { $G.txtDnNote.Text = 'Runs on your GPU with fixed strengths [' + (Scale-HList (Get-KnlmFixed $p) ([double]$it.KnlmScale)) + '].' }
        }
        else { $G.txtDnNote.Text = 'Classic CPU denoiser, same as v4.3.' }
        if ($it.Crf -eq 0) { $G.tbCrf.Text = '' } else { $G.tbCrf.Text = [string]$it.Crf }
        $G.tbPreset.Text = [string]$it.Preset
        $G.tbKeyint.Text = [string]$it.Keyint
        $G.tbTune.Text = [string]$it.Tune
        $G.tbVboost.Text = [string]$it.VBoost
        $G.tbFilmGrain.Text = [string]$it.FilmGrain
        $G.cbGrainIso.SelectedIndex = 0
        if ($it.GrainIso -ne '') { $G.cbGrainIso.SelectedIndex = 1 + [array]::IndexOf([int[]]$IsoLadder, (Snap-Iso ([int]$it.GrainIso))) }
        $G.cbGrainIso.IsEnabled = -not ($it.Mode -ne 2 -and $it.Grain -eq 1)
        $G.chkSceneKf.IsChecked = ($it.SceneKf -eq '1')
        $G.chkDarkTune.IsChecked = ($it.DarkTune -eq '1')
        $G.chkKnlmAuto.IsChecked = ($it.KnlmAuto -eq '1')
        $ki = 0
        $kbest = 99.0
        for ($q = 0; $q -lt $KnlmScales.Count; $q++) {
            $dd = [math]::Abs([double]$KnlmScales[$q] - [double]$it.KnlmScale)
            if ($dd -lt $kbest) { $kbest = $dd; $ki = $q }
        }
        $G.cbKnlmScale.SelectedIndex = $ki
        $G.spKnlm.IsEnabled = ($it.Denoiser -eq 'knlm' -and $G.HasVs -and $it.Workflow -ne 4 -and $it.Workflow -ne 5)
        $G.cbAudFormat.SelectedIndex = [int]($it.AudFormat -eq 'copy')
        $G.cbAudChannels.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]@('auto', 'keep', 'stereo'), [string]$it.AudChannels))
        $G.tbAudKbps.Text = [string]$it.AudKbps
        $G.chkAudNorm.IsChecked = ($it.AudNorm -eq '1')
        $G.spAudOpus.IsEnabled = ($it.AudFormat -ne 'copy')
        if ($it.AudFormat -eq 'copy') { $G.txtAudNote.Text = 'The track goes into the new file untouched. Lossless tracks [TrueHD, DTS-HD MA] are 2-6 GB on a film, so the file gets much bigger.' }
        else { $G.txtAudNote.Text = 'Encoded while the video encodes, so it adds no time.' }
        $G.txtProfileSum.Text = Get-ProfileSummary $it
        $G.cbOutWhere.SelectedIndex = [int]([string]$it.OutDir -ne '')
        $G.dpOutDir.IsEnabled = ([string]$it.OutDir -ne '')
        $G.tbOutDir.Text = [string]$it.OutDir
        $G.tbOutName.Text = [string]$it.OutName
        $G.cbOutExists.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]@('number', 'skip', 'replace'), [string]$it.OutExists))
        $G.txtOutPreview.Text = 'Will be: ' + (Get-OutPreview $it)
        Fill-CrfPick $it
        Fill-LazyTab $it
        Update-TabMarks $it
        $G.tbSvtParams.Text = [string]$it.SvtParams
        $G.txtParams.Text = Get-ParamsNote $it
        $G.cbAudio.Items.Clear()
        foreach ($t in $it.AudioTracks) { [void]$G.cbAudio.Items.Add($t.Display) }
        if ($it.AudioIdx -ge 0) { $G.cbAudio.SelectedIndex = $it.AudioIdx }
        $G.cbAudio.IsEnabled = ($sel.Count -eq 1)
        Fill-Subs $it -1
        $G.lbSubs.IsEnabled = ($sel.Count -eq 1)
        $G.btnSubToggle.IsEnabled = ($sel.Count -eq 1)
        $G.btnSubUp.IsEnabled = ($sel.Count -eq 1)
        $G.btnSubDown.IsEnabled = ($sel.Count -eq 1)
        $G.cbSubDefault.IsEnabled = ($sel.Count -eq 1)
    }
    finally {
        $G.Loading = $false
        # lines with nothing to say take no room
        foreach ($tb in @($G.txtNote, $G.txtWarn)) { if ([string]$tb.Text -eq '') { $tb.Visibility = 'Collapsed' } else { $tb.Visibility = 'Visible' } }
    }
}

# Characters that would break the batch engine [quotes, percent, exclamation, redirection]
function Test-UnsafeParams([string]$t) { return ($t -match '["%!&|<>^]') }

function Get-ParamsNote($it) {
    if ([string]$it.SvtParams -eq '') { return 'None. Anything typed here comes last, so it overrides the profile.' }
    if (Test-UnsafeParams $it.SvtParams) { return 'Not usable: remove " % ! & | < > ^ from the extra options.' }
    return 'Passed to ' + (Get-EncoderDef $it.Encoder).Name + ' after everything else; checked against its --help when you press Start.'
}

# Options in the extra field that this encoder does not know. One --help per encoder, cached.
function Get-UnknownParams([string]$exe, [string]$params) {
    if ($params.Trim() -eq '' -or $exe -eq '') { return @() }
    if ($null -eq $G.HelpCache) { $G.HelpCache = @{} }
    if (-not $G.HelpCache.ContainsKey($exe)) {
        $r = Invoke-Native $exe @('--help')
        $known = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($m in [regex]::Matches(($r.Out + "`n" + $r.Err), '--[A-Za-z0-9][A-Za-z0-9-]*')) { [void]$known.Add($m.Value.ToLowerInvariant()) }
        $G.HelpCache[$exe] = $known
    }
    $known = $G.HelpCache[$exe]
    if ($known.Count -lt 20) { return @() }   # help text not readable: do not block the encode on a guess
    $bad = @()
    foreach ($m in [regex]::Matches($params, '(?<!\S)--[A-Za-z0-9][A-Za-z0-9-]*')) {
        if (-not $known.Contains($m.Value.ToLowerInvariant())) { $bad += $m.Value }
    }
    return $bad
}

function Edit-Selected([scriptblock]$change) {
    if ($G.Loading) { return }
    foreach ($it in @($G.lvQueue.SelectedItems)) {
        & $change $it
        Normalize-Item $it
    }
    $G.lvQueue.Items.Refresh()
    Show-Details
}

function Esc-Cmd([string]$s) { return $s.Replace('%', '%%') }

function Write-JobFiles($items, [bool]$analyse) {
    $dir = Join-Path $env:TEMP ('av1_job_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    $j = New-Object System.Collections.Generic.List[string]
    $j.Add('@echo off')
    $j.Add('set "GUI_MODE=1"')
    $j.Add('set "JOB_DIR=' + (Esc-Cmd $dir) + '"')
    $j.Add('set "QN=' + @($items).Count + '"')
    $j.Add('set "CPU_MODE=' + $CpuValues[[math]::Max(0, $G.cbCpu.SelectedIndex)] + '"')
    # The window runs its own countdown for sleep / shut down, with a Cancel button
    $j.Add('set "WHEN_DONE=none"')
    $ap = '0'
    if ($G.chkApprove.IsChecked -and -not $analyse) { $ap = '1' }
    $j.Add('set "APPROVE=' + $ap + '"')
    if ($analyse) { $j.Add('set "ANALYSE_ONLY=1"') } else { $j.Add('set "ANALYSE_ONLY="') }
    for ($i = 0; $i -lt @($items).Count; $i++) {
        $it = @($items)[$i]
        $n = $i + 1
        $j.Add('set "Q_' + $n + '=' + (Esc-Cmd $it.Path) + '"')
        $p = Get-ProfileByName $it.Profile
        $mode = $it.Mode
        $grain = $it.Grain
        if ($analyse) { $mode = 2; $grain = [math]::Max(2, $grain) }
        $f = New-Object System.Collections.Generic.List[string]
        $f.Add('set "S_SRC=' + $it.Workflow + '"')
        $f.Add('set "S_MODE=' + $mode + '"')
        $f.Add('set "S_GRAIN=' + $grain + '"')
        $f.Add('set "S_CRF=' + $it.Crf + '"')
        $subSel = ''
        if (@($it.SubKeep).Count -gt 0) {
            $f.Add('set "S_SUBS=1"')
            # in the order chosen in the Subtitles tab; output subtitle n = the n-th kept track
            $kept = @($it.SubKeep)
            $subSel = ((@($kept | ForEach-Object { '-map 2:s:' + $_ })) -join ' ') + ' -map 2:t?'
            if ([int]$it.SubDefault -ge -1) {
                for ($sn = 0; $sn -lt $kept.Count; $sn++) {
                    if ([int]$kept[$sn] -eq [int]$it.SubDefault) { $subSel += (' -disposition:s:' + $sn + ' +default') }
                    else { $subSel += (' -disposition:s:' + $sn + ' -default') }
                }
            }
        }
        else { $f.Add('set "S_SUBS=0"') }
        $f.Add('set "SUB_SEL=' + $subSel + '"')
        $f.Add('set "AUD_FIXED=1"')
        $f.Add('set "AUD_IDX=' + $it.AudioIdx + '"')
        $lang = 'und'
        foreach ($t in $it.AudioTracks) { if ($t.Index -eq $it.AudioIdx) { $lang = $t.Lang } }
        $f.Add('set "AUD_LANG=' + (Esc-Cmd $lang) + '"')
        foreach ($k in $ProfileDefaults.Keys) {
            if ($k -eq 'description') { continue }
            $v = [string]$p[$k]
            if ($k -eq 'denoiser') { $v = $it.Denoiser }
            $f.Add('set "PF_' + $k + '=' + (Esc-Cmd $v) + '"')
        }
        # v1: per-file choices made in the window override the profile
        $f.Add('set "PF_crop=' + $it.Crop + '"')
        $f.Add('set "PF_preset=' + (Esc-Cmd $it.Preset) + '"')
        $f.Add('set "PF_keyint=' + (Esc-Cmd $it.Keyint) + '"')
        $f.Add('set "PF_svt_params=' + (Esc-Cmd $it.SvtParams) + '"')
        $f.Add('set "PF_resize=' + $it.Resize + '"')
        $f.Add('set "PF_tune=' + $it.Tune + '"')
        $f.Add('set "PF_vboost=' + $it.VBoost + '"')
        $f.Add('set "PF_film_grain=' + $it.FilmGrain + '"')
        $f.Add('set "PF_grain_iso=' + $it.GrainIso + '"')
        $f.Add('set "PF_scene_kf=' + $it.SceneKf + '"')
        if ($it.KnlmAuto -eq '1') {
            $f.Add('set "PF_knlm_h=auto"')
            $f.Add('set "PF_knlm_scale=' + ([double]$it.KnlmScale).ToString('0.0##', $inv) + '"')
        }
        else {
            $f.Add('set "PF_knlm_h=' + (Scale-HList (Get-KnlmFixed $p) ([double]$it.KnlmScale)) + '"')
            $f.Add('set "PF_knlm_scale=1.0"')
        }
        $dt = Get-DarkTuneValues $it $p
        $f.Add('set "PF_luma_bias=' + $dt[0] + '"')
        $f.Add('set "PF_enable_qm=' + $dt[1] + '"')
        $f.Add('set "PF_qm_min=' + $dt[2] + '"')
        $f.Add('set "PF_audio_format=' + $it.AudFormat + '"')
        $f.Add('set "PF_audio_channels=' + $it.AudChannels + '"')
        $f.Add('set "PF_audio_kbps=' + $it.AudKbps + '"')
        $f.Add('set "PF_audio_norm=' + $it.AudNorm + '"')
        $f.Add('set "PF_out_dir=' + (Esc-Cmd ([string]$it.OutDir).TrimEnd('\')) + '"')
        $f.Add('set "PF_out_name=' + (Esc-Cmd $it.OutName) + '"')
        $f.Add('set "PF_out_exists=' + $it.OutExists + '"')
        $f.Add('set "S_SVT_EXE=' + (Esc-Cmd (Get-EncoderExe $it.Encoder)) + '"')
        $f.Add('set "S_ENC_NAME=' + (Get-EncoderDef $it.Encoder).Name + '"')
        # $i + 1, not $n: the file number must always match Q_<number> in job.cmd
        [System.IO.File]::WriteAllLines((Join-Path $dir ('item_' + ($i + 1) + '.cmd')), $f.ToArray(), $enc)
    }
    [System.IO.File]::WriteAllLines((Join-Path $dir 'job.cmd'), $j.ToArray(), $enc)
    return $dir
}

# The thin progress line on the Files page, and the page names
function Update-Strip {
    if ($G.Running) {
        $G.bdStrip.Visibility = 'Visible'
        $line = [string]$G.txtNow.Text
        if ([string]$G.stEta.Text -ne '' -and [string]$G.stEta.Text -ne '-') { $line += '   |   ' + $G.stEta.Text + ' left' }
        $G.txtStrip.Text = $line
        $G.txtStripPct.Text = [string]$G.txtPct.Text
        $G.pbStrip.Value = $G.pb.Value
        $G.hdrEncoding.Text = (T 'ENCODING') + '  ' + [string]$G.txtPct.Text
    }
    else {
        $G.bdStrip.Visibility = 'Collapsed'
        $G.hdrEncoding.Text = (T 'ENCODING')
    }
    $G.hdrFiles.Text = ((T 'FILES') + '  ({0})' -f $G.Queue.Count)
}

function Set-Running([bool]$on) {
    $G.Running = $on
    if ($on) { Show-Page 'encoding' }
    $G.btnStart.IsEnabled = -not $on
    $G.btnStop.IsEnabled = $on -and -not $G.Analyse
    $G.btnAbort.IsEnabled = $on
    $G.spQueueTools.IsEnabled = -not $on
    $G.spPlanTools.IsEnabled = -not $on
    $G.wpGlobal.IsEnabled = -not $on
    $G.btnSettings.IsEnabled = -not $on
    $G.btnSetup.IsEnabled = -not $on
    $G.spDetails.IsEnabled = (-not $on) -and (@($G.lvQueue.SelectedItems).Count -gt 0)
    if (-not $on) {
        $G.btnApprove.IsEnabled = $false
        $G.btnHold.IsEnabled = $false
        $G.btnSkip.IsEnabled = $false
        $G.pb.IsIndeterminate = $false
    }
}

function Get-PlanDir($it) {
    $dir = [System.IO.Path]::GetDirectoryName($it.Path)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($it.Path)
    $d = Join-Path $dir ($base + '_plan')
    if (-not (Test-Path -LiteralPath (Join-Path $d 'plan.csv'))) {
        $old = Join-Path $dir ($base + '_v4.2_plan')
        if (Test-Path -LiteralPath (Join-Path $old 'plan.csv')) { return $old }
    }
    return $d
}

function Get-PlanText($it) {
    $pd = Get-PlanDir $it
    $pc = Join-Path $pd 'plan.csv'
    $t = ''
    if (Test-Path -LiteralPath $pc) {
        $n = [math]::Max(0, @([System.IO.File]::ReadAllLines($pc) | Where-Object { $_.Trim() -ne '' }).Count - 1)
        $t = ('Grain plan: {0} scenes' -f $n)
        if (Test-Path -LiteralPath (Join-Path $pd 'plan_original.csv')) { $t += ', edited by hand' }
        if ($it.Mode -ne 2) { $t += '  [used in adaptive mode only]' }
        $t += '.'
    }
    elseif ($it.Mode -eq 2) { $t = 'No grain plan yet. It is made when the encode starts, or press Analyse plan to make it now and edit it first.' }
    $cal = Join-Path $pd 'knlm_calibration.txt'
    if (Test-Path -LiteralPath $cal) {
        $kv = Read-KeyValueFile $cal
        if ($kv['h']) { $t += ('  KNLMeansCL calibrated for this film: h ' + ([string]$kv['h']).Replace(',', ' / ') + '.') }
    }
    return $t.Trim()
}

function Start-Engine($items, [bool]$analyse) {
    $items = @($items)
    if ($items.Count -eq 0) { Gui-Msg 'Add at least one film first.'; return }
    $problems = @()
    foreach ($it in $items) {
        $d = Get-EncoderDef $it.Encoder
        $exe = Get-EncoderExe $d.Id
        if ($exe -eq '') { $problems += ($it.Name + ': ' + $d.Name + ' is not installed [Setup and updates > Build latest].'); continue }
        if (Test-UnsafeParams $it.SvtParams) { $problems += ($it.Name + ': the extra options contain " % ! & | < > or ^.'); continue }
        $bad = @(Get-UnknownParams $exe $it.SvtParams)
        if ($bad.Count -gt 0) { $problems += ($it.Name + ': ' + $d.Name + ' does not know ' + ($bad -join ', ') + '.') }
    }
    if ($problems.Count -gt 0) { Gui-Msg ("Nothing was started:`n`n" + ($problems -join "`n")); return }
    if (-not $analyse) {
        $space = Test-QueueSpace $items
        if ($space -ne '') {
            if ((Show-Ask 'Low disk space' ($space + "`n`nThe encode stops with an error if the drive fills up.") @('Start anyway', 'Cancel')) -ne 'Start anyway') { return }
        }
    }
    $G.RunSaved = 0.0
    $G.btnOpenOut.Visibility = 'Collapsed'
    $G.btnPlayOut.Visibility = 'Collapsed'
    if ($G.Bat -eq '') { Gui-Msg 'master_encode.bat must sit next to av1_helper.ps1.'; return }
    $G.Analyse = $analyse
    $G.JobItems = $items
    $G.JobDir = Write-JobFiles $items $analyse
    foreach ($it in $items) { if ($analyse) { $it.Status = 'Queued [plan]' } else { $it.Status = 'Queued'; $it.Quality = '' } }
    $G.lvQueue.Items.Refresh()
    $G.LastStage = ''
    $G.ApproveSince = $null
    $G.Held = $false
    $G.Aborted = $false
    $G.ExitSeen = $null
    $G.DoneAt = $null
    $G.dpDone.Visibility = 'Collapsed'
    Reset-Stats
    $jobFile = Join-Path $G.JobDir 'job.cmd'
    $argLine = '/d /c ""' + $G.Bat + '" --job "' + $jobFile + '""'
    $G.Proc = $null
    $G.Engine = $null
    $what = 'Encoding'
    if ($analyse) { $what = 'Plan analysis' }
    Append-Log ("`r`n==== " + $what + ' started ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', ' + $items.Count + " file(s) ====`r`n")
    $useConsole = ([string]$G.Cfg['GUI_CONSOLE'] -eq '1')
    if (-not $useConsole) {
        try {
            Ensure-Proc
            $logDir = Join-Path $G.Here 'logs'
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            $G.EngineLog = Join-Path $logDir ('engine_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
            $G.Proc = [Av1Proc]::Start($env:ComSpec, $argLine, $G.EngineLog)
        }
        catch {
            # the output panel could not start: the engine still runs, in its own console window
            Write-LogFile 'errors.log' ('output capture: ' + $_.Exception.ToString())
            Append-Log ('Could not show the engine output here [' + $_.Exception.Message + "]. Using a console window instead.`r`n")
            $G.Proc = $null
            $useConsole = $true
        }
    }
    if ($useConsole) {
        $G.Engine = Start-Process -FilePath $env:ComSpec -ArgumentList $argLine -PassThru
        Append-Log "The engine runs in its own console window [Settings > Extras].`r`n"
    }
    Set-Running $true
    $G.txtNow.Text = 'Starting the engine...'
    $G.txtStage.Text = ''
    $G.Tick = 0
    $G.Timer.Start()
}

function Send-Answer([string]$a) {
    if ($null -eq $G.JobDir -or $G.CurIndex -lt 1) { return }
    [System.IO.File]::WriteAllText((Join-Path $G.JobDir ('answer_' + $G.CurIndex + '.txt')), $a)
    if ($a -eq 'H') { $G.Held = $true; $G.btnHold.IsEnabled = $false }
    else { $G.btnApprove.IsEnabled = $false; $G.btnHold.IsEnabled = $false; $G.btnSkip.IsEnabled = $false }
}

# ---- engine output panel ----
function Append-Log([string]$t) {
    if ($t -eq '') { return }
    $G.tbLog.AppendText($t)
    $G.LogChars += $t.Length
    if ($G.LogChars -gt 700000) {
        $all = $G.tbLog.Text
        $G.tbLog.Text = '[older output trimmed - the full log is in the logs folder]' + "`r`n" + $all.Substring($all.Length - 400000)
        $G.LogChars = $G.tbLog.Text.Length
    }
    if ($G.chkFollow.IsChecked) { $G.tbLog.ScrollToEnd() }
}

function Drain-Output {
    if ($null -eq $G.Proc) { return }
    $sb = New-Object System.Text.StringBuilder
    $item = ''
    $live = $null
    $k = 0
    while ($k -lt 5000 -and $G.Proc.Q.TryDequeue([ref]$item)) {
        $k++
        if ($item.Length -lt 1) { continue }
        $text = $item.Substring(1)
        if ($item[0] -eq 'L') { [void]$sb.Append($text).Append("`r`n") }
        else { $live = $text }
        if ($text.IndexOf('Encoding:') -ge 0) { Read-SvtProgress $text }
    }
    if ($sb.Length -gt 0) { Append-Log $sb.ToString() }
    if ($null -ne $live) { $G.txtLive.Text = $live.Trim() }
}

# ---- live encode statistics [FastFlix style] ----
$SvtRx = New-Object System.Text.RegularExpressions.Regex('Encoding:\s*(\d+)(?:\s*/\s*\d+)?\s*Frames\s*@\s*([\d.]+)\s*fps\s*\|\s*([\d.]+)\s*kb/s\s*\|\s*Size:\s*([\d.]+)\s*(KB|MB|GB|B)?(?:.*?Time:\s*(\d+):(\d+):(\d+))?')

function Reset-Stats {
    $G.Enc = $null
    $G.EncSamples = New-Object System.Collections.Generic.List[object]
    foreach ($n in @('stSize', 'stEta', 'stSpeed', 'stRate', 'stFrames')) { $G[$n].Text = '-' }
    foreach ($n in @('stSizeSub', 'stEtaSub', 'stSpeedSub', 'stRateSub', 'stFramesSub')) { $G[$n].Text = '' }
    $G.txtPct.Text = ''
}

function Read-SvtProgress([string]$t) {
    $t = $t -replace '\x1b\[[0-9;?]*[@-~]', ''
    $m = $SvtRx.Match($t)
    if (-not $m.Success) { return }
    $frames = [double]::Parse($m.Groups[1].Value, $inv)
    $mb = [double]::Parse($m.Groups[4].Value, $inv)
    switch ($m.Groups[5].Value) { 'KB' { $mb = $mb / 1024.0 } 'GB' { $mb = $mb * 1024.0 } 'B' { $mb = $mb / 1048576.0 } }
    $el = -1.0
    if ($m.Groups[6].Success) { $el = [double]$m.Groups[6].Value * 3600 + [double]$m.Groups[7].Value * 60 + [double]$m.Groups[8].Value }
    if ($null -ne $G.Enc -and $frames -lt $G.Enc.Frames) { $G.EncSamples.Clear() }   # a new encode started
    $now = Get-Date
    $G.Enc = New-Object PSObject -Property @{ Frames = $frames; Fps = [double]::Parse($m.Groups[2].Value, $inv); Kbps = [double]::Parse($m.Groups[3].Value, $inv); MB = $mb; Elapsed = $el; At = $now }
    $G.EncSamples.Add(@($now, $frames, $mb))
    while ($G.EncSamples.Count -gt 2 -and ($now - $G.EncSamples[0][0]).TotalSeconds -gt 180) { $G.EncSamples.RemoveAt(0) }
    $G.StatsDirty = $true
}

# Rate over the last $sec seconds of samples: @(frames per second, MB per second) or $null
function Get-WindowRate([double]$sec) {
    $n = $G.EncSamples.Count
    if ($n -lt 2) { return $null }
    $last = $G.EncSamples[$n - 1]
    $first = $null
    for ($i = $n - 2; $i -ge 0; $i--) {
        $first = $G.EncSamples[$i]
        if (($last[0] - $first[0]).TotalSeconds -ge $sec) { break }
    }
    $dt = ($last[0] - $first[0]).TotalSeconds
    if ($dt -lt 2 -or $last[1] -le $first[1]) { return $null }
    return @((($last[1] - $first[1]) / $dt), (($last[2] - $first[2]) / $dt), (($last[1] - $first[1])))
}

function Format-Dur([double]$sec) {
    if ($sec -lt 0 -or [double]::IsInfinity($sec) -or [double]::IsNaN($sec)) { return '-' }
    $ts = [timespan]::FromSeconds([math]::Round($sec))
    return ('{0}:{1:00}:{2:00}' -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Update-Stats {
    $e = $G.Enc
    if ($null -eq $e) { return }
    $G.StatsDirty = $false
    $dur = $G.StDur
    $fpsSrc = $G.StFps
    if ($fpsSrc -le 0) { $fpsSrc = 23.976 }
    $total = $dur * $fpsSrc
    $frac = 0.0
    if ($total -gt 0) { $frac = [math]::Min(0.9999, $e.Frames / $total) }
    $G.pb.IsIndeterminate = $false
    $G.pb.Value = 100.0 * $frac
    $G.txtPct.Text = (100.0 * $frac).ToString('0.0', $inv) + ' %'

    # size: what is written so far, scaled up to the whole film, plus the audio
    $audMB = $G.StAudio * 1000.0 / 8.0 * $dur / 1048576.0
    if ($frac -ge 0.003) {
        $finalGB = (($e.MB / $frac) * 1.003 + $audMB) / 1024.0
        $G.stSize.Text = $finalGB.ToString('0.00', $inv) + ' GB'
    }
    else { $G.stSize.Text = '...' }
    $sub = 'written ' + ($e.MB / 1024.0).ToString('0.00', $inv) + ' GB'
    if ($G.StEstimate -ne '' -and $G.StEstimate -ne 'N/A') { $sub += '  |  probes said ' + $G.StEstimate + ' GB' }
    $G.stSizeSub.Text = $sub

    # speed: SVT-AV1 reports the average; the current speed comes from the last 20 seconds
    $avg = $e.Fps
    $w20 = Get-WindowRate 20
    $w90 = Get-WindowRate 90
    $G.stSpeed.Text = $avg.ToString('0.0', $inv) + ' fps'
    $s2 = ''
    if ($null -ne $w20) { $s2 = 'now ' + ([double]$w20[0]).ToString('0.0', $inv) + ' fps  |  ' }
    $G.stSpeedSub.Text = $s2 + ($avg / $fpsSrc).ToString('0.00', $inv) + 'x realtime'

    # time left: the last 90 seconds count most once there are enough of them
    $rate = $avg
    if ($null -ne $w90 -and [double]$w90[0] -gt 0) { $rate = 0.5 * $avg + 0.5 * [double]$w90[0] }
    if ($rate -gt 0 -and $total -gt 0) {
        $left = ($total - $e.Frames) / $rate
        $G.stEta.Text = Format-Dur $left
        $fin = (Get-Date).AddSeconds($left)
        $day = ''
        if ($fin.Date -gt (Get-Date).Date) { $day = $fin.ToString('ddd ', [System.Globalization.CultureInfo]::CurrentCulture) }
        $G.stEtaSub.Text = 'finishes ' + $day + $fin.ToString('HH:mm')
    }

    $G.stRate.Text = ([math]::Round($e.Kbps)).ToString('N0', $inv) + ' kb/s'
    if ($null -ne $w20 -and [double]$w20[0] -gt 0) {
        $kbNow = [double]$w20[1] * 1048576.0 * 8.0 / 1000.0 / ([double]$w20[0] / $fpsSrc)
        $G.stRateSub.Text = 'now ' + ([math]::Round($kbNow)).ToString('N0', $inv) + ' kb/s'
    }
    $G.stFrames.Text = ([math]::Round($e.Frames)).ToString('N0', $inv)
    $fs = ''
    if ($total -gt 0) { $fs = 'of ' + ([math]::Round($total)).ToString('N0', $inv) }
    if ($e.Elapsed -ge 0) { $fs += '  |  elapsed ' + (Format-Dur $e.Elapsed) }
    $G.stFramesSub.Text = $fs
}

function Poll-Status {
    $st = Read-KeyValueFile (Join-Path $G.JobDir 'status.txt')
    $items = @($G.JobItems)
    $res = @()
    $rf = Join-Path $G.JobDir 'results.txt'
    if (Test-Path -LiteralPath $rf) { $res = @([System.IO.File]::ReadAllLines($rf) | Where-Object { $_.Trim() -ne '' }) }
    for ($k = 0; $k -lt $res.Count -and $k -lt $items.Count; $k++) {
        $f = $res[$k].Split('|')
        if ($f[0] -eq 'OK') {
            $x = $items[$k]
            $outGB = To-Num (([string]$f[2]) -replace '[^0-9.]', '')
            $txt = 'Done  ' + $f[2]
            if ([double]$x.SrcGB -gt 0 -and $outGB -gt 0) { $txt += ('  -' + [math]::Round(100.0 * (1.0 - $outGB / [double]$x.SrcGB)) + '%') }
            $x.Status = $txt
            if ($f.Count -ge 5 -and $f[4].Trim() -ne '') { $x.Quality = $f[4].Trim() }
            if ($f.Count -ge 6 -and $f[5].Trim() -ne '') { $x.OutPath = $f[5].Trim(); $G.LastOut = $x.OutPath }
            if (-not $x.Logged) {
                $x.Logged = $true
                Add-History $x $outGB ([string]$f[3]) ([string]$x.Quality) ([string]$x.OutPath)
                $G.RunSaved += ([double]$x.SrcGB - $outGB)
            }
        }
        elseif ($f[0] -eq 'PLAN') { $items[$k].Status = 'Plan ready' }
        elseif ($f[0] -eq 'FAIL') { $items[$k].Status = 'Failed' }
        elseif ($f.Count -ge 3 -and ([string]$f[2]).StartsWith('already exists')) { $items[$k].Status = 'Skipped: output exists' }
        else { $items[$k].Status = 'Skipped' }
    }
    $idx = 0
    if ($st.Contains('index')) { $idx = [int](To-Num $st['index']) }
    $G.CurIndex = $idx
    $stage = [string]$st['stage']
    $detail = [string]$st['detail']
    $G.StDur = To-Num $st['duration']
    $G.StFps = To-Num $st['fps']
    $G.StAudio = To-Num $st['audio_kbps']
    $G.StEstimate = [string]$st['estimate']
    if ($idx -ge 1 -and $idx -le $items.Count -and $res.Count -lt $idx) {
        $names = @{ analysing = 'Analysing'; adaptive = 'Grain plan'; calibrating = 'Calibrating'; indexing = 'Indexing'; probes = 'Probes'; quality = 'Scoring'; approve = 'Waiting for you'; encoding = 'Encoding'; audio = 'Audio'; muxing = 'Muxing' }
        $s = $names[$stage]
        if ($null -eq $s) { $s = 'Working' }
        if ($stage -eq 'encoding' -and $G.txtPct.Text -ne '') { $s = 'Encoding ' + $G.txtPct.Text }
        $items[$idx - 1].Status = $s
        if ([string]$st['quality'] -ne '') { $items[$idx - 1].Quality = [string]$st['quality'] }
    }
    $G.lvQueue.Items.Refresh()
    if ($idx -ge 1) { $G.txtNow.Text = ('File {0} of {1}:  {2}' -f $idx, $st['total'], $st['name']) }

    $stageText = @{
        analysing   = 'Reading the file and scanning for black bars.'
        adaptive    = 'Grain plan: scene cuts and grain in one pass over the film.'
        calibrating = 'Calibrating KNLMeansCL against the hqdn3d levels on this film [once per film, then cached].'
        indexing    = 'Indexing the source for VapourSynth [first time only].'
        probes      = 'Encoding probe ' + $detail + ' for the preview reel and the estimate.'
        quality     = 'Scoring the probes against the source.'
        approve     = 'Preview ready.'
        encoding    = 'Encoding the film.'
        audio       = 'Video done, waiting for the audio.'
        muxing      = 'Muxing the final file.'
        finished    = 'Queue finished.'
    }
    $t = $stageText[$stage]
    if ($null -ne $t) { $G.txtStage.Text = $t }

    if ($stage -ne $G.LastStage) {
        $G.LastStage = $stage
        if ($stage -eq 'approve') { $G.ApproveSince = Get-Date; $G.Held = $false; $G.btnApprove.IsEnabled = $true; $G.btnHold.IsEnabled = $true; $G.btnSkip.IsEnabled = $true }
        else { $G.btnApprove.IsEnabled = $false; $G.btnHold.IsEnabled = $false; $G.btnSkip.IsEnabled = $false }
        if ($stage -eq 'analysing') { Reset-Stats }
        if ($stage -ne 'encoding') { $G.txtLive.Text = ' ' }
    }
    if ($stage -eq 'approve' -and $null -ne $G.ApproveSince) {
        if ($G.Held) { $G.txtStage.Text = 'Preview ready. Waiting for you: press Encode or Skip file.' }
        else {
            $left = [int]([int](To-Num $G.Cfg['AUTO_WAIT']) - ((Get-Date) - $G.ApproveSince).TotalSeconds)
            $G.txtStage.Text = ('Preview ready. Encoding starts by itself in {0} s unless you press Wait or Skip.' -f [math]::Max(0, $left))
        }
    }

    $est = ''
    if ($st['estimate'] -and $st['estimate'] -ne 'N/A') { $est = 'Probe estimate: ~' + $st['estimate'] + ' GB' }
    if ($st['eta'] -and $st['eta'] -ne 'N/A') { $est += '   |   ~' + $st['eta'] }
    $G.txtEstimate.Text = $est
    $q = [string]$st['quality']
    if ($q -ne '') { $G.txtQuality.Text = 'Probe quality [average / worst]: ' + $q } else { $G.txtQuality.Text = '' }
    $reel = [string]$st['reel']
    $G.btnReel.IsEnabled = ($reel -ne '' -and (Test-Path -LiteralPath $reel))
    $G.ReelPath = $reel

    if ($stage -eq 'encoding') {
        if ($null -ne $G.Engine) {
            # console mode: no captured output, so fall back to ffmpeg/vspipe's progress file
            $pf = Join-Path $G.JobDir 'vprog.txt'
            if ($G.StDur -gt 0 -and (Test-Path -LiteralPath $pf)) {
                $ms = [regex]::Matches((Read-Tail $pf), 'out_time_us=(\d+)')
                if ($ms.Count -gt 0) {
                    $o = [double]$ms[$ms.Count - 1].Groups[1].Value / 1000000.0
                    $G.pb.IsIndeterminate = $false
                    $G.pb.Value = [math]::Min(100.0, 100.0 * $o / $G.StDur)
                    $G.txtPct.Text = (100.0 * $o / $G.StDur).ToString('0.0', $inv) + ' %'
                }
            }
        }
        elseif ($null -eq $G.Enc) { $G.pb.IsIndeterminate = $true }
    }
    elseif ($stage -eq 'probes' -and $detail -match '^(\d+)/(\d+)$') {
        $G.pb.IsIndeterminate = $false
        $G.pb.Value = 100.0 * ([double]$Matches[1] - 1) / [math]::Max(1, [double]$Matches[2])
    }
    elseif ($stage -eq 'approve' -or $stage -eq 'finished' -or $stage -eq 'audio' -or $stage -eq 'muxing') { $G.pb.IsIndeterminate = $false }
    else { $G.pb.IsIndeterminate = $true }
}

function Finish-Run {
    $G.Timer.Stop()
    if ($null -ne $G.Proc) { Drain-Output; $G.Proc.CloseLog() }
    try { Poll-Status } catch { }
    Set-Running $false
    Update-Strip
    $ok = 0
    $fail = 0
    foreach ($it in @($G.JobItems)) {
        if ($it.Status -like 'Done*' -or $it.Status -eq 'Plan ready') { $ok++ }
        elseif ($it.Status -eq 'Failed') { $fail++ }
        elseif ($G.Aborted -and $it.Status -notlike 'Skipped*') { $it.Status = 'Aborted' }
    }
    $G.lvQueue.Items.Refresh()
    if ($G.Analyse) {
        $G.txtNow.Text = ('Plan analysis finished: {0} of {1} ready' -f $ok, @($G.JobItems).Count)
        $G.txtStage.Text = 'Select a file and press Edit grain plan. The encode uses the edited plan.'
    }
    else {
        $G.txtNow.Text = ('Finished: {0} of {1} done' -f $ok, @($G.JobItems).Count)
        $G.txtStage.Text = 'Each output has a .log next to it with the settings, the quality score and how long every step took.'
        if ($G.RunSaved -gt 0) { $G.txtStage.Text = ('Saved ' + (Format-Size $G.RunSaved) + ' this run. ') + $G.txtStage.Text }
        if ([string]$G.LastOut -ne '' -and (Test-Path -LiteralPath $G.LastOut)) { $G.btnOpenOut.Visibility = 'Visible'; $G.btnPlayOut.Visibility = 'Visible' }
        $G.TotalSaved = Get-TotalSaved
        Update-Empty
    }
    if ($G.Aborted) { $G.txtNow.Text = 'Aborted' }
    $G.pb.IsIndeterminate = $false
    if (-not $G.Aborted) { $G.pb.Value = 100 }
    $G.txtLive.Text = ' '
    Append-Log ('==== ' + $G.txtNow.Text + ' at ' + (Get-Date -Format 'HH:mm:ss') + " ====`r`n")
    Show-Details
    # when done: the window counts down, with a Cancel button
    $act = $DoneValues[[math]::Max(0, $G.cbDone.SelectedIndex)]
    if (-not $G.Analyse -and -not $G.Aborted -and $act -ne 'none' -and $ok -gt 0) {
        $G.DoneAction = $act
        $G.DoneAt = (Get-Date).AddSeconds([math]::Max(10, [int](To-Num $G.Cfg['AUTO_WAIT'])))
        $G.dpDone.Visibility = 'Visible'
        $G.Timer.Start()
    }
}

function Update-DoneCountdown {
    if ($null -eq $G.DoneAt) { return }
    $left = [int][math]::Ceiling(($G.DoneAt - (Get-Date)).TotalSeconds)
    $word = 'Sleep'
    if ($G.DoneAction -eq 'shutdown') { $word = 'Shut down' }
    $G.txtDone.Text = ('{0} in {1} s' -f $word, [math]::Max(0, $left))
    if ($left -gt 0) { return }
    $G.DoneAt = $null
    $G.dpDone.Visibility = 'Collapsed'
    $G.Timer.Stop()
    if ($G.DoneAction -eq 'shutdown') {
        Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 30 /c "RazAV1 finished. Run: shutdown /a to cancel."' -WindowStyle Hidden
    }
    else {
        [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)
    }
}

function On-Tick {
    $G.Tick++
    try {
        if ($G.Running) {
            Drain-Output
            if ($G.StatsDirty -or ($G.Tick % 4) -eq 0) { Update-Stats; Update-Strip }
            if (($G.Tick % 4) -eq 1 -and $null -ne $G.JobDir) { Poll-Status }
            $exited = $false
            if ($null -ne $G.Proc) { $exited = $G.Proc.Exited }
            elseif ($null -ne $G.Engine) { $exited = $G.Engine.HasExited }
            if ($exited) {
                if ($null -eq $G.ExitSeen) { $G.ExitSeen = Get-Date }
                $pipesDone = ($null -eq $G.Proc) -or $G.Proc.Done
                if ($pipesDone -or ((Get-Date) - $G.ExitSeen).TotalSeconds -gt 5) { Finish-Run }
            }
        }
        Update-DoneCountdown
    }
    catch { Write-LogFile 'errors.log' ('tick: ' + $_.Exception.ToString()) }
}

function Stop-Engine {
    $G.Aborted = $true
    if ($null -ne $G.JobDir) { try { [System.IO.File]::WriteAllText((Join-Path $G.JobDir 'stop.flag'), 'stop') } catch { } }
    if ($null -ne $G.Proc) { $G.Proc.Kill() }
    elseif ($null -ne $G.Engine) {
        try { Start-Process -FilePath 'taskkill.exe' -ArgumentList ('/T /F /PID ' + $G.Engine.Id) -WindowStyle Hidden -Wait } catch { }
    }
    Append-Log ("`r`n==== Aborted by you at " + (Get-Date -Format 'HH:mm:ss') + " ====`r`n")
}

# ---------------------------------------------------------------------------------------------
# v7 grain plan editor
# ---------------------------------------------------------------------------------------------
$LevelColors = @('#24466E', '#1F5FBF', '#3D85E0', '#86B6F2', '#D3E3FA')

function New-Brush([string]$hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze()
    return $b
}

function Format-Tc([double]$sec) {
    $ts = [timespan]::FromSeconds([math]::Max(0, $sec))
    return ('{0}:{1:00}:{2:00}.{3}' -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, [math]::Floor($ts.Milliseconds / 100))
}

function Read-PlanRows([string]$path) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $path)) { return , $rows }
    $lines = [System.IO.File]::ReadAllLines($path)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $f = $lines[$i].Split(',')
        if ($f.Count -lt 5) { continue }
        $rows.Add(@($f[0].Trim(), $f[1].Trim(), $f[2].Trim(), [int](To-Num $f[3]), [int](To-Num $f[4])))
    }
    return , $rows
}

function Update-PlanRow($r) {
    $r.Changed = ''
    if ($r.Level -ne $r.OrigLevel -or $r.Iso -ne $r.OrigIso) { $r.Changed = ('was {0} / {1}' -f $r.OrigLevel, $r.OrigIso) }
}

function Draw-Plan {
    $E = $G.PE
    $cv = $E.cvTime
    $cv.Children.Clear()
    $W = $cv.ActualWidth
    $H = $cv.ActualHeight
    if ($W -lt 20 -or $H -lt 20 -or $E.Dur -le 0) { return }
    $sel = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($r in @($E.lv.SelectedItems)) { [void]$sel.Add([int]$r.N) }
    $top = 8.0
    foreach ($r in $E.Rows) {
        $x = $r.Start / $E.Dur * $W
        $w = [math]::Max(1.0, ($r.End - $r.Start) / $E.Dur * $W)
        $h = ($H - $top - 2) * (0.18 + 0.82 * $r.Level / 5.0)
        $rc = New-Object System.Windows.Shapes.Rectangle
        $rc.Width = $w
        $rc.Height = $h
        $rc.Fill = $E.Brushes[$r.Level - 1]
        [System.Windows.Controls.Canvas]::SetLeft($rc, $x)
        [System.Windows.Controls.Canvas]::SetTop($rc, $H - $h)
        [void]$cv.Children.Add($rc)
        if ($sel.Contains([int]$r.N)) {
            $mk = New-Object System.Windows.Shapes.Rectangle
            $mk.Width = $w
            $mk.Height = 4
            $mk.Fill = $E.SelBrush
            [System.Windows.Controls.Canvas]::SetLeft($mk, $x)
            [System.Windows.Controls.Canvas]::SetTop($mk, 1)
            [void]$cv.Children.Add($mk)
            $ov = New-Object System.Windows.Shapes.Rectangle
            $ov.Width = $w
            $ov.Height = $H - $top
            $ov.Fill = $E.SelShade
            [System.Windows.Controls.Canvas]::SetLeft($ov, $x)
            [System.Windows.Controls.Canvas]::SetTop($ov, $top)
            [void]$cv.Children.Add($ov)
        }
    }
    # time ruler
    $tk = $E.cvTicks
    $tk.Children.Clear()
    $step = 600.0
    if ($E.Dur -lt 1800) { $step = 300.0 }
    if ($E.Dur -gt 9000) { $step = 1200.0 }
    for ($t = 0.0; $t -lt $E.Dur; $t += $step) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = (Format-Dur $t).Substring(0, (Format-Dur $t).Length - 3)
        $tb.FontSize = 10.5
        $tb.Foreground = $E.DimBrush
        [System.Windows.Controls.Canvas]::SetLeft($tb, $t / $E.Dur * $W)
        [void]$tk.Children.Add($tb)
    }
    # share of the film per level
    $share = @(0.0, 0.0, 0.0, 0.0, 0.0)
    foreach ($r in $E.Rows) { $share[$r.Level - 1] += ($r.End - $r.Start) }
    $parts = @()
    for ($L = 1; $L -le 5; $L++) { $parts += ('level {0}: {1}%' -f $L, [math]::Round(100.0 * $share[$L - 1] / $E.Dur)) }
    $E.txtShare.Text = ($parts -join '    ') + ('    |    {0} scenes, {1} changed by hand' -f $E.Rows.Count, @($E.Rows | Where-Object { $_.Changed -ne '' }).Count)
}

function Get-RowIndexAt([double]$x) {
    $E = $G.PE
    $W = $E.cvTime.ActualWidth
    if ($W -le 0) { return -1 }
    $t = [math]::Max(0.0, [math]::Min($E.Dur - 0.001, $x / $W * $E.Dur))
    $lo = 0
    $hi = $E.Rows.Count - 1
    while ($lo -lt $hi) {
        $mid = [int][math]::Floor(($lo + $hi + 1) / 2)
        if ($E.Rows[$mid].Start -le $t) { $lo = $mid } else { $hi = $mid - 1 }
    }
    return $lo
}

function Select-PlanRange([int]$a, [int]$b, [bool]$add) {
    $E = $G.PE
    $lo = [math]::Min($a, $b)
    $hi = [math]::Max($a, $b)
    $E.Syncing = $true
    try {
        if (-not $add) { $E.lv.SelectedItems.Clear() }
        for ($i = $lo; $i -le $hi; $i++) { if (-not $E.lv.SelectedItems.Contains($E.Rows[$i])) { [void]$E.lv.SelectedItems.Add($E.Rows[$i]) } }
    }
    finally { $E.Syncing = $false }
    $E.lv.ScrollIntoView($E.Rows[$b])
    On-PlanSelection
}

function On-PlanSelection {
    $E = $G.PE
    Draw-Plan
    $sel = @($E.lv.SelectedItems)
    if ($sel.Count -eq 0) { $E.txtSel.Text = ''; return }
    $len = 0.0
    foreach ($r in $sel) { $len += ($r.End - $r.Start) }
    $first = $sel[0]
    if ($sel.Count -eq 1) {
        $E.txtSel.Text = ('Scene {0}: {1} to {2} [{3} s], grain {4}, level {5}, ISO {6}' -f $first.N, $first.StartText, $first.EndText, [math]::Round($len, 1), $first.NoiseText, $first.Level, $first.Iso)
    }
    else { $E.txtSel.Text = ('{0} scenes selected, {1} of film' -f $sel.Count, (Format-Dur $len)) }
    $E.Loading = $true
    try {
        $E.cbLevel.SelectedIndex = $first.Level - 1
        $E.cbIso.SelectedIndex = [array]::IndexOf([int[]]$IsoLadder, (Snap-Iso ([int]$first.Iso)))
    }
    finally { $E.Loading = $false }
    $E.ThumbWant = ($first.Start + $first.End) / 2.0
    $E.ThumbTimer.Stop()
    $E.ThumbTimer.Start()
}

function Update-PlanThumb {
    $E = $G.PE
    $E.ThumbTimer.Stop()
    if ($E.ThumbBusy) { $E.ThumbTimer.Start(); return }
    $t = $E.ThumbWant
    if ($t -lt 0) { return }
    $E.ThumbWant = -1.0
    $E.ThumbBusy = $true
    try {
        $E.txtThumb.Text = 'Loading...'
        $png = Join-Path $env:TEMP ('av1_thumb_' + $PID + '.png')
        $ff = (Get-Command ffmpeg -ErrorAction Stop).Source
        $r = Invoke-Native $ff @('-hide_banner', '-v', 'error', '-nostdin', '-y', '-ss', $t.ToString('0.###', $inv), '-i', $E.Item.Path, '-frames:v', '1', '-vf', 'scale=640:-2', $png)
        if ($r.Code -eq 0 -and (Test-Path -LiteralPath $png)) {
            $bytes = [System.IO.File]::ReadAllBytes($png)
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.StreamSource = New-Object System.IO.MemoryStream (, $bytes)
            $bi.EndInit()
            $bi.Freeze()
            $E.imgThumb.Source = $bi
            $E.txtThumb.Text = ''
        }
        else { $E.txtThumb.Text = 'No preview frame' }
    }
    catch { $E.txtThumb.Text = 'No preview frame' }
    finally { $E.ThumbBusy = $false }
    if ($E.ThumbWant -ge 0) { $E.ThumbTimer.Start() }
}

function Set-PlanLevel($rows, [int]$level, [int]$iso) {
    $E = $G.PE
    foreach ($r in @($rows)) {
        $L = [math]::Min(5, [math]::Max(1, $level))
        $r.Level = $L
        if ($iso -gt 0) { $r.Iso = $iso }
        elseif ($E.chkIsoFollow.IsChecked) { $r.Iso = Get-IsoForLevel $L }
        Update-PlanRow $r
    }
    $E.Dirty = $true
    $E.txtPlanStatus.Text = 'Not saved yet.'
    $E.lv.Items.Refresh()
    On-PlanSelection
}

function Step-PlanLevels([int]$delta) {
    $E = $G.PE
    foreach ($r in $E.Rows) {
        $r.Level = [math]::Min(5, [math]::Max(1, $r.Level + $delta))
        if ($E.chkIsoFollow.IsChecked) { $r.Iso = Get-IsoForLevel $r.Level }
        Update-PlanRow $r
    }
    $E.Dirty = $true
    $E.txtPlanStatus.Text = 'Not saved yet.'
    $E.lv.Items.Refresh()
    On-PlanSelection
}

function Save-Plan {
    $E = $G.PE
    $orig = Join-Path $E.Dir 'plan_original.csv'
    if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $E.Csv -Destination $orig -Force }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('start,end,noise,level,iso')
    foreach ($r in $E.Rows) { $out.Add(('{0},{1},{2},{3},{4}' -f $r.StartRaw, $r.EndRaw, $r.NoiseRaw, $r.Level, $r.Iso)) }
    [System.IO.File]::WriteAllLines($E.Csv, $out.ToArray())
    # the encode rebuilds these from the plan
    foreach ($f in @('denoise.cmd', 'grain_timed.tbl')) { Remove-Item -LiteralPath (Join-Path $E.Dir $f) -Force -ErrorAction SilentlyContinue }
    $E.Dirty = $false
    $E.txtPlanStatus.Text = ('Saved at {0}. The analysed plan is kept as plan_original.csv.' -f (Get-Date -Format 'HH:mm:ss'))
}

function Show-PlanEditor($it) {
    $pd = Get-PlanDir $it
    $csv = Join-Path $pd 'plan.csv'
    if (-not (Test-Path -LiteralPath $csv)) { Gui-Msg 'This file has no grain plan yet. Press Analyse plan first [or encode it once in adaptive mode].'; return }
    $w = Load-Xaml $PlanXaml
    $w.Owner = $G.Win
    $E = @{ Win = $w; Item = $it; Dir = $pd; Csv = $csv; Dirty = $false; Loading = $false; Syncing = $false; ThumbBusy = $false; ThumbWant = -1.0; Anchor = 0; Dragging = $false }
    foreach ($n in @('txtFile', 'spLegend', 'cvTime', 'cvTicks', 'txtShare', 'lvSeg', 'imgThumb', 'txtThumb', 'txtSel', 'cbLevel', 'cbIso', 'btnApply', 'chkIsoFollow', 'btnPlus', 'btnMinus', 'btnRevert', 'btnPlanClose', 'btnPlanSave', 'txtPlanStatus')) { $E[$n] = $w.FindName($n) }
    $E.lv = $E.lvSeg
    $E.Brushes = @($LevelColors | ForEach-Object { New-Brush $_ })
    $E.SelBrush = New-Brush (Theme-Hex '#E8EEF8')
    $E.SelShade = New-Brush '#22FFFFFF'
    $E.DimBrush = New-Brush (Theme-Hex '#6E7580')
    $G.PE = $E

    $cur = Read-PlanRows $csv
    $orig = Read-PlanRows (Join-Path $pd 'plan_original.csv')
    if ($orig.Count -ne $cur.Count) { $orig = $cur }
    $E.Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    for ($i = 0; $i -lt $cur.Count; $i++) {
        $c = $cur[$i]
        $s0 = To-Num $c[0]
        $s1 = To-Num $c[1]
        $r = New-Object PSObject -Property ([ordered]@{
                N = $i + 1; Start = $s0; End = $s1; StartRaw = $c[0]; EndRaw = $c[1]; NoiseRaw = $c[2]
                StartText = (Format-Tc $s0); EndText = (Format-Tc $s1); LenText = ([math]::Round($s1 - $s0, 1)).ToString('0.0', $inv) + ' s'
                NoiseText = (To-Num $c[2]).ToString('0.00', $inv); Level = [int]$c[3]; Iso = [int]$c[4]
                OrigLevel = [int]$orig[$i][3]; OrigIso = [int]$orig[$i][4]; Changed = ''
            })
        Update-PlanRow $r
        $E.Rows.Add($r)
    }
    if ($E.Rows.Count -eq 0) { Gui-Msg 'plan.csv has no scenes.'; return }
    $E.Dur = $E.Rows[$E.Rows.Count - 1].End
    $E.txtFile.Text = $it.Name + '   |   ' + $pd
    $E.lv.ItemsSource = $E.Rows
    for ($L = 1; $L -le 5; $L++) {
        [void]$E.cbLevel.Items.Add([string]$L)
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $sp.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $sw = New-Object System.Windows.Shapes.Rectangle
        $sw.Width = 12; $sw.Height = 12; $sw.RadiusX = 2; $sw.RadiusY = 2; $sw.Fill = $E.Brushes[$L - 1]; $sw.Margin = New-Object System.Windows.Thickness(0, 0, 5, 0)
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = 'level ' + $L
        $lb.FontSize = 11
        $lb.Foreground = $E.DimBrush
        [void]$sp.Children.Add($sw)
        [void]$sp.Children.Add($lb)
        [void]$E.spLegend.Children.Add($sp)
    }
    foreach ($v in $IsoLadder) { [void]$E.cbIso.Items.Add([string]$v) }
    $E.cbLevel.SelectedIndex = 2
    $E.cbIso.SelectedIndex = [array]::IndexOf([int[]]$IsoLadder, 400)
    $E.txtPlanStatus.Text = 'Changes are saved to plan.csv; the encode builds the denoise commands and timed grain table from it.'

    $E.ThumbTimer = New-Object System.Windows.Threading.DispatcherTimer
    $E.ThumbTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $E.ThumbTimer.Add_Tick({ Update-PlanThumb })

    $E.cvTime.Add_SizeChanged({ Draw-Plan })
    $E.cvTime.Add_MouseLeftButtonDown({
            param($s, $e)
            $G.PE.cvTime.CaptureMouse() | Out-Null
            $i = Get-RowIndexAt ($e.GetPosition($G.PE.cvTime).X)
            if ($i -lt 0) { return }
            $mods = [System.Windows.Input.Keyboard]::Modifiers
            if (($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) { Select-PlanRange $G.PE.Anchor $i $false }
            elseif (($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
                $r = $G.PE.Rows[$i]
                if ($G.PE.lv.SelectedItems.Contains($r)) { [void]$G.PE.lv.SelectedItems.Remove($r) } else { [void]$G.PE.lv.SelectedItems.Add($r) }
                $G.PE.Anchor = $i
            }
            else { $G.PE.Anchor = $i; Select-PlanRange $i $i $false }
            $G.PE.Dragging = $true
            $G.PE.LastDrag = $i
        })
    $E.cvTime.Add_MouseMove({
            param($s, $e)
            if (-not $G.PE.Dragging) { return }
            $i = Get-RowIndexAt ($e.GetPosition($G.PE.cvTime).X)
            if ($i -ge 0 -and $i -ne $G.PE.LastDrag) { $G.PE.LastDrag = $i; Select-PlanRange $G.PE.Anchor $i $false }
        })
    $E.cvTime.Add_MouseLeftButtonUp({ $G.PE.Dragging = $false; $G.PE.cvTime.ReleaseMouseCapture() })
    $E.lv.Add_SelectionChanged({
            if ($G.PE.Syncing) { return }
            $sel = @($G.PE.lv.SelectedItems)
            if ($sel.Count -eq 1) { $G.PE.Anchor = [int]$sel[0].N - 1 }
            On-PlanSelection
        })
    $E.lv.Add_PreviewKeyDown({
            param($s, $e)
            $k = [string]$e.Key
            if ($k -match '^(D|NumPad)([1-5])$') {
                $sel = @($G.PE.lv.SelectedItems)
                if ($sel.Count -gt 0) { Set-PlanLevel $sel ([int]$Matches[2]) 0 }
                $e.Handled = $true
            }
        })
    $E.cbLevel.Add_SelectionChanged({
            if ($G.PE.Loading -or -not $G.PE.chkIsoFollow.IsChecked -or $G.PE.cbLevel.SelectedIndex -lt 0) { return }
            $G.PE.Loading = $true
            try { $G.PE.cbIso.SelectedIndex = [array]::IndexOf([int[]]$IsoLadder, [int](Get-IsoForLevel ($G.PE.cbLevel.SelectedIndex + 1))) }
            finally { $G.PE.Loading = $false }
        })
    $E.btnApply.Add_Click({
            $sel = @($G.PE.lv.SelectedItems)
            if ($sel.Count -eq 0) { $G.PE.txtPlanStatus.Text = 'Select one or more scenes first.'; return }
            $iso = [int]$IsoLadder[[math]::Max(0, $G.PE.cbIso.SelectedIndex)]
            Set-PlanLevel $sel ($G.PE.cbLevel.SelectedIndex + 1) $iso
        })
    $E.btnPlus.Add_Click({ Step-PlanLevels 1 })
    $E.btnMinus.Add_Click({ Step-PlanLevels -1 })
    $E.btnRevert.Add_Click({
            foreach ($r in $G.PE.Rows) { $r.Level = $r.OrigLevel; $r.Iso = $r.OrigIso; Update-PlanRow $r }
            $G.PE.Dirty = $true
            $G.PE.txtPlanStatus.Text = 'Back to the analysed plan. Not saved yet.'
            $G.PE.lv.Items.Refresh()
            Draw-Plan
        })
    $E.btnPlanSave.Add_Click({ Save-Plan })
    $E.btnPlanClose.Add_Click({ $G.PE.Win.Close() })
    $w.Add_Closing({
            param($s, $e)
            if (-not $G.PE.Dirty) { return }
            $ans = Show-Ask 'Grain plan' 'Save the changes to the grain plan?' @('Yes', 'No', 'Cancel')
            if ($ans -eq 'Yes') { Save-Plan }
            elseif ($ans -eq 'Cancel') { $e.Cancel = $true }
        })
    $w.Add_ContentRendered({ Draw-Plan })
    [void]$w.ShowDialog()
    $G.PE.ThumbTimer.Stop()
    Show-Details
}

# vspipe to test from the Settings window: the portable one when it exists, else what is typed in the box
function Get-SettingsVspipe {
    $b = Get-Bundle $G.Here
    if ($b.Vspipe -ne '') { return $b.Vspipe }
    return $G.S_tbVs.Text
}

function Show-Settings {
    $w = Load-Xaml $SettingsXaml
    $w.Owner = $G.Win
    $G.SW = $w
    foreach ($n in @('tbSvt', 'tbTables', 'tbVs', 'tbDevice', 'tbLang', 'tbWait', 'cbDefProfile', 'txtVsResult', 'btnSvt', 'btnTables', 'btnVs', 'btnCheckVs', 'btnGpu', 'btnSave', 'btnCancel',
            'txtPack', 'btnPack', 'btnSvtCheck', 'btnSvtInstall', 'btnSvtBack', 'chkQuality', 'chkConsole', 'hdSvt', 'hdTables', 'hdVs',  'cbScale', 'cbLang', 'cbDefAudFormat', 'cbDefAudCh', 'chkDefAudNorm', 'cbDefCrop', 'tbDefOutDir', 'tbDefOutName', 'cbDefOutExists')) { $G['S_' + $n] = $w.FindName($n) }
    $G.Raw = Get-Config $G.Here
    $G.S_tbSvt.Text = $G.Raw['SVT_EXE']
    $G.S_tbTables.Text = $G.Raw['DIR_TABLES']
    $G.S_tbVs.Text = $G.Raw['VSPIPE']
    # v7: a portable pack folder that has files wins over these paths, so show what is really used
    $b = Get-Bundle $G.Here
    $G.S_PackSvt = ($b.Svt -ne '')
    $G.S_PackTables = ($b.TableCount -gt 0)
    $G.S_PackVs = ($b.Vspipe -ne '')
    if ($G.S_PackSvt) { $G.S_tbSvt.Text = $b.Svt; $G.S_tbSvt.IsEnabled = $false; $G.S_btnSvt.IsEnabled = $false; $G.S_hdSvt.Text = 'SVTAV1ENCAPP.EXE  [in use: the portable pack, bin folder]' }
    if ($G.S_PackTables) { $G.S_tbTables.Text = $b.Tables; $G.S_tbTables.IsEnabled = $false; $G.S_btnTables.IsEnabled = $false; $G.S_hdTables.Text = ('GRAIN TABLES FOLDER  [in use: the portable pack, tables folder, {0} tables]' -f $b.TableCount) }
    if ($G.S_PackVs) { $G.S_tbVs.Text = $b.Vspipe; $G.S_tbVs.IsEnabled = $false; $G.S_btnVs.IsEnabled = $false; $G.S_hdVs.Text = 'VSPIPE  [in use: the portable pack, vs folder]' }
    $G.S_tbDevice.Text = $G.Raw['KNLM_DEVICE']
    $G.S_tbLang.Text = $G.Raw['PREF_LANG']
    $G.S_tbWait.Text = $G.Raw['AUTO_WAIT']
    $G.S_chkQuality.IsChecked = ([string]$G.Raw['QUALITY'] -ne '0')
    $G.S_chkConsole.IsChecked = ([string]$G.Raw['GUI_CONSOLE'] -eq '1')
    $G.Langs = Get-Languages
    foreach ($lg in $G.Langs) { [void]$G.S_cbLang.Items.Add($lg[1]) }
    $G.S_cbLang.SelectedIndex = 0
    for ($q = 0; $q -lt $G.Langs.Count; $q++) { if ($G.Langs[$q][0] -eq [string]$G.Raw['UI_LANG']) { $G.S_cbLang.SelectedIndex = $q } }
    [void]$G.S_cbScale.Items.Add((T 'Auto  [follows the window]'))
    foreach ($z in $UiScales) { [void]$G.S_cbScale.Items.Add([string]$z + ' %') }
    foreach ($t in @('Opus', 'Keep the original')) { [void]$G.S_cbDefAudFormat.Items.Add((T $t)) }
    $G.S_cbDefAudFormat.SelectedIndex = [int]([string]$G.Raw['DEF_AUDIO_FORMAT'] -eq 'copy')
    foreach ($t in @('Auto  [7.1 becomes 5.1]', 'Keep the channels', 'Stereo')) { [void]$G.S_cbDefAudCh.Items.Add((T $t)) }
    $G.S_cbDefAudCh.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]@('auto', 'keep', 'stereo'), [string]$G.Raw['DEF_AUDIO_CHANNELS']))
    $G.S_chkDefAudNorm.IsChecked = ([string]$G.Raw['DEF_AUDIO_NORM'] -ne '0')
    foreach ($t in @('Auto  [remove black bars]', 'Off')) { [void]$G.S_cbDefCrop.Items.Add((T $t)) }
    $G.S_cbDefCrop.SelectedIndex = [int]([string]$G.Raw['DEF_CROP'] -eq 'off')
    $G.S_tbDefOutDir.Text = [string]$G.Raw['DEF_OUT_DIR']
    $G.S_tbDefOutName.Text = [string]$G.Raw['DEF_OUT_NAME']
    foreach ($t in @('Add a number', 'Skip the file', 'Replace it')) { [void]$G.S_cbDefOutExists.Items.Add((T $t)) }
    $G.S_cbDefOutExists.SelectedIndex = [math]::Max(0, [array]::IndexOf([string[]]@('number', 'skip', 'replace'), [string]$G.Raw['DEF_OUT_EXISTS']))
    if ([string]$G.Raw['UI_SCALE'] -eq 'auto') { $G.S_cbScale.SelectedIndex = 0 }
    else { $G.S_cbScale.SelectedIndex = 1 + [math]::Max(0, [array]::IndexOf([int[]]$UiScales, [int](To-Num $G.Raw['UI_SCALE']))) }
    $G.S_txtPack.Text = Get-PackStatus $G.Here
    foreach ($p in $G.Profiles) { [void]$G.S_cbDefProfile.Items.Add($p['name']) }
    $G.S_cbDefProfile.SelectedItem = $G.Cfg['DEFAULT_PROFILE']
    if ($G.S_cbDefProfile.SelectedIndex -lt 0) { $G.S_cbDefProfile.SelectedIndex = 0 }
    if ($G.HasVs) { $G.S_txtVsResult.Text = 'VapourSynth is ready: ' + $G.VsNote } else { $G.S_txtVsResult.Text = 'VapourSynth: ' + $G.VsNote }

    $G.S_btnSvt.Add_Click({
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Filter = 'SvtAv1EncApp.exe|SvtAv1EncApp*.exe|Programs|*.exe'
            if ($d.ShowDialog() -eq $true) { $G.S_tbSvt.Text = $d.FileName }
        })
    $G.S_btnVs.Add_Click({
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Filter = 'vspipe.exe|vspipe.exe|Programs|*.exe'
            if ($d.ShowDialog() -eq $true) { $G.S_tbVs.Text = $d.FileName }
        })
    $G.S_btnTables.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.SelectedPath = $G.S_tbTables.Text
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $G.S_tbTables.Text = $d.SelectedPath }
        })
    $G.S_btnCheckVs.Add_Click({
            $G.S_txtVsResult.Text = 'Checking...'
            $G.SW.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
            $t = Test-VapourSynth (Get-SettingsVspipe)
            if ($t[0]) { $G.S_txtVsResult.Text = 'Ready: ' + $t[1] } else { $G.S_txtVsResult.Text = 'Not ready: ' + $t[1] }
        })
    $G.S_btnGpu.Add_Click({
            $G.S_txtVsResult.Text = 'Timing KNLMeansCL on each GPU, this takes a few seconds...'
            $G.SW.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
            $s = Get-GpuSpeeds (Get-SettingsVspipe)
            if ($s.Count -eq 0) { $G.S_txtVsResult.Text = 'No GPU ran KNLMeansCL. Check VapourSynth first.'; return }
            $best = $s[0]
            $parts = @()
            foreach ($x in $s) { $parts += ('device {0}: {1} fps' -f $x[0], $x[1]); if ($x[1] -gt $best[1]) { $best = $x } }
            $G.S_tbDevice.Text = [string]$best[0]
            $G.S_txtVsResult.Text = (($parts -join ',  ') + ('.  Using device {0}.' -f $best[0]))
        })
    $G.S_btnPack.Add_Click({
            $G.S_txtPack.Text = 'Building the portable pack...'
            Pump-Ui
            $r = Build-PortablePack
            $G.S_txtPack.Text = Get-PackStatus $G.Here
            $G.S_txtVsResult.Text = ''
            Gui-Msg ("Portable pack:`n`n" + $r + "`n`nZip the whole program folder to take it to another PC.")
        })
    $G.S_btnSvtCheck.Add_Click({
            $eff = Get-EffectiveConfig $G.Here
            $cur = Get-SvtVersion $eff['SVT_EXE']
            try { $rel = Get-LatestSvt }
            catch { Gui-Msg ('Could not reach the SVT-AV1 releases page: ' + $_.Exception.Message); return }
            if ($cur -ne '' -and -not (Test-Newer $cur $rel.Version)) { Gui-Msg ('SVT-AV1 ' + $cur + ' is up to date [newest release ' + $rel.Version + ', ' + $rel.Date + '].'); return }
            $ans = Show-Ask 'SVT-AV1 update' ('You have SVT-AV1 ' + $cur + '. The newest release is ' + $rel.Version + ' [' + $rel.Date + '].' + "`n`nThe easiest way to update is Setup and updates > Build latest. Open the releases page instead?") @('Yes', 'No')
            if ($ans -eq 'Yes') { Start-Process $rel.Url }
        })
    $G.S_btnSvtInstall.Add_Click({
            $G.S_txtPack.Text = 'Testing the new SVT-AV1 build...'
            Pump-Ui
            $r = Install-SvtBuild
            $G.S_txtPack.Text = Get-PackStatus $G.Here
            Gui-Msg $r
        })
    $G.S_btnSvtBack.Add_Click({
            Gui-Msg (Restore-SvtBackup)
            $G.S_txtPack.Text = Get-PackStatus $G.Here
        })
    $G.S_btnCancel.Add_Click({ $G.SW.Close() })
    $G.S_btnSave.Add_Click({
            $G.Raw = Get-Config $G.Here
            # paths taken over by the portable pack stay as they were in av1_config.ini [the fallback]
            if (-not $G.S_PackSvt) { $G.Raw['SVT_EXE'] = $G.S_tbSvt.Text.Trim() }
            if (-not $G.S_PackTables) { $G.Raw['DIR_TABLES'] = $G.S_tbTables.Text.Trim() }
            if (-not $G.S_PackVs) { $G.Raw['VSPIPE'] = $G.S_tbVs.Text.Trim() }
            $G.Raw['KNLM_DEVICE'] = [string][int](To-Num $G.S_tbDevice.Text)
            $G.Raw['PREF_LANG'] = $G.S_tbLang.Text.Trim().ToLower()
            $wait = [int](To-Num $G.S_tbWait.Text)
            if ($wait -lt 5) { $wait = 60 }
            $G.Raw['AUTO_WAIT'] = [string]$wait
            if ($null -ne $G.S_cbDefProfile.SelectedItem) { $G.Raw['DEFAULT_PROFILE'] = [string]$G.S_cbDefProfile.SelectedItem }
            if ($G.S_chkQuality.IsChecked) { $G.Raw['QUALITY'] = '1' } else { $G.Raw['QUALITY'] = '0' }
            if ($G.S_chkConsole.IsChecked) { $G.Raw['GUI_CONSOLE'] = '1' } else { $G.Raw['GUI_CONSOLE'] = '0' }
            $oldLook = [string]$G.Raw['UI_SCALE']
            if ($G.S_cbScale.SelectedIndex -le 0) { $G.Raw['UI_SCALE'] = 'auto' }
            else { $G.Raw['UI_SCALE'] = [string]$UiScales[$G.S_cbScale.SelectedIndex - 1] }
            $G.Raw['DEF_AUDIO_FORMAT'] = @('opus', 'copy')[[math]::Max(0, $G.S_cbDefAudFormat.SelectedIndex)]
            $G.Raw['DEF_AUDIO_CHANNELS'] = @('auto', 'keep', 'stereo')[[math]::Max(0, $G.S_cbDefAudCh.SelectedIndex)]
            if ($G.S_chkDefAudNorm.IsChecked) { $G.Raw['DEF_AUDIO_NORM'] = '1' } else { $G.Raw['DEF_AUDIO_NORM'] = '0' }
            $G.Raw['DEF_CROP'] = @('auto', 'off')[[math]::Max(0, $G.S_cbDefCrop.SelectedIndex)]
            $od = $G.S_tbDefOutDir.Text.Trim().Trim('"')
            if ($od -ne '' -and ($od -notmatch '^([A-Za-z]:\\|\\\\)' -or $od -match '[*?"<>|%!]')) { Gui-Msg 'Default output folder: a full path like D:\AV1 or \\NAS\Films, or blank for next to the source.'; return }
            $G.Raw['DEF_OUT_DIR'] = $od
            $on = $G.S_tbDefOutName.Text.Trim()
            if (-not (Test-OutName $on)) { Gui-Msg 'Default file name: it cannot be empty or contain \ / : * ? " < > | % ! ^ &'; return }
            $G.Raw['DEF_OUT_NAME'] = $on
            $G.Raw['DEF_OUT_EXISTS'] = @('number', 'skip', 'replace')[[math]::Max(0, $G.S_cbDefOutExists.SelectedIndex)]
            $G.LookChanged = ($oldLook -ne [string]$G.Raw['UI_SCALE'])
            $oldLang = [string]$G.Raw['UI_LANG']
            if ($G.S_cbLang.SelectedIndex -ge 0) { $G.Raw['UI_LANG'] = [string]$G.Langs[$G.S_cbLang.SelectedIndex][0] }
            $G.LangChanged = ($oldLang -ne [string]$G.Raw['UI_LANG'])
            Save-Config $G.Here $G.Raw
            $G.Cfg = Get-EffectiveConfig $G.Here
            $script:PrefLang = $G.Cfg['PREF_LANG']
            $vs = Test-VapourSynth $G.Cfg['VSPIPE']
            $G.HasVs = $vs[0]
            $G.VsNote = $vs[1]
            foreach ($it in $G.Queue) { Normalize-Item $it }
            $G.lvQueue.Items.Refresh()
            Show-Details
            $G.SW.Close()
        })
    $G.LookChanged = $false
    $G.LangChanged = $false
    [void]$w.ShowDialog()
    if ($G.LookChanged) { Set-ScaleMode ([string](Get-Config $G.Here)['UI_SCALE']) }
    if ($G.LangChanged) {
        if ($G.Running) { Gui-Msg 'The new language applies the next time the window opens.' }
        elseif ((Show-Ask 'Language' 'The new language applies when the window opens again. Restart the window now? The queue comes back as it is.' @('Restart now', 'Later')) -eq 'Restart now') {
            Start-Process -FilePath (Join-Path $G.Here 'RazAV1.cmd') -WorkingDirectory $G.Here
            $G.Win.Close()
        }
    }
}

$UiScales = @(80, 90, 100, 110, 125, 150)

# UI size: 'auto' follows the window [everything shrinks or grows with it], or a fixed percentage.
# Applied straight away, no restart. Other windows open at the size the main window has at that moment.
function Set-ScaleMode([string]$v) {
    if ($v -eq 'auto') { $script:UiScaleMode = 'auto' }
    else {
        $script:UiScaleMode = 'fixed'
        $z = [int](To-Num $v)
        if ($UiScales -contains $z) { $script:UiScale = $z / 100.0 } else { $script:UiScale = 1.0 }
    }
    if ($null -ne $G.Win) {
        $G.AppliedScale = 0
        Update-MainScale
    }
}

function Update-MainScale {
    if ($null -eq $G.Win -or $G.Win.Content -isnot [System.Windows.FrameworkElement]) { return }
    $sc = [double]$script:UiScale
    if ($script:UiScaleMode -eq 'auto') {
        $w = $G.Win.ActualWidth; $h = $G.Win.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        $sc = [math]::Min($w / 1300.0, $h / 820.0)
        $sc = [math]::Max(0.7, [math]::Min(1.5, $sc))
        $sc = [math]::Round($sc * 40) / 40
        $script:UiScale = $sc
        $G.Win.MinWidth = 860
        $G.Win.MinHeight = 600
    }
    else {
        $G.Win.MinWidth = [math]::Min([System.Windows.SystemParameters]::WorkArea.Width, 960 * $sc)
        $G.Win.MinHeight = [math]::Min([System.Windows.SystemParameters]::WorkArea.Height, 640 * $sc)
    }
    if ([math]::Abs($sc - [double]$G.AppliedScale) -lt 0.001) { return }
    $G.AppliedScale = $sc
    if ([math]::Abs($sc - 1.0) -lt 0.001) { $G.Win.Content.LayoutTransform = [System.Windows.Media.Transform]::Identity }
    else { $G.Win.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($sc, $sc) }
}

# Window size, settings panel width and bottom area height, remembered between sessions
# Window layout. UI_LAYOUT = "width,height,maximized,settings width" [older layouts with more values still read].
# UI_COLS = queue column widths.
function Restore-Layout {
    $l = ([string](Get-Config $G.Here)['UI_LAYOUT']).Split(',')
    if ($l.Count -ge 4) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w = To-Num $l[0]; $h = To-Num $l[1]
        if ($w -ge 700 -and $w -le $wa.Width + 40) { $G.Win.Width = $w }
        if ($h -ge 500 -and $h -le $wa.Height + 40) { $G.Win.Height = $h }
        if ($l[2] -eq '1') { $G.Win.WindowState = 'Maximized' }
        $dw = To-Num $l[3]
        if ($dw -ge 320 -and $dw -le 1600) { $G.Win.FindName('colRight').Width = New-Object System.Windows.GridLength($dw) }
    }
    $cols = ([string](Get-Config $G.Here)['UI_COLS']).Split(',')
    $gv = $G.Win.FindName('lvQueue').View
    if ($cols.Count -eq $gv.Columns.Count) {
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $cw = To-Num $cols[$i]
            if ($cw -ge 20 -and $cw -le 1500) { $gv.Columns[$i].Width = $cw }
        }
    }
}

function Save-Layout {
    try {
        $max = '0'
        $w = $G.Win.ActualWidth; $h = $G.Win.ActualHeight
        if ($G.Win.WindowState -eq 'Maximized') { $max = '1'; $w = $G.Win.RestoreBounds.Width; $h = $G.Win.RestoreBounds.Height }
        $dw = $G.Win.FindName('colRight').ActualWidth
        Set-ConfigValue 'UI_LAYOUT' (('{0},{1},{2},{3}' -f [math]::Round($w), [math]::Round($h), $max, [math]::Round($dw)))
        $cw = @($G.lvQueue.View.Columns | ForEach-Object { [math]::Round($_.ActualWidth) })
        Set-ConfigValue 'UI_COLS' ($cw -join ',')
    }
    catch { }
}

# Files page or Encoding page
function Show-Page([string]$which) {
    if ($which -eq 'encoding') { $G.tabPages.SelectedItem = $G.tabEncoding } else { $G.tabPages.SelectedItem = $G.tabFiles }
}

function Start-Gui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $script:G = @{}
    $G.Here = $PSScriptRoot
    $G.Cfg = Get-EffectiveConfig $G.Here
    $raw0 = Get-Config $G.Here
    $script:UiTheme = 'graphite'
    Load-Language ([string]$raw0['UI_LANG'])
    $script:UiScaleMode = 'fixed'
    if ([string]$raw0['UI_SCALE'] -eq 'auto') { $script:UiScaleMode = 'auto'; $script:UiScale = 1.0 }
    else {
        $z = [int](To-Num $raw0['UI_SCALE'])
        if ($UiScales -contains $z) { $script:UiScale = $z / 100.0 }
    }
    $G.UpdateNote = ''
    $script:PrefLang = $G.Cfg['PREF_LANG']
    $G.Profiles = Get-Profiles $G.Here
    $G.Bat = ''
    $main = Join-Path $G.Here 'master_encode.bat'
    if (Test-Path -LiteralPath $main) { $G.Bat = $main }
    else {
        $bats = @(Get-ChildItem -LiteralPath $G.Here -Filter 'master_encode_v*.bat' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($bats.Count -gt 0) { $G.Bat = $bats[0].FullName }
    }
    $vs = Test-VapourSynth $G.Cfg['VSPIPE']
    $G.HasVs = $vs[0]
    $G.VsNote = $vs[1]
    $G.Loading = $false
    $G.Running = $false
    $G.CurIndex = 0
    $G.Engine = $null
    $G.Proc = $null
    $G.JobDir = $null
    $G.JobItems = @()
    $G.Analyse = $false
    $G.Aborted = $false
    $G.DoneAt = $null
    $G.LogChars = 0
    $G.Tick = 0
    $G.StatsDirty = $false
    $G.StDur = 0.0
    $G.StFps = 0.0
    $G.StAudio = 0.0
    $G.StEstimate = ''
    $G.Enc = $null

    $script:AppIcon = New-AppIcon
    $G.Win = Load-Xaml $GuiXaml
    $G.AppliedScale = $script:UiScale
    Restore-Layout
    $G.Win.Add_SizeChanged({ if ($script:UiScaleMode -eq 'auto') { Update-MainScale } })
    $G.Win.Add_Loaded({ Update-MainScale })
    $G.Win.Add_Closed({ Save-Layout; Save-Queue })
    $script:GuiPump = $true
    try {
        Ensure-Bg
        New-Item -ItemType Directory -Force -Path (Join-Path $G.Here 'logs') | Out-Null
        [Av1Bg]::InstallCrashLog((Join-Path $G.Here 'logs\crash.log'))
    }
    catch { }
    # An error inside a button or list handler shows a message instead of closing the window
    $G.Win.Dispatcher.Add_UnhandledException({
            param($s, $e)
            $e.Handled = $true
            Write-LogFile 'errors.log' ($e.Exception.ToString())
            try { Gui-Msg ('Something went wrong: ' + $e.Exception.Message + "`n`nThe window stays open. If this repeats, send a screenshot of this message.") } catch { }
        })
    foreach ($n in @('btnSetup', 'btnSettings', 'txtSub', 'spQueueTools', 'btnAddFiles', 'btnAddFolder', 'btnRemove', 'btnClear', 'btnSelectAll', 'lvQueue', 'txtEmpty',
            'spPlanTools', 'btnAnalyse', 'btnPlan', 'txtPlan',
            'spDetails', 'txtSource', 'txtNote', 'cbProfile', 'txtProfile', 'cbWorkflow', 'cbMode', 'cbGrain', 'cbDenoiser', 'txtDnNote', 'tbCrf', 'cbAudio', 'lbSubs',
            'cbEncoder', 'txtEncoder', 'cbCrop', 'tbPreset', 'tbKeyint', 'tbSvtParams', 'txtParams',
            'cbResize', 'tbTune', 'tbVboost', 'tbFilmGrain', 'btnSaveProfile', 'cbGrainIso', 'chkSceneKf',
            'tabDetails', 'tabVideo', 'tabGrain', 'tabAudio', 'tabSubs', 'tabAdv', 'btnResetVideo', 'btnResetGrain', 'btnResetAdv',
            'spKnlm', 'chkKnlmAuto', 'cbKnlmScale', 'chkDarkTune',
            'btnSubToggle', 'btnSubUp', 'btnSubDown', 'cbSubDefault',
            'tabOutput', 'tabSource', 'tabCommand', 'cbOutWhere', 'dpOutDir', 'btnOutBrowse', 'tbOutDir', 'tbOutName', 'txtOutPreview', 'cbOutExists',
            'btnResetOutput', 'tbSrcInfo', 'btnCopyCmd', 'tbCmd', 'cbCrfPick', 'cbAudFormat', 'spAudOpus', 'cbAudChannels', 'tbAudKbps', 'chkAudNorm', 'txtAudNote', 'btnResetAudio', 'txtProfileSum',
            'txtWarn', 'cbSimpleQ', 'tabPages', 'tabFiles', 'tabEncoding', 'bdStrip', 'txtStrip', 'txtStripPct', 'pbStrip', 'hdrFiles', 'hdrEncoding', 'btnSimple', 'btnHistory', 'btnAbout', 'btnUp', 'btnDown', 'btnOpenOut', 'btnPlayOut', 'btnDiag',
            'btnStop', 'btnAbort', 'btnStart', 'wpGlobal', 'cbCpu', 'cbDone', 'chkApprove', 'txtNow', 'txtPct', 'txtStage', 'pb', 'wpStats',
            'stSize', 'stSizeSub', 'stEta', 'stEtaSub', 'stSpeed', 'stSpeedSub', 'stRate', 'stRateSub', 'stFrames', 'stFramesSub',
            'txtEstimate', 'txtQuality', 'btnReel', 'btnApprove', 'btnHold', 'btnSkip', 'dpDone', 'txtDone', 'btnDoneCancel',
            'chkFollow', 'btnCopyLog', 'btnClearLog', 'btnLogs', 'tbLog', 'txtLive')) {
        $G[$n] = $G.Win.FindName($n)
        if ($null -eq $G[$n]) { throw ('The window layout has no element named ' + $n) }
    }
    $G.Queue = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $G.lvQueue.ItemsSource = $G.Queue

    foreach ($p in $G.Profiles) { [void]$G.cbProfile.Items.Add($p['name']) }
    foreach ($w in $WfNames) { [void]$G.cbWorkflow.Items.Add((T $w)) }
    [void]$G.cbMode.Items.Add((T 'Static  [one strength for the whole film]'))
    [void]$G.cbMode.Items.Add((T 'Adaptive  [per-scene strength from the grain plan]'))
    [void]$G.cbDenoiser.Items.Add((T 'KNLMeansCL  [GPU, VapourSynth]'))
    [void]$G.cbDenoiser.Items.Add((T 'hqdn3d  [CPU, classic]'))
    [void]$G.cbDenoiser.Items.Add((T 'None'))
    [void]$G.cbCrop.Items.Add((T 'Auto  [scans the whole film, keeps every aspect ratio]'))
    [void]$G.cbCrop.Items.Add((T 'Off  [keep the full frame]'))
    [void]$G.cbResize.Items.Add((T 'As the workflow sets it'))
    [void]$G.cbResize.Items.Add((T '1080p  [scale down to 1920 wide]'))
    [void]$G.cbResize.Items.Add((T '720p  [scale down to 1280 wide]'))
    foreach ($q in @('Smaller  [saves the most space]', 'Balanced', 'Better  [more detail, bigger files]')) { [void]$G.cbSimpleQ.Items.Add((T $q)) }
    [void]$G.cbGrainIso.Items.Add((T 'Auto  [from the grain choice]'))
    foreach ($v in $IsoLadder) { [void]$G.cbGrainIso.Items.Add('ISO ' + $v) }
    foreach ($t in @('Next to the source', 'This folder')) { [void]$G.cbOutWhere.Items.Add((T $t)) }
    foreach ($t in @('Add a number  [Film (2).mkv]', 'Skip the file', 'Replace it')) { [void]$G.cbOutExists.Items.Add((T $t)) }
    [void]$G.cbAudFormat.Items.Add((T 'Opus  [small, sounds the same]'))
    [void]$G.cbAudFormat.Items.Add((T 'Keep the original  [copy, e.g. TrueHD Atmos; much bigger]'))
    [void]$G.cbAudChannels.Items.Add((T 'Auto  [7.1 and 6.1 become 5.1, smaller stays as it is]'))
    [void]$G.cbAudChannels.Items.Add((T 'Keep the channels  [7.1 stays 7.1]'))
    [void]$G.cbAudChannels.Items.Add((T 'Stereo  [for TV speakers and headphones]'))
    foreach ($v in $KnlmScales) {
        $lbl = 'x' + ([double]$v).ToString('0.0#', $inv)
        if ($v -eq 1.0) { $lbl += '  [as measured]' } elseif ($v -lt 1.0) { $lbl += '  [gentler, keeps more grain]' } else { $lbl += '  [stronger, smaller files]' }
        [void]$G.cbKnlmScale.Items.Add($lbl)
    }
    $G.Simple = ([string](Get-Config $G.Here)['UI_SIMPLE'] -eq '1')
    $G.TotalSaved = Get-TotalSaved
    $G.RunSaved = 0.0
    $G.LastOut = ''
    Apply-ViewMode
    Fill-Encoders
    foreach ($c in $CpuNames) { [void]$G.cbCpu.Items.Add((T $c)) }
    foreach ($d in $DoneNames) { [void]$G.cbDone.Items.Add((T $d)) }
    $G.cbCpu.SelectedIndex = 0
    $G.cbDone.SelectedIndex = 0
    $G.spDetails.IsEnabled = $false
    $G.btnPlan.IsEnabled = $false
    Update-Empty

    $G.Win.Add_DragOver({ param($s, $e) $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true })
    $G.Win.Add_Drop({
            param($s, $e)
            if ($G.Running) { return }
            $paths = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
            if ($null -ne $paths) { Add-Paths ([string[]]$paths) }
        })
    $G.btnAddFiles.Add_Click({
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Multiselect = $true
            $d.Filter = 'Video|*.mkv;*.mp4;*.m4v;*.m2ts;*.ts;*.mov;*.avi;*.webm|All files|*.*'
            if ($d.ShowDialog() -eq $true) { Add-Paths $d.FileNames }
        })
    $G.btnAddFolder.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-Paths @($d.SelectedPath) }
        })
    $G.btnRemove.Add_Click({
            foreach ($it in @($G.lvQueue.SelectedItems)) { [void]$G.Queue.Remove($it) }
            Update-Empty
        })
    $G.btnClear.Add_Click({ $G.Queue.Clear(); Update-Empty })
    $G.btnSelectAll.Add_Click({ $G.lvQueue.SelectAll() })
    $G.lvQueue.Add_SelectionChanged({ Show-Details })

    $G.cbProfile.Add_SelectionChanged({
            if ($G.Loading -or $null -eq $G.cbProfile.SelectedItem) { return }
            $p = Get-ProfileByName ([string]$G.cbProfile.SelectedItem)
            Edit-Selected { param($it) Apply-ProfileToItem $it $p }
        })
    $G.cbWorkflow.Add_SelectionChanged({
            if ($G.Loading -or $G.cbWorkflow.SelectedIndex -lt 0) { return }
            $wf = $G.cbWorkflow.SelectedIndex + 1
            Edit-Selected {
                param($it)
                $p = Get-ProfileByName $it.Profile
                $wasDefault = ($it.Crf -eq (Get-ProfileCrf $p $it.Workflow))
                $it.Workflow = $wf
                if ($wasDefault) { $it.Crf = Get-ProfileCrf $p $wf }
            }
        })
    $G.cbMode.Add_SelectionChanged({
            if ($G.Loading -or $G.cbMode.SelectedIndex -lt 0) { return }
            $m = $G.cbMode.SelectedIndex + 1
            Edit-Selected { param($it) $it.Mode = $m }
        })
    $G.cbGrain.Add_SelectionChanged({
            if ($G.Loading -or $G.cbGrain.SelectedIndex -lt 0) { return }
            $gi = $G.cbGrain.SelectedIndex
            Edit-Selected { param($it) if ($it.Mode -eq 2) { $it.Grain = $gi + 2 } else { $it.Grain = $gi + 1 } }
        })
    $G.cbDenoiser.Add_SelectionChanged({
            if ($G.Loading -or $G.cbDenoiser.SelectedIndex -lt 0) { return }
            $dn = @('knlm', 'hqdn3d', 'none')[$G.cbDenoiser.SelectedIndex]
            Edit-Selected { param($it) $it.Denoiser = $dn }
        })
    $G.cbEncoder.Add_SelectionChanged({
            if ($G.Loading -or $G.cbEncoder.SelectedIndex -lt 0) { return }
            $id = @($EncoderDefs.Keys)[$G.cbEncoder.SelectedIndex]
            Edit-Selected { param($it) $it.Encoder = $id }
        })
    $G.cbCrop.Add_SelectionChanged({
            if ($G.Loading -or $G.cbCrop.SelectedIndex -lt 0) { return }
            $c = @('auto', 'off')[$G.cbCrop.SelectedIndex]
            Edit-Selected { param($it) $it.Crop = $c }
        })
    $G.tbPreset.Add_TextChanged({
            if ($G.Loading) { return }
            $t = $G.tbPreset.Text.Trim()
            $v = 0
            if ($t -eq '' -or ([int]::TryParse($t, [ref]$v) -and $v -ge -3 -and $v -le 13)) {
                foreach ($it in @($G.lvQueue.SelectedItems)) { $it.Preset = $t }
            }
        })
    $G.cbResize.Add_SelectionChanged({
            if ($G.Loading -or $G.cbResize.SelectedIndex -lt 0) { return }
            $r = @('', '1920', '1280')[$G.cbResize.SelectedIndex]
            Edit-Selected { param($it) $it.Resize = $r }
        })
    # small number fields: blank or a whole number in range, otherwise the value is not taken
    foreach ($fld in @(@('tbTune', 'Tune', 0, 9), @('tbVboost', 'VBoost', 0, 4), @('tbFilmGrain', 'FilmGrain', 0, 50))) {
        $box = $G[$fld[0]]
        $box.Tag = $fld
        $box.Add_TextChanged({
                param($s, $e)
                if ($G.Loading) { return }
                $f2 = $s.Tag
                $t = $s.Text.Trim()
                $v = 0
                if ($t -eq '' -or ([int]::TryParse($t, [ref]$v) -and $v -ge [int]$f2[2] -and $v -le [int]$f2[3])) {
                    foreach ($it in @($G.lvQueue.SelectedItems)) { $it.($f2[1]) = $t }
                }
            })
    }
    $G.btnSaveProfile.Add_Click({ Save-ItemAsProfile })
    $G.cbGrainIso.Add_SelectionChanged({
            if ($G.Loading -or $G.cbGrainIso.SelectedIndex -lt 0) { return }
            $v = ''
            if ($G.cbGrainIso.SelectedIndex -gt 0) { $v = [string]$IsoLadder[$G.cbGrainIso.SelectedIndex - 1] }
            Edit-Selected { param($it) $it.GrainIso = $v }
        })
    $G.chkDarkTune.Add_Click({
            if ($G.Loading) { return }
            $v = '0'
            if ($G.chkDarkTune.IsChecked) { $v = '1' }
            Edit-Selected { param($it) $it.DarkTune = $v }
        })
    $G.chkKnlmAuto.Add_Click({
            if ($G.Loading) { return }
            $v = '0'
            if ($G.chkKnlmAuto.IsChecked) { $v = '1' }
            Edit-Selected { param($it) $it.KnlmAuto = $v }
        })
    $G.cbKnlmScale.Add_SelectionChanged({
            if ($G.Loading -or $G.cbKnlmScale.SelectedIndex -lt 0) { return }
            $v = [double]$KnlmScales[$G.cbKnlmScale.SelectedIndex]
            Edit-Selected { param($it) $it.KnlmScale = $v }
        })
    $G.btnResetVideo.Add_Click({ Reset-Section 'video' })
    $G.btnResetOutput.Add_Click({ Reset-Section 'output' })
    $G.cbCrfPick.Add_SelectionChanged({
            if ($G.Loading -or $G.cbCrfPick.SelectedIndex -lt 0) { return }
            $v = [int]$G.CrfVals[$G.cbCrfPick.SelectedIndex]
            if ($v -lt 0) { $G.tbCrf.Focus(); return }
            Edit-Selected { param($it) $it.Crf = $v }
        })
    $G.cbOutWhere.Add_SelectionChanged({
            if ($G.Loading -or $G.cbOutWhere.SelectedIndex -lt 0) { return }
            if ($G.cbOutWhere.SelectedIndex -eq 0) { Edit-Selected { param($it) $it.OutDir = '' }; return }
            $G.dpOutDir.IsEnabled = $true
            $v = $G.tbOutDir.Text.Trim()
            if ($v -eq '') { $v = [string](Get-Config $G.Here)['DEF_OUT_DIR'] }
            if ($v -eq '') { $G.tbOutDir.Focus(); return }
            Edit-Selected { param($it) $it.OutDir = $v }
        })
    $G.btnOutBrowse.Add_Click({
            Add-Type -AssemblyName System.Windows.Forms
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = 'Folder for the finished files'
            if ($G.tbOutDir.Text.Trim() -ne '' -and (Test-Path -LiteralPath $G.tbOutDir.Text.Trim())) { $d.SelectedPath = $G.tbOutDir.Text.Trim() }
            if ($d.ShowDialog() -eq 'OK') {
                $v = $d.SelectedPath
                Edit-Selected { param($it) $it.OutDir = $v }
            }
        })
    $G.tbOutDir.Add_LostFocus({
            if ($G.Loading -or $G.cbOutWhere.SelectedIndex -ne 1) { return }
            $v = $G.tbOutDir.Text.Trim().Trim('"')
            if ($v -ne '' -and $v -notmatch '^([A-Za-z]:\\|\\\\)') { Gui-Msg 'Output folder: a full path like D:\AV1 or \\NAS\Films.'; return }
            if ($v -match '[*?"<>|%!]') { Gui-Msg 'Output folder: these characters cannot be used: * ? " < > | % !'; return }
            Edit-Selected { param($it) $it.OutDir = $v }
        })
    $G.tbOutName.Add_TextChanged({
            if ($G.Loading) { return }
            $v = $G.tbOutName.Text.Trim()
            if (-not (Test-OutName $v)) { $G.txtOutPreview.Text = 'Not usable: a name cannot be empty or contain \ / : * ? " < > | % ! ^ &'; return }
            foreach ($it in @($G.lvQueue.SelectedItems)) { $it.OutName = $v }
            $first = @($G.lvQueue.SelectedItems)
            if ($first.Count -gt 0) { $G.txtOutPreview.Text = 'Will be: ' + (Get-OutPreview $first[0]) }
        })
    $G.cbOutExists.Add_SelectionChanged({
            if ($G.Loading -or $G.cbOutExists.SelectedIndex -lt 0) { return }
            $v = @('number', 'skip', 'replace')[$G.cbOutExists.SelectedIndex]
            Edit-Selected { param($it) $it.OutExists = $v }
        })
    $G.btnCopyCmd.Add_Click({ try { [System.Windows.Clipboard]::SetText($G.tbCmd.Text) } catch { } })
    $G.tabDetails.Add_SelectionChanged({
            param($sender, $e)
            if ($e.OriginalSource -ne $G.tabDetails) { return }
            $first = @($G.lvQueue.SelectedItems)
            if ($first.Count -gt 0) { Fill-LazyTab $first[0] }
        })
    $G.btnResetAudio.Add_Click({ Reset-Section 'audio' })
    $G.cbAudFormat.Add_SelectionChanged({
            if ($G.Loading -or $G.cbAudFormat.SelectedIndex -lt 0) { return }
            $v = @('opus', 'copy')[$G.cbAudFormat.SelectedIndex]
            Edit-Selected { param($it) $it.AudFormat = $v }
        })
    $G.cbAudChannels.Add_SelectionChanged({
            if ($G.Loading -or $G.cbAudChannels.SelectedIndex -lt 0) { return }
            $v = @('auto', 'keep', 'stereo')[$G.cbAudChannels.SelectedIndex]
            Edit-Selected { param($it) $it.AudChannels = $v }
        })
    $G.chkAudNorm.Add_Click({
            if ($G.Loading) { return }
            $v = '0'
            if ($G.chkAudNorm.IsChecked) { $v = '1' }
            Edit-Selected { param($it) $it.AudNorm = $v }
        })
    $G.tbAudKbps.Add_TextChanged({
            if ($G.Loading) { return }
            $t = $G.tbAudKbps.Text.Trim()
            $n = 0
            if ($t -ne '' -and -not ([int]::TryParse($t, [ref]$n) -and $n -ge 32 -and $n -le 1024)) { return }
            foreach ($it in @($G.lvQueue.SelectedItems)) { $it.AudKbps = $t }
        })
    $G.btnResetGrain.Add_Click({ Reset-Section 'grain' })
    $G.btnResetAdv.Add_Click({ Reset-Section 'adv' })
    $G.chkSceneKf.Add_Click({
            if ($G.Loading) { return }
            $v = '0'
            if ($G.chkSceneKf.IsChecked) { $v = '1' }
            Edit-Selected { param($it) $it.SceneKf = $v }
        })
    $G.cbSimpleQ.Add_SelectionChanged({
            if ($G.Loading -or $G.cbSimpleQ.SelectedIndex -lt 0) { return }
            $qi = $G.cbSimpleQ.SelectedIndex
            Edit-Selected { param($it) $it.Crf = Get-SimpleCrf $it.Workflow $qi }
        })
    $G.btnSimple.Add_Click({
            $G.Simple = -not $G.Simple
            if ($G.Simple) { Set-ConfigValue 'UI_SIMPLE' '1' } else { Set-ConfigValue 'UI_SIMPLE' '0' }
            Apply-ViewMode
        })
    $G.btnHistory.Add_Click({ Show-History })
    $G.bdStrip.Add_MouseLeftButtonUp({ Show-Page 'encoding' })
    $G.btnAbout.Add_Click({ Show-About })
    $G.btnUp.Add_Click({ Move-Selected -1 })
    $G.btnDown.Add_Click({ Move-Selected 1 })
    $G.btnOpenOut.Add_Click({ if ([string]$G.LastOut -ne '' -and (Test-Path -LiteralPath $G.LastOut)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $G.LastOut + '"') } })
    $G.btnPlayOut.Add_Click({ if ([string]$G.LastOut -ne '' -and (Test-Path -LiteralPath $G.LastOut)) { Start-Process -FilePath $G.LastOut } })
    $G.btnDiag.Add_Click({
            try { [System.Windows.Clipboard]::SetText((Get-Diagnostics)); Gui-Msg 'Diagnostics copied. Paste them into a GitHub issue or a message. They contain your settings and folder paths, so look them over first.' }
            catch { Gui-Msg ('Could not copy: ' + $_.Exception.Message) }
        })
    $G.tbKeyint.Add_TextChanged({
            if ($G.Loading) { return }
            $t = $G.tbKeyint.Text.Trim()
            if ($t -eq '' -or $t -match '^-?\d+s?$') { foreach ($it in @($G.lvQueue.SelectedItems)) { $it.Keyint = $t } }
        })
    $G.tbSvtParams.Add_TextChanged({
            if ($G.Loading) { return }
            $t = ($G.tbSvtParams.Text -replace '\s+', ' ').Trim()
            foreach ($it in @($G.lvQueue.SelectedItems)) { $it.SvtParams = $t }
            $first = @($G.lvQueue.SelectedItems)
            if ($first.Count -gt 0) { $G.txtParams.Text = Get-ParamsNote $first[0] }
        })
    $G.tbCrf.Add_TextChanged({
            if ($G.Loading) { return }
            $t = $G.tbCrf.Text.Trim()
            $v = 0
            if ($t -eq '') { $v = 0 }
            elseif (-not ([int]::TryParse($t, [ref]$v) -and $v -ge 1 -and $v -le 63)) { return }
            foreach ($it in @($G.lvQueue.SelectedItems)) { $it.Crf = $v; Update-ItemText $it }
            $G.lvQueue.Items.Refresh()
        })
    $G.cbAudio.Add_SelectionChanged({
            if ($G.Loading -or $G.cbAudio.SelectedIndex -lt 0) { return }
            $a = $G.cbAudio.SelectedIndex
            Edit-Selected { param($it) $it.AudioIdx = $a }
        })
    $G.btnSubToggle.Add_Click({
            Edit-Subs { param($list, $src) if ($list.Contains($src)) { $list.Remove($src) } else { [void]$list.Add($src) } }
        })
    $G.lbSubs.Add_MouseDoubleClick({
            Edit-Subs { param($list, $src) if ($list.Contains($src)) { $list.Remove($src) } else { [void]$list.Add($src) } }
        })
    $G.btnSubUp.Add_Click({
            Edit-Subs { param($list, $src) $i = $list.IndexOf($src); if ($i -gt 0) { $list.RemoveAt($i); $list.Insert($i - 1, $src) } }
        })
    $G.btnSubDown.Add_Click({
            Edit-Subs { param($list, $src) $i = $list.IndexOf($src); if ($i -ge 0 -and $i -lt $list.Count - 1) { $list.RemoveAt($i); $list.Insert($i + 1, $src) } }
        })
    $G.cbSubDefault.Add_SelectionChanged({
            if ($G.Loading -or $G.cbSubDefault.SelectedIndex -lt 0) { return }
            $sel = @($G.lvQueue.SelectedItems)
            if ($sel.Count -ne 1) { return }
            $sel[0].SubDefault = [int]$G.SubDefRows[$G.cbSubDefault.SelectedIndex]
            $keepSel = -1
            if ($G.lbSubs.SelectedIndex -ge 0) { $keepSel = [int]$G.SubRows[$G.lbSubs.SelectedIndex] }
            $G.Loading = $true
            try { Fill-Subs $sel[0] $keepSel $false } finally { $G.Loading = $false }
        })

    $G.btnSettings.Add_Click({ Show-Settings })
    $G.btnSetup.Add_Click({ Show-Setup })
    $G.btnStart.Add_Click({ Start-Engine @($G.Queue) $false })
    $G.btnStop.Add_Click({
            if ($null -ne $G.JobDir) { [System.IO.File]::WriteAllText((Join-Path $G.JobDir 'stop.flag'), 'stop') }
            $G.btnStop.IsEnabled = $false
            Append-Log "---- The queue stops after the current file. ----`r`n"
        })
    $G.btnAbort.Add_Click({
            $ans = Show-Ask 'Abort' "Stop the encoder now?`n`nA video stream that already finished is kept, so the file resumes at audio and mux next time. A half-encoded video is lost." @('Yes', 'No')
            if ($ans -eq 'Yes') { Stop-Engine }
        })
    $G.btnAnalyse.Add_Click({
            $sel = @($G.lvQueue.SelectedItems | Where-Object { $_.Workflow -ne 5 })
            if ($sel.Count -eq 0) { Gui-Msg 'Select one or more films first [anime has no grain plan].'; return }
            $have = @($sel | Where-Object { Test-Path -LiteralPath (Join-Path (Get-PlanDir $_) 'plan.csv') })
            if ($have.Count -gt 0) {
                $ans = Show-Ask 'Analyse plan' ('{0} of the selected files already have a grain plan. Analyse them again? Hand edits are lost [the scene and grain scan is reused, so it is quick].' -f $have.Count) @('Yes', 'No', 'Cancel')
                if ($ans -eq 'Cancel') { return }
                if ($ans -eq 'Yes') {
                    foreach ($it in $have) {
                        $pd = Get-PlanDir $it
                        foreach ($f in @('plan.csv', 'plan_original.csv', 'denoise.cmd', 'grain_timed.tbl')) { Remove-Item -LiteralPath (Join-Path $pd $f) -Force -ErrorAction SilentlyContinue }
                    }
                }
                else { $sel = @($sel | Where-Object { $have -notcontains $_ }) }
            }
            if ($sel.Count -gt 0) { Start-Engine $sel $true }
        })
    $G.btnPlan.Add_Click({
            $sel = @($G.lvQueue.SelectedItems)
            if ($sel.Count -gt 0) { Show-PlanEditor $sel[0] }
        })
    $G.btnDoneCancel.Add_Click({
            $G.DoneAt = $null
            $G.dpDone.Visibility = 'Collapsed'
            if (-not $G.Running) { $G.Timer.Stop() }
            Append-Log "---- Sleep / shut down cancelled. ----`r`n"
        })
    $G.btnCopyLog.Add_Click({ try { [System.Windows.Clipboard]::SetText($G.tbLog.Text) } catch { } })
    $G.btnClearLog.Add_Click({ $G.tbLog.Clear(); $G.LogChars = 0 })
    $G.btnLogs.Add_Click({
            $d = Join-Path $G.Here 'logs'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $d + '"')
        })
    $G.btnReel.Add_Click({ if ($G.ReelPath -and (Test-Path -LiteralPath $G.ReelPath)) { Start-Process -FilePath $G.ReelPath } })
    $G.btnApprove.Add_Click({ Send-Answer 'Y' })
    $G.btnHold.Add_Click({ Send-Answer 'H' })
    $G.btnSkip.Add_Click({ Send-Answer 'N' })

    $G.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $G.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $G.Timer.Add_Tick({ On-Tick })

    $G.Win.Add_ContentRendered({
            Ask-FirstChoice
            Restore-Queue
            $st = Get-ComponentStatus
            if (-not $st.Complete -and [string](Get-Config $G.Here)['SETUP_SHOWN'] -ne '1') {
                Gui-Msg 'Welcome. The encoder can download and set up everything it needs [ffmpeg, VapourSynth, and SVT-AV1 compiled on this PC] into its own folders. Press "Set up everything" in the next window. Your grain tables go into the tables folder.'
                Show-Setup
            }
            elseif (-not (Test-Path -LiteralPath $G.Cfg['SVT_EXE'])) {
                Gui-Msg 'SvtAv1EncApp.exe was not found. Use Setup and updates to build it, or set its path in Settings.'
            }
            Check-UpdatesQuietly
        })
    $G.Win.Add_Closing({
            param($s, $e)
            if (-not $G.Running) { return }
            if ($null -ne $G.Engine) { Gui-Msg 'The encode keeps running in its console window. Close that window to stop it.'; return }
            $ans = Show-Ask 'RazAV1' 'The encoder runs inside this window. Closing it stops the encode. Abort and close?' @('Yes', 'No')
            if ($ans -eq 'Yes') { Stop-Engine; if ($null -ne $G.Proc) { $G.Proc.CloseLog() } }
            else { $e.Cancel = $true }
        })
    [void]$G.Win.ShowDialog()
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
try {
    if (@('analyze', 'summary', 'build', 'lookup', 'probes') -contains $Mode) {
        if ($WorkDir -eq '') { throw '-WorkDir is required.' }
        if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
        $planCsv = Join-Path $WorkDir 'plan.csv'
        $cutsFile = Join-Path $WorkDir 'cuts.txt'
    }
    switch ($Mode) {
        'analyze'   { Invoke-Analyze }
        'summary'   { Invoke-Summary }
        'build'     { Invoke-Build }
        'lookup'    { Invoke-Lookup }
        'table'     { Invoke-Table }
        'tables'    { Invoke-Tables }
        'keyframes' { Invoke-Keyframes }
        'srcinfo'   { Invoke-SrcInfo }
        'audiolist' { Invoke-AudioList }
        'probes'    { Invoke-Probes }
        'estimate'  { Invoke-Estimate }
        'vpy'       { Invoke-Vpy }
        'vscheck'   { Invoke-VsCheck }
        'gputest'   { Invoke-GpuTest }
        'calibrate' { Invoke-Calibrate }
        'quality'   { Invoke-Quality }
        'watch'     { Invoke-Watch }
        'notify'    { Invoke-Notify }
        'power'     { Invoke-Power }
        'sendto'    { Invoke-SendTo }
        'gui'       { Start-Gui }
    }
}
catch {
    if ($Mode -eq 'gui') {
        try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot 'logs\crash.log'), ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  WINDOW  ' + $_.Exception.ToString() + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n")) } catch { }
        try {
            Add-Type -AssemblyName PresentationFramework
            $why = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($null -ne $inner) { $why += "`n`n" + $inner.Message; $inner = $inner.InnerException }
            [void][System.Windows.MessageBox]::Show(('The window could not start: ' + $why + "`n`n" + $_.InvocationInfo.PositionMessage + "`n`nCtrl+C copies this message."), 'RazAV1')
        }
        catch { }
    }
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
}
