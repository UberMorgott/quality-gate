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
# Help flags are not gate flags: without this they reached check.ps1 and came back
# as "A parameter cannot be found that matches parameter name 'h'".
if ($rest.Count -gt 0 -and $rest[0] -in '-h', '-?', '--help', '/?') { $cmd = 'help' }
if ($cmd) { $rest = @($rest | Select-Object -Skip 1) }

$usage = @'
qgate -- one quality gate for every stack in the repository

  qgate                 run the gate on the current repo (fast level: changed files)
  qgate -All -Full      any flag of the gate, passed straight through
  qgate wire            wire the current repo (configs, agent hooks; -CI adds a workflow)
  qgate outdated        dependencies and toolchains with a newer release
  qgate stop-hook       Claude Code `Stop` hook entry (reads stdin JSON)
  qgate update          git pull in the install directory
  qgate selftest        the gate's own red-then-green self-test
  qgate where           install path, commit and the tool versions in use

Gate flags: -All  -Fast  -Full  -Only <stack>  -Why  -Baseline <rev>  -Root <path>
  -Only takes one or more of: go web rust proto godot  (python is detected, not checked)
Exit codes: 0 pass, 1 fail, 2 from `stop-hook` blocks the agent's turn.
'@

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
    'help' { Write-Output $usage; exit 0 }
    'where' {
        # Which gate actually ran, and with which tools. A second checkout earlier
        # on PATH silently answering for every repo on the machine is a real thing
        # that happened; so is a linter whose patch version differs from CI's.
        # Get-GodotBin: GODOT_BIN set in one shell is invisible to an editor-launched
        # agent hook, and that is exactly the failure this command has to explain.
        . (Join-Path $home_ 'gate\detect.ps1')
        Write-Output "install   $home_  $(git -C $home_ rev-parse --short HEAD 2>$null)"
        Write-Output "resolved  $((Get-Command qgate -ErrorAction SilentlyContinue).Source)"
        foreach ($t in 'go', 'golangci-lint', 'govulncheck', 'node', 'npm', 'cargo', 'lefthook', 'buf', 'gdformat', 'gdlint') {
            $exe = Get-Command $t -ErrorAction SilentlyContinue
            # An absent tool is reported, not skipped: "what does the gate think it
            # has right now" is the whole question this command answers.
            if (-not $exe) { Write-Output "  $t -- not on PATH"; continue }
            $v = switch ($t) {
                'go' { (& go version) }
                'golangci-lint' { (& golangci-lint --version) }
                'node' { "node $(& node --version)" }
                'npm' { "npm $(& npm --version)" }
                'cargo' { (& cargo --version) }
                # Prints a bare version number, which alone in the list reads as nothing.
                'lefthook' { "lefthook $(& lefthook version)" }
                'buf' { "buf $(& buf --version)" }
                # gdformat/gdlint already print their own name.
                'gdformat' { (& gdformat --version) }
                'gdlint' { (& gdlint --version) }
                default { $t }
            }
            Write-Output "  $(($v | Select-Object -First 1))"
        }
        $godot = Get-GodotBin
        if ($godot) {
            Write-Output "  godot $(((& $godot --version 2>$null) | Select-Object -First 1))  $godot"
        } else {
            Write-Output '  godot -- not found; set GODOT_BIN to the Godot executable'
        }
        exit 0
    }
    default {
        [Console]::Error.WriteLine("qgate: unknown command '$cmd'. Try: run, wire, outdated, stop-hook, update, selftest, where")
        exit 64
    }
}
