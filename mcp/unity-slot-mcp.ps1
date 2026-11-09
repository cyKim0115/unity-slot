<#
unity-slot MCP server: stdio, JSON-RPC 2.0, one JSON message per line. ASCII-only source.

A thin wrapper. Every tool call runs ..\unity-slot.ps1 in a child powershell.exe and returns its text,
so the logic (registry, leases, WMI launch, close checks) lives in one place. The MCP client starts
this process for a session and it ends when stdin closes: nothing resident, nothing auto-started.
Shared state (registry, leases) is files under %USERPROFILE%\.unity-slot; leases are created with
CreateNew, so sessions cannot take the same slot.

Tool calls stay short: open/acquire return right after launching and wait_ready waits at most 55 s,
so a call never sits on an MCP tool timeout while Unity starts (12 s to a few minutes).

Register (example): command powershell.exe, args
  -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <repo>\mcp\unity-slot-mcp.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Cli = Join-Path $script:Root 'unity-slot.ps1'
$script:ServerVersion = '0.0.0'
try {
    $vm = [regex]::Match([IO.File]::ReadAllText($script:Cli), '\$script:UnitySlotVersion = ''([^'']+)''')
    if ($vm.Success) { $script:ServerVersion = $vm.Groups[1].Value }
} catch { }
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:Owner = ''
$script:OwnerStable = $false
$script:Protocol = ''
$script:Versions = @('2025-06-18', '2025-03-26', '2024-11-05')

[Console]::InputEncoding = $script:Utf8
[Console]::OutputEncoding = $script:Utf8

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Write-Message($Obj) {
    [Console]::Out.Write(($Obj | ConvertTo-Json -Depth 20 -Compress) + "`n")
    [Console]::Out.Flush()
}

function Write-Log([string]$Text) { [Console]::Error.WriteLine('[unity-slot-mcp] ' + $Text) }

function Send-Result($Id, $Result) { Write-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result }) }

function Send-Error($Id, [int]$Code, [string]$Message) {
    Write-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Message } })
}

# ------------------------------------------------------------------ tools

function New-Tool([string]$Name, [string]$Description, $Properties, [string[]]$Required, $Annotations = $null) {
    $schema = [ordered]@{ type = 'object'; properties = $Properties }
    if ($Required -and $Required.Count -gt 0) { $schema.required = $Required }
    $tool = [ordered]@{ name = $Name; description = $Description; inputSchema = $schema }
    if ($null -ne $Annotations) { $tool.annotations = $Annotations }
    return $tool
}

function New-Prop([string]$Type, [string]$Description) { return [ordered]@{ type = $Type; description = $Description } }

# MCP tool annotations (protocol 2025-03-26 and later; left out for 2024-11-05 clients). Hints only:
# destructiveHint and idempotentHint mean something only when readOnlyHint is false.
function New-Hints([string]$Title, [bool]$ReadOnly, [bool]$Destructive, [bool]$Idempotent, [bool]$OpenWorld) {
    $h = [ordered]@{ title = $Title; readOnlyHint = $ReadOnly }
    if (-not $ReadOnly) { $h.destructiveHint = $Destructive; $h.idempotentHint = $Idempotent }
    $h.openWorldHint = $OpenWorld
    return $h
}

