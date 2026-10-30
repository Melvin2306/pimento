# Tests scripts/install.ps1 against the CLI zip that scripts/package-cli.sh left
# in build/, laid out like a release (stable and versioned names plus
# SHA256SUMS.txt), with Windows PowerShell 5.1 and PowerShell 7, as a script and
# through `iex` (as `irm ... | iex` runs it). It installs into a temporary folder
# but does change your user PATH while it runs (it is removed again): meant for CI.
#
#   pwsh -File scripts/test-install.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Set-Location (Split-Path -Parent $PSScriptRoot)

$appVersion = (Select-String -Path Sources/PimentoCore/AppInfo.swift -Pattern 'static let version = "(.*)"').Matches[0].Groups[1].Value
$zip = "build/pimento-cli-$appVersion-windows-x86_64.zip"
if (-not (Test-Path $zip)) { throw "$zip is missing: run scripts/package-cli.sh first" }

$work = Join-Path ([IO.Path]::GetTempPath()) ("pimento-install-test-" + [Guid]::NewGuid().ToString('N'))
$dist = Join-Path $work 'dist'
$bad = Join-Path $work 'bad'
$dir = Join-Path $work 'Pimento'
New-Item -ItemType Directory -Path $dist, $bad | Out-Null

function Write-Sums([string]$folder) {
    $lines = Get-ChildItem -LiteralPath $folder -Filter '*.zip' | ForEach-Object {
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
    }
    Set-Content -LiteralPath (Join-Path $folder 'SHA256SUMS.txt') -Value $lines -Encoding ASCII
}
function Test-OnUserPath {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    return [bool]($p -and (($p -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dir }))
}
function Invoke-Installer([string]$shell, [string[]]$arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/install.ps1 @arguments 2>&1 | Out-String
    } finally { $ErrorActionPreference = $saved }
    return @{ Code = $LASTEXITCODE; Out = $out }
}

Copy-Item $zip (Join-Path $dist "pimento-cli-$appVersion-windows-x86_64.zip")
Copy-Item $zip (Join-Path $dist 'pimento-cli-windows-x86_64.zip')
Write-Sums $dist

try {
    foreach ($shell in 'powershell', 'pwsh') {
        $r = Invoke-Installer $shell @('-From', $dist, '-InstallDir', $dir)
        if ($r.Code -ne 0) { Write-Host $r.Out; throw "$shell install failed" }
        $v = & (Join-Path $dir 'pimento.exe') version
        if ($v -ne "pimento $appVersion") { throw "$shell installed '$v'" }
        if (-not (Test-OnUserPath)) { throw "$shell did not add $dir to the user PATH" }
        if (-not (Test-Path (Join-Path $dir 'pimento-files.txt'))) { throw 'no file list' }
        Write-Host "ok: install with $shell"

        $r = Invoke-Installer $shell @('-InstallDir', $dir, '-Uninstall')
        if ($r.Code -ne 0) { Write-Host $r.Out; throw "$shell uninstall failed" }
        if (Test-Path $dir) { throw "$shell uninstall left $dir" }
        if (Test-OnUserPath) { throw "$shell uninstall left $dir on the user PATH" }
        Write-Host "ok: uninstall with $shell"
    }

    # As `irm ... | iex` runs it: the script text through Invoke-Expression, options from the environment.
    $env:PIMENTO_FROM = $dist
    $env:PIMENTO_INSTALL_DIR = $dir
    $env:PIMENTO_VERSION = $appVersion
    Get-Content -Raw scripts/install.ps1 | Invoke-Expression
    if ((& (Join-Path $dir 'pimento.exe') version) -ne "pimento $appVersion") { throw 'iex install failed' }
    if ($ErrorActionPreference -ne 'Stop') { throw 'iex changed the session' }
    Write-Host 'ok: install through iex (pinned version)'
    $env:PIMENTO_VERSION = $null
    $env:PIMENTO_FROM = $null

    # A tampered zip is refused; the installed pimento stays as it was.
    $before = (Get-FileHash (Join-Path $dir 'pimento.exe')).Hash
    Copy-Item (Join-Path $dist '*') $bad
    Add-Content -LiteralPath (Join-Path $bad 'pimento-cli-windows-x86_64.zip') -Value 'x' -NoNewline
    $r = Invoke-Installer 'pwsh' @('-From', $bad, '-InstallDir', $dir)
    if ($r.Code -eq 0) { throw 'a tampered zip was installed' }
    if ($r.Out -notmatch 'Checksum mismatch') { Write-Host $r.Out; throw 'no checksum mismatch message' }
    if ((Get-FileHash (Join-Path $dir 'pimento.exe')).Hash -ne $before) { throw 'the installed pimento changed' }
    Write-Host 'ok: tampered zip refused'

    $env:PIMENTO_UNINSTALL = '1'
    Get-Content -Raw scripts/install.ps1 | Invoke-Expression
    $env:PIMENTO_UNINSTALL = $null
    if (Test-Path $dir) { throw 'iex uninstall left the folder' }
    Write-Host 'ok: uninstall through iex'
    Write-Host "install.ps1: all tests passed ($appVersion)"
} finally {
    $env:PIMENTO_INSTALL_DIR = $null
    if (Test-OnUserPath) {
        $p = ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_.TrimEnd('\') -ine $dir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $p, 'User')
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
