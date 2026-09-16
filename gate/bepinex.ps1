# BepInEx plugin metadata that compiles and fails only when the game loads the plugin:
# [BepInPlugin(guid, name, version)] and [BepInDependency(guid[, minVersion])] are strings.
# BepInEx 5 parses the version with System.Version, and a GUID with spaces or a typo'd
# dependency GUID makes the chainloader skip the mod silently.
#
# Called by check.ps1 at the full level for a project whose Reference/PackageReference list
# names BepInEx. Prints `[WARN] bepinex: ...` lines; never a failure (advisory first).
#
# ponytail: regex over the project's .cs source, not the IL. Ceiling: an argument that is
# not a string literal or a `const string` declared in the same project (MyPluginInfo from
# BepInEx.PluginInfoProps lives in obj/ and is generated from csproj properties, string
# interpolation, a constant from another assembly) is not checked, and an attribute split
# by a comment containing `)]` is misread. Upgrade path: read the attribute blobs from the
# built assembly the way gate/harmony.cs already reads HarmonyPatch.
param([Parameter(Mandatory)][string]$ProjectDir)

$files = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Filter *.cs |
    Where-Object { $_.FullName.Substring($ProjectDir.Length) -notmatch '[\\/](bin|obj)[\\/]' })
$src = @{}
foreach ($f in $files) { $src[$f.FullName] = [IO.File]::ReadAllText($f.FullName) }

# const string NAME = "value"; -- the usual PluginGUID / PluginVersion holders.
$consts = @{}
foreach ($t in $src.Values) {
    foreach ($m in [regex]::Matches($t, '\bconst\s+string\s+(\w+)\s*=\s*"([^"\\]*)"\s*;')) { $consts[$m.Groups[1].Value] = $m.Groups[2].Value }
}
# A literal, or the last segment of a (qualified) identifier naming a known const; else $null.
function Resolve-Arg([string]$a) {
    $a = $a.Trim()
    if ($a -match '^"([^"\\]*)"$') { return $Matches[1] }
    if ($a -match '^(?:[\w]+\.)*(\w+)$' -and $consts.ContainsKey($Matches[1])) { return $consts[$Matches[1]] }
    $null
}
# Reverse-DNS: two or more dot-separated labels, no spaces or punctuation.
$guidRx = '^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)+$'
$semverRx = '^\d+\.\d+\.\d+(-[0-9A-Za-z\-\.]+)?(\+[0-9A-Za-z\-\.]+)?$'

foreach ($path in $src.Keys | Sort-Object) {
    $t = $src[$path]
    $rel = [IO.Path]::GetRelativePath($ProjectDir, $path)
    foreach ($m in [regex]::Matches($t, '\[\s*(?:BepInEx\.)?(BepInPlugin|BepInDependency)(?:Attribute)?\s*\((.*?)\)\s*[\],]', 'Singleline')) {
        $line = ($t.Substring(0, $m.Index) -split "`n").Count
        $at = "$rel`:$line"
        # Split on top-level commas; string literals here hold no commas worth protecting.
        $args_ = @($m.Groups[2].Value -split ',')
        $guid = Resolve-Arg $args_[0]
        if ($null -ne $guid) {
            if (-not $guid.Trim()) { "[WARN] bepinex: $($m.Groups[1].Value) GUID is empty ($at)" }
            elseif ($guid -notmatch $guidRx) { "[WARN] bepinex: $($m.Groups[1].Value) GUID '$guid' is not reverse-DNS (e.g. com.author.mod) ($at)" }
        }
        # Plugin version is the third argument; a dependency's optional minimum version the second.
        $vi = if ($m.Groups[1].Value -eq 'BepInPlugin') { 2 } else { 1 }
        if ($args_.Count -gt $vi) {
            $ver = Resolve-Arg $args_[$vi]
            $parsed = $null
            if ($null -ne $ver -and -not [Version]::TryParse($ver, [ref]$parsed)) {
                $why = if ($ver -match $semverRx) { 'valid SemVer, but BepInEx 5 parses System.Version (fine on BepInEx 6 only)' } else { 'not a version BepInEx can parse' }
                "[WARN] bepinex: $($m.Groups[1].Value) version '$ver' -- $why ($at)"
            }
        }
    }
}
