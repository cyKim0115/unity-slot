# Slot registry: which Unity clones exist on this PC, what they are for, and what was detected
# about them. Dot-sourced by unity-slot.ps1. ASCII-only source (see AGENTS.md).
#
# Location: $env:UNITY_SLOT_HOME, else %USERPROFILE%\.unity-slot (not under AppData: the Claude
# desktop app's shell virtualizes AppData writes).
#   slots.json          registry (user fields: purposes, mode, agentUse, memo; detected: the rest)
#   leases\<slot>.json  one file per leased slot (lib\lease.ps1)

$script:PlatformGroups = @('Android', 'WebGL', 'Standalone', 'iOS', 'tvOS', 'VisionOS', 'PS4', 'PS5', 'XboxOne',
    'GameCoreXboxSeries', 'GameCoreXboxOne', 'Switch', 'LinuxHeadlessSimulation', 'EmbeddedLinux', 'QNX')

function Get-SlotHome {
    $dir = $env:UNITY_SLOT_HOME
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:USERPROFILE '.unity-slot' }
    return $dir
}

function Get-RegistryPath { return (Join-Path (Get-SlotHome) 'slots.json') }

# Scan roots: the config's "scanRoots" (folders that hold clones), else what the registry saved.
function Get-DefaultScanRoots {
    @(Get-ExpandedList (Get-Setting 'scanRoots') | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function New-SlotRecord([string]$SlotName, [string]$SlotPath) {
    return [pscustomobject][ordered]@{
        name           = $SlotName
        path           = $SlotPath
        project        = ''
        repo           = ''
        origin         = ''
        kind           = ''
        unity          = ''
        branch         = ''
        platform       = ''
        platformSource = ''
        purposes       = [string[]]@()
        mode           = 'ondemand'
        agentUse       = $true
        memo           = ''
        detectedAt     = ''
        # hook events still to run for this slot (new-clone: afterFirstOpen until the first READY)
        pendingHooks   = [string[]]@()
    }
}

function Read-Registry {
    $reg = [pscustomobject][ordered]@{
        version    = 1
        updatedAt  = ''
        maxEditors = 6
        scanRoots  = [string[]]@()
        slots      = New-Object 'System.Collections.Generic.List[object]'
    }
    $file = Get-RegistryPath
    if (Test-Path -LiteralPath $file) {
        $data = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($k in 'updatedAt', 'maxEditors', 'scanRoots') {
            $v = Get-Prop $data $k
            if ($null -ne $v) { $reg.$k = $v }
        }
        foreach ($s in @(Get-Prop $data 'slots')) {
            if ($null -eq $s) { continue }
            $rec = New-SlotRecord ([string](Get-Prop $s 'name')) ([string](Get-Prop $s 'path'))
            foreach ($p in @($rec.PSObject.Properties)) {
                $v = Get-Prop $s $p.Name
                if ($null -ne $v) { $rec.($p.Name) = $v }
            }
            $rec.purposes = [string[]]@(@($rec.purposes) | Where-Object { $_ })
            $rec.pendingHooks = [string[]]@(@($rec.pendingHooks) | Where-Object { $_ })
            $rec.agentUse = [bool]$rec.agentUse
            $reg.slots.Add($rec)
        }
    }
    # The config wins over what an older registry saved.
    $roots = @(Get-DefaultScanRoots)
    if ($roots.Count -gt 0) { $reg.scanRoots = $roots }
    $reg.scanRoots = [string[]]@(@($reg.scanRoots) | Where-Object { $_ })
    $max = [int](Get-Setting 'maxEditors')
    if ($max -gt 0) { $reg.maxEditors = $max }
    return $reg
}

function Write-Registry($Reg) {
    $dir = Get-SlotHome
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $Reg.updatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $script:Inv)
    $slots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $Reg.slots) {
        $copy = New-SlotRecord $s.name $s.path
        foreach ($p in @($copy.PSObject.Properties)) { $copy.($p.Name) = $s.($p.Name) }
        $copy.purposes = [string[]]@(@($s.purposes) | Where-Object { $_ })
        $copy.pendingHooks = [string[]]@(@($s.pendingHooks) | Where-Object { $_ })
        $copy.agentUse = [bool]$s.agentUse
        $slots.Add($copy)
    }
    $out = [pscustomobject][ordered]@{
        version    = 1
        updatedAt  = $Reg.updatedAt
        maxEditors = [int]$Reg.maxEditors
        scanRoots  = [string[]]@($Reg.scanRoots)
        slots      = $slots.ToArray()
    }
    $file = Get-RegistryPath
    $tmp = $file + '.tmp'
    [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

function Find-Slot($Reg, [string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    foreach ($s in $Reg.slots) {
        if ([string]::Equals($s.name, $Key.Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $s }
    }
    $full = $null
    try { $full = Get-NormPath ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Key)) } catch { }
    if ($full) {
        foreach ($s in $Reg.slots) { if (Test-SamePath $s.path $full) { return $s } }
    }
    return $null
}

# ------------------------------------------------------------------ detection

function Get-ProjectKey([string]$Origin) {
    if ([string]::IsNullOrWhiteSpace($Origin)) { return '' }
    $m = [regex]::Match($Origin.Trim(), '[:/\\]([^/:\\]+)[/\\]([^/\\]+?)(?:\.git)?[/\\]?$')
    if ($m.Success) { return ($m.Groups[1].Value + '/' + $m.Groups[2].Value).ToLowerInvariant() }
    return $Origin.Trim().ToLowerInvariant()
}

function Get-RepoName([string]$Origin) {
    if ([string]::IsNullOrWhiteSpace($Origin)) { return '' }
    $m = [regex]::Match($Origin.Trim(), '[/\\:]([^/\\:]+?)(?:\.git)?[/\\]?$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function ConvertTo-PlatformName([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $r = $Raw.Trim()
    # extra names from the config ("platformAliases": { "mobile": "Android" })
    $aliases = Get-Setting 'platformAliases'
    if ($null -ne $aliases) {
        foreach ($p in $aliases.PSObject.Properties) {
            if ([string]::Equals($p.Name, $r, [StringComparison]::OrdinalIgnoreCase) -and $p.Value) { $r = [string]$p.Value; break }
        }
    }
    if ($r -match '^(?i)(web|webgl|html5)$') { return 'WebGL' }
    if ($r -match '^(?i)(standalone|windows|win|win64|pc|standalonewindows64|windows, mac, linux)$') { return 'Windows' }
    if ($r -match '^(?i)android$') { return 'Android' }
    if ($r -match '^(?i)ios$') { return 'iOS' }
    return $r
}

# -buildTarget value for a platform name used in the registry.
function Get-BuildTargetName([string]$Platform) {
    switch ($Platform) {
        'WebGL' { return 'WebGL' }
        'Windows' { return 'StandaloneWindows64' }
        'Android' { return 'Android' }
        'iOS' { return 'iOS' }
        default { return $Platform }
    }
}

# Editor main window title: "<project> - <scene> - <platform> - Unity 6.6 (6000.6.0f1) <DX12>".
function Get-PlatformFromTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $m = [regex]::Matches($Title, ' - ([^-]+?) - Unity \d')
    if ($m.Count -eq 0) { return '' }
    return (ConvertTo-PlatformName $m[$m.Count - 1].Groups[1].Value)
}

function Get-EditorTitle([int]$EditorPid) {
    foreach ($w in @(Get-ProcessWindows $EditorPid)) {
        $m = [regex]::Match($w, 'title="(.* - Unity \d.*)"')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# Library\EditorUserBuildSettings.asset is a binary serialized file. After the type tree (whose last
# field name is "settings") the first string that is a build platform group name is
# m_ActiveBuildPlatformGroupName, the platform the editor opens with. Checked on 11-06 against the
# window titles of every open editor. Library\PlayerDataCache only shows the last player build.
function Get-PlatformFromLibrary([string]$Clone) {
    $file = Join-Path $Clone 'Library\EditorUserBuildSettings.asset'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file))
    $afterTypeTree = $false
    foreach ($run in [regex]::Matches($text, '[\x20-\x7E]{3,}')) {
        $v = $run.Value
        if (-not $afterTypeTree) { if ($v -ceq 'settings') { $afterTypeTree = $true }; continue }
        if ($script:PlatformGroups -ccontains $v) { return (ConvertTo-PlatformName $v) }
    }
    return ''
}

function Get-CloneFacts([string]$Clone, $Snap) {
    $origin = [string](@(Invoke-Git $Clone @('remote', 'get-url', 'origin')) | Select-Object -First 1)
    $branch = [string](@(Invoke-Git $Clone @('rev-parse', '--abbrev-ref', 'HEAD')) | Select-Object -First 1)
    $kind = 'clone'
    if (Test-Path -LiteralPath (Join-Path $Clone '.git') -PathType Leaf) { $kind = 'worktree' }
    $unity = ''
    try { $unity = Get-EditorVersion $Clone } catch { }
    $editorPid = 0
    $editors = @(Get-OpenFor $Snap $Clone | Where-Object { $_.Kind -eq 'editor' })
    if ($editors.Count -gt 0) { $editorPid = $editors[0].Pid }
    $platform = ''
    $source = ''
    if ($editorPid -gt 0) {
        $platform = Get-PlatformFromTitle (Get-EditorTitle $editorPid)
        if ($platform) { $source = 'window title' }
    }
    if (-not $platform) {
        $platform = Get-PlatformFromLibrary $Clone
        if ($platform) { $source = 'Library settings' }
    }
    return [pscustomobject]@{
        Origin         = $origin
        Project        = (Get-ProjectKey $origin)
        Repo           = (Get-RepoName $origin)
        Branch         = $branch
        Kind           = $kind
        Unity          = $unity
        Platform       = $platform
        PlatformSource = $source
        EditorPid      = $editorPid
        LastUsed       = (Get-LastUsed $Clone)
    }
}

function Get-LastUsed([string]$Clone) {
    foreach ($rel in 'Logs\Editor.log', 'Library') {
        $p = Join-Path $Clone $rel
        if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p -Force).LastWriteTime }
    }
    return [datetime]::MinValue
}

