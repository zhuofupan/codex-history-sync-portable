param(
    [string]$CodexHome,
    [string]$NotifierLauncherPath,
    [string]$NotifierPath,
    [int]$PollSeconds = 1,
    [int]$Seconds = 12,
    [int]$ApprovalWaitSeconds = 10,
    [switch]$SelfTest
)

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Write-DiagnosticLog {
    param([AllowNull()][string]$Text)

    try {
        $dir = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            Join-Path $env:APPDATA 'codex-history-sync-portable'
        }
        else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'codex-history-sync-portable'
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $path = Join-Path $dir 'diagnostic.log'
        $line = '[{0}] [monitor] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), ([string]$Text), [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, $utf8)
    }
    catch {
        return
    }
}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory)][string]$Value)

    return $utf8.GetString([Convert]::FromBase64String($Value))
}

function Join-OptionalPath {
    param(
        [AllowNull()][string]$Base,
        [Parameter(Mandatory)][string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    try { return (Join-Path $Base $Child) } catch { return $null }
}

function Resolve-CodexHome {
    param([AllowNull()][string]$Requested)

    foreach ($path in @(
            $Requested,
            $env:CODEX_HOME,
            (Join-OptionalPath $env:USERPROFILE '.codex'),
            (Join-OptionalPath $env:HOME '.codex')
        )) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath (Join-Path $path 'sessions') -PathType Container) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

$script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CodexHome = Resolve-CodexHome $CodexHome
if ([string]::IsNullOrWhiteSpace($script:CodexHome)) {
    if ($SelfTest) { throw 'CodexHome not found.' }
    return
}

$script:SessionsDir = Join-Path $script:CodexHome 'sessions'
if ([string]::IsNullOrWhiteSpace($NotifierLauncherPath)) {
    $NotifierLauncherPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.vbs'
}
if ([string]::IsNullOrWhiteSpace($NotifierPath)) {
    $NotifierPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.ps1'
}

if ($SelfTest) {
    Write-Output "Monitor SelfTest OK. CodexHome: $script:CodexHome"
    return
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash($utf8.GetBytes($script:CodexHome.ToLowerInvariant()))
$hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 16)
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\CodexTurnCompleteMonitor_$hash", [ref]$createdNew)
if (-not $createdNew) {
    Write-DiagnosticLog "monitor already running for CodexHome='$script:CodexHome'; exiting duplicate."
    return
}

$script:MonitorStartedAt = [DateTimeOffset]::UtcNow
$script:Offsets = @{}
$script:Buffers = @{}
$script:Contexts = @{}
$script:SeenTurns = New-Object 'System.Collections.Generic.HashSet[string]'
$script:PendingApprovals = @{}
$script:StartupCompletionGraceSeconds = 60
Write-DiagnosticLog "monitor started CodexHome='$script:CodexHome' sessions='$script:SessionsDir' pollSeconds=$PollSeconds."

function Shorten-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Max = 48
    )

    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, [Math]::Max(0, $Max - 1)) + '...'
}

function ConvertTo-Utf8Base64 {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    return [Convert]::ToBase64String($utf8.GetBytes($Value))
}

function Get-ObjectStringProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Object) { return '' }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ''
}

function Get-ObjectSearchText {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return '' }
    try {
        return ($Object | ConvertTo-Json -Depth 16 -Compress)
    }
    catch {
        return ([string]$Object)
    }
}

function Get-ContextForFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:Contexts.ContainsKey($Path)) {
        $script:Contexts[$Path] = @{
            Provider          = ''
            Cwd               = ''
            ThreadId          = ''
            LastUserTask      = ''
            PendingUserTask   = ''
            CompletedUserTask = ''
            PendingTurnId     = ''
            CompletedTurnId   = ''
        }
    }
    return $script:Contexts[$Path]
}

function Get-RolloutTurnId {
    param([AllowNull()]$Object)

    $value = Get-ObjectStringProperty $Object.payload @('turn_id', 'turnId', 'id')
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return (Get-ObjectStringProperty $Object @('turn_id', 'turnId', 'id'))
}

