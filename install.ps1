#Requires -Version 5.1
<#
.SYNOPSIS
    Install windots — PowerShell 7 + Windows Terminal, Catppuccin Mocha, end to end.

.DESCRIPTION
    Idempotent. Re-run it any time: anything already correct is reported and left alone.

    What it does, in order:
      0. preflight  — Windows + winget
      1. packages   — winget (pwsh, git, gh, starship, zoxide, fzf, fd, rg, bat, eza, delta, gsudo, WT)
      2. relaunch   — re-executes itself under pwsh 7 once pwsh exists
      3. modules    — PowerShell modules, CurrentUser scope
      4. font       — CaskaydiaCove Nerd Font Mono, per-user (no admin)
      5. config     — profile, starship, bat, git, Windows Terminal
      6. verify     — prints what is actually live

    Nothing here needs admin. Existing files are backed up once to <name>.windots-backup
    before the first overwrite, and the Windows Terminal settings are *merged*, not replaced,
    so machine-generated profile GUIDs survive.

.PARAMETER GitUserName
    git user.name to set globally. Skipped if already configured.

.PARAMETER GitUserEmail
    git user.email to set globally. Skipped if already configured.

.EXAMPLE
    .\install.ps1
    Full install, keeping any git identity already configured.

.EXAMPLE
    .\install.ps1 -GitUserName 'Jane' -GitUserEmail 'jane@example.com'

.EXAMPLE
    .\install.ps1 -WhatIf
    Dry run: prints every change without touching the machine.

.EXAMPLE
    .\install.ps1 -SkipPackages -SkipFont
    Config only — useful when re-applying after editing the repo.

.LINK
    https://github.com/TheoM83/windots
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $SkipPackages,
    [switch] $SkipModules,
    [switch] $SkipFont,
    [switch] $SkipTerminal,
    [string] $GitUserName,
    [string] $GitUserEmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================ constants

$RepoUrl  = 'https://github.com/TheoM83/windots.git'
$FontUrl  = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip'
$FontMask = '*NerdFontMono*.ttf'          # the profile asks for "CaskaydiaCove NFM" = Mono variant

$Packages = @(
    @{ Id = 'Microsoft.PowerShell';    Note = 'pwsh 7' }
    @{ Id = 'Microsoft.WindowsTerminal'; Note = 'terminal' }
    @{ Id = 'Git.Git';                 Note = 'git' }
    @{ Id = 'GitHub.cli';              Note = 'gh' }
    @{ Id = 'Starship.Starship';       Note = 'prompt' }
    @{ Id = 'ajeetdsouza.zoxide';      Note = 'cd' }
    @{ Id = 'junegunn.fzf';            Note = 'fuzzy finder' }
    @{ Id = 'sharkdp.fd';              Note = 'find' }
    @{ Id = 'BurntSushi.ripgrep.MSVC'; Note = 'grep' }
    @{ Id = 'sharkdp.bat';             Note = 'cat' }
    @{ Id = 'eza-community.eza';       Note = 'ls' }
    @{ Id = 'dandavison.delta';        Note = 'git pager' }
    @{ Id = 'gerardog.gsudo';          Note = 'sudo' }
)

# PSReadLine is deliberately absent: 2.4.x ships inside PowerShell 7.6 and installing
# the gallery build on top of it only creates a second, older copy to shadow it.
$Modules = @(
    @{ Name = 'Terminal-Icons';      Minimum = '0.11.0' }
    @{ Name = 'CompletionPredictor'; Minimum = '0.1.1'  }
    @{ Name = 'PSFzf';               Minimum = '2.7.12' }
)

# winget exit codes that mean "nothing to do", not "failure"
$BenignWinget = @{
    -1978335135 = 'already installed'
    -1978335189 = 'already up to date'
    -1978335212 = 'no applicable installer, skipped'
}

$script:Warnings = New-Object System.Collections.ArrayList
$script:Failures = New-Object System.Collections.ArrayList

# ============================================================ output helpers

