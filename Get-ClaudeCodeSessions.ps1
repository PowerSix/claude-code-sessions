<#
.SYNOPSIS
    Triage and search Claude Code session transcripts.

.DESCRIPTION
    Lists or searches the .jsonl session transcripts Claude Code stores under
    $env:USERPROFILE\.claude\projects.  Each project directory's name is the
    cwd with ':' and '\' replaced by '-'.  This script scans every project
    directory and reports a Folder column showing the original cwd relative
    to the user's home (e.g. '\' for the home dir itself,
    '\Projects\my-app' for a subfolder).

    The Folder value is read from the 'cwd' field inside the first user
    message in each session - the directory name is only a fallback.

    With -Prompt / -PromptStart / -PromptEnd, the script switches from a
    table view to a per-session block showing the requested conversation
    turns in chronological order (with a gap marker between halves when
    -Prompt skips the middle of a long session).

.PARAMETER Search
    Phrase to search for inside session transcripts. Case-insensitive,
    literal (not regex). Returns only sessions matching.

.PARAMETER Prompt
    Show the first N turns AND the last N turns of each session in
    chronological order. If the session has 2N or fewer turns, all turns
    are shown (no gap). Otherwise a gap marker reports how many turns
    are omitted between the two halves.

.PARAMETER PromptStart
    Show only the first N turns of each session. Mutually exclusive
    with -Prompt.

.PARAMETER PromptEnd
    Show only the last N turns of each session. Mutually exclusive
    with -Prompt.

.PARAMETER IncludeSubagents
    Include subagent transcripts (subagents/agent-*.jsonl). Off by default.

.PARAMETER Limit
    Cap the number of sessions returned. 0 (default) means no limit.

.PARAMETER PromptMaxChars
    Truncate each turn's text to this many characters when displaying with
    -Prompt/-PromptStart/-PromptEnd. Default 600. Use 0 for no truncation.

.PARAMETER NoColor
    Disable ANSI colors in -Prompt mode output.

.PARAMETER Open
    Pick a single session. Three forms:
      - Integer:   matches the Index column from the table view
      - Substring: matches the filename (UUID fragment is fine)
      - Substring: matches the Session name (custom title set via /title)
    Substring matches are case-insensitive and may return multiple sessions.

    Indexes are assigned after sorting and BEFORE -Limit/-Search filters,
    so the numbers stay stable as long as no new session is added/removed.

    Note: this is named -Open instead of -File because pwsh.exe treats
    -File as its own script-launcher argument and would eat the value.

.PARAMETER Delete
    Permanently delete the sessions in the (filtered) result set. Refuses to
    run without at least one selector (-Search, -Open, -OlderThan,
    -SmallerThan, or -Unnamed) so a bare -Delete can never wipe everything.
    Supports -WhatIf and -Confirm; prompts per file by default because the
    deletion is permanent (no Recycle Bin). Preview by running the identical
    command WITHOUT -Delete - the table shows exactly what would be removed.

.PARAMETER OlderThan
    Keep only sessions whose Modified time is older than N days. Combines with
    other selectors (logical AND). 0 (default) disables the filter.

.PARAMETER SmallerThan
    Keep only sessions whose Size (KB) is below N. Useful for sweeping tiny,
    abandoned sessions. 0 (default) disables the filter.

.PARAMETER Unnamed
    Keep only sessions with no custom /title. Combines with other selectors.

.EXAMPLE
    Get-ClaudeCodeSessions -OlderThan 30
    Preview every session not touched in the last 30 days (read-only table).

.EXAMPLE
    Get-ClaudeCodeSessions -OlderThan 30 -Delete
    Delete those same sessions, prompting before each one.

.EXAMPLE
    Get-ClaudeCodeSessions -SmallerThan 5 -Unnamed -Delete -Confirm:$false
    Nuke tiny, never-titled sessions with no per-file prompt. Combine selectors
    freely - they AND together.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'that embarrassing one' -Delete -WhatIf
    Show what a search-scoped delete would remove, without removing anything.

.EXAMPLE
    Get-ClaudeCodeSessions -Open 23 -Prompt 5
    Open session #23 from the table and show first/last 5 turns.

.EXAMPLE
    Get-ClaudeCodeSessions -Open de8f46e2 -PromptStart 10
    Open the session whose filename contains 'de8f46e2'.

.EXAMPLE
    Get-ClaudeCodeSessions -Open my-app -PromptEnd 20
    Open every session named (custom title) 'my-app', last 20 turns each.

