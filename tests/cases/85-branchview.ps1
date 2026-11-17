# branch-view (0.7.0): one view repository (a plain folder with its .git) per project whose remotes are the slots, the plan without
# -Apply, slots that stay untouched, incremental fetches, placeholder URLs that no configured fetch or push
# can follow, busy slots, registry changes, origin fill, and dashboard branchViews[].
# Dot-sourced by tests\run-tests.ps1. ASCII-only source.
#
# The group pushes to an origin of its own (envs\branchview\origin\my-org\mygame.git, a bare copy of the
# shared fake origin), so other groups that clone the shared origin meanwhile see nothing of it. A fourth
# slot, MyGame-3, is a shallow clone of that origin, registered with scan.

Register-Group 'branchview' -Clones @('MyGame', 'MyGame-1', 'MyGame-2')

$script:BvEntryFields = 'project,repo,path,gitDir,createdAt,updatedAt,coreVersion,slots,origin,error'
$script:BvSlotFields = 'slot,remote,status,fetchedAt,changedSince,error'

function Get-BvNames($Object) { return (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') }

function Get-BvShallowPath($E) { return (Join-Path $E.ClonesDir 'MyGame-3') }

function Get-BvSlotPaths($E) { return @(@($E.Clones.Values | Sort-Object) + @(Get-BvShallowPath $E)) }

function Get-BvRoot($E) { return (Join-Path $E.Home 'view') }

function Get-BvFolder($E) { return (Join-Path (Get-BvRoot $E) 'mygame') }

# The view's git directory (folder form <root>\mygame\.git; no older bare <root>\*.git beside it).
function Get-BvView($E) {
    $old = @(Get-ChildItem -LiteralPath (Get-BvRoot $E) -Directory -Filter '*.git' -ErrorAction SilentlyContinue)
    Assert-Equal $old.Count 0 ('bare view repositories: ' + (@($old | ForEach-Object { $_.Name }) -join ','))
    $dirs = @(Get-ChildItem -LiteralPath (Get-BvRoot $E) -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git\HEAD') })
    Assert-Equal $dirs.Count 1 'view folders'
    return (Join-Path $dirs[0].FullName '.git')
}

# The folder form: <folder>\.git only, not bare, no local branch, an unborn HEAD, a clean status.
function Assert-BvFolderForm($E, [string]$What) {
    $folder = Get-BvFolder $E
    $view = Join-Path $folder '.git'
    Assert-True (Test-Path -LiteralPath (Join-Path $view 'HEAD') -PathType Leaf) ($What + ': ' + $view)
    Assert-Equal (@(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object { $_.Name }) -join ',') '.git' ($What + ': folder entries')
    Assert-Equal (@(Invoke-GitH @('config', '--file', (Join-Path $view 'config'), '--get', 'core.bare') $folder)[0]) 'false' ($What + ': core.bare')
    Assert-Equal (@(Invoke-GitH @('rev-parse', '--is-bare-repository') $folder)[0]) 'false' ($What + ': not bare')
    Assert-Equal @(Get-BvRefs $view 'refs/heads').Count 0 ($What + ': local branches')
    Assert-Equal (Get-BvRef $folder 'HEAD') '' ($What + ': HEAD unborn')
    Assert-Like (@(Invoke-GitH @('symbolic-ref', 'HEAD') $folder)[0]) '^refs/heads/' ($What + ': HEAD names a branch')
    $st = Invoke-BvGitRaw @('status', '--porcelain') $folder
    Assert-True ($st.Code -eq 0 -and -not $st.Text.Trim()) ($What + ': git status --porcelain: ' + $st.Text)
}

# git without throwing: exit code and the output (stdout and stderr together).
function Invoke-BvGitRaw([string[]]$GitArgs, [string]$Dir) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& git -C $Dir -c ('core.hooksPath=' + (Join-Path $script:HarnessRoot 'nohooks')) @GitArgs 2>&1 | ForEach-Object { [string]$_ }) } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

function Get-BvRef([string]$Dir, [string]$Ref) {
    $r = Invoke-BvGitRaw @('rev-parse', '--verify', '-q', $Ref) $Dir
    if ($r.Code -ne 0) { return '' }
    return $r.Text.Trim()
}

function Get-BvRefs([string]$View, [string]$Prefix) {
    return @(Invoke-GitH @('for-each-ref', '--format=%(refname) %(objectname)', $Prefix) $View)
}

function Add-BvCommit([string]$Clone, [string]$File, [string]$Message) {
    Write-TextFile (Join-Path $Clone $File) ($Message + "`n")
    [void](Invoke-GitH @('add', '-A') $Clone)
    [void](Invoke-GitH @('commit', '-q', '-m', $Message) $Clone)
    return (Get-BvRef $Clone 'HEAD')
}

# Every entry of the slots' .git folders: files with size, time and SHA-256 (read with full sharing),
# folders with their own write time.
function Get-BvSnapshot([string[]]$Clones) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($c in $Clones) {
            $root = Join-Path $c '.git'
            $lines.Add(('D|{0}|{1}' -f $root, [IO.Directory]::GetLastWriteTimeUtc($root).Ticks))
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
                if ($item.PSIsContainer) {
                    $lines.Add(('D|{0}|{1}' -f $item.FullName, [IO.Directory]::GetLastWriteTimeUtc($item.FullName).Ticks))
                } else {
                    $fs = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    try { $hash = -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() }
                    $lines.Add(('F|{0}|{1}|{2}|{3}' -f $item.FullName, $item.Length, [IO.File]::GetLastWriteTimeUtc($item.FullName).Ticks, $hash))
                }
            }
        }
    } finally { $sha.Dispose() }
    return $lines.ToArray()
}

# Every file below the view root (path, size, time, SHA-256) and folder: what a reader must leave alone.
# Times come from the item itself (GetLastWriteTimeUtc), not from the folder listing, whose copy of a
# folder's time NTFS updates lazily.
function Get-BvRootSnapshot($E) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath (Get-BvRoot $E) -Recurse -Force | Sort-Object FullName)) {
        if ($item.PSIsContainer) { $lines.Add(('D|{0}|{1}' -f $item.FullName, [IO.Directory]::GetLastWriteTimeUtc($item.FullName).Ticks)); continue }
        $lines.Add(('F|{0}|{1}|{2}|{3}' -f $item.FullName, (New-Object IO.FileInfo($item.FullName)).Length, [IO.File]::GetLastWriteTimeUtc($item.FullName).Ticks,
                (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash))
    }
    return $lines.ToArray()
}

function Assert-BvSnapshotSame($Before, $After, [string]$What) {
    $changed = @(Compare-Object $Before $After | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject })
    if ($changed.Count -gt 0) { Fail ($What + ': slot .git changed:' + "`n  " + (($changed | Select-Object -First 12) -join "`n  ")) }
    Assert-True ($Before.Count -gt 100) ('snapshot entries: ' + $Before.Count)
}

# branch-view -Json: exit code, the stdout document and stderr.
function Invoke-BvJson($E, [string[]]$More = @(), [int]$Code = 0, [hashtable]$ExtraEnv = $null) {
    $r = Invoke-SlotCli $E (@('branch-view', '-Json') + $More) 180 $ExtraEnv
    Assert-Exit $r $Code
    $lines = @($r.Out -split "`n" | Where-Object { $_.Trim() })
    Assert-Equal $lines.Count 1 ('branch-view -Json stdout lines' + (Format-Excerpt $r))
    Assert-True ($r.Out.IndexOf('[branch-view]', [StringComparison]::Ordinal) -lt 0) ('progress lines on stdout' + (Format-Excerpt $r))
    return [pscustomobject]@{ Run = $r; Doc = ($r.Out | ConvertFrom-Json) }
}

