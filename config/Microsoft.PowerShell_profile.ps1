#Requires -Version 7.0
<#
    PowerShell 7 profile — part of windots (https://github.com/TheoM83/windots)

    Layout: 1) environment  2) PSReadLine  3) modules  4) prompt + tools
            5) aliases      6) functions   7) completions  8) local overrides

    Machine-specific tweaks go in `profile.local.ps1` next to this file.
    That file is never tracked and is dot-sourced last, so it wins.
#>

$ProfileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Is this an interactive prompt, or `pwsh -Command ...` / `pwsh -File ...`?
# Two things below must not happen in a one-shot session: the predictor subsystem keeps
# the runspace alive so the process never exits, and PSReadLine's prediction options throw
# when there is no real console. Both are pure ergonomics — a script loses nothing.
#
# PowerShell accepts any unambiguous prefix of a switch (-c, -com, -Command all work), so
# match tokens against the start of each switch name rather than against a fixed list.
# Only look at things that are actually switches, so a command's own text cannot match.
$__switches = [Environment]::GetCommandLineArgs() |
    Where-Object { $_ -like '-*' -or $_ -like '/*' } |
    ForEach-Object { $_.TrimStart('-', '/').ToLowerInvariant() } |
    Where-Object { $_ }

$__isOneShot = [bool] ($__switches | Where-Object {
    $t = $_
    'command', 'file', 'encodedcommand' | Where-Object { $_.StartsWith($t) }
})
# -NoExit hands the session back to the user afterwards, so it is interactive after all.
$__staysOpen = [bool] ($__switches | Where-Object { 'noexit'.StartsWith($_) })

$IsInteractiveShell = (-not $__isOneShot) -or $__staysOpen
Remove-Variable __switches, __isOneShot, __staysOpen

# ---------------------------------------------------------------- 1. environment
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$PSStyle.FileInfo.Directory = "`e[1;38;2;137;180;250m"   # catppuccin blue
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

$env:EDITOR = if (Get-Command code -EA Ignore) { 'code' } else { 'notepad' }
$env:VISUAL = $env:EDITOR
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'

# fzf: fd as source, catppuccin-mocha palette
$env:FZF_DEFAULT_COMMAND = 'fd --hidden --follow --exclude .git'
$env:FZF_CTRL_T_COMMAND  = $env:FZF_DEFAULT_COMMAND
$env:FZF_ALT_C_COMMAND   = 'fd --type d --hidden --follow --exclude .git'
$env:FZF_DEFAULT_OPTS    = @(
    '--height 60% --layout=reverse --border=rounded --info=inline'
    '--pointer=">" --marker="*"'
    '--color=bg+:#313244,bg:-1,spinner:#f5e0dc,hl:#f38ba8'
    '--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc'
    '--color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8'
    '--color=border:#585b70'
) -join ' '

# ---------------------------------------------------------------- 2. PSReadLine
# 2.4.x ships with PowerShell 7.6 — nothing to install. F1/F2 below need it.
Import-Module PSReadLine

Set-PSReadLineOption -EditMode Windows
if ($IsInteractiveShell -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle ListView
}
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -MaximumHistoryCount 50000
Set-PSReadLineOption -ShowToolTips
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -Colors @{
    Command                = '#89b4fa'
    Parameter              = '#94e2d5'
    Operator               = '#f5c2e7'
    Variable               = '#f9e2af'
    String                 = '#a6e3a1'
    Number                 = '#fab387'
    Type                   = '#cba6f7'
    Comment                = '#6c7086'
    Keyword                = '#f38ba8'
    Error                  = '#f38ba8'
    InlinePrediction       = '#585b70'
    ListPredictionSelected = "`e[48;2;49;50;68m"
}

# keep history clean: no secrets, no trivia
Set-PSReadLineOption -AddToHistoryHandler {
    param($line)
    if ($line.Length -lt 3) { return $false }
    if ($line -match '(?i)(password|passwd|secret|token|apikey|api_key|-AsPlainText)') { return $false }
    if ($line -match '^\s*(exit|clear|cls|ls|ll|pwd|history)\s*$') { return $false }
    return $true
}

# navigation / editing
Set-PSReadLineKeyHandler -Key UpArrow         -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow       -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab             -Function MenuComplete
Set-PSReadLineKeyHandler -Key RightArrow      -Function ForwardWord
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function NextWord
Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow  -Function BackwardWord
Set-PSReadLineKeyHandler -Key Ctrl+w          -Function BackwardKillWord
Set-PSReadLineKeyHandler -Key Ctrl+u          -Function BackwardDeleteLine
Set-PSReadLineKeyHandler -Key Ctrl+k          -Function ForwardDeleteLine
Set-PSReadLineKeyHandler -Key Alt+d           -Function KillWord
Set-PSReadLineKeyHandler -Key Ctrl+z          -Function Undo
Set-PSReadLineKeyHandler -Key Ctrl+y          -Function Redo
Set-PSReadLineKeyHandler -Key F1              -Function ShowCommandHelp
Set-PSReadLineKeyHandler -Key F2              -Function SwitchPredictionView
Set-PSReadLineKeyHandler -Key Alt+a           -Function SelectCommandArgument
Set-PSReadLineKeyHandler -Key Ctrl+Spacebar   -Function Complete
Set-PSReadLineKeyHandler -Key Alt+Enter       -Function AddLine

