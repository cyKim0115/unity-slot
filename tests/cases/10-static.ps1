# Static checks of the repository (no environment). Dot-sourced by tests\run-tests.ps1. ASCII-only source.

Register-Group 'static'

# AGENTS.md: .ps1 and .cmd files are ASCII only and every .ps1 parses (the stub source is ASCII too).
Add-Test -Name 'static.ascii-and-syntax' -Group 'static' -Body {
    param($E)
    $bad = New-Object 'System.Collections.Generic.List[string]'
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
            Where-Object { @('.ps1', '.cmd', '.cs') -contains $_.Extension.ToLowerInvariant() -and
                $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\tests\\stub\\bin\\' })
    Assert-True ($files.Count -ge 10) ('only {0} script files found under {1}' -f $files.Count, $script:RepoRoot)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($script:RepoRoot.Length + 1)
        $non = [regex]::Matches($latin1.GetString([IO.File]::ReadAllBytes($f.FullName)), '[^\x00-\x7F]').Count
        if ($non -gt 0) { $bad.Add(('{0}: {1} non-ASCII byte(s)' -f $rel, $non)) }
        if ($f.Extension -eq '.ps1') {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            foreach ($parseError in @($errors)) { if ($null -ne $parseError) { $bad.Add(('{0}:{1}: {2}' -f $rel, $parseError.Extent.StartLineNumber, $parseError.Message)) } }
        }
    }
    Assert-True ($bad.Count -eq 0) ("ASCII / syntax:`n  " + ($bad -join "`n  "))
}