$script:Tools = @(
    (New-Tool 'status' ('Short status of the Unity slots on this PC: a line with open editors of the maximum and the commit, ' +
            'one table (slot, platform, mode, state, lease, agent use) and warnings (commit, editors at the maximum, slot flags). ' +
            'slot or project narrow it. format=json gives the slot registry as JSON instead; processes=true the editor ' +
            'processes and memory; dashboard=true the full read-only dashboard document (editor state, memory, lease, git, ' +
            'recent events, flags).') ([ordered]@{
            slot      = (New-Prop 'string' 'Only this slot (name or clone path).')
            project   = (New-Prop 'string' 'Only slots of this repository (owner/repo, repo, or its end).')
            format    = (New-Prop 'string' 'summary (default, a short table) or json (the slot registry as JSON).')
            processes = (New-Prop 'boolean' 'Show editor processes and memory instead of the slot registry.')
            dashboard = (New-Prop 'boolean' 'Return the dashboard document (schema unity-slot.dashboard/1).')
            git       = (New-Prop 'string' 'With dashboard: basic (default, each slot''s git status) or full (also local-only commits, branches, stash, worktrees).')
        }) @() (New-Hints 'Unity slot status' $true $false $true $false)),
    (New-Tool 'acquire' ('Lease a free slot that fits a purpose or platform (for example agent, webgl, windows, android) ' +
            'and start its editor without waiting. Call it as soon as you know the task needs the Unity editor, before ' +
            'planning or research (pull or switch branches first, while it is closed): the editor starts (12 s to minutes) ' +
            'while you read code, research and plan; edit Unity assets or scripts only after READY. Call wait_ready when ' +
            'you actually need the editor, check through the Unity MCP that Application.dataPath is that slot, work there, ' +
            'and call release when done. Several slots: take them together only while the commit is below the high mark ' +
            '(no "warn capacity" line), else one after another. "NO FREE SLOT" means none fits: show the plan from create ' +
            'to the user. Never switch a slot to another platform. If the result has a "warn capacity" line (editors at the ' +
            'maximum, commit high), tell the user.') ([ordered]@{
            purpose = (New-Prop 'string' 'Purpose tag or platform, for example agent, webgl, windows, android.')
            project = (New-Prop 'string' 'Repository (owner/repo, repo, or its end), for example my-game. Needed when several projects fit.')
            owner   = (New-Prop 'string' 'Lease owner. Default: this MCP session.')
            hours   = (New-Prop 'number' 'Lease length in hours (default: leaseHours in the config, 8). Acquiring again extends your own lease.')
            open    = (New-Prop 'boolean' 'Start the editor (default true). false only leases the slot.')
        }) @('purpose') (New-Hints 'Lease a Unity slot' $false $false $false $false)),
    (New-Tool 'open' ('Start the editor of a slot (name) or clone path and return at once. Like acquire, call it as soon as ' +
            'the task needs the editor and do the work that needs no editor while it starts; call wait_ready when you ' +
            'need it. Does nothing if it is already open. Prefer acquire, which also leases the slot. If the result has a ' +
            '"warn capacity" line, tell the user.') ([ordered]@{
            slot         = (New-Prop 'string' 'Slot name from status, or a clone path.')
            build_target = (New-Prop 'string' 'Platform for a first open (Android, WebGL, Windows). Refused if it would switch the platform.')
        }) @('slot') (New-Hints 'Open a slot editor' $false $false $true $false)),
    (New-Tool 'wait_ready' ('Call it when you actually need the editor, not right after acquire or open: until then do the ' +
            'work that needs no editor. Waits up to timeout_sec (default 45, at most 55) for a starting editor. READY: go on. ' +
            'STARTING: call again. STALLED (over 5 minutes): it lists the dialogs; hand it to the user, never click. ' +
            'NOT RUNNING: it is not open. If the result has a "warn capacity" line, tell the user.') ([ordered]@{
            slot        = (New-Prop 'string' 'Slot name or clone path.')
            timeout_sec = (New-Prop 'number' 'Seconds to wait in this call (1 to 55, default 45).')
        }) @('slot') (New-Hints 'Wait for a slot editor' $true $false $true $false)),
    (New-Tool 'close' ('Close a slot editor like clicking X: Unity saves, nothing is killed. Refuses when a beforeClose ' +
            'hook says not to close now (for example unsaved scenes: save or discard first, as its message says). ' +
            'Reports files written by the close and files changed while it was open; never reverts them. ' +
            'discard_unsaved=true uses the official Unity CLI "unity close", which exits WITHOUT saving; pass it only when ' +
            'the user said to drop unsaved changes (works only for projects with com.unity.pipeline).') ([ordered]@{
            slot            = (New-Prop 'string' 'Slot name or clone path.')
            timeout_sec     = (New-Prop 'number' 'Seconds to wait for the editor to exit (default 60, at most 240).')
            discard_unsaved = (New-Prop 'boolean' 'Close without saving through the official Unity CLI. Only on the user''s word.')
        }) @('slot') (New-Hints 'Close a slot editor' $false $true $true $false)),
    (New-Tool 'release' ('Release a slot you acquired: an on-demand slot is closed like close, a hot slot stays open, then ' +
            'the lease is dropped. Only the lease owner can release. If the MCP server restarted since your acquire, this ' +
            'session has a new owner id: pass owner= the id your acquire result showed (status explains such leases).') ([ordered]@{
            slot        = (New-Prop 'string' 'Slot name.')
            owner       = (New-Prop 'string' 'Lease owner. Default: this MCP session. After a server restart: the owner your acquire showed.')
            keep_open   = (New-Prop 'boolean' 'Drop the lease but leave the editor open.')
            timeout_sec = (New-Prop 'number' 'Seconds to wait for the editor to exit (default 60, at most 240).')
        }) @('slot') (New-Hints 'Release a Unity slot' $false $true $true $false)),
    (New-Tool 'create' ('Plan a new clone slot for a purpose when no slot is free. Without confirm it is a dry run that ' +
            'creates nothing: show the plan to the user. confirm=true runs it (git clone, Library copy, register, ' +
            'afterClone hooks; can take minutes) and is only for after the user agreed to that plan. The first open is ' +
            'left to open + wait_ready; the afterFirstOpen hooks run when that editor is first READY. The clone gets a ' +
            'generic name, <repo>-<smallest free number>: no branch, feature, platform, agent or date in names (the ' +
            'registry keeps purposes, platform and branch).') ([ordered]@{
            purpose = (New-Prop 'string' 'Purpose tag or platform for the new slot.')
            project = (New-Prop 'string' 'Repository (owner/repo, repo, or its end), for example my-game.')
            from    = (New-Prop 'string' 'Slot to copy from (default: a closed slot of that purpose).')
            confirm = (New-Prop 'boolean' 'true = really create it. Only after the user agreed to the dry-run plan.')
        }) @('purpose') (New-Hints 'Plan or create a clone slot' $false $false $false $true))
)

