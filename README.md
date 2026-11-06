# unity-slot

[English](README.en.md)

Unity 프로젝트의 클론 여러 개를 **슬롯**으로 등록해 두고, 에디터는 쓰는 동안에만 엽니다. AI 코딩 에이전트는 용도(「WebGL 클론」, 「아무 에이전트 클론」)로 슬롯을 임대해 그 안에서 일하고, 끝나면 놓습니다. 빈 슬롯이 없으면 새 클론 계획을 보여 주고, 사람이 동의해야 만듭니다.

PowerShell 스크립트 하나와 작은 라이브러리, 선택으로 쓰는 MCP 서버로 되어 있습니다. 프로세스를 강제 종료하지 않고, 대화상자 버튼을 누르지 않고, 클론의 플랫폼을 바꾸지 않고, 타이머나 예약 작업을 만들지 않습니다.

**Windows 전용입니다.** 에디터를 WMI(`Win32_Process.Create`)로 띄우고 창은 Win32 API로 읽습니다.

> **Unity 라이선스.** Unity 에디터를 동시에 여러 개 실행하는 일은 각자의 Unity 라이선스와 약관을 따릅니다. 슬롯 여러 개를 동시에 열어 두기 전에 직접 확인하세요.

## 왜 만들었나

한 Unity 프로젝트를 나눠 작업할 때(에이전트별·플랫폼별·브랜치별 클론) 클론을 따로 두면 편하지만, 열린 에디터 하나하나가 비쌉니다. 임포트 워커·컴파일러 서버·셰이더 컴파일러 같은 자식 프로세스까지 더하면 에디터 하나가 **Private 메모리 5~12GB**를 썼습니다(실측). unity-slot은 클론을 등록해 두고 쓰는 동안에만 에디터를 엽니다. 이미 열린 클론인지 확인하고, 에디터가 정말 준비될 때까지 기다리고, 닫을 때 무엇이 바뀌었는지 알려 줍니다.

## 필요한 것

- Windows 10·11과 Windows PowerShell 5.1(기본 탑재). 따로 설치할 것은 없습니다.
- Unity Hub로 설치한 Unity, 또는 `<버전>\Editor\Unity.exe`가 있는 폴더.
- git.
- 선택: `.py` 훅을 쓸 때만 Python.

## 빠르게 시작하기

```powershell
git clone <이 저장소> unity-slot
cd unity-slot
copy config.example.json config.json      # 선택: 스캔 루트, 클론 위치, 훅 등

# 한 프로젝트의 클론을 등록합니다 (먼저 dry-run, 그다음 -Apply)
.\unity-slot.ps1 scan -ScanRoot C:\Projects -Project my-org/my-game
.\unity-slot.ps1 scan -ScanRoot C:\Projects -Project my-org/my-game -Apply
.\unity-slot.ps1 slots
.\unity-slot.ps1 set MyGame-2 -Purpose agent,webgl -Memo '웹 수정용 에이전트 클론'

# 빈 슬롯을 임대하고, 일하고, 놓습니다
.\unity-slot.ps1 acquire webgl -Project my-game -Owner me
.\unity-slot.ps1 release MyGame-2 -Owner me
```

cmd나 Git Bash에서는 `unity-slot.cmd <명령> ...`으로 쓰세요.

## 개념

