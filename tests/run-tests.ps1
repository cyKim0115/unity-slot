<#
.SYNOPSIS
Regression and failure tests for unity-slot with a fake Unity.exe: no real editor, no real registry.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
      [-Phase all|1|2] [-Only <regex on test names>] [-Root <folder>] [-Parallel 3] [-KeepRoot] [-List]

Builds tests\stub\UnityStub.cs into <root>\editors\9999.0.0f1\Editor\Unity.exe, makes a local bare origin
and fake clones (MyGame, MyGame-1, MyGame-2, MyGame-Web), and runs unity-slot.ps1 and the MCP server with
the UNITY_SLOT_HOME and UNITY_SLOT_CONFIG of each test group (<root>\envs\<group>). Groups run in parallel
processes, the tests of a group one after another. Prints PASS / FAIL / KNOWN / SKIP per test with its
time. KNOWN = a failure listed in tests\FINDINGS.md.

At the end it checks that no stub is left running and that the real state files
(%USERPROFILE%\.unity-slot\slots.json and install.json) did not change. The test folder (default
%TEMP%\unity-slot-tests\<time>) is deleted when everything passed; otherwise it stays for the logs
(<root>\envs\<group>\cli.log has every unity-slot run, <root>\logs\<group>.out the group's output).

Exit 0 = no FAIL. Never kills a process: a stub that does not end is reported and left running; it ends
by itself after 10 minutes. ASCII-only source.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', '1', '2')]
    [string]$Phase = 'all',
    [string]$Only = '',
    [string]$Root = '',
    [int]$Parallel = 3,
    [switch]$KeepRoot,
    [switch]$List,
    # internal: run one group in this process (the main run starts these)
    [string]$Worker = '',
    [string]$ResultFile = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\harness.ps1')
. (Join-Path $PSScriptRoot 'lib\mcp-client.ps1')
foreach ($caseFile in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.ps1' | Sort-Object Name)) { . $caseFile.FullName }

function Get-SelectedTests([string]$Group = '') {
    @($script:Tests | Where-Object {
            ($Phase -eq 'all' -or [string]$_.Phase -eq $Phase) -and
            (-not $Only -or $_.Name -match $Only) -and
            (-not $Group -or $_.Group -eq $Group)
        })
}

function Format-ErrorText($Err) {
    $msg = $Err.Exception.Message
    if ($msg.StartsWith('ASSERT ')) { return $msg.Substring(7) }
    $where = ''
    if ($null -ne $Err.InvocationInfo -and $Err.InvocationInfo.ScriptName) {
        $where = (' ({0}:{1})' -f (Split-Path -Leaf $Err.InvocationInfo.ScriptName), $Err.InvocationInfo.ScriptLineNumber)
    }
    return ('error: ' + $msg + $where)
}

function New-Result($Test, [string]$Status, [double]$Seconds, [string]$Message) {
    return [pscustomobject][ordered]@{
        name = $Test.Name; group = $Test.Group; phase = $Test.Phase; status = $Status
        seconds = [math]::Round($Seconds, 1); message = $Message
    }
}

# Runs the selected tests of one group in this process, each followed by a reset of the environment.
function Invoke-GroupTests([string]$Group) {
    $spec = $script:Groups[$Group]
    $results = New-Object 'System.Collections.Generic.List[object]'
    $tests = @(Get-SelectedTests $Group)
    if ($tests.Count -eq 0) { return $results.ToArray() }
    $E = $null
    if (@($spec.Clones).Count -gt 0) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $E = New-TestEnv $Group $spec.Clones $spec.Timeouts $spec.Stray
        } catch {
            $why = Format-ErrorText $_
            foreach ($t in $tests) { $results.Add((New-Result $t 'FAIL' 0 ('environment setup failed: ' + $why))) }
            return $results.ToArray()
        }
        Write-Host ('[{0}] environment ready in {1:0.0}s' -f $Group, $sw.Elapsed.TotalSeconds)
    }
    foreach ($t in $tests) {
        if ($t.Skip) { $results.Add((New-Result $t 'SKIP' 0 $t.Skip)); continue }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $status = 'PASS'
        $msg = ''
        try {
            [void](& $t.Body $E)
        } catch {
            $status = 'FAIL'
            $msg = Format-ErrorText $_
        } finally {
            if ($null -ne $E) {
                $left = @()
                try { $left = @(Reset-TestEnv $E) } catch { $left = @(); if ($status -eq 'PASS') { $status = 'FAIL'; $msg = 'reset failed: ' + (Format-ErrorText $_) } }
                if ($left.Count -gt 0) {
                    $note = ('stub pid(s) {0} did not end after the test; left running' -f ($left -join ', '))
                    if ($status -eq 'PASS') { $status = 'FAIL'; $msg = $note } else { $msg += ' | ' + $note }
                }
            }
        }
        if ($status -eq 'FAIL' -and $t.Known) { $status = 'KNOWN'; $msg = $t.Known + ': ' + $msg }
        elseif ($status -eq 'PASS' -and $t.Known) { $msg = ('{0} passes now: remove -Known and move {0} to the solved list in tests\FINDINGS.md' -f $t.Known) }
        $sw.Stop()
        $results.Add((New-Result $t $status $sw.Elapsed.TotalSeconds $msg))
        if ($Worker) { Write-Host ('[{0}] {1,-5} {2} {3:0.0}s' -f $Group, $status, $t.Name, $sw.Elapsed.TotalSeconds) }
    }
    return $results.ToArray()
}

