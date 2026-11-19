# `qgate land`: fetch, rebase and push one branch under a machine-wide lock (quality-gate#221).
#
# Parallel agent sessions on one machine land to the same main. A gated push takes minutes
# (the pre-push hook runs the gate), main moved in the meantime, and the push came back
# non-fast-forward after a green gate -- one session lost 8 tries in a row. Holding one lock
# across fetch -> rebase -> `git push` (whose pre-push hook still gates the tree, unchanged)
# means landers through `qgate land` never race each other. A plain `git push` or another
# machine is outside the lock and can still race.
#
# Lock: %LOCALAPPDATA%\qgate\locks\<sha256(push url + branch)>.lock, an exclusive file handle
# (as `qgate update`), so a killed holder frees it. Keyed by the push URL, not the git dir:
# separate clones of one repository share it too. The holder line lives in a sibling file
# because a FileShare.None handle cannot be read by the waiter.
[CmdletBinding(PositionalBinding = $false)]
param([string]$Root, [string]$Remote = 'origin', [string]$Branch = 'main', [int]$WaitMinutes = 60)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'detect.ps1')
if (-not $Root) { $Root = Get-RepoRoot (Get-Location).Path }
$Root = (Resolve-Path $Root).Path
function Fail([string]$Msg) { Write-Output "[FAIL] land -- $Msg"; exit 1 }
function Invoke-Git { & git -C $Root @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') exited $LASTEXITCODE" } }

# No autostash, no landing from a half-finished operation: the rebase below must start clean.
if (-not "$(& git -C $Root symbolic-ref -q HEAD 2>$null)") { Fail 'detached HEAD: check out the branch you land' }
if (@(& git -C $Root status --porcelain --untracked-files=no 2>$null)) { Fail 'tracked files modified or staged: commit or stash first' }
$gitDir = "$(& git -C $Root rev-parse --absolute-git-dir)".Trim()
foreach ($m in 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD') {
    if (Test-Path (Join-Path $gitDir $m)) { Fail "a $m operation is in progress in ${Root}: finish or abort it first" }
}
$urls = @(& git -C $Root remote get-url --push --all $Remote 2>$null)
if ($LASTEXITCODE -ne 0 -or $urls.Count -ne 1) { Fail "remote '$Remote' must have exactly one push URL (has $($urls.Count))" }
# Same repository over different spellings (trailing .git or /, case on GitHub) -> one key.
$key = ($urls[0].Trim().ToLowerInvariant() -replace '/+$', '' -replace '\.git$', '') + " refs/heads/$Branch"
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 16).ToLowerInvariant()
$lock = Enter-QGateLock $hash $WaitMinutes "pid $PID, $Root" { param($h) Write-Output "land: waiting for another land of $key ($h)" }
if (-not $lock.Stream) { Fail "another land still holds $($lock.Path) after $WaitMinutes min" }
$queue = $null
try {
    # #241: a plain `git push` from another worktree never takes the land lock, but its pre-push
    # gate does take the machine-wide push queue. Holding that queue across fetch -> rebase -> push
    # keeps those pushers out of the window; QGATE_SLOT_HELD tells our own pre-push gate it is held.
    if (-not $env:QGATE_SLOT_HELD -and @(Get-Stacks $Root | Where-Object { $_.Stack -ne 'base' })) {
        $qName = if ($env:QGATE_PUSH_QUEUE) { $env:QGATE_PUSH_QUEUE } else { 'push-queue' }
        $qWait = if ($env:QGATE_PUSH_WAIT_MIN -match '^\d+$') { [int]$env:QGATE_PUSH_WAIT_MIN } else { 60 }
        $queue = Enter-QGateLock $qName $qWait "pid $PID, $Root (land)" { param($h, $pos) Write-Output "land: waiting for the machine-wide push queue -- position $pos, held by $h" }
        if ($queue.Stream) { $env:QGATE_SLOT_HELD = '1' } else { $queue = $null } # the pre-push gate queues itself
    }
    $tracking = "refs/remotes/$Remote/$Branch"
    # Another machine (or an unqueued push) can still move the branch: re-fetch, re-rebase and
    # push again, bounded. The pre-push gate re-runs each time because the rebased tree is new.
    for ($try = 1; ; $try++) {
        Invoke-Git fetch -q $Remote "+refs/heads/${Branch}:$tracking"
        $base = "$(& git -C $Root rev-parse $tracking)".Trim()
        & git -C $Root rebase -q $tracking
        if ($LASTEXITCODE -ne 0) {
            & git -C $Root rebase --abort 2>$null
            Fail "rebase onto $Remote/$Branch failed (conflict or the git error above), rebase aborted: resolve it by hand (git rebase $tracking), then land again"
        }
        # Hooks stay on: the pre-push gate judges the rebased tree.
        & git -C $Root push $Remote "HEAD:refs/heads/$Branch"
        $code = $LASTEXITCODE
        if ($code -eq 0) { break }
        Invoke-Git fetch -q $Remote "+refs/heads/${Branch}:$tracking"
        $moved = "$(& git -C $Root rev-parse $tracking)".Trim() -ne $base
        if (-not $moved -or $try -ge 3) { Fail "git push exited $code$(if ($moved) { " ($Remote/$Branch moved on each of $try tries)" } else { ' (the pre-push gate output is above)' })" }
        Write-Output "land: $Remote/$Branch moved during the push, rebasing again (try $($try + 1) of 3)"
    }
    Write-Output "land: $Remote/$Branch is at $("$(& git -C $Root rev-parse --short HEAD)".Trim())"
} finally { if ($queue) { Exit-QGateLock $queue }; Exit-QGateLock $lock }
exit 0
