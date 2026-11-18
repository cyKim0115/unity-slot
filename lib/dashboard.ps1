# Dashboard, event log, install pointer and a one-look readiness check. Dot-sourced by unity-slot.ps1.
# ASCII-only source.
#
#   unity-slot dashboard -Json [-Git basic|full]
# Prints one JSON document (schema unity-slot.dashboard/1) on stdout and nothing else. Read-only: one
# process snapshot (CIM), git with --no-optional-locks, no command lines, no hooks, no writes besides
# the install pointer. On an error: nothing on stdout, the message on stderr, exit 1.
# Git: one status per slot (basic), and with -Git full one for-each-ref and one log per common git
# directory (repos[]); files inside .git are read with full sharing and never written.
# branchViews[]: the branch-view state files and each slot's ref signature (files only, lib\branchview.ps1).
#
# <slot home>\events.jsonl  one JSON object per line: open, ready, close, acquire, release, renew,
#                           takeover (an expired lease taken over), refused, branchview. Rotated to
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
#
# "Local-only" commits = commits on local branches that no ref of origin has, nor a ref of another
# remote whose URL is not a local path. A remote that points at another clone on this PC does not count:
# work that is only there has not reached a server either.

# Above this many local-only commits in one repository, the per-branch walk is skipped (null values).
$script:LocalOnlyWalkMax = 20000

# Text of a file inside a git directory, opened with full sharing so that a git process may still
# rename or delete it meanwhile (Windows refuses that while a reader holds it without FileShare.Delete).
# $null when it is missing or cannot be read.
function Read-GitFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
    } catch {
        return $null
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

function Format-UnixIso([long]$Unix) { return (Format-Iso ([DateTimeOffset]::FromUnixTimeSeconds($Unix).LocalDateTime)) }

# The working folder's own git directory (GitDir: <clone>\.git, or <common>\worktrees\<id> for a linked
# worktree) and the one its branches live in (CommonDir). Both $null when the folder has no .git.
function Get-GitDirs([string]$Clone) {
    $r = [pscustomobject]@{ GitDir = $null; CommonDir = $null }
    $dotGit = Join-Path $Clone '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        $r.GitDir = Get-NormPath $dotGit
        $r.CommonDir = $r.GitDir
        return $r
    }
    $text = Read-GitFile $dotGit
    if ($null -eq $text) { return $r }
    $m = [regex]::Match($text, 'gitdir:\s*(.+)')
    if (-not $m.Success) { return $r }
    $gitDir = $m.Groups[1].Value.Trim()
    if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Clone $gitDir }
    $r.GitDir = Get-NormPath $gitDir
    $r.CommonDir = $r.GitDir
    $rel = [string](Read-GitFile (Join-Path $r.GitDir 'commondir'))
    if ($rel.Trim()) {
        $rel = $rel.Trim()
        if (-not [IO.Path]::IsPathRooted($rel)) { $rel = Join-Path $r.GitDir $rel }
        $r.CommonDir = Get-NormPath $rel
    }
    return $r
}

function Get-GitCommonDir([string]$Clone) { return (Get-GitDirs $Clone).CommonDir }

