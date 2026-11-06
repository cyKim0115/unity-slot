<#
.SYNOPSIS
Open and close Unity editors for clone folders on demand, and show what is open.

.DESCRIPTION
  unity-slot.ps1 open      <clone|slot> [-TimeoutSec 300] [-StandbyWorkers 1] [-BuildTarget <platform>] [-NoWait]
  unity-slot.ps1 wait      <clone|slot> [-TimeoutSec 45]
  unity-slot.ps1 close     <clone|slot> [-TimeoutSec 240] [-AllowDirty]
  unity-slot.ps1 status    [-Json] [-ShowCommandLine]
  unity-slot.ps1 slots     [-Json]
  unity-slot.ps1 scan      [-Project <owner/repo>[,...]] [-ScanRoot <dir>[,...]] [-Apply]
  unity-slot.ps1 set       <slot> [-Purpose a,b] [-Mode hot|ondemand] [-AgentUse true|false] [-Memo <text>]
  unity-slot.ps1 acquire   <purpose|platform> [-Project <repo>] [-Owner <id>] [-Hours 8] [-NoOpen | -NoWait]
  unity-slot.ps1 release   <slot> [-Owner <id>] [-KeepOpen] [-AnyOwner]
  unity-slot.ps1 renew     <slot> [-Owner <id>] [-Hours 8]
  unity-slot.ps1 new-clone <purpose|platform> [-Project <repo>] [-From <slot>] [-Name <folder>]
                           [-CloneRoot <dir>] [-NoOpen] [-Apply]
  unity-slot.ps1 hooks     [<slot|clone> -HookEvent <event>]
  unity-slot.ps1 dashboard -Json [-Git basic|full]
  unity-slot.ps1 <extra command from the config> ...
  Any command: [-NoHooks] [-SkipHook <name>[,...]]

open      Picks Unity.exe for ProjectSettings/ProjectVersion.txt from the editor roots (stops if that
          version is not installed), does nothing if the clone is already open, launches the editor
          through WMI (Win32_Process.Create) so it runs outside the caller's app container and
          environment, and waits for the ##utp ProjectInfo line of that PID in <clone>\Logs\Editor.log.
          -BuildTarget never switches a clone that already has another platform.
          -NoWait returns right after launching; then call wait.
wait      One bounded look (-TimeoutSec, default 45) at a starting editor: READY, STARTING (exit 6),
          or stalled after 5 minutes (exit 2, with the window list).
close     Runs the beforeClose hooks, asks the main window to close (same as clicking X), waits,
          then reports what git sees as written by the close and which child processes still run.
status    Lists open editors with their child processes (import workers, compiler server, ...).
slots     The slot registry with each slot's state and lease (lib\registry.ps1).
scan      Detects version, branch, platform of clones under the scan roots and updates the registry.
set       Changes the user fields of a slot (purposes, mode, agent use, memo).
acquire   Leases a free slot that fits, then opens its editor (lib\lease.ps1). Exit 5: none free.
release   Closes the editor of an on-demand slot and drops the lease. Only the lease owner.
renew     Extends a lease.
new-clone Plans (dry run) or, with -Apply, makes a new clone slot (lib\newclone.ps1).
hooks     Shows the config file, the hooks per event and the extra commands; with a slot and
          -HookEvent it runs that event's hooks for the slot now (lib\config.ps1).
dashboard One read-only JSON document for widgets and agents (schema unity-slot.dashboard/1):
          slots with editor state, memory, lease and git, plus system, events and flags. Only the
          JSON goes to stdout; -Git full adds branch-level git numbers (lib\dashboard.ps1).

Every run refreshes <slot home>\install.json (where this script is, its version) and open, ready,
close, acquire, release, renew, takeover and refusals go to <slot home>\events.jsonl.

Settings (editor roots, scan roots, clone root, purposes, timeouts), hooks and extra commands come
from config.json next to this script or in %USERPROFILE%\.unity-slot (config.example.json).

Rules kept here (README.md has the reasons):
  - Never kills a process and never clicks a dialog button.
  - No scheduled tasks and no timers that close editors later.
  - Values after -accessToken and similar flags are masked whenever a command line or log line is printed.
  - Does not touch audio settings.
  - ASCII-only source: Windows PowerShell 5.1 reads BOM-less files with the ANSI code page.

Exit codes: 0 ok, 1 error, 2 timed out (editor left running), 3 editor version not installed,
            4 refused (lock held, a beforeClose hook, batchmode run, lease of someone else,
              platform switch, new-clone check failed), 5 no free slot, 6 still starting (wait).
#>
[CmdletBinding()]
param(
    # a built-in command (see above) or an extra command named in the config
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Command,

    # clone path (open, close), slot name or path (set, release, renew), purpose or platform (acquire, new-clone)
    [Parameter(Position = 1)]
    [Alias('Path')]
    [string]$Target,

    # 0 = default for the command (config "timeouts": open 300, close 240, wait 45)
    [int]$TimeoutSec = 0,

    # Passed as -standbyWorkerCount (idle import workers kept; Unity default 2). Negative = do not pass it.
    # Default: config "standbyWorkers" (1). 6000.6.0f1 rejects 0 ("Failed to set standby worker count to 0").
    [int]$StandbyWorkers = 1,

    # Folder with <version>\Editor\Unity.exe, tried before the config's "editorRoots".
    [string]$EditorRoot,

    # Python for .py hooks and extra commands. Default: config "python", $env:UNITY_SLOT_PYTHON, python on PATH.
    [string]$Python,

    # close even when a beforeClose hook refuses, e.g. unsaved scenes (Unity then shows its own save dialog).
    [switch]$AllowDirty,

    [switch]$Json,

    [switch]$ShowCommandLine,

    # open, set, new-clone: platform (Android, WebGL, Windows / StandaloneWindows64, iOS)
    [string]$BuildTarget,

    # registry and leases (scan takes several projects; acquire and new-clone use the first)
    [string[]]$Project,
    [string]$Owner,
    # lease length; default: config "leaseHours" (8)
    [double]$Hours = 8,
    [switch]$NoOpen,
    # open, acquire: return right after launching; then call wait until READY (MCP tools stay short)
    [switch]$NoWait,
    [switch]$KeepOpen,
    [switch]$AnyOwner,
    [string[]]$Purpose,
    [ValidateSet('hot', 'ondemand')]
    [string]$Mode,
    [ValidateSet('true', 'false')]
    [string]$AgentUse,
    [string]$Memo,
    [string[]]$ScanRoot,

    # new-clone
    [string]$From,
    [string]$Name,
    # where new-clone puts the clone; default: config "cloneRoot", else next to the template clone
    [string]$CloneRoot,

    # hooks: skip all of them, or the named ones
    [switch]$NoHooks,
    [string[]]$SkipHook,
    # hooks: the event to run now for one slot
    [string]$HookEvent,

    # dashboard: basic = each slot's git status; full = also local-only commits, branches, stash, worktrees
    [Alias('Git')]
    [ValidateSet('basic', 'full')]
    [string]$GitLevel = 'basic',

    # scan, new-clone (and some extra commands): without it they only show what they would do
    [switch]$Apply
)

