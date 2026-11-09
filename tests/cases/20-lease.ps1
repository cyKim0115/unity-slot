# Leases: scan, acquire / wait / release, races, other owners, expired leases, no free slot, hot slots.
# Dot-sourced by tests\run-tests.ps1. ASCII-only source.

Register-Group 'lease' -Clones @('MyGame', 'MyGame-1', 'MyGame-2', 'MyGame-Web')

Add-Test -Name 'lease.scan-registers-clones' -Group 'lease' -Body {
    param($E)
    $doc = Get-EnvSlotsJson $E
    Assert-True (Test-UnderPath $doc.registry $E.Home) ('registry outside the test state folder: ' + $doc.registry)
    $by = @{}
    foreach ($item in @($doc.slots)) { $by[$item.name] = $item }
    Assert-Equal (@($doc.slots).Count) 4 'slots'
    Assert-True (-not $by['MyGame'].agentUse) 'MyGame (no suffix) is the main clone, not for agents'
    Assert-Equal (@($by['MyGame'].purposes) -join ',') 'main' 'MyGame purposes'
    foreach ($n in @('MyGame-1', 'MyGame-2')) {
        Assert-True ([bool]$by[$n].agentUse) ($n + ' agentUse')
        Assert-Equal (@($by[$n].purposes) -join ',') 'agent' ($n + ' purposes')
        Assert-Equal $by[$n].platform 'Android' ($n + ' platform (Library settings)')
    }
    Assert-Equal $by['MyGame-Web'].platform 'WebGL' 'MyGame-Web platform'
    Assert-Equal (@($by['MyGame-Web'].purposes) -join ',') 'webgl' 'MyGame-Web purposes'
    foreach ($item in @($doc.slots)) {
        Assert-Equal $item.project $script:ProjectKey ($item.name + ' project')
        Assert-Equal $item.state 'closed' ($item.name + ' state')
        Assert-True ($null -eq $item.lease) ($item.name + ' lease')
        Assert-Equal $item.branch 'master' ($item.name + ' branch')
    }
}

Add-Test -Name 'lease.acquire-wait-release' -Group 'lease' -Body {
    param($E)
    foreach ($c in @('MyGame-1', 'MyGame-2')) { Set-StubControl $E.Clones[$c] @{ mode = 'normal'; readyMs = '1500'; workers = '1' } -Reset }
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'alice', '-NoWait')
    Assert-Exit $r 0
    $slot = Get-Match $r.Out '^\[acquire\] ACQUIRED (\S+): editor pid \d+ starting \(run: unity-slot wait \S+\); work in '
    Assert-True ($slot -eq 'MyGame-1' -or $slot -eq 'MyGame-2') ('ACQUIRED line' + (Format-Excerpt $r))
    $clone = $E.Clones[$slot]
    $pid1 = [int](Get-Match $r.Out '^\[acquire\] STARTED pid (\d+); not waiting here\. Run "unity-slot wait ')
    Assert-Has $r ('[acquire] next    check Application.dataPath through MCP; when done: unity-slot release {0} -Owner alice' -f $slot)
    $lease = Get-Lease $E $slot
    Assert-Equal $lease.owner 'alice' 'lease owner'
    Assert-Equal $lease.editorPid $pid1 'lease editorPid'
    Assert-True ([bool]$lease.openedByAcquire) 'lease openedByAcquire'
    Assert-True (Test-ProcAlive $pid1) 'editor started'
    Assert-True ((Get-ForegroundPid) -ne $pid1) 'the stub must not take the focus'

    $w = Invoke-SlotCli $E @('wait', $slot, '-TimeoutSec', '20')
    Assert-Exit $w 0
    Assert-Like $w ('^\[wait\] READY pid {0} [0-9.]+s after start\. Unity projectLoad [0-9.]+s \(assetDatabaseRefresh' -f $pid1)
    Assert-Has $w '[wait] license [Licensing::Client] Successfully resolved entitlement details'
    Assert-Like $w '^\[wait\] now     1 import worker\(s\), 0 other child process\(es\)'
    Assert-Equal (Get-LockStateH $clone) 'held' 'Temp\UnityLockfile while open'

    $rel = Invoke-SlotCli $E @('release', $slot, '-Owner', 'alice')
    Assert-Exit $rel 0
    Assert-Has $rel '[release]   scenes  unknown (no Temp\SceneBeacon.json); closing'
    Assert-Has $rel ('[release] close requested for pid {0} (same as clicking X)' -f $pid1)
    Assert-Like $rel '^\[release\] CLOSED after [0-9.]+s'
    Assert-Has $rel '[release] children all 1 child process(es) exited'
    Assert-Has $rel '[release] git     nothing written by the close (working tree clean)'
    Assert-Like $rel '^\[release\] git     nothing changed since open at '
    Assert-Has $rel ('[release] RELEASED {0}' -f $slot)
    Assert-True ($null -eq (Get-Lease $E $slot)) 'lease file removed'
    Assert-True (-not (Test-ProcAlive $pid1)) 'editor ended'
    Assert-True (@(Get-StubProcs $clone).Count -eq 0) 'import worker ended'
    Assert-Equal (Get-LockStateH $clone) 'none' 'Temp\UnityLockfile after the close'

    $ev = @(Get-NewEvents $E $n0 | Where-Object { $_.slot -eq $slot })
    Assert-Equal (($ev | ForEach-Object { $_.event }) -join ',') 'acquire,open,ready,close,release' 'events'
    foreach ($ev1 in $ev) { Assert-Equal $ev1.via 'cli' ('via of ' + $ev1.event) }
    foreach ($ev1 in @($ev | Where-Object { $_.event -in @('open', 'ready', 'close', 'release') })) { Assert-Equal $ev1.pid $pid1 ('pid of ' + $ev1.event) }
    Assert-Equal $ev[0].owner 'alice' 'acquire owner'
    Assert-Equal $ev[0].detail.need 'agent' 'acquire need'
    Assert-True ([double]$ev[2].detail.readySeconds -gt 0) 'ready readySeconds'
    Assert-Equal $ev[3].detail.changedFiles 0 'close changedFiles'
    Assert-True ([double]$ev[3].detail.closeSeconds -gt 0) 'close closeSeconds'
    Assert-True ([bool]$ev[4].detail.closed) 'release closed'
    Assert-Equal $ev[4].detail.leaseOwner 'alice' 'release leaseOwner'
    Assert-Equal $ev[4].owner 'alice' 'release owner'
}

