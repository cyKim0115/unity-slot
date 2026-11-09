# Phase 2: the improvements of the plan: A1-A4 (0.5.0), B1 (0.5.1), B2 (0.5.4), B6 and B7 (0.5.6), B9-B11 (0.6.1). The wording of MCP
# texts keeps changing, so these tests check key words (tool calls, "warn capacity", annotation keys,
# phase names), not whole sentences. The CLI wording that A1 must not change is checked by the phase 1
# tests, which compare the CLI lines word for word. Dot-sourced by tests\run-tests.ps1. ASCII-only source.

Register-Group 'phase2' -Clones @('MyGame', 'MyGame-1', 'MyGame-2', 'MyGame-Web') -Stray @('Stray')

# Under MCP a next step names the tool to call, never a "unity-slot <command>" line or a CLI flag.
function Assert-NoCliWording($R) {
    Assert-NotLike $R 'unity-slot (open|wait|close|status|slots|summary|scan|set|acquire|release|renew|new-clone|hooks|dashboard)\b' 'MCP text'
    Assert-NotLike $R '(^|\s)-(AnyOwner|AllowDirty|Owner|NoWait|NoOpen|Apply|BuildTarget|Project|From)\b' 'MCP text'
}

Add-Test -Name 'phase2.a1-mcp-next-steps-name-tools' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $web = $E.Clones['MyGame-Web'].Replace('\', '/')
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'normal'; readyMs = '10000' } -Reset
    $S = Start-McpServer $E
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        $outs = New-Object 'System.Collections.Generic.List[object]'
        $a = Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame' }; $outs.Add($a)
        Assert-Equal $a.Code 0 'acquire'
        Assert-Has $a 'wait_ready(slot="MyGame-Web")'
        Assert-Has $a ('Application.dataPath is "{0}/Assets"' -f $web)
        Assert-Has $a 'release(slot="MyGame-Web")'
        $item = Invoke-McpTool $S 'wait_ready' @{ slot = 'MyGame-Web'; timeout_sec = 1 }; $outs.Add($item)
        Assert-Equal $item.Code 6 'wait_ready while starting'
        Assert-Has $item 'wait_ready(slot="MyGame-Web")'
        $w = $null
        for ($i = 0; $i -lt 4; $i++) { $w = Invoke-McpTool $S 'wait_ready' @{ slot = 'MyGame-Web'; timeout_sec = 20 }; if ($w.Code -ne 6) { break } }
        $outs.Add($w)
        Assert-Equal $w.Code 0 'wait_ready'
        Assert-Has $w ('Application.dataPath is "{0}/Assets"' -f $web)
        $x = Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web'; owner = 'other' }; $outs.Add($x)
        Assert-Equal $x.Code 4 'release by another owner'
        $n = Invoke-McpTool $S 'acquire' @{ purpose = 'nosuch'; project = 'mygame'; open = $false }; $outs.Add($n)
        Assert-Has $n 'status()'
        Assert-Has $n 'create(purpose="nosuch", project="mygame")'
        $f = Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame'; owner = 'zed'; open = $false }; $outs.Add($f)
        Assert-Equal $f.Code 5 'acquire of a leased slot'
        Assert-Has $f ('create(purpose="webgl", project="{0}")' -f $script:ProjectKey)
        $p = Invoke-McpTool $S 'create' @{ purpose = 'webgl'; project = 'mygame' }; $outs.Add($p)
        Assert-Has $p 'confirm=true'
        $o = Invoke-McpTool $S 'open' @{ slot = 'MyGame-1' }; $outs.Add($o)
        Assert-Has $o 'wait_ready(slot="MyGame-1")'
        $r = Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web' }; $outs.Add($r)
        Assert-Equal $r.Code 0 'release'
        $c = Invoke-McpTool $S 'close' @{ slot = 'MyGame-1' }; $outs.Add($c)
        Assert-Equal $c.Code 0 'close'
        foreach ($t in $outs) { Assert-NoCliWording $t }
    } finally { [void](Stop-McpServer $S) }
}

