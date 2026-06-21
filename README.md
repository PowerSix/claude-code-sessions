# Get-ClaudeCodeSessions

PowerShell utility for browsing, triaging, and cleaning up Claude Code session
transcripts. List every session across every project, see custom titles, drill
into any conversation, and delete what you don't need — with `Tab` completion on
session names and a guard rail that won't let an unfiltered delete wipe everything.

## What it does

Claude Code stores every session as a JSONL file under
`%USERPROFILE%\.claude\projects\<encoded-cwd>\`. After a few months of use
these accumulate into hundreds of UUID-named files with no obvious way to tell
what's what. This script reads them, extracts the parts that actually matter
(working directory, custom title, conversation turns), and presents a sorted,
indexed table. From there you can drill into any conversation or delete the
sessions you no longer want — selecting them by age, size, name, or absence of
a title, with a preview-then-delete workflow and per-file confirmation.

```
Index Folder                  Session          Modified              Size File
----- ------                  -------          --------              ---- ----
    1 \                                         2026-05-17 02:25:45   1330 a1b2c3d4-...e5f6.jsonl
    2 \                       refactor          2026-05-14 10:34:55   1555 7g8h9i0j-...k1l2.jsonl
    3 \                       db-migration      2026-05-11 23:55:01    554 m3n4o5p6-...q7r8.jsonl
    4 \Projects\my-app        my-app            2026-05-15 17:02:20  14895 s9t0u1v2-...w3x4.jsonl
    5 \Projects\side-tool     side-tool         2026-05-14 11:50:58  30363 y5z6a7b8-...c9d0.jsonl
```

You can drill into any session and see the conversation:

```
================================================================================
Index    : 5
Folder   : \Projects\side-tool
Session  : side-tool
File     : y5z6a7b8-...c9d0.jsonl
Modified : 2026-05-14 11:50:58
Size     : 30363
Turns    : 6 of 2010 (mode: Prompt (first+last), N=3)
--------------------------------------------------------------------------------
[USER] 2026-04-19 03:30:16
I want to add a destructor cleanup pass to the pipeline...

[CLAUDE] 2026-04-19 03:30:42
Good call. Let me look at the current lifecycle first...

... [2004 turns omitted] ...

