# Development

[README](../README.md) · [中文介绍](../README.zh-CN.md)

`src/` is source. `~/.config/upwsh` is the runtime the shell loads. Install copies `src/` into that directory: `src/script/` (lifecycle), `src/lib/` (modules), `src/theme/` (bundled prompt themes). Tests live in `tests/` at the repository root and are not installed. `bin/` and `tool/bin/` exist only after install (`upwsh.cmd` and downloaded CLIs). `src/lib/prompt.psm1` provides the native `user@host folder branch ❯` prompt and does not depend on Starship. Sample docs and screenshots use `user@host`, not a real account.

## Tests

Run from the repository root with PowerShell 7:

```powershell
pwsh -NoLogo -NoProfile -File tests/test_completion.ps1
pwsh -NoLogo -NoProfile -File tests/test_path_commands.ps1
pwsh -NoLogo -NoProfile -File tests/test_git_completion.ps1
pwsh -NoLogo -NoProfile -File tests/test_git_cache.ps1
pwsh -NoLogo -NoProfile -File tests/test_prompt.ps1
pwsh -NoLogo -NoProfile -File tests/test_prompt_renderer.ps1
pwsh -NoLogo -NoProfile -File tests/test_prompt_segments.ps1
pwsh -NoLogo -NoProfile -File tests/test_theme.ps1
pwsh -NoLogo -NoProfile -File tests/test_term.ps1
pwsh -NoLogo -NoProfile -File tests/test_interaction.ps1
pwsh -NoLogo -NoProfile -File tests/test_install_profile.ps1
pwsh -NoLogo -NoProfile -File tests/test_upwsh.ps1
pwsh -NoLogo -NoProfile -File tests/test_edit_reload.ps1
pwsh -NoLogo -NoProfile -File tests/test_session_cleanup.ps1
pwsh -NoLogo -NoProfile -File tests/test_install.ps1
pwsh -NoLogo -NoProfile -File tests/test_deploy_locks.ps1
```

The test harness uses temporary user homes and profiles and disables persistent environment writes. Symbolic-link creation tests report a separate skip only for an explicit missing symlink privilege/Developer Mode error; unexpected creation errors still fail. Junction safety tests always run.

The public `upwsh` function is created from an unbound script block containing a quoted absolute entry path. It must not retain `upwsh.psm1` session state: lifecycle commands force-reload that module while their calling command is still running. `test_edit_reload.ps1` reproduces the first install's module-import/load sequence and repeated edits in the same process, without running the installer or a real editor.

`session.psm1` retains immutable function/alias snapshots across profile reloads. Unload restores only definitions still owned by upwsh (including personal CommandMap shortcuts), preserving later user overrides; uninstall also removes the managed upwsh entry. PSReadLine options and built-in key bindings are restored when unchanged. Pre-existing custom key scripts are left untouched because PSReadLine does not expose them for reliable restoration. Direct uninstall defers teardown until disk work and status output finish. This does not undo arbitrary side effects executed by user-settings.ps1.

## Deployment

Install/update validate staged files before changing the installation. Deployment also checks existing bundled theme filenames for `Order` and `Modules` before any program changes; a theme without them blocks deployment with backup/replacement instructions rather than being overwritten. They keep live directories in place because Windows directory handles can prevent whole-tree renames. Changed program files use same-volume file replacement with a backup journal; unchanged files, tools, `user-settings.ps1`, `theme.json`, and extra JSON in `theme/` are left in place. A missing `user-settings.ps1` and bundled theme filenames are added and journaled.

A caught deployment error restores completed file changes and environment settings. A locked program file causes a failure naming that file; the installer does not kill the owning process or require elevation. If rollback itself fails, recovery files remain and their locations are reported. Replacement is atomic per file, not across the entire installation; process termination or power loss is outside this rollback guarantee. Install and update deploy the runtime, then the outer `upwsh` command loads the current session. If eza, dust, or btm are missing from PATH or `tool\bin`, install prints `upwsh tool install` for those names and does not download them. CLI tools are managed only through `upwsh tool list|install|update|uninstall`; there is no standalone `tools` command. Uninstall runs `upwsh unload` first. A `user-settings.ps1` that differs from the shipped template is kept; an unchanged template is deleted with the runtime. Themes are not kept.

The lock tests use temporary installations and Windows handles that deny rename/delete, including locked tool files and `user-settings.ps1`.

## Git completion

`src/lib/git_completion.psm1` handles common Git command positions before filesystem completion. It reads refs and configured remotes only when requested by Tab, without contacting a remote. Each query has a 500ms process wait limit and leaves `$LASTEXITCODE` unchanged. Subcommand names need no Git process. The scope is intentionally limited; unknown syntax returns to normal completion.

