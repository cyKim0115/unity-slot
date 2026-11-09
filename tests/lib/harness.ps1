# Shared code of the unity-slot test harness: the test folder, fake clones, the stub Unity.exe,
# unity-slot.ps1 in child processes, and checks. Dot-sourced by tests\run-tests.ps1.
# ASCII-only source (Windows PowerShell 5.1 reads BOM-less files with the ANSI code page).
#
# Isolation: every unity-slot run gets UNITY_SLOT_HOME and UNITY_SLOT_CONFIG of its test environment,
# so the real registry, leases, events and install pointer are never read or written.
# Nothing here kills a process: a stub ends by itself (its control file, CloseMainWindow, its lifetime).

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:CliPath = Join-Path $script:RepoRoot 'unity-slot.ps1'
$script:McpPath = Join-Path $script:RepoRoot 'mcp\unity-slot-mcp.ps1'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:StubVersion = '9999.0.0f1'        # no real Unity has this version, so a real editor never opens
$script:MissingVersion = '9999.1.0f1'     # a version that is not under the editor roots
$script:ProjectKey = 'my-org/mygame'
$script:HarnessRoot = ''
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Tests = New-Object 'System.Collections.Generic.List[object]'

# ------------------------------------------------------------------ small helpers

function Get-P($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-CoreVersion {
    $m = [regex]::Match([IO.File]::ReadAllText($script:CliPath), '\$script:UnitySlotVersion = ''([^'']+)''')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-NormPathH([string]$P) {
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    $q = $P.Trim().Trim('"').Replace('/', '\')
    try { $q = [IO.Path]::GetFullPath($q) } catch { }
    return $q.TrimEnd('\')
}

function Test-SamePathH([string]$A, [string]$B) {
    return [string]::Equals((Get-NormPathH $A), (Get-NormPathH $B), [StringComparison]::OrdinalIgnoreCase)
}

function Test-UnderPath([string]$Path, [string]$Parent) {
    $p = (Get-NormPathH $Path) + '\'
    $root = (Get-NormPathH $Parent) + '\'
    return $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

# One argument for CreateProcess (CommandLineToArgvW rules).
function ConvertTo-CmdArg([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]'\') { $slashes++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append([string]::new([char]'\', $slashes * 2 + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
        if ($slashes -gt 0) { [void]$sb.Append([string]::new([char]'\', $slashes)); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append([string]::new([char]'\', $slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-Match([string]$Text, [string]$Pattern, [int]$Group = 1) {
    $m = [regex]::Match($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $m.Success) { return $null }
    return $m.Groups[$Group].Value
}

function Wait-Until([scriptblock]$Condition, [double]$TimeoutSec, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if (& $Condition) { return }
        if ((Get-Date) -ge $deadline) { Fail ('waited {0}s for {1}' -f $TimeoutSec, $What) }
        Start-Sleep -Milliseconds 250
    }
}

# ------------------------------------------------------------------ tests and checks

# A group is one test environment (its own state folder, config and clones) whose tests run one after
# another in one process; groups run in parallel. No clones = no environment (static checks).
$script:Groups = [ordered]@{}

function Register-Group([string]$Name, [string[]]$Clones = @(), [hashtable]$Timeouts = $null, [string[]]$Stray = @()) {
    $script:Groups[$Name] = [pscustomobject]@{ Name = $Name; Clones = $Clones; Timeouts = $Timeouts; Stray = $Stray }
}

# Body: { param($E) ... } where $E is the group's environment. Skip: reason (the test is not run).
# Known: a tests\FINDINGS.md id; a failure then counts as KNOWN, not FAIL.
function Add-Test {
    param([string]$Name, [string]$Group, [int]$Phase = 1, [scriptblock]$Body, [string]$Skip = '', [string]$Known = '')
    $script:Tests.Add([pscustomobject]@{ Name = $Name; Group = $Group; Phase = $Phase; Body = $Body; Skip = $Skip; Known = $Known })
}

function Fail([string]$Message) { throw (New-Object Exception ('ASSERT ' + $Message)) }

function Get-RunText($R) {
    if ($null -eq $R) { return '' }
    if ($R -is [string]) { return $R }
    return [string](Get-P $R 'Text')
}

function Format-Excerpt($R, [int]$Lines = 25) {
    $text = Get-RunText $R
    $all = @($text -split "`r?`n" | Where-Object { $_.Trim() })
    $shown = @($all | Select-Object -Last $Lines)
    $head = ''
    if ($all.Count -gt $shown.Count) { $head = ('  ... {0} earlier line(s)' -f ($all.Count - $shown.Count)) + "`n" }
    return "`n" + $head + (($shown | ForEach-Object { '  | ' + $_ }) -join "`n")
}

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { Fail $Message } }

function Assert-Equal($Actual, $Expected, [string]$What) {
    if ([string]$Actual -ne [string]$Expected) { Fail ('{0}: got "{1}", expected "{2}"' -f $What, $Actual, $Expected) }
}

function Assert-Exit($R, [int]$Code) {
    if ($R.TimedOut) { Fail ('{0}: still running after {1}s (left running){2}' -f $R.Label, $R.Timeout, (Format-Excerpt $R)) }
    if ($R.Code -ne $Code) { Fail ('{0}: exit {1}, expected {2}{3}' -f $R.Label, $R.Code, $Code, (Format-Excerpt $R)) }
}

# Literal text somewhere in the output.
function Assert-Has($R, [string]$Text, [string]$What = '') {
    if ((Get-RunText $R).IndexOf($Text, [StringComparison]::Ordinal) -lt 0) {
        $label = Get-P $R 'Label'
        if (-not $label) { $label = 'text' }
        if ($What) { $label = $What }
        Fail ('{0}: missing "{1}"{2}' -f $label, $Text, (Format-Excerpt $R))
    }
}

function Assert-HasNot($R, [string]$Text, [string]$What = '') {
    if ((Get-RunText $R).IndexOf($Text, [StringComparison]::Ordinal) -ge 0) {
        $label = Get-P $R 'Label'
        if (-not $label) { $label = 'text' }
        if ($What) { $label = $What }
        Fail ('{0}: must not contain "{1}"{2}' -f $label, $Text, (Format-Excerpt $R))
    }
}

# Regular expression (multiline) somewhere in the output.
function Assert-Like($R, [string]$Pattern, [string]$What = '') {
    if (-not [regex]::IsMatch((Get-RunText $R), $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) {
        $label = Get-P $R 'Label'
        if (-not $label) { $label = 'text' }
        if ($What) { $label = $What }
        Fail ('{0}: no match for /{1}/{2}' -f $label, $Pattern, (Format-Excerpt $R))
    }
}

function Assert-NotLike($R, [string]$Pattern, [string]$What = '') {
    $m = [regex]::Match((Get-RunText $R), $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($m.Success) {
        $label = Get-P $R 'Label'
        if (-not $label) { $label = 'text' }
        if ($What) { $label = $What }
        Fail ('{0}: must not match /{1}/ (found "{2}"){3}' -f $label, $Pattern, $m.Value, (Format-Excerpt $R))
    }
}

# ------------------------------------------------------------------ child processes

function Start-Child([string]$File, [string]$Arguments, [hashtable]$EnvVars) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    if ($null -ne $EnvVars) {
        foreach ($k in @($EnvVars.Keys)) {
            if ($null -eq $EnvVars[$k]) { $psi.EnvironmentVariables.Remove([string]$k) }
            else { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] }
        }
    }
    return [Diagnostics.Process]::Start($psi)
}

# Environment of a unity-slot run: the test environment's state and config, nothing of the caller's
# own unity-slot or Claude session, and a fixed default owner.
function Get-SlotEnvVars($E) {
    return @{
        UNITY_SLOT_HOME = $E.Home; UNITY_SLOT_CONFIG = $E.Config; UNITY_SLOT_OWNER = 'tester'
        UNITY_SLOT_VIA = $null; UNITY_SLOT_MCP_OWNER = $null; UNITY_SLOT_PYTHON = $null; UNITY_SLOT_COMMIT_OVERRIDE = $null
        CLAUDE_CODE_SESSION_ID = $null; CODEX_THREAD_ID = $null
        # MCP for Unity status files of this environment, not the real ones in %USERPROFILE%\.unity-mcp
        UNITY_SLOT_UNITY_MCP_DIR = (Join-Path $E.Dir 'unity-mcp')
    }
}

# $ExtraEnv adds or (with $null) removes variables, e.g. @{ UNITY_SLOT_COMMIT_OVERRIDE = '87' }.
# $Cli runs another copy of the core (New-CoreCopy) instead of this one.
function Start-SlotCli($E, [string[]]$CliArgs, [hashtable]$ExtraEnv = $null, [string]$Cli = '') {
    if (-not $Cli) { $Cli = $script:CliPath }
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CmdArg $Cli) + ' ' +
        ((@($CliArgs) | ForEach-Object { ConvertTo-CmdArg ([string]$_) }) -join ' ')
    $vars = Get-SlotEnvVars $E
    if ($null -ne $ExtraEnv) { foreach ($k in @($ExtraEnv.Keys)) { $vars[$k] = $ExtraEnv[$k] } }
    $p = Start-Child $script:PowerShellExe $line $vars
    $p.StandardInput.Close()
    return [pscustomobject]@{
        Proc = $p; OutTask = $p.StandardOutput.ReadToEndAsync(); ErrTask = $p.StandardError.ReadToEndAsync()
        Watch = [Diagnostics.Stopwatch]::StartNew(); CliArgs = @($CliArgs); E = $E
    }
}

# Waits for a run. On a timeout the process is left running (never killed) and the result says so.
function Complete-SlotCli($Run, [int]$TimeoutSec = 180) {
    $label = 'unity-slot ' + ($Run.CliArgs -join ' ')
    $done = $Run.Proc.WaitForExit($TimeoutSec * 1000)
    $out = ''; $err = ''; $code = $null
    if ($done) {
        $Run.Proc.WaitForExit()
        $code = $Run.Proc.ExitCode
        $out = $Run.OutTask.Result
        $err = $Run.ErrTask.Result
    }
    $Run.Watch.Stop()
    $r = [pscustomobject]@{
        Label = $label; Code = $code; Out = $out; Err = $err; Text = ($out + "`n" + $err); TimedOut = (-not $done)
        Timeout = $TimeoutSec; Seconds = [math]::Round($Run.Watch.Elapsed.TotalSeconds, 1)
    }
    try {
        $log = New-Object Text.StringBuilder
        [void]$log.AppendLine(('==== {0}  exit {1}  {2}s' -f $label, $code, $r.Seconds))
        if ($out.Trim()) { [void]$log.AppendLine($out.TrimEnd()) }
        if ($err.Trim()) { [void]$log.AppendLine('[stderr]'); [void]$log.AppendLine($err.TrimEnd()) }
        [IO.File]::AppendAllText($Run.E.CliLog, $log.ToString(), $script:Utf8)
    } catch { }
    return $r
}

function Invoke-SlotCli($E, [string[]]$CliArgs, [int]$TimeoutSec = 180, [hashtable]$ExtraEnv = $null, [string]$Cli = '') {
    return (Complete-SlotCli (Start-SlotCli $E $CliArgs $ExtraEnv $Cli) $TimeoutSec)
}

# A second copy of the core (unity-slot.ps1 and lib\) in the environment with another version, as a
# development checkout would be. Returns the path of its unity-slot.ps1.
function New-CoreCopy($E, [string]$Version) {
    $dir = Join-Path $E.Dir ('copies\' + $Version)
    [void](New-Item -ItemType Directory -Path (Join-Path $dir 'lib') -Force)
    $text = [IO.File]::ReadAllText($script:CliPath)
    $m = [regex]::Match($text, '\$script:UnitySlotVersion = ''[^'']+''')
    if (-not $m.Success) { throw 'no version line in unity-slot.ps1' }
    $text = $text.Replace($m.Value, ('$script:UnitySlotVersion = ''{0}''' -f $Version))
    $cli = Join-Path $dir 'unity-slot.ps1'
    [IO.File]::WriteAllText($cli, $text, $script:Utf8)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'lib') -Filter '*.ps1')) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir 'lib') }
    return $cli
}

# Runs a script of tests\fixtures with the environment's state and config (like a unity-slot run).
function Invoke-Fixture($E, [string]$Name, [string[]]$FixtureArgs = @(), [int]$TimeoutSec = 120) {
    $file = Join-Path $script:RepoRoot ('tests\fixtures\' + $Name)
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CmdArg $file) + ' ' +
        ((@($FixtureArgs) | ForEach-Object { ConvertTo-CmdArg ([string]$_) }) -join ' ')
    $p = Start-Child $script:PowerShellExe $line (Get-SlotEnvVars $E)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { Fail ('fixture {0} still running after {1}s (left running)' -f $Name, $TimeoutSec) }
    $p.WaitForExit()
    return [pscustomobject]@{ Label = ('fixture ' + $Name); Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result
        Text = ($outTask.Result + "`n" + $errTask.Result); TimedOut = $false; Timeout = $TimeoutSec }
}

# ------------------------------------------------------------------ git (the harness's own calls)

function Invoke-GitH([string[]]$GitArgs, [string]$Dir = '') {
    $base = @('-c', ('core.hooksPath=' + (Join-Path $script:HarnessRoot 'nohooks')), '-c', 'commit.gpgsign=false',
        '-c', 'user.name=unity-slot-tests', '-c', 'user.email=tests@localhost', '-c', 'core.autocrlf=false')
    if ($Dir) { $base = @('-C', $Dir) + $base }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& git @base @GitArgs 2>&1) } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw ('git {0} failed: {1}' -f ($GitArgs -join ' '), (($out | ForEach-Object { [string]$_ }) -join ' ')) }
    $out | ForEach-Object { [string]$_ }
}