function Get-MessageText {
    param([AllowNull()]$Payload)

    if ($null -eq $Payload) { return '' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Payload.message)) {
        return [string]$Payload.message
    }

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($part in @($Payload.content)) {
        if ($null -eq $part) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$part.text)) {
            $texts.Add([string]$part.text)
        }
    }
    return ($texts.ToArray() -join "`n")
}

function Test-UserTaskText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $clean = $Text.Trim()
    if ($clean.StartsWith('<environment_context>')) { return $false }
    if ($clean.StartsWith('<developer_context>')) { return $false }
    if ($clean -match '^\s*#\s*Files mentioned by the user:') { return $false }
    return $true
}

function Update-RolloutContext {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    $context = Get-ContextForFile $Path
    if ([string]$Object.type -eq 'session_meta') {
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.model_provider)) {
            $context.Provider = [string]$Object.payload.model_provider
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.cwd)) {
            $context.Cwd = [string]$Object.payload.cwd
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.id)) {
            $context.ThreadId = [string]$Object.payload.id
        }
        return
    }

    if ([string]$Object.type -eq 'turn_context' -and
        -not [string]::IsNullOrWhiteSpace([string]$Object.cwd)) {
        $context.Cwd = [string]$Object.cwd
        return
    }

    $payloadType = [string]$Object.payload.type
    if ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'task_started') {
        $context.PendingUserTask = ''
        $context.CompletedUserTask = ''
        $context.PendingTurnId = Get-RolloutTurnId $Object
        return
    }

    if ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'task_complete') {
        $context.CompletedTurnId = Get-RolloutTurnId $Object
        if (-not [string]::IsNullOrWhiteSpace([string]$context.PendingUserTask)) {
            $context.CompletedUserTask = [string]$context.PendingUserTask
        }
        else {
            $context.CompletedUserTask = ''
        }
        return
    }

    $role = [string]$Object.payload.role
    $isUserMessage = (
        ([string]$Object.type -eq 'response_item' -and $payloadType -eq 'message' -and $role -eq 'user') -or
        ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'user_message')
    )
    if (-not $isUserMessage) { return }

    $text = Get-MessageText $Object.payload
    if (Test-UserTaskText $text) {
        $context.LastUserTask = $text
        $context.PendingUserTask = $text
    }
}

function Initialize-RolloutContext {
    param([Parameter(Mandatory)][string]$Path)

    [void](Get-ContextForFile $Path)
    try {
        $lines = @()
        $lines += @(Get-Content -LiteralPath $Path -TotalCount 80 -Encoding UTF8 -ErrorAction SilentlyContinue)
        $lines += @(Get-Content -LiteralPath $Path -Tail 240 -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
            }
            catch {
                continue
            }
            Update-RolloutContext -Path $Path -Object $obj
        }
    }
    catch {
        return
    }
}

function Get-RolloutFiles {
    if (-not (Test-Path -LiteralPath $script:SessionsDir -PathType Container)) { return @() }

    $cutoff = [DateTime]::UtcNow.AddDays(-14)
    return @(Get-ChildItem -LiteralPath $script:SessionsDir -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoff -or $script:Offsets.ContainsKey($_.FullName) })
}

