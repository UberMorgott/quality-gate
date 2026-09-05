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
# Counted, because the last line claiming "all checks passed" is the only thing
# anybody reads, and a suite that silently stopped running half of them would say
# exactly the same words. The number also makes the one quoted in README verifiable
# output rather than prose. It moves with the machine: checks whose tool is absent
# report [skip] and are never counted.
$script:Total = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Total++
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
Check 'detects python stack as not implemented' ([bool]($stacks | Where-Object { $_.Stack -eq 'python' -and -not $_.Implemented }))
# A stack with no marker file does not exist at all. testdata/ now holds a python
# fixture (check 28 needs one), so this has to be asked of a tree that has no python
# marker, or it would only be proving that Copy-Item works.
Check 'no phantom python stack where there is no marker' `
    (-not (@(Get-Stacks (Join-Path $PSScriptRoot 'testdata\go-fixture')) | Where-Object { $_.Stack -eq 'python' }))
# What the repo ignores is not part of the repo. Claude Code checks agent worktrees
# out under .claude/worktrees/<agent>/, and that nested go.mod -- an older commit of
# the same repo -- was detected as a second Go stack, so `qgate outdated` reported
# dependencies as behind that were only stale inside the worktree. Both halves are
# asserted: the ignored module is gone AND the root one is still found, because
# "detects nothing at all" would satisfy the first half on its own.
$ign = Join-Path $tmp 'ignored'
New-Item -ItemType Directory -Path (Join-Path $ign '.claude\worktrees\agent-x') -Force | Out-Null
git -C $ign init -q 2>$null
Set-Content (Join-Path $ign '.gitignore') '.claude/'
Set-Content (Join-Path $ign 'go.mod') 'module example.com/root'
Set-Content (Join-Path $ign '.claude\worktrees\agent-x\go.mod') 'module example.com/nested'
$ignStacks = @(Get-Stacks $ign | Where-Object { $_.Stack -eq 'go' })
Check 'a gitignored nested module is not a stack' `
    (($ignStacks.Count -eq 1) -and ($ignStacks[0].Rel -eq '')) `
    (($ignStacks | ForEach-Object { "go '$($_.Rel)'" }) -join ' | ')

# Not walking in is only half of it: the PHASES must not walk in either. gofmt is the
# one Go tool with no notion of modules or ignore rules -- `.` is the whole subtree --
# so a CRLF checkout under .claude/worktrees/<agent>/ failed the ROOT repo's gate, and
# its pre-commit hook, over files that are not in its index. Both directions are
# asserted, because "ignore the ignored file" is also what gofmt switched off would do.
$gign = Join-Path $tmp 'gofmt-ignored'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $gign -Recurse
Set-Content (Join-Path $gign '.gitignore') '.claude/'
git -C $gign init -q 2>$null
git -C $gign add -A 2>$null
git -C $gign -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
New-Item -ItemType Directory -Path (Join-Path $gign '.claude\worktrees\agent-x') -Force | Out-Null
Set-Content (Join-Path $gign '.claude\worktrees\agent-x\go.mod') 'module example.com/nested'
[IO.File]::WriteAllText((Join-Path $gign '.claude\worktrees\agent-x\bad.go'), "package nested`r`n`r`nfunc  Bad()  {}`r`n")
$r = Invoke-Gate $gign
Check 'an unformatted file in a gitignored worktree does not fail the gate' `
    (($r.Code -eq 0) -and ($r.Out -notmatch 'bad\.go')) $r.Out
[IO.File]::WriteAllText((Join-Path $gign 'ugly.go'), "package main`n`nfunc  Ugly()  {}`n")
$r = Invoke-Gate $gign
Check 'gofmt still fails on a real unformatted file' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gofmt') -and ($r.Out -match 'ugly\.go') -and ($r.Out -notmatch 'bad\.go')) $r.Out

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

# A phase killed because the HOST ran out of memory is not a finding about the code,
# but the raw runtime dump reads exactly like one. Reported from the field: a
# `go test -race` failed the same commit twice under parallel load with
# `VirtualAlloc ... errno=1455`, then passed on the third run with nothing changed,
# and all the developer had on screen was a stack blaming a package. Both halves, per
# PLAYBOOK 0.1: the note appears when the output really is an allocation failure, and
# is absent on an ordinary one -- a note printed on every red run is noise, and noise
# is what teaches people to skip the line that mattered.
$oom = Join-Path $tmp 'oom'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $oom -Recurse
$oomTest = Join-Path $oom 'oom_test.go'
# Tab-indented, body on its own line: gofmt expands a one-line func whose body is
# this long, and a fixture that fails gofmt never reaches `go test` at all -- which is
# how the absence half below passed for entirely the wrong reason the first time.
Set-GoFile $oomTest @'
package main

