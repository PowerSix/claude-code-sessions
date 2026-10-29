# Get-ClaudeCodeSessions

A PowerShell script for the session transcripts Claude Code piles up under
`~\.claude\projects`. It shows every session in one table, with where it ran,
what you called it, how big it is and what it needs to resume, and prints any
conversation. When you delete a session it takes the hidden data that session
owns along with it, after showing you exactly what that is. `-Orphans` finds
what earlier deletes and moves left behind.

## What it does

Claude Code stores every session as a JSONL file under
`%USERPROFILE%\.claude\projects\<encoded-cwd>\`. After a few months these
accumulate into hundreds of UUID-named files with no obvious way to tell what
is what. This script reads them and shows one sorted, numbered table.

There are four modes:

| Command | Does |
|---|---|
| `Get-ClaudeCodeSessions` | list every session as a table |
| `Get-ClaudeCodeSessions -Open <sel>` | print that session's conversation |
| `Get-ClaudeCodeSessions -Delete <sel>` | delete it and everything it owns |
| `Get-ClaudeCodeSessions -Orphans` | list what deleted and moved sessions left behind |

```
Index Folder         Session                    Index Modified                Size Context Model    File
----- ------         -------                    ----- --------                ---- ------- -----    ----
    1 \              deploy triage                  1 2026-08-30 17:14:28 2,463 KB     87k opus 5.5 a1b2c3d4-1111-4aaa-8bbb-1a2b3c4d5e6f.jsonl
    2 \Code\MyApp32  MyApp32                        2 2026-08-07 19:15:02 5,636 KB    412k opus 5.5 b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70.jsonl
    3 \Code\OtherApp otherapp-worker                3 2026-08-06 11:20:44 7,952 KB    156k opus 4.8 c3d4e5f6-3333-4ccc-8ddd-3c4d5e6f7081.jsonl
```

Columns are sized to their widest value, so long paths and titles are never
truncated with `...`. `Size` is the transcript file alone; the `-Delete` plan
shows everything else a session owns.

## Requirements

- Windows
- PowerShell 7 or later. The script reads JSON with `ConvertFrom-Json
  -AsHashtable`, which Windows PowerShell 5.1 does not have, so it refuses to
  start there (`#Requires -Version 7.0`) rather than quietly reading nothing.
- Claude Code installed. `-Help` works without it. The script only reads
  unless you pass `-Delete`.

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
Get-ClaudeCodeSessions -Limit 20         # the first 20 rows, in that order
Get-ClaudeCodeSessions | Where-Object Size -lt 5    # objects, not just text
```

`-Limit` keeps the first N rows of the table as sorted, so it is not "the 20
newest sessions overall".

### Check what a session needs before resuming it

`Context` is how many tokens the conversation held as of its last reply, and
`Model` is the model that wrote that reply. Together they tell you whether a
session will fit the model you are about to resume it on:

```powershell
Get-ClaudeCodeSessions | Where-Object Context -gt 200000    # 1M-only sessions
```

Anything over 200k got there on a 1M-context (`[1m]`) model and cannot fit a
standard 200k window. Resume it on the `[1m]` variant, or it opens at 100%.
The transcript does not record the `[1m]` flag itself (see
[How sessions are identified](#how-sessions-are-identified)), so for anything
under 200k the window it ran on cannot be read back.

### Selectors

`-Open` and `-Delete` take the same selector:

| Form | Meaning |
|---|---|
| `23` | the `Index` column from the table |
| `d4e5f6a7` | a fragment of the file name / UUID |
| `my-app` | a fragment of the `Session` name (set with `/rename`) |
| `*` | everything currently listed. With `-Delete` it needs a filter first. |

Fragments are literal and case-insensitive, so `[WIP]` means those five
characters, not a wildcard. They may match several sessions; `-Open` prints
each, and `-Delete` plans them all and asks once. A fragment that happens to
match every session (`-` will) is treated like `*` and needs a filter too.

Indexes are assigned before any filter runs, so `-Search x` shows the same
numbers a bare listing would. They do change when a session is added,
removed or written to: the table is newest first within each folder, so a
session that gets a new reply (the one you are working in, say) moves up and
renumbers the ones it passes. That is why the delete plan prints each
target's first prompt: a stale index shows up there before it costs you
anything.

**Tab completion:** press `Tab` after `-Open` or `-Delete` to cycle through
your real session handles, custom titles first, then UUID file names, each
with a folder and timestamp tooltip. A title is quoted whenever PowerShell
would otherwise misread it (spaces, `#`, `,`, `$`, parentheses, a leading
`-`). Title lookups are cached per file and refresh when a session changes.
When nothing matches what you typed, PowerShell falls back to file names; a
completer cannot prevent that.