function Test-CompleteJsonLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    try {
        [void]($Line | ConvertFrom-Json)
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-Baseline {
    foreach ($file in Get-RolloutFiles) {
        $initialOffset = [Math]::Max([int64]0, ([int64]$file.Length - [int64](256 * 1024)))
        $script:Offsets[$file.FullName] = [int64]$initialOffset
        $script:Buffers[$file.FullName] = ''
        Initialize-RolloutContext ([string]$file.FullName)
    }
}

function Invoke-CompletionPopup {
    param([AllowNull()]$Context)

    $title = ConvertFrom-Utf8Base64 'Q29kZXgg5Lu75Yqh5a6M5oiQ'
    $unknownAccount = ConvertFrom-Utf8Base64 '5pyq55+l6LSm5Y+3'
    $unknownCwd = ConvertFrom-Utf8Base64 '5pyq55+l55uu5b2V'
    $currentThread = ConvertFrom-Utf8Base64 '5b2T5YmN5Lya6K+d'
    $currentTaskDone = ConvertFrom-Utf8Base64 '5b2T5YmN5Lu75Yqh5bey5a6M5oiQ'
    $accountLabel = ConvertFrom-Utf8Base64 '6LSm5Y+377ya'
    $threadLabelPrefix = ConvertFrom-Utf8Base64 '6IGK5aSp77ya'
    $taskLabel = ConvertFrom-Utf8Base64 '5Lu75Yqh77ya'

    $provider = Shorten-Text ([string]$Context.Provider) 18
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = $unknownAccount }

    $cwd = [string]$Context.Cwd
    $cwdLabel = if (-not [string]::IsNullOrWhiteSpace($cwd)) { Split-Path -Leaf $cwd } else { $unknownCwd }
    if ([string]::IsNullOrWhiteSpace($cwdLabel)) { $cwdLabel = Shorten-Text $cwd 24 }

    $threadId = [string]$Context.ThreadId
    $threadLabel = if ($threadId.Length -gt 8) { $threadId.Substring(0, 8) } else { $threadId }
    if ([string]::IsNullOrWhiteSpace($threadLabel)) { $threadLabel = $currentThread }

    $task = Shorten-Text ([string]$Context.CompletedUserTask) 52
    if ([string]::IsNullOrWhiteSpace($task)) { $task = $currentTaskDone }

    $message = "$accountLabel$provider | $cwdLabel`r`n$threadLabelPrefix$threadLabel`r`n$taskLabel$task"
    $messageBase64 = ConvertTo-Utf8Base64 $message
    Write-DiagnosticLog ("completion popup requested provider='{0}' thread='{1}' task='{2}'" -f $provider, $threadLabel, $task)

    if (-not [string]::IsNullOrWhiteSpace($NotifierPath) -and
        (Test-Path -LiteralPath $NotifierPath)) {
        Start-Process -FilePath powershell.exe -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            $NotifierPath,
            '-Title',
            $title,
            '-CodexHome',
            $script:CodexHome,
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
        Write-DiagnosticLog "completion popup launched via powershell '$NotifierPath'."
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($NotifierLauncherPath) -and
        (Test-Path -LiteralPath $NotifierLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $NotifierLauncherPath,
            '-Title',
            $title,
            '-CodexHome',
            $script:CodexHome,
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
        Write-DiagnosticLog "completion popup launched via wscript '$NotifierLauncherPath'."
    }
}

function Get-ApprovalEventInfo {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $eventTime = [DateTimeOffset]::UtcNow
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.timestamp)) {
            $eventTime = [DateTimeOffset]::Parse([string]$Object.timestamp)
        }
        if ($eventTime -lt $script:MonitorStartedAt.AddSeconds(-1 * [int]$script:StartupCompletionGraceSeconds)) { return $null }

        $payload = $Object.payload
        $typeText = @(
            [string]$Object.type,
            [string]$payload.type,
            [string]$payload.subtype,
            [string]$payload.status,
            [string]$payload.state
        ) -join ' '
        $searchText = (($typeText + ' ' + (Get-ObjectSearchText $Object))).ToLowerInvariant()

        $isRequest = (
            ($searchText -match 'approval|permission|sandbox|escalat') -and
            ($searchText -match 'request|pending|wait|waiting|prompt|required|requires|ask')
        )
        $isResolved = (
            ($searchText -match 'approval|permission|sandbox|escalat') -and
            ($searchText -match 'approved|denied|reject|rejected|cancel|cancelled|canceled|granted|resolved|response|decision|completed')
        )
        if ([string]$Object.type -eq 'event_msg' -and [string]$payload.type -eq 'task_complete') {
            $isResolved = $true
        }
        if ([string]$payload.type -match 'exec_command_begin|exec_command_end|command_begin|command_started|tool_call_begin') {
            $isResolved = $true
        }

        if (-not $isRequest -and -not $isResolved) { return $null }

        $id = Get-ObjectStringProperty $payload @(
            'approval_id',
            'approvalId',
            'request_id',
            'requestId',
            'call_id',
            'callId',
            'command_id',
            'commandId',
            'id',
            'turn_id',
            'turnId'
        )
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = Get-ObjectStringProperty $Object @('id', 'event_id', 'eventId', 'turn_id', 'turnId')
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = [string]$Path
        }

        $summary = Get-ObjectStringProperty $payload @('command', 'cmd', 'tool_name', 'toolName', 'name', 'description', 'reason')
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $summary = Shorten-Text (Get-ObjectSearchText $payload) 72
        }

        return [pscustomobject]@{
            Key       = "$Path|$id"
            Path      = $Path
            IsRequest = [bool]$isRequest
            IsResolved = [bool]$isResolved
            StartedAt = $eventTime.UtcDateTime
            Summary   = $summary
        }
    }
    catch {
        return $null
    }
}

