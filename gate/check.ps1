# Quality gate: one entry point for every static check in the repository.
#
# Token-cheap by design: on success one short line per phase, on failure the raw tool
# output with its detail capped at 6000 chars (status lines are never cut). Fail-fast -- the first failing phase stops the
# rest, because a linter report on non-compiling code is noise.
#
# Levels: -Fast drops the expensive bundling phase and is what the agent Stop
# hook runs on every turn. -Full (the default) adds it back and is what the
# pre-commit hook and CI run.
#
# With no stack switch the changed side is auto-detected from git status.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Only,      # base | go | web | rust | proto | godot | dotnet | cpp | custom | deploy -- restrict to these stacks (one value: -Only go,web)
    [switch]$All,         # every detected stack, ignore git status
    [switch]$Fast,
    [switch]$Full,
    [switch]$Quiet,
    [switch]$Why,         # provenance: which marker file created (or did not create) each phase
    [string]$Baseline,    # git rev: report only issues newer than it (adoption on a dirty codebase)
    [switch]$Mutate,      # on demand only: Go mutation testing (gremlins), advisory; scoped by -Baseline
    [switch]$Fix,         # explicit only, never from a hook: gofmt -w + golangci-lint --fix on Go stacks, then the normal gate
    [string]$Root,        # repo root; defaults to the git root of the cwd
    [string]$Sarif,       # opt-in: also write the report as SARIF 2.1.0 to this file; stdout unchanged
    [switch]$Parallel,    # opt-in: run independent stacks (go web rust dotnet cpp godot) as concurrent child processes
    # Internal to -Parallel: the child runs exactly these stacks ("stack|rel;...") and
    # writes its per-stack results to ParallelOut instead of printing a report.
    [Parameter(DontShow)][string]$ParallelStacks,
    [Parameter(DontShow)][string]$ParallelOut,
    # Nothing binds here on a correct call. Positional binding used to swallow the
    # second word of `-Only go python` into -Baseline, and the run then died with
    # "baseline revision not found: python" -- a verdict about a feature the user
    # never touched. PositionalBinding=$false plus this catch-all turns a stray value
    # into a reason about the argument that was actually wrong.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'detect.ps1')
. (Join-Path $PSScriptRoot 'smoke.ps1')

