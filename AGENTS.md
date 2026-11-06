# AGENTS.md

unity-slot registers Unity project clones as slots and opens and closes their editors on demand (`unity-slot.ps1` + `lib\*.ps1`). Usage and design: [README.md](README.md) (Korean) / [README.en.md](README.en.md) (English).

- `unity-slot.ps1`: parameters, open, wait, close, status, command dispatch
- `lib\config.ps1`: settings file, hooks (child processes), extra commands, the `hooks` command
- `lib\registry.ps1`: the registry (`%USERPROFILE%\.unity-slot\slots.json`), detection, scan, slots, set
- `lib\lease.ps1`: leases (`leases\<slot>.json`), acquire, release, renew
- `lib\newclone.ps1`: the new-clone plan (dry run) and `-Apply`
- `mcp\unity-slot-mcp.ps1`: stdio MCP server. A thin shell that runs `unity-slot.ps1` per tool call; no logic of its own.
- `examples\hooks\`: example hooks. `config.example.json`: every setting with its default.

If `private/AGENTS.md` exists (a personal overlay, git-ignored in the public repository), read it and follow it too.

## Rules

- **`.ps1` and `.cmd` files are ASCII only.** Windows PowerShell 5.1 reads BOM-less files with the ANSI code page, which breaks other characters. Put non-ASCII text in UTF-8 data files or pass it as arguments.
- **Never kill a process.** No `Stop-Process`, `taskkill` or `.Kill()`, not even for hooks that run too long. Close editors only with `CloseMainWindow` (same as clicking X).
- **Never click dialog buttons.** On a timeout, list the windows and hand over to a person.
- **No scheduled tasks, timers that close editors later, or logon autostart.** An expiring lease does not close an editor either.
- **Never switch a clone's platform.** `-BuildTarget` is passed only when it matches the detected platform or on a first open.
- **Respect leases.** Someone else's lease is released only with `-AnyOwner`, and only when a person says so. An on-demand slot open without a lease is in use.
- **new-clone `-Apply` runs only after a person saw the dry-run plan and agreed.**
- **Mask secrets.** Command lines and log lines go through `Protect-Text` / `Protect-LogLines` before they are printed or saved (`-accessToken`, `-hubSessionId`, `-cbmEditorLicense`, `-cbmMachineId`).
- **Launch editors through WMI (`Win32_Process.Create`), never `Start-Process`.** In an app-container shell a child's `%LOCALAPPDATA%` writes are redirected and the shell's environment (secrets included) is inherited. For the same reason the registry and leases live in `%USERPROFILE%\.unity-slot`, not under AppData.
- **Keep project-specific behavior out of the core.** Paths, roots, purposes and timeouts belong in the config; project tools and checks belong in hooks or extra commands.
- **Do not change the Unity project's shared settings or commit to the project repository.** No `git clean -x`/`-X` or `git stash -a` in a Unity clone.
- **PowerShell 5.1: do not pass `@($list)` for a `List[object]` parameter.** It fails with "Argument types do not match". Pass `.ToArray()` or loop with `foreach`.
- **The MCP server writes only JSON-RPC messages to stdout.** Logs go to stderr. Tools return quickly (open and acquire with `-NoWait`, wait_ready at most 55 s). There is no kill tool; closing without saving and creating clones need explicit arguments.
- **Do not touch audio settings** (volume, mute, Unity audio settings).

## Checks

```powershell
# ASCII and syntax of every .ps1
Get-ChildItem -Recurse -Include *.ps1 | ForEach-Object {
  $b = [IO.File]::ReadAllBytes($_.FullName); $t = $null; $e = $null
  [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
  '{0}: non-ascii={1} errors={2}' -f $_.Name, @($b | Where-Object { $_ -gt 127 }).Count, @($e | Where-Object { $_ }).Count
}

# Functions only: dot-sourcing loads them without running a command
. .\unity-slot.ps1 status
Protect-Text '-accessToken abc'

# Tests that leave the real registry and config alone
$env:UNITY_SLOT_HOME = "$env:TEMP\unity-slot-test"
$env:UNITY_SLOT_CONFIG = "$env:TEMP\unity-slot-test\config.json"
```

Run real `open`, `close` and `acquire` only on clones that are closed and that nobody is looking at. Test `new-clone -Apply` with a fake project (a local bare origin, `-CloneRoot`, `-NoOpen`).

## Commits

One line, `<area> - <what changed>`, in Korean (for example `런처 - 닫기 후 남은 자식 프로세스 보고 추가`). Push only when asked.
