<#
.SYNOPSIS
    Lists, reads and deletes Claude Code sessions, and finds what deleted
    sessions left behind.

.DESCRIPTION
    Lists or searches the .jsonl session transcripts Claude Code stores under
    $env:USERPROFILE\.claude\projects.  Each project directory's name is the
    cwd with every non-alphanumeric character replaced by '-'.  This script
    scans every project directory and reports a Folder column showing the
    original cwd relative to the user's home (e.g. '\' for the home dir
    itself, '\Projects\my-app' for a subfolder).

    Folder comes from the cwd recorded on the session's first turn.  Without
    one it is the folder Claude Code recorded for that project directory
    (.claude.json, history.jsonl), and only then the directory name decoded,
    which is a guess: '-' stood for any character.

    Requires PowerShell 7.

    Four modes:
      (no selector)    table of every session, by Folder, newest first in each
      -Open <sel>      print that session's conversation
      -Delete <sel>    permanently remove that session and everything it owns
      -Orphans         list what deleted and moved sessions left behind

    WHY -Delete REMOVES MORE THAN THE .jsonl
    A session is not one file.  Alongside the root <uuid>.jsonl it owns a
    sidecar directory (subagents\ and tool-results\), a file-history\<uuid>
    tree of edit snapshots, a session-env\<uuid> dir, a tasks\<uuid> dir, a
    jobs\<first-8-hex> dir, and background task output under %TEMP%\claude.
    Removing only the transcript leaves all of that behind with nothing
    pointing at it.  -Delete therefore sweeps the whole footprint.  Answered
    'yes', it deliberately does NOT touch:

      memory\        shared per PROJECT, not per session - deleting it would
                     destroy MEMORY.md and every auto-memory file
      history.jsonl  your typed prompts, keyed by sessionId, which survive
                     the transcript and are the only record of sessions that
                     Claude Code's own cleanupPeriodDays reaper has eaten
      .claude.json   per-project config, trust flags and token counters
      paste-cache\   keyed by content hash, so it cannot be attributed to a
                     session at all

    Answered 'all', it also removes what the delete leaves behind, which can
    include the folder's memory\ (see -Delete).  No mode ever touches
    history.jsonl, .claude.json, paste-cache\ or the memory of your home
    folder.

    A session's sidecar can live under a DIFFERENT project directory than its
    transcript, because the sidecar lands wherever the cwd was when the tool
    ran.  So the footprint is looked for in every project directory, and it
    goes only once no root transcript with that session ID remains in any
    of them.

    OneDrive note: if .claude\projects is redirected into OneDrive, Files-On-
    Demand marks directories ReadOnly + ReparsePoint.  Deleting those fails
    with access-denied until the attribute is stripped, which this script does.

    CONTEXT AND MODEL COLUMNS
    Context is the conversation's size as of the last reply: input + cache
    writes + cache reads + output from that reply's usage block.  It is the
    same sum Claude Code uses (its own compaction records match it to the
    token), so it is the number you will see on resume.  Model is the API
    model name of that reply.  Neither the Bedrock profile nor the [1m] flag
    is recorded per message, so the window a session ran on cannot be read
    back.  A Context over 200k is the exception: it only fits a 1M window, so
    resume that session on the [1m] variant or it opens at 100%.

    ORPHANS
    -Orphans lists what no live session can reach any more.  Most of it is
    memory: -Delete keeps a project's memory\ by design, so when a folder's
    last session goes, its memory stays behind.  Whether that memory is dead
    depends on its folder, which the encoded dir name cannot tell you (the
    encoding is lossy).  So every cwd Claude Code ever recorded is
    re-encoded and matched: the .claude.json project keys and history.jsonl,
    whose entries outlive their transcripts.  Folder gone = 'orphan'.
    Folder still there = 'dormant', because the memory loads again the
    moment you start a session in it.  A folder on a drive or share that is
    not connected, or one never recorded, is 'dormant' too: it cannot be
    shown to be gone.  '*' never sweeps dormant memory.

    A session that moved leaves its old sidecar and %TEMP% dir behind.  Those
    are listed only when no live transcript mentions them, not just the
    session's own: Claude Code records spilled tool output by absolute path,
    a moved transcript really does keep reading the old location, and a copy
    made under a new session ID keeps reading the old ID's files.  A
    transcript that cannot be read counts as a reference.  So does one that
    only discussed a path, since the two cannot be told apart; the listing
    says how many dirs it held back and which transcripts hold them, and
    the -Delete plan names the session next to each dir it keeps.

    What cannot be checked is never called an orphan.  If the project
    directories cannot all be listed, nothing is listed; a directory that
    cannot be read is skipped, not treated as empty; and a row that could
    not be read in full says so.

.PARAMETER Search
    Phrase to search for inside session transcripts. Case-insensitive,
    literal (not regex). Returns only sessions matching. Type backslashes
    and quotes as they are: the transcript stores them escaped, and both
    forms are tried, so -Search 'C:\work\api' finds a path.

    Searching from inside a Claude Code session also matches that session,
    because the prompt holding the phrase is logged to its transcript.
    -Delete never deletes the running session, so the match is harmless.

.PARAMETER Open
    Select sessions and print their conversation. Selector forms:
      - Integer:   matches the Index column from the table view
      - Substring: matches the file name without .jsonl (a UUID fragment
                   is fine)
      - Substring: matches the Session name (the title set with /rename)
      - '*':       every session currently listed
    Substring matches are literal and case-insensitive and may return
    several sessions, in which case each is printed in turn.

    Indexes are assigned after sorting and BEFORE every filter, -Search
    included, so '-Search x' shows the same Index a bare listing would.
    They change when a session is added or removed, and when one is written
    to: the table is newest first within each folder, so a session that
    gets a new reply (the one you are working in, say) moves up and
    renumbers the ones it passes. -Delete prints each target's first prompt
    before asking, so a shifted index shows up before it costs anything.

    With -IncludeSubagents, subagent transcripts are listed under their
    session with no Index; select one by its file name (agent-...).

    Note: this is named -Open instead of -File because pwsh.exe treats
    -File as its own script-launcher argument and would eat the value.

.PARAMETER Delete
    Select sessions and permanently delete them, along with their sidecar,
    file-history, session-env, tasks, jobs and %TEMP% data. Accepts the same
    selector forms as -Open, with two guards so nothing can wipe every
    session at once: '*' requires at least one narrowing filter (-Search,
    -OlderThan, -SmallerThan or -Unnamed; -Limit does not count), and so
    does any fragment that happens to match every session.

    The plan lists every part about to go (transcript, subagent transcripts,
    saved tool output, file snapshots and so on) with its real path, file
    count and size, then what the delete would leave behind, then what is
    kept either way, and asks once. Deletion is permanent, with no Recycle
    Bin.

      yes   delete the sessions and everything they own
      all   also remove what that leaves behind: the folder's memory when
            this is its last session (dormant or not), stray files and
            backups there, and leftovers carrying this session's ID. Only
            this delete's leftovers; unrelated orphans stay for -Orphans.

    Any other answer, an empty one included, deletes nothing.

    The memory of your home folder ($env:USERPROFILE) is never removed, by
    any answer or mode.

    The copy of a session that is running right now is always skipped. When
    one session lives in two folders, the registry's cwd says which copy is
    live; if that cannot be pinned down, every copy is protected. If a
    running session's registry entry cannot be read at all, nothing is
    deleted. A UUID fragment or title that matches both copies is refused:
    pick one by index.

    A file whose name is not a session ID (notes.jsonl, say) is deleted on
    its own: only a real session ID has a footprint to sweep. A sidecar or
    %TEMP% dir that another session's transcript still mentions is kept.

    The answer is checked against a fresh look at the disk before anything
    goes: a session that started meanwhile is skipped, the shared data stays
    if a copy appeared, and a leftover goes only if it is still an orphan.

    With -Orphans, -Delete selects from the orphan list instead: an o#
    index, a kind (memory, backup, session-env, ...), 'dormant', a path
    fragment, or '*' for every orphan. A kind, a fragment and '*' take
    orphans only; dormant memory needs its o# or the word 'dormant'.

.PARAMETER Orphans
    List leftovers no live session can reach: memory of folders with no
    sessions left, empty project dirs, sidecars of deleted sessions,
    unreferenced leftovers of moved sessions, .bak files, a misplaced
    MEMORY.md, the file-history, session-env and tasks dirs of deleted
    sessions, jobs dirs no session matches, %TEMP% dirs of deleted sessions
    and empty ones, and dead registry entries. Each row says why it is
    listed. Combine with -Delete to remove; that asks for 'yes' only, and
    checks every item against the disk again after the answer.

.PARAMETER Turns
    With -Open, how many turns to print from each end of the conversation.
    Default 10. Use 0 to print every turn. If the session has 2N or fewer
    turns all of them are shown; otherwise a marker reports how many were
    omitted from the middle.

.PARAMETER MaxChars
    Truncate each turn's text to this many characters. Default 600. Use 0
    for no truncation.

.PARAMETER OlderThan
    Keep only sessions whose Modified time is older than N days. Combines with
    the other filters (logical AND). 0 (default) disables the filter.

.PARAMETER SmallerThan
    Keep only sessions whose Size (KB) is below N. Useful for sweeping tiny,
    abandoned sessions. 0 (default) disables the filter.

.PARAMETER Unnamed
    Keep only sessions with no custom title (the one set with /rename).
    Combines with the other filters.

.PARAMETER Limit
    Show only the first N rows left after the filters, in table order (by
    Folder, then newest first), so not the N newest overall. 0 (default)
    means no limit.

.PARAMETER IncludeSubagents
    Include subagent transcripts (<uuid>\subagents\agent-*.jsonl) as rows of
    their own, right under their session and without an Index: they belong
    to it and are deleted with it, never on their own. Off by default.

.PARAMETER NoColor
    Disable ANSI colors. Useful when piping to a file.

.PARAMETER Help
    Show a short colored reference and exit.

.EXAMPLE
    Get-ClaudeCodeSessions
    Table view of every session across every project.

.EXAMPLE
    Get-ClaudeCodeSessions -Open 23
    Print session #23 from the table, first and last 10 turns.

.EXAMPLE
    Get-ClaudeCodeSessions -Open d4e5f6a7 -Turns 0
    Print the whole conversation for the session whose file name contains
    'd4e5f6a7'.

.EXAMPLE
    Get-ClaudeCodeSessions -Delete 23
    Delete session #23 and everything it owns, after one confirmation.

.EXAMPLE
    Get-ClaudeCodeSessions -Delete delete
    Delete every session whose title contains 'delete' - the tombstone
    workflow: '/rename delete' a session when you are done with it, then
    sweep them all later.

.EXAMPLE
    Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
    Sweep tiny sessions untouched for 90 days. Run it without -Delete first
    to see exactly what would go.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'database migration'
    Find sessions in any project folder mentioning the phrase.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'C:\work\api'
    Sessions that mention a path. Backslashes are matched as typed.

.EXAMPLE
    Get-ClaudeCodeSessions | Where-Object Size -lt 5
    Tiny or abandoned sessions - cleanup candidates.

.EXAMPLE
    Get-ClaudeCodeSessions | Where-Object Context -gt 200000
    Sessions too big for a standard 200k window. Resume these on a [1m]
    model, or they open at 100%.

.EXAMPLE
    Get-ClaudeCodeSessions -Orphans
    What deleted and moved sessions left behind, with sizes and paths.

.EXAMPLE
    Get-ClaudeCodeSessions -Orphans -Delete *
    Remove every orphan. Dormant memory is never included; name it with its
    o# (for example -Orphans -Delete o3) if you really want it gone.
