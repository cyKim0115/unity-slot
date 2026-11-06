# unity-slot

[한국어](README.ko.md)

Keep several clones of a Unity project as **slots** and open their editors only while someone needs them. AI coding agents lease a slot by purpose ("a WebGL clone", "any agent clone"), work in it, and release it. When no slot is free, unity-slot plans a new clone and creates it only after you agree.

It is one PowerShell script with a small library and an optional MCP server. It never kills a process, never clicks a dialog button, never switches a clone's platform, and starts no timers or scheduled tasks.

**Windows only.** It launches editors through WMI (`Win32_Process.Create`) and reads windows with Win32 APIs.

> **Unity licensing.** Running several Unity editors at the same time is governed by your Unity license and its terms. Check them yourself before you keep several slots open at once.

## Why

Parallel work on one Unity project (one clone per agent, per platform, per branch) is easier with separate clones, but every open editor is expensive. One editor with its import workers, compiler server, shader compilers and other children took **5 to 12 GB of private memory** in our measurements. unity-slot keeps the clones registered and opens an editor only for the time it is used. It also checks that a clone is not already open, waits until the editor is really ready, and reports what changed when it closes.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in). Nothing to install.
- Unity installed through Unity Hub, or any folder that holds `<version>\Editor\Unity.exe`.
- git.
- Optional: Python, only for `.py` hooks.

## Quick start

```powershell
git clone <this repository> unity-slot
cd unity-slot
copy config.example.json config.json      # optional: scan roots, clone root, hooks, ...

# register the clones of one project (dry run first, then -Apply)
.\unity-slot.ps1 scan -ScanRoot C:\Projects -Project my-org/my-game
.\unity-slot.ps1 scan -ScanRoot C:\Projects -Project my-org/my-game -Apply
.\unity-slot.ps1 slots
.\unity-slot.ps1 set MyGame-2 -Purpose agent,webgl -Memo 'agent clone for web fixes'

# lease a free slot, work, release it
.\unity-slot.ps1 acquire webgl -Project my-game -Owner me
.\unity-slot.ps1 release MyGame-2 -Owner me
```

From cmd or Git Bash, use `unity-slot.cmd <command> ...`.

## Concepts

