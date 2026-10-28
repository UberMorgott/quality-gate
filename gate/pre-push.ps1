# `qgate pre-push`: the gate for the exact tree being pushed (quality-gate#180).
#
# Commits made by `git rebase`, `git cherry-pick` and `git revert` run neither pre-commit
# nor pre-merge-commit, so the usual landing flow -- rebase on the new main, push -- sent
# a tree to the remote that no gate had ever seen: other people's new main plus this
# change, never built together. pre-push is the last hook git runs before the remote.
#
# The gate checks the WORKING TREE, so a push is only judged when what is pushed is what
# is checked out: every pushed local sha must be HEAD, and nothing tracked may be modified
# or staged. Anything else is refused with what to do instead -- running the gate on the
# working tree and calling the result a verdict on another commit would be a guess.
#
# git hands the hook `<local ref> <local sha> <remote ref> <remote sha>` lines on stdin
# (githooks(5)); lefthook passes them on only with `use_stdin: true`. That parsing lives
# here, not in lefthook.yml, because lefthook strips quotes out of a `run:` string.
# A line whose local sha is all zeros deletes a remote ref: nothing to gate.
# No stdin lines at all is a push that sends nothing (everything up to date).
#
# No reuse of an earlier verdict by tree hash: the result also depends on the toolchain,
# the gate version, restored packages and advisory feeds. `git push --no-verify` still
# bypasses this, like every client-side hook.
[CmdletBinding(PositionalBinding = $false)]
param([string]$Root, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'detect.ps1')
# A push hook has no index of its own to protect; an inherited GIT_INDEX_FILE (a push run
# from inside some other hook) would make check.ps1 believe it is inside a commit.
$env:GIT_INDEX_FILE = $null

if (-not $Root) { $Root = Get-RepoRoot (Get-Location).Path }
$Root = (Resolve-Path $Root).Path

$stdin = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
$pushes = @($stdin -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object {
        $f = $_.Trim() -split '\s+'
        [pscustomobject]@{ LocalRef = $f[0]; LocalSha = $f[1]; RemoteRef = $f[2] }
    } | Where-Object { $_.LocalSha -notmatch '^0+$' })
if (-not $pushes) { exit 0 }

$head = "$(& git -C $Root rev-parse -q --verify HEAD 2>$null)".Trim()
$bad = @($pushes | Where-Object { $_.LocalSha -ne $head })
if ($bad) {
    foreach ($b in $bad) {
        Write-Output "[FAIL] pre-push -- $($b.LocalRef) ($($b.LocalSha.Substring(0, [Math]::Min(12, $b.LocalSha.Length)))) -> $($b.RemoteRef) is not the checked-out HEAD ($(if ($head) { $head.Substring(0, 12) } else { 'none' }))"
    }
    Write-Output '       The gate checks the working tree, so it can only vouch for the commit that is checked out.'
    Write-Output '       Check out the branch you push (or push HEAD: git push origin HEAD:<branch>), one ref per push.'
    exit 1
}

$dirty = @(& git -C $Root status --porcelain --untracked-files=no 2>$null)
if ($dirty) {
    Write-Output "[FAIL] pre-push -- $($dirty.Count) tracked file(s) modified or staged; the gate would judge them, not the pushed commit"
    $dirty | Select-Object -First 10 | ForEach-Object { Write-Output "       $_" }
    Write-Output '       Commit or stash first, then push again.'
    exit 1
}
# `git status` is blind to a file marked --assume-unchanged or --skip-worktree: its local
# edit is what the gate would build, while the remote gets the committed bytes. Measured
# (review of #180): a fixed-locally, assume-unchanged file let a broken commit through.
$hidden = @(& git -C $Root ls-files -v 2>$null | Where-Object { $_ -cmatch '^([a-z]|S) ' })
if ($hidden) {
    Write-Output "[FAIL] pre-push -- $($hidden.Count) tracked file(s) are marked assume-unchanged/skip-worktree, so the work tree may not be the pushed commit"
    $hidden | Select-Object -First 10 | ForEach-Object { Write-Output "       $_" }
    Write-Output '       Clear the flag (git update-index --no-assume-unchanged / --no-skip-worktree <file>), then push again.'
    exit 1
}
# Untracked files are said, not refused: a stray scratch file is common and harmless,
# but a build that globs sources (dotnet, Go) does read one, so the reader should know.
$untracked = @(& git -C $Root ls-files --others --exclude-standard 2>$null)
if ($untracked) {
    Write-Output "[WARN] pre-push -- $($untracked.Count) untracked file(s) in the work tree are part of what the gate builds: $(@($untracked | Select-Object -First 5) -join ', ')"
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check.ps1') -Root $Root -All -Full -Quiet -Hook @Extra
exit $LASTEXITCODE
