# Self-test: proves the gate FAILS on a real violation and PASSES once it is
# fixed. A gate nobody has seen fail is not known to work.
#
#   pwsh -NoProfile -File selftest.ps1
#
# Adding a check: assert the REASON, not only the outcome. Five defects in a row
# here were the gate doing something defensible and printing a reason that was not
# the reason -- right exit code, right stacks, wrong explanation -- and every one of
# them satisfied a suite that asserted only pass/fail. So a negative check states
# three things: the outcome, that the reason which applied was printed (-match), and
# that the reason which did NOT apply is absent (-notmatch). The third is the cheap
# one and the one that was missing. Assert absence too: "narrowed to the right
# stack" is proved by the other stacks NOT running. See PLAYBOOK.md 0.1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate\detect.ps1')

# Unique per run: a fixed directory made two concurrent self-tests delete each
# other's fixtures mid-check.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-selftest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:Fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Output "[ok]   $Name" }
    else { Write-Output "[FAIL] $Name $Detail"; $script:Fails++ }
}
function Set-GoFile([string]$Path, [string]$Text) {
    # LF only: gofmt reports a CRLF file as unformatted, which would fail the
    # wrong phase and hide the violation we are testing for.
    [IO.File]::WriteAllText($Path, (($Text -replace "`r`n", "`n").TrimEnd() + "`n"))
}
function Invoke-Gate([string]$Root) {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $Root -All 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# 1. Detection by file presence.
$stacks = @(Get-Stacks (Join-Path $PSScriptRoot 'testdata'))
Check 'detects go stack'   ([bool]($stacks | Where-Object { $_.Stack -eq 'go' -and $_.Implemented }))
Check 'detects web stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'web' -and $_.Implemented }))
Check 'detects rust stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'rust' -and $_.Implemented }))
Check 'detects proto stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'proto' -and $_.Implemented }))
Check 'detects godot stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'godot' -and $_.Implemented }))
Check 'no phantom python stack' (-not ($stacks | Where-Object { $_.Stack -eq 'python' }))

# 2. Clean Go fixture, no linter config -> passes, warns exactly once.
$go = Join-Path $tmp 'go'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $go -Recurse
$r = Invoke-Gate $go
Check 'clean go fixture passes without config' ($r.Code -eq 0) $r.Out
Check 'missing .golangci.yml warned once' (([regex]::Matches($r.Out, 'no \.golangci\.yml')).Count -eq 1) $r.Out

# 3. Same fixture with the template config -> still green, no warning.
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $go
$r = Invoke-Gate $go
Check 'template .golangci.yml passes' ($r.Code -eq 0) $r.Out
Check 'no warning once config present' ($r.Out -notmatch 'WARN') $r.Out

# 4. RED: a go vet violation. 5. GREEN: the same file restored.
$main = Join-Path $go 'main.go'
$clean = Get-Content $main -Raw
Set-GoFile $main @'
package main

import "fmt"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	fmt.Printf("%d", "not an int")
	_ = Add(1, 2)
}
'@
$r = Invoke-Gate $go
Check 'go vet violation fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] go vet')) $r.Out
Set-GoFile $main $clean
$r = Invoke-Gate $go
Check 'gate green again after the fix' ($r.Code -eq 0) $r.Out

# 6. RED: an unchecked error -- only golangci-lint catches this one, so it
#    proves the linter phase is live rather than merely present.
if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
    Set-GoFile $main @'
package main

import "os"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	os.WriteFile("x.txt", nil, 0o600)
	_ = Add(1, 2)
}
'@
    $r = Invoke-Gate $go
    Check 'unchecked error fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] golangci-lint')) $r.Out
    Set-GoFile $main $clean
} else {
    Write-Output '[skip] golangci-lint not on PATH'
}

