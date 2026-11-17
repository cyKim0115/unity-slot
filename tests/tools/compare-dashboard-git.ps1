<#
.SYNOPSIS
Checks the git numbers of the dashboard (slot git, repos[]) against independent read-only git queries on
the same repositories, and optionally times the dashboard against another copy of the core.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\tools\compare-dashboard-git.ps1
      [-Cli <unity-slot.ps1>] [-Baseline <unity-slot.ps1>] [-TimingRuns 3] [-Json <file>]

Runs "dashboard -Json -Git full" twice (before and after the queries) and, in between, for every repos[]
entry other git commands than the core uses, for example:
  - commits on no origin: rev-list --count --branches --not --remotes=origin (and every other remote whose
    URL is not an existing folder), and per branch rev-list --count refs/heads/<b> --not ...
  - upstream: for-each-ref %(upstream:track) for gone, rev-list --left-right --count <b>...<upstream>
  - against the default branch: rev-list --left-right --count, merge-base --is-ancestor
  - tip time and subject: log -1 --format=%ct / %s per branch
  - stashes: the lines of logs\refs\stash, stash list --format=%H and --format=%gs (messages)
  - slot: rev-parse HEAD, symbolic-ref HEAD (detached, and the branch of its repos[] folder),
    status --porcelain=v1 -z (staged / unstaged / untracked / conflicted from the two-letter codes),
    worktree list --porcelain (folders, checked-out branches)
A value counts as a difference only when it matches neither dashboard run (slots keep changing while
people and agents work). With -Baseline, both copies run "dashboard -Json -Git full" (and basic)
-TimingRuns times, alternating, and the average wall time, timing.totalMs and timing.gitMs are printed.

Read-only: the dashboard, and git only with --no-optional-locks. It uses the registry the core finds
(UNITY_SLOT_HOME / UNITY_SLOT_CONFIG apply). Exit 0 = no difference, 4 = differences, 1 = error.
ASCII-only source.
#>
[CmdletBinding()]
param(
    # default: the core of this checkout (two folders up)
    [string]$Cli = '',
    [string]$Baseline = '',
    [int]$TimingRuns = 3,
    [string]$Json = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-Dash([string]$Core, [string]$Level) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Core + '" dashboard -Json -Git ' + $Level
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $wall = $sw.ElapsedMilliseconds
    if ($p.ExitCode -ne 0) { throw ('dashboard of {0} failed (exit {1}): {2}' -f $Core, $p.ExitCode, $err.Result) }
    return [pscustomobject]@{ Doc = ($out.Result | ConvertFrom-Json); WallMs = $wall; Bytes = $out.Result.Length }
}

function G([string]$Dir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $o = @(& git --no-optional-locks -C $Dir -c core.quotepath=false @GitArgs 2>$null) } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = @($o | ForEach-Object { [string]$_ }) }
}