function Get-Arg($Arguments, [string]$Name, $Default) {
    $v = Get-Prop $Arguments $Name
    if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { return $Default }
    return $v
}

function Limit([double]$Value, [double]$Min, [double]$Max) { return [Math]::Max($Min, [Math]::Min($Max, $Value)) }

function ConvertTo-ArgString([string[]]$Items) {
    $parts = foreach ($a in $Items) {
        $s = ([string]$a).TrimEnd('\')
        if ($s -match '^[A-Za-z0-9_:.,/@+=-]+$') { $s } else { '"' + $s.Replace('"', '\"') + '"' }
    }
    return ($parts -join ' ')
}

# Runs unity-slot.ps1 in a child powershell (stdin closed, UTF-8 output). Never kills it.
function Invoke-UnitySlot([string[]]$CliArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:Cli + '" ' + (ConvertTo-ArgString $CliArgs)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    # events.jsonl records which way a command came ("via": "mcp"), and next steps are worded as tool
    # calls; the session's default owner lets them leave owner="..." out when it is the default.
    $psi.EnvironmentVariables['UNITY_SLOT_VIA'] = 'mcp'
    if ($script:Owner) { $psi.EnvironmentVariables['UNITY_SLOT_MCP_OWNER'] = $script:Owner }
    # stable = the id comes from the client's session id and survives a server restart (Claude Code)
    $psi.EnvironmentVariables['UNITY_SLOT_MCP_OWNER_STABLE'] = $(if ($script:OwnerStable) { '1' } else { '0' })
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $text = $outTask.Result.TrimEnd()
    $err = $errTask.Result.Trim()
    if ($err) { $text += "`n[stderr]`n" + $err }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text }
}

# Runs the official Unity CLI (only for close without saving). Its stderr carries hint lines; ignored.
function Invoke-UnityCliClose([string]$SlotOrPath, [int]$Timeout) {
    $cliExe = Join-Path $env:LOCALAPPDATA 'Unity\bin\unity.exe'
    if (-not (Test-Path -LiteralPath $cliExe)) { return [pscustomobject]@{ Code = 1; Text = "official Unity CLI not found at $cliExe" } }
    $path = $SlotOrPath
    $resolved = Invoke-UnitySlot @('slots', '-Json')
    try {
        foreach ($s in @((($resolved.Text -split "`n" | Where-Object { $_ -notmatch '^\[stderr\]' }) -join "`n" | ConvertFrom-Json).slots)) {
            if ([string]::Equals($s.name, $SlotOrPath, [StringComparison]::OrdinalIgnoreCase)) { $path = $s.path }
        }
    } catch { }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cliExe
    $psi.Arguments = 'close ' + (ConvertTo-ArgString @($path)) + ' --timeout ' + $Timeout + ' --json --no-banner --no-color --non-interactive'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [void]$errTask.Result
    $text = ('unity close (no save): exit {0}' -f $p.ExitCode) + "`n" + $outTask.Result.Trim()
    # The CLI does not report files; show what git sees now (nothing is reverted).
    $git = @(& git -C $path status --porcelain 2>$null)
    $text += "`n" + ('git after close: {0} changed entr(ies)' -f $git.Count)
    foreach ($g in ($git | Select-Object -First 40)) { $text += "`n  " + $g }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text }
}

