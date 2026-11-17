# Branch view: one view repository per project whose remotes are the project's slots, so that a git client
# (Fork and the like) shows the local branches of every slot at once. Dot-sourced by unity-slot.ps1.
# ASCII-only source.
#
#   unity-slot branch-view [-Project <repo>[,...]] [-Apply] [-Json]
#
# A view is a folder <root>\<name> holding only its git directory <root>\<name>\.git (Fork does not open a
# bare repository). Nothing is ever checked out: HEAD stays an unborn branch and refs/heads stays empty,
# so the folder has no commits and a clean status; every ref lives under refs/remotes. The folder is what
# a person opens (path in -Json, the state file and the dashboard); gitDir is its .git.
#
# Without -Apply it shows the plan and writes nothing (not even the root folder). With -Apply, for each
# project with at least branchView.minSlots slots (or with a view already):
#   1. lock     <root>\<name>.view-lock opened without sharing; another run holds it: exit 4
#   1b. move    the older bare form <root>\<name>.git (marked unity-slot.project = this project, and no
#               <root>\<name> yet) is moved to <root>\<name>\.git on the same volume and gets core.bare
#               false; refs, remotes and the state file carry on, nothing is fetched again. A bare folder
#               marked for another project, or a <root>\<name> that is no view of this project: left
#               alone, error.
#   2. create   git init <root>\<name> (not bare, never git clone: a local clone hard-links the slot's packs;
#               no checkout, no read-tree, no local branch)
#   3. remotes  one per slot: url and pushurl unity-slot-view://<remote> (a placeholder no git can reach),
#               fetch +refs/heads/*:refs/remotes/<remote>/*, tagOpt --no-tags, followRemoteHEAD always,
#               skipFetchAll (and its older name skipDefaultUpdate) true and the marker unityslot=true.
#               Only marked remotes are changed or removed; remotes of slots that left the registry (or
#               were renamed) go, with their refs.
#   4. skip     (no git) missing folder; busy: gc.pid under 12 h, or objects\maintenance.lock or a temporary
#               pack file (objects\pack\tmp_* / .tmp-*) under 1 h (older ones are reported, not skipped);
#               unchanged: the ref signature (every file under refs\heads with its path, size and time,
#               HEAD, packed-refs, shallow, reftable\tables.list) equals the one of the last good fetch
#   5. fetch    only here does a placeholder lead to the slot:
#               git -c url.<slot>.insteadOf=unity-slot-view://<remote> fetch --prune --porcelain
#               --no-write-fetch-head --no-auto-gc <remote>, with GIT_OPTIONAL_LOCKS=0 and GIT_TERMINAL_PROMPT=0.
#               The signature is taken right before. A detached slot also gives refs/remotes/<remote>/(detached)
#               (fetched again when that ref is missing); shallow slots come last, with --update-shallow; a
#               ref lock conflict in the view is tried once more after 1 s.
#   6. origin   refs/remotes/origin/* of the slot whose FETCH_HEAD is newest, fast-forward only (no network;
#               --update-shallow when that slot is shallow); refused refs (force-pushed or deleted
#               upstream) go to origin.rejected[] of the state file. A
#               refused ref whose slot value is an ancestor of the view's is not stale (a git client fetched
#               origin in the view meanwhile): it is kept and only counted (origin.ahead in -Json).
#   7. finish   <root>\<name>.view.json (schema unity-slot.branch-view/1) written to a temporary file and
#               swapped in, git gc --auto in the view only, event "branchview".
# The lock and state files stay next to the folder, so the folder's status stays clean. Git on a view runs
# no hooks and always names its git directory and folder (Invoke-ViewGit). A git client's own fetch of a
# slot remote fails on the placeholder URL; that is harmless (origin still fetches).
# Slots are only read. The core is the only reader on purpose: on Windows a reader can make a slot's own
# repack fail, so a git client that fetches the view's slot remotes gets "remote helper aborted". For the
# same reason origin keeps a placeholder URL too when the registry's origin is a slot folder, busy is
# checked again right before each slot's fetch (a first run can take minutes), and branchView.root may
# not lie inside a slot. Not a backup: --prune drops what a slot deleted.
#
# The dashboard's branchViews[] (Get-BranchViewEntries in lib\dashboard.ps1) reads the state files and the
# slots' ref signatures (Get-SlotRefSignature here), no git.
#
# Exit codes: 0 ok (failed slots are listed), 1 error, 4 another branch-view run holds a view's lock.
# -Json: stdout gets one document {"schema":"unity-slot.branch-view/1",...,"views":[...]}; progress lines,
# git output and errors go to stderr.

$script:BranchViewSchema = 'unity-slot.branch-view/1'
$script:ViewUrlScheme = 'unity-slot-view://'
$script:GitExe = $null
# width of the name column in the output lines (the longest slot name of the project, at least 24)
$script:BvWidth = 24
# every registry slot of this run (any project), for the origin URL check
$script:BvRegistrySlots = @()

# ------------------------------------------------------------------ settings and names

function Get-BranchViewRoot {
    $raw = [string](Get-Prop (Get-Setting 'branchView') 'root')
    if (-not $raw.Trim()) { $raw = '{state}\view' }
    return (Get-NormPath (Expand-SlotText $raw $null))
}

function Get-BranchViewMinSlots {
    $n = 0
    try { $n = [int](Get-Prop (Get-Setting 'branchView') 'minSlots') } catch { }
    if ($n -lt 1) { $n = 2 }
    return $n
}

# A remote name for a slot: letters, digits, "_" and "-" only, never "origin".
function ConvertTo-ViewRemoteName([string]$Name) {
    $n = [regex]::Replace(([string]$Name).Trim(), '[^A-Za-z0-9_-]', '_').TrimStart('-')
    if (-not $n) { $n = 'slot' }
    if ($n -eq 'origin') { $n = 'origin_' }
    return $n
}

# A file name part for a view: no path separators or characters Windows refuses.
function ConvertTo-ViewFileName([string]$Name) {
    return ([regex]::Replace(([string]$Name).Trim(), '[^A-Za-z0-9._-]', '_').Trim('.'))
}

# The project key branch-view groups a registry slot by (the dashboard uses the same): project, else repo.
function Get-BranchViewKey($Slot) {
    $key = ([string]$Slot.project).Trim().ToLowerInvariant()
    if (-not $key) { $key = ([string]$Slot.repo).Trim().ToLowerInvariant() }
    return $key
}

