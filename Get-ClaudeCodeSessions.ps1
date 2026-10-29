<#
.SYNOPSIS
    Triage, read and delete Claude Code session transcripts.

.DESCRIPTION
    Lists or searches the .jsonl session transcripts Claude Code stores under
    $env:USERPROFILE\.claude\projects.  Each project directory's name is the
    cwd with every non-alphanumeric character replaced by '-'.  This script
    scans every project directory and reports a Folder column showing the
    original cwd relative to the user's home (e.g. '\' for the home dir
    itself, '\Projects\my-app' for a subfolder).

    The Folder value is read from the 'cwd' field inside the first user
    message in each session - the directory name is only a fallback.

    Four modes:
      (no selector)    table of every session, newest first within each folder
      -Open <sel>      print that session's conversation
      -Delete <sel>    permanently remove that session and everything it owns
      -Orphans         list what deleted and moved sessions left behind

    WHY -Delete REMOVES MORE THAN THE .jsonl
    A session is not one file.  Alongside the root <uuid>.jsonl it owns a
    sidecar directory (subagents/ and tool-results/), a file-history/<uuid>
    tree of edit snapshots, a session-env/<uuid> dir, a tasks/<uuid> dir, a
    jobs/<first-8-hex> dir, and scratch under %TEMP%\claude.  Removing only
    the transcript leaves all of that behind as unreachable garbage that
    nothing on the system ever prunes.  -Delete therefore sweeps the whole
    footprint.  It deliberately does NOT touch:

      memory\        shared per PROJECT, not per session - deleting it would
                     destroy MEMORY.md and every auto-memory file
      history.jsonl  your typed prompts, keyed by sessionId, which survive
                     the transcript and are the only record of sessions that
                     Claude Code's own cleanupPeriodDays reaper has eaten
      .claude.json   per-project config, trust flags and token counters
      paste-cache\   keyed by content hash, so it cannot be attributed to a
                     session at all

    A session's sidecar can live under a DIFFERENT project directory than its
    transcript, because the sidecar lands wherever the cwd was when the tool
    ran.  Orphan detection is therefore GLOBAL: a sidecar is only removed once
    no root transcript with that UUID remains in ANY project directory.

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
    moment you start a session in it; '*' never sweeps dormant memory.

    A session that moved leaves its old sidecar and %TEMP% dir behind.  Those
    are listed only when the session's transcript never mentions them:
    Claude Code records spilled tool output by absolute path, and a moved
    transcript really does keep reading the old location.  A transcript that
    cannot be read counts as a reference.

.PARAMETER Search
    Phrase to search for inside session transcripts. Case-insensitive,
    literal (not regex). Returns only sessions matching.

.PARAMETER Open
    Select one session and print its conversation. Three forms:
      - Integer:   matches the Index column from the table view
      - Substring: matches the filename (UUID fragment is fine)
      - Substring: matches the Session name (custom title set via /title)
    Substring matches are case-insensitive and may return several sessions,
    in which case each is printed in turn.

    Indexes are assigned after sorting and BEFORE every filter, -Search
    included, so the numbers stay stable as long as no session is added or
    removed: '-Search x' shows the same Index a bare listing would.

    Note: this is named -Open instead of -File because pwsh.exe treats
    -File as its own script-launcher argument and would eat the value.

.PARAMETER Delete
    Select sessions and permanently delete them, along with their sidecar,
    file-history, session-env, tasks, jobs and %TEMP% data. Accepts the same
    selector forms as -Open, plus '*' meaning "everything currently matched".

    '*' requires at least one narrowing filter (-Search, -OlderThan,
    -SmallerThan or -Unnamed) so it can never wipe every session at once.

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

    The memory of your home folder ($env:USERPROFILE) is never removed, by
    any answer or mode.

    The copy of a session that is running right now is always skipped, which
    also closes the old footgun where searching for a phrase logged that
    phrase into the live transcript and made it match itself. When one
    session lives in two folders, the registry's cwd says which copy is
    live; if that cannot be pinned down, every copy is protected. A UUID
    fragment or title that matches both copies is refused: pick one by
    index.

    With -Orphans, -Delete selects from the orphan list instead: an o#
    index, a kind (memory, backup, session-env, ...), 'dormant', a path
    fragment, or '*' for every orphan.

.PARAMETER Orphans
    List leftovers no live session can reach: memory of folders with no
    sessions left, empty project dirs, sidecars and file-history of deleted
    sessions, unreferenced leftovers of moved sessions, .bak files, a
    misplaced MEMORY.md, empty session-env and %TEMP% dirs, and dead registry
    entries. Each row says why it is listed. Combine with -Delete to remove.

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
    Keep only sessions with no custom /title. Combines with the other filters.

.PARAMETER Limit
    Cap the number of sessions returned. 0 (default) means no limit.

.PARAMETER IncludeSubagents
    Include subagent transcripts (<uuid>/subagents/agent-*.jsonl) as rows in
    their own right. Off by default.

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
    Get-ClaudeCodeSessions -Open de8f46e2 -Turns 0
    Print the whole conversation for the session whose filename contains
    'de8f46e2'.

.EXAMPLE
    Get-ClaudeCodeSessions -Delete 23
    Delete session #23 and everything it owns, after one confirmation.

.EXAMPLE
    Get-ClaudeCodeSessions -Delete delete
    Delete every session whose title contains 'delete' - the tombstone
    workflow: rename a session '/title delete' when you are done with it,
    then sweep them all later.

