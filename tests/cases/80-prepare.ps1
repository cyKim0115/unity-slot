# prepare: a base clone from the origin, its first open, agent clones opened once and closed; the dry
# run, refusals, a second run with nothing to do, and a run that finishes what an earlier one left.
# Dot-sourced by tests\run-tests.ps1. ASCII-only source.
#
# The group starts with one WebGL clone (MyGame-Web, an agent slot of another platform): prepare must not
# take it as the base and must not count it. The tests run in order and build on each other.

Register-Group 'prepare' -Clones @('MyGame-Web')

function Get-PrepareSlots($E) {
    $by = @{}
    foreach ($item in @((Get-EnvSlotsJson $E).slots)) { $by[[string]$item.name] = $item }
    return $by
}

function Get-PrepareClone($E, [string]$Name) { return (Join-Path $E.ClonesDir $Name) }

# Stubs of this group's clones only (other groups run at the same time with the same stub).
function Get-PrepareStubCount($E) {
    return @(Get-StubProcs | Where-Object { Test-UnderPath (Get-ProjectArg ([string]$_.CommandLine)) $E.ClonesDir }).Count
}

# Clones prepare made join the environment, so the reset after each test ends their stubs too.
function Add-PrepareClones($E) {
    foreach ($n in @('mygame', 'mygame-1', 'mygame-2', 'mygame-3')) {
        $p = Get-PrepareClone $E $n
        if ((Test-Path -LiteralPath $p) -and -not $E.Clones.ContainsKey($n)) { $E.Clones[$n] = $p }
    }
}

Add-Test -Name 'prepare.dry-run-and-checks' -Group 'prepare' -Body {
    param($E)
    $origin = Get-OriginPath
    $base = Get-PrepareClone $E 'mygame'

    $d = Invoke-SlotCli $E @('prepare', $origin, '-BuildTarget', 'Android')
    Assert-Exit $d 0
    Assert-Has $d ('[prepare] project {0}' -f $script:ProjectKey)
    Assert-Has $d ('[prepare] base    {0} (to clone from {1})' -f $base, $origin)
    Assert-Has $d '[prepare] platform Android (-BuildTarget, first open)'
    Assert-Has $d '[prepare] agents  0 of 2 agent slot(s) of this platform'
    Assert-Has $d ('[prepare]   1. git clone {0} "{1}"' -f $origin, $base)
    Assert-Like $d '\[prepare\]   3\. first open of the base with -BuildTarget Android'
    Assert-Like $d '\[prepare\]   4\. new-clone agent -From mygame, 2 time\(s\)'
    Assert-Like $d '^\[prepare\] dry-run: nothing was done\.'
    Assert-True (-not (Test-Path -LiteralPath $base)) 'the dry run cloned nothing'

    # no Library and no -BuildTarget: the platform is unknown
    $u = Invoke-SlotCli $E @('prepare', $origin)
    Assert-Exit $u 4
    Assert-Has $u '[prepare] STOP    the platform is unknown (the base has no Library yet): pass -BuildTarget <platform>, for example Android, WebGL or Windows'

    # an agent slot of the project (another platform) is not the base, and a project name alone cannot clone
    $p = Invoke-SlotCli $E @('prepare', 'nosuchgame')
    Assert-Exit $p 1
    Assert-Like $p 'no slot of "nosuchgame" is registered and it is no clone folder\. Pass the origin URL'
    $n = Invoke-SlotCli $E @('prepare', $origin, '-BuildTarget', 'Android', '-Name', 'mygame-7')
    Assert-Exit $n 1
    Assert-Has $n 'prepare names its clones itself (<repo>-<number>); leave -Name out'
    Assert-Equal (@((Get-PrepareSlots $E).Keys).Count) 1 'still only MyGame-Web registered'
}

Add-Test -Name 'prepare.apply-base-and-two-agents' -Group 'prepare' -Body {
    param($E)
    $origin = Get-OriginPath
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('prepare', $origin, '-BuildTarget', 'Android', '-Apply') 240
    Add-PrepareClones $E
    Assert-Exit $r 0
    Assert-Has $r ('[prepare] apply   1 git clone into {0}' -f (Get-PrepareClone $E 'mygame'))
    Assert-Has $r '[prepare]         slot mygame: Android, purposes main, agent use false'
    Assert-Has $r '[prepare] apply   3 first open of mygame'
    Assert-Like $r 'started pid \d+ .* -buildTarget Android'
    Assert-Has $r '[prepare] apply   4 agent clone 1 of 2'
    Assert-Has $r '[prepare] apply   4 agent clone 2 of 2'
    Assert-Has $r ('[prepare] DONE    {0}: base mygame, 2 agent slot(s) of Android: mygame-1, mygame-2' -f $script:ProjectKey)

    $by = Get-PrepareSlots $E
    Assert-Equal (@($by.Keys).Count) 4 'slots: MyGame-Web, mygame, mygame-1, mygame-2'
    Assert-Equal (@($by['mygame'].purposes) -join ',') 'main' 'base purposes'
    Assert-True (-not $by['mygame'].agentUse) 'the base is not for agents'
    Assert-Equal $by['mygame'].platform 'Android' 'base platform after its first open'
    foreach ($a in @('mygame-1', 'mygame-2')) {
        Assert-Equal (@($by[$a].purposes) -join ',') 'agent' ($a + ' purposes')
        Assert-True ([bool]$by[$a].agentUse) ($a + ' agent use')
        Assert-Equal $by[$a].platform 'Android' ($a + ' platform')
        Assert-Equal $by[$a].mode 'ondemand' ($a + ' mode')
        Assert-Equal $by[$a].state 'closed' ($a + ' closed after its first open')
        Assert-True ($null -eq $by[$a].lease) ($a + ' no lease')
        Assert-True (Test-Path -LiteralPath (Join-Path $by[$a].path 'Library\EditorUserBuildSettings.asset')) ($a + ' Library copied')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $by[$a].path 'Logs\unity-slot-prepare.txt'))) ($a + ' marker removed')
    }
    Assert-Equal $by['mygame'].state 'closed' 'base closed after its first open'
    Assert-Equal $by['MyGame-Web'].state 'closed' 'MyGame-Web untouched'
    Assert-Equal (Get-PrepareStubCount $E) 0 'no editor left open'
    $opens = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'open' })
    $closes = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'close' })
    Assert-Equal $opens.Count 3 'open events (base and two agent clones)'
    Assert-Equal $closes.Count 3 'close events'

    # agents can take them now
    $a = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'gpt', '-NoOpen')
    Assert-Exit $a 0
    Assert-Like $a '^\[acquire\] ACQUIRED mygame-[12]: closed \(-NoOpen\)'
}

