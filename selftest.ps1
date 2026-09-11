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
# ...except the one whose marker is the repository itself. testdata/ is inside this
# work tree, so base is there beside every stack a marker file created. Section 37
# asserts the rest of it: alone in a bare repo, and absent outside a work tree.
Check 'detects base stack with no marker file' `
    ([bool]($stacks | Where-Object { $_.Stack -eq 'base' -and $_.Marker -eq 'git work tree' -and $_.Implemented }))
Check 'detects go stack'   ([bool]($stacks | Where-Object { $_.Stack -eq 'go' -and $_.Implemented }))
Check 'detects web stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'web' -and $_.Implemented }))
Check 'detects rust stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'rust' -and $_.Implemented }))
Check 'detects proto stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'proto' -and $_.Implemented }))
Check 'detects godot stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'godot' -and $_.Implemented }))
# The one marker that is a PATTERN: a csproj is named after its project, and one .NET
# repo carries several of them. The marker recorded has to be the file, not the glob.
Check 'detects dotnet stack by its csproj name' `
    ([bool]($stacks | Where-Object { $_.Stack -eq 'dotnet' -and $_.Marker -eq 'Fixture.csproj' -and $_.Implemented }))
Check 'detects cpp stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'cpp' -and $_.Marker -eq 'CMakeLists.txt' -and $_.Implemented }))
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
# '{0:N1}' formats with the CURRENT culture: on a ru-RU machine every phase printed
# `(0,0s)`, so the timings this report exists to show meant something different per
# machine and parsed as nothing. Both halves -- a dot present, no comma anywhere.
Check 'a phase time prints with a dot in any locale' `
    (($r.Out -match '\(\d+\.\ds\)') -and ($r.Out -notmatch '\(\d+,\ds\)')) $r.Out
[IO.File]::WriteAllText((Join-Path $gign 'ugly.go'), "package main`n`nfunc  Ugly()  {}`n")
$r = Invoke-Gate $gign
Check 'gofmt still fails on a real unformatted file' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gofmt') -and ($r.Out -match 'ugly\.go') -and ($r.Out -notmatch 'bad\.go')) $r.Out