Add-Test -Name 'phase2.a2-mcp-call-seconds' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $S = Start-McpServer $E
    $stderr = ''
    $calls = New-Object 'System.Collections.Generic.List[object]'
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        $calls.Add((Invoke-McpTool $S 'status' $null))
        $calls.Add((Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame'; open = $false }))
        $calls.Add((Invoke-McpTool $S 'acquire' @{ purpose = 'nosuch'; project = 'mygame'; open = $false }))
        $calls.Add((Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web'; owner = 'other' }))
        $calls.Add((Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web' }))
    } finally { $stderr = Stop-McpServer $S }
    foreach ($c in $calls) {
        Assert-Like $c.FirstLine '^\[unity-slot exit \d+: .+, \d+\.\ds\]$' 'first line'
        Assert-True ($c.Seconds -gt 0) ('seconds in ' + $c.FirstLine)
    }
    Assert-Equal (($calls | ForEach-Object { $_.Code }) -join ',') '0,0,5,4,0' 'exit codes'
    foreach ($name in @('status', 'acquire', 'release')) { Assert-Like $stderr ('tools/call {0} [0-9.]+s exit \d' -f $name) 'server stderr' }
}

Add-Test -Name 'phase2.a3-tool-annotations' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $want = @{
        status = 'True,,,False'; wait_ready = 'False,False,True,False'; acquire = 'False,False,False,False'; open = 'False,False,True,False'
        close = 'False,True,True,False'; release = 'False,True,True,False'; create = 'False,False,False,True'
    }
    $S = Start-McpServer $E
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        foreach ($t in @((Invoke-Mcp $S 'tools/list').result.tools)) {
            $h = Get-P $t 'annotations'
            Assert-True ($null -ne $h) ($t.name + ' has annotations')
            Assert-True ([string](Get-P $h 'title') -ne '') ($t.name + ' annotations.title')
            $got = '{0},{1},{2},{3}' -f (Get-P $h 'readOnlyHint'), (Get-P $h 'destructiveHint'), (Get-P $h 'idempotentHint'), (Get-P $h 'openWorldHint')
            Assert-Equal $got $want[$t.name] ($t.name + ' readOnly,destructive,idempotent,openWorld')
        }
    } finally { [void](Stop-McpServer $S) }
    # protocol 2024-11-05 came before annotations: the tools come without them
    $S2 = Start-McpServer $E
    try {
        [void](Initialize-Mcp $S2 '2024-11-05' 'old client')
        foreach ($t in @((Invoke-Mcp $S2 'tools/list').result.tools)) { Assert-True ($null -eq (Get-P $t 'annotations')) ($t.name + ' without annotations for 2024-11-05') }
    } finally { [void](Stop-McpServer $S2) }
}

Add-Test -Name 'phase2.a4-status-summary' -Group 'phase2' -Phase 2 -Body {
    param($E)
    Set-StubControl $E.Clones['MyGame-2'] @{ mode = 'never-ready' } -Reset
    Assert-Exit (Invoke-SlotCli $E @('open', 'MyGame-2', '-NoWait')) 0
    Assert-Exit (Invoke-SlotCli $E @('acquire', 'webgl', '-Project', 'mygame', '-Owner', 'sam', '-NoOpen')) 0
    $S = Start-McpServer $E
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        $st = Invoke-McpTool $S 'status' $null
        Assert-Equal $st.Code 0 'status'
        $lines = @(($st.Text -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })
        Assert-True ($lines.Count -le 30) ('status lines: ' + $lines.Count)
        # other groups' stubs run at the same time and count as editors outside this registry (B10)
        Assert-Like $lines[0] '^unity-slot  editors \d+/6( \(\d+ outside the registry\))? \| commit \d+% \([0-9.]+/[0-9.]+GB\)$' 'summary first line'
        Assert-Like $st '^slot\s+platform\s+mode\s+state\s+lease\s+agents$' 'summary header'
        Assert-Like $st '^MyGame\s+Android\s+ondemand\s+closed\s+-\s+no$' 'MyGame row'
        Assert-Like $st '^MyGame-1\s+Android\s+ondemand\s+closed\s+-\s+yes$' 'MyGame-1 row'
        Assert-Like $st '^MyGame-2\s+Android\s+ondemand\s+starting\s+no lease \(in use\?\)\s+yes$' 'MyGame-2 row'
        Assert-Like $st '^MyGame-Web\s+WebGL\s+ondemand\s+closed\s+sam until [0-9-]+ [0-9:]+\s+yes$' 'MyGame-Web row'
        $one = Invoke-McpTool $S 'status' @{ slot = 'MyGame-1' }
        Assert-Like $one '^MyGame-1\s' 'slot filter'
        Assert-NotLike $one '^MyGame-(2|Web)\s' 'slot filter'
        $none = Invoke-McpTool $S 'status' @{ project = 'other-game' }
        Assert-Has $none 'no slot matches'
        $json = Invoke-McpTool $S 'status' @{ format = 'json' }
        $mcpDoc = (($json.Text -split "`n", 2)[1]) | ConvertFrom-Json
    } finally { [void](Stop-McpServer $S) }
    $cli = Invoke-SlotCli $E @('slots', '-Json')
    Assert-Exit $cli 0
    $cliDoc = $cli.Out | ConvertFrom-Json
    Assert-Equal (($mcpDoc.slots | ForEach-Object { $_.name + ':' + $_.state }) -join ',') (($cliDoc.slots | ForEach-Object { $_.name + ':' + $_.state }) -join ',') 'format=json equals slots -Json'
    $sum = Invoke-SlotCli $E @('summary', 'MyGame-Web')
    Assert-Exit $sum 0
    Assert-Like $sum '^MyGame-Web\s+WebGL\s+ondemand\s+closed\s+sam until ' 'CLI summary'
}

# B1 (0.5.1): capacity warnings before an editor starts and at READY. Warnings only: exit codes and
# leases stay. The commit charge is made up with UNITY_SLOT_COMMIT_OVERRIDE. Every editor on the
# machine counts against maxEditors (real ones too), so the config sets it to 99, then to 1.
Add-Test -Name 'phase2.b1-capacity-warnings' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $c1 = $E.Clones['MyGame-1']
    Write-EnvConfig $E $null @{ maxEditors = 99 }
    try {
        Set-StubControl $c1 @{ mode = 'normal'; readyMs = '500' } -Reset
        $hi = Invoke-SlotCli $E @('open', 'MyGame-1') -ExtraEnv @{ UNITY_SLOT_COMMIT_OVERRIDE = '87' }
        Assert-Exit $hi 0
        Assert-Like $hi '^\[open\] warn capacity: commit 87% .*high.*Tell the user before opening more\.$'
        Assert-Like $hi '^\[open\] READY pid \d+'
        Assert-Like $hi '^\[open\] warn capacity: commit 87% .*high.*Tell the user\.$'
        Assert-NotLike $hi 'editors are (already )?open' 'open below maxEditors'
        $d = Invoke-SlotCli $E @('dashboard', '-Json') -ExtraEnv @{ UNITY_SLOT_COMMIT_OVERRIDE = '87' }
        Assert-Exit $d 0
        $doc = $d.Out | ConvertFrom-Json
        Assert-Equal $doc.system.commit.percent 87 'dashboard commit percent'
        Assert-True (@($doc.systemFlags) -contains 'commit-high') 'dashboard flag commit-high (the same mark as the warning)'
        Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-1')) 0

        $cr = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'cap', '-NoWait') -ExtraEnv @{ UNITY_SLOT_COMMIT_OVERRIDE = '95' }
        Assert-Exit $cr 0
        Assert-Like $cr '^\[acquire\] warn capacity: commit 95% .*critical.*Tell the user before opening more\.$'
        $slot = Get-Match $cr.Out '^\[acquire\] ACQUIRED (\S+):'
        Assert-True ($null -ne (Get-Lease $E $slot)) 'a warning does not stop the lease'
        Assert-Exit (Invoke-SlotCli $E @('release', $slot, '-Owner', 'cap')) 0

        $lo = Invoke-SlotCli $E @('open', 'MyGame-1', '-NoWait') -ExtraEnv @{ UNITY_SLOT_COMMIT_OVERRIDE = '50' }
        Assert-Exit $lo 0
        Assert-NotLike $lo 'warn capacity' 'open below the marks'
        # MyGame-1 is open now, so with maxEditors 1 the next open warns about the editor count
        Write-EnvConfig $E $null @{ maxEditors = 1 }
        Set-StubControl $E.Clones['MyGame-2'] @{ mode = 'normal'; readyMs = '500' } -Reset
        $mx = Invoke-SlotCli $E @('open', 'MyGame-2', '-NoWait') -ExtraEnv @{ UNITY_SLOT_COMMIT_OVERRIDE = '50' }
        Assert-Exit $mx 0
        Assert-Like $mx '^\[open\] warn capacity: .*maxEditors 1.*Tell the user before opening more\.$'
    } finally {
        Write-EnvConfig $E $null $null
    }
}

