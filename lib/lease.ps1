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
        return [pscustomobject]@{ owner = '(unreadable lease file)'; acquiredAt = $null; expiresAt = $null; need = ''; nonce = ''; editorPid = 0; openedByAcquire = $false; host = ''; Expired = $true }
    }
    $exp = $null
    $e = [string](Get-Prop $d 'expiresAt')
    if ($e) { $exp = [datetime]::Parse($e, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    $acq = $null
    $a = [string](Get-Prop $d 'acquiredAt')
    if ($a) { $acq = [datetime]::Parse($a, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    return [pscustomobject]@{
        owner           = [string](Get-Prop $d 'owner')
        acquiredAt      = $acq
        expiresAt       = $exp
        need            = [string](Get-Prop $d 'need')
        nonce           = [string](Get-Prop $d 'nonce')
        editorPid       = [int](Get-Prop $d 'editorPid')
        openedByAcquire = [bool](Get-Prop $d 'openedByAcquire')
        host            = [string](Get-Prop $d 'host')
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
    }
    return ($out | ConvertTo-Json)
}

# Returns the new lease, or $null when someone else got there first.
function New-SlotLease($Slot, [string]$OwnerId, [string]$Need, [double]$HoursValue, [bool]$ReplaceExpired) {
    $dir = Get-LeaseDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $now = Get-Date
    $lease = [pscustomobject]@{
        owner = $OwnerId; acquiredAt = $now; expiresAt = $now.AddHours($HoursValue); need = $Need
        nonce = [guid]::NewGuid().ToString('N'); editorPid = 0; openedByAcquire = $false; host = $env:COMPUTERNAME; Expired = $false
    }
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
    if ($reg.slots.Count -eq 0) { throw ('no slots registered ({0}). Run: unity-slot scan -Project <owner/repo> -Apply' -f (Get-RegistryPath)) }
    $snap = Get-Snapshot

    $matched = @($reg.slots | Where-Object { $_.agentUse -and (Test-SlotNeed $_ $need) -and (Test-SlotProject $_ $projectFilter) })
    if ($matched.Count -eq 0) {
        Say ('NO SLOT: no agent slot has purpose or platform "{0}"{1}.' -f $need, $(if ($projectFilter) { ' in ' + $projectFilter } else { '' }))
        Say ('see: unity-slot slots   new clone plan: unity-slot new-clone {0}{1}' -f $need, $(if ($projectFilter) { ' -Project ' + $projectFilter } else { '' }))
        $script:ExitCode = 5
        return
    }
    $projects = @($matched | ForEach-Object { $_.project } | Select-Object -Unique)
    if ($projects.Count -gt 1) {
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
        Say ('next    show the user a new clone plan: unity-slot new-clone {0} -Project {1}' -f $need, $projects[0])
        $script:ExitCode = 5
        return
    }

    $chosen = $null
    $lease = $null
    foreach ($c in @($free | Sort-Object Rank, @{ Expression = { $_.LastUsed }; Descending = $true })) {
        $existing = $c.State.Lease
        if ($null -ne $existing -and $existing.owner -eq $ownerId) {
            $existing.expiresAt = (Get-Date).AddHours((Get-LeaseHours))
            Update-SlotLease $c.Slot.name $existing
            $chosen = $c; $lease = $existing
            Say ('lease   already yours; extended to {0}' -f (Format-Time $existing.expiresAt))
            break
        }
        $replace = ($null -ne $existing -and $existing.Expired)
        $lease = New-SlotLease $c.Slot $ownerId $need (Get-LeaseHours) $replace
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
    $state = 'closed (-NoOpen)'
    if ($editorPid -gt 0) { $state = 'editor pid ' + $editorPid }
    if ($NoWait -and $lease.openedByAcquire) { $state += ' starting (run: unity-slot wait ' + $slot.name + ')' }
    Say ('ACQUIRED {0}: {1}; work in {2}' -f $slot.name, $state, $slot.path)
    Say ('next    check Application.dataPath through MCP; when done: unity-slot release {0} -Owner {1}' -f $slot.name, $lease.owner)
}

function Invoke-Release {
    $reg = Read-Registry
    $slot = Find-Slot $reg $Target
    if ($null -eq $slot) { throw ('no registered slot named or located at "{0}". See: unity-slot slots' -f $Target) }
    $ownerId = Resolve-Owner
    $snap = Get-Snapshot
    $st = Get-SlotState $slot $snap
    Say ('slot    {0}: {1}; lease {2}' -f $slot.name, $st.Text, (Format-Lease $st.Lease))
    if ($null -eq $st.Lease) {
        Say 'NOT LEASED: nothing to release. Editors are only closed for the session that holds the lease.'
        return
    }
    if ($st.Lease.owner -ne $ownerId -and -not $AnyOwner) {
        Say ('REFUSED: the lease belongs to {0}, not {1}. -AnyOwner releases it anyway (only when the user says so).' -f $st.Lease.owner, $ownerId)
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