# 7. Provenance: every phase names the marker that created it.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -All -Why 2>&1 | Out-String)
Check 'provenance names the found marker' ($out -match '\[WHY\] go .*found go\.mod') $out
Check 'provenance names an absent stack' ($out -match '\[WHY\] python -- absent') $out

# 8. Fail closed: an unusable root is a failure, never "nothing to check".
$r = Invoke-Gate (Join-Path $tmp 'does-not-exist')
Check 'unusable root fails closed' ($r.Code -ne 0) $r.Out

# 9. A present-but-unverifiable stack must FAIL, never pass silently.
$web = Join-Path $tmp 'web'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $web -Recurse
$r = Invoke-Gate $web
Check 'web without node_modules fails loudly' (($r.Code -ne 0) -and ($r.Out -match 'node_modules missing')) $r.Out

# 10. Wiring fills the frontend gap: a phase whose config is absent is skipped, so
# before this a web repo with no eslint/stylelint config passed in silence. A config
# the project already has must survive a re-run untouched.
$wire = Join-Path $tmp 'wire'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wire -Recurse
git -C $wire init -q 2>$null
$installer = Join-Path $PSScriptRoot 'install.ps1'
& pwsh -NoProfile -File $installer -Target $wire -NoHook *> $null
$eslintCfg = Join-Path $wire 'eslint.config.js'
Check 'wire installs the frontend linter configs' `
    ((Test-Path $eslintCfg) -and (Test-Path (Join-Path $wire '.stylelintrc.json')))
Set-Content $eslintCfg 'mine' -NoNewline
& pwsh -NoProfile -File $installer -Target $wire -NoHook *> $null
Check 'wire keeps a config the project already had' ((Get-Content $eslintCfg -Raw) -eq 'mine')

# 11. Rust is checked for real now, red then green like Go.
$rust = Join-Path $tmp 'rust'
Copy-Item (Join-Path $PSScriptRoot 'testdata\rust-fixture') $rust -Recurse
$r = Invoke-Gate $rust
Check 'clean rust fixture passes' ($r.Code -eq 0) $r.Out
$rsMain = Join-Path $rust 'src\main.rs'
$rsClean = Get-Content $rsMain -Raw
# Badly formatted AND clippy-hostile: `== true` is a clippy error, the spacing is
# a rustfmt error. Either one alone would prove only half the pipeline.
[IO.File]::WriteAllText($rsMain, 'fn main() {  let x = true; if x == true { println!("y"); } }' + "`n")
$r = Invoke-Gate $rust
Check 'rust violation fails the gate' ($r.Code -ne 0) $r.Out
[IO.File]::WriteAllText($rsMain, $rsClean)
$r = Invoke-Gate $rust
Check 'rust green again after the fix' ($r.Code -eq 0) $r.Out

# 16. Proto, red then green. buf ships with nothing else, so its absence is a
# skip -- same rule as golangci-lint above.
if (Get-Command buf -ErrorAction SilentlyContinue) {
    $proto = Join-Path $tmp 'proto'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') $proto -Recurse
    $r = Invoke-Gate $proto
    Check 'clean proto fixture passes' ($r.Code -eq 0) $r.Out
    $pf = Join-Path $proto 'example\v1\greeting.proto'
    $pClean = [IO.File]::ReadAllText($pf)
    [IO.File]::WriteAllText($pf, $pClean.Replace('string text = 1;', 'string Text = 1;'))
    $r = Invoke-Gate $proto
    Check 'proto lint violation fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] buf lint')) $r.Out
    [IO.File]::WriteAllText($pf, $pClean)
    $r = Invoke-Gate $proto
    Check 'proto green again after the fix' ($r.Code -eq 0) $r.Out
} else {
    Write-Output '[skip] buf not on PATH'
}

