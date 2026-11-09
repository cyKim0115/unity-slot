# prepare: get one project ready on a PC in one go: a base clone, its first import, and agent clones.
# Dot-sourced by unity-slot.ps1. ASCII-only source.
#
#   unity-slot prepare <origin URL | owner/repo | slot | clone folder> [-Count 2] [-BuildTarget <platform>]
#                      [-CloneRoot <dir>] [-NoOpen] [-Apply]
#
# Dry run unless -Apply, like new-clone: it prints each step as done or still to do. With -Apply it does
# the steps that are left, in order, and stops at the first one that does not finish. Running it again
# goes on from there: every step looks at what is already there.
#   1. base clone: the registered slot or clone folder named, else git clone <origin> <root>\<repo>
#   2. register the base (the draft scan makes: no suffix = main, not for agents)
#   3. first open of the base (-BuildTarget when it has no Library yet), wait for READY, close. This
#      makes the Library the agent clones copy, so their first open does not import everything.
#   4. agent clones until the project has -Count agent slots of the base's platform (new-clone -From
#      <base>: copies the Library, registers, runs the afterClone hooks), each opened once and closed
#      (the afterFirstOpen hooks run at that READY) unless -NoOpen
# A clone prepare made or opened has <clone>\Logs\unity-slot-prepare.txt (pid 0, or the editor it
# started) until its first open and close are done; a later run finishes those. Any other open editor
# is someone's: prepare stops instead of closing it, and it leaves other slots alone.
# Never: switching a platform, killing a process, git pull, commits to the project repository.

$script:PrepareMarker = 'Logs\unity-slot-prepare.txt'