.EXAMPLE
    Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
    Sweep tiny sessions untouched for 90 days. Run it without -Delete first
    to see exactly what would go.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'database migration'
    Find sessions in any project folder mentioning the phrase.

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
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Search,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        # Attaching ANY completer to this parameter makes PowerShell hand its
        # completion entirely to us, suppressing the default filesystem
        # fallback that otherwise suggests files in the current directory. We
        # offer session handles instead: custom titles first, then UUIDs.
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $root)) { return }
        $word = $wordToComplete.Trim("'", '"')
        if (-not $global:CCSessionTitleCache) { $global:CCSessionTitleCache = @{} }
        $cache = $global:CCSessionTitleCache
        $titles = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $files  = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $folder = if ($dir.Name -match '^([A-Za-z])--(.+)$') { "$($matches[1]):\" + ($matches[2] -replace '-', '\') } else { $dir.Name }
            foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
                $stem = $file.BaseName
                if (-not $word -or $stem -like "*$word*") {
                    $files.Add([System.Management.Automation.CompletionResult]::new(
                        $stem, $stem, 'ParameterValue', ('{0}  {1}' -f $folder, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))))
                }
                # Title lookups read whole transcripts, so cache them keyed by
                # path and invalidate on LastWriteTime.
                $entry = $cache[$file.FullName]
                if (-not $entry -or $entry.Mtime -ne $file.LastWriteTimeUtc.Ticks) {
                    $title = ''
                    foreach ($h in (Select-String -LiteralPath $file.FullName -Pattern 'custom-title' -ErrorAction SilentlyContinue)) {
                        try { $t = [string]($h.Line | ConvertFrom-Json -ErrorAction Stop).customTitle } catch { continue }
                        if ($t) { $title = $t }
                    }
                    $entry = @{ Mtime = $file.LastWriteTimeUtc.Ticks; Title = $title }
                    $cache[$file.FullName] = $entry
                }
                $title = $entry.Title
                if ($title -and (-not $word -or $title -like "*$word*") -and $seen.Add($title)) {
                    $completion = if ($title -match '[\s'']') { "'" + ($title -replace "'", "''") + "'" } else { $title }
                    $titles.Add([System.Management.Automation.CompletionResult]::new(
                        $completion, $title, 'ParameterValue', "Session: $title  ($folder)"))
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
        if (-not $global:CCSessionTitleCache) { $global:CCSessionTitleCache = @{} }
        $cache = $global:CCSessionTitleCache
        $titles = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $files  = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $folder = if ($dir.Name -match '^([A-Za-z])--(.+)$') { "$($matches[1]):\" + ($matches[2] -replace '-', '\') } else { $dir.Name }
            foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
                $stem = $file.BaseName
                if (-not $word -or $stem -like "*$word*") {
                    $files.Add([System.Management.Automation.CompletionResult]::new(
                        $stem, $stem, 'ParameterValue', ('{0}  {1}' -f $folder, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))))
                }
                $entry = $cache[$file.FullName]
                if (-not $entry -or $entry.Mtime -ne $file.LastWriteTimeUtc.Ticks) {
                    $title = ''
                    foreach ($h in (Select-String -LiteralPath $file.FullName -Pattern 'custom-title' -ErrorAction SilentlyContinue)) {
                        try { $t = [string]($h.Line | ConvertFrom-Json -ErrorAction Stop).customTitle } catch { continue }
                        if ($t) { $title = $t }
                    }
                    $entry = @{ Mtime = $file.LastWriteTimeUtc.Ticks; Title = $title }
                    $cache[$file.FullName] = $entry
                }
                $title = $entry.Title
                if ($title -and (-not $word -or $title -like "*$word*") -and $seen.Add($title)) {
                    $completion = if ($title -match '[\s'']') { "'" + ($title -replace "'", "''") + "'" } else { $title }
                    $titles.Add([System.Management.Automation.CompletionResult]::new(
                        $completion, $title, 'ParameterValue', "Session: $title  ($folder)"))
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

$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$ClaudeRoot   = Join-Path $env:USERPROFILE '.claude'
$UserHome     = $env:USERPROFILE

if (-not (Test-Path $ProjectsRoot)) {
    Write-Error "Claude Code projects directory not found: $ProjectsRoot"
    return
}

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
${Bold}${Green}Get-ClaudeCodeSessions${Reset} - Browse, read and delete Claude Code session transcripts.

${Bold}FOUR MODES${Reset}
  ${Cyan}Get-ClaudeCodeSessions${Reset}                 list every session as a table
  ${Cyan}Get-ClaudeCodeSessions -Open${Reset} <sel>     print that session's conversation
  ${Cyan}Get-ClaudeCodeSessions -Delete${Reset} <sel>   delete it and everything it owns
  ${Cyan}Get-ClaudeCodeSessions -Orphans${Reset}        list what deleted and moved sessions left behind

${Bold}SELECTORS${Reset} (for -Open and -Delete)
  ${Cyan}23${Reset}          the Index column from the table
  ${Cyan}de8f46e2${Reset}    a fragment of the filename / UUID
  ${Cyan}my-app${Reset}      a fragment of the Session name (set with /title)
  ${Cyan}*${Reset}           everything currently matched (-Delete only, and it
              refuses to run unless a filter narrows the set first)

${Bold}FILTERS${Reset} (combine freely, they AND together)
  ${Cyan}-Search${Reset} <string>     literal, case-insensitive search inside transcripts
  ${Cyan}-OlderThan${Reset} <N>       only sessions older than N days
  ${Cyan}-SmallerThan${Reset} <N>     only sessions under N KB
  ${Cyan}-Unnamed${Reset}             only sessions with no custom /title
  ${Cyan}-Limit${Reset} <N>           cap the number of rows

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
  ${Cyan}-IncludeSubagents${Reset}    also list subagent transcripts as their own rows
  ${Cyan}-NoColor${Reset}             strip ANSI colors
  ${Cyan}-Help${Reset}                this screen

${Bold}WHAT -Delete ACTUALLY REMOVES${Reset}
  A session is not one file. -Delete sweeps the whole footprint:
    ${Dim}projects\<proj>\<uuid>.jsonl        the transcript${Reset}
    ${Dim}projects\*\<uuid>\                 sidecar: subagents\ + tool-results\${Reset}
    ${Dim}file-history\<uuid>\               edit snapshots (often the biggest part)${Reset}
    ${Dim}session-env\<uuid>\  tasks\<uuid>\  jobs\<first8>\${Reset}
    ${Dim}%TEMP%\claude\*\<uuid>\            background task scratch${Reset}
  It never touches ${Bold}memory\${Reset} (shared per project), ${Bold}history.jsonl${Reset} (your typed
  prompts, which outlive the transcript), ${Bold}.claude.json${Reset} or ${Bold}paste-cache\${Reset}.
  The plan lists every part with its path, file count and size before asking.
  Answer ${Cyan}yes${Reset}, or ${Cyan}all${Reset} to also remove what the delete leaves behind (the
  folder's memory when it is the last session there, its strays and backups).

${Bold}ORPHANS${Reset}
  ${Cyan}-Orphans${Reset}                     list leftovers, each with State, Why, Size and Path
  ${Cyan}-Orphans -Delete${Reset} <sel>        remove them: ${Cyan}o3${Reset}, a kind (${Cyan}memory${Reset}, ${Cyan}backup${Reset},
                                ${Cyan}session-env${Reset}, ...), ${Cyan}dormant${Reset}, a path fragment, or ${Cyan}*${Reset}
  ${Dim}orphan  = nothing will ever read it again${Reset}
  ${Dim}dormant = memory whose folder still exists; it loads again when you start a${Reset}
  ${Dim}          session there, so * never takes it. Name it by o# instead.${Reset}

${Bold}SAFETY${Reset}
  ${Dim}- The plan is printed, then ONE confirmation: 'yes', or 'all'.${Reset}
  ${Dim}- Deletion is permanent: there is no Recycle Bin.${Reset}
  ${Dim}- Your home folder's memory is never removed, by any mode.${Reset}
  ${Dim}- The running copy of a session is always skipped, so it cannot delete itself.${Reset}
  ${Dim}- A UUID or title that matches both copies of a moved session is refused.${Reset}
  ${Dim}- A sidecar is removed only once no transcript with that UUID exists in ANY${Reset}
  ${Dim}  project dir, because a sidecar can outlive a cwd change.${Reset}
  ${Dim}- Preview any delete by running the same command with -Open instead.${Reset}

${Bold}EXAMPLES${Reset}
  Get-ClaudeCodeSessions
  Get-ClaudeCodeSessions -Open 23
  Get-ClaudeCodeSessions -Open de8f46e2 -Turns 0
  Get-ClaudeCodeSessions -Search "database migration"
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
    # Returns a hashtable with .Turns (list of user/assistant turns),
    # .CustomTitle (string or empty), .Context (tokens or $null) and .Model
    # (string or empty).  The custom title is set by the user via /title in
    # Claude Code and is recorded as 'custom-title' lines in the session JSONL.
    # The same title can appear multiple times if it was changed; we keep the
    # LAST one we see.
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
    param([string]$JsonlPath)

    # Named $turnList, not $turns: the -Turns parameter is [int] and PowerShell
    # variable names are case-insensitive, so a local $turns would collide with
    # it and fail to accept a List.
    $turnList = New-Object System.Collections.Generic.List[object]
    $customTitle = ''
    $context = $null
    $model = ''

    if ([string]::IsNullOrWhiteSpace($JsonlPath)) {
        return @{ Turns = $turnList; CustomTitle = $customTitle; Context = $context; Model = $model }
    }

    foreach ($line in Get-Content -LiteralPath $JsonlPath -ErrorAction SilentlyContinue) {
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

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
        if ($obj.isSidechain) { continue }

        if ($obj.type -eq 'assistant' -and $obj.message.model -and $obj.message.model -ne '<synthetic>') {
            $model = [string]$obj.message.model
            $u = $obj.message.usage
            if ($u) {
                $context = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens +
                           [long]$u.cache_read_input_tokens + [long]$u.output_tokens
            }
        }

        $role = $obj.message.role
        if (-not $role) { $role = $obj.type }

        $text = Get-MessageText $obj.message.content
        if (-not $text) { continue }

        $turnList.Add([PSCustomObject]@{
            Role      = $role
            Text      = $text
            Cwd       = $obj.cwd
            Timestamp = $obj.timestamp
        })
    }

    return @{ Turns = $turnList; CustomTitle = $customTitle; Context = $context; Model = $model }
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
    if ($source.StartsWith($homePath, [StringComparison]::OrdinalIgnoreCase)) {
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
    return $Text.Substring(0, $Max).TrimEnd() + "`n...[truncated]"
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
        $idx = [int]($Selector.TrimStart('#'))
        return @($list | Where-Object { $_.Index -eq $idx })
    }
    return @($list | Where-Object { $_.File -like "*$Selector*" -or $_.Session -like "*$Selector*" })
}

function Get-RunningSession {
    # One record per live Claude Code process: SessionId, plus ProjectDir, the
    # project dir name its cwd maps to ($null when unknown). Read from
    # ~\.claude\sessions\<pid>.json. Only trust an entry whose pid is still
    # alive, otherwise a crashed session would be protected forever.
    # CLAUDE_CODE_SESSION_ID covers running from inside a session's own shell;
    # the env var carries no cwd, so that record has no ProjectDir.
    $recs = New-Object System.Collections.Generic.List[object]
    if ($env:CLAUDE_CODE_SESSION_ID) { $recs.Add([pscustomobject]@{ SessionId = [string]$env:CLAUDE_CODE_SESSION_ID; ProjectDir = $null }) }
    $dir = Join-Path $ClaudeRoot 'sessions'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $o.sessionId) { continue }
            if ($o.pid -and -not (Get-Process -Id $o.pid -ErrorAction SilentlyContinue)) { continue }
            $pd = if ($o.cwd) { ConvertTo-ProjectDirName ([string]$o.cwd) } else { $null }
            $recs.Add([pscustomobject]@{ SessionId = [string]$o.sessionId; ProjectDir = $pd })
        }
    }
    return [object[]]$recs
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
    return [string[]]@(Get-RunningSession | ForEach-Object SessionId)
}