.EXAMPLE
    Get-ClaudeCodeSessions
    Table view of every session across every project, newest first.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'database migration'
    Find sessions in any project folder mentioning the phrase.

.EXAMPLE
    Get-ClaudeCodeSessions -Search 'kiro' -Prompt 3
    Show first 3 turns and last 3 turns of every match.

.EXAMPLE
    Get-ClaudeCodeSessions -PromptStart 2 -Limit 5
    For the 5 newest sessions, show the first two turns of each.

.EXAMPLE
    Get-ClaudeCodeSessions | Where-Object Size -lt 5
    Tiny/abandoned sessions - cleanup candidates.
#>
[CmdletBinding(DefaultParameterSetName = 'Table', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$Search,

    [Parameter(ParameterSetName = 'Prompt')]
    [int]$Prompt,

    [Parameter(ParameterSetName = 'PromptStart')]
    [int]$PromptStart,

    [Parameter(ParameterSetName = 'PromptEnd')]
    [int]$PromptEnd,

    [switch]$IncludeSubagents,

    [int]$Limit = 0,

    [int]$PromptMaxChars = 600,

    [switch]$NoColor,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        # Attaching ANY completer to -Open makes PowerShell hand this parameter's
        # completion entirely to us, suppressing the default filesystem fallback
        # that otherwise suggests files in the current directory. We offer session
        # handles instead: custom titles first, then UUID filenames.

        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $root)) { return }

        # PowerShell may include surrounding quotes in the word; strip them so a
        # partially-typed quoted title still matches.
        $word = $wordToComplete.Trim("'", '"')

        # Decode an encoded project-dir name ('C--Users-foo') into a readable
        # folder for the tooltip. Pure string work - no file reads.
        $decode = {
            param($n)
            if ($n -match '^([A-Za-z])--(.+)$') { "$($matches[1]):\" + ($matches[2] -replace '-', '\') }
            else { $n }
        }

        # Title lookups read whole transcripts, so cache them keyed by path and
        # invalidate on LastWriteTime. The first Tab pays the scan; later presses
        # are fast and self-refresh when a session changes.
        if (-not $global:CCSessionTitleCache) { $global:CCSessionTitleCache = @{} }
        $cache = $global:CCSessionTitleCache

        $titleResults = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $fileResults  = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $seenTitles   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $folder = & $decode $dir.Name
            foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {

                # Filename / UUID handle - instant, no file read.
                $stem = $file.BaseName
                if (-not $word -or $stem -like "*$word*") {
                    $tip = '{0}  {1}' -f $folder, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    $fileResults.Add([System.Management.Automation.CompletionResult]::new(
                        $stem, $stem, 'ParameterValue', $tip))
                }

                # Custom title - cached. Last non-empty custom-title wins, mirroring
                # the main script so a completed title actually resolves on -Open.
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
                if ($title -and (-not $word -or $title -like "*$word*") -and $seenTitles.Add($title)) {
                    $completion = if ($title -match '[\s'']') { "'" + ($title -replace "'", "''") + "'" } else { $title }
                    $titleResults.Add([System.Management.Automation.CompletionResult]::new(
                        $completion, $title, 'ParameterValue', "Session: $title  ($folder)"))
                }
            }
        }

        # Titles first (the memorable handles), then UUID filenames.
        $out = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
        $out.AddRange($titleResults)
        $out.AddRange($fileResults)
        return $out
    })]
    [string]$Open,

    [switch]$Delete,

    [int]$OlderThan = 0,

    [int]$SmallerThan = 0,

    [switch]$Unnamed,

    [switch]$Help
)

$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$UserHome     = $env:USERPROFILE

if (-not (Test-Path $ProjectsRoot)) {
    Write-Error "Claude Code projects directory not found: $ProjectsRoot"
    return
}

$Esc    = [char]27
if ($NoColor) {
    $Green = ''; $Blue = ''; $Yellow = ''; $Cyan = ''; $Bold = ''; $Dim = ''; $Reset = ''
} else {
    $Green  = "$Esc[32m"
    $Blue   = "$Esc[94m"
    $Yellow = "$Esc[33m"
    $Cyan   = "$Esc[36m"
    $Bold   = "$Esc[1m"
    $Dim    = "$Esc[2m"
    $Reset  = "$Esc[0m"
}

# ---- Help ------------------------------------------------------------------

