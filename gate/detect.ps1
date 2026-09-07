# Stack detection by file presence. Dot-sourced by check.ps1 and install.ps1.
#
# A stack with no marker file DOES NOT EXIST: it costs nothing and is never
# mentioned. A stack whose marker is present but whose linter config is missing
# is reported once, clearly, and the run continues.

# Every stack this gate knows about and the file that proves it exists.
# Used for provenance output: `check.ps1 -Why` names the marker behind every
# phase that ran and every stack that does not exist here.
$script:KnownMarkers = [ordered]@{
    go     = 'go.mod'
    web    = 'package.json + vite/next/webpack/rollup.config.*'
    godot  = 'project.godot'
    proto  = 'buf.yaml'
    python = 'pyproject.toml or requirements.txt'
    rust   = 'Cargo.toml'
    dotnet = '*.csproj'
    custom = 'qgate.json with a non-empty "checks" array'
}

# Directories that never hold a project we own.
$script:SkipDirs = @('node_modules', '.git', 'vendor', 'dist', 'build', '.cache', '.venv', 'target', 'bin', 'obj')

function Get-RepoRoot([string]$StartDir) {
    $top = (& git -C $StartDir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path ($top -replace '/', '\')).Path }
    return (Resolve-Path $StartDir).Path
}

# What a repo ignores is not part of that repo. The list above cannot enumerate it:
# Claude Code checks agent worktrees out under .claude/worktrees/<agent>/, and that
# nested go.mod -- an older commit of this same repo -- was detected as a second Go
# stack. `qgate outdated` then blamed the root module for dependencies that were only
# stale inside the worktree, and a -All run would have built, linted and tested it.
# So the repo's own ignore rules decide. Asked WITHOUT --no-index on purpose: a
# tracked file belongs to the repo even when a pattern matches it, and the default
# already answers that way.
function Test-GitIgnored([string]$Root, [string]$Path) {
    $prev = $global:LASTEXITCODE
    & git -C $Root check-ignore -q -- $Path 2>$null
    # 0 = ignored. 1 = not ignored. 128 = no git, or $Root is not a repo -- which is
    # not evidence of anything, so the marker is kept and detection works as before.
    $ignored = ($LASTEXITCODE -eq 0)
    # Put back what the caller had. `check-ignore` answering "not ignored" is exit 1,
    # and check.ps1's Phase fails a phase on a non-zero $LASTEXITCODE -- so leaking it
    # would fail the very phase this function is called to filter.
    $global:LASTEXITCODE = $prev
    return $ignored
}

# The same question asked per DIRECTORY and remembered. The Godot runner collects
# every *.gd in the project with Get-ChildItem -Recurse, and a project holds hundreds
# of them: one git process per file is not a filter, it is a second build step.
# Directories are far fewer, an ignored checkout IS a directory, and check-ignore
# answers for one -- measured, including a directory several levels inside the ignored
# one, and exit 1 for the repo root itself.
#
# Batching through `check-ignore --stdin` was tried and rejected: git C-quotes any
# path containing a backslash on the way back out (`"C:\\dir\\f.gd"`, plus a trailing
# CR), and `-z`, which would return them raw, switches the INPUT to NUL-separated too,
# which a PowerShell pipeline does not produce. Exit codes need no parsing at all.
#
# Granularity is the directory, so a .gitignore rule naming an individual file inside
# a directory that is otherwise tracked is NOT honoured here. That is the price of not
# spawning git per file; the case this exists for -- a whole nested checkout -- is a
# directory.
$script:IgnoredDirs = @{}
function Test-GitIgnoredDir([string]$Root, [string]$Dir) {
    if (-not $script:IgnoredDirs.ContainsKey($Dir)) {
        $script:IgnoredDirs[$Dir] = Test-GitIgnored $Root $Dir
    }
    return $script:IgnoredDirs[$Dir]
}

function Find-Marker([string]$Root, [string[]]$Names, [int]$Depth = 3) {
    Get-ChildItem -Path $Root -Recurse -Depth $Depth -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            # -like, not -contains: the .NET marker is a PATTERN (*.csproj), because a
            # C# project file is named after the project. A literal name has no wildcard
            # character in it, so every other stack keeps matching exactly as before.
            $f = $_
            ($Names | Where-Object { $f.Name -like $_ }) -and
            ($_.FullName.Substring($Root.Length) -split '[\\/]' | Where-Object { $script:SkipDirs -contains $_ }).Count -eq 0 -and
            # Last: it spawns a process, and the cheap tests above have already cut
            # the candidates down to the handful of real marker files.
            -not (Test-GitIgnored $Root $_.FullName)
        }
}

# Stable short key for a path: names per-repo temp files and build directories so
# two repos (or two agents in different worktrees) never share one.
function Get-PathKey([string]$Text) {
    [BitConverter]::ToString(
        [Security.Cryptography.MD5]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))).Replace('-', '')
}

