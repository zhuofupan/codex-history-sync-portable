<#
.SYNOPSIS
Clone Codex Desktop history between local model_provider accounts.

.DESCRIPTION
Codex Desktop keeps local thread metadata in %USERPROFILE%\.codex\state_5.sqlite
and rollout JSONL files under %USERPROFILE%\.codex\sessions. The desktop UI
separates history by the threads.model_provider value, for example openai,
custom, or rightcode.

This tool copies a thread to another provider instead of moving it. The source
thread stays visible in the original account, and the copied thread gets a new
thread id under the destination provider.

.EXAMPLES
.\codex-history-sync.ps1 providers
.\codex-history-sync.ps1 list -From openai -Limit 20
.\codex-history-sync.ps1 clone -Id 019eb473-dbac-7681-82e1-7e6f964c4946 -To custom
.\codex-history-sync.ps1 sync -From openai -To custom
.\codex-history-sync.ps1 mirror -Providers openai,custom
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('providers', 'list', 'clone', 'sync', 'mirror', 'register')]
    [string]$Action = 'list',

    [string]$CodexHome,
    [string]$Id,
    [string]$CloneId,
    [string]$From,
    [string]$To,
    [string[]]$Providers,
    [string]$Cwd,
    [int]$Limit = 30,
    [switch]$IncludeArchived,
    [switch]$IncludeImported,
    [switch]$DryRun,
    [switch]$ForceNew,
    [switch]$NoGlobalState
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
[Console]::InputEncoding = $script:Utf8NoBom
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RootDir = Split-Path -Parent $script:ToolDir

function Resolve-CodexHome {
    param([AllowNull()][string]$Requested)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
            $Requested,
            $env:CODEX_HOME,
            $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.codex' }),
            $(if ($env:HOME) { Join-Path $env:HOME '.codex' })
        )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $candidates.Contains($path)) {
            $candidates.Add($path)
        }
    }

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $path 'state_5.sqlite')) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    foreach ($root in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Recurse -Force -Filter 'state_5.sqlite' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) {
            return $hit.DirectoryName
        }
    }

    throw "Codex history database was not found. Pass -CodexHome <path-to-.codex> or set CODEX_HOME."
}

function Resolve-ToolPath {
    param([string]$Name)

    $exeName = if ($Name.EndsWith('.exe')) { $Name } else { "$Name.exe" }
    foreach ($path in @(
            (Join-Path $script:RootDir "bin\$exeName"),
            (Join-Path $script:ToolDir "bin\$exeName"),
            (Join-Path $script:RootDir "dist\codex-history-sync-portable\bin\$exeName")
        )) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command '$Name' was not found in PATH."
    }
    return $cmd.Source
}

$CodexHome = Resolve-CodexHome $CodexHome
$script:Sqlite = Resolve-ToolPath 'sqlite3'
$script:StateDb = Join-Path $CodexHome 'state_5.sqlite'
$script:MapPath = Join-Path $CodexHome 'codex-history-sync-map.json'
$script:GlobalStatePath = Join-Path $CodexHome '.codex-global-state.json'

if (-not (Test-Path -LiteralPath $script:StateDb)) {
    throw "Codex state database not found: $script:StateDb"
}

function Quote-Sql {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-Sql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [switch]$Json
    )

    if ($Json) {
        $raw = & $script:Sqlite -json $script:StateDb $Sql
    }
    else {
        $raw = & $script:Sqlite $script:StateDb $Sql
    }

    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 failed with exit code $LASTEXITCODE."
    }

    if ($Json) {
        $text = ($raw -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        return ($text | ConvertFrom-Json)
    }

    return $raw
}

function Convert-CodexCwd {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return ($Path -replace '^\\\\\?\\', '').TrimEnd('\')
}

function Convert-CodexFilePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return ($Path -replace '^\\\\\?\\', '')
}

function Shorten-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Max = 80
    )

    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, $Max - 1) + '...'
}