# 17. Godot. The binary is usually absent on Windows, which is exactly when a
# naive gate goes quiet -- so the phases that need no binary are checked for real
# here, and the missing binary itself has to be a loud failure.
$gdt = Join-Path $tmp 'godot'
Copy-Item (Join-Path $PSScriptRoot 'testdata\godot-fixture') $gdt -Recurse
$gdMain = Join-Path $gdt 'main.gd'
$gdClean = [IO.File]::ReadAllText($gdMain)
[IO.File]::WriteAllText($gdMain, "extends Node`n`nconst MISSING := preload(`"res://does_not_exist.gd`")`n")
$r = Invoke-Gate $gdt
Check 'dangling res:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'res://does_not_exist\.gd does not resolve')) $r.Out
# The one Windows cannot catch by asking the filesystem: right file, wrong case.
# It loads here and breaks in a Linux CI run or export.
[IO.File]::WriteAllText($gdMain, "extends Node`n`nconst S := preload(`"res://Main.gd`")`n")
$r = Invoke-Gate $gdt
Check 'wrong-case res:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'res://Main\.gd does not resolve')) $r.Out
[IO.File]::WriteAllText($gdMain, $gdClean)
# A uid:// cannot be checked against a path -- only against the file that declares
# it -- and Godot rewrites paths by uid, so a stale one silently loads nothing.
$gdScene = Join-Path $gdt 'main.tscn'
$scClean = [IO.File]::ReadAllText($gdScene)
[IO.File]::WriteAllText($gdScene, $scClean.Replace('[ext_resource type="Script"', '[ext_resource type="Script" uid="uid://cnotdeclared"'))
$r = Invoke-Gate $gdt
Check 'dangling uid:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'main\.tscn:\d+: uid://cnotdeclared matches nothing')) $r.Out
[IO.File]::WriteAllText($gdScene, $scClean)
$r = Invoke-Gate $gdt
Check 'res:// scan clean once the reference is fixed' (($r.Out -notmatch 'does not resolve') -and ($r.Out -notmatch 'matches nothing')) $r.Out
if (Get-GodotBin) {
    Check 'godot fixture passes with a real binary' ($r.Code -eq 0) $r.Out
} else {
    Write-Output '[skip] GODOT_BIN unset -- import/test/smoke phases not exercised'
}
# The missing binary is fatal at the full level and a warning in the fast lane:
# every phase that needs it is full-level only, so failing the fast lane over it
# blocked every agent turn on a binary the turn was never going to invoke. Run
# both levels with GODOT_BIN cleared, whether or not this machine has one.
if (-not (Get-Command godot -ErrorAction SilentlyContinue)) {
    $priorGodot = $env:GODOT_BIN
    $env:GODOT_BIN = $null
    try {
        $fastOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt -All 2>&1 | Out-String)
        $fastCode = $LASTEXITCODE
        $fullOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt -All -Full 2>&1 | Out-String)
        $fullCode = $LASTEXITCODE
    } finally { $env:GODOT_BIN = $priorGodot }
    Check 'no GODOT_BIN does not fail the fast lane' ($fastCode -eq 0) $fastOut
    Check 'no GODOT_BIN is still said out loud in the fast lane' ($fastOut -match 'GODOT_BIN') $fastOut
    Check 'no GODOT_BIN fails the full level' (($fullCode -ne 0) -and ($fullOut -match 'set GODOT_BIN')) $fullOut
} else {
    Write-Output '[skip] godot is on PATH -- the missing-binary levels cannot be exercised'
}

# 12. A directory that is not a git repository must not pass by way of "no
# changes": the default run has nothing to narrow by and has to check everything.
$nogit = Join-Path $tmp 'nogit'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $nogit -Recurse
Set-GoFile (Join-Path $nogit 'broken.go') "package main`nfunc  Broken() {}"
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $nogit 2>&1 | Out-String)
Check 'non-git directory is checked, not skipped' (($LASTEXITCODE -ne 0) -and ($out -notmatch 'no changes')) $out

