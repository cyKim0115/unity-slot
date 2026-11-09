# Closing: a beforeClose hook refusal (unsaved scene), close timeouts (never killed), batchmode runs and
# a held lock file. Dot-sourced by tests\run-tests.ps1. ASCII-only source.

Register-Group 'close' -Clones @('MyGame-1', 'MyGame-Web')

Add-Test -Name 'close.unsaved-scene-refused' -Group 'close' -Body {
    param($E)
    $c = $E.Clones['MyGame-Web']
    Set-StubControl $c @{ mode = 'dirty'; readyMs = '500' } -Reset
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'fay')
    Assert-Exit $r 0
    $pid1 = [int](Get-Match $r.Out '^\[acquire\] READY pid (\d+)')
    Wait-Until { Test-Path -LiteralPath (Join-Path $c 'Temp\SceneBeacon.json') } 10 'the scene beacon'

    $x = Invoke-SlotCli $E @('close', 'MyGame-Web')
    Assert-Exit $x 4
    Assert-Has $x '[close]   scenes  unsaved: Assets/Scenes/SampleScene.unity'
    Assert-Has $x '[close] hook    beforeClose/scene-beacon: exit 4 (refuses)'
    Assert-Has $x '[close] REFUSED: beforeClose hook scene-beacon says not to close now (see above). Save or discard first, or ask the user.'
    Assert-Like $x '^\[close\]\s+-AllowDirty sends the close anyway; Unity then shows its save dialog and stays open\.'
    Assert-True (Test-ProcAlive $pid1) 'editor still open after the refusal'

    $rel = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'fay')
    Assert-Exit $rel 4
    Assert-Has $rel '[release] lease   kept: the editor did not close (exit 4)'
    Assert-Equal (Get-Lease $E 'MyGame-Web').owner 'fay' 'lease kept'

    $d = Invoke-SlotCli $E @('dashboard', '-Json')
    Assert-Exit $d 0
    $slot = @(($d.Out | ConvertFrom-Json).slots | Where-Object { $_.name -eq 'MyGame-Web' })[0]
    Assert-True ($slot.editor.unsavedScene -eq $true) 'dashboard editor.unsavedScene'
    Assert-True (@($slot.flags) -contains 'unsaved-scene') 'dashboard flag unsaved-scene'

    # -AllowDirty: the editor shows its save dialog and stays open; the close times out, nothing is clicked
    $y = Invoke-SlotCli $E @('close', 'MyGame-Web', '-AllowDirty', '-TimeoutSec', '4')
    Assert-Exit $y 2
    Assert-Has $y '[close] note    beforeClose refused (scene-beacon); closing anyway (-AllowDirty).'
    Assert-Has $y ('[close] STILL OPEN pid {0} after 4s. Not killed.' -f $pid1)
    Assert-Like $y 'title="Scene\(s\) Have Been Modified" buttons=\[Save, Don''t Save, Cancel\] text="Do you want to save the changes'
    Assert-Has $y '[close] hook    closeStalled/record: exit 0'
    Assert-True (Test-ProcAlive $pid1) 'left running, not killed'
    Assert-HasNot (Get-StubLog $c) 'button clicked' 'stub log (no dialog button may be clicked)'
    $calls = @(Get-HookCalls $E | Where-Object { $_.Event -eq 'closeStalled' })
    Assert-True ($calls.Count -ge 1) 'closeStalled hook ran'
    Assert-Equal $calls[-1].Pid $pid1 'closeStalled hook pid'
    Assert-Equal $calls[-1].Slot 'MyGame-Web' 'closeStalled hook slot'

    # saved (as an editor tool would do it): the release closes it
    Set-StubControl $c @{ dirty = '0' }
    Wait-Until { (Get-StubLog $c).Contains('[stub] saved; save dialog closed') } 10 'the stub to save'
    $ok = Invoke-SlotCli $E @('release', 'MyGame-Web', '-Owner', 'fay')
    Assert-Exit $ok 0
    Assert-Has $ok '[release]   scenes  all saved'
    Assert-Has $ok '[release] RELEASED MyGame-Web'
    Assert-True (-not (Test-ProcAlive $pid1)) 'closed after saving'

    $refused = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'refused' })
    Assert-Equal $refused.Count 2 'refused events (close, release)'
    Assert-Equal $refused[0].detail.command 'close' 'refused command'
    Assert-Equal $refused[0].detail.reason 'beforeClose' 'refused reason'
    Assert-Equal (@($refused[0].detail.hooks) -join ',') 'scene-beacon' 'refused hooks'
}