$script:UnitySlotVersion = '0.4.0'
$script:ExitCode = 0
$script:LastOpenPid = 0
$script:PendingHooksFailed = $false
$script:LastCloseDetail = $null
$script:Bound = $PSBoundParameters
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:SecretFlags = 'accessToken|hubSessionId|cbmEditorLicense|cbmMachineId'

$script:SlotRepo = $PSScriptRoot
foreach ($lib in @('config', 'registry', 'lease', 'newclone', 'dashboard')) { . (Join-Path $PSScriptRoot ('lib\' + $lib + '.ps1')) }

# ------------------------------------------------------------------ output and masking

function Say([string]$Text) {
    Write-Host ('[{0}] {1}' -f $Command, $Text)
}

function Protect-Text([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $pattern = '(?i)("?-(?:' + $script:SecretFlags + ')"?\s+)("[^"]*"|\S+)'
    return [regex]::Replace($Text, $pattern, '$1***')
}

# Unity prints its command line one argument per line at the top of Editor.log,
# so the value sits on the line after the flag.
function Protect-LogLines([string[]]$Lines) {
    $flagOnly = '(?i)^\s*"?-(?:' + $script:SecretFlags + ')"?\s*$'
    $maskNext = $false
    foreach ($line in $Lines) {
        if ($maskNext) { '***'; $maskNext = $false; continue }
        if ($line -match $flagOnly) { $maskNext = $true }
        Protect-Text $line
    }
}

# Fixed-width table. Format-Table drops columns that do not fit the host width.
function Write-TextTable([string[]]$Header, $Rows) {
    $widths = @($Header | ForEach-Object { $_.Length })
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $Header.Count; $i++) { $widths[$i] = [math]::Max($widths[$i], ([string]$row[$i]).Length) }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((@(for ($i = 0; $i -lt $Header.Count; $i++) { $Header[$i].PadRight($widths[$i]) }) -join '  ').TrimEnd())
    $lines.Add((@(for ($i = 0; $i -lt $Header.Count; $i++) { '-' * $widths[$i] }) -join '  '))
    foreach ($row in $Rows) {
        $lines.Add((@(for ($i = 0; $i -lt $Header.Count; $i++) { ([string]$row[$i]).PadRight($widths[$i]) }) -join '  ').TrimEnd())
    }
    foreach ($l in $lines) { Write-Host $l }
}

function Format-Time($Date) {
    if ($null -eq $Date) { return '-' }
    return ([datetime]$Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)
}

function Format-Num([double]$Value) { return $Value.ToString('0.0', $script:Inv) }

function Format-GB([double]$Bytes) { return Format-Num ($Bytes / 1GB) }

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# ------------------------------------------------------------------ paths and project

function Get-NormPath([string]$P) {
    if ([string]::IsNullOrWhiteSpace($P)) { return $null }
    $q = $P.Trim().Trim('"').Replace('/', '\')
    try { $q = [IO.Path]::GetFullPath($q) } catch { }
    if ($q.Length -gt 3) { $q = $q.TrimEnd('\') }
    return $q
}

function Test-SamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals((Get-NormPath $A), (Get-NormPath $B), [StringComparison]::OrdinalIgnoreCase)
}

# Letter case as on disk, so Unity (and MCP names derived from the path) see what the Hub passes.
function Get-CanonicalPath([string]$Full) {
    $dir = New-Object IO.DirectoryInfo($Full)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    while ($null -ne $dir.Parent) {
        $name = $dir.Name
        try {
            $hit = @($dir.Parent.GetDirectories($name))
            if ($hit.Count -eq 1) { $name = $hit[0].Name }
        } catch { }
        $parts.Insert(0, $name)
        $dir = $dir.Parent
    }
    $root = $dir.FullName.ToUpperInvariant()
    if ($parts.Count -eq 0) { return $root }
    return [IO.Path]::Combine($root, ($parts -join '\'))
}

function Resolve-Clone([string]$P) {
    if ([string]::IsNullOrWhiteSpace($P)) { throw "usage: unity-slot.ps1 $Command <clone path>" }
    $full = Get-NormPath ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($P))
    if (-not (Test-Path -LiteralPath (Join-Path $full 'Assets') -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $full 'ProjectSettings') -PathType Container)) {
        throw "not a Unity project (Assets and ProjectSettings expected): $full"
    }
    return (Get-CanonicalPath $full)
}

function Get-EditorVersion([string]$Clone) {
    $file = Join-Path $Clone 'ProjectSettings\ProjectVersion.txt'
    if (-not (Test-Path -LiteralPath $file)) { throw "missing $file" }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*m_EditorVersion:\s*(\S+)') { return $Matches[1] }
    }
    throw "m_EditorVersion not found in $file"
}

# ------------------------------------------------------------------ processes

# Value after -Flag. The Hub writes -projectpath C:\x, import workers write "-projectPath" "C:/x".
function Get-CmdArg([string]$CommandLine, [string]$Flag) {
    $m = [regex]::Match($CommandLine, '(?i)(?:^|\s)"?-' + $Flag + '"?\s+(?:"([^"]*)"|([^\s"]+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

function Test-CmdFlag([string]$CommandLine, [string]$Flag) {
    return [regex]::IsMatch($CommandLine, '(?i)(?:^|\s)"?-' + $Flag + '"?(?:\s|$)')
}

function ConvertTo-UnityProc($P) {
    $cl = [string]$P.CommandLine
    $project = $null
    $projectArg = Get-CmdArg $cl 'projectPath'
    if ($projectArg) { $project = Get-NormPath $projectArg }
    $owner = 0
    $parentArg = Get-CmdArg $cl 'parentPid'
    if ($parentArg) { $kind = 'worker'; $owner = [int]$parentArg }
    elseif ($project -and (Test-CmdFlag $cl 'batchMode')) { $kind = 'batch' }
    elseif ($project) { $kind = 'editor' }
    else { $kind = 'other' }
    $launch = 'direct'
    if (Test-CmdFlag $cl 'useHub') { $launch = 'hub' }
    $standby = Get-CmdArg $cl 'standbyWorkerCount'
    if (-not $standby) { $standby = 'default' }
    return [pscustomobject]@{
        Pid          = [int]$P.ProcessId
        ParentPid    = [int]$P.ParentProcessId
        Kind         = $kind
        Owner        = $owner
        Project      = $project
        Started      = $P.CreationDate
        Launch       = $launch
        Standby      = $standby
        LogFile      = (Get-CmdArg $cl 'logFile')
        PrivateBytes = [double]$P.PrivatePageCount
        WorkingSet   = [double]$P.WorkingSetSize
        CommandLine  = $cl
    }
}

function Get-Snapshot {
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate, PrivatePageCount, WorkingSetSize)
    $byPid = @{}
    $children = @{}
    foreach ($p in $all) {
        $id = [int]$p.ProcessId
        $byPid[$id] = $p
        $parent = [int]$p.ParentProcessId
        if ($parent -eq $id) { continue }
        if (-not $children.ContainsKey($parent)) { $children[$parent] = New-Object 'System.Collections.Generic.List[object]' }
        $children[$parent].Add($p)
    }
    $unity = @($all | Where-Object { $_.Name -eq 'Unity.exe' } | ForEach-Object { ConvertTo-UnityProc $_ })
    return [pscustomobject]@{ ByPid = $byPid; Children = $children; Unity = $unity }
}

function Get-Descendants($Snap, [int]$RootPid) {
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $seen = @{}
    $queue.Enqueue($RootPid)
    $seen[$RootPid] = $true
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $Snap.Children.ContainsKey($cur)) { continue }
        $curProc = $Snap.ByPid[$cur]
        foreach ($c in $Snap.Children[$cur]) {
            $cid = [int]$c.ProcessId
            if ($seen.ContainsKey($cid)) { continue }
            # A child is never older than its parent; an older one only shares a reused parent id.
            if ($null -ne $curProc -and $null -ne $c.CreationDate -and $null -ne $curProc.CreationDate -and
                $c.CreationDate -lt $curProc.CreationDate) { continue }
            $seen[$cid] = $true
            $queue.Enqueue($cid)
            $c
        }
    }
}

function Get-Sum($Items, [string]$Property) {
    $total = 0.0
    foreach ($i in @($Items)) { if ($null -ne $i) { $total += [double]$i.$Property } }
    return $total
}

# Editor plus everything it started: import workers (Unity.exe -parentPid) and other children
# (dotnet compiler server, shader compilers, package manager, MCP servers, ...).
function Get-EditorTree($Snap, [int]$EditorPid) {
    $editor = $Snap.ByPid[$EditorPid]
    $desc = @(Get-Descendants $Snap $EditorPid)
    $workers = @($desc | Where-Object { $_.Name -eq 'Unity.exe' })
    $others = @($desc | Where-Object { $_.Name -ne 'Unity.exe' })
    $ePriv = 0.0
    $eWs = 0.0
    if ($null -ne $editor) { $ePriv = [double]$editor.PrivatePageCount; $eWs = [double]$editor.WorkingSetSize }
    $wPriv = Get-Sum $workers 'PrivatePageCount'
    $wWs = Get-Sum $workers 'WorkingSetSize'
    $oPriv = Get-Sum $others 'PrivatePageCount'
    $oWs = Get-Sum $others 'WorkingSetSize'
    return [pscustomobject]@{
        EditorPriv  = $ePriv
        EditorWs    = $eWs
        WorkerCount = $workers.Count
        WorkerPriv  = $wPriv
        WorkerWs    = $wWs
        OtherCount  = $others.Count
        OtherPriv   = $oPriv
        OtherWs     = $oWs
        TotalPriv   = $ePriv + $wPriv + $oPriv
        TotalWs     = $eWs + $wWs + $oWs
        Descendants = $desc
    }
}

function Get-OpenFor($Snap, [string]$Clone) {
    @($Snap.Unity | Where-Object { ($_.Kind -eq 'editor' -or $_.Kind -eq 'batch') -and (Test-SamePath $_.Project $Clone) })
}

# Pre-close children that still run, matched by pid and creation time (pids get reused).
# Takes an array: PowerShell 5.1 throws "Argument types do not match" on @($list) for a List[object] parameter.
function Get-Survivors([object[]]$Before) {
    $now = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, CreationDate, Name, PrivatePageCount)) {
        $now[[int]$p.ProcessId] = $p
    }
    foreach ($b in $Before) {
        $id = [int]$b.ProcessId
        if ($now.ContainsKey($id) -and $now[$id].CreationDate -eq $b.CreationDate) { $now[$id] }
    }
}

function Wait-Exit([int[]]$Pids, [datetime]$Deadline) {
    while ((Get-Date) -lt $Deadline) {
        $alive = @($Pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    $Pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ memory, lock, git, beacon

function Get-CommitInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property TotalVirtualMemorySize, FreeVirtualMemory, FreePhysicalMemory
    $limit = [double]$os.TotalVirtualMemorySize * 1KB
    $used = $limit - [double]$os.FreeVirtualMemory * 1KB
    return [pscustomobject]@{
        UsedGB         = [math]::Round($used / 1GB, 2)
        LimitGB        = [math]::Round($limit / 1GB, 2)
        Percent        = [math]::Round(100 * $used / $limit, 0)
        FreePhysicalGB = [math]::Round([double]$os.FreePhysicalMemory * 1KB / 1GB, 2)
    }
}

function Format-Commit($C) {
    return ('{0} / {1} GB ({2}%), free physical {3} GB' -f (Format-Num $C.UsedGB), (Format-Num $C.LimitGB), $C.Percent, (Format-Num $C.FreePhysicalGB))
}

# Unity keeps Temp\UnityLockfile open without sharing while the project is open.
function Get-LockState([string]$Clone) {
    $file = Join-Path $Clone 'Temp\UnityLockfile'
    if (-not (Test-Path -LiteralPath $file)) { return 'none' }
    try {
        $s = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $s.Dispose()
        return 'stale'
    } catch {
        return 'held'
    }
}

# --no-optional-locks: reading never takes the index lock an agent's git command may need.
function Invoke-Git([string]$Clone, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git --no-optional-locks -C $Clone -c core.quotepath=false @GitArgs 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-GitState([string]$Clone) {
    $raw = (@(Invoke-Git $Clone @('status', '--porcelain=v1', '-z', '--branch')) -join "`n")
    $branch = '(git status failed)'
    $changes = [ordered]@{}
    $fields = $raw.Split([char]0)
    for ($i = 0; $i -lt $fields.Length; $i++) {
        $f = $fields[$i]
        if ($f.StartsWith('## ')) { $branch = $f.Substring(3); continue }
        if ($f.Length -lt 4) { continue }
        $code = $f.Substring(0, 2)
        if ($code.StartsWith('R') -or $code.StartsWith('C')) { $i++ }   # next field is the old path
        $changes[$f.Substring(3)] = $code
    }
    return [pscustomobject]@{ Branch = $branch; Changes = $changes }
}

# Entries of $After that are new or have another status than in $Before, or whose file was written
# at or after $Since. Prints "XY path" lines.
function Get-GitDelta([string]$Clone, $Before, $After, [datetime]$Since) {
    foreach ($k in $After.Keys) {
        $code = $After[$k]
        $changed = (-not $Before.Contains($k)) -or ($Before[$k] -ne $code)
        $touched = $false
        if (-not $k.EndsWith('/')) {
            $full = Join-Path $Clone ($k.Replace('/', '\'))
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                try { $touched = ((Get-Item -LiteralPath $full -Force).LastWriteTime -ge $Since) } catch { }
            }
        }
        if ($changed -or $touched) { '{0} {1}' -f $code, $k }
    }
}

# open leaves the git state it saw in Logs\ (ignored by git, kept by Unity) so close can tell
# what changed while the editor was open, e.g. assets the editor re-serialized.
function Save-OpenSnapshot([string]$Clone, [int]$EditorPid, [datetime]$Time, $Git) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# unity-slot: git status when the editor was opened')
    $lines.Add('pid=' + $EditorPid)
    $lines.Add('time=' + $Time.ToString('o', $script:Inv))
    foreach ($k in $Git.Changes.Keys) { $lines.Add(('{0} {1}' -f $Git.Changes[$k], $k)) }
    [IO.File]::WriteAllLines((Join-Path $Clone 'Logs\unity-slot-open.txt'), $lines.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

function Read-OpenSnapshot([string]$Clone, [int]$EditorPid) {
    $file = Join-Path $Clone 'Logs\unity-slot-open.txt'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $snapPid = 0
    $time = $null
    $changes = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith('pid=')) { $snapPid = [int]$line.Substring(4); continue }
        if ($line.StartsWith('time=')) {
            $time = [datetime]::Parse($line.Substring(5), $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind)
            continue
        }
        if ($line -match '^[A-Za-z]+=') { continue }   # ready=, readySeconds= (lib\dashboard.ps1)
        if ($line.Length -ge 4) { $changes[$line.Substring(3)] = $line.Substring(0, 2) }
    }
    if ($snapPid -ne $EditorPid -or $null -eq $time) { return $null }
    return [pscustomobject]@{ Time = $time; Changes = $changes }
}

function Write-List($Items, [int]$Max = 60) {
    $all = @($Items)
    foreach ($i in ($all | Select-Object -First $Max)) { Say ('  ' + $i) }
    if ($all.Count -gt $Max) { Say ('  ... {0} more' -f ($all.Count - $Max)) }
}

# ------------------------------------------------------------------ log reading

function New-LogReader([string]$File) {
    return @{ File = $File; Pos = [long]0; Rest = ''; Decoder = [Text.Encoding]::UTF8.GetDecoder() }
}

# New complete lines since the last call.
function Read-NewLogLines($Reader) {
    if (-not (Test-Path -LiteralPath $Reader.File)) { return }
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($Reader.File, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($fs.Length -lt $Reader.Pos) {
            $Reader.Pos = [long]0; $Reader.Rest = ''; $Reader.Decoder = [Text.Encoding]::UTF8.GetDecoder()
        }
        $count = [int][math]::Min([long]($fs.Length - $Reader.Pos), [long]16MB)
        if ($count -le 0) { return }
        [void]$fs.Seek($Reader.Pos, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $Reader.Pos += $read
        $chars = New-Object char[] ($Reader.Decoder.GetCharCount($buf, 0, $read))
        $n = $Reader.Decoder.GetChars($buf, 0, $read, $chars, 0)
        $parts = ($Reader.Rest + [string]::new($chars, 0, $n)) -split "`r?`n"
        $Reader.Rest = $parts[$parts.Count - 1]
        for ($i = 0; $i -lt $parts.Count - 1; $i++) { $parts[$i] }
    } catch [IO.IOException] {
        return
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

# Last lines of a log, masked. Small files are read whole so a flag line is never cut from its value.
function Get-LogTail([string]$File, [int]$Count) {
    if (-not (Test-Path -LiteralPath $File)) { return }
    $fs = New-Object IO.FileStream($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $take = [long]65536
        if ($fs.Length -le 1MB) { $take = $fs.Length }
        $start = $fs.Length - $take
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]$take)
        $read = $fs.Read($buf, 0, [int]$take)
    } finally {
        $fs.Dispose()
    }
    $lines = @([Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`r?`n")
    if ($start -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    $lines = @(Protect-LogLines @($lines | Where-Object { $_.Trim() -ne '' }))
    $lines | Select-Object -Last $Count
}

function Get-ProjectInfo([string]$Line, [int]$EditorPid) {
    $i = $Line.IndexOf('##utp:')
    if ($i -lt 0) { return $null }
    $text = $Line.Substring($i + 6).Trim()
    if ($text.IndexOf('"ProjectInfo"') -lt 0) { return $null }
    try { $obj = $text | ConvertFrom-Json } catch { return $null }
    if ((Get-Prop $obj 'type') -ne 'ProjectInfo') { return $null }
    if ([int](Get-Prop $obj 'processId') -ne $EditorPid) { return $null }
    return $obj
}

# ------------------------------------------------------------------ dialogs (look only)

$script:WindowListerSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace UnitySlot {
    public static class WindowLister {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);

        private static string Text(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
        private static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }

        // Visible top-level windows of one process with their buttons and static texts.
        // GetWindowText does not block on a hung window of another process.
        public static string[] Describe(int pid) {
            var lines = new List<string>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner != (uint)pid || !IsWindowVisible(h)) return true;
                var buttons = new List<string>();
                var texts = new List<string>();
                EnumChildWindows(h, delegate (IntPtr c, IntPtr l2) {
                    string cls = Cls(c).ToLowerInvariant();
                    string t = Text(c);
                    if (cls == "button" && t.Length > 0) buttons.Add(t.Replace("&", ""));
                    else if (cls == "static" && t.Trim().Length > 0) texts.Add(t.Trim());
                    else if (cls == "msctls_progress32") texts.Add("(progress bar)");
                    return true;
                }, IntPtr.Zero);
                string line = "class=" + Cls(h) + " title=\"" + Text(h) + "\"";
                if (buttons.Count > 0) line += " buttons=[" + string.Join(", ", buttons.ToArray()) + "]";
                if (texts.Count > 0) line += " text=\"" + string.Join(" | ", texts.ToArray()) + "\"";
                lines.Add(line);
                return true;
            }, IntPtr.Zero);
            return lines.ToArray();
        }
    }
}
'@

function Get-ProcessWindows([int]$ProcId) {
    if (-not ('UnitySlot.WindowLister' -as [type])) {
        Add-Type -TypeDefinition $script:WindowListerSource -Language CSharp
    }
    [UnitySlot.WindowLister]::Describe($ProcId)
}

function Find-Python {
    if ($Python) { return $Python }
    $configured = [string](Get-Setting 'python')
    if ($configured) { return (Expand-SlotText $configured $null) }
    if ($env:UNITY_SLOT_PYTHON) { return $env:UNITY_SLOT_PYTHON }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

# Lists what the editor is showing (titles, buttons, texts). Never clicks anything.
# Project-specific dialog tools belong in the openStalled / closeStalled hooks.
function Show-EditorWindows([string]$Clone, [int]$EditorPid) {
    Say "windows of pid $EditorPid (look only, nothing is clicked):"
    $wins = @()
    try { $wins = @(Get-ProcessWindows $EditorPid) } catch { $wins = @('window list failed: ' + $_.Exception.Message) }
    if ($wins.Count -eq 0) { Say '  (no visible window)' }
    foreach ($w in $wins) { Say ('  ' + (Protect-Text $w)) }
}

# Folders that hold <version>\Editor\Unity.exe: -EditorRoot, the config's "editorRoots", then the
# Hub's custom install folder (%APPDATA%\UnityHub\secondaryInstallPath.json).
function Get-EditorRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    if ($EditorRoot) { $roots.Add($EditorRoot) }
    foreach ($r in @(Get-ExpandedList (Get-Setting 'editorRoots'))) { $roots.Add($r) }
    $hubFile = Join-Path $env:APPDATA 'UnityHub\secondaryInstallPath.json'
    if (Test-Path -LiteralPath $hubFile -PathType Leaf) {
        try {
            $p = ([IO.File]::ReadAllText($hubFile, [Text.Encoding]::UTF8)).Trim().Trim('"').Replace('\\', '\')
            if ($p) { $roots.Add($p) }
        } catch { }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $roots) { if ($r -and $seen.Add((Get-NormPath $r))) { Get-NormPath $r } }
}

function Find-EditorExe([string]$Version) {
    foreach ($r in @(Get-EditorRoots)) {
        $exe = Join-Path $r (Join-Path $Version 'Editor\Unity.exe')
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    }
    return $null
}

# ------------------------------------------------------------------ commands

function Invoke-Open([string]$ClonePath, [int]$Timeout = 0, [string]$BuildTargetName = '', [bool]$NoWaitMode = $false) {
    $clone = Resolve-Clone $ClonePath
    $timeout = Get-TimeoutSetting 'open' 300
    if ($Timeout -gt 0) { $timeout = $Timeout }
    $version = Get-EditorVersion $clone
    $exe = Find-EditorExe $version
    Say "clone   $clone"
    Say "version $version"
    if (-not $exe) {
        $roots = @(Get-EditorRoots)
        Say ('STOP: Unity {0} is not installed under the editor roots ({1}).' -f $version, ($roots -join '; '))
        $installed = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Editor\Unity.exe') } | ForEach-Object { $_.Name } | Select-Object -Unique)
        Say ('installed: ' + ($installed -join ', '))
        Say 'Opening with another version upgrades the project and reimports it. Ask the user. (Other install folders: "editorRoots" in the config or -EditorRoot.)'
        $script:ExitCode = 3
        return
    }

    $snap = Get-Snapshot
    $open = @(Get-OpenFor $snap $clone)
    $batch = @($open | Where-Object { $_.Kind -eq 'batch' })
    if ($batch.Count -gt 0) {
        Say ('BUSY: batchmode Unity pid {0} is using this clone. Wait until it quits.' -f (($batch | ForEach-Object { $_.Pid }) -join ', '))
        Write-SlotEvent 'refused' $clone $batch[0].Pid ([ordered]@{ command = 'open'; reason = 'batchmode run' })
        $script:ExitCode = 4
        return
    }
    if ($open.Count -gt 0) {
        foreach ($e in $open) {
            $tree = Get-EditorTree $snap $e.Pid
            Say ('ALREADY OPEN pid {0} since {1} ({2} launch), {3} import worker(s). Use this editor.' -f $e.Pid, (Format-Time $e.Started), $e.Launch, $tree.WorkerCount)
            $script:LastOpenPid = $e.Pid
        }
        return
    }
    # Never switch a clone to another platform: that reimports everything. Pick a fitting slot.
    $targetArg = ''
    if ($BuildTargetName) {
        $wanted = ConvertTo-PlatformName $BuildTargetName
        $current = Get-PlatformFromLibrary $clone
        if ($current -and $current -ne $wanted) {
            Say ('REFUSED: this clone opens as {0}. -BuildTarget {1} would switch the platform and reimport everything. Use a {1} slot or ask the user.' -f $current, $wanted)
            Write-SlotEvent 'refused' $clone 0 ([ordered]@{ command = 'open'; reason = 'platform switch'; platform = $current; wanted = $wanted })
            $script:ExitCode = 4
            return
        }
        $targetArg = Get-BuildTargetName $wanted
    }
    $lock = Get-LockState $clone
    if ($lock -eq 'held') {
        Say 'STOP: Temp\UnityLockfile is held, but no Unity.exe has this clone as -projectPath. Not opening; check Task Manager.'
        Write-SlotEvent 'refused' $clone 0 ([ordered]@{ command = 'open'; reason = 'lock held' })
        $script:ExitCode = 4
        return
    }
    if ($lock -eq 'stale') { Say 'note    stale Temp\UnityLockfile (last editor did not exit cleanly); Unity takes it over' }

    $git = Get-GitState $clone
    Say ('git     {0}; {1} changed entr(ies). Pull or switch branches while closed, not after opening.' -f $git.Branch, $git.Changes.Count)
    Say ('commit  {0}' -f (Format-Commit (Get-CommitInfo)))

    # Keep the previous log the way Unity does for its default log.
    $logDir = Join-Path $clone 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir) }
    $log = Join-Path $logDir 'Editor.log'
    if (Test-Path -LiteralPath $log) {
        try { Move-Item -LiteralPath $log -Destination (Join-Path $logDir 'Editor-prev.log') -Force }
        catch { Say ('note    could not move the old Editor.log aside ({0}); Unity overwrites it' -f $_.Exception.Message) }
    }

    $cmdLine = '"{0}" -projectPath "{1}" -logFile "{2}"' -f $exe, $clone, $log
    $standby = $StandbyWorkers
    if (-not $script:Bound.ContainsKey('StandbyWorkers')) {
        $configured = Get-Setting 'standbyWorkers'
        if ($null -ne $configured) { $standby = [int]$configured }
    }
    if ($standby -ge 0) { $cmdLine += ' -standbyWorkerCount {0}' -f $standby }
    if ($targetArg) { $cmdLine += ' -buildTarget {0}' -f $targetArg }
    # WMI starts the editor outside this shell: no app-container file/registry redirection
    # (the Claude desktop app's shell is one) and none of this shell's environment variables.
    $t0 = Get-Date
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $clone }
    if ($r.ReturnValue -ne 0) {
        Say ('ERROR: Win32_Process.Create returned {0}' -f $r.ReturnValue)
        $script:ExitCode = 1
        return
    }
    $editorPid = [int]$r.ProcessId
    $script:LastOpenPid = $editorPid
    Say ('started pid {0} at {1}: {2}' -f $editorPid, (Format-Time $t0), (Protect-Text $cmdLine))
    try { Save-OpenSnapshot $clone $editorPid $t0 $git }
    catch { Say ('note    could not save Logs\unity-slot-open.txt ({0}); close will only compare the close itself' -f $_.Exception.Message) }
    Write-SlotEvent 'open' $clone $editorPid ([ordered]@{ standby = $standby; buildTarget = $(if ($targetArg) { $targetArg } else { $null }) })

    if ($NoWaitMode) {
        Say ('STARTED pid {0}; not waiting here. Run "unity-slot wait {1}" until it says READY (12 s to a few minutes).' -f $editorPid, $clone)
        return
    }
    $state = Wait-EditorReady $clone $editorPid $log $t0 $t0.AddSeconds($timeout)
    if ($state -eq 'exited') { $script:ExitCode = 1; return }
    if ($state -eq 'pending') {
        Say ('TIMEOUT: pid {0} not ready after {1}s. The editor is left running (not killed).' -f $editorPid, $timeout)
        Show-StartupStall $clone $editorPid $log
        $script:ExitCode = 2
    }
}

function Show-StartupStall([string]$Clone, [int]$EditorPid, [string]$Log) {
    Say 'last log lines:'
    foreach ($l in @(Get-LogTail $Log 15)) { Say ('  ' + $l) }
    Show-EditorWindows $Clone $EditorPid
    $null = Invoke-SlotHooks 'openStalled' (Get-HookVars $Clone $EditorPid $Log)
    Say 'Hand this to the user. Do not press dialog buttons from a script.'
}

# Waits until $Deadline for the ##utp ProjectInfo line of $EditorPid in $Log (read from the start).
# Returns 'ready', 'exited' or 'pending', after printing what it saw. $Started = editor process start.
function Wait-EditorReady([string]$Clone, [int]$EditorPid, [string]$Log, [datetime]$Started, [datetime]$Deadline) {
    $reader = New-LogReader $Log
    $info = $null
    $loadedAt = $null
    $licenseLine = $null
    $standbyNote = $null
    $nextNote = [int]((Get-Date) - $Started).TotalSeconds + 30
    while ($true) {
        foreach ($line in @(Read-NewLogLines $reader)) {
            if ($null -eq $licenseLine -and $line -match '^\[Licensing::') {
                if ($line -match '(?i)success|error|fail|not ') { $licenseLine = $line; Say ('license ' + (Protect-Text $line)) }
            }
            # Unity prints this when it rejects the value (6000.6.0f1: 0 is rejected, 1 is accepted).
            if ($null -eq $standbyNote -and $line -match '^Failed to set standby worker count') {
                $standbyNote = $line
                Say ('note    Unity: "{0}" - the -standbyWorkerCount argument did not apply' -f $line.Trim())
            }
            if ($null -eq $loadedAt -and $line -match '^\[Project\] Loading completed') { $loadedAt = Get-Date }
            $info = Get-ProjectInfo $line $EditorPid
            if ($null -ne $info) { break }
        }
        if ($null -ne $info) { break }
        # Older editors may not print ##utp; accept [Project] Loading completed after a grace period.
        if ($null -ne $loadedAt -and ((Get-Date) - $loadedAt).TotalSeconds -ge 15) { break }
        $elapsed = ((Get-Date) - $Started).TotalSeconds
        if ($null -eq (Get-Process -Id $EditorPid -ErrorAction SilentlyContinue)) {
            Say ('EXITED: pid {0} ended {1}s after start, before it was ready. Last log lines:' -f $EditorPid, (Format-Num $elapsed))
            foreach ($l in @(Get-LogTail $Log 25)) { Say ('  ' + $l) }
            return 'exited'
        }
        if ((Get-Date) -ge $Deadline) { return 'pending' }
        if ($elapsed -ge $nextNote) { Say ('waiting {0}s ...' -f [int]$elapsed); $nextNote += 30 }
        Start-Sleep -Milliseconds 1000
    }

    # When the line was written (its "time" is Unix ms), not when we read it: wait may come late.
    $readyAt = Get-Date
    if ($null -ne $info) {
        $ms = Get-Prop $info 'time'
        if ($ms) { $readyAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime }
    }
    $wall = ($readyAt - $Started).TotalSeconds
    if ($null -ne $info) {
        Say ('READY pid {0} {1}s after start. Unity projectLoad {2}s (assetDatabaseRefresh {3}s, assembliesLoad {4}s, sceneOpening {5}s)' -f `
            $EditorPid, (Format-Num $wall), (Format-Num (Get-Prop $info 'projectLoad')), (Format-Num (Get-Prop $info 'assetDatabaseRefresh')),
            (Format-Num (Get-Prop $info 'assembliesLoad')), (Format-Num (Get-Prop $info 'sceneOpening')))
    } else {
        Say ('READY pid {0} {1}s after start ([Project] Loading completed; no ##utp ProjectInfo line)' -f $EditorPid, (Format-Num $wall))
    }
    $script:LastOpenPid = $EditorPid
    # the first READY of an editor unity-slot started: kept next to its open snapshot, logged once
    if (Add-OpenSnapshotReady $Clone $EditorPid $readyAt $wall) {
        Write-SlotEvent 'ready' $Clone $EditorPid ([ordered]@{ readySeconds = [math]::Round($wall, 1) })
    }
    $tree = Get-EditorTree (Get-Snapshot) $EditorPid
    Say ('now     {0} import worker(s), {1} other child process(es); editor tree private {2} GB / ws {3} GB' -f `
        $tree.WorkerCount, $tree.OtherCount, (Format-GB $tree.TotalPriv), (Format-GB $tree.TotalWs))
    Say ('commit  {0}' -f (Format-Commit (Get-CommitInfo)))
    Invoke-PendingHooks $Clone $EditorPid $Log
    Say 'next    check through MCP that Application.dataPath is this clone before writing anything'
    return 'ready'
}

# One bounded look at an editor that is starting: READY, still STARTING (exit 6), stalled (exit 2).
function Invoke-Wait([string]$ClonePath, [int]$Timeout = 0) {
    $clone = Resolve-Clone $ClonePath
    $limit = Get-TimeoutSetting 'wait' 45
    if ($Timeout -gt 0) { $limit = $Timeout }
    Say "clone   $clone"
    $editors = @(Get-OpenFor (Get-Snapshot) $clone | Where-Object { $_.Kind -eq 'editor' })
    $log = Join-Path $clone 'Logs\Editor.log'
    if ($editors.Count -eq 0) {
        Say 'NOT RUNNING: no editor has this clone open. Start it with open or acquire.'
        if ((Test-Path -LiteralPath $log) -and ((Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime).TotalMinutes -lt 10) {
            Say 'last log lines:'
            foreach ($l in @(Get-LogTail $log 15)) { Say ('  ' + $l) }
        }
        $script:ExitCode = 1
        return
    }
    $e = $editors[0]
    $started = [datetime]$e.Started
    $logArg = Get-CmdArg $e.CommandLine 'logFile'
    if ($logArg) { $log = Get-NormPath $logArg }
    if (-not $logArg -and (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).LastWriteTime -lt $started)) {
        Say ('READY? pid {0} was not started by unity-slot and has no log to check; running since {1}.' -f $e.Pid, (Format-Time $started))
        return
    }
    $state = Wait-EditorReady $clone $e.Pid $log $started (Get-Date).AddSeconds($limit)
    if ($state -eq 'ready') { return }
    if ($state -eq 'exited') { $script:ExitCode = 1; return }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    if ($elapsed -ge (Get-TimeoutSetting 'stalled' 300)) {
        Say ('STALLED?: pid {0} is not ready {1}s after start (a warm open takes seconds, a cold import much longer). Left running.' -f $e.Pid, [int]$elapsed)
        Show-StartupStall $clone $e.Pid $log
        $script:ExitCode = 2
        return
    }
    Say ('STARTING: pid {0} not ready yet, {1}s after start. Call wait again.' -f $e.Pid, [int]$elapsed)
    $script:ExitCode = 6
}

# open, close and wait take a slot name as well as a clone path.
function Resolve-TargetPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    try {
        $slot = Find-SlotByName (Read-Registry) $Value.Trim()
        if ($null -ne $slot) { return $slot.path }
    } catch { }
    return $Value
}

function Invoke-Close([string]$ClonePath) {
    $clone = Resolve-Clone $ClonePath
    $timeout = Get-TimeoutSetting 'close' 240
    if ($TimeoutSec -gt 0) { $timeout = $TimeoutSec }
    Say "clone   $clone"
    $snap = Get-Snapshot
    $open = @(Get-OpenFor $snap $clone)
    if ($open.Count -eq 0) {
        Say 'NOT OPEN: no Unity.exe has this clone as -projectPath'
        if ((Get-LockState $clone) -eq 'held') { Say 'note    Temp\UnityLockfile is held by some process anyway; check Task Manager' }
        return
    }
    $batch = @($open | Where-Object { $_.Kind -eq 'batch' })
    if ($batch.Count -gt 0) {
        Say ('REFUSED: batchmode Unity pid {0} is working on this clone. It quits by itself; not touching it.' -f (($batch | ForEach-Object { $_.Pid }) -join ', '))
        Write-SlotEvent 'refused' $clone $batch[0].Pid ([ordered]@{ command = 'close'; reason = 'batchmode run' })
        $script:ExitCode = 4
        return
    }
    # beforeClose hooks may refuse, e.g. a hook that sees unsaved scenes.
    foreach ($e in $open) {
        $hookLog = ''
        if ($e.LogFile) { $hookLog = Get-NormPath $e.LogFile }
        $check = Invoke-SlotHooks 'beforeClose' (Get-HookVars $clone $e.Pid $hookLog)
        if ($check.Refused.Count -gt 0) {
            if ($AllowDirty) {
                Say ('note    beforeClose refused ({0}); closing anyway (-AllowDirty). Unity shows its own save dialog if something is unsaved.' -f ($check.Refused -join ', '))
                continue
            }
            Say ('REFUSED: beforeClose hook {0} says not to close now (see above). Save or discard first, or ask the user.' -f ($check.Refused -join ', '))
            Say '         -AllowDirty sends the close anyway; Unity then shows its save dialog and stays open.'
            Write-SlotEvent 'refused' $clone $e.Pid ([ordered]@{ command = 'close'; reason = 'beforeClose'; hooks = [string[]]@($check.Refused) })
            $script:ExitCode = 4
            return
        }
    }

    $gitBefore = Get-GitState $clone
    $commitBefore = Get-CommitInfo
    $children = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $open) {
        $tree = Get-EditorTree $snap $e.Pid
        foreach ($d in @($tree.Descendants)) { $children.Add($d) }
        Say ('before  pid {0}: {1} import worker(s), {2} other child process(es); private {3} GB / ws {4} GB' -f `
            $e.Pid, $tree.WorkerCount, $tree.OtherCount, (Format-GB $tree.TotalPriv), (Format-GB $tree.TotalWs))
    }
    Say ('commit  {0}' -f (Format-Commit $commitBefore))

    $t0 = Get-Date
    foreach ($e in $open) {
        $proc = Get-Process -Id $e.Pid -ErrorAction SilentlyContinue
        $sent = $false
        if ($null -ne $proc) { $sent = $proc.CloseMainWindow() }
        if ($sent) { Say ('close requested for pid {0} (same as clicking X)' -f $e.Pid) }
        else { Say ('could not request close for pid {0}: no main window' -f $e.Pid) }
    }
    $left = @(Wait-Exit ([int[]]@($open | ForEach-Object { $_.Pid })) $t0.AddSeconds($timeout))
    if ($left.Count -gt 0) {
        foreach ($id in $left) {
            Say ('STILL OPEN pid {0} after {1}s. Not killed.' -f $id, $timeout)
            Show-EditorWindows $clone $id
            $null = Invoke-SlotHooks 'closeStalled' (Get-HookVars $clone $id)
        }
        Say 'A save dialog or a long save is the usual cause. Hand it to the user; do not click from a script.'
        $script:ExitCode = 2
        return
    }
    $closeSeconds = ((Get-Date) - $t0).TotalSeconds
    Say ('CLOSED after {0}s' -f (Format-Num $closeSeconds))

    # Import workers, the compiler server and MCP servers normally follow within seconds.
    $until = (Get-Date).AddSeconds(30)
    $survivors = @(Get-Survivors $children.ToArray())
    while ($survivors.Count -gt 0 -and (Get-Date) -lt $until) {
        Start-Sleep -Seconds 2
        $survivors = @(Get-Survivors $children.ToArray())
    }
    if ($survivors.Count -eq 0) { Say ('children all {0} child process(es) exited' -f $children.Count) }
    else {
        Say ('children {0} of {1} still running 30s after the close (not killed):' -f $survivors.Count, $children.Count)
        foreach ($s in $survivors) { Say ('  {0} pid {1}, private {2} GB' -f $s.Name, $s.ProcessId, (Format-GB $s.PrivatePageCount)) }
    }
    if ((Get-LockState $clone) -eq 'held') { Say 'note    Temp\UnityLockfile is still held' }

    # What the close wrote (compared with just before the close request), then what changed since
    # unity-slot opened this editor. Reported only: nothing is reverted.
    $gitAfter = Get-GitState $clone
    $written = @(Get-GitDelta $clone $gitBefore.Changes $gitAfter.Changes $t0)
    if ($written.Count -eq 0 -and $gitAfter.Changes.Count -eq 0) {
        Say 'git     nothing written by the close (working tree clean)'
    } elseif ($written.Count -eq 0) {
        Say ('git     nothing written by the close ({0} changed entr(ies), all from before)' -f $gitAfter.Changes.Count)
    } else {
        Say ('git     {0} entr(ies) written or changed by the close:' -f $written.Count)
        Write-List $written
    }
    $openSnap = Read-OpenSnapshot $clone $open[0].Pid
    $since = @()
    if ($null -eq $openSnap) {
        Say 'git     no unity-slot open snapshot for this pid; changes made while it was open are not separated'
    } else {
        $since = @(Get-GitDelta $clone $openSnap.Changes $gitAfter.Changes $openSnap.Time)
        if ($since.Count -eq 0) {
            Say ('git     nothing changed since open at {0}' -f (Format-Time $openSnap.Time))
        } else {
            Say ('git     {0} entr(ies) new or changed since open at {1} (re-serialized by the editor or edited):' -f $since.Count, (Format-Time $openSnap.Time))
            Write-List $since
        }
    }
    if ($written.Count -gt 0 -or $since.Count -gt 0) { Say 'git     reported only; review before committing. unity-slot never reverts files.' }
    $commitAfter = Get-CommitInfo
    Say ('commit  {0}; change {1} GB' -f (Format-Commit $commitAfter), (Format-Num ($commitAfter.UsedGB - $commitBefore.UsedGB)))
    $paths = @(@($written) + @($since) | ForEach-Object { ([string]$_).Substring(3) } | Select-Object -Unique)
    $script:LastCloseDetail = [ordered]@{
        closeSeconds  = [math]::Round($closeSeconds, 1)
        commitDeltaGB = [math]::Round($commitAfter.UsedGB - $commitBefore.UsedGB, 2)
        changedFiles  = $paths.Count
    }
    Write-SlotEvent 'close' $clone $open[0].Pid $script:LastCloseDetail
    $null = Invoke-SlotHooks 'afterClose' (Get-HookVars $clone $open[0].Pid)
}

function Invoke-Status {
    $snap = Get-Snapshot
    $commit = Get-CommitInfo
    $editors = @($snap.Unity | Where-Object { $_.Kind -eq 'editor' -or $_.Kind -eq 'batch' } | Sort-Object { $_.Started })
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $editors) {
        $t = Get-EditorTree $snap $e.Pid
        $rows.Add([pscustomobject]@{
            Project        = $e.Project
            Pid            = $e.Pid
            Kind           = $e.Kind
            Started        = (Format-Time $e.Started)
            Launch         = $e.Launch
            Standby        = $e.Standby
            Workers        = $t.WorkerCount
            Children       = $t.OtherCount
            EditorPrivGB   = [math]::Round($t.EditorPriv / 1GB, 2)
            EditorWsGB     = [math]::Round($t.EditorWs / 1GB, 2)
            WorkersPrivGB  = [math]::Round($t.WorkerPriv / 1GB, 2)
            WorkersWsGB    = [math]::Round($t.WorkerWs / 1GB, 2)
            ChildrenPrivGB = [math]::Round($t.OtherPriv / 1GB, 2)
            ChildrenWsGB   = [math]::Round($t.OtherWs / 1GB, 2)
            TotalPrivGB    = [math]::Round($t.TotalPriv / 1GB, 2)
            TotalWsGB      = [math]::Round($t.TotalWs / 1GB, 2)
        })
    }
    $live = @{}
    foreach ($e in $editors) { $live[$e.Pid] = $true }
    $orphans = @($snap.Unity | Where-Object { $_.Kind -eq 'worker' -and -not $live.ContainsKey($_.Owner) })

    if ($Json) {
        [pscustomobject]@{
            Time          = (Format-Time (Get-Date))
            Commit        = $commit
            Editors       = $rows.ToArray()
            OrphanWorkers = @($orphans | ForEach-Object {
                [pscustomobject]@{ Pid = $_.Pid; Owner = $_.Owner; Project = $_.Project; PrivGB = [math]::Round($_.PrivateBytes / 1GB, 2) }
            })
        } | ConvertTo-Json -Depth 4
        return
    }

    if ($rows.Count -eq 0) {
        Say 'no Unity editor is open'
    } else {
        $header = @('Pid', 'Kind', 'Started', 'Launch', 'Standby', 'Workers', 'Children', 'Editor GB', 'Workers GB', 'Children GB', 'Total GB', 'Project')
        $cells = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in $rows) {
            $cells.Add(@([string]$r.Pid, $r.Kind, $r.Started, $r.Launch, $r.Standby, [string]$r.Workers, [string]$r.Children,
                ('{0}/{1}' -f (Format-Num $r.EditorPrivGB), (Format-Num $r.EditorWsGB)),
                ('{0}/{1}' -f (Format-Num $r.WorkersPrivGB), (Format-Num $r.WorkersWsGB)),
                ('{0}/{1}' -f (Format-Num $r.ChildrenPrivGB), (Format-Num $r.ChildrenWsGB)),
                ('{0}/{1}' -f (Format-Num $r.TotalPrivGB), (Format-Num $r.TotalWsGB)),
                $r.Project))
        }
        Write-TextTable $header $cells
        Say 'GB columns are private/working set; Workers = import workers, Children = every other process the editor started'
        $sumPriv = ($rows | Measure-Object TotalPrivGB -Sum).Sum
        $sumWs = ($rows | Measure-Object TotalWsGB -Sum).Sum
        $sumWorkers = ($rows | Measure-Object Workers -Sum).Sum
        Say ('total   {0} editor(s), {1} import worker(s), private {2} GB / ws {3} GB' -f $rows.Count, $sumWorkers, (Format-Num $sumPriv), (Format-Num $sumWs))
    }
    if ($orphans.Count -gt 0) {
        Say ('orphan  {0} import worker(s) whose editor is gone: pid {1}' -f $orphans.Count, (($orphans | ForEach-Object { $_.Pid }) -join ', '))
    }
    Say ('commit  {0}' -f (Format-Commit $commit))
    if ($ShowCommandLine) {
        foreach ($e in $editors) { Say ('cmd     pid {0}: {1}' -f $e.Pid, (Protect-Text $e.CommandLine)) }
    }
}

# ------------------------------------------------------------------ main

# Dot-sourced (tests): load the functions only, without changing the caller's session settings.
if ($MyInvocation.InvocationName -eq '.') { return }

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$prevEncoding = $null
try {
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
} catch {
    $prevEncoding = $null
}
try {
    Update-InstallPointer
    switch ($Command) {
        'dashboard' { Invoke-Dashboard }
        'open' { Invoke-Open (Resolve-TargetPath $Target) $TimeoutSec $BuildTarget $NoWait.IsPresent }
        'wait' { Invoke-Wait (Resolve-TargetPath $Target) $TimeoutSec }
        'close' { Invoke-Close (Resolve-TargetPath $Target) }
        'status' { Invoke-Status }
        'slots' { Invoke-Slots }
        'scan' { Invoke-Scan }
        'set' { Invoke-Set }
        'acquire' { Invoke-Acquire }
        'release' { Invoke-Release }
        'renew' { Invoke-Renew }
        'new-clone' { Invoke-NewClone }
        'hooks' { Invoke-Hooks }
        default {
            # an extra command from the config: dot-source its file here (script scope), then call it
            $extra = Get-ExtraCommand $Command
            if ($null -eq $extra) {
                throw ('unknown command "{0}". Commands: {1}' -f $Command, ((@($script:BuiltinCommands) + @(Get-ExtraCommandNames)) -join ', '))
            }
            . $extra.Script
            & $extra.Function
        }
    }
} catch {
    # dashboard keeps stdout for its JSON only
    if ($Command -eq 'dashboard') { [Console]::Error.WriteLine('ERROR: ' + (Protect-Text $_.Exception.Message)) }
    else { Say ('ERROR: ' + (Protect-Text $_.Exception.Message)) }
    $script:ExitCode = 1
} finally {
    if ($null -ne $prevEncoding) { try { [Console]::OutputEncoding = $prevEncoding } catch { } }
}
exit $script:ExitCode
