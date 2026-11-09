# Dashboard, event log, install pointer and a one-look readiness check. Dot-sourced by unity-slot.ps1.
# ASCII-only source.
#
#   unity-slot dashboard -Json [-Git basic|full]
# Prints one JSON document (schema unity-slot.dashboard/1) on stdout and nothing else. Read-only: one
# process snapshot (CIM), git with --no-optional-locks, no command lines, no hooks, no writes besides
# the install pointer. On an error: nothing on stdout, the message on stderr, exit 1.
#
# <slot home>\events.jsonl  one JSON object per line: open, ready, close, acquire, release, renew,
#                           takeover (an expired lease taken over), refused. Rotated to
#                           events-prev.jsonl above 1 MB. Writing it never fails a command.
# <slot home>\install.json  {"script": "<this unity-slot.ps1>", "version": "...", "schema": 1}, refreshed
#                           by every run so other tools (a widget) find the core. While it points at
#                           another copy that exists, no run of this copy replaces it, newer or not:
#                           development checkouts run too (tests\FINDINGS.md F3). It is written when
#                           it is missing or unreadable, when the copy it names is gone, or by that
#                           copy itself. To move it, delete it; the next copy that runs takes it.

$script:DashboardSchema = 'unity-slot.dashboard/1'
$script:EventsMaxBytes = 1MB

function Format-Iso($Date) {
    if ($null -eq $Date) { return $null }
    $d = [datetime]$Date
    if ($d.Kind -eq [DateTimeKind]::Utc) { $d = $d.ToLocalTime() }
    return $d.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $script:Inv)
}

function ConvertTo-GB([double]$Bytes) { return [math]::Round($Bytes / 1GB, 2) }

# ------------------------------------------------------------------ events (R2)

function Get-EventsPath { return (Join-Path (Get-SlotHome) 'events.jsonl') }

# Appends one event line. Never throws: a log that cannot be written is skipped.
function Write-SlotEvent([string]$EventName, [string]$Clone, [int]$EditorPid = 0, $Detail = $null, [string]$OwnerId = '') {
    try {
        $slotName = $null
        if ($Clone) {
            try { foreach ($s in (Read-Registry).slots) { if (Test-SamePath $s.path $Clone) { $slotName = $s.name } } } catch { }
        }
        if (-not $OwnerId) { $OwnerId = Resolve-Owner }
        $via = 'cli'
        if ($env:UNITY_SLOT_VIA) { $via = [string]$env:UNITY_SLOT_VIA }
        $obj = [ordered]@{
            time   = (Format-Iso (Get-Date))
            event  = $EventName
            slot   = $slotName
            path   = $(if ($Clone) { $Clone } else { $null })
            owner  = $OwnerId
            pid    = $(if ($EditorPid -gt 0) { $EditorPid } else { $null })
            via    = $via
            detail = $Detail
        }
        $bytes = $script:Utf8NoBom.GetBytes((($obj | ConvertTo-Json -Compress -Depth 6) + "`n"))
        $dir = Get-SlotHome
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $file = Get-EventsPath
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt $script:EventsMaxBytes) {
            Move-Item -LiteralPath $file -Destination (Join-Path $dir 'events-prev.jsonl') -Force
        }
        for ($try = 0; $try -lt 3; $try++) {
            try {
                $fs = New-Object IO.FileStream($file, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                return
            } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
        }
    } catch { }
}

function Read-EventLines {
    $file = Get-EventsPath
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } catch { return @() }
    @($text -split "`n" | Where-Object { $_.Trim() })
}

# ------------------------------------------------------------------ install pointer (R7)

