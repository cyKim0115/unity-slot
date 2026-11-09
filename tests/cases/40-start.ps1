# Starting editors: STARTING then READY, STALLED with a dialog (listed, never clicked), open timeouts,
# a missing editor version and platform switches. In this group timeouts.stalled is 12 s and
# timeouts.open 8 s. Dot-sourced by tests\run-tests.ps1. ASCII-only source.

Register-Group 'start' -Clones @('MyGame-1', 'MyGame-Web') -Timeouts @{ stalled = 12; open = 8 }

Add-Test -Name 'start.starting-then-ready' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    Set-StubControl $c @{ mode = 'normal'; readyMs = '10000' } -Reset
    $n0 = Get-EventCount $E
    $o = Invoke-SlotCli $E @('open', 'MyGame-1', '-NoWait', '-StandbyWorkers', '0')
    Assert-Exit $o 0
    $pid1 = [int](Get-Match $o.Out '^\[open\] STARTED pid (\d+); not waiting here\. Run "unity-slot wait ')
    Assert-Like $o '^\[open\] started pid \d+ at .* -standbyWorkerCount 0'
    $item = Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '1')
    Assert-Exit $item 6
    Assert-Like $item ('^\[wait\] STARTING: pid {0} not ready yet, \d+s after start; phase starting the editor, 0 import worker\(s\)\. Call wait again\.' -f $pid1)
    $w = Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '20')
    Assert-Exit $w 0
    Assert-Like $w ('^\[wait\] READY pid {0} ' -f $pid1)
    Assert-Has $w '[wait] note    Unity: "Failed to set standby worker count to 0" - the -standbyWorkerCount argument did not apply'
    $again = Invoke-SlotCli $E @('open', 'MyGame-1')
    Assert-Exit $again 0
    Assert-Like $again ('^\[open\] ALREADY OPEN pid {0} since .* \(direct launch\), 0 import worker\(s\)\. Use this editor\.' -f $pid1)
    $w2 = Invoke-SlotCli $E @('wait', 'MyGame-1')
    Assert-Exit $w2 0
    Assert-Like $w2 ('^\[wait\] READY pid {0} ' -f $pid1)
    Assert-Equal @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'ready' }).Count 1 'ready events (only the first READY of an editor)'
    Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-1')) 0
    $nr = Invoke-SlotCli $E @('wait', 'MyGame-1')
    Assert-Exit $nr 1
    Assert-Has $nr '[wait] NOT RUNNING: no editor has this clone open. Start it with open or acquire.'
    Assert-Has $nr '[wait] last log lines:'
}

Add-Test -Name 'start.stalled-dialog-listed' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    $secret = 'SECRET-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    Set-StubControl $c @{ mode = 'dialog'; logSecret = $secret } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-1', '-NoWait')
    Assert-Exit $o 0
    $pid1 = [int](Get-Match $o.Out '^\[open\] STARTED pid (\d+);')
    Assert-Exit (Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '2')) 6
    $x = Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '10')
    Assert-Exit $x 2
    Assert-Like $x ('^\[wait\] STALLED\?: pid {0} is not ready \d+s after start \(a warm open takes seconds, a cold import much longer\); last phase starting the editor, 0 import worker\(s\)\. Left running\.' -f $pid1)
    Assert-True ((Get-ForegroundPid) -ne $pid1) 'the stub and its dialog must not take the focus'
    Assert-Has $x '[wait] last log lines:'
    Assert-Has $x '[wait]   -accessToken'
    Assert-Has $x '[wait]   ***'
    Assert-HasNot $x $secret 'STALLED output (the log value after -accessToken must be masked)'
    Assert-Has $x ('[wait] windows of pid {0} (look only, nothing is clicked):' -f $pid1)
    Assert-Like $x 'title="Opening Project in Non-Matching Editor Installation" buttons=\[Continue, Quit\] text="This project was saved with a different version of the Unity Editor\."'
    Assert-Has $x '[wait] hook    openStalled/record: exit 0'
    Assert-Has $x '[wait] Hand this to the user. Do not press dialog buttons from a script.'
    Assert-True (Test-ProcAlive $pid1) 'left running'
    Assert-HasNot (Get-StubLog $c) 'button clicked' 'stub log (no dialog button may be clicked)'
    $calls = @(Get-HookCalls $E | Where-Object { $_.Event -eq 'openStalled' })
    Assert-True ($calls.Count -ge 1) 'openStalled hook ran'
    Assert-Equal $calls[-1].Pid $pid1 'openStalled hook pid'
    Assert-Equal $calls[-1].Slot 'MyGame-1' 'openStalled hook slot'
    $d = Invoke-SlotCli $E @('dashboard', '-Json')
    Assert-Exit $d 0
    Assert-HasNot $d $secret 'dashboard'
    $slot = @(($d.Out | ConvertFrom-Json).slots | Where-Object { $_.name -eq 'MyGame-1' })[0]
    Assert-Equal $slot.editor.state 'stalled' 'dashboard editor.state'
    Assert-True (@($slot.flags) -contains 'stalled') 'dashboard flag stalled'
}