#>
# 7.0 because ConvertFrom-Json -AsHashtable and -Depth do not exist in Windows
# PowerShell 5.1, and every such call sits inside a try: 5.1 would not fail,
# it would silently read nothing.
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Search,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        # Offers session handles instead of file names: custom titles first,
        # then UUIDs. (When nothing here matches what was typed, PowerShell
        # falls back to suggesting files; a completer cannot prevent that.)
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $root)) { return }
        $word = $wordToComplete.Trim("'", '"')
        # Get-Variable, not $global:..., which throws under any StrictMode
        # before the first completion has created it.
        $cache = Get-Variable -Name CCSessionTitleCache -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($cache -isnot [hashtable]) { $cache = @{}; $global:CCSessionTitleCache = $cache }
        $titles = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $files  = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $homePath = $env:USERPROFILE.TrimEnd('\')
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
            foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -Force -ErrorAction SilentlyContinue) {
                $stem = $file.BaseName
                # Title lookups read whole transcripts, so cache them keyed by
                # path and invalidate on LastWriteTime.
                $entry = $cache[$file.FullName]
                if (-not $entry -or $entry.Mtime -ne $file.LastWriteTimeUtc.Ticks -or -not $entry.ContainsKey('Folder')) {
                    $title = ''
                    foreach ($h in (Select-String -LiteralPath $file.FullName -Pattern 'custom-title' -ErrorAction SilentlyContinue)) {
                        try { $t = [string]($h.Line | ConvertFrom-Json -ErrorAction Stop).customTitle } catch { continue }
                        if ($t) { $title = $t }
                    }
                    # The folder for the tooltip comes from the recorded cwd:
                    # decoding the dir name is lossy ('-' was any character).
                    $folder = $dir.Name
                    $cwdHit = Select-String -LiteralPath $file.FullName -Pattern '"cwd":"((?:[^"\\]|\\.)*)"' -List -ErrorAction SilentlyContinue
                    if ($cwdHit) {
                        $cwdPath = $cwdHit.Matches[0].Groups[1].Value -replace '\\\\', '\'
                        $folder = if ($cwdPath -ieq $homePath) { '\' } elseif ($cwdPath.StartsWith("$homePath\", [System.StringComparison]::OrdinalIgnoreCase)) { $cwdPath.Substring($homePath.Length) } else { $cwdPath }
                    }
                    $entry = @{ Mtime = $file.LastWriteTimeUtc.Ticks; Title = $title; Folder = $folder }
                    $cache[$file.FullName] = $entry
                }
                $when = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                if (-not $word -or $stem.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $files.Add([System.Management.Automation.CompletionResult]::new(
                        $stem, $stem, 'ParameterValue', ('{0}  {1}' -f $entry.Folder, $when)))
                }
                $title = $entry.Title
                if ($title -and (-not $word -or $title.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and $seen.Add($title)) {
                    # Quote anything that is not plain word characters, or the
                    # parser gets it: '#x' starts a comment, 'a,b' is an array,
                    # '$x' expands, '(x)' runs x, and a leading '-' is a parameter.
                    $completion = if ($title -match '^[\w.][\w.-]*$') { $title } else {
                        "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($title) + "'"
                    }
                    $titles.Add([System.Management.Automation.CompletionResult]::new(
                        $completion, $title, 'ParameterValue', ("Session: {0}  ({1}, {2})" -f $title, $entry.Folder, $when)))
                }
            }
        }
        $out = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $out.AddRange($titles); $out.AddRange($files)
        return $out
    })]
    [string]$Open,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        # With -Orphans, -Delete takes orphan selectors instead. Their o#
        # indexes need a full scan, so offer the kind names; o# comes from
        # reading the -Orphans listing.
        if ($fakeBoundParameters.ContainsKey('Orphans')) {
            return @('*', 'memory', 'project', 'sidecar', 'backup', 'stray', 'file-history', 'session-env', 'tasks', 'jobs', 'temp', 'registry') |
                Where-Object { -not $wordToComplete -or $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "orphan kind: $_") }
        }

        # Same completer as -Open. Duplicated rather than shared because a
        # script's param() block must be its first statement, so there is
        # nowhere earlier to define a shared completer class or function.
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $root)) { return }
        $word = $wordToComplete.Trim("'", '"')
        # Get-Variable, not $global:..., which throws under any StrictMode
        # before the first completion has created it.
        $cache = Get-Variable -Name CCSessionTitleCache -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($cache -isnot [hashtable]) { $cache = @{}; $global:CCSessionTitleCache = $cache }
        $titles = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $files  = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $homePath = $env:USERPROFILE.TrimEnd('\')
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
            foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -Force -ErrorAction SilentlyContinue) {
                $stem = $file.BaseName
                $entry = $cache[$file.FullName]
                if (-not $entry -or $entry.Mtime -ne $file.LastWriteTimeUtc.Ticks -or -not $entry.ContainsKey('Folder')) {
                    $title = ''
                    foreach ($h in (Select-String -LiteralPath $file.FullName -Pattern 'custom-title' -ErrorAction SilentlyContinue)) {
                        try { $t = [string]($h.Line | ConvertFrom-Json -ErrorAction Stop).customTitle } catch { continue }
                        if ($t) { $title = $t }
                    }
                    # The folder for the tooltip comes from the recorded cwd:
                    # decoding the dir name is lossy ('-' was any character).
                    $folder = $dir.Name
                    $cwdHit = Select-String -LiteralPath $file.FullName -Pattern '"cwd":"((?:[^"\\]|\\.)*)"' -List -ErrorAction SilentlyContinue
                    if ($cwdHit) {
                        $cwdPath = $cwdHit.Matches[0].Groups[1].Value -replace '\\\\', '\'
                        $folder = if ($cwdPath -ieq $homePath) { '\' } elseif ($cwdPath.StartsWith("$homePath\", [System.StringComparison]::OrdinalIgnoreCase)) { $cwdPath.Substring($homePath.Length) } else { $cwdPath }
                    }
                    $entry = @{ Mtime = $file.LastWriteTimeUtc.Ticks; Title = $title; Folder = $folder }
                    $cache[$file.FullName] = $entry
                }
                $when = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                if (-not $word -or $stem.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $files.Add([System.Management.Automation.CompletionResult]::new(
                        $stem, $stem, 'ParameterValue', ('{0}  {1}' -f $entry.Folder, $when)))
                }
                $title = $entry.Title
                if ($title -and (-not $word -or $title.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and $seen.Add($title)) {
                    # Quote anything that is not plain word characters, or the
                    # parser gets it: '#x' starts a comment, 'a,b' is an array,
                    # '$x' expands, '(x)' runs x, and a leading '-' is a parameter.
                    $completion = if ($title -match '^[\w.][\w.-]*$') { $title } else {
                        "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($title) + "'"
                    }
                    $titles.Add([System.Management.Automation.CompletionResult]::new(
                        $completion, $title, 'ParameterValue', ("Session: {0}  ({1}, {2})" -f $title, $entry.Folder, $when)))
                }
            }
        }
        $out = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $out.AddRange($titles); $out.AddRange($files)
        return $out
    })]
    [string]$Delete,

    [switch]$Orphans,

    [int]$Turns = 10,

    [int]$MaxChars = 600,

    [int]$OlderThan = 0,

    [int]$SmallerThan = 0,

    [switch]$Unnamed,

    [int]$Limit = 0,

    [switch]$IncludeSubagents,

    [switch]$NoColor,

    [switch]$Help
)

# Pinned, because a script inherits its caller's strict mode. Under a
# caller's 'Latest', reading a field a record does not have (isMeta is absent
# from most records) throws inside the transcript reader, and -Open then
# reported every session as unreadable. 1.0 still catches unset variables.
# Latest itself would need every lenient JSON read guarded first.
Set-StrictMode -Version 1.0

$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$ClaudeRoot   = Join-Path $env:USERPROFILE '.claude'
$UserHome     = $env:USERPROFILE
$OrphanScanIncomplete = $false   # set by Get-OrphanItems when it could not look
$OrphanWithheld = 0; $OrphanWithheldBy = @()   # and what it held back, and why
$OriginCache = $null             # filled on first need by Resolve-FolderLabel

$Esc = [char]27
if ($NoColor) {
    $Green = ''; $Blue = ''; $Yellow = ''; $Cyan = ''; $Red = ''; $Bold = ''; $Dim = ''; $Reset = ''
} else {
    $Green  = "$Esc[32m"
    $Blue   = "$Esc[94m"
    $Yellow = "$Esc[33m"
    $Cyan   = "$Esc[36m"
    $Red    = "$Esc[31m"
    $Bold   = "$Esc[1m"
    $Dim    = "$Esc[2m"
    $Reset  = "$Esc[0m"
}

# ---- Help ------------------------------------------------------------------

if ($Help) {
    $h = @"
${Bold}${Green}Get-ClaudeCodeSessions${Reset} - List, read and delete Claude Code sessions.

${Bold}FOUR MODES${Reset}
  ${Cyan}Get-ClaudeCodeSessions${Reset}                 list every session as a table
  ${Cyan}Get-ClaudeCodeSessions -Open${Reset} <sel>     print that session's conversation
  ${Cyan}Get-ClaudeCodeSessions -Delete${Reset} <sel>   delete it and everything it owns
  ${Cyan}Get-ClaudeCodeSessions -Orphans${Reset}        list what deleted and moved sessions left behind

${Bold}SELECTORS${Reset} (for -Open and -Delete)
  ${Cyan}23${Reset}          the Index column from the table
  ${Cyan}d4e5f6a7${Reset}    a fragment of the file name / UUID
  ${Cyan}my-app${Reset}      a fragment of the Session name (set with /rename)
  ${Cyan}*${Reset}           everything currently listed. With -Delete it needs a filter
              first, and so does a fragment that matches every session.
  Indexes shift when a session is added, removed or written to (the table is
  newest first per folder), so -Delete shows each target's first prompt.

${Bold}FILTERS${Reset} (combine freely, they AND together)
  ${Cyan}-Search${Reset} <string>     literal, case-insensitive search inside transcripts;
                       backslashes and quotes are matched as typed
  ${Cyan}-OlderThan${Reset} <N>       only sessions older than N days
  ${Cyan}-SmallerThan${Reset} <N>     only sessions under N KB
  ${Cyan}-Unnamed${Reset}             only sessions with no custom title (/rename)
  ${Cyan}-Limit${Reset} <N>           the first N rows left, in table order (not the N newest)

${Bold}READING${Reset}
  ${Cyan}-Turns${Reset} <N>           turns from each end of the conversation (default 10,
                       0 = all). A ${Dim}... [X turns omitted] ...${Reset} marker shows the gap.
  ${Cyan}-MaxChars${Reset} <N>        truncate each turn to N chars (default 600, 0 = full)

${Bold}COLUMNS${Reset}
  ${Cyan}Size${Reset}                 the transcript file alone. -Delete shows the rest it owns.
  ${Cyan}Context${Reset}              tokens in context as of the last reply, counted the way
                       Claude Code counts it. Over 200k it only fits a 1M window,
                       so resume it on a [1m] model or it opens at 100%.
  ${Cyan}Model${Reset}                model of the last reply. The [1m] flag is not recorded,
                       so Context is the only tell.

${Bold}OTHER${Reset}
  ${Cyan}-IncludeSubagents${Reset}    also list subagent transcripts, unnumbered, under their session
  ${Cyan}-NoColor${Reset}             strip ANSI colors
  ${Cyan}-Help${Reset}                this screen

${Bold}WHAT -Delete ACTUALLY REMOVES${Reset}
  A session is not one file. -Delete sweeps the whole footprint:
    ${Dim}projects\<proj>\<uuid>.jsonl        the transcript${Reset}
    ${Dim}projects\*\<uuid>\                 sidecar: subagents\ + tool-results\${Reset}
    ${Dim}file-history\<uuid>\               edit snapshots (often the biggest part)${Reset}
    ${Dim}session-env\<uuid>\  tasks\<uuid>\  jobs\<first8>\${Reset}
    ${Dim}%TEMP%\claude\*\<uuid>\            background task output${Reset}
  The plan lists every part with its path, file count and size before asking.
  Answer ${Cyan}yes${Reset}: the footprint goes, and ${Bold}memory\${Reset} (shared per project) stays.
  Answer ${Cyan}all${Reset}: also remove what the delete leaves behind, which includes the
  folder's memory when this was its last session, and its strays and backups.
  No answer ever touches ${Bold}history.jsonl${Reset} (your typed prompts, which outlive the
  transcript), ${Bold}.claude.json${Reset} or ${Bold}paste-cache\${Reset}.

${Bold}ORPHANS${Reset}
  ${Cyan}-Orphans${Reset}                      list leftovers, each with State, Why, Size and Path
  ${Cyan}-Orphans -Delete${Reset} <sel>        remove them: ${Cyan}o3${Reset}, a kind (${Cyan}memory${Reset}, ${Cyan}backup${Reset},
                                ${Cyan}session-env${Reset}, ...), ${Cyan}dormant${Reset}, a path fragment, or ${Cyan}*${Reset}
  ${Dim}orphan  = nothing will ever read it again${Reset}
  ${Dim}dormant = memory whose folder exists, or is on a drive that is not connected,${Reset}
  ${Dim}          or was never recorded. It may load again, so only its o# or the${Reset}
  ${Dim}          word dormant takes it; *, a kind and a path fragment never do.${Reset}

${Bold}SAFETY${Reset}
  ${Dim}- The plan is printed, then ONE confirmation: 'yes', or 'all'.${Reset}
  ${Dim}- Deletion is permanent: there is no Recycle Bin.${Reset}
  ${Dim}- Your home folder's memory is never removed, by any mode.${Reset}
  ${Dim}- The running copy of a session is always skipped, so it cannot delete itself.${Reset}
  ${Dim}- An unreadable registry entry of a running session stops every delete.${Reset}
  ${Dim}- A UUID or title that matches both copies of a moved session is refused.${Reset}
  ${Dim}- A sidecar goes with -Delete only once no transcript with that UUID exists in${Reset}
  ${Dim}  ANY project dir, and never while another transcript still mentions it.${Reset}
  ${Dim}- What cannot be read is never treated as empty or as an orphan.${Reset}
  ${Dim}- After the answer, everything is checked against the disk again.${Reset}
  ${Dim}- To preview a delete, run it and answer no: the plan is the preview.${Reset}

${Bold}EXAMPLES${Reset}
  Get-ClaudeCodeSessions
  Get-ClaudeCodeSessions -Open 23
  Get-ClaudeCodeSessions -Open d4e5f6a7 -Turns 0
  Get-ClaudeCodeSessions -Search "database migration"
  Get-ClaudeCodeSessions -Search 'C:\work\api'
  Get-ClaudeCodeSessions | Where-Object Context -gt 200000
  Get-ClaudeCodeSessions -Delete 23
  Get-ClaudeCodeSessions -Delete delete
  Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
  Get-ClaudeCodeSessions -Orphans
  Get-ClaudeCodeSessions -Orphans -Delete *
"@
    Write-Output $h
    return
}

# After -Help, so the help works on a machine where Claude Code never ran.
if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
    Write-Error "Claude Code projects directory not found: $ProjectsRoot"
    return
}

if ($Open -and $Delete) {
    Write-Error 'Use -Open to read a session or -Delete to remove one, not both.'
    Write-Host ''
    return
}

if ($Orphans -and ($Open -or $Search -or $OlderThan -or $SmallerThan -or $Unnamed -or $Limit -or $IncludeSubagents)) {
    Write-Error '-Orphans works on its own, or with -Delete to remove what it lists. Session filters do not apply to it.'
    Write-Host ''
    return
}

# ---- Helpers ---------------------------------------------------------------

function Get-CleanText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text = $Text -replace '(?s)<system-reminder>.*?</system-reminder>', ''
    $Text = $Text -replace '(?s)<command-[a-z-]+>.*?</command-[a-z-]+>', ''
    $Text = $Text -replace '(?s)<local-command-stdout>.*?</local-command-stdout>', ''
    return $Text.Trim()
}

function Get-MessageText {
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return Get-CleanText $Content }
    $parts = foreach ($block in $Content) {
        if ($block.type -eq 'text' -and $block.text) { $block.text }
    }
    return Get-CleanText (($parts -join "`n").Trim())
}