Add-Test -Name 'lease.race-two-acquires' -Group 'lease' -Body {
    param($E)
    for ($round = 1; $round -le 2; $round++) {
        $a = Start-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', ('raceA' + $round), '-NoOpen')
        $b = Start-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', ('raceB' + $round), '-NoOpen')
        $ra = Complete-SlotCli $a
        $rb = Complete-SlotCli $b
        Assert-Equal ((@($ra.Code, $rb.Code) | Sort-Object) -join ',') '0,5' ('round {0} exit codes (A {1}, B {2})' -f $round, $ra.Code, $rb.Code)
        $winner = 'raceB' + $round
        $loser = $ra
        if ($ra.Code -eq 0) { $winner = 'raceA' + $round; $loser = $rb }
        Assert-Like $loser 'NO FREE SLOT'
        Assert-Equal (@(Get-LeaseNames $E) -join ',') 'MyGame-Web' 'lease files'
        Assert-Equal (Get-Lease $E 'MyGame-Web').owner $winner 'lease owner'
        $rel = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', $winner)
        Assert-Exit $rel 0
        Assert-Has $rel '[release] RELEASED MyGame-Web'
    }
}

# Two acquires that saw the same expired lease must not both win (F4). tests\fixtures\takeover-race.ps1
# plays the two processes in a fixed order with the core's own functions, so the race is deterministic.
Add-Test -Name 'lease.takeover-race' -Group 'lease' -Body {
    param($E)
    Assert-Exit (Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'old', '-NoOpen', '-Hours', '0.0003')) 0
    Start-Sleep -Milliseconds 1300
    $r = Invoke-Fixture $E 'takeover-race.ps1' @('-Slot', 'MyGame-Web')
    Assert-True ($r.Code -eq 0) ('race fixture exit ' + $r.Code + (Format-Excerpt $r))
    $res = $r.Out.Trim() | ConvertFrom-Json
    $winners = @(@($res.a, $res.b) | Where-Object { $_ })
    Assert-Equal $winners.Count 1 ('winners (A {0}, B {1})' -f $res.a, $res.b)
    Assert-Equal $res.file $winners[0] 'the lease file names the one winner'
}

# Extending your own lease through acquire is a renew and is logged like one (F2).
Add-Test -Name 'lease.acquire-own-lease-logs-renew' -Group 'lease' -Body {
    param($E)
    Assert-Exit (Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'kay', '-NoOpen')) 0
    $n0 = Get-EventCount $E
    $again = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'kay', '-NoOpen')
    Assert-Exit $again 0
    Assert-Like $again '^\[acquire\] lease   already yours; extended to '
    $ev = @(Get-NewEvents $E $n0)
    Assert-Equal (($ev | ForEach-Object { $_.event }) -join ',') 'renew' 'events of extending your own lease'
    Assert-Equal $ev[0].owner 'kay' 'renew owner'
    Assert-Equal $ev[0].slot 'MyGame-Web' 'renew slot'
    Assert-Equal $ev[0].detail.by 'acquire' 'renew detail.by'
    Assert-True ([string]$ev[0].detail.expiresAt -ne '') 'renew detail.expiresAt'
}