# smart quotes: wrap selection, skip over closing quote, else auto-pair
Set-PSReadLineKeyHandler -Chord '"',"'" -BriefDescription SmartQuote -ScriptBlock {
    param($key)
    $q = $key.KeyChar
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $sStart = $null; $sLen = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$sStart, [ref]$sLen)
    if ($sStart -ne -1) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($sStart, $sLen, $q + $line.Substring($sStart, $sLen) + $q)
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($sStart + $sLen + 2)
        return
    }
    if ($cursor -lt $line.Length -and $line[$cursor] -eq $q) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1); return
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$q$q")
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
}

# smart braces: same behaviour for ( { [
Set-PSReadLineKeyHandler -Chord '(','{','[' -BriefDescription SmartBrace -ScriptBlock {
    param($key)
    $close = @{ '(' = ')'; '{' = '}'; '[' = ']' }[$key.KeyChar.ToString()]
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $sStart = $null; $sLen = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$sStart, [ref]$sLen)
    if ($sStart -ne -1) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($sStart, $sLen, $key.KeyChar + $line.Substring($sStart, $sLen) + $close)
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($sStart + $sLen + 2)
        return
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)$close")
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
}

# ---------------------------------------------------------------- 3. modules
# Import only what is present: a half-provisioned machine still gets a usable shell.
if (Get-Module -ListAvailable -Name Terminal-Icons) { Import-Module Terminal-Icons }

# CompletionPredictor registers a predictor subsystem that keeps the runspace alive:
# loading it in a one-shot session makes `pwsh -Command ...` hang instead of exiting.
if ($IsInteractiveShell -and (Get-Module -ListAvailable -Name CompletionPredictor)) {
    Import-Module CompletionPredictor
}

if ((Get-Command fzf -EA Ignore) -and (Get-Module -ListAvailable -Name PSFzf)) {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' `
                    -TabExpansion -EnableAliasFuzzyEdit -EnableAliasFuzzyKillProcess -EnableAliasFuzzySetLocation
}

# ---------------------------------------------------------------- 4. prompt + shell tools
if (Get-Command starship -EA Ignore) {
    Invoke-Expression (& starship init powershell)
    # transient prompt: past commands collapse to a bare "❯"
    function Invoke-Starship-TransientFunction { & starship module character }
    Enable-TransientPrompt
}
if (Get-Command zoxide -EA Ignore) { Invoke-Expression (zoxide init powershell --cmd cd | Out-String) }

# ---------------------------------------------------------------- 5. aliases
Set-Alias -Name g     -Value git
Set-Alias -Name which -Value Get-Command
if (Get-Command rg    -EA Ignore) { Set-Alias -Name grep -Value rg }
if (Get-Command gsudo -EA Ignore) { Set-Alias -Name sudo -Value gsudo }

# `ls` and `cat` stay native: they return objects, so the pipeline keeps working
# (ls | Where-Object Length -gt 1MB, cat x.json | ConvertFrom-Json).
# eza / bat live on their own names — text output, for reading not piping.
function l    { eza --icons --group-directories-first -1 @args }
function ll   { eza --icons --group-directories-first -lgh --git @args }
function la   { eza --icons --group-directories-first -lgha --git @args }
function lt   { eza --icons --group-directories-first --tree --level=2 @args }
function ltt  { eza --icons --group-directories-first --tree --level=4 @args }
function view { bat --style=auto --paging=never @args }
function less { bat --style=plain --paging=always @args }

function gs   { git status --short --branch @args }
function ga   { git add @args }
function gcm  { git commit -m @args }
function gp   { git push @args }
function gpl  { git pull --rebase @args }
function gd   { git diff @args }
function gds  { git diff --staged @args }
function gco  { git checkout @args }
function gb   { git branch @args }
function gsw  { git switch @args }
function glog { git log --oneline --graph --decorate --all -30 @args }

function ..   { Set-Location .. }
function ...  { Set-Location ../.. }
function .... { Set-Location ../../.. }

# ---------------------------------------------------------------- 6. functions
function reload { . $PROFILE; Write-Host 'profile reloaded' -ForegroundColor Green }
function editprofile { & $env:EDITOR $PROFILE }

function mkcd {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location $Path
}

function touch {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path)
    foreach ($p in $Path) {
        if (Test-Path $p) { (Get-Item $p).LastWriteTime = Get-Date }
        else { New-Item -ItemType File -Path $p | Out-Null }
    }
}

