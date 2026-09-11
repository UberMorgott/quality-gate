# Harmony patch targets that no longer exist -- the defect a game update leaves behind in a
# BepInEx mod: `[HarmonyPatch(typeof(Hud), "UpdateStatusEffects")]` compiles (it is a string)
# and fails only at runtime, as a Harmony exception or a feature that silently stops working.
#
# Called by check.ps1 after a successful `build`, at the full level, for a project that
# references 0Harmony / Lib.Harmony / HarmonyX. The checker (harmony.cs) reads metadata only;
# no game code is loaded. Prints one line per dangling target and exits 1 when there are any.
#
# No maintained Roslyn analyzer covers this (checked 2026-09): BUTR.Harmony.Analyzer checks
# AccessTools strings only and was last released 2023-06; Harmonize checks how a patch is
# spelled, not whether its target exists. So the gate does it after the build, against the
# exact references the compiler resolved.
param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Root, [string]$Tfm)

if (-not ('QGateHarmony' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'harmony.cs') }

# The references the compiler actually used (HintPath, packages, publicized copies, the
# framework's own), and the assembly the build just wrote. BuildProjectReferences=false:
# `build` already built them, this only asks where they are.
$msArgs = @($Project, '-t:ResolveReferences', '-getProperty:TargetPath', '-getItem:ReferencePath',
    '-p:BuildProjectReferences=false', '-nologo')
if ($Tfm) { $msArgs += "-p:TargetFramework=$Tfm" }
$raw = (& dotnet msbuild @msArgs 2>&1 | Out-String)
$info = if ($LASTEXITCODE -eq 0) { try { $raw | ConvertFrom-Json } catch { $null } }
if (-not $info -or -not (Test-Path -LiteralPath $info.Properties.TargetPath)) {
    "harmony: could not resolve the built assembly and its references"
    ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5)
    exit 1
}
$found = [QGateHarmony]::Run($info.Properties.TargetPath, @($info.Items.ReferencePath.FullPath),
    (Split-Path $Project), $Root)
$found
if ($found) { exit 1 }