# ------------------------------------------------------------------ test folder, stub, fake origin

function Initialize-HarnessRoot([string]$Root) {
    $script:HarnessRoot = Get-NormPathH $Root
    foreach ($d in @('', 'nohooks', 'envs', 'logs')) {
        $p = Join-Path $script:HarnessRoot $d
        if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
    }
}

function Get-StubExe([string]$Version = $script:StubVersion) {
    return (Join-Path $script:HarnessRoot ('editors\' + $Version + '\Editor\Unity.exe'))
}

function Build-Stub {
    $dir = Split-Path -Parent (Get-StubExe)
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $build = Join-Path $script:RepoRoot 'tests\stub\build.ps1'
    $p = Start-Child $script:PowerShellExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CmdArg $build) + ' -Out ' + (ConvertTo-CmdArg $dir)) $null
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Get-StubExe))) { throw ('stub build failed: ' + $outTask.Result + $errTask.Result) }
}

function Write-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Get-OriginPath { return (Join-Path $script:HarnessRoot 'remotes\my-org\mygame.git') }

# A bare origin with a tiny Unity-shaped project (no Library), cloned by every environment.
function New-FakeOrigin {
    $bare = Get-OriginPath
    $seed = Join-Path $script:HarnessRoot 'seed'
    [void](Invoke-GitH @('init', '-q', '--bare', '--initial-branch=master', $bare))
    Write-TextFile (Join-Path $seed '.gitignore') "/[Ll]ibrary/`n/[Tt]emp/`n/[Ll]ogs/`n/[Uu]ser[Ss]ettings/`n"
    Write-TextFile (Join-Path $seed 'Assets\Scenes\SampleScene.unity') "%YAML 1.1`n--- !u!29 &1`nOcclusionCullingSettings: {}`n"
    Write-TextFile (Join-Path $seed 'ProjectSettings\ProjectVersion.txt') ("m_EditorVersion: {0}`nm_EditorVersionWithRevision: {0} (stub)`n" -f $script:StubVersion)
    Write-TextFile (Join-Path $seed 'Packages\manifest.json') "{ `"dependencies`": {} }`n"
    [void](Invoke-GitH @('init', '-q', '--initial-branch=master') $seed)
    [void](Invoke-GitH @('add', '-A') $seed)
    [void](Invoke-GitH @('commit', '-q', '-m', 'fake Unity project') $seed)
    [void](Invoke-GitH @('push', '-q', $bare, 'master') $seed)
}