# $true when $Path is $Dir or lies below it (full paths, case-insensitive).
function Test-PathWithin([string]$Path, [string]$Dir) {
    $p = Get-NormPath $Path
    $d = Get-NormPath $Dir
    if (-not $p -or -not $d) { return $false }
    if ($p.Equals($d, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($d.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# The registered slot (any project) a local URL (a drive or UNC path, file://) points into, else $null.
# A view's origin with such a URL would let a git client read that slot, so it gets a placeholder.
function Get-SlotOfLocalUrl([string]$Url, $Slots) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $p = $Url.Trim()
    if ($p -match '^(?i)file://') {
        $p = $p.Substring(7)
        if ($p -match '^/[A-Za-z]:') { $p = $p.Substring(1) }
        elseif ($p -notmatch '^[A-Za-z]:') { $p = '\\' + $p.TrimStart('/') }
    } elseif ($p -notmatch '^[A-Za-z]:[\\/]' -and $p -notmatch '^[\\/]{2}[^\\/]') { return $null }
    foreach ($s in $Slots) {
        if ($null -ne $s -and $s.path -and (Test-PathWithin $p ([string]$s.path))) { return $s }
    }
    return $null
}

# A URL for output: user and password (or a token) before the host are masked.
function Protect-Url([string]$Url) {
    if (-not $Url) { return $Url }
    return [regex]::Replace($Url, '(?i)^([a-z][a-z0-9+.-]*://)[^/@]+@', '$1***@')
}

function Format-Age([TimeSpan]$Age) {
    if ($Age.TotalMinutes -lt 1) { return ('{0} s' -f [int]$Age.TotalSeconds) }
    if ($Age.TotalHours -lt 1) { return ('{0} min' -f [int]$Age.TotalMinutes) }
    if ($Age.TotalDays -lt 2) { return ('{0} h' -f [int]$Age.TotalHours) }
    return ('{0} d' -f [int]$Age.TotalDays)
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0} GB' -f ($Bytes / 1GB).ToString('0.0', $script:Inv)) }
    if ($Bytes -ge 1MB) { return ('{0} MB' -f [math]::Round($Bytes / 1MB)) }
    return ('{0} KB' -f [math]::Ceiling($Bytes / 1KB))
}

# ------------------------------------------------------------------ reading a slot (files only, no git)

# The slot's ref signature: every file under refs\heads (path, size, time; lock files left out), the HEAD
# text, and size and time of packed-refs, shallow and reftable\tables.list. A commit on a nested branch
# (feature/x) changes only its own file, so the folder times alone would miss it. $null without a git dir.
function Get-SlotRefSignature([string]$GitDir, [string]$CommonDir) {
    if (-not $CommonDir -or -not (Test-Path -LiteralPath $CommonDir -PathType Container)) { return $null }
    if (-not $GitDir) { $GitDir = $CommonDir }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('HEAD ').Append(([string](Read-GitFile (Join-Path $GitDir 'HEAD'))).Trim()).Append("`n")
    Add-FileStamps $sb $CommonDir @('packed-refs', 'shallow', 'reftable\tables.list')
    Add-RefTreeStamps $sb (Join-Path $CommonDir 'refs\heads')
    return (Get-TextHash $sb.ToString())
}

# Signature of what an origin fill reads from a slot: FETCH_HEAD, packed-refs and refs\remotes\origin
# (a push moves refs/remotes/origin/<branch> without a fetch). $null without a git dir.
function Get-OriginRefSignature([string]$CommonDir) {
    if (-not $CommonDir -or -not (Test-Path -LiteralPath $CommonDir -PathType Container)) { return $null }
    $sb = New-Object Text.StringBuilder
    Add-FileStamps $sb $CommonDir @('FETCH_HEAD', 'packed-refs', 'reftable\tables.list')
    Add-RefTreeStamps $sb (Join-Path $CommonDir 'refs\remotes\origin')
    return (Get-TextHash $sb.ToString())
}

function Add-FileStamps($Sb, [string]$Dir, [string[]]$Names) {
    foreach ($name in $Names) {
        $fi = New-Object IO.FileInfo((Join-Path $Dir $name))
        if ($fi.Exists) { [void]$Sb.Append($name).Append(' ').Append($fi.Length).Append(' ').Append($fi.LastWriteTimeUtc.Ticks).Append("`n") }
    }
}

# Every file below $Dir (relative path, size, time), sorted; lock files left out.
function Add-RefTreeStamps($Sb, [string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    $rows = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($Dir, '*', [IO.SearchOption]::AllDirectories)) {
            if ($f.EndsWith('.lock', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $fi = New-Object IO.FileInfo($f)
            $len = -1
            if ($fi.Exists) { $len = $fi.Length }
            $rows.Add(('{0} {1} {2}' -f $f.Substring($Dir.Length), $len, $fi.LastWriteTimeUtc.Ticks))
        }
    } catch { $rows.Add('unreadable ' + $_.Exception.GetType().Name) }
    $rows.Sort([StringComparer]::Ordinal)
    foreach ($r in $rows) { [void]$Sb.Append('ref ').Append($r).Append("`n") }
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($script:Utf8NoBom.GetBytes($Text)) } finally { $sha.Dispose() }
    return (-join ($hash[0..15] | ForEach-Object { $_.ToString('x2') }))
}

# A git process may be rewriting the slot's objects: gc.pid under 12 h, objects\maintenance.lock or a
# temporary pack file under 1 h = busy (Reason). Older ones are only reported (Leftovers): an interrupted
# run leaves them, and skipping on them would skip the slot until git prunes them.
function Get-SlotBusy([string]$CommonDir, [datetime]$Now) {
    $r = [pscustomobject]@{ Reason = $null; Leftovers = (New-Object 'System.Collections.Generic.List[string]') }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $gcPid = New-Object IO.FileInfo((Join-Path $CommonDir 'gc.pid'))
    if ($gcPid.Exists) { $files.Add([pscustomobject]@{ Rel = 'gc.pid'; Item = $gcPid; Hours = 12 }) }
    $ml = New-Object IO.FileInfo((Join-Path $CommonDir 'objects\maintenance.lock'))
    if ($ml.Exists) { $files.Add([pscustomobject]@{ Rel = 'objects\maintenance.lock'; Item = $ml; Hours = 1 }) }
    $packDir = Join-Path $CommonDir 'objects\pack'
    if (Test-Path -LiteralPath $packDir -PathType Container) {
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($packDir)) {
                $leaf = [IO.Path]::GetFileName($f)
                if ($leaf.StartsWith('tmp_') -or $leaf.StartsWith('.tmp-')) {
                    $files.Add([pscustomobject]@{ Rel = ('objects\pack\' + $leaf); Item = (New-Object IO.FileInfo($f)); Hours = 1 })
                }
            }
        } catch { }
    }
    foreach ($x in $files) {
        $age = $Now - $x.Item.LastWriteTime
        if ($age.TotalHours -lt $x.Hours) {
            if (-not $r.Reason) { $r.Reason = ('{0} {1} old' -f $x.Rel, (Format-Age $age)) }
        } else {
            $r.Leftovers.Add(('{0} ({1} old)' -f $x.Rel, (Format-Age $age)))
        }
    }
    return $r
}

# Bytes of everything under a view's objects folder (packs and loose objects: small fetches unpack).
function Get-ViewBytes([string]$View) {
    $dir = Join-Path $View 'objects'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [long]0 }
    $sum = [long]0
    try { foreach ($f in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { $sum += (New-Object IO.FileInfo($f)).Length } } catch { }
    return $sum
}

# Bytes of the pack files under <git dir>\objects\pack (a size estimate; loose objects left out).
function Get-PackBytes([string]$GitDir) {
    $dir = Join-Path $GitDir 'objects\pack'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [long]0 }
    $sum = [long]0
    try { foreach ($f in [IO.Directory]::EnumerateFiles($dir, '*.pack')) { $sum += (New-Object IO.FileInfo($f)).Length } } catch { }
    return $sum
}

# One slot as branch-view sees it (files only): folders, detached, shallow, busy, signature, FETCH_HEAD.
function Get-ViewSlotFacts($Slot, [datetime]$Now) {
    $f = [pscustomobject]@{ Exists = $false; GitDir = $null; CommonDir = $null; Detached = $false; Shallow = $false
        Busy = $null; Leftovers = @(); Signature = $null; FetchHeadAt = $null; OriginSignature = $null; Error = $null }
    if (-not $Slot.path -or -not (Test-Path -LiteralPath $Slot.path -PathType Container)) { return $f }
    $f.Exists = $true
    $dirs = Get-GitDirs $Slot.path
    if (-not $dirs.CommonDir -or -not (Test-Path -LiteralPath $dirs.CommonDir -PathType Container)) {
        $f.Error = 'not a git working folder (no .git)'
        return $f
    }
    $f.GitDir = $dirs.GitDir
    $f.CommonDir = $dirs.CommonDir
    $f.Detached = (([string](Read-GitFile (Join-Path $dirs.GitDir 'HEAD'))).Trim() -match '^[0-9a-f]{40,64}$')
    $f.Shallow = Test-Path -LiteralPath (Join-Path $dirs.CommonDir 'shallow') -PathType Leaf
    $busy = Get-SlotBusy $dirs.CommonDir $Now
    $f.Busy = $busy.Reason
    $f.Leftovers = $busy.Leftovers.ToArray()
    $f.Signature = Get-SlotRefSignature $dirs.GitDir $dirs.CommonDir
    $fh = New-Object IO.FileInfo((Join-Path $dirs.CommonDir 'FETCH_HEAD'))
    if ($fh.Exists) { $f.FetchHeadAt = $fh.LastWriteTime }
    $f.OriginSignature = Get-OriginRefSignature $dirs.CommonDir
    return $f
}

# ------------------------------------------------------------------ state file and lock

function Get-ViewStatePath([string]$Root, [string]$Name) { return (Join-Path $Root ($Name + '.view.json')) }

# The state file (shared read, so a writer may still swap it); $null when missing or unreadable.
function Read-ViewState([string]$File) {
    $text = Read-GitFile $File
    if ($null -eq $text -or -not $text.Trim()) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# Written to a temporary file and swapped in; tried a few times while a reader holds the old one.
function Write-ViewState([string]$File, $State) {
    $text = ($State | ConvertTo-Json -Depth 10) + "`n"
    $tmp = '{0}.{1}.tmp' -f $File, $PID
    [IO.File]::WriteAllText($tmp, $text, $script:Utf8NoBom)
    $last = $null
    for ($try = 0; $try -lt 10; $try++) {
        try {
            # [NullString]: PowerShell would pass $null as "" (an invalid backup path)
            if (Test-Path -LiteralPath $File -PathType Leaf) { [IO.File]::Replace($tmp, $File, [NullString]::Value) }
            else { [IO.File]::Move($tmp, $File) }
            return
        } catch { $last = $_.Exception; Start-Sleep -Milliseconds 150 }
    }
    try { Remove-Item -LiteralPath $tmp -Force } catch { }
    throw ('could not write {0}: {1}' -f $File, $last.Message)
}

# $true while another run holds the lock file (opened without sharing). Opens nothing for writing.
function Test-ViewLockHeld([string]$LockFile) {
    if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) { return $false }
    try {
        $s = [IO.File]::Open($LockFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $s.Dispose()
        return $false
    } catch { return $true }
}

# ------------------------------------------------------------------ git on the view

function Get-GitExe {
    if ($null -eq $script:GitExe) {
        $cmd = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -eq 0) { throw 'git not found on PATH' }
        $script:GitExe = $cmd[0].Source
    }
    return $script:GitExe
}

# One git run with its own environment (GIT_OPTIONAL_LOCKS=0, GIT_TERMINAL_PROMPT=0, no GIT_DIR and the
# like from the caller). -View runs it on that git directory (--git-dir, so safe.bareRepository=explicit
# does not refuse the older bare form; with --work-tree=<folder> for the folder form <folder>\.git, so the
# caller's current folder never counts as its work tree) without hooks: core.hooksPath names a folder
# nothing makes, so neither a global hooks path nor a hook someone put in the view's hooks folder
# (reference-transaction, pre-auto-gc) runs. Waits as long as git runs; never killed.
function Invoke-ViewGit([string[]]$GitArgs, [string]$View = '') {
    $all = New-Object 'System.Collections.Generic.List[string]'
    if ($View) {
        $all.Add('--git-dir=' + $View)
        if ((Split-Path $View -Leaf) -eq '.git') { $all.Add('--work-tree=' + (Split-Path $View -Parent)) }
        $all.Add('-c'); $all.Add('core.hooksPath=' + (Join-Path $View 'unity-slot-no-hooks'))
    }
    $all.Add('-c'); $all.Add('core.quotepath=false')
    foreach ($a in $GitArgs) { $all.Add($a) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Get-GitExe
    $psi.Arguments = (@($all | ForEach-Object { ConvertTo-WinArg $_ })) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($k in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE')) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
    }
    $psi.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $out = @($outTask.Result -split "`r?`n" | Where-Object { $_ -ne '' })
    $err = @($errTask.Result -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err }
}

# Remotes of a view from its config file: name -> @{ key (lower case) -> values }.
function Get-ViewRemoteConfig([string]$View) {
    $map = [ordered]@{}
    $cfg = Join-Path $View 'config'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return $map }
    $r = Invoke-ViewGit @('config', '--file', $cfg, '--get-regexp', '^remote\.')
    foreach ($line in $r.Out) {
        # remote names have no spaces (git refuses them), values may have dots
        $m = [regex]::Match([string]$line, '^remote\.(\S+)\.([A-Za-z0-9-]+)(?: (.*))?$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        if (-not $map.Contains($name)) { $map[$name] = @{} }
        $key = $m.Groups[2].Value.ToLowerInvariant()
        if (-not $map[$name].ContainsKey($key)) { $map[$name][$key] = New-Object 'System.Collections.Generic.List[string]' }
        $map[$name][$key].Add($m.Groups[3].Value)
    }
    return $map
}

function Get-ViewConfigValue([string]$View, [string]$Key) {
    $cfg = Join-Path $View 'config'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return '' }
    $r = Invoke-ViewGit @('config', '--file', $cfg, '--get', $Key)
    if ($r.Code -ne 0 -or $r.Out.Count -eq 0) { return '' }
    return [string]$r.Out[0]
}

# Settings a slot remote must have (keys in lower case, as git config prints them). skipDefaultUpdate is
# the older name of skipFetchAll (an older git knows only it), for git clients that bring their own git.
function Get-WantedRemoteKeys([string]$Remote) {
    $url = $script:ViewUrlScheme + $Remote
    return [ordered]@{
        url = $url; pushurl = $url; fetch = ('+refs/heads/*:refs/remotes/{0}/*' -f $Remote); tagopt = '--no-tags'
        followremotehead = 'always'; skipfetchall = 'true'; skipdefaultupdate = 'true'; unityslot = 'true'
    }
}

# Config keys of a marked remote that differ from what it should have.
function Get-RemoteDrift($Have, $Want) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @($Want.Keys)) {
        $vals = @()
        if ($null -ne $Have -and $Have.ContainsKey($k)) { $vals = @($Have[$k]) }
        if ($vals.Count -ne 1 -or [string]$vals[0] -ne [string]$Want[$k]) { $out.Add($k) }
    }
    return $out.ToArray()
}

