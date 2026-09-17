# `qgate hold` / `qgate release` -- tell the Stop hook that a BACKGROUND WRITER is still
# editing this working tree, so the turn that ends while it works is not gated (#98).
#
# Why this is explicit and not a heuristic: the hook cannot tell a half-written tree from
# a finished one by looking at it. "Some file changed N seconds ago" is the normal case --
# an agent edits and ends its turn at once -- so excusing the gate on that would excuse it
# on almost every real failure too. A marker somebody SET is the only signal that means
# "nobody is claiming this is finished", and it defaults to off, so no repo that does not
# use it changes behaviour.
#
# Bounded on purpose: a hold that outlives the writer would silently disable the hook for
# the rest of the session. It expires (default 15 min), `qgate release` ends it early, and
# the pre-commit gate is untouched either way -- nothing gets committed past the gate.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'on',
    [int]$Minutes = 15,
    [string]$Root
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'detect.ps1')

if (-not $Root) { $Root = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Get-RepoRoot (Get-Location).Path } }
# Same `quality-gate-stop-*` family as the hook's own state, so the hook's one-day sweep
# of TEMP also collects markers left behind by a session that never released.
$file = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-stop-hold-$(Get-PathKey $Root).txt"

switch ($Action.ToLowerInvariant()) {
    'off' {
        $had = Test-Path $file
        Remove-Item $file -ErrorAction SilentlyContinue
        Write-Output $(if ($had) { "qgate hold released for $Root" } else { "qgate hold: nothing held for $Root" })
    }
    'status' {
        $until = Get-QGateHoldUntil $Root
        Write-Output $(if ($until) { "qgate hold active for $Root until $($until.ToString('HH:mm:ss'))" } else { "qgate hold: off for $Root" })
    }
    default {
        if ($Action -notin 'on', '') {
            [Console]::Error.WriteLine("qgate hold: unknown action '$Action' (on, off, status)")
            exit 64
        }
        if ($Minutes -lt 1 -or $Minutes -gt 120) {
            [Console]::Error.WriteLine("qgate hold: -Minutes must be 1..120 (got $Minutes)")
            exit 64
        }
        $until = (Get-Date).AddMinutes($Minutes)
        Set-Content -Path $file -Value $until.ToString('o') -NoNewline
        Write-Output "qgate hold: Stop hook off for $Root until $($until.ToString('HH:mm:ss')) ($Minutes min) -- qgate release ends it; commits are still gated"
    }
}
exit 0
