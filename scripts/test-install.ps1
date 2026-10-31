# Tests scripts/install.ps1 against the CLI zip that scripts/package-cli.sh left
# in build/, laid out like a release (stable and versioned names plus
# SHA256SUMS.txt), with Windows PowerShell 5.1 and PowerShell 7, as a script and
# through `iex` (as `irm ... | iex` runs it). It installs into a temporary folder
# but does change your user PATH while it runs (it is removed again): meant for CI.
# The PowerShell completions go into a temporary profile (-ProfilePath /
# PIMENTO_PROFILE), never yours, and are tried with TabExpansion2 in both shells.
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
$profileFile = Join-Path $work 'profile\profile.ps1'
$check = Join-Path $work 'check-completions.ps1'
New-Item -ItemType Directory -Path $dist, $bad, (Split-Path $profileFile) | Out-Null
# An existing profile in UTF-16 with a byte order mark and a non-ASCII character:
# the installer must leave it as it was, byte for byte, apart from its block.
[IO.File]::WriteAllText($profileFile, "# my profile $([char]0xFC)`r`nSet-Alias ll Get-ChildItem`r`n", [Text.Encoding]::Unicode)
$profileBefore = [IO.File]::ReadAllBytes($profileFile)

# Loads a profile in a fresh shell and completes some lines with TabExpansion2.
Set-Content -LiteralPath $check -Encoding ASCII -Value @'
param([string]$ProfileFile, [string]$Dir)
$ErrorActionPreference = 'Stop'
$env:Path = "$Dir;$env:Path"
. $ProfileFile
function Complete([string]$Line) {
    @((TabExpansion2 -inputScript $Line -cursorColumn $Line.Length).CompletionMatches | ForEach-Object { $_.CompletionText })
}
function Expect([string]$Line, [string]$Want) {
    $got = @(Complete $Line)
    if ($got -notcontains $Want) { throw "'$Line' completes to [$($got -join ', ')], not $Want" }
}
Expect 'pimento act' 'activate'
Expect 'pimento ' 'whoami'
Expect 'pimento.exe sta' 'status'
Expect 'pimento --demo li' 'list'
Expect 'pimento activate --dr' '--dry-run'
Expect 'pimento activate -j "x y" --ho' '--hours'
Expect 'pimento login --dev' '--device-code'
Expect 'pimento list --auth ' 'pimento'
Expect 'pimento activate --hours ' 'max'
Expect 'pimento history --outcome fa' 'failed'
Expect 'pimento presets ' 'show'
Expect 'pimento history ' 'import-azure'
Expect 'pimento completions ' 'powershell'
Expect 'pimento help ' 'approvals'
Expect 'pimento mc' 'mcp'
Expect 'pimento mcp --allow-a' '--allow-activate'
Expect 'pimento keep-alive --days ' 'mon-fri'
Expect 'pimento extend --days ' '30'
Expect 'pimento version --ch' '--check'
Expect 'pimento list --i' '--id'
# Preset names, from `pimento presets list --json` (the demo's presets).
Expect 'pimento --demo activate --preset ' 'On-call'
Expect 'pimento --demo activate --preset Rel' "'Release day'"
Expect 'pimento --demo presets show ' "'Data team'"
Expect 'pimento logout --a' '--all'
if (@(Complete 'pimento logout --a') -contains '--auth') { throw 'logout offers --auth' }
if (@(Complete 'pimento activate --preset Rel --ho') -notcontains '--hours') { throw 'a value was taken for a command' }
# Preset names with PowerShell's other quote characters (U+2018 to U+201E, which
# macOS types for ' and "), with ; and with other non-ASCII letters: each
# completion parses back to one command whose last argument is exactly the name.
$q = @([char]0x2018, [char]0x2019, [char]0x201C)
$names = @("Ops$($q[1]) team", "x$($q[0]);exit 3;$($q[1])", "it$($q[1])s", "say $($q[2])hi$($q[2])", "M$([char]0xFC)ller")
$presetsFile = Join-Path ([IO.Path]::GetTempPath()) ('pimento-presets-' + [Guid]::NewGuid().ToString('N') + '.json')
$i = 0
$presets = @(foreach ($name in $names) {
    $i++
    @{ id = ('00000000-0000-0000-0000-{0:D12}' -f $i); name = $name; roles = @(); match = @(@{ filters = @('prod'); roles = @('Owner') }) }
})
[IO.File]::WriteAllText($presetsFile, (@{ version = 1; presets = $presets } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
$env:PIMENTO_PRESETS = $presetsFile
try {
    $got = @(Complete 'pimento activate --preset ')
    $problems = @()
    $values = @()
    foreach ($completion in $got) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput("pimento activate --preset $completion", [ref]$tokens, [ref]$errors)
        $statements = @($ast.EndBlock.Statements)
        $last = $null
        if ($statements.Count -eq 1) { $last = @($statements[0].PipelineElements[0].CommandElements)[-1] }
        if (@($errors).Count -gt 0 -or $statements.Count -ne 1 -or -not ($last -is [Management.Automation.Language.StringConstantExpressionAst])) {
            $problems += "[$completion] is not one argument"
        } else {
            $values += $last.Value
        }
    }
    foreach ($name in $names) {
        if ($values -cnotcontains $name) { $problems += "nothing completes to [$name]" }
    }
    if ($problems.Count -gt 0) { throw ('preset name completions: ' + ($problems -join '; ') + ' (got: ' + ($got -join ' | ') + ')') }
} finally {
    $env:PIMENTO_PRESETS = $null
    Remove-Item -LiteralPath $presetsFile -Force -ErrorAction SilentlyContinue
}
Write-Host "ok: completions in PowerShell $($PSVersionTable.PSVersion)"
'@

function Get-BlockCount {
    $text = [IO.File]::ReadAllText($profileFile)
    return ([regex]::Matches($text, '(?m)^# >>> pimento completions')).Count
}

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
        $r = Invoke-Installer $shell @('-From', $dist, '-InstallDir', $dir, '-ProfilePath', $profileFile)
        if ($r.Code -ne 0) { Write-Host $r.Out; throw "$shell install failed" }
        $v = & (Join-Path $dir 'pimento.exe') version
        if ($v -ne "pimento $appVersion") { throw "$shell installed '$v'" }
        if (-not (Test-OnUserPath)) { throw "$shell did not add $dir to the user PATH" }
        if (-not (Test-Path (Join-Path $dir 'pimento-files.txt'))) { throw 'no file list' }
        if (-not (Test-Path (Join-Path $dir 'completions\pimento.ps1'))) { throw "$shell did not install the PowerShell completions" }
        if ((Get-BlockCount) -ne 1) { throw "$shell did not add one completion block to the profile" }
        $text = [IO.File]::ReadAllText($profileFile)
        if (-not $text.StartsWith("# my profile $([char]0xFC)")) { throw "$shell changed the profile's own text" }
        Write-Host "ok: install with $shell"

        # Again: the block is replaced, not repeated.
        $r = Invoke-Installer $shell @('-From', $dist, '-InstallDir', $dir, '-ProfilePath', $profileFile)
        if ($r.Code -ne 0) { Write-Host $r.Out; throw "$shell reinstall failed" }
        if ((Get-BlockCount) -ne 1) { throw "$shell repeated the completion block" }
        Write-Host "ok: reinstall with $shell keeps one completion block"

        foreach ($loader in 'powershell', 'pwsh') {
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = & $loader -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $check $profileFile $dir 2>&1 | Out-String }
            finally { $ErrorActionPreference = $saved }
            if ($LASTEXITCODE -ne 0) { Write-Host $out; throw "completions in $loader (installed with $shell)" }
            Write-Host $out.Trim()
        }

        $r = Invoke-Installer $shell @('-InstallDir', $dir, '-Uninstall', '-ProfilePath', $profileFile)
        if ($r.Code -ne 0) { Write-Host $r.Out; throw "$shell uninstall failed" }
        if (Test-Path $dir) { throw "$shell uninstall left $dir" }
        if (Test-OnUserPath) { throw "$shell uninstall left $dir on the user PATH" }
        $after = [IO.File]::ReadAllBytes($profileFile)
        if ([Convert]::ToBase64String($after) -ne [Convert]::ToBase64String($profileBefore)) {
            throw "$shell uninstall did not restore the profile byte for byte"
        }
        Write-Host "ok: uninstall with $shell (profile as before)"
    }

    # -NoCompletions leaves the profile alone.
    $r = Invoke-Installer 'pwsh' @('-From', $dist, '-InstallDir', $dir, '-ProfilePath', $profileFile, '-NoCompletions')
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'install with -NoCompletions failed' }
    if ((Get-BlockCount) -ne 0) { throw '-NoCompletions changed the profile' }
    $r = Invoke-Installer 'pwsh' @('-InstallDir', $dir, '-Uninstall', '-ProfilePath', $profileFile)
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'uninstall after -NoCompletions failed' }
    Write-Host 'ok: -NoCompletions leaves the profile alone'

    # A start marker whose end marker was deleted by hand: the install adds a
    # whole block after it, and uninstall removes only that block, never the
    # profile's own lines after the orphaned marker (nor the profile).
    $orphan = Join-Path $work 'orphan\profile.ps1'
    New-Item -ItemType Directory -Path (Split-Path $orphan) -Force | Out-Null
    $orphanText = "# >>> pimento completions (install.ps1 -Uninstall removes this block) >>>`r`n" +
        "`$pimentoCompletion = 'old'`r`nSet-Alias ll Get-ChildItem`r`n"
    [IO.File]::WriteAllText($orphan, $orphanText, (New-Object Text.UTF8Encoding $false))
    $r = Invoke-Installer 'pwsh' @('-From', $dist, '-InstallDir', $dir, '-ProfilePath', $orphan)
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'install next to an orphaned marker failed' }
    $r = Invoke-Installer 'pwsh' @('-InstallDir', $dir, '-Uninstall', '-ProfilePath', $orphan)
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'uninstall next to an orphaned marker failed' }
    if (-not (Test-Path -LiteralPath $orphan)) { throw 'uninstall deleted a profile with lines of its own' }
    if ([IO.File]::ReadAllText($orphan) -ne $orphanText) { throw "uninstall changed the profile's own lines after an orphaned marker" }
    Write-Host 'ok: an orphaned start marker keeps the lines after it'

    # As `irm ... | iex` runs it: the script text through Invoke-Expression, options from the environment.
    # A profile that does not exist yet is created, and removed again on uninstall. Its path is
    # relative, to PowerShell's location, which is not the process's current directory.
    $installer = Get-Content -Raw scripts/install.ps1
    $freshProfile = Join-Path $work 'fresh\profile.ps1'
    $env:PIMENTO_FROM = $dist
    $env:PIMENTO_INSTALL_DIR = $dir
    $env:PIMENTO_VERSION = $appVersion
    $env:PIMENTO_PROFILE = 'fresh\profile.ps1'
    Push-Location $work
    try { $installer | Invoke-Expression } finally { Pop-Location }
    if ((& (Join-Path $dir 'pimento.exe') version) -ne "pimento $appVersion") { throw 'iex install failed' }
    if ($ErrorActionPreference -ne 'Stop') { throw 'iex changed the session' }
    if (-not (Select-String -LiteralPath $freshProfile -Pattern '^# >>> pimento completions' -Quiet)) { throw 'iex install wrote no profile' }
    if (Get-Variable -Name pimentoCompletion -ErrorAction SilentlyContinue) { throw 'iex left a variable behind' }
    Write-Host 'ok: install through iex (pinned version, new profile)'
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
    Push-Location $work
    try { $installer | Invoke-Expression } finally { Pop-Location }
    $env:PIMENTO_UNINSTALL = $null
    if (Test-Path $dir) { throw 'iex uninstall left the folder' }
    if (Test-Path $freshProfile) { throw 'iex uninstall left the profile it created' }
    Write-Host 'ok: uninstall through iex (profile removed)'

    # Without -ProfilePath, uninstall looks through your own profiles, and
    # changes none that has no pimento block.
    $env:PIMENTO_PROFILE = $null
    $r = Invoke-Installer 'pwsh' @('-InstallDir', $dir, '-Uninstall')
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'uninstall with the default profiles failed' }
    $r = Invoke-Installer 'powershell' @('-InstallDir', $dir, '-Uninstall')
    if ($r.Code -ne 0) { Write-Host $r.Out; throw 'uninstall with the default profiles failed (Windows PowerShell)' }
    Write-Host 'ok: uninstall with the default profiles'
    Write-Host "install.ps1: all tests passed ($appVersion)"
} finally {
    $env:PIMENTO_INSTALL_DIR = $null
    $env:PIMENTO_PROFILE = $null
    if (Test-OnUserPath) {
        $p = ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_.TrimEnd('\') -ine $dir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $p, 'User')
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# The last program run here (the refused tampered install) exited 1; this script succeeded.
exit 0