# One git status of a working folder: branch, upstream, changes, and (same output) head, detached and
# the changes by kind. An entry can be staged and unstaged at once, so the kinds can add up to more
# than changes.
function Get-GitBasic([string]$Clone) {
    $r = [ordered]@{ branch = $null; upstream = $null; upstreamGone = $false; changes = 0; ahead = $null; behind = $null; error = $null
        head = $null; detached = $false; changesDetail = [ordered]@{ staged = 0; unstaged = 0; untracked = 0; conflicted = 0 } }
    $lines = @(Invoke-Git $Clone @('status', '--porcelain=v2', '--branch'))
    if ($LASTEXITCODE -ne 0) { $r.error = ('git status failed (exit {0})' -f $LASTEXITCODE); return $r }
    $hasAb = $false
    $cd = $r.changesDetail
    foreach ($l in $lines) {
        $s = [string]$l
        if ($s.StartsWith('# branch.oid ')) {
            $oid = $s.Substring(13).Trim()
            if ($oid -match '^[0-9a-f]{40,64}$') { $r.head = $oid }
        }
        elseif ($s.StartsWith('# branch.head ')) { $r.branch = $s.Substring(14); $r.detached = ($r.branch -eq '(detached)') }
        elseif ($s.StartsWith('# branch.upstream ')) { $r.upstream = $s.Substring(18) }
        elseif ($s.StartsWith('# branch.ab ')) {
            $m = [regex]::Match($s, '\+(\d+) -(\d+)')
            if ($m.Success) { $r.ahead = [int]$m.Groups[1].Value; $r.behind = [int]$m.Groups[2].Value; $hasAb = $true }
        }
        elseif ($s.StartsWith('#')) { }
        elseif ($s.Trim()) {
            $r.changes++
            if ($s.StartsWith('1 ') -or $s.StartsWith('2 ')) {
                if ($s.Length -gt 3 -and $s[2] -ne [char]'.') { $cd.staged++ }
                if ($s.Length -gt 3 -and $s[3] -ne [char]'.') { $cd.unstaged++ }
            }
            elseif ($s.StartsWith('u ')) { $cd.conflicted++ }
            elseif ($s.StartsWith('? ')) { $cd.untracked++ }
        }
    }
    if ($r.upstream -and -not $hasAb) { $r.upstreamGone = $true }
    return $r
}

# The remotes of a repository from its config file (no git): name and first URL.
function Get-GitRemotes([string]$CommonDir) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $text = Read-GitFile (Join-Path $CommonDir 'config')
    if ($null -eq $text) { return $list.ToArray() }
    $cur = $null
    foreach ($line in ($text -split "`n")) {
        $h = [regex]::Match($line, '^\s*\[\s*remote\s+"((?:[^"\\]|\\.)+)"\s*\]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($h.Success) {
            $cur = [pscustomobject]@{ Name = $h.Groups[1].Value; Url = $null }
            $list.Add($cur)
            continue
        }
        if ($line -match '^\s*\[') { $cur = $null; continue }
        if ($null -eq $cur -or $null -ne $cur.Url) { continue }
        $u = [regex]::Match($line, '^\s*url\s*=\s*(.*?)\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($u.Success) { $cur.Url = $u.Groups[1].Value.Trim('"') }
    }
    return $list.ToArray()
}

# $true when a remote URL is a folder on this PC (or a share) rather than a server.
function Test-LocalGitUrl([string]$Url) {
    $u = ([string]$Url).Trim()
    if (-not $u) { return $false }
    if ($u -match '^(?i)file://') { return $true }
    if ($u -match '^[A-Za-z]:[\\/]') { return $true }
    if ($u -match '^[\\/]') { return $true }
    if ($u -match '^\.\.?([\\/]|$)') { return $true }
    if ($u -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $false }
    if ($u -match '^[^\\/]+:') { return $false }
    return $true
}

# Revision arguments for "not on a remote": origin plus every other remote whose URL is no local path.
function Get-GitRemoteArgs([string]$CommonDir) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    $out.Add('--remotes=origin')
    foreach ($rm in @(Get-GitRemotes $CommonDir)) {
        if ($rm.Name -eq 'origin' -or -not $rm.Url -or (Test-LocalGitUrl $rm.Url)) { continue }
        if ($rm.Name -match '[*?\[\\]') { continue }
        $out.Add('--remotes=' + $rm.Name)
    }
    return $out.ToArray()
}

