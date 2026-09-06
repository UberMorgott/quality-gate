# Quality gate: one entry point for every static check in the repository.
#
# Token-cheap by design: on success one line per stack, on failure the raw tool
# output truncated to 6000 chars. Fail-fast -- the first failing phase stops the
# rest, because a linter report on non-compiling code is noise.
#
# Levels: -Fast drops the expensive bundling phase and is what the agent Stop
# hook runs on every turn. -Full (the default) adds it back and is what the
# pre-commit hook and CI run.
#
# With no stack switch the changed side is auto-detected from git status.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Only,      # go | web | rust | proto | godot | dotnet -- restrict to these stacks (one value: -Only go,web)
    [switch]$All,         # every detected stack, ignore git status
    [switch]$Fast,
    [switch]$Full,
    [switch]$Quiet,
    [switch]$Why,         # provenance: which marker file created (or did not create) each phase
    [string]$Baseline,    # git rev: report only issues newer than it (adoption on a dirty codebase)
    [string]$Root,        # repo root; defaults to the git root of the cwd
    # Nothing binds here on a correct call. Positional binding used to swallow the
    # second word of `-Only go python` into -Baseline, and the run then died with
    # "baseline revision not found: python" -- a verdict about a feature the user
    # never touched. PositionalBinding=$false plus this catch-all turns a stray value
    # into a reason about the argument that was actually wrong.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'detect.ps1')

