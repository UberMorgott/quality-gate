# `qgate global on|off|status` and the gate side of the global dispatcher (#86).
#
#   qgate global on       git config --global core.hooksPath <install>/hooks
#   qgate global off      remove it again (only if it is ours)
#   qgate global status   print what the global setting is now
#   qgate global hook <toplevel>   what hooks/pre-commit calls; not for people
$ErrorActionPreference = 'Stop'
$home_ = Split-Path -Parent $PSScriptRoot
$sub = if ($args.Count -gt 0) { [string]$args[0] } else { 'status' }
$ours = (Join-Path $home_ 'hooks') -replace '\\', '/'

function Get-GlobalHooksPath {
    $v = (& git config --global --get core.hooksPath 2>$null)
    if ($LASTEXITCODE -eq 0 -and $v) { ([string]$v).Trim() } else { '' }
}
function Test-Ours([string]$Path) { $Path -and (($Path -replace '\\', '/').TrimEnd('/') -ieq $ours) }

switch ($sub) {
    'on' {
        $cur = Get-GlobalHooksPath
        if (Test-Ours $cur) { Write-Output "global    -- already on: core.hooksPath = $ours"; exit 0 }
        if ($cur) {
            # Replacing it would silently switch off every hook that setting serves.
            Write-Output "global    -- refused: git config --global core.hooksPath is already '$cur'"
            Write-Output '             unset it yourself first if the gate should take over.'
            exit 1
        }
        & git config --global core.hooksPath $ours
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output "global    -> core.hooksPath = $ours"
        Write-Output '             every repo gets the gate; unwired repos without qgate.json are advisory.'
        Write-Output '             opt a repo out with a .qgate-off file or qgate.json {"enabled": false}.'
        exit 0
    }
    'off' {
        $cur = Get-GlobalHooksPath
        if (-not $cur) { Write-Output 'global    -- already off'; exit 0 }
        if (-not (Test-Ours $cur)) { Write-Output "global    -- left alone: core.hooksPath is '$cur', not the gate's"; exit 0 }
        & git config --global --unset core.hooksPath
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output 'global    -- off: core.hooksPath removed'
        exit 0
    }
    'status' {
        $cur = Get-GlobalHooksPath
        if (Test-Ours $cur) { Write-Output "global    on  ($ours)" }
        elseif ($cur) { Write-Output "global    off (core.hooksPath is '$cur')" }
        else { Write-Output 'global    off' }
        exit 0
    }
    'hook' {
        $root = [string]$args[1]
        if (-not $root) { exit 0 }
        $cfgFile = Join-Path $root 'qgate.json'
        if (Test-Path (Join-Path $root '.qgate-off')) { exit 0 }
        $hasCfg = Test-Path $cfgFile
        if ($hasCfg) {
            $cfg = $null
            try { $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json } catch { $cfg = $null }
            if ($cfg -and $cfg.PSObject.Properties['enabled'] -and $cfg.enabled -eq $false) { exit 0 }
        }
        $gateArgs = @('-NoProfile', '-File', (Join-Path $home_ 'gate\check.ps1'), '-All', '-Full', '-Quiet', '-Root', $root)
        if ($hasCfg) {
            # The repository has said how it wants to be gated: enforce normally.
            & pwsh @gateArgs
            exit $LASTEXITCODE
        }
        # Reached only through the global dispatcher, never wired, no qgate.json: a
        # foreign repository with years of findings must not become uncommittable
        # the moment the global hook appears.
        $out = & pwsh @gateArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $out | ForEach-Object { Write-Output "$_" }
            Write-Output '[WARN] global mode: advisory (run qgate wire or add baseline to enforce)'
        }
        exit 0
    }
    default {
        [Console]::Error.WriteLine("qgate global: unknown subcommand '$sub'. Try: on, off, status")
        exit 64
    }
}
