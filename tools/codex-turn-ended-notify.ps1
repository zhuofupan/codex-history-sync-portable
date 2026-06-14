[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Title,
    [string]$Message,
    [string]$MessageBase64,
    [int]$Seconds = 12,
    [string]$ForwardBase64,
    [string]$CodexHome,
    [string]$Kind = 'Complete',
    [switch]$ForwardOnly,
    [string]$ArgFile,
    [switch]$SelfTest,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$utf8Strict = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
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
        $line = '[{0}] [notify] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), ([string]$Text), [Environment]::NewLine
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

function Repair-MojibakeText {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    try {
        $bytes = [System.Text.Encoding]::Default.GetBytes($Value)
        $candidate = $utf8Strict.GetString($bytes)
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -eq $Value) { return $Value }
        if ($candidate -match '[\u4e00-\u9fff]' -and $candidate -notmatch [char]0xfffd) {
            return $candidate
        }
    }
    catch {
        return $Value
    }
    return $Value
}

function Shorten-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Max = 52
    )

    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, [Math]::Max(0, $Max - 1)) + '...'
}

function Get-PropertyValue {
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

function Get-NestedPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    $direct = Get-PropertyValue -Object $Object -Names $Names
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }

    foreach ($childName in @('payload', 'event', 'data')) {
        $child = $null
        if ($Object -and $Object.PSObject.Properties[$childName]) {
            $child = $Object.PSObject.Properties[$childName].Value
        }
        $value = Get-PropertyValue -Object $child -Names $Names
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ''
}

function Get-NotifyMessageFromJsonObject {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return '' }

    $provider = Get-NestedPropertyValue $Object @('model_provider', 'modelProvider', 'provider', 'account', 'accountName')
    $cwd = Get-NestedPropertyValue $Object @('cwd', 'working_directory', 'workingDirectory', 'workspace', 'directory')
    $thread = Get-NestedPropertyValue $Object @('thread_id', 'threadId', 'session_id', 'sessionId', 'conversation_id', 'conversationId', 'turn_id', 'turnId')
    $task = Get-NestedPropertyValue $Object @('last_user_message', 'lastUserMessage', 'user_message', 'userMessage', 'prompt', 'input', 'message', 'summary')

    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = ConvertFrom-Utf8Base64 '5pyq55+l6LSm5Y+3'
    }
    $cwdLabel = ''
    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        try { $cwdLabel = Split-Path -Leaf $cwd } catch { $cwdLabel = $cwd }
    }
    if ([string]::IsNullOrWhiteSpace($cwdLabel)) {
        $cwdLabel = ConvertFrom-Utf8Base64 '5pyq55+l55uu5b2V'
    }
    if ([string]::IsNullOrWhiteSpace($thread)) {
        $thread = ConvertFrom-Utf8Base64 '5b2T5YmN5Lya6K+d'
    }
    elseif ($thread.Length -gt 8) {
        $thread = $thread.Substring(0, 8)
    }
    if ([string]::IsNullOrWhiteSpace($task) -or $task.Trim().StartsWith('{')) {
        $task = ConvertFrom-Utf8Base64 '5b2T5YmN5Lu75Yqh5bey5a6M5oiQ'
    }

    $accountLabel = ConvertFrom-Utf8Base64 '6LSm5Y+377ya'
    $threadLabel = ConvertFrom-Utf8Base64 '6IGK5aSp77ya'
    $taskLabel = ConvertFrom-Utf8Base64 '5Lu75Yqh77ya'
    return "$accountLabel$(Shorten-Text $provider 18) | $(Shorten-Text $cwdLabel 24)`r`n$threadLabel$(Shorten-Text $thread 18)`r`n$taskLabel$(Shorten-Text $task 52)"
}

function Get-NotifyMessageFromArgs {
    param([AllowNull()][string[]]$Args)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($Args)) {
        if (-not [string]::IsNullOrWhiteSpace($arg)) {
            $candidates.Add([string]$arg)
        }
    }
    if ($candidates.Count -gt 1) {
        $candidates.Add(($candidates.ToArray() -join ' '))
    }

    foreach ($arg in $candidates.ToArray()) {
        if ([string]::IsNullOrWhiteSpace($arg)) { continue }
        $text = $arg.Trim()
        if (-not ($text.StartsWith('{') -or $text.StartsWith('['))) { continue }
        try {
            $obj = $text | ConvertFrom-Json
            $message = Get-NotifyMessageFromJsonObject $obj
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
        }
        catch {
            continue
        }
    }
    return ''
}