function Update-InstallPointer {
    try {
        $me = Join-Path $script:SlotRepo 'unity-slot.ps1'
        $dir = Get-SlotHome
        $file = Join-Path $dir 'install.json'
        $text = ([ordered]@{ script = $me; version = $script:UnitySlotVersion; schema = 1 } | ConvertTo-Json -Compress) + "`n"
        if (Test-Path -LiteralPath $file) {
            $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
            if ($raw -eq $text) { return }
            $cur = $null
            try { $cur = $raw | ConvertFrom-Json } catch { }
            $curScript = [string](Get-Prop $cur 'script')
            # another copy that still exists keeps it, whatever the versions
            if ($curScript -and -not (Test-SamePath $curScript $me) -and (Test-Path -LiteralPath $curScript -PathType Leaf)) { return }
        } elseif (-not (Test-Path -LiteralPath $dir)) {
            [void](New-Item -ItemType Directory -Path $dir -Force)
        }
        $tmp = '{0}.{1}.tmp' -f $file, $PID
        [IO.File]::WriteAllText($tmp, $text, $script:Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $file -Force
    } catch { }
}

# ------------------------------------------------------------------ readiness, one look (R4)

function Read-OpenSnapshotFields([string]$Clone) {
    $file = Join-Path $Clone 'Logs\unity-slot-open.txt'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $f = @{}
    try {
        foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
            $m = [regex]::Match($line, '^([A-Za-z]+)=(.*)$')
            if ($m.Success) { $f[$m.Groups[1].Value] = $m.Groups[2].Value }
        }
    } catch { return $null }
    return $f
}

# open/wait record an editor's first READY next to its open snapshot. $true when written now.
function Add-OpenSnapshotReady([string]$Clone, [int]$EditorPid, [datetime]$ReadyAt, [double]$Seconds) {
    try {
        $f = Read-OpenSnapshotFields $Clone
        if ($null -eq $f -or [string]$f['pid'] -ne [string]$EditorPid -or $f.ContainsKey('ready')) { return $false }
        $add = 'ready={0}{1}readySeconds={2}{1}' -f (Format-Iso $ReadyAt), "`r`n", ([math]::Round($Seconds, 1)).ToString($script:Inv)
        [IO.File]::AppendAllText((Join-Path $Clone 'Logs\unity-slot-open.txt'), $add, $script:Utf8NoBom)
        return $true
    } catch { return $false }
}

