<#
Example beforeClose hook: refuse the close while the editor reports unsaved scenes.

unity-slot cannot see unsaved scenes by itself. This hook reads a small JSON "beacon" file that an
editor script in your project keeps up to date (the editor script is not part of unity-slot):

  {
    "Pid": 1234,                          the Unity editor process that wrote it
    "ScriptPath": "Assets/Editor/X.cs",   optional: the writer; a missing file marks the beacon stale
    "IsPlaying": false,
    "Scenes": [ { "Path": "Assets/Scenes/Main.unity", "IsDirty": true } ],
    "PrefabStagePath": "", "PrefabStageDirty": false
  }

config.json:
  "beforeClose": [ { "name": "scene-beacon",
      "run": [ "{repo}\\examples\\hooks\\scene-beacon.ps1", "-Beacon", "Temp\\SceneBeacon.json" ] } ]

Exit 0: close (all saved, or no usable beacon). Exit 4: refuse (unsaved scenes or prefab stage).
ASCII-only source.
#>
param(
    [string]$Clone = $env:UNITY_SLOT_CLONE,
    [int]$EditorPid = [int]$env:UNITY_SLOT_PID,
    # beacon path, relative to the clone
    [string]$Beacon = 'Temp\SceneBeacon.json',
    # what to tell the caller when it refuses
    [string]$Hint = 'save or discard in the editor first, or ask the user'
)

function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

$file = Join-Path $Clone $Beacon
if (-not (Test-Path -LiteralPath $file)) { Write-Output ('scenes  unknown (no {0}); closing' -f $Beacon); exit 0 }
$data = $null
for ($try = 0; $try -lt 2 -and $null -eq $data; $try++) {
    try { $data = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 200 }
}
if ($null -eq $data) { Write-Output 'scenes  unknown (beacon unreadable); closing'; exit 0 }
if ($EditorPid -gt 0 -and [int](Get-Field $data 'Pid') -ne $EditorPid) { Write-Output 'scenes  unknown (beacon written by another editor process); closing'; exit 0 }
$writer = [string](Get-Field $data 'ScriptPath')
if ($writer) {
    $writerPath = $writer
    if (-not [IO.Path]::IsPathRooted($writerPath)) { $writerPath = Join-Path $Clone $writerPath }
    if (-not (Test-Path -LiteralPath $writerPath)) { Write-Output 'scenes  unknown (beacon writer script is gone, record may be stale); closing'; exit 0 }
}
$unsaved = New-Object 'System.Collections.Generic.List[string]'
foreach ($s in @(Get-Field $data 'Scenes')) {
    if ($null -ne $s -and (Get-Field $s 'IsDirty')) {
        $scenePath = [string](Get-Field $s 'Path')
        if (-not $scenePath) { $scenePath = '(Untitled)' }
        $unsaved.Add($scenePath)
    }
}
$stage = [string](Get-Field $data 'PrefabStagePath')
if ($stage -and (Get-Field $data 'PrefabStageDirty')) { $unsaved.Add('Prefab Mode: ' + $stage) }
$play = ''
if (Get-Field $data 'IsPlaying') { $play = ' (Play mode)' }
if ($unsaved.Count -eq 0) { Write-Output ('scenes  all saved' + $play); exit 0 }
Write-Output ('scenes  unsaved: ' + ($unsaved -join ', ') + $play)
Write-Output ('scenes  ' + $Hint)
exit 4