# The Godot editor binary is almost never on PATH on Windows (no installer, no
# stable name), so GODOT_BIN is the primary answer and PATH the fallback.
# A tool binary built by an older Go than the module targets fails, but never with
# the one fact that explains it. golangci-lint refuses to load its own config
# ("the Go language version used to build golangci-lint is lower than the targeted
# Go version"), and govulncheck blames every file in the repo plus four lines inside
# the standard library -- fifteen lines pointing at the user's own code when the whole
# truth is "this binary is older than the toolchain". Both are one `go install` away
# and neither says so. The gate's own full level is what pushes people to bump the go
# directive in the first place (govulncheck reports stdlib CVEs), so the gate owes
# them the reason for what the bump then breaks.
#
# Compared on major.minor, the Go LANGUAGE version and the same granularity
# golangci-lint itself compares on: a tool built with go1.27.0 against a module
# targeting go1.27.1 is fine and must not be reported.
function Get-GoBuiltWith([string]$Exe) {
    # `go version -m <exe>` -> first line "C:\...\govulncheck.exe: go1.27.1", read out
    # of the binary's own build info. The tools' own --version output cannot be used
    # for this: `govulncheck -version` prints a `Go:` line that is the toolchain
    # ACTIVE IN THE CURRENT DIRECTORY, not the one that built the binary -- the same
    # binary reports go1.26.2 from a plain directory and go1.27.1 inside a module
    # whose go directive pulls a newer toolchain through GOTOOLCHAIN=auto. Reading it
    # would have compared the module against itself and never fired.
    $src = (Get-Command $Exe -ErrorAction SilentlyContinue).Source
    if (-not $src) { return }
    $first = (& go version -m $src 2>$null | Select-Object -First 1)
    # Full version, patch included: `qgate where` exists to show exactly which binary
    # is in use, and a pinned qgate.json is a patch-level statement. The comparison
    # below truncates to major.minor itself.
    if ($first -match ':\s+go(\d+\.\d+(?:\.\d+)?)') { $Matches[1] }
}

function Test-GoToolStale([string]$Exe, [string]$ModuleGo, [string]$Install) {
    if (-not $ModuleGo) { return }
    $built = Get-GoBuiltWith $Exe
    # Unreadable build info is not evidence of anything; the phase runs as before.
    if (-not $built) { return }
    # major.minor on both sides: a go1.27.0 binary against a `go 1.27.1` module is
    # fine, and reporting it would be a false verdict on every patch release.
    $lang = { param($v) (($v -split '\.')[0, 1] -join '.') }
    if ([version](& $lang $built) -ge [version](& $lang $ModuleGo)) { return }
    "$Exe was built with go$built, this module targets go$ModuleGo -- rebuild it: $Install"
}