function New-CodexThreadId {
    [byte[]]$bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    for ($i = 5; $i -ge 0; $i--) {
        $bytes[$i] = [byte]($ms -band 0xff)
        $ms = [Int64]($ms -shr 8)
    }

    $bytes[6] = [byte](($bytes[6] -band 0x0f) -bor 0x70)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)

    $hex = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    return $hex.Substring(0, 8) + '-' +
        $hex.Substring(8, 4) + '-' +
        $hex.Substring(12, 4) + '-' +
        $hex.Substring(16, 4) + '-' +
        $hex.Substring(20, 12)
}

function Read-SyncMap {
    if (-not (Test-Path -LiteralPath $script:MapPath)) {
        return [pscustomobject]@{
            version = 1
            links   = @()
        }
    }

    $raw = Get-Content -LiteralPath $script:MapPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            version = 1
            links   = @()
        }
    }

    $map = $raw | ConvertFrom-Json
    if (-not ($map.PSObject.Properties.Name -contains 'links')) {
        $map | Add-Member -NotePropertyName links -NotePropertyValue @()
    }
    return $map
}

function Save-SyncMap {
    param([Parameter(Mandatory)]$Map)

    if ($DryRun) { return }
    $dir = Split-Path $script:MapPath -Parent
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Map | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:MapPath -Encoding UTF8
}

function Get-MapLinks {
    param([Parameter(Mandatory)]$Map)
    return @($Map.links)
}

function Get-ThreadRow {
    param([Parameter(Mandatory)][string]$ThreadId)

    $rows = Invoke-Sql -Json -Sql @"
SELECT *
FROM threads
WHERE id = $(Quote-Sql $ThreadId);
"@

    if ($rows.Count -eq 0) {
        throw "Thread not found in state database: $ThreadId"
    }
    return $rows[0]
}

function Backup-CodexState {
    param(
        [string]$Reason,
        [string[]]$ExtraPaths = @()
    )

    if ($DryRun) { return $null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeReason = ($Reason -replace '[^A-Za-z0-9_.-]', '-')
    $backupDir = Join-Path (Join-Path $CodexHome 'backups') "history-sync-$safeReason-$stamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $backupDb = Join-Path $backupDir 'state_5.sqlite'
    $backupDbSql = $backupDb -replace '\\', '/'
    & $script:Sqlite $script:StateDb ".backup '$backupDbSql'"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create SQLite backup at $backupDb"
    }

    foreach ($path in @($script:GlobalStatePath, $script:MapPath) + $ExtraPaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir (Split-Path $path -Leaf)) -Force
        }
    }

    return $backupDir
}

function Copy-RolloutFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$OldId,
        [Parameter(Mandatory)][string]$NewId,
        [Parameter(Mandatory)][string]$OldProvider,
        [Parameter(Mandatory)][string]$NewProvider
    )

    if ($DryRun) { return }

    $providerPattern = '"model_provider"\s*:\s*"' + [regex]::Escape($OldProvider) + '"'
    $safeProvider = $NewProvider -replace '"', '\"'
    $providerReplacement = '"model_provider":"' + $safeProvider + '"'

    $tempPath = "$DestinationPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    $shareMode = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $maxAttempts = 8
    $lastError = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $sourceStream = $null
        $destStream = $null
        $reader = $null
        $writer = $null

        try {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force
            }

            $sourceStream = [System.IO.FileStream]::new(
                $SourcePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                $shareMode
            )
            $destStream = [System.IO.FileStream]::new(
                $tempPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $reader = [System.IO.StreamReader]::new($sourceStream, [System.Text.UTF8Encoding]::new($false, $true))
            $writer = [System.IO.StreamWriter]::new($destStream, [System.Text.UTF8Encoding]::new($false))

            while (($line = $reader.ReadLine()) -ne $null) {
                $line = $line.Replace($OldId, $NewId)
                $line = [regex]::Replace($line, $providerPattern, $providerReplacement)
                $writer.WriteLine($line)
            }

            $writer.Dispose()
            $writer = $null
            $reader.Dispose()
            $reader = $null

            if (Test-Path -LiteralPath $DestinationPath) {
                $replaceBackupPath = "$DestinationPath.replace-backup-$([Guid]::NewGuid().ToString('N'))"
                [System.IO.File]::Replace($tempPath, $DestinationPath, $replaceBackupPath)
                if (Test-Path -LiteralPath $replaceBackupPath) {
                    Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                [System.IO.File]::Move($tempPath, $DestinationPath)
            }
            return
        }
        catch {
            $lastError = $_
            if ($writer) { $writer.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($destStream) { $destStream.Dispose() }
            if ($sourceStream) { $sourceStream.Dispose() }
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
            if ($replaceBackupPath -and (Test-Path -LiteralPath $replaceBackupPath)) {
                Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
            }

            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Milliseconds (200 * $attempt)
                continue
            }

            throw "复制会话文件失败，源文件可能正被 Codex 写入：$SourcePath。最后错误：$($lastError.Exception.Message)"
        }
        finally {
            if ($writer) { $writer.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($destStream) { $destStream.Dispose() }
            if ($sourceStream) { $sourceStream.Dispose() }
        }
    }
}