function Test-ViewRefExists([string]$View, [string]$Ref) {
    if (Test-Path -LiteralPath (Join-Path $View ($Ref.Replace('/', '\'))) -PathType Leaf) { return $true }
    $packed = Read-GitFile (Join-Path $View 'packed-refs')
    if ($null -eq $packed) { return $false }
    foreach ($line in ($packed -split "`n")) {
        $p = $line.Trim().Split(' ')
        if ($p.Count -eq 2 -and $p[1] -eq $Ref) { return $true }
    }
    return $false
}

# Lines of "git fetch --porcelain": flag, old, new, ref. Up-to-date lines (=) are not updates.
function Read-FetchPorcelain([string[]]$Lines) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in $Lines) {
        $m = [regex]::Match([string]$l, '^([ +\-*!t=]) ([0-9a-f]{40,64}) ([0-9a-f]{40,64}) (.+)$')
        if ($m.Success) { $list.Add([pscustomobject]@{ Flag = $m.Groups[1].Value; Old = $m.Groups[2].Value; New = $m.Groups[3].Value; Ref = $m.Groups[4].Value }) }
    }
    return $list.ToArray()
}

function Test-RefLockConflict($Run) {
    return [regex]::IsMatch((@($Run.Err) -join "`n"), "(?i)cannot lock ref|unable to create '[^']*\.lock'|could not lock|unable to update local ref")
}

function Format-GitError($Run) {
    $lines = @(@($Run.Err) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch '^(hint|warning):' })
    if ($lines.Count -eq 0) { return ('git exit {0}' -f $Run.Code) }
    return (Protect-Text (($lines | Select-Object -Last 2) -join ' | '))
}

# ------------------------------------------------------------------ projects

# Registry slots grouped by project (registry order), narrowed by -Project.
function Get-BranchViewGroups($Reg) {
    $filters = @(Get-ProjectFilters)
    $groups = [ordered]@{}
    foreach ($s in $Reg.slots) {
        if ($filters.Count -gt 0) {
            $hit = $false
            foreach ($f in $filters) { if (Test-SlotProject $s $f) { $hit = $true } }
            if (-not $hit) { continue }
        }
        $key = Get-BranchViewKey $s
        if (-not $key) { continue }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{ Project = $key; Repo = [string]$s.repo; Origin = ''; Slots = (New-Object 'System.Collections.Generic.List[object]') }
        }
        $g = $groups[$key]
        if (-not $g.Repo -and $s.repo) { $g.Repo = [string]$s.repo }
        if (-not $g.Origin -and $s.origin) { $g.Origin = [string]$s.origin }
        $g.Slots.Add($s)
    }
    return @($groups.Values)
}