function Get-OpenSnapshotReady([string]$Clone, [int]$EditorPid) {
    $f = Read-OpenSnapshotFields $Clone
    if ($null -eq $f -or [string]$f['pid'] -ne [string]$EditorPid -or -not $f.ContainsKey('ready')) { return $null }
    $at = $null
    $sec = $null
    try { $at = [datetime]::Parse($f['ready'], $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    try { $sec = [double]::Parse($f['readySeconds'], $script:Inv) } catch { }
    return [pscustomobject]@{ ReadyAt = $at; Seconds = $sec }
}

# Streams the log (4 MB chunks, stops at the line) for the ##utp ProjectInfo line of $EditorPid.
# Returns $null, or Info (the parsed line, $null if only "[Project] Loading completed" was seen).
function Find-ReadyInLog([string]$Log, [int]$EditorPid) {
    if (-not (Test-Path -LiteralPath $Log -PathType Leaf)) { return $null }
    $loaded = $false
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($Log, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $decoder = [Text.Encoding]::UTF8.GetDecoder()
        $buf = New-Object byte[] (4MB)
        $carry = ''
        $total = [long]0
        $done = $false
        while (-not $done) {
            $n = 0
            if ($total -lt 512MB) { $n = $fs.Read($buf, 0, $buf.Length) }
            if ($n -le 0) { $scan = $carry; $carry = ''; $done = $true }
            else {
                $total += $n
                $chars = New-Object char[] ($decoder.GetCharCount($buf, 0, $n))
                $count = $decoder.GetChars($buf, 0, $n, $chars, 0)
                $text = $carry + [string]::new($chars, 0, $count)
                $cut = $text.LastIndexOf("`n")
                if ($cut -lt 0) { $carry = $text; continue }
                $scan = $text.Substring(0, $cut)
                $carry = $text.Substring($cut + 1)
            }
            if (-not $loaded -and $scan.IndexOf('[Project] Loading completed', [StringComparison]::Ordinal) -ge 0) { $loaded = $true }
            $i = 0
            while (($i = $scan.IndexOf('"ProjectInfo"', $i, [StringComparison]::Ordinal)) -ge 0) {
                $start = $scan.LastIndexOf("`n", $i) + 1
                $end = $scan.IndexOf("`n", $i)
                if ($end -lt 0) { $end = $scan.Length }
                $info = Get-ProjectInfo ($scan.Substring($start, $end - $start)) $EditorPid
                if ($null -ne $info) { return [pscustomobject]@{ Info = $info } }
                $i = $end
            }
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
    if ($loaded) { return [pscustomobject]@{ Info = $null } }
    return $null
}

# One look at an open editor, no waiting: ready | starting | stalled | unknown.
# unknown = no per-clone log to read (an editor the Hub started).
function Get-EditorReadiness([string]$Clone, $Proc) {
    $res = [pscustomobject]@{ State = 'unknown'; ReadyAt = $null; ReadySeconds = $null }
    if (-not $Proc.LogFile) { return $res }
    $started = $null
    if ($null -ne $Proc.Started) { $started = [datetime]$Proc.Started }
    $cached = Get-OpenSnapshotReady $Clone $Proc.Pid
    if ($null -ne $cached) {
        $res.State = 'ready'; $res.ReadyAt = $cached.ReadyAt; $res.ReadySeconds = $cached.Seconds
        return $res
    }
    $found = Find-ReadyInLog (Get-NormPath $Proc.LogFile) $Proc.Pid
    if ($null -ne $found) {
        $res.State = 'ready'
        if ($null -ne $found.Info) {
            $ms = Get-Prop $found.Info 'time'
            if ($ms) { $res.ReadyAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime }
            if ($null -ne $res.ReadyAt -and $null -ne $started) { $res.ReadySeconds = [math]::Round(($res.ReadyAt - $started).TotalSeconds, 1) }
        }
        return $res
    }
    if ($null -eq $started) { return $res }
    if (((Get-Date) - $started).TotalSeconds -ge (Get-TimeoutSetting 'stalled' 300)) { $res.State = 'stalled' } else { $res.State = 'starting' }
    return $res
}

# config "sceneBeacon": a clone-relative JSON file that an editor script keeps up to date (format in
# examples\hooks\scene-beacon.ps1). $true = unsaved scenes, $false = all saved, $null = unknown.
function Get-UnsavedScene([string]$Clone, [int]$EditorPid) {
    $rel = [string](Get-Setting 'sceneBeacon')
    if (-not $rel) { return $null }
    $file = Join-Path $Clone $rel
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $data = $null
    try { $data = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
    if ([int](Get-Prop $data 'Pid') -ne $EditorPid) { return $null }
    $writer = [string](Get-Prop $data 'ScriptPath')
    if ($writer) {
        if (-not [IO.Path]::IsPathRooted($writer)) { $writer = Join-Path $Clone $writer }
        if (-not (Test-Path -LiteralPath $writer)) { return $null }
    }
    foreach ($s in @(Get-Prop $data 'Scenes')) { if ($null -ne $s -and (Get-Prop $s 'IsDirty')) { return $true } }
    if ((Get-Prop $data 'PrefabStagePath') -and (Get-Prop $data 'PrefabStageDirty')) { return $true }
    return $false
}

# ------------------------------------------------------------------ git (read-only, R5 via Invoke-Git)

function Get-GitCommonDir([string]$Clone) {
    $dotGit = Join-Path $Clone '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return (Get-NormPath $dotGit) }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return $null }
    try {
        $m = [regex]::Match([IO.File]::ReadAllText($dotGit), 'gitdir:\s*(.+)')
        if (-not $m.Success) { return $null }
        $gitDir = $m.Groups[1].Value.Trim()
        if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Clone $gitDir }
        $gitDir = Get-NormPath $gitDir
        $cd = Join-Path $gitDir 'commondir'
        if (Test-Path -LiteralPath $cd) {
            $rel = ([IO.File]::ReadAllText($cd)).Trim()
            if (-not [IO.Path]::IsPathRooted($rel)) { $rel = Join-Path $gitDir $rel }
            return (Get-NormPath $rel)
        }
        return $gitDir
    } catch { return $null }
}

function Get-GitBasic([string]$Clone) {
    $r = [ordered]@{ branch = $null; upstream = $null; upstreamGone = $false; changes = 0; ahead = $null; behind = $null; error = $null }
    $lines = @(Invoke-Git $Clone @('status', '--porcelain=v2', '--branch'))
    if ($LASTEXITCODE -ne 0) { $r.error = ('git status failed (exit {0})' -f $LASTEXITCODE); return $r }
    $hasAb = $false
    foreach ($l in $lines) {
        $s = [string]$l
        if ($s.StartsWith('# branch.head ')) { $r.branch = $s.Substring(14) }
        elseif ($s.StartsWith('# branch.upstream ')) { $r.upstream = $s.Substring(18) }
        elseif ($s.StartsWith('# branch.ab ')) {
            $m = [regex]::Match($s, '\+(\d+) -(\d+)')
            if ($m.Success) { $r.ahead = [int]$m.Groups[1].Value; $r.behind = [int]$m.Groups[2].Value; $hasAb = $true }
        }
        elseif ($s.StartsWith('#')) { }
        elseif ($s.Trim()) { $r.changes++ }
    }
    if ($r.upstream -and -not $hasAb) { $r.upstreamGone = $true }
    return $r
}

# Branch-level numbers of one repository (counted once per common git directory).
function Get-GitRepoStats([string]$Clone, [string]$CommonDir) {
    $st = [pscustomobject]@{
        LocalOnly = [ordered]@{ commits = 0; oldestAt = $null }
        Branches  = [ordered]@{ total = 0; noUpstream = 0; upstreamGone = 0 }
        Stash     = 0
        Folders   = @()
        Error     = $null
    }
    $times = @(Invoke-Git $Clone @('log', '--branches', '--not', '--remotes', '--format=%ct'))
    if ($LASTEXITCODE -ne 0) { $st.Error = 'git log failed' }
    else {
        $nums = @($times | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [long]$_ })
        $st.LocalOnly.commits = $nums.Count
        if ($nums.Count -gt 0) {
            $oldest = ($nums | Measure-Object -Minimum).Minimum
            $st.LocalOnly.oldestAt = Format-Iso ([DateTimeOffset]::FromUnixTimeSeconds([long]$oldest).LocalDateTime)
        }
    }
    foreach ($ref in @(Invoke-Git $Clone @('for-each-ref', '--format=%(upstream)|%(upstream:track)', 'refs/heads'))) {
        $parts = ([string]$ref).Split('|')
        if (-not ([string]$ref).Trim()) { continue }
        $st.Branches.total++
        if (-not $parts[0]) { $st.Branches.noUpstream++ }
        elseif ($parts.Count -gt 1 -and $parts[1] -match 'gone') { $st.Branches.upstreamGone++ }
    }
    if ($CommonDir) {
        $stashLog = Join-Path $CommonDir 'logs\refs\stash'
        if (Test-Path -LiteralPath $stashLog) { $st.Stash = @([IO.File]::ReadAllLines($stashLog) | Where-Object { $_.Trim() }).Count }
        $folders = New-Object 'System.Collections.Generic.List[string]'
        if ((Split-Path $CommonDir -Leaf) -eq '.git') { $folders.Add((Split-Path $CommonDir -Parent)) }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $CommonDir 'worktrees') -Directory -Force -ErrorAction SilentlyContinue)) {
            $gd = Join-Path $d.FullName 'gitdir'
            if (-not (Test-Path -LiteralPath $gd)) { continue }
            $p = ([IO.File]::ReadAllText($gd)).Trim()
            if ($p) { $folders.Add((Split-Path (Get-NormPath $p) -Parent)) }
        }
        $st.Folders = $folders.ToArray()
    }
    return $st
}

