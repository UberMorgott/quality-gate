# --- smoke: launch the app a qgate.json check declares, drive it, read its log ------
# Dot-sourced by check.ps1; runs inside the custom stack, so it inherits the whole trust
# model (`qgate trust` hashes the smoke object like any `run`), the full level and the
# leak report. The project supplies the app and any driver that pushes it further
# (a BepInEx plugin, a test flag); the gate supplies the harness:
#
#   launch exe+args (env, cwd) -> per stage: wait for `ready` in the log, hold holdSec,
#   screenshot the main window (optional baseline compare) -> CloseMainWindow, then kill
#   -> FAIL on error lines, on any error repeating more than repeatLimit times, on a
#   leaked process, on a stage never reached.
#
# Isolation: every run gets a fresh data dir, handed to the app as `{dataDir}` (args,
# env, cwd, log, baseline) and as QGATE_DATA_DIR. The app has to USE it -- measured on
# Windows 11 26100: with APPDATA, LOCALAPPDATA and USERPROFILE all pointed elsewhere,
# SHGetKnownFolderPath(LocalAppDataLow) -- Unity's persistentDataPath -- still returned
# the real C:\Users\<me>\AppData\LocalLow. So the gate does not pretend env overrides
# isolate anything; an app that writes user data must take `{dataDir}` on its command line.
#
# Windows only: window capture and the leak report are Win32.

$script:SmokeDefaultErrors = '\w+Exception:|^\[(Error|Fatal)\s*:|^\s*(ERROR|FATAL)\b|Unhandled exception'
# A stack frame: `  at Ns.Type.Method (...)` (Mono/.NET) or `Ns.Type.Method () (at ...)` (Unity).
$script:SmokeFrame = '^\s*(at\s+)?[\w.<>`+\[\],]+[.:][\w<>`]+\s?\('