# The bytes unity-slot reads the platform from (Library\EditorUserBuildSettings.asset): after the type
# tree's "settings" the first build platform group name.
function Get-LibraryAssetBytes([string]$Group) {
    $b = New-Object 'System.Collections.Generic.List[byte]'
    $b.AddRange([byte[]](0, 0, 0, 22, 0, 0, 0, 0))
    $b.AddRange([Text.Encoding]::ASCII.GetBytes('EditorUserBuildSettings'))
    $b.AddRange([byte[]](0, 1, 0, 0))
    $b.AddRange([Text.Encoding]::ASCII.GetBytes('settings'))
    $b.AddRange([byte[]](0, 0, 0, 0, 7, 0, 0, 0))
    $b.AddRange([Text.Encoding]::ASCII.GetBytes($Group))
    $b.AddRange([byte[]](0, 0, 0, 0))
    return $b.ToArray()
}

function New-FakeClone([string]$Path, [string]$Group) {
    [void](Invoke-GitH @('clone', '-q', (Get-OriginPath), $Path))
    $lib = Join-Path $Path 'Library'
    [void](New-Item -ItemType Directory -Path $lib -Force)
    [IO.File]::WriteAllBytes((Join-Path $lib 'EditorUserBuildSettings.asset'), (Get-LibraryAssetBytes $Group))
    Set-StubControl $Path @{ mode = 'normal' } -Reset
}

