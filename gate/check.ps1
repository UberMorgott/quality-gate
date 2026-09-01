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

function Get-ChangedPaths([string]$Repo) {
    # Porcelain lines are "XY <path>" and may carry a rename ("old -> new") and quotes.
    $paths = @()
    foreach ($line in (& git -C $Repo status --porcelain 2>$null)) {
        if ($line.Length -le 3) { continue }
        $p = $line.Substring(3)
        if ($p -match ' -> ') { $p = $p -replace '^.* -> ', '' }
        $paths += $p.Trim('"')
    }
    $paths += (& git -C $Repo diff --name-only HEAD 2>$null)
    $paths | Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique
}

# --- select which stacks to run -------------------------------------------
if ($Only) {
    $stacks = @($stacks | Where-Object { $Only -contains $_.Stack })
} elseif (-not $All) {
    $changed = @(Get-ChangedPaths $Root)
    if ($changed.Count -eq 0) {
        if (-not $Quiet) { Write-Output '[SKIP] no changes' }
        exit 0
    }
    $selected = @()
    foreach ($p in $changed) {
        $owner = $stacks | Where-Object { $_.Rel -and $p.StartsWith("$($_.Rel)/") }
        # A path outside every stack directory (CI config, build scripts, root
        # files) can affect any of them -> run everything.
        if (-not $owner) { $selected = $stacks; break }
        $selected += $owner
    }
    $stacks = @($selected | Sort-Object Stack, Rel -Unique)
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
    $outDir = Join-Path ([IO.Path]::GetTempPath()) 'quality-gate-build'
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
    } else {
        $script:Lines += '[WARN] golangci-lint not on PATH -- phase skipped'
    }
    Phase 'go test' { go test -count=1 -failfast -shuffle=on -timeout=10m ./... }
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
    }
    # The expensive one (bundling): full level only.
    if (-not ($Fast -and -not $Full)) {
        $buildScript = @('build-only', 'build') | Where-Object { $scripts -contains $_ } | Select-Object -First 1
        if ($buildScript) { Phase 'build' { npm run $buildScript } }
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

if ($report -and -not ($Quiet -and -not $script:Failed)) { $report | ForEach-Object { Write-Output $_ } }
exit ($(if ($script:Failed) { 1 } else { 0 }))
