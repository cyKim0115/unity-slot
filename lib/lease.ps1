# Leases: which session holds which slot. Dot-sourced by unity-slot.ps1. ASCII-only source.
#
# One file per leased slot: <slot home>\leases\<slot>.json. Creating it with FileMode.CreateNew is
# the lock, so two sessions cannot take the same free slot. A lease expires after -Hours (default 8);
# an expired lease no longer blocks a closed slot, but it still blocks a slot whose editor is open
# (someone may be looking at it), which needs the user. Nothing here closes editors on a timer.

function Get-LeaseDir { return (Join-Path (Get-SlotHome) 'leases') }

function Get-LeaseFile([string]$SlotName) { return (Join-Path (Get-LeaseDir) ($SlotName + '.json')) }

# Who holds a lease: -Owner, $env:UNITY_SLOT_OWNER, the Claude Code session id, or user@host.
function Resolve-Owner {
    if (-not [string]::IsNullOrWhiteSpace($Owner)) { return $Owner.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_SLOT_OWNER)) { return $env:UNITY_SLOT_OWNER.Trim() }
    $id = $env:CLAUDE_CODE_SESSION_ID
    if (-not [string]::IsNullOrWhiteSpace($id)) { return ('claude:' + $id.Substring(0, [Math]::Min(8, $id.Length))) }
    return ('{0}@{1}' -f $env:USERNAME, $env:COMPUTERNAME)
}

# The MCP client process behind a call (Claude Code, Codex, Cursor): the first process above this one
# that is not a shell, so the MCP server (powershell) and a cmd wrapper are skipped. Only for MCP calls.
# Codex and Cursor give the MCP server no session id, so their owner id changes when the server
# restarts; the client process recorded in the lease tells whether the lease is orphaned.
$script:ClientWrapperNames = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'conhost.exe')
function Get-McpClientProcess($Snap) {
    if (-not (Test-ViaMcp) -or -not $Snap.ByPid.ContainsKey([int]$PID)) { return $null }
    $cur = $Snap.ByPid[[int]$PID]
    for ($i = 0; $i -lt 6; $i++) {
        $parentId = [int]$cur.ParentProcessId
        if ($parentId -eq [int]$cur.ProcessId -or -not $Snap.ByPid.ContainsKey($parentId)) { return $null }
        $parent = $Snap.ByPid[$parentId]
        # a parent is never younger than its child; a younger one only reuses the id
        if ($null -ne $parent.CreationDate -and $null -ne $cur.CreationDate -and $parent.CreationDate -gt $cur.CreationDate) { return $null }
        if ($script:ClientWrapperNames -notcontains ([string]$parent.Name).ToLowerInvariant()) {
            return [pscustomobject]@{ Name = [string]$parent.Name; Pid = $parentId; StartedAt = $parent.CreationDate }
        }
        $cur = $parent
    }
    return $null
}

# $null = the lease has no client process recorded (CLI, or older leases); else whether it still runs.
function Test-LeaseClientAlive($Lease, $Snap) {
    if ($null -eq $Lease -or [int]$Lease.clientPid -le 0) { return $null }
    if (-not $Snap.ByPid.ContainsKey([int]$Lease.clientPid)) { return $false }
    $p = $Snap.ByPid[[int]$Lease.clientPid]
    if ($null -ne $Lease.clientStartedAt -and $null -ne $p.CreationDate -and
        [math]::Abs(([datetime]$p.CreationDate - [datetime]$Lease.clientStartedAt).TotalSeconds) -gt 2) { return $false }
    return $true
}

