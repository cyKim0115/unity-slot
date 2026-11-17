<#
Test fixture for tests\run-tests.ps1: loads unity-slot.ps1 (functions only, as the Checks in AGENTS.md
do) and prints the summary's in-process dashboard document (Invoke-Dashboard -Shallow) as one JSON line:
whether it has the repos and branchViews keys, their values and the number of slots. Runs with the test environment's
state and config. ASCII-only source.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'unity-slot.ps1') summary
$doc = Invoke-Dashboard -Shallow -AsObject
$out = [ordered]@{ hasRepos = $doc.Contains('repos'); repos = $doc['repos']; slots = @($doc['slots']).Count
    hasBranchViews = $doc.Contains('branchViews'); branchViews = $doc['branchViews'] }
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Compress) + "`n")
exit 0