# B2 (0.5.4): the STARTING, STALLED? and TIMEOUT lines name the last startup phase in Editor.log and the
# live import workers. The stub writes Unity's phase lines up to script compilation (step 12 of 40).
Add-Test -Name 'phase2.b2-starting-progress' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $c = $E.Clones['MyGame-1']
    $phase = 'phase asset refresh: compiling scripts \(30%\), 1 import worker\(s\)'
    Set-StubControl $c @{ mode = 'never-ready'; workers = '1'; phases = 'engine,packages,compile' } -Reset
    try {
        Assert-Exit (Invoke-SlotCli $E @('open', 'MyGame-1', '-NoWait')) 0
        $s1 = Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '1')
        Assert-Exit $s1 6
        Assert-Like $s1 ('STARTING: .*; {0}\. Call wait again\.' -f $phase)
        $S = Start-McpServer $E
        try {
            [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
            $m = Invoke-McpTool $S 'wait_ready' @{ slot = 'MyGame-1'; timeout_sec = 1 }
            Assert-Equal $m.Code 6 'wait_ready while starting'
            Assert-Like $m ('STARTING: .*; {0}\. .*wait_ready\(slot="MyGame-1"\)' -f $phase)
        } finally { [void](Stop-McpServer $S) }
        Write-EnvConfig $E @{ stalled = 5 } $null
        $x = Invoke-SlotCli $E @('wait', 'MyGame-1', '-TimeoutSec', '3')
        Assert-Exit $x 2
        Assert-Like $x ('STALLED\?: .*; last {0}\. Left running\.' -f $phase)
        Assert-Equal @(Stop-Stubs @($c)).Count 0 'the stub ended by itself'
        $t = Invoke-SlotCli $E @('open', 'MyGame-1', '-TimeoutSec', '3')
        Assert-Exit $t 2
        Assert-Like $t ('TIMEOUT: pid \d+ not ready after 3s; last {0}\. The editor is left running' -f $phase)
    } finally {
        Write-EnvConfig $E $null $null
    }
}