function Read-ForwardedArgumentFile {
    param([AllowNull()][string]$Path)

    $values = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Path)) { return $values.ToArray() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values.ToArray() }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding Unicode
        if ([string]::IsNullOrWhiteSpace($raw)) { return $values.ToArray() }

        foreach ($item in @($raw | ConvertFrom-Json)) {
            if ($null -ne $item) {
                $values.Add([string]$item)
            }
        }
        Write-DiagnosticLog ("loaded forwarded args count={0}" -f $values.Count)
    }
    catch {
        Write-DiagnosticLog ("forwarded args load failed: " + $_.Exception.Message)
    }
    finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }

    return $values.ToArray()
}

function Apply-ForwardedNotifyArguments {
    param([AllowNull()][string[]]$Args)

    $remaining = New-Object System.Collections.Generic.List[string]
    $items = @($Args)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $arg = [string]$items[$i]
        $key = $arg.ToLowerInvariant()

        switch ($key) {
            { $_ -in @('-title', '--title') } {
                if (($i + 1) -lt $items.Count) { $script:Title = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-message', '--message') } {
                if (($i + 1) -lt $items.Count) { $script:Message = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-messagebase64', '--messagebase64') } {
                if (($i + 1) -lt $items.Count) { $script:MessageBase64 = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-seconds', '--seconds') } {
                if (($i + 1) -lt $items.Count) {
                    $parsedSeconds = 0
                    if ([int]::TryParse([string]$items[++$i], [ref]$parsedSeconds)) {
                        $script:Seconds = $parsedSeconds
                    }
                }
                continue
            }
            { $_ -in @('-forwardbase64', '--forwardbase64') } {
                if (($i + 1) -lt $items.Count) { $script:ForwardBase64 = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-codexhome', '--codexhome') } {
                if (($i + 1) -lt $items.Count) { $script:CodexHome = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-kind', '--kind') } {
                if (($i + 1) -lt $items.Count) { $script:Kind = [string]$items[++$i] }
                continue
            }
            { $_ -in @('-forwardonly', '--forwardonly') } {
                $script:ForwardOnly = $true
                continue
            }
            { $_ -in @('-selftest', '--selftest') } {
                $script:SelfTest = $true
                continue
            }
            default {
                $remaining.Add($arg)
            }
        }
    }

    return $remaining.ToArray()
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
    return ''
}

function Get-RolloutMessageText {
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

function New-RolloutContext {
    return [pscustomobject]@{
        Provider         = ''
        Cwd              = ''
        ThreadId         = ''
        LastSeenUserTask = ''
        PendingUserTask  = ''
        PendingTurnId    = ''
        LastUserTask     = ''
        CompletedTurnId  = ''
        CompletedAtUtc   = $null
        HasCompletedTurn = $false
    }
}

function Get-RolloutEventTimeUtc {
    param([AllowNull()]$Object)

    if ($null -eq $Object -or -not $Object.PSObject.Properties['timestamp']) { return $null }
    $raw = $Object.PSObject.Properties['timestamp'].Value
    if ($null -eq $raw) { return $null }
    if ($raw -is [datetime]) { return $raw.ToUniversalTime() }

    try {
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$raw, [ref]$parsed)) {
            return $parsed.UtcDateTime
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-RolloutTurnId {
    param([AllowNull()]$Object)

    $value = Get-PropertyValue -Object $Object.payload -Names @('turn_id', 'turnId', 'id')
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return (Get-PropertyValue -Object $Object -Names @('turn_id', 'turnId', 'id'))
}

function Split-RolloutLines {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return @() }
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    return @($normalized -split "`n")
}

function Read-FileStreamBytes {
    param(
        [Parameter(Mandatory)]$Stream,
        [Parameter(Mandatory)][byte[]]$Buffer
    )

    $offset = 0
    while ($offset -lt $Buffer.Length) {
        $count = $Stream.Read($Buffer, $offset, $Buffer.Length - $offset)
        if ($count -le 0) { break }
        $offset += $count
    }
    return $offset
}

function Get-RolloutHeadLinesFast {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 131072,
        [int]$MaxLines = 80
    )

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        try {
            $readLength = [int][Math]::Min([int64]$MaxBytes, $stream.Length)
            if ($readLength -le 0) { return @() }
            $buffer = New-Object byte[] $readLength
            $read = Read-FileStreamBytes -Stream $stream -Buffer $buffer
            if ($read -le 0) { return @() }
            return @(Split-RolloutLines ($utf8.GetString($buffer, 0, $read)) | Select-Object -First $MaxLines)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return @()
    }
}

function Get-RolloutTailLinesFast {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 2097152,
        [int]$MaxLines = 1600
    )

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        try {
            $length = [int64]$stream.Length
            if ($length -le 0) { return @() }
            $start = [Math]::Max([int64]0, $length - [int64]$MaxBytes)
            [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
            $readLength = [int]($length - $start)
            $buffer = New-Object byte[] $readLength
            $read = Read-FileStreamBytes -Stream $stream -Buffer $buffer
            if ($read -le 0) { return @() }

            $lines = @(Split-RolloutLines ($utf8.GetString($buffer, 0, $read)))
            if ($start -gt 0 -and $lines.Count -gt 1) {
                $lines = @($lines | Select-Object -Skip 1)
            }
            elseif ($start -gt 0) {
                return @()
            }
            if ($lines.Count -gt $MaxLines) {
                return @($lines | Select-Object -Last $MaxLines)
            }
            return $lines
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return @()
    }
}

function Update-RolloutContext {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Object
    )

    if ([string]$Object.type -eq 'session_meta') {
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.model_provider)) {
            $Context.Provider = [string]$Object.payload.model_provider
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.cwd)) {
            $Context.Cwd = [string]$Object.payload.cwd
        }
        foreach ($name in @('id', 'session_id', 'thread_id', 'conversation_id')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Object.payload.$name)) {
                $Context.ThreadId = [string]$Object.payload.$name
                break
            }
        }
        return
    }

    if ([string]$Object.type -eq 'turn_context' -and
        -not [string]::IsNullOrWhiteSpace([string]$Object.cwd)) {
        $Context.Cwd = [string]$Object.cwd
        return
    }

    $payloadType = [string]$Object.payload.type
    if ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'task_started') {
        $Context.PendingUserTask = ''
        $Context.PendingTurnId = Get-RolloutTurnId $Object
        return
    }

    if ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'task_complete') {
        $Context.HasCompletedTurn = $true
        $Context.CompletedTurnId = Get-RolloutTurnId $Object
        $completedAt = Get-RolloutEventTimeUtc $Object
        if ($null -ne $completedAt) {
            $Context.CompletedAtUtc = $completedAt
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.PendingUserTask)) {
            $Context.LastUserTask = [string]$Context.PendingUserTask
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$Context.LastUserTask) -and
            -not [string]::IsNullOrWhiteSpace([string]$Context.LastSeenUserTask)) {
            $Context.LastUserTask = [string]$Context.LastSeenUserTask
        }
        return
    }

    $role = [string]$Object.payload.role
    $isUserMessage = (
        ([string]$Object.type -eq 'response_item' -and $payloadType -eq 'message' -and $role -eq 'user') -or
        ([string]$Object.type -eq 'event_msg' -and $payloadType -eq 'user_message')
    )
    if (-not $isUserMessage) { return }

    $text = Get-RolloutMessageText $Object.payload
    if (Test-UserTaskText $text) {
        $Context.LastSeenUserTask = $text
        $Context.PendingUserTask = $text
    }
}