if ($Help) {
    $h = @"
${Bold}${Green}Get-ClaudeCodeSessions${Reset} - Browse and triage Claude Code session transcripts.

${Bold}USAGE${Reset}
  Get-ClaudeCodeSessions [parameters]

${Bold}DEFAULT (no parameters)${Reset}
  Lists every session across every project as a table sorted by Folder, then
  by Modified (newest first within each folder).

${Bold}PARAMETERS${Reset}
  ${Cyan}-Open${Reset} <int|substring>
      Pick a single session and switch to header-block view.
        - Integer:   matches the Index column from the table
        - Substring: matches the filename (UUID fragment OK)
        - Substring: matches the Session name (custom title set via /title)
      Substring match is case-insensitive and may return multiple sessions.

  ${Cyan}-Search${Reset} <string>
      Case-insensitive literal search inside transcripts. Filters the result
      set to sessions whose JSONL contains the phrase.

  ${Cyan}-Prompt${Reset} <N>
      Show the first N turns AND the last N turns of each session in
      chronological order. If the session has more than 2N turns, a
      ${Dim}... [X turns omitted] ...${Reset} marker appears between the halves.

  ${Cyan}-PromptStart${Reset} <N>
      Show only the first N turns. Mutually exclusive with -Prompt.

  ${Cyan}-PromptEnd${Reset} <N>
      Show only the last N turns. Mutually exclusive with -Prompt.

  ${Cyan}-PromptMaxChars${Reset} <N>
      Truncate each turn's text to N chars. Default 600. Use 0 for full text.

  ${Cyan}-Limit${Reset} <N>
      Cap the number of sessions returned. Default 0 (no limit).

  ${Cyan}-OlderThan${Reset} <N>
      Keep only sessions older than N days (by Modified). 0 disables.

  ${Cyan}-SmallerThan${Reset} <N>
      Keep only sessions under N KB. 0 disables.

  ${Cyan}-Unnamed${Reset}
      Keep only sessions with no custom /title.

  ${Cyan}-Delete${Reset}
      ${Bold}Permanently${Reset} delete the filtered set. Requires at least one selector
      (-Search/-Open/-OlderThan/-SmallerThan/-Unnamed). Supports -WhatIf and
      -Confirm; prompts per file unless you pass ${Dim}-Confirm:`$false${Reset}. Preview by
      running the same command WITHOUT -Delete.

  ${Cyan}-IncludeSubagents${Reset}
      Include subagent transcripts (subagents/agent-*.jsonl). Off by default.

  ${Cyan}-NoColor${Reset}
      Disable ANSI colors. Useful when piping to a file.

  ${Cyan}-Help${Reset}
      Show this reference and exit.

${Bold}EXAMPLES${Reset}
  ${Dim}# Browse${Reset}
  Get-ClaudeCodeSessions
  Get-ClaudeCodeSessions -Limit 20

  ${Dim}# Open by index, UUID, or Session name${Reset}
  Get-ClaudeCodeSessions -Open 23 -Prompt 5
  Get-ClaudeCodeSessions -Open de8f46e2 -PromptStart 10
  Get-ClaudeCodeSessions -Open my-app -PromptEnd 20

  ${Dim}# Search transcripts${Reset}
  Get-ClaudeCodeSessions -Search "database migration"
  Get-ClaudeCodeSessions -Search "kiro" -Prompt 3

  ${Dim}# Cleanup (preview first, then add -Delete)${Reset}
  Get-ClaudeCodeSessions -OlderThan 30
  Get-ClaudeCodeSessions -OlderThan 30 -Delete
  Get-ClaudeCodeSessions -SmallerThan 5 -Unnamed -Delete -Confirm:`$false
  Get-ClaudeCodeSessions -Search "scratch" -Delete -WhatIf

${Bold}NOTES${Reset}
  ${Dim}- Reads from %USERPROFILE%\.claude\projects. Read-only by default.${Reset}
  ${Dim}- Indexes are stable until a session is added or removed.${Reset}
  ${Dim}- Custom session titles come from /title in Claude Code.${Reset}
  ${Dim}- Run Get-Help Get-ClaudeCodeSessions.ps1 -Detailed for the full doc.${Reset}
"@
    Write-Output $h
    return
}

# ---- Delete guard ----------------------------------------------------------

