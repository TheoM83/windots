# Cheatsheet

Same content as the `cheat` command in the shell, kept here so it is greppable and linkable.

## Keys

| Key | Does |
|---|---|
| `Ctrl+R` | fuzzy history (PSFzf) |
| `Ctrl+T` | fuzzy file picker (PSFzf) |
| `Alt+C` | fuzzy cd (PSFzf) |
| `Tab` | menu completion |
| `→` | accept the inline prediction |
| `Alt+A` | cycle through the command's arguments |
| `F1` | help for the command under the cursor |
| `F2` | toggle inline / list prediction view |
| `Alt+Enter` | newline without executing |
| `Ctrl+W` | delete word backwards |
| `Ctrl+U` / `Ctrl+K` | delete to start / end of line |
| `Alt+D` | delete word forwards |
| `Ctrl+Z` / `Ctrl+Y` | undo / redo |
| `Ctrl+Space` | complete |
| `↑` / `↓` | history search on the current prefix |
| `Ctrl+←` / `Ctrl+→` | word-wise cursor movement |
| `"` `'` `(` `{` `[` | auto-pair, or wrap the current selection |

History is filtered on the way in: lines under 3 characters, anything matching
`password|secret|token|apikey|-AsPlainText`, and bare `exit`/`clear`/`ls`/`pwd`/`history`
are never written to disk.

## Navigation

| Command | Does |
|---|---|
| `cd <fragment>` | zoxide jump to a frecent directory |
| `cdi` | zoxide interactive picker |
| `..` `...` `....` | up 1 / 2 / 3 levels |
| `up N` | up N levels |
| `mkcd <dir>` | create the directory and enter it |
| `fcd` | fuzzy cd with an eza tree preview |

## Files

| Command | Does |
|---|---|
| `ls` / `cat` | native cmdlets — **return objects**, so keep piping them |
| `l` | eza, one entry per line |
| `ll` | eza, long + git status |
| `la` | eza, long + git status + hidden |
| `lt` / `ltt` | eza tree, depth 2 / depth 4 |
| `view <file>` | bat — syntax, line numbers, no pager |
| `less <file>` | bat — plain, paged |
| `ff` | fuzzy file picker with a bat preview, opens in `$EDITOR` |
| `fd` / `rg` | find files / grep (`grep` is aliased to `rg`) |
| `touch <path…>` | create, or bump the write time |
| `sizeof [path]` | recursive size in MB |
| `extract <archive>` | zip / tar / gz / bz2 / xz, and 7z if `7z` is on PATH |
| `path` | PATH entries, one per line, deduplicated |
| `sudo <cmd>` | gsudo elevation |

## Git

| Command | Expands to |
|---|---|
| `g` | `git` |
| `gs` | `git status --short --branch` |
| `ga` | `git add` |
| `gcm "msg"` | `git commit -m` |
| `gp` | `git push` |
| `gpl` | `git pull --rebase` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `gco` | `git checkout` |
| `gb` | `git branch` |
| `gsw` | `git switch` |
| `glog` | `git log --oneline --graph --decorate --all -30` |
| `fbr` | fuzzy branch checkout with a log preview |

All diffs render through delta: side-by-side, line numbers, `zdiff3` conflict style,
Catppuccin Mocha syntax theme.

## Misc

| Command | Does |
|---|---|
| `fkill` | fuzzy process kill, sorted by memory |
| `fenv` | fuzzy environment variable search |
| `http <url>` | GET, pretty-printed JSON through bat |
| `which <name>` | `Get-Command` |
| `reload` | re-source the profile |
| `editprofile` | open the profile in `$EDITOR` |
| `cheat` | this card, in the terminal |

## Environment set by the profile

| Variable | Value |
|---|---|
| `$env:EDITOR` / `$env:VISUAL` | `code` if VS Code is installed, else `notepad` |
| `$env:FZF_DEFAULT_COMMAND` | `fd --hidden --follow --exclude .git` |
| `$env:FZF_DEFAULT_OPTS` | 60 % height, reverse layout, Catppuccin Mocha colours |
| `$env:PROFILE_LOAD_MS` | how long the profile took to load, in milliseconds |
| `$env:DOTNET_CLI_TELEMETRY_OPTOUT` / `$env:POWERSHELL_TELEMETRY_OPTOUT` | `1` |

## Completions

Native argument completers are registered for `dotnet` and `winget`. `gh` completion is
generated once and cached to `gh-completion.ps1` next to the profile, then regenerated only
when `gh.exe` is newer than the cache — spawning `gh.exe` on every shell start costs ~50 ms.
