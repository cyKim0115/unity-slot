# repos[] of the dashboard (0.7.0): one entry per common git directory with its working folders (also with
# basic) and, with -Git full, the local branches, commits on no origin, stashes and flags; slots' new git
# fields (head, detached, changesDetail, gitDir); and that reading changes nothing in .git.
# Dot-sourced by tests\run-tests.ps1. ASCII-only source.
#
# The group pushes to an origin of its own (envs\repos\origin\mygame.git, a bare copy of the shared fake
# origin), so other groups that clone the shared origin meanwhile see nothing of it.

Register-Group 'repos' -Clones @('MyGame', 'MyGame-1', 'MyGame-2')

$script:RepoFields = 'commonDir,project,repo,level,layout,hub,lastFetchAt,defaultBranch,folders,branches,stashes,localOnly,flags,error'
$script:FolderFields = 'path,slot,main,branch,head,detached,locked,prunable,localOnly'
$script:BranchFields = 'name,tip,tipAt,subject,upstream,upstreamGone,ahead,behind,baseAhead,baseBehind,merged,localOnly,checkedOutBy'

function Get-ReposNames($Object) { return (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') }

function Get-ReposDoc($E, [string]$Level) {
    $d = Invoke-SlotCli $E @('dashboard', '-Json', '-Git', $Level)
    Assert-Exit $d 0
    Assert-True ([string]::IsNullOrWhiteSpace($d.Err)) ('dashboard stderr: ' + $d.Err)
    return ($d.Out | ConvertFrom-Json)
}

function Get-ReposSlot($Doc, [string]$Name) {
    $s = @($Doc.slots | Where-Object { $_.name -eq $Name })
    Assert-Equal $s.Count 1 ('slot ' + $Name)
    return $s[0]
}

function Get-ReposEntry($Doc, [string]$Slot) {
    $s = Get-ReposSlot $Doc $Slot
    $r = @($Doc.repos | Where-Object { Test-SamePathH $_.commonDir $s.git.commonDir })
    Assert-Equal $r.Count 1 ('repos entries of ' + $Slot)
    return $r[0]
}

function Get-ReposBranch($Repo, [string]$Name, [string]$Slot) {
    $b = @($Repo.branches | Where-Object { $_.name -eq $Name })
    Assert-Equal $b.Count 1 ('branch ' + $Name + ' of ' + $Slot)
    return $b[0]
}

function Get-ReposRev([string]$Dir, [string]$Rev) { return [string](@(Invoke-GitH @('rev-parse', $Rev) $Dir)[0]) }

# Commits, branches and working changes the full test reads (once per environment):
#   MyGame-1: master pushed, then one unpushed commit; feature/shared pushed and in step; feature/gone
#             pushed and deleted on origin (upstream gone); feature/x and side local only; and a merge
#             of side that stops on a conflict (one conflicted, one staged entry).
#   MyGame:   fetched; one unpushed master commit dated 30 days back (local-only-old); feature/x (same
#             name, other tip) two more commits; a stash on feature/x, then a newer one on master; one
#             staged, unstaged, untracked entry.
#   MyGame-2: fetched; remote peer = the folder of MyGame-1 (a local path: does not count as a remote) and
#             feature/peer from peer/feature/x; remote mirror with a server URL that has
#             feature/mirrored (counts as a remote); a detached HEAD with one commit of its own.
function Initialize-ReposScenario($E) {
    $marker = Join-Path $E.Dir 'repos-scenario.txt'
    if (Test-Path -LiteralPath $marker) { return }
    $origin = Join-Path $E.Dir 'origin\mygame.git'
    [void](Invoke-GitH @('clone', '-q', '--bare', (Get-OriginPath), $origin))
    foreach ($c in @($E.Clones.Values)) {
        [void](Invoke-GitH @('remote', 'set-url', 'origin', $origin) $c)
        [void](Invoke-GitH @('fetch', '-q', 'origin') $c)
    }
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']

    Write-TextFile (Join-Path $m1 'Assets\one.txt') "one`n"
    [void](Invoke-GitH @('add', '-A') $m1)
    [void](Invoke-GitH @('commit', '-q', '-m', 'm1 pushed') $m1)
    [void](Invoke-GitH @('push', '-q', 'origin', 'master') $m1)
    foreach ($b in @('feature/shared', 'feature/gone')) {
        [void](Invoke-GitH @('checkout', '-q', '-b', $b) $m1)
        Write-TextFile (Join-Path $m1 ('Assets\' + $b.Replace('/', '-') + '.txt')) ($b + "`n")
        [void](Invoke-GitH @('add', '-A') $m1)
        [void](Invoke-GitH @('commit', '-q', '-m', ($b + ' work')) $m1)
        [void](Invoke-GitH @('push', '-q', '-u', 'origin', $b) $m1)
        [void](Invoke-GitH @('checkout', '-q', 'master') $m1)
    }
    [void](Invoke-GitH @('push', '-q', 'origin', '--delete', 'feature/gone') $m1)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/x') $m1)
    Write-TextFile (Join-Path $m1 'Assets\x1.txt') "x1`n"
    [void](Invoke-GitH @('add', '-A') $m1)
    [void](Invoke-GitH @('commit', '-q', '-m', 'x on 1') $m1)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'side', 'master') $m1)
    Write-TextFile (Join-Path $m1 'Assets\conflict.txt') "side`n"
    Write-TextFile (Join-Path $m1 'Assets\side-only.txt') "side only`n"
    [void](Invoke-GitH @('add', '-A') $m1)
    [void](Invoke-GitH @('commit', '-q', '-m', 'side') $m1)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m1)
    Write-TextFile (Join-Path $m1 'Assets\conflict.txt') "master`n"
    [void](Invoke-GitH @('add', '-A') $m1)
    [void](Invoke-GitH @('commit', '-q', '-m', 'conflict on master') $m1)
    $merged = $true
    try { [void](Invoke-GitH @('merge', '-q', '--no-edit', 'side') $m1) } catch { $merged = $false }
    Assert-True (-not $merged) 'the merge of side stops on a conflict'

    [void](Invoke-GitH @('fetch', '-q', 'origin') $m0)
    $old = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd'T'HH:mm:ss", $script:Inv)
    $env:GIT_AUTHOR_DATE = $old
    $env:GIT_COMMITTER_DATE = $old
    try {
        Write-TextFile (Join-Path $m0 'Assets\old.txt') "old`n"
        [void](Invoke-GitH @('add', '-A') $m0)
        [void](Invoke-GitH @('commit', '-q', '-m', 'old unpushed') $m0)
    } finally {
        $env:GIT_AUTHOR_DATE = $null
        $env:GIT_COMMITTER_DATE = $null
    }
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/x') $m0)
    foreach ($n in @('one', 'two')) {
        Write-TextFile (Join-Path $m0 ('Assets\x-' + $n + '.txt')) ($n + "`n")
        [void](Invoke-GitH @('add', '-A') $m0)
        [void](Invoke-GitH @('commit', '-q', '-m', ('x ' + $n)) $m0)
    }
    Write-TextFile (Join-Path $m0 'Assets\x-one.txt') "one, stashed`n"
    [void](Invoke-GitH @('stash', 'push', '-q', '-m', 'older on x') $m0)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m0)
    Write-TextFile (Join-Path $m0 'Assets\old.txt') "old, stashed`n"
    [void](Invoke-GitH @('stash', 'push', '-q', '-m', 'keep this') $m0)
    Write-TextFile (Join-Path $m0 'Assets\staged.txt') "staged`n"
    [void](Invoke-GitH @('add', 'Assets/staged.txt') $m0)
    Write-TextFile (Join-Path $m0 'Assets\old.txt') "old, changed`n"
    Write-TextFile (Join-Path $m0 'Assets\untracked.txt') "untracked`n"

    [void](Invoke-GitH @('fetch', '-q', 'origin') $m2)
    [void](Invoke-GitH @('remote', 'add', 'peer', $m1) $m2)
    [void](Invoke-GitH @('fetch', '-q', 'peer') $m2)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/peer', 'peer/feature/x') $m2)
    [void](Invoke-GitH @('checkout', '-q', 'master') $m2)
    [void](Invoke-GitH @('remote', 'add', 'mirror', 'https://example.invalid/mygame.git') $m2)
    [void](Invoke-GitH @('checkout', '-q', '-b', 'feature/mirrored') $m2)
    Write-TextFile (Join-Path $m2 'Assets\mirrored.txt') "mirrored`n"
    [void](Invoke-GitH @('add', '-A') $m2)
    [void](Invoke-GitH @('commit', '-q', '-m', 'mirrored') $m2)
    [void](Invoke-GitH @('update-ref', 'refs/remotes/mirror/feature/mirrored', 'HEAD') $m2)
    [void](Invoke-GitH @('checkout', '-q', '--detach', 'master') $m2)
    Write-TextFile (Join-Path $m2 'Assets\detached.txt') "detached`n"
    [void](Invoke-GitH @('add', '-A') $m2)
    [void](Invoke-GitH @('commit', '-q', '-m', 'detached work') $m2)
    Write-TextFile $marker "done`n"
}

