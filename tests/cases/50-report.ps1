# What unity-slot reports: events.jsonl (format, rotation), the dashboard document (schema, states, flags,
# no secrets), status and wait on an editor the Hub started. Dot-sourced by tests\run-tests.ps1.
# ASCII-only source.

Register-Group 'report' -Clones @('MyGame', 'MyGame-1', 'MyGame-2', 'MyGame-Web') -Stray @('Stray')

Add-Test -Name 'report.events-format' -Group 'report' -Body {
    param($E)
    $n0 = Get-EventCount $E
    Assert-Exit (Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'kim', '-NoOpen')) 0
    Assert-Exit (Invoke-SlotCli $E @('renew', 'MyGame-Web', '-Owner', 'kim')) 0
    Assert-Exit (Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'lee')) 4
    Assert-Exit (Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'kim')) 0
    $lines = @(Get-EventLines $E | Select-Object -Skip $n0)
    Assert-Equal $lines.Count 4 'event lines'
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        # the dashboard reads time, event and slot with a regex: they come first, in this order
        Assert-Like $line '^\{"time":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}","event":"[a-z]+","slot":"MyGame-Web",' 'event line'
        $ev1 = $line | ConvertFrom-Json
        Assert-Equal (@($ev1.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'time,event,slot,path,owner,pid,via,detail' 'event fields'
        Assert-Equal $ev1.via 'cli' 'via'
        Assert-True (Test-SamePathH $ev1.path $E.Clones['MyGame-Web']) ('path ' + $ev1.path)
        $names.Add($ev1.event)
    }
    Assert-Equal ($names -join ',') 'acquire,renew,refused,release' 'events'
}

Add-Test -Name 'report.events-rotation' -Group 'report' -Body {
    param($E)
    $file = Join-Path $E.Home 'events.jsonl'
    $prev = Join-Path $E.Home 'events-prev.jsonl'
    $old = '{"time":"2026-01-01T00:00:00+09:00","event":"renew","slot":"Old","path":null,"owner":"x","pid":null,"via":"cli","detail":{"pad":"' + ('x' * 900) + '"}}'
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt 1200; $i++) { [void]$sb.Append($old).Append("`n") }
    [IO.File]::WriteAllText($file, $sb.ToString(), $script:Utf8)
    $size = (Get-Item -LiteralPath $file).Length
    Assert-True ($size -gt 1MB) 'filled events.jsonl over 1 MB'
    Assert-Exit (Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'rot', '-NoOpen')) 0
    Assert-True (Test-Path -LiteralPath $prev) 'events-prev.jsonl made'
    Assert-Equal (Get-Item -LiteralPath $prev).Length $size 'events-prev.jsonl holds the old file'
    $now = @(Get-EventLines $E)
    Assert-Equal $now.Count 1 'events.jsonl starts over'
    Assert-Equal ($now[0] | ConvertFrom-Json).event 'acquire' 'the new event'
    $d = Invoke-SlotCli $E @('dashboard', '-Json')
    Assert-Exit $d 0
    Assert-Equal @(($d.Out | ConvertFrom-Json).recentEvents).Count 1 'dashboard recentEvents after the rotation'
}

# install.json names the copy that widgets run. Another copy, even a newer one (a development checkout),
# must not take it over while the copy it names exists (F3). A missing copy is replaced, and the copy it
# names refreshes its own entry.
Add-Test -Name 'report.install-pointer-kept' -Group 'report' -Body {
    param($E)
    $pointer = Join-Path $E.Home 'install.json'
    Assert-Exit (Invoke-SlotCli $E @('slots')) 0
    $doc = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
    Assert-True (Test-SamePathH $doc.script $script:CliPath) ('the pointer names this copy: ' + $doc.script)
    Assert-Equal $doc.version (Get-CoreVersion) 'pointer version'
    $copy = New-CoreCopy $E '99.0.0'
    Assert-Exit (Invoke-SlotCli $E @('slots') -Cli $copy) 0
    $doc = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
    Assert-True (Test-SamePathH $doc.script $script:CliPath) ('a newer copy must not take the pointer over: ' + $doc.script)
    $gone = Join-Path $E.Dir 'gone\unity-slot.ps1'
    Write-TextFile $pointer (([ordered]@{ script = $gone; version = '0.0.1'; schema = 1 } | ConvertTo-Json -Compress) + "`n")
    Assert-Exit (Invoke-SlotCli $E @('slots') -Cli $copy) 0
    $doc = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
    Assert-True (Test-SamePathH $doc.script $copy) ('a missing copy is replaced: ' + $doc.script)
    Write-TextFile $pointer (([ordered]@{ script = $copy; version = '0.0.1'; schema = 1 } | ConvertTo-Json -Compress) + "`n")
    Assert-Exit (Invoke-SlotCli $E @('slots') -Cli $copy) 0
    $doc = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
    Assert-Equal $doc.version '99.0.0' 'the copy it names refreshes its version'
}