function Add-JsonPropertyCopy {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$OldName,
        [Parameter(Mandatory)][string]$NewName
    )

    if (-not $Object) { return $false }
    $names = @($Object.PSObject.Properties.Name)
    if (($names -contains $OldName) -and -not ($names -contains $NewName)) {
        $Object | Add-Member -NotePropertyName $NewName -NotePropertyValue $Object.$OldName
        return $true
    }
    return $false
}

function Add-ArrayClone {
    param(
        [AllowNull()]$ArrayValue,
        [Parameter(Mandatory)][string]$OldId,
        [Parameter(Mandatory)][string]$NewId,
        [ref]$Changed
    )

    $items = @($ArrayValue)
    if (($items -contains $OldId) -and -not ($items -contains $NewId)) {
        $Changed.Value = $true
        return @($items + $NewId)
    }
    return $ArrayValue
}

function Update-GlobalStateClone {
    param(
        [Parameter(Mandatory)][string]$OldId,
        [Parameter(Mandatory)][string]$NewId
    )

    if ($NoGlobalState -or $DryRun -or -not (Test-Path -LiteralPath $script:GlobalStatePath)) {
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $script:GlobalStatePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }

        $state = $raw | ConvertFrom-Json
        $changed = $false

        if ($state.PSObject.Properties.Name -contains 'projectless-thread-ids') {
            $state.'projectless-thread-ids' = Add-ArrayClone $state.'projectless-thread-ids' $OldId $NewId ([ref]$changed)
        }

        foreach ($name in @('thread-workspace-root-hints', 'thread-projectless-output-directories')) {
            if (($state.PSObject.Properties.Name -contains $name) -and (Add-JsonPropertyCopy $state.$name $OldId $NewId)) {
                $changed = $true
            }
        }

        $atom = $state.'electron-persisted-atom-state'
        if ($atom) {
            foreach ($name in @('prompt-history', 'heartbeat-thread-permissions-by-id')) {
                if (($atom.PSObject.Properties.Name -contains $name) -and (Add-JsonPropertyCopy $atom.$name $OldId $NewId)) {
                    $changed = $true
                }
            }
        }

        if ($changed) {
            $state | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $script:GlobalStatePath -Encoding UTF8 -NoNewline
        }

        return $changed
    }
    catch {
        Write-Warning "Skipped Codex global UI state update; chat history and database sync are not affected. Reason: $($_.Exception.GetType().Name)"
        return $false
    }
}

function Add-MappingLink {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)]$SourceRow,
        [Parameter(Mandatory)][string]$ClonedId,
        [Parameter(Mandatory)][string]$TargetProvider
    )

    $links = @(Get-MapLinks $Map)
    $existing = @($links | Where-Object {
            $_.source_id -eq $SourceRow.id -and
            $_.cloned_id -eq $ClonedId -and
            $_.target_provider -eq $TargetProvider
        })

    if ($existing.Count -gt 0) { return $false }

    $link = [pscustomobject]@{
        source_id            = $SourceRow.id
        source_provider      = $SourceRow.model_provider
        source_updated_at_ms = $SourceRow.updated_at_ms
        target_provider      = $TargetProvider
        cloned_id            = $ClonedId
        created_at_utc       = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $Map.links = @($links + $link)
    Save-SyncMap $Map
    return $true
}