- **Slot.** A registered clone folder (a git clone or worktree) of a Unity project. unity-slot detects its Unity version, branch, origin and platform. You set its *purposes* (free tags such as `agent`, `webgl`, `build`), its *mode* (`hot`: stays open, `ondemand`: opened when needed), whether agents may use it (`agentUse`) and a memo.
- **Lease.** A file per leased slot. It is created with `FileMode.CreateNew`, so two sessions cannot take the same slot. A lease expires after `leaseHours` (8). An expired lease frees a *closed* slot for the next acquire; it never closes an editor.
- **Free slot.** `agentUse` is on, a purpose or the platform fits, nobody else holds a valid lease, no batchmode Unity runs on it, and the editor is closed or the slot is `hot`. An on-demand slot that is open without a lease counts as in use. acquire prefers your own lease, then open hot slots, then the closed slot used most recently.
- **State.** `%USERPROFILE%\.unity-slot` (`UNITY_SLOT_HOME` moves it): `slots.json` (the registry) and `leases\`. It is not under AppData on purpose (see [Design notes](#design-notes)).

## Commands

| Command | What it does |
|---|---|
| `open <slot\|clone> [-BuildTarget <platform>] [-NoWait]` | Starts the editor if the clone is not open and waits until it is ready. `-NoWait` returns right after the launch; then call `wait`. |
| `wait <slot\|clone> [-TimeoutSec 45]` | One bounded wait for a starting editor: READY, STARTING (exit 6), or stalled after 5 minutes (exit 2, with the editor's windows). |
| `close <slot\|clone> [-AllowDirty]` | Runs the beforeClose hooks, asks the editor to quit (same as clicking X), waits, then reports child processes that still run and files git sees as written by the close or changed while it was open. |
| `status [-Json] [-ShowCommandLine]` | Open editors with their child processes and memory (private / working set). |
| `slots [-Json]` | The registry with each slot's state and lease. |
| `scan [-ScanRoot <dir>[,...]] [-Project <owner/repo>[,...]] [-Apply]` | Finds Unity projects under the scan roots, registers clones of the chosen projects and refreshes detected facts. |
| `set <slot> [-Purpose a,b] [-Mode hot\|ondemand] [-AgentUse true\|false] [-Memo <text>] [-BuildTarget <platform>]` | Changes your fields of a slot. |
| `acquire <purpose\|platform> [-Project <repo>] [-Owner <id>] [-Hours 8] [-NoOpen \| -NoWait]` | Leases a free slot that fits and opens its editor. Exit 5 when none is free. |
| `release <slot> [-Owner <id>] [-KeepOpen] [-AnyOwner]` | Closes the editor of an on-demand slot (a hot slot stays open) and drops the lease. Only the lease owner may release; `-AnyOwner` only when a person says so. |
| `renew <slot> [-Owner <id>] [-Hours 8]` | Extends a lease. |
| `new-clone <purpose\|platform> [-Project <repo>] [-From <slot>] [-Name <folder>] [-CloneRoot <dir>] [-NoOpen] [-Apply]` | Plans another clone (dry run). With `-Apply` it makes it: see [New clones](#new-clones). |
| `hooks [<slot> -HookEvent <event>]` | Shows the config file in use, the hooks per event and the extra commands. With a slot and `-HookEvent` it runs that event's hooks now. |
| `<extra command>` | A command your config adds (see [Extra commands](#extra-commands)). |

Options for any command: `-NoHooks` skips every hook, `-SkipHook a,b` skips the named ones, `-TimeoutSec`, `-StandbyWorkers`, `-EditorRoot`, `-Python`.
`-Project` accepts `owner/repo`, the repository name, or the end of it. `-Owner` defaults to `UNITY_SLOT_OWNER`, then `claude:<first 8 characters of CLAUDE_CODE_SESSION_ID>`, then `user@host`.

Exit codes: 0 ok (including "already open" and "already closed"), 1 error, 2 timed out (the editor is left running), 3 editor version not installed, 4 refused (lock held, a beforeClose hook, a batchmode run, someone else's lease, a platform switch, a failed new-clone check), 5 no free slot, 6 still starting.

## Configuration

Settings come from the first file found: `$env:UNITY_SLOT_CONFIG`, `config.json` next to `unity-slot.ps1` (git-ignored), or `%USERPROFILE%\.unity-slot\config.json`. Every key is optional. [config.example.json](config.example.json) lists them all with their defaults. Text values may use `{home}` (user profile), `{repo}` (the unity-slot folder), `{state}` (the state folder) and `%VARIABLES%`.

| Key | Default | Meaning |
|---|---|---|
| `editorRoots` | `C:\Program Files\Unity\Hub\Editor` | Folders that hold `<version>\Editor\Unity.exe`. The Hub's custom install folder is added automatically. |
| `scanRoots` | none | Folders whose subfolders are clones (scan). |
| `cloneRoot` | next to the template | Where new-clone creates clones. |
| `maxEditors` | 6 | acquire and new-clone refuse to start more editors. |
| `standbyWorkers` | 1 | Passed as `-standbyWorkerCount` (idle import workers). `-1` = not passed. |
| `leaseHours` | 8 | Lease length. |
| `python` | python on PATH | For `.py` hooks. |
| `timeouts` | open 300, close 240, wait 45, stalled 300, firstOpen 2400, firstOpenWithLibrary 900, hook 120 | Seconds. |
| `purposeRules` | see below | First guess at purposes during scan. |
| `platformAliases` | none | Extra platform names, for example `{ "mobile": "Android" }`. |
| `hooks` | none | Programs per event (next section). |
| `commands` | none | Extra commands. |

`purposeRules` guess a new slot's purposes from the folder name without the repository name (the suffix) and the platform: no suffix means `main` and not for agents (`mainWhenNoSuffix`), the first matching `suffix` rule adds its purposes (default: digits mean `agent`), the platform adds its purposes (`WebGL`: `webgl`, `Windows`: `windows`), and `fallback` applies when nothing matched. `notCopiedToNewClone` (default `main`) lists purposes a new clone does not inherit from its template. You confirm or change the result with `set`.

## Hooks

Hooks are programs that unity-slot runs at fixed points, so project-specific checks and setup stay out of the core.

| Event | When | Exit 4 means |
|---|---|---|
| `beforeClose` | before close asks an editor to quit | do not close (unless `-AllowDirty`) |
| `afterClose` | after the editor exited | - |
| `openStalled` | open or wait gave up on a starting editor, after the window list | - |
| `closeStalled` | close timed out and the editor is still open, after the window list | - |
| `afterClone` | new-clone made and registered a clone, before its first open | - |
| `afterFirstOpen` | a new clone's editor is ready for the first time | - |

```json
"hooks": {
  "beforeClose": [
    { "name": "scene-beacon", "run": ["{repo}\\examples\\hooks\\scene-beacon.ps1", "-Beacon", "Temp\\SceneBeacon.json"] }
  ],
  "afterClone": [
    { "name": "setup", "run": ["{repo}\\private\\setup-clone.ps1", "-Path", "{clone}"], "timeoutSec": 600 }
  ]
}
```

- `run` is the program and its arguments. `.ps1` runs in Windows PowerShell, `.py` with `python -X utf8`, `.cmd`/`.bat` with cmd.exe, anything else as is. The working folder is the clone.
- Arguments may use `{clone}`, `{slot}`, `{pid}` (editor process), `{log}` (Editor.log), `{platform}`, `{project}`, `{template}` (new-clone) and `{event}`. The same values are in the environment as `UNITY_SLOT_CLONE`, `UNITY_SLOT_SLOT`, ..., plus `UNITY_SLOT_EVENT`, `UNITY_SLOT_REPO` and `UNITY_SLOT_PYTHON`.
- Exit 0 is ok. Exit 4 refuses (it matters for `beforeClose`). Any other exit code is reported as a failed hook and the command goes on. A `.ps1` hook should end with an explicit `exit <n>`.
- Hooks run in order. A hook that runs longer than its `timeoutSec` (default `timeouts.hook`, 120) is reported and left running. It is never killed.
- `"enabled": false` keeps an entry without running it. `unity-slot hooks` lists what is configured; `unity-slot hooks <slot> -HookEvent beforeClose` runs one event by hand.
- `afterFirstOpen` hooks wait in the new slot's registry record until its editor is first ready, whoever opens it (new-clone, open, wait or acquire). They run once.

[examples/hooks/scene-beacon.ps1](examples/hooks/scene-beacon.ps1) refuses a close while unsaved scenes are reported. unity-slot cannot see unsaved scenes by itself, so the hook reads a small JSON file that an editor script in your project keeps up to date. The editor script is not included; the hook's header describes the format.

## Extra commands

`commands` adds commands to `unity-slot.ps1`. unity-slot dot-sources the script and calls the function. The function sees the same parameters (`$Target`, `$From`, `$Apply`, ...) and helpers (`Say`, `Read-Registry`, `Find-Slot`, `Invoke-Git`, ...) as the built-in commands.

```json
"commands": {
  "sync-notes": { "script": "{repo}\\private\\sync-notes.ps1", "function": "Invoke-SyncNotes", "usage": "sync-notes <slot> [-Apply]" }
}
```

A hook can call an extra command, for example `"run": ["{repo}\\unity-slot.ps1", "sync-notes", "{slot}", "-Apply"]`.

## Personal overlay

`config.json` and the `private/` folder are git-ignored. Keep your machine's settings in `config.json`, and your own hooks, extra commands and notes in `private/`. If `private/AGENTS.md` exists, coding agents working on this repository read it too.

## New clones

When `acquire` finds no free slot (exit 5), `new-clone` plans one. Without `-Apply` it only prints the plan and its checks. Show the plan to a person and run it with `-Apply` only after they agree.

1. **Checks.** The target folder must not exist. Free disk must be 1.2 times what is needed (files, `.git`, and `Library` when it is copied). Fewer editors than `maxEditors` must be open. It warns when the template branch has no upstream or has unpushed commits; the new clone only gets what origin has.
2. **Clone.** `git clone --reference <template> --dissociate --branch <template branch> <origin> <root>\<repo>-<n>`. A clone, not a worktree: a worktree cannot check out a branch another worktree has, and slots often share a branch. `--reference` makes it quick, `--dissociate` keeps it independent.
3. **Library.** Copied with robocopy only while the template editor is closed, which avoids a full import. Otherwise the first open imports everything.
4. **Register.** The template's purposes minus `notCopiedToNewClone`, on demand, agent use.
5. **afterClone hooks.**
6. **First open** with `-BuildTarget <template platform>` (up to 15 minutes with a copied Library, 40 without), then the **afterFirstOpen hooks**. With `-NoOpen` the first open is left to you (`open` + `wait`); the hooks still run at its first ready.

It never runs `git clean -x`, `git stash -a`, commits to the project repository, or switches a platform.

## MCP server

[mcp/unity-slot-mcp.ps1](mcp/unity-slot-mcp.ps1) is a stdio MCP server (JSON-RPC, one message per line) for coding agents. It needs nothing besides Windows PowerShell 5.1. Each tool call runs `unity-slot.ps1` in a child process and returns its text, so all logic stays in one place. The client starts the server per session and it ends when stdin closes.

| Tool | What it does |
|---|---|
| `status` | The registry as JSON; `processes=true` shows editor processes and memory instead. |
| `acquire` | Leases a free slot for a purpose and starts its editor without waiting. |
| `open` | Starts a slot's editor and returns at once. |
| `wait_ready` | Waits up to 55 s per call: READY, STARTING (call again), STALLED, NOT RUNNING. |
| `close` | Closes like clicking X. `discard_unsaved=true` uses the official Unity CLI (`unity close`, no save; projects with `com.unity.pipeline` only) and is only for when a person said to drop changes. |
| `release` | Releases a slot you acquired. |
| `create` | Plans a new clone; `confirm=true` creates it (`new-clone -Apply -NoOpen`) after a person agreed to the plan. |

Tool calls stay short: open and acquire return right after the launch and wait_ready is called until READY, so no call sits on a client's tool timeout while Unity starts. The lease owner is `claude:<session>` under Claude Code, otherwise `<client name>:<random>`.

Register it with the full path of your copy:

```powershell
claude mcp add --scope user unity-slot -- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\path\to\unity-slot\mcp\unity-slot-mcp.ps1
```

```toml
# Codex: ~/.codex/config.toml
[mcp_servers.unity-slot]
command = "powershell.exe"
args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\unity-slot\\mcp\\unity-slot-mcp.ps1"]
startup_timeout_sec = 30
tool_timeout_sec = 300
```

```json
// Cursor: mcp.json
{ "mcpServers": { "unity-slot": { "command": "powershell.exe",
  "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\unity-slot\\mcp\\unity-slot-mcp.ps1"] } } }