# -Delete is destructive and operates on the *filtered* result set. Refuse to
# run without at least one selector, so a bare `-Delete` can never wipe every
# session in one "Yes to All". The per-file ShouldProcess prompt is the
# seatbelt; this required-selector check is the actual guard rail.
if ($Delete) {
    $hasSelector = $Search -or $Open -or ($OlderThan -gt 0) -or ($SmallerThan -gt 0) -or $Unnamed
    if (-not $hasSelector) {
        Write-Error ("Refusing to delete without a selector. Narrow the set first with " +
            "-Search, -Open, -OlderThan, -SmallerThan, or -Unnamed, then re-run with " +
            "-Delete. Run the same command WITHOUT -Delete to preview the victims.")
        return
    }
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

    $turns = New-Object System.Collections.Generic.List[object]
    $customTitle = ''

    if ([string]::IsNullOrWhiteSpace($JsonlPath)) {
        return @{ Turns = $turns; CustomTitle = $customTitle }
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

        $turns.Add([PSCustomObject]@{
            Role      = $role
            Text      = $text
            Cwd       = $obj.cwd
            Timestamp = $obj.timestamp
        })
    }

    return @{ Turns = $turns; CustomTitle = $customTitle }
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
    param(
        [System.Collections.Generic.List[object]]$Turns,
        [string]$Mode,
        [int]$N
    )
    $total = if ($Turns) { $Turns.Count } else { 0 }
    $result = @{ First = @(); Last = @(); Omitted = 0; Total = $total }

    if ($total -eq 0 -or $N -le 0) { return $result }

    switch ($Mode) {
        'Start' {
            $result.First   = @($Turns | Select-Object -First $N)
            $result.Omitted = [Math]::Max(0, $total - $N)
        }
        'End' {
            $result.Last    = @($Turns | Select-Object -Last $N)
            $result.Omitted = [Math]::Max(0, $total - $N)
        }
        'Both' {
            if ($total -le ($N * 2)) {
                $result.First   = @($Turns)
                $result.Omitted = 0
            } else {
                $result.First   = @($Turns | Select-Object -First $N)
                $result.Last    = @($Turns | Select-Object -Last $N)
                $result.Omitted = $total - ($N * 2)
            }
        }
    }
    return $result
}

function Write-TurnBlock {
    param($Turn, [int]$MaxChars)
    if ($Turn.Role -eq 'user') {
        $color = $Blue;   $label = '[USER]'
    } else {
        $color = $Yellow; $label = '[CLAUDE]'
    }
    $ts = Format-Timestamp $Turn.Timestamp
    Write-Output ("{0}{1} {2}{3}" -f $color, $label, $ts, $Reset)
    Write-Output (Format-TurnText -Text $Turn.Text -Max $MaxChars)
    Write-Output ''
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

        $data   = Get-SessionData -JsonlPath $file.FullName
        $turns  = $data.Turns
        $cwd    = ($turns | Where-Object Cwd | Select-Object -First 1).Cwd
        $folder = ConvertTo-FolderLabel -Cwd $cwd -DirName $dir.Name

        $size = [int][math]::Round($file.Length / 1KB)

        $session = [PSCustomObject]@{
            Folder   = $folder
            Session  = $data.CustomTitle
            File     = $file.Name
            Modified = $file.LastWriteTime
            Size     = $size
            FullPath = $file.FullName
            Turns    = $turns
        }
        $Sessions.Add($session)
    }
}

$Sessions = $Sessions | Sort-Object Folder, @{ Expression = 'Modified'; Descending = $true }

# Assign stable indexes BEFORE filtering by -File or applying -Limit, so the
# numbers shown by an earlier `Get-ClaudeCodeSessions` call still resolve.
$i = 1
foreach ($s in $Sessions) {
    $s | Add-Member -NotePropertyName 'Index' -NotePropertyValue $i -Force
    $i++
}

if ($Open) {
    $matchedSessions = if ($Open -match '^\d+$') {
        $idx = [int]$Open
        $Sessions | Where-Object { $_.Index -eq $idx }
    } else {
        $needle = $Open
        $Sessions | Where-Object {
            $_.File -like "*$needle*" -or $_.Session -like "*$needle*"
        }
    }
    if (-not $matchedSessions -or @($matchedSessions).Count -eq 0) {
        Write-Error "No session matched -Open '$Open'."
        return
    }
    $Sessions = @($matchedSessions)
}

# Narrowing selectors. These combine (logical AND) and apply AFTER index
# assignment, so the Index column stays stable regardless of which filters are
# active. They drive both the table preview and -Delete: eyeball the table,
# then re-run the identical command with -Delete added.
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

