# `qgate tools [name ...]`: download the gate's external linters into <install>\tools\bin
# (gitignored), pinned and SHA-256 checked. Nothing goes on PATH or into a package
# manager: detect.ps1 puts this directory before PATH for the gate's own process only.
# The only network the gate does for these tools, and only when asked. No name = all.
# shortcut: Windows x64 assets only, like the rest of the gate; add rows per OS/arch if it ever runs elsewhere.
param([string[]]$Name)
$ErrorActionPreference = 'Stop'

$pins = [ordered]@{
    # https://github.com/betterleaks/betterleaks/releases/tag/v1.10.1 (checksums.txt)
    betterleaks = @{ Url = 'https://github.com/betterleaks/betterleaks/releases/download/v1.10.1/betterleaks_1.10.1_windows_x64.zip'
        Sha256 = '53d4b37635a999992fb8e1d79f8215279315cbb3b4139314289b69407e79143d'; Exe = 'betterleaks.exe' }
    # https://github.com/oxc-project/oxc/releases/tag/oxlint_v1.93.0 (GitHub asset digest)
    oxlint = @{ Url = 'https://github.com/oxc-project/oxc/releases/download/oxlint_v1.93.0/oxlint-x86_64-pc-windows-msvc.zip'
        Sha256 = '075ce1f3baae778da2a37a0bae8c31040f31f9ca3e1b89c60775f82f09661724'; Exe = 'oxlint-x86_64-pc-windows-msvc.exe' }
    # https://github.com/crate-ci/typos/releases/tag/v1.52.2 (GitHub asset digest; no checksums file published)
    typos = @{ Url = 'https://github.com/crate-ci/typos/releases/download/v1.52.2/typos-v1.52.2-x86_64-pc-windows-msvc.zip'
        Sha256 = 'ab79036832cea0f2a21aa947731d39512250cc0f7a6a2f6add26262738a8cc11'; Exe = 'typos.exe' }
    # https://github.com/google/osv-scanner/releases/tag/v2.7.1 (osv-scanner_SHA256SUMS)
    'osv-scanner' = @{ Url = 'https://github.com/google/osv-scanner/releases/download/v2.7.1/osv-scanner_windows_amd64.exe'
        Sha256 = '7121dcf420aefbbf89a7f0050c4d3094e079ff93afd334dfc96f16b02ec85800' }
    # https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1 (gitleaks_8.30.1_checksums.txt)
    gitleaks = @{ Url = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
        Sha256 = 'd29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e'; Exe = 'gitleaks.exe' }
    # https://github.com/golangci/golangci-lint/releases/tag/v2.15.0 (golangci-lint-2.15.0-checksums.txt)
    'golangci-lint' = @{ Url = 'https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-windows-amd64.zip'
        Sha256 = 'cd7ea6063c95de245e17e5246e42bdc14bb221792c429dbd239ab3a6ade6ca6a'; Exe = 'golangci-lint-2.15.0-windows-amd64\golangci-lint.exe' }
    # https://github.com/evilmartians/lefthook/releases/tag/v2.2.2 (lefthook_checksums.txt)
    lefthook = @{ Url = 'https://github.com/evilmartians/lefthook/releases/download/v2.2.2/lefthook_2.2.2_Windows_x86_64.exe'
        Sha256 = 'd45842ed8c7c3d8931f779a6d7eb819cdd12251bdf9ff447352c975d6fcb5b7f' }
    # https://github.com/bufbuild/buf/releases/tag/v1.75.0 (sha256.txt)
    buf = @{ Url = 'https://github.com/bufbuild/buf/releases/download/v1.75.0/buf-Windows-x86_64.exe'
        Sha256 = 'de35b288e7962ac72aefee5048aff80551a4f0e6ac865a21f838693461ac8b8d' }
    # No release binaries: built by the system Go; go.sum and the checksum database verify the source.
    govulncheck = @{ Go = 'golang.org/x/vuln/cmd/govulncheck@v1.9.0' }
}

$Name = @($Name -split ',' | ForEach-Object Trim | Where-Object { $_ })
if (-not $Name) { $Name = @($pins.Keys) }
$bad = @($Name | Where-Object { -not $pins.Contains($_) })
if ($bad) { Write-Output "qgate tools: unknown tool(s) $($bad -join ', '); known: $($pins.Keys -join ', ')"; exit 1 }

$bin = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
foreach ($n in $Name) {
    $p = $pins[$n]
    if ($p.Go) {
        if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Write-Output "[skip] $n -- needs the Go toolchain on PATH"; continue }
        $env:GOBIN = $bin
        & go install $p.Go
        if ($LASTEXITCODE -ne 0) { Write-Output "qgate tools: go install $($p.Go) failed -- not installed"; exit 1 }
        Write-Output "installed $n -> $(Join-Path $bin "$n.exe")"
        continue
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) "qgate-tools-$n-$PID"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $dl = Join-Path $work 'a.dl'
        Invoke-WebRequest -Uri $p.Url -OutFile $dl -UseBasicParsing
        $got = (Get-FileHash -LiteralPath $dl -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $p.Sha256) { Write-Output "qgate tools: $n checksum mismatch (got $got, pinned $($p.Sha256)) -- not installed"; exit 1 }
        # No Exe = the asset is the bare .exe itself.
        if ($p.Exe) {
            Expand-Archive -LiteralPath $dl -DestinationPath (Join-Path $work 'x') -Force
            $dl = Join-Path $work "x\$($p.Exe)"
        }
        Copy-Item -LiteralPath $dl -Destination (Join-Path $bin "$n.exe") -Force
        Write-Output "installed $n -> $(Join-Path $bin "$n.exe")"
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