Add-Test -Name 'lease.release-refused-for-other-owner' -Group 'lease' -Body {
    param($E)
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'normal'; readyMs = '500' } -Reset
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'alice', '-NoWait')
    Assert-Exit $r 0
    $pid1 = [int](Get-Match $r.Out 'STARTED pid (\d+);')
    $x = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'bob')
    Assert-Exit $x 4
    Assert-Has $x '[release] REFUSED: the lease belongs to alice, not bob. -AnyOwner releases it anyway (only when the user says so).'
    Assert-Equal (Get-Lease $E 'MyGame-Web').owner 'alice' 'lease after the refused release'
    Assert-True (Test-ProcAlive $pid1) 'editor untouched by the refused release'
    $y = Invoke-SlotCli $E @('renew', 'MyGame-Web', '-Owner', 'bob')
    Assert-Exit $y 4
    Assert-Has $y '[renew] REFUSED: the lease belongs to alice'
    $z = Invoke-SlotCli $E @('renew', 'MyGame-Web', '-Owner', 'alice', '-Hours', '2')
    Assert-Exit $z 0
    Assert-Like $z '^\[renew\] RENEWED MyGame-Web until '
    $exp = [datetime]::Parse([string](Get-Lease $E 'MyGame-Web').expiresAt, $script:Inv, [Globalization.DateTimeStyles]::RoundtripKind)
    Assert-True ([math]::Abs(($exp - (Get-Date).AddHours(2)).TotalMinutes) -lt 5) ('renewed expiresAt ' + $exp)
    $rel = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'alice')
    Assert-Exit $rel 0
    Assert-Has $rel '[release] RELEASED MyGame-Web'
    Assert-True (-not (Test-ProcAlive $pid1)) 'the owner''s release closed the editor'
    $ev = @(Get-NewEvents $E $n0)
    $refused = @($ev | Where-Object { $_.event -eq 'refused' })
    Assert-Equal $refused.Count 2 'refused events'
    Assert-Equal $refused[0].detail.command 'release' 'refused command'
    Assert-Equal $refused[0].detail.reason 'lease of someone else' 'refused reason'
    Assert-Equal $refused[0].detail.leaseOwner 'alice' 'refused leaseOwner'
    Assert-Equal $refused[0].owner 'bob' 'refused owner'
    Assert-Equal $refused[1].detail.command 'renew' 'second refused command'
    Assert-Equal @($ev | Where-Object { $_.event -eq 'renew' }).Count 1 'renew events'
}

Add-Test -Name 'lease.expired-lease' -Group 'lease' -Body {
    param($E)
    # a closed slot: the next acquire takes an expired lease over
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'old', '-NoOpen', '-Hours', '0.0003')
    Assert-Exit $r 0
    Start-Sleep -Milliseconds 1300
    $t = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'new', '-NoOpen')
    Assert-Exit $t 0
    Assert-Has $t '[acquire] lease   replaced the expired lease of old'
    Assert-Equal (Get-Lease $E 'MyGame-Web').owner 'new' 'lease after the takeover'
    $take = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'takeover' })
    Assert-Equal $take.Count 1 'takeover events'
    Assert-Equal $take[0].detail.previousOwner 'old' 'takeover previousOwner'
    Assert-Equal $take[0].owner 'new' 'takeover owner'
    Assert-Exit (Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'new')) 0

    # an open slot: an expired lease is not taken over while its editor runs
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'normal'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'old2', '-NoWait', '-Hours', '0.0003')
    Assert-Exit $o 0
    $pid1 = [int](Get-Match $o.Out 'STARTED pid (\d+);')
    Assert-Exit (Invoke-SlotCli $E @('wait', 'MyGame-Web', '-TimeoutSec', '20')) 0
    $n = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'new2', '-NoOpen')
    Assert-Exit $n 5
    Assert-Like $n 'expired lease \(old2 until [0-9-]+ [0-9:]+ EXPIRED\) and the editor is still open; ask the user'
    Assert-Equal (Get-Lease $E 'MyGame-Web').owner 'old2' 'expired lease kept'
    Assert-True (Test-ProcAlive $pid1) 'editor untouched'
    $rel = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'old2')
    Assert-Exit $rel 0
    Assert-Has $rel '[release] RELEASED MyGame-Web'
}