# The Godot runner had the identical hole: it collects every *.gd with
# Get-ChildItem -Recurse and excluded only .godot/ and addons/, so the same nested
# checkout reddened a godot repo's root gate. The question is asked per DIRECTORY and
# cached there rather than per file -- this list is every script in the project, while
# gofmt only ever names the handful it wants reformatted.
if ((Get-Command gdformat -ErrorAction SilentlyContinue) -and (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    $gdIgn = Join-Path $tmp 'godot-ignored'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\godot-fixture') $gdIgn -Recurse
    Set-Content (Join-Path $gdIgn '.gitignore') '.claude/'
    git -C $gdIgn init -q 2>$null
    git -C $gdIgn add -A 2>$null
    git -C $gdIgn -c user.email=selftest@local -c user.name=selftest commit -qm init *> $null
    $uglyGd = "extends Node`n`nfunc  _ready():`n        var x    =   1`n        print( x )`n"
    New-Item -ItemType Directory -Path (Join-Path $gdIgn '.claude\worktrees\agent-x') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $gdIgn '.claude\worktrees\agent-x\bad.gd'), $uglyGd)
    $r = Invoke-Gate $gdIgn
    Check 'a misformatted .gd in a gitignored worktree does not fail the gate' `
        (($r.Code -eq 0) -and ($r.Out -notmatch 'bad\.gd')) $r.Out
    [IO.File]::WriteAllText((Join-Path $gdIgn 'ugly.gd'), $uglyGd)
    $r = Invoke-Gate $gdIgn
    Check 'gdformat still fails on a misformatted .gd in the project' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gdformat') -and ($r.Out -match 'ugly\.gd') -and ($r.Out -notmatch 'bad\.gd')) $r.Out
} else {
    Write-Output '[skip] gdformat/gdlint not on PATH -- the Godot ignore filter cannot run'
}

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

# 3b. Probe: is a -Full run green on a fixture already proven clean? govulncheck
# needs a live vulnerability database, so with no network the full level fails --
# correctly, because unverifiable is not clean. That makes every later check that
# asserts a green -Full run an unmet precondition here, not a defect to report, so
# they [skip] rather than fail, exactly like a check whose tool is off PATH.
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -All -Full *> $null
$fullGreen = ($LASTEXITCODE -eq 0)

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

# 11b. .NET, red then green -- and then the two verdicts that are NOT red: a project
# whose references live in a game install this machine does not have, and one targeting
# an SDK major nobody here has. Both are gaps in the machine, and reporting them as a
# broken build would teach people to ignore the build phase.
$dnSdks = @(if (Get-Command dotnet -ErrorAction SilentlyContinue) { (& dotnet --list-sdks 2>$null) | Where-Object { $_ } })
if ($dnSdks) {
    $dn = Join-Path $tmp 'dotnet'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dn -Recurse
    $dnProj = Join-Path $dn 'Fixture.csproj'
    $dnCs = Join-Path $dn 'Greeter.cs'
    $dnProjClean = [IO.File]::ReadAllText($dnProj)
    $dnCsClean = [IO.File]::ReadAllText($dnCs)
    $r = Invoke-Gate $dn
    Check 'clean dotnet fixture passes' ($r.Code -eq 0) $r.Out
    $dnFullOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dn -All -Full 2>&1 | Out-String)
    $dnFullCode = $LASTEXITCODE
    Check 'clean dotnet fixture passes at the full level' ($dnFullCode -eq 0) $dnFullOut
    # `test` and `vuln` are conditional, and an omitted phase used to read exactly like a
    # passing one: the report could not tell "checked, clean" from "never asked". -Full is
    # what CI and the generated hook run, so that is where the difference is spelled out.
    Check 'the full level says which phases do not apply here' `
        (($dnFullOut -match '\[SKIP\] test -- no test project') -and
            ($dnFullOut -match '\[SKIP\] vuln -- no package references')) $dnFullOut
    # The absence half: naming them must not turn a green run red, and must not be mistaken
    # for the run having verified nothing -- the zero-phase invariant counts phases that RAN.
    Check 'naming an inapplicable phase is not a failure and not an empty run' `
        (($dnFullCode -eq 0) -and ($dnFullOut -notmatch 'no check phase ran') -and
            ($dnFullOut -match '\[PASS\] build')) $dnFullOut

    # One space where eight belong. The fix hint matters as much as the finding: every
    # line names file(line,col) and not one of them names the command that fixes them.
    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace('        return $"Hello', ' return $"Hello'))
    $r = Invoke-Gate $dn
    Check 'a whitespace violation fails the dotnet gate' `
        (($r.Code -ne 0) -and ($r.Out -match 'WHITESPACE') -and ($r.Out -match 'fix: dotnet format whitespace')) $r.Out
    Check 'a whitespace violation is not reported as a compile error' ($r.Out -notmatch 'error CS') $r.Out

    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace('return $"Hello, {name}!";', 'int x = "s"; return $"Hello, {name}!{x}";'))
    $r = Invoke-Gate $dn
    Check 'a compile error fails the dotnet gate' (($r.Code -ne 0) -and ($r.Out -match 'error CS0029')) $r.Out
    Check 'a compile error is not reported as a formatting problem' ($r.Out -notmatch 'WHITESPACE') $r.Out

    # Both defects in one file. Reported from the field twice: first `[FAIL] format` and NO
    # build line at all, then -- once the skip was on the record -- 1091 whitespace errors
    # in an upstream fork skipping the build that held the real bug. Whitespace is not
    # semantic: it fails the run, and the build still runs and speaks for itself.
    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace(
            '        return $"Hello, {name}!";', ' int x = "s"; return $"Hello, {name}!{x}";'))
    $r = Invoke-Gate $dn
    Check 'a format failure does not skip the build' `
        (($r.Code -ne 0) -and ($r.Out -match 'FAIL\] format') -and ($r.Out -match 'FAIL\] build') -and
            ($r.Out -match 'error CS0029')) $r.Out
    # The absence half: the old skip line, which hid the compile error behind whitespace.
    Check 'the build after a format failure is not reported as skipped' ($r.Out -notmatch 'SKIP\] build -- not run') $r.Out
    [IO.File]::WriteAllText($dnCs, $dnCsClean)

    # A game mod's <Reference> HintPath points into a Steam directory, and CI and half
    # the developer machines do not have one. Read by evaluating the project, never by
    # building it: the build would report forty MSB3245 lines about the code instead.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Ghost"><HintPath>C:\does\not\exist\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a reference the machine does not have is a skip with the reason, not a red build' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    Check 'a missing reference is not blamed on the code' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB')) $r.Out

    # ...and the HintPath is usually RELATIVE to the csproj (`..\..\lib\X.dll` in a real
    # test project), so both halves: a relative hint that resolves must not be called
    # missing, and one that does not must still be found. Resolving it against the
    # process directory instead of the project directory passes the first half and fails
    # the second -- or worse, silently skips every project on a machine that has
    # everything. The payload is a real managed assembly because the build phase runs
    # right after and a file of garbage bytes would fail it for the wrong reason.
    $dnLib = Join-Path $tmp 'lib'
    New-Item -ItemType Directory $dnLib -Force | Out-Null
    Copy-Item ([psobject].Assembly.Location) (Join-Path $dnLib 'Ghost.dll') -Force
    $dnRelRef = $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Ghost"><HintPath>..\lib\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@)
    [IO.File]::WriteAllText($dnProj, $dnRelRef)
    $r = Invoke-Gate $dn
    Check 'a relative HintPath that resolves is not reported as missing' `
        (($r.Code -eq 0) -and ($r.Out -notmatch 'reference\(s\) missing')) $r.Out
    Remove-Item (Join-Path $dnLib 'Ghost.dll') -Force
    $r = Invoke-Gate $dn
    Check 'a relative HintPath that resolves to nothing is a skip that names the file' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    Check 'a missing relative reference is not blamed on the code' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB')) $r.Out

    # A HintPath into another project's bin/ INSIDE the repository is a build-order gap,
    # not a missing game. Reported from the field: `..\Auga\bin\API\AugaAPI.dll`, the
    # output of a sibling project, was reported as "game/SDK not installed".
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Sibling"><HintPath>Other\bin\API\Sibling.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a missing in-repo build output names the build order, not the game' `
        (($r.Code -eq 0) -and ($r.Out -match 'Sibling\.dll\) -- built by another project in this repo') -and
            ($r.Out -notmatch 'game/SDK not installed')) $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('net8.0', 'net99.0'))
    $r = Invoke-Gate $dn
    Check 'a target framework no installed SDK can build is a skip that names both' `
        (($r.Code -eq 0) -and ($r.Out -match 'needs \.NET SDK 99\.x') -and ($r.Out -match 'installed \d')) $r.Out
    Check 'an SDK the machine lacks is not reported as an error' ($r.Out -notmatch 'error ') $r.Out

    # A multi-targeted project leaves the SINGULAR property empty, so reading only that
    # one reports nothing and builds the project anyway -- green, on a TFM no SDK here
    # can produce.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace(
            '<TargetFramework>net8.0</TargetFramework>', '<TargetFrameworks>net8.0;net99.0</TargetFrameworks>'))
    $r = Invoke-Gate $dn
    Check 'one unbuildable TFM in a multi-targeted project is a skip that names it' `
        (($r.Code -eq 0) -and ($r.Out -match 'needs \.NET SDK 99\.x')) $r.Out
    Check 'a multi-targeted project is not failed over the TFM nobody has' `
        (($r.Out -notmatch 'error ') -and ($r.Out -notmatch 'reference\(s\) missing')) $r.Out

    # ...but a csproj msbuild cannot even evaluate IS a defect in the repository, and it
    # has to land as one rather than as another environment excuse.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', '<Nope'))
    $r = Invoke-Gate $dn
    Check 'an unparseable csproj fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] refs')) $r.Out
    Check 'an unparseable csproj is not called a missing reference' ($r.Out -notmatch 'reference\(s\) missing') $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    # The fast lane. Measured on two real mods: 1396 and 447 whitespace violations, so
    # a whole-project format check on every commit blocks the repository forever. Both
    # halves, or "narrowed correctly" is indistinguishable from "format switched off":
    # the committed violation must be ignored while nothing .cs changed, and must be
    # found the moment it is touched.
    $dnFast = Join-Path $tmp 'dotnet-fast'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnFast -Recurse
    $ugly = Join-Path $dnFast 'Ugly.cs'
    [IO.File]::WriteAllText($ugly, "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n")
    git -C $dnFast init -q 2>$null
    git -C $dnFast add -A 2>$null
    git -C $dnFast -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $dnFast 'notes.md'), "not a .cs file`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFast 2>&1 | Out-String)
    $dnFastCode = $LASTEXITCODE
    Check 'the fast lane does not format a project whose .cs files nobody touched' `
        (($dnFastCode -eq 0) -and ($out -match '\[SKIP\] format Fixture\.csproj') -and ($out -notmatch 'WHITESPACE')) `
        "code=$dnFastCode $out"
    # ...and it still builds it, or the narrowing would have dropped the stack entirely.
    Check 'the fast lane still builds a project it did not format' ($out -match '\[PASS\] build') $out
    [IO.File]::WriteAllText($ugly, "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFast 2>&1 | Out-String)
    $dnTouchCode = $LASTEXITCODE
    Check 'touching a .cs file brings the whitespace check back' `
        (($dnTouchCode -ne 0) -and ($out -match 'WHITESPACE') -and ($out -match 'Ugly\.cs')) "code=$dnTouchCode $out"
    # --include is resolved against the CURRENT DIRECTORY and an absolute path matches
    # nothing at all -- silently, exit 0. That is the shape this half would catch.
    Check 'the narrowed format check is not a silent no-op' ($out -notmatch '\[SKIP\] format') $out

    # ...and the file added inside a BRAND NEW directory, which is the shape the narrowing
    # could not see at all. `git status --porcelain` collapses a wholly untracked directory
    # to one entry, `NewFolder/`, so the changed-path list held a directory, the `*.cs`
    # filter dropped it, and the fast lane reported `no changed .cs files` and exited 0
    # over a real violation that `-All` finds. Get-ChangedPaths is what every stack narrows
    # through, so this was the fast lane's blind spot everywhere, not just here.
    $dnNew = Join-Path $tmp 'dotnet-newdir'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnNew -Recurse
    git -C $dnNew init -q 2>$null
    git -C $dnNew add -A 2>$null
    git -C $dnNew -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    New-Item -ItemType Directory -Path (Join-Path $dnNew 'NewFolder') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnNew 'NewFolder\Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnNew 2>&1 | Out-String)
    $dnNewCode = $LASTEXITCODE
    Check 'a violation inside a brand new directory is seen by the fast lane' `
        (($dnNewCode -ne 0) -and ($out -match 'WHITESPACE') -and ($out -match 'Ugly\.cs')) "code=$dnNewCode $out"
    # The absence half, and it is the whole bug: the run used to be green with this line.
    Check 'a file in a new directory is not called no changed .cs files' `
        ($out -notmatch 'no changed \.cs files') $out

    # -Baseline narrows the whole-project format pass too. Reported from the field: an
    # upstream fork carries 1091 whitespace errors nobody may reformat, and -Baseline was
    # wired to golangci alone, so `-Full -Baseline HEAD` failed exactly like `-Full`.
    # $dnFast has a committed Ugly.cs; restored to HEAD it is a violation nobody touched.
    $dnBase = Join-Path $tmp 'dotnet-baseline'
    Copy-Item $dnFast $dnBase -Recurse
    git -C $dnBase checkout -q -- Ugly.cs 2>$null
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBase -All -Full -Baseline HEAD 2>&1 | Out-String)
    $dnBaseCode = $LASTEXITCODE
    Check '-Baseline leaves a committed format violation alone at the full level' `
        (($dnBaseCode -eq 0) -and ($out -match '\[SKIP\] format Fixture\.csproj -- no changed \.cs files since HEAD') -and
            ($out -match '\[PASS\] build')) "code=$dnBaseCode $out"
    # The other half: the file touched since the baseline is still judged, whole.
    [IO.File]::WriteAllText((Join-Path $dnBase 'Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBase -All -Full -Baseline HEAD 2>&1 | Out-String)
    $dnBaseCode = $LASTEXITCODE
    Check '-Baseline still judges a file touched since the baseline' `
        (($dnBaseCode -ne 0) -and ($out -match 'Ugly\.cs\(5,') -and ($out -match 'Ugly\.cs\(6,')) "code=$dnBaseCode $out"

    # Two or more dotnet projects in one run share ONE `dotnet format` pass over a
    # temporary solution: measured on ContentTool (13 csproj, warm), 25.6s of per-project
    # calls against 3.3-3.6s for one call over the same projects. The saving is worthless
    # if the report stops naming the project that is actually dirty, so both halves --
    # the clean project passes, the dirty one fails with ITS csproj in the fix line.
    $dnMulti = Join-Path $tmp 'dotnet-multi'
    foreach ($n in 'A', 'B') {
        $d = Join-Path $dnMulti $n
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d "$n.csproj"), $dnProjClean)
        [IO.File]::WriteAllText((Join-Path $d 'Greeter.cs'), $dnCsClean)
    }
    $uglyOne = "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n"
    [IO.File]::WriteAllText((Join-Path $dnMulti 'B\Ugly.cs'), $uglyOne)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMulti -All 2>&1 | Out-String)
    $dnMultiCode = $LASTEXITCODE
    Check 'one format pass over two projects still blames the project that is dirty' `
        (($dnMultiCode -ne 0) -and ($out -match '\[PASS\] format \(\d+\.\ds, one pass over 2 projects\)') -and
            ($out -match '\[FAIL\] format \(shared pass\)') -and ($out -match 'B\\Ugly\.cs') -and
            ($out -match 'fix: dotnet format whitespace B\.csproj')) "code=$dnMultiCode $out"
    # The absence half, and it is the whole risk of sharing one pass: the clean project
    # must not inherit its neighbour's violations, and no phase may print 0.0s for work
    # that really took three seconds somewhere else.
    Check 'a shared format pass does not blame the clean project or claim zero time' `
        (($out -notmatch 'fix: dotnet format whitespace A\.csproj') -and ($out -notmatch 'format \(0\.0s')) $out
    # ...and the temporary solution is by-product: it lives outside the repository and
    # does not survive the run that made it.
    $dnSlnKey = "quality-gate-fmt-$(Get-PathKey (Resolve-Path $dnMulti).Path)-*"
    Check 'the temporary solution is gone when the run ends' `
        (-not (Get-ChildItem ([IO.Path]::GetTempPath()) -Filter $dnSlnKey -Directory -ErrorAction SilentlyContinue)) `
        $dnSlnKey

    # ...and a whitespace failure in the FIRST project must not skip the second one: the
    # other stacks are where the semantic checks live. Red run, both stacks on the record.
    $dnMultiSoft = Join-Path $tmp 'dotnet-multi-soft'
    Copy-Item $dnMulti $dnMultiSoft -Recurse
    Move-Item (Join-Path $dnMultiSoft 'B\Ugly.cs') (Join-Path $dnMultiSoft 'A\Ugly.cs')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiSoft -All 2>&1 | Out-String)
    $dnMultiSoftCode = $LASTEXITCODE
    Check 'a format failure in one project does not skip the next project' `
        (($dnMultiSoftCode -ne 0) -and ($out -match '\[FAIL\] dotnet A/') -and ($out -match '\[PASS\] dotnet B/')) `
        "code=$dnMultiSoftCode $out"
    Check 'a format failure does not mark later stacks as not run' ($out -notmatch 'an earlier stack failed') $out

    # The fast lane narrows the same pass with --include, and the narrowing is what keeps
    # a repository with committed violations committable: B carries one nobody touched,
    # A's touched file carries one, and only A's is a verdict.
    $dnMultiFast = Join-Path $tmp 'dotnet-multi-fast'
    Copy-Item $dnMulti $dnMultiFast -Recurse
    [IO.File]::WriteAllText((Join-Path $dnMultiFast 'A\Ugly.cs'), $uglyOne)
    git -C $dnMultiFast init -q 2>$null
    git -C $dnMultiFast add -A 2>$null
    git -C $dnMultiFast -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $dnMultiFast 'A\Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiFast 2>&1 | Out-String)
    $dnMultiFastCode = $LASTEXITCODE
    Check 'the fast lane judges the touched project' `
        (($dnMultiFastCode -ne 0) -and ($out -match 'A\\Ugly\.cs') -and
            ($out -match 'fix: dotnet format whitespace A\.csproj')) "code=$dnMultiFastCode $out"
    # The absence half: an --include list that matched nothing (an absolute path does
    # exactly that, silently) would leave B's committed violation to be reported instead.
    Check 'the fast lane does not report the violation nobody touched' `
        ($out -notmatch 'B\\Ugly\.cs') $out

    # A project no installed SDK can build cannot go into the solution -- it fails the
    # LOAD, which would turn one machine gap into a formatting verdict on every project
    # beside it. It is still reported as the skip it always was, and the other two are
    # still checked in one pass.
    $dnMultiSdk = Join-Path $tmp 'dotnet-multi-sdk'
    Copy-Item $dnMulti $dnMultiSdk -Recurse
    Remove-Item (Join-Path $dnMultiSdk 'B\Ugly.cs') -Force
    $dnC = Join-Path $dnMultiSdk 'C'
    New-Item -ItemType Directory -Path $dnC -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnC 'C.csproj'), $dnProjClean.Replace('net8.0', 'net99.0'))
    [IO.File]::WriteAllText((Join-Path $dnC 'Greeter.cs'), $dnCsClean)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiSdk -All 2>&1 | Out-String)
    $dnMultiSdkCode = $LASTEXITCODE
    Check 'a project no SDK here can build is left out of the shared pass, not run through it' `
        (($dnMultiSdkCode -eq 0) -and ($out -match 'one pass over 2 projects') -and
            ($out -match 'needs \.NET SDK 99\.x')) "code=$dnMultiSdkCode $out"
    # The absence half: leaving it out must not turn into an error, and must not quietly
    # drop the formatting check for the projects that CAN be loaded.
    Check 'leaving the unbuildable project out is not an error and not a dropped check' `
        (($out -notmatch 'error ') -and ($out -match '\[PASS\] format \(shared pass\)')) $out

    # A Unity project's csproj are editor output, not dotnet projects. Reported from the
    # field: six of them became six stacks of [UNKNOWN] and 260-reference skips, and they
    # broke the shared format solution. One SKIP for the Unity project, left out of the
    # shared pass, which still covers the two real projects beside it.
    $dnUnity = Join-Path $tmp 'dotnet-unity'
    Copy-Item $dnMultiSdk $dnUnity -Recurse
    Remove-Item (Join-Path $dnUnity 'C') -Recurse -Force
    $dnU = Join-Path $dnUnity 'U'
    New-Item -ItemType Directory -Path (Join-Path $dnU 'ProjectSettings'), (Join-Path $dnU 'Assets') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnU 'ProjectSettings\ProjectVersion.txt'), "m_EditorVersion: 2022.3.62f1`n")
    foreach ($n in 'Assembly-CSharp', 'Assembly-CSharp-Editor') {
        [IO.File]::WriteAllText((Join-Path $dnU "$n.csproj"), $dnProjClean.Replace('</Project>', '<Nope'))
    }
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnUnity -All 2>&1 | Out-String)
    $dnUnityCode = $LASTEXITCODE
    Check 'a Unity project is one skip, and the shared pass still covers the real projects' `
        (($dnUnityCode -eq 0) -and (@($out -split "`r?`n" | Where-Object { $_ -match '\[SKIP\] dotnet U/ .*Unity-generated' }).Count -eq 1) -and
            ($out -match 'one pass over 2 projects')) "code=$dnUnityCode $out"
    # The absence half: an unparseable Unity csproj would fail `refs` if it were a stack.
    Check 'Unity-generated csproj are not stacks' `
        (($out -notmatch 'Assembly-CSharp') -and ($out -notmatch 'could not load its solution')) $out

    # The whole-project check is the one CI and the generated pre-commit hook run, and on
    # a real mod it is 1397 WHITESPACE lines -- 323k chars, which the report's global
    # 6000-char truncation then cut to 27 lines and a byte count: no total, no file count,
    # and the cut landing mid-line. Capped at twenty with the real numbers beside it.
    $dnFlood = Join-Path $tmp 'dotnet-flood'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnFlood -Recurse
    # One space where four belong, thirty times: methods M1..M30 land on lines 5..34.
    $floodBody = ((1..30 | ForEach-Object { " public static int M$_() => $_;" }) -join "`r`n")
    [IO.File]::WriteAllText((Join-Path $dnFlood 'Flood.cs'),
        "namespace Fixture;`r`n`r`npublic static class Flood`r`n{`r`n$floodBody`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFlood -All 2>&1 | Out-String)
    $dnFloodCode = $LASTEXITCODE
    Check 'a format flood is capped and counted' `
        (($dnFloodCode -ne 0) -and ($out -match 'format: 3\d violation\(s\) in 1 file\(s\) -- showing first 20')) `
        "code=$dnFloodCode $out"
    # The absence half, and it is the whole point: a cap that printed all thirty would
    # satisfy the count above. M1 is on line 5 and must still be there; M26..M30 are on
    # lines 30..34, past the cap, and must not be.
    Check 'the format flood stops at twenty lines' `
        ((@($out -split "`r?`n" | Where-Object { $_ -match 'error WHITESPACE' }).Count -le 20) -and
            ($out -match 'Flood\.cs\(5,') -and ($out -notmatch 'Flood\.cs\(3[0-4],')) $out

    # The warning count is read out of the BUILD OUTPUT, and an incremental build that
    # compiles nothing prints nothing: reported from the field, `[WARN] RailCheck.csproj:
    # 9 compiler warning(s)` on a cold obj/ and no line at all on the next run of the same
    # commit. The number said whether csc ran, not what the code contains. Two runs of the
    # SAME tree is the whole test -- one run cannot tell the two behaviours apart.
    $dnWarn = Join-Path $tmp 'dotnet-warn'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnWarn -Recurse
    [IO.File]::WriteAllText((Join-Path $dnWarn 'Warned.cs'),
        "namespace Fixture;`r`n`r`npublic static class Warned`r`n{`r`n    public static int One()`r`n    {`r`n        int unused;`r`n        return 1;`r`n    }`r`n}`r`n")
    $dnWarn1 = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnWarn -All -Full 2>&1 | Out-String)
    $dnWarn1Code = $LASTEXITCODE
    $dnWarn2 = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnWarn -All -Full 2>&1 | Out-String)
    $dnWarn2Code = $LASTEXITCODE
    Check 'the full level counts compiler warnings on every run, not only a cold one' `
        (($dnWarn1 -match '\[WARN\] Fixture\.csproj: 1 compiler warning\(s\)') -and
            ($dnWarn2 -match '\[WARN\] Fixture\.csproj: 1 compiler warning\(s\)')) `
        "run1=$dnWarn1`nrun2=$dnWarn2"
    # The absence half: a warning is a note beside a green build, never a compile error and
    # never a red run -- rebuilding from scratch must not change the verdict.
    Check 'a counted warning is not turned into a compile error or a red run' `
        (($dnWarn1Code -eq 0) -and ($dnWarn2Code -eq 0) -and ($dnWarn2 -notmatch 'error CS')) `
        "code1=$dnWarn1Code code2=$dnWarn2Code $dnWarn2"

    # `test` and `vuln` used to exist only where a regex found their marker in the csproj
    # TEXT, so anything imported through Directory.Build.props was invisible: measured, a
    # project whose Microsoft.NET.Test.Sdk and xunit come from there passed `-All -Full`
    # with no `test` phase at all while `dotnet test --no-build` found the failing test and
    # exited 1. Both facts now come from the MSBuild evaluation that already runs. The
    # cheap half of that needs no package and no restore: a project that simply declares
    # itself one, in a csproj whose text does not contain the string the old check hunted.
    $dnTest = Join-Path $tmp 'dotnet-istest'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnTest -Recurse
    [IO.File]::WriteAllText((Join-Path $dnTest 'Fixture.csproj'), $dnProjClean.Replace(
            '<Nullable>enable</Nullable>', "<IsTestProject>true</IsTestProject>`n    <Nullable>enable</Nullable>"))
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnTest -All -Full 2>&1 | Out-String)
    $dnTestCode = $LASTEXITCODE
    Check 'a project that evaluates as a test project gets the test phase' `
        (($dnTestCode -ne 0) -and ($out -match '\[FAIL\] test')) "code=$dnTestCode $out"
    # ...and the red is the test phase speaking, not an earlier phase falling over: a
    # broken build would satisfy "exit non-zero" while proving nothing about detection.
    Check 'the test phase verdict is not standing on an earlier failure' `
        ($out -notmatch '\[FAIL\] (refs|format|build)') $out

    # A multi-targeted project evaluates with TargetFramework EMPTY, so every item inside
    # an ItemGroup conditioned on it is absent from the answer: measured on
    # `net8.0;net8.0-windows`, the conditioned <Reference> came back as `"Reference": []`,
    # the missing game DLL went unreported, and the gate BUILT the project -- turning the
    # [SKIP] it owed the reader into CS0246. References are evaluated per TFM now.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace(
            '<TargetFramework>net8.0</TargetFramework>',
            '<TargetFrameworks>net8.0;net8.0-windows</TargetFrameworks>').Replace('</Project>', @"
  <ItemGroup Condition="'`$(TargetFramework)' == 'net8.0-windows'">
    <Reference Include="Ghost"><HintPath>C:\does\not\exist\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a reference conditioned on one target framework is still evaluated' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    # The absence half: the old behaviour was to see no reference and build anyway.
    Check 'a conditioned missing reference is not built over' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB') -and ($r.Out -notmatch '\[PASS\] build')) $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    # The other half of the same defect, plus the report bug it was hiding behind. The
    # package here is declared ONLY in Directory.Build.props, so the vulnerability gate
    # used to skip the project outright; and with the source unreachable that gate answers
    # [UNKNOWN] -- which the summary of a PASSING stack then dropped, because its filter
    # kept [PASS]/[WARN]/[SKIP] and nothing else. Measured: `[PASS] dotnet ... [PASS]
    # build`, exit 0, over a question nobody asked. The package has to come down once
    # before the source is broken, so a machine with no source skips this out loud.
    $dnPkg = Join-Path $tmp 'dotnet-props'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnPkg -Recurse
    [IO.File]::WriteAllText((Join-Path $dnPkg 'Directory.Build.props'), @'
<Project>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
'@)
    Push-Location $dnPkg
    & dotnet restore Fixture.csproj -nologo *> $null
    $dnRestored = ($LASTEXITCODE -eq 0)
    Pop-Location
    if ($dnRestored) {
        # <clear /> plus a port nothing listens on: restore is already satisfied from the
        # global packages folder, `dotnet list package --vulnerable` is not. The retry caps
        # turn NuGet's 18 seconds of backoff into two (measured).
        [IO.File]::WriteAllText((Join-Path $dnPkg 'NuGet.config'), @'
<configuration>
  <packageSources>
    <clear />
    <add key="unreachable" value="http://127.0.0.1:9/v3/index.json" />
  </packageSources>
</configuration>
'@)
        $priorRetry = @($env:NUGET_ENABLE_ENHANCED_HTTP_RETRY, $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT,
            $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS)
        $env:NUGET_ENABLE_ENHANCED_HTTP_RETRY = 'true'
        $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT = '1'
        $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS = '0'
        try {
            $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnPkg -All -Full 2>&1 | Out-String)
            $dnPkgCode = $LASTEXITCODE
        } finally {
            $env:NUGET_ENABLE_ENHANCED_HTTP_RETRY = $priorRetry[0]
            $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT = $priorRetry[1]
            $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS = $priorRetry[2]
        }
        Check 'a package declared only in Directory.Build.props reaches the vulnerability gate' `
            (($dnPkgCode -eq 0) -and ($out -match 'could not check for vulnerable packages')) "code=$dnPkgCode $out"
        Check 'an unperformed check is not dropped from the report of a passing stack' `
            (($out -match '\[PASS\] dotnet') -and ($out -match '\[UNKNOWN\]')) $out
        # ...and it is there because the summary kept it, not because the stack failed and
        # dumped its raw lines -- which is how this would pass while still being broken.
        Check 'the [UNKNOWN] survived the summary, it is not a failure dump' ($out -notmatch '\[FAIL\]') $out
    } else {
        Write-Output '[skip] no NuGet source reachable -- the Directory.Build.props package checks cannot run'
    }

    # Roslyn analyzers, injected through -p:CustomBeforeMicrosoftCommonProps: not one of
    # these repositories edits its csproj to get static analysis, so the gate carries the
    # packages into the build and leaves the work tree alone. Four questions: does anything
    # come out at all, does the fast lane stay out of it, do the Unity rules stay away from
    # a project that has never heard of UnityEngine, and -- the one that matters -- does a
    # diagnostic stay a warning instead of reddening a build that compiles.
    $dnAna = Join-Path $tmp 'dotnet-analyzers'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnAna -Recurse
    # CA1001 (SDK) and MA0084 (Meziantou) in one file: two diagnostics prove both the
    # properties and the injected package arrived. The SDK half has been CA1310 and, before
    # that, MA0074; both are now silenced. CA1001 is silenced too, but only under
    # QGateUnity, and this fixture references no UnityEngine -- the assets check below is
    # the same fact from the other side -- so it is still a live SDK rule here, and it
    # doubles as the proof that the Unity suppression did not go global.
    # Prefix() is a Harmony patch, spelled the only way Harmony accepts -- the leading
    # underscores are the injector's API, and CA1707 asking for them to be renamed is the
    # single loudest false positive this gate can produce on a game mod.
    [IO.File]::WriteAllText((Join-Path $dnAna 'Probe.cs'), @'
namespace Fixture;

public sealed class Probe
{
    private readonly string tag = "probe";

    private readonly System.IO.MemoryStream buffer = new();

    public string Tag => tag;

    public int Length => (int)buffer.Length;

    public int Find(string a, string b)
    {
        var tag = a; ;
        return tag.IndexOf(b);
    }

    public static bool Prefix(object __instance) => __instance != null;
}

internal class Sealable
{
    public int Value => 1;
}
'@)
    # Fast lane FIRST, on a cold obj/: an incremental build that compiles nothing prints no
    # warnings either, so running it after the full level would pass without proving a thing.
    $r = Invoke-Gate $dnAna
    $anaFastOut = $r.Out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnAna -All -Full 2>&1 | Out-String)
    $dnAnaCode = $LASTEXITCODE
    # Only a RESTORE failure is a reason to skip: an analyzer error that read as a failed
    # injection is the defect the `;;` in Find() above exists to catch.
    if ($out -match 'injection failed[^\r\n]*\bNU\d') {
        Write-Output '[skip] analyzer packages could not be restored -- the injection checks cannot run'
    }
    else {
        # MA0037 (empty statement) is ERROR by default in Meziantou. Reported from the
        # field: one stray `;;` failed the analyzer build, the gate called it a failed
        # injection and dropped every analyzer finding. It is a finding like any other.
        Check 'an error-severity analyzer default does not drop the analyzer pass' `
            (($out -notmatch 'injection failed') -and ($out -match 'analyzer diagnostic\(s\)[^\r\n]*MA0037')) $out
        Check 'analyzer diagnostics are reported at the full level' `
            (($out -match 'analyzer diagnostic\(s\)') -and ($out -match 'MA0084') -and ($out -match 'CA1001')) $out
        # The second noise pass, asserted as absence: the probe's Find() is still a
        # culture-sensitive-looking IndexOf and Probe itself is still a candidate for
        # "could be sealed", so a NoWarn list that stopped being applied would show up here.
        Check 'the second-pass suppressions stay silent' `
            (($out -notmatch 'CA1310') -and ($out -notmatch 'CA1852')) $out
        # The rule that had to go. Harmony patch parameters are named __instance, __result,
        # ___privateField and __state because Harmony reads those names; CA1707 asks for
        # every one of them to be renamed, which breaks the patch. 134 hits on the live
        # repositories, not one of them a defect.
        Check 'CA1707 stays silent about a Harmony patch parameter' `
            ($out -notmatch 'CA1707') $out
        # The point of this pass. The owner asked for the volume first, and a rule that goes
        # red before anybody has read it is a rule people learn to route around.
        Check 'analyzer diagnostics are a warning, not a failure' `
            (($dnAnaCode -eq 0) -and ($out -match '\[PASS\] build') -and ($out -notmatch '\[FAIL\]')) "code=$dnAnaCode $out"
        # The compiler's own count is separate: one number for both would read as though csc
        # had suddenly grown 300 opinions about code it used to accept.
        Check 'analyzer diagnostics are not counted as compiler warnings' `
            ($out -notmatch 'compiler warning\(s\)') $out
        Check 'the fast lane does not pay for the analyzer build' `
            (($anaFastOut -notmatch 'analyzer diagnostic') -and ($anaFastOut -notmatch 'MA0084')) $anaFastOut
        # Unity rules on a project with no UnityEngine anywhere are noise. The assets file is
        # the honest witness: it says what restore actually pulled, not what was asked for.
        $anaAssets = [IO.File]::ReadAllText((Join-Path $dnAna 'obj\project.assets.json'))
        Check 'Unity analyzers are not injected into a project with no UnityEngine reference' `
            (($anaAssets -match 'Meziantou\.Analyzer/3\.0\.224') -and ($anaAssets -notmatch 'Microsoft\.Unity\.Analyzers')) `
            'obj/project.assets.json'
    }

    # And the failure this feature must survive. Injecting PackageReferences forces a
    # restore, and a repository that pins its packages with a lock file answers NU1004 --
    # the same shape as an offline machine or a private feed. Reported as a warning, and
    # the build is repeated without the analyzers: nothing here may become unbuildable
    # because the gate wanted an opinion about the code.
    $dnLock = Join-Path $tmp 'dotnet-lock'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnLock -Recurse
    Push-Location $dnLock
    & dotnet restore Fixture.csproj -p:RestorePackagesWithLockFile=true -nologo *> $null
    $dnLocked = (($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $dnLock 'packages.lock.json')))
    Pop-Location
    if ($dnLocked) {
        [IO.File]::WriteAllText((Join-Path $dnLock 'Fixture.csproj'), $dnProjClean.Replace('</PropertyGroup>', @'
  <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
    <RestoreLockedMode>true</RestoreLockedMode>
  </PropertyGroup>
'@))
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnLock -All -Full 2>&1 | Out-String)
        $dnLockCode = $LASTEXITCODE
        Check 'a repository the analyzers cannot be injected into is still built' `
            (($dnLockCode -eq 0) -and ($out -match '\[PASS\] build')) "code=$dnLockCode $out"
        # Silently building without them would be worse than not injecting at all: the report
        # would claim an analysis nobody performed.
        Check 'a failed injection says so, with its reason' `
            (($out -match '\[WARN\] analyzers -- injection failed, built without them') -and ($out -match 'NU1004')) $out
    }
    else {
        Write-Output '[skip] no lock file could be produced -- the injection fallback cannot be exercised'
    }
} else {
    Write-Output '[skip] no .NET SDK on this machine -- the dotnet stack cannot be exercised'
}

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

# A hook does not run in the environment a terminal does: git exports GIT_DIR and
# leaves GIT_WORK_TREE unset, and under those two variables git stops DISCOVERING the
# repository and calls the current directory the work tree root. Measured on git 2.53
# in a linked worktree, from `<worktree>/schema`: `rev-parse --show-toplevel` answered
# `<worktree>/schema`, and `--path-format=absolute` only made that wrong answer
# absolute. The proto phase built buf's baseline from that root and handed it
# `<worktree>/schema/.git`, which does not exist -- `could not clone ... exit status 3`
# on every commit from a worktree, for a schema with nothing wrong with it.
#
# Driven through a CHILD pwsh, because the fix clears those variables once for the
# whole process and this file dot-sourced the gate at line 15 -- setting GIT_DIR here
# would prove nothing. Both halves are asserted in the same run: raw git still gets it
# wrong, or the fixture has stopped reproducing the hook environment at all, and the
# gate gets it right anyway.
$hookWt = Join-Path $tmp 'hookwt'
git -C $mrg worktree add -q -b hookenv $hookWt *> $null
$hookGitDir = (& git -C $hookWt rev-parse --path-format=absolute --git-dir 2>$null)
$probe = Join-Path $tmp 'hookenv-probe.ps1'
[IO.File]::WriteAllText($probe, @'
param([string]$Sub, [string]$GitDir, [string]$Detect)
$env:GIT_DIR = $GitDir
Set-Location $Sub
Write-Output "raw=$(git rev-parse --show-toplevel)"
. $Detect
Write-Output "gate=$(Get-RepoRoot (Get-Location).Path)"
'@)
if (-not $hookGitDir) {
    Write-Output '[skip] git refused to make a linked worktree -- the hook-environment check needs one'
} else {
    $hookOut = (& pwsh -NoProfile -File $probe (Join-Path $hookWt 'schema') $hookGitDir `
        (Join-Path $PSScriptRoot 'gate\detect.ps1') 2>&1 | Out-String)
    # .Trim() first: `$` in a multiline regex matches BEFORE the newline but `.` still
    # matches the `\r` in front of it, so every captured path ends in a carriage return.
    $norm = { param($p) ($p.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
    $wtPath = & $norm (Resolve-Path $hookWt).Path
    $rawTop = & $norm ([regex]::Match($hookOut, '(?m)^raw=(.*)$').Groups[1].Value)
    $gateTop = & $norm ([regex]::Match($hookOut, '(?m)^gate=(.*)$').Groups[1].Value)
    Check 'the hook environment really does break bare `rev-parse --show-toplevel`' `
        ($rawTop -eq "$wtPath\schema") "raw=$rawTop"
    Check 'the repo root resolves to the worktree root with GIT_DIR exported' `
        ($gateTop -eq $wtPath) "gate=$gateTop want=$wtPath"

    # ...and the symptom itself: the proto phase run from a subdirectory of a linked
    # worktree, in that same environment, must not hand buf a baseline under the
    # subdirectory. Asserted on the failure text rather than only on the exit code, so
    # an unrelated red phase cannot be mistaken for this bug being fixed.
    $bufProbe = Join-Path $tmp 'hookenv-buf.ps1'
    [IO.File]::WriteAllText($bufProbe, @'
param([string]$Sub, [string]$GitDir, [string]$Check)
$env:GIT_DIR = $GitDir
Set-Location $Sub
& pwsh -NoProfile -File $Check -Only proto -Full
'@)
    $bufOut = (& pwsh -NoProfile -File $bufProbe (Join-Path $hookWt 'schema') $hookGitDir `
        (Join-Path $PSScriptRoot 'gate\check.ps1') 2>&1 | Out-String)
    Check 'buf breaking gets a real baseline from inside a hook in a worktree' `
        ($bufOut -notmatch 'could not clone') ($bufOut -replace "`r?`n", ' | ')
}

# Concurrent commits in one worktree. Git serialises the final write, but it does not
# protect the INDEX while a hook runs, and this hook runs for 40 seconds to five
# minutes -- the gate is what widens the window from milliseconds to minutes. Measured
# on git 2.53: A staged a.txt and began committing, B ran `git add b.txt` during A's
# hook, and A's commit shipped b.txt inside it while B was told `nothing to commit,
# working tree clean` -- a message shaped like success for work just swallowed.
# `.git/index.lock` does not exist during the hook, so there is nothing to poll.
$cc = Join-Path $tmp 'concurrent'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $cc -Recurse
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $cc
git -C $cc init -q 2>$null
& pwsh -NoProfile -File $installer -Target $cc *> $null
git -C $cc add -A 2>$null
git -C $cc -c user.email=selftest@local -c user.name=selftest commit -qm base --no-verify *> $null
Set-Content (Join-Path $cc 'a.txt') 'a'
git -C $cc add a.txt 2>$null
$ccBefore = (git -C $cc rev-parse HEAD)
$ccJob = Start-Job -ScriptBlock { param($r)
    git -C $r -c user.email=a@local -c user.name=a commit -m 'A' 2>&1 | Out-String
} -ArgumentList $cc
Start-Sleep -Milliseconds 1500
# If the gate already finished there was no race to observe, and asserting anything
# about one would be asserting nothing. Skipped out loud rather than counted.
$ccRacing = ($ccJob.State -eq 'Running')
if ($ccRacing) {
    Set-Content (Join-Path $cc 'b.txt') 'b'
    git -C $cc add b.txt 2>$null
}
$ccOut = (Receive-Job -Job $ccJob -Wait | Out-String)
Remove-Job $ccJob
if ($ccRacing) {
    Check 'a commit whose staged files changed under it is refused' `
        (((git -C $cc rev-parse HEAD) -eq $ccBefore) -and ($ccOut -match 'staged files changed while the gate was running')) $ccOut
} else {
    Write-Output '[skip] the gate finished before a second stage could race it'
}
# ...and it must be silent outside a commit: `qgate` in a terminal while the developer
# stages files is not a race, and git sets GIT_INDEX_FILE only for its own hooks. This
# is the half that keeps the guard from becoming a reason nobody can commit.
$r = Invoke-Gate $cc
Check 'the concurrency guard is silent outside a commit' ($r.Out -notmatch 'staged files changed') $r.Out

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
    if ($fullGreen) {
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All -Full 2>&1 | Out-String)
        Check 'a matching pin does not fail the full level' (($LASTEXITCODE -eq 0) -and ($out -notmatch 'pins')) $out
    } else {
        Write-Output '[skip] no green -Full run here -- a check asserting one cannot be judged'
    }
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
# These assertions used to be made against a LIVE run and were not sound. Two of them
# went red on a perfectly healthy gate whenever the registry was unreachable --
# measured, same commit and same machine minutes apart: 118/118, then 116/118. They
# also depended, silently, on THIS machine's cargo happening to be behind, so an
# up-to-date cargo failed them exactly as an outage did. And the first one passed
# OFFLINE for no reason at all: an absent [OUTDATED] satisfies its -notmatch whether a
# live deferral hid the finding or the network simply never produced one.
#
# So the contract is pinned to fixed inputs. The seam is the cache: outdated writes one
# [OUTDATED] line per finding to a per-repo file in TEMP, and -Summary is the only
# caller allowed to answer from it, so seeding that file fixes BOTH halves of the
# input -- installed version and latest version -- with no registry in the loop.
function Set-Deferrals([string]$RepoRoot, [string]$Json) {
    $f = Join-Path $RepoRoot 'qgate.deferrals.json'
    [IO.File]::WriteAllText($f, $Json)
    # Backdated on purpose: the cache is trusted only while it is STRICTLY newer than
    # every manifest, and two writes in the same instant are not strictly ordered.
    (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-5)
}
function Set-OutdatedCache([string]$RepoRoot, [string[]]$Lines) {
    Set-Content -Path (Join-Path ([IO.Path]::GetTempPath()) `
        "quality-gate-outdated-$(Get-PathKey (Resolve-Path $RepoRoot).Path).txt") -Value ($Lines -join "`n")
}
function Get-Summary([string]$RepoRoot) {
    (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $RepoRoot -Summary 2>&1 | Out-String)
}
$fixedFinding = '[OUTDATED] tool rust/cargo 1.0.0 -> 2.0.0'

Set-Deferrals $def '{"dependencies":[]}'
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
Check 'a finding with no deferral is reported' `
    (($s -match 'dependency update\(s\) available') -and ($s -notmatch 'have expired')) $s

Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$future`",`"reason`":`"waiting on the edition bump`"}]}"
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
Check 'a live deferral hides the finding' `
    (($s -notmatch 'dependency update\(s\) available') -and ($s -notmatch 'have expired')) $s

Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$past`",`"reason`":`"was waiting on the edition bump`"},{`"name`":`"nodate`",`"reason`":`"missing until`"}]}"
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
# Both halves in one run: the expiry is announced AND the finding it was hiding is
# back. An implementation that printed the marker and went on suppressing the finding
# would satisfy either half alone.
Check 'an expired deferral is reported and its finding comes back' `
    (($s -match 'deferral\(s\).*have expired') -and ($s -match 'dependency update\(s\) available')) $s
# Printed ahead of the cache branch, so it must survive the path the pre-commit run
# actually takes -- this used to be asserted only against the live report.
Check 'a deferral without until is a warning, not a silent skip' ($s -match "entry for 'nodate' needs 'until'") $s

# The live path is still worth one smoke test -- a real registry answer flowing into a
# real deferral is not what the cache path proves -- but only when its subject exists.
# The precondition is checked out loud instead of being assumed: neither the registry
# being up nor this machine's cargo being behind is anything this suite arranges.
Set-Deferrals $def '{"dependencies":[]}'
$live = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def 2>&1 | Out-String)
Check 'qgate outdated never fails, deferrals included' ($LASTEXITCODE -eq 0) $live
if ($live -match '\[OUTDATED\] tool rust/cargo') {
    Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$past`",`"reason`":`"was waiting on the edition bump`"}]}"
    $live = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def 2>&1 | Out-String)
    Check 'a live registry answer still reaches the deferral logic' `
        (($live -match '\[DEFERRAL EXPIRED\] rust/cargo') -and ($live -match '\[OUTDATED\] tool rust/cargo')) $live
} else {
    Write-Output '[skip] no live rust/cargo finding to defer -- registry unreachable, or this cargo is current'
}

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
if ($fullGreen) {
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
} else {
    Write-Output '[skip] no green -Full run here -- checks asserting one cannot be judged'
}

# 28. Issue #3 again, through a different door: `-Only <stack the gate does not
# implement>` printed [SKIP] not implemented and exited 0 -- a green pipeline over
# zero checks, which is the exact thing `-Only nonsense` was made fatal for. It has
# no branch of its own any more; the zero-phase invariant below is what fails it.
# Copied OUT of this repository on purpose. The fixture directory itself sits inside a
# git work tree, which is the base stack's marker -- base would then run real phases
# here and the run would no longer be the empty one these checks are about. The
# invariant is what is under test; base has its own section below.
$py = Join-Path $tmp 'python'
Copy-Item (Join-Path $PSScriptRoot 'testdata\python-fixture') $py -Recurse
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
# ...and the free pass itself stays -- but it is now about a directory that is not a
# git work tree. A repo with no marker file has the base stack (section 37), whose
# marker IS the repository, so `no known stack found` there would be a lie.
$bareNoGit = Join-Path $tmp 'nostack-nogit'
New-Item -ItemType Directory -Path $bareNoGit | Out-Null
$out = (& pwsh -NoProfile -File $gate -Root $bareNoGit -Full 2>&1 | Out-String)
Check 'a directory with no marker file is still skipped, not failed' `
    (($LASTEXITCODE -eq 0) -and ($out -match '\[SKIP\] no known stack found')) $out
# In a repository the same absence of markers is the base stack instead, and a green,
# zero-cost run there is a run that named every phase it did not perform.
# -All, because $bare is clean and the fast lane's own `[SKIP] no changes` would exit
# before any stack ran -- which would prove nothing about which stacks are there.
$out = (& pwsh -NoProfile -File $gate -Root $bare -All -Full 2>&1 | Out-String)
Check 'a repo with no marker file gets base, not "no known stack"' `
    (($LASTEXITCODE -eq 0) -and ($out -match 'base \(git work tree\)') -and ($out -notmatch 'no known stack found')) $out

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

