# Claude Code `Stop` hook wrapper: runs the fast level on every agent turn.
#
# Exit 2 => the agent is prevented from ending the turn and stderr becomes the
# blocking reason fed back to the model. See https://code.claude.com/docs/en/hooks
#
# `stop_hook_active` is NOT used as the loop guard: it is already true on the
# second stop of a turn, so honouring it made the gate block once and then wave
# through every later stop no matter what the gate said. The guard is a failure
# counter instead -- the gate blocks up to $MaxBlocks consecutive stops, then
# gives up and lets the turn end. Any passing run resets it.
$ErrorActionPreference = 'Continue'
$MaxBlocks = 3

# Stderr of a hook that exits 0 goes to the debug log only, never the transcript
# (https://code.claude.com/docs/en/hooks#exit-code-0), so a non-blocking verdict printed
# there reached nobody. `systemMessage` on stdout is shown in the transcript. Stderr keeps
# the copy for the debug log.
function Exit-Advisory([string]$Message) {
    [Console]::Error.WriteLine($Message)
    [Console]::Out.WriteLine((@{ systemMessage = $Message } | ConvertTo-Json -Compress))
    exit 0
}

. (Join-Path $PSScriptRoot 'detect.ps1')
# The gate lives outside the repo it checks, so $PSScriptRoot says nothing about
# which repo this is: the project directory comes from Claude Code, cwd otherwise.
$root = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Get-RepoRoot (Get-Location).Path }

# The counter is keyed by session as well as repo: several sessions can share one
# working tree, and a counter left behind by one of them must not eat another
# session's attempts (or wave a failing gate straight through).
$session = ''
$writers = @()
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try {
        $in = $raw | ConvertFrom-Json
        $session = $in.session_id
        # #98: `qgate hold` relied on the LEAD remembering to call it, and it did not. Claude
        # Code already tells the Stop hook what is still in flight: `background_tasks`, one
        # entry per in-flight task, `type` a label such as subagent / teammate / workflow /
        # shell / monitor (https://code.claude.com/docs/en/hooks#stop-input). Only the kinds
        # that edit files count as writers -- a background `tail -f` or dev server must not
        # switch the gate off for the whole session. `local_agent` is the raw discriminant a
        # subagent falls back to when the label is unknown. Absent on older Claude Code: then
        # nothing changes and `qgate hold` is still the way to say it.
        $writers = @($in.background_tasks | Where-Object {
                $_ -and ("$($_.type)" -match 'subagent|teammate|workflow|local_agent') -and
                ("$($_.status)" -notmatch '^(completed|failed|killed|stopped|cancell?ed)$')
            })
    } catch { }
}
$stateFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-$(Get-PathKey "$root|$session").txt"

# Counters from sessions that ended days ago would otherwise sit in TEMP forever,
# and a reused session id would inherit their attempts.
#
# The mask also matches the green mark below, deliberately: a repo nobody has
# touched for a day loses its mark and pays one -All on the next turn. That is the
# safe direction -- the mark is a claim that a green run has seen this commit, and
# an old claim about a repo that may have been rebased, pulled or edited by another
# tool is worth less than one extra fast run.
Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'quality-gate-stop-*.txt' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -ErrorAction SilentlyContinue

# The fast level scopes itself to UNCOMMITTED work (`git status` + `git diff HEAD`),
# so a turn that edits and then commits hands the hook a clean tree and the gate has
# nothing left to look at -- and committing as soon as a change verifies is this
# project's own rule, so that is the normal case, not a corner one. Worse, it stays
# blind on every later turn too: the commit is never uncommitted again.
#
# So the hook tracks the commit the gate was last green on. HEAD past it means work
# landed that no green run has seen, and the turn is checked in full instead of not
# at all. Keyed by repo only, not by session: the commit history is shared.
#
# This checks committed work at the FAST level. A defect only the full level catches
# (`go test -race`, govulncheck, the Godot import/headless/smoke phases) still rides
# in on a commit as far as this hook is concerned; pre-commit and CI are what cover
# it. That boundary is deliberate -- a per-turn hook cannot pay for the full level.
#
# ponytail: -All rechecks every stack on any new commit. Measured on a three-stack
# monorepo: clean-tree turn 1.0s, new-commit -All turn 3.3s, full level 30.6s. A new
# commit costs ~+2.3s, so the blunt version is worth keeping. If that stops being
# true, scope it with `git diff --name-only <lastGreen> HEAD` instead.
$greenFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-green-$(Get-PathKey $root).txt"
$head = (& git -C $root rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0) { $head = $null }
# No mark means no green run has vouched for this commit -- from a fresh TEMP, a
# swept mark, or a first run. Unknown is treated as moved, on purpose.
$lastGreen = if (Test-Path $greenFile) { (Get-Content $greenFile -Raw).Trim() } else { '' }

