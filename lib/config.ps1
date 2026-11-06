# Settings, hooks and extra commands. Dot-sourced by unity-slot.ps1. ASCII-only source.
#
# Settings file: the first of
#   $env:UNITY_SLOT_CONFIG
#   <unity-slot folder>\config.json      (git-ignored in the public repository)
#   <slot home>\config.json              (%USERPROFILE%\.unity-slot unless UNITY_SLOT_HOME says otherwise)
# Missing keys fall back to Get-DefaultConfig; config.example.json shows every key.
# Text values may use {home} (user profile), {repo} (the unity-slot folder), {state} (slot home)
# and %VARIABLE% environment variables.
#
# Hooks: programs listed per event under "hooks", run in order as child processes, never killed.
#   .ps1 -> Windows PowerShell, .py -> python -X utf8, .cmd/.bat -> cmd.exe, anything else as is.
#   Arguments may use {clone} {slot} {pid} {log} {platform} {project} {template} {event}. The same
#   values are in the environment as UNITY_SLOT_CLONE, UNITY_SLOT_SLOT, ..., plus UNITY_SLOT_EVENT,
#   UNITY_SLOT_REPO and UNITY_SLOT_PYTHON.
#   Exit 0 = ok. Exit 4 = refuse (beforeClose: the editor is not closed). Anything else = the hook
#   failed: reported, and the command goes on (new-clone counts failed afterFirstOpen hooks).
#   A .ps1 hook should end with an explicit "exit <n>"; without it the last native exit code counts.
# Commands: "commands" maps an extra command name to a .ps1 file and a function in it. unity-slot
#   dot-sources the file and calls the function, which sees the same parameters ($Target, $From,
#   $Apply, ...) and helpers (Say, Read-Registry, Find-Slot, Invoke-Git, ...) as the built-in commands.

$script:HookEvents = @('beforeClose', 'afterClose', 'openStalled', 'closeStalled', 'afterClone', 'afterFirstOpen')
$script:HookEventHelp = [ordered]@{
    beforeClose    = 'before close asks an editor to quit; exit 4 refuses the close (overridden by -AllowDirty)'
    afterClose     = 'after the editor has exited'
    openStalled    = 'open or wait gave up on a starting editor (after the window list)'
    closeStalled   = 'close timed out and the editor is still open (after the window list)'
    afterClone     = 'new-clone made and registered a clone (before its first open)'
    afterFirstOpen = 'a new clone''s editor is READY for the first time (new-clone, open or wait)'
}
$script:BuiltinCommands = @('open', 'wait', 'close', 'status', 'slots', 'scan', 'set', 'acquire', 'release', 'renew', 'new-clone', 'hooks')
$script:ConfigCache = $null
$script:ConfigFileUsed = $null
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-DefaultConfig {
    return [pscustomobject][ordered]@{
        editorRoots     = [string[]]@('C:\Program Files\Unity\Hub\Editor')
        scanRoots       = [string[]]@()
        cloneRoot       = ''
        maxEditors      = 0
        standbyWorkers  = 1
        leaseHours      = 8
        python          = ''
        timeouts        = [pscustomobject][ordered]@{
            open = 300; close = 240; wait = 45; stalled = 300; firstOpen = 2400; firstOpenWithLibrary = 900; hook = 120
        }
        purposeRules    = [pscustomobject][ordered]@{
            mainWhenNoSuffix    = $true
            suffix              = @([pscustomobject][ordered]@{ pattern = '^\d+$'; purposes = [string[]]@('agent') })
            platform            = [pscustomobject][ordered]@{ WebGL = [string[]]@('webgl'); Windows = [string[]]@('windows') }
            fallback            = [string[]]@('agent')
            notCopiedToNewClone = [string[]]@('main')
        }
        platformAliases = [pscustomobject]@{}
        hooks           = [pscustomobject]@{}
        commands        = [pscustomobject]@{}
    }
}