import "testing"

func TestAllocationFailure(t *testing.T) {
	t.Fatal("runtime: VirtualAlloc of 1048576 bytes failed with errno=1455\nfatal error: out of memory")
}
'@
$r = Invoke-Gate $oom
Check 'an out-of-memory failure is named as the host, not the code' `
    (($r.Code -ne 0) -and ($r.Out -match '\[NOTE\].*allocation failure on this machine')) $r.Out
Set-GoFile $oomTest @'
package main

import "testing"

func TestOrdinaryFailure(t *testing.T) {
	t.Fatal("values differ")
}
'@
$r = Invoke-Gate $oom
# The reason has to be the right one: assert the phase that failed is `go test`, or
# this passes on any red run that never got that far.
Check 'an ordinary failure carries no memory note' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] go test') -and ($r.Out -notmatch '\[NOTE\]')) $r.Out

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
$hookTpl = Get-Content (Join-Path $PSScriptRoot 'templates\pre-commit') -Raw
$invocations = @([regex]::Matches("$lh`n$hookTpl", '(?m)^(?!\s*#).*qgate(\.cmd)? -All -Full.*$') |
    ForEach-Object { $_.Value })
$noisy = @($invocations | Where-Object { $_ -notmatch '-Quiet' })
Check 'every generated pre-commit invocation is quiet on green' `
    (($invocations.Count -ge 3) -and ($noisy.Count -eq 0)) `
    "found $($invocations.Count), noisy: $($noisy -join ' | ')"

# 14. gofmt reads a CRLF checkout as unformatted, so the .gitattributes line is a
# prerequisite, not advice -- wire has to write it. Go repo: it is a Go rule.
$goWire = Join-Path $tmp 'gowire'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $goWire -Recurse
git -C $goWire init -q 2>$null
& pwsh -NoProfile -File $installer -Target $goWire -NoHook *> $null
$ga = Join-Path $goWire '.gitattributes'
Check 'wire writes the gofmt eol rule' ((Test-Path $ga) -and ((Get-Content $ga -Raw) -match '\*\.go text eol=lf')) `
    "$(if (Test-Path $ga) { Get-Content $ga -Raw })"
# The rule governs only what git writes NEXT: files already on disk stay CRLF and
# gofmt fails on every one of them. Wire printed "fixed" and said nothing about that,
# so the first run after wire failed 57 files with no hint. Assert the count and the
# command -- "printed something" is what let the silence through in the first place.
# The command must be gofmt -w: `git add --renormalize . && git checkout -- .` is the
# answer everyone reaches for and it is a no-op, because --renormalize leaves the
# index stat cache matching the CRLF file and checkout then skips it. Asserting its
# absence is what stops that from being "helpfully" restored later.
[IO.File]::WriteAllText((Join-Path $goWire 'crlf.go'), "package main`r`n")
git -C $goWire add -A 2>$null
$wireOut = (& pwsh -NoProfile -File $installer -Target $goWire -NoHook 2>&1 | Out-String)
Check 'wire names a command that really rewrites a CRLF working tree' `
    (($wireOut -match '1 tracked \.go file\(s\) are CRLF') -and ($wireOut -match '(?m)^\s+gofmt -w \.\s*$')) $wireOut
Check 'wire does not name the renormalise no-op' ($wireOut -notmatch 'renormalize') $wireOut

# `qgate wire` is run again every time the gate is upgraded, so a second run with
# nothing to change must be a no-op. Set-Content appends its own newline on top of the
# one the body already ends with, so every rewrite left one more blank line at the end
# of the file than it found; and the comparison was made against raw bytes, so a file
# git had checked out as CRLF -- which `* text=auto` does to every doc in a repo with
# core.autocrlf=true -- never equalled the LF block and was rewritten every run.
$agentsFile = Join-Path $goWire 'AGENTS.md'
$agentsBefore = [IO.File]::ReadAllBytes($agentsFile)
$wireAgain = (& pwsh -NoProfile -File $installer -Target $goWire -NoHook 2>&1 | Out-String)
$agentsAfter = [IO.File]::ReadAllBytes($agentsFile)
Check 'a second wire leaves AGENTS.md byte-identical' `
    ((($agentsBefore -join ',') -eq ($agentsAfter -join ',')) -and ($wireAgain -match 'AGENTS\.md\s+-- unchanged')) `
    "before=$($agentsBefore.Length) after=$($agentsAfter.Length)"
