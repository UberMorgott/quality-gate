# `qgate trust`: record that the custom checks in this repository's qgate.json may be
# executed on this machine.
#
# They are arbitrary command lines out of a file in the working tree -- a clone, a
# pull or a branch switch can change them under the reader -- so the gate runs them
# only after somebody has seen them printed here and said yes. `qgate wire` never
# does it: wiring a repository is not reading its commands.
#
#   qgate trust                trust the checks of the repo the cwd is in
#   qgate trust -Root <path>   ...of that repo
#   qgate trust -Remove        forget them again
[CmdletBinding(PositionalBinding = $false)]
param([string]$Root, [switch]$Remove)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'detect.ps1')

if (-not $Root) { $Root = Get-RepoRoot (Get-Location).Path }
if (-not (Test-Path $Root)) { Write-Output "[FAIL] root not found: $Root"; exit 1 }
$Root = (Resolve-Path $Root).Path
$store = Get-TrustStore
$key = Get-TrustKey $Root

$map = [ordered]@{}
if (Test-Path $store) {
    $j = try { Get-Content $store -Raw | ConvertFrom-Json } catch { $null }
    # Fail closed: overwriting a store we could not read would silently drop every
    # other repository the user has trusted.
    if ($null -eq $j) { Write-Output "[FAIL] the trust store is not readable, fix or delete it: $store"; exit 1 }
    foreach ($p in $j.PSObject.Properties) { $map[$p.Name] = $p.Value }
}

function Save-TrustStore($Map, [string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json $Map -Depth 3))
}

if ($Remove) {
    if (-not $map.Contains($key)) { Write-Output "not trusted, nothing to remove: $key"; exit 0 }
    $map.Remove($key)
    Save-TrustStore $map $store
    Write-Output "removed  $key"
    Write-Output "store    $store"
    exit 0
}

$custom = Get-CustomChecks $Root
if (-not $custom) {
    Write-Output "[FAIL] nothing to trust -- $(Join-Path $Root 'qgate.json') has no non-empty `"checks`" array"
    exit 1
}
if ($custom.Error) { Write-Output "[FAIL] $($custom.Error)"; exit 1 }

# The exact string, not a summary of it: the whole job of this command is that the
# person typing it has seen what will run as them.
Write-Output "These commands will run as you, from $Root, on every gate run:"
foreach ($c in $custom.Checks) {
    Write-Output "  $($c.Name)  [$($c.Level) level, timeout $($c.TimeoutSec)s]"
    Write-Output "    $(if ($c.Smoke) { 'smoke: ' + (ConvertTo-Json $c.Smoke -Compress -Depth 10) } else { $c.Run })"
}
$map[$key] = Get-ChecksHash $custom.Checks
Save-TrustStore $map $store
Write-Output "trusted  $key"
Write-Output "store    $store"
Write-Output 'Any edit to a name, command, level or timeout revokes this -- run qgate trust again.'
exit 0