function Update-MappingLinkMetadata {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)]$SourceRow,
        [Parameter(Mandatory)][string]$ClonedId,
        [Parameter(Mandatory)][string]$TargetProvider
    )

    $changed = $false
    foreach ($link in (Get-MapLinks $Map)) {
        if ($link.source_id -eq $SourceRow.id -and
            $link.cloned_id -eq $ClonedId -and
            $link.target_provider -eq $TargetProvider) {

            if ($link.PSObject.Properties.Name -contains 'source_updated_at_ms') {
                $link.source_updated_at_ms = $SourceRow.updated_at_ms
            }
            else {
                $link | Add-Member -NotePropertyName source_updated_at_ms -NotePropertyValue $SourceRow.updated_at_ms
            }

            if ($link.PSObject.Properties.Name -contains 'updated_at_utc') {
                $link.updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            else {
                $link | Add-Member -NotePropertyName updated_at_utc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))
            }

            $changed = $true
            break
        }
    }

    if ($changed) {
        Save-SyncMap $Map
    }
    return $changed
}

function Find-MappedClone {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$TargetProvider
    )

    $links = @(Get-MapLinks $Map)
    foreach ($link in $links) {
        if ($link.source_id -eq $SourceId -and $link.target_provider -eq $TargetProvider) {
            $count = Invoke-Sql -Sql "SELECT count(*) FROM threads WHERE id = $(Quote-Sql $link.cloned_id);"
            if (($count -join '').Trim() -eq '1') {
                return $link
            }
        }
    }
    return $null
}

function Test-IsImportedClone {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$ThreadId
    )

    foreach ($link in (Get-MapLinks $Map)) {
        if ($link.cloned_id -eq $ThreadId) { return $true }
    }
    return $false
}

function Get-NewRolloutPath {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OldId,
        [Parameter(Mandatory)][string]$NewId
    )

    $SourcePath = Convert-CodexFilePath $SourcePath
    $dir = Split-Path $SourcePath -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = [System.IO.Path]::GetDirectoryName($SourcePath)
    }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "Could not determine rollout directory for: $SourcePath"
    }
    $name = Split-Path $SourcePath -Leaf
    if ($name.Contains($OldId)) {
        $newName = $name.Replace($OldId, $NewId)
    }
    else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext = [System.IO.Path]::GetExtension($name)
        $newName = "$base-copy-$NewId$ext"
    }
    return Join-Path $dir $newName
}

function Update-ExistingClone {
    param(
        [Parameter(Mandatory)]$SourceRow,
        [Parameter(Mandatory)]$MappedLink,
        [Parameter(Mandatory)][string]$TargetProvider,
        [Parameter(Mandatory)]$Map
    )

    $clone = Get-ThreadRow ([string]$MappedLink.cloned_id)
    $sourcePath = Convert-CodexFilePath ([string]$SourceRow.rollout_path)
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Rollout JSONL file not found for $($SourceRow.id): $sourcePath"
    }

    $destPath = Convert-CodexFilePath ([string]$clone.rollout_path)
    if ([string]::IsNullOrWhiteSpace($destPath)) {
        $destPath = Get-NewRolloutPath $sourcePath ([string]$SourceRow.id) ([string]$MappedLink.cloned_id)
    }

    $backupPaths = @($sourcePath)
    if (Test-Path -LiteralPath $destPath) {
        $backupPaths += $destPath
    }
    $backupDir = Backup-CodexState "update-$($SourceRow.id)-to-$TargetProvider" $backupPaths

    if ($DryRun) {
        return [pscustomobject]@{
            status          = 'dry-run-update-existing'
            source_id       = $SourceRow.id
            source_provider = $SourceRow.model_provider
            target_provider = $TargetProvider
            cloned_id       = $MappedLink.cloned_id
            backup_dir      = $backupDir
            rollout_path    = $destPath
        }
    }

    Copy-RolloutFile $sourcePath $destPath ([string]$SourceRow.id) ([string]$MappedLink.cloned_id) ([string]$SourceRow.model_provider) $TargetProvider

    $sourceId = Quote-Sql ([string]$SourceRow.id)
    $cloneId = Quote-Sql ([string]$MappedLink.cloned_id)
    $target = Quote-Sql $TargetProvider
    $dest = Quote-Sql $destPath

    $sql = @"