# ...and it is not enough that the size stopped moving: the file must not carry the
# blank line the old write left behind, or every wired repo keeps one forever.
Check 'the wired doc ends with exactly one newline' `
    (($agentsAfter[-1] -eq 10) -and ($agentsAfter[-2] -ne 10)) `
    ("tail=" + [BitConverter]::ToString($agentsAfter[-4..-1]))

# A lefthook.yml this installer wrote at an OLDER version is not a foreign file, but
# "kept existing lefthook.yml" said the same thing about both. When pre-merge-commit
# was added to the template, every already-wired repo kept its pre-commit-only config
# and `qgate wire` reported success while the merge bypass stayed wide open -- the
# upgrade was undeliverable by the very command that announces it.
if (Get-Command lefthook -ErrorAction SilentlyContinue) {
    $lhr = Join-Path $tmp 'lefthookver'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $lhr -Recurse
    git -C $lhr init -q 2>$null
    & pwsh -NoProfile -File $installer -Target $lhr *> $null
    $curOut = (& pwsh -NoProfile -File $installer -Target $lhr 2>&1 | Out-String)
    # The absence half, and it is falsifiable here because this repo really was wired
    # by this version a line ago: a check that fires on a current config would make the
    # warning noise nobody reads.
    Check 'a current lefthook.yml is not reported as stale' ($curOut -notmatch 'no pre-merge-commit hook') $curOut
    Set-Content (Join-Path $lhr 'lefthook.yml') "pre-commit:`n  jobs:`n    - name: quality-gate`n      run: 'qgate.cmd -All -Full -Quiet'`n"
    $staleOut = (& pwsh -NoProfile -File $installer -Target $lhr 2>&1 | Out-String)
    Check 'wire names the hook a stale lefthook.yml is missing' `
        (($staleOut -match 'no pre-merge-commit hook') -and ($staleOut -match 'lefthook install')) $staleOut
} else {
    Write-Output '[skip] lefthook not on PATH -- the stale-config path cannot run'
}

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

# 23. The generated pre-commit hook, executed the way git executes it. Nothing in
# this suite had ever run one: the checks above assert on the TEXT of the template,
# and the shipped hook was text that read correctly and failed. It probed with
# `command -v qgate.cmd`, which is false under sh.exe even though qgate.cmd runs
# there, so the else branch took a bare `qgate`, exited 127 and BLOCKED the commit.
# `lefthook run pre-commit` typed in a shell passed the whole time, because that
# path goes through bash. Only a real `git commit` distinguishes them.
$genRepo = Join-Path $tmp 'gencommit'
New-Item -ItemType Directory -Path $genRepo | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $genRepo 'schema') -Recurse
git -C $genRepo init -q 2>$null
$shExe = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source
if ($shExe) {
    Push-Location $genRepo
    try {
        & $shExe (Join-Path $PSScriptRoot 'templates\pre-commit') *> $null
        $shCode = $LASTEXITCODE
    } finally { Pop-Location }
    Check 'the generated hook body runs under sh, the shell git uses' ($shCode -eq 0) "code=$shCode"
} else {
    Write-Output '[skip] no sh.exe -- the generated hook body cannot be run as git would'
}
& pwsh -NoProfile -File $installer -Target $genRepo *> $null
git -C $genRepo add -A 2>$null
git -C $genRepo -c user.email=selftest@local -c user.name=selftest commit -qm 'clean' *> $null
$commitCode = $LASTEXITCODE
Check 'a real git commit passes the generated hook on a clean tree' ($commitCode -eq 0) "code=$commitCode"
# ...and is refused when the gate fails, which is the entire job of a pre-commit.
$pfx = Join-Path $genRepo 'schema\example\v1\greeting.proto'
[IO.File]::WriteAllText($pfx, ([IO.File]::ReadAllText($pfx).Replace('string text = 1;', 'string Text = 1;')))
git -C $genRepo add -A 2>$null
git -C $genRepo -c user.email=selftest@local -c user.name=selftest commit -qm 'violation' *> $null
$refuseCode = $LASTEXITCODE
Check 'a real git commit is refused when the gate fails' ($refuseCode -ne 0) "code=$refuseCode"

# ...and the same for a MERGE, which git guards with a different hook entirely. A
# merge that commits on its own runs pre-merge-commit and never pre-commit, so
# wiring one name left `git merge --no-ff` completely unguarded: measured on git
# 2.53, the merge commit lands and no hook runs at all. Two branches that are each
# clean can merge into a tree that does not build, so the break reaches main and the
# next ordinary commit is the one refused, for a failure it did not cause. Driven
# through real git for the same reason as the block above: only real git picks the
# hook name, and `lefthook run pre-commit` would pass either way.
$mrg = Join-Path $tmp 'mergehook'
New-Item -ItemType Directory -Path $mrg | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $mrg 'schema') -Recurse
git -C $mrg init -q 2>$null
# Pinned, not inherited: with core.autocrlf=true every checkout below writes the
# fixture back as CRLF, buf format then reports the whole file as misformatted, and
# this block fails for a reason that has nothing to do with which hook git ran.
git -C $mrg config core.autocrlf false 2>$null
& pwsh -NoProfile -File $installer -Target $mrg *> $null
git -C $mrg add -A 2>$null
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'clean' *> $null
# Whatever `git init` called it: init.defaultBranch is a user setting, and assuming
# "main" left every checkout below on the branch it started on, so the merge merged a
# branch into itself and reported "Already up to date" -- green, for no reason.
$mainBranch = (git -C $mrg rev-parse --abbrev-ref HEAD)
$mpfx = Join-Path $mrg 'schema\example\v1\greeting.proto'
git -C $mrg checkout -q -b bad-branch 2>$null
[IO.File]::WriteAllText($mpfx, ([IO.File]::ReadAllText($mpfx).Replace('string text = 1;', 'string Text = 1;')))
git -C $mrg add -A 2>$null
# --no-verify, because that is how a red commit reaches a branch in the first place.
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'violation' --no-verify *> $null
git -C $mrg checkout -q $mainBranch 2>$null
$beforeMerge = (git -C $mrg rev-parse HEAD)
git -C $mrg -c user.email=selftest@local -c user.name=selftest merge --no-ff -m 'merge the violation' bad-branch *> $null
$mergeCode = $LASTEXITCODE
Check 'a merge commit is refused when the merged tree fails the gate' `
    (($mergeCode -ne 0) -and ($beforeMerge -eq (git -C $mrg rev-parse HEAD))) `
    "code=$mergeCode head moved: $($beforeMerge -ne (git -C $mrg rev-parse HEAD))"
git -C $mrg merge --abort *> $null
# ...and a clean merge still lands, or "merges are always broken" would pass the
# check above for entirely the wrong reason.
git -C $mrg checkout -q -b good-branch 2>$null
Set-Content (Join-Path $mrg 'notes.txt') 'harmless'
git -C $mrg add -A 2>$null
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'clean branch work' *> $null
git -C $mrg checkout -q $mainBranch 2>$null
$beforeGood = (git -C $mrg rev-parse HEAD)
git -C $mrg -c user.email=selftest@local -c user.name=selftest merge --no-ff -m 'merge the clean branch' good-branch *> $null
$goodCode = $LASTEXITCODE
# Three fields from `rev-list --parents`: the commit itself plus two parents. Two
# fields would be an ordinary commit, i.e. no merge happened at all.
$parents = @((git -C $mrg rev-list --parents -n 1 HEAD) -split ' ')
Check 'a clean merge commit still lands' `
    (($goodCode -eq 0) -and ((git -C $mrg rev-parse HEAD) -ne $beforeGood) -and ($parents.Count -eq 3)) `
    "code=$goodCode fields=$($parents.Count)"

# 24. A pin exists to make a run reproducible, so at the full level a mismatch is
# a failure, not a note: a green -Full run on a different compiler than the repo
# declared says nothing about the pinned version. Fast lane still only warns.
$pin = Join-Path $tmp 'pin'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $pin -Recurse
[IO.File]::WriteAllText((Join-Path $pin 'qgate.json'), '{"tools":{"go":"0.0.1"}}')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All 2>&1 | Out-String)
Check 'a pin mismatch only warns in the fast lane' (($LASTEXITCODE -eq 0) -and ($out -match '\[WARN\] go .*pins 0\.0\.1')) $out
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All -Full 2>&1 | Out-String)
Check 'a pin mismatch fails the full level' (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] go .*pins 0\.0\.1')) $out
# ...and a pin that matches must not fail, or the check would be unfalsifiable.
$goVer = if ((& go version) -match 'go(\d+\.\d+(\.\d+)?)') { $Matches[1] } else { $null }
if ($goVer) {
    [IO.File]::WriteAllText((Join-Path $pin 'qgate.json'), "{`"tools`":{`"go`":`"$goVer`"}}")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All -Full 2>&1 | Out-String)
    Check 'a matching pin does not fail the full level' (($LASTEXITCODE -eq 0) -and ($out -notmatch 'pins')) $out
}

# 25. Deferred updates. Without them the only way to stop an accepted-and-known
# update being reported every session is to stop reading the report -- and a
# deferral with no expiry is just a silence, so `until` is mandatory and an
# expired one comes back louder than it left.
$def = Join-Path $tmp 'defer'
New-Item -ItemType Directory -Path $def | Out-Null
$future = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')
$past = (Get-Date).AddDays(-5).ToString('yyyy-MM-dd')
[IO.File]::WriteAllText((Join-Path $def 'qgate.deferrals.json'), @"
{"dependencies":[
 {"name":"go","until":"$future","reason":"linter cannot parse the new syntax"},
 {"name":"rust/cargo","until":"$past","reason":"was waiting on the edition bump"},
 {"name":"nodate","reason":"missing until"}
]}
"@)
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def 2>&1 | Out-String)
Check 'a live deferral hides its finding but stays visible' `
    (($out -match '\[DEFERRED\] go until') -and ($out -notmatch '\[OUTDATED\] tool go ')) $out
Check 'an expired deferral is reported and its finding comes back' `
    (($out -match '\[DEFERRAL EXPIRED\] rust/cargo') -and ($out -match '\[OUTDATED\] tool rust/cargo')) $out
Check 'a deferral without until is a warning, not a silent skip' ($out -match "entry for 'nodate' needs 'until'") $out
# The run above wrote the cache; the summary answers from it and must still see
# the expiry, or an expired deferral would go unmentioned for the cache's life.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def -Summary 2>&1 | Out-String)
Check 'the cached summary still reports an expired deferral' ($out -match 'deferral\(s\).*have expired') $out
Check 'qgate outdated never fails, deferrals included' ($LASTEXITCODE -eq 0) $out

# 26. An unreadable qgate.deferrals.json must say so ONCE. `@($null)` iterates one
# null element, so the correct "not readable" line was followed by a second warning
# about "entry 1" that no entry ever produced -- a right outcome with an invented
# reason, the shape PLAYBOOK.md 0.1 is about.
$defBad = Join-Path $tmp 'defer-bad'
New-Item -ItemType Directory -Path $defBad | Out-Null
[IO.File]::WriteAllText((Join-Path $defBad 'qgate.deferrals.json'), '{ this is not json')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $defBad 2>&1 | Out-String)
Check 'an unreadable deferrals file is reported, and the run still passes' `
    (($LASTEXITCODE -eq 0) -and ($out -match 'qgate\.deferrals\.json is not readable')) $out
Check 'an unreadable deferrals file is not also blamed on a missing name/reason' `
    ($out -notmatch "needs both 'name' and 'reason'") $out

# 27. The same warning has to reach the -Full gate run. It was emitted only after
# the -Summary early return, and -Summary is the path -Full calls -- so a malformed
# qgate.deferrals.json was silently ignored exactly where it guards a commit, while
# README claimed a [WARN] and not a silent skip.
$defFull = Join-Path $tmp 'defer-full'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $defFull -Recurse
[IO.File]::WriteAllText((Join-Path $defFull 'qgate.deferrals.json'), '{"dependencies":[{"name":"go"}]}')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full 2>&1 | Out-String)
$defCode = $LASTEXITCODE
Check 'a malformed deferral is warned about on a -Full run' `
    (($defCode -eq 0) -and ($out -match "\[WARN\] qgate\.deferrals\.json entry 1 needs both 'name' and 'reason'")) "code=$defCode $out"
# A check that asserted `-notmatch '[DEFERRED]'` stood here and was deleted: a
# malformed entry is stored with no Name, and Split-Deferred iterates only entries
# that have one, so it could not emit [DEFERRED] for one either before or after the
# fix. An assertion that cannot fail is decoration, not the 0.1 absence check.
# What it should have been guarding is below: the warning has to reach the mode the
# hook actually runs in.
#
# -Quiet is what the generated pre-commit hook uses, and the warning was gated on
# `-not $Quiet` -- so a repo whose qgate.deferrals.json the gate cannot read got
# NOTHING at all (output length 0, exit 0) precisely where the gate guards a commit.
$outQ = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full -Quiet 2>&1 | Out-String)
$qCode = $LASTEXITCODE
Check 'a malformed deferral still reaches the -Quiet run the hook uses' `
    (($qCode -eq 0) -and ($outQ -match "\[WARN\] qgate\.deferrals\.json entry 1 needs both 'name' and 'reason'")) "code=$qCode $outQ"
# ...without -Quiet becoming chatty: a passing run stays silent about everything
# that is not the gate's own config being broken.
Check '-Quiet on a green run still says nothing else' `
    (($outQ -notmatch '\[PASS\]') -and ($outQ -notmatch '\[INFO\]') -and ($outQ -notmatch 'golangci\.yml')) $outQ
Remove-Item (Join-Path $defFull 'qgate.deferrals.json')
$outQ = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full -Quiet 2>&1 | Out-String)
Check '-Quiet prints nothing at all on a clean pass' `
    (($LASTEXITCODE -eq 0) -and [string]::IsNullOrWhiteSpace($outQ)) $outQ

# 28. Issue #3 again, through a different door: `-Only <stack the gate does not
# implement>` printed [SKIP] not implemented and exited 0 -- a green pipeline over
# zero checks, which is the exact thing `-Only nonsense` was made fatal for. It has
# no branch of its own any more; the zero-phase invariant below is what fails it.
$py = Join-Path $PSScriptRoot 'testdata\python-fixture'
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $py -Only 'python' 2>&1 | Out-String)
$pyCode = $LASTEXITCODE
Check '-Only on a detected but unimplemented stack fails the run' ($pyCode -ne 0) "code=$pyCode $out"
Check '-Only python gives the reason that applied' ($out -match 'python .*not implemented') $out
# The other -Only failure mode prints a different reason; if that one fired, the
# right exit code would be standing on the wrong explanation.
Check '-Only python is not blamed on an undetected stack' ($out -notmatch 'no such stack detected here') $out