Successful raw queries are cached for 1 second, capped at 16 entries with oldest-entry eviction. Keys include the working directory, executable, ordered `-C` and query arguments, and Git environment overrides. Actual command input clears query data; empty Enter does not. Failed or timed-out queries are not cached. Git executable discovery is reused until Path, PATHEXT, working directory, or executable availability changes.

Git completion tests create and remove isolated local repositories with fixture branches, tags, and remote-tracking refs. Cache tests use Git Trace2 to count real queries. They do not modify the project repository or access remotes.

## Path conversion

`src/lib/path_convert.ps1` defines `winpath` and `unixpath`. Path conversion, completion normalization, command output, and setup share these interfaces. Path candidates use plain quoting rather than generated conversion expressions; the shared hook edit returns the cursor before a closing quote for files, directories, and common prefixes. Explicit user-written winpath expressions remain supported. The Enter handler only recognizes a standalone existing directory for navigation; it never infers argument roles from path-shaped strings. Command adapters and explicit `winpath` expressions convert known paths; the converter functions only transform path text.

Known filesystem operands use `ConvertTo-WindowsPathOperands`: it applies `winpath` before glob expansion, skips null operands, and preserves relative output by default. Use `-Literal` for destinations or paths that must not expand wildcards, and `-Absolute` when an absolute path is required. `Resolve-WindowsPath` converts then resolves against PowerShell's current location, without requiring the target to exist; resolution errors propagate instead of returning an unprocessed path. These interfaces accept path values, not shell-quoted source text or arbitrary option/search values. All ordinary command arguments, bare or quoted, remain untouched by Enter; external commands can use explicit `winpath` expressions. `Resolve-WindowsPath -PreserveProvider` preserves non-filesystem provider navigation syntax, including relative paths while inside such a provider.

Command adapters identify path roles before invoking the shared helpers: `cp`/`mv` split the final destination before expanding sources, and resolve destinations with `-Literal -Absolute`. `cd` uses the shared resolver with `-PreserveProvider`; `mkcd` resolves a filesystem path before invoking `cd`; Git completion converts each `-C` value literally while preserving relative values for repeated `-C` semantics. Read commands and `du` pass only their parsed path operands, never search expressions.

For mixed external arguments, `ConvertTo-WindowsMixedPathArguments` avoids command-specific option tables: operands before options are converted; after an option, ambiguous values remain unchanged until `--`. The eza adapter uses this rule for user arguments. Use `ls --ignore-glob '/i/*' -- '/i/my folder'` to preserve the pattern and convert the path, or pass `(winpath '...')` explicitly. Fixed adapter options are forwarded unchanged. Quoted strings for arbitrary external commands are still not globally rewritten. `fs.psm1` exposes a thin `cp` command: option parsing, shared path operand conversion, and status reporting. Its nested internal `copy.psm1` module owns destination layout, copy preflight, Robocopy invocation, staging and overwrite recovery, exporting only `Invoke-UpwshCopy` to `fs` (not the shell session). Copy safety uses its private `Assert-CopyPathWithoutLinks` preflight: source trees, source/destination ancestors, and effective write targets must contain no reparse points, including junctions and symbolic links. Directory copies inspect their actual destination subtree; file copies inspect only their final target and ancestors, leaving unrelated destination siblings out of scope. All targets are checked before any copy begins. Such copies are rejected explicitly before creating targets; links are not followed. This conservative policy also rejects cloud placeholders and other reparse points. Robocopy additionally uses `/XJ`. Preflight is not an atomic filesystem snapshot and cannot prevent every concurrent path replacement. Ordinary files are overwritten consistently whether the user names the file or its parent directory. Single-file `cp -f` replacement clears only the destination ReadOnly bit after staging succeeds; if replacement fails, the original attributes are restored. ACLs are never relaxed. Robocopy may treat same-size/same-mtime attribute differences as metadata-only `Tweaked` copies. The adapter temporarily separates the matching target timestamp to select content copying in that case; successful copying restores source metadata, and failure restores the recorded target timestamp and attributes.

Standalone installers contain generated copies so `irm | iex` works before installation. After editing the converter, synchronize and check those copies:

```powershell
pwsh -NoLogo -NoProfile -File src/script/sync_path_convert.ps1
pwsh -NoLogo -NoProfile -File src/script/sync_path_convert.ps1 -Check
```

## Native prompt

`src/lib/prompt.psm1` reads local `.git/HEAD` directly at a repository root. In subdirectories and worktrees, one local `git rev-parse --git-path HEAD` query locates it (250ms process wait limit). This also works before the first commit. Each actual render reads fresh branch data; only the completed prompt text is cached by `hook.psm1`. Empty Enter and editing redraws neither read Git nor launch subprocesses. Detached HEAD uses a `detached@<short-sha>` label.

