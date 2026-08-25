#Requires -Version 7.0
<#
.SYNOPSIS
    Pull the machine's live configuration back into this repo.

.DESCRIPTION
    install.ps1 pushes the repo onto the machine; sync.ps1 is the other direction.
    Edit the real files, use the shell for a week, then run this to record the result.

    It also regenerates docs/VERSIONS.md from what is actually installed, so the
    version table can never drift from reality.

    Nothing is committed — inspect `git diff` and commit yourself.

.EXAMPLE
    .\sync.ps1

.EXAMPLE
    .\sync.ps1 -WhatIf
    Show what would change in the repo without writing anything.

.LINK
    https://github.com/TheoM83/windots
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot  = $PSScriptRoot
$ConfigDir = Join-Path $RepoRoot 'config'
$DocsDir   = Join-Path $RepoRoot 'docs'

function Write-Ok      { param([string] $M) Write-Host '  [~] ' -NoNewline -ForegroundColor Yellow;   Write-Host $M }
function Write-Same    { param([string] $M) Write-Host '  [=] ' -NoNewline -ForegroundColor DarkGray; Write-Host $M -ForegroundColor DarkGray }
function Write-Missing { param([string] $M) Write-Host '  [?] ' -NoNewline -ForegroundColor DarkYellow; Write-Host $M -ForegroundColor DarkYellow }

function Get-Sha256 {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# .gitattributes checks this repo out with CRLF; writing LF here would make every
# generated file look modified on every run.
function Write-RepoText {
    param([string] $Path, [string] $Content)
    $normalized = $Content -replace "`r`n", "`n" -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $normalized, (New-Object System.Text.UTF8Encoding $false))
}

function Test-RepoTextCurrent {
    param([string] $Path, [string] $Content)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $normalized = $Content -replace "`r`n", "`n" -replace "`n", "`r`n"
    (Get-Content -LiteralPath $Path -Raw) -eq $normalized
}

function Copy-IntoRepo {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Live, [string] $Repo, [string] $Label)

    if (-not (Test-Path -LiteralPath $Live)) { Write-Missing "$Label not on this machine ($Live)"; return }
    if ((Get-Sha256 $Live) -eq (Get-Sha256 $Repo)) { Write-Same "$Label unchanged"; return }
    if (-not $PSCmdlet.ShouldProcess($Repo, "update from $Live")) { return }

    $dir = Split-Path -Parent $Repo
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $Live -Destination $Repo -Force
    Write-Ok "$Label updated"
}

# ------------------------------------------------------------------ files

Write-Host ''
Write-Host '==> Snapshotting live config' -ForegroundColor Cyan

Copy-IntoRepo -Label 'PowerShell profile' `
    -Live $PROFILE.CurrentUserCurrentHost `
    -Repo (Join-Path $ConfigDir 'Microsoft.PowerShell_profile.ps1')

Copy-IntoRepo -Label 'starship.toml' `
    -Live (Join-Path $HOME '.config\starship.toml') `
    -Repo (Join-Path $ConfigDir 'starship.toml')

Copy-IntoRepo -Label 'bat config' `
    -Live (Join-Path $env:APPDATA 'bat\config') `
    -Repo (Join-Path $ConfigDir 'bat\config')

Copy-IntoRepo -Label 'bat theme' `
    -Live (Join-Path $env:APPDATA 'bat\themes\Catppuccin Mocha.tmTheme') `
    -Repo (Join-Path $ConfigDir 'bat\themes\Catppuccin Mocha.tmTheme')

# Windows Terminal: track only what install.ps1 actually applies. profiles.list and
# defaultProfile hold machine-generated GUIDs that the merge deliberately ignores, so
# keeping them here would just be a lie about what the repo controls.
function Sync-TerminalSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Live, [string] $Repo)

    if (-not (Test-Path -LiteralPath $Live)) { Write-Missing "Windows Terminal settings not on this machine"; return }

    $settings = Get-Content -LiteralPath $Live -Raw | ConvertFrom-Json
    $settings.PSObject.Properties.Remove('defaultProfile')
    if ($settings.PSObject.Properties.Name -contains 'profiles') {
        $settings.profiles.PSObject.Properties.Remove('list')
    }
    $json = ($settings | ConvertTo-Json -Depth 32) + "`n"

    if (Test-RepoTextCurrent -Path $Repo -Content $json) {
        Write-Same 'Windows Terminal settings unchanged'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Repo, "update from $Live")) { return }

    Write-RepoText -Path $Repo -Content $json
    Write-Ok 'Windows Terminal settings updated (profiles.list and defaultProfile stripped)'
}