# 29. THE INVARIANT: a run that executed zero check phases is not green. The rule is
# about phases that actually ran, never about which stacks were detected -- and both
# halves have to be stated or it collapses into "python never fails" (the old check
# here) or into "python always fails".
# Alone, an unimplemented stack IS the whole run and nothing was checked:
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $py -All 2>&1 | Out-String)
$pyAllCode = $LASTEXITCODE
Check '-All over an unimplemented stack alone fails: nothing was checked' `
    (($pyAllCode -ne 0) -and ($out -match '\[FAIL\] no check phase ran') -and ($out -match '\[SKIP\] python .*not implemented')) `
    "code=$pyAllCode $out"
# ...and the reason is the empty run, not the -Only rule, which was never invoked.
Check '-All over an unimplemented stack is not blamed on -Only' ($out -notmatch '\-Only') $out
# Beside a stack that did real work the same python marker is only a note: phases
# ran, so the run stands. Failing here would block work the gate never promised.
$mixed = Join-Path $tmp 'mixed'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $mixed -Recurse
Copy-Item (Join-Path $py 'pyproject.toml') $mixed
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $mixed -All 2>&1 | Out-String)
$mixCode = $LASTEXITCODE
Check '-All passes when a real stack ran and only flags the unimplemented one' `
    (($mixCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python .*not implemented')) "code=$mixCode $out"
Check 'a run that did check something is not called empty' ($out -notmatch 'no check phase ran') $out
# The web stack is the same hole with no unimplemented stack in sight: every phase
# of it is conditional on a config file or a package script, so a project with a
# node_modules but no eslint/stylelint config, no tsconfig, no build script and no
# lockfile ran nothing at all and was reported [PASS], exit 0.
$wz = Join-Path $tmp 'webzero'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wz -Recurse
New-Item -ItemType Directory -Path (Join-Path $wz 'node_modules\.bin') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $wz 'package.json'), '{"name":"webzero","private":true,"type":"module"}')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $wz -Only 'web' -Full 2>&1 | Out-String)
$wzCode = $LASTEXITCODE
Check 'a web stack whose every phase is conditional cannot report a green run' `
    (($wzCode -ne 0) -and ($out -match '\[FAIL\] no check phase ran')) "code=$wzCode $out"
