param(
    [string]$CodexHome,
    [string]$NotifierLauncherPath,
    [string]$NotifierPath,
    [int]$PollSeconds = 1,
    [int]$Seconds = 12,
    [switch]$SelfTest
)

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

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
if (-not $createdNew) { return }

$script:MonitorStartedAt = [DateTimeOffset]::UtcNow
$script:Offsets = @{}
$script:Buffers = @{}
$script:Contexts = @{}
$script:SeenTurns = New-Object 'System.Collections.Generic.HashSet[string]'

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

function Get-ContextForFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:Contexts.ContainsKey($Path)) {
        $script:Contexts[$Path] = @{
            Provider     = ''
            Cwd          = ''
            ThreadId     = ''
            LastUserTask = ''
        }
    }
    return $script:Contexts[$Path]
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
    $role = [string]$Object.payload.role
    $isUserMessage = (
        ([string]$Object.type -eq 'response_item' -and $payloadType -eq 'message' -and $role -eq 'user') -or
        ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'user_message')
    )
    if (-not $isUserMessage) { return }

    $text = Get-MessageText $Object.payload
    if (Test-UserTaskText $text) {
        $context.LastUserTask = $text
    }
}

function Initialize-RolloutContext {
    param([Parameter(Mandatory)][string]$Path)

    [void](Get-ContextForFile $Path)
    try {
        $lines = @()
        $lines += @(Get-Content -LiteralPath $Path -TotalCount 80 -ErrorAction SilentlyContinue)
        $lines += @(Get-Content -LiteralPath $Path -Tail 240 -ErrorAction SilentlyContinue)
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

function Initialize-Baseline {
    foreach ($file in Get-RolloutFiles) {
        $script:Offsets[$file.FullName] = [int64]$file.Length
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

    $task = Shorten-Text ([string]$Context.LastUserTask) 52
    if ([string]::IsNullOrWhiteSpace($task)) { $task = $currentTaskDone }

    $message = "$accountLabel$provider | $cwdLabel`r`n$threadLabelPrefix$threadLabel`r`n$taskLabel$task"
    $messageBase64 = ConvertTo-Utf8Base64 $message

    if (-not [string]::IsNullOrWhiteSpace($NotifierLauncherPath) -and
        (Test-Path -LiteralPath $NotifierLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $NotifierLauncherPath,
            '-Title',
            $title,
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
        return
    }

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
            '-MessageBase64',
            $messageBase64,
            '-Seconds',
            ([string]$Seconds)
        ) -WindowStyle Hidden | Out-Null
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
        if ($eventTime -lt $script:MonitorStartedAt.AddSeconds(-2)) { return $null }

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
        $script:Buffers[$path] = $parts[$count - 1]
        $count--
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
        $taskCompleteKey = Get-TaskCompleteKey $obj
        if (-not [string]::IsNullOrWhiteSpace($taskCompleteKey) -and $script:SeenTurns.Add($taskCompleteKey)) {
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
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch { }
        $mutex.Dispose()
    }
}
