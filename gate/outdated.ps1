# Reports dependencies and toolchains that have a newer release. Never fails:
# "outdated" is not a defect, and a gate whose verdict depends on what the world
# published today is not a gate. Vulnerabilities are a different question and are
# deliberately not handled here.
#
#   qgate outdated            full report
#   qgate outdated -Summary   one line, used by the -Full run of the gate
#
# The network answers are cached per repo for a day: the pre-commit run must not
# pay for a registry round trip every time.
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Summary
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'detect.ps1')

if (-not $Root) { $Root = Get-RepoRoot (Get-Location).Path }
if (-not (Test-Path $Root)) { Write-Output "[FAIL] root not found: $Root"; exit 0 }
$Root = (Resolve-Path $Root).Path

$cacheFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-outdated-$(Get-PathKey $Root).txt"

# A manifest edited after the cache was written invalidates it: otherwise adding a
# dependency leaves yesterday's answer standing for another day.
$newestManifest = Get-ChildItem $Root -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in 'go.mod', 'go.sum', 'package.json', 'package-lock.json', 'Cargo.toml', 'qgate.deferrals.json' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Optional qgate.deferrals.json: an update knowingly postponed, with the reason
# and a date. Without it the only way to stop a known-and-accepted update from
# being reported every session is to stop reading the report.
#
#   {"dependencies": [
#     {"name": "vue", "until": "2026-11-01", "reason": "blocked by the component library"}
#   ]}
#
# `until` is mandatory and is the whole point: a deferral with no expiry is just
# a silence, and a reason nobody can find later is why this file exists at all.
# Parsed BEFORE the cache branch below, because that branch returns early and an
# expired deferral would then stay unreported for the life of the cache.
$deferrals = @()
$deferFile = Join-Path $Root 'qgate.deferrals.json'
if (Test-Path $deferFile) {
    $parsed = $null
    try { $parsed = (Get-Content $deferFile -Raw | ConvertFrom-Json).dependencies } catch { $parsed = $null }
    if ($null -eq $parsed) {
        $deferrals += , @{ Bad = 'qgate.deferrals.json is not readable as {"dependencies": [...]}' }
    }
    $n = 0
    foreach ($d in @($parsed)) {
        $n++
        $due = [datetime]::MinValue
        if (-not $d.name -or -not $d.reason) {
            $deferrals += , @{ Bad = "qgate.deferrals.json entry $n needs both 'name' and 'reason'" }
        } elseif (-not [datetime]::TryParseExact([string]$d.until, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$due)) {
            $deferrals += , @{ Bad = "qgate.deferrals.json entry for '$($d.name)' needs 'until' as yyyy-MM-dd" }
        } else {
            $deferrals += , @{ Name = [string]$d.name; Until = $due; Reason = [string]$d.reason }
        }
    }
}
$badDeferrals = @($deferrals | Where-Object { $_.Bad } | ForEach-Object { "[WARN] $($_.Bad)" })

# Splits a findings list into what is still reported, what a live deferral hides,
# and which deferrals have run out. A deferral matches the report line for its
# package -- the name, then its current version, then the arrow -- anchored that
# way so `vue` cannot silence `vue-router`.
function Split-Deferred([string[]]$Findings, [object[]]$Deferrals) {
    $today = (Get-Date).Date
    $keep = @($Findings)
    $hid = @()
    $exp = @()
    foreach ($d in $Deferrals | Where-Object { $_.Name }) {
        $rx = '(^|\s)' + [regex]::Escape($d.Name) + '\s+\S+\s+->'
        if (-not @($keep | Where-Object { $_ -match $rx })) { continue }
        if ($d.Until -ge $today) {
            $keep = @($keep | Where-Object { $_ -notmatch $rx })
            $hid += "[DEFERRED] $($d.Name) until $($d.Until.ToString('yyyy-MM-dd')) -- $($d.Reason)"
        } else {
            $exp += "[DEFERRAL EXPIRED] $($d.Name) was deferred until $($d.Until.ToString('yyyy-MM-dd')) -- $($d.Reason)"
        }
    }
    @{ Found = $keep; Hidden = $hid; Expired = $exp }
}

# The summary is the only caller allowed to answer from cache: an explicit
# `qgate outdated` must always go and look.
if ($Summary -and (Test-Path $cacheFile) -and
    ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalHours -lt 24 -and
    (-not $newestManifest -or $newestManifest.LastWriteTime -lt (Get-Item $cacheFile).LastWriteTime)) {
    # The cache holds the already-filtered list, so a deferral that has since
    # expired left its finding in there -- re-split it rather than trusting the
    # count, or an expiry would go unmentioned until the cache aged out.
    $c = Split-Deferred @(Get-Content $cacheFile | Where-Object { $_ }) $deferrals
    if ($c.Found.Count) { Write-Output "[INFO] $($c.Found.Count) dependency update(s) available -- run 'qgate outdated' for the list" }
    if ($c.Expired.Count) { Write-Output "[INFO] $($c.Expired.Count) deferral(s) in qgate.deferrals.json have expired -- run 'qgate outdated'" }
    exit 0
}

function Get-Latest([string]$Url, [string]$Property) {
    # Offline, rate-limited or renamed endpoint: say nothing rather than guess.
    try {
        $r = Invoke-RestMethod -Uri $Url -TimeoutSec 5 -MaximumRedirection 3
        if ($Property) { $r.$Property } else { ($r -split "`n")[0].Trim() }
    } catch { $null }
}