function Get-BvSlotOut($Doc, [string]$Slot) {
    $v = @($Doc.views | Where-Object { $_.project -eq $script:ProjectKey })
    Assert-Equal $v.Count 1 'views of my-org/mygame'
    $s = @($v[0].slots | Where-Object { $_.slot -eq $Slot })
    Assert-Equal $s.Count 1 ('slot ' + $Slot + ' in the branch-view document')
    return $s[0]
}

function Get-BvDashboard($E) {
    $d = Invoke-SlotCli $E @('dashboard', '-Json')
    Assert-Exit $d 0
    Assert-True ([string]::IsNullOrWhiteSpace($d.Err)) ('dashboard stderr: ' + $d.Err)
    return ($d.Out | ConvertFrom-Json)
}

function Get-BvDashSlot($Dash, [string]$Slot) {
    Assert-Equal @($Dash.branchViews).Count 1 'dashboard branchViews'
    $s = @($Dash.branchViews[0].slots | Where-Object { $_.slot -eq $Slot })
    Assert-Equal $s.Count 1 ('dashboard branchViews slot ' + $Slot)
    return $s[0]
}

function Get-BvState($E) {
    $f = @(Get-ChildItem -LiteralPath (Get-BvRoot $E) -Filter '*.view.json' -File)
    Assert-Equal $f.Count 1 'state files'
    return ([IO.File]::ReadAllText($f[0].FullName, $script:Utf8) | ConvertFrom-Json)
}

# Slots for the whole group (once per environment):
#   MyGame:   feature/x with two local commits, a local tag, fetched
#   MyGame-1: feature/x with another tip, feature/shared pushed to the group's origin, feature/deep pushed
#             and deleted locally, fetched last (its FETCH_HEAD is the newest, so origin/* of the view
#             comes from it)
#   MyGame-2: detached HEAD with a commit of its own
#   MyGame-3: a shallow clone (depth 1) of the group's origin with a local feature/deep, registered with scan
function Initialize-BvScenario($E) {
    $marker = Join-Path $E.Dir 'bv-scenario.txt'
    if (Test-Path -LiteralPath $marker) { return }
    $origin = Join-Path $E.Dir 'origin\my-org\mygame.git'
    [void](Invoke-GitH @('clone', '-q', '--bare', (Get-OriginPath), $origin))
    foreach ($c in @($E.Clones.Values)) {
        [void](Invoke-GitH @('remote', 'set-url', 'origin', $origin) $c)
        [void](Invoke-GitH @('fetch', '-q', 'origin') $c)
    }
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/x') $m0)
    [void](Add-BvCommit $m0 'Assets\x0.txt' 'x zero one')
    [void](Add-BvCommit $m0 'Assets\x0.txt' 'x zero two')
    [void](Invoke-GitH @('tag', 'local-tag') $m0)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m0)

    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/x') $m1)
    [void](Add-BvCommit $m1 'Assets\x1.txt' 'x one')
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/shared', 'master') $m1)
    [void](Add-BvCommit $m1 'Assets\shared.txt' 'shared')
    [void](Invoke-GitH @('push', '-q', '-u', 'origin', 'feature/shared') $m1)
    # feature/deep: on origin only (no slot has it as a local branch but the shallow one)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/deep', 'master') $m1)
    [void](Add-BvCommit $m1 'Assets\deep.txt' 'deep one')
    [void](Add-BvCommit $m1 'Assets\deep.txt' 'deep two')
    [void](Invoke-GitH @('push', '-q', 'origin', 'feature/deep') $m1)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m1)
    [void](Invoke-GitH @('branch', '-q', '-D', 'feature/deep') $m1)

    [void](Invoke-GitH @('checkout', '-q', '--detach', 'master') $m2)
    [void](Add-BvCommit $m2 'Assets\detached.txt' 'detached work')

    # MyGame-3: depth 1, with a local feature/deep whose history the view has from no other slot, so the
    # view takes it only with --update-shallow
    $m3 = Get-BvShallowPath $E
    $url = 'file:///' + $origin.Replace('\', '/')
    [void](Invoke-GitH @('clone', '-q', '--depth', '1', '--no-single-branch', $url, $m3))
    [void](Invoke-GitH @('branch', '-q', 'feature/deep', 'origin/feature/deep') $m3)
    $lib = Join-Path $m3 'Library'
    [void](New-Item -ItemType Directory -Path $lib -Force)
    [IO.File]::WriteAllBytes((Join-Path $lib 'EditorUserBuildSettings.asset'), (Get-LibraryAssetBytes 'Android'))
    Assert-True (Test-Path -LiteralPath (Join-Path $m3 '.git\shallow')) 'MyGame-3 is shallow'
    $r = Invoke-SlotCli $E @('scan', '-ScanRoot', $E.ClonesDir, '-Project', $script:ProjectKey, '-Apply')
    Assert-Exit $r 0
    $slots = Get-EnvSlotsJson $E
    Assert-Equal (@($slots.slots | Where-Object { $_.project -eq $script:ProjectKey } | ForEach-Object { $_.name } | Sort-Object) -join ',') 'MyGame,MyGame-1,MyGame-2,MyGame-3' 'registered slots'

    Start-Sleep -Milliseconds 50
    [void](Invoke-GitH @('fetch', '-q', 'origin') $m0)
    Start-Sleep -Milliseconds 50
    [void](Invoke-GitH @('fetch', '-q', 'origin') $m1)
    Write-TextFile $marker "done`n"
}

# The view exists (made by an earlier test of the group, or now).
function Initialize-BvView($E) {
    Initialize-BvScenario $E
    if (Test-Path -LiteralPath (Join-Path (Get-BvFolder $E) '.git\HEAD')) { return }
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
}