function Test-IsMap($Value) {
    return ($null -ne $Value -and $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')
}

# Objects merge key by key (the file wins); arrays and plain values are replaced.
# Keys starting with "_" or "$" are comments.
function Merge-Settings($Base, $Over) {
    if ($null -eq $Over) { return $Base }
    if (-not (Test-IsMap $Base) -or -not (Test-IsMap $Over)) { return $Over }
    $out = [pscustomobject][ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        if ($p.Name.StartsWith('_') -or $p.Name.StartsWith('$')) { continue }
        $cur = $out.PSObject.Properties[$p.Name]
        if ($null -ne $cur) { $cur.Value = Merge-Settings $cur.Value $p.Value }
        else { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    return $out
}

function Get-ConfigFile {
    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_SLOT_CONFIG)) { return $env:UNITY_SLOT_CONFIG }
    foreach ($c in @((Join-Path $script:SlotRepo 'config.json'), (Join-Path (Get-SlotHome) 'config.json'))) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    return $null
}

function Get-SlotConfig {
    if ($null -ne $script:ConfigCache) { return $script:ConfigCache }
    $cfg = Get-DefaultConfig
    $file = Get-ConfigFile
    if ($file) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "UNITY_SLOT_CONFIG names a missing file: $file" }
        $data = $null
        try { $data = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json }
        catch { throw ('config {0} is not valid JSON: {1}' -f $file, $_.Exception.Message) }
        $cfg = Merge-Settings $cfg $data
    }
    $script:ConfigFileUsed = $file
    $script:ConfigCache = $cfg
    return $cfg
}

function Get-Setting([string]$Name) { return (Get-Prop (Get-SlotConfig) $Name) }

function Get-SettingList($Value) {
    @(@($Value) | Where-Object { $null -ne $_ -and ([string]$_) -ne '' } | ForEach-Object { [string]$_ })
}

function Get-TimeoutSetting([string]$Name, [int]$Fallback) {
    $v = Get-Prop (Get-Setting 'timeouts') $Name
    if ($null -eq $v -or [int]$v -le 0) { return $Fallback }
    return [int]$v
}

# {home} {repo} {state} and %VARIABLE%, then the call's own placeholders ({clone}, {slot}, ...).
function Expand-SlotText([string]$Text, $Vars) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = [Environment]::ExpandEnvironmentVariables($Text)
    $all = @{ home = $env:USERPROFILE; repo = $script:SlotRepo; state = (Get-SlotHome) }
    if ($null -ne $Vars) { foreach ($k in @($Vars.Keys)) { $all[[string]$k] = [string]$Vars[$k] } }
    foreach ($k in @($all.Keys)) { $out = $out.Replace('{' + $k + '}', [string]$all[$k]) }
    return $out
}

function Get-ExpandedList($Value) { @(Get-SettingList $Value | ForEach-Object { Expand-SlotText $_ $null }) }

# ------------------------------------------------------------------ hooks

function Get-Hooks([string]$EventName) {
    @(@(Get-Prop (Get-Setting 'hooks') $EventName) | Where-Object { $null -ne $_ -and (Get-Prop $_ 'enabled') -ne $false })
}

function Get-HookName($Hook) {
    $n = [string](Get-Prop $Hook 'name')
    if ($n) { return $n }
    $run = @(Get-SettingList (Get-Prop $Hook 'run'))
    if ($run.Count -gt 0) { return [IO.Path]::GetFileNameWithoutExtension($run[0]) }
    return '(unnamed)'
}