function Get-RolloutContextFromFile {
    param([Parameter(Mandatory)][string]$Path)

    $context = New-RolloutContext
    try {
        $headLines = @(Get-RolloutHeadLinesFast -Path $Path)
        $tailLines = @(Get-RolloutTailLinesFast -Path $Path)
        foreach ($line in $headLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
            }
            catch {
                continue
            }
            if ([string]$obj.type -notin @('session_meta', 'turn_context')) { continue }
            Update-RolloutContext -Context $context -Object $obj
        }

        $context.LastSeenUserTask = ''
        $context.PendingUserTask = ''
        $context.PendingTurnId = ''

        foreach ($line in $tailLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
            }
            catch {
                continue
            }
            Update-RolloutContext -Context $context -Object $obj
        }
    }
    catch {
        return $context
    }
    return $context
}

function Test-RolloutContextHasUsefulInfo {
    param([AllowNull()]$Context)

    if ($null -eq $Context) { return $false }
    return (-not [string]::IsNullOrWhiteSpace([string]$Context.Provider)) -or
        (-not [string]::IsNullOrWhiteSpace([string]$Context.Cwd)) -or
        (-not [string]::IsNullOrWhiteSpace([string]$Context.ThreadId)) -or
        (-not [string]::IsNullOrWhiteSpace([string]$Context.LastUserTask))
}