function Remove-PathHard {
    # OneDrive Files-On-Demand marks synced directories ReadOnly +
    # ReparsePoint. Directory.Delete and Remove-Item both fail on those with
    # access-denied until ReadOnly is cleared, so clear it first, depth-first.
    param([string]$Path)
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

function ConvertTo-DisplayPath {
    # ~ for the profile, %TEMP% for the temp dir. Temp is checked first
    # because it lives inside the profile.
    param([string]$Path)
    $temp = Join-Path $env:LOCALAPPDATA 'Temp'
    if ($Path.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { return '%TEMP%' + $Path.Substring($temp.Length) }
    if ($Path.StartsWith($UserHome, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $Path.Substring($UserHome.Length) }
    return $Path
}

function Get-SessionFootprint {
    # Everything a session owns EXCEPT its root transcript, which the caller
    # deletes first. Sidecar dirs are searched across every project dir, since
    # a sidecar lands wherever the cwd was when the tool ran and can end up
    # separated from its transcript.
    param([string]$Uuid)

    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($dir in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue) {
        $sidecar = Join-Path $dir.FullName $Uuid
        if (Test-Path -LiteralPath $sidecar) { $paths.Add($sidecar) }
    }
    foreach ($sub in @('file-history', 'session-env', 'tasks')) {
        $p = Join-Path (Join-Path $ClaudeRoot $sub) $Uuid
        if (Test-Path -LiteralPath $p) { $paths.Add($p) }
    }
    # jobs\ is keyed by the first 8 hex chars of the session id, inferred from
    # observed pairings. Guard against a prefix collision with a live session.
    if ($Uuid.Length -ge 8) {
        $prefix = $Uuid.Substring(0, 8)
        $jobDir = Join-Path (Join-Path $ClaudeRoot 'jobs') $prefix
        if (Test-Path -LiteralPath $jobDir) { $paths.Add($jobDir) }
    }
    $tempRoot = Join-Path $env:LOCALAPPDATA 'Temp\claude'
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($pd in Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction SilentlyContinue) {
            $p = Join-Path $pd.FullName $Uuid
            if (Test-Path -LiteralPath $p) { $paths.Add($p) }
        }
    }
    return $paths
}

function ConvertTo-ProjectDirName {
    # How Claude Code names a project dir: every non-alphanumeric character of
    # the cwd becomes '-'. Verified against every live sessions\ entry,
    # including a path with spaces and ' - '. The encoding is lossy, so never
    # decode a dir name: re-encode candidate paths and compare instead.
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
    # The home folder's memory is never removed, by any mode: it is the memory
    # every session started in the profile root shares. Guards the project dir
    # itself too, since removing that would take its memory\ with it.
    param([string]$Path)
    $homeProj = Join-Path $ProjectsRoot (ConvertTo-ProjectDirName $UserHome)
    $homeMem  = Join-Path $homeProj 'memory'
    return ($Path -eq $homeProj -or $Path -eq $homeMem -or $Path.StartsWith("$homeMem\", [StringComparison]::OrdinalIgnoreCase))
}

function Get-FirstCwd {
    # The cwd of the first conversation turn, by the same rules Get-SessionData
    # uses to derive Folder, but stopping at the first hit instead of parsing
    # the whole file. -Search misses need only that, as a sort key, so their
    # rows can still take part in numbering without the cost of a full parse.
    param([string]$JsonlPath)
    $sr = $null
    try {
        $sr = [IO.StreamReader]::new([IO.FileStream]::new($JsonlPath, 'Open', 'Read', 'ReadWrite'))
        while ($null -ne ($line = $sr.ReadLine())) {
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.type -ne 'user' -and $obj.type -ne 'assistant') { continue }
            if (-not $obj.message -or $obj.isSidechain) { continue }
            if (-not (Get-MessageText $obj.message.content)) { continue }
            if ($obj.cwd) { return [string]$obj.cwd }
        }
    } catch {
    } finally {
        if ($sr) { $sr.Dispose() }
    }
    return $null
}

function Test-PathReferenced {
    # Does any live transcript still mention <Prefix>\<ProjDir>\<Uuid>, in any
    # spelling (JSON-escaped backslashes, forward slashes, raw)? Asked before
    # calling a stranded sidecar or temp dir an orphan, because Claude Code
    # records spilled tool output by absolute path. A transcript that cannot
    # be read counts as a reference: unknown is not the same as unused.
    param([string[]]$Transcripts, [string]$Prefix, [string]$ProjDir, [string]$Uuid)
    $needles = @("$Prefix\\$ProjDir\\$Uuid", "$Prefix/$ProjDir/$Uuid", "$Prefix\$ProjDir\$Uuid")
    foreach ($t in $Transcripts) {
        $ev = $null
        $hit = Select-String -LiteralPath $t -Pattern $needles -SimpleMatch -Quiet -ErrorAction SilentlyContinue -ErrorVariable +ev
        if ($hit -or $ev) { return $true }
    }
    return $false
}

function Test-ShellDir {
    # True when a dir holds nothing except, at most, an empty memory\ (plus
    # whatever is about to be deleted, passed as -Ignore). Claude Code
    # recreates both on the next session there, so such a dir is a shell.
    # The delete plan and both executors share this rule, so the plan never
    # promises to remove a dir that the executor then keeps.
    param([string]$Path, [string[]]$Ignore = @())
    foreach ($k in Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
        if ($Ignore -contains $k.FullName) { continue }
        if ($k.PSIsContainer -and $k.Name -eq 'memory' -and (Get-PathStats -Path $k.FullName).Files -eq 0) { continue }
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
    # human recognises, for the delete plan. Display only: deletion still
    # removes each footprint path whole, so the parts must cover every byte
    # under it. A sidecar therefore becomes one row per subfolder plus one per
    # loose file.
    param([string[]]$Paths)
    $tempRoot = Join-Path $env:LOCALAPPDATA 'Temp\claude'
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
    param([string[]]$GoneTranscripts = @(), [string[]]$GonePaths = @(), [switch]$NoFold)
    $uuidRx   = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $tempRoot = Join-Path $env:LOCALAPPDATA 'Temp\claude'
    $origin   = Get-ProjectOrigin
    $gone     = @($GoneTranscripts) + @($GonePaths)

    # Live = has a root transcript somewhere, or is running right now.
    $txDirs = @{}; $txPaths = @{}
    $projDirs = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($pd in $projDirs) {
        foreach ($t in Get-ChildItem -LiteralPath $pd.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
            if ($gone -contains $t.FullName) { continue }
            if (-not $txDirs.ContainsKey($t.BaseName)) {
                $txDirs[$t.BaseName]  = New-Object System.Collections.Generic.List[string]
                $txPaths[$t.BaseName] = New-Object System.Collections.Generic.List[string]
            }
            $txDirs[$t.BaseName].Add($pd.Name); $txPaths[$t.BaseName].Add($t.FullName)
        }
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
        $items.Add([pscustomobject]@{
            Index = 0; State = $State; Kind = $Kind; Folder = $Folder; Files = $files; Bytes = $bytes
            LastWrite = $newest; Why = $Why; Path = (& $where $Paths); Paths = $Paths
            Note = $Note; Errors = $errs
        })
    }

    foreach ($pd in $projDirs) {
        $kids   = @(Get-ChildItem -LiteralPath $pd.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $gone -notcontains $_.FullName })
        $folder = & $folderOf $pd.Name
        $inUse  = (@($kids | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.jsonl' }).Count -gt 0) -or
                  ($runningDirs -contains $pd.Name)
        $memDir   = Join-Path $pd.FullName 'memory'
        $memFiles = @(if (Test-Path -LiteralPath $memDir) { Get-ChildItem -LiteralPath $memDir -Recurse -File -Force -ErrorAction SilentlyContinue })

        # Never offered for removal, so never listed: see Test-ProtectedPath.
        if (-not $inUse -and -not (Test-ProtectedPath $pd.FullName)) {
            if ($memFiles.Count) {
                $cands = @(if ($origin.ByDir.ContainsKey($pd.Name)) { $origin.ByDir[$pd.Name] })
                $there = @($cands | Where-Object { Test-Path -LiteralPath $_ })
                # A folder we cannot place counts as still wanted, not as gone.
                if ($there.Count)     { $state = 'dormant'; $why = 'no sessions; folder exists' }
                elseif ($cands.Count) { $state = 'orphan';  $why = 'no sessions; folder gone' }
                else                  { $state = 'dormant'; $why = 'no sessions; folder unknown' }
                $note = 'memory files: ' + (@($memFiles | Sort-Object Name | ForEach-Object Name) -join ', ')
                & $add 'memory' $state $folder $why @($memDir) $note
            } elseif (@($kids | Where-Object { -not ($_.PSIsContainer -and $_.Name -eq 'memory') }).Count -eq 0) {
                # Nothing in it but an empty memory\, if that: an empty shell.
                & $add 'project' 'orphan' $folder 'no sessions, no memory' @($pd.FullName) ''
                continue
            }
        }

        foreach ($k in $kids) {
            if ($k.PSIsContainer -and $k.Name -match $uuidRx) {
                if ($liveIds -notcontains $k.Name) {
                    & $add 'sidecar' 'orphan' $folder 'session gone' @($k.FullName) ''
                } elseif ($running -notcontains $k.Name -and $txDirs.ContainsKey($k.Name) -and $txDirs[$k.Name] -notcontains $pd.Name) {
                    # Stranded: the session moved and left its old sidecar here.
                    if (-not (Test-PathReferenced -Transcripts $txPaths[$k.Name] -Prefix 'projects' -ProjDir $pd.Name -Uuid $k.Name)) {
                        $to = @($txDirs[$k.Name] | ForEach-Object { & $folderOf $_ }) -join ', '
                        & $add 'sidecar' 'orphan' $folder 'session moved; unreferenced' @($k.FullName) "left behind when the session moved to $to; its transcript never points here"
                    }
                }
            } elseif (-not $k.PSIsContainer -and $k.Extension -ne '.jsonl') {
                # Only names we can account for. An unrecognised file might be
                # something a newer Claude Code writes, so it is left alone.
                if ($k.Name -like '*.bak') {
                    & $add 'backup' 'orphan' $folder 'backup from a session move' @($k.FullName) ''
                } elseif ($k.Name -eq 'MEMORY.md') {
                    & $add 'stray' 'orphan' $folder 'misplaced; only memory\MEMORY.md is read' @($k.FullName) ''
                }
            }
        }
    }

    foreach ($store in 'file-history', 'session-env', 'tasks') {
        foreach ($d in Get-ChildItem -LiteralPath (Join-Path $ClaudeRoot $store) -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name -notmatch $uuidRx -or $liveIds -contains $d.Name -or $gone -contains $d.FullName) { continue }
            $f = if ($origin.BySession.ContainsKey($d.Name)) { ConvertTo-FolderLabel -Cwd $origin.BySession[$d.Name] -DirName '' } else { '' }
            & $add $store 'orphan' $f 'session gone' @($d.FullName) ''
        }
    }
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $ClaudeRoot 'jobs') -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -match '^[0-9a-f]{8}$' -and $livePrefix -notcontains $d.Name -and $gone -notcontains $d.FullName) {
            & $add 'jobs' 'orphan' '' 'no session has this ID prefix' @($d.FullName) ''
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($pd in Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction SilentlyContinue) {
            # Per-project dirs only. The rest of %TEMP%\claude is not session data.
            if ($pd.Name -notmatch '^[A-Za-z]--') { continue }
            $folder = & $folderOf $pd.Name
            $kids = @(Get-ChildItem -LiteralPath $pd.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $gone -notcontains $_.FullName })
            if ($kids.Count -eq 0) {
                if ($runningDirs -notcontains $pd.Name) { & $add 'temp' 'orphan' $folder 'empty' @($pd.FullName) '' }
                continue
            }
            foreach ($k in $kids | Where-Object { $_.PSIsContainer -and $_.Name -match $uuidRx }) {
                if ($liveIds -notcontains $k.Name) {
                    & $add 'temp' 'orphan' $folder 'session gone' @($k.FullName) ''
                } elseif ($running -notcontains $k.Name -and $txDirs.ContainsKey($k.Name) -and $txDirs[$k.Name] -notcontains $pd.Name) {
                    if (-not (Test-PathReferenced -Transcripts $txPaths[$k.Name] -Prefix 'claude' -ProjDir $pd.Name -Uuid $k.Name)) {
                        $to = @($txDirs[$k.Name] | ForEach-Object { & $folderOf $_ }) -join ', '
                        & $add 'temp' 'orphan' $folder 'session moved; unreferenced' @($k.FullName) "left behind when the session moved to $to"
                    }
                }
            }
        }
    }
    $reg = Join-Path $ClaudeRoot 'sessions'
    foreach ($j in Get-ChildItem -LiteralPath $reg -Filter *.json -File -ErrorAction SilentlyContinue) {
        $procNum = 0
        if (-not [int]::TryParse($j.BaseName, [ref]$procNum)) { continue }
        if (Get-Process -Id $procNum -ErrorAction SilentlyContinue) { continue }
        $paths = @($j.FullName) + @(Get-ChildItem -LiteralPath $reg -Filter "$procNum.*.key" -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
        & $add 'registry' 'orphan' '' 'process gone' $paths ''
    }

    # Empty dirs carry no information one by one (22 session-env dirs would
    # read as 22 identical rows), so fold them into one row per kind.
    $final = New-Object System.Collections.Generic.List[object]
    $foldable = if ($NoFold) { @() } else { @($items | Where-Object { $_.Files -eq 0 -and $_.Kind -notin 'memory', 'project', 'registry' }) }
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
    foreach ($it in $sorted) { $it.Index = $n++; $it.PSObject.TypeNames.Insert(0, 'CCOrphan') }
    return $sorted
}

function Select-Orphans {
    # Orphan selectors: o# (or a bare #) from the listing, a kind name,
    # 'orphan' or 'dormant', a path fragment, or '*' = every ORPHAN. Dormant
    # memory loads again if you return to its folder, so it must be named.
    param([object[]]$Items, [string]$Selector)
    if ($Selector -eq '*') { return @($Items | Where-Object State -eq 'orphan') }
    if ($Selector -match '^[oO]?(\d+)$') { $want = [int]$Matches[1]; return @($Items | Where-Object Index -eq $want) }
    $named = @($Items | Where-Object { $_.Kind -eq $Selector -or $_.State -eq $Selector })
    if ($named.Count) { return $named }
    return @($Items | Where-Object { @($_.Paths | Where-Object { $_.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 })
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

    if (-not $Delete) {
        Write-Host ''
        if ($orphanItems.Count -eq 0) {
            Write-Host 'No orphans or leftovers found.'
            Write-Host ''
            return
        }
        $sum = [long]0; foreach ($o in $orphanItems) { $sum += $o.Bytes }
        Write-Host ("{0}{1} leftover item(s), {2}.{3}" -f $Bold, $orphanItems.Count, (Format-Size $sum), $Reset)
        Write-Host ("{0}orphan = nothing will ever read it again. dormant = memory that loads again if you start a session in its folder.{1}" -f $Dim, $Reset)
        Write-Host ("{0}Remove with -Orphans -Delete <o#|kind|path fragment|*>. '*' takes only orphans; dormant memory needs its own o#.{1}" -f $Dim, $Reset)
        Write-Host ("{0}Never listed, kept by design: history.jsonl (your prompts outlive their sessions), .claude.json, paste-cache\.{1}" -f $Dim, $Reset)
        $orphanItems
        return
    }

    $targetItems = @(Select-Orphans -Items $orphanItems -Selector $Delete)
    if ($targetItems.Count -eq 0) {
        Write-Warning "No orphan matched -Delete '$Delete'. Run -Orphans on its own to see the list."
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
    Write-Host ("  {0}A project dir this leaves empty is removed too.{1}" -f $Dim, $Reset)
    Write-Host ("  {0}There is no Recycle Bin. This cannot be undone.{1}" -f $Red, $Reset)
    Write-Host ''

    $answer = Read-Host "Type 'yes' to delete"
    if ($answer -ne 'yes') {
        Write-Host ("{0}Aborted. Nothing was deleted.{1}" -f $Cyan, $Reset)
        Write-Host ''
        return
    }

    $tempRoot    = Join-Path $env:LOCALAPPDATA 'Temp\claude'
    $runningDirs = @(Get-RunningProjectDir)
    $removed = 0; $failed = 0; $freed = [long]0
    foreach ($t in $targetItems) {
        $ok = $true; $parents = @()
        foreach ($p in $t.Paths) {
            if (Test-ProtectedPath $p) { $ok = $false; Write-Warning "  refusing to remove protected $p"; continue }
            if (Remove-PathHard -Path $p) { $parents += (Split-Path $p -Parent) }
            else { $ok = $false; Write-Warning "  could not remove $p" }
        }
        if ($ok) { $removed++; $freed += $t.Bytes; Write-Host ("{0}deleted{1} [o{2}] {3}  {4}" -f $Green, $Reset, $t.Index, $t.Kind, $t.Path) }
        else { $failed++ }
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

$ProjectDirs = Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue

$Sessions = New-Object System.Collections.Generic.List[object]
# -Search misses: never shown, but numbered. See the note at the sort below.
$Misses   = New-Object System.Collections.Generic.List[object]

foreach ($dir in $ProjectDirs) {
    $files = if ($IncludeSubagents) {
        Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue
    }

    foreach ($file in $files) {
        if ($Search) {
            $hit = Select-String -LiteralPath $file.FullName -Pattern $Search -SimpleMatch -List -ErrorAction SilentlyContinue
            if (-not $hit) {
                $Misses.Add([PSCustomObject]@{
                    Folder   = ConvertTo-FolderLabel -Cwd (Get-FirstCwd -JsonlPath $file.FullName) -DirName $dir.Name
                    File     = $file.Name
                    Modified = $file.LastWriteTime
                    FullPath = $file.FullName
                    IsMiss   = $true
                })
                continue
            }
        }

        $data    = Get-SessionData -JsonlPath $file.FullName
        $sTurns  = $data.Turns
        $cwd     = ($sTurns | Where-Object Cwd | Select-Object -First 1).Cwd
        $folder  = ConvertTo-FolderLabel -Cwd $cwd -DirName $dir.Name

        $Sessions.Add([PSCustomObject]@{
            Folder   = $folder
            Session  = $data.CustomTitle
            File     = $file.Name
            Modified = $file.LastWriteTime
            # Rounded up, like Format-Size, so the table and the delete
            # plan show the same KB for the same file.
            Size     = [int][math]::Ceiling($file.Length / 1KB)
            Context  = $data.Context
            Model    = $data.Model
            FullPath = $file.FullName
            Turns    = $sTurns
        })
    }
}

# Assign stable indexes BEFORE the selectors and filters run, -Search
# included, so the numbers printed by an earlier bare `Get-ClaudeCodeSessions`
# still resolve. -Search misses are numbered too and dropped afterwards: an
# Index must mean the same session with or without -Search, or '-Search x'
# followed by a bare '-Delete 1' hits a different session. FullPath breaks
# ties so the order is deterministic.
$numbered = New-Object System.Collections.Generic.List[object]
$numbered.AddRange($Sessions); $numbered.AddRange($Misses)
$sorted = @($numbered | Sort-Object Folder, @{ Expression = 'Modified'; Descending = $true }, FullPath)
$i = 1
foreach ($s in $sorted) {
    $s | Add-Member -NotePropertyName 'Index' -NotePropertyValue $i -Force
    $i++
}
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
            "-Search, -OlderThan, -SmallerThan or -Unnamed. Run the same command with " +
            "-Open instead to preview, or name a single session: -Delete <index|uuid|title>.")
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

    # A session moved or copied by hand lives in two folders under ONE file
    # name, so a UUID fragment or a title matches every copy at once. Deleting
    # both by accident is exactly how you lose the copy you kept, so a
    # substring selector that hits two copies is refused: pick one by index.
    # '*' after a filter means "everything matched" and is left alone.
    if ($Delete -ne '*' -and $Delete -notmatch '^#?\d+$') {
        $twins = @($targets | Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.File) } | Where-Object Count -gt 1)
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

    # Never delete the copy of a session that is running right now. This also
    # closes the old footgun: -Search wrote the search phrase into the live
    # transcript, which then matched itself.
    # Decided per COPY, not per session ID: when a session lives in two
    # folders, the registry's cwd says which copy the live process writes.
    # The other copy is released only when the live one is positively found
    # in a folder a live process is using; anything less certain (no cwd, or a
    # cwd that matches no copy) protects every copy.
    $live = @(Get-RunningSession)
    $isRunning = {
        param($s)
        $u    = [IO.Path]::GetFileNameWithoutExtension($s.File)
        $recs = @($live | Where-Object SessionId -eq $u)
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

    # Every root transcript on disk, by UUID. Needed BEFORE the plan: the same
    # UUID can be a root transcript in two project dirs at once (a session
    # whose cwd changed, or one relocated by hand). The copies share one
    # footprint, which goes only with the last copy, so the plan must know
    # whether a copy survives outside this delete.
    $transcriptsByUuid = @{}
    foreach ($dir in $ProjectDirs) {
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
            $u = $f.BaseName
            if (-not $transcriptsByUuid.ContainsKey($u)) { $transcriptsByUuid[$u] = New-Object System.Collections.Generic.List[string] }
            $transcriptsByUuid[$u].Add($f.FullName)
        }
    }

    # One block per session ID, holding every copy being deleted.
    $groups = [ordered]@{}
    foreach ($s in $targets) {
        $uuid = [IO.Path]::GetFileNameWithoutExtension($s.File)
        if (-not $groups.Contains($uuid)) { $groups[$uuid] = New-Object System.Collections.Generic.List[object] }
        $groups[$uuid].Add($s)
    }
    $targetPaths     = @($targets | ForEach-Object FullPath)
    $footprintByUuid = @{}

    Write-Host ''
    Write-Host ("{0}The following {1} session(s) will be PERMANENTLY deleted:{2}" -f $Bold, $targets.Count, $Reset)
    $totalBytes = [long]0; $totalFiles = 0; $unreadable = 0
    foreach ($uuid in $groups.Keys) {
        $copies = $groups[$uuid]
        Write-Host ''
        foreach ($s in $copies) {
            $name = if ($s.Session) { $s.Session } else { '(unnamed)' }
            Write-Host ("  {0}[{1}] {2}{3}  in {4}" -f $Bold, $s.Index, $name, $Reset, $s.Folder)
        }
        $twin = if ($copies.Count -gt 1) { "  ($($copies.Count) copies of one session)" } else { '' }
        Write-Host ("  {0}session ID {1}{2}{3}" -f $Dim, $uuid, $twin, $Reset)

        $parts = New-Object System.Collections.Generic.List[object]
        foreach ($s in $copies) { $parts.Add((New-FootprintPart 'transcript' $s.FullPath)) }

        $keptNote  = $null
        $survivors = @($transcriptsByUuid[$uuid] | Where-Object { $targetPaths -notcontains $_ })
        if ($survivors.Count) {
            $where = @($survivors | ForEach-Object {
                $sp = $_
                $hit = @($AllSessions | Where-Object FullPath -eq $sp)
                if ($hit.Count) { $hit[0].Folder } else { Split-Path (Split-Path $sp -Parent) -Leaf }
            }) -join ', '
            $keptNote = "Everything else this session owns is KEPT: the same session ID is still alive in $where."
            $footprintByUuid[$uuid] = @()
        } else {
            # @() because Get-SessionFootprint's List is unrolled on output.
            $paths = @(Get-SessionFootprint -Uuid $uuid)
            # jobs\ is keyed by only the first 8 hex chars, so a different live
            # session could own the same dir. Keep it rather than guess.
            $prefix = $uuid.Substring(0, [Math]::Min(8, $uuid.Length))
            if (@($transcriptsByUuid.Keys | Where-Object { $_ -ne $uuid -and $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                $jobsPath = Join-Path (Join-Path $ClaudeRoot 'jobs') $prefix
                if ($paths -contains $jobsPath) { $keptNote = "Kept jobs\${prefix}: another live session shares that ID prefix." }
                $paths = @($paths | Where-Object { $_ -ne $jobsPath })
            }
            $footprintByUuid[$uuid] = $paths
            foreach ($part in Get-FootprintParts -Paths $paths) { $parts.Add($part) }
        }

        Write-Host ''
        Write-Host ("    {0,-24} {1,6} {2,12}  {3}" -f 'Part', 'Files', 'Size', 'Path')
        Write-Host ("    {0,-24} {1,6} {2,12}  {3}" -f '----', '-----', '----', '----')
        foreach ($part in $parts) {
            Write-Host ("    {0,-24} {1,6:N0} {2,12}  {3}" -f $part.Label, $part.Files, (Format-Size $part.Bytes), (ConvertTo-DisplayPath $part.Path))
            $totalBytes += $part.Bytes; $totalFiles += $part.Files; $unreadable += $part.Errors
        }
        if ($keptNote) { Write-Host ("    {0}{1}{2}" -f $Dim, $keptNote, $Reset) }
    }

    Write-Host ''
    Write-Host ("  {0}Total: {1} in {2:N0} file(s).{3}" -f $Bold, (Format-Size $totalBytes), $totalFiles, $Reset)
    if ($unreadable) { Write-Host ("  {0}{1} item(s) could not be read, so that total may undercount.{2}" -f $Yellow, $unreadable, $Reset) }

    # What this delete leaves behind: ask the orphan finder what the world
    # looks like once these transcripts and footprint paths are gone, with the
    # same rules -Orphans uses. Keep only rows that belong to this delete:
    # anything carrying one of these session IDs in its path, and everything
    # inside a project dir this delete vacates (its last session goes) or that
    # dir's %TEMP% twin. Unrelated orphans elsewhere are left to -Orphans.
    # 'project' rows and empty 'temp' rows are the dirs themselves; those are
    # shells, handled below, so they are not listed twice.
    $projPaths   = @($targets | ForEach-Object { Split-Path $_.FullPath -Parent } | Sort-Object -Unique)
    $tempRoot    = Join-Path $env:LOCALAPPDATA 'Temp\claude'
    $runningDirs = @(Get-RunningProjectDir)
    $footprint   = @($footprintByUuid.Values | ForEach-Object { $_ })
    $goneYes     = @($targetPaths) + $footprint
    $othersIn    = {
        param([string]$Dir)
        @(Get-ChildItem -LiteralPath $Dir -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object { $targetPaths -notcontains $_.FullName }).Count
    }
    $vacated = @($projPaths | Where-Object { -not (& $othersIn $_) -and $runningDirs -notcontains (Split-Path $_ -Leaf) })
    $roots   = @($vacated | ForEach-Object { $_; Join-Path $tempRoot (Split-Path $_ -Leaf) })
    $ids     = @($groups.Keys)
    $leftBehind = @(Get-OrphanItems -GoneTranscripts $targetPaths -GonePaths $footprint -NoFold | Where-Object {
        $it = $_
        if ($it.Kind -eq 'project' -or ($it.Kind -eq 'temp' -and $it.Why -eq 'empty')) { return $false }
        @($it.Paths | Where-Object {
            $p = $_
            (@($ids | Where-Object { $p.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) -or
            (@($roots | Where-Object { $p.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        }).Count -gt 0
    })
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
            $why = if ($x.Kind -eq 'memory' -and $x.State -eq 'dormant') { "dormant: $($x.Folder) still exists, so this memory would load again in a new session there" }
                   elseif ($x.Kind -eq 'memory') { "$($x.Folder) no longer exists" }
                   else { $x.Why }
            Write-Host ("      {0}{1}{2}" -f $Dim, $why, $Reset)
            if ($x.Note) { Write-Host ("      {0}{1}{2}" -f $Dim, $x.Note, $Reset) }
            $lbBytes += $x.Bytes; $lbFiles += $x.Files
        }
        if ($shellsAll.Count) {
            Write-Host ("    {0}then the dirs left empty: {1}{2}" -f $Dim, (@($shellsAll | ForEach-Object { ConvertTo-DisplayPath $_ }) -join ', '), $Reset)
        }
        Write-Host ("    'all' adds {0} in {1:N0} file(s)." -f (Format-Size $lbBytes), $lbFiles)
    }

    # Say out loud what stays. The old plan only said 'NOT touched', which
    # left you guessing whether memory or CLAUDE.md were among the parts.
    Write-Host ''
    Write-Host ("  {0}Kept either way:{1}" -f $Bold, $Reset)
    foreach ($pdPath in $projPaths) {
        $mem = Get-PathStats -Path (Join-Path $pdPath 'memory')
        if (-not $mem.Files) { continue }
        $folder = @($targets | Where-Object { (Split-Path $_.FullPath -Parent) -eq $pdPath })[0].Folder
        $others = & $othersIn $pdPath
        $why = if ($others) { "$others other session(s) there still use it" }
               elseif (Test-ProtectedPath $pdPath) { "the home folder's memory is never removed" }
               elseif ($runningDirs -contains (Split-Path $pdPath -Leaf)) { 'a session running there uses it' }
               else { $null }   # vacated: listed under 'Left behind' instead
        if ($why) { Write-Host ("    memory for {0}: {1:N0} file(s), {2}; {3}." -f $folder, $mem.Files, (Format-Size $mem.Bytes), $why) }
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

    # Deletes exactly what the plan showed: the footprint paths were fixed
    # above, never re-scanned here.
    $deleted = 0; $failed = 0; $freed = [long]0; $keptSidecars = 0
    foreach ($uuid in $groups.Keys) {
        foreach ($s in $groups[$uuid]) {
            $bytes = (Get-PathStats -Path $s.FullPath).Bytes
            if (-not (Remove-PathHard -Path $s.FullPath)) {
                Write-Error "Failed to delete transcript $($s.FullPath)"
                $failed++
                continue
            }
            $deleted++; $freed += $bytes
            Write-Host ("{0}deleted{1} [{2}] {3}" -f $Green, $Reset, $s.Index, $s.File)
        }

        # The shared footprint goes only once no copy remains anywhere,
        # re-checked now in case a copy above failed to delete.
        if (@($transcriptsByUuid[$uuid] | Where-Object { Test-Path -LiteralPath $_ }).Count) {
            Write-Host ("  {0}kept this session's shared data: a copy of it still exists{1}" -f $Dim, $Reset)
            $keptSidecars++
            continue
        }
        foreach ($extra in $footprintByUuid[$uuid]) {
            if (Test-ProtectedPath $extra) { Write-Warning "  refusing to remove protected $extra"; continue }
            $st = Get-PathStats -Path $extra
            if (Remove-PathHard -Path $extra) {
                $freed += $st.Bytes
                Write-Host ("  {0}+ removed {1} ({2}){3}" -f $Dim, (ConvertTo-DisplayPath $extra), (Format-Size $st.Bytes), $Reset)
            } else {
                Write-Warning "  could not remove $extra"
            }
        }
    }

    if ($answer -eq 'all') {
        foreach ($x in $leftBehind) {
            foreach ($p in $x.Paths) {
                if (Test-ProtectedPath $p) { Write-Warning "  refusing to remove protected $p"; continue }
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
    foreach ($d in @($shellsYes) + $(if ($answer -eq 'all') { @($shellsAll) } else { @() })) {
        if (-not (Test-Path -LiteralPath $d) -or (Test-ProtectedPath $d) -or -not (Test-ShellDir -Path $d)) { continue }
        if (Remove-PathHard -Path $d) {
            Write-Host ("  {0}+ removed the now-empty {1}{2}" -f $Dim, (ConvertTo-DisplayPath $d), $Reset)
        }
    }

    Write-Host ''
    Write-Host ("{0}Deleted {1} of {2} session(s), freed ~{3}.{4}" -f $Green, $deleted, $targets.Count, (Format-Size $freed), $Reset)
    if ($failed)       { Write-Host ("{0}{1} failed.{2}" -f $Red, $failed, $Reset) }
    if ($keptSidecars) { Write-Host ("{0}{1} session(s) kept their shared data because another copy is still alive.{2}" -f $Dim, $keptSidecars, $Reset) }
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
        $picked = Select-TurnsForDisplay -SessionTurns $s.Turns -N $Turns
        $shown  = $picked.First.Count + $picked.Last.Count

        $header = @(
            ('=' * 80),
            ("Index    : {0}" -f $s.Index),
            ("Folder   : {0}" -f $s.Folder),
            ("Session  : {0}" -f $s.Session),
            ("File     : {0}" -f $s.File),
            ("Modified : {0}" -f $s.Modified.ToString('yyyy-MM-dd HH:mm:ss')),
            ("Size     : {0:N0} KB" -f $s.Size),
            ("Context  : {0}" -f $(if ($null -ne $s.Context) { '{0:N0} tokens' -f $s.Context } else { 'unknown' })),
            ("Model    : {0}" -f $(if ($s.Model) { $s.Model } else { 'unknown' })),
            ("Turns    : {0} of {1}{2}" -f $shown, $picked.Total, $(if ($Turns -gt 0) { " (first/last $Turns)" } else { ' (all)' })),
            ('-' * 80)
        )
        Write-Output ("{0}{1}{2}" -f $Green, ($header -join "`n"), $Reset)

        if ($shown -eq 0) {
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