# --- -Sarif: the same run, its report also written as SARIF 2.1.0 -----------
# One place for every stack and every exit path: the gate runs itself without -Sarif,
# prints the child's stdout as-is, and converts those same lines. Nothing per tool.
# [FAIL] -> error, [WARN]/[UNKNOWN] -> warning, [SKIP]/[NOTE]/[INFO] -> note, [PASS]
# is not a result. ruleId is the first word after the tag. An untagged line of raw
# tool output that starts `path:line[:col]` becomes its own result with a location
# under the last tag; any other untagged line is appended to the previous result.
# ponytail: location only for `path:line[:col]` with no spaces in the path, relative
# paths as the tool printed them (a stack in a subdirectory prints them relative to
# it); -Quiet on a green run prints nothing, so the SARIF is empty too.
# This run's own command line, minus the named parameters: how -Sarif and -Parallel re-run the gate.
function Get-SelfArgv($Bound, [string[]]$Drop) {
    $argv = @()
    foreach ($k in $Bound.Keys) {
        if ($k -in $Drop) { continue }
        $v = $Bound[$k]
        if ($v -is [switch]) { if ($v) { $argv += "-$k" } }
        elseif ($k -eq 'Only') { $argv += '-Only', (@($v) -join ',') }
        else { $argv += "-$k", $v }
    }
    $argv
}
if ($PSBoundParameters.ContainsKey('Sarif')) {
    if (-not $Sarif) { Write-Output '[FAIL] -Sarif was given an empty value -- name the output file: -Sarif qgate.sarif'; exit 1 }
    $argv = @(Get-SelfArgv $PSBoundParameters 'Sarif', 'Extra')
    if ($Extra) { $argv += $Extra }
    $childOut = @(& pwsh -NoProfile -File $PSCommandPath @argv)
    $code = $LASTEXITCODE
    $childOut | ForEach-Object { Write-Output $_ }
    $base = try { (Resolve-Path $(if ($Root) { $Root } else { Get-RepoRoot (Get-Location).Path })).Path } catch { $null }
    $results = [Collections.Generic.List[object]]::new()
    $rule = 'gate'; $tagLevel = $null
    $levels = @{ FAIL = 'error'; WARN = 'warning'; UNKNOWN = 'warning'; SKIP = 'note'; NOTE = 'note'; INFO = 'note' }
    foreach ($line in @($childOut | ForEach-Object { "$_" -split "`r?`n" })) {
        # Older reports carried a passing stack's phases inline: `[PASS] go (go.mod) [PASS] build [WARN] ...`.
        foreach ($seg in ($line -split ' (?=\[(?:PASS|FAIL|WARN|SKIP|UNKNOWN|NOTE|INFO)\] )')) {
            if ($seg -match '^\[(PASS|FAIL|WARN|SKIP|UNKNOWN|NOTE|INFO|WHY)\] (.*)$') {
                $tagLevel = $levels[$Matches[1]]
                $rule = if ($Matches[2] -match '^([^\s:(]+)') { $Matches[1] } else { 'gate' }
                if ($tagLevel) { $results.Add([ordered]@{ ruleId = $rule; level = $tagLevel; message = [ordered]@{ text = $seg } }) }
            } elseif ($tagLevel -and $seg -match '^\s*(?<p>(?:[A-Za-z]:[\\/])?[^\s:]+\.[A-Za-z0-9]+):(?<l>\d+)(?::(?<c>\d+))?') {
                $p = $Matches.p
                $uri = if ([IO.Path]::IsPathRooted($p)) {
                    $rel = if ($base) { [IO.Path]::GetRelativePath($base, $p) } else { $p }
                    if ($rel -notmatch '^\.\.' -and -not [IO.Path]::IsPathRooted($rel)) { $rel -replace '\\', '/' } else { ([Uri]$p).AbsoluteUri }
                } else { $p -replace '\\', '/' -replace '^\./', '' }
                $region = [ordered]@{ startLine = [int]$Matches.l }
                if ($Matches.c -and [int]$Matches.c -gt 0) { $region.startColumn = [int]$Matches.c }
                if ($region.startLine -lt 1) { $region = $null }
                $loc = [ordered]@{ artifactLocation = [ordered]@{ uri = $uri } }
                if ($region) { $loc.region = $region }
                $results.Add([ordered]@{ ruleId = $rule; level = $tagLevel; message = [ordered]@{ text = $seg.Trim() }; locations = @([ordered]@{ physicalLocation = $loc }) })
            } elseif ($seg.Trim() -and $results.Count) {
                $results[-1].message.text += "`n" + $seg
            }
        }
    }
    $doc = [ordered]@{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @([ordered]@{ tool = [ordered]@{ driver = [ordered]@{ name = 'quality-gate'; informationUri = 'https://github.com/UberMorgott/quality-gate' } }; results = @($results) })
    }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Sarif, (Get-Location).Path), ($doc | ConvertTo-Json -Depth 20))
    exit $code
}

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
# -Since: the revision the tracked half is diffed against. HEAD for the fast lane;
# -Baseline passes its own, so "changed" means "changed since the baseline".
function Get-ChangedPaths([string]$Repo, [string]$Since = 'HEAD') {
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
    $paths += @((& git -C $Repo diff --name-only -z $Since 2>$null | Out-String) -split "`0")
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

# -Baseline for the tools that have no baseline of their own: a diff-line filter.
# Changed lines since the rev: repo-relative path -> list of @(first, last), or $true for
# an untracked file (all of it is new). Same change set as Get-ChangedPaths: working tree
# against the rev, staged or not, plus untracked files.
# ponytail: changed LINES only -- a finding on an untouched line that the change caused
# (a new unused import, a now-dead branch) is hidden too. Per-tool snapshots if that bites.
function Get-BaselineLines([string]$Repo, [string]$Since) {
    $map = @{}
    $cur = $null; $prev = ''
    foreach ($l in @(& git -C $Repo -c core.quotepath=false diff --no-color --no-ext-diff -U0 $Since 2>$null)) {
        # `+++` only right after `---`: an added line reading `++ b/x` is content, not a header.
        if ($prev -like '--- *' -and $l -match '^\+\+\+ (?:b/(.*?)\t?$|/dev/null)') {
            $cur = $Matches[1]
            if ($cur -and -not $map.ContainsKey($cur)) { $map[$cur] = [Collections.Generic.List[object]]::new() }
        } elseif ($cur -and $l -match '^@@ -\S+ \+(\d+)(?:,(\d+))? @@') {
            $n = if ($null -ne $Matches[2]) { [int]$Matches[2] } else { 1 }
            if ($n) { $map[$cur].Add(@([int]$Matches[1], ([int]$Matches[1] + $n - 1))) }
        }
        $prev = $l
    }
    foreach ($u in @((& git -C $Repo ls-files --others --exclude-standard -z 2>$null | Out-String) -split "`0")) {
        $u = $u.Trim("`n", "`r")
        if ($u) { $map[$u] = $true }
    }
    $map
}

# One tool output line: $null when it is not `path:line[:col]` naming a file in this repo
# (never hidden -- what cannot be attributed stays), else $true to keep, $false to hide.
# $Dir is what a relative path in the tool's output is relative to.
function Test-BaselineLine([string]$Line, [string]$Dir) {
    if ($Line -notmatch '^\s*(?<p>(?:[A-Za-z]:[\\/])?[^:\t]+?):(?<l>\d+)(?=[:\s]|$)') { return $null }
    $n = [int]$Matches.l
    $abs = try { [IO.Path]::GetFullPath($Matches.p.Trim(), $Dir) } catch { return $null }
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { return $null }
    $rel = [IO.Path]::GetRelativePath($Root, $abs) -replace '\\', '/'
    if ($rel -like '../*' -or [IO.Path]::IsPathRooted($rel)) { return $null }
    $r = $script:BaselineLines[$rel]
    if ($r -is [bool]) { return $true }
    if (-not $r) { return $false }
    # Line 0 is a whole-file finding: kept when the file changed at all.
    if ($n -eq 0) { return $r.Count -gt 0 }
    [bool]($r | Where-Object { $n -ge $_[0] -and $n -le $_[1] })
}

# Filters a tool's output. A line under a hidden finding that is indented or a `N |`
# snippet (actionlint's source excerpt) goes with it; every other unlocated line stays.
# Located/Hidden: a tool that failed with all Located findings Hidden has nothing new.
function Select-BaselineFindings([string]$Text, [string]$Dir) {
    $kept = [Collections.Generic.List[string]]::new()
    $located = 0; $hidden = 0; $drop = $false
    foreach ($ln in ($Text -split "`r?`n")) {
        $k = Test-BaselineLine $ln $Dir
        if ($null -ne $k) {
            $located++
            $drop = -not $k
            if ($drop) { $hidden++ } else { $kept.Add($ln) }
            continue
        }
        if ($drop -and $ln -match '^(\s|\d*\s*\|)') { continue }
        $drop = $false
        $kept.Add($ln)
    }
    @{ Text = ($kept -join "`n"); Located = $located; Hidden = $hidden }
}

# The same filter over regex hits already known to be findings (tidy, cppcheck).
function Select-BaselineHits($Hits, [string]$Name, [string]$Dir) {
    $keep = @($Hits | Where-Object { (Test-BaselineLine $_.Value.TrimEnd() $Dir) -ne $false })
    if ($Hits.Count -gt $keep.Count) { $script:Warnings += @("[NOTE] ${Name}: $($Hits.Count - $keep.Count) pre-existing finding(s) hidden by -Baseline $Baseline") }
    $keep
}

# --- select which stacks to run -------------------------------------------
if ($ParallelStacks) {
    # A -Parallel child: the parent already selected; run exactly what it was handed.
    $keys = $ParallelStacks -split ';'
    $stacks = @($allStacks | Where-Object { $keys -contains "$($_.Stack)|$($_.Rel)" })
} elseif ($onlyGiven) {
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
        # base is always-on and owns no directory of its own, so no changed path can
        # ever select it -- it is added back below rather than left out of every
        # narrowed run, which is every agent turn.
        $baseStack = @($stacks | Where-Object { $_.Stack -eq 'base' })
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
        # -Unique over the sort keys, so the widening branch above -- which already
        # took every stack, base included -- does not list it twice.
        $stacks = @(@($selected) + $baseStack | Sort-Object Stack, Rel -Unique)
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

# #80: a committed baseline. -Baseline is a CLI flag, so the hooks -- which run a fixed
# command line -- could not use it, and wire on a legacy repository left the first
# commit refused. qgate.json "baseline": "<rev>" is the opt-in the hooks and CI read;
# an explicit -Baseline still wins. Said on every run: it hides findings.
$baselineFrom = ''
if (-not $Baseline -and (Test-Path $pinFile)) {
    try { $jsonBaseline = (Get-Content $pinFile -Raw | ConvertFrom-Json).baseline } catch { $jsonBaseline = $null }
    if ($jsonBaseline -is [string] -and $jsonBaseline.Trim()) {
        $Baseline = $jsonBaseline.Trim()
        $baselineFrom = ' (qgate.json "baseline")'
        if (-not $Quiet) { Write-Output "[NOTE] baseline $Baseline from qgate.json -- findings on lines unchanged since it are hidden" }
    }
}
# A baseline that does not resolve would surface as a confusing linter error deep
# in the run; say so here instead.
if ($Baseline) {
    & git -C $Root rev-parse --verify --quiet "$Baseline^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { Write-Output "[FAIL] baseline revision not found: $Baseline$baselineFrom"; exit 1 }
    $script:BaselineLines = Get-BaselineLines $Root $Baseline
}

$script:Failed = $false
# A -Soft phase failed: the run is red, but the phases and stacks after it still run.
# StackSoft is per stack (its [FAIL] header), SoftFailed is the run's (the exit code).
$script:StackSoft = $false
$script:SoftFailed = $false
$script:Lines = @()
# Set when the custom stack deliberately ran nothing: the checks are not trusted here,
# or every one of them is full-level and this is the fast lane. The deploy stack sets it
# too: full-level only, and a machine without the deployed copy has nothing to compare
# (CI never has the game installed). Read once, by the
# zero-phase invariant at the bottom of this file.
$script:CustomDeferred = $false
# The same thing for the base stack: one of its phases declined because the tool it
# needs is not installed here, or there was nothing staged for it to read. Read once,
# by the zero-phase invariant, and only when base is the whole run -- see there.
$script:BaseDeferred = $false
# How many check phases actually executed. The one number the green verdict at the
# bottom of this file is not allowed to ignore.
$script:Phases = 0
$script:Warnings = @()

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
    # -Time: the parenthetical, written out. For a phase whose real cost is not a
    # duration of its own -- one `dotnet format` pass shared by several projects, where
    # printing the same 3.4s on each would multiply the run's cost by the number of
    # stacks, and printing 0.0s on the others would deny the work happened at all.
    # -Soft: a non-semantic phase (whitespace). Its failure fails the run but does not
    # skip what follows -- reported from the field: 1091 whitespace errors in an upstream
    # fork skipped build, analyzers, vuln and every other dotnet stack, and the build was
    # where the real bug was.
    param([string]$Name, [scriptblock]$Body, [switch]$FailIfOutput, [double]$Elapsed = -1, [string]$Time, [switch]$Soft)
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
    $script:PhaseSkip = $null
    $out = (& $Body 2>&1 | Out-String).TrimEnd()
    $script:PhaseOut = $out
    $sw.Stop()
    # A body that ran the tool and found it could not JUDGE (#99: a build whose
    # references were never on this machine to resolve) reports a skip, not a pass and
    # not a fail. Not counted as a phase either -- the zero-phase invariant asks how
    # many real checks ran, and this one did not reach the code.
    if ($script:PhaseSkip) {
        $script:Phases--
        $script:Lines += "[SKIP] $Name -- $($script:PhaseSkip)"
        $script:PhaseSkip = $null
        return
    }
    # InvariantCulture, not '{0:N1}': under a comma-decimal locale (ru-RU here) every
    # phase printed `0,0s`, so the timings the report exists to show were unreadable to
    # anything that parses them and inconsistent between machines.
    $secs = if ($Elapsed -ge 0) { $Elapsed } else { $sw.Elapsed.TotalSeconds }
    $sec = if ($Time) { $Time } else { "$($secs.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s" }
    if (($LASTEXITCODE -ne 0) -or ($FailIfOutput -and $out)) {
        $script:Lines += "[FAIL] $Name ($sec)"
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
        if ($Soft) { $script:StackSoft = $true } else { $script:Failed = $true }
    } else {
        $script:Lines += "[PASS] $Name ($sec)"
    }
}

function Fail([string]$Message) {
    $script:Lines += "[FAIL] $Message"
    $script:Failed = $true
}

# quality-gate#75: the cap applies to DETAIL, never to status. Cut from the head of the
# whole stack text, a formatter diff with long paths ate the 6000 chars and the later
# `[FAIL] harmony` line of the same stack never reached the report -- a real finding
# hidden behind the one that happened to print first. Status lines ([PASS]/[FAIL]/[SKIP]/
# [UNKNOWN]/[WARN]/[NOTE], `fix:`, `run:`) are always kept; the detail budget is split evenly
# across the detail blocks between them, so one loud phase cannot starve the next.
function Format-StackOutput([string[]]$Lines, [int]$Max) {
    $status = '^\s*(\[(PASS|FAIL|SKIP|UNKNOWN|WARN|NOTE)\]|fix:|run:)'
    $rows = @($Lines | ForEach-Object { "$_" -split "`r?`n" })
    $blocks = 0; $inDetail = $false
    foreach ($r in $rows) { $d = $r -notmatch $status; if ($d -and -not $inDetail) { $blocks++ }; $inDetail = $d }
    $cap = if ($blocks) { [Math]::Floor($Max / $blocks) } else { $Max }
    $out = [Collections.Generic.List[string]]::new()
    $used = 0; $cut = 0
    foreach ($r in $rows) {
        if ($r -match $status) {
            if ($cut) { $out.Add("...[truncated, $cut more chars]"); $cut = 0 }
            $out.Add($r); $used = 0; continue
        }
        if ($used + $r.Length + 1 -le $cap) { $out.Add($r); $used += $r.Length + 1 } else { $cut += $r.Length + 1; $used = $cap + 1 }
    }
    if ($cut) { $out.Add("...[truncated, $cut more chars]") }
    ($out -join "`n").TrimEnd()
}

function Have([string]$Exe) { [bool](Get-Command $Exe -ErrorAction SilentlyContinue) }

# quality-gate#82: an advisory with no fixed version failed every -Full run and every
# commit, and nothing in the repository could fix it. qgate.deferrals.json
# "vulnerabilities" acknowledges one by id, with a reason and an expiry. $Found holds
# one id list per advisory (its id plus aliases, so an ack under either name holds).
# Returns the advisories that still fail; each live acknowledgement is a report-level
# [WARN], so it is printed on every run, -Quiet included. An expired or invalid entry
# acknowledges nothing -- its advisory fails like any other, and says why.
function Get-UnackedVulns([string]$Tool, [object[]]$Found) {
    $acks = @(Read-Deferrals $Root 'vulnerabilities' 'id')
    $script:Warnings += @($acks | Where-Object { $_.Bad } | ForEach-Object { "[WARN] $($_.Bad)" })
    $today = (Get-Date).Date
    foreach ($ids in $Found) {
        $a = @($acks | Where-Object { $_.Name -and $ids -contains $_.Name })[0]
        if (-not $a) { "not acknowledged: $($ids[0])" }
        elseif ($a.Until -lt $today) { "acknowledgement expired: $($a.Name) was acknowledged until $($a.Until.ToString('yyyy-MM-dd')) -- $($a.Reason)" }
        else { $script:Warnings += "[WARN] qgate.deferrals.json: $Tool $($a.Name) acknowledged until $($a.Until.ToString('yyyy-MM-dd')) -- $($a.Reason)" }
    }
}
function Test-VulnAcks { [bool]@(Read-Deferrals $Root 'vulnerabilities' 'id').Count }

# --- stack runners ---------------------------------------------------------
function Invoke-GoStack($s) {
    Set-Location $s.Dir
    # quality-gate#44: -Fix rewrites first, then the unchanged phases below judge the
    # result. Only an explicit `qgate -Fix` does this -- hooks and CI never pass it, so
    # the gate itself still reports rather than rewrites (linters run without --fix).
    if ($Fix) {
        $fmt = @(gofmt -l . | Where-Object { -not (Test-GitIgnored $s.Dir (Join-Path $s.Dir $_)) })
        if ($fmt) { gofmt -w @fmt }
        $lint = if (Have 'golangci-lint') { golangci-lint run --allow-serial-runners --fix ./... *> $null; 'golangci-lint --fix applied' } else { 'golangci-lint not on PATH' }
        $global:LASTEXITCODE = 0
        $script:Lines += "[INFO] fix: gofmt rewrote $($fmt.Count) file(s), $lint -- the gate below judges the result"
    }
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
        # quality-gate#83: `run` loads configs its own JSON schema rejects (measured on
        # 2.13.2: an unknown top-level key, `rules:` left null), while golangci-lint-action
        # runs `config verify` first by default -- local gate green, CI red. A FAIL, not a
        # WARN: the verdict is the tool's own schema, and it is the verdict CI already gives.
        # Exit 6 = no config file (the action skips verify then too); a golangci-lint too old
        # to have `config verify` is not a finding about the repo.
        $vSw = [Diagnostics.Stopwatch]::StartNew()
        $vOut = (& golangci-lint config verify 2>&1 | Out-String).TrimEnd()
        $vCode = $LASTEXITCODE
        $vSw.Stop()
        if ($vOut -match 'unknown command') {
            $script:Lines += '[WARN] golangci-lint has no `config verify` -- config schema check skipped (update golangci-lint)'
        } elseif ($vCode -ne 6) {
            Phase 'golangci-lint config verify' { $vOut; $global:LASTEXITCODE = $vCode } -Elapsed $vSw.Elapsed.TotalSeconds
        }
        # quality-gate#93: golangci-lint holds a machine-wide lock in TEMP, and a second
        # run without a runners flag exits 3 "parallel golangci-lint is running" -- two
        # repos or a hook beside a manual run turned clean code red (measured). Serial,
        # not parallel: waiting keeps two heavy analyses from competing for the machine.
        # Every `golangci-lint run` the gate issues carries it (selftest asserts).
        Phase 'golangci-lint' {
            golangci-lint run --allow-serial-runners --output.text.print-issued-lines=false --output.text.colors=false `
                --max-issues-per-linter=0 --max-same-issues=0 @newFrom ./...
        }
        # Advisory, full level only: a note about the config, not about this change.
        if ($Full) { $script:Warnings += @(Get-GolangciFloorGaps $s.Dir $s.Rel (Join-Path $PSScriptRoot '..\templates\.golangci.yml')) }
    } elseif ($Full) {
        # The full level is what guards a commit and CI. A gate that quietly drops
        # its main linter there is not a gate.
        Fail 'golangci-lint not on PATH -- required at the full level (go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest)'
    } else {
        $script:Lines += '[WARN] golangci-lint not on PATH -- phase skipped'
    }
    # quality-gate#40: opt-in (qgate.json go.lintGoos) vet and lint under other GOOS targets.
    if ($Full) {
        $script:GoHostOs = if ($script:GoHostOs) { $script:GoHostOs } else { go env GOOS }
        $lg = Get-GoLintGoos $Root $script:GoHostOs
        if ($lg.Error) { Fail $lg.Error }
        # No lintGoos key is $null, and @($null.Goos) is one $null element: every -Full run
        # repeated go vet and golangci-lint under an empty "GOOS=" heading (#84, measured).
        foreach ($os in @($lg.Goos | Where-Object { $_ })) {
            Phase "go vet GOOS=$os" { Invoke-WithGoos $os { go vet ./... } }
            if (Have 'golangci-lint') {
                Phase "golangci-lint GOOS=$os" {
                    Invoke-WithGoos $os {
                        golangci-lint run --allow-serial-runners --output.text.print-issued-lines=false --output.text.colors=false `
                            --max-issues-per-linter=0 --max-same-issues=0 @newFrom ./...
                    }
                }
            }
        }
    }
    if ($Full) {
        # A trustworthy verdict: no cache, and shuffled so order dependence surfaces.
        Phase 'go test' { go test -count=1 -failfast -shuffle=on -timeout=10m ./... }
        # Report-level, not a stack line: -Quiet drops a green stack's lines, and the
        # commit hook runs -Quiet -- the one place this warning has to be seen.
        if ($script:Lines[-1] -like '`[PASS`]*') { $script:Warnings += @(Get-SlowGoPackages $script:PhaseOut 600) }
        # Workflows are the repository's, not the module's: asked once per run.
        if (-not $script:CiGoAsked) {
            $script:CiGoAsked = $true
            $goEnv = @(go env GOOS GOARCH)
            $checks = Get-CustomChecks $Root
            $covered = if ($checks -and -not $checks.Error) { ($checks.Checks.Run -join "`n") } else { '' }
            $covered += "`n" + ((@((Get-GoLintGoos $Root $goEnv[0]).Goos) | Where-Object { $_ } | ForEach-Object { "GOOS=$_" }) -join "`n")
            $script:Warnings += @(Get-CiGoGaps $Root $goEnv[0] $goEnv[1] $covered)
        }
        # The race detector catches a bug class go vet and golangci-lint structurally
        # cannot. It needs a cgo toolchain, so its absence is a warning, not a failure.
        if ($env:CGO_ENABLED -ne '0' -and (Have 'gcc')) {
            Phase 'go test -race' { go test -race -short -failfast -timeout=15m ./... }
        } else {
            $script:Lines += '[WARN] no cgo toolchain (gcc) -- go test -race skipped'
        }
        # Advisory Go checks: never a verdict, and noise over code that does not build.
        if (-not $script:Failed) {
            $script:Warnings += @(Get-GoleakGaps $s.Dir)
            # Opt-in (qgate.json go.deterministic): purity profile over this module's listed packages.
            $det = Get-GoDeterministic $Root
            if ($det.Error) { $script:Warnings += "[WARN] $($det.Error)" }
            elseif ($det) {
                $mine = @($det.Dirs | Where-Object { $_ -eq $s.Dir.TrimEnd('\', '/') -or $_.StartsWith($s.Dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar) })
                if ($mine) { $script:Warnings += @(Get-GoPurity $s.Dir $mine) + @(Get-GoPropertyGaps $s.Dir $mine) }
            }
            # quality-gate#103: opt-in (qgate.json go.flaky) re-run of the CHANGED test
            # packages under constrained scheduling, plus the cheap static scan beside it.
            # Changed, not the whole module: the reported cost is minutes per package, and
            # a -Full lane that pays that for untouched code would be turned off in a week.
            # A repo that wants a fixed set regardless of the diff names it in "packages".
            $fl = Get-GoFlaky $Root
            if ($fl.Error) { $script:Warnings += "[WARN] $($fl.Error)" }
            elseif ($fl) {
                $script:Warnings += @(Get-GoFlakyGaps $s.Dir)
                $pkgs = @($fl.Packages)
                if (-not $pkgs) {
                    $ch = Get-ChangedPaths $Root $(if ($Baseline) { $Baseline } else { 'HEAD' })
                    $pkgs = @($ch | Where-Object { $_ -like '*_test.go' } |
                            ForEach-Object { Split-Path (Join-Path $Root ($_ -replace '/', '\')) -Parent } | Sort-Object -Unique)
                }
                # Other modules' packages are not this module's to run: a repo with two
                # go.mod files would otherwise run each changed package under both.
                $mine = @($pkgs | Where-Object { $_ -eq $s.Dir.TrimEnd('\', '/') -or $_.StartsWith($s.Dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar) } |
                        Where-Object { Test-Path $_ -PathType Container })
                if (-not $mine) {
                    $script:Lines += '[SKIP] flaky tests -- no changed test packages (qgate.json go.flaky "packages" runs a fixed set)'
                } else {
                    $lsw = [Diagnostics.Stopwatch]::StartNew()
                    $fr = Invoke-GoFlakyTests $s.Dir $fl $mine
                    $secs = $lsw.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                    if ($fr.Failed -eq 0) {
                        $script:Lines += "[PASS] flaky tests ($($fr.Ran) package(s), -count=$($fl.Count) -cpu=$($fl.Cpu)$(if ($fl.Race) { ' -race' })) (${secs}s)"
                    } elseif ($fl.Fail) {
                        $script:Lines += $fr.Lines; $script:Failed = $true
                    } else {
                        $script:Warnings += $fr.Lines
                    }
                    $script:Warnings += @($fr.Warn)
                }
            }
            $fsw = [Diagnostics.Stopwatch]::StartNew()
            $fuzz = Invoke-GoFuzz $s.Dir
            if ($fuzz.Ran) { $script:Lines += "$(if ($fuzz.Warn -match ' failed -- ') { '[WARN]' } else { '[PASS]' }) go fuzz $($fuzz.Ran) target(s) ($($fsw.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s)" }
            $script:Warnings += @($fuzz.Warn)
            if (-not (Have 'deadcode')) {
                $script:Lines += '[SKIP] deadcode -- not on PATH (go install golang.org/x/tools/cmd/deadcode@latest)'
            } elseif ($stale = Test-GoToolStale 'deadcode' $modGo 'go install golang.org/x/tools/cmd/deadcode@latest') {
                $script:Lines += "[SKIP] $stale"
            } else {
                $script:Warnings += @(Get-GoDeadcode $s.Dir)
            }
        }
    } else {
        # Both -count=1 and -shuffle=on defeat the Go test cache, so the fast lane
        # re-ran every package on every agent turn. -short lets a repo park its slow
        # suites behind testing.Short() instead of paying for them each turn.
        Phase 'go test' { go test -short -failfast -timeout=10m ./... }
    }
    # Mutation testing is minutes, not seconds: only when asked for, never from a hook.
    if ($Mutate -and -not $script:Failed) {
        if (-not (Have 'gremlins')) {
            $script:Lines += '[SKIP] gremlins -- not on PATH (go install github.com/go-gremlins/gremlins/cmd/gremlins@latest)'
        } elseif ($stale = Test-GoToolStale 'gremlins' $modGo 'go install github.com/go-gremlins/gremlins/cmd/gremlins@latest') {
            $script:Lines += "[SKIP] $stale"
        } else {
            $mut = @(Get-GoMutants $s.Dir $Baseline)
            $script:Lines += @($mut | Where-Object { $_ -like '`[PASS`]*' })
            $script:Warnings += @($mut | Where-Object { $_ -notlike '`[PASS`]*' })
        }
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
            # Exit 3 is "vulnerabilities found". Only then, and only when the repo acknowledges
            # any, is it asked again for ids: -format openvex is one JSON document whose
            # `affected` statements are exactly the called vulnerabilities the text lists.
            Phase 'govulncheck' {
                govulncheck ./...
                if ($LASTEXITCODE -eq 3 -and (Test-VulnAcks)) {
                    $vex = try { govulncheck -format openvex ./... 2>$null | Out-String | ConvertFrom-Json } catch { $null }
                    $found = @(foreach ($st in @($vex.statements | Where-Object { $_.status -eq 'affected' })) {
                            , @(@($st.vulnerability.name) + @($st.vulnerability.aliases) | Where-Object { $_ }) })
                    # No ids read is not "all acknowledged": the verdict stays the text run's.
                    if ($found) {
                        $left = @(Get-UnackedVulns 'govulncheck' $found)
                        $left
                        $global:LASTEXITCODE = [int][bool]$left.Count
                    }
                }
            }
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

# --- dotnet: one format pass over a temporary solution ---------------------
# `dotnet format` pays for loading an MSBuild workspace before it reads a single
# character of whitespace, and that cost is per INVOCATION, not per project. Measured
# on ContentTool (13 csproj, warm): 13 per-project calls 25.6s, ONE call over a
# solution holding the same 13 projects 3.3-3.6s. So a run with two or more dotnet
# stacks asks once and splits the answer back out per project -- every WHITESPACE line
# ends with `[<absolute csproj path>]`, so the attribution is the tool's own and not a
# guess of ours.
$script:DnEval = @{}
$script:FmtShared = $null   # $null = not tried yet, $false = per-project calls
$script:FmtSlnDir = $null

# One MSBuild evaluation per csproj, cached: the shared pass needs every project's TFM
# before the second stack has run its own `refs` phase, and paying for that evaluation
# twice would cost more than the pass saves.
function Get-DotnetEval([string]$ProjPath) {
    if (-not $script:DnEval.ContainsKey($ProjPath)) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $q = (& dotnet msbuild $ProjPath -getProperty:TargetFramework -getProperty:TargetFrameworks `
                -getProperty:IsTestProject -getProperty:OutputType -getItem:Reference -getItem:PackageReference -nologo 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        $sw.Stop()
        $script:DnEval[$ProjPath] = @{ Out = $q; Code = $code; Elapsed = $sw.Elapsed.TotalSeconds }
    }
    $script:DnEval[$ProjPath]
}

# qgate.json "dotnet" section, or an empty object.
function Get-QGateDotnetConfig([string]$Repo) {
    $f = Join-Path $Repo 'qgate.json'
    $c = if (Test-Path -LiteralPath $f) { try { (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).dotnet } catch { $null } }
    if ($c) { $c } else { [pscustomobject]@{} }
}

# Highest release version of a package already extracted in the global NuGet folder
# (NUGET_PACKAGES / NuGet.Config globalPackagesFolder respected), or $null. `.nupkg.metadata`
# is what NuGet itself writes last, so a half-extracted folder does not count.
# ponytail: highest version wins; an analyzer built for a newer Roslyn than the SDK surfaces
# as CS9057 (reported after the build); a per-package version pin is the upgrade path.
function Get-NuGetCachedVersion([string]$Id) {
    if ($null -eq $script:NuGetGlobal) {
        $script:NuGetGlobal = ''
        if ("$(& dotnet nuget locals global-packages --list 2>$null)" -match 'global-packages:\s*(.+?)\s*$') { $script:NuGetGlobal = $Matches[1] }
    }
    if (-not $script:NuGetGlobal) { return $null }
    $dir = Join-Path $script:NuGetGlobal $Id.ToLowerInvariant()
    @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName '.nupkg.metadata')) } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
}

function Get-DotnetTfms($info) {
    @(if ($info.Properties.TargetFramework) { $info.Properties.TargetFramework }
        else { ($info.Properties.TargetFrameworks -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
}

# The first TFM no installed SDK can build, or $null.
function Get-DotnetTooNew($Tfms, [int]$MaxSdk) {
    foreach ($t in $Tfms) { if ($t -match '^net(\d+)\.\d' -and [int]$Matches[1] -gt $MaxSdk) { return $Matches[1] } }
    $null
}

# Changed .cs files belonging to one stack, as the REPO-relative paths git gave us.
function Get-DotnetChangedCs($Stack, $Changed) {
    $prefix = if ($Stack.Rel) { "$($Stack.Rel)/" } else { '' }
    @($Changed | Where-Object { $_ -like '*.cs' -and $_.StartsWith($prefix) })
}

# $false when this run gets no shared pass -- fewer than two projects to check, or a
# solution that would not load. Every caller falls back to the per-project call.
function Get-DotnetSharedFormat([int]$MaxSdk, $Changed) {
    if ($null -ne $script:FmtShared) { return $script:FmtShared }
    $script:FmtShared = $false
    $cand = @()
    $inc = @()
    foreach ($d in @($stacks | Where-Object { $_.Stack -eq 'dotnet' -and $_.Implemented })) {
        # Only the projects this run would format anyway: the workspace load IS the
        # cost, so a project whose .cs files nobody touched does not belong in here.
        $cs = if ($null -ne $Changed) { Get-DotnetChangedCs $d $Changed } else { @() }
        if ($null -ne $Changed -and -not $cs) { continue }
        $e = Get-DotnetEval (Join-Path $d.Dir $d.Marker)
        if ($e.Code -ne 0) { continue }
        $i = try { $e.Out | ConvertFrom-Json } catch { $null }
        if (-not $i) { continue }
        # A TFM newer than every installed SDK fails the whole solution load, and the
        # project is a [SKIP] in its own stack anyway -- one machine gap must not turn
        # into a formatting verdict on the projects beside it.
        if (Get-DotnetTooNew (Get-DotnetTfms $i) $MaxSdk) { continue }
        $cand += (Join-Path $d.Dir $d.Marker)
        $inc += $cs
    }
    if ($cand.Count -lt 2) { return $false }

    # Written as text rather than `dotnet new sln` + `dotnet sln add`: measured 0.008s
    # against 0.63s for the same 13 projects, and 0.6s is a fifth of what the whole
    # pass costs. Absolute csproj paths load exactly like the relative ones the SDK
    # writes (measured); the type GUID is the one `dotnet sln add` stamps on a .csproj.
    # Outside the repository, keyed by root AND process, like the Go build directory:
    # two agents, or a hook and a hand-run qgate, must not write one file over another.
    $script:FmtSlnDir = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-fmt-$(Get-PathKey $Root)-$PID"
    New-Item -ItemType Directory -Path $script:FmtSlnDir -Force | Out-Null
    $sln = Join-Path $script:FmtSlnDir 'gate.sln'
    $txt = "Microsoft Visual Studio Solution File, Format Version 12.00`r`n"
    foreach ($p in $cand) {
        $txt += "Project(`"{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}`") = `"$([IO.Path]::GetFileNameWithoutExtension($p))`", " +
        "`"$p`", `"{$([guid]::NewGuid().ToString().ToUpper())}`"`r`nEndProject`r`n"
    }
    [IO.File]::WriteAllText($sln, $txt)

    $fargs = @($sln, '--verify-no-changes', '--no-restore', '-v', 'q')
    # --include is resolved against the CURRENT DIRECTORY, and an ABSOLUTE path matches
    # nothing at all -- silently, exit 0. The paths here are repo-relative because that
    # is what Get-ChangedPaths returns, so the pass runs from the repo root.
    if ($inc) { $fargs += @('--include') + $inc }
    Push-Location $Root
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = (& dotnet format whitespace @fargs 2>&1 | Out-String).TrimEnd()
    $code = $LASTEXITCODE
    $sw.Stop()
    Pop-Location

    $ws = @($out -split "`r?`n" | Where-Object { $_ -match 'error WHITESPACE' })
    if ($code -ne 0 -and -not $ws) {
        # The solution did not load. Nothing in that is a verdict on anyone's
        # whitespace, so the run goes back to the call it used to make and says so --
        # a check quietly downgraded is how a gate stops being one.
        # With the first error line: a fallback with no reason sends the reader to rerun
        # the tool by hand. On the same line -- a passing stack's summary keeps only the
        # [TAG] lines, so a second line would vanish exactly when the run is green.
        $why = @($out -split "`r?`n" | Where-Object { $_ -match '\berror\b' } | Select-Object -First 1)
        if (-not $why) { $why = @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) }
        $t = if ($why) { $why[0].Trim() -replace '\s+', ' ' } else { '' }
        $why = if ($t) { " ($($t.Substring(0, [Math]::Min(200, $t.Length))))" } else { '' }
        $script:Lines += "[WARN] the shared dotnet format pass could not load its solution -- falling back to one call per project$why"
        return $false
    }
    $byProj = @{}
    foreach ($l in $ws) {
        if ($l -match '\[([^\[\]]+\.csproj)\]\s*$') {
            $k = $Matches[1].ToLowerInvariant()
            if (-not $byProj.ContainsKey($k)) { $byProj[$k] = @() }
            $byProj[$k] += $l
        }
    }
    $script:FmtShared = @{ Lines = $byProj; Elapsed = $sw.Elapsed.TotalSeconds; Count = $cand.Count; First = $true }
    $script:FmtShared
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
    #
    # Cached: the shared format pass below evaluates every dotnet project in the run
    # before the first one is formatted, so by the time a later stack gets here the
    # answer is already paid for. The elapsed time is the one that evaluation cost,
    # whenever it happened.
    $projAbs = Join-Path $s.Dir $proj
    $ev = Get-DotnetEval $projAbs
    # A csproj msbuild cannot even evaluate IS a defect, so this one is a real phase.
    Phase 'refs' { if ($ev.Code -ne 0) { $ev.Out; $global:LASTEXITCODE = 1 } } -Elapsed $ev.Elapsed
    if ($script:Failed) { return }
    $info = try { $ev.Out | ConvertFrom-Json } catch { $null }

    # A multi-targeted project leaves the singular property EMPTY and lists them in the
    # plural one as `net8.0;net472`. Reading only TargetFramework there is a silent pass
    # over every TFM the project actually has.
    $tfms = Get-DotnetTfms $info
    # net4xx builds on any modern SDK; net<major>.0 needs that major installed. Reported
    # as a skip, not a red build: a project targeting an SDK nobody here has is a gap in
    # the machine, and the raw NETSDK1045 tells the reader nothing about which one.
    $tooNew = Get-DotnetTooNew $tfms $maxSdk
    if ($tooNew) {
        $script:Lines += "[SKIP] ${proj}: needs .NET SDK $($tooNew).x, installed $($sdkVers -join ', ')"
        return
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
    #
    # -Baseline narrows the same way at every level: whole files touched since that
    # revision, like golangci's --whole-files. Reported from the field: an upstream fork
    # carries 1091 whitespace errors nobody may reformat, and -Baseline was ignored here.
    $fmtArgs = @($proj, '--verify-no-changes', '--no-restore', '-v', 'q')
    $runFormat = $true
    $changed = $null
    if ($Baseline) { $changed = Get-ChangedPaths $Root $Baseline }
    elseif (-not $Full -and -not $All) { $changed = Get-ChangedPaths $Root }
    if ($null -ne $changed) {
        $prefix = if ($s.Rel) { "$($s.Rel)/" } else { '' }
        # --include is resolved against the CURRENT DIRECTORY, and an ABSOLUTE path
        # matches nothing at all -- silently, exit 0, a green format phase over an
        # unformatted file. Set-Location above put us in the project directory, so
        # these are relative to it.
        $cs = @(Get-DotnetChangedCs $s $changed | ForEach-Object { $_.Substring($prefix.Length) })
        if ($cs) { $fmtArgs += @('--include') + $cs }
        # A phase that did not run must never look like a phase that passed.
        else { $runFormat = $false; $script:Lines += "[SKIP] format $proj -- no changed .cs files$(if ($Baseline) { " since $Baseline" })" }
    }
    if ($runFormat) {
        # One pass over every dotnet project in this run, when there are two or more of
        # them; $false when there are not, and the per-project call below is unchanged.
        $shared = Get-DotnetSharedFormat $maxSdk $changed
        $fmtPhaseArgs = @{}
        if ($shared) {
            $ws = @($shared.Lines[$projAbs.ToLowerInvariant()])
            $fmtOut = ($ws -join "`n")
            # The tool's own exit code says whether the SOLUTION is clean; this project's
            # verdict is whether any of those lines carries its csproj.
            $fmtCode = if ($ws) { 2 } else { 0 }
            # The real cost lands on the first project that reads the pass. The others
            # say where their answer came from: a repeated 3.4s would multiply the run's
            # cost by the number of stacks, and 0.0s would deny the work happened.
            $fmtPhaseArgs.Time = if ($shared.First) {
                "$($shared.Elapsed.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s, one pass over $($shared.Count) projects"
            } else { 'shared pass' }
            $shared.First = $false
        }
        else {
            $fmtSw = [Diagnostics.Stopwatch]::StartNew()
            $fmtOut = (& dotnet format whitespace @fmtArgs 2>&1 | Out-String).TrimEnd()
            $fmtCode = $LASTEXITCODE
            $fmtSw.Stop()
            $fmtPhaseArgs.Elapsed = $fmtSw.Elapsed.TotalSeconds
        }
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
            } @fmtPhaseArgs -Soft
        }
        # Code style (IDE rules at warning/error in .editorconfig), -Full only and advisory:
        # a repository that raised a rule to `warning` but still carries violations would go
        # red on adoption. No .editorconfig anywhere above the project = no style rules, so
        # the ~2.7s workspace load (measured on the fixture) is not paid for nothing.
        # Same --include narrowing as whitespace. templates/.editorconfig starts at `suggestion`.
        $ec = $s.Dir
        while ($ec -and -not (Test-Path -LiteralPath (Join-Path $ec '.editorconfig'))) { $ec = Split-Path $ec -Parent }
        if ($Full -and $ec) {
            $styleOut = @(& dotnet format style @fmtArgs 2>&1 | ForEach-Object { "$_" })
            $styleCode = $LASTEXITCODE
            $ide = @($styleOut | Where-Object { $_ -match ':\s+(?:warning|error)\s+IDE\d+' })
            if ($ide) {
                $top = (@($ide | ForEach-Object { [regex]::Match($_, 'IDE\d+').Value } | Group-Object |
                        Sort-Object Count, Name -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
                $script:Lines += "[WARN] ${proj}: $($ide.Count) code-style violation(s) -- $top (fix: dotnet format style $proj)"
            }
            elseif ($styleCode -ne 0) { $script:Lines += "[UNKNOWN] ${proj}: could not check code style -- dotnet format style exited $styleCode" }
        }
    }

    # BepInEx plugin metadata (GUID, version, dependency GUIDs): strings BepInEx only checks
    # when the game loads the plugin. Source-only, so it runs even without the game
    # installed. Advisory; see gate/bepinex.ps1 for the regex ceiling.
    if ($Full -and (@($refs.Identity) + @($pkgs.Identity) | Where-Object { $_ -match '^BepInEx(\.|$)' })) {
        $script:Lines += @(& (Join-Path $PSScriptRoot 'bepinex.ps1') -ProjectDir $s.Dir)
    }

    # A missing reference is NOT a reason to skip the build unasked (#99): a HintPath can be
    # GENERATED by a pre-build target. JotunnLib's `build/JotunnLibRefsCorlib.props` points at
    # `$(VALHEIM_MANAGED)/publicized_assemblies/*.dll`, which its own task creates from
    # `AfterTargets="BeforeBuild"`, so on a machine where the game IS installed but no build
    # has run yet, a file that is not there says nothing about the install. Reported from the
    # field: the gate answered "game/SDK not installed" where plain `dotnet build` succeeded,
    # and one manual build flipped the verdict -- a gate whose answer depends on build history.
    #
    # So the build runs, and the references are looked at AGAIN afterwards: what is still not
    # on disk is what was really missing. Not read out of the build log -- MSB3245 is a
    # WARNING, so a project that compiles without ever touching the reference succeeds with it
    # and a quieter verbosity may not print it at all. The file system answers both cases.
    $rootDir = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    # Reported once, with the count and a name, so the reader can tell "game not installed"
    # from "the csproj is wrong" without reading forty MSB3245 lines.
    # A HintPath into bin/ or obj/ INSIDE this repository is another project's build output,
    # not a game install. Reported from the field: `..\Auga\bin\API\AugaAPI.dll` was blamed on
    # a missing game/SDK, the wrong cause and the wrong fix.
    $refNote = {
        param($set)
        $built = @($set | Where-Object {
                $f = [IO.Path]::GetFullPath($_.HintPath, $s.Dir)
                $f.StartsWith($rootDir, [StringComparison]::OrdinalIgnoreCase) -and
                (@($f.Substring($rootDir.Length) -split '[\\/]') | Where-Object { $_ -in 'bin', 'obj' })
            })
        $cause = if ($built.Count -eq $set.Count) { 'built by another project in this repo (build it first)' } else { 'game/SDK not installed on this machine' }
        "${proj}: $($set.Count) reference(s) missing ($([IO.Path]::GetFileName($set[0].HintPath))) -- $cause"
    }
    $script:DotnetRefSkip = $false
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
    # Roslyn analyzers, injected into THIS build and nowhere else: no repository here edits
    # its csproj to get static analysis, so the gate brings the packages with it. See
    # gate/qgate.analyzers.props for why that property and not DirectoryBuildPropsPath.
    # Full level only -- a fast lane that pays for an analyzer build on every commit is a
    # fast lane people stop running. Unity rules only where UnityEngine actually is: the
    # refs above already evaluated both item lists, so this costs nothing extra.
    $anaArgs = @()
    if ($Full) {
        $anaArgs = @("-p:CustomBeforeMicrosoftCommonProps=$(Join-Path $PSScriptRoot 'qgate.analyzers.props')",
            '-p:EnableNETAnalyzers=true', '-p:AnalysisLevel=latest-Recommended',
            '-p:AnalysisMode=Recommended', '-p:EnforceCodeStyleInBuild=true')
        if (@($refs.Identity) + @($pkgs.Identity) | Where-Object { $_ -like 'UnityEngine*' }) {
            $anaArgs += '-p:QGateUnity=true'
        }
        # Opt-in analyzers the gate NEVER downloads: injected only when the package already
        # sits in this machine's global NuGet folder, so restore resolves it from disk
        # (measured: builds with RestoreSources pointed at an empty directory). A repository
        # that references the package itself already gets its diagnostics, counted below.
        $optIn = @()
        if ((Get-QGateDotnetConfig $Root).sonar -eq $true) { $optIn += , @('SonarAnalyzer.CSharp', 'QGateSonarVersion', 'qgate.json dotnet.sonar') }
        $banned = @((Join-Path $s.Dir 'BannedSymbols.txt'), (Join-Path $Root 'BannedSymbols.txt')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($banned) { $optIn += , @('Microsoft.CodeAnalysis.BannedApiAnalyzers', 'QGateBannedApiVersion', 'BannedSymbols.txt') }
        foreach ($oi in $optIn) {
            if (@($pkgs.Identity) -contains $oi[0]) { continue }
            $v = Get-NuGetCachedVersion $oi[0]
            if ($v) {
                $anaArgs += "-p:$($oi[1])=$v"
                if ($oi[0] -like '*BannedApi*') { $anaArgs += "-p:QGateBannedSymbols=$banned" }
            }
            else { $script:Lines += "[SKIP] $($oi[0]) ($($oi[2])) -- not in the local NuGet cache; the gate does not download it (restore it once in any project)" }
        }
    }
    Phase 'build' {
        $o = (& dotnet build @buildArgs @anaArgs 2>&1 | Out-String).Trim()
        # Injecting PackageReferences forces a restore, and a restore has its own ways to
        # fail that have nothing to do with the code: no network, a private feed, a lock
        # file the new items do not match. A repository must never become unbuildable
        # because the gate wanted analyzers, so the build is repeated without them and the
        # verdict is the one the repository itself would get. `error CS` is what tells the
        # two apart -- the compiler ran and rejected the code, and that IS the verdict.
        # An analyzer error is the same: the analyzers ran, nothing failed to inject.
        # qgate.globalconfig caps the rules that default to error, so one left here is a
        # severity the repository itself asked for. Reported from the field: MA0037 read
        # as an injection failure and every analyzer finding went with it.
        if ($LASTEXITCODE -ne 0 -and $anaArgs -and $o -notmatch '(?m):\s+error\s+(?:CS|CA|MA|IDE|UNT|RS|S)\d+') {
            # Any coded error, not just NU/MSB: a reason nobody can act on is the generic
            # fallback the field report complained about.
            $reason = [regex]::Match($o, '(?m)error\s+[A-Z]+\d+[^\r\n]{0,60}').Value
            if (-not $reason) { $reason = 'the build failed with the analyzers injected' }
            $o = (& dotnet build @buildArgs 2>&1 | Out-String).Trim()
            $anaArgs = @()
            $script:Lines += "[WARN] analyzers -- injection failed, built without them ($reason)"
        }
        # The references, re-read now that any pre-build target has had its turn (#99). Still
        # not on disk means the machine really does not have them, and that is a skip -- never
        # a red build, whatever the exit code says. A machine without the game fails with
        # MSB3245 and a wall of CS0246 about every game type, and none of that is a verdict on
        # the code. Checked before the exit code on purpose: a project can also COMPILE
        # without a reference it never uses, and reporting [PASS] build for that would hide
        # that the gate checked the code with a reference silently dropped.
        $still = if ($missing) {
            @($missing | Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::GetFullPath($_.HintPath, $s.Dir)) -PathType Leaf) })
        }
        if ($still) { $script:PhaseSkip = (& $refNote $still); $script:DotnetRefSkip = $true; return }
        if ($LASTEXITCODE -ne 0) { $o; return }
        # Analyzer diagnostics are counted apart from the compiler's own: they are new, they
        # are loud on code nobody wrote against them, and a single number would make it look
        # as though csc suddenly disliked 300 things. No -warnaserror on either -- the owner
        # asked to see the volume first, and a rule that goes red before anyone has read it
        # is a rule people route around. Top offenders by rule id, capped like `format` above.
        # Rules whose only fix is an API added after .NET Framework (throw helpers, char
        # overloads, string.Contains(char)). Reported from the field (#87): a file that a
        # net8.0 test project `<Compile Include="..\X.cs" Link=...>`-links from a net472
        # project gets CA1512, and the suggested ThrowIfLessThanOrEqual does not exist where
        # that file really lives. Such a diagnostic in a file OUTSIDE this project's directory
        # is shown as info, not counted; the same rule on the project's own files still WARNs.
        $newApiRules = 'CA1510', 'CA1511', 'CA1512', 'CA1513', 'CA1847', 'CA1865', 'CA1866', 'CA1867', 'CA2249'
        $projDir = [IO.Path]::GetFullPath($s.Dir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $diags = @([regex]::Matches($o, '(?m)^\s*(?:(.+?)\(\d+[\d,]*\))?[^\r\n]*?:\s+warning\s+([A-Z]+\d+)') | ForEach-Object {
                $file = $_.Groups[1].Value
                [pscustomobject]@{
                    Code   = $_.Groups[2].Value
                    Linked = [bool]$file -and ($newApiRules -contains $_.Groups[2].Value) -and
                    -not ([IO.Path]::GetFullPath($file, $projDir).StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase))
                }
            })
        $linked = @($diags | Where-Object Linked | ForEach-Object Code)
        $codes = @($diags | Where-Object { -not $_.Linked } | ForEach-Object Code)
        if ($linked) {
            $script:Lines += "[INFO] ${proj}: $($linked.Count) newer-API analyzer diagnostic(s) in files linked from outside the project dir, not counted -- $((@($linked | Group-Object | Sort-Object Count, Name -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" })) -join ', ')"
        }
        # RS0030/RS0031 = BannedApiAnalyzers, S1234 = SonarAnalyzer: injected opt-in above or
        # referenced by the repository itself.
        $ana = @($codes | Where-Object { $_ -match '^(CA|MA|IDE|UNT|RS|S)\d+$' })
        $w = $codes.Count - $ana.Count
        if ($w) { $script:Lines += "[WARN] ${proj}: $w compiler warning(s)" }
        # An analyzer compiled against a newer Roslyn than this SDK does not load at all, and
        # its silence would read as a clean pass.
        if ($codes -contains 'CS9057') { $script:Lines += "[WARN] ${proj}: an analyzer needs a newer compiler than this SDK (CS9057) -- its rules did not run" }
        if ($ana) {
            $top = (@($ana | Group-Object | Sort-Object Count, Name -Descending |
                    Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
            $script:Lines += "[WARN] ${proj}: $($ana.Count) analyzer diagnostic(s) -- $top"
        }
    }
    # The build could not resolve the references after all: nothing below can say more
    # about code the compiler never read.
    if ($script:DotnetRefSkip) { return }
    if (-not $Full) { return }

    # Harmony patch targets a game update removed: strings the compiler cannot check. See
    # gate/harmony.ps1. Only where Harmony is referenced; the references themselves are
    # present, or the missing-reference [SKIP] on the build above already returned.
    if (@($refs.Identity) + @($pkgs.Identity) | Where-Object { $_ -match '^(0Harmony|Lib\.Harmony|HarmonyX)\b' }) {
        $hTfm = if (-not $info.Properties.TargetFramework) { $tfms[0] }
        Phase 'harmony' {
            # -Why lists every target that resolved, beside the count of them.
            $h = @(& (Join-Path $PSScriptRoot 'harmony.ps1') -Project $projAbs -Root $Root -Tfm $hTfm -Targets:$Why)
            $code = $LASTEXITCODE
            # Probes, other assemblies' findings and the per-assembly count of what could not
            # be checked are notes beside the verdict: shown on a pass too, like build's counts.
            $script:Lines += @($h | Where-Object { $_ -match '^\[(WARN|NOTE)\] ' })
            $h | Where-Object { $_ -notmatch '^\[(WARN|NOTE)\] ' }
            $global:LASTEXITCODE = $code
        }
    }

    # JetBrains InspectCode, opt-in (qgate.json {"dotnet": {"inspectcode": true}}): ReSharper's
    # own dead-code / redundancy / nullability engine, a different class than the Roslyn
    # analyzers above. Advisory. Takes a csproj directly (no temp .sln needed, measured), and
    # --no-build reuses the build above. --toolset-path pins the SDK's MSBuild: left to
    # itself it picked VS BuildTools' MSBuild, failed MSB4236 on the SDK resolver and
    # exited 3 with "No files to inspect". Roslyn-shaped rule ids are dropped (the build
    # line already counted them), and so is InconsistentNaming on `_`-prefixed names:
    # Harmony reads __instance / ___field by name.
    # Stays opt-in (#97): a full ReSharper pass costs minutes on a cold cache, and a check
    # nobody asked for that slows every commit is how a gate gets bypassed. What was missing
    # was that nobody knew it existed -- so a repo with jb installed and the switch off is
    # told once, on the full lane, how to turn it on.
    if ((Get-QGateDotnetConfig $Root).inspectcode -ne $true -and ($Full -or $All) -and (Have 'jb')) {
        $script:Warnings += '[NOTE] inspectcode (dead code, redundancies) is available: jb is on PATH -- enable with qgate.json {"dotnet": {"inspectcode": true}}'
    }
    if ((Get-QGateDotnetConfig $Root).inspectcode -eq $true -and -not $script:Failed) {
        if (-not (Have 'jb')) { $script:Lines += '[SKIP] inspectcode -- jb not on PATH (dotnet tool install -g JetBrains.ReSharper.GlobalTools)' }
        else {
            $sdkVer = "$(& dotnet --version 2>$null)".Trim()
            $sdkLine = @($sdks | Where-Object { $_ -like "$sdkVer *" }) | Select-Object -First 1
            $msb = if ($sdkLine -match '\[(.+)\]\s*$') { Join-Path (Join-Path $Matches[1] $sdkVer) 'MSBuild.dll' }
            # Caches kept per repository between runs (the warm run is the cheap one); the report is not.
            $icDir = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-inspectcode-$(Get-PathKey $Root)"
            New-Item -ItemType Directory -Path $icDir -Force | Out-Null
            $sarif = Join-Path $icDir "$PID.sarif"
            $icArgs = @($projAbs, '--no-build', "--output=$sarif", '--severity=WARNING', "--caches-home=$icDir", '--verbosity=ERROR')
            if ($msb -and (Test-Path -LiteralPath $msb)) { $icArgs += "--toolset-path=$msb" }
            $icSw = [Diagnostics.Stopwatch]::StartNew()
            $icOut = (& jb inspectcode @icArgs 2>&1 | Out-String).Trim()
            $icCode = $LASTEXITCODE
            $icSw.Stop()
            $icj = if ($icCode -eq 0 -and (Test-Path -LiteralPath $sarif)) { try { Get-Content -LiteralPath $sarif -Raw | ConvertFrom-Json } catch { $null } }
            Remove-Item -LiteralPath $sarif -Force -ErrorAction SilentlyContinue
            if (-not $icj) {
                $why = @($icOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
                $script:Lines += "[UNKNOWN] ${proj}: InspectCode produced no report (exit $icCode$(if ($why) { ": $($why[0])" }))"
            }
            else {
                $hits = @($icj.runs | ForEach-Object { $_.results } | Where-Object {
                        $_.ruleId -notmatch '^[A-Z]{1,4}\d+$' -and
                        -not ($_.ruleId -eq 'InconsistentNaming' -and $_.message.text -match "^Name '_")
                    })
                $secs = $icSw.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                if (-not $hits) { $script:Lines += "[PASS] inspectcode ${proj} (${secs}s)" }
                else {
                    $top = (@($hits | Group-Object ruleId | Sort-Object Count, Name -Descending |
                            Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
                    $script:Lines += "[WARN] ${proj}: $($hits.Count) InspectCode finding(s) (${secs}s) -- $top"
                    $script:Lines += @($hits | Select-Object -First 10 | ForEach-Object {
                            $loc = $_.locations[0].physicalLocation
                            "[WARN] inspectcode: $($loc.artifactLocation.uri):$($loc.region.startLine) $($_.ruleId) -- $($_.message.text)"
                        })
                }
            }
        }
    }

    # `dotnet test` exists only where a real test SDK does (custom Exe runners below).
    # Both facts come from the evaluation above, never from
    # the csproj text: IsTestProject is what the SDK itself sets once the project is
    # restored, and the PackageReference list covers the project before its first restore
    # and everything Directory.Build.props imports into it.
    $pkgIds = @($pkgs.Identity)
    if ($info.Properties.IsTestProject -eq 'true' -or $pkgIds -contains 'Microsoft.NET.Test.Sdk') {
        Phase 'test' { dotnet test $proj --no-build -nologo -v q }
    }
    # A self-check runner (#88): `Foo.Tests.csproj`, OutputType Exe, no test SDK, exit code
    # is the verdict. Seen in three BepInEx mod repos, each reported `no test project` while
    # `dotnet run` printed `all checks passed`. Recognised by the NAME plus Exe, never Exe
    # alone -- the mod's own tool is an Exe too. Advisory until the repo says otherwise
    # (qgate.json dotnet.testRunner "fail"): a runner may want a game install or a console,
    # and a new default-on FAIL over that would be red on machines, not on code.
    # Bounded and redirected to files, for the reasons the npm test script is.
    elseif ($info.Properties.OutputType -eq 'Exe' -and [IO.Path]::GetFileNameWithoutExtension($proj) -match '\.Tests?$') {
        $runTimeoutSec = 600
        $outFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-dntest-$(Get-PathKey $projAbs)-$PID.out"
        $errFile = "$outFile.err"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # Quoted by hand: Start-Process joins -ArgumentList with bare spaces.
        $p = Start-Process dotnet -ArgumentList 'run', '--project', "`"$proj`"", '--no-build' `
            -WorkingDirectory $s.Dir -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $done = $p.WaitForExit($runTimeoutSec * 1000)
        $sw.Stop()
        if (-not $done) { try { $p.Kill($true) } catch { } ; [void]$p.WaitForExit(5000) }
        $code = if ($done) { $p.ExitCode } else { 1 }
        $text = ((@((Get-Content $outFile -Raw -ErrorAction SilentlyContinue),
                    (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)) -join '') -as [string]).TrimEnd()
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        $name = if ($done) { "test (dotnet run $proj)" } else { "test (dotnet run $proj) -- timeout after ${runTimeoutSec}s" }
        if ($code -eq 0 -or (Get-QGateDotnetConfig $Root).testRunner -eq 'fail') {
            Phase $name { if ($code -ne 0) { $text; $global:LASTEXITCODE = 1 } } -Elapsed $sw.Elapsed.TotalSeconds
        }
        else {
            $script:Lines += "[WARN] $name exited $code -- advisory; qgate.json {`"dotnet`": {`"testRunner`": `"fail`"}} makes it a failure"
            # Tagged: a passing stack prints only tagged lines.
            $script:Lines += @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 20 | ForEach-Object { "[WARN] test: $_" })
        }
    }
    # An omitted phase and a passing one read identically in the report, and this is the
    # level where the reader is entitled to the difference: -Full is what CI and the
    # generated pre-commit hook run. The fast lane says nothing -- it never promised these.
    else { $script:Lines += '[SKIP] test -- no test project (IsTestProject/Microsoft.NET.Test.Sdk)' }
    # The analyzer build restored obj/project.assets.json WITH the injected packages. Every
    # later reader evaluates the project without them: `dotnet list package` then reported
    # the assets file out of sync in problems[] and vuln was [UNKNOWN] on every restored
    # project (reported from the field, measured), and the user's obj/ stayed injected.
    # A plain restore puts obj/ back to what the repository itself restores; the phases
    # above that reuse the build (--no-build) have already run.
    & dotnet restore $proj -nologo -v q *> $null
    # See the govulncheck note above: a known vulnerability is a defect, it lives on the
    # network, and a project with no PackageReference has nothing to ask about.
    if ($pkgIds) {
        # Neither the exit code nor the human table is readable: it exits 0 whether or
        # not it found anything, exits 1 when the source was merely unreachable, and
        # prints the table in the machine's display language. JSON is the only answer
        # that means the same thing everywhere. It needs the assets file, which is why
        # this runs after `build` restored one.
        $vulnSw = [Diagnostics.Stopwatch]::StartNew()
        $vo = (& dotnet list $proj package --vulnerable --include-transitive --format json --output-version 1 2>&1 | Out-String).Trim()
        $vulnSw.Stop()
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
            # Same as format/refs above: the tool ran before the Phase (its JSON has to be
            # parsed before it can be a verdict), so the stopwatch inside Phase wrapped a
            # loop over an in-memory array and printed `(0.0s)` for a phase that just went
            # to the advisory database over the network.
            # #82: the advisory id is the last segment of its URL (GHSA-...).
            $vulnLines = @(foreach ($p in $vulnerable) {
                    foreach ($v in $p.vulnerabilities) { "$($p.id) $($p.resolvedVersion): $($v.severity) -- $($v.advisoryurl)" }
                })
            if ($vulnLines -and (Test-VulnAcks)) {
                $found = @(foreach ($p in $vulnerable) { foreach ($v in $p.vulnerabilities) { , @(($v.advisoryurl -split '/')[-1]) } })
                $left = @(Get-UnackedVulns 'vuln' $found)
                $vulnLines = if ($left) { $vulnLines + $left } else { @() }
            }
            Phase 'vuln' {
                $vulnLines
                if ($vulnLines) { $global:LASTEXITCODE = 1 }
            } -Elapsed $vulnSw.Elapsed.TotalSeconds
        }
    }
    # Same reason as `test` above: nothing to ask reads exactly like nothing found.
    else { $script:Lines += '[SKIP] vuln -- no package references' }
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

    # Lint caches live under node_modules (#96): a bare `.cache/` at the package root is
    # ignored by no scaffold, so the first gate run left the tree dirty and an agent's
    # `git add -A` committed the caches. The directory is created here because neither
    # linter is required to make the parent of its --cache-location.
    New-Item -ItemType Directory -Force -Path (Join-Path $s.Dir 'node_modules\.cache') | Out-Null

    if (Test-AnyFile $s.Dir @('stylelint.config.*', '.stylelintrc*')) {
        Phase 'stylelint' {
            & "$bin\stylelint.cmd" "**/*.{vue,css,scss}" --no-color --max-warnings 0 --formatter compact `
                --cache --cache-strategy content --cache-location 'node_modules/.cache/stylelintcache'
        }
    }
    # eslint runs WITHOUT --fix on purpose: the gate must report problems, not
    # silently rewrite files another session may be editing.
    if (Test-AnyFile $s.Dir @('eslint.config.*', '.eslintrc*')) {
        Phase 'eslint' {
            & "$bin\eslint.cmd" . --no-color --max-warnings 0 --format stylish `
                --cache --cache-strategy content --cache-location 'node_modules/.cache/eslintcache'
        }
    }
    # knip: unused files, exports and dependencies (#97). The JS half of dead-code analysis,
    # advisory like `deadcode` is for Go. Runs only when the package installed knip AND
    # configured it: knip with no config reports against its own guesses about entry points,
    # which on a repo that never opted in is noise, not findings. Full lane only (it walks
    # the whole dependency graph). --no-exit-code, so a finding is a warning, not a verdict.
    $knipCfg = (Test-AnyFile $s.Dir @('knip.json', 'knip.jsonc', 'knip.config.*', 'knip.ts', 'knip.js')) -or $pkg.knip
    if (($Full -or $All) -and $knipCfg -and (Test-Path "$bin\knip.cmd")) {
        $kSw = [Diagnostics.Stopwatch]::StartNew()
        $kOut = (& "$bin\knip.cmd" --no-exit-code --reporter compact --no-progress 2>&1 | Out-String)
        $kSw.Stop()
        # The compact reporter prints a `Unused files (3)` style header per issue type; the
        # counts in those headers are the finding, the file lists under them the detail.
        $kHits = @([regex]::Matches($kOut, '(?m)^(?<t>[A-Za-z][^(\r\n]*?)\s*\((?<n>\d+)\)\s*$') |
                ForEach-Object { "$($_.Groups['t'].Value.Trim()): $($_.Groups['n'].Value)" })
        if ($kHits) {
            $script:Warnings += @("[WARN] knip: $($kHits -join ', ') ($([math]::Round($kSw.Elapsed.TotalSeconds, 1))s) -- advisory, not a failure",
                '       run `npx knip` in ' + ($(if ($s.Rel) { $s.Rel } else { '.' })) + ' for the list')
        } else { $script:Lines += "[PASS] knip ($([math]::Round($kSw.Elapsed.TotalSeconds, 1))s)" }
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
    # The repository's own declared test script, full level only -- the same split
    # `build` above uses, and for the same reason: the fast lane runs on every agent
    # turn. Only `test`: discovering arbitrary scripts would make the gate's meaning
    # depend on names nobody agreed on, and a project that declares none is silent
    # here exactly as it was before.
    if ($Full -and $scripts -contains 'test') {
        # Redirected to files and bounded, for the two reasons the custom stack is:
        # vitest and jest default to WATCH mode, so the run never returns at all, and
        # a process filling a pipe nobody drains blocks forever. CI=1 is what turns
        # both runners into a single pass; the timeout is what happens when it does
        # not. 10m, the same ceiling `go test` is given.
        $testTimeoutSec = 600
        $outFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-webtest-$(Get-PathKey $s.Dir)-$PID.out"
        $errFile = "$outFile.err"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # FORCE_COLOR for the same reason every other phase passes --no-color: escape
        # codes in a failure dump are noise the reader pays for. Restored either way,
        # like GIT_LFS_SKIP_SMUDGE below -- this process runs the other stacks too.
        $prior = @{ CI = $env:CI; FORCE_COLOR = $env:FORCE_COLOR }
        $env:CI = '1'
        $env:FORCE_COLOR = '0'
        try {
            $npmExe = if ($IsWindows) { 'npm.cmd' } else { 'npm' }
            # Read before the launch, so nothing born after it can be mistaken for
            # something already here: the defence against a recycled pid.
            $launchedAt = Get-Date
            $p = Start-Process $npmExe -ArgumentList 'run', 'test' `
                -WorkingDirectory $s.Dir -NoNewWindow -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $done = $p.WaitForExit($testTimeoutSec * 1000)
        } finally { $env:CI = $prior.CI; $env:FORCE_COLOR = $prior.FORCE_COLOR }
        $sw.Stop()
        # Kill the tree: npm is a parent, and the runner it started is what hangs.
        if (-not $done) { try { $p.Kill($true) } catch { } ; [void]$p.WaitForExit(5000) }
        $code = if ($done) { $p.ExitCode } else { 1 }
        # A dev server the suite forgot to stop is the same defect a custom check has,
        # and it is the one that keeps the port. Before the temp files are removed: a
        # leaked child holding the inherited stdout handle keeps them undeletable.
        $leak = Get-LeakReport $p.Id $launchedAt 'test'
        $text = ((@((Get-Content $outFile -Raw -ErrorAction SilentlyContinue),
                    (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)) -join '') -as [string]).TrimEnd()
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        # The timeout goes in the NAME, like the custom stack's: a killed runner
        # usually printed nothing, and "never came back" is not "exited 1".
        $name = if ($done) { 'test' } else { "test -- timeout after ${testTimeoutSec}s (watch mode? it is run with CI=1)" }
        Phase $name {
            if ($text) { $text }
            if ($leak) { $leak }
            if (($code -ne 0) -or $leak) { $global:LASTEXITCODE = 1 }
        } -Elapsed $sw.Elapsed.TotalSeconds
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
        # GIT_INDEX_FILE is cleared for the same call: inside a commit hook the clone
        # inherits the CALLER's index and rewrites it (measured with buf 1.50.1: the
        # staged tree changed, exit 0), and the staged-concurrency guard then blames a
        # commit that does not exist. Only here -- the guard itself still needs it.
        Phase 'buf breaking' {
            $prior = $env:GIT_LFS_SKIP_SMUDGE
            $priorIndex = $env:GIT_INDEX_FILE
            $env:GIT_LFS_SKIP_SMUDGE = '1'
            $env:GIT_INDEX_FILE = $null
            try { buf breaking --against $against } finally {
                $env:GIT_LFS_SKIP_SMUDGE = $prior
                $env:GIT_INDEX_FILE = $priorIndex
            }
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
        # Only the [gd_scene]/[gd_resource] header line, an .import sidecar and a
        # .uid sidecar (scripts and shaders, Godot 4.4+: the bare `uid://...` line)
        # declare one; every other uid= (an [ext_resource], a preload) is a
        # reference to a file that must exist.
        $decl = '^\[gd_(scene|resource)\b'
        $uids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($f in Get-ChildItem $s.Dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.tscn', '.tres', '.import', '.uid' -and $_.FullName -notmatch $noGodotDir }) {
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                if ($f.Extension -eq '.uid') {
                    if ($l -match '^\s*uid://(\S+)\s*$') { [void]$uids.Add($Matches[1]) }
                    continue
                }
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
    # quality-gate#104: every engine run below is bounded. `--import` sat at 100 % CPU
    # for 73 minutes on CodeDungeon (a broken %APPDATA%\Godot junction hung every
    # user:// write inside the editor) and the gate waited with it, in the pre-commit
    # lane too. An import normally takes seconds; ten minutes is generous for a first
    # import of a large asset tree and still ends a hang inside one coffee.
    $budget = Get-ToolTimeoutSec 'godot' 600
    # Quoted by hand: Start-Process joins -ArgumentList with bare spaces.
    $dirArg = "`"$($s.Dir)`""
    # Run twice: the first pass creates .godot/ and routinely reports errors that
    # exist only because it did not yet. Only the second pass is a verdict.
    Invoke-GodotPhase 'godot import' $godot $s.Dir @('--headless', '--path', $dirArg, '--import') $errs $budget -Warmup
    # A test that exercises a rejection path makes the engine print ERROR: lines
    # on purpose (a codec refusing a corrupt frame, say) -- that is the code under
    # test working. So here only a script that failed to load or parse is a
    # verdict from the output; the test itself speaks through its exit code, which
    # Phase already checks.
    $scriptErrs = 'SCRIPT ERROR|Parse Error|Failed to load script'
    foreach ($t in Get-ChildItem $s.Dir -Recurse -File -Filter '*_headless_test.gd' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $noGodotDir }) {
        $tf = "`"$($t.FullName)`""
        Invoke-GodotPhase "godot test $($t.Name)" $godot $s.Dir @('--headless', '--path', $dirArg, '--script', $tf) $scriptErrs $budget
    }
    # Boots the main scene and quits: catches autoload and boot-order breakage that
    # neither the import nor a script test ever loads.
    Invoke-GodotPhase 'godot smoke' $godot $s.Dir @('--headless', '--path', $dirArg, '--quit-after', '1') $errs $budget
}

# One bounded engine run, reported as a phase. -Warmup runs the same command once
# more first and discards what it printed (the import's create-.godot pass); a warmup
# that hangs is the same finding as a verdict that hangs, and is reported as one.
function Invoke-GodotPhase([string]$Name, [string]$Godot, [string]$Dir, [string[]]$GodotArgs, [string]$ErrPattern, [int]$TimeoutSec, [switch]$Warmup) {
    if ($script:Failed) { Phase $Name { }; return }
    $elapsed = 0.0
    if ($Warmup) {
        $r = Invoke-Bounded $Godot $GodotArgs $Dir $TimeoutSec
        $elapsed += $r.Elapsed
    }
    if (-not $Warmup -or $r.Done) {
        $r = Invoke-Bounded $Godot $GodotArgs $Dir $TimeoutSec
        $elapsed += $r.Elapsed
    }
    # The timeout goes in the NAME, like the custom stack's: "the engine never came
    # back" and "the engine reported an error" are different findings.
    $name = if ($r.Done) { $Name } else { "$Name -- timeout after ${TimeoutSec}s" }
    Phase $name {
        if ($r.Done) {
            $r.Lines | Where-Object { $_ -match $ErrPattern }
            if ($r.ExitCode -ne 0) { $global:LASTEXITCODE = $r.ExitCode }
        } else {
            # A hang usually has a cause outside the project (user:// on a broken
            # junction, a modal the headless run still waits on), so the remedy names
            # the budget, and the tail of the output is the only evidence there is.
            "godot was killed: no exit after ${TimeoutSec}s (budget: `"timeouts`": {`"godot`": <seconds>} in qgate.json)"
            $tail = @($r.Lines | Where-Object { "$_".Trim() } | Select-Object -Last 10)
            if ($tail) { 'last output:'; $tail }
        }
    } -FailIfOutput -Elapsed $elapsed
}

# --- bounded tool runs (#104) ---------------------------------------------
# A spawned tool with no time budget makes the gate exactly as reliable as the tool's
# worst day: a child at 100 % CPU with no output and no exit held a commit for 73
# minutes. Every run through here ends -- by exit or by kill of the whole process tree
# -- and says which. Output goes to files, not pipes: a process that fills a pipe
# nobody drains blocks forever, and the whole reason there is a timeout is that this
# process may not come back.
function Invoke-Bounded([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [int]$TimeoutSec) {
    $outFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-run-$PID-$([IO.Path]::GetRandomFileName()).out"
    $errFile = "$outFile.err"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $done = $p.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()
    # Kill the tree, not just the root: what hangs may be a child of what was launched.
    if (-not $done) { try { $p.Kill($true) } catch { } ; [void]$p.WaitForExit(5000) }
    $lines = @(foreach ($f in $outFile, $errFile) { Get-Content $f -ErrorAction SilentlyContinue })
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Done     = $done
        ExitCode = $(if ($done) { $p.ExitCode } else { 1 })
        Lines    = $lines
        Elapsed  = $sw.Elapsed.TotalSeconds
    }
}

# Optional qgate.json: {"timeouts": {"godot": 120}} -- seconds a stack's spawned tool
# may run before it is killed. Per stack, not per phase: the repo knows how long its
# tools take, and one number a reader can find beats one per engine flag. Anything
# that is not a positive integer means the default.
function Get-ToolTimeoutSec([string]$Stack, [int]$Default) {
    $file = Join-Path $Root 'qgate.json'
    if (-not (Test-Path $file)) { return $Default }
    $t = try { (Get-Content $file -Raw | ConvertFrom-Json).timeouts.$Stack } catch { $null }
    $n = $t -as [int]
    if ($n -gt 0) { return $n }
    return $Default
}

# The compile database, when the configure above did not write one. The Visual Studio
# generators ignore CMAKE_EXPORT_COMPILE_COMMANDS -- cmake's own documentation says so
# ("implemented only by Makefile Generators and the Ninja generator"), and 4.3.2 here
# writes no file for a VS build tree. That generator is the DEFAULT on Windows, so
# without this both analysis phases would be permanently [SKIP] on the platform this
# gate mostly runs on. A second configure with Ninja and clang-cl answers the same
# question -- which sources, with which flags -- and nothing else: it never builds, it
# writes inside the build tree the gate already owns, and it took 1.1s on Renderforge.
# clang-cl finds the MSVC toolchain and the Windows SDK by itself, so no developer
# shell is needed. The database is a LIST OF FLAGS, not a verdict: the build phase above
# is still the compiler's answer, this only tells the analysers where to look.
# No ninja, no clang-cl, or a project that clang-cl cannot configure -> no database, and
# the phases say so out loud rather than reading as though they had run.
function Get-CppCompileDb([string]$Dir, [string]$Build) {
    if (-not ((Have 'ninja') -and (Have 'clang-cl'))) { return $null }
    $out = Join-Path $Build 'qgate-cdb'
    & cmake -S $Dir -B $out -G Ninja -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_C_COMPILER=clang-cl `
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>&1 | Out-Null
    $db = Join-Path $out 'compile_commands.json'
    if (Test-Path $db) { return $db }
    return $null
}

# The fallback tree above is CONFIGURED and never BUILT, and that is the whole hole
# reported in #102: a dependency pulled by FetchContent can GENERATE its headers at
# build time (godot-cpp writes godot_cpp/classes/*.hpp from a custom command), so every
# translation unit that includes one is unparseable there -- counted as "not analysed"
# forever, silently blind. The generated headers DO exist, in the main tree, which the
# build phase just built; the Visual Studio projects there name the directories they
# live in. Harvest those and hand them to clang-tidy as extra -I. Appended, so they are
# searched AFTER the database's own flags: a directory that already has the header wins,
# and a stale one changes nothing. Building the cdb tree instead would pay a second full
# compile with a second compiler on every commit, and fail wherever clang-cl cannot
# build what MSVC can.
function Get-CppGeneratedIncludes([string]$Build) {
    if (-not (Test-Path $Build)) { return @() }
    $dirs = [ordered]@{}
    foreach ($p in @(Get-ChildItem $Build -Recurse -File -Filter '*.vcxproj' -ErrorAction SilentlyContinue)) {
        try { $x = [xml](Get-Content $p.FullName -Raw -ErrorAction Stop) } catch { continue }
        foreach ($v in @($x.Project.ItemDefinitionGroup.ClCompile.AdditionalIncludeDirectories)) {
            foreach ($d in @("$v" -split ';')) {
                # %(...) is MSBuild's "whatever was there before" and $(...) a macro this
                # gate is not the one to expand; both are noise, not directories.
                if (-not $d -or $d -match '%\(|\$\(') { continue }
                if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
                $full = (Resolve-Path -LiteralPath $d).Path
                if (-not $dirs.Contains($full)) { $dirs[$full] = $true }
            }
        }
    }
    # A command line, not a search: a tree with hundreds of projects would blow past the
    # Windows argument limit long before the extra directory helped anyone.
    return @($dirs.Keys | Select-Object -First 100)
}

# --- cpp: clang-format on the sources, cmake configure and build -----------
function Invoke-CppStack($s) {
    Set-Location $s.Dir
    $exts = '*.c', '*.cc', '*.cpp', '*.cxx', '*.h', '*.hh', '*.hpp', '*.hxx'
    # The repo root first: a native subdirectory inside a bigger repository keeps its
    # style at the top, which is also where clang-format's own upward search finds it.
    $cfg = @($Root, $s.Dir) | Where-Object { Test-Path (Join-Path $_ '.clang-format') } | Select-Object -First 1
    if (-not $cfg) {
        # There is no house style to check against, and inventing one would make the
        # gate the author of a diff nobody asked for. Said out loud: a phase that did
        # not run must never read like a phase that passed.
        $script:Lines += '[SKIP] format -- no .clang-format'
    } elseif (-not (Have 'clang-format')) {
        $script:Lines += '[SKIP] format -- clang-format not found'
    } else {
        $src = @(Get-ChildItem $s.Dir -Recurse -File -Include $exts -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Substring($s.Dir.Length) -notmatch $script:CppSkipDir })
        # -All means "every detected stack, ignore git status", so it ignores it here
        # too -- the same rule the Godot runner follows, and for the reason measured
        # there: narrowing under -All left the phase out of a run that asked for
        # everything while the stack line still said [PASS].
        if (-not $Full -and -not $All) {
            $changed = Get-ChangedPaths $Root
            if ($null -ne $changed) {
                $want = @($changed | ForEach-Object { Join-Path $Root ($_ -replace '/', '\') })
                $src = @($src | Where-Object { $want -contains $_.FullName })
            }
        }
        if ($src.Count -gt 0) {
            $paths = @($src.FullName)
            # --Werror is what turns the diagnostic into an exit code; without it
            # clang-format prints the complaint and exits 0.
            Phase 'format' { clang-format --dry-run --Werror @paths }
        } else {
            $script:Lines += '[SKIP] format -- no changed C/C++ sources'
        }
    }

    # Both phases below need cmake and both are full-level only, so the verdict about
    # a missing one comes AFTER the format phase rather than instead of it -- exactly
    # where the Godot binary's does, and for the same reason: failing every agent turn
    # over a tool that turn was never going to invoke is not a gate. The fast lane
    # still says it, as the detection [WARN] on the stack line.
    if (-not $Full) { return }
    if (-not (Have 'cmake')) {
        Fail 'cpp: cmake not on PATH -- required at the full level (https://cmake.org/download/)'
        return
    }
    # An existing cache is reused, never wiped: a configure from scratch re-runs every
    # compiler probe and re-fetches every FetchContent dependency, and this phase runs
    # on a commit.
    $build = Join-Path $s.Dir 'build'
    Phase 'configure' {
        # -A x64 is the generator PLATFORM, which only the Visual Studio generators
        # take -- and one of those is the default on Windows. Everywhere else the
        # generator is single-config, so the build type is a configure-time answer.
        # CMAKE_EXPORT_COMPILE_COMMANDS is what the two analysis phases below are
        # driven by; it costs nothing where it works and is ignored where it does not.
        if ($IsWindows) { cmake -S $s.Dir -B $build -A x64 -DCMAKE_EXPORT_COMPILE_COMMANDS=ON }
        else { cmake -S $s.Dir -B $build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON }
    }
    # --config on both platforms: a multi-config generator needs it and a single-config
    # one ignores it, so one code path covers the two.
    Phase 'build' { cmake --build $build --config Release }

    $cdb = Join-Path $build 'compile_commands.json'
    $extra = @()
    if (-not (Test-Path $cdb)) {
        $cdb = Get-CppCompileDb $s.Dir $build
        # Only the fallback tree needs them: a database the main tree wrote describes the
        # tree the build phase built, generated headers and all.
        if ($cdb) { $extra = @(Get-CppGeneratedIncludes $build | ForEach-Object { "--extra-arg=-I$_" }) }
    }

    # clang-tidy, driven by that database. Every finding is a [WARN] and none of them
    # fails the phase -- the same first pass the Roslyn analyzers got in 379f39d: the
    # volume comes first, and a rule that goes red before anybody has read it is a rule
    # people route around. The check list is judged the way b98e67d judged those, by
    # sampled hits over a real repository (Renderforge, 22 translation units):
    #   misc-include-cleaner 664, misc-non-private-member-variables-in-classes 478,
    #   misc-const-correctness 296, performance-enum-size 105, misc-use-anonymous-
    #   namespace 69, bugprone-easily-swappable-parameters 58
    # are 1670 of 1837 findings and not one of them reads as a bug -- "windows.h is not
    # used directly", "member variable 'color' has public visibility", "consider uint8_t
    # for this enum". They are off. What is left is 167, and it includes the ones worth
    # the phase: D3D12_HEAP_TYPE zero-initialised when that enum has no zero value,
    # (int)(x + 0.5) instead of lround, an increment inside a compound condition.
    # clang-diagnostic-* is off too: the analysis compiler here is not the build
    # compiler (see Get-CppCompileDb), so its opinion of the code is not this gate's --
    # `build` above already ran the one that is.
    $checks = 'bugprone-*,clang-analyzer-*,cert-*,performance-*,misc-*' +
    ',-modernize-*,-readability-*,-fuchsia-*,-llvmlibc-*,-altera-*,-cppcoreguidelines-avoid-magic-numbers' +
    ',-clang-diagnostic-*,-misc-include-cleaner,-misc-non-private-member-variables-in-classes' +
    ',-misc-const-correctness,-misc-use-anonymous-namespace,-performance-enum-size' +
    ',-bugprone-easily-swappable-parameters'
    if (-not (Have 'clang-tidy')) {
        $script:Lines += '[SKIP] tidy -- clang-tidy not found'
    } elseif (-not $cdb) {
        $script:Lines += '[SKIP] tidy -- no compile database'
    } else {
        $files = @((Get-Content $cdb -Raw | ConvertFrom-Json).file | Sort-Object -Unique |
            Where-Object { Test-CppOwn $_ $s.Dir })
        if ($files.Count -eq 0) {
            $script:Lines += '[SKIP] tidy -- no sources of this stack in the compile database'
        } else {
            Phase 'tidy' {
                $o = (& clang-tidy -p (Split-Path $cdb) --quiet "--checks=$checks" @extra @files 2>&1 | Out-String)
                $code = $LASTEXITCODE
                $hits = @([regex]::Matches($o, '(?m)^(.+?):\d+:\d+: warning: .*\[([a-z0-9-]+)\]\s*$') |
                    Where-Object { Test-CppOwn $_.Groups[1].Value $s.Dir })
                # A translation unit clang could not parse produced no findings and is not
                # therefore clean. It is also not a verdict on the code: the file compiles,
                # with the compiler the build phase used. Counted and named, never silent.
                $errs = @([regex]::Matches($o, '(?m)^.+?:\d+:\d+: error: ')).Count
                if ($code -ne 0 -and $hits.Count -eq 0 -and $errs -eq 0) { $o; return }
                if ($Baseline) { $hits = @(Select-BaselineHits $hits 'tidy' $s.Dir) }
                if ($hits.Count) {
                    $top = (@($hits | Group-Object { $_.Groups[2].Value } | Sort-Object Count, Name -Descending |
                            Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
                    $script:Lines += "[WARN] tidy: $($hits.Count) finding(s) -- $top"
                }
                if ($errs) { $script:Lines += "[WARN] tidy: $errs diagnostic(s) clang rejected that the build compiler accepts -- not analysed" }
                $global:LASTEXITCODE = 0
            }
        }
    }

    # cppcheck over the same database. Same first pass, same reason, and the same path
    # filter -- its findings arrive from wherever the preprocessor reached.
    if (-not (Have 'cppcheck')) {
        $script:Lines += '[SKIP] cppcheck -- cppcheck not found'
    } elseif (-not $cdb) {
        $script:Lines += '[SKIP] cppcheck -- no compile database'
    } else {
        Phase 'cppcheck' {
            $o = (& cppcheck --project=$cdb --enable=warning,performance,portability --inline-suppr --error-exitcode=1 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $hits = @([regex]::Matches($o, '(?m)^(.+?):\d+:\d+: [a-z]+: .*\[(\w+)\]\s*$') |
                Where-Object { Test-CppOwn $_.Groups[1].Value $s.Dir })
            if ($code -ne 0 -and $hits.Count -eq 0 -and $o -notmatch '(?m):\d+:\d+: ') { $o; return }
            if ($Baseline) { $hits = @(Select-BaselineHits $hits 'cppcheck' $s.Dir) }
            if ($hits.Count) {
                $top = (@($hits | Group-Object { $_.Groups[2].Value } | Sort-Object Count, Name -Descending |
                        Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
                $script:Lines += "[WARN] cppcheck: $($hits.Count) finding(s) -- $top"
            }
            $global:LASTEXITCODE = 0
        }
    }
}

# --- base: the checks that ask nothing about a language --------------------
# Every repository has this stack; there is no marker file to find. All three tools are
# optional external binaries, so a missing one is a [SKIP] carrying its name and never
# a failure -- the gate does not install toolchains, and turning every repository on a
# machine red over a tool nobody asked for is not a gate. Said out loud each time,
# because a phase that did not run must never read like a phase that passed.
function Invoke-BaseStack($s) {
    Set-Location $Root
    # #97: dead PROJECTS, the thing no per-language check was looking at. Full lane only --
    # it reads every .csproj and .sln in the tree, and the fast lane runs on every agent turn.
    if ($Full -or $All) { $script:Warnings += @(Get-OrphanProjects $Root) }
    # The gate's own rule set: gitleaks' default, minus three rules that were 51 of 51
    # false positives across nine repositories (the reasoning is in the .toml itself).
    # NOT applied over a repository that ships a gitleaks config of its own -- `-c`
    # REPLACES that file rather than adding to it, and a repo that already tuned its own
    # rules has thought about them harder than the gate has. Both lanes get the same
    # argument: a fast lane and a full lane disagreeing about one file is the divergence
    # the typos phase already had to be taught not to grow.
    $glCfg = @(if (-not (@('.gitleaks.toml', 'gitleaks.toml') |
                Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) })) {
            '-c'; (Join-Path $PSScriptRoot 'qgate.gitleaks.toml') })
    if (-not (Have 'gitleaks')) {
        $script:Lines += '[SKIP] secrets -- gitleaks not on PATH (https://github.com/gitleaks/gitleaks)'
        $script:BaseDeferred = $true
    } elseif ($Full -or $All) {
        # The working tree, untracked files included. NOT `gitleaks git`, which reads
        # commits: a secret sitting in a file nobody has committed yet is exactly the
        # one still worth catching. --redact, so the secret never reaches this log or
        # the agent's context. v8 renamed the old `gitleaks protect`; `git` and `dir`
        # are the current subcommands.
        #
        # JSON to stdout rather than the human `-v` output, because the findings have to
        # be FILTERED before they can be a verdict: `dir` walks the filesystem and knows
        # nothing about .gitignore. Measured on a real repository -- 108 MB of generated
        # graphify cache under an ignored directory, untracked, not that repo's code, and
        # a red gate over a `generic-api-key` inside it. Same rule gofmt and the Godot
        # scanner already follow: what a repo ignores is not part of that repo.
        #
        # Asked per FILE, not per directory: GOwebserver ignores `config.json` by name in
        # a tracked directory, that file holds a real jwt_secret, and the gate hard-failed
        # the repository over a file git can never commit -- a red gate that no correct
        # action makes green. One batched `check-ignore` for every distinct path a finding
        # named, which is a handful even when the findings are in the hundreds.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # 2>$null, not 2>&1: the progress and summary lines go to stderr and would make
        # the report unparseable JSON. Exit 1 is "leaks found" and 0 is "none"; anything
        # else is gitleaks failing, which is not a verdict about the code.
        #
        # `.`, not $Root -- the target is echoed verbatim into every File and, through it,
        # into every Fingerprint. The absolute form printed
        # `E:/DEV/CodeDungeon/x.md:generic-api-key:13` while the fix: line below tells the
        # reader to record that fingerprint in .gitleaksignore, a COMMITTED file: the same
        # finding gets a different fingerprint in a teammate's checkout and in CI, so the
        # line can never suppress it for both. Measured: `.` prints `x.md:github-pat:1`,
        # forward slashes even nested on Windows, and that line in .gitleaksignore takes
        # the finding to zero. Set-Location $Root above is what makes `.` the repo root.
        # A nested repository is another project (see Get-NestedRepos), and `dir` has no
        # exclude flag: a throwaway config extends the one that would have applied and
        # allowlists those paths, which gitleaks skips without reading. Measured on #78:
        # 662 s of secrets scan over repos that were not the commit's content.
        # ponytail: gitleaks caps [extend] depth at 2, so a repo config that itself
        # extends a file (not useDefault) loses that base here.
        #
        # The same allowlist skips what was costing the read without being able to hold a
        # finding (#89). Ignored paths: their findings are dropped below anyway, but gitleaks
        # still read them first. Binary media: no rule matches pixels, and measured on a
        # repo with a tracked Unity project, 2.43 GB walked in 68 s, 7.8 s once the asset
        # tree was skipped (.tga 2.1 GB, .png 321 MB). Text assets (.asset/.prefab/.json)
        # stay scanned. `--ignored` in its default (traditional) mode names a wholly
        # ignored directory once, with its trailing slash; -z keeps paths unquoted.
        $base = if ($glCfg) { $glCfg[1] } else { @('.gitleaks.toml', 'gitleaks.toml') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
        $esc = { param($p) $p -replace '([.\\+*?()\[\]{}|^$])', '\$1' }
        $skip = @(@(Get-NestedRepos $Root) | ForEach-Object { "$(& $esc $_)/" })
        $skip += @(((& git -C $Root status --ignored --porcelain -z 2>$null) -join '') -split "`0" |
                Where-Object { $_ -like '!! *' } | ForEach-Object { & $esc $_.Substring(3) } |
                ForEach-Object { if ($_.EndsWith('/')) { $_ } else { "$_$" } })
        $media = '(?i)\.(tga|png|jpe?g|gif|bmp|tiff?|psd|exr|hdr|dds|ktx2?|fbx|blend1?|wav|ogg|flac|mp[34]|mov|avi|webm)$'
        $paths = @("'''$media'''") + @(if ($skip) { "'''^($($skip -join '|'))'''" })
        $glTmp = Join-Path ([IO.Path]::GetTempPath()) "qgate-gitleaks-$(Get-PathKey $Root).toml"
        Set-Content -LiteralPath $glTmp -Value "[extend]`npath = '''$base'''`n[[allowlists]]`npaths = [$($paths -join ', ')]"
        $glDirCfg = @('-c', $glTmp)
        $raw = (& gitleaks dir @glDirCfg --redact --no-banner --no-color -f json -r - . 2>$null | Out-String)
        $glCode = $LASTEXITCODE
        $sw.Stop()
        $hits = @(if ($glCode -eq 1) { try { $raw | ConvertFrom-Json } catch { $null } })
        # Repo-relative paths with forward slashes; git check-ignore takes them as they
        # are, and `-C $Root` is the directory they are relative to. Verified on Windows.
        $ignored = Get-GitIgnoredSet $Root @($hits | ForEach-Object { $_.File } | Where-Object { $_ } | Sort-Object -Unique)
        $hits = @($hits | Where-Object { $_.File -and -not $ignored[$_.File] })
        Phase 'secrets' {
            if ($glCode -gt 1) { "gitleaks exited $glCode -- the scan did not complete"; $global:LASTEXITCODE = 1; return }
            foreach ($h in $hits) { "$($h.File):$($h.StartLine): $($h.RuleID) -- $($h.Fingerprint)" }
            # The finding itself is redacted, so the only thing a reader can act on is
            # the location and, for a false positive, the fingerprint above.
            if ($hits) { 'fix: remove the secret, or record the fingerprint in .gitleaksignore'; $global:LASTEXITCODE = 1 }
        } -Elapsed $sw.Elapsed.TotalSeconds
    } else {
        # The fast lane is the pre-commit shape: the index, which is what the next
        # commit would publish. Asked first, because nothing staged means nothing
        # scanned, and gitleaks answers that with exit 0 -- a green line standing for
        # an empty scan is the one thing this report must not print.
        $staged = @(& git -C $Root diff --cached --name-only 2>$null | Where-Object { $_ })
        if ($staged) { Phase 'secrets' { gitleaks git --staged @glCfg --redact --no-banner --no-color -v $Root } }
        else {
            $script:Lines += '[SKIP] secrets -- nothing staged (the full level scans the working tree)'
            $script:BaseDeferred = $true
        }
    }

    if (-not (Have 'typos')) {
        $script:Lines += '[SKIP] typos -- typos not on PATH (https://github.com/crate-ci/typos)'
        $script:BaseDeferred = $true
    } else {
        # -Full and -All judge the whole tree; the fast lane judges what changed,
        # narrowed by the same git question every other stack uses. A path git still
        # lists but that no longer exists is a deletion, and handing one to typos is an
        # error about a file nobody can fix.
        $paths = @()
        $narrow = (-not $Full -and -not $All)
        if ($narrow) {
            $changed = Get-ChangedPaths $Root
            if ($null -eq $changed) { $narrow = $false }
            else {
                # RELATIVE to the repository root, which Set-Location above made the
                # current directory. An absolute path is matched against the exclude
                # globs in _typos.toml AS GIVEN, so `E:\repo\locale\fr.txt` matches
                # `locale/*.txt` in nothing at all and the exclusion is lost -- the same
                # trap the dotnet --include pass already documents. Existence is still
                # asked of the absolute path: a path git lists but that no longer exists
                # is a deletion, and handing one to typos is an error about a file
                # nobody can fix.
                $paths = @($changed | ForEach-Object { $_ -replace '/', '\' } |
                    Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf })
            }
        }
        if ($narrow -and -not $paths) {
            $script:Lines += '[SKIP] typos -- no changed files'
            $script:BaseDeferred = $true
        } else {
            # No path argument at all means the current directory, which Set-Location
            # above made the repository root. `brief` is one line per typo,
            # file:line:col -- the long default repeats the line and underlines it.
            #
            # --force-exclude, and ONLY when paths are named: typos applies the repo's
            # own [files] extend-exclude to a tree walk and ignores it for any path
            # handed to it on the command line, so the two lanes disagreed about the
            # same file. Measured on a repo excluding workshop/locale/*.txt: the file
            # named explicitly reported 20 errors and exited 2, and exited 0 with the
            # flag, while the full lane never looked at it at all. The flag is half the
            # fix -- the paths above had to become relative too, or there is nothing for
            # the globs to match. The full lane passes no paths, so there the flag would
            # have nothing to force.
            #
            # --config is the gate's own default set (git hashes are not prose; the
            # reasoning is in the .toml itself). Passed ALWAYS, unlike the gitleaks -c
            # next door, because typos layers it on top of the repository's own
            # _typos.toml instead of replacing that file -- measured both ways, and the
            # two extend-ignore-re lists merge rather than one winning.
            $cfg = Join-Path $PSScriptRoot 'qgate.typos.toml'
            $targs = @('--format', 'brief', '--config', $cfg)
            if ($paths) { $targs += '--force-exclude' }
            # Nested repositories are other projects (Get-NestedRepos); typos' own walker
            # descends into them. --exclude adds to the repo's extend-exclude, measured.
            foreach ($n in Get-NestedRepos $Root) { $targs += '--exclude'; $targs += "/$($n -replace '([\[\]*?{}])', '\$1')/" }
            # Captured and counted, not handed straight to the report, for the reason the
            # format phase next door is: a first run on a repository that never had a
            # dictionary is hundreds of findings -- measured on a game mod, 387 findings and
            # 34630 chars -- and the report's 6000-char cap then cut it to ~76 lines and a
            # byte count. Worse, typos walks the tree in parallel: the surviving prefix
            # differed between runs on the same tree (56 of ~76 lines in common, measured),
            # so a pre-commit hook needed several runs to see one list and never saw the
            # total at all. Twenty SORTED lines plus the real totals say strictly more, and
            # the rest is one command away -- which the last line names, because nobody can
            # guess the --config path this phase runs with.
            $tsw = [Diagnostics.Stopwatch]::StartNew()
            $tOut = (& typos @targs @paths 2>&1 | Out-String)
            $tCode = $LASTEXITCODE
            $tsw.Stop()
            if ($Baseline) {
                $bf = Select-BaselineFindings $tOut $Root
                $tOut = $bf.Text
                if ($tCode -ne 0 -and $bf.Located -and $bf.Located -eq $bf.Hidden) { $tCode = 0 }
                if ($bf.Hidden) { $script:Warnings += @("[NOTE] typos: $($bf.Hidden) pre-existing finding(s) hidden by -Baseline $Baseline") }
            }
            Phase 'typos' {
                $hits = @($tOut -split "`r?`n" | Where-Object { $_ -match '^(.*?):\d+:\d+: ' } | Sort-Object)
                if ($hits.Count -gt 20) {
                    $files = @($hits | ForEach-Object { ($_ -replace '^(.*?):\d+:\d+: .*$', '$1') } |
                            Sort-Object -Unique).Count
                    "typos: $($hits.Count) finding(s) in $files file(s) -- showing first 20"
                    $hits | Select-Object -First 20
                    "full list: typos --format brief --config $cfg ."
                }
                else { $tOut.TrimEnd() }
                if ($tCode -ne 0) { $global:LASTEXITCODE = 1 }
            } -Elapsed $tsw.Elapsed.TotalSeconds
        }
    }

    # Advisory linters, one per file kind. Each runs only when files of its kind exist --
    # the changed ones on the fast lane, the git-tracked ones at -Full/-All, so ignored and
    # vendored trees stay out the same way they do for typos -- and it is [WARN] only,
    # never a verdict: style of markdown and YAML is a policy, and the rest are new here.
    # A missing binary is a [SKIP] naming it, same as every other base tool.
    # A repository's own config always wins; the gate's templates fill in only when there
    # is none, the same rule the gitleaks -c above follows.
    # Assigned before the pipe: Get-ChangedPaths returns its list comma-wrapped, and piped
    # straight on that arrived as ONE item, so the fast lane linted nothing.
    $lintPool = if (-not $Full -and -not $All) { Get-ChangedPaths $Root } else { & git -C $Root ls-files 2>$null }
    $lintPool = @($lintPool) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) }
    $tpl = Join-Path $PSScriptRoot '..\templates'
    $mdCfg = @(if (-not (Get-ChildItem -LiteralPath $Root -Force -Filter '.markdownlint*' -ErrorAction SilentlyContinue)) {
            '--config'; (Join-Path $tpl '.markdownlint.jsonc') })
    $yCfg = @(if (-not (Get-ChildItem -LiteralPath $Root -Force -Filter '.yamllint*' -ErrorAction SilentlyContinue)) {
            '-c'; (Join-Path $tpl '.yamllint.yml') })
    # #91: SpacesAfterTabs. dotnet format aligns a comment under the previous line's trailing
    # comment with tabs + 1-3 spaces, and the default checker called that spaces-for-tabs, so
    # applying the format phase's own fix raised this warning. Space-only indentation still fails.
    $ecCfg = @(if (-not (Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object Name -In '.editorconfig-checker.json', '.ecrc')) {
            '-config'; (Join-Path $tpl '.editorconfig-checker.json') })
    $linters = @(
        @{ Name = 'shellcheck'; Exe = 'shellcheck'; Match = '\.(sh|bash)$'; Args = @('-f', 'gcc'); Url = 'https://www.shellcheck.net' }
        @{ Name = 'actionlint'; Exe = 'actionlint'; Match = '^\.github/workflows/[^/]+\.ya?ml$'; Args = @('-no-color'); Url = 'https://github.com/rhysd/actionlint' }
        @{ Name = 'hadolint'; Exe = 'hadolint'; Match = '(^|/)(Dockerfile[^/]*|[^/]+\.dockerfile)$'; Args = @('--no-color'); Url = 'https://github.com/hadolint/hadolint' }
        @{ Name = 'markdownlint'; Exe = 'markdownlint-cli2'; Match = '\.md$'; Args = $mdCfg; Url = 'https://github.com/DavidAnson/markdownlint-cli2' }
        @{ Name = 'yamllint'; Exe = 'yamllint'; Match = '\.ya?ml$'; Args = @('-f', 'parsable') + $yCfg; Url = 'https://github.com/adrienverge/yamllint' }
        # Only what the repository declared: no .editorconfig, nothing to check against.
        @{ Name = 'editorconfig'; Exe = 'editorconfig-checker'; Match = $(if (Test-Path -LiteralPath (Join-Path $Root '.editorconfig')) { '.' } else { '^$' }); Args = @('-no-color') + $ecCfg; Url = 'https://github.com/editorconfig-checker/editorconfig-checker' }
    )
    foreach ($l in $linters) {
        $files = @($lintPool | Where-Object { $_ -match $l.Match })
        if (-not $files) { continue }
        if (-not (Have $l.Exe)) { $script:Lines += "[SKIP] $($l.Name) -- $($l.Exe) not on PATH ($($l.Url))"; continue }
        # markdownlint-cli2 reads its arguments as globs; ':' makes each a literal path.
        if ($l.Name -eq 'markdownlint') { $files = @($files | ForEach-Object { ":$_" }) }
        $lArgs = $l.Args
        # Its default groups findings under a file header; gcc is `path:line:col:`, which
        # the -Baseline filter can attribute. Only then, so the plain run stays as it was.
        if ($Baseline -and $l.Name -eq 'editorconfig') { $lArgs = @($lArgs) + @('-format', 'gcc') }
        # core.autocrlf=true (Git for Windows' default) checks an LF script out as CRLF, and
        # shellcheck then flags every line SC1017 over bytes the repository never holds.
        # Measured: Git Bash runs that CRLF copy fine. A script committed CRLF keeps it.
        # ponytail: all-or-nothing per run; one CRLF-committed script re-enables SC1017 for the batch.
        if ($l.Name -eq 'shellcheck') {
            $crIdx = @(& git -C $Root ls-files --eol 2>$null | Where-Object { $_ -match '^i/crlf' -and ($_ -split "`t", 2)[1] -in $files })
            if (-not $crIdx) { $lArgs = @($l.Args) + @('-e', 'SC1017') }
        }
        $lOut = ''; $lBad = $false; $lCrash = $null
        # ponytail: 100 paths per call keeps a big -Full tree under the Windows command-line limit.
        for ($i = 0; $i -lt $files.Count; $i += 100) {
            # One splatted array, never `@(a) @(b)`: those are array ARGUMENTS, and npm's
            # .ps1 shim (markdownlint-cli2) handed each to node as one space-joined string --
            # measured: every path became a single ENOENT, and no Markdown was ever linted.
            $callArgs = @($lArgs) + @($files[$i..([Math]::Min($i + 99, $files.Count - 1))])
            $chunkOut = (& $l.Exe @callArgs 2>&1 | Out-String)
            $lOut += $chunkOut
            # Exit 1 is "findings" for every one of these; anything else is the tool failing
            # (measured on a missing file: markdownlint/shellcheck/editorconfig 2, actionlint 3,
            # yamllint -1). ponytail: hadolint exits 1 for both, so its crash still reads as findings.
            if ($LASTEXITCODE -eq 1) { $lBad = $true }
            elseif ($LASTEXITCODE -ne 0 -and $null -eq $lCrash) { $lCrash = "exit $LASTEXITCODE$(@($chunkOut -split "`r?`n" | Where-Object { $_ -match 'error|ENOENT|not found|cannot' } | Select-Object -First 1) | ForEach-Object { ": $($_.Trim())" })" }
        }
        $global:LASTEXITCODE = 0
        if ($lCrash) {
            # A crashed linter checked nothing: never dress that up as advisory findings.
            $script:Lines += "[UNKNOWN] $($l.Name): could not lint $($files.Count) file(s) -- $($l.Exe) failed ($lCrash)"
            continue
        }
        if ($Baseline -and $lBad) {
            $bf = Select-BaselineFindings $lOut $Root
            $lOut = $bf.Text
            if ($bf.Located -and $bf.Located -eq $bf.Hidden) { $lBad = $false }
            if ($bf.Hidden) { $script:Warnings += @("[NOTE] $($l.Name): $($bf.Hidden) pre-existing finding(s) hidden by -Baseline $Baseline") }
        }
        if (-not $lBad) { continue }
        $hits = @($lOut -split "`r?`n" | Where-Object { $_.Trim() })
        # #100: markdownlint-cli2 opens with a banner -- its version, the glob list it was
        # given, the file count, the issue summary -- before the rule hits. None of those is
        # a finding, and the `Finding: :a.md :b.md ...` line echoed every checked path into
        # the warning, so a single MD022 hit read as ten findings.
        if ($l.Name -eq 'markdownlint') {
            $hits = @($hits | Where-Object { $_ -notmatch '^(markdownlint-cli2 v|Finding: |Linting: \d+ files?$|Summary: )' })
        }
        if (-not $hits) { continue }
        # The headline counts the files the findings are IN, not every file checked. A format
        # without a `path:line` prefix (editorconfig's default per-file grouping, a shim) has
        # nothing to count, so it falls back to the number of files handed to the tool.
        $hitFiles = @($hits | ForEach-Object { if ($_ -match '^\s*(.+?):\d+[:\s]') { $Matches[1] } } | Sort-Object -Unique)
        $nFiles = if ($hitFiles) { $hitFiles.Count } else { $files.Count }
        # Report-level, like the Go warnings: a green stack line keeps only the [WARN] header,
        # so the findings themselves would never be seen.
        $script:Warnings += @("[WARN] $($l.Name): findings in $nFiles file(s) -- advisory, not a failure"
            $hits | Select-Object -First 20 | ForEach-Object { "       $_" }
            if ($hits.Count -gt 20) { "       ... $($hits.Count - 20) more line(s): run $($l.Exe) on those files" })
    }

    # Full level only: the advisory database lives on the network, and no agent turn
    # should pay for that -- the same rule govulncheck and `npm audit` already follow.
    if (-not $Full) { return }
    if (-not (Have 'osv-scanner')) {
        $script:Lines += '[SKIP] vuln -- osv-scanner not on PATH (https://github.com/google/osv-scanner)'
        $script:BaseDeferred = $true
        return
    }
    # `scan source` is a v2 spelling. v1 has no such subcommand and reads the word as a
    # DIRECTORY NAME instead, exiting 127 with "cannot find the file specified: source"
    # -- a defensible failure standing on a reason about a path that was never in the
    # command, the same shape as the stale Go tool binary above.
    # Out-String, because it prints THREE lines (version, commit, built at) and -match
    # over an array returns the matching elements without ever setting $Matches -- the
    # version then read as $null and the guard below never fired.
    $osvMajor = if (((& osv-scanner --version 2>$null) | Out-String) -match '(\d+)\.\d+') { [int]$Matches[1] }
    if ($osvMajor -and $osvMajor -lt 2) {
        $script:Lines += "[SKIP] vuln -- osv-scanner $osvMajor.x on PATH, 'scan source' needs v2 (https://github.com/google/osv-scanner/releases)"
        $script:BaseDeferred = $true
        return
    }
    # No --licenses: in v2 it takes an allowlist value, and ANY value -- `false` included,
    # read as a licence named "false" -- switches licence scanning ON: an unrequested
    # licence table online, exit 127 "cannot retrieve licenses locally" offline. Scanning
    # is off unless the flag is given. A licence is a policy question, not a defect, and
    # this phase exists to report defects.
    #
    # Exit 128 is documented as "no packages found", which is not a finding and not an
    # error: a repository with no manifest or lockfile anywhere has nothing to ask the
    # advisory database about. Run before the Phase, because that has to be classified
    # before it can be a verdict -- the same shape as the dotnet vuln phase, which says
    # `[SKIP] vuln -- no package references` for the same reason. 0 is clean, 1 is
    # findings, 127 and everything else is the tool failing.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # Nested repositories are other projects (Get-NestedRepos). A regex exclude is matched
    # against the directory path with the volume and leading slash stripped, forward
    # slashes (measured on 2.5.1: `Temp/qg78/ws/deep/inner`), so it is anchored on that.
    $rootRe = ((($Root -replace '^[A-Za-z]:', '') -replace '\\', '/').Trim('/') -replace '([.\\+*?()\[\]{}|^$])', '\$1')
    $osvEx = @(foreach ($n in Get-NestedRepos $Root) {
            '--experimental-exclude'; "r:(^|/)$rootRe/$($n -replace '([.\\+*?()\[\]{}|^$])', '\$1')$" })
    $osvOut = (& osv-scanner scan source -r @osvEx $Root 2>&1 | Out-String).TrimEnd()
    $osvCode = $LASTEXITCODE
    # #82: exit 1 is findings. With acknowledgements in the repo, ask again in JSON: a
    # group is one advisory, `ids` plus `aliases` every name it goes by.
    if ($osvCode -eq 1 -and (Test-VulnAcks)) {
        $oj = try { & osv-scanner scan source -r --format json @osvEx $Root 2>$null | Out-String | ConvertFrom-Json } catch { $null }
        $found = @(foreach ($g in @($oj.results.packages.groups)) { , @(@($g.ids) + @($g.aliases) | Where-Object { $_ } | Select-Object -Unique) })
        if ($found) {
            $left = @(Get-UnackedVulns 'vuln' $found)
            if ($left) { $osvOut = (@($osvOut) + $left) -join "`n" } else { $osvCode = 0 }
        }
    }
    $sw.Stop()
    if ($osvCode -eq 128) {
        $script:Lines += '[SKIP] vuln -- no package sources found (osv-scanner)'
        $script:BaseDeferred = $true
        return
    }
    Phase 'vuln' {
        if ($osvCode -ne 0) { $osvOut; $global:LASTEXITCODE = 1 }
    } -Elapsed $sw.Elapsed.TotalSeconds
}

# --- custom: the commands the repository declares in its own qgate.json ----
# Arbitrary command lines out of a file in the working tree, which a clone, a pull or
# a branch switch can change under the reader. So they run only for a repo somebody
# read and trusted by hand: `qgate trust` records a hash of the checks, and any edit
# to a name, a command, a level or a timeout invalidates it.
#
# Untrusted is a [SKIP], never a [FAIL]: refusing to execute a command is not a
# verdict on the code, and a repository nobody has trusted yet must not be a repo
# nobody can commit to.
# A check that leaves a process behind reported green while still holding ports and
# files -- and the process that outlives its own parent is exactly the one .Kill($true)
# below cannot see, because the tree that call walks is built from LIVE parents. The
# Win32_Process record of an orphan still names the pid of its dead parent, so the
# orphan is findable by IDENTITY: descendant of the pid we launched, created no earlier
# than we launched it (pids are recycled). Never by executable name -- half this machine
# is running pwsh.
#
# Windows only, and deliberately: there is no Win32_Process elsewhere, and POSIX
# containment (process groups) is not implemented here.
function Get-Descendants([int]$RootPid, [datetime]$NotBefore) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $RootPid -and $_.CreationDate -ge $NotBefore })
    $found = @()
    $frontier = @($RootPid)
    while ($frontier) {
        $kids = @($all | Where-Object {
                $frontier -contains $_.ParentProcessId -and $found.ProcessId -notcontains $_.ProcessId })
        if (-not $kids) { break }
        $found += $kids
        $frontier = @($kids.ProcessId)
    }
    $found
}