Check 'a stack that ran no phase is not called [PASS]' ($out -notmatch '\[PASS\] web') $out
# The legitimate empty run must survive all of this: a clean tree on the fast lane
# says so and exits 0, and section 20 above proves it still does.

# 30. What -Only was actually handed. Both of these ended in a defensible-looking
# outcome standing on a reason about something else entirely.
$gate = Join-Path $PSScriptRoot 'gate\check.ps1'
# An empty value is the PowerShell absence trap: `if ($Only)` read `-Only ''` as
# "no filter given" and quietly widened the run to every stack.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only '' -Full 2>&1 | Out-String)
$emptyCode = $LASTEXITCODE
Check 'an empty -Only is refused, not read as no filter' `
    (($emptyCode -ne 0) -and ($out -match '\[FAIL\] -Only was given an empty value')) "code=$emptyCode $out"
Check 'an empty -Only does not silently widen the run' ($out -notmatch 'checking (every stack|all of them)') $out
# A second value used to bind to -Baseline positionally, so the user asking for two
# stacks was told the baseline revision did not exist.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go' 'banana' -Full 2>&1 | Out-String)
$strayCode = $LASTEXITCODE
Check 'a stray value after -Only is refused' `
    (($strayCode -ne 0) -and ($out -match 'unexpected argument\(s\): banana')) "code=$strayCode $out"