[USER] 2026-05-14 11:48:01
ok let's also handle the case where the queue is empty on shutdown
```

## Requirements

- Windows
- PowerShell 7+ (uses ANSI escape codes, parameter sets, and modern sort syntax)
- Claude Code installed; the script only reads session history unless you pass `-Delete`

## Installation

Drop both files into any directory on your `$PATH`:

- `Get-ClaudeCodeSessions.ps1` (the script)
- `Get-ClaudeCodeSessions.format.ps1xml` (display rules for the table view)

Keep them in the same folder. The script auto-loads the sidecar XML via
`$PSScriptRoot`.

## Usage

### Getting help

```powershell
Get-ClaudeCodeSessions -Help          # quick colorized reference
Get-Help Get-ClaudeCodeSessions.ps1 -Detailed   # full PowerShell help
```

### Browse

```powershell
Get-ClaudeCodeSessions                   # newest first, sorted by Folder
Get-ClaudeCodeSessions -Limit 20         # cap output
```

### Open a specific session

```powershell
Get-ClaudeCodeSessions -Open 23 -Prompt 5            # by Index column
Get-ClaudeCodeSessions -Open de8f46e2                # by UUID fragment
Get-ClaudeCodeSessions -Open my-app -PromptEnd 10    # by custom Session name
```

`-Open` accepts an integer (matches `Index`), or a case-insensitive substring
that matches either the filename or the Session name. Substring matches may
return multiple results.

**Tab completion:** press `Tab` after `-Open` to cycle through your actual
session handles — custom titles first (auto-quoted when they contain spaces),
then UUID filenames, each with a folder/timestamp tooltip. The completer
*replaces* the default behavior, so it no longer suggests unrelated files
(`README.md`, `.gitignore`) from the current directory. Title lookups are
cached per file and refresh when a session changes, so repeat presses are fast.

### Show conversation turns

```powershell
Get-ClaudeCodeSessions -Open 23 -Prompt 5        # first 5 + last 5 turns, with gap marker
Get-ClaudeCodeSessions -Open 23 -PromptStart 10  # first 10 turns only
Get-ClaudeCodeSessions -Open 23 -PromptEnd 10    # last 10 turns only
```

Turns are shown in chronological order. When `-Prompt N` is used and the
session has more than 2N turns, a `... [X turns omitted] ...` marker appears
between the two halves so the conversation flow stays readable.

### Search transcripts

```powershell
Get-ClaudeCodeSessions -Search "database migration"    # filter to matching sessions
Get-ClaudeCodeSessions -Search "kiro" -Prompt 3        # search + show context turns
```

Search is case-insensitive literal matching, not regex. Punctuation like
`(`, `[`, or `:` is treated as itself.

### Cleanup

Deletion is built in. The workflow is **preview, then delete the same set**:
run a command with the narrowing selectors to see the table, then re-run the
*identical* command with `-Delete` appended.

```powershell
# 1. Preview: everything untouched in 30+ days
Get-ClaudeCodeSessions -OlderThan 30

# 2. Delete that exact set (prompts before each file)
Get-ClaudeCodeSessions -OlderThan 30 -Delete
```

Selectors combine with logical AND, so you can be surgical:

```powershell
# Tiny AND never-titled sessions, no per-file prompt
Get-ClaudeCodeSessions -SmallerThan 5 -Unnamed -Delete -Confirm:$false

# Dry-run a search-scoped delete (lists victims, deletes nothing)
Get-ClaudeCodeSessions -Search "scratch" -Delete -WhatIf

# Delete one specific session by index
Get-ClaudeCodeSessions -Open 23 -Delete
```

**Safety model:**

- `-Delete` **refuses to run without a selector** (`-Search`, `-Open`,
  `-OlderThan`, `-SmallerThan`, or `-Unnamed`). A bare `-Delete` errors out
  rather than offering to wipe every session you own.
- Deletion is **permanent** — straight `Remove-Item`, no Recycle Bin. The
  per-file confirmation prompt (`ConfirmImpact='High'`) is the safety net.
  Suppress it with `-Confirm:$false` once you trust the preview.
- `-WhatIf` lists exactly what would be removed and touches nothing.

The selectors also work on their own as read-only filters — `-OlderThan 30`
without `-Delete` is just a narrower table.

## Parameters

| Parameter | Description |
|---|---|
| `-Open <int or substring>` | Pick a single session. Integer matches `Index`; substring matches filename or Session name. |
| `-Search <string>` | Filter to sessions whose transcripts contain the given literal phrase. |
| `-Prompt <N>` | Show first N turns and last N turns of each session, with a gap marker between halves if the session has more than 2N turns. |
| `-PromptStart <N>` | Show only the first N turns. Mutually exclusive with `-Prompt`. |
| `-PromptEnd <N>` | Show only the last N turns. Mutually exclusive with `-Prompt`. |
| `-Limit <N>` | Cap the number of sessions returned. 0 (default) = no limit. |
| `-OlderThan <N>` | Keep only sessions older than N days (by `Modified`). 0 (default) disables. |
| `-SmallerThan <N>` | Keep only sessions under N KB. 0 (default) disables. |
| `-Unnamed` | Keep only sessions with no custom `/title`. |
| `-Delete` | Permanently delete the filtered set. Requires a selector; supports `-WhatIf`/`-Confirm`; prompts per file. |
| `-PromptMaxChars <N>` | Truncate each turn's text. Default 600. Use 0 for no truncation. |
| `-IncludeSubagents` | Include subagent transcripts (`subagents/agent-*.jsonl`). Off by default. |
| `-NoColor` | Disable ANSI colors. Useful when piping to a file. Applies to `-Prompt` and `-Help` output. |
| `-Help` | Print a colorized in-script reference and exit. Works without Claude Code installed. |

### Why `-Open` instead of `-File`

`pwsh.exe` reserves `-File` as its own script-launcher argument. Defining
`-File` on a script causes argument hijacking depending on how the script is
invoked. `-Open` reads naturally and avoids the conflict.

## How sessions are identified

| Column | Source |
|---|---|
| `Index` | Position in the sorted list. Stable across calls until a session is added or removed. |
| `Folder` | The `cwd` recorded inside the first user message, shown relative to your home directory. `\` means the home directory itself. |
| `Session` | The custom title set via `/title` in Claude Code. Latest title wins if renamed mid-conversation. Blank if never named. |
| `Modified` | Filesystem mtime of the JSONL. Updates each time the session is written to. |
| `Size` | File size in KB, rounded to integer. |
| `File` | Filename (UUID + `.jsonl`). Each `/exit` and re-enter creates a new file. |

Sessions sort by `Folder` ascending, then `Modified` descending. All sessions
under a project cluster together with the most recent on top.

## Notes

- `-Open <name>` may return multiple results because Claude Code creates a
  new file each time you re-enter a project. That's intentional; you usually
  want the full history under that name.
- The script never *modifies* session files. The only write operation is
  `-Delete`, which removes whole transcripts via `Remove-Item` on `FullPath`
  and refuses to run without a narrowing selector.
- ANSI colors require a terminal that supports them (Windows Terminal,
  modern VS Code terminal, recent ConEmu). Use `-NoColor` when redirecting.
- Custom session titles are pulled from `custom-title` events embedded in
  the JSONL. If you have not run `/title` in a session, that column stays
  empty.