Add-Test -Name 'close.timeout-left-running' -Group 'close' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    Set-StubControl $c @{ mode = 'ignore-close'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-1')
    Assert-Exit $o 0
    $pid1 = [int](Get-Match $o.Out '^\[open\] READY pid (\d+)')
    $x = Invoke-SlotCli $E @('close', 'MyGame-1', '-TimeoutSec', '4')
    Assert-Exit $x 2
    Assert-Has $x ('[close] close requested for pid {0} (same as clicking X)' -f $pid1)
    Assert-Has $x ('[close] STILL OPEN pid {0} after 4s. Not killed.' -f $pid1)
    Assert-Has $x ('[close] windows of pid {0} (look only, nothing is clicked):' -f $pid1)
    Assert-Has $x ('title="MyGame-1 - SampleScene - Android - Unity 9999.0 ({0}) <DX12>"' -f $script:StubVersion)
    Assert-Has $x '[close] A save dialog or a long save is the usual cause. Hand it to the user; do not click from a script.'
    Assert-True (Test-ProcAlive $pid1) 'left running, not killed'
    Assert-Has (Get-StubLog $c) '[stub] close ignored'
    Assert-Equal @(Get-HookCalls $E | Where-Object { $_.Event -eq 'closeStalled' -and $_.Pid -eq [string]$pid1 }).Count 1 'closeStalled hook'
    $left = @(Stop-Stubs @($c))
    Assert-Equal $left.Count 0 'the stub ended by itself (control file)'
    $n = Invoke-SlotCli $E @('close', 'MyGame-1')
    Assert-Exit $n 0
    Assert-Has $n '[close] NOT OPEN: no Unity.exe has this clone as -projectPath'
}

Add-Test -Name 'close.slow-close-ends-later' -Group 'close' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    Set-StubControl $c @{ mode = 'slow-close'; closeMs = '7000'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-1')
    Assert-Exit $o 0
    $pid1 = [int](Get-Match $o.Out '^\[open\] READY pid (\d+)')
    $x = Invoke-SlotCli $E @('close', 'MyGame-1', '-TimeoutSec', '3')
    Assert-Exit $x 2
    Assert-Has $x ('[close] STILL OPEN pid {0} after 3s. Not killed.' -f $pid1)
    Wait-Until { -not (Test-ProcAlive $pid1) } 20 'the slow close to finish by itself'
    Assert-Equal (Get-LockStateH $c) 'none' 'Temp\UnityLockfile after the slow close'
    $n = Invoke-SlotCli $E @('close', 'MyGame-1')
    Assert-Exit $n 0
    Assert-Has $n '[close] NOT OPEN'
}

Add-Test -Name 'close.batchmode-run-refused' -Group 'close' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    $n0 = Get-EventCount $E
    $bp = Start-StubDirect $c @('-batchMode') -NoLogFile
    Wait-Until { (Get-LockStateH $c) -eq 'held' } 10 'the batch run to hold the lock'
    $o = Invoke-SlotCli $E @('open', 'MyGame-1')
    Assert-Exit $o 4
    Assert-Has $o ('[open] BUSY: batchmode Unity pid {0} is using this clone. Wait until it quits.' -f $bp)
    $x = Invoke-SlotCli $E @('close', 'MyGame-1')
    Assert-Exit $x 4
    Assert-Has $x ('[close] REFUSED: batchmode Unity pid {0} is working on this clone. It quits by itself; not touching it.' -f $bp)
    $a = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'gus', '-NoOpen')
    Assert-Exit $a 5
    Assert-Like $a '^MyGame-1 .*batchmode run in progress'
    Assert-True (Test-ProcAlive $bp) 'batch run untouched'
    $refused = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'refused' })
    Assert-Equal (($refused | ForEach-Object { $_.detail.command + ':' + $_.detail.reason }) -join ',') 'open:batchmode run,close:batchmode run' 'refused events'
}

Add-Test -Name 'close.lock-held-without-editor' -Group 'close' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    $n0 = Get-EventCount $E
    $dir = Join-Path $c 'Temp'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $lock = Join-Path $dir 'UnityLockfile'
    $fs = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $o = Invoke-SlotCli $E @('open', 'MyGame-1')
        Assert-Exit $o 4
        Assert-Has $o '[open] STOP: Temp\UnityLockfile is held, but no Unity.exe has this clone as -projectPath. Not opening; check Task Manager.'
        Assert-True (@(Get-StubProcs $c).Count -eq 0) 'nothing started'
        $x = Invoke-SlotCli $E @('close', 'MyGame-1')
        Assert-Exit $x 0
        Assert-Has $x '[close] note    Temp\UnityLockfile is held by some process anyway; check Task Manager'
        $d = Invoke-SlotCli $E @('dashboard', '-Json')
        Assert-Exit $d 0
        $slot = @(($d.Out | ConvertFrom-Json).slots | Where-Object { $_.name -eq 'MyGame-1' })[0]
        Assert-True (@($slot.flags) -contains 'stale-lock') 'dashboard flag stale-lock'
    } finally {
        $fs.Dispose()
        Remove-Item -LiteralPath $lock -Force
    }
    $refused = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'refused' })
    Assert-Equal (($refused | ForEach-Object { $_.detail.reason }) -join ',') 'lock held' 'refused events'
}
