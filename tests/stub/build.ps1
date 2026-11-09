<#
Builds the fake Unity.exe (UnityStub.cs) with the .NET Framework 4 compiler that ships with Windows.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\stub\build.ps1 [-Out <folder>]

Default output: tests\stub\bin\Unity.exe (git-ignored). Prints the full path of the built file.
tests\run-tests.ps1 builds its own copy into the test folder; this script is for trying the stub by hand.
ASCII-only source.
#>
[CmdletBinding()]
param([string]$Out = (Join-Path $PSScriptRoot 'bin'))
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'UnityStub.cs'
$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe of the .NET Framework 4 was not found under %WINDIR%\Microsoft.NET' }
if (-not (Test-Path -LiteralPath $Out)) { [void](New-Item -ItemType Directory -Path $Out -Force) }
$exe = Join-Path (Resolve-Path -LiteralPath $Out).Path 'Unity.exe'
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$output = @(& $csc /nologo /target:winexe /optimize+ "/out:$exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll $src 2>&1)
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($code -ne 0) {
    foreach ($line in $output) { Write-Host $line }
    throw ('csc failed with exit {0}' -f $code)
}
$exe