Add-Test -Name 'branchview.plan-only' -Group 'branchview' -Body {
    param($E)
    Initialize-BvScenario $E
    $root = Get-BvRoot $E
    $before = Get-BvSnapshot (Get-BvSlotPaths $E)
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('branch-view')
    Assert-Exit $r 0
    Assert-Has $r 'dry run: nothing is written'
    Assert-Like $r 'my-org/mygame: .*\\mygame not made yet; -Apply makes it \(about '
    Assert-Like $r '^\[branch-view\]   open\s+.*\\mygame \(the folder to open in Fork or another git client\)'
    Assert-Like $r '^\[branch-view\]   remotes\s+add MyGame, MyGame-1, MyGame-2, MyGame-3'
    Assert-Like $r '^\[branch-view\]   MyGame-2\s+fetch \(new, detached HEAD\)'
    Assert-Like $r '^\[branch-view\]   MyGame-3\s+fetch \(new, shallow: last, --update-shallow\)'
    Assert-Like $r '^\[branch-view\]   origin\s+fill from MyGame-1 \(newest FETCH_HEAD\)'
    Assert-Has $r '[branch-view] next    unity-slot branch-view -Apply'

    $j = Invoke-BvJson $E
    $doc = $j.Doc
    Assert-Equal $doc.schema 'unity-slot.branch-view/1' 'schema'
    Assert-Equal $doc.version (Get-CoreVersion) 'version'
    Assert-True ($doc.apply -eq $false) 'apply false'
    Assert-True (Test-SamePathH $doc.root $root) ('root ' + $doc.root)
    Assert-Equal $doc.minSlots 2 'minSlots'
    Assert-Equal @($doc.views).Count 1 'views'
    $v = $doc.views[0]
    Assert-Equal ('{0}|{1}|{2}' -f $v.action, $v.exists, $v.name) 'create|False|mygame' 'view plan'
    Assert-True (Test-SamePathH $v.path (Join-Path $root 'mygame')) ('view path ' + $v.path)
    Assert-True (Test-SamePathH $v.gitDir (Join-Path $root 'mygame\.git')) ('view gitDir ' + $v.gitDir)
    Assert-True ($null -eq $v.moveFrom) ('moveFrom ' + $v.moveFrom)
    Assert-True ([long]$v.estimatedBytes -gt 0) ('estimatedBytes ' + $v.estimatedBytes)
    Assert-Equal (@($v.remotes.add) -join ',') 'MyGame,MyGame-1,MyGame-2,MyGame-3' 'remotes to add'
    foreach ($s in @($v.slots)) { Assert-Equal $s.action 'fetch' ($s.slot + ' action') }
    Assert-True ((Get-BvSlotOut $doc 'MyGame-2').detached -eq $true) 'MyGame-2 detached'
    Assert-True ((Get-BvSlotOut $doc 'MyGame-3').shallow -eq $true) 'MyGame-3 shallow'
    Assert-Equal $v.origin.source 'MyGame-1' 'origin source'
    Assert-Has $j.Run.Err '[branch-view] root    ' 'progress on stderr'

    # minSlots: a project with fewer slots gets no view
    $cfg = [IO.File]::ReadAllText($E.Config, $script:Utf8) | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName branchView -NotePropertyValue ([pscustomobject]@{ minSlots = 5 })
    $cfg5 = Join-Path $E.Dir 'config-min5.json'
    Write-TextFile $cfg5 ($cfg | ConvertTo-Json -Depth 8)
    $m = Invoke-SlotCli $E @('branch-view', '-Apply') 120 @{ UNITY_SLOT_CONFIG = $cfg5 }
    Assert-Exit $m 0
    Assert-Has $m 'my-org/mygame: not made (4 slot(s), branchView.minSlots 5)'

    # a filter that matches nothing is an error; with -Json stdout stays empty
    $x = Invoke-SlotCli $E @('branch-view', '-Project', 'nothing-here')
    Assert-Exit $x 1
    Assert-Has $x 'no registered slot matches -Project nothing-here'
    $xj = Invoke-SlotCli $E @('branch-view', '-Project', 'nothing-here', '-Json')
    Assert-Exit $xj 1
    Assert-True ([string]::IsNullOrWhiteSpace($xj.Out)) ('stdout of a failed -Json run: ' + $xj.Out)
    Assert-Has $xj.Err 'ERROR: no registered slot matches' 'stderr of a failed -Json run'

    # a root inside a slot is refused before anything is made
    $cfg = [IO.File]::ReadAllText($E.Config, $script:Utf8) | ConvertFrom-Json
    $inside = Join-Path $E.Clones['MyGame-1'] 'views'
    $cfg | Add-Member -NotePropertyName branchView -NotePropertyValue ([pscustomobject]@{ root = $inside })
    $cfgIn = Join-Path $E.Dir 'config-root-in-slot.json'
    Write-TextFile $cfgIn ($cfg | ConvertTo-Json -Depth 8)
    $ri = Invoke-SlotCli $E @('branch-view', '-Apply', '-Json') 120 @{ UNITY_SLOT_CONFIG = $cfgIn }
    Assert-Exit $ri 1
    Assert-True ([string]::IsNullOrWhiteSpace($ri.Out)) ('stdout of a refused -Json run: ' + $ri.Out)
    Assert-Has $ri.Err 'is inside slot MyGame-1' 'root inside a slot'
    Assert-True (-not (Test-Path -LiteralPath $inside)) ('made ' + $inside)

    Assert-True (-not (Test-Path -LiteralPath $root)) ('the dry run made ' + $root)
    Assert-Equal (Get-EventCount $E) $n0 'events after dry runs'
    Assert-Equal (@((Get-BvDashboard $E).branchViews).Count) 0 'dashboard branchViews before any view'
    Assert-BvSnapshotSame $before (Get-BvSnapshot (Get-BvSlotPaths $E)) 'dry runs'
}

