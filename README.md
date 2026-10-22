# upwsh

**u**nix-style **pwsh**: Unix-style PowerShell 7 on Windows with Unix paths, familiar commands, tab-completion, and a native prompt.

![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/platform-Windows%2010%2B-0078D4?logo=windows11&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

[简体中文](README.zh-CN.md) · [Install](#install) · [Try it](#try-it) · [Themes](#themes) · [Development](docs/development.md)

| `pure-classic` | `colorful-blue` |
| --- | --- |
| ![pure-classic prompt](docs/assets/themes/readme/pure-classic.png) | ![colorful-blue prompt](docs/assets/themes/readme/colorful-blue.png) |

The prompt shows the current folder, Git branch, command duration, and exit status without running Starship. Paths use `/d/work` and `~/projects`, while the shell keeps PowerShell syntax and pipelines.

## What it adds

| Capability | Example |
| --- | --- |
| Unix-style paths | `cd /d/work`, `cd ~/Desktop` |
| Familiar commands | `ls`, `cp -r`, `grep`, `touch -p` |
| Git completion | `git switch fe<Tab>` |
| Path completion | `/d/work/pro<Tab>` |
| Native prompt | `user@host project dev ❯` |
| Theme switching | `upwsh theme use pure-classic` |

## Install

Run in PowerShell 7 (`pwsh`):

```powershell
irm https://github.com/ityme/upwsh/raw/main/src/script/install.ps1 | iex
```

This installs into `~/.config/upwsh`, adds `upwsh` to Path, defines `upwsh` in the current pwsh, and loads the profile. If `eza`, `dust`, or `btm` are missing, install prints:

```text
missing   eza, dust, btm
next      upwsh tool install eza dust btm
```

## Try it

```powershell
cd /d/work
ls
git switch fe<Tab>
touch -p logs/archive/app.log
```

Use `upwsh theme use colorful-blue` to switch from the default prompt to connected color blocks.

## Use paths

At the interactive prompt, write paths with a lowercase drive prefix and forward slashes:

```powershell
cd /d/work
cd ~/Desktop
cd -                         # Return to the previous directory
```

Standalone, unquoted `/c/...` and `~/...` arguments are converted to Windows paths before execution. Quoted text stays unchanged, so strings such as `'use /c/demo'` keep their meaning.

For paths with spaces, variables, or paths in scripts, use `winpath`. Use `unixpath` for the reverse conversion:

```powershell
winpath '/c/my work'          # C:/my work
unixpath 'C:\my work'         # /c/my work
cd (winpath '~/my work')
'C:\one', 'D:\two' | unixpath
```

Both commands accept multiple paths and pipeline input; paths need not exist. Tab inserts `(winpath '…')` when an absolute Unix path needs quoting. Comments, embedded scripts, redirections, and combined arguments such as `--output=/c/a` are not automatically rewritten.

`rm` sends local fixed-drive files to the Recycle Bin. Windows reserved names (`nul`, `con`, `aux`, `prn`, `com1`–`com9`, `lpt1`–`lpt9`) cannot use that API. Tab skips them. Delete with an extended path: `[IO.File]::Delete('\\?\D:\work\nul')`.

## Git completion

With Git on Path, press Tab to complete common commands, branches, tags, and configured remotes:

```text
git sw<Tab>                  → git switch
git switch fe<Tab>           → matching local branches
git checkout v<Tab>          → matching tags and other refs
git push o<Tab>              → origin
git pull origin <Tab>        → locally known branches for origin
git checkout -- ./<Tab>      → files
```

A unique Git word completes with a trailing space, so you can type `git pul<Tab>o<Tab>d<Tab>` without inserting spaces when each prefix has one match. Ambiguous prefixes and directory completions do not add a space.

This uses local Git data only, with no extra dependencies. `git -C <directory>` and `git switch --track` are supported. Less common syntax falls back to normal completion. Queries are cached for one second; entering a command clears the cache. Changes made in another terminal may take up to one second to appear.

## Prompt refresh

The prompt shows a snapshot from the last completed command. Empty Enter, comments, Ctrl+L, Tab, and Ctrl+C while editing reuse it. Executing a command, including a failed or interrupted command, refreshes it once. Directory or window-width changes also refresh it.

Changes made in another window, such as switching a branch in the same working tree, appear after your next command here. Run `git status` to check the repository and refresh the prompt.

## Manage the installation

| Command | Purpose |
| --- | --- |
| `upwsh install` | Install or repair files, Path, and the `upwsh` command, then load |
| `upwsh update` | Update an existing installation, keeping tools, `user-settings.ps1`, extra theme JSON, and the profile hook |
| `upwsh load` | Enable startup loading of `~/.config/upwsh/profile.ps1` and load this pwsh |
| `upwsh unload` | Disable startup loading and drop the current-session prompt |
| `upwsh uninstall` | Unload, then remove the installation; keep a changed `user-settings.ps1`, delete themes |
| `upwsh edit` | Open `~/.config/upwsh/user-settings.ps1` in nvim, then reload this pwsh |

`upwsh install` and `upwsh update` default to the remote release. Use `--local` when developing from this project. Install and update load the current pwsh; uninstall unloads it, then deletes the runtime. A changed `user-settings.ps1` is kept; themes are not.

The install directory is fixed at `~/.config/upwsh`; `UPWSH_HOME` records it. The native prompt in `src/lib/prompt.psm1` follows the current folder and Git branch. Run `upwsh --help` for command help.

## CLI tools

Install tools as needed into `~/.config/upwsh/tool/bin`:

```powershell
upwsh tool list
upwsh tool install eza rg fd fzf
upwsh tool update eza
upwsh tool update --all
upwsh tool uninstall rg
```

## Themes

Two families, 12 local themes. **`pure-classic`** is the default (formerly iWonder). Switch without restarting pwsh:

```powershell
upwsh theme list
upwsh theme use "colorful-blue"
upwsh theme use "pure-classic"
```

| Family | Character | Preview |
| --- | --- | --- |
| `pure-*` | Minimal prompt on the terminal background | [pure-classic](src/theme/pure-classic.json) |
| `colorful-*` | Connected Powerline color blocks | [colorful-blue](src/theme/colorful-blue.json) |

[Open the interactive theme gallery](docs/assets/themes/gallery.html) to compare all command states offline.

### pure-* · transparent backgrounds

| Theme | Preview |
| --- | --- |
| [pure-classic](src/theme/pure-classic.json) | ![pure-classic prompt](docs/assets/themes/readme/pure-classic.png) |
| [pure-glacier](src/theme/pure-glacier.json) | ![pure-glacier prompt](docs/assets/themes/readme/pure-glacier.png) |
| [pure-ember](src/theme/pure-ember.json) | ![pure-ember prompt](docs/assets/themes/readme/pure-ember.png) |
| [pure-quiet](src/theme/pure-quiet.json) | ![pure-quiet prompt](docs/assets/themes/readme/pure-quiet.png) |
| [pure-daylight](src/theme/pure-daylight.json) | ![pure-daylight prompt](docs/assets/themes/readme/pure-daylight.png) |

### colorful-* · connected color blocks

| Theme | Preview |
| --- | --- |
| [colorful-blue](src/theme/colorful-blue.json) | ![colorful-blue prompt](docs/assets/themes/readme/colorful-blue.png) |
| [colorful-green](src/theme/colorful-green.json) | ![colorful-green prompt](docs/assets/themes/readme/colorful-green.png) |
| [colorful-macaron](src/theme/colorful-macaron.json) | ![colorful-macaron prompt](docs/assets/themes/readme/colorful-macaron.png) |
| [colorful-morandi](src/theme/colorful-morandi.json) | ![colorful-morandi prompt](docs/assets/themes/readme/colorful-morandi.png) |
| [colorful-cyberpunk](src/theme/colorful-cyberpunk.json) | ![colorful-cyberpunk prompt](docs/assets/themes/readme/colorful-cyberpunk.png) |
| [colorful-retro](src/theme/colorful-retro.json) | ![colorful-retro prompt](docs/assets/themes/readme/colorful-retro.png) |
| [colorful-memphis](src/theme/colorful-memphis.json) | ![colorful-memphis prompt](docs/assets/themes/readme/colorful-memphis.png) |

Colorful uses connected user, host, folder and Git blocks. Duration, exit code and `❯` stay on the terminal background. Missing Git, short commands and successful commands hide those segments without leftover arrows. Foreground contrast notes are in each JSON's `_Comment.ContrastAdjustments`.

Colorful enables `AddNewline` for one blank line before the prompt; pure disables it. One space follows the color strip, then duration, exit code and symbol join as in pure: ` 6s418ms1❯`.

Each picture above is that theme's prompt only. Quiet hides duration. Dark pictures use `#1a1b26`; Daylight uses white. Selecting a theme does not change the terminal background. **Colorful needs Powerline glyphs**, for example JetBrainsMono Nerd Font.

For an interactive comparison of all eight command states, download the repository and open **[docs/assets/themes/gallery.html](docs/assets/themes/gallery.html)** in a browser. It works offline; GitHub may show the HTML source rather than run it.

All prompt themes live in `~/.config/upwsh/theme/`; `theme.json` records the selection. Copy a bundled JSON, rename it, and edit the copy. `Order` and `Modules` set colors, layout and attached connectors. Each JSON includes Chinese field explanations. Switching refreshes the next prompt; editing requires reselecting the theme.

Updates refresh bundled filenames in `theme/` and leave extra JSON plus `theme.json` in place. Old names are not aliases or automatically renamed. See [Themes](docs/themes.md) for the file layout and configuration.

## Personal settings

Edit `~/.config/upwsh/user-settings.ps1` after the built-in aliases load, or run `upwsh edit` to open it in nvim (`vim` if nvim is missing). When the editor exits, `upwsh edit` reloads this pwsh. `upwsh.cmd` can only reload that child process. `upwsh update` leaves an existing copy in place. Uninstall keeps the file when it differs from the shipped template; an unchanged copy is deleted with the runtime. Themes are always deleted.

```powershell
function global:work { cd (winpath '/d/my work') }
```

Commented examples for `w`, `t`, `i`, `d`, and `gs` are in `user-settings.ps1`. Uncomment and edit them. Terminal status reporting can go there too. Full command text is off by default; see [Terminal Reporting](docs/terminal-reporting.md) for fields and privacy settings.

## Install from source

```powershell
git clone https://github.com/ityme/upwsh.git
cd upwsh
upwsh install --local
```

<details>
<summary>Local, remote, and source options</summary>

`upwsh install` and `upwsh update` default to the remote release. Use `--local` for the current project, or override the source with `--source`, `--ref`, or `--repo`. Piped installs also default to `--remote` and honor `UPWSH_SOURCE`, `UPWSH_REF`, and `UPWSH_REPO`.

```powershell
upwsh install --source I:/ispace/upwsh
upwsh install --remote --ref dev
upwsh update --remote
```

</details>

See [Development](docs/development.md) for tests, performance benchmarks, and converter maintenance.
