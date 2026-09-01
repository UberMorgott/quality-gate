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
$key = [BitConverter]::ToString(
    [Security.Cryptography.MD5]::HashData(
        [Text.Encoding]::UTF8.GetBytes("$($root.ToLowerInvariant())|$session"))
).Replace('-', '')
$stateFile = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-$key.txt"

$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check.ps1') -Root $root -Fast -Quiet 2>&1 | Out-String).TrimEnd()
if ($LASTEXITCODE -eq 0) {
    Remove-Item $stateFile -ErrorAction SilentlyContinue
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