# --- the command line ------------------------------------------------------
# `if ($Only)` was a truthiness test, and PowerShell reads an empty value as absence
# (PLAYBOOK.md 0.1): `-Only ''` bound an empty string, tested false, and silently
# degraded to "no filter at all" -- the run widened to every stack and explained
# itself with a rule about paths instead of with the flag it had been handed. An
# explicitly passed -Only is now asked of $PSBoundParameters, never of the value.
$onlyGiven = $PSBoundParameters.ContainsKey('Only')
# PowerShell parses a bare `-Only go,web` as an ARRAY, and the qgate shim flattens it
# back onto the child command line as `-Only go web`: the help text's own example
# landed here as a stray `web`, and the error then offered that same failing spelling
# as the remedy. Stack names after -Only are its value, whatever the shell did to the
# comma. Anything else is still the stray argument that used to bind to -Baseline.
if ($Extra) {
    $stray = @(if ($onlyGiven) { $Extra | Where-Object { $_ -notin $script:KnownMarkers.Keys } } else { $Extra })
    if ($stray) {
        Write-Output "[FAIL] unexpected argument(s): $($stray -join ' ') -- several stacks are ONE value: -Only `"go,web`""
        exit 1
    }
    $Only = @($Only) + $Extra
}
if ($onlyGiven) {
    # `-Only go,web` arrives as one string through the .cmd shim and as two elements
    # from PowerShell; splitting here makes both spellings mean the same thing.
    $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Only.Count -eq 0) {
        Write-Output "[FAIL] -Only was given an empty value -- name at least one stack (known: $(($script:KnownMarkers.Keys) -join ', '))"
        exit 1
    }
}

$MaxChars = 6000
if (-not $Root) { $Root = Get-RepoRoot (Get-Location).Path }
# Fail closed: an unusable root is a failure, not "nothing to check".
if (-not (Test-Path $Root)) { Write-Output "[FAIL] root not found: $Root"; exit 1 }
$Root = (Resolve-Path $Root).Path

$stacks = @(Get-Stacks $Root)
$allStacks = $stacks

# Optional qgate.json: {"tools": {"golangci-lint": "2.13.1"}}. Linter output is not
# stable across patch releases, so a green run against a different version than CI
# pins predicts nothing. A warning, never a failure -- the gate does not install
# toolchains.
$pinFile = Join-Path $Root 'qgate.json'
if (Test-Path $pinFile) {
    try { $pins = (Get-Content $pinFile -Raw | ConvertFrom-Json).tools } catch { $pins = $null }
    $pinMismatch = @()
    foreach ($p in $pins.PSObject.Properties) {
        $known = $true
        $have = switch ($p.Name) {
            'go' { if ((& go version 2>$null) -match 'go(\d+\.\d+(\.\d+)?)') { $Matches[1] } }
            'golangci-lint' { if ((& golangci-lint --version 2>$null) -match 'version (\S+)') { $Matches[1].TrimStart('v') } }
            'cargo' { if ((& cargo --version 2>$null) -match 'cargo (\S+)') { $Matches[1] } }
            'node' { ((& node --version 2>$null) -as [string]) -replace '^v', '' }
            'buf' { if ((& buf --version 2>$null) -match '(\d+\.\d+\.\d+\S*)') { $Matches[1] } }
            # gdformat and gdlint ship from one pip package at one version, so
            # either name (or the package name) pins both.
            { $_ -in 'gdformat', 'gdlint', 'gdtoolkit' } {
                if ((& gdformat --version 2>$null) -match '(\d+\.\d+(\.\d+)?)') { $Matches[1] }
            }
            # gdlint rule sets change between gdtoolkit releases and Godot's error
            # output changes between 4.x minors, so a green run against a different
            # Godot than CI's predicts nothing.
            'godot' {
                $g = Get-GodotBin
                if ($g -and ((& $g --version 2>$null) -match '(\d+\.\d+(\.\d+)?)')) { $Matches[1] }
            }
            default { $known = $false; $null }
        }
        if (-not $known) {
            # A typo'd key used to be a silent no-op that read as enforcement.
            Write-Output "[WARN] qgate.json pins unknown tool '$($p.Name)' -- known: go, golangci-lint, cargo, node, buf, gdformat/gdlint/gdtoolkit, godot"
        } elseif ($have -and $have -ne ([string]$p.Value).TrimStart('v')) {
            $pinMismatch += "$($p.Name) $have on PATH, qgate.json pins $($p.Value)"
        }
    }
    # A pin exists to make a run reproducible. At the full level -- the one that
    # guards a commit and CI -- a warning does not do that: the run passes, on a
    # different compiler or linter than the repository declared, and the result
    # says nothing about the pinned version. Same rule the missing golangci-lint
    # and gdtoolkit already follow: warn in the fast lane, fail at the full level.
    # Fixing it is a choice between two honest actions, so the message names both.
    if ($pinMismatch) {
        if ($Full) {
            foreach ($m in $pinMismatch) { Write-Output "[FAIL] $m -- install the pinned version or update qgate.json" }
            # $script:Failed and Fail are defined below, so exiting here is the
            # only way to make this verdict stick.
            exit 1
        }
        foreach ($m in $pinMismatch) { Write-Output "[WARN] $m -- this run may not match CI" }
    }
}

if ($Why) {
    foreach ($s in $stacks) { Write-Output "[WHY] $($s.Stack) at $(if ($s.Rel) { $s.Rel + '/' } else { './' }) -- found $($s.Marker)" }
    foreach ($k in $script:KnownMarkers.Keys) {
        if (-not ($stacks | Where-Object { $_.Stack -eq $k })) { Write-Output "[WHY] $k -- absent, no $($script:KnownMarkers[$k])" }
    }
}
# A repo with no marker file is a repo the gate was never given anything to check:
# it costs nothing and it says so. But NOT when -Only named a stack -- this return
# fired BEFORE -Only was validated below, so `qgate -Only go` in a repo with no
# go.mod exited 0 over zero checks. The user named a stack and got a green run.
if ($stacks.Count -eq 0 -and -not $onlyGiven) {
    if (-not $Quiet) { Write-Output '[SKIP] no known stack found' }
    exit 0
}

# Returns $null when this is not a git repository -- distinct from "no changes",
# which is an empty list. Conflating the two let a non-git directory pass the
# default run without a single check.
function Get-ChangedPaths([string]$Repo) {
    # -z: NUL separated and NOT quoted/escaped. With plain --porcelain git escapes
    # spaces, tabs and every non-ASCII byte, and the escaped string then matches no
    # stack directory -- the gate would check the wrong stack, or none.
    # --untracked-files=all: git's DEFAULT collapses a wholly untracked directory to one
    # entry, `NewFolder/`. Measured: a new `NewFolder/Ugly.cs` with a whitespace violation
    # came back as the directory, matched no `*.cs` filter and no stack prefix, and the
    # fast lane reported `[SKIP] format -- no changed .cs files` and exited 0 while `-All`
    # found the violation. Every stack narrows through this one function, so the whole
    # fast lane was blind to a file added inside a new directory. Ignored files are still
    # excluded -- -uall widens the listing, it does not switch off .gitignore.
    $raw = (& git -C $Repo status --porcelain=v1 -z --untracked-files=all 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) { return $null }
    $paths = @()
    $items = @($raw -split "`0")
    for ($i = 0; $i -lt $items.Count; $i++) {
        $e = $items[$i]
        if ($e.Length -le 3) { continue }
        $paths += $e.Substring(3)
        # A rename or copy stores the source path as the next record; skip it, the
        # destination above is the path that matters.
        if ($e[0] -eq 'R' -or $e[0] -eq 'C' -or $e[1] -eq 'R' -or $e[1] -eq 'C') { $i++ }
    }
    $paths += @((& git -C $Repo diff --name-only -z HEAD 2>$null | Out-String) -split "`0")
    # The leading comma is the whole contract: PowerShell enumerates a collection on
    # return, so a bare `@(...)` hands an EMPTY result back as $null and the caller
    # reads "no changes" as "not a git repository". That made the [SKIP] no changes
    # branch dead code, checked every stack on every clean-tree agent turn, and said
    # "not a git repository" inside an obvious git work tree.
    # Trim BEFORE filtering. Out-String appends a trailing newline, so the last
    # element of the split is "`r`n" -- non-empty, therefore truthy, therefore it
    # survived a filter placed first and only then trimmed down to ''. That empty
    # string sorts to the front, matches no stack prefix, and widened the run to
    # every stack on the FIRST iteration: the fast lane never narrowed for a tracked
    # edit at all, and blamed proto for it.
    , @($paths | ForEach-Object { $_.Trim("`n", "`r") -replace '\\', '/' } | Where-Object { $_ } | Sort-Object -Unique)
}

# --- select which stacks to run -------------------------------------------
if ($onlyGiven) {
    # `-Only nonsense` checked nothing and exited 0, which reads exactly like a clean
    # run: a typo'd `-Only godo` in a CI or lefthook invocation was a green pipeline.
    # A warning was not enough -- nobody reads a warning in a passing log. This exits
    # here rather than calling Fail because $script:Failed and Fail are both defined
    # below, so setting the flag from here would be overwritten a moment later.
    $missing = @($Only | Where-Object { $o = $_; -not ($allStacks | Where-Object { $_.Stack -eq $o }) })
    if ($missing) {
        foreach ($m in $missing) {
            Write-Output "[FAIL] -Only $m -- no such stack detected here (known: $(($script:KnownMarkers.Keys) -join ', '))"
        }
        exit 1
    }
    $stacks = @($stacks | Where-Object { $Only -contains $_.Stack })
    # `-Only <a stack the gate does not implement>` used to be its own special case
    # right here. It no longer needs one: the zero-phase invariant at the bottom of
    # this file catches it, and every other door into the same room, once.
} elseif (-not $All) {
    $changed = Get-ChangedPaths $Root
    if ($null -eq $changed) {
        # No git, so nothing to narrow by. Checking everything is the only honest
        # answer -- an empty change list here used to mean "[SKIP] no changes".
        if (-not $Quiet) { Write-Output '[WARN] not a git repository -- checking every stack' }
    } elseif ($changed.Count -eq 0) {
        if (-not $Quiet) { Write-Output '[SKIP] no changes' }
        exit 0
    } else {
        $selected = @()
        $widenedBy = $null
        foreach ($p in $changed) {
            # Longest match wins: with nested modules a/go.mod and a/b/go.mod, a
            # file under a/b belongs to a/b alone.
            $owner = $stacks | Where-Object { $_.Rel -and $p.StartsWith("$($_.Rel)/") } |
                Sort-Object { $_.Rel.Length } -Descending | Select-Object -First 1
            # A path outside every stack directory (CI config, build scripts, root
            # files) can affect any of them -> run everything.
            if (-not $owner) { $selected = $stacks; $widenedBy = $p; break }
            $selected += $owner
        }
        $stacks = @($selected | Sort-Object Stack, Rel -Unique)
        # Generated code crosses stack boundaries: a .proto edit produces Go and
        # GDScript that nobody touched, so narrowing to the schema directory would
        # report green on a break. Conservative and cheap: re-check everything.
        #
        # Read from $selected BEFORE the widening above, never from the widened
        # $stacks: a root file pulls every stack in, proto with it, and the gate then
        # announced "proto changed" with no .proto in the change set -- a wrong reason
        # on the output whose only job is explaining the selection, and it hid the
        # rule that actually fired.
        # -ne $null, not a truthy test: an empty path is exactly what used to get
        # here, and a truthy test read it as "never widened" and fell through to the
        # proto branch. Same falsy trap as the unary comma one function up.
        if ($null -ne $widenedBy) {
            if (-not $Quiet) { Write-Output "[WHY] $widenedBy belongs to no stack -- checking all of them" }
        } elseif ($selected | Where-Object { $_.Stack -eq 'proto' }) {
            if (-not $Quiet) { Write-Output '[WHY] proto changed -- generated code crosses stacks, checking all of them' }
            $stacks = $allStacks
        }
    }
}

# A baseline that does not resolve would surface as a confusing linter error deep
# in the run; say so here instead.
if ($Baseline) {
    & git -C $Root rev-parse --verify --quiet "$Baseline^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { Write-Output "[FAIL] baseline revision not found: $Baseline"; exit 1 }
}

$script:Failed = $false
$script:Lines = @()
# How many check phases actually executed. The one number the green verdict at the
# bottom of this file is not allowed to ignore.
$script:Phases = 0

# Concurrent commits in one worktree. Git serialises the final write -- the second
# `git commit` loses -- but it does NOT protect the INDEX while a hook runs, and this
# hook runs for 40 seconds to five minutes, so the gate is what widens the window from
# milliseconds to minutes.
#
# Measured on git 2.53: agent A staged a.txt and began committing; during A's hook,
# agent B ran `git add b.txt`, which mutated the shared index; A's commit then
# captured BOTH and shipped b.txt inside A's commit. B was told `nothing to commit,
# working tree clean` -- a message shaped exactly like success, for work that had just
# been swallowed. That is what makes the next agent delete a lock file or commit from
# a stale index. `.git/index.lock` does not even exist while the hook runs, so there is
# nothing to poll for.
#
# Only inside a commit: git sets GIT_INDEX_FILE for its hooks and nothing else does,
# so a developer running `qgate` in a terminal while staging files is not this rule's
# business. `git write-tree` is the hash of the staged content and is stable across the
# whole hook window -- measured with unstaged modifications present and lefthook's
# stash active, so lefthook's own bookkeeping does not trip it. Unmerged entries make
# it fail, which is evidence of nothing, so the guard stays quiet.
$script:StagedAtStart = $null
if ($env:GIT_INDEX_FILE) {
    $tree = (& git -C $Root write-tree 2>$null)
    if ($LASTEXITCODE -eq 0) { $script:StagedAtStart = $tree }
}

function Phase {
    # -Elapsed: seconds the TOOL took, for a phase whose command ran before the block.
    # `dotnet msbuild` and `dotnet format` run ahead of their Phase (their output has to
    # be classified before it can be a verdict), so the stopwatch here wrapped nothing
    # and printed `(0.0s)` for a phase that cost six seconds -- a time that says the
    # opposite of the truth is worse than no time at all.
    param([string]$Name, [scriptblock]$Body, [switch]$FailIfOutput, [double]$Elapsed = -1)
    # A phase the run never reached must not vanish. Reported from the field: a file with a
    # whitespace nit AND a compile error printed `[FAIL] format` and no `build` line at all,
    # so the report read as "the only thing wrong here is whitespace". Same rule the stack
    # loop already applies one level up -- the work is still skipped, the skipping is on the
    # record. Not counted as a phase: it did not run, and the zero-phase invariant asks how
    # many ran. Here in Phase, so every stack gets it, not just the one that reported it.
    if ($script:Failed) { $script:Lines += "[SKIP] $Name -- not run: an earlier phase failed"; return }
    $script:Phases++
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $global:LASTEXITCODE = 0
    $out = (& $Body 2>&1 | Out-String).TrimEnd()
    $sw.Stop()
    # InvariantCulture, not '{0:N1}': under a comma-decimal locale (ru-RU here) every
    # phase printed `0,0s`, so the timings the report exists to show were unreadable to
    # anything that parses them and inconsistent between machines.
    $secs = if ($Elapsed -ge 0) { $Elapsed } else { $sw.Elapsed.TotalSeconds }
    $sec = $secs.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    if (($LASTEXITCODE -ne 0) -or ($FailIfOutput -and $out)) {
        $script:Lines += "[FAIL] $Name (${sec}s)"
        if ($out) { $script:Lines += $out }
        # A phase killed because the HOST ran out of memory is not a finding about the
        # code, and the raw dump does not say which of the two it is. Reported from the
        # field: `go test -race` failed a commit twice under parallel load with
        # `VirtualAlloc ... errno=1455` -- Windows for "the paging file is too small for
        # this operation" -- then passed on the third run with nothing changed, and the
        # only thing on screen was a runtime stack blaming a package. Same class as
        # naming the stale tool binary instead of the repo: the outcome was defensible,
        # the reason printed was not the reason.
        #
        # Here in Phase, not in the Go runner: cargo, npm and buf allocate too, and
        # `out of memory` also covers node's "JavaScript heap out of memory".
        #
        # Advisory only. The phase still fails -- a run that could not finish is not a
        # run that passed, and a note that flipped an exit code would be the gate
        # deciding it knows better than the tool.
        if ($out -match '(?i)out of memory|errno=1455') {
            $script:Lines += '[NOTE] that is an allocation failure on this machine, not a verdict on the code -- retry with less running before believing it. -race is usually the first casualty.'
        }
        $script:Failed = $true
    } else {
        $script:Lines += "[PASS] $Name (${sec}s)"
    }
}

function Fail([string]$Message) {
    $script:Lines += "[FAIL] $Message"
    $script:Failed = $true
}

function Have([string]$Exe) { [bool](Get-Command $Exe -ErrorAction SilentlyContinue) }

# --- stack runners ---------------------------------------------------------
function Invoke-GoStack($s) {
    Set-Location $s.Dir
    # gofmt exits 0 even when it lists unformatted files -> failure is "any output".
    # It is also the one Go phase with no notion of modules or ignore rules: `.` means
    # the whole subtree. Claude Code checks agent worktrees out under
    # .claude/worktrees/<agent>/, so a CRLF checkout of an older commit sitting there
    # turned the ROOT repo's gate -- and its pre-commit hook -- red over files that are
    # not in its index and not its business. Every other Go phase is module-scoped and
    # already stops at the nested go.mod (measured: with a deliberately broken nested
    # module, build, vet, test, golangci-lint and govulncheck all stay green), so the
    # filter belongs here and nowhere else in this runner.
    Phase 'gofmt' {
        gofmt -l . | Where-Object { -not (Test-GitIgnored $s.Dir (Join-Path $s.Dir $_)) }
    } -FailIfOutput
    # -o into a temp dir: a bare `go build ./...` drops the linked binary of every
    # main package into the working tree.
    #
    # Keyed by module directory AND by this process. The module key alone was meant to
    # keep two agents, two worktrees or two modules from writing binaries over each
    # other, and it does -- but it still let two runs on the SAME module collide, which
    # is exactly what a pre-commit hook and a hand-run `qgate` in one repo are. Linking
    # two builds onto the same output paths at once is not something to leave to luck
    # on Windows, where an executable being written cannot be replaced.
    #
    # Removed when the phase is done: these binaries are pure by-product, nothing reads
    # them, and without this TEMP kept one directory per module ever gated on this
    # machine, forever. Directories written by older versions do not have the process
    # suffix and are left alone rather than swept up -- deleting files this run did not
    # create is not the gate's business.
    $outDir = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-build-$(Get-PathKey $s.Dir)-$PID"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    try { Phase 'go build' { go build -o $outDir ./... } }
    finally { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    Phase 'go vet' { go vet ./... }
    # The `go` directive, not the `toolchain` one: it is what both tools compare
    # themselves against, and it is what the error messages call "the targeted Go
    # version".
    $modGo = if ((Get-Content (Join-Path $s.Dir 'go.mod') -Raw) -match '(?m)^go\s+(\d+\.\d+)') { $Matches[1] }
    if (Have 'golangci-lint') {
        $stale = Test-GoToolStale 'golangci-lint' $modGo `
            'go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest'
        if ($stale) { Fail $stale }
        # No issue caps: a capped report lies about the totals, so fixing the
        # listed issues just makes new ones appear.
        # -Baseline: report only issues newer than that revision. This is the
        # recommended way to adopt the linter on a dirty codebase -- unlike a
        # per-package exclusion list it still catches a NEW defect inside an
        # untouched package. --whole-files, not just changed lines, so a touched
        # file is judged as a whole.
        $newFrom = if ($Baseline) { @('--new-from-rev', $Baseline, '--whole-files') } else { @() }
        Phase 'golangci-lint' {
            golangci-lint run --output.text.print-issued-lines=false --output.text.colors=false `
                --max-issues-per-linter=0 --max-same-issues=0 @newFrom ./...
        }
    } elseif ($Full) {
        # The full level is what guards a commit and CI. A gate that quietly drops
        # its main linter there is not a gate.
        Fail 'golangci-lint not on PATH -- required at the full level (go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest)'
    } else {
        $script:Lines += '[WARN] golangci-lint not on PATH -- phase skipped'
    }
    if ($Full) {
        # A trustworthy verdict: no cache, and shuffled so order dependence surfaces.
        Phase 'go test' { go test -count=1 -failfast -shuffle=on -timeout=10m ./... }
        # The race detector catches a bug class go vet and golangci-lint structurally
        # cannot. It needs a cgo toolchain, so its absence is a warning, not a failure.
        if ($env:CGO_ENABLED -ne '0' -and (Have 'gcc')) {
            Phase 'go test -race' { go test -race -short -failfast -timeout=15m ./... }
        } else {
            $script:Lines += '[WARN] no cgo toolchain (gcc) -- go test -race skipped'
        }
    } else {
        # Both -count=1 and -shuffle=on defeat the Go test cache, so the fast lane
        # re-ran every package on every agent turn. -short lets a repo park its slow
        # suites behind testing.Short() instead of paying for them each turn.
        Phase 'go test' { go test -short -failfast -timeout=10m ./... }
    }
    # Known vulnerabilities ARE defects, so unlike "outdated" they fail the run --
    # but only on the full level: the database lives on the network and no agent
    # turn should pay for that.
    if ($Full) {
        if (Have 'govulncheck') {
            $stale = Test-GoToolStale 'govulncheck' $modGo `
                'go install golang.org/x/vuln/cmd/govulncheck@latest'
            # Fail, not Phase: a stale binary here reports "package requires newer Go
            # version" once per package of the user's own code. Phase would print all
            # of it under a heading that says nothing.
            if ($stale) { Fail $stale }
            Phase 'govulncheck' { govulncheck ./... }
        }
        else { $script:Lines += '[WARN] govulncheck not on PATH -- phase skipped (go install golang.org/x/vuln/cmd/govulncheck@latest)' }
    }
}

function Invoke-RustStack($s) {
    Set-Location $s.Dir
    if (-not (Have 'cargo')) {
        # Same rule as node_modules: an unverifiable stack must never pass silently.
        Fail 'rust: cargo not on PATH (cannot verify this stack)'
        return
    }
    Phase 'cargo fmt' { cargo fmt --check }
    # clippy compiles as it lints, so a separate `cargo build` would only pay the
    # same cost twice. --all-targets covers tests and benches, not just the binary.
    Phase 'cargo clippy' { cargo clippy --all-targets --quiet -- -D warnings }
    Phase 'cargo test' { cargo test --quiet }
}

function Invoke-DotnetStack($s) {
    Set-Location $s.Dir
    $proj = $s.Marker
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    # The `dotnet` first on PATH can be the x86 host with no SDK beside it -- it runs,
    # it answers `--version`, and it cannot build anything ("No .NET SDKs were found").
    # So the question is the SDK list, not the executable.
    $sdks = @(if (Have 'dotnet') { (& dotnet --list-sdks 2>$null) | Where-Object { $_ } })
    if (-not $sdks) {
        # Same split as the Godot binary: every phase here needs the SDK, and failing
        # every agent turn over a toolchain the fast lane cannot install is not a gate.
        if ($Full) { Fail 'dotnet: no .NET SDK found -- required at the full level (install https://dot.net)'; return }
        $script:Lines += '[WARN] dotnet SDK not found -- dotnet stack skipped (install https://dot.net)'
        return
    }
    $sdkVers = @($sdks | ForEach-Object { ($_ -split ' ')[0] })
    $maxSdk = ($sdkVers | ForEach-Object { [int]($_ -split '\.')[0] } | Measure-Object -Maximum).Maximum

    # Evaluation only: -getProperty/-getItem run no targets, so a Directory.Build.props
    # <Error> guarding a missing game install does not fire here and the references come
    # back as readable data. That is the whole point -- a game mod's HintPath points into
    # a Steam directory that CI and half the developer machines do not have, and a build
    # failure there is a fact about the machine, not about the code.
    #
    # IsTestProject and PackageReference are asked here too, because the phases below used
    # to grep the csproj TEXT for them. Measured: with Microsoft.NET.Test.Sdk and xunit
    # pulled in through Directory.Build.props, `-All -Full` exited 0 with no `test` phase
    # and no `vuln` phase at all, while `dotnet test --no-build` on the same project found
    # the failing test and exited 1. Evaluation sees every import; a regex over one file
    # sees one file.
    $refsSw = [Diagnostics.Stopwatch]::StartNew()
    $q = (& dotnet msbuild $proj -getProperty:TargetFramework -getProperty:TargetFrameworks `
            -getProperty:IsTestProject -getItem:Reference -getItem:PackageReference -nologo 2>&1 | Out-String).Trim()
    $qCode = $LASTEXITCODE
    $refsSw.Stop()
    # A csproj msbuild cannot even evaluate IS a defect, so this one is a real phase.
    Phase 'refs' { if ($qCode -ne 0) { $q; $global:LASTEXITCODE = 1 } } -Elapsed $refsSw.Elapsed.TotalSeconds
    if ($script:Failed) { return }
    $info = try { $q | ConvertFrom-Json } catch { $null }

    # A multi-targeted project leaves the singular property EMPTY and lists them in the
    # plural one as `net8.0;net472`. Reading only TargetFramework there is a silent pass
    # over every TFM the project actually has.
    $tfms = @(
        if ($info.Properties.TargetFramework) { $info.Properties.TargetFramework }
        else { ($info.Properties.TargetFrameworks -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    )
    # net4xx builds on any modern SDK; net<major>.0 needs that major installed. Reported
    # as a skip, not a red build: a project targeting an SDK nobody here has is a gap in
    # the machine, and the raw NETSDK1045 tells the reader nothing about which one.
    foreach ($tfm in $tfms) {
        if ($tfm -match '^net(\d+)\.\d' -and [int]$Matches[1] -gt $maxSdk) {
            $script:Lines += "[SKIP] ${proj}: needs .NET SDK $($Matches[1]).x, installed $($sdkVers -join ', ')"
            return
        }
    }
    # A multi-targeted project evaluates with TargetFramework EMPTY, so everything inside
    # an `ItemGroup Condition="'$(TargetFramework)' == 'net8.0-windows'"` is simply absent
    # from the answer above. Measured on `net8.0;net8.0-windows`: the conditioned
    # <Reference> came back as `"Reference": []`, the missing game DLL went unreported,
    # and the run built the project instead of the [SKIP] it owed the reader -- CS0246.
    # One evaluation per TFM (measured at 0s each, and only for the multi-targeted case),
    # unioned. PackageReference rides along in the same call for the same reason.
    $refs = @($info.Items.Reference)
    $pkgs = @($info.Items.PackageReference)
    if (-not $info.Properties.TargetFramework) {
        foreach ($tfm in $tfms) {
            $tq = (& dotnet msbuild $proj -getItem:Reference -getItem:PackageReference `
                    -p:TargetFramework=$tfm -nologo 2>&1 | Out-String).Trim()
            # A TFM that will not evaluate is not a verdict here: `refs` above already
            # passed on the project as a whole, and the build phase is what judges code.
            $ti = if ($LASTEXITCODE -eq 0) { try { $tq | ConvertFrom-Json } catch { $null } }
            if ($ti) { $refs += @($ti.Items.Reference); $pkgs += @($ti.Items.PackageReference) }
        }
    }
    # HintPath is routinely RELATIVE to the csproj (`..\..\lib\AssetsTools.NET.dll` in a
    # real test project), so it is resolved against the project directory explicitly --
    # not against wherever the process happens to stand. The item's own FullPath field is
    # not an option: msbuild builds it from Identity, so it reads
    # `<projectdir>\AssetsTools.NET` -- the wrong directory and no extension.
    # -PathType Leaf because a reference is a FILE; a directory of that name is not one.
    # Unique by HintPath: the same reference listed under two TFMs is one missing file,
    # and the count in the message below is what the reader acts on.
    $missing = @($refs | Where-Object { $_.HintPath } | Sort-Object -Property HintPath -Unique |
        Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::GetFullPath($_.HintPath, $s.Dir)) -PathType Leaf) })

    # Whitespace only: the gate reports, it never rewrites, and a repo with no
    # .editorconfig has no style to enforce beyond it. Measured on two real mods: 1396
    # and 447 violations, so the whole project is a full-level question. The fast lane
    # judges the files this commit touches, or it blocks every commit forever.
    $fmtArgs = @($proj, '--verify-no-changes', '--no-restore', '-v', 'q')
    $runFormat = $true
    if (-not $Full -and -not $All) {
        $changed = Get-ChangedPaths $Root
        if ($null -ne $changed) {
            $prefix = if ($s.Rel) { "$($s.Rel)/" } else { '' }
            # --include is resolved against the CURRENT DIRECTORY, and an ABSOLUTE path
            # matches nothing at all -- silently, exit 0, a green format phase over an
            # unformatted file. Set-Location above put us in the project directory, so
            # these are relative to it.
            $cs = @($changed | Where-Object { $_ -like '*.cs' -and $_.StartsWith($prefix) } |
                ForEach-Object { $_.Substring($prefix.Length) })
            if ($cs) { $fmtArgs += @('--include') + $cs }
            # A phase that did not run must never look like a phase that passed.
            else { $runFormat = $false; $script:Lines += "[SKIP] format $proj -- no changed .cs files" }
        }
    }
    if ($runFormat) {
        $fmtSw = [Diagnostics.Stopwatch]::StartNew()
        $fmtOut = (& dotnet format whitespace @fmtArgs 2>&1 | Out-String).TrimEnd()
        $fmtCode = $LASTEXITCODE
        $fmtSw.Stop()
        if ($fmtCode -ne 0 -and $fmtOut -notmatch 'error WHITESPACE') {
            # dotnet format loads the project through MSBuild before it reads a single
            # character of whitespace, and a workspace it cannot load exits non-zero with
            # no WHITESPACE line at all. Calling that a formatting failure would print
            # `fix: dotnet format whitespace` at a reader whose problem it does not touch;
            # same convention as govulncheck offline -- an answer nobody got is not a
            # verdict.
            $script:Lines += "[UNKNOWN] ${proj}: could not check formatting -- dotnet format failed to load the project"
            $script:Lines += (($fmtOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join "`n")
        }
        else {
            Phase 'format' {
                # Whole-project on a real mod is 1397 WHITESPACE lines -- 323k chars, which
                # the report's global 6000-char truncation then cut to 27 lines and a byte
                # count. Twenty lines and the real totals say strictly more than a flood
                # sliced at an arbitrary character, and the fix is one command either way.
                $ws = @($fmtOut -split "`r?`n" | Where-Object { $_ -match 'error WHITESPACE' })
                if ($ws.Count -gt 20) {
                    # The summary goes FIRST, not after the twenty: every WHITESPACE line
                    # carries the .cs path AND the csproj path, so twenty of them can still
                    # top the report's 6000-char truncation -- measured, and the line it ate
                    # was the count. The totals are the only part a reader cannot recover.
                    $files = @($ws | ForEach-Object { ($_ -split '\(')[0].Trim() } | Sort-Object -Unique).Count
                    "format: $($ws.Count) violation(s) in $files file(s) -- showing first 20"
                    $ws | Select-Object -First 20
                }
                else { $fmtOut }
                # Every line already names file(line,col); what none of them says is the
                # one command that fixes all of them.
                if ($fmtCode -ne 0) { "fix: dotnet format whitespace $proj"; $global:LASTEXITCODE = 1 }
            } -Elapsed $fmtSw.Elapsed.TotalSeconds
        }
    }

    if ($missing) {
        # Format needed none of them (measured); a compiler does. Reported once, with
        # the count and a name, so the reader can tell "game not installed" from "the
        # csproj is wrong" without reading forty MSB3245 lines.
        $script:Lines += "[SKIP] ${proj}: $($missing.Count) reference(s) missing ($([IO.Path]::GetFileName($missing[0].HintPath))) -- game/SDK not installed on this machine"
        return
    }
    # No -warnaserror: real repos carry warnings and a fast lane stricter than CI is a
    # gate people learn to bypass. The count is a note, the build is the verdict.
    #
    # --no-incremental under -Full, because the count is read out of the BUILD OUTPUT and
    # an incremental build that compiles nothing prints nothing: reported from the field,
    # `[WARN] RailCheck.csproj: 9 compiler warning(s)` on a cold obj/ and no line at all on
    # the next run of the same commit. The number then says whether csc ran, not what the
    # code contains -- exactly the shape of defect PLAYBOOK 0.1 is about. Measured here
    # (warm obj/): RailCheck.csproj 1.3s incremental vs 2.7-3.8s, Multiplayer.csproj
    # 1.3-1.7s vs 1.6-1.7s. The fast lane keeps the incremental build: it runs on every
    # commit, and its warning count is a note beside a verdict that does not depend on it.
    $buildArgs = @($proj, '-nologo', '-v', 'q', '-clp:NoSummary')
    if ($Full) { $buildArgs += '--no-incremental' }
    Phase 'build' {
        $o = (& dotnet build @buildArgs 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $o; return }
        $w = @([regex]::Matches($o, '(?m):\s+warning\s')).Count
        if ($w) { $script:Lines += "[WARN] ${proj}: $w compiler warning(s)" }
    }
    if (-not $Full) { return }

    # Test projects in these repos are custom Exe runners, so the phase exists only
    # where a real test SDK does. Both facts come from the evaluation above, never from
    # the csproj text: IsTestProject is what the SDK itself sets once the project is
    # restored, and the PackageReference list covers the project before its first restore
    # and everything Directory.Build.props imports into it.
    $pkgIds = @($pkgs.Identity)
    if ($info.Properties.IsTestProject -eq 'true' -or $pkgIds -contains 'Microsoft.NET.Test.Sdk') {
        Phase 'test' { dotnet test $proj --no-build -nologo -v q }
    }
    # See the govulncheck note above: a known vulnerability is a defect, it lives on the
    # network, and a project with no PackageReference has nothing to ask about.
    if ($pkgIds) {
        # Neither the exit code nor the human table is readable: it exits 0 whether or
        # not it found anything, exits 1 when the source was merely unreachable, and
        # prints the table in the machine's display language. JSON is the only answer
        # that means the same thing everywhere. It needs the assets file, which is why
        # this runs after `build` restored one.
        $vo = (& dotnet list $proj package --vulnerable --include-transitive --format json --output-version 1 2>&1 | Out-String).Trim()
        $vj = try { $vo | ConvertFrom-Json } catch { $null }
        if (-not $vj -or $vj.problems) {
            # An unreachable source prints plain `error:` lines and no JSON at all; a
            # project problem lands in problems[]. Either way nobody asked the advisory
            # database anything, and "not asked" is not "clean" -- same UNKNOWN the
            # offline outdated check reports.
            $script:Lines += "[UNKNOWN] ${proj}: could not check for vulnerable packages -- offline, the source failed or the project is not restored"
        }
        else {
            $vulnerable = @(foreach ($f in @($vj.projects.frameworks)) {
                    @($f.topLevelPackages) + @($f.transitivePackages) | Where-Object { $_.vulnerabilities }
                })
            Phase 'vuln' {
                foreach ($p in $vulnerable) {
                    foreach ($v in $p.vulnerabilities) { "$($p.id) $($p.resolvedVersion): $($v.severity) -- $($v.advisoryurl)" }
                }
                if ($vulnerable) { $global:LASTEXITCODE = 1 }
            }
        }
    }
}

function Invoke-WebStack($s) {
    Set-Location $s.Dir
    $bin = Join-Path $s.Dir 'node_modules\.bin'
    if (-not (Test-Path $bin)) {
        # Not "nothing to check" -- an unverifiable stack must never pass silently.
        Fail 'web: node_modules missing, run `npm ci` (cannot verify this stack)'
        return
    }
    $pkg = Get-Content (Join-Path $s.Dir 'package.json') -Raw | ConvertFrom-Json
    $scripts = if ($pkg.scripts) { $pkg.scripts.PSObject.Properties.Name } else { @() }

    if (Test-AnyFile $s.Dir @('stylelint.config.*', '.stylelintrc*')) {
        Phase 'stylelint' {
            & "$bin\stylelint.cmd" "**/*.{vue,css,scss}" --no-color --max-warnings 0 --formatter compact `
                --cache --cache-strategy content --cache-location '.cache/stylelintcache'
        }
    }
    # eslint runs WITHOUT --fix on purpose: the gate must report problems, not
    # silently rewrite files another session may be editing.
    if (Test-AnyFile $s.Dir @('eslint.config.*', '.eslintrc*')) {
        Phase 'eslint' {
            & "$bin\eslint.cmd" . --no-color --max-warnings 0 --format stylish `
                --cache --cache-strategy content --cache-location '.cache/eslintcache'
        }
    }
    if ($scripts -contains 'type-check') {
        Phase 'type-check' { npm run type-check -- --pretty false }
    } elseif (Test-Path (Join-Path $s.Dir 'tsconfig.json')) {
        $tsc = if (Test-Path "$bin\vue-tsc.cmd") { "$bin\vue-tsc.cmd" } elseif (Test-Path "$bin\tsc.cmd") { "$bin\tsc.cmd" } else { $null }
        if ($tsc) { Phase 'type-check' { & $tsc --noEmit --pretty false } }
        # A typed project whose type checker is not installed is unverifiable, not fine.
        else { Fail 'web: tsconfig.json present but neither vue-tsc nor tsc is installed (cannot verify types)' }
    }
    # The expensive one (bundling): full level only.
    if (-not ($Fast -and -not $Full)) {
        $buildScript = @('build-only', 'build') | Where-Object { $scripts -contains $_ } | Select-Object -First 1
        if ($buildScript) { Phase 'build' { npm run $buildScript } }
    }
    # See the govulncheck note above: a real defect, full level only, and it needs
    # a lockfile to have anything to resolve against.
    if ($Full) {
        if (Test-AnyFile $s.Dir @('package-lock.json', 'npm-shrinkwrap.json')) {
            Phase 'npm audit' { npm audit --audit-level=high }
        } else {
            $script:Lines += '[WARN] no package-lock.json -- npm audit skipped'
        }
    }
}

function Invoke-ProtoStack($s) {
    Set-Location $s.Dir
    if (-not (Have 'buf')) {
        # Same rule as cargo: an unverifiable stack must never pass silently.
        Fail 'proto: buf not on PATH (cannot verify this stack)'
        return
    }
    Phase 'buf lint' { buf lint }
    # --exit-code turns the formatter into a checker: it reports, it never rewrites.
    Phase 'buf format' { buf format --diff --exit-code }
    if (-not $Full) { return }

    $top = (& git -C $s.Dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { $top = $null } else { $top = ($top -replace '/', '\') }

    # Wire compatibility is judged against the branch point, not the tip: against
    # origin/main it reports what THIS branch broke rather than what the last commit
    # did. A fresh repo has neither reference -- that is a missing baseline, not a
    # breaking change, so it warns instead of failing.
    $base = $null
    if ($top) {
        $base = (& git -C $top merge-base HEAD origin/main 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $base) { $base = (& git -C $top rev-parse --verify --quiet 'HEAD~1^{commit}' 2>$null) }
        if ($LASTEXITCODE -ne 0) { $base = $null }
    }
    # A baseline that predates the schema has nothing to compare against, and buf
    # reports that as a hard error ("had no .proto files"). Adding the first .proto
    # in a module is not a breaking change.
    $baseHasProto = $false
    if ($base) {
        $scope = if ($s.Rel) { $s.Rel } else { '.' }
        $baseHasProto = [bool](@(& git -C $top ls-tree -r --name-only $base -- $scope 2>$null) -like '*.proto')
    }
    if ($base -and $baseHasProto) {
        $subdir = if ($s.Rel) { ",subdir=$($s.Rel)" } else { '' }
        $against = "$(Join-Path $top '.git')#ref=$(([string]$base).Trim())$subdir"
        # buf clones the ref to read it, and that clone runs git's LFS smudge
        # filter over every tracked binary with no remote to fetch from. The
        # .proto files are never LFS objects, so skip the smudge for this call.
        Phase 'buf breaking' {
            $prior = $env:GIT_LFS_SKIP_SMUDGE
            $env:GIT_LFS_SKIP_SMUDGE = '1'
            try { buf breaking --against $against } finally { $env:GIT_LFS_SKIP_SMUDGE = $prior }
        }
    } elseif ($base) {
        $script:Lines += '[WARN] no .proto in the baseline revision -- buf breaking skipped'
    } else {
        $script:Lines += '[WARN] no origin/main and no HEAD~1 -- buf breaking skipped'
    }

    if (-not (Test-Path (Join-Path $s.Dir 'buf.gen.yaml'))) {
        $script:Lines += '[WARN] no buf.gen.yaml -- generate/drift check skipped'
    } elseif (-not $top) {
        $script:Lines += '[WARN] not a git repository -- generate/drift check skipped'
    } else {
        # The valuable one: generated code that no longer matches its .proto still
        # compiles and is still wrong. Generating writes files, so the tree is put
        # back before the phase returns -- a check must not leave the tree modified.
        # Both lists are snapshotted first, or an unrelated edit already in the tree
        # would be reported as drift.
        Phase 'buf generate drift' {
            $wasDirty = @(& git -C $top diff --name-only)
            $wasNew = @(& git -C $top ls-files --others --exclude-standard)
            buf generate
            if ($LASTEXITCODE -ne 0) { return }
            $dirty = @(& git -C $top diff --name-only | Where-Object { $_ -and $wasDirty -notcontains $_ })
            $new = @(& git -C $top ls-files --others --exclude-standard | Where-Object { $_ -and $wasNew -notcontains $_ })
            foreach ($p in $dirty) { "drifted from its .proto source: $p" }
            foreach ($p in $new) { "generated but never committed: $p" }
            if ($dirty) { & git -C $top checkout -- @dirty *>&1 | Out-Null }
            $global:LASTEXITCODE = $(if ($dirty -or $new) { 1 } else { 0 })
        }
    }
}

function Invoke-GodotStack($s) {
    Set-Location $s.Dir
    # addons/ is other people's code: a project cannot fix its formatting and
    # should not be blocked by its docstrings. Its files still count as targets
    # a reference may resolve to (see $known below); they are just not scanned.
    $noGodotDir = '[\\/](\.godot|addons)[\\/]'
    # Ignored directories are not this project's code, for the same reason gofmt no
    # longer walks into them: a nested checkout under a gitignored path -- Claude Code
    # puts agent worktrees in .claude/worktrees/<agent>/ -- would otherwise be linted
    # as part of the root project and redden its gate over files not in its index.
    # Asked per directory and cached, because this list is every .gd in the project.
    $gd = @(Get-ChildItem $s.Dir -Recurse -File -Filter '*.gd' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $noGodotDir -and -not (Test-GitIgnoredDir $s.Dir $_.DirectoryName) })
    # -All means "every detected stack, ignore git status", so it must ignore it
    # here too -- narrowing under -All left both lint phases out of the output
    # entirely while the stack line still said [PASS].
    if (-not $Full -and -not $All) {
        # The fast lane runs on every agent turn: lint only what git says changed.
        $changed = Get-ChangedPaths $Root
        if ($null -ne $changed) {
            $want = @($changed | Where-Object { $_ -like '*.gd' } | ForEach-Object { Join-Path $Root ($_ -replace '/', '\') })
            $gd = @($gd | Where-Object { $want -contains $_.FullName })
        }
    }
    if ((Have 'gdformat') -and (Have 'gdlint')) {
        if ($gd.Count -gt 0) {
            $paths = @($gd.FullName)
            Phase 'gdformat' { gdformat --check @paths }
            Phase 'gdlint' { gdlint @paths }
        } else {
            # A phase that did not run must never be indistinguishable from a phase
            # that passed.
            $script:Lines += '[SKIP] gdformat/gdlint -- no changed .gd files'
        }
    } elseif ($Full) {
        # Same rule as golangci-lint: unverifiable is not clean, and the full level
        # is what guards a commit and CI. `-Only` is the escape hatch for a repo
        # that genuinely does not want gdtoolkit.
        Fail 'gdformat/gdlint not on PATH -- required at the full level (pip install gdtoolkit), or exclude this stack with -Only'
    } else {
        $script:Lines += '[WARN] gdformat/gdlint not on PATH -- phases skipped (pip install gdtoolkit)'
    }

    # Godot resolves res:// case-sensitively on Linux. A reference whose case is
    # wrong opens fine on a Windows dev box and breaks the Linux CI run or export,
    # so this compares ordinally against a case-exact index of the project instead
    # of asking the filesystem.
    Phase 'res:// references' {
        $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($e in Get-ChildItem $s.Dir -Recurse -Force -ErrorAction SilentlyContinue) {
            [void]$known.Add($e.FullName.Substring($s.Dir.Length).TrimStart('\').Replace('\', '/'))
        }
        # A uid:// resolves through the file that DECLARES it, never through a path.
        # Only the [gd_scene]/[gd_resource] header line and an .import sidecar declare
        # one; every other uid= (an [ext_resource], a preload) is a reference to a
        # file that must exist.
        $decl = '^\[gd_(scene|resource)\b'
        $uids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($f in Get-ChildItem $s.Dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.tscn', '.tres', '.import' -and $_.FullName -notmatch $noGodotDir }) {
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                if ($f.Extension -ne '.import' -and $l -notmatch $decl) { continue }
                foreach ($m in [regex]::Matches($l, 'uid\s*=\s*"uid://([^"]+)"')) { [void]$uids.Add($m.Groups[1].Value) }
            }
        }
        foreach ($f in Get-ChildItem $s.Dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.tscn', '.tres', '.gd' -and $_.FullName -notmatch $noGodotDir }) {
            # Plain text, no parsing: this runs on every agent turn. A reference is
            # a quoted string literal; res:// in a comment, a docstring or a format
            # template ("res://addons/%s/plugin.cfg") is prose and is not checked.
            $rel = $f.FullName.Substring($s.Dir.Length).TrimStart('\').Replace('\', '/')
            $lines = [IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($m in [regex]::Matches($lines[$i], '["'']res://([^"'']*)["'']')) {
                    $p = $m.Groups[1].Value.TrimEnd('/')
                    if ($p -match '[%*<>\[\]]') { continue }
                    if ($p -and -not $known.Contains($p)) { "${rel}:$($i + 1): res://$p does not resolve" }
                }
                if ($lines[$i] -match $decl) { continue }
                foreach ($m in [regex]::Matches($lines[$i], '["'']uid://([^"'']*)["'']')) {
                    $u = $m.Groups[1].Value
                    if ($u -and -not $uids.Contains($u)) { "${rel}:$($i + 1): uid://$u matches nothing in the project" }
                }
            }
        }
    } -FailIfOutput

    # Every phase below needs the Godot binary, and every one of them is full-level
    # only -- so this return comes FIRST. The "unverifiable is not clean" rule that
    # makes a missing cargo or buf fatal applies because those tools run fast-lane
    # phases (`cargo fmt`, `buf lint`); the Godot binary has no fast-lane work, and
    # failing every agent turn over a binary the turn was never going to invoke is
    # not the same thing. Fast lane: the detection [WARN] says it is missing.
    if (-not $Full) { return }
    $godot = Get-GodotBin
    if (-not $godot) {
        # Full level guards commits and CI, and there the binary is the whole stack.
        # Symmetric with gdtoolkit above: both warn in the fast lane, both fail here.
        Fail 'godot: set GODOT_BIN to the Godot executable (cannot verify this stack)'
        return
    }

    # THE Godot trap: it writes script errors to STDOUT and still exits 0 for a
    # large class of them, so an exit-code-only check reports false green. Every
    # phase below filters its run down to the error lines and fails on any output;
    # a clean run prints nothing.
    $errs = 'SCRIPT ERROR|ERROR:'
    # Run twice: the first pass creates .godot/ and routinely reports errors that
    # exist only because it did not yet. Only the second pass is a verdict.
    Phase 'godot import' {
        & $godot --headless --path $s.Dir --import *>&1 | Out-Null
        (& $godot --headless --path $s.Dir --import *>&1) | Where-Object { $_ -match $errs }
    } -FailIfOutput
    # A test that exercises a rejection path makes the engine print ERROR: lines
    # on purpose (a codec refusing a corrupt frame, say) -- that is the code under
    # test working. So here only a script that failed to load or parse is a
    # verdict from the output; the test itself speaks through its exit code, which
    # Phase already checks.
    $scriptErrs = 'SCRIPT ERROR|Parse Error|Failed to load script'
    foreach ($t in Get-ChildItem $s.Dir -Recurse -File -Filter '*_headless_test.gd' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $noGodotDir }) {
        $tf = $t.FullName
        Phase "godot test $($t.Name)" {
            (& $godot --headless --path $s.Dir --script $tf *>&1) | Where-Object { $_ -match $scriptErrs }
        } -FailIfOutput
    }
    # Boots the main scene and quits: catches autoload and boot-order breakage that
    # neither the import nor a script test ever loads.
    Phase 'godot smoke' {
        (& $godot --headless --path $s.Dir --quit-after 1 *>&1) | Where-Object { $_ -match $errs }
    } -FailIfOutput
}

# --- run -------------------------------------------------------------------
$cwd = (Get-Location).Path
$report = @()
foreach ($s in $stacks) {
    $label = if ($s.Rel) { "$($s.Stack) $($s.Rel)/" } else { $s.Stack }
    if (-not $s.Implemented) {
        $report += "[SKIP] $label ($($s.Marker)) -- $($s.Warn)"
        continue
    }
    # Fail-fast across stacks, but never in silence: `break` ended the loop and the
    # report simply stopped, so a red go stack made the web stack indistinguishable
    # from a web stack that does not exist -- the reader cannot tell "not run" from
    # "nothing to check". The work is still skipped; the skipping is now on the record.
    if ($script:Failed) { $report += "[SKIP] $label ($($s.Marker)) -- an earlier stack failed, not run"; continue }
    if ($s.Warn) { $report += "[WARN] $label -- $($s.Warn)" }
    $script:Lines = @()
    $before = $script:Phases
    try {
        switch ($s.Stack) {
            'go' { Invoke-GoStack $s }
            'web' { Invoke-WebStack $s }
            'rust' { Invoke-RustStack $s }
            'proto' { Invoke-ProtoStack $s }
            'godot' { Invoke-GodotStack $s }
            'dotnet' { Invoke-DotnetStack $s }
        }
    } catch {
        # Fail closed: a crash in the gate is a failure, never a silent pass.
        Fail "${label}: gate crashed -- $($_.Exception.Message)"
    } finally { Set-Location $cwd }

    if ($script:Failed) {
        $out = ($script:Lines -join "`n").TrimEnd()
        if ($out.Length -gt $MaxChars) {
            $extra = $out.Length - $MaxChars
            $out = $out.Substring(0, $MaxChars) + "`n...[truncated, $extra more chars]"
        }
        $report += "[FAIL] $label"
        $report += $out
    } elseif (-not $Quiet) {
        # SKIP belongs in the summary too: a phase that did not run is exactly what
        # a reader of a [PASS] stack line needs to be told about.
        # UNKNOWN belongs here for the same reason SKIP does, and more so: it is the gate
        # saying a check was never performed -- the vulnerability database unreachable, a
        # project dotnet format could not load. Measured: with the source offline the vuln
        # branch wrote its [UNKNOWN] and this filter dropped it, so the stack reported
        # `[PASS] dotnet ... [PASS] build` and exit 0 over a question nobody answered. An
        # unperformed check hidden behind a green line is the one thing this report must
        # never do. One filter, so every stack that ever emits one is covered.
        $timings = ($script:Lines | Where-Object { $_ -match '^\[(PASS|WARN|SKIP|UNKNOWN)\]' }) -join ' '
        # Same rule one level down from the invariant below. Every web phase is
        # conditional on a config file or a package script, so a project with none of
        # them ran nothing and was still reported [PASS]. A stack that verified
        # nothing is flagged, never passed -- beside a stack that did real work the
        # run as a whole still stands, exactly as it does for an unimplemented stack.
        $ran = $script:Phases -gt $before
        $report += "$(if ($ran) { '[PASS]' } else { '[SKIP]' }) $label ($($s.Marker))$(if (-not $ran) { ' -- no check phase applies here' }) $timings"
    }
}

# THE INVARIANT: a run that executed zero check phases is not a green run.
# Every false green this gate has shipped was a different door into this one room --
# a stack detected but not implemented, a web stack whose every phase is conditional
# on a config file, an -Only naming a stack that is not here. Patching the doors one
# at a time left the next one open, so the rule lives here, once, and reads the only
# fact that decides it: how many phases ran, not which stacks were detected. Beside a
# stack that did real work a flagged one is only a note -- the count is the run's.
# The two runs that legitimately verify nothing say so and exit long before this
# point: `[SKIP] no changes` on a clean fast lane, and `[SKIP] no known stack found`
# in a repo the gate was never given a marker file for.
if (-not $script:Failed -and $script:Phases -eq 0) {
    $names = @($stacks | ForEach-Object { $_.Stack }) -join ', '
    $report += "[FAIL] no check phase ran -- nothing was verified$(if ($names) { " ($names)" }), so this run is not green"
    $script:Failed = $true
}

# The other half of the concurrency guard above. Checked before the advisory below so
# a run already lost to a race does not also go and ask a registry about it.
if ($script:StagedAtStart) {
    $stagedNow = (& git -C $Root write-tree 2>$null)
    if ($LASTEXITCODE -eq 0 -and $stagedNow -ne $script:StagedAtStart) {
        $report += '[FAIL] the staged files changed while the gate was running -- another commit is running in this worktree'
        $report += '       Committing now would take the other one''s staged changes with it. Wait for it, re-read `git status`, then commit again.'
        $script:Failed = $true
    }
}

# Only on the full level, only when everything passed: a note about newer releases,
# never a verdict. It cannot fail the run, and the Stop hook (-Fast) never sees it.
if ($Full -and -not $script:Failed) {
    $note = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'outdated.ps1') -Root $Root -Summary 2>$null)
    if ($note) { $report += $note }
}

# -Quiet keeps a PASSING run silent -- that is its whole documented job, and the
# generated pre-commit hook runs in it because the hook's stdout is context the
# model pays for. A [WARN] about the gate's own config file being unreadable is not
# a passing condition though: it is the gate saying its input is broken, and
# swallowing it here hid it exactly where it guards a commit. Same rule the
# qgate.json unknown-key warning already follows; the advisory [INFO] about newer
# releases and the per-stack notes stay silent on green.
if ($Quiet -and -not $script:Failed) { $report = @($report | Where-Object { $_ -match '^\[WARN\] qgate\.' }) }
if ($report) { $report | ForEach-Object { Write-Output $_ } }
exit ($(if ($script:Failed) { 1 } else { 0 }))