Add-Test -Name 'start.acquire-timeout-keeps-lease' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    Set-StubControl $c @{ mode = 'never-ready' } -Reset
    $r = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'hal', '-TimeoutSec', '4')
    Assert-Exit $r 2
    $pid1 = [int](Get-Match $r.Out '^\[acquire\] TIMEOUT: pid (\d+) not ready after 4s; last phase starting the editor, 0 import worker\(s\)\. The editor is left running \(not killed\)\.')
    Assert-True ($pid1 -gt 0) ('TIMEOUT line' + (Format-Excerpt $r))
    Assert-Has $r ('[acquire] windows of pid {0} (look only, nothing is clicked):' -f $pid1)
    Assert-Has $r '[acquire] lease   kept: the editor is running but not ready (exit 2). Hand it to the user.'
    Assert-Equal (Get-Lease $E 'MyGame-1').owner 'hal' 'lease kept'
    Assert-True (Test-ProcAlive $pid1) 'left running'
    Assert-Equal @(Stop-Stubs @($c)).Count 0 'the stub ended by itself'
    $rel = Invoke-SlotCli $E @('release', 'MyGame-1', '-Owner', 'hal')
    Assert-Exit $rel 0
    Assert-Has $rel '[release] RELEASED MyGame-1'
}

# open -TimeoutSec (and acquire -TimeoutSec, new-clone's first open) must bound the wait. The group's
# timeouts.open is 8 s, so the 3 s of the argument show whether it is used (F1, fixed in 0.5.4).
Add-Test -Name 'start.open-timeout-argument' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    Set-StubControl $c @{ mode = 'never-ready' } -Reset
    $r = Invoke-SlotCli $E @('open', 'MyGame-1', '-TimeoutSec', '3')
    Assert-Exit $r 2
    Assert-Like $r '^\[open\] TIMEOUT: pid \d+ not ready after 3s; last phase starting the editor, 0 import worker\(s\)\. The editor is left running \(not killed\)\.'
}

Add-Test -Name 'start.version-not-installed' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-Web']
    $pv = Join-Path $c 'ProjectSettings\ProjectVersion.txt'
    $orig = [IO.File]::ReadAllText($pv)
    try {
        [IO.File]::WriteAllText($pv, ("m_EditorVersion: {0}`n" -f $script:MissingVersion), $script:Utf8)
        $o = Invoke-SlotCli $E @('open', 'MyGame-Web')
        Assert-Exit $o 3
        Assert-Like $o ('^\[open\] STOP: Unity {0} is not installed under the editor roots' -f [regex]::Escape($script:MissingVersion))
        Assert-Like $o ('^\[open\] installed: .*{0}' -f [regex]::Escape($script:StubVersion))
        $a = Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'ivy')
        Assert-Exit $a 3
        Assert-Has $a '[acquire] lease   released: the editor did not start (exit 3)'
        Assert-True ($null -eq (Get-Lease $E 'MyGame-Web')) 'no lease left'
        Assert-True (@(Get-StubProcs $c).Count -eq 0) 'nothing started'
    } finally {
        [IO.File]::WriteAllText($pv, $orig, $script:Utf8)
    }
}

Add-Test -Name 'start.platform-switch-refused' -Group 'start' -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    $n0 = Get-EventCount $E
    $x = Invoke-SlotCli $E @('open', 'MyGame-1', '-BuildTarget', 'WebGL', '-NoWait')
    Assert-Exit $x 4
    Assert-Has $x '[open] REFUSED: this clone opens as Android. -BuildTarget WebGL would switch the platform and reimport everything. Use a WebGL slot or ask the user.'
    Assert-True (@(Get-StubProcs $c).Count -eq 0) 'nothing started'
    Set-StubControl $c @{ mode = 'normal'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-1', '-BuildTarget', 'Android')
    Assert-Exit $o 0
    Assert-Like $o '^\[open\] started pid \d+ at .* -buildTarget Android'
    $sc = Invoke-SlotCli $E @('scan', '-Apply')
    Assert-Exit $sc 0
    Assert-Like $sc 'MyGame-1 .*Android \(window title\)'
    $refused = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'refused' })
    Assert-Equal $refused.Count 1 'refused events'
    Assert-Equal $refused[0].detail.reason 'platform switch' 'refused reason'
    Assert-Equal $refused[0].detail.platform 'Android' 'refused platform'
    Assert-Equal $refused[0].detail.wanted 'WebGL' 'refused wanted'
    Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-1')) 0
}
