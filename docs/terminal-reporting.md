# Terminal Reporting

[README](../README.md) | [中文介绍](../README.zh-CN.md)

The shell sends OSC escape sequences to the terminal for working-directory tracking, command boundaries, window titles, and optional status-bar variables. It does not run Git, inspect process trees, or poll system metrics to build reports.

## Configuration

Put settings in `~/.config/upwsh/user-settings.ps1`. Do not edit the installed `lib/term.psm1`; updates replace it.

```powershell
# Default: emit only to an interactive VT-capable console, not redirected output.
Set-TermReporting -Mode Auto

# Disable reporting, including titles and command markers.
Set-TermReporting -Mode Off

# Select exactly these protocols and fields. USERVARS enables OSC 1337 variables.
Set-TermReporting -Mode Auto -Fields @(
    'OSC133', 'OSC7', 'TITLE', 'USERVARS',
    'SESSION_ID', 'PID', 'CWD', 'CWD_UNIX', 'CMD', 'BUSY',
    'OK', 'EXIT', 'STATUS', 'LAST_CMD', 'LAST_ELAPSED_MS'
)
```

`-Mode On` bypasses interactive/redirection checks; reserve it for explicit integration or tests. `-Reset` restores default fields and options. Disabled variables that were already sent are cleared once on the next enabled report.

Before profile loading, the same choices can be supplied through environment variables:

| Variable | Values |
| --- | --- |
| `UPWSH_OSC` | `Auto` (default), `On`, `Off` |
| `UPWSH_OSC_FIELDS` | Comma-separated field/channel names; replaces the defaults |
| `UPWSH_OSC_COMMAND` | `1` opts into full command-line reporting |

The defaults enable OSC 2, OSC 7, and OSC 133. OSC 1337 user variables are enabled when WezTerm/iTerm2 is detected, or when starting with `UPWSH_OSC=On`. OSC 9;9 is enabled when `WT_SESSION` identifies Windows Terminal. Detection is only a default: nested terminals, SSH, and multiplexers may require explicit fields or passthrough settings. A terminal ignoring a sequence does not gain support just because the shell emits it.

## Privacy

Full command text is **off by default**. `CMD` is a short command label, not its arguments. Opt in only when your terminal configuration needs the full text:

```powershell
Set-TermReporting -FullCommand $true -CommandMaxBytes 2048
```

`COMMAND` is bounded to 2,048 UTF-8 bytes by default; the configurable limit is 0–16,384 bytes. Text is truncated on a UTF-8 boundary. Base64 is encoding, not encryption: arguments may contain secrets, and terminal logs or plugins may retain them. No automatic redaction is claimed. Disabling `COMMAND` does not hide the normal command line displayed in the terminal.

## Fields

OSC 1337 fields are project conventions, not universally recognized terminal properties. Existing short names remain available. `SCHEMA=2` identifies this contract.