Add-Test -Name 'branchview.create-and-refs' -Group 'branchview' -Body {
    param($E)
    Initialize-BvScenario $E
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']
    $m3 = Get-BvShallowPath $E
    $before = Get-BvSnapshot (Get-BvSlotPaths $E)
    $n0 = Get-EventCount $E
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r 'my-org/mygame: created \S*\\mygame\r?$'
    Assert-Like $r '^\[branch-view\]   open\s+.*\\mygame \(the folder to open in Fork'
    Assert-Like $r '^\[branch-view\]   remotes\s+added MyGame, MyGame-1, MyGame-2, MyGame-3'
    foreach ($s in @('MyGame', 'MyGame-1', 'MyGame-2', 'MyGame-3')) { Assert-Like $r ('^\[branch-view\]   ' + [regex]::Escape($s) + '\s+fetched, \d+ ref update\(s\)') }
    Assert-Like $r '^\[branch-view\]   origin\s+filled from MyGame-1, \d+ ref update\(s\)'
    Assert-Like $r 'my-org/mygame: done in [\d.]+ s \(fetched 4, unchanged 0, skipped 0, failed 0'
    $view = Get-BvView $E
    Assert-BvFolderForm $E 'created'

    # remotes: placeholders for url and pushurl, the slot refspec, no tags, the marker
    foreach ($s in @('MyGame', 'MyGame-1', 'MyGame-2', 'MyGame-3')) {
        $cfg = @(Invoke-GitH @('config', '--get-regexp', ('^remote\.' + [regex]::Escape($s) + '\.')) $view) -join '|'
        $want = (@(('remote.{0}.url unity-slot-view://{0}' -f $s), ('remote.{0}.pushurl unity-slot-view://{0}' -f $s),
                ('remote.{0}.fetch +refs/heads/*:refs/remotes/{0}/*' -f $s), ('remote.{0}.tagopt --no-tags' -f $s),
                ('remote.{0}.followremotehead always' -f $s), ('remote.{0}.skipfetchall true' -f $s), ('remote.{0}.skipdefaultupdate true' -f $s),
                ('remote.{0}.unityslot true' -f $s)) -join '|')
        Assert-Equal $cfg $want ($s + ' remote config')
    }
    Assert-Equal (@(Invoke-GitH @('config', '--get', 'remote.origin.pushurl') $view)[0]) 'unity-slot-view://origin' 'origin pushurl'
    Assert-Equal (@(Invoke-GitH @('config', '--get', 'unity-slot.project') $view)[0]) $script:ProjectKey 'view project'

    # refs: each slot's branches under its own name, the detached HEAD, origin from MyGame-1, no tags
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame/master') (Get-BvRef $m0 'master') 'MyGame/master'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame/feature/x') (Get-BvRef $m0 'feature/x') 'MyGame/feature/x'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-1/feature/x') (Get-BvRef $m1 'feature/x') 'MyGame-1/feature/x'
    Assert-True ((Get-BvRef $view 'refs/remotes/MyGame/feature/x') -ne (Get-BvRef $view 'refs/remotes/MyGame-1/feature/x')) 'feature/x differs per slot'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') (Get-BvRef $m2 'HEAD') 'MyGame-2/(detached)'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-3/master') (Get-BvRef $m3 'master') 'MyGame-3/master (shallow slot)'
    Assert-True ((Get-BvRef $m3 'feature/deep') -ne '') 'MyGame-3 has feature/deep'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-3/feature/deep') (Get-BvRef $m3 'feature/deep') 'MyGame-3/feature/deep (history only in the shallow slot)'
    Assert-Equal (@(Invoke-GitH @('symbolic-ref', 'refs/remotes/MyGame/HEAD') $view)[0]) 'refs/remotes/MyGame/master' 'MyGame/HEAD follows the slot'
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/feature/shared') (Get-BvRef $m1 'refs/remotes/origin/feature/shared') 'origin/feature/shared'
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/HEAD') '' 'no origin/HEAD'
    Assert-Equal @(Get-BvRefs $view 'refs/tags').Count 0 'tags in the view'
    Assert-Equal @(Get-BvRefs $view 'refs/heads').Count 0 'local branches in the view'

    # state file and event
    $st = Get-BvState $E
    Assert-Equal $st.schema 'unity-slot.branch-view/1' 'state schema'
    Assert-Equal (@($st.slots | ForEach-Object { '{0}:{1}' -f $_.slot, $_.status }) -join ',') 'MyGame:fetched,MyGame-1:fetched,MyGame-2:fetched,MyGame-3:fetched' 'state slots'
    foreach ($s in @($st.slots)) { Assert-Like ([string]$s.signature) '^[0-9a-f]{32}$' ($s.slot + ' signature') }
    Assert-Equal ('{0}|{1}' -f $st.origin.filledFrom, @($st.origin.rejected).Count) 'MyGame-1|0' 'state origin'
    $ev = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'branchview' })
    Assert-Equal $ev.Count 1 'branchview events'
    Assert-True ($null -eq $ev[0].slot -and (Test-SamePathH $ev[0].path (Get-BvFolder $E))) ('event slot/path ' + $ev[0].slot + ' ' + $ev[0].path)
    Assert-True (Test-SamePathH $ev[0].detail.gitDir $view) ('event gitDir ' + $ev[0].detail.gitDir)
    Assert-True ((Test-SamePathH $st.path (Get-BvFolder $E)) -and (Test-SamePathH $st.gitDir $view)) ('state path/gitDir ' + $st.path + ' ' + $st.gitDir)
    Assert-Equal ('{0}|{1}|{2}|{3}' -f $ev[0].detail.project, $ev[0].detail.created, $ev[0].detail.fetched, (@($ev[0].detail.added) -join ',')) 'my-org/mygame|True|4|MyGame,MyGame-1,MyGame-2,MyGame-3' 'event detail'

    # dashboard branchViews[]: the contract's fields, nothing changed since; the view root stays as it was
    $rootBefore = Get-BvRootSnapshot $E
    $dash = Get-BvDashboard $E
    $rootDiff = @(Compare-Object $rootBefore (Get-BvRootSnapshot $E) | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject })
    Assert-True ($rootDiff.Count -eq 0) ('dashboard changed the view root: ' + ($rootDiff -join '; '))
    Assert-Equal (@($dash.PSObject.Properties | ForEach-Object { $_.Name }) | Select-Object -Last 3) 'timing repos branchViews' 'branchViews comes last'
    $bv = $dash.branchViews[0]
    Assert-Equal (Get-BvNames $bv) $script:BvEntryFields 'branchViews entry fields'
    Assert-Equal (Get-BvNames $bv.origin) 'filledFrom,rejected' 'branchViews origin fields'
    Assert-Equal ('{0}|{1}|{2}|{3}' -f $bv.project, $bv.coreVersion, $bv.origin.filledFrom, $bv.error) ('my-org/mygame|{0}|MyGame-1|' -f (Get-CoreVersion)) 'branchViews entry'
    Assert-True (Test-SamePathH $bv.path (Get-BvFolder $E)) ('branchViews path ' + $bv.path)
    Assert-True (Test-SamePathH $bv.gitDir $view) ('branchViews gitDir ' + $bv.gitDir)
    foreach ($s in @($bv.slots)) {
        Assert-Equal (Get-BvNames $s) $script:BvSlotFields ($s.slot + ' branchViews slot fields')
        Assert-Equal ('{0}|{1}|{2}' -f $s.status, $s.changedSince, $s.remote) ('fetched|False|' + $s.slot) ($s.slot + ' branchViews slot')
    }

    # a second run fetches nothing
    $j = Invoke-BvJson $E @('-Apply')
    Assert-Equal $j.Doc.views[0].action 'none' 'second run action'
    # the view's size counts loose objects too (fetches this small unpack)
    Assert-True ([long]$j.Doc.views[0].sizeBytes -gt 0) ('view sizeBytes ' + $j.Doc.views[0].sizeBytes)
    foreach ($s in @($j.Doc.views[0].slots)) { Assert-Equal ('{0}|{1}' -f $s.action, $s.status) 'unchanged|unchanged' ($s.slot + ' second run') }
    Assert-Equal $j.Doc.views[0].origin.action 'unchanged' 'second run origin'
    Assert-BvSnapshotSame $before (Get-BvSnapshot (Get-BvSlotPaths $E)) 'create and a second run'
}

Add-Test -Name 'branchview.slots-untouched' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m3 = Get-BvShallowPath $E
    # changes so that the slots are fetched, then locks an agent's git might hold meanwhile
    [void](Add-BvCommit $m0 'Assets\untouched0.txt' 'untouched zero')
    [void](Invoke-GitH @('branch', 'feature/new', 'master') $m1)
    [void](Add-BvCommit $m3 'Assets\untouched3.txt' 'untouched three')
    $locks = @((Join-Path $m0 '.git\index.lock'), (Join-Path $m0 '.git\refs\heads\master.lock'), (Join-Path $m3 '.git\index.lock'))
    try {
        foreach ($l in $locks) { Write-TextFile $l "held by someone else`n" }
        $before = Get-BvSnapshot (Get-BvSlotPaths $E)
        $r = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $r 0
        foreach ($s in @('MyGame', 'MyGame-1', 'MyGame-3')) { Assert-Like $r ('^\[branch-view\]   ' + [regex]::Escape($s) + '\s+fetched, ') }
        Assert-Like $r '^\[branch-view\]   MyGame-2\s+unchanged'
        $after = Get-BvSnapshot (Get-BvSlotPaths $E)
        Assert-BvSnapshotSame $before $after 'branch-view -Apply with lock files and a shallow slot'
        $view = Get-BvView $E
        Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-3/master') (Get-BvRef $m3 'master') 'MyGame-3/master after a commit'
        Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-1/feature/new') (Get-BvRef $m1 'feature/new') 'MyGame-1/feature/new'
    } finally {
        foreach ($l in $locks) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
    }
}