function Get-GodotBin {
    if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { return $env:GODOT_BIN }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# --- repo-declared custom checks -------------------------------------------
# qgate.json may carry a "checks" array: commands this repository wants run as part
# of the gate. Parsed here rather than in check.ps1 because the presence of a
# non-empty array is what creates the `custom` stack, and detection is what answers
# that question.
#
# Returns $null when nothing is declared -- no qgate.json, no `checks` key, or an
# empty array -- so a repo without one simply has no custom stack. Otherwise an
# object with .Checks (Name/Run/Level/TimeoutSec, in file order) and .Error: the
# FIRST reason the array is unusable, or ''. A malformed array is never silently
# ignored -- a check nobody notices reads exactly like a check that passes.
function Get-CustomChecks([string]$Root) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    # Same rule the tool pins already follow: a qgate.json that is not JSON declares
    # nothing. It cannot declare a malformed `checks` either -- there is no `checks`
    # to read -- so this is absence, not a verdict.
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $json.PSObject.Properties.Name -notcontains 'checks') { return $null }
    $bad = { param($m) [pscustomobject]@{ Checks = @(); Error = $m } }
    $raw = $json.checks
    if ($raw -isnot [Array]) { return (& $bad 'qgate.json "checks" must be an array') }
    if ($raw.Count -eq 0) { return $null }

    $checks = @()
    for ($i = 0; $i -lt $raw.Count; $i++) {
        $c = $raw[$i]
        $n = $i + 1
        # A missing name, a name that is not a string and an element that is not an
        # object at all all land here, which is the honest answer: none of them names
        # a check. Lowercase because the name is printed in [PASS]/[FAIL] lines beside
        # phase names the gate itself owns.
        $name = [string]$c.name
        if ($name -cnotmatch '^[a-z0-9][a-z0-9._-]*$') {
            return (& $bad "qgate.json check #${n} has no usable name ('$name') -- must match ^[a-z0-9][a-z0-9._-]*$")
        }
        if ($checks.Name -contains $name) { return (& $bad "qgate.json declares two checks named '$name'") }
        $run = $c.run
        if ($run -isnot [string] -or -not $run.Trim()) {
            return (& $bad "qgate.json check '$name' needs a non-empty `"run`" string")
        }
        $level = if ($null -eq $c.level) { 'full' } else { [string]$c.level }
        if ($level -cnotin 'fast', 'full') {
            return (& $bad "qgate.json check '$name' has level '$level' -- must be fast or full")
        }
        $sec = 600
        if ($null -ne $c.timeoutSec) {
            if (($c.timeoutSec -is [string]) -or (($c.timeoutSec -as [int]) -le 0)) {
                return (& $bad "qgate.json check '$name' has timeoutSec '$($c.timeoutSec)' -- must be a positive number of seconds")
            }
            $sec = [int]$c.timeoutSec
        }
        $checks += [pscustomobject]@{ Name = $name; Run = $run; Level = $level; TimeoutSec = $sec }
    }
    [pscustomobject]@{ Checks = $checks; Error = '' }
}

# Where this machine remembers which repositories may run their own commands. Per
# user, never inside the repository: a trust marker a clone can carry is not trust.
function Get-TrustStore {
    if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'qgate\trusted.json' }
    else { Join-Path $HOME '.config/qgate/trusted.json' }
}

function Get-TrustKey([string]$Root) { (Resolve-Path $Root).Path.TrimEnd('\', '/') }

# The checks, re-serialised deterministically: sorted by name, the four known fields
# only, no whitespace. So reformatting qgate.json, reordering the array or adding a
# comment field does not cost the user their trust, while any change to a name, a
# command, a level or a timeout does -- which is the only thing the hash is for.
# Sorted ORDINALLY: a culture-aware sort of '.', '-' and '_' is not the same order on
# every machine, and a hash that depends on the locale is not a hash.
function Get-ChecksHash($Checks) {
    $byName = @{}
    foreach ($c in $Checks) { $byName[$c.Name] = $c }
    $names = [string[]]@($byName.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $canon = '[' + (@($names | ForEach-Object {
                $c = $byName[$_]
                '{"name":' + (ConvertTo-Json $c.Name -Compress) + ',"run":' + (ConvertTo-Json $c.Run -Compress) +
                ',"level":' + (ConvertTo-Json $c.Level -Compress) + ',"timeoutSec":' + $c.TimeoutSec + '}'
            }) -join ',') + ']'
    [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canon))).Replace('-', '').ToLowerInvariant()
}

function Get-TrustedHash([string]$Root) {
    $f = Get-TrustStore
    if (-not (Test-Path $f)) { return $null }
    $j = try { Get-Content $f -Raw | ConvertFrom-Json } catch { $null }
    if (-not $j) { return $null }
    # Property lookup is case-insensitive, which is what a Windows path needs.
    $j.(Get-TrustKey $Root)
}

function Test-ChecksTrusted([string]$Root, $Checks) {
    $have = Get-TrustedHash $Root
    [bool]($have -and $have -eq (Get-ChecksHash $Checks))
}

function Test-AnyFile([string]$Dir, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if (Get-ChildItem -Path $Dir -Filter $p -File -Force -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Returns one object per detected stack:
#   Stack       go | web | godot | proto | python | rust
#   Dir         absolute directory holding the marker
#   Rel         path relative to the repo root, forward slashes, '' for the root
#   Marker      the file whose presence created this phase (provenance)
#   Implemented $true only for stacks this gate actually checks
#   Warn        one-line message about missing tooling/config, or ''
function Get-Stacks([string]$Root) {
    $stacks = @()
    $rel = {
        param($d)
        $r = $d.Substring($Root.Length).Trim('\').Replace('\', '/')
        $r
    }

    foreach ($m in Find-Marker $Root @('go.mod')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Test-Path (Join-Path $dir '.golangci.yml')) -and -not (Test-Path (Join-Path $dir '.golangci.yaml'))) {
            $warn = 'no .golangci.yml -- running golangci-lint on its defaults; copy templates/.golangci.yml'
        }
        $stacks += [pscustomobject]@{ Stack = 'go'; Dir = $dir; Rel = (& $rel $dir); Marker = 'go.mod'; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('package.json')) {
        $dir = $m.DirectoryName
        $bundler = @('vite.config.*', 'next.config.*', 'webpack.config.*', 'rollup.config.*') |
            Where-Object { Test-AnyFile $dir @($_) } | Select-Object -First 1
        if (-not $bundler) { continue }
        $warn = ''
        if (-not (Test-Path (Join-Path $dir 'node_modules'))) {
            $warn = 'node_modules missing -- run npm ci; the gate cannot verify this stack until then'
        }
        $stacks += [pscustomobject]@{ Stack = 'web'; Dir = $dir; Rel = (& $rel $dir); Marker = "package.json + $bundler"; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('Cargo.toml')) {
        $dir = $m.DirectoryName
        # A workspace member has no [package] of its own to build; the workspace
        # root already covers it.
        if ((Get-Content $m.FullName -Raw) -notmatch '(?m)^\s*\[package\]') { continue }
        $warn = ''
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            $warn = 'cargo not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'rust'; Dir = $dir; Rel = (& $rel $dir); Marker = 'Cargo.toml'; Implemented = $true; Warn = $warn }
    }

    # One stack per PROJECT FILE, not per directory: a .NET repo carries several
    # (root plus tools/*, demos/*, tests/*) and every one of them builds on its own.
    # No .sln handling -- these repos have none, and the csproj is what the SDK takes.
    foreach ($m in Find-Marker $Root @('*.csproj')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            $warn = 'dotnet not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'dotnet'; Dir = $dir; Rel = (& $rel $dir); Marker = $m.Name; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('buf.yaml')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Get-Command buf -ErrorAction SilentlyContinue)) {
            $warn = 'buf not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'proto'; Dir = $dir; Rel = (& $rel $dir); Marker = 'buf.yaml'; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('project.godot')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Get-GodotBin)) {
            $warn = 'no Godot binary -- set GODOT_BIN; the gate cannot verify this stack until then'
        }
        $stacks += [pscustomobject]@{ Stack = 'godot'; Dir = $dir; Rel = (& $rel $dir); Marker = 'project.godot'; Implemented = $true; Warn = $warn }
    }

    # The one stack whose marker is not a file the language brought with it: the
    # repository declares it. Root only -- qgate.json is the gate's own config file
    # and the gate has exactly one per repository. A malformed `checks` still creates
    # the stack, because the alternative is a broken config that reads as absence.
    if (Get-CustomChecks $Root) {
        $stacks += [pscustomobject]@{ Stack = 'custom'; Dir = $Root; Rel = ''; Marker = 'qgate.json'; Implemented = $true; Warn = '' }
    }

    # Declared, detected, NOT checked. Reported so nobody mistakes silence for a
    # passing stack. Implement one only after it has been run for real.
    $todo = @{ 'pyproject.toml' = 'python'; 'requirements.txt' = 'python' }
    foreach ($m in Find-Marker $Root ($todo.Keys)) {
        $dir = $m.DirectoryName
        $name = $todo[$m.Name]
        if ($stacks | Where-Object { $_.Stack -eq $name -and $_.Dir -eq $dir }) { continue }
        $stacks += [pscustomobject]@{ Stack = $name; Dir = $dir; Rel = (& $rel $dir); Marker = $m.Name; Implemented = $false; Warn = 'not implemented -- nothing is checked here' }
    }

    $stacks
}