if ($Limit -gt 0) { $Sessions = $Sessions | Select-Object -First $Limit }

# ---- Delete ----------------------------------------------------------------

# Runs against the fully filtered/limited set. SupportsShouldProcess gives us
# -WhatIf and -Confirm for free; ConfirmImpact='High' means each file prompts
# unless the caller passes -Confirm:$false. Deletion is permanent (Remove-Item),
# so there is no Recycle Bin safety net - the prompt and the selector guard are.
if ($Delete) {
    if (@($Sessions).Count -eq 0) {
        Write-Warning 'No sessions matched the given filters; nothing to delete.'
        return
    }

    $deleted = 0
    foreach ($s in $Sessions) {
        $name   = if ($s.Session) { $s.Session } else { '(unnamed)' }
        $target = "[{0}] {1}  {2}  {3}KB  {4}" -f $s.Index, $s.Folder, $name, $s.Size, $s.File
        if ($PSCmdlet.ShouldProcess($target, 'Delete session transcript')) {
            try {
                Remove-Item -LiteralPath $s.FullPath -Force -ErrorAction Stop
                $deleted++
            } catch {
                Write-Error "Failed to delete $($s.FullPath): $_"
            }
        }
    }

    if ($WhatIfPreference) {
        Write-Output ("{0}-WhatIf: {1} session(s) would be deleted.{2}" -f $Cyan, @($Sessions).Count, $Reset)
    } else {
        Write-Output ("{0}Deleted {1} of {2} session(s).{3}" -f $Green, $deleted, @($Sessions).Count, $Reset)
    }
    return
}

# ---- Output ----------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Table') {
    $typeName = 'CCSession'

    # Load the sidecar format XML so PowerShell renders this type as a table
    # with our exact column widths, instead of falling back to Format-List
    # (which is the default once an object has 5+ public properties).
    $formatXml = Join-Path $PSScriptRoot 'Get-ClaudeCodeSessions.format.ps1xml'
    if (Test-Path $formatXml) {
        Update-FormatData -PrependPath $formatXml
    }

    foreach ($s in $Sessions) {
        $s.PSObject.TypeNames.Insert(0, $typeName)
        $s
    }
    return
}

$mode = $null; $n = 0
switch ($PSCmdlet.ParameterSetName) {
    'Prompt'      { $mode = 'Both';  $n = $Prompt }
    'PromptStart' { $mode = 'Start'; $n = $PromptStart }
    'PromptEnd'   { $mode = 'End';   $n = $PromptEnd }
}

foreach ($s in $Sessions) {
    $picked     = Select-TurnsForDisplay -Turns $s.Turns -Mode $mode -N $n
    $totalShown = $picked.First.Count + $picked.Last.Count

    $modeLabel = switch ($PSCmdlet.ParameterSetName) {
        'Prompt'      { 'Prompt (first+last)' }
        'PromptStart' { 'PromptStart' }
        'PromptEnd'   { 'PromptEnd' }
    }

    $headerLines = @(
        ('=' * 80),
        ("Index    : {0}" -f $s.Index),
        ("Folder   : {0}" -f $s.Folder),
        ("Session  : {0}" -f $s.Session),
        ("File     : {0}" -f $s.File),
        ("Modified : {0}" -f $s.Modified.ToString('yyyy-MM-dd HH:mm:ss')),
        ("Size     : {0}" -f $s.Size),
        ("Turns    : {0} of {1} (mode: {2}, N={3})" -f $totalShown, $picked.Total, $modeLabel, $n),
        ('-' * 80)
    )
    Write-Output ("{0}{1}{2}" -f $Green, ($headerLines -join "`n"), $Reset)

    if ($totalShown -eq 0) {
        Write-Output '(no matching turns)'
        Write-Output ''
        continue
    }

    foreach ($t in $picked.First) {
        Write-TurnBlock -Turn $t -MaxChars $PromptMaxChars
    }

    if ($picked.Omitted -gt 0 -and $picked.First.Count -gt 0 -and $picked.Last.Count -gt 0) {
        Write-Output ("{0}... [{1} turns omitted] ...{2}" -f $Dim, $picked.Omitted, $Reset)
        Write-Output ''
    }

    foreach ($t in $picked.Last) {
        Write-TurnBlock -Turn $t -MaxChars $PromptMaxChars
    }
}