Sync-TerminalSettings `
    -Live (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') `
    -Repo (Join-Path $ConfigDir 'windows-terminal-settings.json')

# git: the tracked fragment must never carry an identity, so it is only ever synced
# from the include file that install.ps1 owns.
$gitInclude = Join-Path $HOME '.config\git\windots.gitconfig'
if (Test-Path -LiteralPath $gitInclude) {
    Copy-IntoRepo -Label 'git config fragment' -Live $gitInclude -Repo (Join-Path $ConfigDir 'gitconfig')
} else {
    Write-Missing 'git fragment not deployed yet — run install.ps1 first (~/.gitconfig is never read from, it holds your identity)'
}

# ------------------------------------------------------------------ versions

Write-Host ''
Write-Host '==> Recording versions' -ForegroundColor Cyan

function Get-ToolVersion {
    param([string] $Tool)
    if (-not (Get-Command $Tool -ErrorAction Ignore)) { return 'not installed' }
    $line = @(& $Tool --version 2>&1 | Where-Object { $_ -match '\d+\.\d+' }) | Select-Object -First 1
    if (-not $line) { return 'unknown' }
    if ($line -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
    return ($line -replace '\s+', ' ').Trim()
}

$toolRows = foreach ($t in 'pwsh', 'git', 'gh', 'starship', 'zoxide', 'fzf', 'fd', 'rg', 'bat', 'eza', 'delta', 'gsudo') {
    '| `{0}` | {1} |' -f $t, (Get-ToolVersion $t)
}

$moduleRows = foreach ($m in 'PSReadLine', 'Terminal-Icons', 'CompletionPredictor', 'PSFzf') {
    $found = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
    '| `{0}` | {1} |' -f $m, $(if ($found) { $found.Version } else { 'not installed' })
}

$os = (Get-CimInstance Win32_OperatingSystem).Caption
$build = [Environment]::OSVersion.Version.ToString()

$versions = @"
# Versions

Regenerated by ``sync.ps1`` — do not edit by hand.

Snapshot: **$(Get-Date -Format 'yyyy-MM-dd')** on $os (build $build)

## Tools

| Tool | Version |
|---|---|
$($toolRows -join "`n")

## PowerShell modules

| Module | Version |
|---|---|
$($moduleRows -join "`n")

``PSReadLine`` ships inside PowerShell 7.6 — ``install.ps1`` never installs it from the gallery.

"@

$versionsPath = Join-Path $DocsDir 'VERSIONS.md'
if (Test-RepoTextCurrent -Path $versionsPath -Content $versions) {
    Write-Same 'docs/VERSIONS.md unchanged'
} elseif ($PSCmdlet.ShouldProcess($versionsPath, 'regenerate')) {
    if (-not (Test-Path -LiteralPath $DocsDir)) { New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null }
    Write-RepoText -Path $versionsPath -Content $versions
    Write-Ok 'docs/VERSIONS.md'
}

# ------------------------------------------------------------------ report

Write-Host ''
Write-Host '==> Repo status' -ForegroundColor Cyan
if (Get-Command git -ErrorAction Ignore) {
    & git -C $RepoRoot status --short
    Write-Host ''
    Write-Host 'Review with ' -NoNewline
    Write-Host 'git -C ' -NoNewline -ForegroundColor Cyan
    Write-Host "$RepoRoot" -NoNewline -ForegroundColor Cyan
    Write-Host ' diff' -ForegroundColor Cyan
} else {
    Write-Host '  git not on PATH' -ForegroundColor Yellow
}
