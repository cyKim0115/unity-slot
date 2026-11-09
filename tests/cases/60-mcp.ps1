# The MCP server: protocol (initialize, BOM, ping, tools/list, errors, stdout only JSON) and a lease flow
# through tools/call (exit codes, isError, events via mcp). Dot-sourced by tests\run-tests.ps1.
# ASCII-only source.

Register-Group 'mcp' -Clones @('MyGame-1', 'MyGame-Web')

Add-Test -Name 'mcp.protocol' -Group 'mcp' -Body {
    param($E)
    $S = Start-McpServer $E
    $stderr = ''
    try {
        # a .NET parent may put a UTF-8 BOM before the first message
        $init = Initialize-Mcp $S '2025-03-26' 'slot test!' -Bom
        $res = $init.result
        Assert-Equal $res.protocolVersion '2025-03-26' 'protocolVersion'
        Assert-Equal $res.serverInfo.name 'unity-slot' 'serverInfo.name'
        Assert-Equal $res.serverInfo.version (Get-CoreVersion) 'serverInfo.version'
        Assert-True ($res.capabilities.tools.listChanged -eq $false) 'capabilities.tools.listChanged'
        foreach ($word in @('acquire(purpose, project)', 'wait_ready', 'release(slot)')) { Assert-Has $res.instructions $word 'instructions' }
        $ping = Invoke-Mcp $S 'ping'
        Assert-True ($null -ne (Get-P $ping 'result')) 'ping result'
        $tools = @((Invoke-Mcp $S 'tools/list').result.tools)
        Assert-Equal (($tools | ForEach-Object { $_.name }) -join ',') 'status,acquire,open,wait_ready,close,release,create' 'tools'
        $required = @{ status = ''; acquire = 'purpose'; open = 'slot'; wait_ready = 'slot'; close = 'slot'; release = 'slot'; create = 'purpose' }
        foreach ($t in $tools) {
            Assert-Equal $t.inputSchema.type 'object' ($t.name + ' inputSchema.type')
            Assert-True ([string]$t.description -ne '') ($t.name + ' description')
            Assert-Equal (@(Get-P $t.inputSchema 'required') -join ',') $required[$t.name] ($t.name + ' required')
        }
        Send-McpLine $S '{"jsonrpc": "2.0", "id": 99, "method": "tools/li'
        $perr = Read-McpMessage $S
        Assert-Equal $perr.error.code -32700 'parse error code'
        Assert-True ($null -eq $perr.id) 'parse error id is null'
        # a notification gets no answer, even for an unknown method; a request gets -32601
        [void](Send-McpRequest $S 'notifications/whatever' $null -Notification)
        $u = Invoke-Mcp $S 'foo/bar'
        Assert-Equal $u.error.code -32601 'unknown method code'
        Assert-Equal $u.error.message 'method not found: foo/bar' 'unknown method message'
        $t = Invoke-McpTool $S 'nope' $null
        Assert-True $t.IsError 'unknown tool isError'
        Assert-Has $t 'unity-slot MCP error: unknown tool: nope'
    } finally {
        $stderr = Stop-McpServer $S
    }
    Assert-Like $stderr 'initialize 2025-03-26 -> 2025-03-26, owner slottest:[0-9a-f]{6}' 'server stderr'
    Assert-Has $stderr 'stdin closed, exiting' 'server stderr'
    # an unknown protocol version gets the newest one this server knows
    $S2 = Start-McpServer $E
    try {
        $i2 = Initialize-Mcp $S2 '1999-01-01' 'other'
        Assert-Equal $i2.result.protocolVersion '2025-06-18' 'protocolVersion for an unknown version'
    } finally { [void](Stop-McpServer $S2) }
}

Add-Test -Name 'mcp.lease-flow' -Group 'mcp' -Body {
    param($E)
    Set-StubControl $E.Clones['MyGame-Web'] @{ mode = 'normal'; readyMs = '1500' } -Reset
    $n0 = Get-EventCount $E
    $S = Start-McpServer $E
    $owner = ''
    try {
        [void](Initialize-Mcp $S '2025-06-18' 'slot test!')
        $st = Invoke-McpTool $S 'status' @{ format = 'json' }
        Assert-Equal $st.Code 0 'status exit'
        Assert-True (-not $st.IsError) 'status isError'
        $json = (($st.Text -split "`n", 2)[1]) | ConvertFrom-Json
        Assert-Equal @($json.slots).Count 2 'status format=json slots'
        Assert-True (Test-UnderPath $json.registry $E.Home) ('status registry ' + $json.registry)

        $a = Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame' }
        Assert-Equal $a.Code 0 ('acquire exit' + (Format-Excerpt $a))
        Assert-Has $a 'ACQUIRED MyGame-Web'
        $owner = Get-Match $a.Text '\[acquire\] lease   (\S+) until '
        Assert-Like $owner '^slottest:[0-9a-f]{6}$' 'MCP session owner'
        $w = $null
        for ($i = 0; $i -lt 4; $i++) {
            $w = Invoke-McpTool $S 'wait_ready' @{ slot = 'MyGame-Web'; timeout_sec = 20 }
            if ($w.Code -ne 6) { break }
        }
        Assert-Equal $w.Code 0 ('wait_ready exit' + (Format-Excerpt $w))
        Assert-Has $w 'READY pid'

        $x = Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web'; owner = 'someone-else' }
        Assert-Equal $x.Code 4 'release by another owner'
        Assert-True $x.IsError 'refused is an error'
        Assert-Equal $x.CodeLabel 'refused' 'refused label'
        $again = Invoke-McpTool $S 'acquire' @{ purpose = 'webgl'; project = 'mygame' }
        Assert-Equal $again.Code 0 'acquire again'
        Assert-Has $again 'already yours'
        $none = Invoke-McpTool $S 'acquire' @{ purpose = 'nosuch'; project = 'mygame'; open = $false }
        Assert-Equal $none.Code 5 'acquire without a fitting slot'
        Assert-True (-not $none.IsError) 'exit 5 is not an error'
        Assert-Equal $none.CodeLabel 'no free slot' 'exit 5 label'
        $plan = Invoke-McpTool $S 'create' @{ purpose = 'webgl'; project = 'mygame' }
        Assert-Equal $plan.Code 0 ('create dry run' + (Format-Excerpt $plan))
        Assert-Has $plan 'dry-run: nothing was created'
        Assert-Equal @(Get-ChildItem -LiteralPath $E.ClonesDir -Directory).Count 2 'create without confirm made no clone'
        $r = Invoke-McpTool $S 'release' @{ slot = 'MyGame-Web' }
        Assert-Equal $r.Code 0 'release'
        Assert-Has $r 'RELEASED MyGame-Web'
    } finally { [void](Stop-McpServer $S) }
    $ev = @(Get-NewEvents $E $n0)
    Assert-True ($ev.Count -ge 6) ('events: ' + (($ev | ForEach-Object { $_.event }) -join ','))
    foreach ($ev1 in $ev) { Assert-Equal $ev1.via 'mcp' ('via of ' + $ev1.event) }
    foreach ($ev1 in @($ev | Where-Object { $_.event -in @('acquire', 'release') })) { Assert-Equal $ev1.owner $owner ('owner of ' + $ev1.event) }
    # acquiring a slot you already hold is logged as a renew (tests\FINDINGS.md F2)
    Assert-Equal (($ev | ForEach-Object { $_.event }) -join ',') 'acquire,open,ready,refused,renew,close,release' 'events'
}