# Every entry of the clones' .git folders: files with size, time and SHA-256, folders with their own
# write time (read directly: a listing's value lags behind).
function Get-ReposGitSnapshot($E) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($c in @($E.Clones.Values | Sort-Object)) {
            $root = Join-Path $c '.git'
            $lines.Add(('D|{0}|{1}' -f $root, [IO.Directory]::GetLastWriteTimeUtc($root).Ticks))
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
                if ($item.PSIsContainer) {
                    $lines.Add(('D|{0}|{1}' -f $item.FullName, [IO.Directory]::GetLastWriteTimeUtc($item.FullName).Ticks))
                } else {
                    $hash = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($item.FullName)) | ForEach-Object { $_.ToString('x2') })
                    $lines.Add(('F|{0}|{1}|{2}|{3}' -f $item.FullName, $item.Length, [IO.File]::GetLastWriteTimeUtc($item.FullName).Ticks, $hash))
                }
            }
        }
    } finally { $sha.Dispose() }
    return $lines.ToArray()
}

Add-Test -Name 'repos.basic-shape' -Group 'repos' -Body {
    param($E)
    $doc = Get-ReposDoc $E 'basic'
    Assert-Equal (@($doc.PSObject.Properties | ForEach-Object { $_.Name }) | Select-Object -Last 3) 'timing repos branchViews' 'repos comes after timing, then branchViews'
    Assert-Equal @($doc.repos).Count 3 'repos (one per clone)'
    foreach ($name in @('MyGame', 'MyGame-1', 'MyGame-2')) {
        $s = Get-ReposSlot $doc $name
        $r = Get-ReposEntry $doc $name
        Assert-True (Test-SamePathH $s.git.gitDir (Join-Path $s.path '.git')) ($name + ' git.gitDir ' + $s.git.gitDir)
        Assert-True (Test-SamePathH $s.git.commonDir $s.git.gitDir) ($name + ' commonDir = gitDir in a clone')
        Assert-Equal (Get-ReposNames $r) $script:RepoFields ($name + ' repo fields')
        Assert-Equal $r.project $s.project ($name + ' project')
        Assert-Equal $r.repo $s.repo ($name + ' repo')
        Assert-Equal $r.level 'basic' ($name + ' level')
        Assert-Equal $r.layout 'clone' ($name + ' layout')
        Assert-True ($null -eq $r.hub) ($name + ' hub null')
        Assert-Equal $r.defaultBranch 'origin/master' ($name + ' defaultBranch')
        Assert-Equal $r.lastFetchAt $s.git.lastFetchAt ($name + ' lastFetchAt')
        foreach ($k in @('branches', 'stashes', 'localOnly', 'flags', 'error')) { Assert-True ($null -eq $r.$k) ($name + ' ' + $k + ' is null with basic') }
        Assert-Equal @($r.folders).Count 1 ($name + ' folders')
        $f = $r.folders[0]
        Assert-Equal (Get-ReposNames $f) $script:FolderFields ($name + ' folder fields')
        Assert-True (Test-SamePathH $f.path $s.path) ($name + ' folder path ' + $f.path)
        Assert-Equal $f.slot $name ($name + ' folder slot')
        Assert-True ($f.main -eq $true) ($name + ' folder main')
        Assert-Equal $f.branch 'master' ($name + ' folder branch')
        Assert-Equal $f.head $s.git.head ($name + ' folder head = slot git.head')
        Assert-Equal $f.head (Get-ReposRev $s.path 'HEAD') ($name + ' head = git rev-parse HEAD')
        Assert-True ($f.detached -eq $false) ($name + ' folder detached')
        foreach ($k in @('locked', 'prunable', 'localOnly')) { Assert-True ($null -eq $f.$k) ($name + ' folder ' + $k + ' null') }
    }
    # the summary's document (-Shallow) has the key with null
    $sh = Invoke-Fixture $E 'dashboard-shallow.ps1'
    Assert-Exit $sh 0
    $j = $sh.Out | ConvertFrom-Json
    Assert-True ($j.hasRepos -eq $true) 'shallow document has repos'
    Assert-True ($null -eq $j.repos) 'shallow repos is null'
    Assert-True ($j.hasBranchViews -eq $true -and $null -eq $j.branchViews) 'shallow branchViews is null'
    Assert-Equal $j.slots 3 'shallow slots'
}

