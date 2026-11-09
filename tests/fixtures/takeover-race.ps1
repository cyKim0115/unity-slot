<#
Test fixture for tests\run-tests.ps1 (lease.takeover-race): the race of two acquire processes that both
saw the same expired lease, played in a fixed order so that it is deterministic. It loads the core's
functions (dot-sourcing unity-slot.ps1 runs no command) with the test environment's UNITY_SLOT_HOME and
UNITY_SLOT_CONFIG, then:
  1. reads the slot's lease, as both processes do while it is still the expired one;
  2. lets A take it over;
  3. lets B take it over too, still acting on what it read in step 1.
Prints one JSON line {"a": winner A or null, "b": winner B or null, "file": owner in the lease file}.
Only one of A and B may win. ASCII-only source.
#>
param([string]$Slot)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'unity-slot.ps1') status
$record = Find-SlotByName (Read-Registry) $Slot
if ($null -eq $record) { throw ('no slot ' + $Slot) }
$seen = Get-SlotLease $Slot
if ($null -eq $seen -or -not $seen.Expired) { throw 'the slot must hold an expired lease' }
$a = New-SlotLease -Slot $record -OwnerId 'raceA' -Need 'race' -HoursValue 8 -ReplaceExpired $true -ExpectedNonce $seen.nonce
$b = New-SlotLease -Slot $record -OwnerId 'raceB' -Need 'race' -HoursValue 8 -ReplaceExpired $true -ExpectedNonce $seen.nonce
$file = Get-SlotLease $Slot
$out = [ordered]@{ a = $null; b = $null; file = $null }
if ($null -ne $a) { $out.a = $a.owner }
if ($null -ne $b) { $out.b = $b.owner }
if ($null -ne $file) { $out.file = $file.owner }
[Console]::Out.WriteLine(($out | ConvertTo-Json -Compress))