$found = @()
# Everything that could not be answered. Reporting "current" when the registry
# never replied is worse than saying nothing.
$unknown = @()

foreach ($s in @(Get-Stacks $Root)) {
    if (-not $s.Implemented) { continue }
    Push-Location $s.Dir
    try {
        $where = if ($s.Rel) { $s.Rel + '/' } else { './' }
        if ($s.Stack -eq 'go') {
            # Direct requirements only: an indirect module is the business of the
            # dependency that pulls it in.
            $tmpl = '{{if and (not .Indirect) .Update}}{{.Path}} {{.Version}} -> {{.Update.Version}}{{end}}'
            $lines = & go list -m -u -f $tmpl all 2>$null
            if ($LASTEXITCODE -ne 0) { $unknown += "go modules at $where" }
            else { foreach ($line in $lines) { if ($line) { $found += "[OUTDATED] go   $where $line" } } }
        } elseif ($s.Stack -eq 'web') {
            if (-not (Test-Path (Join-Path $s.Dir 'node_modules'))) {
                $found += "[SKIP] npm  $where node_modules missing, run npm ci"
            } else {
                # npm outdated exits 1 when it finds something -- that is data, not failure.
                $json = (& npm outdated --json 2>$null | Out-String).Trim()
                $global:LASTEXITCODE = 0
                try {
                    $pkgs = if ($json) { $json | ConvertFrom-Json } else { $null }
                    foreach ($p in $pkgs.PSObject.Properties) {
                        if ($p.Value.current -and $p.Value.latest -and $p.Value.current -ne $p.Value.latest) {
                            $found += "[OUTDATED] npm  $where $($p.Name) $($p.Value.current) -> $($p.Value.latest)"
                        }
                    }
                } catch { $unknown += "npm packages at $where" }
            }
        }
    } finally { Pop-Location }
}

# Toolchains: the gate's own results depend on these versions, so a stale one is
# worth knowing about even when every dependency is current.
if (Get-Command go -ErrorAction SilentlyContinue) {
    $cur = if ((& go version) -match 'go(\d+\.\d+(\.\d+)?)') { $Matches[1] } else { $null }
    $latest = Get-Latest 'https://go.dev/VERSION?m=text' $null
    if (-not $latest) { $unknown += 'go toolchain' }
    elseif ($cur -and "go$cur" -ne $latest) { $found += "[OUTDATED] tool go $cur -> $($latest -replace '^go', '')" }
}
if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
    $cur = if ((& golangci-lint --version) -match 'version (\S+)') { $Matches[1].TrimStart('v') } else { $null }
    $latest = (Get-Latest 'https://api.github.com/repos/golangci/golangci-lint/releases/latest' 'tag_name')
    if (-not $latest) { $unknown += 'golangci-lint' }
    elseif ($cur -and $cur -ne $latest.TrimStart('v')) { $found += "[OUTDATED] tool golangci-lint $cur -> $($latest.TrimStart('v'))" }
}
if (Get-Command cargo -ErrorAction SilentlyContinue) {
    $cur = if ((& cargo --version) -match 'cargo (\S+)') { $Matches[1] } else { $null }
    $latest = Get-Latest 'https://api.github.com/repos/rust-lang/rust/releases/latest' 'tag_name'
    if (-not $latest) { $unknown += 'rust toolchain' }
    elseif ($cur -and $cur -ne $latest) { $found += "[OUTDATED] tool rust/cargo $cur -> $latest" }
}

$split = Split-Deferred $found $deferrals
$found = $split.Found
$hidden = $split.Hidden
$expired = $split.Expired

# Only a complete answer is worth caching: a run that could not reach the network
# must not freeze "nothing to report" in for a day.
# ponytail: the cache stores the already-filtered list, so a deferral that expires
# today can stay hidden for up to the 24h cache life. Editing the file invalidates
# the cache (see $newestManifest), and a day's lag on a date the repo chose itself
# is not worth caching both lists to fix.
if (-not $unknown.Count) { Set-Content -Path $cacheFile -Value ($found -join "`n") }

if ($Summary) {
    # An expired deferral is the one thing here worth a line on an otherwise green
    # -Full run: the repo set that date itself and it has passed.
    if ($found.Count) { Write-Output "[INFO] $($found.Count) dependency update(s) available -- run 'qgate outdated' for the list" }
    if ($expired.Count) { Write-Output "[INFO] $($expired.Count) deferral(s) in qgate.deferrals.json have expired -- run 'qgate outdated'" }
    exit 0
}
if ($badDeferrals.Count) { $badDeferrals | ForEach-Object { Write-Output $_ } }
if ($expired.Count) { $expired | ForEach-Object { Write-Output $_ } }
if ($found.Count) { $found | ForEach-Object { Write-Output $_ } }
# Printed after the findings, not instead of them: a deferral is a decision the
# repo made, and it stays visible so it can be revisited rather than forgotten.
if ($hidden.Count) { $hidden | ForEach-Object { Write-Output $_ } }
if ($unknown.Count) {
    Write-Output "[UNKNOWN] could not check: $($unknown -join ', ') -- offline, rate limited or the tool failed"
} elseif (-not $found.Count) {
    Write-Output '[OK] every direct dependency and toolchain is current'
}
exit 0