function Write-Step {
    param([string] $Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok   { param([string] $M) Write-Host '  [+] ' -NoNewline -ForegroundColor Green;    Write-Host $M }
function Write-Skip { param([string] $M) Write-Host '  [=] ' -NoNewline -ForegroundColor DarkGray; Write-Host $M -ForegroundColor DarkGray }

function Write-Warn {
    param([string] $M)
    Write-Host '  [!] ' -NoNewline -ForegroundColor Yellow
    Write-Host $M -ForegroundColor Yellow
    [void] $script:Warnings.Add($M)
}

function Write-Fail {
    param([string] $M)
    Write-Host '  [x] ' -NoNewline -ForegroundColor Red
    Write-Host $M -ForegroundColor Red
    [void] $script:Failures.Add($M)
}

# ============================================================ small utilities

function Test-Command {
    param([string] $Name)
    [bool] (Get-Command $Name -ErrorAction Ignore)
}

# winget writes to the *persisted* PATH; this session still has the old one.
function Update-SessionPath {
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    $env:Path = ($parts -join ';')
}

# UTF-8 without BOM: git chokes on a BOM in an included config, bat does not want one either.
function Write-TextFile {
    param([string] $Path, [string] $Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

# Keeps the pristine pre-windots version, once. Later runs never clobber that snapshot.
function Backup-Once {
    param([string] $Path)
    $backup = "$Path.windots-backup"
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Skip "backed up original -> $(Split-Path -Leaf $backup)"
    }
}

function Get-Sha256 {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Install-ConfigFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Source,
        [string] $Destination,
        [string] $Label
    )
    if ((Get-Sha256 $Source) -eq (Get-Sha256 $Destination)) {
        Write-Skip "$Label already current"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, "write $Label")) { return }

    Backup-Once $Destination
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Ok "$Label -> $Destination"
}

# ============================================================ 0. preflight

function Invoke-Preflight {
    Write-Step 'Preflight'

    if (-not $IsWindowsPlatform) {
        throw 'windots targets Windows only.'
    }
    Write-Skip "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    if (-not (Test-Command 'winget')) {
        throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
    }
    Write-Skip 'winget available'

    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        throw "config directory not found at $ConfigDir — run install.ps1 from inside a windots clone."
    }
    Write-Skip "source: $RepoRoot"
}

# ============================================================ 1. packages

function Get-InstalledPackageId {
    # `winget list` truncates long ids in its table; the export manifest carries them whole.
    $manifest = Join-Path $env:TEMP 'windots-winget-export.json'
    $ids = @{}
    try {
        & winget export --output $manifest --source winget --accept-source-agreements 2>&1 | Out-Null
        if (Test-Path -LiteralPath $manifest) {
            $doc = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
            foreach ($src in @($doc.Sources)) {
                foreach ($pkg in @($src.Packages)) { $ids[$pkg.PackageIdentifier] = $true }
            }
        }
    } catch {
        Write-Warn "could not enumerate installed packages ($($_.Exception.Message)) — will let winget decide"
    } finally {
        Remove-Item -LiteralPath $manifest -Force -ErrorAction Ignore -WhatIf:$false
    }
    return $ids
}

function Install-Packages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step 'winget packages'

    $installed = Get-InstalledPackageId

    foreach ($p in $Packages) {
        $id = $p.Id
        if ($installed.ContainsKey($id)) { Write-Skip "$id ($($p.Note))"; continue }
        if (-not $PSCmdlet.ShouldProcess($id, 'winget install')) { continue }

        Write-Host "  ... installing $id" -ForegroundColor DarkGray
        & winget install --id $id --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        $code = $LASTEXITCODE

        if ($code -eq 0)                      { Write-Ok   "$id ($($p.Note))" }
        elseif ($BenignWinget.ContainsKey($code)) { Write-Skip "$id — $($BenignWinget[$code])" }
        else                                  { Write-Fail "$id failed (winget exit $code)" }
    }

    Update-SessionPath
}

# ============================================================ 2. relaunch under pwsh