function Get-Prop2($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Format-V($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return [string]$Value
}

function Get-UnixOfIso([string]$Iso) {
    if (-not $Iso) { return $null }
    return [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
}

# ------------------------------------------------------------------ independent values

function Get-RemoteNotArgs([string]$Dir) {
    $args2 = New-Object 'System.Collections.Generic.List[string]'
    $args2.Add('--remotes=origin')
    $local = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in (G $Dir @('remote')).Lines) {
        if (-not $name -or $name -eq 'origin') { continue }
        $url = @((G $Dir @('remote', 'get-url', $name)).Lines)[0]
        $isFolder = $false
        try { $isFolder = [bool]($url -and (Test-Path -LiteralPath ($url -replace '^file://', ''))) } catch { }
        if ($isFolder) { $local.Add($name) } else { $args2.Add('--remotes=' + $name) }
    }
    return [pscustomobject]@{ Args = $args2.ToArray(); LocalRemotes = $local.ToArray() }
}

function Get-StatusKinds([string]$Dir) {
    $raw = ((G $Dir @('status', '--porcelain=v1', '-z')).Lines -join "`n")
    $k = [ordered]@{ staged = 0; unstaged = 0; untracked = 0; conflicted = 0 }
    $fields = $raw.Split([char]0)
    for ($i = 0; $i -lt $fields.Length; $i++) {
        $f = $fields[$i].TrimStart("`n")
        if ($f.Length -lt 3) { continue }
        $xy = $f.Substring(0, 2)
        if ($xy[0] -eq [char]'R' -or $xy[0] -eq [char]'C') { $i++ }
        if ($xy -eq '??') { $k.untracked++ }
        elseif ($xy -eq '!!') { }
        elseif (@('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU') -contains $xy) { $k.conflicted++ }
        else {
            if ($xy[0] -ne [char]' ') { $k.staged++ }
            if ($xy[1] -ne [char]' ') { $k.unstaged++ }
        }
    }
    return $k
}

function Get-Independent($Repo, $Slots) {
    $dir = [string]$Repo.folders[0].path
    $v = [ordered]@{}
    $na = Get-RemoteNotArgs $dir
    $v['remotes.localExcluded'] = ($na.LocalRemotes -join ',')
    $c = G $dir (@('rev-list', '--count', '--branches', '--not') + $na.Args)
    $v['repo.localOnly.commits'] = @($c.Lines)[0]
    $times = @((G $dir (@('log', '--branches', '--not') + $na.Args + @('--format=%ct'))).Lines | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [long]$_ })
    $v['repo.localOnly.oldestAt'] = $(if ($times.Count) { ($times | Measure-Object -Minimum).Minimum } else { $null })
    $def = $null
    $sr = G $dir @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
    if ($sr.Code -eq 0) { $def = @($sr.Lines)[0] }
    $v['repo.defaultBranch'] = $def
    # worktrees: folders and which branch each has checked out
    $wtPaths = New-Object 'System.Collections.Generic.List[string]'
    $checked = @{}
    $cur = $null
    foreach ($l in (G $dir @('worktree', 'list', '--porcelain')).Lines) {
        if ($l.StartsWith('worktree ')) { $cur = [IO.Path]::GetFullPath($l.Substring(9).Replace('/', '\')); $wtPaths.Add($cur.ToLowerInvariant()) }
        elseif ($l.StartsWith('branch refs/heads/') -and $cur) { $checked[$l.Substring(18)] = $cur.ToLowerInvariant() }
    }
    $v['repo.folders'] = (@($wtPaths | Sort-Object) -join ';')
    foreach ($b in (G $dir @('for-each-ref', '--format=%(refname:strip=2)|%(objectname)|%(upstream:short)|%(upstream:track)', 'refs/heads')).Lines) {
        $p = $b.Split('|')
        if ($p.Count -lt 4) { continue }
        $n = $p[0]
        $v["branch[$n].tip"] = $p[1]
        $v["branch[$n].tipAt"] = @((G $dir @('log', '-1', '--format=%ct', ('refs/heads/' + $n))).Lines)[0]
        $subject = [string]@((G $dir @('log', '-1', '--format=%s', ('refs/heads/' + $n))).Lines)[0]
        if ($subject.Length -gt 120) { $subject = $subject.Substring(0, 120) }
        $v["branch[$n].subject"] = $subject
        $v["branch[$n].upstream"] = $(if ($p[2]) { $p[2] } else { $null })
        $gone = ($p[3] -match 'gone')
        $v["branch[$n].upstreamGone"] = $gone
        $ahead = $null; $behind = $null
        if ($p[2] -and -not $gone) {
            $lr = @((G $dir @('rev-list', '--left-right', '--count', ('refs/heads/' + $n + '...' + $p[2]))).Lines)[0]
            if ($lr -match '^(\d+)\s+(\d+)$') { $ahead = $Matches[1]; $behind = $Matches[2] }
        }
        $v["branch[$n].ahead"] = $ahead
        $v["branch[$n].behind"] = $behind
        $v["branch[$n].localOnly.commits"] = @((G $dir (@('rev-list', '--count', ('refs/heads/' + $n), '--not') + $na.Args)).Lines)[0]
        if ($def) {
            $lr = @((G $dir @('rev-list', '--left-right', '--count', ('refs/heads/' + $n + '...' + $def))).Lines)[0]
            if ($lr -match '^(\d+)\s+(\d+)$') { $v["branch[$n].baseAhead"] = $Matches[1]; $v["branch[$n].baseBehind"] = $Matches[2] }
            $v["branch[$n].merged"] = ((G $dir @('merge-base', '--is-ancestor', ('refs/heads/' + $n), $def)).Code -eq 0)
        }
        $v["branch[$n].checkedOutBy"] = $(if ($checked.ContainsKey($n)) { $checked[$n] } else { '' })
    }
    $stashFile = Join-Path ([string]$Repo.commonDir) 'logs\refs\stash'
    $lines = 0
    if (Test-Path -LiteralPath $stashFile) {
        $fs = New-Object IO.FileStream($stashFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $lines = @((New-Object IO.StreamReader($fs)).ReadToEnd() -split "`n" | Where-Object { $_.Trim() }).Count } finally { $fs.Dispose() }
    }
    $v['repo.stashes.count'] = $lines
    $v['repo.stashes.shas'] = ((G $dir @('stash', 'list', '--format=%H')).Lines -join ',')
    $v['repo.stashes.messages'] = ((G $dir @('stash', 'list', '--format=%gs')).Lines -join '|')
    foreach ($s in $Slots) {
        $sd = [string]$s.path
        $k = 'slot[' + $s.name + ']'
        $v["$k.head"] = @((G $sd @('rev-parse', 'HEAD')).Lines)[0]
        $sym = G $sd @('symbolic-ref', '-q', '--short', 'HEAD')
        $v["$k.detached"] = ($sym.Code -ne 0)
        $v["$k.folderBranch"] = $(if ($sym.Code -eq 0) { @($sym.Lines)[0] } else { $null })
        $kinds = Get-StatusKinds $sd
        foreach ($kk in $kinds.Keys) { $v["$k.changesDetail.$kk"] = $kinds[$kk] }
        $gd = @((G $sd @('rev-parse', '--absolute-git-dir')).Lines)[0]
        $v["$k.gitDir"] = $(if ($gd) { [IO.Path]::GetFullPath($gd.Replace('/', '\')).ToLowerInvariant() } else { $null })
    }
    return $v
}

# ------------------------------------------------------------------ the same values from a document

function Get-FromDoc($Doc, [string]$CommonDir) {
    $v = [ordered]@{}
    $repo = @($Doc.repos | Where-Object { [string]::Equals([string]$_.commonDir, $CommonDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($repo.Count -eq 0) { return $v }
    $r = $repo[0]
    $v['repo.localOnly.commits'] = $r.localOnly.commits
    $v['repo.localOnly.oldestAt'] = Get-UnixOfIso $r.localOnly.oldestAt
    $v['repo.defaultBranch'] = $r.defaultBranch
    $v['repo.folders'] = (@($r.folders | ForEach-Object { ([string]$_.path).ToLowerInvariant() } | Sort-Object) -join ';')
    foreach ($b in @($r.branches)) {
        $n = $b.name
        $v["branch[$n].tip"] = $b.tip
        $v["branch[$n].tipAt"] = Get-UnixOfIso $b.tipAt
        $v["branch[$n].subject"] = $b.subject
        $v["branch[$n].upstream"] = $b.upstream
        $v["branch[$n].upstreamGone"] = $b.upstreamGone
        $v["branch[$n].ahead"] = $b.ahead
        $v["branch[$n].behind"] = $b.behind
        $v["branch[$n].localOnly.commits"] = $(if ($null -ne $b.localOnly) { $b.localOnly.commits } else { $null })
        if ($r.defaultBranch) {
            $v["branch[$n].baseAhead"] = $b.baseAhead
            $v["branch[$n].baseBehind"] = $b.baseBehind
            $v["branch[$n].merged"] = $b.merged
        }
        $v["branch[$n].checkedOutBy"] = (@($b.checkedOutBy | ForEach-Object { ([string]$_.path).ToLowerInvariant() }) -join ';')
    }
    $v['repo.stashes.count'] = @($r.stashes).Count
    $v['repo.stashes.shas'] = (@($r.stashes | ForEach-Object { $_.sha }) -join ',')
    $v['repo.stashes.messages'] = (@($r.stashes | ForEach-Object { $_.message }) -join '|')
    foreach ($s in @($Doc.slots | Where-Object { $null -ne $_.git -and [string]::Equals([string]$_.git.commonDir, $CommonDir, [StringComparison]::OrdinalIgnoreCase) })) {
        $k = 'slot[' + $s.name + ']'
        $v["$k.head"] = $s.git.head
        $v["$k.detached"] = $s.git.detached
        $folder = @($r.folders | Where-Object { [string]::Equals([string]$_.path, [string]$s.path, [StringComparison]::OrdinalIgnoreCase) })
        $v["$k.folderBranch"] = $(if ($folder.Count -gt 0) { $folder[0].branch } else { '(no folder)' })
        foreach ($kk in @('staged', 'unstaged', 'untracked', 'conflicted')) { $v["$k.changesDetail.$kk"] = $s.git.changesDetail.$kk }
        $v["$k.gitDir"] = $(if ($s.git.gitDir) { ([string]$s.git.gitDir).ToLowerInvariant() } else { $null })
    }
    return $v
}

# ------------------------------------------------------------------ main

try {
    if (-not $Cli) { $Cli = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))) 'unity-slot.ps1' }
    $Cli = [IO.Path]::GetFullPath($Cli)
    Write-Host ('compare  core {0}' -f $Cli)
    $d1 = Invoke-Dash $Cli 'full'
    $doc1 = $d1.Doc
    if ($null -eq (Get-Prop2 $doc1 'repos')) { throw ('the core has no repos[] (version {0}); 0.7.0 or later is needed' -f $doc1.version) }
    $qsw = [Diagnostics.Stopwatch]::StartNew()
    $independent = [ordered]@{}
    foreach ($r in @($doc1.repos)) {
        $slots = @($doc1.slots | Where-Object { $null -ne $_.git -and [string]::Equals([string]$_.git.commonDir, [string]$r.commonDir, [StringComparison]::OrdinalIgnoreCase) })
        $independent[[string]$r.commonDir] = Get-Independent $r $slots
    }
    $queryMs = $qsw.ElapsedMilliseconds
    $d2 = Invoke-Dash $Cli 'full'
    $doc2 = $d2.Doc
    $diffs = New-Object 'System.Collections.Generic.List[string]'
    $moved = New-Object 'System.Collections.Generic.List[string]'
    $checked = 0
    foreach ($cd in $independent.Keys) {
        $q = $independent[$cd]
        $a = Get-FromDoc $doc1 $cd
        $b = Get-FromDoc $doc2 $cd
        $name = @($doc1.repos | Where-Object { $_.commonDir -eq $cd })[0].folders[0].slot
        if ($q['remotes.localExcluded']) { Write-Host ('note     {0}: remotes at a local path, not counted as remotes: {1}' -f $name, $q['remotes.localExcluded']) }
        $keys = New-Object 'System.Collections.Generic.List[string]'
        foreach ($k in @($q.Keys) + @($a.Keys) + @($b.Keys)) { if ($k -ne 'remotes.localExcluded' -and -not $keys.Contains($k)) { $keys.Add($k) } }
        foreach ($k in $keys) {
            $qv = Format-V $(if ($q.Contains($k)) { $q[$k] } else { '(missing)' })
            $av = Format-V $(if ($a.Contains($k)) { $a[$k] } else { '(missing)' })
            $bv = Format-V $(if ($b.Contains($k)) { $b[$k] } else { '(missing)' })
            $checked++
            if ($qv -eq $av -and $qv -eq $bv) { continue }
            if ($qv -eq $av -or $qv -eq $bv) { $moved.Add(('{0} {1}: git {2}, dashboard {3} then {4}' -f $name, $k, $qv, $av, $bv)); continue }
            $diffs.Add(('{0} {1}: git {2}, dashboard {3} / {4}' -f $name, $k, $qv, $av, $bv))
        }
    }
    foreach ($m in $moved) { Write-Host ('changed  ' + $m) }
    foreach ($m in $diffs) { Write-Host ('DIFF     ' + $m) }
    Write-Host ('result   {0} repos, {1} values, {2} difference(s), {3} changed meanwhile; dashboards {4} / {5} ms, queries {6} ms' -f
        @($independent.Keys).Count, $checked, $diffs.Count, $moved.Count, $d1.WallMs, $d2.WallMs, $queryMs)
    foreach ($r in @($doc1.repos)) {
        Write-Host ('repo     {0,-34} branches {1,2}  local-only {2,3}  stashes {3}  flags {4}' -f $r.folders[0].slot, @($r.branches).Count,
            $r.localOnly.commits, @($r.stashes).Count, (@($r.flags) -join ','))
    }

    $timing = @()
    if ($Baseline) {
        $Baseline = [IO.Path]::GetFullPath($Baseline)
        Write-Host ('timing   {0} run(s) each, alternating: baseline {1}' -f $TimingRuns, $Baseline)
        for ($i = 1; $i -le $TimingRuns; $i++) {
            foreach ($pair in @(@('baseline', $Baseline), @('new', $Cli))) {
                foreach ($lvl in @('basic', 'full')) {
                    $t = Invoke-Dash $pair[1] $lvl
                    $timing += [pscustomobject]@{ core = $pair[0]; level = $lvl; wallMs = $t.WallMs; totalMs = [double]$t.Doc.timing.totalMs; gitMs = [double]$t.Doc.timing.gitMs; bytes = $t.Bytes }
                }
            }
        }
        foreach ($g in @($timing | Group-Object core, level)) {
            Write-Host ('timing   {0,-16} wall {1,5:0} ms  totalMs {2,5:0}  gitMs {3,5:0}  json {4,6:0} chars' -f $g.Name,
                ($g.Group | Measure-Object wallMs -Average).Average, ($g.Group | Measure-Object totalMs -Average).Average,
                ($g.Group | Measure-Object gitMs -Average).Average, ($g.Group | Measure-Object bytes -Average).Average)
        }
    }
    if ($Json) {
        $report = [ordered]@{ core = $Cli; version = $doc1.version; time = $doc1.time; differences = $diffs.ToArray(); changedMeanwhile = $moved.ToArray()
            values = $checked; timing = $timing }
        [IO.File]::WriteAllText($Json, ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    }
    if ($diffs.Count -gt 0) { exit 4 }
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    exit 1
}
