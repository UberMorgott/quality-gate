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
    deploy = 'qgate.json with a non-empty "deploy" array'
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

# The compile database cut down to the stack's own translation units (#106). Filtering
# cppcheck's FINDINGS afterwards is not enough: `--project` analyses every entry first,
# and on CodeDungeon 1022 of 1027 were godot-cpp sources under build/_deps -- 45 minutes
# of one core before the gate threw every one of those findings away. Each kept entry is
# copied whole, so a TU keeps its own flags, defines and include paths, and headers it
# reaches outside the stack are still dropped by the Test-CppOwn filter on the output.
# Written to <Out>\compile_commands.json; $null when no entry is the stack's own.
function Write-CppOwnDb([string]$Db, [string]$Dir, [string]$Out) {
    $own = @(Get-Content -LiteralPath $Db -Raw | ConvertFrom-Json | Where-Object {
            $f = "$($_.file)"
            if ($f -and -not [IO.Path]::IsPathRooted($f)) { $f = Join-Path "$($_.directory)" $f }
            Test-CppOwn $f $Dir
        })
    if ($own.Count -eq 0) { return $null }
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
    $path = Join-Path $Out 'compile_commands.json'
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $own -Depth 5), [Text.UTF8Encoding]::new($false))
    return $path
}

# The generator a configure of $Build will use, in CMake's own order: the one an
# existing cache recorded (cmake refuses to switch it), then the CMAKE_GENERATOR
# environment variable, then the default `cmake --help` marks with `*`. #105: -A is a
# platform only the Visual Studio generators (and Green Hills MULTI) accept, and the
# Windows default is Visual Studio only where one is installed -- without one CMake 4.x
# picks Ninja, which refuses -A outright. Empty when none of the three answers.
function Get-CMakeGenerator([string]$Build) {
    $cache = Join-Path $Build 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cache) {
        $m = Select-String -LiteralPath $cache -Pattern '^CMAKE_GENERATOR:INTERNAL=(.+)$' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    if ($env:CMAKE_GENERATOR) { return $env:CMAKE_GENERATOR }
    $m = @(& cmake --help 2>$null) | Select-String -Pattern '^\*\s*(.+?)\s*(=.*)?$' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return ''
}

