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
    [string[]]$Only,      # 'go' / 'web' -- restrict to these stacks
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
    @($paths | Where-Object { $_ } | ForEach-Object { $_.Trim("`n", "`r") -replace '\\', '/' } | Sort-Object -Unique)
}

# --- select which stacks to run -------------------------------------------
if ($Only) {
    $stacks = @($stacks | Where-Object { $Only -contains $_.Stack })
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
        foreach ($p in $changed) {
            # Longest match wins: with nested modules a/go.mod and a/b/go.mod, a
            # file under a/b belongs to a/b alone.
            $owner = $stacks | Where-Object { $_.Rel -and $p.StartsWith("$($_.Rel)/") } |
                Sort-Object { $_.Rel.Length } -Descending | Select-Object -First 1
            # A path outside every stack directory (CI config, build scripts, root
            # files) can affect any of them -> run everything.
            if (-not $owner) { $selected = $stacks; break }
            $selected += $owner
        }
        $stacks = @($selected | Sort-Object Stack, Rel -Unique)
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

function Phase {
    param([string]$Name, [scriptblock]$Body, [switch]$FailIfOutput)
    if ($script:Failed) { return }
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
    Phase 'go test' { go test -count=1 -failfast -shuffle=on -timeout=10m ./... }
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
    try {
        switch ($s.Stack) {
            'go' { Invoke-GoStack $s }
            'web' { Invoke-WebStack $s }
            'rust' { Invoke-RustStack $s }
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
        $timings = ($script:Lines | Where-Object { $_ -match '^\[(PASS|WARN)\]' }) -join ' '
        $report += "[PASS] $label ($($s.Marker)) $timings"
    }
}

# Only on the full level, only when everything passed: a note about newer releases,
# never a verdict. It cannot fail the run, and the Stop hook (-Fast) never sees it.
if ($Full -and -not $script:Failed -and -not $Quiet) {
    $note = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'outdated.ps1') -Root $Root -Summary 2>$null)
    if ($note) { $report += $note }
}

if ($report -and -not ($Quiet -and -not $script:Failed)) { $report | ForEach-Object { Write-Output $_ } }
exit ($(if ($script:Failed) { 1 } else { 0 }))
