# Get-ClaudeCodeSessions

PowerShell utility for browsing, reading and cleaning up Claude Code session
transcripts. List every session across every project, see custom titles, read
any conversation, and delete the ones you don't want along with all the hidden
data they own. `Tab` completion on session handles, one confirmation, no
Recycle Bin surprises.

## What it does

Claude Code stores every session as a JSONL file under
`%USERPROFILE%\.claude\projects\<encoded-cwd>\`. After a few months these
accumulate into hundreds of UUID-named files with no obvious way to tell what
is what. This script reads them, extracts the parts that matter (working
directory, custom title, conversation turns), and presents a sorted, indexed,
autosized table.

There are three modes, one per verb:

| Command | Does |
|---|---|
| `Get-ClaudeCodeSessions` | list every session as a table |
| `Get-ClaudeCodeSessions -Open <sel>` | print that session's conversation |
| `Get-ClaudeCodeSessions -Delete <sel>` | delete it and everything it owns |

```
Index Folder         Session                    Index Modified            Size File
----- ------         -------                    ----- --------            ---- ----
    1 \              windows shut down suddenly     1 2026-08-30 17:14:28 2463 a1b2c3d4-1111-4aaa-8bbb-1a2b3c4d5e6f.jsonl
    2 \Code\MyApp32  MyApp32                        2 2026-08-07 19:15:02 5636 b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70.jsonl
    3 \Code\OtherApp otherapp-worker                3 2026-08-06 11:20:44 7952 c3d4e5f6-3333-4ccc-8ddd-3c4d5e6f7081.jsonl
```

Columns are sized to their widest value, so long paths and titles are never
truncated with `...`.

## Requirements

- Windows
- PowerShell 7+ (ANSI escapes, modern sort syntax)
- Claude Code installed. The script only reads unless you pass `-Delete`.

## Installation

Drop both files into any directory on your `$PATH`:

- `Get-ClaudeCodeSessions.ps1` (the script)
- `Get-ClaudeCodeSessions.format.ps1xml` (table display rules)

Keep them in the same folder. The script auto-loads the sidecar XML via
`$PSScriptRoot`.

## Usage

### Getting help

```powershell
Get-ClaudeCodeSessions -Help                     # quick colorized reference
Get-Help Get-ClaudeCodeSessions.ps1 -Detailed    # full PowerShell help
```

### Browse

```powershell
Get-ClaudeCodeSessions                   # sorted by Folder, newest first within each
Get-ClaudeCodeSessions -Limit 20         # cap output
Get-ClaudeCodeSessions | Where-Object Size -lt 5    # objects, not just text
```

### Selectors

`-Open` and `-Delete` take the same selector:

| Form | Meaning |
|---|---|
| `23` | the `Index` column from the table |
| `de8f46e2` | a fragment of the filename / UUID |
| `my-app` | a fragment of the `Session` name (set with `/title`) |
| `*` | everything currently matched (`-Delete` only, and it needs a filter first) |

Substring matches are case-insensitive and may return several sessions, which
is intentional: Claude Code creates a new file each time you re-enter a
project, so one title usually spans several transcripts.

**Tab completion:** press `Tab` after `-Open` or `-Delete` to cycle through your
real session handles, custom titles first (auto-quoted when they contain
spaces), then UUID filenames, each with a folder and timestamp tooltip. The
completer *replaces* the default behavior, so it no longer suggests unrelated
files from the current directory. Title lookups are cached per file and refresh
when a session changes.

### Read a conversation

```powershell
Get-ClaudeCodeSessions -Open 23                      # first and last 10 turns
Get-ClaudeCodeSessions -Open de8f46e2 -Turns 3       # first and last 3
Get-ClaudeCodeSessions -Open my-app -Turns 0         # every turn
Get-ClaudeCodeSessions -Open 23 -MaxChars 0          # no per-turn truncation
```

Turns print in chronological order. When the session has more than `2N` turns a
`... [X turns omitted] ...` marker appears between the two halves.

```
================================================================================
Index    : 4
Folder   : \
Session  : crash triage
File     : d4e5f6a7-4444-4ddd-8eee-4d5e6f708192.jsonl
Modified : 2026-08-27 19:42:40
Size     : 931 KB
Turns    : 2 of 45 (first/last 1)
--------------------------------------------------------------------------------
[USER] 2026-08-25 20:31:34
windows shut down suddenly

... [43 turns omitted] ...

