# Stack detection by file presence. Dot-sourced by check.ps1 and install.ps1.
#
# A stack with no marker file DOES NOT EXIST: it costs nothing and is never
# mentioned. A stack whose marker is present but whose linter config is missing
# is reported once, clearly, and the run continues.

# Every git question the gate asks names its directory with `-C`, so the git
# environment it INHERITED can only ever be wrong. A hook is the case that
# proves it: git exports GIT_DIR and leaves GIT_WORK_TREE unset, and under those
# two variables git stops discovering the repository and treats the CURRENT
# directory as the work tree root. Measured on git 2.53, in a linked worktree,
# from `<worktree>/shared`: `rev-parse --show-toplevel` answers `.../shared`
# with GIT_DIR set and `.../` (the real root) without it, and
# `--path-format=absolute` does NOT fix it -- it makes the wrong answer absolute.
# That wrong root then became buf's baseline `<worktree>/shared/.git`, a path
# that does not exist ("could not clone ... exit status 3"), and every other
# `git -C $top` in the same run inherited it. Cleared once here, for the whole
# process, because this file is the prologue of every entry point.
#
# GIT_INDEX_FILE is deliberately KEPT: git exports it as an absolute path, it
# stays correct without GIT_DIR, and check.ps1 reads its presence as the signal
# that this run is inside a commit.
$env:GIT_DIR = $null
$env:GIT_WORK_TREE = $null

# Every stack this gate knows about and the file that proves it exists.
# Used for provenance output: `check.ps1 -Why` names the marker behind every
# phase that ran and every stack that does not exist here.
$script:KnownMarkers = [ordered]@{
    # The one stack with no marker file: its tools ask nothing about a language, so
    # every repository has it and the marker is the repository itself.
    base   = 'git work tree'
    go     = 'go.mod'
    web    = 'package.json + vite/next/webpack/rollup.config.*'
    godot  = 'project.godot'
    proto  = 'buf.yaml'
    python = 'pyproject.toml or requirements.txt'
    rust   = 'Cargo.toml'
    dotnet = '*.csproj'
    cpp    = 'CMakeLists.txt'
    custom = 'qgate.json with a non-empty "checks" array'
}

# Directories that never hold a project we own.
$script:SkipDirs = @('node_modules', '.git', 'vendor', 'dist', 'build', '.cache', '.venv', 'target', 'bin', 'obj')

# CMake's own output, not anybody's source. A configured build tree carries a
# CMakeLists.txt for every dependency it fetched (under `_deps/`) plus generated ones
# of its own, and an IDE names its tree `cmake-build-debug`. Detecting those would gate
# generated code, in a directory the next configure run deletes. $SkipDirs above covers
# the exact names it knows; these are the ones it cannot spell -- a PREFIX
# (cmake-build-*) and names it does not carry. Used for the marker search AND for the
# source sweep the format phase does, so both answer the same question.
$script:CppSkipDir = '(?i)[\\/](build|out|_deps|cmake-build[^\\/]*|node_modules|\.git)[\\/]'