# <repo>, else <owner>-<repo>, else with a number: a name no other project's view or this run uses.
function Resolve-ViewName($Group, [string]$Root, $Taken) {
    $base = ConvertTo-ViewFileName $Group.Repo
    if (-not $base) { $base = ConvertTo-ViewFileName (($Group.Project -split '/')[-1]) }
    if (-not $base) { $base = 'view' }
    $cands = New-Object 'System.Collections.Generic.List[string]'
    $cands.Add($base)
    if ($Group.Project.Contains('/')) { $cands.Add((ConvertTo-ViewFileName ((($Group.Project -split '/')[0]) + '-' + $base))) }
    for ($i = 2; $i -lt 100; $i++) { $cands.Add(('{0}-{1}' -f $base, $i)) }
    foreach ($c in $cands) {
        if (-not $c -or $Taken.ContainsKey($c.ToLowerInvariant())) { continue }
        $owner = ''
        $st = Read-ViewState (Get-ViewStatePath $Root $c)
        if ($null -ne $st) { $owner = [string](Get-Prop $st 'project') }
        else {
            # the folder form's git directory, else the older bare form; a folder or repository nobody
            # marked: leave it alone
            $folder = Join-Path $Root $c
            $oldDir = Join-Path $Root ($c + '.git')
            if (Test-Path -LiteralPath (Join-Path $folder '.git') -PathType Container) { $owner = Get-ViewConfigValue (Join-Path $folder '.git') 'unity-slot.project' }
            elseif (Test-Path -LiteralPath $oldDir -PathType Container) { $owner = Get-ViewConfigValue $oldDir 'unity-slot.project' }
            if (-not $owner -and ((Test-Path -LiteralPath $folder) -or (Test-Path -LiteralPath $oldDir))) { $owner = '?' }
        }
        if ($owner -and $owner -ne $Group.Project) { continue }
        $Taken[$c.ToLowerInvariant()] = $true
        return $c
    }
    throw ('no free view name for ' + $Group.Project)
}

# The older bare form <root>\<name>.git against the folder form <folder>\.git: $null when there is nothing
# to move (the folder form exists, or neither), else From (the bare folder to move, or $null) and Error
# (why nothing is touched). A folder that is no view of this project is never written into.
function Get-ViewMove([string]$Project, [string]$Folder, [string]$GitDir, [string]$OldDir) {
    if (Test-Path -LiteralPath (Join-Path $GitDir 'HEAD') -PathType Leaf) { return $null }
    $folderUsed = $false
    if (Test-Path -LiteralPath $Folder -PathType Leaf) { $folderUsed = $true }
    elseif (Test-Path -LiteralPath $Folder -PathType Container) {
        try { $folderUsed = @([IO.Directory]::EnumerateFileSystemEntries($Folder)).Count -gt 0 } catch { $folderUsed = $true }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $OldDir 'HEAD') -PathType Leaf)) {
        if (-not $folderUsed) { return $null }
        return [pscustomobject]@{ From = $null; Error = ('{0} exists and is no view of this project (no .git\HEAD); left alone. Move it away, or set branchView.root elsewhere' -f $Folder) }
    }
    $r = [pscustomobject]@{ From = $OldDir; Error = $null }
    $owner = Get-ViewConfigValue $OldDir 'unity-slot.project'
    if ($owner -ne $Project) { $r.Error = ('the older bare view {0} is marked for project "{1}", not this one; left alone' -f $OldDir, $owner) }
    elseif ($folderUsed) { $r.Error = ('{0} already exists, so the older bare view {1} cannot move there; both left alone. Move that folder away, then run again' -f $Folder, $OldDir) }
    return $r
}

function Set-ViewMoveError($Entry, $Move) {
    $Entry.action = 'error'
    $Entry.error = $Move.Error
    Write-BranchViewLine ('{0}: ERROR {1}' -f $Entry.project, $Move.Error)
    return $Entry
}

# The older bare form moved (renamed on the same volume, not copied) to <folder>\.git, then core.bare false.
function Move-ViewToFolder([string]$OldDir, [string]$Folder, [string]$GitDir) {
    $made = $false
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $Folder); $made = $true }
    try { [IO.Directory]::Move($OldDir, $GitDir) }
    catch {
        if ($made) { try { [IO.Directory]::Delete($Folder) } catch { } }   # still empty
        throw ('could not move {0} to {1}: {2}' -f $OldDir, $GitDir, $_.Exception.Message)
    }
    $r = Invoke-ViewGit @('config', '--file', (Join-Path $GitDir 'config'), 'core.bare', 'false')
    if ($r.Code -ne 0) { throw ('git config core.bare false failed in {0}: {1}' -f $GitDir, (Format-GitError $r)) }
    # hidden like the .git that git init makes
    try { $di = New-Object IO.DirectoryInfo($GitDir); $di.Attributes = $di.Attributes -bor [IO.FileAttributes]::Hidden } catch { }
}

# ------------------------------------------------------------------ output

function Write-BranchViewLine([string]$Text) {
    if ($Json) { [Console]::Error.WriteLine('[branch-view] ' + $Text) } else { Say $Text }
}

function New-ViewSlotOut([string]$SlotName, [string]$Remote, [string]$Path) {
    return [ordered]@{ slot = $SlotName; remote = $Remote; status = $null; fetchedAt = $null; changedSince = $null; error = $null
        path = $Path; action = $null; updates = $null; detached = $false; shallow = $false; note = $null; leftovers = @(); signature = $null }
}

function Format-SlotAction($S) {
    switch ([string]$S.action) {
        'fetch' { return ('fetch ({0})' -f $S.note) }
        'fetched' { return ('fetched, {0} ref update(s)' -f [int]$S.updates) }
        'unchanged' { return 'unchanged' }
        'busy' { return ('SKIP busy ({0})' -f $S.note) }
        'missing' { return ('SKIP missing ({0})' -f $S.path) }
        'failed' { return ('FAILED {0}' -f $S.error) }
    }
    return [string]$S.action
}

# ------------------------------------------------------------------ the command

function Invoke-BranchView {
    if (-not [string]::IsNullOrWhiteSpace($Target)) { throw 'usage: unity-slot branch-view [-Project <repo>[,...]] [-Apply] [-Json]' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $root = Get-BranchViewRoot
    $minSlots = Get-BranchViewMinSlots
    $apply = $Apply.IsPresent
    $reg = Read-Registry
    $groups = @(Get-BranchViewGroups $reg)
    if ($groups.Count -eq 0) {
        if (@(Get-ProjectFilters).Count -gt 0) { throw ('no registered slot matches -Project {0}. See: unity-slot slots' -f ((@(Get-ProjectFilters)) -join ',')) }
        throw 'the registry has no slots. See: unity-slot scan'
    }
    if (Test-Path -LiteralPath $root -PathType Leaf) { throw ('branchView.root is a file: ' + $root) }
    # (no @() around the registry's slot list: PowerShell 5.1 refuses it for a List[object])
    foreach ($s in $reg.slots) {
        if ($s.path -and (Test-PathWithin $root ([string]$s.path))) {
            throw ('branchView.root {0} is inside slot {1}; keep it outside the slots (and the scan roots)' -f $root, $s.name)
        }
    }
    $script:BvRegistrySlots = $reg.slots
    $mode = 'dry run: nothing is written; -Apply makes or refreshes the views'
    if ($apply) { $mode = 'apply' }
    Write-BranchViewLine ('root    {0} ({1})' -f $root, $mode)

    $taken = @{}
    $views = New-Object 'System.Collections.Generic.List[object]'
    $anyError = $false
    $anyBusy = $false
    $anyWork = $false
    foreach ($g in $groups) {
        $entry = $null
        try {
            $entry = Invoke-BranchViewProject $g $root $minSlots $apply $taken
            if ($entry.error) {
                if ($entry.action -eq 'busy') { $anyBusy = $true } else { $anyError = $true }
            }
            if ($entry.action -eq 'create' -or ($entry.action -eq 'refresh' -and -not $apply) -or ($entry.moveFrom -and -not $apply -and -not $entry.error)) { $anyWork = $true }
        } catch {
            $msg = Protect-Text $_.Exception.Message
            Write-BranchViewLine ('{0}: ERROR {1}' -f $g.Project, $msg)
            $entry = [ordered]@{ project = $g.Project; repo = $g.Repo; path = $null; gitDir = $null; createdAt = $null; updatedAt = $null; coreVersion = $null
                slots = @(); origin = [ordered]@{ filledFrom = $null; rejected = @() }; error = $msg
                name = $null; exists = $false; action = 'error'; reason = $null; moveFrom = $null; remotes = $null; sizeBytes = $null; estimatedBytes = $null; seconds = $null }
            $anyError = $true
        }
        $views.Add($entry)
    }
    if (-not $apply -and $anyWork) {
        $p = ''
        if (@(Get-ProjectFilters).Count -gt 0) { $p = ' -Project ' + ((@(Get-ProjectFilters)) -join ',') }
        Write-BranchViewLine ('next    unity-slot branch-view{0} -Apply' -f $p)
    }
    if ($anyError) { $script:ExitCode = 1 } elseif ($anyBusy) { $script:ExitCode = 4 }
    if ($Json) {
        $doc = [ordered]@{
            schema = $script:BranchViewSchema; version = $script:UnitySlotVersion; time = (Format-Iso (Get-Date)); apply = $apply
            root = $root; minSlots = $minSlots; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); views = $views.ToArray()
        }
        [Console]::Out.Write(($doc | ConvertTo-Json -Compress -Depth 10) + "`n")
        [Console]::Out.Flush()
    }
}

