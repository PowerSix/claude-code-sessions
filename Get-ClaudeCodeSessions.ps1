<#
.SYNOPSIS
    Triage, read and delete Claude Code session transcripts.

.DESCRIPTION
    Lists or searches the .jsonl session transcripts Claude Code stores under
    $env:USERPROFILE\.claude\projects.  Each project directory's name is the
    cwd with ':' and '\' replaced by '-'.  This script scans every project
    directory and reports a Folder column showing the original cwd relative
    to the user's home (e.g. '\' for the home dir itself,
    '\Projects\my-app' for a subfolder).

    The Folder value is read from the 'cwd' field inside the first user
    message in each session - the directory name is only a fallback.

    Three modes, one per verb:
      (no selector)    table of every session, newest first within each folder
      -Open <sel>      print that session's conversation
      -Delete <sel>    permanently remove that session and everything it owns

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

    Indexes are assigned after sorting and BEFORE the narrowing filters,
    so the numbers stay stable as long as no session is added or removed.

    Note: this is named -Open instead of -File because pwsh.exe treats
    -File as its own script-launcher argument and would eat the value.

.PARAMETER Delete
    Select sessions and permanently delete them, along with their sidecar,
    file-history, session-env, tasks, jobs and %TEMP% data. Accepts the same
    selector forms as -Open, plus '*' meaning "everything currently matched".

    '*' requires at least one narrowing filter (-Search, -OlderThan,
    -SmallerThan or -Unnamed) so it can never wipe every session at once.

    The matched set is printed as a table and a single confirmation is
    required: you must type 'yes'. Deletion is permanent, with no Recycle Bin.
    Preview by running the same command with -Open instead.

    Sessions that are currently running are always skipped, which also closes
    the old footgun where searching for a phrase logged that phrase into the
    live transcript and made it match itself.

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

${Bold}THREE MODES${Reset}
  ${Cyan}Get-ClaudeCodeSessions${Reset}                 list every session as a table
  ${Cyan}Get-ClaudeCodeSessions -Open${Reset} <sel>     print that session's conversation
  ${Cyan}Get-ClaudeCodeSessions -Delete${Reset} <sel>   delete it and everything it owns

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

${Bold}SAFETY${Reset}
  ${Dim}- The matched set is printed, then ONE confirmation asks you to type 'yes'.${Reset}
  ${Dim}- Deletion is permanent: there is no Recycle Bin.${Reset}
  ${Dim}- Running sessions are always skipped, so it cannot delete itself.${Reset}
  ${Dim}- A sidecar is removed only once no transcript with that UUID exists in ANY${Reset}
  ${Dim}  project dir, because a sidecar can outlive a cwd change.${Reset}
  ${Dim}- Preview any delete by running the same command with -Open instead.${Reset}

${Bold}EXAMPLES${Reset}
  Get-ClaudeCodeSessions
  Get-ClaudeCodeSessions -Open 23
  Get-ClaudeCodeSessions -Open de8f46e2 -Turns 0
  Get-ClaudeCodeSessions -Search "database migration"
  Get-ClaudeCodeSessions -Delete 23
  Get-ClaudeCodeSessions -Delete delete
  Get-ClaudeCodeSessions -OlderThan 90 -SmallerThan 5 -Delete *
"@
    Write-Output $h
    return
}