# Asked on every path out of every command this gate owns, exit 0 included: a parent
# that exits clean while its child keeps the port is the entire defect. Grace first and
# bounded -- a child normally goes down within a moment of its parent, and only what
# survives that is a leak. Returns '' when there is nothing to report.
function Get-LeakReport([int]$RootPid, [datetime]$NotBefore, [string]$Name) {
    if (-not $IsWindows) { return '' }
    $left = @()
    foreach ($i in 1..6) {
        $left = @(Get-Descendants $RootPid $NotBefore)
        if (-not $left -or $i -eq 6) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $left) { return '' }
    # pid, name, and the ports it is holding -- never the command line, which is where a
    # token ends up. Get-NetTCPConnection is a Windows module that can be absent, and
    # evidence that cannot be gathered is not an error.
    $ev = foreach ($d in $left) {
        $ports = @()
        try {
            $ports = @(Get-NetTCPConnection -OwningProcess $d.ProcessId -State Listen -ErrorAction Stop |
                    Select-Object -ExpandProperty LocalPort -Unique)
        } catch { }
        "pid $($d.ProcessId) $($d.Name)$(if ($ports) { " listening on $($ports -join ',')" })"
    }
    # They are ours, so they are ours to end -- the same .Kill($true) a timeout uses.
    # Then verified: a kill that failed quietly would leave the report claiming a
    # cleanup that never happened.
    foreach ($d in $left) { try { (Get-Process -Id $d.ProcessId -ErrorAction Stop).Kill($true) } catch { } }
    Start-Sleep -Milliseconds 300
    $alive = @(Get-Descendants $RootPid $NotBefore)
    $leak = "[LEAK] $Name left $($left.Count) process(es) running: $($ev -join '; ')"
    $leak + $(if ($alive) { " -- STILL RUNNING after kill: $($alive.ProcessId -join ',')" } else { ' -- killed' })
}