Add-Test -Name 'prepare.second-run-and-resume' -Group 'prepare' -Body {
    param($E)
    Add-PrepareClones $E
    # everything is there: by slot name, by URL (finds the main slot), nothing to do
    $s = Invoke-SlotCli $E @('prepare', 'mygame')
    Assert-Exit $s 0
    Assert-Has $s '[prepare]   1. (done) base clone'
    Assert-Has $s '[prepare]   2. (done) registered as mygame (main, agent use false)'
    Assert-Has $s '[prepare]   3. (done) the base has a Library'
    Assert-Has $s '[prepare]   4. (done) 2 agent slot(s)'
    $u = Invoke-SlotCli $E @('prepare', (Get-OriginPath), '-Apply')
    Assert-Exit $u 0
    Assert-Has $u '[prepare] note    my-org/mygame has a main slot already, mygame; using that clone as the base'
    Assert-HasNot $u 'apply   ' 'nothing to apply'
    Assert-Has $u ('[prepare] DONE    {0}: base mygame, 2 agent slot(s) of Android: mygame-1, mygame-2' -f $script:ProjectKey)

    # -BuildTarget of another platform never switches the base
    $w = Invoke-SlotCli $E @('prepare', 'mygame', '-BuildTarget', 'WebGL')
    Assert-Exit $w 4
    Assert-Like $w 'STOP    the base opens as Android; -BuildTarget WebGL would switch its platform'

    # an editor prepare started and lost (the shell was cut off): the next run waits for it and closes it
    $c2 = Get-PrepareClone $E 'mygame-2'
    $o = Invoke-SlotCli $E @('open', 'mygame-2', '-NoWait')
    Assert-Exit $o 0
    $pid2 = [int](Get-Match $o.Out '\[open\] started pid (\d+)')
    [IO.File]::WriteAllText((Join-Path $c2 'Logs\unity-slot-prepare.txt'), ('pid={0} started=test' -f $pid2))
    $f = Invoke-SlotCli $E @('prepare', 'mygame')
    Assert-Exit $f 0
    Assert-Has $f '[prepare]   4. finish mygame-2: prepare made it; its first open and close are not done yet'
    $g = Invoke-SlotCli $E @('prepare', 'mygame', '-Apply')
    Assert-Exit $g 0
    Assert-Has $g '[prepare] apply   4 finish mygame-2'
    Assert-Has $g ('[prepare]         mygame-2: the editor prepare started before (pid {0}) is still there; waiting for it' -f $pid2)
    Assert-True (-not (Test-ProcAlive $pid2)) 'closed by the second run'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $c2 'Logs\unity-slot-prepare.txt'))) 'marker removed'

    # an editor someone else opened is theirs: no new clone while the base is open, nothing closed
    $b = Invoke-SlotCli $E @('open', 'mygame', '-NoWait')
    Assert-Exit $b 0
    $pidB = [int](Get-Match $b.Out '\[open\] started pid (\d+)')
    $x = Invoke-SlotCli $E @('prepare', 'mygame', '-Count', '3', '-Apply')
    Assert-Exit $x 4
    Assert-Like $x 'STOP    the base .* is open \(pid \d+\) and prepare did not start it\. New clones copy its Library only while it is closed: close it first\.'
    Assert-True (Test-ProcAlive $pidB) 'the base editor is left open'
    Assert-True (-not (Test-Path -LiteralPath (Get-PrepareClone $E 'mygame-3'))) 'no third clone'

    # -NoOpen: a third clone without its first open; a later run without -NoOpen finishes it
    $cl = Invoke-SlotCli $E @('close', 'mygame')
    Assert-Exit $cl 0
    $y = Invoke-SlotCli $E @('prepare', 'mygame', '-Count', '3', '-NoOpen', '-Apply') 120
    Add-PrepareClones $E
    Assert-Exit $y 0
    Assert-Has $y ('[prepare] DONE    {0}: base mygame, 3 agent slot(s) of Android: mygame-1, mygame-2, mygame-3' -f $script:ProjectKey)
    Assert-True (Test-Path -LiteralPath (Join-Path (Get-PrepareClone $E 'mygame-3') 'Logs\unity-slot-prepare.txt')) 'marked: first open not done'
    Assert-Equal (Get-PrepareStubCount $E) 0 'nothing opened with -NoOpen'
    $z = Invoke-SlotCli $E @('prepare', 'mygame', '-Count', '3', '-Apply') 120
    Assert-Exit $z 0
    Assert-Has $z '[prepare] apply   4 finish mygame-3'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-PrepareClone $E 'mygame-3') 'Logs\unity-slot-prepare.txt'))) 'mygame-3 finished'
    Assert-Equal (Get-PrepareStubCount $E) 0 'closed again'
}