# origin's default branch from refs\remotes\origin\HEAD (a file, no git), for example "origin/master".
function Get-GitDefaultBranch([string]$CommonDir) {
    $text = Read-GitFile (Join-Path $CommonDir 'refs\remotes\origin\HEAD')
    if ($null -eq $text) { return $null }
    $m = [regex]::Match($text, '^ref:\s*refs/remotes/(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# A ref's object from the loose file or packed-refs (no git); $null when neither has it.
function Resolve-GitRefFile([string]$CommonDir, [string]$Ref) {
    $loose = Read-GitFile (Join-Path $CommonDir ($Ref.Replace('/', '\')))
    if ($null -ne $loose -and $loose.Trim() -match '^[0-9a-f]{40,64}$') { return $loose.Trim() }
    $packed = Read-GitFile (Join-Path $CommonDir 'packed-refs')
    if ($null -eq $packed) { return $null }
    foreach ($line in ($packed -split "`n")) {
        $p = $line.Trim().Split(' ')
        if ($p.Count -eq 2 -and $p[1] -eq $Ref -and $p[0] -match '^[0-9a-f]{40,64}$') { return $p[0] }
    }
    return $null
}

# Branch and head of a working folder from its HEAD file (no git).
function Read-GitHeadFile([string]$CommonDir, [string]$HeadFile) {
    $r = [pscustomobject]@{ Branch = $null; Head = $null; Detached = $false }
    $text = ([string](Read-GitFile $HeadFile)).Trim()
    $m = [regex]::Match($text, '^ref:\s*refs/heads/(.+)$')
    if ($m.Success) {
        $r.Branch = $m.Groups[1].Value
        $r.Head = Resolve-GitRefFile $CommonDir ('refs/heads/' + $r.Branch)
    } elseif ($text -match '^[0-9a-f]{40,64}$') {
        $r.Head = $text
        $r.Detached = $true
    }
    return $r
}

# The working folders of a repository from its common git directory (files only, no git): the main
# work tree (the folder that holds the common directory as .git, or a slot whose own git directory it
# is) and the linked worktrees (worktrees\<id>\gitdir).
function Get-GitFolderList([string]$CommonDir, [string[]]$MainCandidates) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $main = $null
    if ((Split-Path $CommonDir -Leaf) -eq '.git') { $main = Split-Path $CommonDir -Parent }
    elseif (@($MainCandidates).Count -gt 0) { $main = @($MainCandidates)[0] }
    if ($main) {
        $list.Add([pscustomobject]@{ Path = (Get-NormPath $main); Main = $true; HeadFile = (Join-Path $CommonDir 'HEAD'); Locked = $null; Prunable = $null })
    }
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $CommonDir 'worktrees') -Directory -Force -ErrorAction SilentlyContinue)) {
        $p = ([string](Read-GitFile (Join-Path $d.FullName 'gitdir'))).Trim()
        if (-not $p) { continue }
        # relative to worktrees\<id> with worktree.useRelativePaths (git 2.48)
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $d.FullName $p }
        $dotGit = Get-NormPath $p
        $list.Add([pscustomobject]@{ Path = (Split-Path $dotGit -Parent); Main = $false; HeadFile = (Join-Path $d.FullName 'HEAD')
                Locked = (Test-Path -LiteralPath (Join-Path $d.FullName 'locked')); Prunable = (-not (Test-Path -LiteralPath $dotGit)) })
    }
    return $list.ToArray()
}

# Local-only commits reachable from $Tip inside the set of one log run (sha -> fields: sha, time, parents).
function Measure-LocalOnly($Set, [string]$Tip) {
    $n = 0
    $oldest = [long]::MaxValue
    if ($Tip -and $Set.ContainsKey($Tip)) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Tip)
        while ($stack.Count -gt 0) {
            $c = $stack.Pop()
            if (-not $seen.Add($c)) { continue }
            $f = $Set[$c]
            $n++
            $t = [long]$f[1]
            if ($t -lt $oldest) { $oldest = $t }
            for ($i = 2; $i -lt $f.Length; $i++) {
                $parent = $f[$i]
                if ($parent -and $Set.ContainsKey($parent) -and -not $seen.Contains($parent)) { $stack.Push($parent) }
            }
        }
    }
    $at = $null
    if ($n -gt 0) { $at = Format-UnixIso $oldest }
    return [ordered]@{ commits = $n; oldestAt = $at }
}