function Invoke-CustomStack($s) {
    $custom = Get-CustomChecks $Root
    if (-not $custom) { return }
    if ($custom.Error) { Fail "custom -- $($custom.Error)"; return }
    if (-not (Test-ChecksTrusted $Root $custom.Checks)) {
        $script:Lines += '[SKIP] custom -- untrusted qgate.json checks (run: qgate trust)'
        $script:CustomDeferred = $true
        return
    }
    # From the repository root, whatever -Root said: a command written in qgate.json
    # is written against the repository, not against wherever the shell stood.
    Set-Location $Root
    foreach ($c in $custom.Checks) {
        # The same fast/full split every other phase uses: `full` is the level that
        # guards a commit and CI, `fast` also runs on every agent turn.
        if ($c.Level -eq 'full' -and -not $Full) {
            $script:Lines += "[SKIP] $($c.Name) -- level full, not run in the fast lane"
            # `full` is the DEFAULT, so a repo whose only stack is custom would meet the
            # zero-phase invariant on every fast run and block every agent turn over
            # work it explicitly deferred to the level that guards the commit.
            $script:CustomDeferred = $true
            continue
        }
        if ($c.Smoke) { Invoke-SmokeCheck $c; continue }
        # Redirected to files, not read from pipes: a process that fills a pipe nobody
        # is draining blocks forever, and the whole reason there is a timeout here is
        # that this command may not come back. Keyed by check AND process, like the Go
        # build directory: two agents in one repo must not write over each other.
        $outFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-custom-$(Get-PathKey "$Root|$($c.Name)")-$PID.out"
        $errFile = "$outFile.err"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # Read before the launch, so nothing born after it can be mistaken for something
        # that was already here: this is the whole defence against a recycled pid.
        $launchedAt = Get-Date
        $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $c.Run `
            -WorkingDirectory $Root -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $done = $p.WaitForExit($c.TimeoutSec * 1000)
        $sw.Stop()
        # Kill the tree, not the shell: `pwsh -Command` is a parent, and the build it
        # started is what is actually hanging.
        if (-not $done) { try { $p.Kill($true) } catch { } ; [void]$p.WaitForExit(5000) }
        $code = if ($done) { $p.ExitCode } else { 1 }
        # Asked before the temp files are removed: a leaked child still holding the
        # inherited stdout handle keeps them undeletable.
        $leak = Get-LeakReport $p.Id $launchedAt $c.Name
        $text = ((@((Get-Content $outFile -Raw -ErrorAction SilentlyContinue),
                    (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)) -join '') -as [string]).TrimEnd()
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        # The timeout goes in the NAME. "the command never came back" and "it exited 1"
        # are different findings, and the raw output cannot tell them apart -- a killed
        # command usually printed nothing at all.
        $name = if ($done) { $c.Name } else { "$($c.Name) -- timeout after $($c.TimeoutSec)s" }
        Phase $name {
            # Only when there is any: a killed command usually printed nothing at all,
            # and an empty line above the reason is not output, it is a gap.
            if ($text) { $text }
            # Every other phase's output names the tool that produced it; this one's
            # does not, and the command is the only thing here a reader can act on.
            if ($code -ne 0) { "run: $($c.Run)" }
            # ADDED to whatever the command itself reported, never instead of it: a leak
            # that replaced the real reason would trade one blind spot for another. And
            # it fails the phase on its own -- a green exit code is precisely how this
            # gets past a gate today.
            if ($leak) { $leak }
            if (($code -ne 0) -or $leak) { $global:LASTEXITCODE = 1 }
        } -Elapsed $sw.Elapsed.TotalSeconds
    }
}

# --- deploy: is the copy the host loads the one this tree builds? ----------
# quality-gate#26: "every rebuild of Auga gives a different hash" was measured false --
# two builds in one directory, clean or incremental, are byte-identical. What differs
# is the DIRECTORY: a deterministic build embeds the absolute obj\...\X.pdb path in
# the debug directory, and the PDB id, MVID and PE timestamp are hashed from it, so
# the same commit built in a worktree is 427 other bytes. A plain hash compare is
# therefore correct; the job here is naming which of the two causes a mismatch is.
function Get-PdbPath([string]$Path) {
    # The CodeView entry: where the compiler wrote the .pdb. $null for a non-PE file.
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $pe = [Reflection.PortableExecutable.PEReader]::new($fs)
            $cv = @($pe.ReadDebugDirectory() | Where-Object Type -eq 'CodeView')
            if ($cv) { $pe.ReadCodeViewDebugDirectoryData($cv[0]).Path }
        } finally { $fs.Dispose() }
    } catch { $null }
}

function Invoke-DeployStack($s) {
    $d = Get-DeployEntries $Root
    if (-not $d) { return }
    if ($d.Error) { Fail "deploy -- $($d.Error)"; return }
    # Full only: the fast lane does not rebuild the release artifact, so a compare there
    # would judge whatever build happened to be lying around.
    if (-not $Full) {
        $script:Lines += '[SKIP] deploy -- full level, not run in the fast lane'
        $script:CustomDeferred = $true
        return
    }
    foreach ($e in $d.Entries) {
        # %VARS% expand, so a committed qgate.json can say %VALHEIM%\BepInEx\plugins\...
        $built = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($e.Built), $Root)
        $dep = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($e.Deployed), $Root)
        $leaf = [IO.Path]::GetFileName($dep)
        if (-not (Test-Path -LiteralPath $dep -PathType Leaf)) {
            $script:Lines += "[SKIP] deploy $leaf -- not deployed on this machine ($dep)"
            $script:CustomDeferred = $true
            continue
        }
        if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
            $script:Lines += "[SKIP] deploy $leaf -- nothing built at $built (declare the build that makes it in `"checks`")"
            $script:CustomDeferred = $true
            continue
        }
        Phase "deploy $leaf" {
            $hb = (Get-FileHash -LiteralPath $built).Hash
            $hd = (Get-FileHash -LiteralPath $dep).Hash
            if ($hb -eq $hd) { return }
            "built $($hb.Substring(0, 12)) != deployed $($hd.Substring(0, 12)) ($dep)"
            $pb = Get-PdbPath $built
            $pd = Get-PdbPath $dep
            if ($pb -and $pd -and $pb -ne $pd) {
                "the deployed copy was compiled in another directory ($pd, this tree: $pb) -- the compiler embeds that path, so the same source from another checkout or worktree is different bytes. Deploy from this tree, or make the build path-independent: <PathMap>`$(MSBuildThisFileDirectory)=/_/</PathMap>"
            } elseif ((Get-Item -LiteralPath $built).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dep).LastWriteTimeUtc) {
                "the build is newer than the deployed copy -- redeploy: copy $built to $dep"
            } else {
                "the deployed copy is newer than this build -- it came from other source or another configuration; rebuild, then redeploy"
            }
            $global:LASTEXITCODE = 1
        }
    }
}