if ($Open -and $Delete) {
    Write-Error 'Use -Open to read a session or -Delete to remove one, not both.'
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
    # Returns a hashtable with .Turns (list of user/assistant turns) and
    # .CustomTitle (string or empty).  The custom title is set by the user via
    # /title in Claude Code and is recorded as 'custom-title' lines in the
    # session JSONL.  The same title can appear multiple times if it was
    # changed; we keep the LAST one we see.
    param([string]$JsonlPath)

    # Named $turnList, not $turns: the -Turns parameter is [int] and PowerShell
    # variable names are case-insensitive, so a local $turns would collide with
    # it and fail to accept a List.
    $turnList = New-Object System.Collections.Generic.List[object]
    $customTitle = ''

    if ([string]::IsNullOrWhiteSpace($JsonlPath)) {
        return @{ Turns = $turnList; CustomTitle = $customTitle }
    }

    foreach ($line in Get-Content -LiteralPath $JsonlPath -ErrorAction SilentlyContinue) {
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

        if ($obj.type -eq 'custom-title' -and $obj.customTitle) {
            $customTitle = [string]$obj.customTitle
            continue
        }

        if ($obj.type -ne 'user' -and $obj.type -ne 'assistant') { continue }
        if (-not $obj.message) { continue }
        if ($obj.isSidechain) { continue }

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

    return @{ Turns = $turnList; CustomTitle = $customTitle }
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

function Get-RunningSessionId {
    # ~\.claude\sessions\<pid>.json maps a live process to its sessionId. Only
    # trust an entry whose pid is still alive, otherwise a crashed session
    # would be protected forever. CLAUDE_CODE_SESSION_ID covers the case where
    # this script is run from inside a session's own shell.
    #
    # Returns a plain string ARRAY, deliberately not a HashSet. PowerShell
    # enumerates any collection a function outputs, so returning a HashSet
    # yields $null for 0 entries, a bare [string] for 1, and [object[]] for 2+.
    # The $null case then throws on .Contains(), and the single-string case
    # silently switches to String.Contains() substring matching. Test membership
    # at the call site with -contains / -notcontains: those are case-insensitive
    # for strings, do equality rather than substring, and treat $null as "no
    # match" instead of erroring.
    $ids = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_CODE_SESSION_ID) { $ids.Add([string]$env:CLAUDE_CODE_SESSION_ID) }
    $dir = Join-Path $ClaudeRoot 'sessions'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $o.sessionId) { continue }
            if ($o.pid -and -not (Get-Process -Id $o.pid -ErrorAction SilentlyContinue)) { continue }
            $ids.Add([string]$o.sessionId)
        }
    }
    return [string[]]$ids
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

function Get-PathSizeKB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item.PSIsContainer) { return [int][math]::Round($item.Length / 1KB) }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    if (-not $files.Count) { return 0 }
    return [int][math]::Round((($files | Measure-Object Length -Sum).Sum) / 1KB)
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

# ---- Scan ------------------------------------------------------------------

$ProjectDirs = Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue

$Sessions = New-Object System.Collections.Generic.List[object]

foreach ($dir in $ProjectDirs) {
    $files = if ($IncludeSubagents) {
        Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue
    }

    foreach ($file in $files) {
        if ($Search) {
            $hit = Select-String -LiteralPath $file.FullName -Pattern $Search -SimpleMatch -List -ErrorAction SilentlyContinue
            if (-not $hit) { continue }
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
            Size     = [int][math]::Round($file.Length / 1KB)
            FullPath = $file.FullName
            Turns    = $sTurns
        })
    }
}

$Sessions = @($Sessions | Sort-Object Folder, @{ Expression = 'Modified'; Descending = $true })

