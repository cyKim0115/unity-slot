<#
Test hook for tests\run-tests.ps1: appends "event|slot|pid|clone" to the file given in -Out and exits 0,
so a test can check that unity-slot ran its hooks with the right values. ASCII-only source.
#>
param([string]$Out)
$line = '{0}|{1}|{2}|{3}' -f $env:UNITY_SLOT_EVENT, $env:UNITY_SLOT_SLOT, $env:UNITY_SLOT_PID, $env:UNITY_SLOT_CLONE
[IO.File]::AppendAllText($Out, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
Write-Output ('recorded ' + $env:UNITY_SLOT_EVENT)
exit 0
