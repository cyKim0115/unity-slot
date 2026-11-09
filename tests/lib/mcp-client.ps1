# A small MCP client for the tests: starts mcp\unity-slot-mcp.ps1 with a test environment and talks
# JSON-RPC over its stdin/stdout (one message per line). Dot-sourced by tests\run-tests.ps1.
# ASCII-only source.

function Start-McpServer($E, [hashtable]$ExtraEnv = $null) {
    $vars = Get-SlotEnvVars $E
    $vars['UNITY_SLOT_OWNER'] = $null
    if ($null -ne $ExtraEnv) { foreach ($k in @($ExtraEnv.Keys)) { $vars[$k] = $ExtraEnv[$k] } }
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-CmdArg $script:McpPath)
    $p = Start-Child $script:PowerShellExe $line $vars
    return [pscustomobject]@{
        Proc = $p; ErrTask = $p.StandardError.ReadToEndAsync(); Pending = $null; NextId = 1; E = $E
        Lines = (New-Object 'System.Collections.Generic.List[string]')
    }
}

# Writes one line of raw bytes (UTF-8, optionally with a BOM in front) to the server's stdin.
function Send-McpLine($S, [string]$Text, [switch]$Bom) {
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    if ($Bom) { $bytes.AddRange([byte[]](0xEF, 0xBB, 0xBF)) }
    $bytes.AddRange($script:Utf8.GetBytes($Text + "`n"))
    $arr = $bytes.ToArray()
    $S.Proc.StandardInput.BaseStream.Write($arr, 0, $arr.Length)
    $S.Proc.StandardInput.BaseStream.Flush()
}

# The next stdout line as a parsed JSON-RPC message. Every stdout line must be JSON.
function Read-McpMessage($S, [int]$TimeoutSec = 90) {
    if ($null -eq $S.Pending) { $S.Pending = $S.Proc.StandardOutput.ReadLineAsync() }
    if (-not $S.Pending.Wait($TimeoutSec * 1000)) { Fail ('no MCP message within {0}s' -f $TimeoutSec) }
    $line = $S.Pending.Result
    $S.Pending = $null
    if ($null -eq $line) { Fail 'the MCP server closed stdout' }
    $S.Lines.Add($line)
    try { $msg = $line | ConvertFrom-Json } catch { Fail ('stdout line is not JSON: ' + $line) }
    if ((Get-P $msg 'jsonrpc') -ne '2.0') { Fail ('not a JSON-RPC 2.0 message: ' + $line) }
    return $msg
}

function Send-McpRequest($S, [string]$Method, $Params = $null, [switch]$Notification, [switch]$Bom) {
    $msg = [ordered]@{ jsonrpc = '2.0' }
    $id = $null
    if (-not $Notification) { $id = $S.NextId; $S.NextId++; $msg.id = $id }
    $msg.method = $Method
    if ($null -ne $Params) { $msg.params = $Params }
    Send-McpLine $S ($msg | ConvertTo-Json -Compress -Depth 10) -Bom:$Bom
    return $id
}

# A request and its response (the id must match).
function Invoke-Mcp($S, [string]$Method, $Params = $null, [int]$TimeoutSec = 90, [switch]$Bom) {
    $id = Send-McpRequest $S $Method $Params -Bom:$Bom
    $resp = Read-McpMessage $S $TimeoutSec
    if ([string](Get-P $resp 'id') -ne [string]$id) { Fail ('response id {0}, expected {1}' -f (Get-P $resp 'id'), $id) }
    return $resp
}

function Initialize-Mcp($S, [string]$Version = '2025-06-18', [string]$Client = 'slot test!', [switch]$Bom) {
    $resp = Invoke-Mcp $S 'initialize' ([ordered]@{
            protocolVersion = $Version; capabilities = [ordered]@{}; clientInfo = [ordered]@{ name = $Client; version = '1.0' }
        }) -Bom:$Bom
    Send-McpRequest $S 'notifications/initialized' $null -Notification | Out-Null
    return $resp
}

# tools/call: the text, isError, and the exit code and seconds from the first line.
function Invoke-McpTool($S, [string]$Name, $Arguments, [int]$TimeoutSec = 120) {
    if ($null -eq $Arguments) { $Arguments = [ordered]@{} }
    $resp = Invoke-Mcp $S 'tools/call' ([ordered]@{ name = $Name; arguments = $Arguments }) $TimeoutSec
    $result = Get-P $resp 'result'
    if ($null -eq $result) { Fail ('tools/call {0}: no result: {1}' -f $Name, ($resp | ConvertTo-Json -Compress -Depth 10)) }
    $text = [string]((@(Get-P $result 'content'))[0].text)
    $first = ($text -split "`n")[0]
    # "[unity-slot exit 2: timed out, editor left running, 4.4s]": the label may hold a comma
    $m = [regex]::Match($first, '^\[unity-slot exit (\d+): (.+?)(?:, ([0-9]+\.[0-9])s)?\]$')
    $code = $null; $label = ''; $seconds = $null
    if ($m.Success) {
        $code = [int]$m.Groups[1].Value; $label = $m.Groups[2].Value
        if ($m.Groups[3].Success) { $seconds = [double]::Parse($m.Groups[3].Value, $script:Inv) }
    }
    return [pscustomobject]@{
        Label = ('mcp ' + $Name); Text = $text; FirstLine = $first; Code = $code; CodeLabel = $label; Seconds = $seconds
        IsError = [bool](Get-P $result 'isError'); TimedOut = $false; Timeout = $TimeoutSec
    }
}

# Closes stdin and waits for the server to end by itself. Returns its stderr. Whatever it still wrote
# to stdout must be JSON-RPC too.
function Stop-McpServer($S, [int]$TimeoutSec = 20) {
    try { $S.Proc.StandardInput.Close() } catch { }
    if (-not $S.Proc.WaitForExit($TimeoutSec * 1000)) { Fail ('the MCP server did not end within {0}s after stdin closed (left running)' -f $TimeoutSec) }
    $S.Proc.WaitForExit()
    $rest = ''
    if ($null -ne $S.Pending) {
        if ($S.Pending.Wait(2000) -and $null -ne $S.Pending.Result) { $rest = $S.Pending.Result + "`n" }
        $S.Pending = $null
    }
    $rest += $S.Proc.StandardOutput.ReadToEnd()
    foreach ($line in @($rest -split "`n" | Where-Object { $_.Trim() })) {
        try { [void]($line | ConvertFrom-Json) } catch { Fail ('stdout line after the last call is not JSON: ' + $line) }
    }
    return $S.ErrTask.Result
}