# 35. Custom checks the repository declares in its own qgate.json. They are arbitrary
# command lines out of a file in the working tree, so the whole feature stands on the
# trust gate: nothing runs until somebody on this machine has read the commands. The
# store is a per-user file, so LOCALAPPDATA is redirected for the whole block -- a
# self-test that wrote into the developer's real trust store would be doing to them
# exactly what the trust gate exists to prevent.
$cust = Join-Path $tmp 'custom'
New-Item -ItemType Directory -Path $cust | Out-Null
$custJson = Join-Path $cust 'qgate.json'
$priorLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $tmp 'trusthome'
# ...and QGATE_HOME, which OVERRIDES that redirect: on a machine where it is set, every
# check below would otherwise be writing into the developer's real trust store, which
# is precisely what redirecting LOCALAPPDATA exists to prevent.
$priorQGate = $env:QGATE_HOME
$env:QGATE_HOME = $null
function Invoke-Trust([string]$Repo, [switch]$Remove) {
    (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\trust.ps1') -Root $Repo -Remove:$Remove 2>&1 | Out-String)
}
try {
    # `fast` runs at both levels, `full` (the default) only under -Full -- the same
    # split every other phase uses.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"quick","run":"exit 0","level":"fast"},{"name":"heavy","run":"exit 0"}]}')
    $r = Invoke-Gate $cust
    Check 'a declared check does not run until the repo is trusted' `
        (($r.Code -eq 0) -and ($r.Out -match '\[SKIP\] custom -- untrusted qgate\.json checks \(run: qgate trust\)')) $r.Out
    # The absence half, and it is the whole rule: an untrusted repo is a [SKIP], never a
    # [FAIL]. Refusing to run a command is not a verdict on the code, and a repository
    # nobody has trusted yet must not be one nobody can commit to -- including through
    # the zero-phase invariant, which this is the third documented exemption from.
    Check 'an untrusted repo is skipped, not failed' ($r.Out -notmatch '\[FAIL\]') $r.Out

    # `qgate trust` is the one place the exact command is shown to the person allowing
    # it, so printing a summary instead of the string would defeat the whole gate.
    $t = Invoke-Trust $cust
    Check 'qgate trust prints every check and the store it writes' `
        (($t -match '(?m)^\s+quick\b') -and ($t -match '(?m)^\s+exit 0\s*$') -and ($t -match 'trusted\.json')) $t
    $r = Invoke-Gate $cust
    Check 'a trusted check runs and passes' (($r.Code -eq 0) -and ($r.Out -match '\[PASS\] quick')) $r.Out
    Check 'a full-level check is not run in the fast lane' `
        (($r.Out -match '\[SKIP\] heavy -- level full') -and ($r.Out -notmatch '\[PASS\] heavy')) $r.Out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -All -Full 2>&1 | Out-String)
    Check 'a full-level check runs at the full level' `
        (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] heavy')) $out
    # `custom` is a stack like any other, or -Only would be a documented flag that
    # cannot name it.
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -Only 'custom' -Full 2>&1 | Out-String)
    Check '-Only custom selects the stack' (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] custom')) $out

    # Trust is a hash of the checks, so editing the command re-arms the gate. This is
    # the case the feature exists to survive: a pull, a branch switch or a teammate
    # changing `run` under a repo that was trusted yesterday.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"quick","run":"exit 1","level":"fast"},{"name":"heavy","run":"exit 0"}]}')
    $r = Invoke-Gate $cust
    Check 'editing the run string of a trusted check revokes the trust' `
        (($r.Code -eq 0) -and ($r.Out -match 'untrusted qgate\.json checks')) $r.Out
    # ...and the edited command really did not run: a revocation that still executed it
    # would satisfy the line above and be worth nothing.
    Check 'the edited command is not executed' ($r.Out -notmatch '\[(PASS|FAIL)\] quick') $r.Out

    # A non-zero exit is the finding, and the output plus the command line is what a
    # reader acts on -- no other phase's output has to name the tool that produced it.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"boom","run":"Write-Output the-real-reason; exit 3","level":"fast"}]}')
    Invoke-Trust $cust | Out-Null
    $r = Invoke-Gate $cust
    Check 'a check that exits non-zero fails the gate under its own name' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] boom') -and ($r.Out -match 'the-real-reason') -and
            ($r.Out -match 'run: Write-Output the-real-reason; exit 3')) $r.Out

    # A command that never comes back is not a command that failed, and the raw output
    # cannot tell them apart: a killed process usually printed nothing at all.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"hang","run":"Start-Sleep 30","level":"fast","timeoutSec":1}]}')
    Invoke-Trust $cust | Out-Null
    $r = Invoke-Gate $cust
    Check 'a check that outruns its timeout is killed and named as a timeout' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] hang -- timeout after 1s')) $r.Out

    # A command that exits 0 while a process it started keeps running is a green verdict
    # over a held port, and the orphan -- whose parent is already gone -- is exactly what
    # the .Kill($true) above cannot see. The bystander is started FIRST and is the same
    # executable as the leak: the walk has to match identity, not names, or this process
    # dies with them.
    $bystander = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 90' -PassThru -WindowStyle Hidden
    try {
        [IO.File]::WriteAllText($custJson,
            '{"checks":[{"name":"leaky","run":"Start-Process pwsh -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep 90'' -WindowStyle Hidden; exit 0","level":"fast"}]}')
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        # The count is not pinned: the orphaned pwsh drags its own conhost.exe along, and
        # a walk that dropped that one would be matching on a name again.
        Check 'a check that leaves a process behind fails even though it exited 0' `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] leaky') -and
                ($r.Out -match '\[LEAK\] leaky left \d+ process\(es\) running:')) $r.Out
        # Named by pid, and then actually ended: a report that says `killed` while the
        # process is still holding the port is worth less than no report at all.
        $leakPid = if ($r.Out -match '\[LEAK\][^\r\n]*pid (\d+) pwsh') { [int]$Matches[1] } else { 0 }
        Check 'the leaked process is named by pid and is gone after the run' `
            (($leakPid -gt 0) -and ($r.Out -match ' -- killed') -and
                (-not (Get-Process -Id $leakPid -ErrorAction SilentlyContinue))) $r.Out
        Check 'a process the gate did not start is left alone' `
            (-not $bystander.HasExited) "bystander pid $($bystander.Id)"

        # ...and a repository that leaves nothing behind reads exactly as it did before:
        # a cleanup that reported on every ordinary run would be noise nobody can act on.
        [IO.File]::WriteAllText($custJson, '{"checks":[{"name":"tidy","run":"exit 0","level":"fast"}]}')
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        Check 'a check that leaves nothing behind still passes, with no leak line' `
            (($r.Code -eq 0) -and ($r.Out -match '\[PASS\] tidy') -and ($r.Out -notmatch 'LEAK')) $r.Out
    } finally { try { $bystander.Kill() } catch { } }

    # Malformed checks are a [FAIL] with the specific reason, never a silent absence:
    # a config that reads as enforcement and does nothing is the oldest defect in this
    # file. Trusted first, so the verdict cannot be standing on the trust gate instead.
    foreach ($case in @(
            @{ Json = '{"checks":[{"name":"Bad Name","run":"exit 0"}]}'; Match = 'no usable name' },
            @{ Json = '{"checks":[{"name":"a","run":"exit 0"},{"name":"a","run":"exit 0"}]}'; Match = "two checks named 'a'" },
            @{ Json = '{"checks":[{"name":"a"}]}'; Match = 'needs a non-empty' },
            @{ Json = '{"checks":[{"name":"a","run":"exit 0","level":"sometimes"}]}'; Match = 'must be fast or full' },
            @{ Json = '{"checks":"not an array"}'; Match = 'must be an array' })) {
        [IO.File]::WriteAllText($custJson, $case.Json)
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        Check "malformed checks fail with the reason: $($case.Match)" `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] custom') -and ($r.Out -match [regex]::Escape($case.Match))) $r.Out
    }

    # ...and the two shapes that are simply absence, or every repository that pins a
    # tool version would grow a stack it never asked for.
    [IO.File]::WriteAllText($custJson, '{"tools":{"go":"1.0.0"},"checks":[]}')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -All -Why 2>&1 | Out-String)
    Check 'an empty checks array is no stack at all' `
        (($out -match '\[WHY\] custom -- absent') -and ($out -notmatch '\[FAIL\] custom')) $out

    # QGATE_HOME: the state directory moves off the system drive, so reinstalling the
    # machine does not take what it trusts with it. Redirected here for the same reason
    # LOCALAPPDATA above is.
    $priorQHome = $env:QGATE_HOME
    try {
        [IO.File]::WriteAllText($custJson, '{"checks":[{"name":"quick","run":"exit 0","level":"fast"}]}')
        $legacyStore = Join-Path $env:LOCALAPPDATA 'qgate\trusted.json'
        $env:QGATE_HOME = $null
        $t = Invoke-Trust $cust
        Check 'without QGATE_HOME the trust store stays at the platform default' `
            ($t -match [regex]::Escape($legacyStore)) $t

        # An empty new store is not a neutral starting point: every repository trusted
        # yesterday silently stops running its own checks, and a phase that stopped
        # running reads exactly like a phase that passed. So the legacy file is copied
        # across on first use, and said out loud.
        $qh = Join-Path $tmp 'qgatehome'
        New-Item -ItemType Directory -Path $qh | Out-Null
        $env:QGATE_HOME = $qh
        $newStore = Join-Path $qh 'trusted.json'
        $r = Invoke-Gate $cust
        Check 'a QGATE_HOME with no store yet inherits the legacy one instead of dropping the trust' `
            ((Test-Path $newStore) -and
                ((Get-Content $newStore -Raw) -eq (Get-Content $legacyStore -Raw)) -and
                ($r.Out -match 'copied the trust store') -and ($r.Out -match '\[PASS\] quick')) $r.Out

        # ...and from there on QGATE_HOME is the store, not a copy nobody writes to.
        [IO.File]::WriteAllText($custJson,
            '{"checks":[{"name":"quick","run":"exit 0","level":"fast"},{"name":"moved","run":"exit 0","level":"fast"}]}')
        $t = Invoke-Trust $cust
        $r = Invoke-Gate $cust
        Check 'QGATE_HOME is where the trust store is read and written' `
            (($t -match [regex]::Escape($newStore)) -and ($r.Out -match '\[PASS\] moved') -and
                ((Get-Content $newStore -Raw) -ne (Get-Content $legacyStore -Raw))) "$t $($r.Out)"
    } finally { $env:QGATE_HOME = $priorQHome }
} finally { $env:LOCALAPPDATA = $priorLocal; $env:QGATE_HOME = $priorQGate }