# Assign stable indexes BEFORE the selectors and filters run, so the numbers
# printed by an earlier bare `Get-ClaudeCodeSessions` still resolve.
$i = 1
foreach ($s in $Sessions) {
    $s | Add-Member -NotePropertyName 'Index' -NotePropertyValue $i -Force
    $i++
}

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

    # Never delete a session that is currently running. This also closes the
    # old footgun: -Search wrote the search phrase into the live transcript,
    # which then matched itself.
    # -contains, not .Contains(): see the note in Get-RunningSessionId. With no
    # session running at all (Claude Code closed) the function returns nothing,
    # and -contains simply reports no match instead of throwing on $null.
    $running = @(Get-RunningSessionId)
    $skipped = @($targets | Where-Object { $running -contains [IO.Path]::GetFileNameWithoutExtension($_.File) })
    $targets = @($targets | Where-Object { $running -notcontains [IO.Path]::GetFileNameWithoutExtension($_.File) })

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

    # Show exactly what will die, plus the full reclaimable footprint.
    $plan = foreach ($s in $targets) {
        $uuid  = [IO.Path]::GetFileNameWithoutExtension($s.File)
        # @() because Get-SessionFootprint's List is unrolled on output: without
        # it, 0 paths arrive as $null and 1 path as a bare string.
        $extra = @(Get-SessionFootprint -Uuid $uuid)
        $extraKB = 0
        foreach ($p in $extra) { $extraKB += Get-PathSizeKB -Path $p }
        [PSCustomObject]@{
            Session = $s
            Uuid    = $uuid
            Extra   = $extra
            ExtraKB = $extraKB
            TotalKB = $s.Size + $extraKB
        }
    }
    $plan = @($plan)

    Write-Host ''
    Write-Host ("{0}The following {1} session(s) will be PERMANENTLY deleted:{2}" -f $Bold, $plan.Count, $Reset)
    Write-Host ''
    # Two transcripts can carry the SAME uuid (a session whose cwd changed, or
    # one relocated by hand). They then share one footprint, so it must be
    # counted once or the total lies. Dedupe by path for the total, and label
    # the repeat rows 'shared' rather than repeating the number.
    $uniqueExtra = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $uuidCounts  = @{}
    foreach ($p in $plan) {
        if (-not $uuidCounts.ContainsKey($p.Uuid)) { $uuidCounts[$p.Uuid] = 0 }
        $uuidCounts[$p.Uuid]++
        foreach ($e in $p.Extra) { [void]$uniqueExtra.Add($e) }
    }
    $sumE = 0
    foreach ($e in $uniqueExtra) { $sumE += Get-PathSizeKB -Path $e }

    Write-Host ("  {0,-5} {1,-42} {2,-28} {3,9} {4,9} {5,7}" -f 'Index', 'Folder', 'Session', 'Xcript KB', 'Extra KB', 'Parts')
    Write-Host ("  {0,-5} {1,-42} {2,-28} {3,9} {4,9} {5,7}" -f '-----', '------', '-------', '---------', '--------', '-----')
    $sumX = 0
    $seenUuid = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $plan) {
        $name = if ($p.Session.Session) { $p.Session.Session } else { '(unnamed)' }
        $extraCell = if ($uuidCounts[$p.Uuid] -gt 1 -and -not $seenUuid.Add($p.Uuid)) { 'shared' } else { [string]$p.ExtraKB }
        Write-Host ("  {0,-5} {1,-42} {2,-28} {3,9} {4,9} {5,7}" -f `
            $p.Session.Index, $p.Session.Folder, $name, $p.Session.Size, $extraCell, $p.Extra.Count)
        $sumX += $p.Session.Size
    }
    Write-Host ''
    Write-Host ("  transcripts {0} KB + sidecar/history/scratch {1} KB = {2}{3} KB total{4}" -f `
        $sumX, $sumE, $Bold, ($sumX + $sumE), $Reset)
    Write-Host ("  {0}memory\, history.jsonl, .claude.json and paste-cache\ are NOT touched.{1}" -f $Dim, $Reset)
    Write-Host ("  {0}There is no Recycle Bin. This cannot be undone.{1}" -f $Red, $Reset)
    Write-Host ''

    $answer = Read-Host "Type 'yes' to delete"
    if ($answer -ne 'yes') {
        Write-Host ("{0}Aborted. Nothing was deleted.{1}" -f $Cyan, $Reset)
        Write-Host ''
        return
    }

    # Map every UUID to all root transcripts carrying it, so a sidecar is only
    # removed once none remain anywhere. A UUID really can appear in two
    # project dirs at once (a session whose cwd changed, or one relocated by
    # hand), and deleting one copy must not orphan the other's sidecar.
    $transcriptsByUuid = @{}
    foreach ($dir in $ProjectDirs) {
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
            $u = $f.BaseName
            if (-not $transcriptsByUuid.ContainsKey($u)) { $transcriptsByUuid[$u] = New-Object System.Collections.Generic.List[string] }
            $transcriptsByUuid[$u].Add($f.FullName)
        }
    }

    $deleted = 0; $failed = 0; $freedKB = 0; $keptSidecars = 0
    foreach ($p in $plan) {
        $s = $p.Session

        if (-not (Remove-PathHard -Path $s.FullPath)) {
            Write-Error "Failed to delete transcript $($s.FullPath)"
            $failed++
            continue
        }
        $deleted++
        $freedKB += $s.Size
        Write-Host ("{0}deleted{1} [{2}] {3}" -f $Green, $Reset, $s.Index, $s.File)

        # Does any transcript with this UUID still exist elsewhere?
        $stillLive = $false
        if ($transcriptsByUuid.ContainsKey($p.Uuid)) {
            foreach ($other in $transcriptsByUuid[$p.Uuid]) {
                if ($other -ne $s.FullPath -and (Test-Path -LiteralPath $other)) { $stillLive = $true; break }
            }
        }
        if ($stillLive) {
            Write-Host ("  {0}kept sidecar data - another transcript with this UUID still exists{1}" -f $Dim, $Reset)
            $keptSidecars++
            continue
        }

        # jobs\<first8> could in principle collide with a live session's
        # prefix, so re-check before removing that one.
        $prefix = if ($p.Uuid.Length -ge 8) { $p.Uuid.Substring(0, 8) } else { $p.Uuid }
        $jobsPath = Join-Path (Join-Path $ClaudeRoot 'jobs') $prefix
        $prefixClash = $false
        foreach ($u in $transcriptsByUuid.Keys) {
            if ($u -ne $p.Uuid -and $u.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                foreach ($other in $transcriptsByUuid[$u]) {
                    if (Test-Path -LiteralPath $other) { $prefixClash = $true; break }
                }
            }
            if ($prefixClash) { break }
        }

        foreach ($extra in $p.Extra) {
            if ($extra -eq $jobsPath -and $prefixClash) {
                Write-Host ("  {0}kept jobs\{1} - another live session shares that prefix{2}" -f $Dim, $prefix, $Reset)
                continue
            }
            $kb = Get-PathSizeKB -Path $extra
            if (Remove-PathHard -Path $extra) {
                $freedKB += $kb
                Write-Host ("  {0}+ removed {1} ({2} KB){3}" -f $Dim, $extra.Replace($env:USERPROFILE, '~'), $kb, $Reset)
            } else {
                Write-Warning "  could not remove $extra"
            }
        }
    }

    Write-Host ''
    Write-Host ("{0}Deleted {1} of {2} session(s), freed ~{3} KB ({4} MB).{5}" -f `
        $Green, $deleted, $plan.Count, $freedKB, [math]::Round($freedKB / 1024, 2), $Reset)
    if ($failed)       { Write-Host ("{0}{1} failed.{2}" -f $Red, $failed, $Reset) }
    if ($keptSidecars) { Write-Host ("{0}{1} sidecar set(s) kept because a duplicate UUID is still live.{2}" -f $Dim, $keptSidecars, $Reset) }
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
            ("Size     : {0} KB" -f $s.Size),
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

# Load the sidecar format XML so PowerShell renders this type as an autosized
# table instead of falling back to Format-List (the default once an object has
# 5+ public properties).
$formatXml = Join-Path $PSScriptRoot 'Get-ClaudeCodeSessions.format.ps1xml'
if (Test-Path $formatXml) {
    Update-FormatData -PrependPath $formatXml
}

foreach ($s in $Sessions) {
    $s.PSObject.TypeNames.Insert(0, 'CCSession')
    $s
}