function Write-ResultLine($R) {
    $line = '{0,-5} {1,-46} {2,6:0.0}s' -f $R.status, $R.name, [double]$R.seconds
    Write-Host $line
    if ($R.message) {
        $msgLines = @(([string]$R.message) -split "`r?`n")
        # a FAIL shows everything; KNOWN, SKIP and notes on a PASS show their first line
        if ($R.status -ne 'FAIL') { $msgLines = @($msgLines | Select-Object -First 1) }
        foreach ($l in $msgLines) { Write-Host ('      ' + $l) }
    }
}

# ------------------------------------------------------------------ worker mode

if ($Worker) {
    $exitCode = 0
    try {
        Initialize-HarnessRoot $Root
        $res = @(Invoke-GroupTests $Worker)
        [IO.File]::WriteAllText($ResultFile, (ConvertTo-Json -InputObject @($res) -Depth 4), $script:Utf8)
    } catch {
        Write-Host ('worker error: ' + (Format-ErrorText $_))
        $exitCode = 1
    }
    exit $exitCode
}

# ------------------------------------------------------------------ main

$total = [Diagnostics.Stopwatch]::StartNew()
$core = Get-CoreVersion
if ($List) {
    foreach ($t in @(Get-SelectedTests)) {
        $note = ''
        if ($t.Skip) { $note = ' (skip: ' + $t.Skip + ')' }
        Write-Host ('{0,-8} phase {1}  {2}{3}' -f $t.Group, $t.Phase, $t.Name, $note)
    }
    exit 0
}
if (-not $Root) {
    $Root = Join-Path ([IO.Path]::GetTempPath()) ('unity-slot-tests\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
}
$Root = Get-NormPathH $Root
$realHome = Join-Path $env:USERPROFILE '.unity-slot'
if ((Test-SamePathH $Root $realHome) -or (Test-UnderPath $Root $realHome) -or (Test-UnderPath $realHome $Root)) {
    Write-Host ('STOP: the test folder must not be or contain the real state folder ({0})' -f $realHome); exit 1
}
if ((Test-PackagedProcess) -and ((Test-UnderPath $Root $env:LOCALAPPDATA) -or (Test-UnderPath $Root $env:APPDATA))) {
    Write-Host ('STOP: this shell runs inside an app package, so its writes under AppData are redirected and a stub')
    Write-Host ('      started through WMI would not see them. Pass -Root with a folder outside AppData.')
    exit 1
}
if ((Test-Path -LiteralPath $Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -gt 0) {
    Write-Host ('STOP: the test folder is not empty: ' + $Root); exit 1
}
Initialize-HarnessRoot $Root
$realBefore = @(Get-RealState)
Write-Host ('unity-slot tests: core {0} ({1}), phase {2}, root {3}' -f $core, $script:RepoRoot, $Phase, $Root)

$allResults = New-Object 'System.Collections.Generic.List[object]'
$failedSetup = $false

# groups without an environment run here first
foreach ($g in @($script:Groups.Keys)) {
    if (@($script:Groups[$g].Clones).Count -gt 0) { continue }
    foreach ($r in @(Invoke-GroupTests $g)) { $allResults.Add($r); Write-ResultLine $r }
}

$envGroups = @($script:Groups.Keys | Where-Object { @($script:Groups[$_].Clones).Count -gt 0 -and @(Get-SelectedTests $_).Count -gt 0 })
if ($envGroups.Count -gt 0) {
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Build-Stub
        New-FakeOrigin
        Write-Host ('setup  stub Unity.exe {0} and fake origin in {1:0.0}s' -f $script:StubVersion, $sw.Elapsed.TotalSeconds)
    } catch {
        Write-Host ('FAIL  setup: ' + (Format-ErrorText $_))
        $failedSetup = $true
        $envGroups = @()
    }
}

# one worker process per group, at most $Parallel at a time
$queue = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($g in $envGroups) { $queue.Enqueue($g) }
$running = New-Object 'System.Collections.Generic.List[object]'
$logDir = Join-Path $Root 'logs'
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt [Math]::Max(1, $Parallel)) {
        $g = $queue.Dequeue()
        $resultFile = Join-Path $logDir ($g + '.json')
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CmdArg $PSCommandPath) +
            ' -Worker ' + $g + ' -Root ' + (ConvertTo-CmdArg $Root) + ' -ResultFile ' + (ConvertTo-CmdArg $resultFile) + ' -Phase ' + $Phase
        if ($Only) { $argLine += ' -Only ' + (ConvertTo-CmdArg $Only) }
        $p = Start-Child $script:PowerShellExe $argLine $null
        $p.StandardInput.Close()
        Write-Host ('group  {0} started ({1} test(s))' -f $g, @(Get-SelectedTests $g).Count)
        $running.Add([pscustomobject]@{ Group = $g; Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); ResultFile = $resultFile })
    }
    Start-Sleep -Milliseconds 300
    foreach ($w in @($running.ToArray())) {
        if (-not $w.Proc.HasExited) { continue }
        $w.Proc.WaitForExit()
        [void]$running.Remove($w)
        $out = $w.Out.Result + $w.Err.Result
        [IO.File]::WriteAllText((Join-Path $logDir ($w.Group + '.out')), $out, $script:Utf8)
        $res = @()
        if (Test-Path -LiteralPath $w.ResultFile) {
            # ConvertFrom-Json in PowerShell 5.1 returns a JSON array as one object: unroll it
            $parsed = [IO.File]::ReadAllText($w.ResultFile, $script:Utf8) | ConvertFrom-Json
            $res = @($parsed | ForEach-Object { $_ })
        }
        if ($res.Count -eq 0) {
            $r = [pscustomobject]@{ name = ('group ' + $w.Group); group = $w.Group; phase = 0; status = 'FAIL'; seconds = 0
                message = ('the group process ended without results (exit {0}):{1}' -f $w.Proc.ExitCode, (Format-Excerpt $out 15)) }
            $res = @($r)
        }
        Write-Host ('-- {0}' -f $w.Group)
        foreach ($r in $res) { $allResults.Add($r); Write-ResultLine $r }
    }
}