[CLAUDE] 2026-08-27 19:42:33
Done, and verified end to end...
```

### Search transcripts

```powershell
Get-ClaudeCodeSessions -Search "database migration"
Get-ClaudeCodeSessions -Search "kiro" -Open '*'      # search, then read every hit
```

Search is case-insensitive literal matching, not regex. Punctuation like `(`,
`[` or `:` is treated as itself.

### Filters

All combine with logical AND, and all work on their own as read-only table
filters:

```powershell
Get-ClaudeCodeSessions -OlderThan 90                 # untouched for 90+ days
Get-ClaudeCodeSessions -SmallerThan 5 -Unnamed       # tiny and never titled
```

### Cleanup

```powershell
Get-ClaudeCodeSessions -Delete 23              # one session by index
Get-ClaudeCodeSessions -Delete de8f46e2        # by UUID fragment
Get-ClaudeCodeSessions -Delete delete          # every session titled "delete"
Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
```

The last form is the tombstone workflow: run `/title delete` on a session when
you are done with it, then sweep them all later with `-Delete delete`.

Every delete prints the matched set with its full reclaimable size and asks
once:

```
The following 2 session(s) will be PERMANENTLY deleted:

  Index Folder                                     Session                      Xcript KB  Extra KB   Parts
  ----- ------                                     -------                      ---------  --------   -----
  15    \                                          MyApp32                            406     68249       4
  30    \Code\MyApp32                              MyApp32                           5636    shared       4

  transcripts 6042 KB + sidecar/history/scratch 68249 KB = 74291 KB total
  memory\, history.jsonl, .claude.json and paste-cache\ are NOT touched.
  There is no Recycle Bin. This cannot be undone.

Type 'yes' to delete:
```

## What `-Delete` actually removes

A session is **not one file**. Deleting only the transcript leaves behind data
that nothing on the system ever prunes, so `-Delete` sweeps the whole
footprint:

| Path | Contents |
|---|---|
| `projects\<proj>\<uuid>.jsonl` | the transcript |
| `projects\*\<uuid>\subagents\` | subagent transcripts |
| `projects\*\<uuid>\tool-results\` | spilled large tool output |
| `file-history\<uuid>\` | file edit snapshots, often the biggest part |
| `session-env\<uuid>\` | per-session env |
| `tasks\<uuid>\` | task lock and highwatermark |
| `jobs\<first-8-hex>\` | background job state and timeline |
| `%TEMP%\claude\*\<uuid>\` | background task scratch |

It deliberately never touches:

| Path | Why |
|---|---|
| `projects\<proj>\memory\` | shared per **project**, not per session. Deleting it destroys `MEMORY.md` and every auto-memory file. |
| `history.jsonl` | your typed prompts, keyed by `sessionId`. They outlive the transcript and are the only record left of sessions that Claude Code's own `cleanupPeriodDays` reaper has deleted. |
| `.claude.json` | per-project config, trust flags, token counters |
| `paste-cache\` | keyed by content hash, so it cannot be attributed to a session at all |

## Safety model

- **The selector is required.** There is no bare `-Delete`. `-Delete *`
  additionally refuses to run unless `-Search`, `-OlderThan`, `-SmallerThan` or
  `-Unnamed` has narrowed the set, so it can never wipe everything at once.
- **One confirmation.** The matched set is printed, then you must type `yes`.
  Deletion is permanent: there is no Recycle Bin.
- **Running sessions are always skipped.** This also closes an old footgun:
  `-Search <phrase>` used to write that phrase into the live transcript, which
  then matched itself and could delete the session you were sitting in.
- **Orphan detection is global.** A sidecar directory lands wherever the `cwd`
  was when the tool ran, so it can end up under a different project directory
  than its transcript. A sidecar is removed only once no transcript with that
  UUID remains in **any** project directory.
- **Duplicate UUIDs are handled.** The same UUID really can appear as a root
  transcript in two project directories (a session whose `cwd` changed, or one
  relocated by hand). The shared footprint is counted once in the total,
  labelled `shared` in the table, and removed only with the last copy.
- **Preview by reading.** Run the same command with `-Open` instead of
  `-Delete` to see exactly what you are about to lose.

## Parameters

| Parameter | Description |
|---|---|
| `-Open <sel>` | Print the conversation for the matched session(s). |
| `-Delete <sel>` | Permanently delete the matched session(s) and their whole footprint. Requires typing `yes`. |
| `-Search <string>` | Filter to sessions whose transcripts contain the literal phrase. |
| `-Turns <N>` | With `-Open`, turns to print from each end. Default 10, `0` = all. |
| `-MaxChars <N>` | Truncate each turn's text. Default 600, `0` = no truncation. |
| `-OlderThan <N>` | Keep only sessions older than N days (by `Modified`). 0 disables. |
| `-SmallerThan <N>` | Keep only sessions under N KB. 0 disables. |
| `-Unnamed` | Keep only sessions with no custom `/title`. |
| `-Limit <N>` | Cap the number of sessions returned. 0 = no limit. |
| `-IncludeSubagents` | Also list subagent transcripts as their own rows. |
| `-NoColor` | Disable ANSI colors. Useful when redirecting to a file. |
| `-Help` | Print a colorized in-script reference and exit. |

### Why `-Open` instead of `-File`

`pwsh.exe` reserves `-File` as its own script-launcher argument. Defining
`-File` on a script causes argument hijacking depending on how the script is
invoked. `-Open` reads naturally and avoids the conflict.

## How sessions are identified

| Column | Source |
|---|---|
| `Index` | Position in the sorted list. Assigned before the filters run, so numbers stay stable until a session is added or removed. |
| `Folder` | The `cwd` recorded inside the first user message, shown relative to your home directory. `\` means the home directory itself. Falls back to decoding the directory name. |
| `Session` | The custom title set via `/title`. Latest title wins if renamed mid-conversation. Blank if never named. |
| `Modified` | Filesystem mtime of the JSONL. |
| `Size` | File size in KB, rounded. |
| `File` | Filename (UUID + `.jsonl`). Each `/exit` and re-enter creates a new file. |

Sessions sort by `Folder` ascending, then `Modified` descending.

## Notes

- The script never *modifies* session files. The only write operation is
  `-Delete`.
- If `.claude\projects` is redirected into OneDrive, Files-On-Demand marks
  synced directories `ReadOnly + ReparsePoint`. Both `Remove-Item` and
  `Directory.Delete` fail on those with access-denied until the attribute is
  cleared, which this script does before deleting.
- Also beware that `Get-ChildItem -Recurse` will **not** descend a junction, so
  an ad-hoc `~\.claude -Recurse` search finds almost nothing when `projects` is
  a junction. Start the search at `projects` itself. (OneDrive placeholder
  directories use a transparent reparse tag and *are* traversed.)
- ANSI colors require a terminal that supports them (Windows Terminal, modern
  VS Code terminal, recent ConEmu). Use `-NoColor` when redirecting.
- Custom titles come from `custom-title` events embedded in the JSONL. If you
  have never run `/title` in a session, that column stays empty.
