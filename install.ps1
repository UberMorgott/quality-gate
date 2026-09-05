# Wires the quality gate into a repository. Idempotent -- re-run after `qgate update`.
#
#   qgate wire                       # current repo
#   qgate wire -Target C:\path\repo  # -Root is accepted too: the gate's own flag
#                                    # for "which repository" is -Root everywhere
#                                    # else, and `wire -Root <path>` used to die
#                                    # with a raw PowerShell parameter error.
#
# Nothing is copied into the repo except configuration: the gate itself stays in
# one place per machine and is reached through `qgate` on PATH. What lands in the
# repo is a .golangci.yml per go.mod, lefthook.yml, the agent Stop hook in
# .claude/settings.json, an AGENTS.md section for agents that have no hooks, and
# optionally a CI workflow. Existing files are never overwritten silently.
[CmdletBinding()]
param(
    [Alias('Root')][string]$Target = (Get-Location).Path,
    [switch]$NoHook,
    [switch]$CI      # write .github/workflows/quality-gate.yml (opt-in)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate\detect.ps1')

$root = Get-RepoRoot (Resolve-Path $Target).Path
Write-Output "repo      $root"

# Everything wired below calls `qgate` by name. If it is not on PATH here it will
# not be on PATH for the hooks either -- say so now rather than at commit time.
if (-not (Get-Command qgate -ErrorAction SilentlyContinue)) {
    Write-Output "  warn:   'qgate' is not on PATH. Run bootstrap.ps1, then restart this terminal."
}

function Install-WebConfigs([string]$dir, [string]$where) {
    $need = @()
    if (Test-AnyFile $dir @('eslint.config.*', '.eslintrc*')) {
        Write-Output "web       $where -- kept existing eslint config"
    } else {
        Copy-Item (Join-Path $PSScriptRoot 'templates\eslint.config.js') $dir
        Write-Output "web       $where -- installed eslint.config.js"
        $need += 'eslint @eslint/js typescript-eslint eslint-plugin-vue'
    }
    if (Test-AnyFile $dir @('stylelint.config.*', '.stylelintrc*')) {
        Write-Output "web       $where -- kept existing stylelint config"
    } else {
        Copy-Item (Join-Path $PSScriptRoot 'templates\.stylelintrc.json') $dir
        Write-Output "web       $where -- installed .stylelintrc.json"
        $need += 'stylelint stylelint-config-standard-scss stylelint-config-recommended-vue'
    }
    # Config without packages fails the phase loudly, which is the point: before
    # this, a web repo with no linter config was waved through in silence.
    if ($need) { Write-Output "  next:   npm i -D $($need -join ' ')" }
}

$stacks = @(Get-Stacks $root)
foreach ($s in $stacks) {
    $where = if ($s.Rel) { $s.Rel + '/' } else { './' }
    if (-not $s.Implemented) {
        Write-Output "skipped   $($s.Stack) at $where -- not implemented, nothing will be checked there"
        continue
    }
    if ($s.Stack -eq 'go') {
        $cfg = Join-Path $s.Dir '.golangci.yml'
        if (Test-Path $cfg) {
            Write-Output "go        $where -- kept existing .golangci.yml"
        } else {
            Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $cfg
            Write-Output "go        $where -- installed .golangci.yml"
            $s.Warn = '' # the warning was about the file we just created
        }
    } elseif ($s.Stack -eq 'web') {
        Write-Output "web       $where -- enabled"
        Install-WebConfigs $s.Dir $where
    } else {
        Write-Output "$($s.Stack.PadRight(9)) $where -- enabled"
    }
    if ($s.Warn) { Write-Output "  warn:   $($s.Warn)" }
}

# --- gofmt's prerequisite: LF in the working tree ----------------------------
# gofmt reports a CRLF checkout as unformatted, so the whole tree fails on a Windows
# clone. This is not advice, it is a prerequisite -- write it. Once, at the repo
# root: it is a repo-wide rule, and a monorepo has one .gitattributes however many
# modules it holds.
if ($stacks | Where-Object { $_.Stack -eq 'go' -and $_.Implemented }) {
    $ga = Join-Path $root '.gitattributes'
    $gaBody = if (Test-Path $ga) { Get-Content $ga -Raw } else { '' }
    if ($gaBody -notmatch '\*\.go') {
        $line = '*.go text eol=lf'
        Set-Content -Path $ga -Value (($gaBody.TrimEnd() + "`n" + $line).TrimStart() + "`n") -Encoding utf8 -NoNewline
        Write-Output "  fixed:  added `"$line`" to .gitattributes"
    }
    # The rule only governs what git writes NEXT. Files already on disk stay CRLF, so
    # the first `qgate` after wire fails gofmt on every one of them -- 57 files in one
    # report -- with nothing on screen tying that to the line just written. The rule
    # was added, the problem was not, and only one of those was ever said out loud.
    #
    # The command named here is gofmt, not git, because the obvious git answer does
    # nothing. `git add --renormalize .` leaves the index stat cache matching the CRLF
    # file on disk, so the `git checkout -- .` after it decides the file is up to date
    # and skips it. Measured on git 2.53 with core.autocrlf both true and false, and
    # the same no-op holds for `checkout -f`, `restore --worktree --source=:0`,
    # `checkout-index -f -a` and a stash round-trip: only deleting the files first
    # makes checkout rewrite them. gofmt -w needs no git surgery at all -- it is the
    # tool doing the complaining, it always writes LF, and the next `git add`
    # normalises the index through the rule written above.
    $crlf = @(& git -C $root ls-files --eol -- '*.go' 2>$null | Where-Object { $_ -match '\sw/crlf\s' })
    if ($crlf) {
        Write-Output "  next:   $($crlf.Count) tracked .go file(s) are CRLF on disk -- gofmt fails on every one until you run, in each go module:"
        Write-Output "            gofmt -w ."
    }
}

# --- agent Stop hook ---------------------------------------------------------
# Exit 2 from the hook is what blocks an agent from ending its turn, and only a
# real command can produce it -- hence `qgate stop-hook` rather than lefthook,
# whose `lefthook run` exits 1.
function Set-StopHook {
    $file = Join-Path $root '.claude\settings.json'
    $cmd = 'qgate stop-hook'
    $settings = if (Test-Path $file) {
        Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
    } else {
        New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
        @{}
    }
    if (-not $settings.ContainsKey('hooks')) { $settings.hooks = @{} }
    $stop = @($settings.hooks.Stop)
    if (($stop | ConvertTo-Json -Depth 10) -match [regex]::Escape($cmd)) {
        Write-Output 'stop-hook -- already wired'
        return
    }
    $existing = @($stop | Where-Object { $_ })
    $settings.hooks.Stop = $existing + @{
        hooks = @(@{ type = 'command'; command = $cmd })
    }
    Set-Content -Path $file -Value ($settings | ConvertTo-Json -Depth 10) -Encoding utf8
    Write-Output "stop-hook -> $file"
    # Appending next to someone else's hook is the right call, but saying nothing
    # about it leaves two hooks running overlapping checks on every turn and the
    # user discovering that on their own.
    if ($existing) {
        Write-Output "  note:   this repo already had $($existing.Count) other Stop hook(s) -- if they check the same stack, both now run on every turn"
    }
}

# --- instructions for agents without a hook mechanism ------------------------
$agentDoc = @'
<!-- quality-gate -->
## Completion gate (mandatory)

After changing files, run `qgate` from the repository root. Use `qgate -All` when
dependencies, build configuration, generated files or several stacks changed.

Exit code 0 means done. Anything else means NOT done: the output names the exact
failures -- fix them and run it again. Do not report completion while the gate is
failing, and never edit or disable the gate to make it pass. Include the command
you ran and its pass/fail result in your final response.

If `qgate` is unavailable, report that as a blocker, do not skip it. It installs with
`irm https://raw.githubusercontent.com/UberMorgott/quality-gate/main/bootstrap.ps1 | iex`

If the gate itself is wrong -- it crashes, blames code that is provably correct,
misses a whole stack, or cannot be satisfied at all -- do not work around it and do
not disable it. Open an issue against the gate and say so in your final response:

```powershell
qgate where   # install path + commit, paste this into the issue
gh issue create --repo UberMorgott/quality-gate --title "<what broke>" --body "<qgate output, the command you ran, the file it blamed, `qgate where` output>"
```
<!-- /quality-gate -->
'@ -replace "`r`n", "`n"

# The block goes at the TOP of the file: agents weigh early instructions more, and
# long project guidance below must not bury it.
function Set-AgentDoc([string]$name) {
    $file = Join-Path $root $name
    $body = if (Test-Path $file) { Get-Content $file -Raw } else { '' }
    $new = if ($body -match '(?s)<!-- quality-gate -->.*?<!-- /quality-gate -->') {
        $body -replace '(?s)<!-- quality-gate -->.*?<!-- /quality-gate -->', $agentDoc.Trim()
    } else {
        ($agentDoc + "`n" + $body.TrimStart()).TrimEnd() + "`n"
    }
    if ($new -eq $body) { Write-Output "$($name.PadRight(9)) -- unchanged"; return }
    Set-Content -Path $file -Value $new -Encoding utf8
    Write-Output "$($name.PadRight(9)) -> $file"
}

# One source of truth per generated artifact: the templates. Anything the
# installer prints as advice is quoted from the file it would have written.
$script:LefthookTemplate = Join-Path $PSScriptRoot 'templates\lefthook.yml'
$script:LefthookRun = (Select-String -Path $script:LefthookTemplate -Pattern '^\s*run:' |
    Select-Object -First 1).Line.Trim()

function Install-Lefthook {
    $cfg = Join-Path $root 'lefthook.yml'
    if (Test-Path $cfg) {
        Write-Output 'lefthook  -- kept existing lefthook.yml'
        # Keeping a foreign config is right, but "kept" must not read as "wired":
        # `lefthook install` would then succeed with no gate job in it at all.
        if ((Get-Content $cfg -Raw) -notmatch 'qgate') {
            # Both hook names: a job under pre-commit alone leaves `git merge --no-ff`
            # unguarded, which is the whole point of the pre-merge-commit block in the
            # template we are quoting from.
            Write-Output '  warn:   it has no quality-gate job -- add this under BOTH pre-commit.jobs and pre-merge-commit.jobs yourself:'
            Write-Output '            - name: quality-gate'
            # Quoted from the template, never retyped: the advice and the generated
            # file drifted apart once already, and the pasted copy was the broken
            # one -- it said bare `qgate`, which exits 127 under a Git shell.
            Write-Output "            $($script:LefthookRun)"
        }
    } else {
        Copy-Item (Join-Path $PSScriptRoot 'templates\lefthook.yml') $cfg
        Write-Output "lefthook  -> $cfg"
    }
    Push-Location $root
    try { $out = (& lefthook install 2>&1 | Out-String).Trim() } finally { Pop-Location }
    Write-Output "lefthook  -- $($out -replace "`r?`n", '; ')"
}

# The hook body lives in templates/pre-commit rather than in a here-string, so the
# self-test can execute the real thing through sh. It was a string in this file for
# as long as it was wrong, and a string in this file is exactly what no test runs.
$hookBody = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\pre-commit'))) -replace "`r`n", "`n"

# Ask git where the hooks live: in a worktree or a submodule `.git` is a FILE and
# `<root>\.git\hooks` does not exist at all.
$hooksDir = (& git -C $root rev-parse --path-format=absolute --git-path hooks 2>$null)
$isRepo = $LASTEXITCODE -eq 0 -and $hooksDir
# Both, and the same body in each. A merge that commits on its own runs
# pre-merge-commit, never pre-commit, so wiring one name left `git merge --no-ff`
# completely unguarded: measured on git 2.53, the merge commit lands and no hook
# runs. See templates/lefthook.yml for which other commit paths are covered and
# which git gives nothing to cover them with.
$hookNames = @('pre-commit', 'pre-merge-commit')
if ($NoHook) {
    Write-Output 'hooks     -- skipped (-NoHook)'
} elseif (-not $isRepo) {
    Write-Output 'hooks     -- skipped: not a git repository'
} elseif (Get-Command lefthook -ErrorAction SilentlyContinue) {
    # Lefthook owns the hook wiring where it is available; the fallback below is
    # for machines without it.
    Install-Lefthook
} else {
    foreach ($name in $hookNames) {
        $hook = Join-Path ($hooksDir -replace '/', '\') $name
        if ((Test-Path $hook) -and -not ((Get-Content $hook -Raw) -match 'quality-gate')) {
            # Never clobber someone else's hook; core.hooksPath is deliberately not
            # touched either -- redirecting it would disable other hooks in .git/hooks.
            Write-Output "$($name.PadRight(10))-- EXISTS and is not ours, left alone. Add this to it yourself:"
            # Quoted from templates/pre-commit for the same reason as the lefthook advice.
            ($hookBody -split "`n" | Where-Object { $_ -and $_ -notmatch '^\s*#' }) |
                ForEach-Object { Write-Output "  $_" }
        } else {
            New-Item -ItemType Directory -Path (Split-Path $hook) -Force | Out-Null
            Set-Content -Path $hook -Value $hookBody -Encoding utf8 -NoNewline
            Write-Output "$($name.PadRight(10))-> $hook"
        }
    }
}

Set-StopHook
Set-AgentDoc 'AGENTS.md'
Set-AgentDoc 'CLAUDE.md'

# CI is opt-in. Writing it by default made deleting it impossible: a repo whose own
# workflow already covers this ground got the file back on the next `wire`, and
# `wire` is exactly what you re-run after `qgate update`.
$wf = Join-Path $root '.github\workflows\quality-gate.yml'
if (Test-Path $wf) {
    Write-Output 'ci        -- kept existing .github/workflows/quality-gate.yml'
} elseif ($CI) {
    New-Item -ItemType Directory -Path (Split-Path $wf) -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'templates\ci.yml') $wf
    Write-Output "ci        -> $wf"
} else {
    Write-Output 'ci        -- not installed; `qgate wire -CI` adds a GitHub Actions workflow'
}

Write-Output ''
Write-Output 'Now break something on purpose and confirm `qgate` complains.'