function Test-RolloutContextHasCompletedTurn {
    param([AllowNull()]$Context)

    if ($null -eq $Context) { return $false }
    return [bool]$Context.HasCompletedTurn
}

function Get-NotifyMessageFromRolloutContext {
    param([AllowNull()]$Context)

    if (-not (Test-RolloutContextHasUsefulInfo $Context)) { return '' }

    $unknownAccount = ConvertFrom-Utf8Base64 '5pyq55+l6LSm5Y+3'
    $unknownCwd = ConvertFrom-Utf8Base64 '5pyq55+l55uu5b2V'
    $currentThread = ConvertFrom-Utf8Base64 '5b2T5YmN5Lya6K+d'
    $currentTaskDone = ConvertFrom-Utf8Base64 '5b2T5YmN5Lu75Yqh5bey5a6M5oiQ'
    $accountLabel = ConvertFrom-Utf8Base64 '6LSm5Y+377ya'
    $threadLabel = ConvertFrom-Utf8Base64 '6IGK5aSp77ya'
    $taskLabel = ConvertFrom-Utf8Base64 '5Lu75Yqh77ya'

    $provider = Shorten-Text ([string]$Context.Provider) 18
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = $unknownAccount }

    $cwd = [string]$Context.Cwd
    $cwdLabel = if (-not [string]::IsNullOrWhiteSpace($cwd)) { Split-Path -Leaf $cwd } else { $unknownCwd }
    if ([string]::IsNullOrWhiteSpace($cwdLabel)) { $cwdLabel = Shorten-Text $cwd 24 }

    $thread = [string]$Context.ThreadId
    if ($thread.Length -gt 8) { $thread = $thread.Substring(0, 8) }
    if ([string]::IsNullOrWhiteSpace($thread)) { $thread = $currentThread }

    $task = Shorten-Text ([string]$Context.LastUserTask) 52
    if ([string]::IsNullOrWhiteSpace($task)) { $task = $currentTaskDone }

    return "$accountLabel$provider | $(Shorten-Text $cwdLabel 24)`r`n$threadLabel$(Shorten-Text $thread 18)`r`n$taskLabel$task"
}