Add-Test -Name 'branchview.incremental-and-prune' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']
    $view = Get-BvView $E
    Assert-True ((Get-BvRef $view 'refs/remotes/MyGame-1/feature/x') -ne '') 'MyGame-1/feature/x before'
    $tip = Add-BvCommit $m0 'Assets\incremental.txt' 'incremental'
    [void](Invoke-GitH @('branch', '-D', 'feature/x') $m1)
    $dash = Get-BvDashboard $E
    Assert-Equal ('{0}|{1}|{2}|{3}' -f (Get-BvDashSlot $dash 'MyGame').changedSince, (Get-BvDashSlot $dash 'MyGame-1').changedSince,
        (Get-BvDashSlot $dash 'MyGame-2').changedSince, (Get-BvDashSlot $dash 'MyGame-3').changedSince) 'True|True|False|False' 'changedSince before'
    $p = Invoke-SlotCli $E @('branch-view')
    Assert-Exit $p 0
    Assert-Like $p '2 slot\(s\) changed since'
    Assert-Like $p '^\[branch-view\]   MyGame\s+fetch \(changed\)'
    Assert-Like $p '^\[branch-view\]   MyGame-2\s+unchanged'

    $j = Invoke-BvJson $E @('-Apply')
    Assert-Equal ('{0}|{1}|{2}|{3}' -f (Get-BvSlotOut $j.Doc 'MyGame').action, (Get-BvSlotOut $j.Doc 'MyGame-1').action,
        (Get-BvSlotOut $j.Doc 'MyGame-2').action, (Get-BvSlotOut $j.Doc 'MyGame-3').action) 'fetched|fetched|unchanged|unchanged' 'actions'
    Assert-Equal (Get-BvSlotOut $j.Doc 'MyGame').updates 1 'MyGame ref updates'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame/master') $tip 'MyGame/master moved'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-1/feature/x') '' 'MyGame-1/feature/x pruned'
    $dash = Get-BvDashboard $E
    foreach ($s in @($dash.branchViews[0].slots)) { Assert-True ($s.changedSince -eq $false) ($s.slot + ' changedSince after') }

    # MyGame-2 on a branch: (detached) goes and <remote>/HEAD follows; detached again: back
    $det = Get-BvRef $m2 'HEAD'
    [void](Invoke-GitH @('checkout', '-q', 'master') $m2)
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r '^\[branch-view\]   MyGame-2\s+fetched, '
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') '' 'MyGame-2/(detached) gone on a branch'
    Assert-Equal (@(Invoke-GitH @('symbolic-ref', 'refs/remotes/MyGame-2/HEAD') $view)[0]) 'refs/remotes/MyGame-2/master' 'MyGame-2/HEAD on a branch'
    [void](Invoke-GitH @('checkout', '-q', '--detach', $det) $m2)
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') $det 'MyGame-2/(detached) back'
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-2/HEAD') '' 'MyGame-2/HEAD dropped while detached'
}

# A commit on a branch below a folder (feature/x) changes only that ref file: neither refs\heads nor HEAD
# nor packed-refs move. The signature still sees it.
Add-Test -Name 'branchview.nested-branch' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $view = Get-BvView $E
    $cur = Get-BvRef $m0 'refs/heads/feature/x'
    [void](Invoke-GitH @('update-ref', 'refs/heads/feature/x', $cur) $m0)   # a loose ref file
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    $headsDir = Join-Path $m0 '.git\refs\heads'
    $t0 = [IO.Directory]::GetLastWriteTimeUtc($headsDir).Ticks
    $h0 = [IO.File]::ReadAllText((Join-Path $m0 '.git\HEAD'))
    $tree = Get-BvRef $m0 'feature/x^{tree}'
    $new = [string](@(Invoke-GitH @('commit-tree', '-p', $cur, '-m', 'nested only', $tree) $m0)[0])
    [void](Invoke-GitH @('update-ref', 'refs/heads/feature/x', $new, $cur) $m0)
    Assert-Equal ([IO.Directory]::GetLastWriteTimeUtc($headsDir).Ticks) $t0 'refs\heads folder time unchanged (premise)'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $m0 '.git\HEAD'))) $h0 'HEAD unchanged (premise)'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r '^\[branch-view\]   MyGame\s+fetched, 1 ref update\(s\)'
    foreach ($s in @('MyGame-1', 'MyGame-2', 'MyGame-3')) { Assert-Like $r ('^\[branch-view\]   ' + [regex]::Escape($s) + '\s+unchanged') }
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame/feature/x') $new 'MyGame/feature/x'
}

# What a git client does with the view's settings (Fork's fetch, a person's git fetch) cannot reach a slot.
Add-Test -Name 'branchview.config-fetch-blocked' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $view = Get-BvView $E
    [void](Add-BvCommit $m0 'Assets\blocked.txt' 'not fetched by others')
    $refs0 = @(Get-BvRefs $view 'refs/remotes/MyGame')
    $before = Get-BvSnapshot (Get-BvSlotPaths $E)
    foreach ($ga in @(@('fetch', 'MyGame'), @('fetch', '--prune', 'MyGame-2'), @('fetch', 'MyGame-3'), @('fetch', 'MyGame-1', 'master'))) {
        $g = Invoke-BvGitRaw $ga $view
        Assert-True ($g.Code -ne 0) ('git ' + ($ga -join ' ') + ' in the view succeeded: ' + $g.Text)
        Assert-Like $g.Text 'unity-slot-view' ('git ' + ($ga -join ' ') + ' error')
    }
    # fetch --all skips the slot remotes (skipFetchAll) and fetches origin only
    $all = Invoke-BvGitRaw @('fetch', '--all') $view
    Assert-Equal $all.Code 0 ('git fetch --all: ' + $all.Text)
    Assert-HasNot $all.Text 'unity-slot-view' 'git fetch --all'
    Assert-Equal (@(Get-BvRefs $view 'refs/remotes/MyGame') -join ';') ($refs0 -join ';') 'slot refs after the blocked fetches'
    Assert-BvSnapshotSame $before (Get-BvSnapshot (Get-BvSlotPaths $E)) 'fetches with the view''s own settings'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame/master') (Get-BvRef $m0 'master') 'branch-view still fetches MyGame'
    Assert-True ((Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') -ne '') 'MyGame-2/(detached) kept'
}

Add-Test -Name 'branchview.push-guard' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $view = Get-BvView $E
    $before = Get-BvSnapshot (Get-BvSlotPaths $E)
    $originRefs = @(Invoke-GitH @('for-each-ref', '--format=%(refname) %(objectname)') (Join-Path $E.Dir 'origin\my-org\mygame.git'))
    foreach ($ga in @(@('push', 'MyGame', 'refs/remotes/MyGame/master:refs/heads/pushed'), @('push', 'MyGame-3', 'refs/remotes/MyGame/master:refs/heads/pushed'),
            @('push', 'origin', 'refs/remotes/MyGame/master:refs/heads/pushed'), @('push', '--all', 'MyGame-1'))) {
        $g = Invoke-BvGitRaw $ga $view
        Assert-True ($g.Code -ne 0) ('git ' + ($ga -join ' ') + ' in the view succeeded: ' + $g.Text)
        Assert-Like $g.Text 'unity-slot-view' ('git ' + ($ga -join ' ') + ' error')
    }
    Assert-Equal (Get-BvRef $m0 'refs/heads/pushed') '' 'nothing pushed into MyGame'
    Assert-BvSnapshotSame $before (Get-BvSnapshot (Get-BvSlotPaths $E)) 'pushes from the view'
    Assert-Equal (@(Invoke-GitH @('for-each-ref', '--format=%(refname) %(objectname)') (Join-Path $E.Dir 'origin\my-org\mygame.git')) -join ';') ($originRefs -join ';') 'origin refs'
}