# Everything past this point wants PowerShell 7: module scope, $PROFILE target and
# the JSON merge all differ under Windows PowerShell 5.1.
function Invoke-RelaunchUnderPwsh {
    if ($PSVersionTable.PSEdition -eq 'Core') { return $false }

    Update-SessionPath
    $pwsh = Get-Command pwsh -ErrorAction Ignore
    if (-not $pwsh) {
        throw 'pwsh 7 is still not on PATH. Open a new terminal and re-run install.ps1.'
    }

    Write-Step 'Relaunching under PowerShell 7'
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-SkipPackages')
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'SkipPackages') { continue }
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $forward += "-$($kv.Key)" }
        } else {
            $forward += @("-$($kv.Key)", [string] $kv.Value)
        }
    }
    & $pwsh.Source @forward
    exit $LASTEXITCODE
}

# ============================================================ 3. modules

function Install-Modules {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step 'PowerShell modules (CurrentUser)'

    # PSResourceGet ships with PowerShell 7.4+ and needs no NuGet provider bootstrap.
    $useResource = [bool] (Get-Command Install-PSResource -ErrorAction Ignore)

    foreach ($m in $Modules) {
        $have = Get-Module -ListAvailable -Name $m.Name |
                Sort-Object Version -Descending |
                Select-Object -First 1
        if ($have -and $have.Version -ge [version] $m.Minimum) {
            Write-Skip "$($m.Name) $($have.Version)"
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($m.Name, "install module >= $($m.Minimum)")) { continue }

        try {
            if ($useResource) {
                Install-PSResource -Name $m.Name -Version "[$($m.Minimum),)" -Scope CurrentUser `
                                   -TrustRepository -Reinstall:$false -ErrorAction Stop
            } else {
                Install-Module -Name $m.Name -MinimumVersion $m.Minimum -Scope CurrentUser `
                               -Force -AllowClobber -ErrorAction Stop
            }
            Write-Ok "$($m.Name) $($m.Minimum)+"
        } catch {
            Write-Fail "$($m.Name): $($_.Exception.Message)"
        }
    }

    $prl = Get-Module -ListAvailable -Name PSReadLine |
           Sort-Object Version -Descending | Select-Object -First 1
    if ($prl -and $prl.Version -ge [version] '2.4.0') {
        Write-Skip "PSReadLine $($prl.Version) (bundled with pwsh)"
    } else {
        Write-Warn 'PSReadLine < 2.4 — F1 (ShowCommandHelp) and F2 (SwitchPredictionView) will not bind. Update PowerShell.'
    }
}

# ============================================================ 4. font

function Test-FontPresent {
    $key = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $key)) { return $false }
    $props = (Get-ItemProperty -Path $key).PSObject.Properties.Name
    [bool] ($props | Where-Object { $_ -like 'CaskaydiaCoveNerdFontMono*' })
}