Add-Test -Name 'repos.full-branches' -Group 'repos' -Body {
    param($E)
    Initialize-ReposScenario $E
    $doc = Get-ReposDoc $E 'full'
    $m0 = $E.Clones['MyGame']
    $m1 = $E.Clones['MyGame-1']
    $m2 = $E.Clones['MyGame-2']

    # MyGame: an old unpushed commit, feature/x on top, a stash, one change of each kind but conflicts
    $s0 = Get-ReposSlot $doc 'MyGame'
    $r0 = Get-ReposEntry $doc 'MyGame'
    Assert-Equal $r0.level 'full' 'MyGame level'
    Assert-Equal (@($s0.git.changesDetail.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ',') 'staged=1,unstaged=1,untracked=1,conflicted=0' 'MyGame changesDetail'
    Assert-Equal $s0.git.changes 3 'MyGame changes'
    Assert-Equal $r0.localOnly.commits 3 'MyGame repo localOnly'
    Assert-True (@($r0.flags) -contains 'local-only-old') ('MyGame repo flags: ' + (@($r0.flags) -join ','))
    Assert-True (@($s0.flags) -contains 'local-only-old') 'MyGame slot flag local-only-old'
    Assert-Equal $s0.git.localOnly.commits 3 'MyGame slot git.localOnly'
    Assert-Equal $s0.git.stash 2 'MyGame slot git.stash'
    Assert-Equal @($r0.branches).Count 2 'MyGame branches'
    foreach ($b in @($r0.branches)) { Assert-Equal (Get-ReposNames $b) $script:BranchFields ('MyGame ' + $b.name + ' fields') }
    $b = Get-ReposBranch $r0 'master' 'MyGame'
    Assert-Equal $b.tip (Get-ReposRev $m0 'master') 'MyGame master tip'
    Assert-Equal $b.subject 'old unpushed' 'MyGame master subject'
    Assert-Equal $b.upstream 'origin/master' 'MyGame master upstream'
    Assert-Equal ('{0}/{1}' -f $b.ahead, $b.behind) '1/1' 'MyGame master ahead/behind'
    Assert-Equal ('{0}/{1}/{2}' -f $b.baseAhead, $b.baseBehind, $b.merged) '1/1/False' 'MyGame master against origin/master'
    Assert-Equal $b.localOnly.commits 1 'MyGame master localOnly'
    Assert-True (([datetime]::Now - [datetime]::Parse($b.localOnly.oldestAt, $script:Inv)).TotalDays -gt 29) ('MyGame master oldestAt ' + $b.localOnly.oldestAt)
    Assert-Equal @($b.checkedOutBy).Count 1 'MyGame master checkedOutBy'
    Assert-Equal $b.checkedOutBy[0].slot 'MyGame' 'MyGame master checked out by MyGame'
    Assert-True (Test-SamePathH $b.checkedOutBy[0].path $m0) ('MyGame master checked out in ' + $b.checkedOutBy[0].path)
    $x0 = Get-ReposBranch $r0 'feature/x' 'MyGame'
    Assert-Equal $x0.subject 'x two' 'MyGame feature/x subject'
    Assert-True ($null -eq $x0.upstream -and $null -eq $x0.ahead -and $x0.upstreamGone -eq $false) 'MyGame feature/x has no upstream'
    Assert-Equal $x0.localOnly.commits 3 'MyGame feature/x localOnly (its two and master''s one)'
    Assert-Equal ('{0}/{1}/{2}' -f $x0.baseAhead, $x0.baseBehind, $x0.merged) '3/1/False' 'MyGame feature/x against origin/master'
    Assert-Equal @($x0.checkedOutBy).Count 0 'MyGame feature/x not checked out'
    Assert-Equal @($r0.stashes).Count 2 'MyGame stashes'
    $st = $r0.stashes[0]
    Assert-Equal ('{0}|{1}|{2}' -f $st.index, $st.branch, $st.message) '0|master|On master: keep this' 'MyGame stash@{0} (the newest)'
    Assert-Equal $st.sha (Get-ReposRev $m0 'stash@{0}') 'MyGame stash@{0} sha'
    $st1 = $r0.stashes[1]
    Assert-Equal ('{0}|{1}|{2}' -f $st1.index, $st1.branch, $st1.message) '1|feature/x|On feature/x: older on x' 'MyGame stash@{1}'
    Assert-Equal $st1.sha (Get-ReposRev $m0 'stash@{1}') 'MyGame stash@{1} sha'
    Assert-True ([DateTimeOffset]::Parse($st.at, $script:Inv) -ge [DateTimeOffset]::Parse($st1.at, $script:Inv)) ('stash times ' + $st.at + ' / ' + $st1.at)

    # MyGame-1: upstream in step, upstream gone, two local-only branches, a conflicted merge
    $s1 = Get-ReposSlot $doc 'MyGame-1'
    $r1 = Get-ReposEntry $doc 'MyGame-1'
    Assert-Equal (@($s1.git.changesDetail.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ',') 'staged=1,unstaged=0,untracked=0,conflicted=1' 'MyGame-1 changesDetail'
    Assert-Equal (@($r1.branches | ForEach-Object { $_.name }) -join ',') 'feature/gone,feature/shared,feature/x,master,side' 'MyGame-1 branches'
    Assert-Equal ('{0}/{1}/{2}' -f $s1.git.branches.total, $s1.git.branches.noUpstream, $s1.git.branches.upstreamGone) '5/2/1' 'MyGame-1 slot git.branches'
    Assert-Equal $r1.localOnly.commits 4 'MyGame-1 repo localOnly'
    Assert-Equal @($r1.flags).Count 0 ('MyGame-1 flags: ' + (@($r1.flags) -join ','))
    $sh = Get-ReposBranch $r1 'feature/shared' 'MyGame-1'
    Assert-Equal ('{0}|{1}|{2}|{3}|{4}' -f $sh.upstream, $sh.upstreamGone, $sh.ahead, $sh.behind, $sh.localOnly.commits) 'origin/feature/shared|False|0|0|0' 'MyGame-1 feature/shared'
    Assert-Equal ('{0}/{1}/{2}' -f $sh.baseAhead, $sh.baseBehind, $sh.merged) '1/0/False' 'MyGame-1 feature/shared against origin/master'
    $gone = Get-ReposBranch $r1 'feature/gone' 'MyGame-1'
    Assert-True ($gone.upstreamGone -eq $true -and $null -eq $gone.ahead -and $null -eq $gone.behind) 'MyGame-1 feature/gone upstream gone'
    Assert-Equal $gone.localOnly.commits 1 'MyGame-1 feature/gone localOnly (deleted on origin)'
    $ma1 = Get-ReposBranch $r1 'master' 'MyGame-1'
    Assert-Equal ('{0}/{1}/{2}' -f $ma1.ahead, $ma1.behind, $ma1.localOnly.commits) '1/0/1' 'MyGame-1 master'
    $x1 = Get-ReposBranch $r1 'feature/x' 'MyGame-1'
    Assert-Equal $x1.localOnly.commits 1 'MyGame-1 feature/x localOnly'
    Assert-True ($x1.tip -ne $x0.tip) 'feature/x has another tip in each clone'

    # MyGame-2: a remote at a local path does not count, one with a server URL does; detached HEAD
    $s2 = Get-ReposSlot $doc 'MyGame-2'
    $r2 = Get-ReposEntry $doc 'MyGame-2'
    Assert-True ($s2.git.detached -eq $true) 'MyGame-2 slot git.detached'
    Assert-Equal $s2.git.branch '(detached)' 'MyGame-2 slot git.branch stays as git reports it'
    Assert-Equal $s2.git.head (Get-ReposRev $m2 'HEAD') 'MyGame-2 slot git.head'
    $peer = Get-ReposBranch $r2 'feature/peer' 'MyGame-2'
    Assert-Equal ('{0}|{1}|{2}' -f $peer.upstream, $peer.ahead, $peer.behind) 'peer/feature/x|0|0' 'MyGame-2 feature/peer upstream'
    Assert-Equal $peer.localOnly.commits 1 'MyGame-2 feature/peer: only on another clone = local only'
    $mir = Get-ReposBranch $r2 'feature/mirrored' 'MyGame-2'
    Assert-Equal $mir.localOnly.commits 0 'MyGame-2 feature/mirrored: on a server remote'
    $ma2 = Get-ReposBranch $r2 'master' 'MyGame-2'
    Assert-Equal ('{0}/{1}/{2}/{3}' -f $ma2.ahead, $ma2.behind, $ma2.baseAhead, $ma2.merged) '0/1/0/True' 'MyGame-2 master'
    Assert-Equal $r2.localOnly.commits 1 'MyGame-2 repo localOnly (feature/peer)'
    foreach ($b in @($r2.branches)) { Assert-Equal @($b.checkedOutBy).Count 0 ('MyGame-2 ' + $b.name + ' not checked out (detached)') }
    $f2 = $r2.folders[0]
    Assert-True ($f2.detached -eq $true -and $null -eq $f2.branch) 'MyGame-2 folder detached, no branch'
    Assert-Equal $f2.head $s2.git.head 'MyGame-2 folder head'
    Assert-Equal $f2.localOnly.commits 1 'MyGame-2 folder localOnly (the detached commit)'
    Assert-Equal (@($r2.flags) -join ',') 'detached-local-only' 'MyGame-2 flags'
    Assert-Equal @($r2.stashes).Count 0 'MyGame-2 stashes'
    Assert-Equal @($s2.git.worktrees).Count 0 'MyGame-2 worktrees'

    # basic keeps the folders up to date and leaves the full fields null
    $bd = Get-ReposDoc $E 'basic'
    $b2 = Get-ReposEntry $bd 'MyGame-2'
    Assert-True ($b2.folders[0].detached -eq $true -and $b2.folders[0].head -eq $s2.git.head) 'basic folder of MyGame-2'
    Assert-True ($null -eq $b2.branches -and $null -eq $b2.flags -and $null -eq $b2.folders[0].localOnly) 'basic leaves the full fields null'
}

# The paths a current git and a normal repository do not take, played in-process by a fixture: git before
# 2.41 (no %(ahead-behind): merged from --merged, the counts null), a default branch that does not resolve,
# and more commits on no origin than the per-branch walk takes (the per-branch values null).
Add-Test -Name 'repos.fallbacks' -Group 'repos' -Body {
    param($E)
    Initialize-ReposScenario $E
    $doc = Get-ReposDoc $E 'full'
    $normal = @{}
    foreach ($r in @($doc.repos)) {
        foreach ($b in @($r.branches)) { $normal[$r.folders[0].slot + '|' + $b.name] = $b }
    }
    $variants = @{}
    foreach ($v in @('old-git', 'no-default', 'walk-max')) {
        $f = Invoke-Fixture $E 'dashboard-git-variants.ps1' @('-Variant', $v)
        Assert-Exit $f 0
        $variants[$v] = $f.Out | ConvertFrom-Json
        Assert-Equal $variants[$v].variant $v ('fixture variant ' + $v)
        Assert-Equal @($variants[$v].repos).Count 3 ($v + ' repos')
        foreach ($r in @($variants[$v].repos)) {
            Assert-True ($null -eq $r.error) ($v + ' ' + $r.slot + ' error: ' + $r.error)
            $names = (@($r.branches | ForEach-Object { $_.name }) -join ',')
            $want = (@(@($doc.repos | Where-Object { $_.folders[0].slot -eq $r.slot })[0].branches | ForEach-Object { $_.name }) -join ',')
            Assert-Equal $names $want ($v + ' ' + $r.slot + ' branches')
        }
    }

    # git before 2.41: the for-each-ref with %(ahead-behind) fails, one without it and one --merged follow
    $og = $variants['old-git']
    Assert-Equal @($og.refCalls | Where-Object { $_ -match 'no-such-field' }).Count 3 'old-git: one failing for-each-ref per repository'
    Assert-Equal @($og.refCalls | Where-Object { $_ -match '--merged origin/master' }).Count 3 'old-git: one --merged per repository'
    $mergedTrue = 0
    foreach ($r in @($og.repos)) {
        foreach ($b in @($r.branches)) {
            $n = $normal[$r.slot + '|' + $b.name]
            Assert-True ($null -eq $b.baseAhead -and $null -eq $b.baseBehind) ('old-git ' + $r.slot + ' ' + $b.name + ' counts null')
            Assert-Equal $b.merged $n.merged ('old-git ' + $r.slot + ' ' + $b.name + ' merged from --merged = merged from ahead-behind')
            Assert-Equal $b.localOnly.commits $n.localOnly.commits ('old-git ' + $r.slot + ' ' + $b.name + ' localOnly')
            if ($b.merged -eq $true) { $mergedTrue++ }
        }
    }
    Assert-True ($mergedTrue -ge 1) 'old-git: at least one merged branch (MyGame-2 master)'

    # a default branch that does not resolve: no error, the default-branch values null, the rest as usual
    foreach ($r in @($variants['no-default'].repos)) {
        Assert-Equal $r.defaultBranch 'origin/nope' ('no-default ' + $r.slot + ' defaultBranch')
        foreach ($b in @($r.branches)) {
            Assert-True ($null -eq $b.baseAhead -and $null -eq $b.baseBehind -and $null -eq $b.merged) ('no-default ' + $r.slot + ' ' + $b.name + ' base values null')
            Assert-Equal $b.localOnly.commits $normal[$r.slot + '|' + $b.name].localOnly.commits ('no-default ' + $r.slot + ' ' + $b.name + ' localOnly')
        }
    }

    # walk limit 2: repositories with more commits on no origin (MyGame 3, MyGame-1 4) keep the repository
    # count and leave the per-branch values null; MyGame-2 (1) still has them
    $by = @{}
    foreach ($r in @($variants['walk-max'].repos)) { $by[$r.slot] = $r }
    foreach ($pair in @(@('MyGame', 3), @('MyGame-1', 4))) {
        $r = $by[$pair[0]]
        Assert-Equal $r.localOnly.commits $pair[1] ('walk-max ' + $pair[0] + ' repository localOnly')
        foreach ($b in @($r.branches)) { Assert-True ($null -eq $b.localOnly) ('walk-max ' + $pair[0] + ' ' + $b.name + ' localOnly null') }
    }
    $peer = @($by['MyGame-2'].branches | Where-Object { $_.name -eq 'feature/peer' })
    Assert-Equal $peer.Count 1 'walk-max MyGame-2 feature/peer'
    Assert-Equal $peer[0].localOnly.commits 1 'walk-max MyGame-2 feature/peer localOnly (1 is within the limit)'
}

Add-Test -Name 'repos.readonly' -Group 'repos' -Body {
    param($E)
    Initialize-ReposScenario $E
    $before = Get-ReposGitSnapshot $E
    [void](Get-ReposDoc $E 'full')
    [void](Get-ReposDoc $E 'basic')
    $after = Get-ReposGitSnapshot $E
    $changed = @(Compare-Object $before $after | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject })
    if ($changed.Count -gt 0) { Fail ('.git changed while the dashboard read it:' + "`n  " + (($changed | Select-Object -First 10) -join "`n  ")) }
    $locks = @($after | Where-Object { $_ -match '^F\|[^|]*\.lock\|' })
    Assert-Equal $locks.Count 0 ('lock files in .git: ' + ($locks -join '; '))
    Assert-True ($before.Count -gt 50) ('snapshot entries: ' + $before.Count)
}
