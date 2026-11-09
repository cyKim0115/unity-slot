# 시험 하니스가 찾은 문제

`tests\run-tests.ps1`이 찾은 코어 문제를 적습니다. 문제마다 재현 시험을 먼저 넣고(`Add-Test -Known F<n>`, 실패가 KNOWN으로 집계), 코어를 고친 커밋에서 `-Known`을 지웁니다.
고칠 수 없는 것(실제 Unity에서만 재현되는 것 등)만 이유와 함께 「열림」에 남깁니다.

## 열림

(없음)

## 해결

### F3. 개발 중인 사본이 실제 `install.json`을 가져갔습니다 (설계)

- 확인: 2026-11-06 21:16:59와 21:35:08, 하니스 실행 중 실제 상태 점검이 잡았습니다. 재현 시험 `report.install-pointer-kept`(시험 폴더에 버전만 높인 코어 사본을 만들어 돌림). 다른 세션의 워크트리(`<저장소>\.claude\worktrees\b-batch`, 0.5.3·0.5.4)가 실제 상태 폴더로 실행되면서, 라이브 체크아웃을 가리키던 포인터를 자기로 바꿨습니다. 하니스의 실행은 격리돼 있어 포인터를 쓰지 않았습니다.
- 원인: `Update-InstallPointer`(`lib\dashboard.ps1`)는 모든 실행에서 돌고, 다른 사본을 가리키고 있어도 자기 버전이 더 높으면 가져갑니다. 개발 중인 사본은 보통 버전이 더 높습니다.
- 영향: `install.json`으로 코어를 찾는 위젯이 개발 중인 워크트리의 코어를 썼습니다. 그 워크트리를 지우면, 다른 사본이 한 번 실행될 때까지 포인터가 없는 파일을 가리킵니다.
- 수정: 가리키는 다른 사본이 있으면 버전과 상관없이 바꾸지 않습니다. 포인터가 없거나 읽을 수 없을 때, 가리키는 사본이 없어졌을 때, 그 사본 자신(새 버전)만 씁니다. README의 계약 문장도 바꿨습니다. 옮기려면 `install.json`을 지우면 다음에 실행되는 사본이 가져갑니다.
- 남은 일: 고치기 전에 이미 바뀐 실제 포인터는 그대로입니다. 병합 뒤 라이브 체크아웃을 가리키지 않으면 `%USERPROFILE%\.unity-slot\install.json`을 지우고 라이브 체크아웃으로 한 번 실행합니다.

### F2. 자기 임대를 `acquire`로 다시 잡으면 이벤트가 남지 않았습니다 (낮음)

- 확인: 0.5.0~0.5.5. 재현 시험 `lease.acquire-own-lease-logs-renew`.
- 현상: `acquire`가 이미 내 임대인 슬롯을 고르면 만료 시각을 늘리고(`lease   already yours; extended to ...`) `events.jsonl`에는 아무것도 쓰지 않았습니다. 같은 일을 하는 `renew`는 `renew` 이벤트를 남깁니다. 대시보드·위젯이 이 연장을 볼 수 없었습니다.
- 수정: 이 경로도 `renew` 이벤트를 남깁니다(`detail.by`가 `acquire`). `mcp.lease-flow`의 기대 이벤트 순서에 `renew`가 들어갔습니다.

### F4. 만료 임대를 두 acquire가 함께 넘겨받을 수 있었습니다

- 확인: 0.5.4~0.5.5. 재현 시험 `lease.takeover-race`(`tests\fixtures\takeover-race.ps1`이 두 프로세스의 순서를 고정해 재현).
- 원인: `New-SlotLease`(`lib\lease.ps1`)는 만료 임대를 넘겨받을 때 새 임대를 쓰고 300 ms 뒤 nonce를 다시 읽어 자기 것이면 이긴 것으로 봤습니다. 두 프로세스가 같은 만료 임대를 읽은 뒤, 한쪽의 확인이 끝난 다음에 다른 쪽이 쓰면 둘 다 자기 nonce를 읽고 둘 다 이겼습니다. 먼저 이긴 쪽은 남이 덮어쓴 임대를 자기 것으로 알고 일합니다.
- 수정: 넘겨받을 때 임대 파일을 공유 없이 열고, 읽어 둔 만료 임대의 nonce가 그대로이며 아직 만료인 때만 그 자리에서 바꿉니다(`Invoke-Acquire`가 본 nonce를 넘김). 300 ms 대기도 없어졌습니다.

### F1. `open`·`acquire`의 `-TimeoutSec`이 무시됐습니다 (new-clone 첫 열기 대기도)

- 확인: 0.5.0~0.5.3. 재현 시험 `start.open-timeout-argument`(0.5.4부터 통과).
- 원인: `Invoke-Open`(`unity-slot.ps1`)의 매개변수 `$Timeout`과 지역변수 `$timeout`은 PowerShell에서 같은 변수입니다(변수 이름의 대소문자를 가리지 않습니다). 첫 줄 `$timeout = Get-TimeoutSetting 'open' 300`이 인자를 덮어써서, `open -TimeoutSec`과 new-clone 첫 열기의 `firstOpenWithLibrary`(900초)·`firstOpen`(2400초)가 늘 `timeouts.open`(300초)이 됐습니다.
- 수정: 코어 담당 세션이 `170068b`(0.5.4, B2와 함께)에서 지역변수를 `$limit`로 바꿨습니다.