# 13. The wiring templates must call the entry point that actually exists. The
# lefthook job pointed at a path `wire` no longer creates, which broke every
# commit in a repo that had lefthook.
# It must also call qgate.cmd, not bare qgate: lefthook runs jobs through Git Bash,
# where PATHEXT does not apply and a bare `qgate` exits 127, command not found.
$lh = Get-Content (Join-Path $PSScriptRoot 'templates\lefthook.yml') -Raw
Check 'lefthook template calls qgate.cmd' (($lh -match 'run:.*qgate\.cmd ') -and ($lh -notmatch 'tools/quality-gate')) $lh
# A commit in an agent workflow is a tool call, so the hook's stdout is context the
# model pays for -- measured at 342 chars of [PASS] lines per commit on a
# three-stack monorepo. Silent on green, loud on red. CI keeps its output, which is
# why this is a property of the generated hooks and not a global default.
$inst = Get-Content $installer -Raw
$gen = @([regex]::Matches($inst, '(?m)^.*qgate(\.cmd)? -All -Full.*$') | ForEach-Object { $_.Value })
$noisy = @($gen | Where-Object { $_ -notmatch '-Quiet' })
Check 'every generated pre-commit invocation is quiet on green' `
    (($gen.Count -ge 3) -and ($noisy.Count -eq 0) -and ($lh -match '-All -Full -Quiet')) `
    "found $($gen.Count), noisy: $($noisy -join ' | ')"

# 14. gofmt reads a CRLF checkout as unformatted, so the .gitattributes line is a
# prerequisite, not advice -- wire has to write it. Go repo: it is a Go rule.
$goWire = Join-Path $tmp 'gowire'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $goWire -Recurse
git -C $goWire init -q 2>$null
& pwsh -NoProfile -File $installer -Target $goWire -NoHook *> $null
$ga = Join-Path $goWire '.gitattributes'
Check 'wire writes the gofmt eol rule' ((Test-Path $ga) -and ((Get-Content $ga -Raw) -match '\*\.go text eol=lf')) `
    "$(if (Test-Path $ga) { Get-Content $ga -Raw })"

# 15. The version report is advisory. It must never fail a run -- offline, rate
# limited or with a registry that answers garbage, the exit code stays 0.
$outdated = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $go 2>&1 | Out-String)
Check 'outdated never fails the run' ($LASTEXITCODE -eq 0) $outdated

# 12. The agent contract: `qgate stop-hook` must reach Claude Code as exit code 2
# with the reason on stderr, through the .cmd shim it is actually invoked by.
# Anything less and a failing gate silently lets the agent declare victory.
$hookRepo = Join-Path $tmp 'hook'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $hookRepo -Recurse
git -C $hookRepo init -q 2>$null
git -C $hookRepo add -A 2>$null   # silences the CRLF-conversion warnings
git -C $hookRepo -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
# -Fast only looks at changed files, so the violation has to be uncommitted.
Set-GoFile (Join-Path $hookRepo 'bad.go') "package main`nfunc  Bad() {}"
Push-Location $hookRepo
try {
    $stderrFile = Join-Path $tmp 'hook.err'
    $env:CLAUDE_PROJECT_DIR = $hookRepo
    # A fresh session id every run: the block counter lives in TEMP keyed by
    # (repo, session) and a leftover from an earlier run would make the gate give
    # up on the first block instead of blocking.
    $hookOut = "{`"session_id`":`"$([guid]::NewGuid())`"}" |
        & cmd /c "`"$(Join-Path $PSScriptRoot 'bin\qgate.cmd')`" stop-hook" 2>$stderrFile
    $hookCode = $LASTEXITCODE
    $env:CLAUDE_PROJECT_DIR = $null
} finally { Pop-Location }
$hookErr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
Check 'stop-hook blocks the turn with exit 2' ($hookCode -eq 2) "code=$hookCode"
Check 'stop-hook puts the reason on stderr' ($hookErr -match 'Quality gate failed') $hookErr
Check 'stop-hook keeps stdout clean' ([string]::IsNullOrWhiteSpace(($hookOut | Out-String))) ($hookOut | Out-String)

# 22. The hook's blind spot: the fast level only ever looks at UNCOMMITTED work, so
# a turn that edits and commits leaves a clean tree and the hook waved it through --
# and every later turn too, because the commit never becomes uncommitted again. The
# hook now remembers the commit it was last green on. Two runs, because the first
# one is what records the mark; a single run would pass on the first-run rule and
# prove nothing about the case that matters.
$hook2 = Join-Path $tmp 'hook2'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $hook2 -Recurse
git -C $hook2 init -q 2>$null
git -C $hook2 add -A 2>$null
git -C $hook2 -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
function Invoke-StopHook([string]$Repo, [string]$Session) {
    $err = Join-Path $tmp "hook-$([guid]::NewGuid()).err"
    Push-Location $Repo
    try {
        $env:CLAUDE_PROJECT_DIR = $Repo
        "{`"session_id`":`"$Session`"}" | & cmd /c "`"$(Join-Path $PSScriptRoot 'bin\qgate.cmd')`" stop-hook" 2>$err | Out-Null
        $code = $LASTEXITCODE
        $env:CLAUDE_PROJECT_DIR = $null
    } finally { Pop-Location }
    $text = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
    [pscustomobject]@{ Code = $code; Err = $text }
}
$sid = [guid]::NewGuid()
$h = Invoke-StopHook $hook2 $sid
Check 'stop-hook passes a clean repo and records it' ($h.Code -eq 0) "code=$($h.Code) $($h.Err)"
# Commit the violation, leave the tree clean: the state the old hook could not see.
Set-GoFile (Join-Path $hook2 'bad.go') "package main`nfunc  Bad() {}"
git -C $hook2 add -A 2>$null
git -C $hook2 -c user.email=selftest@local -c user.name=selftest commit -qm violation 2>$null
$h = Invoke-StopHook $hook2 $sid
Check 'stop-hook blocks a violation that was committed on a clean tree' ($h.Code -eq 2) "code=$($h.Code) $($h.Err)"