# A build tree remembers its tools by ABSOLUTE path -- the compiler in every
# compile_commands.json entry, the make program, linker and archiver in CMakeCache.txt
# -- and a reconfigure does not look them up again. Uninstall or move LLVM and the tree
# keeps naming the old one: measured, cmake then fails the reconfigure ("Tell CMake where
# to find the compiler") and leaves the previous database in place, which the gate read
# as current. The first recorded tool that is gone, or $null when every one still exists.
function Get-CppStaleTool([string]$Tree) {
    $paths = @()
    $db = Join-Path $Tree 'compile_commands.json'
    if (Test-Path -LiteralPath $db) {
        $e = try { @(Get-Content -LiteralPath $db -Raw | ConvertFrom-Json)[0] } catch { $null }
        if ($e.arguments) { $paths += "$($e.arguments[0])" }
        elseif ("$($e.command)" -match '^\s*(?:"([^"]+)"|(\S+))') { $paths += "$($Matches[1])$($Matches[2])" }
    }
    $cache = Join-Path $Tree 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cache) {
        $paths += @(Select-String -LiteralPath $cache -Pattern '^CMAKE_(C_COMPILER|CXX_COMPILER|MAKE_PROGRAM|LINKER|AR):(FILEPATH|STRING)=(.+)$' |
            ForEach-Object { $_.Matches[0].Groups[3].Value.Trim() })
    }
    foreach ($p in $paths) {
        if ($p -and [IO.Path]::IsPathRooted($p) -and -not (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# The target a GCC-built database has to be analysed for (#114). clang-tidy takes the
# compiler out of each entry, but not the target: clang on Windows defaults to
# x86_64-pc-windows-msvc, so a MinGW database is parsed against the MSVC STL -- or, with
# no Visual Studio installed, against nothing ("'string' file not found"). Told the
# MinGW triple GCC itself reports, clang finds that toolchain's libstdc++ next to the
# compiler the entry names. $null for anything but a GCC whose target is Windows-GNU:
# elsewhere clang's default already is the build's target.
function Get-CppTidyTarget([string]$Db) {
    $e = try { @(Get-Content -LiteralPath $Db -Raw | ConvertFrom-Json)[0] } catch { $null }
    $cc = if ($e.arguments) { "$($e.arguments[0])" }
    elseif ("$($e.command)" -match '^\s*(?:"([^"]+)"|(\S+))') { "$($Matches[1])$($Matches[2])" }
    if (-not $cc -or (Split-Path $cc -Leaf) -notmatch '(?i)^([\w.]+-)?(gcc|g\+\+|c\+\+|cc)(-[\d.]+)?(\.exe)?$') { return $null }
    if (-not (Get-Command $cc -ErrorAction SilentlyContinue)) { return $null }
    $t = "$(& $cc -dumpmachine 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or $t -notmatch '(?i)mingw|windows-gnu|cygwin') { return $null }
    return $t
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
    # A file inside a nested repository is not this repo's either, and git's check-ignore
    # answers "not ignored" for it (#78). Every per-file filter routes through here.
    if (Test-InNestedRepo $Root $Path) { return $true }
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

# Directories below $Root holding their own repository (a `.git` dir or file), repo-
# relative with forward slashes and no trailing slash. They are separate projects with
# their own gate, and git itself never descends into one -- neither does the gate.
# Issue #78: a workspace root holding cloned repos and a decompiled dump got 20 dotnet
# stacks and 14772 typos findings in files that were not its own.
#
# In a work tree git already knows: `ls-files -o` lists an untracked nested repository
# as `dir/` and never a plain directory that way (measured, including one several levels
# inside an untracked directory), and a submodule is a 160000 index entry. -z because
# git C-quotes non-ASCII paths otherwise. Outside a work tree there is no git to ask.
$script:NestedRepos = @{}
function Get-NestedRepos([string]$Root) {
    if ($script:NestedRepos.ContainsKey($Root)) { return $script:NestedRepos[$Root] }
    $prev = $global:LASTEXITCODE
    $found = @()
    & git -C $Root rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
        $untracked = (& git -C $Root ls-files -z -o --exclude-standard 2>$null | Out-String).Split([char]0)
        $found += @($untracked | Where-Object { $_.EndsWith('/') } | ForEach-Object { $_.TrimEnd('/') })
        $staged = (& git -C $Root ls-files -z -s 2>$null | Out-String).Split([char]0)
        $found += @($staged | Where-Object { $_ -match '^160000 ' } | ForEach-Object { ($_ -split "`t", 2)[1] })
        $found = @($found | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Root "$_\.git")) })
    } else {
        # ponytail: depth 3 = Find-Marker's reach, which is all this path serves (base
        # phases need a work tree); deeper nested repos in a non-git dir are not seen.
        $found = @(Get-ChildItem -LiteralPath $Root -Recurse -Depth 3 -Force -Filter '.git' -ErrorAction SilentlyContinue |
            ForEach-Object { Split-Path $_.FullName -Parent } | Where-Object { $_ -ne $Root.TrimEnd('\') } |
            ForEach-Object { $_.Substring($Root.TrimEnd('\').Length).Trim('\').Replace('\', '/') })
    }
    $global:LASTEXITCODE = $prev
    $script:NestedRepos[$Root] = @($found | Sort-Object -Unique)
    return $script:NestedRepos[$Root]
}

function Test-InNestedRepo([string]$Root, [string]$Path) {
    $r = $Root.TrimEnd('\')
    if (-not $Path.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $rel = $Path.Substring($r.Length).Trim('\').Replace('\', '/') + '/'
    foreach ($n in Get-NestedRepos $Root) {
        if ($rel.StartsWith("$n/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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
#
# #108: one repo, two spellings. Claude Code hands the Stop hook CLAUDE_PROJECT_DIR as
# `E:/DEV/Repo` (forward slashes, even on Windows) while `qgate hold` run from a shell
# resolves the same tree to `E:\DEV\Repo`, and the two keys named two different marker
# files -- so an active hold was invisible to the hook. Separators and a trailing one
# are normalised before hashing; case already was.
function Get-PathKey([string]$Text) {
    $norm = ($Text -replace '/', '\') -replace '(?<=.)\\+$', ''
    [BitConverter]::ToString(
        [Security.Cryptography.MD5]::HashData(
            [Text.Encoding]::UTF8.GetBytes($norm.ToLowerInvariant()))).Replace('-', '')
}

# The `qgate hold` marker for a repo: the expiry it was set with, or $null when no hold
# is active. Shared by gate/hold.ps1 and the Stop hook so both agree on the file name and
# on what an unreadable or expired marker means -- nothing held. An expired marker is
# deleted here: a hold nobody released must not sit in TEMP looking active to `status`.
function Get-QGateHoldUntil([string]$Root) {
    $file = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-hold-$(Get-PathKey $Root).txt"
    if (-not (Test-Path $file)) { return $null }
    # Typed, not $null: the 4-argument TryParse takes an `out DateTime`, and an untyped
    # [ref] made PowerShell report "Cannot find an overload for TryParse".
    $until = [datetime]::MinValue
    # Round-trip format and InvariantCulture: the marker is written by one process and read
    # by another, and ru-RU here parses `2026-09-17T14:03:11` differently than en-US.
    if (-not [datetime]::TryParse((Get-Content $file -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$until)) {
        Remove-Item $file -ErrorAction SilentlyContinue
        return $null
    }
    if ($until -lt (Get-Date)) { Remove-Item $file -ErrorAction SilentlyContinue; return $null }
    $until
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

# Optional qgate.deferrals.json in the repo root, one loader for both of its sections:
#
#   {"dependencies":    [{"name": "vue",          "until": "2026-11-01", "reason": "..."}],
#    "vulnerabilities": [{"id":   "GO-2026-5932", "until": "2026-11-01", "reason": "..."}]}
#
# `qgate outdated` reads "dependencies"; the vulnerability phases read "vulnerabilities".
# `until` and `reason` are mandatory: a deferral with no expiry is just a silence. Returns
# @{ Name; Until; Reason } per valid entry and @{ Bad = message } per invalid one.
function Read-Deferrals([string]$Root, [string]$Section, [string]$Key) {
    $file = Join-Path $Root 'qgate.deferrals.json'
    if (-not (Test-Path $file)) { return }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    # A file that parses but holds neither section is as unreadable as broken JSON.
    if (-not $json -or -not ($json.PSObject.Properties.Name | Where-Object { $_ -in 'dependencies', 'vulnerabilities' })) {
        return @{ Bad = 'qgate.deferrals.json is not readable as {"dependencies": [...], "vulnerabilities": [...]}' }
    }
    $where = if ($Section -eq 'dependencies') { '' } else { "$Section " }
    $n = 0
    # The -and is load-bearing: `@($null)` iterates ONE null element, which reported an
    # "entry 1" nobody wrote for a section the file does not have.
    foreach ($d in @($json.$Section | Where-Object { $null -ne $_ })) {
        $n++
        $due = [datetime]::MinValue
        if (-not $d.$Key -or -not $d.reason) {
            @{ Bad = "qgate.deferrals.json ${where}entry $n needs both '$Key' and 'reason'" }
        } elseif (-not [datetime]::TryParseExact([string]$d.until, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$due)) {
            @{ Bad = "qgate.deferrals.json ${where}entry for '$($d.$Key)' needs 'until' as yyyy-MM-dd" }
        } else {
            @{ Name = [string]$d.$Key; Until = $due; Reason = [string]$d.reason }
        }
    }
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

# quality-gate#41: a package that passes here can still hit `-timeout` in CI under -race.
# Measured on the reporting repo: its sim package took 27s in the full `go test`, and the
# same package under CI's `go test -race` died at the 10m timeout. The race detector costs
# 2-20x (go.dev/doc/articles/race_detector) and a CI runner is slower than a dev box, so
# anything over a thirtieth of the timeout is within reach of it. -timeout is per test
# binary, which is per package -- so the `ok <pkg> <secs>s` line is the right measure,
# and reading it leaves the phase's output exactly as it was.
# ponytail: names the package, not the slow test; `go test -json` would, at the cost of
# rebuilding the readable failure output.
function Get-SlowGoPackages([string]$Out, [int]$TimeoutSec) {
    foreach ($m in [regex]::Matches($Out, '(?m)^ok\s+(\S+)\s+(\d+(?:\.\d+)?)s\b')) {
        $sec = [double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($sec -ge $TimeoutSec / 30) {
            "[WARN] slow tests: $($m.Groups[1].Value) took $($m.Groups[2].Value)s, over 1/30 of its $($TimeoutSec)s -timeout -- -race runs 2-20x slower, so CI can time out here"
        }
    }
}

# quality-gate#42: CI ran `go test` for GOARCH=386 and stayed red for ten days while the
# gate, which only ever builds for this machine, stayed green. Names the workflow steps
# that run Go (test, vet, golangci-lint) for a target the gate's own phases never touch.
# A step is a YAML list item plus the lines up to the next one, so an `env:` block and
# its `run:` are read together -- the reporting repo sets GOARCH exactly that way.
# ponytail: text match, not a YAML parser -- job-level `env:` and matrix-expanded values
# are not seen. `$Covered` is the run text of the repo's qgate.json checks: a variant
# already declared there is not a gap. `-race` without `-short` is deliberately not one:
# measured, 2 of 5 local repos run exactly that in CI, the only remedy would be a second
# full race run per commit, and the timeout risk it carries is what `slow tests` names.
function Get-CiGoGaps([string]$Root, [string]$GoOS, [string]$GoArch, [string]$Covered) {
    $dir = Join-Path $Root '.github/workflows'
    if (-not (Test-Path $dir)) { return }
    foreach ($f in @(Get-ChildItem $dir -File | Where-Object { $_.Extension -in '.yml', '.yaml' })) {
        $steps = @(); $cur = ''
        foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
            if ($line -match '^\s*-\s+[\w-]+:') { $steps += $cur; $cur = '' }
            $cur += "$line`n"
        }
        $steps += $cur
        foreach ($st in $steps) {
            if ($st -notmatch '(?m)^[^#]*\b(go\s+(test|vet)|golangci-lint\s+run)\b') { continue }
            $gaps = @()
            foreach ($v in 'GOOS', 'GOARCH') {
                $want = if ($v -eq 'GOOS') { $GoOS } else { $GoArch }
                if ($st -match "(?m)^[^#]*\b$v\s*[:=]\s*[`"']?(\w+)" -and $Matches[1] -ne $want -and
                    $Covered -notmatch "\b$v\W+$($Matches[1])\b") { $gaps += "$v=$($Matches[1])" }
            }
            if ($st -match '(?m)^[^#]*\s(-tags[= ]+\S+)' -and -not $Covered.Contains($Matches[1])) { $gaps += $Matches[1] }
            if (-not $gaps) { continue }
            $name = if ($st -match '(?m)^\s*-?\s*name:\s*(.+?)\s*$') { $Matches[1].Trim('"', "'") } else { 'unnamed step' }
            "[WARN] CI parity: $($f.Name) step '$name' runs Go with $($gaps -join ', ') -- the gate does not; declare it as a qgate.json check"
        }
    }
}

# quality-gate#43: a repo's own .golangci.yml silently diverging from the template's
# curated floor. Reported from the field: govet with no settings was assumed to include
# `nilness`; it does not, the template enables it explicitly. Linters are read from
# golangci-lint itself (`linters -c`, ~0.15s, no analysis), so `default: standard/all`
# resolves the way the run does. A floor name that appears ANYWHERE in the repo config
# -- a `disable:` entry, a comment giving the reason -- counts as a decision, not a gap,
# so a deliberate omission is silenced by writing its reason down.
# ponytail: govet analyzers are a text match on both files, not a YAML parser; govet
# `enable-all: true` is honoured, other spellings are not.
function Get-GolangciFloorGaps([string]$Dir, [string]$Rel, [string]$Template) {
    $cfg = @('.golangci.yml', '.golangci.yaml') | ForEach-Object { Join-Path $Dir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cfg -or -not (Test-Path $Template)) { return }
    $prev = $global:LASTEXITCODE
    $enabled = {
        param($c)
        $on = $false
        foreach ($l in @(& golangci-lint linters -c $c 2>$null)) {
            if ($l -like 'Enabled by your configuration linters:*') { $on = $true; continue }
            if (-not $l.Trim()) { if ($on) { break } else { continue } }
            if ($on -and $l -match '^([\w-]+):') { $Matches[1] }
        }
    }
    $want = @(& $enabled $Template)
    $have = @(& $enabled $cfg)
    $global:LASTEXITCODE = $prev
    # An unloadable config lists nothing; the golangci-lint phase already says why.
    if (-not $want -or -not $have) { return }
    $text = Get-Content $cfg -Raw
    $named = { param($n) $text -match "(?<![\w-])$([regex]::Escape($n))(?![\w-])" }
    $missing = @($want | Where-Object { $_ -notin $have -and -not (& $named $_) })
    $vet = @()
    $tpl = Get-Content $Template -Raw
    if ($tpl -match '(?ms)^    govet:.*?^      enable:\s*\n(.*?)^    \S' -and $text -notmatch '(?ms)govet:.*?enable-all:\s*true') {
        $vet = @([regex]::Matches($Matches[1], '(?m)^\s*-\s*(\w+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { -not (& $named $_) })
    }
    if (-not $missing -and -not $vet) { return }
    $where = "$(if ($Rel) { "$Rel/" })$(Split-Path -Leaf $cfg)"
    $parts = @(if ($missing) { "linters: $($missing -join ', ')" }) + @(if ($vet) { "govet analyzers: $($vet -join ', ')" })
    "[WARN] golangci floor: $where lacks template $($parts -join '; ') -- enable them, or name each in a comment with the reason (templates/.golangci.yml)"
}

# quality-gate#47: a package that starts goroutines, has tests, and none of them check
# for leaks (go.uber.org/goleak: VerifyTestMain / VerifyNone). Package membership comes
# from `go list` (build tags, nested modules, vendor handled by the toolchain); the rest
# is a text scan of the listed files. A package without tests is not named: there is
# nowhere to put the check yet.
# ponytail: regex on source lines, not the AST -- a `go f(` line inside a raw string
# counts, goroutines started by a dependency do not, and any `goleak.` mention in a test
# file counts as covered. go/ast via a helper binary if the noise says so.
function Get-GoleakGaps([string]$Dir) {
    $prev = $global:LASTEXITCODE
    Push-Location $Dir
    try { $pkgs = @(& go list -f '{{.Dir}}|{{.GoFiles}}|{{.TestGoFiles}}|{{.XTestGoFiles}}' ./... 2>$null) }
    finally { Pop-Location; $global:LASTEXITCODE = $prev }
    $files = { param($d, $list) @($list.Trim('[', ']') -split ' ' | Where-Object { $_ } | ForEach-Object { Join-Path $d $_ }) }
    $gaps = @(foreach ($p in $pkgs) {
            $f = $p -split '\|'
            if ($f.Count -ne 4) { continue }
            $tests = @(& $files $f[0] $f[2]) + @(& $files $f[0] $f[3])
            if (-not $tests) { continue }
            $starts = @(& $files $f[0] $f[1] | Where-Object { [IO.File]::ReadAllText($_) -match '(?m)^\s*go\s+(func\s*\(|[\w.]+\s*\()' })
            if (-not $starts) { continue }
            if (@($tests | Where-Object { [IO.File]::ReadAllText($_) -match '\bgoleak\.' })) { continue }
            $r = [IO.Path]::GetRelativePath($Dir, $f[0]).Replace('\', '/')
            if ($r -eq '.') { './' } else { $r }
        })
    if ($gaps) {
        "[WARN] goleak: $($gaps.Count) package(s) start goroutines but no test checks for leaks: $($gaps -join ', ') -- add goleak.VerifyTestMain(m) (go.uber.org/goleak)"
    }
}

# quality-gate#49: run the module's existing Fuzz* targets for a short budget. One
# target per `go test -fuzz` (it accepts exactly one match in one package), -run=^$ so
# the package's tests do not run a second time. Bounded for a commit hook: $PerTargetSec
# each, and no new target is started once that would pass $BudgetSec -- the ones left
# out are named. A crash is ADVISORY until calibrated: go writes the failing input into
# the package's testdata/fuzz/<Target>/, where every later plain `go test` would fail on
# it -- the gate would have turned its own warning into a verdict. So a file this run
# created is printed into the warning (enough to re-create it) and removed.
# ponytail: sequential; targets beyond the budget are skipped, not rotated between runs.
# quality-gate#118: `go test -fuzz` starts GOMAXPROCS workers, each its own pkg.test
# process -- dozens on a many-core box, enough to exhaust RAM and the paging file. So
# -parallel is capped (half the cores, 1..4) and every worker gets a GOMEMLIMIT soft cap.
# qgate.json go.fuzzParallel / go.fuzzMemLimit override; an inherited GOMEMLIMIT is kept.
function Get-GoFuzzLimits([string]$Root) {
    $cfg = [pscustomobject]@{
        Parallel = [Math]::Max(1, [Math]::Min(4, [Math]::Floor([Environment]::ProcessorCount / 2)))
        MemLimit = if ($env:GOMEMLIMIT) { $env:GOMEMLIMIT } else { '2GiB' }
        Error    = ''
    }
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $cfg }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $null -eq $json.go) { return $cfg }
    $names = $json.go.PSObject.Properties.Name
    if ($names -contains 'fuzzParallel') {
        $v = $json.go.fuzzParallel
        if (($v -isnot [int] -and $v -isnot [long]) -or $v -lt 1 -or $v -gt 256) { $cfg.Error = 'qgate.json "go.fuzzParallel" must be a number of fuzz workers between 1 and 256' }
        else { $cfg.Parallel = [int]$v }
    }
    if ($names -contains 'fuzzMemLimit') {
        $v = $json.go.fuzzMemLimit
        if ($v -isnot [string] -or $v -notmatch '^\d+(B|KiB|MiB|GiB|TiB)?$') { $cfg.Error = 'qgate.json "go.fuzzMemLimit" must be a GOMEMLIMIT value like "2GiB"' }
        else { $cfg.MemLimit = $v }
    }
    $cfg
}

function Get-GoFuzzArgs([string]$Pkg, [string]$Name, [int]$PerTargetSec, [int]$Parallel) {
    @('test', '-run=^$', "-fuzz=^$Name$", "-fuzztime=$($PerTargetSec)s", "-parallel=$Parallel", $Pkg)
}

function Invoke-GoFuzz([string]$Dir, [int]$PerTargetSec = 10, [int]$BudgetSec = 60, $Limits = (Get-GoFuzzLimits $Dir)) {
    $prev = $global:LASTEXITCODE
    $prevMem = $env:GOMEMLIMIT
    $env:GOMEMLIMIT = $Limits.MemLimit
    Push-Location $Dir
    $res = [pscustomobject]@{ Ran = 0; Warn = @() }
    try {
        $pkgDir = @{}
        foreach ($l in @(& go list -f '{{.ImportPath}}|{{.Dir}}' ./... 2>$null)) { $p = $l -split '\|', 2; $pkgDir[$p[0]] = $p[1] }
        $targets = @(); $names = @()
        foreach ($l in @(& go test -list '^Fuzz' ./... 2>$null)) {
            if ($l -match '^Fuzz\w*$') { $names += $l }
            elseif ($l -match '^ok\s+(\S+)') { $targets += @($names | ForEach-Object { [pscustomobject]@{ Pkg = $Matches[1]; Name = $_ } }); $names = @() }
            else { $names = @() }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $skipped = @()
        foreach ($t in $targets) {
            if ($sw.Elapsed.TotalSeconds + $PerTargetSec -gt $BudgetSec) { $skipped += $t.Name; continue }
            $corpus = Join-Path $pkgDir[$t.Pkg] "testdata/fuzz/$($t.Name)"
            $before = @(Get-ChildItem $corpus -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
            # The outermost directory the run may create: removed whole if it did.
            $created = @('testdata', 'testdata/fuzz', "testdata/fuzz/$($t.Name)") | ForEach-Object { Join-Path $pkgDir[$t.Pkg] $_ } |
                Where-Object { -not (Test-Path $_) } | Select-Object -First 1
            $goArgs = Get-GoFuzzArgs $t.Pkg $t.Name $PerTargetSec $Limits.Parallel
            $out = (& go @goArgs 2>&1 | Out-String)
            $res.Ran++
            if ($LASTEXITCODE -eq 0) { continue }
            $new = @(Get-ChildItem $corpus -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $before })
            $res.Warn += "[WARN] go fuzz: $($t.Pkg) $($t.Name) failed -- advisory, not a failure"
            $res.Warn += @($out -split "`r?`n" | Where-Object { $_ -match '^\s+\S' -and $_ -notmatch 'Failing input written|To re-run|go test -run=' } | Select-Object -First 10 | ForEach-Object { "       $($_.Trim())" })
            foreach ($f in $new) {
                $res.Warn += "       failing input (removed from the tree; save as $($t.Name)/$($f.Name) under testdata/fuzz to keep it as a regression):"
                $res.Warn += @(Get-Content $f.FullName | ForEach-Object { "         $_" })
                Remove-Item $f.FullName -Force
            }
            if ($created -and (Test-Path $created)) { Remove-Item $created -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($skipped) { $res.Warn += "[WARN] go fuzz: budget ${BudgetSec}s spent -- not run: $($skipped -join ', ')" }
    } finally { Pop-Location; $global:LASTEXITCODE = $prev; $env:GOMEMLIMIT = $prevMem }
    $res
}

# A cgo `//export` function is the C ABI of a -buildmode=c-shared/c-archive build: C calls it,
# Go never does, and deadcode roots only main, init and tests -- so it reports every export
# and every helper only exports call. deadcode takes no extra roots, so this returns the names
# (deadcode's spelling: `f`, `T.m`) in package dir $PkgDir that its exports reach: the exports
# of files importing "C", then, transitively, each top-level func or method of the package whose
# name appears as an identifier in a reached body (comments dropped). A textual scan, so it errs
# toward live: an identifier that merely shares a name counts. Callees in OTHER packages that
# only an export reaches are not followed and stay reported. No exports: an empty set.
function Get-GoCgoExportLive([string]$PkgDir) {
    $live = [Collections.Generic.HashSet[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $PkgDir -Filter '*.go' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*_test.go' })
    $roots = [Collections.Generic.List[string]]::new()
    $bodies = [hashtable]::new([StringComparer]::Ordinal); $byIdent = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($f in $files) {
        $lines = @(Get-Content -LiteralPath $f.FullName)
        $cgo = [bool]@($lines -match '^\s*(import\s+)?"C"\s*$').Count
        $key = $null
        foreach ($l in $lines) {
            if ($cgo -and $l -match '^//export\s+(\w+)') { $roots.Add($Matches[1]); continue }
            if ($l -match '^func\s+(?:\(\s*(?:\w+\s+)?\*?(\w+)[^)]*\)\s*)?(\w+)') {
                $key = if ($Matches[1]) { "$($Matches[1]).$($Matches[2])" } else { $Matches[2] }
                if (-not $byIdent.ContainsKey($Matches[2])) { $byIdent[$Matches[2]] = @() }
                $byIdent[$Matches[2]] += $key
                $bodies[$key] = ''
            } elseif ($l -match '^(type|var|const|import)\b') { $key = $null }
            if ($key) { $bodies[$key] += ($l -replace '//.*$', '') + "`n" }
        }
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($r in $roots) { if ($live.Add($r)) { $queue.Enqueue($r) } }
    while ($queue.Count) {
        $k = $queue.Dequeue()
        if (-not $bodies.ContainsKey($k)) { continue }
        foreach ($m in [regex]::Matches($bodies[$k], '\b[A-Za-z_]\w*\b')) {
            foreach ($c in @($byIdent[$m.Value])) { if ($c -and $live.Add($c)) { $queue.Enqueue($c) } }
        }
    }
    , $live
}

# quality-gate#51: whole-program unreachable functions (golang.org/x/tools/cmd/deadcode).
# -test, so a helper only tests call is reachable -- the first false-positive class the
# report named; it also makes a library's test binaries the roots, so a library with
# tests is analyzed too. It exits 0 with findings, so the verdict is the output. A module
# with neither main nor tests has no program to walk (`deadcode: no main packages`,
# exit 1): nothing to say. Any other error is named once, never raised: this check is advisory.
# quality-gate#112: $Tags = the qgate.json go.tags sets. deadcode passes its own `-tags=`
# (empty by default) to the package loader, which overrides GOFLAGS (measured), so each set
# goes on its command line; a function is reported only if every set that has a program
# finds it unreachable -- one binary's code is not dead because another binary skips it.
function Get-GoDeadcode([string]$Dir, [string[]]$Tags = @('')) {
    $hits = @(); $ran = $false
    foreach ($t in $Tags) {
        $tagArg = @(if ($t) { "-tags=$t" })
        $prev = $global:LASTEXITCODE
        Push-Location $Dir
        try { $out = @(& deadcode -test @tagArg ./... 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
        finally { Pop-Location; $global:LASTEXITCODE = $prev }
        if ($code -ne 0) {
            if ($out -match 'no main packages') { continue }
            return "[WARN] deadcode$(if ($t) { " (tags=$t)" }) could not analyze this module -- $(@($out | Select-Object -Last 1))"
        }
        $set = @($out | Where-Object { $_ -match 'unreachable func' })
        $hits = if (-not $ran) { $set } else { @($hits | Where-Object { $_ -in $set }) }
        $ran = $true
    }
    $hits = @($hits | Where-Object { $_ })
    $live = @{}
    $hits = @($hits | Where-Object {
        if ($_ -notmatch '^(?<file>.+\.go):\d+:\d+: unreachable func: (?<name>\S+)') { return $true }
        $name = $Matches.name
        $pkg = Split-Path ([IO.Path]::Combine($Dir, $Matches.file)) -Parent
        if (-not $live.ContainsKey($pkg)) { $live[$pkg] = Get-GoCgoExportLive $pkg }
        -not $live[$pkg].Contains($name)
    })
    if (-not $hits) { return }
    "[WARN] deadcode: $($hits.Count) unreachable function(s) -- advisory, not a failure"
    $hits | Select-Object -First 20 | ForEach-Object { "       $_" }
    if ($hits.Count -gt 20) { "       ... $($hits.Count - 20) more: run deadcode -test$(if ($Tags[0]) { " -tags=$($Tags[0])" }) ./..." }
}

# quality-gate#97: a .csproj that no solution lists and no other project references is a
# project nothing builds -- the case that prompted this was a forked example project for an
# abandoned API, kept in the tree, broken, and flagged by nothing.
# Only asked of a repository that HAS a solution: without one, several standalone projects
# side by side is a normal layout, not an orphan each. Advisory, never a failure -- an
# unreferenced project can be a deliberate scratch target, and this gate does not delete code.
function Get-OrphanProjects([string]$Root, [int]$Depth = 3) {
    $projs = @(Find-Marker $Root @('*.csproj') $Depth)
    $slns = @(Find-Marker $Root @('*.sln', '*.slnx') $Depth)
    if (-not $slns -or -not $projs) { return }
    # The referenced set is collected as FULL PATHS: a solution and a ProjectReference both
    # spell the path relative to the file holding them, so each is resolved against its own
    # directory before the two can be compared.
    $ref = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($BaseDir, $Rel)
        $p = try { [IO.Path]::GetFullPath((Join-Path $BaseDir ($Rel -replace '/', '\'))) } catch { $null }
        if ($p) { [void]$ref.Add($p) }
    }
    foreach ($s in $slns) {
        $txt = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches("$txt", '"([^"]+\.csproj)"')) { & $add $s.DirectoryName $m.Groups[1].Value }
        # .slnx spells it as an attribute: <Project Path="src/App/App.csproj" />
        foreach ($m in [regex]::Matches("$txt", 'Path\s*=\s*"([^"]+\.csproj)"')) { & $add $s.DirectoryName $m.Groups[1].Value }
    }
    foreach ($p in $projs) {
        $txt = Get-Content -LiteralPath $p.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches("$txt", '(?i)<ProjectReference\s+Include\s*=\s*"([^"]+)"')) { & $add $p.DirectoryName $m.Groups[1].Value }
    }
    $orphans = @($projs | Where-Object { -not $ref.Contains($_.FullName) } |
            ForEach-Object { ($_.FullName.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/' })
    if (-not $orphans) { return }
    "[WARN] orphan projects: $($orphans.Count) project(s) no solution or project references -- advisory, not a failure"
    $orphans | Select-Object -First 20 | ForEach-Object { "       $_" }
    if ($orphans.Count -gt 20) { "       ... $($orphans.Count - 20) more" }
}

# quality-gate#50: on-demand mutation testing (qgate -Mutate), never part of a hook run.
# `gremlins unleash` mutates covered code and reruns the tests; a mutant the tests still
# pass on (LIVED) is an assertion gap. -Baseline scopes it to files changed since that rev
# (--diff); gremlins treats an empty diff as no filter, so the whole module then runs.
# Advisory: survivors are a [WARN], never a failure. Returns lines; a [PASS] when none lived.
# ponytail: no overall time cap -- gremlins' own per-mutant timeout bounds each test run;
# a wall-clock budget belongs here if a whole-module run proves too slow in practice.
function Get-GoMutants([string]$Dir, [string]$Baseline) {
    $diff = if ($Baseline) { @('--diff', $Baseline) } else { @() }
    $prev = $global:LASTEXITCODE
    Push-Location $Dir
    try { $out = @(& gremlins unleash @diff --output-statuses l . 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { Pop-Location; $global:LASTEXITCODE = $prev }
    $sum = $out | Where-Object { $_ -match 'Killed: (\d+), Lived: (\d+), Not covered: (\d+)' } | Select-Object -Last 1
    if ($code -ne 0 -or -not $sum) {
        # Windows gremlins also prints "impossible to remove temporary folder" -- not the cause.
        $why = @($out | Where-Object { $_.Trim() -and $_ -notmatch 'remove temporary folder|^\s+\S*gremlins-\d+' }) | Select-Object -Last 1
        return "[WARN] gremlins could not run on this module -- $why"
    }
    $null = $sum -match 'Killed: (\d+), Lived: (\d+), Not covered: (\d+)'
    $killed, $lived, $uncovered = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
    if ($lived -eq 0) { return "[PASS] gremlins: $killed mutant(s) killed, 0 lived ($uncovered not covered by tests)" }
    "[WARN] gremlins: $lived surviving mutant(s) of $($killed + $lived) tested ($uncovered not covered) -- advisory, not a failure"
    $hits = @($out | Where-Object { $_ -match '^\s*LIVED ' } | ForEach-Object { $_.Trim() })
    $hits | Select-Object -First 20 | ForEach-Object { "       $_" }
    if ($hits.Count -gt 20) { "       ... $($hits.Count - 20) more: run gremlins unleash -S l" }
}

# quality-gate#46: qgate.json {"go": {"deterministic": ["server/internal/sim", ...]}} --
# package directories, relative to the repository root, that must replay bit-for-bit.
# Same contract as Get-DeployEntries: $null when nothing is declared, else .Dirs
# (absolute) and .Error. Opt-in only: no key, no check.
function Get-GoDeterministic([string]$Root) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $null -eq $json.go -or $json.go.PSObject.Properties.Name -notcontains 'deterministic') { return $null }
    $raw = $json.go.deterministic
    $bad = { param($m) [pscustomobject]@{ Dirs = @(); Error = $m } }
    if ($raw -isnot [Array]) { return (& $bad 'qgate.json "go.deterministic" must be an array of package directories') }
    $dirs = @()
    foreach ($e in $raw) {
        if ($e -isnot [string] -or -not $e.Trim()) { return (& $bad 'qgate.json "go.deterministic" entries must be non-empty strings') }
        $d = Join-Path $Root $e
        if (-not (Test-Path $d -PathType Container)) { return (& $bad "qgate.json go.deterministic '$e' is not a directory") }
        $dirs += (Resolve-Path $d).Path.TrimEnd('\', '/')
    }
    if (-not $dirs) { return $null }
    [pscustomobject]@{ Dirs = $dirs; Error = '' }
}

# quality-gate#40: qgate.json {"go": {"lintGoos": ["linux"]}} -- extra GOOS targets that
# go vet and golangci-lint run under at -Full, so a _linux.go file is not first read by
# CI. Opt-in only: cross-GOOS turns cgo off, and a cgo package or a Windows-only import
# then fails for reasons that are not defects (measured on a fixture), so no repo gets it
# unasked. Same contract as Get-GoDeterministic: $null, or .Goos and .Error. The host's
# own GOOS is dropped -- the normal phases already ran it.
function Get-GoLintGoos([string]$Root, [string]$HostGoos) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $null -eq $json.go -or $json.go.PSObject.Properties.Name -notcontains 'lintGoos') { return $null }
    $raw = $json.go.lintGoos
    $bad = { param($m) [pscustomobject]@{ Goos = @(); Error = $m } }
    if ($raw -isnot [Array]) { return (& $bad 'qgate.json "go.lintGoos" must be an array of GOOS names, e.g. ["linux"]') }
    $known = @(go tool dist list 2>$null | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $goos = @()
    foreach ($e in $raw) {
        if ($e -isnot [string] -or ($known -and $e -notin $known)) { return (& $bad "qgate.json go.lintGoos '$e' is not a GOOS (go tool dist list)") }
        if ($e -ne $HostGoos -and $e -notin $goos) { $goos += $e }
    }
    if (-not $goos) { return $null }
    [pscustomobject]@{ Goos = $goos; Error = '' }
}

# quality-gate#111: qgate.json {"go": {"tags": ["valheim", "windrose"]}} -- build-tag sets.
# A repo whose main package lives entirely behind tags (one binary per tag) could never be
# green, and its tagged files were never vetted or linted. Each entry is one set, as
# `-tags` takes it ("a,b" = both at once); the Go stack runs once per set. Same contract as
# Get-GoLintGoos: $null, or .Sets and .Error.
function Get-GoTags([string]$Root) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $null -eq $json.go -or $json.go.PSObject.Properties.Name -notcontains 'tags') { return $null }
    $raw = $json.go.tags
    $bad = { param($m) [pscustomobject]@{ Sets = @(); Error = $m } }
    if ($raw -isnot [Array]) { return (& $bad 'qgate.json "go.tags" must be an array of build-tag sets, e.g. ["valheim", "windrose"]') }
    $sets = @()
    foreach ($e in $raw) {
        if ($e -isnot [string] -or $e -notmatch '^[\w.]+(,[\w.]+)*$') { return (& $bad "qgate.json go.tags '$e' is not a build-tag set (tag names, comma-separated)") }
        if ($e -notin $sets) { $sets += $e }
    }
    if (-not $sets) { return $null }
    [pscustomobject]@{ Sets = $sets; Error = '' }
}

# quality-gate#103: qgate.json {"go": {"flaky": true}} -- re-run the CHANGED test packages
# under constrained scheduling, where a test that treats a short wall-clock window as a
# verdict ("no pong in 100ms" = "the client is dead") stops passing. Reported from the
# field: a commit that touched no test at all turned a 2-core Windows CI runner red twice,
# because a new CPU-heavy package now ran in parallel with an already-tight heartbeat test.
# The gate could not see it -- on an idle dev machine those tests pass every time.
#
# `-cpu 1,2` is the whole mechanism: GOMAXPROCS=1 makes one busy goroutine delay every
# other one, which is what a starved runner does, and it is portable (no affinity masks,
# no burner processes). Probabilistic, not a proof: the reported incident reproduced in
# 4 of 80 one-core runs, and `-race -cpu 1,2 -count=40` surfaced a second race that plain
# `-count=30` never did.
#
# Opt-in and minutes long, so: -Full only, changed test packages only, a wall-clock budget,
# and ADVISORY by default -- "fail": true is how a repo asks for a verdict.
# Same contract as Get-GoDeterministic: $null when nothing is declared, else the settings
# and .Error. `true` means every default; an object overrides the ones it names.
function Get-GoFlaky([string]$Root) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $null -eq $json.go -or $json.go.PSObject.Properties.Name -notcontains 'flaky') { return $null }
    $raw = $json.go.flaky
    $bad = { param($m) [pscustomobject]@{ Error = $m } }
    $cfg = [pscustomobject]@{ Count = 20; Budget = 180; Cpu = '1,2'; Race = $true; Fail = $false; Packages = @(); Error = '' }
    if ($raw -is [bool]) {
        if (-not $raw) { return $null }
    } elseif ($raw -is [psobject] -and $raw.GetType().Name -eq 'PSCustomObject') {
        $known = 'count', 'budget', 'cpu', 'race', 'fail', 'packages'
        $unknown = @($raw.PSObject.Properties.Name | Where-Object { $_ -notin $known })
        if ($unknown) { return (& $bad "qgate.json go.flaky has unknown key(s): $($unknown -join ', ') -- known: $($known -join ', ')") }
        foreach ($p in $raw.PSObject.Properties) {
            switch ($p.Name) {
                'count' {
                    if ($p.Value -isnot [int] -and $p.Value -isnot [long]) { return (& $bad 'qgate.json "go.flaky.count" must be a number of test runs') }
                    if ($p.Value -lt 1 -or $p.Value -gt 500) { return (& $bad 'qgate.json "go.flaky.count" must be between 1 and 500') }
                    $cfg.Count = [int]$p.Value
                }
                'budget' {
                    if ($p.Value -isnot [int] -and $p.Value -isnot [long]) { return (& $bad 'qgate.json "go.flaky.budget" must be a number of seconds') }
                    if ($p.Value -lt 10 -or $p.Value -gt 3600) { return (& $bad 'qgate.json "go.flaky.budget" must be between 10 and 3600 seconds') }
                    $cfg.Budget = [int]$p.Value
                }
                'cpu' {
                    if ("$($p.Value)" -notmatch '^\d+(,\d+)*$') { return (& $bad 'qgate.json "go.flaky.cpu" must be a GOMAXPROCS list like "1,2"') }
                    $cfg.Cpu = "$($p.Value)"
                }
                'race' {
                    if ($p.Value -isnot [bool]) { return (& $bad 'qgate.json "go.flaky.race" must be true or false') }
                    $cfg.Race = [bool]$p.Value
                }
                'fail' {
                    if ($p.Value -isnot [bool]) { return (& $bad 'qgate.json "go.flaky.fail" must be true or false') }
                    $cfg.Fail = [bool]$p.Value
                }
                'packages' {
                    if ($p.Value -isnot [Array]) { return (& $bad 'qgate.json "go.flaky.packages" must be an array of package directories') }
                    $dirs = @()
                    foreach ($e in $p.Value) {
                        if ($e -isnot [string] -or -not $e.Trim()) { return (& $bad 'qgate.json "go.flaky.packages" entries must be non-empty strings') }
                        $d = Join-Path $Root $e
                        if (-not (Test-Path $d -PathType Container)) { return (& $bad "qgate.json go.flaky.packages '$e' is not a directory") }
                        $dirs += (Resolve-Path $d).Path.TrimEnd('\', '/')
                    }
                    $cfg.Packages = $dirs
                }
            }
        }
    } else {
        return (& $bad 'qgate.json "go.flaky" must be true or an object, e.g. {"count": 20, "budget": 180, "fail": false}')
    }
    $cfg
}

# The dynamic half of #103. $Pkgs are absolute package directories inside the module at
# $Dir; each is run once as `go test -count=N -cpu ... [-race]`, sequentially, until the
# budget is spent -- the packages left out are named rather than silently dropped.
# A failure prints the exact command that produced it: the report exists to hand the
# reader a reproduction, and re-running a probabilistic check by memory is guesswork.
# ponytail: one invocation per package, no burner processes and no affinity mask; the
# catch rate is whatever -cpu 1 plus $Count buys.
function Invoke-GoFlakyTests([string]$Dir, $Cfg, [string[]]$Pkgs) {
    $prev = $global:LASTEXITCODE
    $res = [pscustomobject]@{ Ran = 0; Failed = 0; Lines = @(); Warn = @() }
    Push-Location $Dir
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $skipped = @()
        foreach ($p in $Pkgs) {
            $r = [IO.Path]::GetRelativePath($Dir, $p).Replace('\', '/')
            $rel = if ($r -eq '.') { '.' } else { "./$r" }
            if ($sw.Elapsed.TotalSeconds -ge $Cfg.Budget) { $skipped += $rel; continue }
            $tArgs = @("-count=$($Cfg.Count)", "-cpu=$($Cfg.Cpu)", '-timeout=10m')
            if ($Cfg.Race) { $tArgs += '-race' }
            $out = (& go test @tArgs $rel 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $res.Ran++
            if ($code -eq 0) { continue }
            $res.Failed++
            $res.Lines += "$(if ($Cfg.Fail) { '[FAIL]' } else { '[WARN]' }) flaky tests: $rel failed under constrained scheduling"
            $res.Lines += "       run: go test $($tArgs -join ' ') $rel"
            $res.Lines += @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 12 | ForEach-Object { "       $($_.TrimEnd())" })
        }
        if ($skipped) { $res.Warn += "[WARN] flaky tests: budget $($Cfg.Budget)s spent -- not run: $($skipped -join ', ')" }
    } finally { Pop-Location; $global:LASTEXITCODE = $prev }
    $res
}

# The cheap static half of #103, advisory and under the same opt-in: a *_test.go file that
# starts a listener, a process or a goroutine AND treats a sub-second wall-clock wait as an
# assertion deadline. Under CPU starvation that wait expires for reasons that are not the
# code's, which is exactly how the reported incident failed.
# A wait that must NOT fire (a negative case: nothing arrived within the window) is fine
# under starvation -- it only gets weaker -- so the scan takes the positive deadline forms:
# time.After / time.Sleep / context.WithTimeout as the body of a wait.
# ponytail: regex over source lines, not the AST -- a duration built from a variable, or
# assembled across lines, is not seen; expect false positives on deliberate short sleeps.
function Get-GoFlakyGaps([string]$Dir) {
    $ms = {
        param($Text)
        $hits = @()
        foreach ($m in [regex]::Matches($Text, '(?:time\.After|time\.Sleep|WithTimeout)\s*\([^()\n]*?(?:(\d+)\s*\*\s*)?time\.(Second|Millisecond|Microsecond|Nanosecond)')) {
            $n = if ($m.Groups[1].Success) { [double]$m.Groups[1].Value } else { 1 }
            $unit = switch ($m.Groups[2].Value) { 'Second' { 1000 } 'Millisecond' { 1 } 'Microsecond' { 0.001 } default { 0.000001 } }
            if ($n * $unit -lt 1000) { $hits += $m.Value.Trim() }
        }
        $hits
    }
    $files = @(Get-ChildItem $Dir -Recurse -File -Filter '*_test.go' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](testdata|vendor)[\\/]' })
    $gaps = @(foreach ($f in $files) {
            $txt = [IO.File]::ReadAllText($f.FullName)
            if ($txt -notmatch 'net\.Listen|httptest\.New|exec\.Command|(?m)^\s*go\s+(func\s*\(|[\w.]+\s*\()') { continue }
            $h = @(& $ms $txt)
            if (-not $h) { continue }
            "$([IO.Path]::GetRelativePath($Dir, $f.FullName).Replace('\', '/')) ($($h.Count): $(($h | Select-Object -Unique -First 3) -join ', '))"
        })
    if ($gaps) {
        "[WARN] flaky tests: $($gaps.Count) test file(s) use a sub-second wait as a deadline beside a listener, process or goroutine -- advisory, not a failure"
        $gaps | Select-Object -First 10 | ForEach-Object { "       $_" }
        if ($gaps.Count -gt 10) { "       ... $($gaps.Count - 10) more" }
    }
}

# Runs $Body with GOOS set and cgo off, then puts both variables back as they were.
function Invoke-WithGoos([string]$Goos, [scriptblock]$Body) {
    $prev = $env:GOOS, $env:CGO_ENABLED
    $env:GOOS = $Goos; $env:CGO_ENABLED = '0'
    try { & $Body } finally { $env:GOOS, $env:CGO_ENABLED = $prev }
}

# quality-gate#46: the purity profile over the deterministic packages of the module in
# $Dir. forbidigo + depguard through golangci-lint with a generated config (tests
# excluded: a property test may use rand), then gate/gopurity for what those linters
# cannot express -- range over a map, go and select statements. Advisory until
# calibrated on a real consumer repo.
# ponytail: import bans are depguard prefixes (os also bans os/exec, io bans io/fs);
# float literals with no named float type (x := 1.5) are not flagged; map range is found
# by go/types, so a package that fails to type-check can hide one.
function Get-GoPurity([string]$Dir, [string[]]$Pkgs) {
    $prev = $global:LASTEXITCODE
    $cfg = Join-Path ([IO.Path]::GetTempPath()) "qgate-purity-$PID.yml"
    [IO.File]::WriteAllText($cfg, @'
version: "2"
run:
  tests: false
  relative-path-mode: wd
linters:
  default: none
  enable: [forbidigo, depguard]
  settings:
    forbidigo:
      analyze-types: true
      forbid:
        - pattern: ^float(32|64)$
          msg: floating point differs across platforms -- use fixed-point
        - pattern: ^time\.(Now|Since|Until)$
          msg: wall clock -- pass time in as input
        - pattern: ^os\.(Getenv|LookupEnv|Environ)$
          msg: environment -- pass configuration in as input
    depguard:
      rules:
        purity:
          deny:
            - { pkg: math/rand, desc: "nondeterministic -- use the seeded rng package" }
            - { pkg: crypto/rand, desc: "nondeterministic -- use the seeded rng package" }
            - { pkg: os, desc: "side effects do not belong in a deterministic package" }
            - { pkg: net, desc: "side effects do not belong in a deterministic package" }
            - { pkg: io, desc: "side effects do not belong in a deterministic package" }
'@)
    Push-Location $Dir
    try {
        $rel = @($Pkgs | ForEach-Object { './' + [IO.Path]::GetRelativePath($Dir, $_).Replace('\', '/') })
        $hits = @()
        if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
            $hits += @(& golangci-lint run --allow-serial-runners -c $cfg --output.text.print-issued-lines=false --output.text.colors=false `
                    --max-issues-per-linter=0 --max-same-issues=0 @rel 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '\((forbidigo|depguard)\)$' })
        }
        $hits += @(& go run (Join-Path $PSScriptRoot 'gopurity\main.go') @Pkgs 2>$null | ForEach-Object {
                if ($_ -match '^(.+?\.go)(:\d+:\d+: .*)$') { [IO.Path]::GetRelativePath($Dir, $Matches[1]) + $Matches[2] } })
    } finally { Pop-Location; Remove-Item $cfg -Force -ErrorAction SilentlyContinue; $global:LASTEXITCODE = $prev }
    if (-not $hits) { return }
    "[WARN] purity: $($hits.Count) finding(s) in deterministic packages (qgate.json go.deterministic) -- advisory, not a failure"
    $hits | ForEach-Object { "       $($_.Replace('\', '/'))" }
}

# quality-gate#48: a deterministic package whose tests hold no property test
# (pgregory.net/rapid, testing/quick) and no Fuzz target. Text scan of its _test.go files.
function Get-GoPropertyGaps([string]$Dir, [string[]]$Pkgs) {
    $gaps = @(foreach ($p in $Pkgs) {
            $covered = @(Get-ChildItem $p -Filter '*_test.go' -File -ErrorAction SilentlyContinue | Where-Object {
                    [IO.File]::ReadAllText($_.FullName) -match '\brapid\.(Check|MakeCheck|MakeFuzz)\b|\bquick\.(Check|CheckEqual)\b|func\s+Fuzz\w*\s*\(\s*\w+\s+\*testing\.F\b' })
            if (-not $covered) { [IO.Path]::GetRelativePath($Dir, $p).Replace('\', '/') }
        })
    if ($gaps) {
        "[WARN] property tests: $($gaps.Count) deterministic package(s) have no property or fuzz test: $($gaps -join ', ') -- see templates/go-determinism_test.go (pgregory.net/rapid)"
    }
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
        # A smoke check launches an app instead of a command line (gate/smoke.ps1). The
        # shape is checked here so a malformed one is a [FAIL] custom, never a silent skip.
        $smoke = $c.smoke
        if ($null -ne $smoke) {
            if ($smoke -isnot [Management.Automation.PSCustomObject]) { return (& $bad "qgate.json check '$name' has a `"smoke`" that is not an object") }
            if ($null -ne $c.run) { return (& $bad "qgate.json check '$name' declares both `"run`" and `"smoke`" -- pick one") }
            if ($smoke.exe -isnot [string] -or -not $smoke.exe.Trim()) {
                return (& $bad "qgate.json check '$name' smoke needs a non-empty `"exe`" string")
            }
            if ($smoke.stages -isnot [Array] -or $smoke.stages.Count -eq 0 -or
                @($smoke.stages | Where-Object { $_.name -isnot [string] -or $_.ready -isnot [string] -or -not $_.ready })) {
                return (& $bad "qgate.json check '$name' smoke needs a `"stages`" array of {name, ready}")
            }
            # Smoke opens a real app for tens of seconds: never on every agent turn.
            if ($null -ne $c.level -and [string]$c.level -cne 'full') {
                return (& $bad "qgate.json check '$name' is a smoke check -- its level can only be full")
            }
            $run = ''
        } else {
            $run = $c.run
            if ($run -isnot [string] -or -not $run.Trim()) {
                return (& $bad "qgate.json check '$name' needs a non-empty `"run`" string")
            }
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
        $checks += [pscustomobject]@{ Name = $name; Run = $run; Level = $level; TimeoutSec = $sec; Smoke = $smoke }
    }
    [pscustomobject]@{ Checks = $checks; Error = '' }
}

# qgate.json "deploy": [{"built": "<path>", "deployed": "<path>"}] -- the copy a game or
# host actually loads, compared with the one this tree builds (quality-gate#26). Paths,
# not commands, so no trust is needed. Same contract as Get-CustomChecks: $null when
# nothing is declared, else .Entries (Built/Deployed) and .Error.
function Get-DeployEntries([string]$Root) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $null }
    $json = try { Get-Content $file -Raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $json -or $json.PSObject.Properties.Name -notcontains 'deploy') { return $null }
    $raw = $json.deploy
    if ($raw -isnot [Array]) { return [pscustomobject]@{ Entries = @(); Error = 'qgate.json "deploy" must be an array' } }
    if ($raw.Count -eq 0) { return $null }
    $entries = @()
    for ($i = 0; $i -lt $raw.Count; $i++) {
        $e = $raw[$i]
        if ($e.built -isnot [string] -or -not $e.built.Trim() -or $e.deployed -isnot [string] -or -not $e.deployed.Trim()) {
            return [pscustomobject]@{ Entries = @(); Error = "qgate.json deploy #$($i + 1) needs non-empty `"built`" and `"deployed`" strings" }
        }
        $entries += [pscustomobject]@{ Built = $e.built; Deployed = $e.deployed }
    }
    [pscustomobject]@{ Entries = $entries; Error = '' }
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
                ',"level":' + (ConvertTo-Json $c.Level -Compress) + ',"timeoutSec":' + $c.TimeoutSec +
                # Only when present, so every hash trusted before smoke existed still holds.
                # ponytail: key order inside smoke is part of the hash; reordering it re-asks trust.
                $(if ($c.Smoke) { ',"smoke":' + (ConvertTo-Json $c.Smoke -Compress -Depth 10) }) + '}'
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

    # A go.mod under testdata/ of an enclosing Go module is a fixture of that module's
    # tests, not a module of its own (#107): the go tool never enters testdata, so
    # `go build ./...` from the parent is silent about it, and gating it separately
    # turned a green repo red over a library-only fixture. Only with a go.mod above it:
    # this gate's own testdata/go-fixture sits under no Go module and must stay a stack.
    $goMods = @(Find-Marker $Root @('go.mod'))
    $goModDirs = @($goMods | ForEach-Object { $_.DirectoryName.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar })
    foreach ($m in $goMods) {
        $dir = $m.DirectoryName
        if ($dir.Substring($Root.Length) -match '(^|[\\/])testdata([\\/]|$)' -and
            ($goModDirs | Where-Object { $_.Length -lt $dir.Length + 1 -and $dir.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
            continue
        }
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
    # After custom, so a build declared in `checks` has written the artifact first.
    if (Get-DeployEntries $Root) {
        $stacks += [pscustomobject]@{ Stack = 'deploy'; Dir = $Root; Rel = ''; Marker = 'qgate.json'; Implemented = $true; Warn = '' }
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