# ------------------------------------------------------------------ environments

# Settings of a test environment (config.json). $Timeouts overrides single timeouts, $Extra other
# top-level settings (for example maxEditors).
function Write-EnvConfig($E, [hashtable]$Timeouts, [hashtable]$Extra = $null) {
    $t = [ordered]@{ open = 30; close = 20; wait = 10; stalled = 300; hook = 30 }
    if ($null -ne $Timeouts) { foreach ($k in @($Timeouts.Keys)) { $t[$k] = $Timeouts[$k] } }
    $record = @('{repo}\tests\fixtures\record-hook.ps1', '-Out', $E.HookLog)
    $cfg = [ordered]@{
        _comment       = 'unity-slot test environment (tests\run-tests.ps1); deleted with the test folder'
        editorRoots    = @((Join-Path $script:HarnessRoot 'editors'))
        scanRoots      = @($E.ClonesDir)
        cloneRoot      = $E.ClonesDir
        maxEditors     = 6
        standbyWorkers = 1
        leaseHours     = 8
        sceneBeacon    = 'Temp\SceneBeacon.json'
        timeouts       = $t
        hooks          = [ordered]@{
            beforeClose  = @([ordered]@{ name = 'scene-beacon'; run = @('{repo}\examples\hooks\scene-beacon.ps1', '-Beacon', 'Temp\SceneBeacon.json') })
            openStalled  = @([ordered]@{ name = 'record'; run = $record })
            closeStalled = @([ordered]@{ name = 'record'; run = $record })
        }
    }
    if ($null -ne $Extra) { foreach ($k in @($Extra.Keys)) { $cfg[$k] = $Extra[$k] } }
    Write-TextFile $E.Config ($cfg | ConvertTo-Json -Depth 8)
}