# 36. The C/C++ CMake stack. Its two halves ask different tools -- clang-format for the
# format phase, cmake for configure and build -- and neither is on every machine, so
# every check here either asserts what the gate does WITHOUT the tool, or is guarded
# the way the gdtoolkit ones above are.
$cpp = Join-Path $tmp 'cpp'
Copy-Item (Join-Path $PSScriptRoot 'testdata\cpp-fixture') $cpp -Recurse
# A cmake run against this repository leaves testdata/cpp-fixture/build/ behind. It is
# gitignored, Copy-Item -Recurse does not care, and CMakeCache.txt records the ABSOLUTE
# path it was generated for -- so the copy failed `configure` with "the current
# CMakeCache.txt directory is different", on a fixture nobody had touched. Invisible
# until cmake was on PATH, which is the machine this suite is supposed to be honest on.
Remove-Item (Join-Path $cpp 'build') -Recurse -Force -ErrorAction SilentlyContinue

# A build tree is CMake's own output -- it carries a CMakeLists.txt for every
# dependency it fetched, and the next configure run deletes the lot. A CMakeLists.txt
# BELOW one that was already detected is add_subdirectory() material: the top one
# configures it too, so a second stack would configure and build the same code twice.
$cppTree = Join-Path $tmp 'cpp-tree'
foreach ($sub in '', 'build', 'out', '_deps', 'cmake-build-debug', 'src\engine') {
    $d = if ($sub) { Join-Path $cppTree $sub } else { $cppTree }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content (Join-Path $d 'CMakeLists.txt') 'project(x)'
}
$cppStacks = @(Get-Stacks $cppTree | Where-Object { $_.Stack -eq 'cpp' })
Check 'only the topmost CMakeLists.txt of a tree is a stack' `
    (($cppStacks.Count -eq 1) -and ($cppStacks[0].Rel -eq '')) `
    (($cppStacks | ForEach-Object { "cpp '$($_.Rel)'" }) -join ' | ')