PRAGMA busy_timeout=5000;
BEGIN IMMEDIATE;
UPDATE threads
SET
  rollout_path = $dest,
  created_at = (SELECT created_at FROM threads WHERE id = $sourceId),
  updated_at = (SELECT updated_at FROM threads WHERE id = $sourceId),
  source = (SELECT source FROM threads WHERE id = $sourceId),
  model_provider = $target,
  cwd = (SELECT cwd FROM threads WHERE id = $sourceId),
  title = (SELECT title FROM threads WHERE id = $sourceId),
  sandbox_policy = (SELECT sandbox_policy FROM threads WHERE id = $sourceId),
  approval_mode = (SELECT approval_mode FROM threads WHERE id = $sourceId),
  tokens_used = (SELECT tokens_used FROM threads WHERE id = $sourceId),
  has_user_event = (SELECT has_user_event FROM threads WHERE id = $sourceId),
  archived = (SELECT archived FROM threads WHERE id = $sourceId),
  archived_at = (SELECT archived_at FROM threads WHERE id = $sourceId),
  git_sha = (SELECT git_sha FROM threads WHERE id = $sourceId),
  git_branch = (SELECT git_branch FROM threads WHERE id = $sourceId),
  git_origin_url = (SELECT git_origin_url FROM threads WHERE id = $sourceId),
  cli_version = (SELECT cli_version FROM threads WHERE id = $sourceId),
  first_user_message = (SELECT first_user_message FROM threads WHERE id = $sourceId),
  agent_nickname = (SELECT agent_nickname FROM threads WHERE id = $sourceId),
  agent_role = (SELECT agent_role FROM threads WHERE id = $sourceId),
  memory_mode = (SELECT memory_mode FROM threads WHERE id = $sourceId),
  model = (SELECT model FROM threads WHERE id = $sourceId),
  reasoning_effort = (SELECT reasoning_effort FROM threads WHERE id = $sourceId),
  agent_path = (SELECT agent_path FROM threads WHERE id = $sourceId),
  created_at_ms = (SELECT created_at_ms FROM threads WHERE id = $sourceId),
  updated_at_ms = (SELECT updated_at_ms FROM threads WHERE id = $sourceId),
  thread_source = (SELECT thread_source FROM threads WHERE id = $sourceId),
  preview = (SELECT preview FROM threads WHERE id = $sourceId)
WHERE id = $cloneId;

DELETE FROM thread_dynamic_tools
WHERE thread_id = $cloneId;

INSERT OR IGNORE INTO thread_dynamic_tools (
  thread_id, position, name, description, input_schema, defer_loading, namespace
)
SELECT
  $cloneId, position, name, description, input_schema, defer_loading, namespace
FROM thread_dynamic_tools
WHERE thread_id = $sourceId;
COMMIT;
"@

    Invoke-Sql -Sql $sql | Out-Null
    Update-GlobalStateClone ([string]$SourceRow.id) ([string]$MappedLink.cloned_id) | Out-Null
    Update-MappingLinkMetadata $Map $SourceRow ([string]$MappedLink.cloned_id) $TargetProvider | Out-Null

    return [pscustomobject]@{
        status          = 'updated-existing'
        source_id       = $SourceRow.id
        source_provider = $SourceRow.model_provider
        target_provider = $TargetProvider
        cloned_id       = $MappedLink.cloned_id
        backup_dir      = $backupDir
        rollout_path    = $destPath
    }
}