function Get-NotifyMessageFromLatestRollout {
    param([AllowNull()][string]$RequestedCodexHome)

    $resolvedCodexHome = Resolve-CodexHome $RequestedCodexHome
    if ([string]::IsNullOrWhiteSpace($resolvedCodexHome)) {
        Write-DiagnosticLog 'rollout fallback skipped: CodexHome not resolved.'
        return ''
    }

    $sessionsDir = Join-Path $resolvedCodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsDir -PathType Container)) {
        Write-DiagnosticLog "rollout fallback skipped: sessions dir not found '$sessionsDir'."
        return ''
    }

    $completedCandidates = New-Object System.Collections.Generic.List[object]
    $fallbackContext = $null
    $bestCompletedAtUtc = $null
    try {
        $files = @(Get-ChildItem -LiteralPath $sessionsDir -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 6)
        Write-DiagnosticLog ("rollout fallback scanning files={0} home='{1}'." -f $files.Count, $resolvedCodexHome)
        foreach ($file in $files) {
            if ($null -ne $bestCompletedAtUtc -and $file.LastWriteTimeUtc -lt $bestCompletedAtUtc) {
                Write-DiagnosticLog ("rollout fallback stopped early before file='{0}' bestCompletedAt='{1}'." -f
                    $file.Name,
                    ([DateTime]$bestCompletedAtUtc).ToString('o'))
                break
            }

            $context = Get-RolloutContextFromFile ([string]$file.FullName)
            if (-not $fallbackContext -and (Test-RolloutContextHasUsefulInfo $context)) {
                $fallbackContext = $context
            }
            if (Test-RolloutContextHasCompletedTurn $context) {
                $completedCandidates.Add([pscustomobject]@{
                        File           = $file
                        Context        = $context
                        CompletedAtUtc = $context.CompletedAtUtc
                    })
                if ($null -ne $context.CompletedAtUtc -and
                    ($null -eq $bestCompletedAtUtc -or $context.CompletedAtUtc -gt $bestCompletedAtUtc)) {
                    $bestCompletedAtUtc = $context.CompletedAtUtc
                }
            }
        }

        if ($completedCandidates.Count -gt 0) {
            $selected = @($completedCandidates.ToArray() | Sort-Object `
                    @{ Expression = { if ($_.CompletedAtUtc) { $_.CompletedAtUtc } else { [DateTime]::MinValue } }; Descending = $true }, `
                    @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true } |
                Select-Object -First 1)[0]
            $context = $selected.Context
            $completedAtText = if ($context.CompletedAtUtc) { ([DateTime]$context.CompletedAtUtc).ToString('o') } else { '' }
            Write-DiagnosticLog ("rollout fallback selected completed file='{0}' turn='{1}' completedAt='{2}' provider='{3}' cwdSet={4} taskSet={5}." -f
                $selected.File.Name,
                ([string]$context.CompletedTurnId),
                $completedAtText,
                ([string]$context.Provider),
                (-not [string]::IsNullOrWhiteSpace([string]$context.Cwd)),
                (-not [string]::IsNullOrWhiteSpace([string]$context.LastUserTask)))
            return (Get-NotifyMessageFromRolloutContext $context)
        }
    }
    catch {
        Write-DiagnosticLog ("rollout fallback failed: " + $_.Exception.Message)
        return ''
    }

    Write-DiagnosticLog 'rollout fallback found no completed turn; using fallback context.'
    return (Get-NotifyMessageFromRolloutContext $fallbackContext)
}