function Register-ApprovalEvent {
    param(
        [Parameter(Mandatory)]$Info,
        [AllowNull()]$Context
    )

    if ($Info.IsResolved) {
        if ($script:PendingApprovals.ContainsKey($Info.Key)) {
            $script:PendingApprovals.Remove($Info.Key)
        }
        foreach ($key in @($script:PendingApprovals.Keys)) {
            if ($key.StartsWith("$($Info.Path)|", [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:PendingApprovals.Remove($key)
            }
        }
        return
    }

    if (-not $Info.IsRequest) { return }
    if ($script:PendingApprovals.ContainsKey($Info.Key)) { return }

    $script:PendingApprovals[$Info.Key] = [pscustomobject]@{
        Key       = [string]$Info.Key
        Path      = [string]$Info.Path
        StartedAt = [datetime]$Info.StartedAt
        Summary   = [string]$Info.Summary
        Context   = $Context
        Notified  = $false
    }
}

function Invoke-ApprovalWaitPopup {
    param([Parameter(Mandatory)]$Pending)

    $context = $Pending.Context
    if (-not $context) {
        $context = Get-ContextForFile ([string]$Pending.Path)
    }

    $title = 'Codex 等待权限审批'
    $cwd = [string]$context.Cwd
    $cwdLabel = if (-not [string]::IsNullOrWhiteSpace($cwd)) { Split-Path -Leaf $cwd } else { '未知目录' }
    if ([string]::IsNullOrWhiteSpace($cwdLabel)) { $cwdLabel = Shorten-Text $cwd 24 }
    $provider = Shorten-Text ([string]$context.Provider) 18
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = '未知账号' }
    $thread = [string]$context.ThreadId
    if ($thread.Length -gt 8) { $thread = $thread.Substring(0, 8) }
    if ([string]::IsNullOrWhiteSpace($thread)) { $thread = '当前会话' }

    $age = [Math]::Max(0, [int](([DateTime]::UtcNow - [datetime]$Pending.StartedAt).TotalSeconds))
    $summary = Shorten-Text ([string]$Pending.Summary) 54
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = '权限审批请求' }
    $message = "账号：$provider | $cwdLabel`r`n聊天：$thread`r`n已等待审批 ${age}s：$summary"
    $messageBase64 = ConvertTo-Utf8Base64 $message

    if (-not [string]::IsNullOrWhiteSpace($NotifierPath) -and
        (Test-Path -LiteralPath $NotifierPath)) {
        Start-Process -FilePath powershell.exe -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            $NotifierPath,
            '-Title',
            $title,
            '-Kind',
            'ApprovalWait',
            '-CodexHome',
            $script:CodexHome,
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($NotifierLauncherPath) -and
        (Test-Path -LiteralPath $NotifierLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $NotifierLauncherPath,
            '-Title',
            $title,
            '-Kind',
            'ApprovalWait',
            '-CodexHome',
            $script:CodexHome,
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
    }
}

function Check-PendingApprovalPopups {
    $thresholdSeconds = [Math]::Max(1, $ApprovalWaitSeconds)
    $now = [DateTime]::UtcNow
    foreach ($key in @($script:PendingApprovals.Keys)) {
        $pending = $script:PendingApprovals[$key]
        $ageSeconds = ($now - [datetime]$pending.StartedAt).TotalSeconds
        if ($ageSeconds -gt 600) {
            $script:PendingApprovals.Remove($key)
            continue
        }
        if (-not [bool]$pending.Notified -and $ageSeconds -ge $thresholdSeconds) {
            Invoke-ApprovalWaitPopup -Pending $pending
            $pending.Notified = $true
        }
    }
}

function Read-AppendedText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Offset
    )

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, $utf8, $true)
        $text = $reader.ReadToEnd()
        return [pscustomobject]@{
            Text   = $text
            Offset = [int64]$stream.Length
        }
    }
    catch {
        return $null
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Get-TaskCompleteKey {
    param([Parameter(Mandatory)]$Object)

    try {
        if ([string]$Object.type -ne 'event_msg') { return $null }
        if ([string]$Object.payload.type -ne 'task_complete') { return $null }

        $eventTime = [DateTimeOffset]::MinValue
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.timestamp)) {
            $eventTime = [DateTimeOffset]::Parse([string]$Object.timestamp)
        }
        if ($eventTime -lt $script:MonitorStartedAt.AddSeconds(-1 * [int]$script:StartupCompletionGraceSeconds)) { return $null }

        $turnId = [string]$Object.payload.turn_id
        if ([string]::IsNullOrWhiteSpace($turnId)) {
            $turnId = [string]$Object.timestamp
        }
        if ([string]::IsNullOrWhiteSpace($turnId)) { return $null }

        return $turnId
    }
    catch {
        return $null
    }
}