function Clone-Thread {
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string]$TargetProvider,
        [Parameter(Mandatory)]$Map
    )

    $source = Get-ThreadRow $ThreadId

    if (-not $ForceNew) {
        $mapped = Find-MappedClone $Map $ThreadId $TargetProvider
        if ($mapped) {
            return Update-ExistingClone $source $mapped $TargetProvider $Map
        }
    }

    if ($source.model_provider -eq $TargetProvider -and -not $ForceNew) {
        return [pscustomobject]@{
            status          = 'skipped-same-provider'
            source_id       = $ThreadId
            source_provider = $source.model_provider
            target_provider = $TargetProvider
            cloned_id       = $ThreadId
            backup_dir      = $null
            rollout_path    = $source.rollout_path
        }
    }

    $sourcePath = Convert-CodexFilePath ([string]$source.rollout_path)
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Rollout JSONL file not found for ${ThreadId}: $sourcePath"
    }

    do {
        $newId = New-CodexThreadId
        $exists = (Invoke-Sql -Sql "SELECT count(*) FROM threads WHERE id = $(Quote-Sql $newId);") -join ''
    } while ($exists.Trim() -ne '0')

    $destPath = Get-NewRolloutPath $sourcePath $ThreadId $newId
    if (Test-Path -LiteralPath $destPath) {
        throw "Destination rollout already exists: $destPath"
    }

    $backupDir = Backup-CodexState "clone-$ThreadId-to-$TargetProvider" @($sourcePath)
    if ($DryRun) {
        return [pscustomobject]@{
            status          = 'dry-run'
            source_id       = $ThreadId
            source_provider = $source.model_provider
            target_provider = $TargetProvider
            cloned_id       = $newId
            backup_dir      = $backupDir
            rollout_path    = $destPath
        }
    }

    Copy-RolloutFile $sourcePath $destPath $ThreadId $newId $source.model_provider $TargetProvider

    $sql = @"
PRAGMA busy_timeout=5000;
BEGIN IMMEDIATE;
INSERT INTO threads (
  id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
  git_sha, git_branch, git_origin_url, cli_version, first_user_message,
  agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
  created_at_ms, updated_at_ms, thread_source, preview
)
SELECT
  $(Quote-Sql $newId), $(Quote-Sql $destPath), created_at, updated_at, source, $(Quote-Sql $TargetProvider), cwd, title,
  sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
  git_sha, git_branch, git_origin_url, cli_version, first_user_message,
  agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
  created_at_ms, updated_at_ms, thread_source, preview
FROM threads
WHERE id = $(Quote-Sql $ThreadId);

INSERT OR IGNORE INTO thread_dynamic_tools (
  thread_id, position, name, description, input_schema, defer_loading, namespace
)
SELECT
  $(Quote-Sql $newId), position, name, description, input_schema, defer_loading, namespace
FROM thread_dynamic_tools
WHERE thread_id = $(Quote-Sql $ThreadId);
COMMIT;
"@

    Invoke-Sql -Sql $sql | Out-Null
    Update-GlobalStateClone $ThreadId $newId | Out-Null
    Add-MappingLink $Map $source $newId $TargetProvider | Out-Null

    return [pscustomobject]@{
        status          = 'cloned'
        source_id       = $ThreadId
        source_provider = $source.model_provider
        target_provider = $TargetProvider
        cloned_id       = $newId
        backup_dir      = $backupDir
        rollout_path    = $destPath
    }
}

function Show-Providers {
    $rows = Invoke-Sql -Json -Sql @"
SELECT model_provider, source, count(*) AS count
FROM threads
GROUP BY model_provider, source
ORDER BY count DESC, model_provider, source;
"@

    $rows | Format-Table -AutoSize
}

function Show-List {
    $conditions = @()
    if ($From) { $conditions += "model_provider = $(Quote-Sql $From)" }
    if (-not $IncludeArchived) { $conditions += "archived = 0" }
    $where = ''
    if ($conditions.Count -gt 0) {
        $where = 'WHERE ' + ($conditions -join ' AND ')
    }

    $rows = Invoke-Sql -Json -Sql @"
SELECT id, model_provider, cwd, title, archived, updated_at_ms
FROM threads
$where
ORDER BY updated_at_ms DESC, id DESC
LIMIT $Limit;
"@

    if ($Cwd) {
        $wanted = (Convert-CodexCwd $Cwd)
        $rows = @($rows | Where-Object { (Convert-CodexCwd $_.cwd) -eq $wanted })
    }

    $rows |
        ForEach-Object {
            [pscustomobject]@{
                updated        = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$_.updated_at_ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm'))
                provider       = $_.model_provider
                archived       = [bool]$_.archived
                id             = $_.id
                cwd            = Convert-CodexCwd $_.cwd
                title          = Shorten-Text $_.title 70
            }
        } |
        Format-Table -AutoSize
}