# Another run's lock: exit 4 and nothing written. A slot whose gc runs: skipped. Temporary pack files: a new
# one skips the slot, an old one is only reported.
Add-Test -Name 'branchview.busy-and-stale-temp' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']
    $view = Get-BvView $E
    $lockFile = Join-Path (Get-BvRoot $E) 'mygame.view-lock'
    $stateFile = Join-Path (Get-BvRoot $E) 'mygame.view.json'
    $stateText = [IO.File]::ReadAllText($stateFile)
    $n0 = Get-EventCount $E
    $held = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $b = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $b 4
        Assert-Has $b 'BUSY another branch-view run holds'
        $p = Invoke-SlotCli $E @('branch-view')
        Assert-Exit $p 0
        Assert-Has $p 'another branch-view run holds this view right now'
        $bj = Invoke-BvJson $E @('-Apply') 4
        Assert-Equal ('{0}|{1}' -f $bj.Doc.views[0].action, ($bj.Doc.views[0].error -match 'another branch-view run')) 'busy|True' 'busy view in -Json'
    } finally { $held.Dispose() }
    Assert-Equal (Get-EventCount $E) $n0 'events after the busy runs'
    Assert-Equal ([IO.File]::ReadAllText($stateFile)) $stateText 'state file after the busy runs'

    $files = @((Join-Path $m1 '.git\gc.pid'), (Join-Path $m0 '.git\objects\pack\tmp_pack_old'), (Join-Path $m2 '.git\objects\pack\tmp_pack_new'))
    try {
        [void](Invoke-GitH @('branch', 'feature/during-gc', 'master') $m1)
        [void](Add-BvCommit $m0 'Assets\old-temp.txt' 'old temp')
        foreach ($f in $files) { Write-TextFile $f "1234 host`n" }
        [IO.File]::SetLastWriteTime($files[1], (Get-Date).AddHours(-3))
        $r = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $r 0
        Assert-Like $r '^\[branch-view\]   MyGame-1\s+SKIP busy \(gc\.pid \d+ s old\)'
        Assert-Like $r '^\[branch-view\]   MyGame-2\s+SKIP busy \(objects\\pack\\tmp_pack_new \d+ s old\)'
        Assert-Like $r '^\[branch-view\]   MyGame\s+fetched, '
        Assert-Like $r 'note: leftover temp file\(s\) of an earlier git run \(reported only\): objects\\pack\\tmp_pack_old \(3 h old\)'
        Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-1/feature/during-gc') '' 'nothing fetched from MyGame-1 while its gc runs'
        $st = Get-BvState $E
        Assert-Equal (@($st.slots | Where-Object { $_.slot -eq 'MyGame-1' })[0].status) 'busy' 'state status busy'
        $dash = Get-BvDashboard $E
        Assert-Equal ('{0}|{1}' -f (Get-BvDashSlot $dash 'MyGame-1').status, (Get-BvDashSlot $dash 'MyGame-1').changedSince) 'busy|True' 'dashboard busy slot'
    } finally {
        foreach ($f in $files) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r '^\[branch-view\]   MyGame-1\s+fetched, '
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-1/feature/during-gc') (Get-BvRef $m1 'feature/during-gc') 'MyGame-1 fetched after its gc'
}