# One argument for CreateProcess (the rules CommandLineToArgvW and the C runtime parse back).
function ConvertTo-WinArg([string]$Arg) {
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

# One argument inside a PowerShell command: parameter names (-Apply, -Path) stay bare so a script
# binds them as parameters; everything else is a single-quoted literal.
function ConvertTo-PsArg([string]$Arg) {
    if ($Arg -match '^-[A-Za-z][A-Za-z0-9]*$') { return $Arg }
    return ("'" + $Arg.Replace("'", "''") + "'")
}

# Starts a hook and waits up to $TimeoutSec. On timeout it is left running (never killed).
function Start-HookProcess([string[]]$Run, [hashtable]$EnvVars, [int]$TimeoutSec, [string]$WorkDir) {
    $exe = $Run[0]
    $rest = @()
    if ($Run.Count -gt 1) { $rest = @($Run[1..($Run.Count - 1)]) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $ext = [IO.Path]::GetExtension($exe).ToLowerInvariant()
    if ($ext -eq '.ps1') {
        # -EncodedCommand: no quoting trouble, and the child writes UTF-8 like unity-slot itself.
        # All streams go to stdout as text (otherwise progress and errors arrive on stderr as CLIXML).
        $call = "& '" + $exe.Replace("'", "''") + "' " + (@($rest | ForEach-Object { ConvertTo-PsArg $_ }) -join ' ')
        $cmd = '$ProgressPreference = ''SilentlyContinue''; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ' +
            'try { ' + $call + ' *>&1 | Out-String -Stream -Width 4096; exit $LASTEXITCODE } ' +
            'catch { Write-Output (''hook error: '' + $_.Exception.Message); exit 1 }'
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    } elseif ($ext -eq '.py') {
        $py = Find-Python
        if (-not $py) { throw 'python not found (set "python" in the config, or UNITY_SLOT_PYTHON)' }
        $psi.FileName = $py
        $psi.Arguments = (@(@('-X', 'utf8', $exe) + $rest) | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    } elseif ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c "' + ((@(@($exe) + $rest) | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ') + '"'
    } else {
        $psi.FileName = $exe
        $psi.Arguments = (@($rest | ForEach-Object { ConvertTo-WinArg $_ })) -join ' '
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    if ($WorkDir -and (Test-Path -LiteralPath $WorkDir -PathType Container)) { $psi.WorkingDirectory = $WorkDir }
    foreach ($k in @($EnvVars.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
        return [pscustomobject]@{ Code = $null; TimedOut = $true; Pid = $p.Id; Lines = @() }
    }
    $p.WaitForExit()
    $text = $outTask.Result
    $err = $errTask.Result
    if ($err -and $err.Trim()) { $text = $text.TrimEnd() + "`n" + $err }
    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    return [pscustomobject]@{ Code = $p.ExitCode; TimedOut = $false; Pid = $p.Id; Lines = $lines }
}

# Values a hook gets for one clone: the registry slot (when registered) and what the caller knows.
function Get-HookVars([string]$Clone, [int]$EditorPid = 0, [string]$Log = '') {
    $vars = [ordered]@{ clone = $Clone; slot = ''; pid = ''; log = $Log; platform = ''; project = ''; template = '' }
    if ($EditorPid -gt 0) { $vars.pid = [string]$EditorPid }
    if (-not $Log) { $vars.log = Join-Path $Clone 'Logs\Editor.log' }
    try {
        foreach ($s in (Read-Registry).slots) {
            if (Test-SamePath $s.path $Clone) { $vars.slot = $s.name; $vars.platform = $s.platform; $vars.project = $s.project }
        }
    } catch { }
    return $vars
}

# Runs the hooks of one event in order and prints what each one said (masked).
function Invoke-SlotHooks([string]$EventName, $Vars) {
    $result = [pscustomobject]@{
        Ran     = 0
        Refused = (New-Object 'System.Collections.Generic.List[string]')
        Failed  = (New-Object 'System.Collections.Generic.List[string]')
    }
    $hooks = @(Get-Hooks $EventName)
    if ($hooks.Count -eq 0) { return $result }
    if ($NoHooks) { Say ('hook    {0}: {1} hook(s) skipped (-NoHooks)' -f $EventName, $hooks.Count); return $result }
    $skip = @(@($SkipHook) | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $all = [ordered]@{}
    if ($null -ne $Vars) { foreach ($k in @($Vars.Keys)) { $all[[string]$k] = [string]$Vars[$k] } }
    $all['event'] = $EventName
    $envVars = @{ UNITY_SLOT_EVENT = $EventName; UNITY_SLOT_REPO = $script:SlotRepo }
    foreach ($k in @($all.Keys)) { if ($k -ne 'event') { $envVars['UNITY_SLOT_' + $k.ToUpperInvariant()] = $all[$k] } }
    $py = Find-Python
    if ($py) { $envVars['UNITY_SLOT_PYTHON'] = $py }
    foreach ($h in $hooks) {
        $name = Get-HookName $h
        if ($skip -contains $name) { Say ('hook    {0}/{1}: skipped (-SkipHook)' -f $EventName, $name); continue }
        $run = @(Get-SettingList (Get-Prop $h 'run') | ForEach-Object { Expand-SlotText $_ $all })
        if ($run.Count -eq 0) { Say ('hook    {0}/{1}: no "run" in the config; skipped' -f $EventName, $name); $result.Failed.Add($name); continue }
        $timeout = [int](Get-Prop $h 'timeoutSec')
        if ($timeout -le 0) { $timeout = Get-TimeoutSetting 'hook' 120 }
        Say ('hook    {0}/{1}: {2}' -f $EventName, $name, (Protect-Text ($run -join ' ')))
        $r = $null
        try { $r = Start-HookProcess $run $envVars $timeout $all['clone'] }
        catch { Say ('hook    {0}/{1}: could not start: {2}' -f $EventName, $name, $_.Exception.Message); $result.Failed.Add($name); continue }
        $result.Ran++
        $shown = @($r.Lines)
        if ($shown.Count -gt 40) { Say ('  ... {0} earlier line(s)' -f ($shown.Count - 40)); $shown = @($shown | Select-Object -Last 40) }
        foreach ($l in $shown) { Say ('  ' + (Protect-Text ([string]$l))) }
        if ($r.TimedOut) {
            Say ('hook    {0}/{1}: still running after {2}s (pid {3}); left running, not killed' -f $EventName, $name, $timeout, $r.Pid)
            $result.Failed.Add($name)
        } elseif ($r.Code -eq 0) {
            Say ('hook    {0}/{1}: exit 0' -f $EventName, $name)
        } elseif ($r.Code -eq 4) {
            Say ('hook    {0}/{1}: exit 4 (refuses)' -f $EventName, $name)
            $result.Refused.Add($name)
        } else {
            Say ('hook    {0}/{1}: exit {2} (failed)' -f $EventName, $name, $r.Code)
            $result.Failed.Add($name)
        }
    }
    return $result
}

# A new clone's afterFirstOpen hooks wait in its registry record until its editor is first READY,
# whoever opens it (new-clone, open, wait, acquire). Cleared before running, so they run once.
function Invoke-PendingHooks([string]$Clone, [int]$EditorPid, [string]$Log) {
    $reg = $null
    try { $reg = Read-Registry } catch { return }
    $slot = $null
    foreach ($s in $reg.slots) { if (Test-SamePath $s.path $Clone) { $slot = $s } }
    if ($null -eq $slot -or @($slot.pendingHooks).Count -eq 0) { return }
    $events = @($slot.pendingHooks)
    $slot.pendingHooks = [string[]]@()
    Write-Registry $reg
    foreach ($ev in $events) {
        $r = Invoke-SlotHooks $ev (Get-HookVars $Clone $EditorPid $Log)
        if ($r.Failed.Count -gt 0 -or $r.Refused.Count -gt 0) {
            $script:PendingHooksFailed = $true
            Say ('warn    {0} hook(s) did not succeed: {1}. Run them again: unity-slot hooks {2} -HookEvent {0}' -f $ev, ((@($r.Failed) + @($r.Refused)) -join ', '), $slot.name)
        }
    }
}

# ------------------------------------------------------------------ extra commands

function Get-ExtraCommand([string]$Name) {
    $c = Get-Prop (Get-Setting 'commands') $Name
    if ($null -eq $c) { return $null }
    $file = Expand-SlotText ([string](Get-Prop $c 'script')) $null
    $fn = [string](Get-Prop $c 'function')
    if (-not $file -or -not $fn) { throw ('command "{0}" in the config needs "script" and "function"' -f $Name) }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ('command "{0}": {1} not found' -f $Name, $file) }
    return [pscustomobject]@{ Name = $Name; Script = $file; Function = $fn; Usage = [string](Get-Prop $c 'usage') }
}

function Get-ExtraCommandNames {
    $c = Get-Setting 'commands'
    if ($null -eq $c) { return @() }
    @($c.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') -and -not $_.Name.StartsWith('$') } | ForEach-Object { $_.Name })
}

# ------------------------------------------------------------------ hooks command

function Invoke-Hooks {
    $file = Get-ConfigFile
    $null = Get-SlotConfig
    if ($file) { Say ('config  {0}' -f $file) } else { Say 'config  none (built-in defaults). See config.example.json.' }
    if (-not $HookEvent) {
        foreach ($ev in $script:HookEvents) {
            $hooks = @(Get-Hooks $ev)
            Say ('{0,-14} {1}' -f $ev, $script:HookEventHelp[$ev])
            if ($hooks.Count -eq 0) { Say '               (none)' }
            foreach ($h in $hooks) {
                $t = [int](Get-Prop $h 'timeoutSec')
                $tt = ''
                if ($t -gt 0) { $tt = (' (timeout {0}s)' -f $t) }
                Say ('               {0}: {1}{2}' -f (Get-HookName $h), (Protect-Text (@(Get-SettingList (Get-Prop $h 'run')) -join ' ')), $tt)
            }
        }
        $names = @(Get-ExtraCommandNames)
        if ($names.Count -eq 0) { Say 'commands (no extra commands)' }
        foreach ($n in $names) {
            $c = Get-Prop (Get-Setting 'commands') $n
            Say ('command {0}: {1} -> {2}' -f $n, [string](Get-Prop $c 'usage'), (Expand-SlotText ([string](Get-Prop $c 'script')) $null))
        }
        return
    }
    if ($script:HookEvents -notcontains $HookEvent) { throw ('unknown hook event "{0}". Events: {1}' -f $HookEvent, ($script:HookEvents -join ', ')) }
    if ([string]::IsNullOrWhiteSpace($Target)) { throw 'usage: unity-slot hooks <slot|clone> -HookEvent <event>' }
    $clone = Resolve-Clone (Resolve-TargetPath $Target)
    $editorPid = 0
    $log = ''
    $editors = @(Get-OpenFor (Get-Snapshot) $clone | Where-Object { $_.Kind -eq 'editor' })
    if ($editors.Count -gt 0) {
        $editorPid = $editors[0].Pid
        $logArg = Get-CmdArg $editors[0].CommandLine 'logFile'
        if ($logArg) { $log = Get-NormPath $logArg }
    }
    $vars = Get-HookVars $clone $editorPid $log
    Say ('clone   {0}; slot {1}; editor pid {2}' -f $clone, $(if ($vars.slot) { $vars.slot } else { '(not registered)' }), $(if ($editorPid) { $editorPid } else { '(closed)' }))
    $r = Invoke-SlotHooks $HookEvent $vars
    if ($r.Ran -eq 0 -and @(Get-Hooks $HookEvent).Count -eq 0) { Say ('no {0} hooks in the config' -f $HookEvent) }
    if ($r.Refused.Count -gt 0) { $script:ExitCode = 4 }
    elseif ($r.Failed.Count -gt 0) { $script:ExitCode = 1 }
}