# 18. `-All` is documented as "every detected stack, ignore git status", but the
# .gd list was still narrowed by git status under it: a tree whose dirty files are
# not .gd dropped gdformat and gdlint from the run and still printed [PASS] godot,
# with no SKIP and no WARN to say so. A phase that did not run must never be
# indistinguishable from a phase that passed.
if ((Get-Command gdformat -ErrorAction SilentlyContinue) -and (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    git -C $gdt init -q 2>$null
    git -C $gdt add -A 2>$null
    git -C $gdt -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $gdt 'notes.txt'), "dirty, and not a .gd file`n")
    $r = Invoke-Gate $gdt
    Check '-All lints .gd even when git reports no .gd change' ($r.Out -match 'gdformat') $r.Out
    # The fast lane still narrows -- but says so out loud.
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt 2>&1 | Out-String)
    Check 'a skipped gd lint phase is visible, not silent' ($out -match '\[SKIP\] gdformat/gdlint') $out
} else {
    Write-Output '[skip] gdtoolkit not on PATH'
}

# 19. Discoverability: a flag value nobody validates and a config key nobody reads
# are both silent no-ops that look exactly like enforcement.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -Only 'nonsense' 2>&1 | Out-String)
$onlyCode = $LASTEXITCODE
Check '-Only naming an undetected stack is reported' ($out -match '\[FAIL\] -Only nonsense') $out
# The half that was missing: a warning in a run that exits 0 is a green pipeline.
Check '-Only naming an undetected stack fails the run' ($onlyCode -ne 0) "code=$onlyCode $out"
# A real stack name must still work, or the validation would be worse than the bug.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -Only 'go' 2>&1 | Out-String)
Check '-Only naming a detected stack still runs it' (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] go')) $out
[IO.File]::WriteAllText((Join-Path $go 'qgate.json'), '{"tools": {"nosuchtool": "1.0.0"}}')
$r = Invoke-Gate $go
Check 'qgate.json pinning an unknown tool warns' ($r.Out -match "pins unknown tool 'nosuchtool'") $r.Out
if (Get-Command gdformat -ErrorAction SilentlyContinue) {
    [IO.File]::WriteAllText((Join-Path $go 'qgate.json'), '{"tools": {"gdtoolkit": "0.0.1"}}')
    $r = Invoke-Gate $go
    Check 'qgate.json can pin gdtoolkit' ($r.Out -match 'gdtoolkit .* qgate\.json pins 0\.0\.1') $r.Out
}
Remove-Item (Join-Path $go 'qgate.json')