function Install-NerdFont {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step 'CaskaydiaCove Nerd Font Mono (per-user)'

    if (Test-FontPresent) { Write-Skip 'already registered'; return }
    if (-not $PSCmdlet.ShouldProcess('CaskaydiaCove NFM', 'download and register font')) { return }

    # Nerd Fonts is not on winget, so this comes straight from the GitHub release.
    $zip     = Join-Path $env:TEMP 'windots-CascadiaCode.zip'
    $unpack  = Join-Path $env:TEMP 'windots-CascadiaCode'
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regKey  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    try {
        Write-Host '  ... downloading CascadiaCode.zip' -ForegroundColor DarkGray
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'      # Invoke-WebRequest is ~10x faster without it
        Invoke-WebRequest -Uri $FontUrl -OutFile $zip -UseBasicParsing
        $ProgressPreference = $oldProgress

        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        New-Item -ItemType Directory -Force -Path $fontDir | Out-Null

        $faces = Get-ChildItem -LiteralPath $unpack -Filter $FontMask
        if (-not $faces) { throw "no file matching $FontMask inside the archive" }

        foreach ($f in $faces) {
            $target = Join-Path $fontDir $f.Name
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force
            New-ItemProperty -Path $regKey -Name "$($f.BaseName) (TrueType)" `
                             -Value $target -PropertyType String -Force | Out-Null
        }
        Write-Ok "$($faces.Count) faces registered under HKCU"
    } catch {
        Write-Fail "font install failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $zip, $unpack -Recurse -Force -ErrorAction Ignore -WhatIf:$false
    }
}

# ============================================================ 5. config files

function Install-Profile {
    $dest = $PROFILE.CurrentUserCurrentHost
    Install-ConfigFile -Source (Join-Path $ConfigDir 'Microsoft.PowerShell_profile.ps1') `
                       -Destination $dest -Label 'PowerShell profile'
}

function Install-Starship {
    Install-ConfigFile -Source (Join-Path $ConfigDir 'starship.toml') `
                       -Destination (Join-Path $HOME '.config\starship.toml') -Label 'starship.toml'
}

function Install-Bat {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $batDir = Join-Path $env:APPDATA 'bat'
    Install-ConfigFile -Source (Join-Path $ConfigDir 'bat\config') `
                       -Destination (Join-Path $batDir 'config') -Label 'bat config'
    Install-ConfigFile -Source (Join-Path $ConfigDir 'bat\themes\Catppuccin Mocha.tmTheme') `
                       -Destination (Join-Path $batDir 'themes\Catppuccin Mocha.tmTheme') -Label 'bat theme'

    # Without a built cache the theme name does not resolve and delta silently loses its
    # colours — but rebuilding costs a second, so only do it when the theme is genuinely stale.
    if (-not (Test-Command 'bat')) { Write-Warn 'bat not on PATH — skipped `bat cache --build`'; return }

    $themeFile = Join-Path $batDir 'themes\Catppuccin Mocha.tmTheme'
    $cacheFile = Join-Path (& bat --cache-dir 2>$null) 'themes.bin'
    $stale = -not (Test-Path -LiteralPath $cacheFile) -or
             (Get-Item -LiteralPath $themeFile).LastWriteTime -gt (Get-Item -LiteralPath $cacheFile).LastWriteTime

    if (-not $stale) { Write-Skip 'bat theme cache current'; return }
    if (-not $PSCmdlet.ShouldProcess('bat theme cache', 'rebuild')) { return }

    & bat cache --build 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'bat theme cache rebuilt' }
    else { Write-Warn "bat cache --build exited $LASTEXITCODE" }
}

function Install-GitConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    # An include leaves ~/.gitconfig — identity, credential helper, work overrides — untouched.
    $include = Join-Path $HOME '.config\git\windots.gitconfig'
    Install-ConfigFile -Source (Join-Path $ConfigDir 'gitconfig') `
                       -Destination $include -Label 'git config fragment'

    if (-not (Test-Command 'git')) { Write-Warn 'git not on PATH — include not registered'; return }

    # git expands `~` to an absolute path when it *writes* the value, and it mixes separators
    # doing so, so the registered entry never matches the string we passed in. Compare
    # normalised paths, or every run appends another copy of the same include.
    $normalize = { param([string] $P) ($P -replace '\\', '/').Trim().ToLowerInvariant() }
    $expected  = & $normalize $include
    $existing  = @(& git config --global --get-all include.path 2>$null)
    $hits      = @($existing | Where-Object { (& $normalize $_) -eq $expected })

    if ($hits.Count -eq 1) {
        Write-Skip 'include already registered in ~/.gitconfig'
    } elseif ($hits.Count -gt 1) {
        if ($PSCmdlet.ShouldProcess('~/.gitconfig', 'deduplicate include.path')) {
            & git config --global --unset-all include.path 'windots\.gitconfig$'
            & git config --global --add include.path $include
            Write-Ok "include.path deduplicated ($($hits.Count) copies -> 1)"
        }
    } elseif ($PSCmdlet.ShouldProcess('~/.gitconfig', "add include.path $include")) {
        Backup-Once (Join-Path $HOME '.gitconfig')
        & git config --global --add include.path $include
        Write-Ok "include.path $include"
    }

    foreach ($pair in @(
        @{ Key = 'user.name';  Value = $GitUserName  }
        @{ Key = 'user.email'; Value = $GitUserEmail }
    )) {
        $current = (& git config --global --get $pair.Key 2>$null)
        if ($pair.Value) {
            if ($current -eq $pair.Value) { Write-Skip "$($pair.Key) already $current" }
            elseif ($PSCmdlet.ShouldProcess('~/.gitconfig', "set $($pair.Key)")) {
                & git config --global $pair.Key $pair.Value
                Write-Ok "$($pair.Key) = $($pair.Value)"
            }
        } elseif ($current) {
            Write-Skip "$($pair.Key) = $current (kept)"
        } else {
            Write-Warn "$($pair.Key) unset — run: git config --global $($pair.Key) '...'"
        }
    }
}

# --- Windows Terminal ------------------------------------------------------
# settings.json is merged, never replaced: profile GUIDs are generated per machine and
# clobbering them points defaultProfile at a profile that does not exist locally.

function Set-JsonProperty {
    param([object] $Object, [string] $Name, [object] $Value)
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Merge-TerminalSettings {
    param([string] $Source, [string] $Destination)

    $desired = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json

    if (Test-Path -LiteralPath $Destination) {
        try {
            $current = Get-Content -LiteralPath $Destination -Raw | ConvertFrom-Json
        } catch {
            Write-Warn "existing settings.json is not parseable ($($_.Exception.Message)) — replacing it wholesale"
            $current = $null
        }
    } else {
        $current = $null
    }
    if (-not $current) { $current = [pscustomobject] @{} }

    # 1. top-level look-and-feel keys we own
    $topLevel = @(
        'actions', 'alwaysShowTabs', 'copyFormatting', 'copyOnSelect', 'focusFollowMouse',
        'initialCols', 'initialRows', 'keybindings', 'newTabMenu', 'showTabsInTitlebar',
        'tabWidthMode', 'theme', 'themes', 'useAcrylicInTabRow'
    )
    foreach ($k in $topLevel) {
        if ($desired.PSObject.Properties.Name -contains $k) {
            Set-JsonProperty $current $k $desired.$k
        }
    }

    # 2. profiles.defaults — ours wins key by key, anything extra locally is kept
    if (-not ($current.PSObject.Properties.Name -contains 'profiles')) {
        Set-JsonProperty $current 'profiles' ([pscustomobject] @{})
    }
    if (-not ($current.profiles.PSObject.Properties.Name -contains 'defaults')) {
        Set-JsonProperty $current.profiles 'defaults' ([pscustomobject] @{})
    }
    foreach ($p in $desired.profiles.defaults.PSObject.Properties) {
        Set-JsonProperty $current.profiles.defaults $p.Name $p.Value
    }

    # 3. colour schemes — upsert by name
    $schemes = @()
    if ($current.PSObject.Properties.Name -contains 'schemes' -and $current.schemes) {
        $schemes = @($current.schemes)
    }
    foreach ($s in @($desired.schemes)) {
        $schemes = @($schemes | Where-Object { $_.name -ne $s.name }) + $s
    }
    Set-JsonProperty $current 'schemes' $schemes

    # 4. profiles.list stays local (machine GUIDs); only nudge the pwsh entry
    $pwshProfile = $null
    if ($current.profiles.PSObject.Properties.Name -contains 'list') {
        $pwshProfile = @($current.profiles.list) |
            Where-Object { $_.PSObject.Properties.Name -contains 'source' -and
                           $_.source -eq 'Windows.Terminal.PowershellCore' } |
            Select-Object -First 1
    }
    if ($pwshProfile) {
        Set-JsonProperty $pwshProfile 'startingDirectory' '%USERPROFILE%'
        Set-JsonProperty $current 'defaultProfile' $pwshProfile.guid
    } else {
        Write-Warn 'no PowerShell Core profile in settings.json — defaultProfile left as is (open Windows Terminal once, then re-run)'
    }

    $json = $current | ConvertTo-Json -Depth 32
    # sanity check before we hand it to Windows Terminal
    $null = $json | ConvertFrom-Json
    return $json
}

function Install-TerminalSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step 'Windows Terminal'

    $wtDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    if (-not (Test-Path -LiteralPath $wtDir)) {
        Write-Warn "Windows Terminal state not found — launch it once, then re-run with -SkipPackages"
        return
    }
    $dest   = Join-Path $wtDir 'settings.json'
    $source = Join-Path $ConfigDir 'windows-terminal-settings.json'

    try {
        $merged = Merge-TerminalSettings -Source $source -Destination $dest
    } catch {
        Write-Fail "merge failed: $($_.Exception.Message)"
        return
    }

    if ((Test-Path -LiteralPath $dest) -and
        ((Get-Content -LiteralPath $dest -Raw).Trim() -eq $merged.Trim())) {
        Write-Skip 'settings.json already current'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($dest, 'merge Windows Terminal settings')) { return }

    Backup-Once $dest
    Write-TextFile -Path $dest -Content $merged
    Write-Ok "settings merged -> $dest"
}

function Install-Configs {
    Write-Step 'Config files'
    Install-Profile
    Install-Starship
    Install-Bat
    Install-GitConfig
}

# ============================================================ 6. verify

function Invoke-Verify {
    Write-Step 'Verify'

    Update-SessionPath
    $tools = 'pwsh', 'git', 'gh', 'starship', 'zoxide', 'fzf', 'fd', 'rg', 'bat', 'eza', 'delta', 'gsudo'

    foreach ($t in $tools) {
        if (-not (Test-Command $t)) { Write-Fail "$t not on PATH"; continue }
        # first line carrying a version number — some tools lead with a tagline
        $line = @(& $t --version 2>&1 | Where-Object { $_ -match '\d+\.\d+' }) | Select-Object -First 1
        if (-not $line) { $line = '(version unknown)' }
        Write-Ok ('{0,-9} {1}' -f $t, (($line -replace '\s+', ' ').Trim()))
    }

    if (Test-FontPresent) { Write-Ok 'font      CaskaydiaCove NFM registered' }
    else { Write-Warn 'font      CaskaydiaCove NFM missing — the prompt will show tofu' }

    if (Test-Command 'bat') {
        $themes = & bat --list-themes 2>$null
        if (($themes -join "`n") -match 'Catppuccin Mocha') { Write-Ok 'bat       Catppuccin Mocha theme resolves' }
        else { Write-Warn 'bat       Catppuccin Mocha not in the cache — run: bat cache --build' }
    }
}

function Write-Summary {
    Write-Host ''
    if ($script:Failures.Count) {
        Write-Host "$($script:Failures.Count) failure(s):" -ForegroundColor Red
        $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }
    if ($script:Warnings.Count) {
        Write-Host "$($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    if (-not $script:Failures.Count -and -not $script:Warnings.Count) {
        Write-Host 'Clean install.' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Open a new Windows Terminal tab, then run ' -NoNewline
    Write-Host 'cheat' -NoNewline -ForegroundColor Cyan
    Write-Host ' for the keymap.'
}

# ============================================================ main

# Windows PowerShell 5.1 has no $IsWindows.
$IsWindowsPlatform = if (Get-Variable -Name IsWindows -ErrorAction Ignore) { $IsWindows } else { $true }

$RepoRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigDir = Join-Path $RepoRoot 'config'

Write-Host ''
Write-Host '  windots' -ForegroundColor Magenta -NoNewline
Write-Host '  —  PowerShell 7 + Windows Terminal, Catppuccin Mocha'
Write-Host "  $RepoUrl" -ForegroundColor DarkGray

Invoke-Preflight

if (-not $SkipPackages) { Install-Packages } else { Write-Step 'winget packages'; Write-Skip 'skipped' }

if (Invoke-RelaunchUnderPwsh) { return }   # never returns: the child process does the rest

if (-not $SkipModules)  { Install-Modules }   else { Write-Step 'PowerShell modules'; Write-Skip 'skipped' }
if (-not $SkipFont)     { Install-NerdFont }  else { Write-Step 'Nerd Font';          Write-Skip 'skipped' }

Install-Configs

if (-not $SkipTerminal) { Install-TerminalSettings } else { Write-Step 'Windows Terminal'; Write-Skip 'skipped' }

Invoke-Verify
Write-Summary

exit ([int] ($script:Failures.Count -gt 0))