function Get-SessionData {
    # Returns a hashtable: .Turns (list of user/assistant turns, left empty
    # with -Light or -CwdOnly), .Cwd (cwd of the first turn), .CustomTitle
    # (string or empty), .Context (tokens or $null), .Model (string or empty)
    # and .ReadError ($true when the file could not be opened, so everything
    # else is unknown, not empty). The custom title is set by the user via
    # /rename in Claude Code and is recorded as 'custom-title' lines in the
    # session JSONL. The same title can appear multiple times if it was
    # changed; we keep the LAST one we see.
    #
    # Lines are streamed with FileShare.ReadWrite, never through Get-Content,
    # which decorates every line with provider properties: on a few hundred MB
    # of transcripts that cost 650 MB of RAM and most of the run time. A line
    # is parsed only if it can matter, recognized by its own unescaped "type"
    # field: text inside a record is JSON-escaped, so a real record can never
    # be missed this way, only parsed needlessly. If nothing in a non-empty
    # file is recognized (a format change), it is read again without the
    # shortcut rather than reported as empty.
    #
    # -Light is for the table: once the first turn's cwd is known, user
    # records are skipped, since only the title, that cwd and the last reply
    # are needed. -CwdOnly stops at that cwd, so -Search misses can be
    # numbered by exactly the same rules. -Subagent keeps sidechain records:
    # in a subagent transcript every record is one, while in a root transcript
    # they are old inline subagent turns.
    #
    # Context is input + cache_creation + cache_read + output from the usage
    # block of the LAST real reply. That is exactly how Claude Code counts it:
    # its own compact_boundary preTokens equals this sum to the token. Take the
    # last record, never a sum: one API response is written as several
    # assistant records (thinking, text, tool_use), each repeating the same
    # usage. '<synthetic>' records (timeouts, API errors) carry zero usage and
    # are skipped. A compaction after the last reply resets Context to the
    # compacted size, its postTokens.
    #
    # Model is message.model of that same reply, the bare API name such as
    # 'claude-opus-5-5'. It never carries the Bedrock profile or the [1m] flag,
    # so it cannot tell a 1M session from a 200k one. Context sometimes can:
    # anything over 200k only fits a 1M window.
    param([string]$JsonlPath, [switch]$Light, [switch]$CwdOnly, [switch]$Subagent)

    # Named $turnList, not $turns: the -Turns parameter is [int] and PowerShell
    # variable names are case-insensitive, so a local $turns would collide with
    # it and fail to accept a List.
    $turnList = New-Object System.Collections.Generic.List[object]
    $customTitle = ''
    $context = $null
    $model = ''
    $firstCwd = $null
    $wantTurns = -not ($Light -or $CwdOnly)

    if ([string]::IsNullOrWhiteSpace($JsonlPath)) {
        return @{ Turns = $turnList; Cwd = $null; CustomTitle = ''; Context = $null; Model = ''; ReadError = $false }
    }

    $triage = $true
    while ($true) {
        try {
            $sr = [IO.StreamReader]::new([IO.FileStream]::new($JsonlPath, 'Open', 'Read', 'ReadWrite'))
        } catch {
            return @{ Turns = $turnList; Cwd = $null; CustomTitle = ''; Context = $null; Model = ''; ReadError = $true }
        }
        $readAny = $false; $recognized = 0
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                $readAny = $true
                if ($triage) {
                    $isAsst = $line.Contains('"type":"assistant"')
                    $isUser = $line.Contains('"type":"user"')
                    if (-not ($isAsst -or $isUser -or $line.Contains('"type":"custom-title"') -or $line.Contains('"compact_boundary"'))) { continue }
                    $recognized++
                    # User records cannot change the title, context or model.
                    # A line carrying the assistant marker is always parsed.
                    if ($isUser -and -not $isAsst -and -not $wantTurns -and $firstCwd) { continue }
                }
                # -AsHashtable: a record with keys that differ only by case (or
                # an empty key) is legal JSON that plain ConvertFrom-Json drops,
                # and a dropped final reply would leave Context stale.
                try { $obj = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { continue }

                if ($obj.type -eq 'custom-title' -and $obj.customTitle) {
                    $customTitle = [string]$obj.customTitle
                    continue
                }

                if ($obj.type -eq 'system' -and $obj.subtype -eq 'compact_boundary') {
                    # Without postTokens the pre-compact figure would be stale, so
                    # report unknown until the next reply sets it again.
                    $post = if ($obj.compactMetadata) { $obj.compactMetadata.postTokens }
                    $context = if ($post) { [long]$post } else { $null }
                    continue
                }

                if ($obj.type -ne 'user' -and $obj.type -ne 'assistant') { continue }
                if (-not $obj.message) { continue }
                if ($obj.isSidechain -and -not $Subagent) { continue }

                if ($obj.type -eq 'assistant' -and $obj.message.model -and $obj.message.model -ne '<synthetic>') {
                    $model = [string]$obj.message.model
                    $u = $obj.message.usage
                    if ($u) {
                        $context = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens +
                                   [long]$u.cache_read_input_tokens + [long]$u.output_tokens
                    }
                }

                # Turn text is only needed to find the first turn's cwd, or
                # for every turn when the caller wants the conversation.
                if (-not $wantTurns -and $firstCwd) { continue }
                $text = Get-MessageText $obj.message.content
                if (-not $text) { continue }
                if (-not $firstCwd -and $obj.cwd) {
                    $firstCwd = [string]$obj.cwd
                    if ($CwdOnly) { break }
                }
                if ($wantTurns) {
                    # What -Open shows. Records Claude Code injects rather than
                    # anyone typed (command caveats, the "this session is being
                    # continued" summary, task notifications) are left out here
                    # only, so they never change which turn sets Folder.
                    if ($obj.isMeta -or $obj.isCompactSummary) { continue }
                    $shown = ($text -replace '(?s)<local-command-caveat>.*?</local-command-caveat>', '' -replace '(?s)<task-notification>.*?</task-notification>', '').Trim()
                    if (-not $shown) { continue }
                    $role = $obj.message.role
                    if (-not $role) { $role = $obj.type }
                    $turnList.Add([PSCustomObject]@{
                        Role      = $role
                        Text      = $shown
                        Cwd       = $obj.cwd
                        Timestamp = $obj.timestamp
                    })
                }
            }
        } catch {
            # Failed partway through: what was read is not the whole story.
            # Keep the cwd (it decides Folder, and so the Index) and nothing else.
            return @{ Turns = $turnList; Cwd = $firstCwd; CustomTitle = ''; Context = $null; Model = ''; ReadError = $true }
        } finally {
            $sr.Dispose()
        }
        if ($triage -and $readAny -and $recognized -eq 0) { $triage = $false; continue }
        break
    }

    return @{ Turns = $turnList; Cwd = $firstCwd; CustomTitle = $customTitle; Context = $context; Model = $model; ReadError = $false }
}