function Process-RolloutFile {
    param([Parameter(Mandatory)]$File)

    $path = [string]$File.FullName
    if (-not $script:Offsets.ContainsKey($path)) {
        $script:Offsets[$path] = [int64]0
        $script:Buffers[$path] = ''
        Initialize-RolloutContext $path
    }

    $read = Read-AppendedText $path ([int64]$script:Offsets[$path])
    if ($null -eq $read) { return }
    $script:Offsets[$path] = [int64]$read.Offset
    if ([string]::IsNullOrEmpty([string]$read.Text)) { return }

    $combined = [string]$script:Buffers[$path] + [string]$read.Text
    $endsWithNewline = $combined.EndsWith("`n")
    $parts = $combined -split "`n"
    $count = $parts.Count
    if (-not $endsWithNewline -and $count -gt 0) {
        $tail = [string]$parts[$count - 1]
        if (Test-CompleteJsonLine $tail) {
            $script:Buffers[$path] = ''
        }
        else {
            $script:Buffers[$path] = $tail
            $count--
        }
    }
    else {
        $script:Buffers[$path] = ''
    }

    for ($i = 0; $i -lt $count; $i++) {
        $line = ([string]$parts[$i]).TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        Update-RolloutContext -Path $path -Object $obj
        $approvalInfo = Get-ApprovalEventInfo -Object $obj -Path $path
        if ($approvalInfo) {
            Register-ApprovalEvent -Info $approvalInfo -Context (Get-ContextForFile $path)
        }
        $taskCompleteKey = Get-TaskCompleteKey $obj
        if (-not [string]::IsNullOrWhiteSpace($taskCompleteKey) -and $script:SeenTurns.Add($taskCompleteKey)) {
            Write-DiagnosticLog "task_complete detected turn='$taskCompleteKey' path='$path'."
            foreach ($key in @($script:PendingApprovals.Keys)) {
                if ($key.StartsWith("$path|", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $script:PendingApprovals.Remove($key)
                }
            }
            Invoke-CompletionPopup -Context (Get-ContextForFile $path)
        }
    }
}

try {
    Initialize-Baseline
    while ($true) {
        foreach ($file in Get-RolloutFiles) {
            Process-RolloutFile $file
        }
        Check-PendingApprovalPopups
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch { }
        $mutex.Dispose()
    }
}