Add-Test -Name 'report.dashboard-and-secrets' -Group 'report' -Body {
    param($E)
    $s1 = 'TOKEN-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $s2 = 'HUBSESSION-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $s3 = 'LICENSE-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    # MyGame-2 started like the Hub does: no -logFile, secrets on the command line
    $hubPid = Start-StubDirect $E.Clones['MyGame-2'] @('-useHub', '-accessToken', $s1, '-hubSessionId', $s2) -NoLogFile
    # an editor of a clone that is not registered
    $strayPid = Start-StubDirect $E.Stray['Stray'] @('-cbmEditorLicense', $s3)
    Wait-Until { (Get-LockStateH $E.Clones['MyGame-2']) -eq 'held' -and (Get-LockStateH $E.Stray['Stray']) -eq 'held' } 10 'the directly started stubs'
    # MyGame-1: acquired and ready, a clean scene beacon, one import worker (MyGame-2 is in use, so acquire takes MyGame-1)
    Set-StubControl $E.Clones['MyGame-1'] @{ mode = 'normal'; readyMs = '500'; beacon = '1'; dirty = '0'; workers = '1' } -Reset
    $a = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'alice')
    Assert-Exit $a 0
    Assert-Like $a '^MyGame-2 .*editor open without a lease \(someone is using it\)'
    $pid1 = [int](Get-Match $a.Out '^\[acquire\] READY pid (\d+)')
    Assert-Has $a '[acquire] ACQUIRED MyGame-1: '
    # MyGame-Web: starting, no lease
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'never-ready' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-Web', '-NoWait')
    Assert-Exit $o 0
    $webPid = [int](Get-Match $o.Out '^\[open\] STARTED pid (\d+);')
    Wait-Until { (Test-Path -LiteralPath (Join-Path $E.Clones['MyGame-1'] 'Temp\SceneBeacon.json')) } 10 'the scene beacon'

    $d = Invoke-SlotCli $E @('dashboard', '-Json')
    Assert-Exit $d 0
    Assert-True ([string]::IsNullOrWhiteSpace($d.Err)) ('dashboard stderr: ' + $d.Err)
    Assert-Equal @($d.Out -split "`n" | Where-Object { $_.Trim() }).Count 1 'dashboard stdout lines'
    foreach ($item in @($s1, $s2, $s3)) { Assert-HasNot $d.Out $item 'dashboard' }
    $doc = $d.Out | ConvertFrom-Json
    Assert-Equal $doc.schema 'unity-slot.dashboard/1' 'schema'
    Assert-Equal $doc.version (Get-CoreVersion) 'version'
    Assert-Equal (@($doc.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'schema,version,time,host,registry,system,slots,unregisteredEditors,orphanWorkers,recentEvents,systemFlags,timing' 'top-level fields'
    Assert-True (Test-UnderPath $doc.registry.path $E.Home) ('registry.path ' + $doc.registry.path)
    Assert-True ([int]$doc.system.editorsOpen -ge 4) ('system.editorsOpen ' + $doc.system.editorsOpen)
    Assert-True ([double]$doc.timing.totalMs -gt 0) 'timing.totalMs'
    $by = @{}
    foreach ($item in @($doc.slots)) { $by[$item.name] = $item }
    Assert-Equal @($doc.slots).Count 4 'slots'
    $slotFields = 'name,path,project,repo,kind,unity,platform,purposes,mode,agentUse,memo,exists,editor,lease,git,lastOpenedAt,lastClosedAt,flags'
    $editorFields = 'state,pid,startedAt,readyAt,readySeconds,launch,standby,lock,unsavedScene,memory'
    foreach ($item in @($doc.slots)) {
        Assert-Equal (@($item.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') $slotFields ($item.name + ' fields')
        Assert-Equal (@($item.editor.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') $editorFields ($item.name + ' editor fields')
        Assert-Equal $item.git.branch 'master' ($item.name + ' git.branch')
        Assert-Equal $item.git.changes 0 ($item.name + ' git.changes')
    }
    Assert-Equal $by['MyGame'].editor.state 'closed' 'MyGame state'
    Assert-Equal @($by['MyGame'].flags).Count 0 'MyGame flags'
    $m1 = $by['MyGame-1']
    Assert-Equal $m1.editor.state 'ready' 'MyGame-1 state'
    Assert-Equal $m1.editor.pid $pid1 'MyGame-1 pid'
    Assert-True ([double]$m1.editor.readySeconds -gt 0) 'MyGame-1 readySeconds'
    Assert-Equal $m1.editor.launch 'direct' 'MyGame-1 launch'
    Assert-Equal $m1.editor.standby '1' 'MyGame-1 standby'
    Assert-Equal $m1.editor.lock 'held' 'MyGame-1 lock'
    Assert-True ($m1.editor.unsavedScene -eq $false) 'MyGame-1 unsavedScene false'
    Assert-Equal $m1.editor.memory.workers 1 'MyGame-1 workers'
    Assert-Equal $m1.lease.owner 'alice' 'MyGame-1 lease owner'
    Assert-True ([bool]$m1.lease.openedByAcquire) 'MyGame-1 lease openedByAcquire'
    Assert-Equal @($m1.flags).Count 0 'MyGame-1 flags'
    $m2 = $by['MyGame-2']
    Assert-Equal $m2.editor.state 'unknown' 'MyGame-2 state (no per-clone log)'
    Assert-Equal $m2.editor.launch 'hub' 'MyGame-2 launch'
    Assert-Equal $m2.editor.pid $hubPid 'MyGame-2 pid'
    Assert-True (@($m2.flags) -contains 'open-without-lease') 'MyGame-2 flag open-without-lease'
    $web = $by['MyGame-Web']
    Assert-Equal $web.editor.state 'starting' 'MyGame-Web state'
    Assert-Equal $web.editor.pid $webPid 'MyGame-Web pid'
    Assert-True (@($web.flags) -contains 'open-without-lease') 'MyGame-Web flag open-without-lease'
    $stray = @($doc.unregisteredEditors | Where-Object { $_.pid -eq $strayPid })
    Assert-Equal $stray.Count 1 'unregisteredEditors has the stray editor'
    Assert-True (Test-SamePathH $stray[0].project $E.Stray['Stray']) ('stray project ' + $stray[0].project)

    $st = Invoke-SlotCli $E @('status', '-ShowCommandLine')
    Assert-Exit $st 0
    foreach ($item in @($s1, $s2, $s3)) { Assert-HasNot $st $item 'status -ShowCommandLine' }
    Assert-Has $st '-accessToken ***'
    Assert-Has $st '-hubSessionId ***'
    Assert-Has $st '-cbmEditorLicense ***'
    $sj = Invoke-SlotCli $E @('status', '-Json')
    Assert-Exit $sj 0
    foreach ($item in @($s1, $s2, $s3)) { Assert-HasNot $sj $item 'status -Json' }
    $row = @(($sj.Out | ConvertFrom-Json).Editors | Where-Object { $_.Pid -eq $pid1 })
    Assert-Equal $row.Count 1 'status -Json lists the editor'
    Assert-Equal $row[0].Workers 1 'status -Json workers'
    $w = Invoke-SlotCli $E @('wait', 'MyGame-2')
    Assert-Exit $w 0
    Assert-Has $w ('[wait] READY? pid {0} was not started by unity-slot and has no log to check; running since ' -f $hubPid)
}