# Branches, local-only commits and stashes of one repository (once per common git directory): one
# for-each-ref with %(ahead-behind) (where that fails, on git before 2.41 or with a default branch that
# does not resolve: one without it and one --merged), one log walked in memory, and the stash reflog
# file. $SlotNames maps lower-case folder paths to slot names.
function Get-GitRepoDetail([string]$Clone, [string]$CommonDir, [string]$DefaultBranch, $SlotNames) {
    $d = [pscustomobject]@{
        Branches  = @()
        Stats     = [ordered]@{ total = 0; noUpstream = 0; upstreamGone = 0 }
        LocalOnly = [ordered]@{ commits = 0; oldestAt = $null }
        Stashes   = @()
        StashCount = 0
        RemoteArgs = @(Get-GitRemoteArgs $CommonDir)
        Error     = $null
    }
    $base = '%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(worktreepath)%1f'
    $refs = $null
    $withAb = $false
    if ($DefaultBranch) {
        $refs = @(Invoke-Git $Clone @('for-each-ref', ('--format=' + $base + '%(ahead-behind:' + $DefaultBranch + ')%1f%(contents:subject)'), 'refs/heads'))
        if ($LASTEXITCODE -eq 0) { $withAb = $true } else { $refs = $null }
    }
    if ($null -eq $refs) {
        $refs = @(Invoke-Git $Clone @('for-each-ref', ('--format=' + $base + '%1f%(contents:subject)'), 'refs/heads'))
        if ($LASTEXITCODE -ne 0) { $d.Error = 'git for-each-ref failed'; $refs = @() }
    }
    $mergedSet = $null
    if (-not $withAb -and $DefaultBranch -and -not $d.Error) {
        # git before 2.41 (no %(ahead-behind)), or a default branch that does not resolve
        $ml = @(Invoke-Git $Clone @('for-each-ref', '--format=%(refname)', '--merged', $DefaultBranch, 'refs/heads'))
        if ($LASTEXITCODE -eq 0) { $mergedSet = @{}; foreach ($x in $ml) { $mergedSet[[string]$x] = $true } }
    }

    $logArgs = @('log', '--branches', '--not') + $d.RemoteArgs + @('--format=%H %ct %P')
    $lines = @(Invoke-Git $Clone $logArgs)
    $logOk = ($LASTEXITCODE -eq 0)
    if (-not $logOk) { $d.Error = 'git log failed'; $lines = @() }
    $commits = New-Object 'System.Collections.Generic.List[object]'
    $oldest = [long]::MaxValue
    foreach ($l in $lines) {
        $f = ([string]$l).Split(' ')
        if ($f.Length -lt 2 -or $f[0].Length -lt 40) { continue }
        $t = 0L
        if (-not [long]::TryParse($f[1], [ref]$t)) { continue }
        $commits.Add($f)
        if ($t -lt $oldest) { $oldest = $t }
    }
    $d.LocalOnly.commits = $commits.Count
    if ($commits.Count -gt 0) { $d.LocalOnly.oldestAt = Format-UnixIso $oldest }
    # per-branch values only from a log that ran and is small enough to walk (else null, not 0)
    $set = $null
    if ($logOk -and $commits.Count -le $script:LocalOnlyWalkMax) {
        $set = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($f in $commits) { $set[$f[0]] = $f }
    }

    $branches = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $refs) {
        $f = ([string]$r).Split([char[]]@([char]0x1f), 8)
        if ($f.Length -lt 8) { continue }
        $name = $f[0]
        if ($name.StartsWith('refs/heads/')) { $name = $name.Substring(11) }
        $d.Stats.total++
        $upstream = $null
        $ahead = $null
        $behind = $null
        $gone = $false
        if (-not $f[3]) { $d.Stats.noUpstream++ }
        else {
            $upstream = $f[3]
            if ($f[4] -match 'gone') { $gone = $true; $d.Stats.upstreamGone++ }
            else {
                $ahead = 0
                $behind = 0
                $m = [regex]::Match($f[4], 'ahead (\d+)')
                if ($m.Success) { $ahead = [int]$m.Groups[1].Value }
                $m = [regex]::Match($f[4], 'behind (\d+)')
                if ($m.Success) { $behind = [int]$m.Groups[1].Value }
            }
        }
        $baseAhead = $null
        $baseBehind = $null
        $merged = $null
        $m = [regex]::Match($f[6], '^(\d+) (\d+)$')
        if ($withAb -and $m.Success) {
            $baseAhead = [int]$m.Groups[1].Value
            $baseBehind = [int]$m.Groups[2].Value
            $merged = ($baseAhead -eq 0)
        } elseif ($null -ne $mergedSet) { $merged = $mergedSet.ContainsKey($f[0]) }
        $tipAt = $null
        $unix = 0L
        if ([long]::TryParse($f[2], [ref]$unix)) { $tipAt = Format-UnixIso $unix }
        $subject = $f[7]
        if ($subject.Length -gt 120) { $subject = $subject.Substring(0, 120) }
        $local = $null
        if ($null -ne $set) { $local = Measure-LocalOnly $set $f[1] }
        $by = New-Object 'System.Collections.Generic.List[object]'
        if ($f[5]) {
            $wt = Get-NormPath $f[5]
            $slotName = $null
            $key = $wt.ToLowerInvariant()
            if ($SlotNames.ContainsKey($key)) { $slotName = $SlotNames[$key] }
            $by.Add([ordered]@{ path = $wt; slot = $slotName })
        }
        $branches.Add([ordered]@{
                name = $name; tip = $f[1]; tipAt = $tipAt; subject = $subject
                upstream = $upstream; upstreamGone = $gone; ahead = $ahead; behind = $behind
                baseAhead = $baseAhead; baseBehind = $baseBehind; merged = $merged
                localOnly = $local; checkedOutBy = $by.ToArray()
            })
    }
    $d.Branches = $branches.ToArray()

    # stash@{0} is the last line of the reflog: "<old> <new> <name> <mail> <time> <zone>`t<message>"
    # (git skips lines it cannot parse when it numbers stash@{n}, and so does this; the message is optional)
    $stashes = New-Object 'System.Collections.Generic.List[object]'
    $text = Read-GitFile (Join-Path $CommonDir 'logs\refs\stash')
    if ($null -ne $text) {
        $sl = @(($text -split "`n") | Where-Object { $_.Trim() })
        $d.StashCount = $sl.Count
        for ($i = $sl.Count - 1; $i -ge 0; $i--) {
            $m = [regex]::Match($sl[$i].TrimEnd("`r"), '^\S+ ([0-9a-f]{40,64}) [^\t]*?> (\d+) [+-]\d{4}(?:\t(.*))?$')
            if (-not $m.Success) { continue }
            $msg = $m.Groups[3].Value
            $branch = $null
            $bm = [regex]::Match($msg, '^(?:WIP on|On) (.+?): ')
            if ($bm.Success -and $bm.Groups[1].Value -ne '(no branch)') { $branch = $bm.Groups[1].Value }
            $stashes.Add([ordered]@{ index = $stashes.Count; sha = $m.Groups[1].Value; at = (Format-UnixIso ([long]$m.Groups[2].Value)); branch = $branch; message = $msg })
        }
    }
    $d.Stashes = $stashes.ToArray()
    return $d
}