function Invoke-Tool([string]$Name, $A) {
    switch ($Name) {
        'status' {
            if (Get-Arg $A 'dashboard' $false) {
                $level = 'basic'
                if ([string](Get-Arg $A 'git' 'basic') -eq 'full') { $level = 'full' }
                return Invoke-UnitySlot @('dashboard', '-Json', '-Git', $level)
            }
            if (Get-Arg $A 'processes' $false) { return Invoke-UnitySlot @('status', '-Json') }
            $cli = @('summary')
            if ([string](Get-Arg $A 'format' 'summary') -eq 'json') { $cli = @('slots', '-Json') }
            $slot = [string](Get-Arg $A 'slot' '')
            if ($slot) { $cli += $slot }
            $project = [string](Get-Arg $A 'project' '')
            if ($project) { $cli += @('-Project', $project) }
            return Invoke-UnitySlot $cli
        }
        'acquire' {
            $cli = @('acquire', [string](Get-Arg $A 'purpose' ''), '-Owner', [string](Get-Arg $A 'owner' $script:Owner))
            $hours = Get-Arg $A 'hours' $null
            if ($null -ne $hours) { $cli += @('-Hours', ([string](Limit ([double]$hours) 0.1 72))) }
            $project = [string](Get-Arg $A 'project' '')
            if ($project) { $cli += @('-Project', $project) }
            if (Get-Arg $A 'open' $true) { $cli += '-NoWait' } else { $cli += '-NoOpen' }
            return Invoke-UnitySlot $cli
        }
        'open' {
            $cli = @('open', [string](Get-Arg $A 'slot' ''), '-NoWait')
            $bt = [string](Get-Arg $A 'build_target' '')
            if ($bt) { $cli += @('-BuildTarget', $bt) }
            return Invoke-UnitySlot $cli
        }
        'wait_ready' {
            $t = [int](Limit ([double](Get-Arg $A 'timeout_sec' 45)) 1 55)
            return Invoke-UnitySlot @('wait', [string](Get-Arg $A 'slot' ''), '-TimeoutSec', [string]$t)
        }
        'close' {
            $t = [int](Limit ([double](Get-Arg $A 'timeout_sec' 60)) 5 240)
            if (Get-Arg $A 'discard_unsaved' $false) { return Invoke-UnityCliClose ([string](Get-Arg $A 'slot' '')) $t }
            return Invoke-UnitySlot @('close', [string](Get-Arg $A 'slot' ''), '-TimeoutSec', [string]$t)
        }
        'release' {
            $t = [int](Limit ([double](Get-Arg $A 'timeout_sec' 60)) 5 240)
            $cli = @('release', [string](Get-Arg $A 'slot' ''), '-Owner', [string](Get-Arg $A 'owner' $script:Owner), '-TimeoutSec', [string]$t)
            if (Get-Arg $A 'keep_open' $false) { $cli += '-KeepOpen' }
            return Invoke-UnitySlot $cli
        }
        'create' {
            $cli = @('new-clone', [string](Get-Arg $A 'purpose' ''))
            # no name argument: new clones get the generic <repo>-<n> name
            foreach ($pair in @(@('project', '-Project'), @('from', '-From'))) {
                $v = [string](Get-Arg $A $pair[0] '')
                if ($v) { $cli += @($pair[1], $v) }
            }
            # The first open is always left to open + wait_ready, so the dry-run plan says what confirm does.
            $cli += '-NoOpen'
            if (Get-Arg $A 'confirm' $false) { $cli += '-Apply' }
            return Invoke-UnitySlot $cli
        }
        default { throw "unknown tool: $Name" }
    }
}

# exit codes of unity-slot.ps1 that mean the call failed or was refused
$script:ErrorCodes = @(1, 3, 4)
$script:CodeNames = @{ 0 = 'ok'; 1 = 'error'; 2 = 'timed out, editor left running'; 3 = 'editor version not installed'
    4 = 'refused'; 5 = 'no free slot'; 6 = 'still starting' }