# One project: the plan, and with -Apply the work under the view's lock. Returns its views[] entry.
function Invoke-BranchViewProject($Group, [string]$Root, [int]$MinSlots, [bool]$DoApply, $Taken) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $name = Resolve-ViewName $Group $Root $Taken
    $folder = Join-Path $Root $name
    $view = Join-Path $folder '.git'
    $oldDir = Join-Path $Root ($name + '.git')
    $stateFile = Get-ViewStatePath $Root $name
    $lockFile = Join-Path $Root ($name + '.view-lock')
    $entry = [ordered]@{
        project = $Group.Project; repo = $Group.Repo; path = $folder; gitDir = $view; createdAt = $null; updatedAt = $null; coreVersion = $null
        slots = @(); origin = [ordered]@{ filledFrom = $null; rejected = @() }; error = $null
        name = $name; exists = $false; action = 'none'; reason = $null; moveFrom = $null
        remotes = [ordered]@{ add = @(); update = @(); remove = @(); conflict = @() }; sizeBytes = $null; estimatedBytes = $null; seconds = $null
    }
    $move = Get-ViewMove $Group.Project $folder $view $oldDir
    if ($null -ne $move) { $entry.moveFrom = $move.From }
    if ($Group.Slots.Count -lt $MinSlots -and -not (Test-Path -LiteralPath (Join-Path $view 'HEAD') -PathType Leaf) -and -not $entry.moveFrom) {
        $entry.action = 'skip'
        $entry.reason = ('{0} slot(s), branchView.minSlots {1}' -f $Group.Slots.Count, $MinSlots)
        Write-BranchViewLine ('{0}: not made ({1})' -f $Group.Project, $entry.reason)
        return $entry
    }
    if ($null -ne $move -and $move.Error) { return (Set-ViewMoveError $entry $move) }
    $script:BvWidth = 24
    foreach ($s in $Group.Slots) { if (([string]$s.name).Length -gt $script:BvWidth) { $script:BvWidth = ([string]$s.name).Length } }
    $plan = $null
    if (-not $DoApply) {
        # a pending move: the plan reads the older bare form, where the refs and remotes are now
        $readDir = $view
        if ($entry.moveFrom) { $readDir = $entry.moveFrom }
        $plan = Get-BranchViewPlan $Group $readDir $stateFile $entry
        Write-BranchViewPlan $entry $plan (Test-ViewLockHeld $lockFile)
    } else {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { [void](New-Item -ItemType Directory -Path $Root -Force) }
        $lock = $null
        try { $lock = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            $entry.action = 'busy'
            $entry.error = ('another branch-view run holds {0}' -f $lockFile)
            Write-BranchViewLine ('{0}: BUSY {1}; nothing done' -f $Group.Project, $entry.error)
            return $entry
        }
        try {
            # the move is checked again and done under the lock; another run may have moved it meanwhile
            $move = Get-ViewMove $Group.Project $folder $view $oldDir
            if ($null -ne $move -and $move.Error) { return (Set-ViewMoveError $entry $move) }
            if ($null -ne $move) {
                $entry.moveFrom = $move.From
                Move-ViewToFolder $move.From $folder $view
                Write-BranchViewLine ('{0}: moved the older bare form {1} to {2}' -f $Group.Project, $move.From, $view)
            }
            # planned under the lock, so no other run changes the view meanwhile
            $plan = Get-BranchViewPlan $Group $view $stateFile $entry
            Invoke-BranchViewApply $Group $view $stateFile $entry $plan
        } finally {
            $lock.Dispose()
        }
    }
    $outs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in $plan.Items) {
        $o = $it.Out
        $o.Remove('signature')
        $outs.Add($o)
    }
    $entry.slots = $outs.ToArray()
    if ($entry.origin.Contains('signature')) { $entry.origin.Remove('signature') }
    $entry.seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    return $entry
}