- **슬롯.** 등록한 Unity 프로젝트 클론 폴더(git clone이나 worktree)입니다. Unity 버전·브랜치·origin·플랫폼은 unity-slot이 감지합니다. *용도*(`agent`·`webgl`·`build` 같은 자유 태그), *운용*(`hot`: 늘 열어 둠, `ondemand`: 필요할 때 엶), 에이전트 사용 여부(`agentUse`), 메모는 사람이 정합니다.
- **임대.** 임대한 슬롯마다 파일 하나입니다. `FileMode.CreateNew`로 만들어서 두 세션이 같은 슬롯을 잡지 못합니다. `leaseHours`(8시간) 뒤에 만료됩니다. 만료된 임대는 *닫힌* 슬롯을 다음 acquire에 내줍니다. 에디터를 닫지는 않습니다.
- **빈 슬롯.** `agentUse`가 켜져 있고, 용도나 플랫폼이 맞고, 남의 유효한 임대가 없고, batchmode Unity가 돌고 있지 않고, 에디터가 닫혀 있거나 `hot` 슬롯이어야 합니다. 임대 없이 열려 있는 온디맨드 슬롯은 누가 쓰는 중으로 봅니다. acquire는 내 임대, 열린 hot 슬롯, 가장 최근에 쓴 닫힌 슬롯 순으로 고릅니다.
- **상태.** `%USERPROFILE%\.unity-slot`(`UNITY_SLOT_HOME`으로 옮길 수 있습니다)에 `slots.json`(등록부)과 `leases\`가 있습니다. 일부러 AppData 밖에 둡니다([설계 메모](#설계-메모) 참고).

## 명령

| 명령 | 하는 일 |
|---|---|
| `open <슬롯\|클론> [-BuildTarget <플랫폼>] [-NoWait]` | 클론이 열려 있지 않으면 에디터를 띄우고 준비될 때까지 기다립니다. `-NoWait`면 띄우고 바로 끝나니, 그다음 `wait`를 부르면 됩니다. |
| `wait <슬롯\|클론> [-TimeoutSec 45]` | 시작 중인 에디터를 한 번 정해진 시간만큼 기다립니다. READY, STARTING(exit 6), 5분이 넘으면 멈춤으로 봅니다(exit 2, 에디터 창 목록). |
| `close <슬롯\|클론> [-AllowDirty]` | beforeClose 훅을 돌리고, X 버튼처럼 닫기를 요청하고, 기다린 뒤 남은 자식 프로세스와 git이 보는 변경(닫으며 쓴 파일, 열린 동안 바뀐 파일)을 알려 줍니다. |
| `status [-Json] [-ShowCommandLine]` | 열린 에디터와 자식 프로세스, 메모리(Private/작업 집합)를 보여 줍니다. |
| `slots [-Json]` | 등록부와 슬롯별 상태·임대를 보여 줍니다. |
| `scan [-ScanRoot <폴더>[,...]] [-Project <owner/repo>[,...]] [-Apply]` | 스캔 루트 아래 Unity 프로젝트를 찾아 고른 프로젝트의 클론을 등록하고, 감지한 값을 새로 고칩니다. |
| `set <슬롯> [-Purpose a,b] [-Mode hot\|ondemand] [-AgentUse true\|false] [-Memo <글>] [-BuildTarget <플랫폼>]` | 슬롯에서 사람이 정하는 칸을 바꿉니다. |
| `acquire <용도\|플랫폼> [-Project <repo>] [-Owner <id>] [-Hours 8] [-NoOpen \| -NoWait]` | 맞는 빈 슬롯을 임대하고 에디터를 엽니다. 없으면 exit 5. |
| `release <슬롯> [-Owner <id>] [-KeepOpen] [-AnyOwner]` | 온디맨드 슬롯이면 에디터를 닫고(hot 슬롯은 열어 둡니다) 임대를 풉니다. 임대 주인만 할 수 있습니다. `-AnyOwner`는 사람이 시킬 때만 쓰세요. |
| `renew <슬롯> [-Owner <id>] [-Hours 8]` | 임대를 늘립니다. |
| `new-clone <용도\|플랫폼> [-Project <repo>] [-From <슬롯>] [-Name <폴더>] [-CloneRoot <폴더>] [-NoOpen] [-Apply]` | 새 클론 계획(dry-run)을 보여 줍니다. `-Apply`면 만듭니다. [새 클론](#새-클론) 참고. |
| `hooks [<슬롯> -HookEvent <이벤트>]` | 쓰는 설정 파일, 이벤트별 훅, 추가 명령을 보여 줍니다. 슬롯과 `-HookEvent`를 주면 그 이벤트의 훅을 지금 돌립니다. |
| `<추가 명령>` | 설정에서 더한 명령([추가 명령](#추가-명령)). |

모든 명령에 쓰는 옵션: `-NoHooks`(훅 모두 건너뜀), `-SkipHook a,b`(이름으로 건너뜀), `-TimeoutSec`, `-StandbyWorkers`, `-EditorRoot`, `-Python`.
`-Project`에는 `owner/repo`, 저장소 이름, 그 이름의 끝을 쓸 수 있습니다. `-Owner` 기본값은 `UNITY_SLOT_OWNER`, 없으면 `claude:<CLAUDE_CODE_SESSION_ID 앞 8자>`, 없으면 `user@host`입니다.

종료 코드: 0 정상(「이미 열림」·「이미 닫힘」 포함), 1 오류, 2 시간 초과(에디터는 그대로 둠), 3 에디터 버전 미설치, 4 거부(잠금, beforeClose 훅, batchmode 실행, 남의 임대, 플랫폼 전환, new-clone 점검 실패), 5 빈 슬롯 없음, 6 아직 시작 중.

## 설정

설정은 처음 찾은 파일에서 읽습니다: `$env:UNITY_SLOT_CONFIG`, `unity-slot.ps1` 옆의 `config.json`(git 무시), `%USERPROFILE%\.unity-slot\config.json`. 모든 키는 선택입니다. [config.example.json](config.example.json)에 키와 기본값이 다 있습니다. 글자 값에는 `{home}`(사용자 프로필), `{repo}`(unity-slot 폴더), `{state}`(상태 폴더), `%환경변수%`를 쓸 수 있습니다.

| 키 | 기본값 | 뜻 |
|---|---|---|
| `editorRoots` | `C:\Program Files\Unity\Hub\Editor` | `<버전>\Editor\Unity.exe`가 있는 폴더. Hub의 사용자 지정 설치 폴더는 자동으로 더합니다. |
| `scanRoots` | 없음 | 하위 폴더가 클론인 폴더(scan). |
| `cloneRoot` | 템플릿 옆 | new-clone이 클론을 만드는 곳. |
| `maxEditors` | 6 | acquire·new-clone이 이보다 많이 띄우지 않습니다. |
| `standbyWorkers` | 1 | `-standbyWorkerCount`로 넘깁니다(쉬는 임포트 워커 수). `-1`이면 넘기지 않습니다. |
| `leaseHours` | 8 | 임대 시간. |
| `python` | PATH의 python | `.py` 훅용. |
| `timeouts` | open 300, close 240, wait 45, stalled 300, firstOpen 2400, firstOpenWithLibrary 900, hook 120 | 초. |
| `purposeRules` | 아래 | scan이 잡는 용도 초안. |
| `platformAliases` | 없음 | 플랫폼 별칭. 예: `{ "mobile": "Android" }` |
| `hooks` | 없음 | 이벤트별 프로그램(다음 절). |
| `commands` | 없음 | 추가 명령. |

`purposeRules`는 폴더 이름에서 저장소 이름을 뺀 나머지(접미사)와 플랫폼으로 새 슬롯의 용도를 짐작합니다. 접미사가 없으면 `main`이고 에이전트용이 아닙니다(`mainWhenNoSuffix`). 처음 맞는 `suffix` 규칙의 용도를 더합니다(기본: 숫자면 `agent`). 플랫폼의 용도를 더합니다(`WebGL`: `webgl`, `Windows`: `windows`). 아무것도 안 맞으면 `fallback`을 씁니다. `notCopiedToNewClone`(기본 `main`)은 새 클론이 템플릿에서 물려받지 않는 용도입니다. 결과는 사람이 `set`으로 확인하거나 고칩니다.

## 훅

훅은 unity-slot이 정해진 시점에 돌리는 프로그램입니다. 프로젝트마다 다른 점검과 준비를 코어 밖에 두려고 씁니다.

| 이벤트 | 시점 | exit 4의 뜻 |
|---|---|---|
| `beforeClose` | close가 에디터에 닫기를 요청하기 전 | 닫지 않음(`-AllowDirty`면 무시) |
| `afterClose` | 에디터가 끝난 뒤 | - |
| `openStalled` | open이나 wait가 시작 중인 에디터를 더 기다리지 않을 때, 창 목록 다음 | - |
| `closeStalled` | close가 시간 초과로 끝나고 에디터가 아직 열려 있을 때, 창 목록 다음 | - |
| `afterClone` | new-clone이 클론을 만들고 등록한 뒤, 첫 열기 전 | - |
| `afterFirstOpen` | 새 클론의 에디터가 처음 준비됐을 때 | - |

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

- `run`은 프로그램과 인자입니다. `.ps1`은 Windows PowerShell, `.py`는 `python -X utf8`, `.cmd`·`.bat`은 cmd.exe, 나머지는 그대로 실행합니다. 작업 폴더는 그 클론입니다.
- 인자에는 `{clone}`, `{slot}`, `{pid}`(에디터 프로세스), `{log}`(Editor.log), `{platform}`, `{project}`, `{template}`(new-clone), `{event}`를 쓸 수 있습니다. 같은 값이 환경변수 `UNITY_SLOT_CLONE`, `UNITY_SLOT_SLOT`, ...로도 들어가고, `UNITY_SLOT_EVENT`, `UNITY_SLOT_REPO`, `UNITY_SLOT_PYTHON`도 들어갑니다.
- exit 0은 정상입니다. exit 4는 거부입니다(`beforeClose`에서 의미가 있습니다). 그 밖의 종료 코드는 실패한 훅으로 알리고 명령은 계속합니다. `.ps1` 훅은 끝에 `exit <n>`을 명시하세요.
- 훅은 순서대로 돕니다. `timeoutSec`(기본 `timeouts.hook`, 120초)보다 오래 걸리면 알리고 그대로 둡니다. 강제 종료하지 않습니다.
- `"enabled": false`면 항목을 남겨 두고 돌리지 않습니다. `unity-slot hooks`는 설정된 훅을 보여 주고, `unity-slot hooks <슬롯> -HookEvent beforeClose`는 한 이벤트를 손으로 돌립니다.
- `afterFirstOpen` 훅은 새 슬롯의 등록부 기록에서 기다리다가, 누가 열든(new-clone, open, wait, acquire) 그 에디터가 처음 준비됐을 때 한 번 돕니다.

[examples/hooks/scene-beacon.ps1](examples/hooks/scene-beacon.ps1)은 저장하지 않은 씬이 있다고 알려 오면 close를 거부합니다. unity-slot은 미저장 씬을 스스로 볼 수 없어서, 프로젝트의 에디터 스크립트가 갱신하는 작은 JSON 파일을 읽습니다. 에디터 스크립트는 들어 있지 않습니다. 파일 형식은 훅 머리말에 있습니다.

## 추가 명령

`commands`로 `unity-slot.ps1`에 명령을 더합니다. unity-slot이 그 스크립트를 dot-source하고 함수를 부릅니다. 함수는 내장 명령과 같은 매개변수(`$Target`, `$From`, `$Apply`, ...)와 도우미(`Say`, `Read-Registry`, `Find-Slot`, `Invoke-Git`, ...)를 쓸 수 있습니다.

```json
"commands": {
  "sync-notes": { "script": "{repo}\\private\\sync-notes.ps1", "function": "Invoke-SyncNotes", "usage": "sync-notes <slot> [-Apply]" }
}
```

훅이 추가 명령을 부를 수도 있습니다. 예: `"run": ["{repo}\\unity-slot.ps1", "sync-notes", "{slot}", "-Apply"]`.

## 개인 오버레이

`config.json`과 `private/` 폴더는 git이 무시합니다. 내 기기 설정은 `config.json`에, 내 훅·추가 명령·메모는 `private/`에 두세요. `private/AGENTS.md`가 있으면 이 저장소에서 일하는 코딩 에이전트가 그것도 읽습니다.

## 새 클론

`acquire`가 빈 슬롯을 못 찾으면(exit 5) `new-clone`으로 계획합니다. `-Apply`가 없으면 계획과 점검 결과만 보여 줍니다. 그 계획을 사람에게 보여 주고, 동의한 뒤에만 `-Apply`로 돌리세요.

1. **점검.** 대상 폴더가 없어야 합니다. 디스크 여유가 필요량(파일, `.git`, 복사할 때의 `Library`)의 1.2배 이상이어야 합니다. 열린 에디터가 `maxEditors`보다 적어야 합니다. 템플릿 브랜치에 upstream이 없거나 푸시하지 않은 커밋이 있으면 경고합니다. 새 클론은 origin에 있는 것만 받습니다.
2. **클론.** `git clone --reference <템플릿> --dissociate --branch <템플릿 브랜치> <origin> <루트>\<repo>-<번호>`. 워크트리가 아니라 클론입니다. 워크트리는 다른 워크트리가 쓰는 브랜치를 체크아웃할 수 없고, 슬롯끼리는 브랜치를 자주 같이 씁니다. `--reference`로 빠르게 받고 `--dissociate`로 템플릿과 끊습니다.
3. **Library.** 템플릿 에디터가 닫혀 있을 때만 robocopy로 복사합니다(전체 임포트를 피하려고). 열려 있으면 첫 열기에서 전부 임포트합니다.
4. **등록.** 템플릿 용도에서 `notCopiedToNewClone`을 빼고, 온디맨드·에이전트 사용으로 등록합니다.
5. **afterClone 훅.**
6. **첫 열기**를 `-BuildTarget <템플릿 플랫폼>`으로 하고(Library를 복사했으면 15분, 아니면 40분까지 기다림), 그다음 **afterFirstOpen 훅**을 돌립니다. `-NoOpen`이면 첫 열기는 사람이 합니다(`open` + `wait`). 훅은 그때 처음 준비됐을 때 돕니다.

`git clean -x`, `git stash -a`, 프로젝트 저장소 커밋, 플랫폼 전환은 하지 않습니다.

## MCP 서버

[mcp/unity-slot-mcp.ps1](mcp/unity-slot-mcp.ps1)은 코딩 에이전트용 stdio MCP 서버입니다(JSON-RPC, 한 줄에 메시지 하나). Windows PowerShell 5.1 말고는 필요한 것이 없습니다. 도구 호출마다 `unity-slot.ps1`을 자식 프로세스로 돌려 그 출력을 돌려주므로 로직은 한 곳에 있습니다. 클라이언트가 세션마다 서버를 띄우고, stdin이 닫히면 끝납니다.

| 도구 | 하는 일 |
|---|---|
| `status` | 등록부 JSON을 돌려줍니다. `processes=true`면 에디터 프로세스와 메모리도 돌려줍니다. |
| `acquire` | 용도로 빈 슬롯을 임대하고 에디터를 띄운 뒤 기다리지 않고 돌아옵니다. |
| `open` | 슬롯의 에디터를 띄우고 바로 돌아옵니다. |
| `wait_ready` | 호출마다 최대 55초 기다립니다. READY, STARTING(다시 부름), STALLED, NOT RUNNING. |
| `close` | X 버튼처럼 닫습니다. `discard_unsaved=true`면 공식 Unity CLI(`unity close`, 저장 안 함, `com.unity.pipeline`이 있는 프로젝트만)를 쓰므로, 사람이 변경을 버리라고 했을 때만 쓰세요. |
| `release` | 임대한 슬롯을 놓습니다. |
| `create` | 새 클론을 계획합니다. 사람이 계획에 동의한 뒤 `confirm=true`로 만듭니다(`new-clone -Apply -NoOpen`). |

도구 호출은 짧게 끝납니다. open·acquire는 띄우자마자 돌아오고 wait_ready를 READY까지 부르므로, Unity가 시작하는 동안 클라이언트의 도구 시간 제한에 걸리지 않습니다. 임대 주인은 Claude Code에서는 `claude:<세션>`, 그 밖에서는 `<클라이언트 이름>:<무작위>`입니다.

내 복사본의 전체 경로로 등록하세요.

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

도구에 MCP annotations가 없어서 클라이언트가 호출마다 승인을 물을 수 있습니다. 비대화형 실행(예: `codex exec`)에서는 클라이언트 승인 설정에서 이 서버의 도구를 허용하세요.

에이전트 규칙은 이 정도로 짧아도 됩니다: 「Unity 작업은 슬롯을 acquire(용도, 프로젝트)하고, READY까지 wait_ready를 부르고, Unity MCP로 `Application.dataPath`가 그 슬롯인지 확인한 뒤 일하고, 끝나면 release하세요. 플랫폼을 바꾸지 말고, 남이 임대한 슬롯을 잡지 말고, 멈추면 사용자에게 넘기세요.」

## 설계 메모

- **WMI로 띄웁니다.** 어떤 에이전트 셸은 앱 컨테이너 안에서 돕니다(예: MSIX 패키지로 설치한 데스크톱 앱). 거기서 `Start-Process`로 띄운 자식은 `%LOCALAPPDATA%` 쓰기가 앱 전용 폴더로 갔고, 셸의 환경변수(시크릿 포함)도 물려받았습니다. `Win32_Process.Create`로 띄운 에디터는 밖에서 돕니다. 실제 AppData를 쓰고, 셸 변수를 받지 않고, 창도 평소처럼 뜹니다(부모는 `WmiPrvSE.exe`). 상태 폴더를 AppData 밖에 두는 이유도 같습니다.
- **Hub 없이.** 에디터는 실행 중인 Licensing Client에 붙어 entitlement를 받습니다. Hub 토큰이 없어서 로그에 `Access token is unavailable; failed to update`가 찍히지만, 열기에는 지장이 없습니다.
- **준비 판정.** 에디터를 `-logFile <클론>\Logs\Editor.log`로 띄우고, 그 프로세스 ID의 `##utp:` `ProjectInfo` 줄이 찍히면 준비로 봅니다. 그 줄이 없는 옛 에디터는 `[Project] Loading completed` 15초 뒤를 준비로 봅니다. 이전 로그는 `Editor-prev.log`로 남겨 둡니다.
- **이미 열림.** 실행 중인 `Unity.exe` 명령줄의 `-projectPath`로 맞춥니다(Hub 형식 `-projectpath C:\x`와 임포트 워커 형식 `"-projectPath" "C:/x"` 모두). 맞는 프로세스가 없는데 `Temp\UnityLockfile`이 잠겨 있으면 열지 않습니다.
- **닫기.** X 버튼과 같은 `CloseMainWindow`라서 Unity가 평소처럼 저장합니다. 끝날 때까지 기다리고, 자식 프로세스(임포트 워커, 컴파일러 서버, MCP 서버)를 30초 동안 지켜봅니다. 닫기 직전의 `git status`와, open이 `Logs\unity-slot-open.txt`에 남긴 스냅샷을 비교해 「닫으며 쓴 파일」과 「열린 동안 바뀐 파일」(에디터가 재직렬화한 에셋 등)을 보여 줍니다. 보고만 하고 되돌리지 않습니다.
- **플랫폼.** 열린 에디터는 창 제목, 닫힌 클론은 `Library\EditorUserBuildSettings.asset`의 활성 플랫폼 그룹으로 봅니다. `Library\PlayerDataCache`는 마지막 플레이어 빌드만 보여 줍니다. 클론의 플랫폼을 바꾸게 되는 `-BuildTarget`은 거부합니다. 전부 다시 임포트하게 되기 때문입니다.
- **쉬는 워커.** Unity 6000.6은 `-standbyWorkerCount 0`을 거부하고(「Failed to set standby worker count to 0」) 기본값 2를 씁니다. 1은 받습니다. 그래서 기본값이 1입니다.
- **비밀값.** Hub가 띄운 에디터의 명령줄과 Editor.log 머리에는 `-accessToken`·`-hubSessionId`가, 임포트 워커에는 `-cbmEditorLicense`·`-cbmMachineId`가 있습니다. unity-slot이 출력하는 명령줄과 로그 줄에서는 이 값을 `***`로 바꿉니다.
- **하지 않는 것.** 강제 종료, 대화상자 클릭, 나중에 에디터를 닫는 예약 작업·타이머, `git pull`, 플랫폼 전환, 소리 설정 변경. 새 클론은 사람이 동의한 뒤 `-Apply`로만 만듭니다.

## 시험한 환경

Windows 10 22H2, Windows PowerShell 5.1, Unity 6000.6.0f1, 한 기기에서 프로젝트 2개와 각각의 클론 여러 개(동시에 에디터 최대 5개). 다시 열기는 12~14초, 며칠 만의 첫 열기는 약 60초, 닫기는 4~13초 걸렸습니다. 다른 Unity 버전과 기기에서는 시험하지 않았습니다. 결과를 알려 주시면 반영하겠습니다.

## 라이선스

[MIT](LICENSE)