# B6 (0.5.6): acquire and READY print a "pin" line with the MCP for Unity instance id: the project folder
# and the first 8 hex digits of the SHA-1 of Application.dataPath (UTF-8, "/", ending /Assets, upper-case
# drive letter). A status file of the plugin whose project_path is the clone gives the id instead.
function Get-ExpectedInstanceId([string]$Clone) {
    $root = $Clone.TrimEnd('\')
    $root = $root.Substring(0, 1).ToUpperInvariant() + $root.Substring(1)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.Replace('\', '/') + '/Assets'))[0..3] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    return ('{0}@{1}' -f (Split-Path $root -Leaf), $hex)
}

Add-Test -Name 'phase2.b6-pin-line' -Group 'phase2' -Phase 2 -Body {
    param($E)
    # the hash on a fixed path (SHA-1 of "C:/Projects/MyGame/Assets", worked out separately)
    Assert-Equal (Get-ExpectedInstanceId 'c:\Projects\MyGame') 'MyGame@90629475' 'instance id of a fixed path'
    $c1 = $E.Clones['MyGame-1']
    [void](Stop-Stubs @($c1))
    $a = Invoke-SlotCli $E @('acquire', 'agent', '-Project', 'mygame', '-Owner', 'pin', '-NoOpen')
    Assert-Exit $a 0
    $slot = Get-Match $a.Out '^\[acquire\] ACQUIRED (\S+):'
    Assert-Has $a ('[acquire] pin     MCP for Unity instance {0}: pin it with set_active_instance before the first Unity call' -f (Get-ExpectedInstanceId $E.Clones[$slot]))
    Assert-Exit (Invoke-SlotCli $E @('release', $slot, '-Owner', 'pin')) 0
    $S = Start-McpServer $E
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        $m = Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame'; open = $false }
        Assert-Equal $m.Code 0 'MCP acquire'
        Assert-Has $m ('set_active_instance(instance="{0}")' -f (Get-ExpectedInstanceId $E.Clones['MyGame-Web']))
        Assert-NoCliWording $m
        Assert-Equal (Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web' }).Code 0 'MCP release'
    } finally { [void](Stop-McpServer $S) }
    Set-StubControl $c1 @{ mode = 'normal'; readyMs = '500' } -Reset
    $o = Invoke-SlotCli $E @('open', 'MyGame-1')
    Assert-Exit $o 0
    Assert-Has $o ('[open] pin     MCP for Unity instance {0}: pin it with set_active_instance before the first Unity call' -f (Get-ExpectedInstanceId $c1))
    # a status file of MCP for Unity for this clone (its path in another case) gives the name and hash
    $dir = Join-Path $E.Dir 'unity-mcp'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $status = [ordered]@{ unity_port = 6401; project_name = 'MyGame-1'; project_path = ($c1.Replace('\', '/') + '/Assets').ToLowerInvariant(); last_heartbeat = '2026-11-09T00:00:00Z' }
    [IO.File]::WriteAllText((Join-Path $dir 'unity-mcp-status-0badc0de.json'), ($status | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    try {
        $w = Invoke-SlotCli $E @('wait', 'MyGame-1')
        Assert-Exit $w 0
        Assert-Has $w '[wait] pin     MCP for Unity instance MyGame-1@0badc0de: pin it with set_active_instance before the first Unity call'
    } finally {
        Remove-Item -LiteralPath (Join-Path $dir 'unity-mcp-status-0badc0de.json') -Force
        Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-1')) 0
    }
}

# B7 (0.5.6): a log tail (NOT RUNNING, EXITED, STALLED, TIMEOUT) leaves out ##utp lines and cuts long lines
# at 300 characters, after masking.
Add-Test -Name 'phase2.b7-log-tail' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $c = $E.Clones['MyGame']
    [void](Stop-Stubs @($c))
    $secret = 'SECRET-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $logDir = Join-Path $c 'Logs'
    [void](New-Item -ItemType Directory -Path $logDir -Force)
    $lines = @('first line', ('##utp:{"type":"MemoryLeaks","version":2,"allocatedMemory":"' + ('x' * 2500) + '"}'),
        ('long ' + ('y' * 1000)), '-accessToken', $secret, 'last line')
    [IO.File]::WriteAllText((Join-Path $logDir 'Editor.log'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $nr = Invoke-SlotCli $E @('wait', 'MyGame')
    Assert-Exit $nr 1
    Assert-Has $nr '[wait] last log lines:'
    Assert-Has $nr '[wait]   first line'
    Assert-HasNot $nr '##utp' 'log tail (##utp lines are left out)'
    Assert-Like $nr ('^\[wait\]   long y{295} \.\.\.$')
    Assert-Has $nr '[wait]   ***'
    Assert-HasNot $nr $secret 'log tail (the value after -accessToken is masked before lines are cut)'
    Assert-Has $nr '[wait]   last line'
    $longest = (@($nr.Out -split "`r?`n") | Measure-Object -Property Length -Maximum).Maximum
    Assert-True ($longest -le 320) ('longest output line {0} characters' -f $longest)
}

# B9 (0.6.1): the pending afterFirstOpen hooks of a READY print one line when they succeed, and
# wait_ready is no longer read-only (those hooks may write into the clone; see phase2.a3).
Add-Test -Name 'phase2.b9-pending-hooks-brief' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $c = $E.Clones['MyGame-2']
    [void](Stop-Stubs @($c))
    $hook = Join-Path $E.Dir 'five-lines.ps1'
    Write-TextFile $hook "1..5 | ForEach-Object { 'line ' + `$_ }`n"
    Write-EnvConfig $E $null @{ hooks = [ordered]@{ afterFirstOpen = @([ordered]@{ name = 'five'; run = @($hook) }) } }
    try {
        $regFile = Join-Path $E.Home 'slots.json'
        $reg = [IO.File]::ReadAllText($regFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($s in @($reg.slots)) { if ($s.name -eq 'MyGame-2') { $s | Add-Member -NotePropertyName pendingHooks -NotePropertyValue @('afterFirstOpen') -Force } }
        Write-TextFile $regFile ($reg | ConvertTo-Json -Depth 10)
        Set-StubControl $c @{ mode = 'normal'; readyMs = '500' } -Reset
        $o = Invoke-SlotCli $E @('open', 'MyGame-2')
        Assert-Exit $o 0
        Assert-Has $o '[open] hook    afterFirstOpen/five: exit 0 (5 output line(s), last: line 5)'
        Assert-HasNot $o 'line 1' 'READY output (a successful pending hook shows one line)'
        Assert-NotLike $o 'five-lines\.ps1' 'READY output (no hook command line when it succeeds)'
        Assert-Exit (Invoke-SlotCli $E @('close', 'MyGame-2')) 0
    } finally {
        Write-EnvConfig $E $null $null
    }
}

# B10 (0.6.1): the summary's editor count names the editors of no registered slot.
Add-Test -Name 'phase2.b10-editors-outside-registry' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $s = $E.Stray['Stray']
    [void](Start-StubDirect $s @())
    try {
        Wait-Until { (Get-LockStateH $s) -eq 'held' } 15 'the stray stub'
        $o = Invoke-SlotCli $E @('summary')
        Assert-Exit $o 0
        # at least this stray stub; stubs of the groups running in parallel are outside this registry too
        $n = [int](Get-Match $o.Out '^unity-slot  editors \d+/6 \((\d+) outside the registry\) \| commit \d+% ')
        Assert-True ($n -ge 1) ('editors outside the registry: ' + $n)
    } finally { [void](Stop-Stubs @($s)) }
}

# B11 (0.6.1): the scene-beacon hook finds a writer script recorded with the full path of the folder
# the clone had before it was renamed (a [CallerFilePath] value) under this clone's Assets.
Add-Test -Name 'phase2.b11-beacon-writer-renamed-clone' -Group 'phase2' -Phase 2 -Body {
    param($E)
    $clone = Join-Path $E.Dir 'beacon-clone'
    [void](New-Item -ItemType Directory -Path (Join-Path $clone 'Assets\Editor'), (Join-Path $clone 'Temp') -Force)
    $writer = Join-Path $clone 'Assets\Editor\Beacon.cs'
    Write-TextFile $writer "// writer`n"
    $beacon = [ordered]@{ Pid = 0; ScriptPath = 'C:/old/MyGame-GPT/Assets/Editor/Beacon.cs'; IsPlaying = $false
        Scenes = @([ordered]@{ Path = 'Assets/Main.unity'; IsDirty = $true }) }
    Write-TextFile (Join-Path $clone 'Temp\B.json') ($beacon | ConvertTo-Json -Depth 5)
    $hookPath = Join-Path $script:RepoRoot 'examples\hooks\scene-beacon.ps1'
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath -Clone $clone -EditorPid 0 -Beacon 'Temp\B.json' 2>&1 | Out-String)
    Assert-Equal $LASTEXITCODE 4 'hook exit (the writer is found in this clone, so the dirty scene refuses)'
    Assert-True ($out -match 'unsaved: Assets/Main\.unity') ('hook output: ' + $out.Trim())
    Remove-Item -LiteralPath $writer -Force
    $out2 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath -Clone $clone -EditorPid 0 -Beacon 'Temp\B.json' 2>&1 | Out-String)
    Assert-Equal $LASTEXITCODE 0 'hook exit (no writer anywhere)'
    Assert-True ($out2 -match 'beacon writer script is gone') ('hook output: ' + $out2.Trim())
}