# What the slots and the view look like now (files and git config only), and what a run would do.
# Fills the entry's plan fields and returns Items (per slot: Slot, Out, Facts, Kind, Want), ToRemove,
# Have, OriginSrc, State.
function Get-BranchViewPlan($Group, [string]$View, [string]$StateFile, $Entry) {
    $now = Get-Date
    $exists = Test-Path -LiteralPath (Join-Path $View 'HEAD') -PathType Leaf
    $state = Read-ViewState $StateFile
    $stOrigin = Get-Prop $state 'origin'
    $Entry.exists = [bool]$exists
    $Entry.createdAt = Get-Prop $state 'createdAt'
    $Entry.updatedAt = Get-Prop $state 'updatedAt'
    $Entry.coreVersion = Get-Prop $state 'coreVersion'
    # origin keeps the registry's URL, unless that is a slot folder: then a placeholder like the slot remotes
    $originUrl = [string]$Group.Origin
    $originSlot = Get-SlotOfLocalUrl $originUrl $script:BvRegistrySlots
    $urlNote = $null
    if ($null -ne $originSlot) {
        $originUrl = $script:ViewUrlScheme + 'origin'
        $urlNote = ('the registry''s origin is the folder of slot {0}; the view keeps a placeholder URL so a git client cannot read it' -f $originSlot.name)
    }
    $Entry.origin = [ordered]@{
        filledFrom = (Get-Prop $stOrigin 'filledFrom'); rejected = @(@(Get-Prop $stOrigin 'rejected') | Where-Object { $null -ne $_ })
        ahead = @(); url = (Protect-Url $originUrl); urlNote = $urlNote; action = 'none'; source = $null; updates = $null; error = (Get-Prop $stOrigin 'error')
        filledAt = (Get-Prop $stOrigin 'filledAt'); fetchHeadAt = (Get-Prop $stOrigin 'fetchHeadAt'); signature = (Get-Prop $stOrigin 'signature')
    }

    $prev = @{}
    foreach ($ps in @(Get-Prop $state 'slots')) { if ($null -ne $ps -and (Get-Prop $ps 'slot')) { $prev[([string](Get-Prop $ps 'slot')).ToLowerInvariant()] = $ps } }
    $have = [ordered]@{}
    if ($exists) { $have = Get-ViewRemoteConfig $View }
    $usedRemotes = @{ origin = $true }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $Group.Slots) {
        $remote = ConvertTo-ViewRemoteName $s.name
        $base = $remote
        for ($i = 2; $usedRemotes.ContainsKey($remote.ToLowerInvariant()); $i++) { $remote = '{0}-{1}' -f $base, $i }
        $usedRemotes[$remote.ToLowerInvariant()] = $true
        $o = New-ViewSlotOut $s.name $remote $s.path
        $facts = Get-ViewSlotFacts $s $now
        $p = $null
        if ($prev.ContainsKey($s.name.ToLowerInvariant())) { $p = $prev[$s.name.ToLowerInvariant()] }
        if ($null -ne $p) {
            $o.status = Get-Prop $p 'status'
            $o.fetchedAt = Get-Prop $p 'fetchedAt'
            $o.signature = Get-Prop $p 'signature'
            $o.error = Get-Prop $p 'error'
        }
        $o.detached = [bool]$facts.Detached
        $o.shallow = [bool]$facts.Shallow
        $o.leftovers = [string[]]@($facts.Leftovers)
        $haveCfg = $null
        if ($have.Contains($remote)) { $haveCfg = $have[$remote] }
        $want = Get-WantedRemoteKeys $remote
        $kind = 'ok'
        if ($null -eq $haveCfg) { $kind = 'add' }
        elseif (-not (Test-MarkedRemote $haveCfg)) { $kind = 'conflict' }
        elseif (@(Get-RemoteDrift $haveCfg $want).Count -gt 0) { $kind = 'update' }
        if ($facts.Signature) { $o.changedSince = ($facts.Signature -ne [string]$o.signature) }
        if (-not $facts.Exists) { $o.action = 'missing' }
        elseif ($facts.Error) { $o.action = 'failed'; $o.error = $facts.Error }
        elseif ($kind -eq 'conflict') { $o.action = 'failed'; $o.error = ('the view has a remote "{0}" that branch-view did not add; rename or remove it' -f $remote) }
        elseif ($facts.Busy) { $o.action = 'busy'; $o.note = $facts.Busy }
        else {
            $why = $null
            if ($kind -eq 'add' -or -not $exists) { $why = 'new' }
            elseif (-not $o.signature) { $why = 'not fetched yet' }
            elseif ($null -ne $p -and -not (Test-SamePath ([string](Get-Prop $p 'path')) $s.path)) { $why = 'folder moved' }
            elseif ($o.changedSince) { $why = 'changed' }
            elseif ($kind -eq 'update') { $why = 'remote settings' }
            elseif ($facts.Detached -and -not (Test-ViewRefExists $View ('refs/remotes/{0}/(detached)' -f $remote))) { $why = 'detached HEAD not in the view' }
            if ($why) {
                if ($facts.Detached) { $why += ', detached HEAD' }
                if ($facts.Shallow) { $why += ', shallow: last, --update-shallow' }
                $o.action = 'fetch'
                $o.note = $why
            } else { $o.action = 'unchanged' }
        }
        $items.Add([pscustomobject]@{ Slot = $s; Out = $o; Facts = $facts; Kind = $kind; Want = $want })
    }
    $wanted = @{}
    foreach ($it in $items) { $wanted[$it.Out.remote] = $true }
    $toRemove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rn in @($have.Keys)) {
        if ($rn -ne 'origin' -and -not $wanted.ContainsKey($rn) -and (Test-MarkedRemote $have[$rn])) { $toRemove.Add($rn) }
    }
    $Entry.remotes.add = [string[]]@($items | Where-Object { $_.Kind -eq 'add' } | ForEach-Object { $_.Out.remote })
    $Entry.remotes.update = [string[]]@($items | Where-Object { $_.Kind -eq 'update' } | ForEach-Object { $_.Out.remote })
    $Entry.remotes.remove = $toRemove.ToArray()
    $Entry.remotes.conflict = [string[]]@($items | Where-Object { $_.Kind -eq 'conflict' } | ForEach-Object { $_.Out.remote })

    # origin: from the slot whose FETCH_HEAD is newest (else the first usable one), again when what that
    # slot has under refs/remotes/origin changed (a fetch or a push) or the last fill failed
    $src = $null
    foreach ($it in $items) {
        if (-not $it.Facts.Exists -or $it.Facts.Error -or $it.Facts.Busy -or $it.Kind -eq 'conflict') { continue }
        if ($null -eq $src) { $src = $it; continue }
        $a = $it.Facts.FetchHeadAt
        $b = $src.Facts.FetchHeadAt
        if ($null -ne $a -and ($null -eq $b -or $a -gt $b)) { $src = $it }
    }
    if ($null -ne $src) {
        $Entry.origin.source = $src.Slot.name
        $same = $exists -and ([string]$Entry.origin.filledFrom -eq $src.Slot.name) -and ([string]$Entry.origin.signature -eq [string]$src.Facts.OriginSignature) -and
            -not $Entry.origin.error
        if ($same) { $Entry.origin.action = 'unchanged' } else { $Entry.origin.action = 'fill' }
    }

    $fetchCount = @($items | Where-Object { $_.Out.action -eq 'fetch' }).Count
    if (-not $exists) { $Entry.action = 'create' }
    elseif ($fetchCount -gt 0 -or $toRemove.Count -gt 0 -or $Entry.remotes.update.Count -gt 0 -or $Entry.origin.action -eq 'fill') { $Entry.action = 'refresh' }
    else { $Entry.action = 'none' }
    if ($exists) { $Entry.sizeBytes = Get-ViewBytes $View }
    else {
        $max = [long]0
        foreach ($it in $items) { if ($it.Facts.CommonDir) { $b = Get-PackBytes $it.Facts.CommonDir; if ($b -gt $max) { $max = $b } } }
        $Entry.estimatedBytes = $max
    }
    return [pscustomobject]@{ Items = $items; ToRemove = $toRemove; Have = $have; OriginSrc = $src; State = $state; OriginUrl = $originUrl }
}

function Test-MarkedRemote($Cfg) {
    return ($null -ne $Cfg -and $Cfg.ContainsKey('unityslot') -and [string](@($Cfg['unityslot'])[-1]) -eq 'true')
}