# ...and "topmost per TREE" is not "one per repository". Without this half, a rule that
# detected nothing at all below the root would satisfy the check above.
$cppTwo = Join-Path $tmp 'cpp-two'
foreach ($sub in 'a', 'b') {
    New-Item -ItemType Directory -Path (Join-Path $cppTwo $sub) -Force | Out-Null
    Set-Content (Join-Path $cppTwo "$sub\CMakeLists.txt") 'project(x)'
}
$cppRels = @(Get-Stacks $cppTwo | Where-Object { $_.Stack -eq 'cpp' }).Rel
Check 'two sibling CMake projects are two stacks' `
    ((($cppRels | Sort-Object) -join ',') -eq 'a,b') "got: $($cppRels -join ',')"

# No .clang-format: the gate has no style to check the sources against, and it neither
# invents one nor stays quiet about the phase it therefore did not run.
$r = Invoke-Gate $cpp
Check 'format is skipped when there is no .clang-format' `
    ($r.Out -match '\[SKIP\] format -- no \.clang-format') $r.Out

$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -Only cpp 2>&1 | Out-String)
Check '-Only cpp selects the stack' `
    (($out -notmatch 'no such stack detected') -and ($out -match 'cpp \(CMakeLists\.txt\)')) $out

Set-Content (Join-Path $cpp '.clang-format') 'BasedOnStyle: LLVM'
[IO.File]::WriteAllText((Join-Path $cpp 'src\ugly.cpp'), "int  ugly( ) {return    0;}`n")
$r = Invoke-Gate $cpp
if (Get-Command clang-format -ErrorAction SilentlyContinue) {
    Check 'clang-format fails the gate on a misformatted source' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] format') -and ($r.Out -match 'ugly\.cpp')) $r.Out
} else {
    # Nothing was checked, and "not checked" must never read as "clean" -- the same
    # rule the [UNKNOWN] lines elsewhere in this gate exist for.
    Check 'a missing clang-format is named, not silently passed' `
        ($r.Out -match '\[SKIP\] format -- clang-format not found') $r.Out
}
# It has served its purpose, and every later run over this fixture is about something
# else -- a stack the gate selects, a tool it cannot find. Left in place, on a machine
# that HAS clang-format those runs came back `[FAIL] format` and the checks below read
# a red report for a question they never asked.
Remove-Item (Join-Path $cpp 'src\ugly.cpp') -Force

# cmake is on this machine or it is not, and the gate's answer has to be the same
# either way -- so it is hidden from PATH for the two runs below instead of the suite
# skipping itself on half the machines. Same split the .NET SDK and the Godot binary
# follow: the full level is what guards a commit and CI, so it fails there; the fast
# lane never reaches configure or build, so it only warns.
$priorPath = $env:PATH
$sep = [IO.Path]::PathSeparator
$env:PATH = @($priorPath -split $sep | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'cmake.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cmake') -ErrorAction SilentlyContinue)
    }) -join $sep
try {
    $fast = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -All 2>&1 | Out-String)
    $full = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -All -Full 2>&1 | Out-String)
    $fullCode = $LASTEXITCODE
    Check 'no cmake warns on the fast level, it does not fail there' `
        (($fast -match '\[WARN\] cpp .*cmake not on PATH') -and ($fast -notmatch 'required at the full level')) $fast
    Check 'no cmake fails the full level, with the reason' `
        (($fullCode -ne 0) -and ($full -match 'cmake not on PATH -- required at the full level')) $full
} finally { $env:PATH = $priorPath }

# The two static-analysis phases read their file list out of a compile database, which
# is CMake's answer: it names every translation unit the BUILD compiles, dependencies
# included, and the findings arrive from wherever the preprocessor reached. Both
# conditions of the filter, because either alone lets one of those through -- measured
# on a real repository, half the cppcheck findings came out of SDK headers two
# directories above the project.
$owner = Join-Path $tmp 'cpp'
Check 'the stack own sources are what the analysis phases see' `
    ((Test-CppOwn (Join-Path $owner 'src\greeting.cpp') $owner) -and
    (Test-CppOwn (($owner -replace '\\', '/') + '/src/greeting.cpp') $owner))
Check 'build trees and paths outside the stack are not analysed' `
    (-not ((Test-CppOwn (Join-Path $owner 'build\_deps\zlib\z.c') $owner) -or
        (Test-CppOwn (Join-Path $owner '_deps\zlib\z.c') $owner) -or
        (Test-CppOwn (Join-Path $tmp 'elsewhere\sdk\ngx.h') $owner)))

# A clean copy: the fixture above now carries a .clang-format and a deliberately
# misformatted source, and a failed format phase would leave every phase after it
# reporting "not run" -- which is not what these checks are about.
$cppAn = Join-Path $tmp 'cpp-analysis'
Copy-Item (Join-Path $PSScriptRoot 'testdata\cpp-fixture') $cppAn -Recurse
Remove-Item (Join-Path $cppAn 'build') -Recurse -Force -ErrorAction SilentlyContinue
# bugprone-incorrect-roundings in the stack's own source, bugprone-branch-clone in a
# dependency the build compiles: one has to be reported and the other has to not be.
[IO.File]::WriteAllText((Join-Path $cppAn 'src\rounding.cpp'), "int qgate_round(double x) { return (int)(x + 0.5); }`n")
New-Item -ItemType Directory -Path (Join-Path $cppAn '_deps\vendor') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $cppAn '_deps\vendor\vendor.cpp'), "int qgate_pick(int c) { if (c) { return 7; } else { return 7; } }`n")
# Leading newline: the fixture's last line has none, and cmake answers an appended
# command with `Parse error. Expected a newline`.
Add-Content (Join-Path $cppAn 'CMakeLists.txt') "`ntarget_sources(qgate_fixture PRIVATE src/rounding.cpp _deps/vendor/vendor.cpp)"