# ------------------------------------------------------------------ dashboard (R1)

# -Shallow (the summary only) skips what the summary table does not show: git, the event history and
# memory trees. States, leases and flags still come from the code below. -AsObject returns the
# document instead of printing it. The dashboard command uses neither, so its JSON is unchanged.
function Invoke-Dashboard {
    param([switch]$Shallow, [switch]$AsObject)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $full = ($GitLevel -eq 'full')
    $reg = Read-Registry
    $dash = Get-Setting 'dashboard'
    $highPct = [int](Get-Prop $dash 'commitHighPercent')
    $critPct = [int](Get-Prop $dash 'commitCriticalPercent')
    $expiringMin = [double](Get-Prop $dash 'leaseExpiringMinutes')
    $oldDays = [double](Get-Prop $dash 'localOnlyOldDays')
    $recentMax = [int](Get-Prop $dash 'recentEvents')

    $t = $sw.ElapsedMilliseconds
    $snap = Get-Snapshot
    $commit = Get-CommitInfo
    $processMs = $sw.ElapsedMilliseconds - $t
    $now = Get-Date
    $editors = @($snap.Unity | Where-Object { $_.Kind -eq 'editor' -or $_.Kind -eq 'batch' })
    $editorsOpen = @($snap.Unity | Where-Object { $_.Kind -eq 'editor' }).Count

    # last open / close per slot from the event log (a light regex pass; full parse only for the recent ones)
    $events = @()
    if (-not $Shallow) { $events = @(Read-EventLines) }
    $lastOpen = @{}
    $lastClose = @{}
    $evRx = New-Object Text.RegularExpressions.Regex('^\{"time":"([^"]+)","event":"([a-z]+)","slot":"((?:[^"\\]|\\.)*)"')
    foreach ($line in $events) {
        $m = $evRx.Match($line)
        if (-not $m.Success) { continue }
        $slotKey = [regex]::Unescape($m.Groups[3].Value).ToLowerInvariant()
        if ($m.Groups[2].Value -eq 'open') { $lastOpen[$slotKey] = $m.Groups[1].Value }
        elseif ($m.Groups[2].Value -eq 'close') { $lastClose[$slotKey] = $m.Groups[1].Value }
    }

    $claimed = @{}
    $repoCache = @{}
    $gitWatch = New-Object Diagnostics.Stopwatch
    $slotsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $reg.slots) {
        $exists = Test-Path -LiteralPath $s.path -PathType Container
        $open = @()
        if ($exists) { $open = @($editors | Where-Object { Test-SamePath $_.Project $s.path }) }
        foreach ($o in $open) { $claimed[$o.Pid] = $true }
        $ed = @($open | Where-Object { $_.Kind -eq 'editor' } | Select-Object -First 1)
        $bt = @($open | Where-Object { $_.Kind -eq 'batch' } | Select-Object -First 1)
        $flags = New-Object 'System.Collections.Generic.List[string]'

        $editor = [ordered]@{ state = 'closed'; pid = $null; startedAt = $null; readyAt = $null; readySeconds = $null
            launch = $null; standby = $null; lock = $null; unsavedScene = $null; memory = $null }
        $proc = $null
        if (-not $exists) { $editor.state = 'missing'; $flags.Add('missing-path') }
        elseif ($bt.Count -gt 0) { $proc = $bt[0]; $editor.state = 'batch'; $flags.Add('batch-running') }
        elseif ($ed.Count -gt 0) {
            $proc = $ed[0]
            $ready = Get-EditorReadiness $s.path $proc
            $editor.state = $ready.State
            $editor.readyAt = Format-Iso $ready.ReadyAt
            $editor.readySeconds = $ready.ReadySeconds
            $editor.launch = $proc.Launch
            $editor.standby = [string]$proc.Standby
            $editor.lock = Get-LockState $s.path
            $editor.unsavedScene = Get-UnsavedScene $s.path $proc.Pid
            if ($editor.state -eq 'stalled') { $flags.Add('stalled') }
            if ($editor.unsavedScene -eq $true) { $flags.Add('unsaved-scene') }
        } elseif ((Get-LockState $s.path) -eq 'held') { $flags.Add('stale-lock') }
        if ($null -ne $proc) {
            $editor.pid = $proc.Pid
            $editor.startedAt = Format-Iso $proc.Started
            if (-not $Shallow) {
                $tree = Get-EditorTree $snap $proc.Pid
                $editor.memory = [ordered]@{
                    editorPrivGB = (ConvertTo-GB $tree.EditorPriv); workersPrivGB = (ConvertTo-GB $tree.WorkerPriv)
                    childrenPrivGB = (ConvertTo-GB $tree.OtherPriv); totalPrivGB = (ConvertTo-GB $tree.TotalPriv)
                    totalWsGB = (ConvertTo-GB $tree.TotalWs); workers = $tree.WorkerCount; children = $tree.OtherCount
                }
            }
        }
        $isOpen = ($null -ne $proc -and $editor.state -ne 'batch')

        $lease = $null
        $l = Get-SlotLease $s.name
        if ($null -ne $l) {
            $lease = [ordered]@{ owner = $l.owner; need = $l.need; acquiredAt = (Format-Iso $l.acquiredAt); expiresAt = (Format-Iso $l.expiresAt)
                expired = [bool]$l.Expired; openedByAcquire = [bool]$l.openedByAcquire; host = $l.host; client = $null }
            # MCP leases record the client process (Claude Code, Codex, Cursor); gone = orphaned lease
            $alive = Test-LeaseClientAlive $l $snap
            if ($null -ne $alive) {
                $lease.client = [ordered]@{ name = $l.clientName; pid = $l.clientPid; startedAt = (Format-Iso $l.clientStartedAt); alive = [bool]$alive }
                if (-not $alive) { $flags.Add('lease-client-gone') }
            }
            if ($l.Expired -and $isOpen) { $flags.Add('lease-expired-open') }
            elseif (-not $l.Expired -and $null -ne $l.expiresAt -and ([datetime]$l.expiresAt - $now).TotalMinutes -le $expiringMin) { $flags.Add('lease-expiring') }
        } elseif ($isOpen -and $s.mode -ne 'hot') { $flags.Add('open-without-lease') }

        $git = $null
        if ($exists -and -not $Shallow) {
            $gitWatch.Start()
            $b = Get-GitBasic $s.path
            $common = Get-GitCommonDir $s.path
            $fetch = $null
            if ($common -and (Test-Path -LiteralPath (Join-Path $common 'FETCH_HEAD'))) { $fetch = Format-Iso (Get-Item -LiteralPath (Join-Path $common 'FETCH_HEAD')).LastWriteTime }
            $git = [ordered]@{ level = $GitLevel; branch = $b.branch; upstream = $b.upstream; upstreamGone = $b.upstreamGone
                changes = $b.changes; ahead = $b.ahead; behind = $b.behind; lastFetchAt = $fetch; commonDir = $common
                localOnly = $null; branches = $null; stash = $null; worktrees = $null; error = $b.error }
            if ($full -and -not $b.error) {
                $key = ([string]$common).ToLowerInvariant()
                if (-not $repoCache.ContainsKey($key)) { $repoCache[$key] = Get-GitRepoStats $s.path $common }
                $rs = $repoCache[$key]
                $git.localOnly = $rs.LocalOnly
                $git.branches = $rs.Branches
                $git.stash = $rs.Stash
                $git.worktrees = [string[]]@($rs.Folders | Where-Object { -not (Test-SamePath $_ $s.path) })
                if ($rs.Error) { $git.error = $rs.Error }
                $oldest = $rs.LocalOnly.oldestAt
                if ($oldest -and ($now - [datetime]::Parse($oldest, $script:Inv)).TotalDays -gt $oldDays) { $flags.Add('local-only-old') }
            }
            $gitWatch.Stop()
        }

        $key = $s.name.ToLowerInvariant()
        $openedAt = $null
        if ($lastOpen.ContainsKey($key)) { $openedAt = [datetime]::Parse($lastOpen[$key], $script:Inv) }
        if ($isOpen -and $null -ne $proc.Started -and ($null -eq $openedAt -or [datetime]$proc.Started -gt $openedAt)) { $openedAt = [datetime]$proc.Started }
        $closedAt = $null
        if ($lastClose.ContainsKey($key)) { $closedAt = [datetime]::Parse($lastClose[$key], $script:Inv) }
        if (-not $isOpen -and $exists) {
            $logFile = Join-Path $s.path 'Logs\Editor.log'
            if (Test-Path -LiteralPath $logFile) {
                $mt = (Get-Item -LiteralPath $logFile).LastWriteTime
                if ($null -eq $closedAt -or $mt -gt $closedAt) { $closedAt = $mt }
            }
        }

        $slotsOut.Add([ordered]@{
            name = $s.name; path = $s.path; project = $s.project; repo = $s.repo; kind = $s.kind; unity = $s.unity
            platform = $s.platform; purposes = [string[]]@($s.purposes); mode = $s.mode; agentUse = [bool]$s.agentUse
            memo = $s.memo; exists = [bool]$exists; editor = $editor; lease = $lease; git = $git
            lastOpenedAt = (Format-Iso $openedAt); lastClosedAt = (Format-Iso $closedAt); flags = $flags.ToArray()
        })
    }

    $unregistered = @($editors | Where-Object { -not $claimed.ContainsKey($_.Pid) } | ForEach-Object {
            $tree = Get-EditorTree $snap $_.Pid
            [ordered]@{ pid = $_.Pid; kind = $_.Kind; project = $_.Project; startedAt = (Format-Iso $_.Started); launch = $_.Launch
                memory = [ordered]@{ totalPrivGB = (ConvertTo-GB $tree.TotalPriv); totalWsGB = (ConvertTo-GB $tree.TotalWs) } }
        })
    $live = @{}
    foreach ($e in $editors) { $live[$e.Pid] = $true }
    $orphans = @($snap.Unity | Where-Object { $_.Kind -eq 'worker' -and -not $live.ContainsKey($_.Owner) } | ForEach-Object {
            [ordered]@{ pid = $_.Pid; ownerPid = $_.Owner; project = $_.Project; privGB = (ConvertTo-GB $_.PrivateBytes) }
        })
    $recent = New-Object 'System.Collections.Generic.List[object]'
    for ($i = $events.Count - 1; $i -ge 0 -and $recent.Count -lt $recentMax; $i--) {
        try { $recent.Add(($events[$i] | ConvertFrom-Json)) } catch { }
    }
    $sysFlags = New-Object 'System.Collections.Generic.List[string]'
    if ($commit.Percent -ge $critPct) { $sysFlags.Add('commit-critical') } elseif ($commit.Percent -ge $highPct) { $sysFlags.Add('commit-high') }
    if ($editorsOpen -ge [int]$reg.maxEditors) { $sysFlags.Add('editors-at-max') }

    $doc = [ordered]@{
        schema              = $script:DashboardSchema
        version             = $script:UnitySlotVersion
        time                = (Format-Iso $now)
        host                = $env:COMPUTERNAME
        registry            = [ordered]@{ path = (Get-RegistryPath); updatedAt = $reg.updatedAt; maxEditors = [int]$reg.maxEditors }
        system              = [ordered]@{ commit = [ordered]@{ usedGB = $commit.UsedGB; limitGB = $commit.LimitGB; percent = $commit.Percent }
            freePhysicalGB = $commit.FreePhysicalGB; editorsOpen = $editorsOpen }
        slots               = $slotsOut.ToArray()
        unregisteredEditors = $unregistered
        orphanWorkers       = $orphans
        recentEvents        = $recent.ToArray()
        systemFlags         = $sysFlags.ToArray()
        timing              = [ordered]@{ totalMs = $sw.ElapsedMilliseconds; processMs = $processMs; gitMs = $gitWatch.ElapsedMilliseconds }
    }
    if ($AsObject) { return $doc }
    [Console]::Out.Write(($doc | ConvertTo-Json -Compress -Depth 12) + "`n")
    [Console]::Out.Flush()
}