| Group | Fields | Meaning |
| --- | --- | --- |
| Identity | `SHELL`, `SHELL_VERSION`, `HOST`, `USER`, `DOMAIN`, `ADMIN`, `SSH` | Shell, machine, account, elevation and SSH indicators |
| Session | `PID`, `SESSION_ID`, `SCHEMA` | Process ID, integration-session GUID, field schema version |
| Location | `CWD`, `CWD_UNIX`, `DIR`, `CWD_HOME`, `DRIVE` | Native filesystem directory, Unix-style path, directory leaf, home-abbreviated display path, drive |
| PowerShell location | `PROVIDER`, `LOCATION` | Actual provider and location, including `Env:\` or `HKCU:\` |
| Environment | `VENV` | Leaf name of `VIRTUAL_ENV`, or empty when inactive |
| Running command | `CMD`, `COMMAND`, `BUSY`, `COMMAND_ID` | Short label, opt-in full text, 0/1 busy flag, submission counter |
| Result | `OK`, `EXIT`, `STATUS` | Success flag, effective result code, `success` / `error` / `interrupted` where detectable |
| Duration | `ELAPSED_MS`, `LAST_ELAPSED_MS` | Completion duration; persistent last duration |
| Last command | `LAST_CMD`, `LAST_NATIVE_EXIT` | Last short label and raw PowerShell `$LASTEXITCODE` snapshot |

`CWD` stays the last filesystem directory even when PowerShell is at another provider; use `PROVIDER` and `LOCATION` for the actual shell location. `CWD_HOME` retains its original display convention: `~/...` within home, otherwise the native path. Use `CWD_UNIX` for consistent Unix formatting.

On completion, `CMD` and `COMMAND` clear and `BUSY` becomes `0`. `LAST_CMD` and `LAST_ELAPSED_MS` remain until another command finishes. For compatibility, `ELAPSED_MS` clears on the next idle prompt. Command duration uses a monotonic clock and 64-bit milliseconds, captured before prompt rendering.

`EXIT=0` means success. PowerShell errors and detected interruptions use nonzero effective codes rather than a stale native exit code. `LAST_NATIVE_EXIT` may refer to an earlier native program and must not be treated as this command's result. `CMD` is the first statically named command found in the submitted input; expressions/dynamic invocations may have no label. It is not the current foreground process or a complete pipeline description.

## Protocol And Sending Rules

- **OSC 133:** `A` precedes visible prompt output, `B` follows it, `C` precedes command output, and `D;<code>` closes an executed command. An idle/abandoned input is closed with an unnumbered `D`, not a false successful result. Pure editing redraws do not emit lifecycle markers.
- **OSC 7:** a percent-encoded file URI with empty authority for local drives and server authority for UNC paths. This uses real Windows paths, not the shell's `/c/...` shorthand.
- **OSC 2:** a bounded, control-character-filtered title.
- **OSC 9;9:** optional native working-directory reporting for Windows Terminal.
- **OSC 1337:** base64-encoded UTF-8 user variables, sent only when selected and changed.

After a successful upwsh `cd` (including `cd -`, `mkcd`, and shortcuts routed through `cd`), the shell immediately sends changed location fields and enabled OSC 7 / OSC 9;9 channels. This happens before the next command in `cd project; pi`, so terminal working-directory tracking does not wait for Pi to exit. It sends no prompt/command-boundary markers, title change, completion status, or busy-state change, and preserves the native exit code. Failed directory changes send nothing; unchanged location values are deduplicated. Directory changes and prompts use the same cached location snapshot and encoding path. Immediate reporting failures are isolated from the successful directory change, preserve the native exit code and caller error history, and schedule a later resynchronization. Direct `Set-Location` and other programs that change directory still synchronize at the next prompt.

Reports prepare pending fields, channels, and disabled-field clears, then write one frame. Only a successful writer return commits the sent-value cache; a failed or partial write retains clears and forces a retry. Re-enabling a field cancels any undelivered clear. Success here means the output writer accepted the frame, not that the terminal acknowledged or interpreted it.

The first prompt sends a full snapshot. Unchanged idle prompts send only necessary lifecycle markers: normally 24 bytes for `D`, `A`, and `B`. A completed command forces a full state resync because a child process or nested shell may have changed terminal state. This is intentional even when the parent-side values are unchanged. No polling is required.

One integration should own command-boundary markers. Enabling another prompt/shell-integration package that emits its own OSC 133 can produce duplicate or conflicting boundaries.

## Validation

```powershell
pwsh -NoLogo -NoProfile -File tests/test_term.ps1
pwsh -NoLogo -NoProfile -File tests/bench_term.ps1
python tests/bench_console.py --osc
python tests/bench_console.py --lifecycle
```

The unit tests capture sequences, URI edge cases, field changes, privacy limits, and output gating. ConPTY checks actual wire order around visible prompt text. The microbenchmark measures CPU/bytes written to memory, not terminal plugin callbacks or screen painting. Real consumer behavior still depends on terminal configuration and version.

Protocol references: [Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration), [WezTerm](https://wezterm.org/shell-integration.html), [iTerm2](https://iterm2.com/documentation-escape-codes.html).