# Neither phase runs on the fast lane. They cost tens of seconds on a real tree (26.7s
# for clang-tidy over 22 translation units), and a fast lane that pays that on every
# commit is a fast lane people stop running -- the same split configure and build take.
$r = Invoke-Gate $cppAn
Check 'tidy and cppcheck are full-level only' `
    (($r.Out -notmatch '\btidy\b') -and ($r.Out -notmatch '\bcppcheck\b')) $r.Out

# Neither tool is on every machine, and "not checked" must never read as "clean".
$priorPath = $env:PATH
$env:PATH = @($priorPath -split $sep | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'clang-tidy.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'clang-tidy') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cppcheck.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cppcheck') -ErrorAction SilentlyContinue)
    }) -join $sep
try {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cppAn -All -Full 2>&1 | Out-String)
    Check 'a missing clang-tidy is named, not silently passed' `
        ($out -match '\[SKIP\] tidy -- clang-tidy not found') $out
    Check 'a missing cppcheck is named, not silently passed' `
        ($out -match '\[SKIP\] cppcheck -- cppcheck not found') $out
} finally { $env:PATH = $priorPath }

# The findings themselves, where the tools exist. clang-tidy needs a compile database,
# and on Windows the default generator is a Visual Studio one, which ignores
# CMAKE_EXPORT_COMPILE_COMMANDS -- the gate configures a throwaway Ninja tree with
# clang-cl to get one, so this needs those two as well.
$cdbOk = (Get-Command ninja -ErrorAction SilentlyContinue) -and (Get-Command clang-cl -ErrorAction SilentlyContinue)
if ((Get-Command clang-tidy -ErrorAction SilentlyContinue) -and ($cdbOk -or -not $IsWindows)) {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cppAn -All -Full 2>&1 | Out-String)
    $code = $LASTEXITCODE
    # First pass over these repositories, exactly as the Roslyn analyzers got in 379f39d:
    # the volume is reported and nothing goes red on it. A rule that fails a commit
    # before anybody has read it is a rule people route around.
    Check 'clang-tidy findings warn, they do not fail the phase' `
        (($code -eq 0) -and ($out -match '\[WARN\] tidy: \d+ finding\(s\).*bugprone-incorrect-roundings') -and
        ($out -match '\[PASS\] tidy')) "code=$code $out"
    # ...and the dependency's own defect is the build's business, not this repository's.
    Check 'a _deps source the build compiles is not analysed' `
        ($out -notmatch 'bugprone-branch-clone') $out
}

# 37. The base stack: the one with no marker file. Every git work tree has it, all
# three of its tools are optional external binaries, and none of them is on every
# machine -- so every check here either strips the tools from PATH itself or asserts
# something true whether or not they are installed.
$baseRepo = Join-Path $tmp 'base'
New-Item -ItemType Directory -Path $baseRepo | Out-Null
git -C $baseRepo init -q 2>$null
$baseStacks = @(Get-Stacks $baseRepo)
# Both halves: base is there with no marker file of any kind, and it is the ONLY
# thing there -- "detects every stack everywhere" would satisfy the first half alone.
Check 'base exists in a repo with no marker file at all' `
    ((($baseStacks | ForEach-Object { $_.Stack }) -join ',') -eq 'base') `
    "got: $(($baseStacks | ForEach-Object { $_.Stack }) -join ',')"
# ...and the condition really is the work tree, not "always": a directory that is not
# a repository has no index for the fast secrets scan to read, and it is still the
# documented free pass that section 31 asserts.
$baseNoGit = Join-Path $tmp 'base-nogit'
New-Item -ItemType Directory -Path $baseNoGit | Out-Null
Check 'base does not exist outside a git work tree' `
    (-not (@(Get-Stacks $baseNoGit) | Where-Object { $_.Stack -eq 'base' }))