# Clone names: MyGame (main, not for agents), MyGame-<n> (agent), MyGame-Web (WebGL). $Stray: clones
# outside the scan root (never registered). Registers the clones with scan, as a person would.
function New-TestEnv([string]$Name, [string[]]$Clones, [hashtable]$Timeouts = $null, [string[]]$Stray = @()) {
    $dir = Join-Path $script:HarnessRoot ('envs\' + $Name)
    $E = [pscustomobject]@{
        Name = $Name; Dir = $dir; Home = (Join-Path $dir 'home'); Config = (Join-Path $dir 'config.json')
        ClonesDir = (Join-Path $dir 'clones'); OtherDir = (Join-Path $dir 'other'); HookLog = (Join-Path $dir 'hooks.log')
        CliLog = (Join-Path $dir 'cli.log'); Clones = @{}; Stray = @{}
    }
    foreach ($d in @($E.Home, $E.ClonesDir, $E.OtherDir)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    foreach ($c in $Clones) {
        $group = 'Android'
        if ($c -like '*-Web') { $group = 'WebGL' }
        $path = Join-Path $E.ClonesDir $c
        New-FakeClone $path $group
        $E.Clones[$c] = $path
    }
    foreach ($s in $Stray) {
        $path = Join-Path $E.OtherDir $s
        New-FakeClone $path 'Android'
        $E.Stray[$s] = $path
    }
    Write-EnvConfig $E $Timeouts
    $r = Invoke-SlotCli $E @('scan', '-ScanRoot', $E.ClonesDir, '-Project', $script:ProjectKey, '-Apply')
    Assert-Exit $r 0
    Assert-Has $r ('saved   {0} slot(s)' -f $Clones.Count)
    return $E
}

function Get-EnvSlotsJson($E) {
    $r = Invoke-SlotCli $E @('slots', '-Json')
    Assert-Exit $r 0
    return ($r.Out | ConvertFrom-Json)
}

# ------------------------------------------------------------------ stub control and processes

function Get-StubControlPath([string]$Clone) { return (Join-Path $Clone 'Temp\unity-stub.txt') }

function Read-StubControl([string]$Clone) {
    $map = [ordered]@{}
    $file = Get-StubControlPath $Clone
    if (-not (Test-Path -LiteralPath $file)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($file, $script:Utf8)) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
    }
    return $map
}

# Writes the stub's control file (atomically). -Reset drops every key except the quit/dismiss tokens,
# which must not change under a running stub unless that is the point.
function Set-StubControl([string]$Clone, [hashtable]$Values, [switch]$Reset) {
    $cur = Read-StubControl $Clone
    if ($Reset) {
        $keep = [ordered]@{}
        foreach ($k in @('quit', 'dismiss')) { if ($cur.Contains($k)) { $keep[$k] = $cur[$k] } }
        $cur = $keep
    }
    foreach ($k in @($Values.Keys)) { $cur[[string]$k] = [string]$Values[$k] }
    $lines = @($cur.Keys | ForEach-Object { '{0}={1}' -f $_, $cur[$_] })
    $file = Get-StubControlPath $Clone
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = $file + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $script:Utf8)
    for ($try = 0; $try -lt 20; $try++) {
        try { Move-Item -LiteralPath $tmp -Destination $file -Force; return } catch { Start-Sleep -Milliseconds 50 }
    }
    throw ('could not write ' + $file)
}