function Invoke-Sync {
    param(
        [Parameter(Mandatory)][string]$SourceProvider,
        [Parameter(Mandatory)][string]$TargetProvider,
        [Parameter(Mandatory)]$Map
    )

    $conditions = @("model_provider = $(Quote-Sql $SourceProvider)")
    if (-not $IncludeArchived) { $conditions += "archived = 0" }
    $where = 'WHERE ' + ($conditions -join ' AND ')

    $rows = Invoke-Sql -Json -Sql @"
SELECT id, model_provider, cwd, title, updated_at_ms, archived
FROM threads
$where
ORDER BY updated_at_ms ASC, id ASC;
"@

    if ($Cwd) {
        $wanted = Convert-CodexCwd $Cwd
        $rows = @($rows | Where-Object { (Convert-CodexCwd $_.cwd) -eq $wanted })
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        if (-not $IncludeImported -and (Test-IsImportedClone $Map $row.id)) {
            $results.Add([pscustomobject]@{
                    status          = 'skipped-imported-clone'
                    source_id       = $row.id
                    source_provider = $SourceProvider
                    target_provider = $TargetProvider
                    cloned_id       = ''
                    backup_dir      = ''
                    rollout_path    = ''
                })
            continue
        }

        $results.Add((Clone-Thread $row.id $TargetProvider $Map))
    }

    return $results
}

function Register-CloneMapping {
    param(
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$ExistingCloneId,
        [Parameter(Mandatory)][string]$TargetProvider,
        [Parameter(Mandatory)]$Map
    )

    $source = Get-ThreadRow $SourceId
    $clone = Get-ThreadRow $ExistingCloneId

    if ($clone.model_provider -ne $TargetProvider) {
        throw "Clone thread provider is '$($clone.model_provider)', not '$TargetProvider'."
    }

    Backup-CodexState "register-$SourceId-to-$TargetProvider" @() | Out-Null
    $added = Add-MappingLink $Map $source $ExistingCloneId $TargetProvider
    return [pscustomobject]@{
        status          = $(if ($added) { 'registered' } else { 'already-registered' })
        source_id       = $SourceId
        source_provider = $source.model_provider
        target_provider = $TargetProvider
        cloned_id       = $ExistingCloneId
        clone_provider  = $clone.model_provider
    }
}

$map = Read-SyncMap

switch ($Action) {
    'providers' {
        Show-Providers
    }

    'list' {
        Show-List
    }

    'clone' {
        if (-not $Id -or -not $To) {
            throw "Usage: clone -Id <thread-id> -To <provider>"
        }
        Clone-Thread $Id $To $map | Format-List
    }

    'sync' {
        if (-not $From -or -not $To) {
            throw "Usage: sync -From <provider> -To <provider>"
        }
        Invoke-Sync $From $To $map | Format-Table -AutoSize
    }

    'mirror' {
        if (-not $Providers -or $Providers.Count -ne 2) {
            throw "Usage: mirror -Providers openai,custom"
        }
        $a = $Providers[0]
        $b = $Providers[1]
        $first = Invoke-Sync $a $b $map
        $map = Read-SyncMap
        $second = Invoke-Sync $b $a $map
        @($first + $second) | Format-Table -AutoSize
    }

    'register' {
        if (-not $Id -or -not $CloneId -or -not $To) {
            throw "Usage: register -Id <source-thread-id> -CloneId <existing-clone-id> -To <provider>"
        }
        Register-CloneMapping $Id $CloneId $To $map | Format-List
    }
}