# The app keeps its log open for writing; a plain read would fail on the share mode.
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try { ([IO.StreamReader]::new($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

# Error lines grouped by message + first stack frame, digits and addresses folded, so a
# per-frame exception is ONE finding with a count instead of 3700 lines. ignorePattern
# drops a group only while it stays under repeatLimit: a benign error once is noise, the
# same error every frame is a stalled Update loop.
# ponytail: key = message + first frame within 3 lines; distinct call sites sharing both collapse.
function Get-SmokeErrors([string]$Text, $S) {
    $errPat = if ($S.errorPattern) { $S.errorPattern } else { $script:SmokeDefaultErrors }
    $limit = if ($null -ne $S.repeatLimit) { [int]$S.repeatLimit } else { 10 }
    $lines = $Text -split "`r?`n"
    $groups = [ordered]@{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cnotmatch $errPat) { continue }
        $frame = ''
        for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
            if ($lines[$j] -cmatch $script:SmokeFrame) { $frame = $lines[$j].Trim(); break }
        }
        $sample = $lines[$i].Trim() + $(if ($frame) { " | $frame" })
        $key = $sample -replace '0x[0-9a-fA-F]+|\d+', '#'
        if ($groups.Contains($key)) { $groups[$key].Count++ }
        else { $groups[$key] = [pscustomobject]@{ Count = 1; Sample = $sample } }
    }
    @($groups.Values | Where-Object { $_.Count -gt $limit -or -not ($S.ignorePattern -and $_.Sample -cmatch $S.ignorePattern) } |
            Sort-Object Count -Descending | ForEach-Object { "  x$($_.Count)$(if ($_.Count -gt $limit) { " [repeats > $limit]" }) $($_.Sample)" })
}

function Initialize-SmokeNative {
    if ('QgateNative' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing
    # No System.Drawing types in here: referencing them from Add-Type needs assemblies
    # pwsh does not ship as reference assemblies. Bitmaps are handled from PowerShell.
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class QgateNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    public static long CountDiff(byte[] a, byte[] b, int thr) {
        long n = 0;
        for (int i = 0; i + 3 < a.Length; i += 4)
            if (Math.Abs(a[i] - b[i]) > thr || Math.Abs(a[i + 1] - b[i + 1]) > thr || Math.Abs(a[i + 2] - b[i + 2]) > thr) n++;
        return n;
    }
}
'@
}

# The launched process and whatever it started (a launcher's real game), with a window.
function Get-SmokeWindows($P, [datetime]$NotBefore) {
    @(@($P.Id) + @(Get-Descendants $P.Id $NotBefore | ForEach-Object ProcessId) | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue } | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
}

# Returns '' on success, else why there is no image.
function Save-SmokeShot([IntPtr]$Hwnd, [string]$Path) {
    $r = [QgateNative+RECT]::new()
    if (-not [QgateNative]::GetWindowRect($Hwnd, [ref]$r) -or $r.R -le $r.L -or $r.B -le $r.T) { return 'the window has no area' }
    $bmp = [Drawing.Bitmap]::new($r.R - $r.L, $r.B - $r.T)
    try {
        $g = [Drawing.Graphics]::FromImage($bmp)
        $dc = $g.GetHdc()
        # 2 = PW_RENDERFULLCONTENT: hardware-accelerated windows (games) can come out black without it.
        # PrintWindow, not a screen copy: the window is captured even when covered or off-screen.
        $ok = [QgateNative]::PrintWindow($Hwnd, $dc, 2)
        $g.ReleaseHdc($dc); $g.Dispose()
        if (-not $ok) { return 'PrintWindow failed' }
        $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
        ''
    } finally { $bmp.Dispose() }
}

# Fraction of pixels whose R, G or B differs by more than 16; -1 when the sizes differ.
# ponytail: plain per-pixel ratio -- a 1px layout shift of a whole panel fails it; switch to
# a perceptual/SSIM compare if baselines turn out flaky.
function Get-ImageDiff([string]$A, [string]$B) {
    $ia = [Drawing.Bitmap]::new($A); $ib = [Drawing.Bitmap]::new($B)
    try {
        if ($ia.Width -ne $ib.Width -or $ia.Height -ne $ib.Height) { return -1 }
        $bytes = foreach ($im in $ia, $ib) {
            $d = $im.LockBits([Drawing.Rectangle]::new(0, 0, $im.Width, $im.Height), 'ReadOnly', 'Format32bppArgb')
            $buf = [byte[]]::new($d.Stride * $d.Height)
            [Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $buf.Length)
            $im.UnlockBits($d)
            , $buf
        }
        [QgateNative]::CountDiff($bytes[0], $bytes[1], 16) / ($ia.Width * $ia.Height)
    } finally { $ia.Dispose(); $ib.Dispose() }
}

function Invoke-SmokeCheck($c) {
    if (-not $IsWindows) { $script:Lines += "[SKIP] $($c.Name) -- smoke checks are Windows-only"; $script:CustomDeferred = $true; return }
    Initialize-SmokeNative
    $s = $c.Smoke
    # One run dir per repo+check, wiped at the start of the next run: screenshots and the
    # log stay readable after a red run, and nothing piles up.
    # ponytail: two concurrent smoke runs of one check in one repo share this dir; a GUI app
    # smoked twice at once would fight over more than a directory anyway.
    $runDir = Join-Path ([IO.Path]::GetTempPath()) "qgate-smoke\$(Get-PathKey "$Root|$($c.Name)")"
    Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
    $data = Join-Path $runDir 'data'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $x = { param($v) ([string]$v).Replace('{dataDir}', $data) }
    $abs = { param($v) [IO.Path]::GetFullPath($v, $Root) }

    $exe = & $x $s.exe
    if (Test-Path -LiteralPath (& $abs $exe) -PathType Leaf) { $exe = & $abs $exe }  # else: found on PATH
    $cwd = if ($s.cwd) { & $abs (& $x $s.cwd) } else { $Root }
    $out = Join-Path $runDir 'stdout.log'
    $log = if ($s.log) { & $abs (& $x $s.log) } else { $out }
    # A log left over from the last run would match the ready pattern before the app started.
    if ($s.log -and (Test-Path -LiteralPath $log)) {
        try { Move-Item -LiteralPath $log -Destination "$log.prev" -Force -ErrorAction Stop }
        catch { Fail "$($c.Name) -- cannot move the old log aside, is the app already running? $($_.Exception.Message)"; return }
    }
    # Windows command-line quoting: backslashes before a quote are doubled, then the quote escaped.
    $argLine = @($s.args | Where-Object { $null -ne $_ } | ForEach-Object {
            $a = & $x $_
            if ($a -eq '' -or $a -match '[\s"]') { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $a }
        }) -join ' '
    $envSet = [ordered]@{ QGATE_DATA_DIR = $data }
    if ($s.env) { foreach ($e in $s.env.PSObject.Properties) { $envSet[$e.Name] = & $x $e.Value } }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $launchedAt = Get-Date
    $prior = @{}
    try {
        # Set in this process for the child to inherit, then put back.
        foreach ($k in $envSet.Keys) { $prior[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envSet[$k]) }
        $sp = @{ FilePath = $exe; WorkingDirectory = $cwd; NoNewWindow = $true; PassThru = $true
            RedirectStandardOutput = $out; RedirectStandardError = (Join-Path $runDir 'stderr.log') }
        if ($argLine) { $sp.ArgumentList = $argLine }
        $p = Start-Process @sp
        $null = $p.Handle  # keeps ExitCode readable after exit
    } catch {
        Fail "$($c.Name) -- could not launch '$exe': $($_.Exception.Message)"; return
    } finally { foreach ($k in $prior.Keys) { [Environment]::SetEnvironmentVariable($k, $prior[$k]) } }

    $deadline = $launchedAt.AddSeconds($c.TimeoutSec)
    $report = @(); $findings = @(); $shots = 0; $timedOut = $false; $pos = 0
    for ($si = 0; $si -lt $s.stages.Count; $si++) {
        $st = $s.stages[$si]
        $re = [regex]$st.ready
        while ($true) {
            $exited = $p.HasExited  # read BEFORE the log: after exit the log is complete
            $txt = Read-SharedText $log
            $m = $re.Match($txt, [Math]::Min($pos, $txt.Length))
            if ($m.Success -or $exited) { break }
            if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $m.Success) {
            $findings += if ($timedOut) { "stage '$($st.name)': ready pattern /$($st.ready)/ never matched in $log" }
            else { "stage '$($st.name)': the app exited (code $($p.ExitCode)) before /$($st.ready)/ matched in $log" }
            break
        }
        $pos = $m.Index + $m.Length
        $line = "stage $($st.name): ready at $($sw.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s"
        $until = (Get-Date).AddSeconds([double]$st.holdSec)
        while ((Get-Date) -lt $until -and -not $p.HasExited -and -not $timedOut) {
            if ((Get-Date) -gt $deadline) { $timedOut = $true } else { Start-Sleep -Milliseconds 250 }
        }
        if ($timedOut) { $findings += "stage '$($st.name)': its hold ran past the timeout"; break }
        if ($p.HasExited) {
            # After the LAST stage, exiting is how a driver that ends the run says it is done.
            if ($si -lt $s.stages.Count - 1) { $findings += "stage '$($st.name)': the app exited (code $($p.ExitCode)) during its $($st.holdSec)s hold" }
            else { $report += "$line, then the app exited on its own (code $($p.ExitCode))" }
            break
        }
        $win = @(Get-SmokeWindows $p $launchedAt) | Select-Object -First 1
        $png = Join-Path $runDir "$($st.name -replace '[^\w.-]', '_').png"
        $why = if ($win) { Save-SmokeShot $win.MainWindowHandle $png } else { 'no main window' }
        if (-not $why) { $shots++; $line += ", screenshot $png" } else { $line += ", no screenshot ($why)" }
        if ($st.baseline) {
            $base = & $abs (& $x $st.baseline)
            $tol = if ($null -ne $st.tolerance) { [double]$st.tolerance } else { 0.01 }
            if ($why) { $findings += "stage '$($st.name)': baseline declared but no screenshot ($why)" }
            elseif (-not (Test-Path -LiteralPath $base)) { $findings += "stage '$($st.name)': no baseline at $base -- to accept this screen: Copy-Item '$png' '$base'" }
            else {
                $d = Get-ImageDiff $png $base
                $pct = { param($v) ($v * 100).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%' }
                if ($d -lt 0) { $findings += "stage '$($st.name)': screenshot size differs from baseline $base" }
                elseif ($d -gt $tol) { $findings += "stage '$($st.name)': screenshot differs from baseline by $(& $pct $d) (tolerance $(& $pct $tol)) -- $base" }
                else { $line += ", baseline diff $(& $pct $d)" }
            }
        }
        $report += $line
    }

    # Graceful first -- a game saves and releases its files on WM_CLOSE -- then the tree.
    if (-not $p.HasExited) {
        $wins = @(Get-SmokeWindows $p $launchedAt)
        foreach ($w in $wins) { [void]$w.CloseMainWindow() }
        $closeSec = if ($null -ne $s.closeSec) { [int]$s.closeSec } else { 15 }
        if (-not $wins -or -not $p.WaitForExit($closeSec * 1000)) {
            $report += if ($wins) { "did not close within ${closeSec}s of CloseMainWindow -- killed" } else { 'no main window to close -- killed' }
            try { $p.Kill($true) } catch { }
            [void]$p.WaitForExit(5000)
        }
    }
    $sw.Stop()
    $leak = Get-LeakReport $p.Id $launchedAt $c.Name
    $errs = @(Get-SmokeErrors (Read-SharedText $log) $s)
    if ($errs) { $findings += "$($errs.Count) distinct error line(s) in ${log}:"; $findings += @($errs | Select-Object -First 15) }
    if ($log -ne $out) { Copy-Item -LiteralPath $log -Destination $runDir -ErrorAction SilentlyContinue }

    $name = if ($timedOut) { "$($c.Name) -- timeout after $($c.TimeoutSec)s" }
    elseif ($shots) { "$($c.Name) -- $shots screenshot(s) in $runDir" } else { $c.Name }
    Phase $name {
        $findings
        $report
        if ($leak) { $leak }
        "run dir: $runDir (data dir, stdout/stderr, log copy, screenshots)"
        if ($findings -or $leak) { $global:LASTEXITCODE = 1 }
    } -Elapsed $sw.Elapsed.TotalSeconds
}