# nothing may be left running, and the real state must be as it was
$left = @(Stop-Stubs @() 20)
$stubLine = 'PASS  no stub process left'
if ($left.Count -gt 0) { $stubLine = ('FAIL  stub pid(s) {0} still running; left running (they end by themselves within 10 minutes)' -f ($left -join ', ')) }
Write-Host $stubLine
$realChanges = @(Get-RealStateChanges $realBefore @(Get-RealState))
$changed = @($realChanges | Where-Object { $_.Leak })
if ($realChanges.Count -eq 0) { Write-Host 'PASS  real state unchanged (%USERPROFILE%\.unity-slot\slots.json, install.json)' }
foreach ($c in $realChanges) {
    if ($c.Leak) { Write-Host ('FAIL  real {0} was written by this run: {1}' -f $c.Name, $c.Note) }
    else { Write-Host ('WARN  real {0} changed during the run, not by this run: {1}' -f $c.Name, $c.Note) }
}

$count = @{ PASS = 0; FAIL = 0; KNOWN = 0; SKIP = 0 }
foreach ($r in $allResults) { $count[[string]$r.status]++ }
$failed = $count.FAIL + [int]($left.Count -gt 0) + [int]($changed.Count -gt 0) + [int]$failedSetup
Write-Host ('result {0} passed, {1} failed, {2} known, {3} skipped in {4:0.0}s' -f $count.PASS, $count.FAIL, $count.KNOWN, $count.SKIP, $total.Elapsed.TotalSeconds)
if ($failed -eq 0 -and -not $KeepRoot -and $left.Count -eq 0) {
    try { Remove-Item -LiteralPath $Root -Recurse -Force; Write-Host 'cleanup test folder removed' }
    catch { Write-Host ('cleanup could not remove {0}: {1}' -f $Root, $_.Exception.Message) }
} else {
    Write-Host ('kept   ' + $Root)
}
if ($failed -gt 0) { exit 1 }
exit 0