The bundled `pure-classic` theme in `src/theme/pure-classic.json` preserves the user's Starship `pure` visual reference, without parsing TOML or executing Starship. `src/lib/theme.psm1` accepts `Order`/`Modules`, validates and fills defaults once per load, and persists the selected filename in `theme.json`. Changing its revision invalidates the rendered prompt cache. The renderer resolves visible built-in data first, then literal text and attached connectors using neighboring visible backgrounds. Themes without those fields are rejected. See [Themes](themes.md) for settings and update/uninstall behavior.

In pure-classic, user/host is `#22C55E`, the italic folder is `#EAB308`, the branch is `#06B6D4`, duration is `#73DACA`, the bold success character is `#0DB447`, and the bold error code and character are `#D15B71`. Both states use `❯` and one trailing space. Failures print the numeric effective exit code immediately before `❯`; there is no `!` or extra error icon. Duration appears at 2,000ms, uses milliseconds (`2s345ms`), and precedes the error code without an extra separator, matching the reference format. The hook reuses the monotonic duration already recorded by terminal reporting, even when OSC is disabled.

The user's folder-only requirement overrides the reference's three-component path truncation: home is `~`, a drive root is `/c`, and other filesystem locations display their last folder name. Colors are truecolor ANSI, disabled for redirected output, `TERM=dumb`, or `NO_COLOR`. Tests can use `Get-UpwshPromptText -Color Always/Never` for deterministic captures.

## Performance

```powershell
pwsh -NoLogo -NoProfile -File tests/bench_prompt.ps1 -Enforce
python tests/bench_console.py --enforce
python tests/bench_console.py --completion --samples 20
python tests/bench_console.py --quoted-path
python tests/bench_console.py --lifecycle
python tests/bench_console.py --osc
pwsh -NoLogo -NoProfile -File tests/bench_term.ps1
pwsh -NoLogo -NoProfile -File tests/bench_interaction.ps1 -Files 1000 -Samples 10
pwsh -NoLogo -NoProfile -File tests/bench_git_completion.ps1 -Samples 20
```

- `bench_startup.py --baseline <snapshot>/src/profile.ps1 --candidate src/profile.ps1 --runs 7` alternates fresh ConPTY processes and reports startup-to-input-ready medians and ranges. Use `--output <file.json>` to retain samples and `--max-ratio 0.95` to require at least a 5% median reduction. This measures process startup, profile loading, first rendering and input setup together, not reboot-cold disk access or the terminal application's window painting. Each process uses a temporary user home; configured themes/custom files come from the supplied runtime trees. Without a ratio gate, completion means measurements were collected, not that an optimization passed.
- `bench_prompt.ps1` measures profile loading, the first prompt, and empty Enter handling.
- `bench_console.py` sends Enter through Windows ConPTY. `--completion` creates a temporary Git repository, types `git pull origin `, and presses Tab without executing the command. It checks that listing candidates preserves the buffer and does not rerun the prompt renderer or emit prompt-boundary events. `--lifecycle` checks actual Ctrl+L/Ctrl+C, multiline cancellation, alternate submission, failure, and interruption behavior. It requires Python and uses only the standard library.
- `bench_term.ps1` reports OSC formatting time, byte count, and sequence count; `bench_console.py --osc` verifies protocol order on the wire.
- `bench_interaction.ps1` measures terminal reporting and file completion with generated files.
- `bench_git_completion.ps1` compares fresh queries with immediate repeats in the current repository, including word completion and its trailing space. The first query still starts Git; different query types do not share cache entries.

The empty Enter target is p95 below 30ms. Startup and completion have separate measurements; ConPTY timings exclude the terminal application's screen painting. Compare repeated runs on the same machine, since system load affects the results.

`PSConsoleHostReadLine` records submitted code after PSReadLine returns, independent of the submit key. Empty/comment-only input and editing cancellation leave the cached prompt valid. A pending command is consumed once by the next prompt, including failure or execution interruption. While PSReadLine is editing, prompt redraws do not emit command-finished or prompt-boundary events. Idle new input lines emit prompt boundaries and may close the abandoned input with an unnumbered D, but never a false numbered command result. End time is captured before rendering, and the last success/exit snapshot survives idle redraws.

Directory, window-width, and selected-theme changes also invalidate the rendered text. Branch/status changes made elsewhere are not polled: they appear after a command in this shell. This snapshot policy deliberately favors predictable low-latency editing.

Explicit path completion queries the filesystem first. Candidate display reuses that keypress's results; the next Tab queries again to see filesystem changes. Idle terminal reports send only changed fields. Command completion resynchronizes the full snapshot to restore state possibly changed by child processes. See [Terminal Reporting](terminal-reporting.md) for field definitions, configuration, privacy, and protocol tests.
