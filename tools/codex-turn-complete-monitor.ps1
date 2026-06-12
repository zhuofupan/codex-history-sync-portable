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
$script:SeenTurns = New-Object 'System.Collections.Generic.HashSet[string]'

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
    }
}

function Invoke-CompletionPopup {
    $title = ConvertFrom-Utf8Base64 'Q29kZXgg5Lu75Yqh5a6M5oiQ'
    $message = ConvertFrom-Utf8Base64 'Q29kZXgg5bey5a6M5oiQ5LiA5Liq5Zue5aSN44CC'

    if (-not [string]::IsNullOrWhiteSpace($NotifierLauncherPath) -and
        (Test-Path -LiteralPath $NotifierLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $NotifierLauncherPath,
            '-Title',
            $title,
            '-Message',
            $message,
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
            '-Message',
            $message,
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

function Test-TaskCompleteLine {
    param([Parameter(Mandatory)][string]$Line)

    try {
        $obj = $Line | ConvertFrom-Json
        if ([string]$obj.type -ne 'event_msg') { return $false }
        if ([string]$obj.payload.type -ne 'task_complete') { return $false }

        $eventTime = [DateTimeOffset]::MinValue
        if (-not [string]::IsNullOrWhiteSpace([string]$obj.timestamp)) {
            $eventTime = [DateTimeOffset]::Parse([string]$obj.timestamp)
        }
        if ($eventTime -lt $script:MonitorStartedAt.AddSeconds(-2)) { return $false }

        $turnId = [string]$obj.payload.turn_id
        if ([string]::IsNullOrWhiteSpace($turnId)) {
            $turnId = [string]$obj.timestamp
        }
        if ([string]::IsNullOrWhiteSpace($turnId)) { return $false }

        return $script:SeenTurns.Add($turnId)
    }
    catch {
        return $false
    }
}

function Process-RolloutFile {
    param([Parameter(Mandatory)]$File)

    $path = [string]$File.FullName
    if (-not $script:Offsets.ContainsKey($path)) {
        $script:Offsets[$path] = [int64]0
        $script:Buffers[$path] = ''
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
        if (Test-TaskCompleteLine $line) {
            Invoke-CompletionPopup
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