```

The tools have no MCP annotations, so clients may ask before each call. In a non-interactive run (for example `codex exec`), allow this server's tools in the client's approval settings.

A rule for agents can be this short: "For Unity work, acquire a slot (purpose, project), call wait_ready until READY, check through your Unity MCP that `Application.dataPath` is that slot, work, then release it. Never switch platforms, never take slots leased by others, hand stalls to the user."

## Design notes

- **Launch through WMI.** Some agent shells run inside an app container (for example a desktop app installed as an MSIX package). A child started there with `Start-Process` had its `%LOCALAPPDATA%` writes redirected into the app's private folder and inherited the shell's environment, secrets included. An editor started with `Win32_Process.Create` runs outside: real AppData, none of the shell's variables, a normal window (its parent is `WmiPrvSE.exe`). The state folder is not under AppData for the same reason.
- **Without the Hub.** The editor connects to the running Licensing Client and gets its entitlement. The log notes `Access token is unavailable; failed to update` because no Hub token was passed; opening works.
- **Ready.** The editor is started with `-logFile <clone>\Logs\Editor.log` and is ready when the `##utp:` `ProjectInfo` line of that process id appears. Older editors without it are accepted 15 s after `[Project] Loading completed`. The previous log is kept as `Editor-prev.log`.
- **Already open.** Running `Unity.exe` command lines are matched on `-projectPath` (both the Hub's `-projectpath C:\x` and the import workers' `"-projectPath" "C:/x"`). If none matches but `Temp\UnityLockfile` is held, open refuses.
- **Close.** `CloseMainWindow`, the same as clicking X, so Unity saves as usual. unity-slot waits, then watches the children (import workers, compiler server, MCP servers) for 30 s. It compares `git status` just before the close and with the snapshot that open saved in `Logs\unity-slot-open.txt`, so you see what the close wrote and what changed while the editor was open (for example assets the editor re-serialized). It only reports; nothing is reverted.
- **Platform.** An open editor's platform comes from its window title, a closed clone's from the active platform group in `Library\EditorUserBuildSettings.asset`. `Library\PlayerDataCache` only shows the last player build. `-BuildTarget` is refused when it would switch a clone's platform, because that reimports everything.
- **Standby workers.** Unity 6000.6 rejects `-standbyWorkerCount 0` ("Failed to set standby worker count to 0") and keeps its default of 2; it accepts 1, the default here.
- **Secrets.** Hub-launched editors carry `-accessToken` and `-hubSessionId` on their command line and at the top of Editor.log; import workers carry `-cbmEditorLicense` and `-cbmMachineId`. Every command line or log line unity-slot prints has these values replaced with `***`.
- **Never.** No killed processes, no clicked dialogs, no scheduled tasks or timers that close editors later, no `git pull`, no platform switches, no audio changes. New clones only with `-Apply` after a person agreed.

## Tested with

Windows 10 22H2, Windows PowerShell 5.1, Unity 6000.6.0f1, two projects with several clones each on one machine (up to five editors open at a time). A warm open took 12 to 14 s, the first open after days about 60 s, a close 4 to 13 s. Other Unity versions and machines are untested; reports are welcome.

## License

[MIT](LICENSE)