function Set-DetectedFields($Rec, $Facts) {
    $Rec.project = $Facts.Project
    $Rec.repo = $Facts.Repo
    $Rec.origin = $Facts.Origin
    $Rec.kind = $Facts.Kind
    $Rec.unity = $Facts.Unity
    $Rec.branch = $Facts.Branch
    if ($Facts.Platform) { $Rec.platform = $Facts.Platform; $Rec.platformSource = $Facts.PlatformSource }
    $Rec.detectedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $script:Inv)
}

# First guess at what a clone is for, from its folder name and platform (config "purposeRules").
# The user confirms it. The folder name without the repository name is the suffix:
#   none (and a real clone)  -> main, not for agents   (mainWhenNoSuffix)
#   matches a suffix rule    -> that rule's purposes   (suffix: [{ pattern, purposes }], first match)
#   platform                 -> its purposes           (platform: { WebGL: [...] })
#   nothing above            -> fallback
function Set-DraftFields($Rec, $Facts) {
    $rules = Get-Setting 'purposeRules'
    $leaf = Split-Path $Rec.path -Leaf
    $suffix = $leaf
    if ($Facts.Repo -and $leaf.StartsWith($Facts.Repo, [StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $leaf.Substring($Facts.Repo.Length).TrimStart('-', '_', ' ')
    }
    $purposes = New-Object 'System.Collections.Generic.List[string]'
    $agent = $true
    if ($suffix -eq '' -and $Facts.Kind -eq 'clone' -and (Get-Prop $rules 'mainWhenNoSuffix') -ne $false) {
        $purposes.Add('main'); $agent = $false
    } else {
        foreach ($rule in @(Get-Prop $rules 'suffix')) {
            $pattern = [string](Get-Prop $rule 'pattern')
            if ($pattern -and [regex]::IsMatch($suffix, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                foreach ($p in @(Get-SettingList (Get-Prop $rule 'purposes'))) { $purposes.Add($p.ToLowerInvariant()) }
                break
            }
        }
    }
    if ($Facts.Platform) {
        foreach ($p in @(Get-SettingList (Get-Prop (Get-Prop $rules 'platform') $Facts.Platform))) { $purposes.Add($p.ToLowerInvariant()) }
    }
    if ($purposes.Count -eq 0) {
        foreach ($p in @(Get-SettingList (Get-Prop $rules 'fallback'))) { $purposes.Add($p.ToLowerInvariant()) }
    }
    $Rec.purposes = [string[]]@($purposes | Select-Object -Unique)
    $Rec.mode = 'ondemand'
    $Rec.agentUse = $agent
}

function New-SlotName($Reg, [string]$SlotPath) {
    $leaf = Split-Path $SlotPath -Leaf
    $candidate = $leaf
    for ($n = 2; $null -ne (Find-SlotByName $Reg $candidate); $n++) { $candidate = '{0}~{1}' -f $leaf, $n }
    return $candidate
}

function Find-SlotByName($Reg, [string]$SlotName) {
    foreach ($s in $Reg.slots) { if ([string]::Equals($s.name, $SlotName, [StringComparison]::OrdinalIgnoreCase)) { return $s } }
    return $null
}

# A slot fits a need when the need is one of its purposes or names its platform (webgl, android, windows...).
function Test-SlotNeed($Slot, [string]$Need) {
    if ([string]::IsNullOrWhiteSpace($Need)) { return $true }
    $n = $Need.Trim()
    if (@($Slot.purposes) -contains $n) { return $true }
    $platform = ConvertTo-PlatformName $n
    return ($Slot.platform -and [string]::Equals($Slot.platform, $platform, [StringComparison]::OrdinalIgnoreCase))
}

function Get-ProjectFilters {
    @(@($Project) | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ProjectFilter {
    $all = @(Get-ProjectFilters)
    if ($all.Count -eq 0) { return '' }
    return [string]$all[0]
}

# -Project accepts owner/repo, repo, or the end of either (case-insensitive).
function Test-SlotProject($Slot, [string]$Filter) {
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
    $f = $Filter.Trim().ToLowerInvariant()
    $key = ([string]$Slot.project).ToLowerInvariant()
    $repo = ([string]$Slot.repo).ToLowerInvariant()
    return ($key -eq $f) -or ($repo -eq $f) -or $key.EndsWith('/' + $f) -or $repo.EndsWith('-' + $f) -or $repo.EndsWith('_' + $f)
}

function Get-SlotState($Slot, $Snap) {
    $exists = Test-Path -LiteralPath $Slot.path -PathType Container
    $open = @()
    if ($exists) { $open = @(Get-OpenFor $Snap $Slot.path) }
    $editor = @($open | Where-Object { $_.Kind -eq 'editor' })
    $batch = @($open | Where-Object { $_.Kind -eq 'batch' })
    $editorPid = 0
    if ($editor.Count -gt 0) { $editorPid = $editor[0].Pid }
    $text = 'closed'
    if (-not $exists) { $text = 'missing' }
    elseif ($batch.Count -gt 0) { $text = 'batch pid ' + $batch[0].Pid }
    elseif ($editorPid -gt 0) { $text = 'open pid ' + $editorPid }
    return [pscustomobject]@{
        Exists    = $exists
        EditorPid = $editorPid
        Batch     = ($batch.Count -gt 0)
        Lease     = (Get-SlotLease $Slot.name)
        Text      = $text
    }
}

function Format-Lease($Lease) {
    if ($null -eq $Lease) { return '-' }
    $until = '?'
    if ($null -ne $Lease.expiresAt) { $until = ([datetime]$Lease.expiresAt).ToString('MM-dd HH:mm', $script:Inv) }
    $flag = ''
    if ($Lease.Expired) { $flag = ' EXPIRED' }
    return ('{0} until {1}{2}' -f $Lease.owner, $until, $flag)
}

# ------------------------------------------------------------------ commands

function Invoke-Scan {
    $reg = Read-Registry
    $snap = Get-Snapshot
    $roots = @(@($ScanRoot) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($roots.Count -gt 0) { $reg.scanRoots = [string[]]$roots }
    else { $roots = @($reg.scanRoots) }
    if ($roots.Count -eq 0 -and $reg.slots.Count -eq 0) {
        Say 'no scan roots: pass -ScanRoot <folder that holds the clones>[,...] or set "scanRoots" in the config'
    }
    $filters = @(Get-ProjectFilters)
    $known = @($reg.slots | ForEach-Object { $_.project } | Where-Object { $_ } | Select-Object -Unique)

    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $roots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ((Test-Path -LiteralPath (Join-Path $d.FullName 'ProjectSettings\ProjectVersion.txt')) -and
                (Test-Path -LiteralPath (Join-Path $d.FullName 'Assets') -PathType Container)) {
                $paths.Add((Get-CanonicalPath $d.FullName))
            }
        }
    }
    foreach ($s in $reg.slots) {
        $seen = $false
        foreach ($p in $paths) { if (Test-SamePath $p $s.path) { $seen = $true } }
        if (-not $seen) { $paths.Add($s.path) }
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $changed = 0
    foreach ($p in $paths) {
        $existing = $null
        foreach ($s in $reg.slots) { if (Test-SamePath $s.path $p) { $existing = $s } }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            $rows.Add(@('missing', $existing.name, $existing.project, '', '', '', '', $p))
            continue
        }
        $facts = Get-CloneFacts $p $snap
        $action = ''
        $rec = $existing
        if ($null -ne $existing) {
            Set-DetectedFields $existing $facts
            $action = 'update'
            $changed++
        } else {
            $match = $false
            if ($filters.Count -gt 0) {
                foreach ($f in $filters) { if (Test-SlotProject ([pscustomobject]@{ project = $facts.Project; repo = $facts.Repo }) $f) { $match = $true } }
            } else {
                $match = ($known -contains $facts.Project)
            }
            if ($match) {
                $rec = New-SlotRecord (New-SlotName $reg $p) $p
                Set-DetectedFields $rec $facts
                Set-DraftFields $rec $facts
                $reg.slots.Add($rec)
                $action = 'add'
                $changed++
            } else {
                $action = 'not registered'
            }
        }
        if ($null -ne $rec) {
            $platform = $rec.platform
            if ($rec.platformSource) { $platform = '{0} ({1})' -f $rec.platform, $rec.platformSource }
            $rows.Add(@($action, $rec.name, $rec.project, $platform, $rec.branch, $rec.kind, ((@($rec.purposes) -join ',') + ' / ' + $rec.mode + ' / agent ' + $rec.agentUse.ToString().ToLowerInvariant()), $p))
        } else {
            $platform = $facts.Platform
            if ($facts.PlatformSource) { $platform = '{0} ({1})' -f $facts.Platform, $facts.PlatformSource }
            $rows.Add(@($action, (Split-Path $p -Leaf), $facts.Project, $platform, $facts.Branch, $facts.Kind, '', $p))
        }
    }
    Write-TextTable @('Action', 'Name', 'Project', 'Platform (source)', 'Branch', 'Kind', 'Purposes / mode / agent', 'Path') $rows
    if ($Apply) {
        Write-Registry $reg
        Say ('saved   {0} slot(s) in {1}' -f $reg.slots.Count, (Get-RegistryPath))
    } else {
        Say ('dry-run: nothing saved ({0} slot(s) would be added or updated). Add -Apply to save to {1}' -f $changed, (Get-RegistryPath))
        if ($filters.Count -eq 0 -and $known.Count -eq 0) { Say 'first run: pass -Project <owner/repo>[,<owner/repo>] to choose which projects to register' }
    }
}

function Invoke-Slots {
    $reg = Read-Registry
    if ($reg.slots.Count -eq 0) {
        Say ('no slots registered yet ({0}). Run: unity-slot scan -Project <owner/repo> -Apply' -f (Get-RegistryPath))
        return
    }
    $snap = Get-Snapshot
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $reg.slots) {
        $st = Get-SlotState $s $snap
        $rows.Add(@($s.name, $s.platform, $s.branch, $s.mode, $s.agentUse.ToString().ToLowerInvariant(), (@($s.purposes) -join ','), $st.Text, (Format-Lease $st.Lease), $s.project))
        $leaseOut = $null
        if ($null -ne $st.Lease) {
            $leaseOut = [pscustomobject]@{ owner = $st.Lease.owner; expiresAt = (Format-Time $st.Lease.expiresAt); expired = $st.Lease.Expired; need = $st.Lease.need }
        }
        $items.Add([pscustomobject]@{
            name = $s.name; path = $s.path; project = $s.project; platform = $s.platform; branch = $s.branch; kind = $s.kind
            purposes = [string[]]@($s.purposes); mode = $s.mode; agentUse = [bool]$s.agentUse; memo = $s.memo
            state = $st.Text; editorPid = $st.EditorPid; lease = $leaseOut
        })
    }
    if ($Json) {
        [pscustomobject]@{ registry = (Get-RegistryPath); maxEditors = [int]$reg.maxEditors; slots = $items.ToArray() } | ConvertTo-Json -Depth 5
        return
    }
    Write-TextTable @('Name', 'Platform', 'Branch', 'Mode', 'Agent', 'Purposes', 'State', 'Lease', 'Project') $rows
    $editors = @($snap.Unity | Where-Object { $_.Kind -eq 'editor' }).Count
    Say ('editors {0} open of max {1}; registry {2}' -f $editors, $reg.maxEditors, (Get-RegistryPath))
    foreach ($s in $reg.slots) { if ($s.memo) { Say ('memo    {0}: {1}' -f $s.name, $s.memo) } }
}

function Invoke-Set {
    $reg = Read-Registry
    $slot = Find-Slot $reg $Target
    if ($null -eq $slot) { throw ('no registered slot named or located at "{0}". See: unity-slot slots' -f $Target) }
    $purposes = @(@($Purpose) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($purposes.Count -gt 0) { $slot.purposes = [string[]]@($purposes | Select-Object -Unique) }
    if ($Mode) { $slot.mode = $Mode }
    if ($AgentUse) { $slot.agentUse = ($AgentUse -eq 'true') }
    if ($script:Bound.ContainsKey('Memo')) { $slot.memo = $Memo }
    if ($BuildTarget) { $slot.platform = ConvertTo-PlatformName $BuildTarget; $slot.platformSource = 'set by hand' }
    Write-Registry $reg
    Say ('saved   {0}: purposes {1}; mode {2}; agentUse {3}; platform {4}; memo "{5}"' -f $slot.name, (@($slot.purposes) -join ','), $slot.mode, $slot.agentUse.ToString().ToLowerInvariant(), $slot.platform, $slot.memo)
}