# Commits reachable from a detached HEAD that no branch and no remote (as for local-only) has.
function Get-GitDetachedLocalOnly([string]$Clone, [string]$Head, [string[]]$RemoteArgs) {
    $times = @(Invoke-Git $Clone (@('log', $Head, '--not', '--branches') + $RemoteArgs + @('--format=%ct')))
    if ($LASTEXITCODE -ne 0) { return $null }
    $n = 0
    $oldest = [long]::MaxValue
    foreach ($l in $times) {
        $t = 0L
        if (-not [long]::TryParse(([string]$l).Trim(), [ref]$t)) { continue }
        $n++
        if ($t -lt $oldest) { $oldest = $t }
    }
    $at = $null
    if ($n -gt 0) { $at = Format-UnixIso $oldest }
    return [ordered]@{ commits = $n; oldestAt = $at }
}

# One repos[] entry: the working folders always, with -Git full also branches, stashes, local-only
# commits and flags (else null). $Group: CommonDir, Clone, Project, Repo, DefaultBranch, Slots (each
# Path, Name, GitDir, Basic, Git), Detail. Fills the full slots' git.worktrees.
function New-RepoEntry($Group, [bool]$Full, [double]$OldDays, [datetime]$Now, $SlotNames) {
    $byPath = @{}
    $mains = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $Group.Slots) {
        $byPath[(Get-NormPath $s.Path).ToLowerInvariant()] = $s
        if ($s.GitDir -and (Test-SamePath $s.GitDir $Group.CommonDir)) { $mains.Add($s.Path) }
    }
    $list = @(Get-GitFolderList $Group.CommonDir $mains.ToArray())
    $detail = $Group.Detail
    $folders = New-Object 'System.Collections.Generic.List[object]'
    $detachedLocal = $false
    foreach ($fo in $list) {
        $key = $fo.Path.ToLowerInvariant()
        $slotName = $null
        if ($SlotNames.ContainsKey($key)) { $slotName = $SlotNames[$key] }
        $branch = $null
        $head = $null
        $detached = $false
        $s = $null
        if ($byPath.ContainsKey($key)) { $s = $byPath[$key] }
        if ($null -ne $s -and $null -ne $s.Basic -and -not $s.Basic.error) {
            $head = $s.Basic.head
            $detached = [bool]$s.Basic.detached
            if (-not $detached) { $branch = $s.Basic.branch }
        } else {
            $h = Read-GitHeadFile $Group.CommonDir $fo.HeadFile
            $branch = $h.Branch
            $head = $h.Head
            $detached = $h.Detached
        }
        $local = $null
        if ($Full -and $null -ne $detail -and $detached -and $head) {
            $local = Get-GitDetachedLocalOnly $Group.Clone $head $detail.RemoteArgs
            if ($null -ne $local -and $local.commits -gt 0) { $detachedLocal = $true }
        }
        $folders.Add([ordered]@{ path = $fo.Path; slot = $slotName; main = [bool]$fo.Main; branch = $branch; head = $head
                detached = [bool]$detached; locked = $fo.Locked; prunable = $fo.Prunable; localOnly = $local })
    }
    $layout = 'clone'
    $hub = $null
    if (@($list | Where-Object { $_.Main }).Count -eq 0) { $layout = 'bare-hub'; $hub = $Group.CommonDir }
    elseif ($list.Count -gt 1) { $layout = 'worktrees' }
    if ($Full) {
        foreach ($s in $Group.Slots) {
            if ($null -eq $s.Git -or $null -eq $s.Git.localOnly) { continue }
            $s.Git.worktrees = [string[]]@($list | Where-Object { -not (Test-SamePath $_.Path $s.Path) } | ForEach-Object { $_.Path })
        }
    }
    $fetch = $null
    $fh = Join-Path $Group.CommonDir 'FETCH_HEAD'
    if (Test-Path -LiteralPath $fh) { $fetch = Format-Iso (Get-Item -LiteralPath $fh).LastWriteTime }
    $err = $null
    $bad = @($Group.Slots | Where-Object { $null -ne $_.Basic -and $_.Basic.error })
    if ($bad.Count -gt 0 -and $bad.Count -eq @($Group.Slots).Count) { $err = $bad[0].Basic.error }
    $branches = $null
    $stashes = $null
    $localOnly = $null
    $flags = $null
    if ($Full -and $null -ne $detail) {
        $branches = $detail.Branches
        $stashes = $detail.Stashes
        $localOnly = $detail.LocalOnly
        $fl = New-Object 'System.Collections.Generic.List[string]'
        $oldest = $detail.LocalOnly.oldestAt
        if ($oldest -and ($Now - [datetime]::Parse($oldest, $script:Inv)).TotalDays -gt $OldDays) { $fl.Add('local-only-old') }
        if ($detachedLocal) { $fl.Add('detached-local-only') }
        $flags = $fl.ToArray()
        if ($detail.Error) { $err = $detail.Error }
    }
    return [ordered]@{
        commonDir = $Group.CommonDir; project = $Group.Project; repo = $Group.Repo; level = $GitLevel
        layout = $layout; hub = $hub; lastFetchAt = $fetch; defaultBranch = $Group.DefaultBranch
        folders = $folders.ToArray(); branches = $branches; stashes = $stashes; localOnly = $localOnly
        flags = $flags; error = $err
    }
}

