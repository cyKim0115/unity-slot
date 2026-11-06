# new-clone: make another slot when no fitting slot is free. Dot-sourced by unity-slot.ps1.
# ASCII-only source.
#
# Default is a dry run that only prints the plan and its checks. -Apply runs it, and only after the
# user agreed to that plan. Steps:
#   1. git clone --reference <template repo> --dissociate --branch <template branch> <origin> <root>\<name>
#      (a clone, not a worktree: a worktree cannot check out a branch another worktree has, and
#       slots often share a branch; --reference makes it quick, --dissociate keeps it independent)
#   2. copy Library from the template while the template is closed (avoids a cold import)
#   3. register the slot (template purposes without the config's "notCopiedToNewClone", on demand,
#      agent use); the afterFirstOpen hooks wait in the record until its editor is first READY
#   4. afterClone hooks (config), e.g. linking shared folders or writing agent instructions
#   5. first open with -buildTarget <template platform>; when it is READY the afterFirstOpen hooks run
# Never: git clean -x / -X, git stash -a, commits to the project repository, switching a platform.

function Get-DirSize([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return [long]0 }
    $total = [long]0
    try {
        foreach ($f in (New-Object IO.DirectoryInfo($Dir)).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $total += $f.Length }
    } catch {
        return [long]-1
    }
    return $total
}

function Get-TrackedSize([string]$Clone) {
    $total = [long]0
    foreach ($line in @(Invoke-Git $Clone @('ls-tree', '-r', '-l', 'HEAD'))) {
        $m = [regex]::Match([string]$line, '^\S+ blob \S+\s+(\d+)\t')
        if ($m.Success) { $total += [long]$m.Groups[1].Value }
    }
    return $total
}

function Get-GitObjectSize([string]$Clone) {
    $total = [long]0
    foreach ($line in @(Invoke-Git $Clone @('count-objects', '-v'))) {
        $m = [regex]::Match([string]$line, '^(size|size-pack): (\d+)$')
        if ($m.Success) { $total += [long]$m.Groups[2].Value * 1KB }
    }
    return $total
}

function Get-ReferenceRepo([string]$Clone) {
    $common = [string](@(Invoke-Git $Clone @('rev-parse', '--git-common-dir')) | Select-Object -First 1)
    if (-not $common) { return '' }
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $Clone $common }
    return (Get-NormPath $common)
}

function Get-NextCloneName($Reg, [string]$RepoName, [string]$Root) {
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Reg.slots) { [void]$used.Add((Split-Path $s.path -Leaf)); [void]$used.Add($s.name) }
    foreach ($r in @(@($Reg.scanRoots) + $Root)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) { [void]$used.Add($d.Name) }
    }
    for ($n = 1; $n -lt 100; $n++) {
        $candidate = '{0}-{1}' -f $RepoName, $n
        if (-not $used.Contains($candidate)) { return $candidate }
    }
    throw "no free name for $RepoName"
}