# 20. Which stacks were selected, and the reason the gate gives for it. Both bugs
# here were invisible to a suite that asserts on stacks and phases: the run still
# checked something and still exited 0, it just said something untrue about why.
$sel = Join-Path $tmp 'select'
New-Item -ItemType Directory -Path $sel | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $sel 'schema') -Recurse
git -C $sel init -q 2>$null
git -C $sel add -A 2>$null
git -C $sel -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
# Get-ChangedPaths documents $null as "not a git repository" and an empty list as
# "no changes". PowerShell enumerates a collection on return, so the empty list came
# back as $null: the [SKIP] no changes branch was unreachable, every clean-tree fast
# lane checked every stack, and it blamed git for it.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
$selCode = $LASTEXITCODE
Check 'a clean tree reports no changes' (($selCode -eq 0) -and ($out -match 'no changes')) "code=$selCode $out"
Check 'a clean git tree is not called a non-git directory' ($out -notmatch 'not a git repository') $out
# A root-level file belongs to no stack, so everything runs -- but the reason the
# gate printed was 'proto changed', with no .proto in the change set.
[IO.File]::WriteAllText((Join-Path $sel 'README.md'), "a root file, owned by no stack`n")
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
Check 'a path outside every stack gives the reason that applied' ($out -match 'README\.md belongs to no stack') $out
Check 'a path outside every stack is not blamed on proto' ($out -notmatch 'proto changed') $out
# ...and the proto rule itself must still fire when a .proto really did change.
Remove-Item (Join-Path $sel 'README.md')
$pf = Join-Path $sel 'schema\example\v1\greeting.proto'
[IO.File]::WriteAllText($pf, ([IO.File]::ReadAllText($pf) -replace '(?m)^(syntax)', "// touched by the self-test`n`$1"))
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
Check 'a real .proto change still widens with the proto reason' ($out -match 'proto changed') $out

# 21. Narrowing for a TRACKED edit. `git diff --name-only -z HEAD` goes through
# Out-String, which appends a trailing newline, so the split produced one "`r`n"
# element; it is non-empty and survived a filter placed before the trim, then the
# trim made it ''. That empty path sorted first, matched no stack, and widened the
# run on the first iteration -- so the fast lane had never narrowed for a tracked
# edit, and blamed proto for it. Every earlier check here used untracked fixtures,
# which is exactly why none of them saw it.
git -C $sel checkout -- . 2>$null
$track = Join-Path $tmp 'tracked'
New-Item -ItemType Directory -Path $track | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') (Join-Path $track 'server') -Recurse
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $track 'schema') -Recurse
git -C $track init -q 2>$null
git -C $track add -A 2>$null
git -C $track -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
Set-GoFile (Join-Path $track 'server\main.go') ((Get-Content (Join-Path $track 'server\main.go') -Raw) + "`n// a tracked edit`n")
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $track 2>&1 | Out-String)
Check 'a tracked edit narrows to its own stack' (($out -match '\[PASS\] go server/') -and ($out -notmatch 'proto')) $out

Remove-Item $tmp -Recurse -Force
if ($script:Fails) { Write-Output "`n$($script:Fails) check(s) failed"; exit 1 }
Write-Output "`nall checks passed"