function up { param([int]$Levels = 1) Set-Location ('..\' * $Levels) }

function sizeof {
    param([string]$Path = '.')
    $b = (Get-ChildItem $Path -Recurse -File -EA Ignore | Measure-Object Length -Sum).Sum
    '{0:N2} MB' -f ($b / 1MB)
}

function Get-PathEntries { $env:PATH -split ';' | Where-Object { $_ } | Sort-Object -Unique }
Set-Alias path Get-PathEntries

# --- fuzzy helpers -------------------------------------------------
function ff {
    $f = fd --type f --hidden --exclude .git | fzf --preview 'bat --color=always --style=numbers {}'
    if ($f) { & $env:EDITOR $f }
}

function fcd {
    $d = fd --type d --hidden --exclude .git | fzf --preview 'eza --tree --level=2 --icons --color=always {}'
    if ($d) { Set-Location $d }
}

function fkill {
    $p = Get-Process | Sort-Object WS -Descending |
         ForEach-Object { '{0,-8} {1,-40} {2,10:N1} MB' -f $_.Id, $_.ProcessName, ($_.WS / 1MB) } |
         fzf --header 'PID      NAME                                         MEM'
    if ($p) { Stop-Process -Id ($p.Trim() -split '\s+')[0] -Force }
}

function fbr {
    $b = git branch --all --format='%(refname:short)' | fzf --preview 'git log --oneline --graph --color=always -20 {}'
    if ($b) { git checkout ($b -replace '^origin/', '') }
}

function fenv { Get-ChildItem env: | ForEach-Object { "$($_.Name)=$($_.Value)" } | fzf }

function extract {
    param([Parameter(Mandatory)][string]$Path)
    switch -Regex ($Path) {
        '\.zip$'                 { Expand-Archive -Path $Path -DestinationPath (Get-Item $Path).BaseName -Force }
        '\.(tar|gz|tgz|bz2|xz)$' { tar -xf $Path }
        '\.7z$'                  {
            if (Get-Command 7z -EA Ignore) { 7z x $Path }
            else { Write-Warning '7z not on PATH — winget install 7zip.7zip' }
        }
        default                  { Write-Warning "unknown archive: $Path" }
    }
}

function http { param([Parameter(Mandatory)]$Url) Invoke-RestMethod $Url | ConvertTo-Json -Depth 10 | bat -l json }

function cheat {
@"

 KEYS
   Ctrl+R      fuzzy history            Ctrl+T      fuzzy file picker
   Tab         menu completion          Alt+A       cycle command arguments
   ->          accept prediction        F2          toggle inline/list prediction
   F1          help for command         Alt+Enter   newline w/o executing
   Ctrl+W      delete word back         Ctrl+U/K    delete to start/end of line
   Alt+C       fuzzy cd (PSFzf)         Ctrl+Z/Y    undo / redo

 NAV
   cd <part>   zoxide jump              cdi         zoxide interactive
   .. ... .... up 1/2/3 levels          up N        up N levels
   mkcd <dir>  create + enter           fcd         fuzzy cd

 FILES
   ls / cat    native, return OBJECTS -> pipe them
   l ll la     eza listings             lt / ltt    tree depth 2 / 4
   view <f>    bat (syntax + numbers)   less <f>    bat paged
   ff          fuzzy open in `$EDITOR    fd / rg     find files / grep
   touch sizeof extract path            sudo        gsudo elevation

 GIT
   gs  status      ga  add       gcm "msg" commit      gp  push
   gpl pull-rebase gd  diff      gds staged diff       gco checkout
   gb  branch      gsw switch    glog graph log        fbr fuzzy branch
   (diffs render through delta, side-by-side)

 MISC
   fkill  fuzzy kill proc     fenv   fuzzy env var     http <url>  GET+json
   reload reload profile      editprofile              cheat  this card

"@ | Write-Host
}

# ---------------------------------------------------------------- 7. native completions
if (Get-Command dotnet -EA Ignore) {
    Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        dotnet complete --position $cursorPosition "$commandAst" | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}

if (Get-Command winget -EA Ignore) {
    Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        [Console]::InputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $local:word = $wordToComplete.Replace('"', '""')
        $local:ast  = $commandAst.ToString().Replace('"', '""')
        winget complete --word "$local:word" --commandline "$local:ast" --position $cursorPosition | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}

# gh completion is cached on disk: regenerating it spawns gh.exe (~50 ms) every start.
if ($gh = Get-Command gh -CommandType Application -EA Ignore) {
    $ghCache = Join-Path (Split-Path $PROFILE) 'gh-completion.ps1'
    $stale = -not (Test-Path $ghCache) -or
             (Get-Item $ghCache).LastWriteTime -lt (Get-Item $gh.Source).LastWriteTime
    if ($stale) { gh completion -s powershell | Set-Content $ghCache -Encoding utf8 }
    . $ghCache
}

# ---------------------------------------------------------------- 8. local overrides
# Untracked, machine-specific: work proxies, extra aliases, one-off tweaks.
$LocalProfile = Join-Path (Split-Path $PROFILE) 'profile.local.ps1'
if (Test-Path $LocalProfile) { . $LocalProfile }

$ProfileStopwatch.Stop()
$env:PROFILE_LOAD_MS = [int]$ProfileStopwatch.Elapsed.TotalMilliseconds
