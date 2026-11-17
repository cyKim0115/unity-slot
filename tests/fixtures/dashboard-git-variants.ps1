<#
Test fixture for tests\run-tests.ps1 (repos.fallbacks): the dashboard's repos[] with -Git full along the
paths a normal git and repository do not take. It loads the core's functions (dot-sourcing unity-slot.ps1
runs no command) with the test environment's UNITY_SLOT_HOME and UNITY_SLOT_CONFIG, changes one thing and
builds the document in this process (Invoke-Dashboard -AsObject, StrictMode 2.0 as the command line has).
-Variant:
  old-git     every %(ahead-behind:...) field becomes an unknown one, so for-each-ref fails as on git before
              2.41 (the core must fall back to for-each-ref without it and --merged)
  no-default  origin's default branch is one that does not resolve (origin/nope)
  walk-max    the per-branch walk limit is 2 commits instead of 20,000
Git still runs through the core's own Invoke-Git (--no-optional-locks). Prints one JSON line: the variant,
the for-each-ref argument lists in call order, and per repos[] entry its first folder's slot,
defaultBranch, error, localOnly and branches (name, baseAhead, baseBehind, merged, localOnly).
ASCII-only source.
#>
param([ValidateSet('old-git', 'no-default', 'walk-max')][string]$Variant)
# unity-slot.ps1 has a -Mode parameter of its own: dot-sourcing it would reset a variable of that name
$script:FixtureVariant = $Variant
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'unity-slot.ps1') dashboard -GitLevel full
Set-StrictMode -Version 2.0

$script:RealInvokeGit = ${function:Invoke-Git}
$script:RefCalls = New-Object 'System.Collections.Generic.List[string]'
function Invoke-Git([string]$Clone, [string[]]$GitArgs) {
    $a = [string[]]@($GitArgs)
    if ($script:FixtureVariant -eq 'old-git') { $a = [string[]]@($a | ForEach-Object { ([string]$_) -replace '%\(ahead-behind:[^)]*\)', '%(no-such-field)' }) }
    if ($a.Count -gt 0 -and $a[0] -eq 'for-each-ref') { $script:RefCalls.Add(($a -join ' ')) }
    & $script:RealInvokeGit $Clone $a
}
if ($script:FixtureVariant -eq 'no-default') {
    function Get-GitDefaultBranch([string]$CommonDir) { return 'origin/nope' }
}
if ($script:FixtureVariant -eq 'walk-max') { $script:LocalOnlyWalkMax = 2 }

$doc = Invoke-Dashboard -AsObject
$repos = New-Object 'System.Collections.Generic.List[object]'
foreach ($r in @($doc['repos'])) {
    $branches = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in @($r['branches'])) {
        $branches.Add([ordered]@{ name = $b['name']; baseAhead = $b['baseAhead']; baseBehind = $b['baseBehind']; merged = $b['merged']; localOnly = $b['localOnly'] })
    }
    $repos.Add([ordered]@{ slot = $r['folders'][0]['slot']; defaultBranch = $r['defaultBranch']; error = $r['error']; localOnly = $r['localOnly']
            branches = $branches.ToArray() })
}
$out = [ordered]@{ variant = $script:FixtureVariant; refCalls = $script:RefCalls.ToArray(); repos = $repos.ToArray() }
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Compress -Depth 8) + "`n")
exit 0