# The -Apply part of one project; the caller holds the lock.
function Invoke-BranchViewApply($Group, [string]$View, [string]$StateFile, $Entry, $Plan) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $label = $Group.Project
    $created = $false
    $fetched = New-Object 'System.Collections.Generic.List[string]'
    $unchanged = New-Object 'System.Collections.Generic.List[string]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $folder = [string]$Entry.path
    if (-not $Entry.exists) {
        # not bare (Fork does not open a bare repository) and nothing checked out: only <folder>\.git
        $r = Invoke-ViewGit @('init', '-q', $folder)
        if ($r.Code -ne 0) { throw ('git init failed: ' + (Format-GitError $r)) }
        $created = $true
        $Entry.createdAt = Format-Iso (Get-Date)
        Write-BranchViewLine ('{0}: created {1}' -f $label, $folder)
    } else {
        Write-BranchViewLine ('{0}: {1}' -f $label, $folder)
    }
    Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1} (the folder to open in Fork or another git client)') -f 'open', $folder)
    if (-not $Entry.createdAt) { $Entry.createdAt = Format-Iso (Get-Date) }
    if ((Get-ViewConfigValue $View 'unity-slot.project') -ne $Group.Project) {
        $r = Invoke-ViewGit @('config', 'unity-slot.project', $Group.Project) $View
        if ($r.Code -ne 0) { throw ('git config unity-slot.project failed: ' + (Format-GitError $r)) }
    }
    # a move that stopped after the rename leaves core.bare true
    if ((Get-ViewConfigValue $View 'core.bare') -ne 'false') {
        $r = Invoke-ViewGit @('config', '--file', (Join-Path $View 'config'), 'core.bare', 'false')
        if ($r.Code -ne 0) { throw ('git config core.bare false failed: ' + (Format-GitError $r)) }
    }

    # remotes: drop the marked ones of slots that left the registry, then add or correct the slots' ones
    foreach ($rn in $Plan.ToRemove) {
        $r = Invoke-ViewGit @('remote', 'remove', $rn) $View
        if ($r.Code -ne 0) { throw ('git remote remove {0} failed: {1}' -f $rn, (Format-GitError $r)) }
    }
    foreach ($it in $Plan.Items) {
        if ($it.Kind -ne 'add' -and $it.Kind -ne 'update') { continue }
        $haveCfg = $null
        if ($Plan.Have.Contains($it.Out.remote)) { $haveCfg = $Plan.Have[$it.Out.remote] }
        foreach ($k in @(Get-RemoteDrift $haveCfg $it.Want)) {
            $r = Invoke-ViewGit @('config', '--replace-all', ('remote.{0}.{1}' -f $it.Out.remote, $k), [string]$it.Want[$k]) $View
            if ($r.Code -ne 0) { throw ('git config remote.{0}.{1} failed: {2}' -f $it.Out.remote, $k, (Format-GitError $r)) }
        }
    }
    if ($Plan.ToRemove.Count -gt 0) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'removed {1} (not in the registry any more)') -f 'remotes', ($Plan.ToRemove -join ', ')) }
    if ($Entry.remotes.add.Count -gt 0) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'added {1}') -f 'remotes', ($Entry.remotes.add -join ', ')) }
    if ($Entry.remotes.update.Count -gt 0) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'corrected {1}') -f 'remotes', ($Entry.remotes.update -join ', ')) }
    # origin keeps the real URL (a person may fetch it in the git client) unless it is a slot folder; pushes
    # go nowhere
    if ($Group.Origin) {
        $oc = $null
        if ($Plan.Have.Contains('origin')) { $oc = $Plan.Have['origin'] }
        if ($Entry.origin.urlNote) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'note: {1}') -f 'origin', $Entry.origin.urlNote) }
        if ($null -eq $oc -or (Test-MarkedRemote $oc)) {
            $ow = [ordered]@{ url = $Plan.OriginUrl; pushurl = ($script:ViewUrlScheme + 'origin'); fetch = '+refs/heads/*:refs/remotes/origin/*'; unityslot = 'true' }
            foreach ($k in @(Get-RemoteDrift $oc $ow)) {
                $r = Invoke-ViewGit @('config', '--replace-all', ('remote.origin.' + $k), [string]$ow[$k]) $View
                if ($r.Code -ne 0) { throw ('git config remote.origin.{0} failed: {1}' -f $k, (Format-GitError $r)) }
            }
        }
    }

    # fetch the changed slots, shallow ones last
    $order = @(@($Plan.Items | Where-Object { -not $_.Facts.Shallow }) + @($Plan.Items | Where-Object { $_.Facts.Shallow }))
    foreach ($it in $order) {
        $o = $it.Out
        if ($o.action -ne 'fetch') {
            switch ([string]$o.action) {
                'unchanged' { $unchanged.Add($o.slot) }
                'failed' { $failed.Add($o.slot) }
                default { $skipped.Add($o.slot) }
            }
            $o.status = $o.action
            if ($o.action -ne 'failed') { $o.error = $null }
            Write-ViewSlotLine $o
            continue
        }
        # busy again right before the fetch: earlier fetches of this run may have taken minutes
        $busyNow = Get-SlotBusy $it.Facts.CommonDir (Get-Date)
        if ($busyNow.Reason) {
            $o.action = 'busy'
            $o.status = 'busy'
            $o.note = $busyNow.Reason
            $o.error = $null
            $skipped.Add($o.slot)
            Write-ViewSlotLine $o
            continue
        }
        # the signature right before the fetch: a change after it is seen next time
        $sig = Get-SlotRefSignature $it.Facts.GitDir $it.Facts.CommonDir
        $fa = New-Object 'System.Collections.Generic.List[string]'
        foreach ($x in @('-c', (Get-InsteadOfArg $it.Slot.path $o.remote), '-c', 'fetch.pruneTags=false',
                'fetch', '--prune', '--porcelain', '--no-write-fetch-head', '--no-auto-gc', '--no-recurse-submodules')) { $fa.Add($x) }
        if ($it.Facts.Shallow) { $fa.Add('--update-shallow') }
        $fa.Add($o.remote)
        if ($it.Facts.Detached) {
            # the configured refspec plus HEAD; prune keeps (detached) while HEAD is there
            $fa.Add(('+refs/heads/*:refs/remotes/{0}/*' -f $o.remote))
            $fa.Add(('+HEAD:refs/remotes/{0}/(detached)' -f $o.remote))
        }
        $r = Invoke-ViewGitRetry $fa.ToArray() $View
        if ($r.Code -eq 0 -and $it.Facts.Detached -and (Test-ViewRefExists $View ('refs/remotes/{0}/HEAD' -f $o.remote))) {
            # <remote>/HEAD still names the branch the slot had before it was detached; followRemoteHEAD
            # sets it again once the slot is on a branch
            [void](Invoke-ViewGit @('update-ref', '--no-deref', '-d', ('refs/remotes/{0}/HEAD' -f $o.remote)) $View)
        }
        if ($r.Code -eq 0) {
            $o.status = 'fetched'
            $o.action = 'fetched'
            $o.updates = @(Read-FetchPorcelain $r.Out | Where-Object { $_.Flag -ne '=' }).Count
            $o.fetchedAt = Format-Iso (Get-Date)
            $o.signature = $sig
            $o.changedSince = $false
            $o.error = $null
            $fetched.Add($o.slot)
        } else {
            # the signature stays the last good one, so the next run tries again
            $o.status = 'failed'
            $o.action = 'failed'
            $o.error = Format-GitError $r
            $failed.Add($o.slot)
            if ($Json) { foreach ($l in @($r.Err)) { [Console]::Error.WriteLine('  git: ' + (Protect-Text ([string]$l))) } }
        }
        Write-ViewSlotLine $o
    }

    # origin from the newest slot, fast-forward only (no network)
    $og = $Entry.origin
    $src = $Plan.OriginSrc
    if ($og.action -eq 'fill') {
        # the source may have started a gc since the plan; then origin waits for the next run
        $srcBusy = Get-SlotBusy $src.Facts.CommonDir (Get-Date)
        if ($srcBusy.Reason) {
            $og.action = 'busy'
            Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'SKIP fill: {1} is busy ({2}); next run') -f 'origin', $src.Slot.name, $srcBusy.Reason)
        }
    }
    if ($og.action -eq 'fill') {
        $osig = Get-OriginRefSignature $src.Facts.CommonDir
        $oa = New-Object 'System.Collections.Generic.List[string]'
        foreach ($x in @('-c', (Get-InsteadOfArg $src.Slot.path $src.Out.remote), 'fetch', '--porcelain', '--no-write-fetch-head', '--no-tags', '--no-auto-gc',
                '--no-recurse-submodules')) { $oa.Add($x) }
        # from a shallow slot git silently drops refs that need new shallow boundaries without this
        if ($src.Facts.Shallow) { $oa.Add('--update-shallow') }
        foreach ($x in @(($script:ViewUrlScheme + $src.Out.remote), 'refs/remotes/origin/*:refs/remotes/origin/*', '^refs/remotes/origin/HEAD')) { $oa.Add($x) }
        $r = Invoke-ViewGitRetry $oa.ToArray() $View
        $lines = @(Read-FetchPorcelain $r.Out)
        $rej = @($lines | Where-Object { $_.Flag -eq '!' })
        if ($r.Code -eq 0 -or ($r.Code -eq 1 -and $rej.Count -gt 0)) {
            $og.filledFrom = $src.Slot.name
            $og.filledAt = Format-Iso (Get-Date)
            $og.fetchHeadAt = Format-Iso $src.Facts.FetchHeadAt
            $og.signature = $osig
            # refused and stale (force-pushed or re-created upstream), or refused because the view is ahead:
            # the slot's value is an ancestor of the view's (a git client fetched origin here); that one stays
            $staleRefs = New-Object 'System.Collections.Generic.List[object]'
            $ahead = New-Object 'System.Collections.Generic.List[string]'
            foreach ($x in $rej) {
                $n = $x.Ref
                if ($n.StartsWith('refs/remotes/')) { $n = $n.Substring(13) }
                $anc = Invoke-ViewGit @('merge-base', '--is-ancestor', $x.New, $x.Old) $View
                if ($anc.Code -eq 0) { $ahead.Add($n) } else { $staleRefs.Add([ordered]@{ name = $n; viewSha = $x.Old; slotSha = $x.New }) }
            }
            $og.rejected = $staleRefs.ToArray()
            $og.ahead = $ahead.ToArray()
            $og.updates = @($lines | Where-Object { $_.Flag -ne '=' -and $_.Flag -ne '!' }).Count
            $og.error = $null
            $msg = ('filled from {0}, {1} ref update(s)' -f $src.Slot.name, $og.updates)
            if ($ahead.Count -gt 0) { $msg += ('; {0} ref(s) newer here than in {1} (origin fetched in a git client), kept' -f $ahead.Count, $src.Slot.name) }
            if ($staleRefs.Count -gt 0) { $msg += '; ' + (Format-OriginStale $og.rejected $src.Slot.name) }
            Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1}') -f 'origin', $msg)
        } else {
            $og.error = Format-GitError $r
            Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'FAILED to fill from {1}: {2}') -f 'origin', $src.Slot.name, $og.error)
        }
    } elseif ($og.action -eq 'unchanged') {
        $line = ('unchanged (from {0})' -f $src.Slot.name)
        if (@($og.rejected).Count -gt 0) { $line += '; ' + (Format-OriginStale $og.rejected '') }
        Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1}') -f 'origin', $line)
    }

    if ($fetched.Count -gt 0 -or $created) {
        $r = Invoke-ViewGit @('-c', 'gc.autoDetach=false', 'gc', '--auto', '--quiet') $View
        if ($r.Code -ne 0) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'gc --auto: {1}') -f 'view', (Format-GitError $r)) }
    }

    $Entry.exists = $true
    $Entry.updatedAt = Format-Iso (Get-Date)
    $Entry.coreVersion = $script:UnitySlotVersion
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    $stateSlots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in $Plan.Items) {
        $o = $it.Out
        $stateSlots.Add([ordered]@{ slot = $o.slot; remote = $o.remote; path = $o.path; status = $o.status; fetchedAt = $o.fetchedAt; signature = $o.signature
                detached = $o.detached; shallow = $o.shallow; error = $o.error; note = $o.note })
    }
    Write-ViewState $StateFile ([ordered]@{
            schema = $script:BranchViewSchema; project = $Group.Project; repo = $Group.Repo; path = $folder; gitDir = $View
            createdAt = $Entry.createdAt; updatedAt = $Entry.updatedAt; coreVersion = $Entry.coreVersion
            slots = $stateSlots.ToArray()
            origin = [ordered]@{ url = $og.url; filledFrom = $og.filledFrom; filledAt = $og.filledAt; fetchHeadAt = $og.fetchHeadAt; signature = $og.signature
                rejected = @($og.rejected); error = $og.error }
            seconds = $seconds
        })
    $Entry.sizeBytes = Get-ViewBytes $View
    $Entry.estimatedBytes = $null
    Write-BranchViewLine ('{0}: done in {1} s (fetched {2}, unchanged {3}, skipped {4}, failed {5}; view {6})' -f $label,
        $seconds.ToString('0.0', $script:Inv), $fetched.Count, $unchanged.Count, $skipped.Count, $failed.Count, (Format-Size $Entry.sizeBytes))
    Write-SlotEvent 'branchview' $folder 0 ([ordered]@{
            project = $Group.Project; created = $created; fetched = $fetched.Count; unchanged = $unchanged.Count
            skipped = $skipped.ToArray(); failed = $failed.ToArray(); added = @($Entry.remotes.add); removed = @($Entry.remotes.remove)
            originRejected = @($og.rejected).Count; seconds = $seconds; gitDir = $View; movedFrom = $Entry.moveFrom
        })
}

