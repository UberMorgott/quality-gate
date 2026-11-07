# Harmony patch targets that no longer exist -- the defect a game update leaves behind in a
# BepInEx mod: `[HarmonyPatch(typeof(Hud), "UpdateStatusEffects")]` compiles (it is a string)
# and fails only at runtime, as a Harmony exception or a feature that silently stops working.
#
# Called by check.ps1 after a successful `build`, at the full level, for a project that
# references 0Harmony / Lib.Harmony / HarmonyX. The checker (harmony.cs) reads metadata only;
# no game code is loaded. Prints one line per dangling target and exits 1 when there are any.
# `[WARN] harmony: ...` (a null-checked probe, another assembly's finding) and the per-assembly
# `[NOTE] harmony: ...` count are notes beside the verdict, never a failure.
#
# No maintained Roslyn analyzer covers this (checked 2026-09): BUTR.Harmony.Analyzer checks
# AccessTools strings only and was last released 2023-06; Harmonize checks how a patch is
# spelled, not whether its target exists. So the gate does it after the build, against the
# exact references the compiler resolved.
# -Targets (check.ps1 -Why): also print one `[NOTE] harmony: OK <target> (<source>)` per patch
# whose target DID resolve -- a new hook is confirmed by name, not by a count that went up.
param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Root, [string]$Tfm, [switch]$Targets)

if (-not ('QGateHarmony' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'harmony.cs') }

# The references the compiler actually used (HintPath, packages, publicized copies, the
# framework's own), and the assembly the build just wrote. BuildProjectReferences=false:
# `build` already built them, this only asks where they are.
$msArgs = @($Project, '-t:ResolveReferences', '-getProperty:TargetPath', '-getItem:ReferencePath',
    '-getItem:ProjectReference', '-p:BuildProjectReferences=false', '-nologo')
if ($Tfm) { $msArgs += "-p:TargetFramework=$Tfm" }
$raw = (& dotnet msbuild @msArgs 2>&1 | Out-String)
$info = if ($LASTEXITCODE -eq 0) { try { $raw | ConvertFrom-Json } catch { $null } }
if (-not $info -or -not (Test-Path -LiteralPath $info.Properties.TargetPath)) {
    "harmony: could not resolve the built assembly and its references"
    ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5)
    exit 1
}
$mod = $info.Properties.TargetPath
$refs = @($info.Items.ReferencePath.FullPath)
# A referenced project's own references do not flow into ours (a <Private>false</Private> game
# reference), yet a test project loads that game at run time and looks its types up by name
# (#184): resolve them too, transitively. A project that will not resolve adds nothing.
# shortcut: a multi-targeting referenced project is skipped (no TFM passed); pick its nearest TFM when a repo needs it.
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$queue = [Collections.Generic.Queue[string]]::new()
foreach ($p in @($info.Items.ProjectReference.FullPath)) { if ($p) { $queue.Enqueue($p) } }
while ($queue.Count) {
    $p = $queue.Dequeue()
    if (-not $seen.Add($p)) { continue }
    $sub = try {
        & dotnet msbuild $p -t:ResolveReferences -getItem:ReferencePath -getItem:ProjectReference '-p:BuildProjectReferences=false' -nologo 2>$null |
            Out-String | ConvertFrom-Json
    } catch { $null }
    if (-not $sub) { continue }
    $refs += @($sub.Items.ReferencePath.FullPath)
    foreach ($q in @($sub.Items.ProjectReference.FullPath)) { if ($q) { $queue.Enqueue($q) } }
}
# Our own references first: the checker indexes the first copy of a type it meets.
$uniq = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$refs = @($refs | Where-Object { $_ -and $uniq.Add($_) })

# qgate.json {"harmony": {"assemblies": ["%ValheimDir%\\BepInEx\\plugins\\**\\*.dll"]}}: other
# assemblies checked against the same game -- the plugins installed beside this mod, whose
# broken patches break the same game session. Root-relative or absolute, %VAR% expanded,
# `**` = recursive. Their findings are warnings: not this repository's code.
$extra = @()
$cfg = Join-Path $Root 'qgate.json'
$globs = @(if (Test-Path $cfg) { try { (Get-Content $cfg -Raw | ConvertFrom-Json).harmony.assemblies } catch { } }) |
    Where-Object { $_ -is [string] -and $_.Trim() }
foreach ($g in $globs) {
    $g = [Environment]::ExpandEnvironmentVariables($g)
    if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $Root $g }
    $base, $leaf = $g -split '\*\*[\\/]?', 2
    $hits = if ($null -ne $leaf) {
        Get-ChildItem -LiteralPath $base -Recurse -File -Filter ($leaf ? $leaf : '*.dll') -ErrorAction SilentlyContinue
    } else { Get-ChildItem -Path $g -File -ErrorAction SilentlyContinue }
    # The deployed copy of this very mod is not "another" assembly.
    $extra += @($hits | Where-Object { $_.Extension -eq '.dll' -and $_.Name -ne (Split-Path $mod -Leaf) } | ForEach-Object FullName)
}
$extra = @($extra | Sort-Object -Unique)
# A pattern that matches nothing must not read as coverage.
if ($globs -and -not $extra) { "[WARN] harmony: qgate.json harmony.assemblies matched no .dll ($($globs -join ', '))" }
# Other plugins reach into more of the game than this mod does: load every assembly beside
# the ones it references too (the game's Managed folder, BepInEx core).
if ($extra) {
    $refs += @($refs | ForEach-Object { [IO.Path]::GetDirectoryName($_) } | Sort-Object -Unique |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.dll -File | ForEach-Object FullName })
}

$lines = [QGateHarmony]::Run(@($mod) + $extra, 1, $refs, (Split-Path $Project), $Root, $Targets.IsPresent)
$lines
if ($lines | Where-Object { $_ -notmatch '^\[(WARN|NOTE)\] ' }) { exit 1 }
