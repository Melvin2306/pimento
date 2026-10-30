# Installs the pimento command-line tool on Windows from a GitHub release, for
# the current user (no administrator rights):
#
#   irm https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.ps1 | iex
#
# It downloads the zip and SHA256SUMS.txt, checks the zip's SHA-256 (and, when
# the GitHub CLI is installed and signed in, its build provenance attestation),
# puts pimento.exe and its Swift runtime DLLs in
# %LOCALAPPDATA%\Programs\Pimento, adds that folder to your user PATH, and
# sets up tab completion for PowerShell: completions\pimento.ps1 in that
# folder, loaded by a marked block in your PowerShell profile
# ($PROFILE.CurrentUserAllHosts of the PowerShell you run this in). It is
# replaced, not repeated, on every install, and removed with -Uninstall.
#
# Parameters, or environment variables for `irm ... | iex`:
#   -Version X         PIMENTO_VERSION       install release X instead of the latest
#   -InstallDir DIR    PIMENTO_INSTALL_DIR   install into DIR
#   -NoAttestation     PIMENTO_NO_ATTESTATION=1
#   -NoCompletions     PIMENTO_NO_COMPLETIONS=1  leave your PowerShell profile alone
#   -ProfilePath FILE  PIMENTO_PROFILE       the profile for the completions (default: see above)
#   -Uninstall         PIMENTO_UNINSTALL=1   remove pimento, its PATH entry and its profile block
#   -From DIR          PIMENTO_FROM          use the zip and SHA256SUMS.txt in DIR (testing)
#   -DownloadBase URL  PIMENTO_DOWNLOAD_BASE download from URL instead of the release
#
# With parameters: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.ps1))) -Uninstall
param(
    [string]$Version = $env:PIMENTO_VERSION,
    [string]$InstallDir = $env:PIMENTO_INSTALL_DIR,
    [string]$From = $env:PIMENTO_FROM,
    [string]$DownloadBase = $env:PIMENTO_DOWNLOAD_BASE,
    [string]$ProfilePath = $env:PIMENTO_PROFILE,
    [switch]$NoAttestation = ($env:PIMENTO_NO_ATTESTATION -eq '1'),
    [switch]$NoCompletions = ($env:PIMENTO_NO_COMPLETIONS -eq '1'),
    [switch]$Uninstall = ($env:PIMENTO_UNINSTALL -eq '1')
)