# -c url.<slot folder>.insteadOf=unity-slot-view://<remote>: the one place a placeholder leads to a slot.
function Get-InsteadOfArg([string]$SlotPath, [string]$Remote) {
    return ('url.{0}.insteadOf={1}{2}' -f (Get-NormPath $SlotPath).Replace('\', '/'), $script:ViewUrlScheme, $Remote)
}

# A git run on the view, once more after 1 s when a ref lock of the view was taken.
function Invoke-ViewGitRetry([string[]]$GitArgs, [string]$View) {
    $r = Invoke-ViewGit $GitArgs $View
    if ($r.Code -ne 0 -and (Test-RefLockConflict $r)) {
        Start-Sleep -Seconds 1
        $r = Invoke-ViewGit $GitArgs $View
    }
    return $r
}

function Format-OriginStale($Rejected, [string]$Source) {
    $all = @($Rejected)
    $names = @($all | Select-Object -First 5 | ForEach-Object {
            $n = [string](Get-ViewField $_ 'name')
            $v = [string](Get-ViewField $_ 'viewSha')
            $s = [string](Get-ViewField $_ 'slotSha')
            if ($v.Length -ge 7 -and $s.Length -ge 7) { '{0} (view {1}, slot {2})' -f $n, $v.Substring(0, 7), $s.Substring(0, 7) } else { $n }
        })
    $more = ''
    if ($all.Count -gt 5) { $more = (' and {0} more' -f ($all.Count - 5)) }
    $from = ''
    if ($Source) { $from = ' from ' + $Source }
    return ('origin partly stale here: {0} ref(s) refused{1} (not a fast-forward: force-pushed or deleted upstream?): {2}{3}' -f $all.Count, $from, ($names -join ', '), $more)
}

# A field of a dictionary (this run) or of an object read from JSON (the state file).
function Get-ViewField($Item, [string]$Name) {
    if ($null -eq $Item) { return $null }
    if ($Item -is [Collections.IDictionary]) { return $Item[$Name] }
    return (Get-Prop $Item $Name)
}

function Write-ViewSlotLine($O) {
    Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1}') -f $O.slot, (Format-SlotAction $O))
    if (@($O.leftovers).Count -gt 0) {
        Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'note: leftover temp file(s) of an earlier git run (reported only): {1}') -f '', (@($O.leftovers) -join ', '))
    }
}

function Write-BranchViewPlan($Entry, $Plan, [bool]$LockHeld) {
    $label = $Entry.project
    if (-not $Entry.exists) {
        Write-BranchViewLine ('{0}: {1} not made yet; -Apply makes it (about {2}, the largest slot''s packs)' -f $label, $Entry.path, (Format-Size $Entry.estimatedBytes))
    } else {
        $changed = @($Plan.Items | Where-Object { $_.Out.changedSince -eq $true }).Count
        $when = '-'
        if ($Entry.updatedAt) { $when = $Entry.updatedAt }
        Write-BranchViewLine ('{0}: {1}, updated {2} ({3}); {4} slot(s) changed since' -f $label, $Entry.path, $when, (Format-Size $Entry.sizeBytes), $changed)
    }
    if ($Entry.moveFrom) {
        Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'older bare form {1} -> folder form {2} (-Apply moves it on the same volume; refs and remotes stay, nothing is fetched again)') -f 'move', $Entry.moveFrom, $Entry.gitDir)
    }
    Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1} (the folder to open in Fork or another git client)') -f 'open', $Entry.path)
    if ($LockHeld) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + 'another branch-view run holds this view right now; -Apply would stop (exit 4)') -f 'note') }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($Entry.remotes.add.Count -gt 0) { $parts.Add('add ' + ($Entry.remotes.add -join ', ')) }
    if ($Entry.remotes.update.Count -gt 0) { $parts.Add('correct ' + ($Entry.remotes.update -join ', ')) }
    if ($Plan.ToRemove.Count -gt 0) { $parts.Add('remove ' + ($Plan.ToRemove -join ', ') + ' (not in the registry any more)') }
    if ($parts.Count -gt 0) { Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1}') -f 'remotes', ($parts -join '; ')) }
    foreach ($it in $Plan.Items) { Write-ViewSlotLine $it.Out }
    $og = $Entry.origin
    $line = 'no slot to fill it from'
    if ($og.action -eq 'fill') { $line = ('fill from {0} (newest FETCH_HEAD), fast-forward only' -f $og.source) }
    elseif ($og.action -eq 'unchanged') { $line = ('unchanged (from {0})' -f $og.source) }
    if (@($og.rejected).Count -gt 0) { $line += '; last run: ' + (Format-OriginStale $og.rejected '') }
    if ($og.url) { $line += ('; remote origin {0}' -f $og.url) }
    if ($og.urlNote) { $line += (' (' + $og.urlNote + ')') }
    Write-BranchViewLine (('  {0,-' + $script:BvWidth + '} ' + '{1}') -f 'origin', $line)
}