# Claude Code passes its session id (CLAUDE_CODE_SESSION_ID), so its owner id survives a server restart.
# Codex passes MCP servers only a fixed list of environment variables and Cursor documents no session or
# chat id (checked 2026-11-06), so other clients get a random id per server process; the lease records
# the client process and status explains leases of the same client name (lib\lease.ps1 Get-LeaseNotes).
function Get-OwnerId($ClientInfo) {
    $id = $env:CLAUDE_CODE_SESSION_ID
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        $script:OwnerStable = $true
        return ('claude:' + $id.Substring(0, [Math]::Min(8, $id.Length)))
    }
    $script:OwnerStable = $false
    $client = [string](Get-Prop $ClientInfo 'name')
    $client = ($client -replace '[^A-Za-z0-9_-]', '')
    if (-not $client) { $client = 'mcp' }
    return ('{0}:{1}' -f $client, [guid]::NewGuid().ToString('N').Substring(0, 6))
}

# ------------------------------------------------------------------ main loop

Write-Log ('started, cli ' + $script:Cli)
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    # A .NET parent whose console input encoding is UTF-8 writes a BOM before the first message.
    $line = $line.TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $msg = $null
    try { $msg = $line | ConvertFrom-Json } catch { Send-Error $null -32700 'parse error'; continue }
    $method = [string](Get-Prop $msg 'method')
    $hasId = $null -ne $msg.PSObject.Properties['id']
    $id = Get-Prop $msg 'id'
    if (-not $method) { continue }
    $params = Get-Prop $msg 'params'
    try {
        switch ($method) {
            'initialize' {
                $script:Owner = Get-OwnerId (Get-Prop $params 'clientInfo')
                $asked = [string](Get-Prop $params 'protocolVersion')
                $version = $script:Versions[0]
                if ($script:Versions -contains $asked) { $version = $asked }
                $script:Protocol = $version
                Write-Log ('initialize ' + $asked + ' -> ' + $version + ', owner ' + $script:Owner)
                Send-Result $id ([ordered]@{
                        protocolVersion = $version
                        capabilities    = [ordered]@{ tools = [ordered]@{ listChanged = $false } }
                        serverInfo      = [ordered]@{ name = 'unity-slot'; version = $script:ServerVersion }
                        instructions    = ('Unity editors on this PC are slots. Decide first whether the task needs the Unity ' +
                            'editor; if it does, pull or switch branches while it is closed, then call acquire(purpose, project) ' +
                            'before planning or research. It returns at once; while the editor starts, read code, research and ' +
                            'plan, but edit Unity assets or scripts only after READY. When you need the editor: wait_ready until ' +
                            'READY -> check Application.dataPath through the Unity MCP -> work -> release(slot). Tell the user ' +
                            'about "warn capacity" lines. Do not switch platforms, do not take slots leased by others, never ' +
                            'force anything; hand stalls to the user.')
                    })
            }
            'ping' { if ($hasId) { Send-Result $id ([ordered]@{}) } }
            'tools/list' {
                $list = $script:Tools
                # annotations came with protocol 2025-03-26; an older client gets the tools without them
                if ($script:Protocol -eq '2024-11-05') {
                    $list = @($script:Tools | ForEach-Object { [ordered]@{ name = $_.name; description = $_.description; inputSchema = $_.inputSchema } })
                }
                Send-Result $id ([ordered]@{ tools = $list })
            }
            'tools/call' {
                $name = [string](Get-Prop $params 'name')
                $arguments = Get-Prop $params 'arguments'
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-Tool $name $arguments
                $seconds = $watch.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                $label = $script:CodeNames[[int]$r.Code]
                if (-not $label) { $label = 'exit ' + $r.Code }
                Write-Log ('tools/call {0} {1}s exit {2}' -f $name, $seconds, $r.Code)
                $text = ('[unity-slot exit {0}: {1}, {2}s]' -f $r.Code, $label, $seconds) + "`n" + $r.Text
                Send-Result $id ([ordered]@{
                        content = @([ordered]@{ type = 'text'; text = $text })
                        isError = ($script:ErrorCodes -contains [int]$r.Code)
                    })
            }
            default {
                if ($hasId) { Send-Error $id -32601 ('method not found: ' + $method) }
            }
        }
    } catch {
        Write-Log ('error in ' + $method + ': ' + $_.Exception.Message)
        if ($hasId) {
            if ($method -eq 'tools/call') {
                Send-Result $id ([ordered]@{ content = @([ordered]@{ type = 'text'; text = ('unity-slot MCP error: ' + $_.Exception.Message) }); isError = $true })
            } else {
                Send-Error $id -32603 $_.Exception.Message
            }
        }
    }
}
Write-Log 'stdin closed, exiting'