# --- run -------------------------------------------------------------------
$cwd = (Get-Location).Path
$report = @()

# -Parallel: stacks that only read and build inside their own directory run first, one
# child process per stack type (all go stacks share one child: the CI-parity question is
# asked once per run; all dotnet stacks share one `dotnet format` pass). The loop below
# then walks the stacks in the usual order and takes each child's result where the stack
# would have run, so the report, fail-fast SKIPs, warnings order and exit code are the
# sequential run's. The children ran every stack, so a stack after a failure costs time
# here but is still reported as not run. base, custom, deploy and proto stay in-process,
# after every child has exited: base scans the working tree, proto writes generated code
# into it and puts it back, custom runs arbitrary commands (deploy compares their output),
# and none of them may run while another stack is changing the tree.
# ponytail: one child per stack type, not per stack directory; split further if a repo
# with many modules of one type shows it matters.
$script:ChildResults = @{}
$parallelKeys = @()
if ($Parallel -and -not $ParallelStacks) {
    $groups = @($stacks | Where-Object { $_.Implemented -and $_.Stack -in 'go', 'web', 'rust', 'dotnet', 'cpp', 'godot' } | Group-Object Stack)
    if ($groups.Count -gt 1) {
        $pdir = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-parallel-$PID"
        New-Item -ItemType Directory -Force $pdir | Out-Null
        $childArgv = @(Get-SelfArgv $PSBoundParameters 'Parallel', 'Sarif', 'Extra', 'Root', 'ParallelStacks', 'ParallelOut') + @('-Root', $Root)
        $jobs = @($groups | ForEach-Object {
            [pscustomobject]@{ Keys = @($_.Group | ForEach-Object { "$($_.Stack)|$($_.Rel)" }); Out = Join-Path $pdir "$($_.Name).xml" }
        })
        $parallelKeys = @($jobs | ForEach-Object { $_.Keys })
        $jobs | ForEach-Object -ThrottleLimit ([Math]::Min($jobs.Count, [Environment]::ProcessorCount)) -Parallel {
            & pwsh -NoProfile -File $using:PSCommandPath @using:childArgv -ParallelStacks ($_.Keys -join ';') -ParallelOut $_.Out *> $null
        }
        foreach ($j in $jobs) {
            if (Test-Path $j.Out) { $r = Import-Clixml $j.Out; foreach ($k in $r.Keys) { $script:ChildResults[$k] = $r[$k] } }
        }
        Remove-Item $pdir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$childRec = @{}

foreach ($s in $stacks) {
    $label = if ($s.Rel) { "$($s.Stack) $($s.Rel)/" } else { $s.Stack }
    $key = "$($s.Stack)|$($s.Rel)"
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
    if ($parallelKeys -contains $key) {
        # Fail closed: a child that died without a result is a failure, not a pass.
        $r = $script:ChildResults[$key]
        if (-not $r) { $r = @{ Report = @("[FAIL] $label", "[FAIL] ${label}: -Parallel worker exited without a result"); Warnings = @(); Phases = 0; Failed = $true; Soft = $false } }
        $report += @($r.Report | Where-Object { $null -ne $_ })
        $script:Warnings += @($r.Warnings | Where-Object { $null -ne $_ })
        $script:Phases += $r.Phases
        if ($r.Failed) { $script:Failed = $true }
        if ($r.Soft) { $script:SoftFailed = $true }
        continue
    }
    $reportAt = $report.Count
    $warnAt = $script:Warnings.Count
    $script:Lines = @()
    $script:StackSoft = $false
    $before = $script:Phases
    try {
        switch ($s.Stack) {
            'base' { Invoke-BaseStack $s }
            'go' { Invoke-GoStack $s }
            'web' { Invoke-WebStack $s }
            'rust' { Invoke-RustStack $s }
            'proto' { Invoke-ProtoStack $s }
            'godot' { Invoke-GodotStack $s }
            'dotnet' { Invoke-DotnetStack $s }
            'cpp' { Invoke-CppStack $s }
            'custom' { Invoke-CustomStack $s }
            'deploy' { Invoke-DeployStack $s }
        }
    } catch {
        # Fail closed: a crash in the gate is a failure, never a silent pass.
        Fail "${label}: gate crashed -- $($_.Exception.Message)"
    } finally { Set-Location $cwd }

    if ($script:StackSoft) { $script:SoftFailed = $true }
    if ($script:Failed -or $script:StackSoft) {
        $out = Format-StackOutput $script:Lines $MaxChars
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
        # One phase per line, as a failing stack prints them (#75): joined with spaces, a
        # passing stack after a red one read as a single run-on line of [PASS]/[WARN] tags.
        $timings = @($script:Lines | Where-Object { $_ -match '^\[(PASS|WARN|SKIP|UNKNOWN|INFO)\]' }) | ForEach-Object { "`n$_" }
        $timings = $timings -join ''
        # Same rule one level down from the invariant below. Every web phase is
        # conditional on a config file or a package script, so a project with none of
        # them ran nothing and was still reported [PASS]. A stack that verified
        # nothing is flagged, never passed -- beside a stack that did real work the
        # run as a whole still stands, exactly as it does for an unimplemented stack.
        $ran = $script:Phases -gt $before
        $report += "$(if ($ran) { '[PASS]' } else { '[SKIP]' }) $label ($($s.Marker))$(if (-not $ran) { ' -- no check phase applies here' })$timings"
    }
    if ($ParallelStacks) {
        $childRec[$key] = @{
            Report = @($report | Select-Object -Skip $reportAt); Warnings = @($script:Warnings | Select-Object -Skip $warnAt)
            Phases = $script:Phases - $before; Failed = $script:Failed; Soft = $script:StackSoft
        }
    }
}
# Advisory, never a verdict: printed after the stack lines, shown under -Quiet (below).
if ($script:Warnings) { $report += $script:Warnings }
# Every stack has run; from here on a soft failure is a failure like any other.
if ($script:SoftFailed) { $script:Failed = $true }

# The temporary solution the dotnet format pass ran over is pure by-product: nothing
# reads it after the pass, and leaving it behind would keep one directory per repository
# ever gated on this machine, forever. Here rather than in a finally around the loop --
# every path out of the loop reaches this line, and a killed process leaves a directory
# named by its own PID, which nothing else will ever collide with.
if ($script:FmtSlnDir) { Remove-Item $script:FmtSlnDir -Recurse -Force -ErrorAction SilentlyContinue }
if ($ParallelStacks) { $childRec | Export-Clixml -LiteralPath $ParallelOut; exit 0 }

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
# The third one is the custom stack declining to run: nobody on this machine has read
# those commands yet, or they are full-level and this is the fast lane. Both are
# decisions of the gate's own rather than a repository that verifies nothing, and both
# say so on the record -- failing them would make an untrusted repo one nobody can
# commit to, and a repo whose checks are full-level one no agent turn can finish.
# The fourth is the base stack declining: all three of its tools are optional external
# binaries, and a machine without them must not turn every repository on it into one
# nobody can commit to. But base has no marker file, so it is in EVERY run -- an
# unconditional exemption here would quietly cover the web stack whose every phase is
# conditional, which is one of the doors this invariant was built to close. So it holds
# only when base was the whole run: beside any other stack, the count is the run's.
$baseOnly = $script:BaseDeferred -and -not @($stacks | Where-Object { $_.Stack -ne 'base' })
if (-not $script:Failed -and $script:Phases -eq 0 -and -not $script:CustomDeferred -and -not $baseOnly) {
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
# Bounded, the way the web test phase bounds npm: `go list -m -u all` and `npm outdated`
# ask a registry, and a stalled one held every full run -- the commit hook included --
# for as long as it liked, over a note that cannot change the verdict. The tree is
# killed on timeout because pwsh is only the parent; go or npm is what hangs.
if ($Full -and -not $script:Failed) {
    $advisoryTimeoutSec = 30
    $outFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-advisory-$PID.out"
    # Quoted by hand: Start-Process joins -ArgumentList with bare spaces, so a root with
    # a space in it would arrive as two arguments.
    $p = Start-Process 'pwsh' -ArgumentList '-NoProfile', '-File', "`"$(Join-Path $PSScriptRoot 'outdated.ps1')`"", '-Root', "`"$Root`"", '-Summary' `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    if ($p.WaitForExit($advisoryTimeoutSec * 1000)) {
        $note = @(Get-Content $outFile -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($note) { $report += $note }
    } else {
        try { $p.Kill($true) } catch { }
        [void]$p.WaitForExit(5000)
        $report += "[WARN] dependency update advisory timed out after ${advisoryTimeoutSec}s; update status is unknown"
    }
    Remove-Item $outFile, "$outFile.err" -Force -ErrorAction SilentlyContinue
}

# -Quiet keeps a PASSING run silent -- that is its whole documented job, and the
# generated pre-commit hook runs in it because the hook's stdout is context the
# model pays for. A [WARN] about the gate's own config file being unreadable is not
# a passing condition though: it is the gate saying its input is broken, and
# swallowing it here hid it exactly where it guards a commit. Same rule the
# qgate.json unknown-key warning already follows; the advisory [INFO] about newer
# releases and the per-stack notes stay silent on green. A timed-out advisory is shown:
# it is the reason this commit took 30s longer, and it says nothing was checked. A slow
# test package is shown: the hook is the only early warning before CI's -race times out.
# So is a CI Go variant the gate never runs: green here says nothing about that target.
if ($Quiet -and -not $script:Failed) { $report = @($report | Where-Object { $_ -match '^\[WARN\] (qgate\.|dependency update advisory timed out|slow tests:|CI parity:)' }) }
# A broken qgate.deferrals.json is read by outdated and by every vuln phase; say it once.
$seenDefer = [Collections.Generic.HashSet[string]]::new()
$report = @($report | Where-Object { "$_" -notmatch '^\[WARN\] qgate\.deferrals\.json (is not|.*entry)' -or $seenDefer.Add("$_") })
if ($report) { $report | ForEach-Object { Write-Output $_ } }
exit ($(if ($script:Failed) { 1 } else { 0 }))