# ------------------------------------------------------------------ branch views (files only)

# branchViews[]: one entry per branch-view state file under branchView.root (lib\branchview.ps1 writes
# them), from files only, no git: the last run's slots with changedSince from each slot's ref signature
# now (Get-SlotRefSignature), registry slots of the project that the view does not have yet (status
# not-fetched), origin's source and refused refs. [] when the root does not exist. The state files are
# opened with full sharing (Read-GitFile), so a branch-view run may swap them meanwhile.
function Get-BranchViewEntries($Reg) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $root = $null
    try { $root = Get-BranchViewRoot } catch { return $list.ToArray() }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return $list.ToArray() }
    $files = @()
    try { $files = @([IO.Directory]::GetFiles($root, '*.view.json') | Where-Object { $_.EndsWith('.view.json', [StringComparison]::OrdinalIgnoreCase) } | Sort-Object) }
    catch { return $list.ToArray() }
    foreach ($file in $files) {
        $e = [ordered]@{ project = $null; repo = $null; path = $null; gitDir = $null; createdAt = $null; updatedAt = $null; coreVersion = $null
            slots = @(); origin = [ordered]@{ filledFrom = $null; rejected = @() }; error = $null }
        try {
            $st = Read-ViewState $file
            if ($null -eq $st -or [string](Get-Prop $st 'schema') -notlike 'unity-slot.branch-view/*') {
                $e.path = $file
                $e.error = 'state file unreadable: ' + $file
                $list.Add($e)
                continue
            }
            $e.project = Get-Prop $st 'project'
            $e.repo = Get-Prop $st 'repo'
            # path: the folder to open in a git client; gitDir: its .git. A state file of the older bare form
            # has no gitDir: its path is the git directory itself.
            $e.path = Get-Prop $st 'path'
            $e.gitDir = Get-Prop $st 'gitDir'
            if (-not $e.gitDir) { $e.gitDir = $e.path }
            $e.createdAt = Get-Prop $st 'createdAt'
            $e.updatedAt = Get-Prop $st 'updatedAt'
            $e.coreVersion = Get-Prop $st 'coreVersion'
            $so = Get-Prop $st 'origin'
            $e.origin.filledFrom = Get-Prop $so 'filledFrom'
            $e.origin.rejected = @(@(Get-Prop $so 'rejected') | Where-Object { $null -ne $_ } | ForEach-Object {
                    [ordered]@{ name = (Get-Prop $_ 'name'); viewSha = (Get-Prop $_ 'viewSha'); slotSha = (Get-Prop $_ 'slotSha') } })
            if (-not $e.gitDir -or -not (Test-Path -LiteralPath (Join-Path ([string]$e.gitDir) 'HEAD') -PathType Leaf)) { $e.error = 'view repository missing' }
            $regSlots = @{}
            foreach ($s in $Reg.slots) {
                if ((Get-BranchViewKey $s) -eq ([string]$e.project).Trim().ToLowerInvariant()) { $regSlots[$s.name.ToLowerInvariant()] = $s }
            }
            $seen = @{}
            $slots = New-Object 'System.Collections.Generic.List[object]'
            foreach ($x in @(Get-Prop $st 'slots')) {
                if ($null -eq $x) { continue }
                $n = [string](Get-Prop $x 'slot')
                $seen[$n.ToLowerInvariant()] = $true
                $changed = $null
                if ($regSlots.ContainsKey($n.ToLowerInvariant())) {
                    $rs = $regSlots[$n.ToLowerInvariant()]
                    if ($rs.path -and (Test-Path -LiteralPath $rs.path -PathType Container)) {
                        $dirs = Get-GitDirs $rs.path
                        $sig = Get-SlotRefSignature $dirs.GitDir $dirs.CommonDir
                        if ($sig) { $changed = ($sig -ne [string](Get-Prop $x 'signature')) }
                    }
                }
                $slots.Add([ordered]@{ slot = $n; remote = (Get-Prop $x 'remote'); status = (Get-Prop $x 'status'); fetchedAt = (Get-Prop $x 'fetchedAt')
                        changedSince = $changed; error = (Get-Prop $x 'error') })
            }
            foreach ($s in $Reg.slots) {
                if (-not $regSlots.ContainsKey($s.name.ToLowerInvariant()) -or $seen.ContainsKey($s.name.ToLowerInvariant())) { continue }
                $slots.Add([ordered]@{ slot = $s.name; remote = $null; status = 'not-fetched'; fetchedAt = $null; changedSince = $true; error = $null })
            }
            $e.slots = $slots.ToArray()
        } catch {
            $e.error = Protect-Text $_.Exception.Message
        }
        $list.Add($e)
    }
    return $list.ToArray()
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
    $repoGroups = [ordered]@{}
    $slotNames = @{}
    foreach ($s in $reg.slots) {
        $np = Get-NormPath $s.path
        if ($np) { $slotNames[$np.ToLowerInvariant()] = $s.name }
    }
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
                expired = [bool]$l.Expired; openedByAcquire = [bool]$l.openedByAcquire; batch = [bool]$l.batch; host = $l.host; client = $null }
            # MCP leases record the client process (Claude Code, Codex, Cursor); gone = orphaned lease
            $alive = Test-LeaseClientAlive $l $snap
            if ($null -ne $alive) {
                $lease.client = [ordered]@{ name = $l.clientName; pid = $l.clientPid; startedAt = (Format-Iso $l.clientStartedAt); alive = [bool]$alive }
                if (-not $alive) { $flags.Add('lease-client-gone') }
            }
            # what release -Stale drops (Get-StaleReason): no editor or batchmode run, and expired or client gone
            $lease.stale = ($null -eq $proc -and ([bool]$l.Expired -or $alive -eq $false))
            if ($l.Expired -and $isOpen) { $flags.Add('lease-expired-open') }
            elseif (-not $l.Expired -and $null -ne $l.expiresAt -and ([datetime]$l.expiresAt - $now).TotalMinutes -le $expiringMin) { $flags.Add('lease-expiring') }
        } elseif ($isOpen -and $s.mode -ne 'hot') { $flags.Add('open-without-lease') }

        $git = $null
        if ($exists -and -not $Shallow) {
            $gitWatch.Start()
            $b = Get-GitBasic $s.path
            $dirs = Get-GitDirs $s.path
            $common = $dirs.CommonDir
            $fetch = $null
            if ($common -and (Test-Path -LiteralPath (Join-Path $common 'FETCH_HEAD'))) { $fetch = Format-Iso (Get-Item -LiteralPath (Join-Path $common 'FETCH_HEAD')).LastWriteTime }
            $git = [ordered]@{ level = $GitLevel; branch = $b.branch; upstream = $b.upstream; upstreamGone = $b.upstreamGone
                changes = $b.changes; ahead = $b.ahead; behind = $b.behind; lastFetchAt = $fetch; commonDir = $common
                localOnly = $null; branches = $null; stash = $null; worktrees = $null; error = $b.error
                head = $b.head; detached = [bool]$b.detached; changesDetail = $b.changesDetail; gitDir = $dirs.GitDir }
            if ($common) {
                # one repos[] entry per common git directory, in registry order
                $key = $common.ToLowerInvariant()
                if (-not $repoGroups.Contains($key)) {
                    $repoGroups[$key] = [pscustomobject]@{ CommonDir = $common; Clone = $s.path; Project = $s.project; Repo = $s.repo
                        DefaultBranch = (Get-GitDefaultBranch $common); Slots = (New-Object 'System.Collections.Generic.List[object]'); Detail = $null }
                }
                $grp = $repoGroups[$key]
                $grp.Slots.Add([pscustomobject]@{ Path = $s.path; Name = $s.name; GitDir = $dirs.GitDir; Basic = $b; Git = $git })
                if ($full -and -not $b.error) {
                    if ($null -eq $grp.Detail) {
                        $grp.Clone = $s.path
                        $grp.Detail = Get-GitRepoDetail $s.path $common $grp.DefaultBranch $slotNames
                    }
                    $rs = $grp.Detail
                    $git.localOnly = $rs.LocalOnly
                    $git.branches = $rs.Stats
                    $git.stash = $rs.StashCount
                    $git.worktrees = [string[]]@()
                    if ($rs.Error) { $git.error = $rs.Error }
                    $oldest = $rs.LocalOnly.oldestAt
                    if ($oldest -and ($now - [datetime]::Parse($oldest, $script:Inv)).TotalDays -gt $oldDays) { $flags.Add('local-only-old') }
                }
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

    # repos: null for the summary (-Shallow), else one entry per common git directory
    $repos = $null
    if (-not $Shallow) {
        $gitWatch.Start()
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($grp in $repoGroups.Values) { $list.Add((New-RepoEntry $grp $full $oldDays $now $slotNames)) }
        $repos = $list.ToArray()
        $gitWatch.Stop()
    }
    # branchViews: null for the summary (-Shallow), else one entry per branch-view state file (files only)
    $branchViews = $null
    if (-not $Shallow) { $branchViews = @(Get-BranchViewEntries $reg) }

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
        repos               = $repos
        branchViews         = $branchViews
    }
    if ($AsObject) { return $doc }
    [Console]::Out.Write(($doc | ConvertTo-Json -Compress -Depth 12) + "`n")
    [Console]::Out.Flush()
}