function Test-NotifyMessageNeedsRolloutContext {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $clean = ($Value -replace '\s+', ' ').Trim()
    if ($clean.IndexOf('turn-ended', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    if ([string]::Equals($clean, 'Codex', [System.StringComparison]::OrdinalIgnoreCase) -or
        $clean -match '^(?i:codex)\s+(?i:codex)$') {
        return $true
    }
    if ($clean -match '未知账号|未知目录|当前会话|当前任务已完成|Codex 已完成当前会话|turn-ended') {
        return $true
    }
    if ($clean -match '账号[:：]\s*codex(\s|\||$)') {
        return $true
    }
    if ($clean -match 'codex\s*\|\s*codex') {
        return $true
    }
    if ($clean -match '聊天[:：]\s*codex(\s|$)' -or $clean -match '任务[:：]\s*codex(\s|$)') {
        return $true
    }
    return $false
}

function Test-RolloutCompletionSelection {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-notify-selftest-' + [Guid]::NewGuid().ToString('N'))
    $path = Join-Path $tempDir 'rollout-selftest.jsonl'
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $lines = @(
            '{"timestamp":"2026-06-14T00:00:00Z","type":"session_meta","payload":{"model_provider":"custom","cwd":"D:\\work","id":"session-one"}}',
            '{"timestamp":"2026-06-14T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"done-turn"}}',
            '{"timestamp":"2026-06-14T00:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"finished task text"}}',
            '{"timestamp":"2026-06-14T00:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"done-turn"}}',
            '{"timestamp":"2026-06-14T00:00:04Z","type":"event_msg","payload":{"type":"task_started","turn_id":"pending-turn"}}',
            '{"timestamp":"2026-06-14T00:00:05Z","type":"event_msg","payload":{"type":"user_message","message":"unfinished task text"}}'
        )
        [System.IO.File]::WriteAllLines($path, [string[]]$lines, $utf8)

        $context = Get-RolloutContextFromFile $path
        return (
            [bool]$context.HasCompletedTurn -and
            [string]$context.CompletedTurnId -eq 'done-turn' -and
            [string]$context.LastUserTask -eq 'finished task text' -and
            [string]$context.LastSeenUserTask -eq 'unfinished task text'
        )
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$forwardedArgs = @(Read-ForwardedArgumentFile $ArgFile)
if ($forwardedArgs.Count -gt 0) {
    $RemainingArgs = @(Apply-ForwardedNotifyArguments $forwardedArgs) + @($RemainingArgs)
}

if ($SelfTest) {
    if (-not (Test-RolloutCompletionSelection)) {
        throw 'Notifier SelfTest failed: completed rollout context selection is incorrect.'
    }
    Write-Output 'Notifier SelfTest OK.'
    return
}

if ([string]::IsNullOrWhiteSpace($Title)) {
    $Title = ConvertFrom-Utf8Base64 'Q29kZXgg5Lya6K+d5bey57uT5p2f'
}
if (-not [string]::IsNullOrWhiteSpace($MessageBase64)) {
    $Message = ConvertFrom-Utf8Base64 $MessageBase64
}
elseif ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    $argMessage = Get-NotifyMessageFromArgs $RemainingArgs
    if (-not [string]::IsNullOrWhiteSpace($argMessage)) {
        $Message = $argMessage
    }
}
$needsRolloutContext = Test-NotifyMessageNeedsRolloutContext $Message
if (-not $needsRolloutContext -and ([string]$Message).Length -le 32 -and @($RemainingArgs).Count -gt 0) {
    $needsRolloutContext = $true
}
Write-DiagnosticLog ("message precheck length={0} needsRollout={1} remainingArgs={2} hasMessageBase64={3}" -f
    ([string]$Message).Length,
    [bool]$needsRolloutContext,
    @($RemainingArgs).Count,
    (-not [string]::IsNullOrWhiteSpace($MessageBase64)))
if ($needsRolloutContext) {
    Write-DiagnosticLog 'message needs rollout context.'
    $rolloutMessage = Get-NotifyMessageFromLatestRollout -RequestedCodexHome $CodexHome
    if (-not [string]::IsNullOrWhiteSpace($rolloutMessage)) {
        $Message = $rolloutMessage
        Write-DiagnosticLog ("rollout context applied messageLength={0}." -f ([string]$Message).Length)
    }
    else {
        Write-DiagnosticLog 'rollout context unavailable.'
    }
}
if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = ConvertFrom-Utf8Base64 'Q29kZXgg5bey5a6M5oiQ5b2T5YmN5Lya6K+d44CC'
}
$Message = Repair-MojibakeText $Message

function Invoke-ForwardNotify {
    param(
        [AllowNull()][string]$EncodedCommand,
        [AllowNull()][string[]]$ExtraArgs
    )

    if ([string]::IsNullOrWhiteSpace($EncodedCommand)) { return }

    try {
        $json = $utf8.GetString([Convert]::FromBase64String($EncodedCommand))
        $command = @($json | ConvertFrom-Json)
        if ($command.Count -eq 0) { return }

        $filePath = [string]$command[0]
        if ([string]::IsNullOrWhiteSpace($filePath)) { return }

        $arguments = @()
        if ($command.Count -gt 1) {
            for ($i = 1; $i -lt $command.Count; $i++) {
                $arguments += [string]$command[$i]
            }
        }
        foreach ($arg in @($ExtraArgs)) {
            if ($null -ne $arg) { $arguments += [string]$arg }
        }

        Start-Process -FilePath $filePath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
    catch {
        return
    }
}

function Test-ShouldSuppressDuplicateNotification {
    param(
        [AllowNull()][string]$RequestedHome,
        [AllowNull()][string]$NotificationMessage
    )

    try {
        $resolvedHome = Resolve-CodexHome $RequestedHome
        if ([string]::IsNullOrWhiteSpace($resolvedHome)) { $resolvedHome = [string]$RequestedHome }
        $normalizedMessage = ([string]$NotificationMessage -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($normalizedMessage)) { $normalizedMessage = [string]$Title }

        $hashInput = "$resolvedHome`n$normalizedMessage"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash($utf8.GetBytes($hashInput))
        }
        finally {
            $sha.Dispose()
        }
        $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 24)
        $dedupeDir = Join-Path ([System.IO.Path]::GetTempPath()) 'codex-history-sync-notify'
        New-Item -ItemType Directory -Path $dedupeDir -Force | Out-Null

        $now = [DateTime]::UtcNow
        foreach ($oldFile in @(Get-ChildItem -LiteralPath $dedupeDir -Filter '*.lock' -ErrorAction SilentlyContinue)) {
            if (($now - $oldFile.LastWriteTimeUtc).TotalHours -gt 12) {
                Remove-Item -LiteralPath $oldFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        $lockPath = Join-Path $dedupeDir "$hash.lock"
        if (Test-Path -LiteralPath $lockPath) {
            $ageSeconds = ($now - (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc).TotalSeconds
            if ($ageSeconds -lt 6) { return $true }
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }

        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $stream.Dispose()
            return $false
        }
        catch {
            return (Test-Path -LiteralPath $lockPath)
        }
    }
    catch {
        return $false
    }
}

Write-DiagnosticLog ("start kind='{0}' forwardOnly={1} hasForward={2} remainingArgs={3} messageLength={4}" -f
    $Kind,
    [bool]$ForwardOnly,
    (-not [string]::IsNullOrWhiteSpace($ForwardBase64)),
    @($RemainingArgs).Count,
    ([string]$Message).Length)
Invoke-ForwardNotify -EncodedCommand $ForwardBase64 -ExtraArgs $RemainingArgs

if ($ForwardOnly) {
    Write-DiagnosticLog 'exit after forward only.'
    return
}

if (Test-ShouldSuppressDuplicateNotification -RequestedHome $CodexHome -NotificationMessage $Message) {
    Write-DiagnosticLog 'duplicate notification suppressed.'
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexNotifyNative {
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const int SW_SHOWNORMAL = 1;
    public const int SW_RESTORE = 9;
    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, UInt32 uFlags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect, int nWidthEllipse, int nHeightEllipse);

    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$isApprovalWait = [string]::Equals($Kind, 'ApprovalWait', [System.StringComparison]::OrdinalIgnoreCase)
$accentColor = if ($isApprovalWait) {
    [System.Drawing.Color]::FromArgb(245, 158, 11)
}
else {
    [System.Drawing.Color]::FromArgb(34, 111, 245)
}
$iconText = if ($isApprovalWait) { '!' } else { 'OK' }
$iconBackColor = $accentColor

function Play-NotifySound {
    try {
        if ($isApprovalWait) {
            [System.Media.SystemSounds]::Exclamation.Play()
            Start-Sleep -Milliseconds 120
            [Console]::Beep(740, 140)
            [Console]::Beep(740, 140)
        }
        else {
            [System.Media.SystemSounds]::Asterisk.Play()
            Start-Sleep -Milliseconds 120
            [System.Media.SystemSounds]::Exclamation.Play()
            [Console]::Beep(880, 120)
            [Console]::Beep(1175, 160)
        }
    }
    catch {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { return }
    }
}

$screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$width = 420
$height = 154
$margin = 18

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = New-Object System.Drawing.Point(($screen.Right - $width - $margin), ($screen.Bottom - $height - $margin))
$form.BackColor = [System.Drawing.Color]::White

$accentPanel = New-Object System.Windows.Forms.Panel
$accentPanel.Location = New-Object System.Drawing.Point(0, 0)
$accentPanel.Size = New-Object System.Drawing.Size(7, $height)
$accentPanel.BackColor = $accentColor
$form.Controls.Add($accentPanel)

$iconPanel = New-Object System.Windows.Forms.Panel
$iconPanel.Location = New-Object System.Drawing.Point(22, 22)
$iconPanel.Size = New-Object System.Drawing.Size(44, 44)
$iconPanel.BackColor = $iconBackColor
$form.Controls.Add($iconPanel)

$iconLabel = New-Object System.Windows.Forms.Label
$iconLabel.Text = $iconText
$iconLabel.ForeColor = [System.Drawing.Color]::White
$iconLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$iconLabel.Location = New-Object System.Drawing.Point(0, 0)
$iconLabel.Size = New-Object System.Drawing.Size(44, 44)
$iconLabel.TextAlign = 'MiddleCenter'
$iconPanel.Controls.Add($iconLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $Title
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 31, 40)
$titleLabel.Location = New-Object System.Drawing.Point(78, 22)
$titleLabel.Size = New-Object System.Drawing.Size(($width - 118), 28)
$titleLabel.TextAlign = 'MiddleLeft'
$form.Controls.Add($titleLabel)

$messageLabel = New-Object System.Windows.Forms.Label
$messageLabel.Text = $Message
$messageLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$messageLabel.ForeColor = [System.Drawing.Color]::FromArgb(68, 76, 88)
$messageLabel.Location = New-Object System.Drawing.Point(80, 50)
$messageLabel.Size = New-Object System.Drawing.Size(($width - 104), 64)
$messageLabel.TextAlign = 'TopLeft'
$form.Controls.Add($messageLabel)

$topLine = New-Object System.Windows.Forms.Panel
$topLine.Location = New-Object System.Drawing.Point(7, 0)
$topLine.Size = New-Object System.Drawing.Size(($width - 7), 1)
$topLine.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
$form.Controls.Add($topLine)

$bottomLine = New-Object System.Windows.Forms.Panel
$bottomLine.Location = New-Object System.Drawing.Point(7, ($height - 1))
$bottomLine.Size = New-Object System.Drawing.Size(($width - 7), 1)
$bottomLine.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
$form.Controls.Add($bottomLine)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = ConvertFrom-Utf8Base64 '55+l6YGT5LqG'
$closeButton.Location = New-Object System.Drawing.Point(($width - 98), 116)
$closeButton.Size = New-Object System.Drawing.Size(78, 26)
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = $accentColor
$closeButton.ForeColor = [System.Drawing.Color]::White
$closeButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$closeX = New-Object System.Windows.Forms.Label
$closeX.Text = 'x'
$closeX.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$closeX.ForeColor = [System.Drawing.Color]::FromArgb(114, 124, 140)
$closeX.Location = New-Object System.Drawing.Point(($width - 30), 12)
$closeX.Size = New-Object System.Drawing.Size(18, 18)
$closeX.TextAlign = 'MiddleCenter'
$closeX.Cursor = [System.Windows.Forms.Cursors]::Hand
$closeX.Add_Click({ $form.Close() })
$form.Controls.Add($closeX)

$keepTopTimer = New-Object System.Windows.Forms.Timer
$keepTopTimer.Interval = 700
$keepTopTimer.Add_Tick({
        $form.TopMost = $true
        [void][CodexNotifyNative]::SetWindowPos(
            $form.Handle,
            [CodexNotifyNative]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [CodexNotifyNative]::SWP_NOMOVE -bor [CodexNotifyNative]::SWP_NOSIZE -bor [CodexNotifyNative]::SWP_SHOWWINDOW
        )
    })

$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = [Math]::Max(3, $Seconds) * 1000
$closeTimer.Add_Tick({
        $closeTimer.Stop()
        $form.Close()
    })

$soundTimer = New-Object System.Windows.Forms.Timer
$soundTimer.Interval = 140
$soundTimer.Add_Tick({
        $soundTimer.Stop()
        Play-NotifySound
    })

$form.Add_Shown({
        Write-DiagnosticLog ("form shown title='{0}' kind='{1}' seconds={2}" -f $Title, $Kind, $Seconds)
        $region = [CodexNotifyNative]::CreateRoundRectRgn(0, 0, $form.Width + 1, $form.Height + 1, 14, 14)
        [void][CodexNotifyNative]::SetWindowRgn($form.Handle, $region, $true)
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $form.TopMost = $true
        [void][CodexNotifyNative]::ShowWindow($form.Handle, [CodexNotifyNative]::SW_RESTORE)
        [void][CodexNotifyNative]::ShowWindow($form.Handle, [CodexNotifyNative]::SW_SHOWNORMAL)
        $form.Activate()
        [void][CodexNotifyNative]::SetForegroundWindow($form.Handle)
        [void][CodexNotifyNative]::SetWindowPos(
            $form.Handle,
            [CodexNotifyNative]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [CodexNotifyNative]::SWP_NOMOVE -bor [CodexNotifyNative]::SWP_NOSIZE -bor [CodexNotifyNative]::SWP_SHOWWINDOW
        )
        $keepTopTimer.Start()
        $closeTimer.Start()
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $soundTimer.Start()
    })

$form.Add_FormClosed({
        Write-DiagnosticLog ("form closed title='{0}' kind='{1}'" -f $Title, $Kind)
        $keepTopTimer.Stop()
        $closeTimer.Stop()
        $soundTimer.Stop()
        $keepTopTimer.Dispose()
        $closeTimer.Dispose()
        $soundTimer.Dispose()
        $form.Dispose()
    })

[void][System.Windows.Forms.Application]::Run($form)
