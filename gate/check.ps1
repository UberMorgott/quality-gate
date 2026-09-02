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
[CmdletBinding()]
param(
    [string[]]$Only,      # go | web | rust | proto | godot -- restrict to these stacks
    [switch]$All,         # every detected stack, ignore git status
    [switch]$Fast,
    [switch]$Full,
    [switch]$Quiet,
    [switch]$Why,         # provenance: which marker file created (or did not create) each phase
    [string]$Baseline,    # git rev: report only issues newer than it (adoption on a dirty codebase)
    [string]$Root         # repo root; defaults to the git root of the cwd
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'detect.ps1')

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
if ($stacks.Count -eq 0) {
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
    $raw = (& git -C $Repo status --porcelain=v1 -z 2>$null | Out-String)
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
if ($Only) {
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

function Phase {
    param([string]$Name, [scriptblock]$Body, [switch]$FailIfOutput)
    if ($script:Failed) { return }
    $script:Phases++
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $global:LASTEXITCODE = 0
    $out = (& $Body 2>&1 | Out-String).TrimEnd()
    $sw.Stop()
    $sec = '{0:N1}' -f $sw.Elapsed.TotalSeconds
    if (($LASTEXITCODE -ne 0) -or ($FailIfOutput -and $out)) {
        $script:Lines += "[FAIL] $Name (${sec}s)"
        if ($out) { $script:Lines += $out }
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
    Phase 'gofmt' { gofmt -l . } -FailIfOutput
    # -o into a temp dir: a bare `go build ./...` drops the linked binary of every
    # main package into the working tree.
    # Keyed by module directory: two agents, two worktrees or two modules must not
    # write their binaries over each other.
    $outDir = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-build-$(Get-PathKey $s.Dir)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Phase 'go build' { go build -o $outDir ./... }
    Phase 'go vet' { go vet ./... }
    if (Have 'golangci-lint') {
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
        if (Have 'govulncheck') { Phase 'govulncheck' { govulncheck ./... } }
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
    $gd = @(Get-ChildItem $s.Dir -Recurse -File -Filter '*.gd' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $noGodotDir })
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
    if ($script:Failed) { break }
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
        $timings = ($script:Lines | Where-Object { $_ -match '^\[(PASS|WARN|SKIP)\]' }) -join ' '
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

# Only on the full level, only when everything passed: a note about newer releases,
# never a verdict. It cannot fail the run, and the Stop hook (-Fast) never sees it.
if ($Full -and -not $script:Failed -and -not $Quiet) {
    $note = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'outdated.ps1') -Root $Root -Summary 2>$null)
    if ($note) { $report += $note }
}

if ($report -and -not ($Quiet -and -not $script:Failed)) { $report | ForEach-Object { Write-Output $_ } }
exit ($(if ($script:Failed) { 1 } else { 0 }))