# Is this file the stack's OWN source? The two static-analysis phases read their file
# list out of a compile database, which is CMake's answer and not the gate's: it names
# every translation unit the build compiles, including the ones a FetchContent
# dependency brought in, and every header they reach -- measured on Renderforge, 85 of
# 173 cppcheck findings came out of SDK headers two directories above the project, code
# nobody in that repository can fix. Two conditions, because either alone lets one of
# those through: under the stack directory, and not in a build tree inside it.
function Test-CppOwn([string]$Path, [string]$Dir) {
    if (-not $Path) { return $false }
    $p = ($Path -replace '/', '\')
    $d = $Dir.TrimEnd('\')
    if (-not $p.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($p.Substring($d.Length) -notmatch $script:CppSkipDir)
}

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

# Which of these paths does the repo ignore? One git process for the whole batch.
# `check-ignore -v --non-matching` prints exactly one line per path, in the order given,
# and the line for a path git does NOT ignore begins with `::`. Only that two-character
# prefix is read, so git's C-quoting of the echoed path -- the reason the --stdin form
# above was rejected -- cannot corrupt the answer.
#
# Paths go as ARGUMENTS, never through stdin: PowerShell terminates a piped string with
# CRLF, and the trailing CR became part of the last path. Measured, and it lied in both
# directions -- `config.json\r` read as NOT ignored, `docs/api/autograph-public.md\r`
# read as ignored because the CR also defeated the `!` line that re-included it.
#
# Chunked, because the whole batch is one command line and Windows caps that at 32 KB.
function Get-GitIgnoredSet([string]$Root, [string[]]$Paths) {
    $set = @{}
    $prev = $global:LASTEXITCODE
    for ($i = 0; $i -lt $Paths.Count; $i += 200) {
        $chunk = @($Paths[$i..([Math]::Min($i + 199, $Paths.Count - 1))])
        $out = @(& git -C $Root check-ignore -v --non-matching -- @chunk 2>$null)
        # A short answer is git refusing the batch, not an answer about these paths.
        # Ignore nothing rather than drop findings on a reply nobody can align.
        if ($out.Count -ne $chunk.Count) { continue }
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            if (-not "$($out[$j])".StartsWith('::')) { $set[$chunk[$j]] = $true }
        }
    }
    # Same reason as Test-GitIgnored: --non-matching exits 1 when nothing matched, and
    # check.ps1's Phase fails a phase on a non-zero $LASTEXITCODE.
    $global:LASTEXITCODE = $prev
    return $set
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
function Get-DefaultTrustStore {
    if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'qgate\trusted.json' }
    else { Join-Path $HOME '.config/qgate/trusted.json' }
}

# QGATE_HOME moves the whole state directory wherever the owner keeps state -- off the
# system drive, so a Windows reinstall does not take it. Unset, nothing changes.
function Get-TrustStore {
    if (-not $env:QGATE_HOME) { return (Get-DefaultTrustStore) }
    $store = Join-Path $env:QGATE_HOME 'trusted.json'
    # First use of a fresh QGATE_HOME carries the old store across. Starting empty is
    # not a neutral state: every repository trusted yesterday silently stops running
    # its own checks, and a check that stopped running looks exactly like a check that
    # passed. Said once on stderr, because after the copy the file is there.
    if (-not (Test-Path $store)) {
        $legacy = Get-DefaultTrustStore
        if (Test-Path $legacy) {
            New-Item -ItemType Directory -Path $env:QGATE_HOME -Force | Out-Null
            Copy-Item -LiteralPath $legacy -Destination $store
            [Console]::Error.WriteLine("qgate: copied the trust store to $store (from $legacy)")
        }
    }
    $store
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
#   Stack       base | go | web | godot | proto | python | rust | dotnet | cpp | custom
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

    # First, and unconditional: gitleaks, typos and osv-scanner ask nothing about a
    # language, so there is no marker file to find -- the repository IS the marker. A
    # git work tree is the whole condition, because the fast secrets scan reads the
    # index and a directory that is not a repository has none. A non-git directory
    # therefore still reports `[SKIP] no known stack found`, exactly as before.
    # Ordered first so a leaked secret stops the run before anything compiles.
    $prev = $global:LASTEXITCODE
    & git -C $Root rev-parse --is-inside-work-tree *> $null
    $isRepo = ($LASTEXITCODE -eq 0)
    # Same rule as Test-GitIgnored: `rev-parse` answering "not a repository" is a
    # non-zero exit, and leaking it would fail the first phase that reads it.
    $global:LASTEXITCODE = $prev
    if ($isRepo) {
        $stacks += [pscustomobject]@{ Stack = 'base'; Dir = $Root; Rel = ''; Marker = 'git work tree'; Implemented = $true; Warn = '' }
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
    $unitySeen = @{}
    foreach ($m in Find-Marker $Root @('*.csproj')) {
        $dir = $m.DirectoryName
        # A Unity project's csproj are the editor's own output: regenerated on every
        # open, referencing the editor install, not buildable by `dotnet`. Reported from
        # the field: six of them became six stacks, each an [UNKNOWN] format and a
        # 260-reference [SKIP], and they broke the shared format solution for everyone.
        # One SKIP per Unity project; not Implemented, so no phase and no shared .sln.
        $unity = $null
        for ($d = $dir; $d.Length -ge $Root.TrimEnd('\').Length; $d = Split-Path $d -Parent) {
            if ((Test-Path -LiteralPath (Join-Path $d 'ProjectSettings\ProjectVersion.txt') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $d 'Assets') -PathType Container)) { $unity = $d; break }
        }
        if ($unity) {
            if (-not $unitySeen.ContainsKey($unity)) {
                $unitySeen[$unity] = $true
                $stacks += [pscustomobject]@{ Stack = 'dotnet'; Dir = $unity; Rel = (& $rel $unity); Marker = '*.csproj'; Implemented = $false
                    Warn = 'Unity-generated csproj (regenerated by the Unity editor, not buildable by dotnet)' }
            }
            continue
        }
        $warn = ''
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            $warn = 'dotnet not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'dotnet'; Dir = $dir; Rel = (& $rel $dir); Marker = $m.Name; Implemented = $true; Warn = $warn }
    }

    # One stack per TREE, not per marker: a CMakeLists.txt inside a project that
    # already has one is add_subdirectory() material -- configuring the top one
    # configures it too, so detecting both would configure and build the same code
    # twice, into two build trees. Shortest directory first, so a parent is always
    # recorded before the children it swallows.
    $cppDirs = @()
    foreach ($m in Find-Marker $Root @('CMakeLists.txt') | Sort-Object { $_.DirectoryName.Length }) {
        $dir = $m.DirectoryName
        if ($m.FullName.Substring($Root.Length) -match $script:CppSkipDir) { continue }
        if ($cppDirs | Where-Object { $dir.StartsWith("$_\") -or $dir.StartsWith("$_/") }) { continue }
        $cppDirs += $dir
        $warn = ''
        if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
            $warn = 'cmake not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'cpp'; Dir = $dir; Rel = (& $rel $dir); Marker = 'CMakeLists.txt'; Implemented = $true; Warn = $warn }
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