function ConvertTo-FolderLabel {
    param([string]$Cwd, [string]$DirName)

    $source = $Cwd
    if (-not $source -and $DirName) {
        if ($DirName -match '^([A-Za-z])--(.+)$') {
            $source = "$($matches[1]):\" + ($matches[2] -replace '-', '\')
        } else {
            $source = $DirName
        }
    }
    if (-not $source) { return '?' }

    $homePath = $UserHome.TrimEnd('\')
    if ($source -ieq $homePath) { return '\' }
    # With the separator: C:\Users\me2\x is not inside C:\Users\me.
    if ($source.StartsWith("$homePath\", [StringComparison]::OrdinalIgnoreCase)) {
        return $source.Substring($homePath.Length)
    }
    return $source
}

function Format-Timestamp {
    param($Stamp)
    if (-not $Stamp) { return '' }
    if ($Stamp -is [DateTime]) {
        return $Stamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    try {
        return [DateTimeOffset]::Parse([string]$Stamp).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    } catch {
        return [string]$Stamp
    }
}

function Format-TurnText {
    param([string]$Text, [int]$Max)
    if ($Max -le 0) { return $Text }
    if ($Text.Length -le $Max) { return $Text }
    return (Limit-Text $Text $Max).TrimEnd() + "`n...[truncated]"
}

function Select-TurnsForDisplay {
    param([object]$SessionTurns, [int]$N)
    # Do NOT use @($SessionTurns) here. On PowerShell 7.6.5 the array
    # subexpression operator throws "Argument types do not match" when applied
    # to a System.Collections.Generic.List[object], which is exactly what
    # Get-SessionData returns. [object[]] casts fine; so would .ToArray().
    $list = @()
    if ($null -ne $SessionTurns) { $list = [object[]]$SessionTurns }
    $total = $list.Count
    if ($total -eq 0) { return @{ First = @(); Last = @(); Omitted = 0; Total = 0 } }
    if ($N -le 0 -or $total -le ($N * 2)) {
        return @{ First = $list; Last = @(); Omitted = 0; Total = $total }
    }
    return @{
        First   = @($list | Select-Object -First $N)
        Last    = @($list | Select-Object -Last $N)
        Omitted = $total - ($N * 2)
        Total   = $total
    }
}

function Write-TurnBlock {
    param($Turn, [int]$Max)
    if ($Turn.Role -eq 'user') {
        $color = $Blue;   $label = '[USER]'
    } else {
        $color = $Yellow; $label = '[CLAUDE]'
    }
    Write-Output ("{0}{1} {2}{3}" -f $color, $label, (Format-Timestamp $Turn.Timestamp), $Reset)
    Write-Output (Format-TurnText -Text $Turn.Text -Max $Max)
    Write-Output ''
}

function Select-BySelector {
    # Shared matching for -Open and -Delete: index, or substring of filename
    # or custom title. '*' means "the whole current set".
    param([object]$Candidates, [string]$Selector)
    # [object[]] rather than @() - see the note in Select-TurnsForDisplay.
    $list = @()
    if ($null -ne $Candidates) { $list = [object[]]$Candidates }
    if ($Selector -eq '*') { return $list }
    if ($Selector -match '^#?\d+$') {
        # All digits is always an Index, never a UUID fragment or a title.
        # TryParse: a long digit string is no index at all, not an overflow.
        $idx = 0
        if (-not [int]::TryParse($Selector.TrimStart('#'), [ref]$idx)) { return @() }
        return @($list | Where-Object { $_.Index -eq $idx })
    }
    # Literal substring, case-insensitive, of the file stem or the title. Not
    # -like: that treats [ ] * ? as wildcards, so '-Delete [WIP]' would mean
    # "any title containing W, I or P". The stem, not the file name, or
    # 'jsonl' and '.' would match every session.
    return @($list | Where-Object {
        [IO.Path]::GetFileNameWithoutExtension($_.File).IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($_.Session -and ([string]$_.Session).IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}

function Get-RunningSession {
    # One record per live Claude Code process: SessionId, plus ProjectDir, the
    # project dir name its cwd maps to ($null when unknown). Read from
    # ~\.claude\sessions\<pid>.json. An entry whose pid is gone is ignored,
    # or a crashed session would be protected forever; one with no pid at all
    # is trusted, which errs toward protecting it.
    # CLAUDE_CODE_SESSION_ID covers running from inside a session's own shell;
    # the env var carries no cwd, so that record has no ProjectDir.
    #
    # These files are rewritten while a session runs (status, updatedAt), so a
    # read can land mid-write. An entry that will not parse is retried once;
    # if its pid (the file name) is still alive after that, it comes back as
    # an Unknown record, and callers refuse to delete anything rather than
    # guess which session it was.
    $recs = New-Object System.Collections.Generic.List[object]
    if ($env:CLAUDE_CODE_SESSION_ID) { $recs.Add([pscustomobject]@{ SessionId = [string]$env:CLAUDE_CODE_SESSION_ID; ProjectDir = $null; Unknown = $false }) }
    $dir = Join-Path $ClaudeRoot 'sessions'
    if (Test-Path -LiteralPath $dir) {
        # Not -Filter, which hides a listing error: a registry that cannot be
        # listed would read as "nothing is running".
        $regErr = $null
        $entries = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue -ErrorVariable +regErr | Where-Object Extension -eq '.json')
        if ($regErr) { $recs.Add([pscustomobject]@{ SessionId = ''; ProjectDir = $null; Unknown = $true; File = 'the sessions\ dir itself' }) }
        foreach ($f in $entries) {
            $o = $null
            foreach ($try in 1, 2) {
                try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; break }
                catch { $o = $null; if ($try -eq 1) { Start-Sleep -Milliseconds 150 } }
            }
            if (-not $o) {
                $procNum = 0
                if ([int]::TryParse($f.BaseName, [ref]$procNum) -and (Get-Process -Id $procNum -ErrorAction SilentlyContinue)) {
                    $recs.Add([pscustomobject]@{ SessionId = ''; ProjectDir = $null; Unknown = $true; File = $f.Name })
                }
                continue
            }
            if (-not $o.sessionId) { continue }
            if ($o.pid -and -not (Get-Process -Id $o.pid -ErrorAction SilentlyContinue)) { continue }
            $pd = if ($o.cwd) { ConvertTo-ProjectDirName ([string]$o.cwd) } else { $null }
            $recs.Add([pscustomobject]@{ SessionId = [string]$o.sessionId; ProjectDir = $pd; Unknown = $false })
        }
    }
    return [object[]]$recs
}

function Get-UnknownRunningSession {
    # Registry entries of live processes that could not be read (see
    # Get-RunningSession). Non-empty means "some session is running and we
    # cannot tell which", so nothing should be deleted until it reads cleanly.
    return [string[]]@(Get-RunningSession | Where-Object Unknown | ForEach-Object File)
}

function Get-RunningSessionId {
    # Returns a plain string ARRAY, deliberately not a HashSet. PowerShell
    # enumerates any collection a function outputs, so returning a HashSet
    # yields $null for 0 entries, a bare [string] for 1, and [object[]] for 2+.
    # The $null case then throws on .Contains(), and the single-string case
    # silently switches to String.Contains() substring matching. Test membership
    # at the call site with -contains / -notcontains: those are case-insensitive
    # for strings, do equality rather than substring, and treat $null as "no
    # match" instead of erroring.
    return [string[]]@(Get-RunningSession | Where-Object SessionId | ForEach-Object SessionId)
}

function Remove-PathHard {
    # OneDrive Files-On-Demand marks synced directories ReadOnly +
    # ReparsePoint. Directory.Delete and Remove-Item both fail on those with
    # access-denied until ReadOnly is cleared, so clear it first, depth-first.
    param([string]$Path)
    # The last line of defense: whatever computed this path, never a store
    # root, an ancestor of one, or the home folder's memory.
    if (Test-ProtectedPath $Path) {
        Write-Warning "Refusing to remove a protected path: $Path"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue) {
                try { $child.Attributes = $child.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) } catch { }
            }
            try { $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) } catch { }
            [System.IO.Directory]::Delete($Path, $true)
        } else {
            try { $item.Attributes = [System.IO.FileAttributes]::Normal } catch { }
            [System.IO.File]::Delete($Path)
        }
    } catch {
        return $false
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Get-PathStats {
    # Files, bytes and newest file write under a path (the file itself, or
    # everything below a directory), plus how many entries could not be read.
    # An unreadable entry makes the size a floor, not a measurement, so
    # callers must say so instead of printing a confident number.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Files = 0; Bytes = [long]0; Newest = $null; Errors = 0 } }
    $ev = $null
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable +ev
    if (-not $item) { return [pscustomobject]@{ Files = 0; Bytes = [long]0; Newest = $null; Errors = 1 } }
    if (-not $item.PSIsContainer) { return [pscustomobject]@{ Files = 1; Bytes = [long]$item.Length; Newest = $item.LastWriteTime; Errors = 0 } }
    $n = 0; $bytes = [long]0; $newest = $null
    foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +ev) {
        $n++; $bytes += $f.Length
        if (-not $newest -or $f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime }
    }
    if (-not $newest) { $newest = $item.LastWriteTime }
    return [pscustomobject]@{ Files = $n; Bytes = $bytes; Newest = $newest; Errors = $(if ($ev) { $ev.Count } else { 0 }) }
}

function Format-Size {
    # Explorer style: whole KB with separators, rounded UP so a 300-byte file
    # never claims to be 0 KB. The table's Size column uses the same rule, so
    # a transcript shows the same number in both places.
    param([long]$Bytes)
    return ('{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB))
}

function Get-TempBase {
    # The temp dir Claude Code's %TEMP%\claude lives in. Reads TEMP, then TMP,
    # the order Node's os.tmpdir() uses on Windows; .NET's GetTempPath() reads
    # TMP first, so it is only the last resort. On a normal setup all of them
    # are %LOCALAPPDATA%\Temp, which is what this replaced.
    if ($env:TEMP) { return $env:TEMP.TrimEnd('\') }
    if ($env:TMP)  { return $env:TMP.TrimEnd('\') }
    return [IO.Path]::GetTempPath().TrimEnd('\')
}

function Get-ClaudeTempRoot {
    return (Join-Path (Get-TempBase) 'claude')
}

function Limit-Text {
    # At most $Max characters, without splitting a surrogate pair: an emoji
    # is two UTF-16 chars, and half of one renders as garbage.
    param([string]$Text, [int]$Max)
    if ($Max -le 0 -or $Text.Length -le $Max) { return $Text }
    $cut = $Max
    if ([char]::IsHighSurrogate($Text[$cut - 1])) { $cut-- }
    return $Text.Substring(0, $cut)
}

function Get-FirstPrompt {
    # The first thing typed in a session, for the delete plan. An index can
    # point somewhere new between a listing and a delete (sessions get added,
    # and written to), and '(unnamed)' tells two sessions apart badly. Reads
    # only the top of the file, skipping meta records, tool results and
    # command echoes.
    param([string]$JsonlPath, [int]$Max = 80)
    try { $sr = [IO.StreamReader]::new([IO.FileStream]::new($JsonlPath, 'Open', 'Read', 'ReadWrite')) } catch { return '' }
    try {
        $n = 0
        while ($null -ne ($line = $sr.ReadLine())) {
            if (++$n -gt 400) { break }
            if (-not $line.Contains('"type":"user"')) { continue }
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.type -ne 'user' -or -not $obj.message -or $obj.isMeta -or $obj.isCompactSummary -or $obj.isSidechain) { continue }
            $c = $obj.message.content
            if ($c -isnot [string] -and @($c | Where-Object { $_.type -eq 'tool_result' }).Count) { continue }
            $t = (Get-MessageText $c) -replace '\s+', ' '
            if (-not $t) { continue }
            $short = Limit-Text $t $Max
            if ($short.Length -lt $t.Length) { $short = $short.TrimEnd() + '...' }
            return $short
        }
    } catch {
    } finally {
        $sr.Dispose()
    }
    return ''
}

function ConvertTo-DisplayPath {
    # ~ for the profile, %TEMP% for the temp dir. Temp is checked first
    # because it lives inside the profile.
    param([string]$Path)
    # Both with the separator: ...\Temp2 is not inside ...\Temp.
    $temp = Get-TempBase
    if ($Path.StartsWith("$temp\", [StringComparison]::OrdinalIgnoreCase)) { return '%TEMP%' + $Path.Substring($temp.Length) }
    $homePath = $UserHome.TrimEnd('\')
    if ($Path.StartsWith("$homePath\", [StringComparison]::OrdinalIgnoreCase)) { return '~' + $Path.Substring($homePath.Length) }
    return $Path
}

function Get-SessionFootprint {
    # Everything a session owns EXCEPT its root transcript, which the caller
    # deletes first. Sidecar dirs are searched across every project dir, since
    # a sidecar lands wherever the cwd was when the tool ran and can end up
    # separated from its transcript.
    param([string]$Uuid)

    $paths = New-Object System.Collections.Generic.List[string]
    if (-not (Test-SessionId $Uuid)) { return $paths }

    foreach ($dir in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force -ErrorAction SilentlyContinue) {
        $sidecar = Join-Path $dir.FullName $Uuid
        if (Test-Path -LiteralPath $sidecar) { $paths.Add($sidecar) }
    }
    foreach ($sub in @('file-history', 'session-env', 'tasks')) {
        $p = Join-Path (Join-Path $ClaudeRoot $sub) $Uuid
        if (Test-Path -LiteralPath $p) { $paths.Add($p) }
    }
    # jobs\ is keyed by the first 8 hex chars of the session id, inferred from
    # observed pairings. The delete plan keeps it when another session shares
    # the prefix.
    if ($Uuid.Length -ge 8) {
        $prefix = $Uuid.Substring(0, 8)
        $jobDir = Join-Path (Join-Path $ClaudeRoot 'jobs') $prefix
        if (Test-Path -LiteralPath $jobDir) { $paths.Add($jobDir) }
    }
    $tempRoot = Get-ClaudeTempRoot
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($pd in Get-ChildItem -LiteralPath $tempRoot -Directory -Force -ErrorAction SilentlyContinue) {
            $p = Join-Path $pd.FullName $Uuid
            if (Test-Path -LiteralPath $p) { $paths.Add($p) }
        }
    }
    return $paths
}

function ConvertTo-ProjectDirName {
    # How Claude Code names a project dir: every non-alphanumeric character of
    # the cwd becomes '-'. Verified against every live sessions\ entry,
    # including a path with spaces and ' - '. The encoding is lossy, so a dir
    # name is decoded only as a last resort: re-encode candidate paths and
    # compare instead.
    param([string]$Cwd)
    return ($Cwd -replace '[^A-Za-z0-9]', '-')
}

function Read-SharedLines {
    # Lines of a file another process may be appending to (history.jsonl):
    # without FileShare.ReadWrite the open can fail mid-write.
    param([string]$Path)
    $fs = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite')
    $sr = [IO.StreamReader]::new($fs)
    try { while ($null -ne ($l = $sr.ReadLine())) { $l } } finally { $sr.Dispose() }
}

function Get-ProjectOrigin {
    # Which folder each project dir came from, and which project each session
    # ID belonged to. Re-encodes every cwd Claude Code has recorded: the
    # .claude.json project keys (forward slashes), and history.jsonl, whose
    # entries outlive their transcripts and so still describe dead sessions.
    $byDir = @{}; $bySession = @{}
    $add = {
        param([string]$Path)
        if (-not $Path) { return }
        $n = ConvertTo-ProjectDirName $Path
        if (-not $byDir.ContainsKey($n)) { $byDir[$n] = New-Object System.Collections.Generic.List[string] }
        if (-not $byDir[$n].Contains($Path)) { $byDir[$n].Add($Path) }
    }
    $cj = Join-Path $UserHome '.claude.json'
    if (Test-Path -LiteralPath $cj) {
        try {
            # -AsHashtable because the keys can differ only by drive-letter
            # case (C:/... and c:/...), which plain ConvertFrom-Json rejects.
            $j = Get-Content -LiteralPath $cj -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
            if ($j -and $j.ContainsKey('projects')) { foreach ($k in $j['projects'].Keys) { & $add ($k -replace '/', '\') } }
        } catch { }
    }
    $hist = Join-Path $ClaudeRoot 'history.jsonl'
    if (Test-Path -LiteralPath $hist) {
        foreach ($l in Read-SharedLines $hist) {
            if ($l -notmatch '"project":"((?:[^"\\]|\\.)*)"') { continue }
            $proj = $Matches[1] -replace '\\\\', '\'
            & $add $proj
            if ($l -match '"sessionId":"([0-9a-f-]{36})"') { $bySession[$Matches[1]] = $proj }
        }
    }
    return @{ ByDir = $byDir; BySession = $bySession }
}

function Get-RunningProjectDir {
    # Project dirs of sessions running right now. A brand-new session can own
    # memory and a session-env before it has written a single transcript line.
    return [string[]]@(Get-RunningSession | Where-Object ProjectDir | ForEach-Object ProjectDir)
}

function Test-ProtectedPath {
    # Paths no mode may ever remove. The home folder's memory, which every
    # session started in the profile root shares, and the dir holding it. And
    # every root this script works under, or any ancestor of one: a backstop
    # against path-building bugs, since a transcript named '.jsonl' has an
    # empty stem that turns 'file-history\<stem>' into the store root, and
    # '...jsonl' turns it into ~\.claude itself. Remove-PathHard checks this
    # on every call. Compared normalized, so 'X\' and 'X' agree.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }
    $homeProj = Join-Path $ProjectsRoot (ConvertTo-ProjectDirName $UserHome)
    $homeMem  = Join-Path $homeProj 'memory'
    if ($full.StartsWith("$homeMem\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $roots = @($homeMem, $homeProj, $ProjectsRoot, $ClaudeRoot, $UserHome, (Get-ClaudeTempRoot)) +
             @('file-history', 'session-env', 'tasks', 'jobs', 'sessions' | ForEach-Object { Join-Path $ClaudeRoot $_ })
    foreach ($root in $roots) {
        $r = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($r -eq $full -or $r.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-SessionId {
    # A real session ID. Only these get a footprint: the file stem becomes a
    # path segment, and a stem like '', '..' or 'memory' would aim it at
    # something else entirely.
    param([string]$Id)
    return ($Id -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Resolve-FolderLabel {
    # Folder for a transcript: its first turn's cwd. Without one (no turns
    # yet, or the file could not be read) use the folder Claude Code recorded
    # for that project dir in .claude.json / history.jsonl, and only then
    # decode the dir name. The decode is lossy ('-' could have been any
    # character), and a wrong label re-sorts the row and shifts every index
    # after it, so '-Delete <n>' would point at a different session.
    param([string]$Cwd, [string]$DirName)
    if (-not $Cwd) {
        if ($null -eq $script:OriginCache) { $script:OriginCache = Get-ProjectOrigin }
        if ($script:OriginCache.ByDir.ContainsKey($DirName)) { $Cwd = $script:OriginCache.ByDir[$DirName][0] }
    }
    return (ConvertTo-FolderLabel -Cwd $Cwd -DirName $DirName)
}

function Test-SubagentPath {
    # Subagent transcripts live at projects\<proj>\<uuid>\subagents\agent-*.jsonl.
    param([string]$Path)
    return ((Split-Path (Split-Path $Path -Parent) -Leaf) -eq 'subagents')
}

function Test-ShellDir {
    # True when a dir holds nothing except, at most, an empty memory\ (plus
    # whatever is about to be deleted, passed as -Ignore). Claude Code
    # recreates both on the next session there, so such a dir is a shell.
    # The delete plan and both executors share this rule, so the plan never
    # promises to remove a dir that the executor then keeps.
    param([string]$Path, [string[]]$Ignore = @())
    # A dir that cannot be listed is unknown, never a shell.
    $ev = $null
    $kids = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable +ev)
    if ($ev) { return $false }
    foreach ($k in $kids) {
        if ($Ignore -contains $k.FullName) { continue }
        if ($k.PSIsContainer -and $k.Name -eq 'memory') {
            $st = Get-PathStats -Path $k.FullName
            if ($st.Files -eq 0 -and $st.Errors -eq 0) { continue }
        }
        return $false
    }
    return $true
}

function New-FootprintPart {
    param([string]$Label, [string]$Path)
    $st = Get-PathStats -Path $Path
    return [pscustomobject]@{ Label = $Label; Path = $Path; Files = $st.Files; Bytes = $st.Bytes; Errors = $st.Errors }
}

function Get-FootprintParts {
    # Splits a session's footprint (from Get-SessionFootprint) into parts a
    # human recognizes, for the delete plan. Display only: deletion still
    # removes each footprint path whole, so the parts must cover every byte
    # under it. A sidecar therefore becomes one row per subfolder plus one per
    # loose file.
    param([string[]]$Paths)
    $tempRoot = Get-ClaudeTempRoot
    foreach ($p in $Paths) {
        if ($p.StartsWith($ProjectsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $kids = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 0) { New-FootprintPart 'sidecar (empty)' $p; continue }
            foreach ($k in $kids) {
                $label = if (-not $k.PSIsContainer) { 'sidecar file' }
                         elseif ($k.Name -eq 'subagents') { 'subagent transcripts' }
                         elseif ($k.Name -eq 'tool-results') { 'saved tool output' }
                         else { "sidecar\$($k.Name)" }
                New-FootprintPart $label $k.FullName
            }
        } elseif ($p.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            New-FootprintPart 'background task output' $p
        } else {
            $store = Split-Path (Split-Path $p -Parent) -Leaf
            $label = switch ($store) {
                'file-history' { 'file snapshots (/rewind)' }
                'session-env'  { 'session env' }
                'tasks'        { 'task list state' }
                'jobs'         { 'background jobs' }
                default        { $store }
            }
            New-FootprintPart $label $p
        }
    }
}

function Get-OrphanItems {
    # Everything in the session stores that no live session can reach, as
    # CCOrphan rows. State 'orphan' = nothing will ever read it again.
    # State 'dormant' = memory whose folder still exists: it loads again the
    # moment a session starts there, so '*' never sweeps it.
    #
    # -GoneTranscripts / -GonePaths ask "what would be orphaned if these were
    # already deleted?" The -Delete plan uses that to list what a delete
    # leaves behind, with the same rules as -Orphans instead of a second copy
    # of them. -NoFold keeps one row per path, so a folded row can never drag
    # an unrelated empty dir into that answer.
    #
    # Unknown is never orphan. If the project dirs cannot all be listed, it is
    # unknown which sessions are live, so nothing is listed at all. A project
    # dir, store or temp dir that cannot be listed is skipped, never treated
    # as empty. A memory folder on a drive or share that is not connected is
    # 'dormant', not 'gone'. And a sidecar or temp dir any live transcript
    # still mentions by path is never listed, whatever its session ID says:
    # a session moved the CLAUDE.md way gets a NEW ID and still reads the old
    # ID's saved tool output.
    param([string[]]$GoneTranscripts = @(), [string[]]$GonePaths = @(), [switch]$NoFold)
    # Set when the scan gave up, so callers can tell "none" from "could not look".
    $script:OrphanScanIncomplete = $false
    # Leftovers held back because a live transcript mentions them, and which
    # transcripts those are, so the listing can say so instead of hiding them.
    $script:OrphanWithheld = 0; $script:OrphanWithheldBy = @()
    $uuidRx   = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $tempRoot = Get-ClaudeTempRoot
    $origin   = Get-ProjectOrigin
    $gone     = @($GoneTranscripts) + @($GonePaths)
    $skipped  = New-Object System.Collections.Generic.List[string]

    # Live = has a root transcript somewhere, or is running right now.
    $txDirs = @{}; $txPaths = @{}
    $listErr = $null
    $projDirs = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +listErr)
    foreach ($pd in $projDirs) {
        # Not -Filter: see the scan; it hides an unreadable dir.
        foreach ($t in Get-ChildItem -LiteralPath $pd.FullName -File -Force -ErrorAction SilentlyContinue -ErrorVariable +listErr | Where-Object Extension -eq '.jsonl') {
            if ($gone -contains $t.FullName) { continue }
            if (-not $txDirs.ContainsKey($t.BaseName)) {
                $txDirs[$t.BaseName]  = New-Object System.Collections.Generic.List[string]
                $txPaths[$t.BaseName] = New-Object System.Collections.Generic.List[string]
            }
            $txDirs[$t.BaseName].Add($pd.Name); $txPaths[$t.BaseName].Add($t.FullName)
        }
    }
    if ($listErr) {
        Write-Warning ("{0} error(s) listing the project dirs, so it is unknown which sessions are live. Listing no orphans. First: {1}" -f $listErr.Count, $listErr[0].Exception.Message)
        $script:OrphanScanIncomplete = $true
        return
    }
    $running     = @(Get-RunningSessionId)
    $runningDirs = @(Get-RunningProjectDir)
    $liveIds     = @($txDirs.Keys) + $running
    $livePrefix  = @($liveIds | ForEach-Object { $_.Substring(0, [Math]::Min(8, $_.Length)) })

    $folderOf = {
        param([string]$DirName)
        if ($origin.ByDir.ContainsKey($DirName)) { return (ConvertTo-FolderLabel -Cwd $origin.ByDir[$DirName][0] -DirName $DirName) }
        return $DirName
    }
    # One path, or the first plus a count: a folded row must never read as
    # if it were the whole store.
    $where = {
        param([string[]]$Paths)
        $first = ConvertTo-DisplayPath $Paths[0]
        if ($Paths.Count -gt 1) { return "$first (+$($Paths.Count - 1) more)" }
        return $first
    }
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Kind, [string]$State, [string]$Folder, [string]$Why, [string[]]$Paths, [string]$Note)
        $files = 0; $bytes = [long]0; $errs = 0; $newest = $null
        foreach ($p in $Paths) {
            $st = Get-PathStats -Path $p
            $files += $st.Files; $bytes += $st.Bytes; $errs += $st.Errors
            if ($st.Newest -and (-not $newest -or $st.Newest -gt $newest)) { $newest = $st.Newest }
        }
        # Said in the row itself: 0 files from a dir that could not be read
        # is not 0 files.
        if ($errs) { $Why = "$Why; $errs unreadable" }
        $row = [pscustomobject]@{
            Index = 0; State = $State; Kind = $Kind; Folder = $Folder; Files = $files; Bytes = $bytes
            LastWrite = $newest; Why = $Why; Path = (& $where $Paths); Paths = $Paths
            Note = $Note; Errors = $errs
        }
        $items.Add($row)
        return $row
    }
    # Sidecar and temp rows wait here for the reference check below.
    $refCands = New-Object System.Collections.Generic.List[object]
    $needles = {
        param([string]$Prefix, [string]$Dir, [string]$Id)
        @("$Prefix\\$Dir\\$Id", "$Prefix/$Dir/$Id", "$Prefix\$Dir\$Id")
    }

    foreach ($pd in $projDirs) {
        $kidErr = $null
        $kids   = @(Get-ChildItem -LiteralPath $pd.FullName -Force -ErrorAction SilentlyContinue -ErrorVariable +kidErr | Where-Object { $gone -notcontains $_.FullName })
        if ($kidErr) { $skipped.Add($pd.FullName); continue }
        $folder = & $folderOf $pd.Name
        $inUse  = (@($kids | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.jsonl' }).Count -gt 0) -or
                  ($runningDirs -contains $pd.Name)
        $memDir   = Join-Path $pd.FullName 'memory'
        $memStats = Get-PathStats -Path $memDir

        # Never offered for removal, so never listed: see Test-ProtectedPath.
        if (-not $inUse -and -not (Test-ProtectedPath $pd.FullName)) {
            if ($memStats.Files -or $memStats.Errors) {
                $cands = @(if ($origin.ByDir.ContainsKey($pd.Name)) { $origin.ByDir[$pd.Name] })
                $there = @($cands | Where-Object { Test-Path -LiteralPath $_ })
                # 'Gone' needs the drive or share to be there to say so: an
                # unplugged disk answers Test-Path with False too.
                $reachable = @($cands | Where-Object { $root = [IO.Path]::GetPathRoot($_); $root -and [IO.Directory]::Exists($root) })
                if ($there.Count)                                          { $state = 'dormant'; $why = 'no sessions; folder exists' }
                elseif ($cands.Count -and $reachable.Count -eq $cands.Count) { $state = 'orphan';  $why = 'no sessions; folder gone' }
                elseif ($cands.Count)                                      { $state = 'dormant'; $why = 'no sessions; folder unreachable (drive or share offline)' }
                else                                                       { $state = 'dormant'; $why = 'no sessions; folder unknown' }
                $memNames = @(Get-ChildItem -LiteralPath $memDir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name)
                $note = 'memory files: ' + $(if ($memNames.Count) { $memNames -join ', ' } else { 'none readable' }) +
                        $(if ($memStats.Errors) { " ($($memStats.Errors) read error(s))" } else { '' })
                [void](& $add 'memory' $state $folder $why @($memDir) $note)
            } elseif (@($kids | Where-Object { -not ($_.PSIsContainer -and $_.Name -eq 'memory') }).Count -eq 0) {
                # Nothing in it but an empty memory\, if that: an empty shell.
                [void](& $add 'project' 'orphan' $folder 'no sessions, no memory' @($pd.FullName) '')
                continue
            }
        }

        foreach ($k in $kids) {
            if ($k.PSIsContainer -and $k.Name -match $uuidRx) {
                if ($liveIds -notcontains $k.Name) {
                    $row = & $add 'sidecar' 'orphan' $folder 'session gone' @($k.FullName) ''
                    $refCands.Add([pscustomobject]@{ Row = $row; Id = $k.Name; Needles = (& $needles 'projects' $pd.Name $k.Name) })
                } elseif ($running -notcontains $k.Name -and $txDirs.ContainsKey($k.Name) -and $txDirs[$k.Name] -notcontains $pd.Name) {
                    # Stranded: the session moved and left its old sidecar here.
                    $to = @($txDirs[$k.Name] | ForEach-Object { & $folderOf $_ }) -join ', '
                    $row = & $add 'sidecar' 'orphan' $folder 'session moved; unreferenced' @($k.FullName) "left behind when the session moved to $to; no transcript points here"
                    $refCands.Add([pscustomobject]@{ Row = $row; Id = $k.Name; Needles = (& $needles 'projects' $pd.Name $k.Name) })
                }
            } elseif (-not $k.PSIsContainer -and $k.Extension -ne '.jsonl') {
                # Only names we can account for. An unrecognized file might be
                # something a newer Claude Code writes, so it is left alone.
                if ($k.Name -like '*.bak') {
                    [void](& $add 'backup' 'orphan' $folder 'backup file (.bak)' @($k.FullName) '')
                } elseif ($k.Name -eq 'MEMORY.md') {
                    [void](& $add 'stray' 'orphan' $folder 'misplaced; only memory\MEMORY.md is read' @($k.FullName) '')
                }
            }
        }
    }

    foreach ($store in 'file-history', 'session-env', 'tasks') {
        $storeErr = $null
        $dirs = @(Get-ChildItem -LiteralPath (Join-Path $ClaudeRoot $store) -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +storeErr)
        if ($storeErr -and (Test-Path -LiteralPath (Join-Path $ClaudeRoot $store))) { $skipped.Add((Join-Path $ClaudeRoot $store)); continue }
        foreach ($d in $dirs) {
            if ($d.Name -notmatch $uuidRx -or $liveIds -contains $d.Name -or $gone -contains $d.FullName) { continue }
            $f = if ($origin.BySession.ContainsKey($d.Name)) { ConvertTo-FolderLabel -Cwd $origin.BySession[$d.Name] -DirName '' } else { '' }
            [void](& $add $store 'orphan' $f 'session gone' @($d.FullName) '')
        }
    }
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $ClaudeRoot 'jobs') -Directory -Force -ErrorAction SilentlyContinue) {
        if ($d.Name -match '^[0-9a-f]{8}$' -and $livePrefix -notcontains $d.Name -and $gone -notcontains $d.FullName) {
            [void](& $add 'jobs' 'orphan' '' 'no session has this ID prefix' @($d.FullName) '')
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($pd in Get-ChildItem -LiteralPath $tempRoot -Directory -Force -ErrorAction SilentlyContinue) {
            # Per-project dirs only. The rest of %TEMP%\claude is not session data.
            if ($pd.Name -notmatch '^[A-Za-z]--') { continue }
            $folder = & $folderOf $pd.Name
            $kidErr = $null
            $kids = @(Get-ChildItem -LiteralPath $pd.FullName -Force -ErrorAction SilentlyContinue -ErrorVariable +kidErr | Where-Object { $gone -notcontains $_.FullName })
            if ($kidErr) { $skipped.Add($pd.FullName); continue }
            if ($kids.Count -eq 0) {
                if ($runningDirs -notcontains $pd.Name) { [void](& $add 'temp' 'orphan' $folder 'empty' @($pd.FullName) '') }
                continue
            }
            foreach ($k in $kids | Where-Object { $_.PSIsContainer -and $_.Name -match $uuidRx }) {
                if ($liveIds -notcontains $k.Name) {
                    $row = & $add 'temp' 'orphan' $folder 'session gone' @($k.FullName) ''
                    $refCands.Add([pscustomobject]@{ Row = $row; Id = $k.Name; Needles = (& $needles 'claude' $pd.Name $k.Name) })
                } elseif ($running -notcontains $k.Name -and $txDirs.ContainsKey($k.Name) -and $txDirs[$k.Name] -notcontains $pd.Name) {
                    $to = @($txDirs[$k.Name] | ForEach-Object { & $folderOf $_ }) -join ', '
                    $row = & $add 'temp' 'orphan' $folder 'session moved; unreferenced' @($k.FullName) "left behind when the session moved to $to; no transcript points here"
                    $refCands.Add([pscustomobject]@{ Row = $row; Id = $k.Name; Needles = (& $needles 'claude' $pd.Name $k.Name) })
                }
            }
        }
    }
    $reg = Join-Path $ClaudeRoot 'sessions'
    foreach ($j in Get-ChildItem -LiteralPath $reg -Filter *.json -File -Force -ErrorAction SilentlyContinue) {
        $procNum = 0
        if (-not [int]::TryParse($j.BaseName, [ref]$procNum)) { continue }
        if (Get-Process -Id $procNum -ErrorAction SilentlyContinue) { continue }
        $paths = @($j.FullName) + @(Get-ChildItem -LiteralPath $reg -Filter "$procNum.*.key" -File -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
        [void](& $add 'registry' 'orphan' '' 'process gone' $paths '')
    }

    # Drop every sidecar or temp row a live transcript still mentions by path.
    if ($refCands.Count) {
        $live = @($txPaths.Values | ForEach-Object { $_ })
        $refs = Find-ReferencedCandidate -Candidates ([object[]]$refCands) -Transcripts $live
        foreach ($i in $refs.Hit) { [void]$items.Remove($refCands[$i].Row) }
        if (-not $refs.Unreadable.Count -and $refs.Hit.Count) {
            $script:OrphanWithheld   = $refs.Hit.Count
            $script:OrphanWithheldBy = [string[]]@($refs.By.Values | Sort-Object -Unique)
        }
        if ($refs.Unreadable.Count) {
            Write-Warning ("{0} live transcript(s) could not be read, so sidecar and temp leftovers are not listed: any of them might still point there. First: {1}" -f $refs.Unreadable.Count, (Split-Path $refs.Unreadable[0] -Leaf))
        }
    }
    if ($skipped.Count) {
        Write-Warning ("{0} dir(s) could not be listed and were skipped, not treated as empty: {1}" -f $skipped.Count, (@($skipped | ForEach-Object { ConvertTo-DisplayPath $_ }) -join ', '))
    }

    # Empty dirs carry no information one by one (22 session-env dirs would
    # read as 22 identical rows), so fold them into one row per kind. A row
    # with read errors is never folded: "empty" would be a guess.
    $final = New-Object System.Collections.Generic.List[object]
    $foldable = if ($NoFold) { @() } else { @($items | Where-Object { $_.Files -eq 0 -and $_.Errors -eq 0 -and $_.Kind -notin 'memory', 'project', 'registry' }) }
    foreach ($it in $items) { if ($foldable -notcontains $it) { $final.Add($it) } }
    foreach ($g in $foldable | Group-Object Kind, State, Why) {
        if ($g.Count -eq 1) { $final.Add($g.Group[0]); continue }
        $first    = $g.Group[0]
        $allPaths = [string[]]@($g.Group | ForEach-Object { $_.Paths })
        $folders  = @($g.Group | ForEach-Object Folder | Where-Object { $_ } | Sort-Object -Unique)
        $final.Add([pscustomobject]@{
            Index = 0; State = $first.State; Kind = $first.Kind
            Folder = $(if ($folders.Count -eq 1) { $folders[0] } elseif ($folders.Count -gt 1) { '(various)' } else { '' })
            Files = 0; Bytes = [long]0
            LastWrite = @($g.Group | Sort-Object LastWrite -Descending)[0].LastWrite
            Why = "$($g.Count) empty dirs; $($first.Why)"
            Path = (& $where $allPaths)
            Paths = $allPaths; Note = ''; Errors = 0
        })
    }

    $order  = @('memory', 'project', 'sidecar', 'backup', 'stray', 'file-history', 'session-env', 'tasks', 'jobs', 'temp', 'registry')
    $sorted = @($final | Sort-Object @{ Expression = { $order.IndexOf($_.Kind) } }, @{ Expression = { $_.State -eq 'dormant' } }, Path)
    $n = 1
    foreach ($it in $sorted) {
        $it.Index = $n++
        # Size in KB, rounded up like the session table, so 'Where-Object Size' works on both.
        $it | Add-Member -NotePropertyName 'Size' -NotePropertyValue ([int][math]::Ceiling($it.Bytes / 1KB)) -Force
        $it.PSObject.TypeNames.Insert(0, 'CCOrphan')
    }
    return $sorted
}

function Find-ReferencedCandidate {
    # One streaming pass over the given live transcripts, returning the
    # indexes of candidates (rows with an Id and path Needles) that some line
    # mentions. A cheap regex over all candidate IDs picks the few lines worth
    # checking, so this costs one read when nothing is a candidate's. A
    # transcript that cannot be read makes every candidate count as
    # referenced: unknown is not the same as unused.
    # .By maps each hit to the transcript that mentioned it first, so callers
    # can say which session is holding a dir, not just that one is.
    param([object[]]$Candidates, [string[]]$Transcripts)
    $hit = New-Object 'System.Collections.Generic.HashSet[int]'
    $by  = @{}
    $unreadable = New-Object System.Collections.Generic.List[string]
    $all = { for ($i = 0; $i -lt $Candidates.Count; $i++) { [void]$hit.Add($i) } }
    $rx  = [regex]::new((@($Candidates | ForEach-Object { [regex]::Escape($_.Id) } | Sort-Object -Unique) -join '|'), 'IgnoreCase')
    foreach ($t in $Transcripts) {
        if ($hit.Count -eq $Candidates.Count) { break }
        try { $sr = [IO.StreamReader]::new([IO.FileStream]::new($t, 'Open', 'Read', 'ReadWrite')) } catch { $unreadable.Add($t); & $all; break }
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                if (-not $rx.IsMatch($line)) { continue }
                for ($i = 0; $i -lt $Candidates.Count; $i++) {
                    if ($hit.Contains($i) -or $line.IndexOf($Candidates[$i].Id, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    foreach ($nd in $Candidates[$i].Needles) {
                        if ($line.IndexOf($nd, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$hit.Add($i); $by[$i] = $t; break }
                    }
                }
            }
        } catch { $unreadable.Add($t); & $all } finally { $sr.Dispose() }
    }
    return @{ Hit = [int[]]@($hit); Unreadable = [string[]]$unreadable; By = $by }
}

function Select-Orphans {
    # Orphan selectors: o# (or a bare #) from the listing, a kind name, a
    # path fragment, 'dormant', or '*'. Dormant memory loads again if you
    # return to its folder, so only its o# or the word 'dormant' reaches it;
    # '*', a kind and a fragment take orphan rows only. A kind name always
    # means the kind, even when there are none of it, so it never falls
    # through to matching paths that happen to contain the word.
    param([object[]]$Items, [string]$Selector)
    $kinds = @('memory', 'project', 'sidecar', 'backup', 'stray', 'file-history', 'session-env', 'tasks', 'jobs', 'temp', 'registry')
    if ($Selector -match '^[oO]?(\d{1,9})$') { $want = [int]$Matches[1]; return @($Items | Where-Object Index -eq $want) }
    $orphans = @($Items | Where-Object State -eq 'orphan')
    if ($Selector -eq '*' -or $Selector -eq 'orphan') { return $orphans }
    if ($Selector -eq 'dormant') { return @($Items | Where-Object State -eq 'dormant') }
    if ($kinds -contains $Selector) { return @($orphans | Where-Object Kind -eq $Selector) }
    return @($orphans | Where-Object { @($_.Paths | Where-Object { $_.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 })
}

# Table views for both object types. Loaded before the -Orphans section
# because it emits objects too, not only the session table.
$formatXml = Join-Path $PSScriptRoot 'Get-ClaudeCodeSessions.format.ps1xml'
if (Test-Path $formatXml) {
    Update-FormatData -PrependPath $formatXml
}

# ---- Orphans ---------------------------------------------------------------

if ($Orphans) {
    $orphanItems = @(Get-OrphanItems)
    # Held back rather than hidden: name what is pinning them, since a
    # transcript that only discussed a path pins it too.
    $withheldNote = {
        if (-not $script:OrphanWithheld) { return }
        $who = @($script:OrphanWithheldBy | ForEach-Object {
            '{0} in {1}' -f (Split-Path $_ -Leaf), (Resolve-FolderLabel -Cwd '' -DirName (Split-Path (Split-Path $_ -Parent) -Leaf))
        }) -join '; '
        Write-Host ("{0}{1} leftover dir(s) of deleted or moved sessions not listed: a live transcript still points at them ({2}).{3}" -f $Dim, $script:OrphanWithheld, $who, $Reset)
    }

    if (-not $Delete) {
        Write-Host ''
        if ($orphanItems.Count -eq 0) {
            if ($script:OrphanScanIncomplete) { Write-Host 'Could not check for orphans; see the warning above.' }
            else { Write-Host 'No orphans or leftovers found.'; & $withheldNote }
            Write-Host ''
            return
        }
        $sum = [long]0; foreach ($o in $orphanItems) { $sum += $o.Bytes }
        Write-Host ("{0}{1} leftover item(s), {2}.{3}" -f $Bold, $orphanItems.Count, (Format-Size $sum), $Reset)
        Write-Host ("{0}orphan = nothing will ever read it again. dormant = memory that may load again (its folder exists, or could not be checked).{1}" -f $Dim, $Reset)
        Write-Host ("{0}Remove with -Orphans -Delete <o#|kind|path fragment|*>. Those take orphans only; dormant memory needs its o# or the word dormant.{1}" -f $Dim, $Reset)
        Write-Host ("{0}Never listed, kept by design: history.jsonl (your prompts outlive their sessions), .claude.json, paste-cache\.{1}" -f $Dim, $Reset)
        & $withheldNote
        $partial = @($orphanItems | Where-Object Errors)
        if ($partial.Count) {
            Write-Host ("{0}{1} item(s) could not be read in full, so their Files and Size are a floor: {2}.{3}" -f $Yellow, $partial.Count, (@($partial | ForEach-Object { "o$($_.Index)" }) -join ', '), $Reset)
        }
        $unknownLive = @(Get-UnknownRunningSession)
        if ($unknownLive.Count) {
            Write-Host ("{0}A running session's registry entry could not be read ({1}), so some of these may be its own. -Orphans -Delete refuses until it reads.{2}" -f $Yellow, ($unknownLive -join ', '), $Reset)
        }
        $orphanItems
        return
    }

    # A live session whose registry entry cannot be read might own any of
    # these (a new session has a session-env before its first transcript line).
    $unknownLive = @(Get-UnknownRunningSession)
    if ($unknownLive.Count) {
        Write-Error ("A running Claude Code session's registry entry could not be read ({0}), so it is unknown what is live. Nothing was deleted; try again in a moment." -f ($unknownLive -join ', '))
        Write-Host ''
        return
    }

    $targetItems = @(Select-Orphans -Items $orphanItems -Selector $Delete)
    if ($targetItems.Count -eq 0) {
        if ($script:OrphanScanIncomplete) { Write-Warning 'Nothing was deleted: the orphan scan could not complete.' }
        else { Write-Warning "No orphan matched -Delete '$Delete'. Run -Orphans on its own to see the list." }
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host ("{0}The following {1} item(s) will be PERMANENTLY deleted:{2}" -f $Bold, $targetItems.Count, $Reset)
    $totalBytes = [long]0; $totalFiles = 0; $unreadable = 0
    foreach ($t in $targetItems) {
        Write-Host ''
        $where = if ($t.Folder) { "  in $($t.Folder)" } else { '' }
        Write-Host ("  {0}[o{1}] {2}{3}{4}  ({5}: {6})" -f $Bold, $t.Index, $t.Kind, $Reset, $where, $t.State, $t.Why)
        $when = if ($t.LastWrite) { ', last written ' + $t.LastWrite.ToString('yyyy-MM-dd HH:mm') } else { '' }
        Write-Host ("    {0:N0} file(s), {1}{2}" -f $t.Files, (Format-Size $t.Bytes), $when)
        if ($t.Paths.Count -le 5) { foreach ($p in $t.Paths) { Write-Host ("    {0}" -f (ConvertTo-DisplayPath $p)) } }
        else { Write-Host ("    {0}" -f $t.Path) }
        if ($t.Note) { Write-Host ("    {0}{1}{2}" -f $Dim, $t.Note, $Reset) }
        if ($t.State -eq 'dormant') { Write-Host ("    {0}Dormant: this memory loads again if you start a session in {1}.{2}" -f $Yellow, $t.Folder, $Reset) }
        $totalBytes += $t.Bytes; $totalFiles += $t.Files; $unreadable += $t.Errors
    }
    Write-Host ''
    Write-Host ("  {0}Total: {1} in {2:N0} file(s).{3}" -f $Bold, (Format-Size $totalBytes), $totalFiles, $Reset)
    if ($unreadable) { Write-Host ("  {0}{1} item(s) could not be read, so that total may undercount.{2}" -f $Yellow, $unreadable, $Reset) }
    Write-Host ("  {0}A project dir or %TEMP% dir this leaves empty is removed too.{1}" -f $Dim, $Reset)
    Write-Host ("  {0}There is no Recycle Bin. This cannot be undone.{1}" -f $Red, $Reset)
    Write-Host ''

    $answer = Read-Host "Type 'yes' to delete"
    if ($answer -ne 'yes') {
        Write-Host ("{0}Aborted. Nothing was deleted.{1}" -f $Cyan, $Reset)
        Write-Host ''
        return
    }

    # The world may have moved while the prompt waited: a session can start
    # in a folder, or a transcript can start pointing at a sidecar. Only what
    # a fresh scan still calls an orphan is removed.
    $unknownLive = @(Get-UnknownRunningSession)
    if ($unknownLive.Count) {
        Write-Error ("A running Claude Code session's registry entry became unreadable ({0}). Nothing was deleted; try again." -f ($unknownLive -join ', '))
        Write-Host ''
        return
    }
    $stillOrphan = @(Get-OrphanItems -NoFold | ForEach-Object { $_.Paths })
    if ($script:OrphanScanIncomplete) {
        Write-Warning 'Nothing was deleted: the re-check after your answer could not complete.'
        Write-Host ''
        return
    }

    $tempRoot    = Get-ClaudeTempRoot
    $runningDirs = @(Get-RunningProjectDir)
    $removed = 0; $failed = 0; $freed = [long]0
    foreach ($t in $targetItems) {
        $ok = $true; $parents = @(); $kept = 0
        foreach ($p in $t.Paths) {
            if ($stillOrphan -notcontains $p) {
                if (Test-Path -LiteralPath $p) { $kept++; Write-Host ("  {0}kept {1}: no longer an orphan{2}" -f $Dim, (ConvertTo-DisplayPath $p), $Reset) }
                continue
            }
            if (Remove-PathHard -Path $p) { $parents += (Split-Path $p -Parent) }
            else { $ok = $false; Write-Warning "  could not remove $p" }
        }
        if ($ok -and $kept -lt $t.Paths.Count) { $removed++; $freed += $t.Bytes; Write-Host ("{0}deleted{1} [o{2}] {3}  {4}" -f $Green, $Reset, $t.Index, $t.Kind, $t.Path) }
        elseif (-not $ok) { $failed++ }
        # A project dir (or its %TEMP% twin) emptied by this is a shell: take it too.
        foreach ($parent in @($parents | Sort-Object -Unique)) {
            $grand = Split-Path $parent -Parent
            if ($grand -ne $ProjectsRoot -and $grand -ne $tempRoot) { continue }
            if (-not (Test-Path -LiteralPath $parent) -or $runningDirs -contains (Split-Path $parent -Leaf) -or (Test-ProtectedPath $parent)) { continue }
            if (-not (Test-ShellDir -Path $parent)) { continue }
            if (Remove-PathHard -Path $parent) { Write-Host ("  {0}+ removed the now-empty {1}{2}" -f $Dim, (ConvertTo-DisplayPath $parent), $Reset) }
        }
    }
    Write-Host ''
    Write-Host ("{0}Deleted {1} of {2} item(s), freed ~{3}.{4}" -f $Green, $removed, $targetItems.Count, (Format-Size $freed), $Reset)
    if ($failed) { Write-Host ("{0}{1} failed.{2}" -f $Red, $failed, $Reset) }
    Write-Host ''
    return
}

# ---- Scan ------------------------------------------------------------------

# Listing errors are collected, not swallowed: a project dir that cannot be
# listed drops its sessions from the table and shifts every Index after them.
$ListErr = $null
$ProjectDirs = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +ListErr)

$Sessions = New-Object System.Collections.Generic.List[object]
# -Search misses: never shown, but numbered. See the note at the sort below.
$Misses   = New-Object System.Collections.Generic.List[object]
$Unreadable = New-Object System.Collections.Generic.List[string]

# -Search runs on the raw JSONL, where a backslash is stored as \\ and a
# quote as \". So the phrase is also tried in that escaped form, or any path
# search (the most natural kind) would find nothing.
$SearchPatterns = @()
if ($Search) {
    $SearchPatterns = @($Search)
    $escaped = $Search.Replace('\', '\\').Replace('"', '\"')
    if ($escaped -cne $Search) { $SearchPatterns += $escaped }
}

foreach ($dir in $ProjectDirs) {
    # Never -Filter for these: on a dir that cannot be listed, Get-ChildItem
    # -Filter returns nothing and raises no error at all (verified on 7.6),
    # so an unreadable project dir would pass for an empty one. Every other
    # form reports access-denied.
    $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -Force -ErrorAction SilentlyContinue -ErrorVariable +ListErr | Where-Object Extension -eq '.jsonl')
    if ($IncludeSubagents) {
        # Exactly what Test-SubagentPath recognizes: <uuid>\subagents\*.jsonl.
        foreach ($sc in Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +ListErr) {
            $sa = Join-Path $sc.FullName 'subagents'
            if (Test-Path -LiteralPath $sa -PathType Container) {
                $files += @(Get-ChildItem -LiteralPath $sa -File -Force -ErrorAction SilentlyContinue -ErrorVariable +ListErr | Where-Object Extension -eq '.jsonl')
            }
        }
    }

    foreach ($file in $files) {
        $isSub = Test-SubagentPath $file.FullName
        if ($Search) {
            $searchErr = $null
            $hit = Select-String -LiteralPath $file.FullName -Pattern $SearchPatterns -SimpleMatch -List -ErrorAction SilentlyContinue -ErrorVariable searchErr
            if ($searchErr) { $Unreadable.Add($file.FullName) }
            if (-not $hit) {
                $probe = Get-SessionData -JsonlPath $file.FullName -CwdOnly -Subagent:$isSub
                if ($probe.ReadError -and $Unreadable -notcontains $file.FullName) { $Unreadable.Add($file.FullName) }
                $Misses.Add([PSCustomObject]@{
                    Folder   = Resolve-FolderLabel -Cwd $probe.Cwd -DirName $dir.Name
                    File     = $file.Name
                    Modified = $file.LastWriteTime
                    FullPath = $file.FullName
                    IsMiss   = $true
                })
                continue
            }
        }

        # -Light: the table needs no turn texts; -Open parses its session again.
        $data = Get-SessionData -JsonlPath $file.FullName -Light -Subagent:$isSub
        if ($data.ReadError) { $Unreadable.Add($file.FullName) }

        $Sessions.Add([PSCustomObject]@{
            Folder   = Resolve-FolderLabel -Cwd $data.Cwd -DirName $dir.Name
            Session  = $data.CustomTitle
            File     = $file.Name
            Modified = $file.LastWriteTime
            # Rounded up, like Format-Size, so the table and the delete
            # plan show the same KB for the same file.
            Size     = [int][math]::Ceiling($file.Length / 1KB)
            Context  = $data.Context
            Model    = $data.Model
            FullPath = $file.FullName
        })
    }
}

if ($ListErr) {
    Write-Warning ("{0} error(s) listing the project dirs, so sessions may be missing from this list and the Index numbers after them shifted. First: {1}" -f
        $ListErr.Count, $ListErr[0].Exception.Message)
}

# A transcript that cannot be opened is unknown, not empty: say so instead of
# showing it as an untitled session with no context.
if ($Unreadable.Count) {
    Write-Warning ("{0} transcript(s) could not be read (another program may hold them locked), so their title, context and model are unknown: {1}" -f
        $Unreadable.Count, (@($Unreadable | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
}

# Assign stable indexes BEFORE the selectors and filters run, -Search
# included, so the numbers printed by an earlier bare `Get-ClaudeCodeSessions`
# still resolve. -Search misses are numbered too and dropped afterwards: an
# Index must mean the same session with or without -Search, or '-Search x'
# followed by a bare '-Delete 1' hits a different session. FullPath breaks
# ties so the order is deterministic.
#
# Only root transcripts are numbered, for the same reason: with
# -IncludeSubagents, numbered subagent rows renumbered 28 of 34 sessions, so
# an Index read with the switch pointed somewhere else without it. Subagent
# rows have no Index (they cannot be deleted on their own anyway) and are
# listed right under the transcript of the session they belong to.
$numbered = New-Object System.Collections.Generic.List[object]
$numbered.AddRange($Sessions); $numbered.AddRange($Misses)
$roots   = @($numbered | Where-Object { -not (Test-SubagentPath $_.FullPath) } | Sort-Object Folder, @{ Expression = 'Modified'; Descending = $true }, FullPath)
$subRows = @($numbered | Where-Object { Test-SubagentPath $_.FullPath } | Sort-Object @{ Expression = 'Modified'; Descending = $true }, FullPath)
$i = 1
foreach ($s in $roots) {
    $s | Add-Member -NotePropertyName 'Index' -NotePropertyValue $i -Force
    $i++
}
$underParent = @{}
foreach ($s in $subRows) {
    $s | Add-Member -NotePropertyName 'Index' -NotePropertyValue $null -Force
    $parentPath = (Split-Path (Split-Path $s.FullPath -Parent) -Parent) + '.jsonl'
    if (-not $underParent.ContainsKey($parentPath)) { $underParent[$parentPath] = New-Object System.Collections.Generic.List[object] }
    $underParent[$parentPath].Add($s)
}
$sorted = New-Object System.Collections.Generic.List[object]
foreach ($r in $roots) {
    $sorted.Add($r)
    if ($underParent.ContainsKey($r.FullPath)) { $sorted.AddRange($underParent[$r.FullPath]); $underParent.Remove($r.FullPath) }
}
# Subagent transcripts whose session transcript is gone go last.
foreach ($k in @($underParent.Keys)) { $sorted.AddRange($underParent[$k]) }
$sorted = [object[]]$sorted
# Unfiltered, misses included, so the delete plan can name the folder of a
# surviving copy even when a filter hid it.
$AllSessions = $sorted
$Sessions = @($sorted | Where-Object { -not $_.PSObject.Properties['IsMiss'] })

# Narrowing filters. These combine (logical AND) and apply AFTER index
# assignment, so the Index column stays stable regardless of which are active.
if ($OlderThan -gt 0) {
    $cutoff   = (Get-Date).AddDays(-$OlderThan)
    $Sessions = @($Sessions | Where-Object { $_.Modified -lt $cutoff })
}
if ($SmallerThan -gt 0) {
    $Sessions = @($Sessions | Where-Object { $_.Size -lt $SmallerThan })
}
if ($Unnamed) {
    $Sessions = @($Sessions | Where-Object { -not $_.Session })
}
if ($Limit -gt 0) {
    $Sessions = @($Sessions | Select-Object -First $Limit)
}

$HasFilter = [bool]$Search -or ($OlderThan -gt 0) -or ($SmallerThan -gt 0) -or $Unnamed

# ---- Delete ----------------------------------------------------------------

if ($Delete) {
    # o# only means something in the -Orphans listing. Without the switch it
    # would fall through to substring matching on session titles.
    if ($Delete -match '^[oO]\d+$') {
        Write-Error "'$Delete' is an orphan index from the -Orphans listing. Run: Get-ClaudeCodeSessions -Orphans -Delete $Delete"
        Write-Host ''
        return
    }

    if ($Delete -eq '*' -and -not $HasFilter) {
        Write-Error ("Refusing to delete every session. '-Delete *' needs a filter first: " +
            "-Search, -OlderThan, -SmallerThan or -Unnamed. To preview any delete, run it and answer 'no', " +
            "or name a single session: -Delete <index|uuid|title>.")
        Write-Host ''
        return
    }

    # A live session whose registry entry cannot be read could be any of the
    # targets, so nothing is planned until it reads cleanly.
    $unknownLive = @(Get-UnknownRunningSession)
    if ($unknownLive.Count) {
        Write-Error ("A running Claude Code session's registry entry could not be read ({0}), so it is unknown which sessions are live. Nothing was deleted; try again in a moment." -f ($unknownLive -join ', '))
        Write-Host ''
        return
    }

    # @() so .Count is reliable: a function's output is unrolled, so a single
    # match would otherwise arrive as a bare object rather than a 1-item array.
    $targets = @(Select-BySelector -Candidates $Sessions -Selector $Delete)
    if ($targets.Count -eq 0) {
        Write-Warning "No session matched -Delete '$Delete'."
        Write-Host ''
        return
    }

    # A fragment that matches every session ('-', 'a', a shared prefix) is
    # '*' by another name, so it gets the same rule: not without a filter.
    $allRoots = @($Sessions | Where-Object { -not (Test-SubagentPath $_.FullPath) })
    $rootHits = @($targets | Where-Object { -not (Test-SubagentPath $_.FullPath) })
    if ($Delete -ne '*' -and -not $HasFilter -and $rootHits.Count -gt 1 -and $rootHits.Count -eq $allRoots.Count) {
        Write-Error ("'$Delete' matches every session, which is what '*' means. Narrow it with a filter " +
            "(-Search, -OlderThan, -SmallerThan, -Unnamed) or name one session.")
        Write-Host ''
        return
    }

    # A subagent transcript (an -IncludeSubagents row) is part of its parent
    # session's sidecar and goes with that session, never on its own. Point
    # at the parent instead of planning something that makes no sense.
    $subRows = @($targets | Where-Object { Test-SubagentPath $_.FullPath })
    foreach ($s in $subRows) {
        $parentId = Split-Path (Split-Path (Split-Path $s.FullPath -Parent) -Parent) -Leaf
        $parent   = @($AllSessions | Where-Object { $_.File -eq "$parentId.jsonl" -and $_.PSObject.Properties['Index'] -and $_.Index })
        $hint = if ($parent.Count) { "delete its session instead: Get-ClaudeCodeSessions -Delete $parentId  (Index $($parent[0].Index))" } else { 'its session is gone, so -Orphans lists what is left of it' }
        Write-Warning ("{0} is a subagent transcript of session {1}; {2}" -f $s.File, $parentId, $hint)
    }
    if ($subRows.Count) {
        $targets = @($targets | Where-Object { $subRows -notcontains $_ })
        if ($targets.Count -eq 0) { Write-Host ''; return }
    }

    # A session moved or copied by hand lives in two folders under ONE file
    # name, so a UUID fragment or a title matches every copy at once. Deleting
    # both by accident is exactly how you lose the copy you kept, so a
    # substring selector that hits two copies is refused: pick one by index.
    # '*' after a filter means "everything matched" and is left alone.
    if ($Delete -ne '*' -and $Delete -notmatch '^#?\d+$') {
        $twins = @($targets | Where-Object { Test-SessionId ([IO.Path]::GetFileNameWithoutExtension($_.File)) } |
                   Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.File) } | Where-Object Count -gt 1)
        if ($twins.Count) {
            foreach ($g in $twins) {
                Write-Warning ("'{0}' matches {1} copies of one session ({2}). Pick the copy by its index:" -f $Delete, $g.Count, $g.Name)
                foreach ($s in $g.Group) {
                    Write-Host ("    Get-ClaudeCodeSessions -Delete {0}    # {1}  in {2}" -f $s.Index, $(if ($s.Session) { $s.Session } else { '(unnamed)' }), $s.Folder)
                }
            }
            Write-Host ''
            return
        }
    }

    # Never delete the copy of a session that is running right now. Searching
    # for a phrase from inside a session used to match that very session (the
    # prompt holding the phrase is logged to its transcript), and this guard
    # is what makes that harmless. Decided per COPY, not per session ID: when
    # a session lives in two folders, the registry's cwd says which copy the
    # live process writes. The other copy is released only when the live one
    # is positively found in a folder a live process is using; anything less
    # certain (no cwd, or a cwd that matches no copy) protects every copy.
    $live = @(Get-RunningSession)
    $isRunning = {
        param($s)
        $u    = [IO.Path]::GetFileNameWithoutExtension($s.File)
        $recs = @($live | Where-Object { $_.SessionId -and $_.SessionId -eq $u })
        if (-not $recs.Count) { return $false }
        $dirs = @($recs | Where-Object ProjectDir | ForEach-Object ProjectDir)
        if ($dirs -contains (Split-Path (Split-Path $s.FullPath -Parent) -Leaf)) { return $true }
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $ProjectsRoot $d) "$u.jsonl")) { return $false }
        }
        return $true
    }
    $skipped = @($targets | Where-Object { & $isRunning $_ })
    $targets = @($targets | Where-Object { -not (& $isRunning $_) })

    foreach ($s in $skipped) {
        Write-Warning ("Skipping live session [{0}] {1} - it is running right now." -f $s.Index, $s.File)
    }
    if ($targets.Count -eq 0) {
        if ($skipped.Count -gt 0) {
            Write-Warning 'Nothing left to delete: every matched session is running right now. Exit it first, or run this from outside Claude Code.'
        } else {
            Write-Warning "No session matched -Delete '$Delete'."
        }
        Write-Host ''
        return
    }

    # Every root transcript on disk, by file stem. Needed BEFORE the plan: the
    # same session ID can be a root transcript in two project dirs at once (a
    # session whose cwd changed, or one relocated by hand). The copies share
    # one footprint, which goes only with the last copy, so the plan must know
    # whether a copy survives outside this delete.
    $transcriptsByUuid = @{}
    # A dir that cannot be listed could hold a surviving copy, or a transcript
    # still reading this session's files. Unknown, so the footprint is kept.
    $txErr = $null
    foreach ($dir in $ProjectDirs) {
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -File -Force -ErrorAction SilentlyContinue -ErrorVariable +txErr | Where-Object Extension -eq '.jsonl') {
            $u = $f.BaseName
            if (-not $transcriptsByUuid.ContainsKey($u)) { $transcriptsByUuid[$u] = New-Object System.Collections.Generic.List[string] }
            $transcriptsByUuid[$u].Add($f.FullName)
        }
    }
    $allTranscripts = @($transcriptsByUuid.Values | ForEach-Object { $_ })
    $listingIncomplete = [bool]($ListErr -or $txErr)
    $tempRoot = Get-ClaudeTempRoot

    # One block per session, holding every copy being deleted. Only a real
    # session ID groups copies and gets a footprint; any other file (a stem
    # like '', '..' or 'notes') is just that file.
    $groups = [ordered]@{}
    foreach ($s in $targets) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($s.File)
        $key  = if (Test-SessionId $stem) { $stem } else { $s.FullPath }
        if (-not $groups.Contains($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($s)
    }
    $targetPaths     = @($targets | ForEach-Object FullPath)
    $footprintByUuid = @{}

    Write-Host ''
    Write-Host ("{0}The following {1} session(s) will be PERMANENTLY deleted:{2}" -f $Bold, $targets.Count, $Reset)
    $totalBytes = [long]0; $totalFiles = 0; $unreadable = 0
    foreach ($key in $groups.Keys) {
        $copies = $groups[$key]
        $isId   = Test-SessionId $key
        Write-Host ''
        foreach ($s in $copies) {
            $name = if ($s.Session) { $s.Session } else { '(unnamed)' }
            Write-Host ("  {0}[{1}] {2}{3}  in {4}" -f $Bold, $s.Index, $name, $Reset, $s.Folder)
            # An index can point somewhere new between a listing and a delete,
            # and '(unnamed)' tells two sessions apart badly: show what started it.
            $first = Get-FirstPrompt -JsonlPath $s.FullPath
            if ($first) { Write-Host ("  {0}first prompt: {1}{2}" -f $Dim, $first, $Reset) }
        }
        if ($isId) {
            $twin = if ($copies.Count -gt 1) { "  ($($copies.Count) copies of one session)" } else { '' }
            Write-Host ("  {0}session ID {1}{2}{3}" -f $Dim, $key, $twin, $Reset)
        } else {
            Write-Host ("  {0}not named like a session ID, so only this file is deleted{1}" -f $Dim, $Reset)
        }

        $parts = New-Object System.Collections.Generic.List[object]
        foreach ($s in $copies) { $parts.Add((New-FootprintPart 'transcript' $s.FullPath)) }

        $notes = New-Object System.Collections.Generic.List[string]
        $footprintByUuid[$key] = @()
        if ($isId) {
            $survivors = @($transcriptsByUuid[$key] | Where-Object { $_ -and $targetPaths -notcontains $_ })
            if ($survivors.Count) {
                $where = @($survivors | ForEach-Object {
                    $sp = $_
                    $hit = @($AllSessions | Where-Object FullPath -eq $sp)
                    if ($hit.Count) { $hit[0].Folder } else { Split-Path (Split-Path $sp -Parent) -Leaf }
                }) -join ', '
                $notes.Add("Everything else this session owns is KEPT: the same session ID is still alive in $where.")
            } elseif ($listingIncomplete) {
                $notes.Add('Everything else this session owns is KEPT: a project dir could not be listed, and it might hold a copy of this session or a transcript still using its files.')
            } else {
                # @() because Get-SessionFootprint's List is unrolled on output.
                $paths = @(Get-SessionFootprint -Uuid $key)
                # jobs\ is keyed by only the first 8 hex chars, so a different
                # live session could own the same dir. Keep it rather than guess.
                $prefix = $key.Substring(0, 8)
                if (@($transcriptsByUuid.Keys | Where-Object { $_ -ne $key -and $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                    $jobsPath = Join-Path (Join-Path $ClaudeRoot 'jobs') $prefix
                    if ($paths -contains $jobsPath) { $notes.Add("Kept jobs\${prefix}: another session shares that ID prefix.") }
                    $paths = @($paths | Where-Object { $_ -ne $jobsPath })
                }
                # A sidecar or temp dir another live transcript still mentions
                # by path stays: a session moved the CLAUDE.md way gets a new ID
                # and keeps reading the old ID's saved tool output.
                $cands = @(foreach ($p in $paths) {
                    $dirName = Split-Path (Split-Path $p -Parent) -Leaf
                    if ($p.StartsWith("$ProjectsRoot\", [StringComparison]::OrdinalIgnoreCase)) {
                        [pscustomobject]@{ Path = $p; Id = $key; Needles = @("projects\\$dirName\\$key", "projects/$dirName/$key", "projects\$dirName\$key") }
                    } elseif ($p.StartsWith("$tempRoot\", [StringComparison]::OrdinalIgnoreCase)) {
                        [pscustomobject]@{ Path = $p; Id = $key; Needles = @("claude\\$dirName\\$key", "claude/$dirName/$key", "claude\$dirName\$key") }
                    }
                })
                $others = @($allTranscripts | Where-Object { $targetPaths -notcontains $_ })
                if ($cands.Count -and $others.Count) {
                    $refs = Find-ReferencedCandidate -Candidates $cands -Transcripts $others
                    $keep = @($refs.Hit | ForEach-Object { $cands[$_].Path })
                    if ($keep.Count) {
                        $paths = @($paths | Where-Object { $keep -notcontains $_ })
                        if ($refs.Unreadable.Count) {
                            $notes.Add(("Kept {0}: another transcript could not be read, so it might still use them." -f (@($keep | ForEach-Object { ConvertTo-DisplayPath $_ }) -join ', ')))
                        } else {
                            # Named, because a transcript that merely discussed
                            # a path pins it too, and only you can tell which.
                            $notes.Add("Kept, because another session's transcript still points there:")
                            foreach ($i in $refs.Hit) {
                                $tp  = $refs.By[$i]
                                $who = @($AllSessions | Where-Object FullPath -eq $tp)[0]
                                $label = if ($who) {
                                    '[{0}] {1} in {2}{3}' -f $who.Index, $(if ($who.Session) { $who.Session } else { '(unnamed)' }), $who.Folder, $(if (& $isRunning $who) { ', running now' } else { '' })
                                } elseif ($tp) { Split-Path $tp -Leaf } else { 'another transcript' }
                                $notes.Add(('  {0}  <- {1}' -f (ConvertTo-DisplayPath $cands[$i].Path), $label))
                            }
                        }
                    }
                }
                $footprintByUuid[$key] = $paths
                foreach ($part in Get-FootprintParts -Paths $paths) { $parts.Add($part) }
            }
        }

        Write-Host ''
        Write-Host ("    {0,-24} {1,6} {2,12}  {3}" -f 'Part', 'Files', 'Size', 'Path')
        Write-Host ("    {0,-24} {1,6} {2,12}  {3}" -f '----', '-----', '----', '----')
        foreach ($part in $parts) {
            Write-Host ("    {0,-24} {1,6:N0} {2,12}  {3}" -f $part.Label, $part.Files, (Format-Size $part.Bytes), (ConvertTo-DisplayPath $part.Path))
            $totalBytes += $part.Bytes; $totalFiles += $part.Files; $unreadable += $part.Errors
        }
        foreach ($nt in $notes) { Write-Host ("    {0}{1}{2}" -f $Dim, $nt, $Reset) }
    }

    Write-Host ''
    Write-Host ("  {0}Total: {1} in {2:N0} file(s).{3}" -f $Bold, (Format-Size $totalBytes), $totalFiles, $Reset)
    if ($unreadable) { Write-Host ("  {0}{1} item(s) could not be read, so that total may undercount.{2}" -f $Yellow, $unreadable, $Reset) }

    # What this delete leaves behind: ask the orphan finder what the world
    # looks like once these transcripts and footprint paths are gone, with the
    # same rules -Orphans uses. Keep only rows that belong to this delete:
    # anything carrying one of these session IDs in its path, and everything
    # -Orphans would list inside a project dir this delete vacates (its last
    # session goes) or that dir's %TEMP% twin. Unrelated orphans elsewhere are
    # left to -Orphans. 'project' rows and empty 'temp' rows are the dirs
    # themselves; those are shells, handled below, so they are not listed twice.
    $projPaths   = @($targets | ForEach-Object { Split-Path $_.FullPath -Parent } | Sort-Object -Unique)
    $runningDirs = @(Get-RunningProjectDir)
    $footprint   = @($footprintByUuid.Values | ForEach-Object { $_ })
    $goneYes     = @($targetPaths) + $footprint
    $othersIn    = {
        param([string]$Dir)
        @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.jsonl' -and $targetPaths -notcontains $_.FullName }).Count
    }
    $vacated = @($projPaths | Where-Object { -not (& $othersIn $_) -and $runningDirs -notcontains (Split-Path $_ -Leaf) })
    $roots   = @($vacated | ForEach-Object { $_; Join-Path $tempRoot (Split-Path $_ -Leaf) })
    $ids     = @($groups.Keys | Where-Object { Test-SessionId $_ })
    $leftBehind = @(Get-OrphanItems -GoneTranscripts $targetPaths -GonePaths $footprint -NoFold | Where-Object {
        $it = $_
        if ($it.Kind -eq 'project' -or ($it.Kind -eq 'temp' -and $it.Why -eq 'empty')) { return $false }
        @($it.Paths | Where-Object {
            $p = $_
            (@($ids | Where-Object { $p.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) -or
            (@($roots | Where-Object { $p.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        }).Count -gt 0
    })
    $leftUnknown = [bool]$script:OrphanScanIncomplete
    $goneAll = $goneYes + @($leftBehind | ForEach-Object { $_.Paths })

    # Dirs that end up holding nothing, removed with whichever answer empties
    # them. Only these are removed afterwards, re-checked at that moment, so
    # the plan never promises a removal the executor then skips or exceeds.
    $shellCands = @($projPaths | ForEach-Object { $_; Join-Path $tempRoot (Split-Path $_ -Leaf) })
    $isShell = {
        param([string]$Dir, [string[]]$Ignore)
        (Test-Path -LiteralPath $Dir) -and -not (Test-ProtectedPath $Dir) -and
            ($runningDirs -notcontains (Split-Path $Dir -Leaf)) -and (Test-ShellDir -Path $Dir -Ignore $Ignore)
    }
    $shellsYes = @($shellCands | Where-Object { & $isShell $_ $goneYes })
    $shellsAll = @($shellCands | Where-Object { $shellsYes -notcontains $_ -and (& $isShell $_ $goneAll) })
    if ($shellsYes.Count) {
        Write-Host ("  {0}Also removed, since they end up empty: {1}{2}" -f $Dim, (@($shellsYes | ForEach-Object { ConvertTo-DisplayPath $_ }) -join ', '), $Reset)
    }

    if ($leftBehind.Count -or $shellsAll.Count) {
        Write-Host ''
        Write-Host ("  {0}Left behind, unless you answer 'all':{1}" -f $Bold, $Reset)
        $lbBytes = [long]0; $lbFiles = 0
        foreach ($x in $leftBehind) {
            Write-Host ("    {0,-24} {1,6:N0} {2,12}  {3}" -f $x.Kind, $x.Files, (Format-Size $x.Bytes), $x.Path)
            $why = if ($x.Kind -eq 'memory' -and $x.Why -like '*folder exists*') { "dormant: $($x.Folder) still exists, so this memory would load again in a new session there" }
                   elseif ($x.Kind -eq 'memory' -and $x.Why -like '*folder gone*') { "$($x.Folder) no longer exists" }
                   else { $x.Why }
            if ($x.Errors -and $why -ne $x.Why) { $why += "; $($x.Errors) unreadable" }
            Write-Host ("      {0}{1}{2}" -f $Dim, $why, $Reset)
            if ($x.Note) { Write-Host ("      {0}{1}{2}" -f $Dim, $x.Note, $Reset) }
            $lbBytes += $x.Bytes; $lbFiles += $x.Files
        }
        if ($shellsAll.Count) {
            Write-Host ("    {0}then the dirs left empty: {1}{2}" -f $Dim, (@($shellsAll | ForEach-Object { ConvertTo-DisplayPath $_ }) -join ', '), $Reset)
        }
        Write-Host ("    'all' adds {0} in {1:N0} file(s)." -f (Format-Size $lbBytes), $lbFiles)
    }
    if ($leftUnknown) {
        Write-Host ("  {0}Could not work out what this delete leaves behind (see the warning above), so 'all' would remove nothing extra.{1}" -f $Yellow, $Reset)
    }

    # Say out loud what stays. The old plan only said 'NOT touched', which
    # left you guessing whether memory or CLAUDE.md were among the parts.
    Write-Host ''
    Write-Host ("  {0}Kept either way:{1}" -f $Bold, $Reset)
    foreach ($pdPath in $projPaths) {
        $mem = Get-PathStats -Path (Join-Path $pdPath 'memory')
        if (-not ($mem.Files -or $mem.Errors)) { continue }
        $folder = @($targets | Where-Object { (Split-Path $_.FullPath -Parent) -eq $pdPath })[0].Folder
        $others = & $othersIn $pdPath
        $why = if ($others) { "$others other session(s) there still use it" }
               elseif (Test-ProtectedPath (Join-Path $pdPath 'memory')) { "the home folder's memory is never removed" }
               elseif ($runningDirs -contains (Split-Path $pdPath -Leaf)) { 'a session running there uses it' }
               else { $null }   # vacated: listed under 'Left behind' instead
        $count = if ($mem.Errors) { '{0:N0}+ file(s), {1}+ ({2} read error(s))' -f $mem.Files, (Format-Size $mem.Bytes), $mem.Errors } else { '{0:N0} file(s), {1}' -f $mem.Files, (Format-Size $mem.Bytes) }
        if ($why) { Write-Host ("    memory for {0}: {1}; {2}." -f $folder, $count, $why) }
    }
    Write-Host '    your project folders themselves (CLAUDE.md included), history.jsonl, .claude.json, paste-cache\'
    Write-Host ("  {0}There is no Recycle Bin. This cannot be undone.{1}" -f $Red, $Reset)
    Write-Host ''

    $prompt = if ($leftBehind.Count -or $shellsAll.Count) { "Type 'yes' to delete, or 'all' to also remove what it leaves behind" } else { "Type 'yes' to delete" }
    $answer = Read-Host $prompt
    if ($answer -notin 'yes', 'all') {
        Write-Host ("{0}Aborted. Nothing was deleted.{1}" -f $Cyan, $Reset)
        Write-Host ''
        return
    }

    # The world may have moved while the prompt waited: check again before
    # touching anything. A session that started meanwhile is skipped.
    $unknownLive = @(Get-UnknownRunningSession)
    if ($unknownLive.Count) {
        Write-Error ("A running Claude Code session's registry entry became unreadable ({0}). Nothing was deleted; try again." -f ($unknownLive -join ', '))
        Write-Host ''
        return
    }
    $live = @(Get-RunningSession)
    $lateLive = @($targets | Where-Object { & $isRunning $_ })
    foreach ($s in $lateLive) { Write-Warning ("Skipping [{0}] {1}: it started running while the prompt waited." -f $s.Index, $s.File) }

    # Deletes exactly what the plan showed: the footprint paths were fixed
    # above. What is re-checked here is only whether each may still go.
    $deleted = 0; $failed = 0; $freed = [long]0; $keptCopy = 0; $keptFailed = 0
    foreach ($key in $groups.Keys) {
        $groupFailed = $false
        foreach ($s in $groups[$key]) {
            if ($lateLive -contains $s) { $groupFailed = $true; continue }
            $bytes = (Get-PathStats -Path $s.FullPath).Bytes
            if (-not (Remove-PathHard -Path $s.FullPath)) {
                Write-Error "Failed to delete transcript $($s.FullPath)"
                $failed++; $groupFailed = $true
                continue
            }
            $deleted++; $freed += $bytes
            Write-Host ("{0}deleted{1} [{2}] {3}" -f $Green, $Reset, $s.Index, $s.File)
        }
        if (-not $footprintByUuid[$key].Count) { continue }

        # The shared footprint goes only once no copy remains anywhere. Asked
        # of the disk, not the plan: a copy may have failed to delete, or one
        # may have appeared in another folder meanwhile.
        if ($groupFailed) {
            Write-Host ("  {0}kept the rest of this session: its transcript is still there{1}" -f $Dim, $Reset)
            $keptFailed++
            continue
        }
        $copiesNow = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force -ErrorAction SilentlyContinue |
                       ForEach-Object { Join-Path $_.FullName "$key.jsonl" } | Where-Object { Test-Path -LiteralPath $_ })
        if ($copiesNow.Count) {
            Write-Host ("  {0}kept this session's shared data: a copy still exists at {1}{2}" -f $Dim, (ConvertTo-DisplayPath $copiesNow[0]), $Reset)
            $keptCopy++
            continue
        }
        foreach ($extra in $footprintByUuid[$key]) {
            $st = Get-PathStats -Path $extra
            if (Remove-PathHard -Path $extra) {
                $freed += $st.Bytes
                Write-Host ("  {0}+ removed {1} ({2}){3}" -f $Dim, (ConvertTo-DisplayPath $extra), (Format-Size $st.Bytes), $Reset)
            } else {
                Write-Warning "  could not remove $extra"
            }
        }
    }

    # 'all' cleans up after sessions that are gone. If a transcript is still
    # there, its session still exists and nothing it left is an orphan. And a
    # planned leftover goes only if a fresh scan of the real state still calls
    # it an orphan: a session may have started in that folder meanwhile.
    if ($answer -eq 'all' -and ($failed -or $lateLive.Count)) {
        Write-Host ("  {0}kept everything under 'Left behind': {1} transcript(s) are still there, so their sessions still exist{2}" -f $Yellow, ($failed + $lateLive.Count), $Reset)
    } elseif ($answer -eq 'all' -and $leftBehind.Count) {
        $stillOrphan = @(Get-OrphanItems -NoFold | ForEach-Object { $_.Paths })
        if ($script:OrphanScanIncomplete) {
            Write-Host ("  {0}kept everything under 'Left behind': the re-check after your answer could not complete{1}" -f $Yellow, $Reset)
            $leftBehind = @()
        }
        foreach ($x in $leftBehind) {
            foreach ($p in $x.Paths) {
                if ($stillOrphan -notcontains $p) {
                    if (Test-Path -LiteralPath $p) { Write-Host ("  {0}kept {1}: no longer an orphan{2}" -f $Dim, (ConvertTo-DisplayPath $p), $Reset) }
                    continue
                }
                $st = Get-PathStats -Path $p
                if (Remove-PathHard -Path $p) {
                    $freed += $st.Bytes
                    Write-Host ("  {0}+ removed {1} ({2}){3}" -f $Dim, (ConvertTo-DisplayPath $p), (Format-Size $st.Bytes), $Reset)
                } else {
                    Write-Warning "  could not remove $p"
                }
            }
        }
    }

    # Empty dirs, exactly the ones the plan named for this answer, and only
    # if they really are empty now. This is what keeps -Delete from
    # manufacturing orphans of its own.
    $runningDirs = @(Get-RunningProjectDir)
    foreach ($d in @($shellsYes) + $(if ($answer -eq 'all') { @($shellsAll) } else { @() })) {
        if (-not (& $isShell $d @())) { continue }
        if (Remove-PathHard -Path $d) {
            Write-Host ("  {0}+ removed the now-empty {1}{2}" -f $Dim, (ConvertTo-DisplayPath $d), $Reset)
        }
    }

    Write-Host ''
    Write-Host ("{0}Deleted {1} of {2} session(s), freed ~{3}.{4}" -f $Green, $deleted, $targets.Count, (Format-Size $freed), $Reset)
    if ($failed)     { Write-Host ("{0}{1} failed.{2}" -f $Red, $failed, $Reset) }
    if ($keptFailed) { Write-Host ("{0}{1} session(s) kept their data because their transcript could not be deleted.{2}" -f $Dim, $keptFailed, $Reset) }
    if ($keptCopy)   { Write-Host ("{0}{1} session(s) kept their shared data because another copy is still alive.{2}" -f $Dim, $keptCopy, $Reset) }
    Write-Host ''
    return
}

# ---- Read a session --------------------------------------------------------

if ($Open) {
    $matched = @(Select-BySelector -Candidates $Sessions -Selector $Open)
    if ($matched.Count -eq 0) {
        Write-Error "No session matched -Open '$Open'."
        Write-Host ''
        return
    }

    foreach ($s in $matched) {
        # The scan read this session light; parse it fully now for its turns.
        $full   = Get-SessionData -JsonlPath $s.FullPath -Subagent:(Test-SubagentPath $s.FullPath)
        $picked = Select-TurnsForDisplay -SessionTurns $full.Turns -N $Turns
        $shown  = $picked.First.Count + $picked.Last.Count

        $header = @(
            ('=' * 80),
            ("Index    : {0}" -f $(if ($null -ne $s.Index) { $s.Index } else { '(subagent transcript, not numbered)' })),
            ("Folder   : {0}" -f $s.Folder),
            ("Session  : {0}" -f $s.Session),
            ("File     : {0}" -f $s.File),
            ("Modified : {0}" -f $s.Modified.ToString('yyyy-MM-dd HH:mm:ss')),
            ("Size     : {0:N0} KB" -f $s.Size),
            ("Context  : {0}" -f $(if ($null -ne $s.Context) { '{0:N0} tokens' -f $s.Context } else { 'unknown' })),
            ("Model    : {0}" -f $(if ($s.Model) { $s.Model } else { 'unknown' })),
            ("Turns    : {0} of {1}{2}" -f $shown, $picked.Total, $(if ($picked.Omitted -gt 0) { " (first/last $Turns)" } else { ' (all)' })),
            ('-' * 80)
        )
        Write-Output ("{0}{1}{2}" -f $Green, ($header -join "`n"), $Reset)

        if ($full.ReadError) {
            Write-Output '(this transcript could not be read in full; another program may hold it locked)'
            Write-Output ''
            if ($shown -eq 0) { continue }
        } elseif ($shown -eq 0) {
            Write-Output '(no conversation turns in this transcript)'
            Write-Output ''
            continue
        }

        foreach ($t in $picked.First) { Write-TurnBlock -Turn $t -Max $MaxChars }
        if ($picked.Omitted -gt 0) {
            Write-Output ("{0}... [{1} turns omitted] ...{2}" -f $Dim, $picked.Omitted, $Reset)
            Write-Output ''
        }
        foreach ($t in $picked.Last) { Write-TurnBlock -Turn $t -Max $MaxChars }
    }
    return
}

# ---- Table -----------------------------------------------------------------

# The format XML (loaded before the -Orphans section) renders this type as an
# autosized table instead of falling back to Format-List, the default once an
# object has 5+ public properties.
foreach ($s in $Sessions) {
    $s.PSObject.TypeNames.Insert(0, 'CCSession')
    $s
}
