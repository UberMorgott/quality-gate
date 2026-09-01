# Single entry point for the quality gate. Everything else is reached through it,
# so no call site anywhere ever needs an absolute path.
#
#   qgate                 run the gate on the current repo (fast level)
#   qgate -All -Full      any flag of gate/check.ps1, passed straight through
#   qgate wire            wire the current repo: agent hooks, configs, CI
#   qgate outdated        dependencies and toolchains with a newer release
#   qgate stop-hook       Claude Code `Stop` hook entry (reads stdin JSON)
#   qgate update          git pull in the install directory
#   qgate selftest        run the gate's own red-then-green self-test
#   qgate where           print the install directory and version
$ErrorActionPreference = 'Stop'
$home_ = Split-Path -Parent $PSScriptRoot
$rest = @($args)
$cmd = if ($rest.Count -gt 0 -and $rest[0] -notlike '-*') { $rest[0] } else { '' }
if ($cmd) { $rest = @($rest | Select-Object -Skip 1) }

function Invoke-Child([string]$script, [object[]]$argv) {
    # -File keeps $LASTEXITCODE meaningful; child scripts own their own output.
    & pwsh -NoProfile -File (Join-Path $home_ $script) @argv
    exit $LASTEXITCODE
}

switch ($cmd) {
    ''          { Invoke-Child 'gate\check.ps1'     $rest }
    'run'       { Invoke-Child 'gate\check.ps1'     $rest }
    'outdated'  { Invoke-Child 'gate\outdated.ps1'  $rest }
    'stop-hook' { Invoke-Child 'gate\stop-hook.ps1' $rest }
    'wire'      { Invoke-Child 'install.ps1'        $rest }
    'selftest'  { Invoke-Child 'selftest.ps1'       $rest }
    'update' {
        git -C $home_ pull --ff-only
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output "quality-gate $(git -C $home_ rev-parse --short HEAD) at $home_"
        exit 0
    }
    'where' {
        Write-Output "$home_  $(git -C $home_ rev-parse --short HEAD 2>$null)"
        exit 0
    }
    default {
        [Console]::Error.WriteLine("qgate: unknown command '$cmd'. Try: run, wire, outdated, stop-hook, update, selftest, where")
        exit 64
    }
}
