<#
Example afterClose hook: when an agent puts a leased slot down, revert the files the Unity editor
re-serialized while it was open (materials, font atlases, .meta files, project settings) so the
next session starts from a clean working tree. A backup patch is kept first.

A file is reverted only when all of these hold:
  - the slot is leased (an agent's release or close; a person's own close is left alone)
  - unity-slot opened this editor and left its snapshot (Logs\unity-slot-open.txt with this pid)
  - the file was clean when the editor opened and was written while it was open
  - it is a tracked file, modified in the working tree only (nothing staged for it)
  - its path matches -Include or -Also and not -Exclude (git paths, -like patterns, any case;
    several patterns in one argument are separated by commas)
Everything else stays: staged files, new or deleted files, files that were already changed at open,
and other kinds (scripts, scenes, prefabs, docs). Stage or commit what you want to keep before the
release.

The backup is Logs\unity-slot-cleanup\<time>-<slot>.patch in the clone (Logs is ignored by git).
Undo: git apply <patch>

config.json:
  "afterClose": [ { "name": "release-cleanup",
      "run": [ "{repo}\\examples\\hooks\\release-cleanup.ps1", "-Also", "Assets/Plugins/Android/*.xml" ] } ]

Exit 0: done or nothing to do. Exit 1: git failed (files may be partly reverted; the patch is kept).
ASCII-only source.
#>
param(
    [string]$Clone = $env:UNITY_SLOT_CLONE,
    [string]$Slot = $env:UNITY_SLOT_SLOT,
    [int]$EditorPid = [int]$env:UNITY_SLOT_PID,
    # what Unity re-serializes on its own
    [string[]]$Include = @('*.mat', '*.asset', '*.meta', 'ProjectSettings/*'),
    # more patterns on top of -Include (project files your editor rewrites)
    [string[]]$Also = @(),
    # never revert these, even when they match
    [string[]]$Exclude = @(),
    # clone-relative backup folder
    [string]$BackupDir = 'Logs\unity-slot-cleanup',
    # list what would be reverted, change nothing
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# A hook argument is one string: "a,b" means two patterns.
function Split-Patterns([string[]]$List) { @($List | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$Include = Split-Patterns $Include
$Also = Split-Patterns $Also
$Exclude = Split-Patterns $Exclude

function Say([string]$Text) { Write-Output ('cleanup ' + $Text) }

function Get-SlotHome {
    if ($env:UNITY_SLOT_HOME) { return $env:UNITY_SLOT_HOME }
    return (Join-Path $env:USERPROFILE '.unity-slot')
}

# git with literal paths, unquoted output; returns the exit code. -Out collects stdout lines.
function Invoke-GitC([string[]]$GitArgs, [System.Collections.Generic.List[string]]$Out = $null) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & git -C $Clone -c core.quotepath=false --literal-pathspecs @GitArgs 2>$null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($null -ne $Out) { foreach ($l in @($lines)) { if ($null -ne $l) { $Out.Add([string]$l) } } }
    return $code
}

function Test-AnyLike([string]$Path, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($p -and $Path -like $p) { return $true } }
    return $false
}

# Paths in groups that keep a command line well under the Windows limit.
function Split-Chunks([string[]]$Paths, [int]$MaxChars = 20000) {
    $chunk = New-Object 'System.Collections.Generic.List[string]'
    $len = 0
    foreach ($p in $Paths) {
        if ($chunk.Count -gt 0 -and ($len + $p.Length + 3) -gt $MaxChars) { , $chunk.ToArray(); $chunk.Clear(); $len = 0 }
        $chunk.Add($p); $len += $p.Length + 3
    }
    if ($chunk.Count -gt 0) { , $chunk.ToArray() }
}

if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) { Say 'skipped: not a git clone'; exit 0 }
if (-not $Slot) { Say 'skipped: not a registered slot'; exit 0 }
if (-not (Test-Path -LiteralPath (Join-Path (Get-SlotHome) ('leases\' + $Slot + '.json')))) {
    Say ('skipped: {0} is not leased (only an agent''s release or close cleans up)' -f $Slot)
    exit 0
}

# what was already changed when unity-slot opened this editor
$snapFile = Join-Path $Clone 'Logs\unity-slot-open.txt'
$snapPid = 0
$snapTime = $null
$atOpen = @{}
if (Test-Path -LiteralPath $snapFile) {
    foreach ($line in [IO.File]::ReadAllLines($snapFile, [Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith('pid=')) { $snapPid = [int]$line.Substring(4); continue }
        if ($line.StartsWith('time=')) {
            $snapTime = [datetime]::Parse($line.Substring(5), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            continue
        }
        if ($line -match '^[A-Za-z]+=') { continue }
        if ($line.Length -ge 4) { $atOpen[$line.Substring(3)] = $true }
    }
}
if ($null -eq $snapTime -or $EditorPid -le 0 -or $snapPid -ne $EditorPid) {
    Say ('skipped: no unity-slot open snapshot for pid {0}; cannot tell what was changed before the open' -f $EditorPid)
    exit 0
}

$raw = New-Object 'System.Collections.Generic.List[string]'
if ((Invoke-GitC @('--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=no') $raw) -ne 0) { Say 'git status failed; nothing reverted'; exit 1 }
$fields = ($raw -join "`n").Split([char]0)
$revert = New-Object 'System.Collections.Generic.List[string]'
$kept = New-Object 'System.Collections.Generic.List[string]'
$patterns = @(@($Include) + @($Also))
for ($i = 0; $i -lt $fields.Length; $i++) {
    $f = $fields[$i]
    if ($f.Length -lt 4) { continue }
    $code = $f.Substring(0, 2)
    $path = $f.Substring(3)
    if ($code.StartsWith('R') -or $code.StartsWith('C')) { $i++ }
    if ($atOpen.ContainsKey($path)) { continue }
    $full = Join-Path $Clone ($path.Replace('/', '\'))
    $written = $false
    try { $written = ((Get-Item -LiteralPath $full -Force).LastWriteTime -ge $snapTime) } catch { }
    if (-not $written) { continue }
    if ($code -ne ' M') { $kept.Add(('{0} {1} (staged or not a plain change)' -f $code, $path)); continue }
    if (-not (Test-AnyLike $path $patterns) -or (Test-AnyLike $path $Exclude)) { $kept.Add(('{0} {1} (not a re-serialized kind)' -f $code, $path)); continue }
    $revert.Add($path)
}

if ($kept.Count -gt 0) {
    Say ('{0} file(s) changed while open are kept (commit them or revert them yourself):' -f $kept.Count)
    foreach ($k in ($kept | Select-Object -First 30)) { Write-Output ('  ' + $k) }
    if ($kept.Count -gt 30) { Write-Output ('  ... {0} more' -f ($kept.Count - 30)) }
}
if ($revert.Count -eq 0) { Say 'nothing to revert'; exit 0 }
if ($DryRun) {
    Say ('dry-run: would revert {0} file(s):' -f $revert.Count)
    foreach ($p in $revert) { Write-Output ('  ' + $p) }
    exit 0
}

$dir = Join-Path $Clone $BackupDir
[void](New-Item -ItemType Directory -Path $dir -Force)
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
$patch = Join-Path $dir ('{0}-{1}.patch' -f $stamp, $Slot)
$parts = New-Object 'System.Collections.Generic.List[string]'
$n = 0
foreach ($chunk in @(Split-Chunks $revert.ToArray())) {
    $part = '{0}.{1}' -f $patch, $n
    $n++
    $code = Invoke-GitC (@('--no-optional-locks', 'diff', '--binary', '--no-color', '--no-ext-diff', ('--output=' + $part), '--') + $chunk)
    if ($code -ne 0) { Say ('git diff failed (exit {0}); nothing reverted' -f $code); exit 1 }
    $parts.Add($part)
}
$fs = [IO.File]::Create($patch)
try {
    foreach ($p in $parts) { $b = [IO.File]::ReadAllBytes($p); $fs.Write($b, 0, $b.Length) }
} finally { $fs.Dispose() }
foreach ($p in $parts) { Remove-Item -LiteralPath $p -Force }
if ((Get-Item -LiteralPath $patch).Length -eq 0) { Say 'backup patch is empty (the changes are line endings only?); nothing reverted'; Remove-Item -LiteralPath $patch -Force; exit 0 }

foreach ($chunk in @(Split-Chunks $revert.ToArray())) {
    $code = Invoke-GitC (@('restore', '--worktree', '--') + $chunk)
    if ($code -ne 0) { Say ('git restore failed (exit {0}); backup kept at {1}' -f $code, $patch); exit 1 }
}
Say ('reverted {0} file(s) Unity re-serialized while the editor was open. Backup: {1}' -f $revert.Count, $patch)
Say ('undo: git -C "{0}" apply "{1}"' -f $Clone, $patch)
foreach ($p in ($revert | Select-Object -First 30)) { Write-Output ('  ' + $p) }
if ($revert.Count -gt 30) { Write-Output ('  ... {0} more' -f ($revert.Count - 30)) }
exit 0