### Read a conversation

```powershell
Get-ClaudeCodeSessions -Open 23                      # first and last 10 turns
Get-ClaudeCodeSessions -Open d4e5f6a7 -Turns 3       # first and last 3
Get-ClaudeCodeSessions -Open my-app -Turns 0         # every turn
Get-ClaudeCodeSessions -Open 23 -MaxChars 0          # no per-turn truncation
```

Turns print in chronological order. When the session has more than `2N` turns
a `... [X turns omitted] ...` marker appears between the two halves. Records
Claude Code writes on its own (command caveats, the "this session is being
continued" summary after a compaction, background task notifications) are
left out, so what you read is what was said.

```
================================================================================
Index    : 4
Folder   : \
Session  : deploy triage
File     : d4e5f6a7-4444-4ddd-8eee-4d5e6f708192.jsonl
Modified : 2026-08-27 19:42:40
Size     : 931 KB
Context  : 131,507 tokens
Model    : claude-opus-5-5
Turns    : 2 of 45 (first/last 1)
--------------------------------------------------------------------------------
[USER] 2026-08-26 09:14:05
the staging deploy hangs at the migrate step

... [43 turns omitted] ...

[CLAUDE] 2026-08-27 19:42:33
Done, and verified end to end...
```

### Search transcripts

```powershell
Get-ClaudeCodeSessions -Search "database migration"
Get-ClaudeCodeSessions -Search 'C:\work\api'               # paths work as typed
Get-ClaudeCodeSessions -Search "terraform" -Open '*'       # search, then read every hit
```

Search is case-insensitive literal matching, not regex, so `(`, `[` or `:`
mean themselves. Transcripts store a backslash as `\\` and a quote as `\"`;
the phrase is tried both as typed and in that escaped form, so a path search
finds what it should.

Searching from inside a Claude Code session also matches that session, since
the prompt holding the phrase is logged to its transcript. `-Delete` never
deletes the running session, so the extra hit is harmless.

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
Get-ClaudeCodeSessions -Delete d4e5f6a7        # by UUID fragment
Get-ClaudeCodeSessions -Delete delete          # every session titled "delete"
Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
```

The third form is the tombstone workflow: `/rename delete` a session when you
are done with it, then sweep them all later with `-Delete delete`.

Every delete prints a plan first: each part about to go, with its real path,
file count and size, then what the delete would leave behind, then what is
kept either way. It asks once:

```
The following 1 session(s) will be PERMANENTLY deleted:

  [2] MyApp32  in \Code\MyApp32
  first prompt: add a retry with backoff to the upload step
  session ID b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70

    Part                      Files         Size  Path
    ----                      -----         ----  ----
    transcript                    1     5,636 KB  ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70.jsonl
    subagent transcripts          2       141 KB  ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70\subagents
    saved tool output             3        96 KB  ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70\tool-results
    file snapshots (/rewind)    166     1,148 KB  ~\.claude\file-history\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70
    session env                   0         0 KB  ~\.claude\session-env\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70
    background task output        2         4 KB  %TEMP%\claude\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70

  Total: 7,025 KB in 174 file(s).
  Also removed, since they end up empty: %TEMP%\claude\C--Users-you-Code-MyApp32

  Left behind, unless you answer 'all':
    memory                        3        12 KB  ~\.claude\projects\C--Users-you-Code-MyApp32\memory
      dormant: \Code\MyApp32 still exists, so this memory would load again in a new session there
      memory files: build-notes.md, MEMORY.md, release-checklist.md
    backup                        1     3,510 KB  ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70.jsonl.20261008-020817.bak
      backup file (.bak)
    then the dirs left empty: ~\.claude\projects\C--Users-you-Code-MyApp32
    'all' adds 3,522 KB in 4 file(s).

  Kept either way:
    your project folders themselves (CLAUDE.md included), history.jsonl, .claude.json, paste-cache\
  There is no Recycle Bin. This cannot be undone.

Type 'yes' to delete, or 'all' to also remove what it leaves behind:
```

| Answer | Does |
|---|---|
| `yes` | deletes the sessions and everything they own, as listed |
| `all` | also removes everything under *Left behind*, so there is nothing to clean up afterwards with `-Orphans` |
| anything else | aborts, nothing is deleted |

*Left behind* is only what **this** delete leaves: the folder's memory when
this is its last session (dormant or not, since you see it listed before you
answer), stray files and backups in that folder, and leftovers anywhere that
carry this session's ID. Unrelated orphans elsewhere are never swept by
`all`; that is what `-Orphans` is for. When nothing would be left behind, the
prompt only offers `yes`.

**Your home folder's memory is never removed**, by any answer or mode. It is
the memory every session started in your profile root shares, so deleting the
last session there keeps it and the plan says so.

If the same session ID also lives in another folder (a moved or copied
session), only the transcript goes and the plan says the rest is kept for the
surviving copy. With `all`, what the deleted copy leaves in its own folder
goes too, except anything a remaining transcript still mentions.

A file in a project dir whose name is not a session ID (`notes.jsonl`, say)
is listed like any transcript but deleted on its own: only a real session ID
has a footprint to sweep.

## What `-Delete` actually removes

A session is **not one file**. Deleting only the transcript leaves the rest
behind with nothing pointing at it, so `-Delete` sweeps the whole footprint:

| Path | Shown in the plan as | Contents |
|---|---|---|
| `projects\<proj>\<uuid>.jsonl` | transcript | the conversation itself |
| `projects\*\<uuid>\subagents\` | subagent transcripts | conversations of subagents the session ran |
| `projects\*\<uuid>\tool-results\` | saved tool output | tool output too large to keep inline |
| any other file in `projects\*\<uuid>\` | sidecar file | small per-session files, such as a saved title |
| `file-history\<uuid>\` | file snapshots (/rewind) | copies of edited files, often the biggest part |
| `session-env\<uuid>\` | session env | per-session environment, usually empty |
| `tasks\<uuid>\` | task list state | task lock and highwatermark |
| `jobs\<first-8-hex>\` | background jobs | background job state and timeline |
| `%TEMP%\claude\*\<uuid>\` | background task output | output of background shell tasks |

A sidecar or `%TEMP%` dir that another session's transcript still mentions is
kept, and the plan names that session next to the dir (see
[Orphans](#orphans) for why a mere mention counts). `jobs\` is keyed by only the first 8
characters of the session ID, so it is kept when another session shares them.

Answered `yes`, it never touches:

| Path | Why |
|---|---|
| `projects\<proj>\memory\` | shared per **project**, not per session. Deleting it destroys `MEMORY.md` and every auto-memory file. `all` removes it only when this was the folder's last session, and never for your home folder. |
| your project folder | its `CLAUDE.md` and everything else in it. The tool only works inside `.claude` and `%TEMP%\claude`. |
| `history.jsonl` | your typed prompts, keyed by `sessionId`. They outlive the transcript and are the only record left of sessions that Claude Code's own `cleanupPeriodDays` reaper has deleted. Never touched by any mode. |
| `.claude.json` | per-project config, trust flags, token counters. Never touched by any mode. |
| `paste-cache\` | keyed by content hash, so it cannot be attributed to a session at all. Never touched by any mode. |

## Orphans

Deleted and moved sessions leave things behind, mostly memory: `-Delete`
keeps a project's `memory\` by design, so when a folder's last session goes,
its memory stays. `-Orphans` lists everything no live session can reach, with
a reason for each:

```
Index State   Kind        Folder               Files     Size Last write Why                                      Path
----- -----   ----        ------               -----     ---- ---------- ---                                      ----
   o1 orphan  memory      \old-demo                8    27 KB 2026-07-17 no sessions; folder gone                 ~\.claude\projects\C--Users-you-old-demo\memory
   o2 dormant memory      \Talks\Agents 101        8    41 KB 2026-10-28 no sessions; folder exists               ~\.claude\projects\C--Users-you-Talks-Agents-101\memory
   o3 orphan  project     \scratch-blog            0     0 KB 2026-10-09 no sessions, no memory                   ~\.claude\projects\C--Users-you-scratch-blog
   o4 orphan  backup      \Code\MyApp32            1 3,510 KB 2026-10-08 backup file (.bak)                       ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70.jsonl.20261008-020817.bak
   o5 orphan  stray       \Code\OtherApp           1     3 KB 2026-09-02 misplaced; only memory\MEMORY.md is read ~\.claude\projects\C--Users-you-Code-OtherApp\MEMORY.md
   o6 orphan  session-env (various)                0     0 KB 2026-10-28 22 empty dirs; session gone              ~\.claude\session-env\e5f6a7b8-5555-4eee-8fff-5e6f708192a3 (+21 more)
```

**State** is the part that matters:

- `orphan`: nothing will ever read it again.
- `dormant`: memory that may load again. Usually its folder still exists, so
  it loads the moment you start a session there. A folder on a drive or share
  that is not connected, or one Claude Code never recorded, is dormant too,
  because it cannot be shown to be gone. `*`, a kind and a path fragment never
  take dormant memory; only its `o#` or the word `dormant` does.

To tell the two apart, the tool needs each project dir's original folder.
The dir name cannot give it back (the encoding turns every non-alphanumeric
character into `-`), so every folder Claude Code ever recorded is re-encoded
and matched instead: the `.claude.json` project keys and `history.jsonl`,
whose entries outlive their transcripts. Your home folder's memory is never
listed at all, because nothing in this tool will ever remove it.

| Kind | What | Listed when |
|---|---|---|
| `memory` | a project's `memory\` | the project has no sessions left |
| `project` | a project dir | it holds no sessions and no memory |
| `sidecar` | `projects\<proj>\<uuid>\` | its session is gone, or the session moved, and no live transcript mentions it |
| `backup` | `*.bak` in a project dir | always (a hand-made session move leaves these) |
| `stray` | `MEMORY.md` loose in a project dir | always: only `memory\MEMORY.md` is read |
| `file-history`, `session-env`, `tasks` | `<store>\<uuid>\` | its session is gone |
| `jobs` | `jobs\<first-8-hex>\` | no live session has that ID prefix |
| `temp` | `%TEMP%\claude\<proj>\...` | its session is gone or moved and no live transcript mentions it, or the dir is empty |
| `registry` | `sessions\<pid>.json` and its `.key` | that process is gone |

Empty dirs of one kind fold into one row (`22 empty dirs`); the path shows the
first one and how many more.

**Moved sessions keep reading their old location.** Claude Code records large
tool output and background task output by absolute path, so a session that
was moved to another folder still points at its old sidecar and `%TEMP%` dir.
A copy made under a new session ID still reads the old ID's files. So a
sidecar or temp dir is listed only when no live transcript mentions it, in
any spelling, whichever session that transcript belongs to. A transcript that
cannot be read counts as a mention, and so does one that merely discussed the
path (a session spent debugging these very folders will pin them), because
the two cannot be told apart. Nothing is hidden silently: the listing ends
with how many dirs were held back and which transcripts hold them, and the
`-Delete` plan names the session next to each dir it keeps:

```
    Kept, because another session's transcript still points there:
      ~\.claude\projects\C--Users-you-Code-MyApp32\b2c3d4e5-2222-4bbb-8ccc-2b3c4d5e6f70  <- [7] release notes in \Code\MyApp32
```

**What cannot be checked is never called an orphan.** If the project dirs
cannot all be listed, `-Orphans` lists nothing and says it could not check. A
dir that cannot be read is skipped with a warning, never treated as empty,
and a row that could not be read in full says so in its `Why` (its size is a
floor, not a measurement).

Remove what it found with the same one-confirmation plan:

```powershell
Get-ClaudeCodeSessions -Orphans -Delete *            # every orphan, never dormant memory
Get-ClaudeCodeSessions -Orphans -Delete o2           # one row, dormant or not
Get-ClaudeCodeSessions -Orphans -Delete backup       # one kind
Get-ClaudeCodeSessions -Orphans -Delete b2c3d4e5     # any orphan whose path contains this
```

It asks for `yes` only, and after the answer checks every item against the
disk again: anything that stopped being an orphan meanwhile (a session
started in that folder, a transcript began mentioning that sidecar) is kept.
A project dir or `%TEMP%` dir this leaves empty is removed too. Memory items
in the plan list their file names, so you can see what knowledge you are
throwing away.

## Safety model

- **The selector is required.** There is no bare `-Delete`. `-Delete *`
  refuses to run unless `-Search`, `-OlderThan`, `-SmallerThan` or `-Unnamed`
  has narrowed the set (`-Limit` does not count), and so does any fragment
  that matches every session, so nothing can wipe everything at once.
- **One confirmation, and the plan is the contract.** The plan is printed,
  then you type `yes` or `all`. Deletion is permanent: there is no Recycle
  Bin. Nothing the plan did not show is ever removed. After your answer the
  disk is checked again, and that can only keep more: a session that started
  meanwhile is skipped, a copy that appeared keeps the shared data, a
  leftover that is no longer an orphan stays.
- **The home folder's memory is never removed**, by any answer or mode.
- **The running copy of a session is always skipped.** When a session lives
  in two folders, the registry's `cwd` says which copy the live process
  writes, so the other copy stays deletable. If that cannot be pinned down,
  every copy is protected. If a running session's registry entry cannot be
  read at all, nothing is deleted until it can.
- **Ambiguous selectors are refused.** A UUID fragment or title that matches
  both copies of a moved session would delete both, so it stops and lists the
  copies' indexes instead. `*` after a filter still takes everything matched.
- **Indexes never shift under `-Search`.** A row's `Index` is the same with or
  without it, so `-Search x` followed by `-Delete <n>` hits the session you
  saw. Sessions being written to can still move; the plan's first prompt is
  the check.
- **The footprint is found everywhere.** A sidecar directory lands wherever
  the `cwd` was when the tool ran, so it can end up under a different project
  directory than its transcript. A sidecar goes with `-Delete` only once no
  transcript with that UUID remains in **any** project directory, and never
  while another transcript still mentions it.
- **Duplicate UUIDs are handled.** The same UUID really can appear as a root
  transcript in two project directories (a session whose `cwd` changed, or one
  relocated by hand). The copies share one footprint, listed once, and it is
  removed only with the last copy.
- **Unknown is never empty.** A transcript that cannot be read keeps its
  place in the numbering and is reported, not shown as an empty session. A
  project dir that cannot be listed is reported, and a delete then keeps the
  session's shared data, since the dir it cannot see might hold a copy or a
  reference.
- **Orphan cleanup is conservative.** `-Orphans -Delete *` never takes dormant
  memory. `-Delete o3` without `-Orphans` is refused rather than treated as a
  session selector. Unrecognized files in project dirs are never listed, since
  a newer Claude Code may be the one writing them, and nothing that belongs to
  a running session is listed either.
- **Preview by answering no.** The plan is the preview; nothing happens until
  you type `yes` or `all`.

## Parameters

| Parameter | Description |
|---|---|
| `-Open <sel>` | Print the conversation for the matched session(s). |
| `-Delete <sel>` | Permanently delete the matched session(s) and their whole footprint. Requires typing `yes`, or `all` to also remove what the delete leaves behind. |
| `-Orphans` | List what no live session can reach. With `-Delete`, remove them: `o#`, a kind, `dormant`, a path fragment, or `*` (orphans only). |
| `-Search <string>` | Filter to sessions whose transcripts contain the literal phrase. Backslashes and quotes are matched as typed. |
| `-Turns <N>` | With `-Open`, turns to print from each end. Default 10, `0` = all. |
| `-MaxChars <N>` | Truncate each turn's text. Default 600, `0` = no truncation. |
| `-OlderThan <N>` | Keep only sessions older than N days (by `Modified`). 0 disables. |
| `-SmallerThan <N>` | Keep only sessions under N KB. 0 disables. |
| `-Unnamed` | Keep only sessions with no custom title (`/rename`). |
| `-Limit <N>` | Keep the first N rows left after the filters, in table order. 0 = no limit. |
| `-IncludeSubagents` | Also list subagent transcripts, without an Index, right under their session. They are deleted with it, never on their own. |
| `-NoColor` | Disable ANSI colors. Useful when redirecting to a file. |
| `-Help` | Print a colorized in-script reference and exit. |

### Why `-Open` instead of `-File`

`pwsh.exe` reserves `-File` as its own script-launcher argument. Defining
`-File` on a script causes argument hijacking depending on how the script is
invoked. `-Open` reads naturally and avoids the conflict.

## How sessions are identified

| Column | Source |
|---|---|
| `Index` | Position in the sorted list, root transcripts only. Assigned before every filter runs, `-Search` included. Changes when a session is added, removed or written to. |
| `Folder` | The `cwd` recorded on the session's first turn, shown relative to your home directory. `\` means the home directory itself. Without one, the folder Claude Code recorded for that project dir, and only then the dir name decoded, which is a guess. |
| `Session` | The custom title set with `/rename`. Latest title wins if renamed mid-conversation. Blank if never named. |
| `Modified` | Filesystem mtime of the JSONL. |
| `Size` | The transcript file alone, in KB, rounded up (a 300-byte file shows `1 KB`, as in Explorer). The rest of a session's footprint shows in the `-Delete` plan. |
| `Context` | Tokens in context as of the last reply: input + cache writes + cache reads + output from that reply's `usage`. This is the same sum Claude Code uses (its own compaction records match it to the token). If the session was compacted after its last reply, it is the compacted size. Shown in decimal `k`, rounded half up, because windows are quoted as 200k / 1M; `<1k` under 1,000. Blank if nothing ever replied. |
| `Model` | `message.model` of the last reply, e.g. `claude-opus-5-5`, displayed as `opus 5.5`. The object keeps the raw name for filtering. |
| `File` | The file name: the session ID plus `.jsonl`. |

Two traps if you read these fields yourself:

- **Never sum `usage` across records.** One API response is written as several
  assistant records (thinking, text, tool_use), and each repeats the same
  `usage` block. Take the last one. Skip `<synthetic>` records too: those are
  timeouts and API errors with zero usage.
- **`message.model` is the bare API name.** It never carries a provider prefix
  (such as a Bedrock inference profile) or the `[1m]` flag, so a 1M session
  and a 200k session on the same model look identical. Context over 200k is the
  only reliable tell.

Sessions sort by `Folder` ascending, then `Modified` descending.

## Notes

- The script never *modifies* session files. The only write operations are
  `-Delete` and `-Orphans -Delete`.
- If `.claude\projects` is redirected into OneDrive, Files-On-Demand marks
  synced directories `ReadOnly + ReparsePoint`. Both `Remove-Item` and
  `Directory.Delete` fail on those with access-denied until the attribute is
  cleared, which this script does before deleting.
- Also beware that `Get-ChildItem -Recurse` will **not** descend a junction, so
  an ad-hoc `~\.claude -Recurse` search finds almost nothing when `projects` is
  a junction. Start the search at `projects` itself. (OneDrive placeholder
  directories use a transparent reparse tag and *are* traversed.)
- The script sets its own `Set-StrictMode -Version 1.0`, so a stricter mode
  in your profile cannot change how it reads transcripts.
- ANSI colors require a terminal that supports them (Windows Terminal, modern
  VS Code terminal, recent ConEmu). Use `-NoColor` when redirecting.
- Custom titles come from `custom-title` events embedded in the JSONL. If you
  have never run `/rename` in a session, that column stays empty.