function Install-Pimento {
    param(
        [string]$Version,
        [string]$InstallDir,
        [string]$From,
        [string]$DownloadBase,
        [string]$ProfilePath,
        [bool]$NoAttestation,
        [bool]$NoCompletions,
        [bool]$Uninstall
    )
    # Function scope: `irm | iex` runs in your session, whose settings stay as they were.
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version 3.0

    $Repo = 'Melvin2306/pimento'
    $Manifest = 'pimento-files.txt'
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Pimento' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)

    function Get-UserPath {
        $p = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $p) { return @() }
        return @($p -split ';' | Where-Object { $_ -ne '' })
    }
    function Test-SamePath([string]$a, [string]$b) {
        return $a.TrimEnd('\') -ieq $b.TrimEnd('\')
    }
    # PowerShell completion: completions\pimento.ps1, dot-sourced from a block
    # between these markers in the profile.
    $Completion = Join-Path $InstallDir 'completions\pimento.ps1'
    $BlockStart = '# >>> pimento completions (install.ps1 -Uninstall removes this block) >>>'
    $BlockEnd = '# <<< pimento completions <<<'
    $BlockPattern = '(?m)^# >>> pimento completions\b[^\r\n]*(?:\r?\n)(?s:.*?)^# <<< pimento completions\b[^\r\n]*(?:\r?\n)?'

    # The profiles to add the block to (one) and to remove it from (all of yours).
    function Get-ProfileTargets([bool]$All) {
        if ($ProfilePath) { return @([IO.Path]::GetFullPath($ProfilePath)) }
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $edition = 'WindowsPowerShell'
        if ($PSVersionTable.PSEdition -eq 'Core') { $edition = 'PowerShell' }
        $current = Join-Path $docs "$edition\profile.ps1"
        $known = Get-Variable -Name PROFILE -ValueOnly -ErrorAction SilentlyContinue
        if ($known -and $known.PSObject.Properties['CurrentUserAllHosts']) { $current = $known.CurrentUserAllHosts }
        if (-not $All) { return @($current) }
        $paths = @($current)
        if ($known) {
            foreach ($name in 'CurrentUserAllHosts', 'CurrentUserCurrentHost') {
                if ($known.PSObject.Properties[$name]) { $paths += $known.$name }
            }
        }
        foreach ($folder in 'WindowsPowerShell', 'PowerShell') {
            foreach ($file in 'profile.ps1', 'Microsoft.PowerShell_profile.ps1', 'Microsoft.VSCode_profile.ps1') {
                $paths += Join-Path $docs "$folder\$file"
            }
        }
        return @($paths | Select-Object -Unique)
    }
    # A profile's text and its encoding, so that it is written back unchanged
    # apart from Pimento's block: UTF-8 or UTF-16 by their byte order mark,
    # else ISO-8859-1, which maps each byte to one character and back (the
    # block itself is ASCII, so it fits any of them).
    function Read-ProfileText([string]$Path) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $encoding = [Text.Encoding]::GetEncoding(28591)
        $skip = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = New-Object Text.UTF8Encoding $true; $skip = 3
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = New-Object Text.UnicodeEncoding $false, $true; $skip = 2
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = New-Object Text.UnicodeEncoding $true, $true; $skip = 2
        }
        return @{ Encoding = $encoding; Text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip) }
    }
    function Write-ProfileText([string]$Path, $Encoding, [string]$Text) {
        [byte[]]$bytes = @($Encoding.GetPreamble()) + @($Encoding.GetBytes($Text))
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
    # A PowerShell expression for $Text in ASCII: a quoted string, or the
    # characters by number when it has others (a profile without a byte order
    # mark is read in the ANSI code page by Windows PowerShell, as UTF-8 by 7).
    function ConvertTo-AsciiLiteral([string]$Text) {
        if ($Text -match '^[\x20-\x7E]*$') { return "'" + ($Text -replace "'", "''") + "'" }
        return '(-join [char[]]@(' + ((@([int[]][char[]]$Text)) -join ',') + '))'
    }
    function Add-CompletionBlock([string]$Path) {
        $local = "$env:LOCALAPPDATA".TrimEnd('\')
        if ($local -and $Completion.StartsWith("$local\", [StringComparison]::OrdinalIgnoreCase)) {
            $where = '(Join-Path $env:LOCALAPPDATA ' + (ConvertTo-AsciiLiteral $Completion.Substring($local.Length + 1)) + ')'
        } else {
            $where = ConvertTo-AsciiLiteral $Completion
        }
        if (Test-Path -LiteralPath $Path) {
            $read = Read-ProfileText $Path
            $encoding = $read.Encoding; $text = $read.Text
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            $encoding = [Text.Encoding]::GetEncoding(28591); $text = ''
        }
        $nl = "`r`n"
        if ($text.Contains("`n") -and -not $text.Contains("`r`n")) { $nl = "`n" }
        $block = (@(
            $BlockStart,
            "`$pimentoCompletion = $where",
            'if (Test-Path -LiteralPath $pimentoCompletion) { . $pimentoCompletion }',
            'Remove-Variable pimentoCompletion',
            $BlockEnd
        ) -join $nl) + $nl
        $found = [regex]::Match($text, $BlockPattern)
        if ($found.Success) {
            # In place; any further copy goes.
            $rest = [regex]::Replace($text.Substring($found.Index + $found.Length), $BlockPattern, '')
            $text = $text.Substring(0, $found.Index) + $block + $rest
        } else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += $nl }
            $text += $block
        }
        Write-ProfileText $Path $encoding $text
    }
    # Removes the block from each profile that has it; true if one had.
    function Remove-CompletionBlock {
        $removed = $false
        foreach ($path in Get-ProfileTargets $true) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $read = Read-ProfileText $path
            if (-not [regex]::IsMatch($read.Text, $BlockPattern)) { continue }
            $rest = [regex]::Replace($read.Text, $BlockPattern, '')
            if ($rest.Length -eq 0) {
                # Nothing but Pimento's block was in it (the install created it).
                Remove-Item -LiteralPath $path -Force
            } else {
                Write-ProfileText $path $read.Encoding $rest
            }
            Write-Host "Removed the pimento completions from $path"
            $removed = $true
        }
        return $removed
    }

    # Runs a program and returns its exit code. (Windows PowerShell 5.1 turns a
    # program's stderr into errors, which 'Stop' would throw.)
    function Invoke-Native([scriptblock]$Block) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $Block *> $null } finally { $ErrorActionPreference = $saved }
        return $LASTEXITCODE
    }

    if ($Uninstall) {
        $null = Remove-CompletionBlock
        $listed = Join-Path $InstallDir $Manifest
        if (Test-Path -LiteralPath $listed) {
            foreach ($name in Get-Content -LiteralPath $listed) {
                if ($name -match '^[A-Za-z0-9._-]+$') {
                    Remove-Item -LiteralPath (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $Completion -Force -ErrorAction SilentlyContinue
            $folder = Split-Path -Parent $Completion
            if ((Test-Path -LiteralPath $folder) -and -not (Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $folder -Force
            }
            Remove-Item -LiteralPath $listed -Force
            if (-not (Get-ChildItem -LiteralPath $InstallDir -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $InstallDir -Force
            }
            Write-Host "Removed pimento from $InstallDir"
        } else {
            Write-Host "No pimento installed by this script in $InstallDir"
        }
        $userPath = @(Get-UserPath)
        $kept = @($userPath | Where-Object { -not (Test-SamePath $_ $InstallDir) })
        if ($kept.Count -ne $userPath.Count) {
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
            Write-Host "Removed $InstallDir from your user PATH"
        }
        Write-Host "Pimento's own files (presets, history, sign-in) are kept in $env:APPDATA\Pimento."
        Write-Host "Run 'pimento logout --all' before uninstalling to remove the sign-in, or delete that folder."
        return
    }

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -eq 'ARM64') {
        Write-Host 'Windows on Arm: installing the x86_64 build, which runs under emulation on Windows 11.'
    } elseif ($arch -ne 'AMD64') {
        throw "pimento needs 64-bit Windows (x86_64); this is $arch."
    }

    $Version = "$Version".TrimStart('v')
    if ($Version -and $Version -notmatch '^[0-9A-Za-z.-]+$') { throw "Not a version: $Version" }
    if ($Version) {
        $asset = "pimento-cli-$Version-windows-x86_64.zip"
        if (-not $DownloadBase) { $DownloadBase = "https://github.com/$Repo/releases/download/v$Version" }
    } else {
        $asset = 'pimento-cli-windows-x86_64.zip'
        if (-not $DownloadBase) { $DownloadBase = "https://github.com/$Repo/releases/latest/download" }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("pimento-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset
        $sums = Join-Path $tmp 'SHA256SUMS.txt'
        if ($From) {
            Write-Host "Using $asset from $From"
            Copy-Item -LiteralPath (Join-Path $From $asset) -Destination $zip
            Copy-Item -LiteralPath (Join-Path $From 'SHA256SUMS.txt') -Destination $sums
        } else {
            # Windows PowerShell 5.1 may still default to TLS 1.0.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Host "Downloading $asset from $DownloadBase"
            Invoke-WebRequest -UseBasicParsing -Uri "$DownloadBase/$asset" -OutFile $zip
            Invoke-WebRequest -UseBasicParsing -Uri "$DownloadBase/SHA256SUMS.txt" -OutFile $sums
        }

        $expected = $null
        foreach ($line in Get-Content -LiteralPath $sums) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $expected = $parts[0].ToLowerInvariant(); break }
        }
        if (-not $expected) { throw "SHA256SUMS.txt has no checksum for $asset" }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Checksum mismatch for ${asset}: expected $expected, got $actual. Nothing was installed."
        }
        Write-Host "Checksum OK (SHA-256 $actual)"

        if (-not $NoAttestation -and -not $From -and (Get-Command gh -ErrorAction SilentlyContinue)) {
            if ((Invoke-Native { gh auth status }) -eq 0) {
                $verified = Invoke-Native { gh attestation verify $zip --repo $Repo --signer-workflow "$Repo/.github/workflows/release.yml" }
                if ($verified -ne 0) {
                    throw "gh attestation verify failed for ${asset}: it was not built by $Repo's release workflow. Nothing was installed. (-NoAttestation skips this check.)"
                }
                Write-Host "Build provenance attestation OK (built by $Repo's release workflow)"
            } else {
                Write-Host 'Skipping the attestation check: gh is not signed in (gh auth login).'
            }
        }

        $unpacked = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
        $exe = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter 'pimento.exe')
        if ($exe.Count -ne 1) { throw "$asset should hold exactly one pimento.exe" }
        $pkg = $exe[0].DirectoryName
        $files = @(Get-ChildItem -LiteralPath $pkg -File | Where-Object { $_.Extension -in '.exe', '.dll' })

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        # Files of an earlier install that this version no longer has.
        $listed = Join-Path $InstallDir $Manifest
        if (Test-Path -LiteralPath $listed) {
            $now = $files | ForEach-Object { $_.Name }
            foreach ($name in Get-Content -LiteralPath $listed) {
                if ($name -match '^[A-Za-z0-9._-]+$' -and $now -notcontains $name) {
                    Remove-Item -LiteralPath (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue
                }
            }
        }
        foreach ($f in $files) {
            Copy-Item -LiteralPath $f.FullName -Destination $InstallDir -Force
            Unblock-File -LiteralPath (Join-Path $InstallDir $f.Name)
        }
        Set-Content -LiteralPath $listed -Value ($files | ForEach-Object { $_.Name }) -Encoding ASCII
        # PowerShell completion, from the zip (older releases have none).
        $packaged = Join-Path $pkg 'completions\pimento.ps1'
        $hasCompletion = Test-Path -LiteralPath $packaged -PathType Leaf
        if ($hasCompletion) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Completion) -Force | Out-Null
            Copy-Item -LiteralPath $packaged -Destination $Completion -Force
            Unblock-File -LiteralPath $Completion
        }

        $installed = Join-Path $InstallDir 'pimento.exe'
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = & $installed version 2>&1 } finally { $ErrorActionPreference = $saved }
        if ($LASTEXITCODE -ne 0) {
            throw ("$installed does not start (exit code $LASTEXITCODE). It needs the Microsoft Visual C++ " +
                "Redistributable (x64): https://aka.ms/vs/17/release/vc_redist.x64.exe")
        }
        Write-Host "Installed $installed ($out)"

        $userPath = @(Get-UserPath)
        if (-not ($userPath | Where-Object { Test-SamePath $_ $InstallDir })) {
            [Environment]::SetEnvironmentVariable('Path', (@($userPath) + $InstallDir) -join ';', 'User')
            Write-Host "Added $InstallDir to your user PATH (new terminals will find pimento)."
        }
        if (-not (($env:Path -split ';') | Where-Object { $_ -and (Test-SamePath $_ $InstallDir) })) {
            $env:Path = "$env:Path;$InstallDir"
        }
        $found = Get-Command pimento -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found -and -not (Test-SamePath (Split-Path $found.Source) $InstallDir)) {
            Write-Warning "Another pimento comes first on your PATH: $($found.Source)"
        }

        if ($hasCompletion -and -not $NoCompletions) {
            $target = @(Get-ProfileTargets $false)[0]
            Add-CompletionBlock $target
            Write-Host "Tab completion for PowerShell: added to $target (new sessions; in this one: . '$Completion')"
            $policy = "$(Get-ExecutionPolicy)"
            if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
                Write-Host ("PowerShell's execution policy is $policy, so it does not run your profile as it is. " +
                    "Completions load once it does: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'pimento needs the Microsoft Visual C++ Redistributable (x64), which most systems have.'
    Write-Host 'Next steps:'
    Write-Host '  pimento --demo list    try it with synthetic data, no Azure needed'
    Write-Host '  az login               sign in with the Azure CLI (or: pimento login, see the README)'
    Write-Host '  pimento list           your eligible PIM roles'
    Write-Host '  pimento help           all commands'
}

Install-Pimento -Version $Version -InstallDir $InstallDir -From $From -DownloadBase $DownloadBase -ProfilePath $ProfilePath `
    -NoAttestation:$NoAttestation.IsPresent -NoCompletions:$NoCompletions.IsPresent -Uninstall:$Uninstall.IsPresent
