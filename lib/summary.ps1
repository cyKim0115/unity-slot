# summary: the short status for people and agents, and the MCP status tool's default output.
# One line for the machine (editors open of maxEditors, commit), one table (slot, platform, mode,
# state, lease, agent use), then the warnings (system flags, the slots' flags). States and flags are
# the dashboard's: Invoke-Dashboard runs in-process (shallow: no git, event history or memory trees,
# which the table does not show) and hands back its document, so the dashboard stays the one place
# that decides them (its JSON contract is not changed here).
# Dot-sourced by unity-slot.ps1. ASCII-only source.

$script:SummaryStates = @{
    closed = 'closed'; starting = 'starting'; ready = 'ready'; stalled = 'STALLED'
    unknown = 'open'; batch = 'batch'; missing = 'missing'
}

# The dashboard document as an object, computed shallow and never turned into JSON.
function Get-DashboardDocument {
    return (Invoke-Dashboard -Shallow -AsObject)
}

function Format-SummaryLease($Slot) {
    $l = $Slot.lease
    if ($null -eq $l) {
        if (@($Slot.flags) -contains 'open-without-lease') { return 'no lease (in use?)' }
        return '-'
    }
    $until = '?'
    if ($l.expiresAt) { $until = ([datetime]::Parse([string]$l.expiresAt, $script:Inv)).ToString('MM-dd HH:mm', $script:Inv) }
    $text = '{0} until {1}' -f $l.owner, $until
    if ($l.expired) { $text += ' EXPIRED' }
    return $text
}

function Invoke-Summary {
    $reg = Read-Registry
    if ($reg.slots.Count -eq 0) {
        if (Test-ViaMcp) { Write-Host ('no slots registered yet ({0}). Ask the user to register the clones (scan).' -f (Get-RegistryPath)) }
        else { Write-Host ('no slots registered yet ({0}). Run: unity-slot scan -Project <owner/repo> -Apply' -f (Get-RegistryPath)) }
        return
    }
    $wanted = @{}
    foreach ($s in @(Select-RegistrySlots $reg)) { $wanted[$s.name.ToLowerInvariant()] = $true }
    $doc = Get-DashboardDocument
    $sys = $doc.system
    # editorsOpen counts every editor (memory does not care whose); the ones of no registered slot are
    # named so that "2/6" next to a table of closed slots is not a puzzle
    $outside = @(@($doc.unregisteredEditors) | Where-Object { $null -ne $_ -and [string]$_.kind -eq 'editor' }).Count
    $outsideText = ''
    if ($outside -gt 0) { $outsideText = ' ({0} outside the registry)' -f $outside }
    Write-Host ('unity-slot  editors {0}/{1}{2} | commit {3}% ({4}/{5}GB)' -f $sys.editorsOpen, $doc.registry.maxEditors, $outsideText, $sys.commit.percent,
        (Format-Num $sys.commit.usedGB), (Format-Num $sys.commit.limitGB))
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $flagLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in @($doc.slots)) {
        if (-not $wanted.ContainsKey(([string]$s.name).ToLowerInvariant())) { continue }
        $state = $script:SummaryStates[[string]$s.editor.state]
        if (-not $state) { $state = [string]$s.editor.state }
        $rows.Add(@([string]$s.name, [string]$s.platform, [string]$s.mode, $state, (Format-SummaryLease $s), $(if ($s.agentUse) { 'yes' } else { 'no' })))
        # open-without-lease already shows in the lease column
        $f = @(@($s.flags) | Where-Object { $_ -and $_ -ne 'open-without-lease' })
        if ($f.Count -gt 0) { $flagLines.Add(('flags   {0}: {1}' -f $s.name, ($f -join ', '))) }
        if ($null -ne $s.lease) {
            $l = [pscustomobject]@{ owner = [string]$s.lease.owner; clientName = ''; clientPid = 0 }
            $alive = $null
            if ($null -ne $s.lease.client) { $l.clientName = [string]$s.lease.client.name; $l.clientPid = [int]$s.lease.client.pid; $alive = [bool]$s.lease.client.alive }
            foreach ($n in @(Get-LeaseNotes ([string]$s.name) $l $alive)) { $flagLines.Add($n) }
        }
    }
    if ($rows.Count -eq 0) { Write-Host 'no slot matches'; return }
    Write-TextTable @('slot', 'platform', 'mode', 'state', 'lease', 'agents') $rows
    foreach ($w in @($doc.systemFlags)) {
        switch ([string]$w) {
            'commit-high' { Write-Host ('warn    commit-high: commit {0}%' -f $sys.commit.percent) }
            'commit-critical' { Write-Host ('warn    commit-critical: commit {0}%' -f $sys.commit.percent) }
            'editors-at-max' { Write-Host ('warn    editors-at-max: {0}/{1} editors open' -f $sys.editorsOpen, $doc.registry.maxEditors) }
            default { Write-Host ('warn    ' + $w) }
        }
    }
    foreach ($line in $flagLines) { Write-Host $line }
}