function Get-ProjectArg([string]$CommandLine) {
    $m = [regex]::Match($CommandLine, '(?i)(?:^|\s)"?-projectPath"?\s+(?:"([^"]*)"|([^\s"]+))')
    if (-not $m.Success) { return '' }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

# Stub processes of this test folder (by executable path), optionally of one clone.
function Get-StubProcs([string]$Clone = '') {
    $prefix = (Join-Path $script:HarnessRoot 'editors') + '\'
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='Unity.exe'" -Property ProcessId, ParentProcessId, ExecutablePath, CommandLine, CreationDate)) {
        $exe = [string]$p.ExecutablePath
        if (-not $exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Clone -and -not (Test-SamePathH (Get-ProjectArg ([string]$p.CommandLine)) $Clone)) { continue }
        $p
    }
}

function Test-ProcAlive([int]$ProcId) { return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) }

# Asks the stubs of these clones (all stubs of the folder when none is given) to end themselves through
# their control files, and waits. Returns the pids still running; they are left alone (never killed).
function Stop-Stubs([string[]]$Clones = @(), [int]$TimeoutSec = 15) {
    $procs = @(Get-StubProcs)
    if ($Clones.Count -gt 0) {
        $procs = @($procs | Where-Object { $proj = Get-ProjectArg ([string]$_.CommandLine); @($Clones | Where-Object { Test-SamePathH $proj $_ }).Count -gt 0 })
    }
    if ($procs.Count -eq 0) { return @() }
    $projects = @{}
    foreach ($p in $procs) {
        $proj = Get-NormPathH (Get-ProjectArg ([string]$p.CommandLine))
        if ($proj -and (Test-Path -LiteralPath $proj)) { $projects[$proj.ToLowerInvariant()] = $proj }
    }
    foreach ($proj in @($projects.Values)) { Set-StubControl $proj @{ quit = [guid]::NewGuid().ToString('N') } }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $alive = @($procs | ForEach-Object { [int]$_.ProcessId })
    while ($alive.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $alive = @($alive | Where-Object { Test-ProcAlive $_ })
    }
    return $alive
}