$gate = Join-Path $PSScriptRoot 'gate\check.ps1'
$out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
$baseOnlyCode = $LASTEXITCODE
Check '-Only base selects the stack' `
    (($out -notmatch 'no such stack detected') -and ($out -match 'base \(git work tree\)')) $out
# ...and a machine with none of the three tools must not turn every repository on it
# into one nobody can commit to. base has no marker file, so it is in EVERY run: the
# zero-phase invariant is exempted only when base was the whole run.
Check 'base alone with nothing to run is not a failed run' ($baseOnlyCode -eq 0) "code=$baseOnlyCode $out"

# ...but -Only cpp must not drag it along. The cpp fixture is made a work tree first,
# or the absence proved here would only be the absence of a git repository.
git -C $cpp init -q 2>$null
$out = (& pwsh -NoProfile -File $gate -Root $cpp -Only cpp 2>&1 | Out-String)
Check '-Only cpp does not run base' (($out -match 'cpp \(CMakeLists\.txt\)') -and ($out -notmatch 'base')) $out

# Each phase names the tool it is missing. Stripped from PATH here rather than skipped
# on half the machines: "the tool is absent" is the gate's answer, and it has to be the
# same answer everywhere. A [SKIP] carrying the name, never a [FAIL] -- the gate does
# not install toolchains.
$priorPath = $env:PATH
$sep = [IO.Path]::PathSeparator
$env:PATH = @($priorPath -split $sep | Where-Object {
        $d = $_
        $d -and -not (@('gitleaks', 'typos', 'osv-scanner') | Where-Object {
                (Test-Path -LiteralPath (Join-Path $d "$_.exe") -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue) })
    }) -join $sep
try {
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
    $noToolCode = $LASTEXITCODE
    Check 'a missing gitleaks is named, not silently passed' `
        ($out -match '\[SKIP\] secrets -- gitleaks not on PATH') $out
    Check 'a missing typos is named, not silently passed' `
        ($out -match '\[SKIP\] typos -- typos not on PATH') $out
    Check 'a missing osv-scanner is named, not silently passed' `
        ($out -match '\[SKIP\] vuln -- osv-scanner not on PATH') $out
    Check 'an absent optional tool is a skip, not a failed run' `
        (($noToolCode -eq 0) -and ($out -notmatch '\[FAIL\]')) "code=$noToolCode $out"
} finally { $env:PATH = $priorPath }

# The vulnerability database lives on the network, so vuln is full-level only -- the
# same rule govulncheck and `npm audit` follow. Asserted on the LINE, not on a verdict:
# whether it passes, skips for a missing binary or skips for an osv-scanner v1 that has
# no `scan source`, the full level says something about vuln and the fast lane does not.
$fast = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base 2>&1 | Out-String)
$full = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
Check 'vuln does not run on the fast lane' ($fast -notmatch 'vuln') $fast
Check 'vuln runs at the full level' ($full -match 'vuln') $full

# typos scopes itself the way every other fast phase does: the whole tree at the full
# level, only what git says changed on the fast lane. Both halves, because "never
# reports anything" would satisfy the fast one on its own.
if (Get-Command typos -ErrorAction SilentlyContinue) {
    $ty = Join-Path $tmp 'typos'
    New-Item -ItemType Directory -Path $ty | Out-Null
    git -C $ty init -q 2>$null
    # Assembled from two halves so the misspelling is never a literal in this file:
    # written out whole it is a real finding in THIS repository, and the gate's own
    # base stack fails on its own test fixture. Silencing it in _typos.toml instead
    # would switch off the word everywhere, which is the opposite of the point.
    $typo = 'rec' + 'ieve'
    [IO.File]::WriteAllText((Join-Path $ty 'committed.txt'), "you will $typo this line`n")
    git -C $ty add -A 2>$null
    git -C $ty -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $ty 'touched.txt'), "this one is spelled correctly`n")
    $out = (& pwsh -NoProfile -File $gate -Root $ty -Only base 2>&1 | Out-String)
    $tyFastCode = $LASTEXITCODE
    Check 'typos on the fast lane judges only the changed files' `
        (($tyFastCode -eq 0) -and ($out -notmatch $typo)) "code=$tyFastCode $out"
    $out = (& pwsh -NoProfile -File $gate -Root $ty -Only base -Full 2>&1 | Out-String)
    $tyFullCode = $LASTEXITCODE
    Check 'typos at the full level judges the whole tree' `
        (($tyFullCode -ne 0) -and ($out -match '\[FAIL\] typos') -and ($out -match 'committed\.txt')) "code=$tyFullCode $out"

    # The invariant the scoping above cannot state on its own: the two lanes must
    # reach the SAME verdict about the same file. typos applies the repository's own
    # _typos.toml excludes when it walks the tree and ignores them for any path named
    # on the command line, so the fast lane -- which narrows to changed paths -- was
    # red on a file the full lane never looked at. Asked as an equality rather than as
    # "the flag is present", because any phase that narrows to changed paths can grow
    # this same divergence with a different tool.
    $tx = Join-Path $tmp 'typos-exclude'
    New-Item -ItemType Directory -Path (Join-Path $tx 'locale') -Force | Out-Null
    git -C $tx init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $tx '_typos.toml'), "[files]`nextend-exclude = [`"locale/*.txt`"]`n")
    [IO.File]::WriteAllText((Join-Path $tx 'locale\fr.txt'), "you will $typo this line`n")
    $txFast = (& pwsh -NoProfile -File $gate -Root $tx -Only base 2>&1 | Out-String)
    $txFastCode = $LASTEXITCODE
    $txFull = (& pwsh -NoProfile -File $gate -Root $tx -Only base -Full 2>&1 | Out-String)
    $txFullCode = $LASTEXITCODE
    Check 'an excluded file gets the same typos verdict on the fast lane and the full one' `
        (($txFastCode -eq $txFullCode) -and ($txFastCode -eq 0) -and
            ($txFast -notmatch $typo) -and ($txFull -notmatch $typo)) `
        "fast=$txFastCode $txFast full=$txFullCode $txFull"
    # ...and the agreement above is not the boring kind. Without the exclusion the same
    # fixture reddens the same lane, so the file really does carry a finding.
    Remove-Item (Join-Path $tx '_typos.toml')
    $txNone = (& pwsh -NoProfile -File $gate -Root $tx -Only base 2>&1 | Out-String)
    Check 'the excluded fixture is green because of the exclusion, not because it is clean' `
        (($LASTEXITCODE -ne 0) -and ($txNone -match '\[FAIL\] typos')) "code=$LASTEXITCODE $txNone"

    # A git hash in prose is not a misspelling. typos splits `6129afe` at the digits and
    # corrects its three-letter tail; the same run reported another such tail inside a
    # go.mod pseudo-version. Every repository puts hashes in docs and lockfiles, so the gate
    # ships the ignore and the fixture asserts BOTH halves: the hash is quiet and a real
    # typo on the same line is still red -- an ignore that swallowed the line would pass
    # the first half alone.
    $th = Join-Path $tmp 'typos-hash'
    New-Item -ItemType Directory -Path $th | Out-Null
    git -C $th init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $th 'plan.md'),
        "see 6129afe and v0.0.0-20250101120000-abc123def456`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check 'a commit hash and a go.mod pseudo-version are not typos' `
        (($LASTEXITCODE -eq 0) -and ($thOut -notmatch 'plan\.md')) "code=$LASTEXITCODE $thOut"
    [IO.File]::WriteAllText((Join-Path $th 'plan.md'),
        "see 6129afe -- you will $typo it`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check 'a real typo beside a hash on the same line is still caught' `
        (($LASTEXITCODE -ne 0) -and ($thOut -match '\[FAIL\] typos') -and ($thOut -match 'plan\.md')) `
        "code=$LASTEXITCODE $thOut"
    # ...and the gate's own config must not evict the repository's. typos merges the two,
    # gitleaks' -c would have replaced the file.
    [IO.File]::WriteAllText((Join-Path $th '_typos.toml'), "[default.extend-words]`n$typo = `"$typo`"`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check "the repository's own _typos.toml still applies with the gate's config passed" `
        (($LASTEXITCODE -eq 0) -and ($thOut -notmatch 'plan\.md')) "code=$LASTEXITCODE $thOut"

    # Encoded bytes are not prose. A vendored mail test fixture reported the same two-letter
    # fragment five times (spelled out here it would redden THIS file, exactly as the gate's
    # own config comment says), every hit a hex pair of a quoted-printable body. All three
    # shapes here, because a different pattern ignores each: the short encoded-word is far
    # below the 48-character base64 threshold and only the RFC 2047 sentinels cover it, and
    # the quoted-printable run also splits a word, so the letters glued to the escapes are
    # part of the encoded run and not a misspelling. Then the same file with a
    # real misspelling in a comment, to prove the exemption is the encoded run and not the
    # line, the string or the file.
    $tb = Join-Path $tmp 'typos-base64'
    New-Item -ItemType Directory -Path $tb | Out-Null
    git -C $tb init -q 2>$null
    $mime = @'
package email

const raw = "" +
	"Subject: =?utf-8?B?eHk5BA3eg==?=\r\n" +
	"Content-Transfer-Encoding: base64\r\n\r\n" +
	"aGVsbG8gd29ybGQgdGhpcyBpcyBhIHZlcnkgbG9uZzBiYXNlNjQgYm9keTBmb3IgdGVzdGluZw5BA3\r\n" +
	"Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
	"=D0=9F=D0=BE=D0=B4=D1=81=D0=BA=D0=B0=D0=B6=D0=B8=D1=82=D0=B5\r\n" +
	"y funcion=C3=B3 de maravilla\r\n"
'@
    [IO.File]::WriteAllText((Join-Path $tb 'imap_test.go'), "$mime`n")
    $tbOut = (& pwsh -NoProfile -File $gate -Root $tb -Only base -Full 2>&1 | Out-String)
    Check 'quoted-printable, base64 and an encoded-word are not typos' `
        (($LASTEXITCODE -eq 0) -and ($tbOut -notmatch 'imap_test\.go')) "code=$LASTEXITCODE $tbOut"
    [IO.File]::WriteAllText((Join-Path $tb 'imap_test.go'), "$mime`n// you will $typo it`n")
    $tbOut = (& pwsh -NoProfile -File $gate -Root $tb -Only base -Full 2>&1 | Out-String)
    Check 'a real typo in a comment beside an encoded body is still caught' `
        (($LASTEXITCODE -ne 0) -and ($tbOut -match '\[FAIL\] typos') -and
            ($tbOut -match 'imap_test\.go')) "code=$LASTEXITCODE $tbOut"

    # A repository that never had a dictionary reports hundreds of findings on its first
    # run -- 387 measured on a game mod, 34630 chars -- and the report's 6000-char cap cut
    # that to a prefix and a byte count, never the total. typos walks the tree in parallel,
    # so the surviving prefix differed between runs on the same tree and a pre-commit hook
    # needed several of them to see one list. The phase counts and sorts for itself now.
    $tm = Join-Path $tmp 'typos-many'
    New-Item -ItemType Directory -Path $tm | Out-Null
    git -C $tm init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $tm 'notes.md'),
        ((1..25 | ForEach-Object { "line $_ you will $typo it" }) -join "`n") + "`n")
    $tmOut = (& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String)
    $tmCode = $LASTEXITCODE
    $tmHits = @($tmOut -split "`r?`n" | Where-Object { $_ -match ':\d+:\d+: ' })
    Check 'a flood of typos reports its real total and shows twenty' `
        (($tmCode -ne 0) -and ($tmHits.Count -eq 20) -and
            ($tmOut -match 'typos: 25 finding\(s\) in 1 file\(s\) -- showing first 20') -and
            ($tmOut -match 'full list: typos --format brief')) "code=$tmCode $tmOut"
    # The shown twenty must be the SAME twenty next run -- the half a byte cap could never
    # give, because the parallel walk made the surviving prefix a lottery.
    $tmAgain = @((& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String) -split "`r?`n" |
            Where-Object { $_ -match ':\d+:\d+: ' })
    Check 'the shown findings are the same list on a second run' `
        ((($tmHits -join "`n") -eq ($tmAgain -join "`n")) -and ($tmHits.Count -eq 20)) `
        "run1=$($tmHits -join '|') run2=$($tmAgain -join '|')"
    # ...and a handful still prints in full: the summary is for a flood, not for every run.
    [IO.File]::WriteAllText((Join-Path $tm 'notes.md'), "you will $typo it`n")
    $tmFew = (& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String)
    Check 'a couple of findings still print in full, with no summary line' `
        (($LASTEXITCODE -ne 0) -and ($tmFew -notmatch 'showing first 20') -and
            ($tmFew -match 'notes\.md')) "code=$LASTEXITCODE $tmFew"
} else {
    Write-Output '[skip] typos not on PATH -- its fast/full scoping cannot be judged here'
}

# 38. secrets. Measured across nine real repositories, the phase reported 51 findings
# and every one was false -- so the two questions here are "does it still catch a real
# secret" and "has it stopped failing repositories over files git cannot commit".
#
# The planted token is assembled from two halves for the same reason the typo above is:
# written out whole it is a real finding in THIS repository, and the gate's own base
# stack goes red on its own test fixture.
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    $sec = Join-Path $tmp 'secrets'
    New-Item -ItemType Directory -Path (Join-Path $sec 'vendor') -Force | Out-Null
    git -C $sec init -q 2>$null
    $pat = 'ghp_' + 'S8kQ2mVx7bTnR4wLzYe1CdHu6JaGpF0iNoBq'
    # A file named by .gitignore inside a TRACKED directory. This is the case that made
    # the gate unusable: GOwebserver ignores `config.json` by name, that file holds a
    # real jwt_secret, and the run failed over it -- red, correct about the string, and
    # green-able by no action anyone could take. Filtering by directory could never see
    # it, because the directory is the repository root.
    [IO.File]::WriteAllText((Join-Path $sec '.gitignore'), "config.json`nvendor/`n")
    [IO.File]::WriteAllText((Join-Path $sec 'config.json'), "{ `"github_token`": `"$pat`" }`n")
    # ...and the directory case the phase already handled, kept asserted so the new
    # filter is not a regression of the old one.
    [IO.File]::WriteAllText((Join-Path $sec 'vendor\dump.json'), "{ `"github_token`": `"$pat`" }`n")
    # Documentation quoting a curl example, and a manifest whose ids look like keys.
    # 51 of the 51 false findings were one of these two shapes.
    [IO.File]::WriteAllText((Join-Path $sec 'API.md'),
        "curl -H `"Authorization: Bearer 0af1c39b7e5d24a8f6b013ce97d5a2b4`" https://example.test/v1`n")
    [IO.File]::WriteAllText((Join-Path $sec 'assets.json'), "{ `"key`": `"c7a9f1d24b6e4a3c8f5b7d1e9a2c4b60`" }`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    $secCode = $LASTEXITCODE
    Check 'a secret in a gitignored FILE inside a tracked directory does not fail the gate' `
        (($secCode -eq 0) -and ($out -notmatch 'config\.json') -and ($out -notmatch 'dump\.json')) `
        "code=$secCode $out"
    Check 'a curl example and an asset manifest are not secrets' `
        (($out -notmatch 'API\.md') -and ($out -notmatch 'assets\.json')) $out
    # The green above must be the filter's doing, not a phase that stopped looking. The
    # same token, same repository, in a file nothing ignores.
    [IO.File]::WriteAllText((Join-Path $sec 'app.env'), "GITHUB_TOKEN=$pat`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    $secCode = $LASTEXITCODE
    Check 'a real token in a tracked file still fails the gate' `
        (($secCode -ne 0) -and ($out -match '\[FAIL\] secrets') -and ($out -match 'app\.env') -and
            ($out -match 'github-pat')) "code=$secCode $out"
    # ...and it names only that file: the ignored copies of the identical token must not
    # ride along on a run that was going to be red anyway.
    Check 'the failing run still says nothing about the ignored copies' `
        (($out -notmatch 'config\.json') -and ($out -notmatch 'dump\.json')) $out
    # The fingerprint on that line is what the fix: hint tells the reader to commit to
    # .gitleaksignore, so it must not carry this machine's checkout path -- a teammate and
    # CI resolve the repository somewhere else, and an absolute fingerprint suppresses the
    # finding for exactly one person. Asserted as "no drive letter, nothing of $sec in it",
    # and then as the thing the hint actually promises: that line, committed, takes the
    # same run to green.
    $fp = (($out -split "`n" | Select-String 'app\.env:.*github-pat -- ' | Select-Object -First 1) -split ' -- ')[-1].Trim()
    Check 'the printed fingerprint is repo-relative, not a path on this machine' `
        ($fp -and ($fp -notmatch '^[A-Za-z]:') -and ($fp -notmatch [regex]::Escape($sec)) -and
            ($fp -like 'app.env:github-pat:*')) "fingerprint=$fp"
    [IO.File]::WriteAllText((Join-Path $sec '.gitleaksignore'), "$fp`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    Check 'that fingerprint in .gitleaksignore suppresses the finding' `
        (($LASTEXITCODE -eq 0) -and ($out -notmatch 'app\.env')) "code=$LASTEXITCODE $out"
} else {
    Write-Output '[skip] gitleaks not on PATH -- the secrets filter cannot be judged here'
}

# 39. The web stack linted, type-checked, built and audited -- and never ran the
# test script the repository itself declares, so a project whose suite was red went
# through the gate green. The two halves: a declared `test` that exits non-zero must
# be the thing that fails the full run, and a project that declares none must be
# exactly as silent as it was before.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $wt = Join-Path $tmp 'webtest'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wt -Recurse
    New-Item -ItemType Directory -Path (Join-Path $wt 'node_modules\.bin') -Force | Out-Null
    # No eslint/stylelint config, no tsconfig: `build` and `test` are the only phases
    # this fixture has, which is what makes the failure attributable to one of them.
    [IO.File]::WriteAllText((Join-Path $wt 'package.json'),
        '{"name":"webtest","private":true,"type":"module","scripts":{"build":"node -e \"process.exit(0)\"","test":"node -e \"process.exit(1)\""}}')
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Full 2>&1 | Out-String)
    $wtCode = $LASTEXITCODE
    Check 'a failing npm test script fails the full gate' `
        (($wtCode -ne 0) -and ($out -match '(?m)^\[FAIL\] test\b')) "code=$wtCode $out"
    # ...and it is the test step that is named. A red `build` line here would be the
    # same exit code standing on a different reason.
    Check 'the failure names the test step, not the build' `
        (($out -notmatch '(?m)^\[FAIL\] build') -and ($out -match '(?m)^\[PASS\] build')) $out
    # The fast lane runs on every agent turn and never promised the expensive phases.
    # This fixture's test script is red, so a fast run that touched it could not stay
    # quiet about it.
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Fast 2>&1 | Out-String)
    Check 'the fast lane does not run the test script' ($out -notmatch '(?m)^\[(PASS|FAIL)\] test\b') $out
    # No `test` declared: nothing to ask, nothing said, same verdict as before.
    [IO.File]::WriteAllText((Join-Path $wt 'package.json'),
        '{"name":"webtest","private":true,"type":"module","scripts":{"build":"node -e \"process.exit(0)\""}}')
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Full 2>&1 | Out-String)
    $wtCode = $LASTEXITCODE
    Check 'a web project that declares no test script is unaffected' `
        (($wtCode -eq 0) -and ($out -notmatch '(?m)^\[(PASS|FAIL)\] test\b')) "code=$wtCode $out"
} else {
    Write-Output '[skip] npm not on PATH -- the web test phase cannot be judged here'
}

Remove-Item $tmp -Recurse -Force
if ($script:Fails) { Write-Output "`n$($script:Fails) of $($script:Total) check(s) failed"; exit 1 }
Write-Output "`nall checks passed ($($script:Total)/$($script:Total))"
