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

. (Join-Path $PSScriptRoot 'detect.ps1')
# The gate lives outside the repo it checks, so $PSScriptRoot says nothing about
# which repo this is: the project directory comes from Claude Code, cwd otherwise.
$root = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Get-RepoRoot (Get-Location).Path }

# The counter is keyed by session as well as repo: several sessions can share one
# working tree, and a counter left behind by one of them must not eat another
# session's attempts (or wave a failing gate straight through).
$session = ''
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try { $session = ($raw | ConvertFrom-Json).session_id } catch { }
}
$stateFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-$(Get-PathKey "$root|$session").txt"

# Counters from sessions that ended days ago would otherwise sit in TEMP forever,
# and a reused session id would inherit their attempts.
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
# ponytail: -All rechecks every stack on any new commit. If that gets slow on a big
# monorepo, scope it with `git diff --name-only <lastGreen> HEAD` instead.
$greenFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-green-$(Get-PathKey $root).txt"
$head = (& git -C $root rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0) { $head = $null }
$lastGreen = if (Test-Path $greenFile) { (Get-Content $greenFile -Raw).Trim() } else { '' }

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

$blocks = 0
if (Test-Path $stateFile) { [int]::TryParse((Get-Content $stateFile -Raw), [ref]$blocks) | Out-Null }
$blocks++
Set-Content -Path $stateFile -Value $blocks -NoNewline

if ($blocks -gt $MaxBlocks) {
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("Quality gate still failing after $MaxBlocks blocks, letting the turn end:`n$out")
    exit 0
}

[Console]::Error.WriteLine("Quality gate failed. Fix these before finishing:`n$out")
exit 2