function Test-GitUrl([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    return ($v -match '^(https?|ssh|git|file)://' -or $v -match '^[^@/\\\s]+@[^/\\:\s]+:' -or $v -match '\.git[\\/]?$')
}

function Test-UnityFolder([string]$Dir) {
    return ((Test-Path -LiteralPath (Join-Path $Dir 'ProjectSettings\ProjectVersion.txt')) -and
        (Test-Path -LiteralPath (Join-Path $Dir 'Assets') -PathType Container))
}

# The pid prepare wrote when it started this clone's editor (0 = none).
function Get-PrepareMarkerPid([string]$Clone) {
    $file = Join-Path $Clone $script:PrepareMarker
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    try {
        $m = [regex]::Match([IO.File]::ReadAllText($file), 'pid=(\d+)')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch { }
    return 0
}

function Test-PrepareMarker([string]$Clone) { return (Test-Path -LiteralPath (Join-Path $Clone $script:PrepareMarker)) }

# A clone prepare made but has not opened yet: pid 0 until its first open.
function Set-PrepareMarker([string]$Clone) {
    $file = Join-Path $Clone $script:PrepareMarker
    try {
        $dir = Split-Path $file -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText($file, ('pid=0 created={0}' -f (Format-Time (Get-Date))))
    } catch { }
}

function Remove-PrepareMarker([string]$Clone) {
    $file = Join-Path $Clone $script:PrepareMarker
    if (Test-Path -LiteralPath $file) { try { Remove-Item -LiteralPath $file -Force } catch { } }
}

# A project's main slot when it has one, else (unless -MainOnly) its most recently used slot.
function Select-ProjectBaseSlot($Reg, [string]$ProjectKey, [string]$Filter, [bool]$MainOnly = $false) {
    $cands = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $Reg.slots) {
        if ($ProjectKey -and $s.project -ne $ProjectKey) { continue }
        if ($Filter -and -not (Test-SlotProject $s $Filter)) { continue }
        if (-not (Test-Path -LiteralPath $s.path -PathType Container)) { continue }
        $cands.Add($s)
    }
    if ($cands.Count -eq 0) { return $null }
    $projects = @($cands | ForEach-Object { $_.project } | Select-Object -Unique)
    if ($projects.Count -gt 1) { throw ('"{0}" matches {1} projects ({2}). Name one as owner/repo.' -f $Filter, $projects.Count, ($projects -join ', ')) }
    foreach ($s in $cands) { if (@($s.purposes) -contains 'main') { return $s } }
    if ($MainOnly) { return $null }
    return @($cands | Sort-Object @{ Expression = { Get-LastUsed $_.path }; Descending = $true })[0]
}

# Agent slots of a project and platform (the ones -Count counts).
function Get-PrepareAgentSlots($Reg, [string]$ProjectKey, [string]$Platform, [string]$BasePath) {
    foreach ($s in $Reg.slots) {
        if ($s.project -ne $ProjectKey -or -not $s.agentUse -or @($s.purposes) -contains 'main') { continue }
        if ($BasePath -and (Test-SamePath $s.path $BasePath)) { continue }
        if (-not $Platform -or -not [string]::Equals([string]$s.platform, $Platform, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $s.path -PathType Container)) { continue }
        $s
    }
}

# A slot prepare made or opened and has not finished: its editor (no lease) is the one prepare started,
# or it is closed and still marked (not with -NoOpen: then the first open is left for later).
function Test-PrepareUnfinished($Slot, $Snap) {
    if (-not (Test-PrepareMarker $Slot.path)) { return $false }
    $st = Get-SlotState $Slot $Snap
    if ($st.EditorPid -gt 0) { return ($null -eq $st.Lease -and (Get-PrepareMarkerPid $Slot.path) -eq $st.EditorPid) }
    return (-not $NoOpen)
}

# Opens a clone (or takes over the editor prepare started there before), waits for READY, closes it.
# $script:ExitCode tells how it went.
function Invoke-PrepareWarm([string]$Clone, [int]$OpenTimeout, [string]$BuildTargetName, [string]$Label) {
    # $Label is the slot name: leases are looked up by it
    $probe = [pscustomobject]@{ name = $Label; path = $Clone }
    $st = Get-SlotState $probe (Get-Snapshot)
    if ($st.EditorPid -gt 0) {
        if ($null -ne $st.Lease -or (Get-PrepareMarkerPid $Clone) -ne $st.EditorPid) {
            Say ('STOP    {0} is open (pid {1}) and prepare did not start it, or it is leased: someone is using it. Run prepare again after it is closed.' -f $Label, $st.EditorPid)
            $script:ExitCode = 4
            return
        }
        Say ('        {0}: the editor prepare started before (pid {1}) is still there; waiting for it' -f $Label, $st.EditorPid)
        Invoke-Wait $Clone $OpenTimeout
    } else {
        $script:StartedPidFile = $script:PrepareMarker
        $script:LastOpenPid = 0
        try { Invoke-Open $Clone $OpenTimeout $BuildTargetName } finally { $script:StartedPidFile = '' }
        if ($script:ExitCode -eq 0 -and (Get-PrepareMarkerPid $Clone) -ne $script:LastOpenPid) {
            Say ('note    {0} was opened by someone else meanwhile; leaving it open' -f $Label)
            Remove-PrepareMarker $Clone
            return
        }
    }
    if ($script:ExitCode -ne 0) {
        if ($script:ExitCode -eq 2 -or $script:ExitCode -eq 6) {
            Say ('STOP    {0} is not READY yet; the editor keeps running. Run the same prepare command again later: it waits for this editor and goes on.' -f $Label)
        } else {
            Say ('STOP    {0} did not open (exit {1}, see above).' -f $Label, $script:ExitCode)
        }
        return
    }
    # an agent may have acquired it while it started (an open slot without a lease is not free, a
    # closed one is): then it is theirs now
    $st = Get-SlotState $probe (Get-Snapshot)
    if ($null -ne $st.Lease) {
        Say ('note    {0} was leased by {1} meanwhile; leaving it open for them' -f $Label, $st.Lease.owner)
        Remove-PrepareMarker $Clone
        return
    }
    Invoke-Close $Clone
    if ($script:ExitCode -ne 0) {
        Say ('STOP    {0} did not close (exit {1}, see above). Nothing was killed; run prepare again after it is closed.' -f $Label, $script:ExitCode)
        return
    }
    Remove-PrepareMarker $Clone
}

function Invoke-Prepare {
    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw 'usage: unity-slot prepare <origin URL | owner/repo | slot | clone folder> [-Count 2] [-BuildTarget <platform>] [-CloneRoot <dir>] [-NoOpen] [-Apply]'
    }
    if ($Name) { throw 'prepare names its clones itself (<repo>-<number>); leave -Name out' }
    $value = $Target.Trim()
    $want = $Count
    if ($want -lt 0 -or $want -gt 9) { throw '-Count is the number of agent slots wanted, 0 to 9' }
    $reg = Read-Registry
    $snap = Get-Snapshot

    # ---- what the base is
    $root = $CloneRoot
    if (-not $root) { $root = Expand-SlotText ([string](Get-Setting 'cloneRoot')) $null }
    if (-not $root -and @($reg.scanRoots).Count -gt 0) { $root = [string]@($reg.scanRoots)[0] }
    $base = $null            # registered slot
    $basePath = ''
    $origin = ''
    $needClone = $false
    $stop = New-Object 'System.Collections.Generic.List[string]'

    $base = Find-Slot $reg $value
    if ($null -ne $base) {
        $basePath = $base.path
    } elseif ((Test-Path -LiteralPath $value -PathType Container) -and (Test-UnityFolder $value)) {
        $basePath = Get-CanonicalPath (Get-NormPath (Resolve-Path -LiteralPath $value).ProviderPath)
    } elseif (Test-GitUrl $value) {
        $origin = $value
        $key = Get-ProjectKey $origin
        # a registered main clone of that project is the base; other slots (agent, WebGL, ...) are not
        $base = Select-ProjectBaseSlot $reg $key '' $true
        if ($null -ne $base) {
            $basePath = $base.path
            Say ('note    {0} has a main slot already, {1}; using that clone as the base' -f $key, $base.name)
        } else {
            if (-not $root) { throw 'no clone root: pass -CloneRoot <folder> or set "cloneRoot" in the config' }
            $repoName = Get-RepoName $origin
            if (-not $repoName) { throw ('cannot tell the repository name from "{0}"' -f $origin) }
            $basePath = Join-Path $root $repoName
            if (Test-Path -LiteralPath $basePath) {
                if (-not (Test-UnityFolder $basePath)) {
                    $stop.Add(('{0} exists but is not a Unity project (a partial clone?). Ask the user before deleting or moving it.' -f $basePath))
                } else {
                    $there = [string](@(Invoke-Git $basePath @('remote', 'get-url', 'origin')) | Select-Object -First 1)
                    if ((Get-ProjectKey $there) -ne $key) { $stop.Add(('{0} exists and is a clone of {1}, not {2}' -f $basePath, $there, $key)) }
                }
                $base = Find-Slot $reg $basePath
            } else {
                $needClone = $true
            }
        }
    } else {
        $base = Select-ProjectBaseSlot $reg '' $value
        if ($null -eq $base) {
            throw ('no slot of "{0}" is registered and it is no clone folder. Pass the origin URL (for example https://github.com/owner/repo.git, or the SSH form) to clone it.' -f $value)
        }
        $basePath = $base.path
    }

    # ---- facts about the base (some only after the clone exists)
    $facts = $null
    if (-not $needClone -and (Test-Path -LiteralPath $basePath -PathType Container) -and (Test-UnityFolder $basePath)) { $facts = Get-CloneFacts $basePath $snap }
    if ($null -ne $facts -and $facts.Origin) { $origin = $facts.Origin }
    $projectKey = Get-ProjectKey $origin
    $platform = ''
    if ($null -ne $base -and $base.platform) { $platform = $base.platform }
    if (-not $platform -and $null -ne $facts) { $platform = $facts.Platform }
    $hasLibrary = (-not $needClone) -and (Test-Path -LiteralPath (Join-Path $basePath 'Library\EditorUserBuildSettings.asset'))
    $wanted = ''
    if ($BuildTarget) { $wanted = ConvertTo-PlatformName $BuildTarget }
    if ($wanted -and $platform -and $wanted -ne $platform) {
        $stop.Add(('the base opens as {0}; -BuildTarget {1} would switch its platform and reimport everything. Use a {1} clone or leave -BuildTarget out.' -f $platform, $wanted))
    }
    if (-not $platform) { $platform = $wanted }
    if (-not $platform -and ($want -gt 0 -or -not $NoOpen)) {
        $stop.Add('the platform is unknown (the base has no Library yet): pass -BuildTarget <platform>, for example Android, WebGL or Windows')
    }
    $baseState = $null
    if ($null -ne $base) { $baseState = Get-SlotState $base $snap }
    elseif (-not $needClone) { $baseState = Get-SlotState ([pscustomobject]@{ name = (Split-Path $basePath -Leaf); path = $basePath }) $snap }
    $baseOpenPid = 0
    if ($null -ne $baseState) { $baseOpenPid = $baseState.EditorPid }
    $baseOurs = ($baseOpenPid -gt 0 -and (Get-PrepareMarkerPid $basePath) -eq $baseOpenPid)

    $agents = @()
    if ($projectKey -and $platform) { $agents = @(Get-PrepareAgentSlots $reg $projectKey $platform $basePath) }
    $missing = [Math]::Max(0, $want - $agents.Count)
    $needWarmBase = (-not $NoOpen) -and ((-not $hasLibrary) -or $baseOurs)
    # agent clones prepare made or opened whose first open and close are not done yet
    $unfinished = @($agents | Where-Object { Test-PrepareUnfinished $_ $snap })
    if ($baseOpenPid -gt 0 -and -not $baseOurs -and ($missing -gt 0 -or ($needWarmBase -and -not $hasLibrary))) {
        $stop.Add(('the base {0} is open (pid {1}) and prepare did not start it. New clones copy its Library only while it is closed: close it first.' -f $basePath, $baseOpenPid))
    }

    # ---- the plan
    $baseName = Split-Path $basePath -Leaf
    if ($null -ne $base) { $baseName = $base.name }
    Say ('project {0}' -f $(if ($projectKey) { $projectKey } else { '?' }))
    if ($needClone) { Say ('base    {0} (to clone from {1})' -f $basePath, $origin) }
    else { Say ('base    {0}: {1}' -f $baseName, $(if ($null -ne $baseState) { $baseState.Text } else { 'missing' })) }
    $platformText = '?'
    if ($platform) {
        $platformText = $platform
        if ($hasLibrary) { $platformText += ' (Library)' } elseif ($wanted) { $platformText += ' (-BuildTarget, first open)' }
    }
    Say ('platform {0}' -f $platformText)
    $agentNames = @($agents | ForEach-Object { $_.name })
    Say ('agents  {0} of {1} agent slot(s) of this platform{2}' -f $agents.Count, $want, $(if ($agentNames.Count -gt 0) { ': ' + ($agentNames -join ', ') } else { '' }))
    Say 'plan:'
    if ($needClone) { Say ('  1. git clone {0} "{1}"' -f $origin, $basePath) } else { Say '  1. (done) base clone' }
    if ($null -eq $base) { Say ('  2. register {0} (draft purposes from the folder name, as scan does)' -f (Split-Path $basePath -Leaf)) }
    else { Say ('  2. (done) registered as {0} ({1}, agent use {2})' -f $base.name, (@($base.purposes) -join ','), $base.agentUse.ToString().ToLowerInvariant()) }
    if ($NoOpen) { Say '  3. (skipped: -NoOpen) first open of the base; without a Library each new clone imports everything on its first open' }
    elseif ($baseOurs) { Say '  3. wait for the base editor prepare started before, then close it' }
    elseif ($hasLibrary) { Say '  3. (done) the base has a Library' }
    else {
        Say ('  3. first open of the base with -BuildTarget {0} (waits up to {1} min: everything is imported once), then close it' -f `
            (Get-BuildTargetName $platform), [int]((Get-TimeoutSetting 'firstOpen' 2400) / 60))
    }
    foreach ($u in $unfinished) { Say ('  4. finish {0}: prepare made it; its first open and close are not done yet' -f $u.name) }
    if ($missing -gt 0) {
        $each = 'each opened once (Library copied: up to {0} min) and closed' -f [int]((Get-TimeoutSetting 'firstOpenWithLibrary' 900) / 60)
        if ($NoOpen) { $each = 'first open later (-NoOpen)' }
        Say ('  4. new-clone agent -From {0}, {1} time(s): <repo>-<smallest free number>, Library copy, afterClone hooks; {2}' -f $baseName, $missing, $each)
    } elseif ($unfinished.Count -eq 0) { Say ('  4. (done) {0} agent slot(s)' -f $agents.Count) }

    if ($stop.Count -gt 0) {
        foreach ($s in $stop) { Say ('STOP    ' + $s) }
        $script:ExitCode = 4
        return
    }
    if (-not $Apply) {
        Say 'dry-run: nothing was done. Show this plan to the user; after they agree, run the same command with -Apply (it can take long: cloning, then the first import).'
        return
    }

    # ---- 1. clone
    if ($needClone) {
        Say ('apply   1 git clone into {0}' -f $basePath)
        $parent = Split-Path $basePath -Parent
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = @(& git clone --quiet $origin $basePath 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        if ($code -ne 0) {
            foreach ($l in $out) { Say ('  ' + (Protect-Text ([string]$l))) }
            Say ('FAILED: git clone exit {0}. A partial folder may be left at {1}; ask the user before deleting it.' -f $code, $basePath)
            $script:ExitCode = 1
            return
        }
        if (-not (Test-UnityFolder $basePath)) {
            Say ('FAILED: {0} has no ProjectSettings\ProjectVersion.txt and Assets: not a Unity project at the repository root' -f $basePath)
            $script:ExitCode = 1
            return
        }
        $basePath = Get-CanonicalPath $basePath
    }

    # ---- 2. register
    $reg = Read-Registry
    $base = Find-Slot $reg $basePath
    if ($null -eq $base) {
        Say 'apply   2 register'
        $facts = Get-CloneFacts $basePath (Get-Snapshot)
        $base = New-SlotRecord (New-SlotName $reg $basePath) $basePath
        Set-DetectedFields $base $facts
        Set-DraftFields $base $facts
        if (-not $base.platform -and $wanted) { $base.platform = $wanted; $base.platformSource = 'prepare -BuildTarget' }
        $reg.slots.Add($base)
        Write-Registry $reg
        Say ('        slot {0}: {1}, purposes {2}, agent use {3}' -f $base.name, $(if ($base.platform) { $base.platform } else { '?' }), (@($base.purposes) -join ','), $base.agentUse.ToString().ToLowerInvariant())
    }
    $baseName = $base.name
    $projectKey = $base.project

    # ---- 3. first open of the base
    $hasLibrary = Test-Path -LiteralPath (Join-Path $basePath 'Library\EditorUserBuildSettings.asset')
    $st = Get-SlotState $base (Get-Snapshot)
    $baseOurs = ($st.EditorPid -gt 0 -and (Get-PrepareMarkerPid $basePath) -eq $st.EditorPid)
    if (-not $NoOpen -and (-not $hasLibrary -or $baseOurs)) {
        Say ('apply   3 first open of {0}' -f $baseName)
        $bt = ''
        if (-not $hasLibrary) { $bt = Get-BuildTargetName $platform }
        Invoke-PrepareWarm $basePath (Get-TimeoutSetting 'firstOpen' 2400) $bt $baseName
        if ($script:ExitCode -ne 0) { return }
        $reg = Read-Registry
        $base = Find-Slot $reg $basePath
        Set-DetectedFields $base (Get-CloneFacts $basePath (Get-Snapshot))
        Write-Registry $reg
    }
    if ($base.platform) { $platform = $base.platform }

    # ---- 4. agent clones
    $reg = Read-Registry
    $agents = @(Get-PrepareAgentSlots $reg $projectKey $platform $basePath)
    if (-not $NoOpen) {
        foreach ($a in $agents) {
            if (-not (Test-PrepareUnfinished $a (Get-Snapshot))) { continue }
            Say ('apply   4 finish {0}' -f $a.name)
            Invoke-PrepareWarm $a.path (Get-TimeoutSetting 'firstOpenWithLibrary' 900) '' $a.name
            if ($script:ExitCode -ne 0) { return }
        }
    }
    $missing = [Math]::Max(0, $want - $agents.Count)
    for ($i = 1; $i -le $missing; $i++) {
        Say ('apply   4 agent clone {0} of {1}' -f $i, $missing)
        $before = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($s in (Read-Registry).slots) { [void]$before.Add([string]$s.name) }
        $keep = @{ Target = $Target; From = $From; NoOpen = $NoOpen }
        $script:Target = 'agent'
        $script:From = $baseName
        $script:NoOpen = [switch]$true
        try { Invoke-NewClone } finally { $script:Target = $keep.Target; $script:From = $keep.From; $script:NoOpen = $keep.NoOpen }
        if ($script:ExitCode -ne 0) { Say ('STOP    new-clone did not finish (exit {0}, see above)' -f $script:ExitCode); return }
        $new = $null
        foreach ($s in (Read-Registry).slots) { if (-not $before.Contains([string]$s.name)) { $new = $s } }
        if ($null -eq $new) { Say 'STOP    new-clone reported no new slot'; $script:ExitCode = 1; return }
        Set-PrepareMarker $new.path
        if (-not $NoOpen) {
            Invoke-PrepareWarm $new.path (Get-TimeoutSetting 'firstOpenWithLibrary' 900) (Get-BuildTargetName $platform) $new.name
            if ($script:ExitCode -ne 0) { return }
        }
    }

    $reg = Read-Registry
    $agents = @(Get-PrepareAgentSlots $reg $projectKey $platform $basePath)
    Say ('DONE    {0}: base {1}, {2} agent slot(s) of {3}: {4}' -f $projectKey, $baseName, $agents.Count, $platform, ((@($agents | ForEach-Object { $_.name })) -join ', '))
    Say ('next    unity-slot slots -Project {0}; agents take one with acquire agent -Project {0}' -f $projectKey)
}