Check 'a stray value after -Only is not reported as a missing baseline' `
    ($out -notmatch 'baseline revision not found') $out
# ...but PowerShell parses the documented `-Only go,web` as an ARRAY and the shim
# flattens it into two arguments, so the help text's own example was refused by the
# error message that then quoted it back as the remedy. Stack names after -Only are
# its value, however the shell split them.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go' 'python' 2>&1 | Out-String)
$splitCode = $LASTEXITCODE
Check 'stack names split by the shell are read as the -Only list' `
    (($splitCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python')) "code=$splitCode $out"
# ...and the spelling that works has to keep working, or the validation would be
# worse than the bug: one value, comma separated, is a list of stacks.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go,python' 2>&1 | Out-String)
$listCode = $LASTEXITCODE
Check '-Only takes a comma-separated list as one value' `
    (($listCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python')) "code=$listCode $out"
Check '-Only does not read the whole list as one stack name' ($out -notmatch 'no such stack detected here') $out

# 30a. Fail-fast across stacks used to `break` the loop, and the report simply ended:
# a red go stack left the web stack with no line at all, indistinguishable from a repo
# that has no web stack. The work is still skipped; the skipping has to be on the record.
$twin = Join-Path $tmp 'twin'
New-Item -ItemType Directory -Path $twin | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') (Join-Path $twin 'go') -Recurse
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') (Join-Path $twin 'web') -Recurse
Set-GoFile (Join-Path $twin 'go\main.go') @'
package main

import "fmt"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	fmt.Printf("%d", "not an int")
	_ = Add(1, 2)
}
'@
$out = (& pwsh -NoProfile -File $gate -Root $twin -All 2>&1 | Out-String)
$twinCode = $LASTEXITCODE
Check 'a failing stack still fails the run' (($twinCode -ne 0) -and ($out -match '\[FAIL\] go go/')) "code=$twinCode $out"
Check 'a stack skipped by an earlier failure says so' `
    ($out -match '\[SKIP\] web web/.*earlier stack failed') $out

# 31. Order of the two early returns. `[SKIP] no known stack found` sat above the
# -Only validation, so in a repo with no marker file at all `-Only go` never reached
# it: exit 0, nothing checked, and a message about the repo rather than about the
# flag -- the same green-over-zero-checks lie as `-Only nonsense`, one line earlier.
$bare = Join-Path $tmp 'nostack'
New-Item -ItemType Directory -Path $bare | Out-Null
git -C $bare init -q 2>$null
$out = (& pwsh -NoProfile -File $gate -Root $bare -Only 'go' -Full 2>&1 | Out-String)
$bareCode = $LASTEXITCODE
Check '-Only in a repo with no stack at all fails' `
    (($bareCode -ne 0) -and ($out -match '\[FAIL\] -Only go -- no such stack detected here')) "code=$bareCode $out"
Check '-Only is not waved through as a repo the gate knows nothing about' `
    ($out -notmatch 'no known stack found') $out
# ...and the free pass itself stays: no marker file and no -Only is still a silent,
# green, zero-cost run, which is the documented behaviour for a repo with no stack.
$out = (& pwsh -NoProfile -File $gate -Root $bare -Full 2>&1 | Out-String)
Check 'a repo with no marker file is still skipped, not failed' `
    (($LASTEXITCODE -eq 0) -and ($out -match '\[SKIP\] no known stack found')) $out

# 32. A tool binary older than the module's go directive. Both failures are opaque:
# golangci-lint refuses to load its config, govulncheck names every file in the repo
# and four more inside the standard library. The verdict has to name the binary and
# the `go install` line instead. Driven through the helper rather than a fixture,
# because a go.mod the local toolchain cannot build fails at `go build` long before
# either tool runs -- and the machine's own tool versions are not a fixed point.
$installLine = 'go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest'
Check 'the Go a tool was built with is readable' `
    ((Get-GoBuiltWith 'golangci-lint') -match '^\d+\.\d+(\.\d+)?$')
# Build info, never the tool's own version output: `govulncheck -version` prints a
# `Go:` line that is the toolchain active in the CURRENT DIRECTORY, so the same binary
# reads go1.26.2 from a plain directory and go1.27.1 inside a module whose go
# directive pulls a newer toolchain. Comparing THAT against the module's directive
# compares the module with itself and can never fire. The number has to come out of
# the binary, and this check reads it independently to say so -- from inside a module,
# which is where every gate phase runs.
$vulnExe = (Get-Command govulncheck -ErrorAction SilentlyContinue).Source
if ($vulnExe) {
    $truth = if (((& go version -m $vulnExe) | Select-Object -First 1) -match ':\s+go(\d+\.\d+(?:\.\d+)?)') { $Matches[1] }
    Push-Location $go
    $inModule = Get-GoBuiltWith 'govulncheck'
    Pop-Location
    Check 'built-with is read from the binary, not from its own version output' `
        (($truth) -and ($inModule -eq $truth)) "binary=$truth read=$inModule"
}
$stale = Test-GoToolStale 'golangci-lint' '99.0' $installLine
Check 'a tool older than the go directive is named, with its reinstall line' `
    (($stale -match 'built with go\d+\.\d+') -and ($stale -match 'targets go99\.0') -and ($stale -match [regex]::Escape($installLine))) $stale
Check 'a tool newer than the go directive is not reported' `
    ($null -eq (Test-GoToolStale 'golangci-lint' '1.0' $installLine)) `
    (Test-GoToolStale 'golangci-lint' '1.0' $installLine)
Check 'a module with no go directive is not a staleness verdict' `
    ($null -eq (Test-GoToolStale 'golangci-lint' '' $installLine))

# 33. Third-party Go inside an npm tree. `golangci-lint run ./...` from the module
# root walks into web/node_modules -- npm packages ship .go files (eslint pulls in
# `flatted`, which contains a Go implementation) -- and a go+web repo went red on
# code nobody there wrote. The shipped .golangci.yml has to exclude it, and the
# control below proves the fixture really does trip the linter.
$nm = Join-Path $tmp 'nodemods'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $nm -Recurse
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $nm
$thirdParty = @'
package thirdparty

// Has reports whether s contains v.
func Has(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
'@
New-Item -ItemType Directory -Path (Join-Path $nm 'own') | Out-Null
Set-GoFile (Join-Path $nm 'own\has.go') $thirdParty
$r = Invoke-Gate $nm
Check 'the control file really is a linter finding' `
    (($r.Code -ne 0) -and ($r.Out -match 'slicescontains')) $r.Out
Remove-Item (Join-Path $nm 'own') -Recurse -Force
$vendored = Join-Path $nm 'web\node_modules\flattish'
New-Item -ItemType Directory -Path $vendored -Force | Out-Null
Set-GoFile (Join-Path $vendored 'has.go') $thirdParty
$r = Invoke-Gate $nm
Check 'the shipped config keeps the linter out of node_modules' `
    (($r.Code -eq 0) -and ($r.Out -notmatch 'slicescontains')) $r.Out

# 34. `wire` takes the gate's own name for "which repository". -Root is documented
# under the gate flags and wire took only -Target, so `qgate wire -Root <path>` died
# with a raw "A parameter cannot be found that matches parameter name 'Root'".
git -C $nm init -q 2>$null
$wireRoot = (& pwsh -NoProfile -File $installer -Root $nm -NoHook 2>&1 | Out-String)
Check 'wire accepts -Root as the repository to wire' `
    (($LASTEXITCODE -eq 0) -and ($wireRoot -match [regex]::Escape($nm))) "code=$LASTEXITCODE $wireRoot"

Remove-Item $tmp -Recurse -Force
if ($script:Fails) { Write-Output "`n$($script:Fails) of $($script:Total) check(s) failed"; exit 1 }
Write-Output "`nall checks passed ($($script:Total)/$($script:Total))"