Add-Test -Name 'lease.no-free-slot' -Group 'lease' -Body {
    param($E)
    $n = Invoke-SlotCli $E @('acquire', 'nosuch', '-Project', 'mygame', '-Owner', 'x', '-NoOpen')
    Assert-Exit $n 5
    Assert-Has $n '[acquire] NO SLOT: no agent slot has purpose or platform "nosuch" in mygame.'
    Assert-Has $n '[acquire] see: unity-slot slots   new clone plan: unity-slot new-clone nosuch -Project mygame'
    foreach ($o in @('a1', 'a2')) { Assert-Exit (Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', $o, '-NoOpen')) 0 }
    # android fits MyGame-1 and MyGame-2 (both leased now); MyGame is Android too but not for agents
    $f = Invoke-SlotCli $E @('acquire', 'android', '-Project', 'mygame', '-Owner', 'b')
    Assert-Exit $f 5
    Assert-Has $f '[acquire] NO FREE SLOT for "android". Nothing was opened.'
    Assert-Has $f ('[acquire] next    show the user a new clone plan: unity-slot new-clone android -Project {0}' -f $script:ProjectKey)
    Assert-NotLike $f '^MyGame\s' 'acquire table (the main clone must not be offered)'
    Assert-Equal ((@(Get-LeaseNames $E) | Sort-Object) -join ',') 'MyGame-1,MyGame-2' 'lease files'
    foreach ($c in @($E.Clones.Values)) { Assert-True (@(Get-StubProcs $c).Count -eq 0) ('nothing opened: ' + $c) }
}

Add-Test -Name 'lease.own-lease-and-hot-slot' -Group 'lease' -Body {
    param($E)
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'normal'; readyMs = '500' } -Reset
    $r = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'carol', '-NoOpen')
    Assert-Exit $r 0
    Assert-Like $r '^\[acquire\] ACQUIRED MyGame-Web: closed \(-NoOpen\); work in '
    $again = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'carol', '-NoOpen')
    Assert-Exit $again 0
    Assert-Like $again '^\[acquire\] lease   already yours; extended to '
    Assert-Exit (Invoke-SlotCli $E @('set', 'MyGame-Web', '-Mode', 'hot')) 0
    try {
        $o = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'carol')
        Assert-Exit $o 0
        $pid1 = [int](Get-Match $o.Out '^\[acquire\] READY pid (\d+)')
        $rel = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'carol')
        Assert-Exit $rel 0
        Assert-Has $rel '[release] editor  hot slot: stays open'
        Assert-True (Test-ProcAlive $pid1) 'a hot slot stays open after release'
        $d = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'dave')
        Assert-Exit $d 0
        Assert-Has $d ('[acquire] ACQUIRED MyGame-Web: editor pid {0}; work in ' -f $pid1)
        Assert-HasNot $d '[acquire] started pid' 'acquire of an open hot slot'
        Assert-Exit (Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'dave')) 0
        Assert-True (Test-ProcAlive $pid1) 'still open'
    } finally {
        [void](Invoke-SlotCli $E @('set', 'MyGame-Web', '-Mode', 'ondemand'))
    }
    $cl = Invoke-SlotCli $E @('close', 'MyGame-Web')
    Assert-Exit $cl 0
    Assert-Like $cl '^\[close\] CLOSED after '
}

Add-Test -Name 'lease.editor-exits-before-ready' -Group 'lease' -Body {
    param($E)
    $c = $E.Clones['MyGame-Web']
    Set-StubControl $c @{ mode = 'exit-early'; exitMs = '1500' } -Reset
    $r = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'erin', '-TimeoutSec', '20')
    Assert-Exit $r 1
    Assert-Like $r '^\[acquire\] EXITED: pid \d+ ended [0-9.]+s after start, before it was ready\. Last log lines:'
    Assert-Has $r '[acquire] lease   released: the editor did not start (exit 1)'
    Assert-True ($null -eq (Get-Lease $E 'MyGame-Web')) 'no lease left'
    Assert-Equal (Get-LockStateH $c) 'stale' 'Temp\UnityLockfile after a crash'
    Set-StubControl $c @{ mode = 'normal'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-Web')
    Assert-Exit $o 0
    Assert-Has $o '[open] note    stale Temp\UnityLockfile (last editor did not exit cleanly); Unity takes it over'
    Assert-Like $o '^\[open\] READY pid \d+'
    Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-Web')) 0
}