# A slot whose gc starts while branch-view fetches the slots before it is skipped: busy is checked again
# right before each fetch. Here MyGame's fetch (its upload-pack, through a pack-objects hook in a test-only
# global git config) leaves a fresh gc.pid in MyGame-2, which comes later in the fetch order. Hooks that
# someone put in the view's own hooks folder do not run either.
Add-Test -Name 'branchview.busy-during-run' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m0 = $E.Clones['MyGame']
    $m2 = $E.Clones['MyGame-2']
    $view = Get-BvView $E
    $gcPid = Join-Path $m2 '.git\gc.pid'
    $hook = Join-Path $E.Dir 'bv-gc-starts.sh'
    Write-TextFile $hook ("#!/bin/sh`n: > '" + $gcPid.Replace('\', '/') + "'`nexec `"`$@`"`n")
    $global = Join-Path $E.Dir 'bv-global.gitconfig'
    Write-TextFile $global ("[uploadpack]`n`tpackObjectsHook = sh '" + $hook.Replace('\', '/') + "'`n")
    # a hook in the view: it runs for a plain git update-ref there (premise), never for branch-view
    $marker = Join-Path $E.Dir 'bv-view-hook-ran.txt'
    $viewHook = Join-Path $view 'hooks\reference-transaction'
    Write-TextFile $viewHook ("#!/bin/sh`necho ran >> '" + $marker.Replace('\', '/') + "'`nexit 0`n")
    $tip0 = Get-BvRef $view 'refs/remotes/MyGame/master'
    $g = Invoke-BvGitRaw @('-c', ('core.hooksPath=' + (Join-Path $view 'hooks')), 'update-ref', 'refs/bvtest/x', $tip0) $view
    Assert-True ($g.Code -eq 0 -and (Test-Path -LiteralPath $marker)) ('the view hook runs for git itself (premise): ' + $g.Text)
    [void](Invoke-GitH @('update-ref', '-d', 'refs/bvtest/x') $view)
    Remove-Item -LiteralPath $marker -Force

    [void](Add-BvCommit $m0 'Assets\during0.txt' 'during zero')
    $det = Add-BvCommit $m2 'Assets\during2.txt' 'during two'   # MyGame-2 is detached: its HEAD moves
    try {
        $r = Invoke-SlotCli $E @('branch-view', '-Apply') 180 @{ GIT_CONFIG_GLOBAL = $global }
        Assert-Exit $r 0
        Assert-Like $r '^\[branch-view\]   MyGame\s+fetched, '
        Assert-Like $r '^\[branch-view\]   MyGame-2\s+SKIP busy \(gc\.pid \d+ s old\)'
        Assert-True (Test-Path -LiteralPath $gcPid) 'the pack-objects hook ran (premise)'
        Assert-True ((Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') -ne $det) 'MyGame-2 not fetched while busy'
    } finally {
        if (Test-Path -LiteralPath $gcPid) { Remove-Item -LiteralPath $gcPid -Force }
        Remove-Item -LiteralPath $viewHook -Force
    }
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'branch-view ran a hook of the view'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-2/(detached)') $det 'MyGame-2 fetched after its gc'
}

# origin/* is filled fast-forward only: after a force push upstream the view keeps its value and says so.
Add-Test -Name 'branchview.origin-stale' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m1 = $E.Clones['MyGame-1']
    $view = Get-BvView $E
    $old = Get-BvRef $view 'refs/remotes/origin/feature/shared'
    Assert-True ($old -ne '') 'origin/feature/shared in the view'
    [void](Invoke-GitH @('checkout', '-q', 'feature/shared') $m1)
    [void](Invoke-GitH @('commit', '-q', '--amend', '-m', 'shared, rewritten') $m1)
    [void](Invoke-GitH @('push', '-q', '--force', 'origin', 'feature/shared') $m1)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m1)
    [void](Invoke-GitH @('fetch', '-q', 'origin') $m1)
    $new = Get-BvRef $m1 'refs/remotes/origin/feature/shared'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r ('origin partly stale here: 1 ref\(s\) refused from MyGame-1 .*: origin/feature/shared \(view {0}, slot {1}\)' -f $old.Substring(0, 7), $new.Substring(0, 7))
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/feature/shared') $old 'the view keeps its origin/feature/shared'
    $st = Get-BvState $E
    Assert-Equal (@($st.origin.rejected | ForEach-Object { '{0}|{1}|{2}' -f $_.name, $_.viewSha, $_.slotSha }) -join ';') ('origin/feature/shared|{0}|{1}' -f $old, $new) 'state origin.rejected'
    $dash = Get-BvDashboard $E
    Assert-Equal (@($dash.branchViews[0].origin.rejected | ForEach-Object { $_.name }) -join ',') 'origin/feature/shared' 'dashboard origin.rejected'
    $p = Invoke-SlotCli $E @('branch-view')
    Assert-Exit $p 0
    Assert-Like $p 'origin\s+unchanged \(from MyGame-1\); last run: origin partly stale here: 1 ref\(s\) refused'
}

# A git client that fetches origin in the view moves its origin/* past the slots': the next fill refuses
# those refs, but they are not stale (the slot's value is an ancestor of the view's). A shallow source slot
# fills origin with --update-shallow (without it git drops a ref that needs a new shallow boundary, exit 0).
Add-Test -Name 'branchview.origin-ahead' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $m1 = $E.Clones['MyGame-1']
    $m3 = Get-BvShallowPath $E
    $view = Get-BvView $E
    $origin = Join-Path $E.Dir 'origin\my-org\mygame.git'
    # a clone that is no slot, with objects of its own (no hard links into the slots' objects)
    $pusher = Join-Path $E.Dir 'pusher'
    if (-not (Test-Path -LiteralPath $pusher)) { [void](Invoke-GitH @('clone', '-q', '--no-local', $origin, $pusher)) }
    $tip = Add-BvCommit $pusher 'Assets\ahead.txt' 'ahead of every slot'
    [void](Invoke-GitH @('push', '-q', 'origin', 'master') $pusher)
    # what a git client does with the view's origin (its real URL)
    [void](Invoke-GitH @('fetch', '-q', 'origin') $view)
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/master') $tip 'the view fetched origin/master'
    # MyGame-1 learns feature/shared only: newest FETCH_HEAD, its origin/master stays behind the view's
    Start-Sleep -Milliseconds 50
    [void](Invoke-GitH @('fetch', '-q', 'origin', 'feature/shared') $m1)
    Assert-True ((Get-BvRef $m1 'refs/remotes/origin/master') -ne $tip) 'MyGame-1 origin/master behind (premise)'
    $j = Invoke-BvJson $E @('-Apply')
    Assert-Like $j.Run.Err 'origin\s+filled from MyGame-1, \d+ ref update\(s\); 1 ref\(s\) newer here than in MyGame-1' 'origin line'
    Assert-HasNot $j.Run.Err 'partly stale' 'origin line'
    $v = $j.Doc.views[0]
    Assert-Equal (@($v.origin.ahead) -join ',') 'origin/master' 'origin.ahead'
    Assert-Equal @($v.origin.rejected).Count 0 'origin.rejected'
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/master') $tip 'the view keeps the newer origin/master'
    Assert-Equal @((Get-BvState $E).origin.rejected).Count 0 'state origin.rejected'
    Assert-Equal @((Get-BvDashboard $E).branchViews[0].origin.rejected).Count 0 'dashboard origin.rejected'

    # MyGame-3 (shallow) catches up, then takes feature/z at depth 1: its FETCH_HEAD is the newest, and the
    # view has no history of feature/z
    [void](Invoke-GitH @('fetch', '-q', 'origin') $m3)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/z', 'master') $pusher)
    [void](Add-BvCommit $pusher 'Assets\z.txt' 'z one')
    $z = Add-BvCommit $pusher 'Assets\z.txt' 'z two'
    [void](Invoke-GitH @('push', '-q', 'origin', 'feature/z') $pusher)
    [void](Invoke-GitH @('checkout', '-q', 'master') $pusher)
    Start-Sleep -Milliseconds 50
    [void](Invoke-GitH @('fetch', '-q', '--depth', '1', 'origin', 'feature/z') $m3)
    Assert-Equal (Get-BvRef $m3 'refs/remotes/origin/feature/z') $z 'MyGame-3 origin/feature/z (premise)'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r '^\[branch-view\]   origin\s+filled from MyGame-3, [1-9]\d* ref update\(s\)'
    Assert-HasNot $r 'partly stale'
    Assert-Equal (Get-BvRef $view 'refs/remotes/origin/feature/z') $z 'origin/feature/z from the shallow slot'
}

# Slots that leave the registry or get another name: their remotes and refs go; a remote someone added by
# hand stays; a slot whose remote name a hand-made remote has is reported, not changed.
Add-Test -Name 'branchview.registry-change' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $view = Get-BvView $E
    $regFile = Join-Path $E.Home 'slots.json'
    $saved = [IO.File]::ReadAllText($regFile)
    [void](Invoke-GitH @('remote', 'add', 'mine', 'https://example.invalid/mine.git') $view)
    try {
        $reg = $saved | ConvertFrom-Json
        $reg.slots = @($reg.slots | Where-Object { $_.name -ne 'MyGame-3' })
        foreach ($s in @($reg.slots)) { if ($s.name -eq 'MyGame-2') { $s.name = 'MyGame-Two' } }
        Write-TextFile $regFile ($reg | ConvertTo-Json -Depth 6)
        $p = Invoke-SlotCli $E @('branch-view')
        Assert-Exit $p 0
        Assert-Like $p 'remotes\s+add MyGame-Two; remove MyGame-2, MyGame-3 \(not in the registry any more\)'
        $r = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $r 0
        Assert-Like $r 'remotes\s+removed MyGame-2, MyGame-3 \(not in the registry any more\)'
        Assert-Like $r 'remotes\s+added MyGame-Two'
        Assert-Equal ((@(Invoke-GitH @('remote') $view) | Sort-Object) -join ',') 'mine,MyGame,MyGame-1,MyGame-Two,origin' 'remotes'
        Assert-Equal @(Get-BvRefs $view 'refs/remotes/MyGame-2').Count 0 'refs of MyGame-2'
        Assert-Equal @(Get-BvRefs $view 'refs/remotes/MyGame-3').Count 0 'refs of MyGame-3'
        Assert-Equal (Get-BvRef $view 'refs/remotes/MyGame-Two/(detached)') (Get-BvRef $E.Clones['MyGame-2'] 'HEAD') 'MyGame-Two/(detached)'
        Assert-Equal (@(Invoke-GitH @('config', '--get', 'remote.mine.url') $view)[0]) 'https://example.invalid/mine.git' 'the hand-made remote stays'
        $dash = Get-BvDashboard $E
        Assert-Equal (@($dash.branchViews[0].slots | ForEach-Object { $_.slot }) -join ',') 'MyGame,MyGame-1,MyGame-Two' 'dashboard slots after the rename'

        # a slot named like the hand-made remote: reported, the remote left alone
        foreach ($s in @($reg.slots)) { if ($s.name -eq 'MyGame-Two') { $s.name = 'mine' } }
        Write-TextFile $regFile ($reg | ConvertTo-Json -Depth 6)
        $c = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $c 0
        Assert-Like $c '^\[branch-view\]   mine\s+FAILED the view has a remote "mine" that branch-view did not add'
        Assert-Like $c 'remotes\s+removed MyGame-Two'
        Assert-Equal (@(Invoke-GitH @('config', '--get-all', 'remote.mine.url') $view) -join ',') 'https://example.invalid/mine.git' 'the hand-made remote unchanged'
        Assert-Equal (Get-BvRef $view 'refs/remotes/mine/(detached)') '' 'nothing fetched into the hand-made remote'
    } finally {
        Write-TextFile $regFile $saved
    }
    [void](Invoke-GitH @('remote', 'remove', 'mine') $view)
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Like $r 'remotes\s+added MyGame-2, MyGame-3'
    Assert-Equal ((@(Invoke-GitH @('remote') $view) | Sort-Object) -join ',') 'MyGame,MyGame-1,MyGame-2,MyGame-3,origin' 'remotes restored'
}

# A registry origin that is a slot folder (here as a file:// URL): the view's origin gets a placeholder URL
# like the slot remotes, so a git client fetching origin cannot read that slot; back to the real URL after.
Add-Test -Name 'branchview.origin-url-slot' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $view = Get-BvView $E
    $regFile = Join-Path $E.Home 'slots.json'
    $saved = [IO.File]::ReadAllText($regFile)
    $realUrl = [string](@(Invoke-GitH @('config', '--get', 'remote.origin.url') $view)[0])
    $before = Get-BvSnapshot (Get-BvSlotPaths $E)
    try {
        $reg = $saved | ConvertFrom-Json
        $slotUrl = 'file:///' + $E.Clones['MyGame-1'].Replace('\', '/')
        foreach ($s in @($reg.slots)) { $s.origin = $slotUrl }
        Write-TextFile $regFile ($reg | ConvertTo-Json -Depth 6)
        $p = Invoke-SlotCli $E @('branch-view')
        Assert-Exit $p 0
        Assert-Like $p 'origin\s+.*remote origin unity-slot-view://origin \(the registry''s origin is the folder of slot MyGame-1'
        $r = Invoke-SlotCli $E @('branch-view', '-Apply')
        Assert-Exit $r 0
        Assert-Like $r 'origin\s+note: the registry''s origin is the folder of slot MyGame-1'
        Assert-Equal (@(Invoke-GitH @('config', '--get-all', 'remote.origin.url') $view) -join ',') 'unity-slot-view://origin' 'origin url'
        $g = Invoke-BvGitRaw @('fetch', 'origin') $view
        Assert-True ($g.Code -ne 0) ('git fetch origin in the view succeeded: ' + $g.Text)
        Assert-Like $g.Text 'unity-slot-view' 'git fetch origin error'
    } finally {
        Write-TextFile $regFile $saved
    }
    Assert-BvSnapshotSame $before (Get-BvSnapshot (Get-BvSlotPaths $E)) 'origin URL that is a slot'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    Assert-Equal (@(Invoke-GitH @('config', '--get-all', 'remote.origin.url') $view) -join ',') $realUrl 'origin url restored'
}
# The older bare form (<root>\<name>.git, as a pre-release 0.7.0 made it; Fork does not open it): the plan only shows the
# move, a <root>\<name> that is someone else's folder is left alone (exit 1), and -Apply moves the bare
# folder to <root>\<name>\.git (same volume, not copied) with core.bare false. Refs, remotes and the state
# file carry on: nothing is fetched again.
Add-Test -Name 'branchview.move-old-bare' -Group 'branchview' -Body {
    param($E)
    Initialize-BvView $E
    $root = Get-BvRoot $E
    $folder = Get-BvFolder $E
    $old = Join-Path $root 'mygame.git'
    $r = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $r 0
    $view = Get-BvView $E
    $refs0 = @(Get-BvRefs $view 'refs/remotes')
    $remotes0 = @(Invoke-GitH @('config', '--get-regexp', '^remote\.') $view)
    Assert-True ($refs0.Count -gt 5) ('refs before: ' + $refs0.Count)
    # the older form: a bare repository beside the state file, whose path names it (no gitDir)
    [IO.Directory]::Move($view, $old)
    [IO.Directory]::Delete($folder)
    [void](Invoke-GitH @('config', '--file', (Join-Path $old 'config'), 'core.bare', 'true'))
    $stateFile = Join-Path $root 'mygame.view.json'
    $st = [IO.File]::ReadAllText($stateFile, $script:Utf8) | ConvertFrom-Json
    $st.path = $old
    $st.PSObject.Properties.Remove('gitDir')
    Write-TextFile $stateFile ($st | ConvertTo-Json -Depth 10)
    Assert-Equal (@(Invoke-GitH @('rev-parse', '--is-bare-repository') $old)[0]) 'true' 'the older form is bare (premise)'
    $dash = Get-BvDashboard $E
    Assert-True ((Test-SamePathH $dash.branchViews[0].gitDir $old) -and -not $dash.branchViews[0].error) ('dashboard of the older form: ' + $dash.branchViews[0].gitDir + ' ' + $dash.branchViews[0].error)

    # the plan shows the move and writes nothing
    $before = Get-BvRootSnapshot $E
    $p = Invoke-SlotCli $E @('branch-view')
    Assert-Exit $p 0
    Assert-Like $p '^\[branch-view\]   move\s+older bare form \S*\\mygame\.git -> folder form \S*\\mygame\\\.git \(-Apply moves it'
    Assert-Like $p '^\[branch-view\]   open\s+\S*\\mygame \(the folder to open in Fork'
    Assert-Has $p '[branch-view] next    unity-slot branch-view -Apply'
    $j = Invoke-BvJson $E
    $v = $j.Doc.views[0]
    Assert-True ((Test-SamePathH $v.moveFrom $old) -and $v.exists -eq $true -and $v.action -eq 'none') ('plan: moveFrom {0}, exists {1}, action {2}' -f $v.moveFrom, $v.exists, $v.action)
    foreach ($s in @($v.slots)) { Assert-Equal $s.action 'unchanged' ($s.slot + ' planned') }
    $diff = @(Compare-Object $before (Get-BvRootSnapshot $E))
    Assert-Equal $diff.Count 0 'the dry runs changed the view root'

    # someone else's folder at <root>\mygame: both left alone, exit 1
    [void](New-Item -ItemType Directory -Path $folder)
    Write-TextFile (Join-Path $folder 'someone.txt') "not a view`n"
    $c = Invoke-SlotCli $E @('branch-view', '-Apply')
    Assert-Exit $c 1
    Assert-Like $c 'ERROR \S*\\mygame already exists, so the older bare view \S*\\mygame\.git cannot move there; both left alone'
    Assert-Equal (@(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object { $_.Name }) -join ',') 'someone.txt' 'the other folder untouched'
    Assert-True (Test-Path -LiteralPath (Join-Path $old 'HEAD')) 'the older form left alone'
    Assert-Equal (@(Invoke-GitH @('rev-parse', '--is-bare-repository') $old)[0]) 'true' 'the older form still bare'
    Remove-Item -LiteralPath $folder -Recurse -Force

    # the move
    $n0 = Get-EventCount $E
    $j = Invoke-BvJson $E @('-Apply')
    Assert-Like $j.Run.Err 'my-org/mygame: moved the older bare form \S*\\mygame\.git to \S*\\mygame\\\.git' 'move line'
    Assert-True (-not (Test-Path -LiteralPath $old)) 'the older form is gone'
    Assert-BvFolderForm $E 'moved'
    $view = Get-BvView $E
    $v = $j.Doc.views[0]
    Assert-True ((Test-SamePathH $v.moveFrom $old) -and $v.action -eq 'none') ('apply: moveFrom {0}, action {1}' -f $v.moveFrom, $v.action)
    foreach ($s in @($v.slots)) { Assert-Equal ('{0}|{1}' -f $s.action, $s.status) 'unchanged|unchanged' ($s.slot + ' after the move') }
    Assert-Equal $v.origin.action 'unchanged' 'origin after the move'
    Assert-Equal (@(Get-BvRefs $view 'refs/remotes') -join ';') ($refs0 -join ';') 'refs carry on'
    Assert-Equal (@(Invoke-GitH @('config', '--get-regexp', '^remote\.') $view) -join ';') ($remotes0 -join ';') 'remotes carry on'
    $st = Get-BvState $E
    Assert-True ((Test-SamePathH $st.path $folder) -and (Test-SamePathH $st.gitDir $view)) ('state path/gitDir ' + $st.path + ' ' + $st.gitDir)
    $ev = @(Get-NewEvents $E $n0 | Where-Object { $_.event -eq 'branchview' })
    Assert-True ($ev.Count -eq 1 -and (Test-SamePathH $ev[0].detail.movedFrom $old)) ('event movedFrom ' + ($ev | ConvertTo-Json -Compress -Depth 5))
    $dash = Get-BvDashboard $E
    Assert-True ((Test-SamePathH $dash.branchViews[0].path $folder) -and (Test-SamePathH $dash.branchViews[0].gitDir $view) -and -not $dash.branchViews[0].error) 'dashboard after the move'

    # a second run: nothing to move, nothing to fetch
    $j = Invoke-BvJson $E @('-Apply')
    Assert-True ($null -eq $j.Doc.views[0].moveFrom -and $j.Doc.views[0].action -eq 'none') ('second run: ' + $j.Doc.views[0].action)
    Assert-BvFolderForm $E 'second run'
}