# Notes on a lease that is not this session's: orphaned (its client process has exited), or, over MCP,
# another id of this session's own client (Codex and Cursor get a new id when the MCP server restarts).
function Get-LeaseNotes([string]$SlotName, $Lease, $Alive) {
    if ($null -eq $Lease) { return }
    # this session's own lease (a resumed Claude Code session keeps its id but has a new process)
    if ((Test-ViaMcp) -and [string]$Lease.owner -eq [string]$env:UNITY_SLOT_MCP_OWNER) { return }
    if ($Alive -eq $false) {
        if (Test-ViaMcp) { 'note    {0}: the lease of {1} is orphaned: the {2} process that took it has exited. Tell the user; only they can release another session''s lease.' -f $SlotName, $Lease.owner, $Lease.clientName }
        else { 'note    {0}: the lease of {1} is orphaned: its client process ({2} pid {3}) has exited. -AnyOwner releases it (only when the user says so).' -f $SlotName, $Lease.owner, $Lease.clientName, $Lease.clientPid }
        return
    }
    if (Test-SameClientOtherId ([string]$Lease.owner)) {
        $prefix = ([string]$env:UNITY_SLOT_MCP_OWNER -split ':', 2)[0]
        'note    {0}: leased by {1}, another {2} id. If this conversation acquired {0} before the MCP server restarted (that acquire result showed owner {1}), call {3}; otherwise it is another {2} session''s: leave it.' -f `
            $SlotName, $Lease.owner, $prefix, (Format-ToolCall 'release' @('slot', $SlotName, 'owner', [string]$Lease.owner))
    }
}

# MCP only: an owner id from the same client name as this session's (for example codex-mcp-client:...)
# when this session's id is not stable (no session id from the client), so a server restart made it.
function Test-SameClientOtherId([string]$LeaseOwner) {
    $me = [string]$env:UNITY_SLOT_MCP_OWNER
    if (-not (Test-ViaMcp) -or -not $me -or $env:UNITY_SLOT_MCP_OWNER_STABLE -eq '1' -or $LeaseOwner -eq $me) { return $false }
    $prefix = ($me -split ':', 2)[0]
    return ($prefix -and $LeaseOwner.StartsWith($prefix + ':', [StringComparison]::OrdinalIgnoreCase))
}

# Lease length: -Hours when given, else the config's "leaseHours" (8).
function Get-LeaseHours {
    if ($script:Bound.ContainsKey('Hours')) { return [double]$Hours }
    $h = [double](Get-Setting 'leaseHours')
    if ($h -gt 0) { return $h }
    return 8.0
}

function Get-SlotLease([string]$SlotName) {
    $file = Get-LeaseFile $SlotName
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $d = $null
    for ($try = 0; $try -lt 2 -and $null -eq $d; $try++) {
        try { $d = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 200 }
    }
    if ($null -eq $d) {
        return [pscustomobject]@{ owner = '(unreadable lease file)'; acquiredAt = $null; expiresAt = $null; need = ''; nonce = ''; editorPid = 0; openedByAcquire = $false; host = ''
            clientName = ''; clientPid = 0; clientStartedAt = $null; Expired = $true }
    }
    $exp = $null
    $e = [string](Get-Prop $d 'expiresAt')
    if ($e) { $exp = [datetime]::Parse($e, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    $acq = $null
    $a = [string](Get-Prop $d 'acquiredAt')
    if ($a) { $acq = [datetime]::Parse($a, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    $c = Get-Prop $d 'client'
    $cStarted = $null
    $cs = [string](Get-Prop $c 'startedAt')
    if ($cs) { $cStarted = [datetime]::Parse($cs, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    return [pscustomobject]@{
        owner           = [string](Get-Prop $d 'owner')
        acquiredAt      = $acq
        expiresAt       = $exp
        need            = [string](Get-Prop $d 'need')
        nonce           = [string](Get-Prop $d 'nonce')
        editorPid       = [int](Get-Prop $d 'editorPid')
        openedByAcquire = [bool](Get-Prop $d 'openedByAcquire')
        host            = [string](Get-Prop $d 'host')
        clientName      = [string](Get-Prop $c 'name')
        clientPid       = [int](Get-Prop $c 'pid')
        clientStartedAt = $cStarted
        Expired         = ($null -eq $exp -or (Get-Date) -gt $exp)
    }
}

function ConvertTo-LeaseJson($SlotName, $Lease) {
    $out = [pscustomobject][ordered]@{
        slot            = $SlotName
        owner           = $Lease.owner
        acquiredAt      = ([datetime]$Lease.acquiredAt).ToString('o', $script:Inv)
        expiresAt       = ([datetime]$Lease.expiresAt).ToString('o', $script:Inv)
        need            = $Lease.need
        nonce           = $Lease.nonce
        editorPid       = [int]$Lease.editorPid
        openedByAcquire = [bool]$Lease.openedByAcquire
        host            = $env:COMPUTERNAME
        client          = $null
    }
    if ([int]$Lease.clientPid -gt 0) {
        $started = $null
        if ($null -ne $Lease.clientStartedAt) { $started = ([datetime]$Lease.clientStartedAt).ToString('o', $script:Inv) }
        $out.client = [pscustomobject][ordered]@{ name = $Lease.clientName; pid = [int]$Lease.clientPid; startedAt = $started }
    }
    return ($out | ConvertTo-Json)
}

# Returns the new lease, or $null when someone else got there first.
function New-SlotLease($Slot, [string]$OwnerId, [string]$Need, [double]$HoursValue, [bool]$ReplaceExpired, $Client = $null) {
    $dir = Get-LeaseDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $now = Get-Date
    $lease = [pscustomobject]@{
        owner = $OwnerId; acquiredAt = $now; expiresAt = $now.AddHours($HoursValue); need = $Need
        nonce = [guid]::NewGuid().ToString('N'); editorPid = 0; openedByAcquire = $false; host = $env:COMPUTERNAME
        clientName = ''; clientPid = 0; clientStartedAt = $null; Expired = $false
    }
    if ($null -ne $Client) { $lease.clientName = $Client.Name; $lease.clientPid = $Client.Pid; $lease.clientStartedAt = $Client.StartedAt }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-LeaseJson $Slot.name $lease))
    $file = Get-LeaseFile $Slot.name
    if (-not $ReplaceExpired) {
        try {
            $fs = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return $lease
        } catch [IO.IOException] {
            return $null
        }
    }
    # Taking over an expired lease: write, wait, and check that our nonce is the one that stayed.
    $tmp = '{0}.{1}.tmp' -f $file, $lease.nonce
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $file -Force
    Start-Sleep -Milliseconds 300
    $check = Get-SlotLease $Slot.name
    if ($null -ne $check -and $check.nonce -eq $lease.nonce) { return $lease }
    return $null
}

function Update-SlotLease([string]$SlotName, $Lease) {
    [IO.File]::WriteAllText((Get-LeaseFile $SlotName), (ConvertTo-LeaseJson $SlotName $Lease), (New-Object Text.UTF8Encoding($false)))
}

function Remove-SlotLease([string]$SlotName) {
    $file = Get-LeaseFile $SlotName
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

# '' when the slot can be given to $OwnerId, otherwise why not.
function Get-BusyReason($Slot, $St, [string]$OwnerId) {
    if (-not $St.Exists) { return 'folder missing' }
    if ($St.Batch) { return 'batchmode run in progress' }
    $mine = ($null -ne $St.Lease -and $St.Lease.owner -eq $OwnerId)
    if ($null -ne $St.Lease -and -not $mine) {
        if (-not $St.Lease.Expired) { return ('leased by ' + (Format-Lease $St.Lease)) }
        if ($St.EditorPid -gt 0) { return ('expired lease (' + (Format-Lease $St.Lease) + ') and the editor is still open; ask the user') }
    }
    if ($St.EditorPid -gt 0 -and $Slot.mode -ne 'hot' -and -not $mine) { return 'editor open without a lease (someone is using it)' }
    return ''
}

function Invoke-Acquire {
    if ([string]::IsNullOrWhiteSpace($Target)) { throw 'usage: unity-slot acquire <purpose or platform> [-Project <repo>] [-Owner <id>] [-Hours 8] [-NoOpen]' }
    $need = $Target.Trim()
    $ownerId = Resolve-Owner
    $projectFilter = Get-ProjectFilter
    $reg = Read-Registry
    if ($reg.slots.Count -eq 0) {
        if (Test-ViaMcp) { throw ('no slots registered ({0}). Ask the user to register the clones (scan).' -f (Get-RegistryPath)) }
        throw ('no slots registered ({0}). Run: unity-slot scan -Project <owner/repo> -Apply' -f (Get-RegistryPath))
    }
    $snap = Get-Snapshot

    $matched = @($reg.slots | Where-Object { $_.agentUse -and (Test-SlotNeed $_ $need) -and (Test-SlotProject $_ $projectFilter) })
    if ($matched.Count -eq 0) {
        Say ('NO SLOT: no agent slot has purpose or platform "{0}"{1}.' -f $need, $(if ($projectFilter) { ' in ' + $projectFilter } else { '' }))
        if (Test-ViaMcp) { Say ('see: status()   new clone plan: {0}' -f (Format-ToolCall 'create' @('purpose', $need, 'project', $projectFilter))) }
        else { Say ('see: unity-slot slots   new clone plan: unity-slot new-clone {0}{1}' -f $need, $(if ($projectFilter) { ' -Project ' + $projectFilter } else { '' })) }
        $script:ExitCode = 5
        return
    }
    $projects = @($matched | ForEach-Object { $_.project } | Select-Object -Unique)
    if ($projects.Count -gt 1) {
        if (Test-ViaMcp) { throw ('"{0}" matches slots of {1} projects ({2}). Add project="<repo>".' -f $need, $projects.Count, ($projects -join ', ')) }
        throw ('"{0}" matches slots of {1} projects ({2}). Add -Project <repo>.' -f $need, $projects.Count, ($projects -join ', '))
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $free = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $matched) {
        $st = Get-SlotState $s $snap
        $reason = Get-BusyReason $s $st $ownerId
        $rows.Add(@($s.name, $s.platform, $s.mode, $st.Text, (Format-Lease $st.Lease), $(if ($reason) { $reason } else { 'free' })))
        if (-not $reason) {
            # own lease first, then open hot slots (no start-up wait), then closed slots used most recently
            $rank = 2
            if ($null -ne $st.Lease -and $st.Lease.owner -eq $ownerId) { $rank = 0 }
            elseif ($st.EditorPid -gt 0) { $rank = 1 }
            $free.Add([pscustomobject]@{ Slot = $s; State = $st; Rank = $rank; LastUsed = (Get-LastUsed $s.path) })
        }
    }
    Write-TextTable @('Slot', 'Platform', 'Mode', 'State', 'Lease', 'For you') $rows
    if ($free.Count -eq 0) {
        Say ('NO FREE SLOT for "{0}". Nothing was opened.' -f $need)
        if (Test-ViaMcp) { Say ('next    show the user a new clone plan: {0}' -f (Format-ToolCall 'create' @('purpose', $need, 'project', $projects[0]))) }
        else { Say ('next    show the user a new clone plan: unity-slot new-clone {0} -Project {1}' -f $need, $projects[0]) }
        $script:ExitCode = 5
        return
    }

    $chosen = $null
    $lease = $null
    $client = Get-McpClientProcess $snap
    foreach ($c in @($free | Sort-Object Rank, @{ Expression = { $_.LastUsed }; Descending = $true })) {
        $existing = $c.State.Lease
        if ($null -ne $existing -and $existing.owner -eq $ownerId) {
            $existing.expiresAt = (Get-Date).AddHours((Get-LeaseHours))
            if ($null -ne $client) { $existing.clientName = $client.Name; $existing.clientPid = $client.Pid; $existing.clientStartedAt = $client.StartedAt }
            Update-SlotLease $c.Slot.name $existing
            $chosen = $c; $lease = $existing
            Say ('lease   already yours; extended to {0}' -f (Format-Time $existing.expiresAt))
            break
        }
        $replace = ($null -ne $existing -and $existing.Expired)
        $lease = New-SlotLease $c.Slot $ownerId $need (Get-LeaseHours) $replace $client
        if ($null -ne $lease) {
            $chosen = $c
            if ($replace) {
                Say ('lease   replaced the expired lease of {0}' -f $existing.owner)
                Write-SlotEvent 'takeover' $c.Slot.path $c.State.EditorPid ([ordered]@{ previousOwner = $existing.owner; previousExpiresAt = (Format-Iso $existing.expiresAt) }) $ownerId
            }
            Write-SlotEvent 'acquire' $c.Slot.path $c.State.EditorPid ([ordered]@{ need = $need; hours = (Get-LeaseHours); expiresAt = (Format-Iso $lease.expiresAt) }) $ownerId
            break
        }
        Say ('lease   {0} was taken a moment ago, trying the next slot' -f $c.Slot.name)
    }
    if ($null -eq $chosen) {
        Say 'NO FREE SLOT: every free slot was taken while choosing. Try again.'
        $script:ExitCode = 5
        return
    }
    $slot = $chosen.Slot
    Say ('slot    {0}: {1}, {2}, {3}, {4}' -f $slot.name, $slot.platform, $slot.branch, $slot.mode, $slot.path)
    Say ('lease   {0} until {1}' -f $lease.owner, (Format-Time $lease.expiresAt))

    $editorPid = $chosen.State.EditorPid
    if ($editorPid -eq 0 -and -not $NoOpen) {
        $script:LastOpenPid = 0
        Invoke-Open $slot.path $TimeoutSec '' $NoWait.IsPresent
        if ($script:ExitCode -ne 0) {
            $running = @(Get-OpenFor (Get-Snapshot) $slot.path).Count -gt 0
            if ($running) {
                Say ('lease   kept: the editor is running but not ready (exit {0}). Hand it to the user.' -f $script:ExitCode)
            } else {
                Remove-SlotLease $slot.name
                Say ('lease   released: the editor did not start (exit {0})' -f $script:ExitCode)
            }
            return
        }
        $editorPid = $script:LastOpenPid
        $lease.editorPid = $editorPid
        $lease.openedByAcquire = $true
        Update-SlotLease $slot.name $lease
    }
    $mcp = Test-ViaMcp
    $state = 'closed (-NoOpen)'
    if ($mcp) { $state = 'closed (open=false)' }
    if ($editorPid -gt 0) { $state = 'editor pid ' + $editorPid }
    $starting = ($NoWait -and $lease.openedByAcquire)
    if ($starting) {
        if ($mcp) { $state += ' starting (call ' + (Format-ToolCall 'wait_ready' @('slot', $slot.name)) + ' when you need it)' }
        else { $state += ' starting (run: unity-slot wait ' + $slot.name + ')' }
    }
    Say ('ACQUIRED {0}: {1}; work in {2}' -f $slot.name, $state, $slot.path)
    $releaseCall = Format-ToolCall 'release' @('slot', $slot.name, 'owner', (Get-OwnerArg $lease.owner))
    if ($mcp -and $starting) {
        Say ('next    while it starts, do the work that needs no editor (read code, research, plan; no Unity asset or script edits yet); when you need the editor: {0}, then check with your Unity MCP that Application.dataPath is "{1}/Assets"; when done: {2}' -f (Format-ToolCall 'wait_ready' @('slot', $slot.name)), $slot.path.Replace('\', '/'), $releaseCall)
    } elseif ($mcp) {
        Say ('next    check with your Unity MCP that Application.dataPath is "{0}/Assets"; when done: {1}' -f $slot.path.Replace('\', '/'), $releaseCall)
    } else {
        Say ('next    check Application.dataPath through MCP; when done: unity-slot release {0} -Owner {1}' -f $slot.name, $lease.owner)
    }
}

function Invoke-Release {
    $reg = Read-Registry
    $slot = Find-Slot $reg $Target
    if ($null -eq $slot) {
        if (Test-ViaMcp) { throw ('no registered slot named or located at "{0}". See status().' -f $Target) }
        throw ('no registered slot named or located at "{0}". See: unity-slot slots' -f $Target)
    }
    $ownerId = Resolve-Owner
    $snap = Get-Snapshot
    $st = Get-SlotState $slot $snap
    Say ('slot    {0}: {1}; lease {2}' -f $slot.name, $st.Text, (Format-Lease $st.Lease))
    if ($null -eq $st.Lease) {
        Say 'NOT LEASED: nothing to release. Editors are only closed for the session that holds the lease.'
        return
    }
    if ($st.Lease.owner -ne $ownerId -and -not $AnyOwner) {
        if (Test-ViaMcp) { Say ('REFUSED: the lease belongs to {0}, not {1}. Only the user can release someone else''s lease.' -f $st.Lease.owner, $ownerId) }
        else { Say ('REFUSED: the lease belongs to {0}, not {1}. -AnyOwner releases it anyway (only when the user says so).' -f $st.Lease.owner, $ownerId) }
        foreach ($n in @(Get-LeaseNotes $slot.name $st.Lease (Test-LeaseClientAlive $st.Lease $snap))) { Say $n }
        Write-SlotEvent 'refused' $slot.path $st.EditorPid ([ordered]@{ command = 'release'; reason = 'lease of someone else'; leaseOwner = $st.Lease.owner }) $ownerId
        $script:ExitCode = 4
        return
    }
    $detail = [ordered]@{ closed = $false; keptOpen = $false; anyOwner = [bool]$AnyOwner; leaseOwner = $st.Lease.owner }
    if ($st.EditorPid -gt 0) {
        if ($slot.mode -eq 'hot') {
            Say 'editor  hot slot: stays open'
            $detail.keptOpen = $true
        } elseif ($KeepOpen) {
            Say 'editor  left open (-KeepOpen)'
            $detail.keptOpen = $true
        } else {
            $script:LastCloseDetail = $null
            Invoke-Close $slot.path
            if ($script:ExitCode -ne 0) {
                Say ('lease   kept: the editor did not close (exit {0})' -f $script:ExitCode)
                return
            }
            $detail.closed = $true
            if ($null -ne $script:LastCloseDetail) { foreach ($k in @($script:LastCloseDetail.Keys)) { $detail[$k] = $script:LastCloseDetail[$k] } }
        }
    }
    Remove-SlotLease $slot.name
    Write-SlotEvent 'release' $slot.path $st.EditorPid $detail $ownerId
    Say ('RELEASED {0}' -f $slot.name)
}

function Invoke-Renew {
    $reg = Read-Registry
    $slot = Find-Slot $reg $Target
    if ($null -eq $slot) { throw ('no registered slot named or located at "{0}"' -f $Target) }
    $ownerId = Resolve-Owner
    $lease = Get-SlotLease $slot.name
    if ($null -eq $lease) { Say 'NOT LEASED'; $script:ExitCode = 4; return }
    if ($lease.owner -ne $ownerId) {
        Say ('REFUSED: the lease belongs to {0}' -f $lease.owner)
        Write-SlotEvent 'refused' $slot.path 0 ([ordered]@{ command = 'renew'; reason = 'lease of someone else'; leaseOwner = $lease.owner }) $ownerId
        $script:ExitCode = 4
        return
    }
    $lease.expiresAt = (Get-Date).AddHours((Get-LeaseHours))
    Update-SlotLease $slot.name $lease
    Write-SlotEvent 'renew' $slot.path 0 ([ordered]@{ expiresAt = (Format-Iso $lease.expiresAt) }) $ownerId
    Say ('RENEWED {0} until {1}' -f $slot.name, (Format-Time $lease.expiresAt))
}