# A background subagent editing this same checkout is a writer the hook must not judge
# (#98): its half-written tree fails on purpose -- a red TDD phase does not compile -- and
# the FAIL lands on the LEAD agent, which must not touch those files at all. `qgate hold`
# says so out loud; see gate/hold.ps1 for why an explicit marker and not a heuristic.
# QGATE_HOLD covers the harness-configured case, where the env var is all there is.
$hold = if ($env:QGATE_HOLD -in '1', 'true', 'yes') { 'QGATE_HOLD' } else {
    $u = Get-QGateHoldUntil $root
    if ($u) { "until $($u.ToString('HH:mm:ss'))" }
}
if ($hold) {
    # Exit 0 and no gate run at all: the green mark is left alone, because no green run
    # happened and the next unheld turn still owes the check.
    Exit-Advisory "Quality gate skipped: qgate hold is active ($hold) -- a background writer owns this tree. Commits are still gated; qgate release ends the hold."
}

$argv = @('-Root', $root, '-Fast', '-Quiet')
if ($head -and $head -ne $lastGreen) { $argv += '-All' }

$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check.ps1') @argv 2>&1 | Out-String).TrimEnd()
if ($LASTEXITCODE -eq 0) {
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    # Only a green run may move this mark, or a failing run would excuse itself from
    # the next turn's check.
    if ($head) { Set-Content -Path $greenFile -Value $head -NoNewline }
    exit 0
}

# A red tree while a background writer is still running is not the LEAD's to fix (#98):
# report it, do not block. The true positive is not lost -- the turn that follows the
# writer's finish has no writer in flight and is gated as usual, and commits are gated by
# pre-commit either way. The block counter is left alone: this was not a blocked stop.
if ($writers) {
    $names = ($writers | ForEach-Object { (@($_.type, $_.agent_type) | Where-Object { $_ }) -join ' ' }) -join ', '
    Exit-Advisory "[WARN] Quality gate not enforced this turn: $($writers.Count) background writer(s) still running ($names), the tree may be half-written. Do not edit their files. The turn after they finish is gated; commits are still gated.`n$out"
}

$blocks = 0
if (Test-Path $stateFile) { [int]::TryParse((Get-Content $stateFile -Raw), [ref]$blocks) | Out-Null }
$blocks++
Set-Content -Path $stateFile -Value $blocks -NoNewline

if ($blocks -gt $MaxBlocks) {
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    Exit-Advisory "Quality gate still failing after $MaxBlocks blocks, letting the turn end:`n$out"
}

# Whose failure is this? A file written seconds ago can still be mid-edit by a background
# subagent, and then the fix is NOT for this agent to make: two writers on one file lose
# edits. Freshness alone is no excuse -- an agent that edits and ends its turn at once is
# the normal case, so the gate still blocks -- but it is worth naming, with the way out.
$fresh = @(& git -C $root status --porcelain 2>$null | ForEach-Object {
        if ($_.Length -lt 4) { return }
        # Rename entries read `R  old -> new`, and any path with a space comes quoted.
        $p = (($_.Substring(3) -split ' -> ')[-1]).Trim('"')
        $f = Get-Item -LiteralPath (Join-Path $root $p) -ErrorAction SilentlyContinue
        if ($f -and -not $f.PSIsContainer) { $f }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
$hint = ''
if ($fresh) {
    $age = ((Get-Date) - $fresh[0].LastWriteTime).TotalSeconds
    if ($age -ge 0 -and $age -lt 20) {
        $hint = "`n[NOTE] $($fresh[0].Name) was written $([int]$age)s ago. If a background subagent is still editing this tree, do not edit these files -- run ``qgate hold`` before ending the turn and ``qgate release`` when it finishes."
    }
}
[Console]::Error.WriteLine("Quality gate failed. Fix these before finishing:`n$out$hint")
exit 2