function Invoke-NewClone {
    if ([string]::IsNullOrWhiteSpace($Target)) { throw 'usage: unity-slot new-clone <purpose or platform> [-Project <repo>] [-From <slot>] [-Name <folder>] [-Apply]' }
    $need = $Target.Trim()
    $projectFilter = Get-ProjectFilter
    $reg = Read-Registry
    $snap = Get-Snapshot

    # template: -From, else a closed slot of that purpose (most recently used first)
    $template = $null
    if ($From) {
        $template = Find-Slot $reg $From
        if ($null -eq $template) { throw ('no registered slot "{0}"' -f $From) }
    } else {
        $cands = @($reg.slots | Where-Object { (Test-SlotNeed $_ $need) -and (Test-SlotProject $_ $projectFilter) -and (Test-Path -LiteralPath $_.path -PathType Container) })
        if ($cands.Count -eq 0) { throw ('no registered slot fits "{0}" to copy from. Pass -From <slot>.' -f $need) }
        $projects = @($cands | ForEach-Object { $_.project } | Select-Object -Unique)
        if ($projects.Count -gt 1) { throw ('"{0}" matches {1} projects ({2}). Add -Project <repo>.' -f $need, $projects.Count, ($projects -join ', ')) }
        $ranked = @($cands | ForEach-Object {
                $st = Get-SlotState $_ $snap
                [pscustomobject]@{ Slot = $_; Closed = ($st.EditorPid -eq 0 -and -not $st.Batch); Agent = [bool]$_.agentUse; LastUsed = (Get-LastUsed $_.path) }
            } | Sort-Object @{ Expression = { $_.Closed }; Descending = $true }, @{ Expression = { $_.Agent }; Descending = $true }, @{ Expression = { $_.LastUsed }; Descending = $true })
        $template = $ranked[0].Slot
    }
    $tplState = Get-SlotState $template $snap
    $tplClosed = ($tplState.EditorPid -eq 0 -and -not $tplState.Batch)
    $facts = Get-CloneFacts $template.path $snap
    $platform = $template.platform
    if (-not $platform) { $platform = $facts.Platform }
    $repoName = $facts.Repo
    if (-not $repoName) { $repoName = Split-Path $template.path -Leaf }
    # -CloneRoot, else the config's "cloneRoot", else the folder that holds the template clone
    $root = $CloneRoot
    if (-not $root) { $root = Expand-SlotText ([string](Get-Setting 'cloneRoot')) $null }
    if (-not $root) { $root = Split-Path $template.path -Parent }
    $folder = $Name
    if (-not $folder) { $folder = Get-NextCloneName $reg $repoName $root }
    $dest = Join-Path $root $folder
    $refRepo = Get-ReferenceRepo $template.path
    $branch = $facts.Branch

    Say ('need    {0} ({1})' -f $need, $template.project)
    Say ('from    {0}: {1}, {2}, {3}' -f $template.name, $platform, $branch, $tplState.Text)
    Say ('to      {0}' -f $dest)

    # checks
    $stop = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $dest) { $stop.Add("$dest already exists") }
    if (-not $facts.Origin) { $stop.Add('the template has no origin remote') }
    if (-not $platform) { $stop.Add('the template platform is unknown (unity-slot set <slot> -BuildTarget <platform>)') }
    $upstream = [string](@(Invoke-Git $template.path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')) | Select-Object -First 1)
    if (-not $upstream) {
        Say ('warn    branch {0} has no upstream; it may not exist on origin' -f $branch)
    } else {
        $counts = [string](@(Invoke-Git $template.path @('rev-list', '--left-right', '--count', '@{upstream}...HEAD')) | Select-Object -First 1)
        $m = [regex]::Match($counts, '^(\d+)\s+(\d+)$')
        if ($m.Success -and [int]$m.Groups[2].Value -gt 0) {
            Say ('warn    the template is {0} commit(s) ahead of {1}; the new clone gets origin only, without them' -f $m.Groups[2].Value, $upstream)
        }
    }
    $editorsOpen = @($snap.Unity | Where-Object { $_.Kind -eq 'editor' }).Count
    Say ('editors {0} open of max {1}; the first open adds one' -f $editorsOpen, $reg.maxEditors)
    if (-not $NoOpen -and $editorsOpen -ge [int]$reg.maxEditors) { $stop.Add(('{0} editors are open (max {1}): close one first, or pass -NoOpen' -f $editorsOpen, $reg.maxEditors)) }

    $libSize = Get-DirSize (Join-Path $template.path 'Library')
    $fileSize = Get-TrackedSize $template.path
    $gitSize = Get-GitObjectSize $template.path
    $copyLibrary = $tplClosed -and $libSize -gt 0
    $need_bytes = $fileSize + $gitSize
    if ($copyLibrary) { $need_bytes += $libSize }
    $driveName = ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))).TrimEnd('\')
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $driveName)
    $freeBytes = [double]0
    if ($null -ne $disk) { $freeBytes = [double]$disk.FreeSpace }
    $libText = '?'
    if ($libSize -ge 0) { $libText = Format-GB $libSize }
    if (-not $copyLibrary) { $libText += ' not copied' }
    Say ('disk    {0} free {1} GB; needs about {2} GB (files {3}, .git {4}, Library {5})' -f $driveName, (Format-GB $freeBytes), (Format-GB $need_bytes), (Format-GB $fileSize), (Format-GB $gitSize), $libText)
    if ($freeBytes -lt $need_bytes * 1.2) { $stop.Add('not enough free space on ' + $driveName) }
    if (-not $copyLibrary) {
        Say ('warn    Library is not copied ({0}): the first open imports everything (a large project can take tens of minutes)' -f $(if (-not $tplClosed) { 'the template editor is open; close it to copy' } else { 'the template has no Library' }))
    }
    # The template's purposes without the ones that name that one clone (config
    # "notCopiedToNewClone", default main), plus the need itself when it is not just the platform.
    $notCopied = @(Get-SettingList (Get-Prop (Get-Setting 'purposeRules') 'notCopiedToNewClone') | ForEach-Object { $_.ToLowerInvariant() })
    $purposes = @(@($template.purposes) | Where-Object { $notCopied -notcontains ([string]$_).ToLowerInvariant() })
    if ((ConvertTo-PlatformName $need) -ne $platform -and $purposes -notcontains $need.ToLowerInvariant()) { $purposes += $need.ToLowerInvariant() }
    if ($purposes.Count -eq 0) { $purposes = @('agent') }
    $openTimeout = Get-TimeoutSetting 'firstOpen' 2400
    if ($copyLibrary) { $openTimeout = Get-TimeoutSetting 'firstOpenWithLibrary' 900 }
    $afterClone = @(Get-Hooks 'afterClone' | ForEach-Object { Get-HookName $_ })
    $afterFirstOpen = @(Get-Hooks 'afterFirstOpen' | ForEach-Object { Get-HookName $_ })
    $hookNote = ''
    if ($NoHooks) { $hookNote = ' (skipped: -NoHooks)' }

    Say 'plan:'
    Say ('  1. git clone --reference "{0}" --dissociate --branch {1} {2} "{3}"' -f $refRepo, $branch, $facts.Origin, $dest)
    if ($copyLibrary) { Say ('  2. robocopy "{0}\Library" "{1}\Library" /E /COPY:DAT /DCOPY:T /MT:16 (template stays closed meanwhile)' -f $template.path, $dest) }
    else { Say '  2. (skipped) Library copy' }
    Say ('  3. register slot {0}: {1}, purposes {2}, ondemand, agent use' -f $folder, $platform, ($purposes -join ','))
    if ($afterClone.Count -gt 0) { Say ('  4. afterClone hooks: {0}{1}' -f ($afterClone -join ', '), $hookNote) }
    else { Say '  4. (none) afterClone hooks' }
    $firstOpenHooks = '(no afterFirstOpen hooks)'
    if ($afterFirstOpen.Count -gt 0) { $firstOpenHooks = 'then afterFirstOpen hooks: ' + ($afterFirstOpen -join ', ') + $hookNote }
    if ($NoOpen) { Say ('  5. (later) first open with -BuildTarget {0}; when it is READY: {1}' -f (Get-BuildTargetName $platform), $firstOpenHooks) }
    else { Say ('  5. unity-slot open "{0}" -BuildTarget {1} (waits up to {2} min), {3}' -f $dest, (Get-BuildTargetName $platform), [int]($openTimeout / 60), $firstOpenHooks) }

    if ($stop.Count -gt 0) {
        foreach ($s in $stop) { Say ('STOP    ' + $s) }
        $script:ExitCode = 4
        return
    }
    if (-not $Apply) {
        Say 'dry-run: nothing was created. Show this plan to the user; after they agree, run the same command with -Apply.'
        return
    }

    # ---- apply
    Say 'apply  1/5 clone'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& git clone --quiet --reference $refRepo --dissociate --branch $branch $facts.Origin $dest 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        foreach ($l in $out) { Say ('  ' + [string]$l) }
        Say ('FAILED: git clone exit {0}' -f $code)
        $script:ExitCode = 1
        return
    }

    if ($copyLibrary) {
        Say 'apply  2/5 Library copy'
        if ((Get-SlotState $template (Get-Snapshot)).EditorPid -gt 0) { Say 'FAILED: the template editor was opened meanwhile; Library not copied'; $script:ExitCode = 1; return }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & robocopy (Join-Path $template.path 'Library') (Join-Path $dest 'Library') /E /COPY:DAT /DCOPY:T /R:1 /W:1 /MT:16 /NFL /NDL /NP /NJH /NJS | Out-Null
            $rc = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        if ($rc -ge 8) { Say ('FAILED: robocopy exit {0}' -f $rc); $script:ExitCode = 1; return }
        Say ('        copied {0} GB' -f (Format-GB (Get-DirSize (Join-Path $dest 'Library'))))
    }

    Say 'apply  3/5 register'
    $reg = Read-Registry
    $rec = New-SlotRecord (New-SlotName $reg $dest) (Get-CanonicalPath $dest)
    Set-DetectedFields $rec (Get-CloneFacts $dest (Get-Snapshot))
    $rec.platform = $platform
    $rec.platformSource = 'template ' + $template.name
    $rec.purposes = [string[]]$purposes
    $rec.mode = 'ondemand'
    $rec.agentUse = $true
    $rec.memo = ('new-clone from {0} on {1}' -f $template.name, (Get-Date).ToString('yyyy-MM-dd', $script:Inv))
    if ($afterFirstOpen.Count -gt 0 -and -not $NoHooks) { $rec.pendingHooks = [string[]]@('afterFirstOpen') }
    $reg.slots.Add($rec)
    Write-Registry $reg
    Say ('        slot {0} added' -f $rec.name)

    Say 'apply  4/5 afterClone hooks'
    $vars = Get-HookVars $rec.path
    $vars.template = $template.path
    $cloneHooks = Invoke-SlotHooks 'afterClone' $vars
    if ($cloneHooks.Failed.Count -gt 0 -or $cloneHooks.Refused.Count -gt 0) {
        Say ('warn    afterClone hook(s) did not succeed: {0}. The clone stays; fix it by hand or run: unity-slot hooks {1} -HookEvent afterClone' -f ((@($cloneHooks.Failed) + @($cloneHooks.Refused)) -join ', '), $rec.name)
    }

    if ($NoOpen) {
        $later = ''
        if (@($rec.pendingHooks).Count -gt 0) { $later = ' The afterFirstOpen hooks run when that editor is first READY (open/wait/acquire).' }
        Say ('CREATED {0}. First open later: unity-slot open "{1}" -BuildTarget {2}.{3}' -f $rec.name, $dest, (Get-BuildTargetName $platform), $later)
        return
    }
    Say 'apply  5/5 first open'
    $script:PendingHooksFailed = $false
    Invoke-Open $dest $openTimeout (Get-BuildTargetName $platform)
    if ($script:ExitCode -ne 0) {
        Say ('first open did not finish (exit {0}); the clone and slot stay as they are. The afterFirstOpen hooks run when it is first READY (unity-slot wait {1}).' -f $script:ExitCode, $rec.name)
        return
    }
    if ($script:PendingHooksFailed) {
        Say ('CREATED {0}, but afterFirstOpen hooks did not succeed (see above).' -f $rec.name)
        $script:ExitCode = 4
        return
    }
    Say ('CREATED {0}.' -f $rec.name)
}