# Starts a stub directly through WMI (as a Hub or a batch run would), not through unity-slot.
function Start-StubDirect([string]$Clone, [string[]]$Extra = @(), [switch]$NoLogFile) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add((ConvertTo-CmdArg (Get-StubExe)))
    $parts.Add('-projectPath'); $parts.Add((ConvertTo-CmdArg $Clone))
    if (-not $NoLogFile) { $parts.Add('-logFile'); $parts.Add((ConvertTo-CmdArg (Join-Path $Clone 'Logs\Editor.log'))) }
    foreach ($x in $Extra) { $parts.Add((ConvertTo-CmdArg $x)) }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ($parts -join ' '); CurrentDirectory = $Clone }
    if ($r.ReturnValue -ne 0) { Fail ('Win32_Process.Create returned {0}' -f $r.ReturnValue) }
    return [int]$r.ProcessId
}

function Get-StubLog([string]$Clone, [string]$Name = 'Editor.log') {
    $file = Join-Path $Clone ('Logs\' + $Name)
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $sr = New-Object IO.StreamReader($fs, $script:Utf8); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}

# Unity keeps Temp\UnityLockfile open without sharing: none | stale | held (as unity-slot sees it).
function Get-LockStateH([string]$Clone) {
    $file = Join-Path $Clone 'Temp\UnityLockfile'
    if (-not (Test-Path -LiteralPath $file)) { return 'none' }
    try {
        $s = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $s.Dispose()
        return 'stale'
    } catch { return 'held' }
}

# ------------------------------------------------------------------ leases, events, hooks

function Get-LeaseFile($E, [string]$Slot) { return (Join-Path $E.Home ('leases\' + $Slot + '.json')) }

function Get-Lease($E, [string]$Slot) {
    $file = Get-LeaseFile $E $Slot
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return ([IO.File]::ReadAllText($file, $script:Utf8) | ConvertFrom-Json)
}

function Get-LeaseNames($E) {
    $dir = Join-Path $E.Home 'leases'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | ForEach-Object { $_.BaseName })
}

function Clear-Leases($E) {
    $dir = Join-Path $E.Home 'leases'
    if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force }
}

function Get-EventLines($E) {
    $file = Join-Path $E.Home 'events.jsonl'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $text = (New-Object IO.StreamReader($fs, $script:Utf8)).ReadToEnd() } finally { $fs.Dispose() }
    @($text -split "`n" | Where-Object { $_.Trim() })
}

function Get-EventCount($E) { return @(Get-EventLines $E).Count }

# Events written after the first $Skip lines, parsed.
function Get-NewEvents($E, [int]$Skip) {
    @(Get-EventLines $E | Select-Object -Skip $Skip | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-HookCalls($E) {
    if (-not (Test-Path -LiteralPath $E.HookLog)) { return @() }
    @([IO.File]::ReadAllLines($E.HookLog, $script:Utf8) | Where-Object { $_.Trim() } | ForEach-Object {
            $f = $_.Split('|')
            [pscustomobject]@{ Event = $f[0]; Slot = $f[1]; Pid = $f[2]; Clone = $f[3] }
        })
}

# Brings an environment back to closed, unleased clones in normal stub mode after a test. Returns the
# stub pids that did not end (left running).
function Reset-TestEnv($E) {
    $left = @(Stop-Stubs (@($E.Clones.Values) + @($E.Stray.Values)))
    Clear-Leases $E
    foreach ($c in (@($E.Clones.Values) + @($E.Stray.Values))) {
        Set-StubControl $c @{ mode = 'normal' } -Reset
        if ($left.Count -eq 0) {
            foreach ($f in @('Temp\SceneBeacon.json', 'Temp\UnityLockfile')) {
                $p = Join-Path $c $f
                if (Test-Path -LiteralPath $p) { try { Remove-Item -LiteralPath $p -Force } catch { } }
            }
        }
    }
    return $left
}

# ------------------------------------------------------------------ the real unity-slot state

# Files of the real state folder that a test run must never change.
function Get-RealState {
    $dir = Join-Path $env:USERPROFILE '.unity-slot'
    foreach ($name in @('slots.json', 'install.json')) {
        $file = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $file)) { [pscustomobject]@{ Name = $name; Exists = $false; Stamp = ''; Hash = '' }; continue }
        $item = Get-Item -LiteralPath $file
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($file)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
        [pscustomobject]@{ Name = $name; Exists = $true; Stamp = $item.LastWriteTimeUtc.Ticks; Hash = $hash }
    }
}

# Real state files that changed during a run. Leak = this run wrote it (install.json points at this
# copy, or slots.json holds a path of the test folder); otherwise another copy or a person changed it
# meanwhile (for example another checkout with a newer version takes the install pointer over).
function Get-RealStateChanges($Before, $After) {
    $dir = Join-Path $env:USERPROFILE '.unity-slot'
    foreach ($b in @($Before)) {
        $a = @($After | Where-Object { $_.Name -eq $b.Name })[0]
        if ($null -eq $a) { continue }
        if ($a.Exists -eq $b.Exists -and $a.Stamp -eq $b.Stamp -and $a.Hash -eq $b.Hash) { continue }
        $text = ''
        if ($a.Exists) { try { $text = [IO.File]::ReadAllText((Join-Path $dir $b.Name), $script:Utf8) } catch { } }
        $leak = $false
        $note = ''
        if ($b.Name -eq 'install.json') {
            $pointer = $null
            try { $pointer = $text | ConvertFrom-Json } catch { }
            $target = [string](Get-P $pointer 'script')
            $leak = Test-SamePathH $target $script:CliPath
            $note = ('now points at {0} (version {1})' -f $target, [string](Get-P $pointer 'version'))
        } else {
            $root = $script:HarnessRoot
            $leak = ($text.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($text.IndexOf($root.Replace('\', '\\'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
            $note = 'holds no path of the test folder'
            if ($leak) { $note = 'holds paths of the test folder' }
        }
        [pscustomobject]@{ Name = $b.Name; Leak = $leak; Note = $note }
    }
}

# Process id of the window that has the keyboard focus (0 when there is none). A stub must never take
# the focus away from the person using the PC.
function Get-ForegroundPid {
    if (-not ('UnitySlotTests.Foreground' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace UnitySlotTests {
    public static class Foreground {
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        public static int Pid() {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return 0;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }
    }
}
'@
    }
    return [UnitySlotTests.Foreground]::Pid()
}

# True when this process runs with a package identity (an MSIX app's shell). Such a shell writes to
# %LOCALAPPDATA% / %APPDATA% through a private copy that a WMI-started stub cannot see.
function Test-PackagedProcess {
    if (-not ('UnitySlotTests.PackageInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace UnitySlotTests {
    public static class PackageInfo {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetCurrentPackageFullName(ref int length, StringBuilder name);
        public static bool IsPackaged() { int len = 0; return GetCurrentPackageFullName(ref len, null) != 15700; }
    }
}
'@
    }
    try { return [UnitySlotTests.PackageInfo]::IsPackaged() } catch { return $false }
}
