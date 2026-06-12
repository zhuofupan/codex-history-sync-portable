param(
    [string]$CodexHome,
    [string]$CcSwitchHome,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
[Console]::InputEncoding = $script:Utf8NoBom
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$script:SuppressThreadRefresh = $true

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexHistorySyncWindow {
    public const int SW_SHOWNORMAL = 1;
    public const int SW_RESTORE = 9;

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RootDir = Split-Path -Parent $script:ToolDir
$script:CliPath = Join-Path $script:RootDir 'codex-history-sync.cmd'
$script:NotifierPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.ps1'
$script:NotifierLauncherPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.vbs'
$script:TurnCompleteMonitorPath = Join-Path $script:ToolDir 'codex-turn-complete-monitor.ps1'
$script:TurnCompleteMonitorLauncherPath = Join-Path $script:ToolDir 'codex-turn-complete-monitor.vbs'

function Join-OptionalPath {
    param(
        [AllowNull()][string]$Base,
        [Parameter(Mandatory)][string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    try {
        return (Join-Path $Base $Child)
    }
    catch {
        return $null
    }
}

function Resolve-CodexHome {
    param([AllowNull()][string]$Requested)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
            $Requested,
            $env:CODEX_HOME,
            (Join-OptionalPath $env:USERPROFILE '.codex'),
            (Join-OptionalPath $env:HOME '.codex')
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

    throw "找不到 Codex 聊天记录数据库。请用 -CodexHome 指定 .codex 目录，或设置 CODEX_HOME。"
}

function Get-CodexHomeHelpText {
    return @"
请选择 Codex 历史记录目录，也就是包含 state_5.sqlite 的 .codex 文件夹。

常见位置：
1. %USERPROFILE%\.codex
2. 环境变量 CODEX_HOME 指向的目录
3. 便携或迁移环境中，可能在你手动设置过的 .codex 目录

判断是否选对：
- 目录里应该能看到 state_5.sqlite
- 通常还会有 sessions 文件夹
- sessions 下面会按年份、月份保存 rollout-*.jsonl 聊天记录文件

找不到时可以用 Everything 搜索 state_5.sqlite；它所在的目录就是要加载的记录目录。
点击【记录目录寻找提示】时，工具会自动把 state_5.sqlite 复制到剪贴板，方便直接粘贴到 Everything。

如果你误选了 sessions 或 sessions 下的子目录，工具会自动向上查找包含 state_5.sqlite 的父目录。
"@
}

function Resolve-CodexHomeFromSelection {
    param([AllowNull()][string]$SelectedPath)

    if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return $null }
    $path = Convert-CodexPath $SelectedPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }

    $directChild = Join-Path $path '.codex'
    if (Test-Path -LiteralPath (Join-Path $directChild 'state_5.sqlite')) {
        return (Resolve-Path -LiteralPath $directChild).Path
    }

    $current = (Resolve-Path -LiteralPath $path).Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current 'state_5.sqlite')) {
            return (Resolve-Path -LiteralPath $current).Path
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }

    return $null
}

function Resolve-CcSwitchDb {
    param([AllowNull()][string]$RequestedHome)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
            (Join-OptionalPath $RequestedHome 'cc-switch.db'),
            (Join-Path $script:RootDir 'cc-switch.db'),
            (Join-Path (Split-Path -Parent $script:RootDir) 'cc-switch.db'),
            (Join-OptionalPath $env:LOCALAPPDATA 'cc-switch\cc-switch.db'),
            (Join-OptionalPath $env:APPDATA 'cc-switch\cc-switch.db')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $candidates.Contains($path)) {
            $candidates.Add($path)
        }
    }

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Get-CcSwitchHomeHelpText {
    return @"
请选择 cc-switch 账号目录，也就是包含 cc-switch.db 的目录。

常见位置：
1. cc-switch.exe 所在目录
2. 你解压或安装 cc-switch 的目录
3. %LOCALAPPDATA%\cc-switch 或 %APPDATA%\cc-switch

如果自动加载不到新增账号：
- 先在 cc-switch 里确认已经新增并保存 Codex 节点
- 回到本工具点击【刷新】
- 仍然没有时，点击【增加账号目录】，选择包含 cc-switch.db 的目录

找不到时可以用 Everything 搜索 cc-switch.db，然后选择这个文件所在的目录。点击【账号目录寻找提示】时，工具会自动把 cc-switch.db 复制到剪贴板。
"@
}

function Resolve-CcSwitchDbFromSelection {
    param([AllowNull()][string]$SelectedPath)

    if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return $null }
    $path = Convert-CodexPath $SelectedPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Split-Path -Leaf $path) -ieq 'cc-switch.db') {
            return (Resolve-Path -LiteralPath $path).Path
        }
        $path = Split-Path -Parent $path
    }

    $current = (Resolve-Path -LiteralPath $path).Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $candidate = Join-Path $current 'cc-switch.db'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }

    try {
        $hit = Get-ChildItem -LiteralPath $path -Recurse -Force -Filter 'cc-switch.db' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    catch {
        return $null
    }

    return $null
}

$script:CodexHomeResolveError = $null
try {
    $CodexHome = Resolve-CodexHome $CodexHome
}
catch {
    $script:CodexHomeResolveError = $_.Exception.Message
    $CodexHome = $null
}
$script:CcSwitchDb = Resolve-CcSwitchDb $CcSwitchHome
$script:CcSwitchSettingsPath = if ($script:CcSwitchDb) { Join-Path (Split-Path -Parent $script:CcSwitchDb) 'settings.json' } else { $null }
$script:StateDb = if ($CodexHome) { Join-Path $CodexHome 'state_5.sqlite' } else { $null }
$script:AllCwdLabel = '全部目录'

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

$script:Sqlite = Resolve-ToolPath 'sqlite3'

if (-not (Test-Path -LiteralPath $script:CliPath)) {
    throw "Sync CLI not found: $script:CliPath"
}

if ($script:StateDb -and -not (Test-Path -LiteralPath $script:StateDb)) {
    $script:CodexHomeResolveError = "Codex state database not found: $script:StateDb"
    $script:StateDb = $null
}

function Quote-Sql {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-SqlJson {
    param([Parameter(Mandatory)][string]$Sql)

    Assert-CodexHomeReady
    $raw = & $script:Sqlite -json $script:StateDb $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 failed with exit code $LASTEXITCODE."
    }

    $text = ($raw -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "解析 Codex 本地数据库输出失败。已启用 UTF-8，如果仍出现这个错误，请重启 GUI 后再试。原始错误：$($_.Exception.Message)"
    }
}

function Invoke-CcSwitchSqlJson {
    param([Parameter(Mandatory)][string]$Sql)

    if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb) -or -not (Test-Path -LiteralPath $script:CcSwitchDb)) {
        throw '未找到 cc-switch.db。历史记录同步仍可使用；如需切换账号并启动，请把工具放到 cc-switch 目录，或用 -CcSwitchHome 指定 cc-switch 安装目录。'
    }

    $raw = & $script:Sqlite -json $script:CcSwitchDb $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 failed with exit code $LASTEXITCODE."
    }

    $text = ($raw -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return ($text | ConvertFrom-Json)
}

function Convert-CodexPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '^\\\\\?\\', '').TrimEnd('\')
}

function Shorten-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Max = 120
    )

    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, $Max - 1) + '...'
}

function Get-ProviderLabel {
    param([AllowNull()][string]$Provider)

    return $Provider
}

function Resolve-ProviderValue {
    param([AllowNull()][string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $Label }
    if ($script:ProviderLabelToValue -and $script:ProviderLabelToValue.ContainsKey($Label)) {
        return $script:ProviderLabelToValue.Get_Item($Label)
    }
    return $Label
}

function Resolve-CcSwitchProviderId {
    param([AllowNull()][string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $Label }
    if ($script:CcSwitchProviderLabelToId -and $script:CcSwitchProviderLabelToId.ContainsKey($Label)) {
        return $script:CcSwitchProviderLabelToId.Get_Item($Label)
    }
    return $Label
}

function Get-CcSwitchCodexProviders {
    if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb) -or -not (Test-Path -LiteralPath $script:CcSwitchDb)) {
        return @()
    }

    return @(Invoke-CcSwitchSqlJson @"
SELECT id, name, settings_config, is_current
FROM providers
WHERE app_type = 'codex'
ORDER BY is_current DESC, sort_index ASC, name ASC;
"@)
}

function Get-HistoryProviderFromCcSwitchProvider {
    param([Parameter(Mandatory)]$ProviderRow)

    $id = [string]$ProviderRow.id
    $name = [string]$ProviderRow.name
    if ($id -eq 'codex-official') { return 'openai' }
    if ($name -eq 'Any Router') { return 'custom' }

    try {
        $settings = [string]$ProviderRow.settings_config | ConvertFrom-Json
        $config = [string]$settings.config
        $match = [System.Text.RegularExpressions.Regex]::Match(
            $config,
            '(?m)^\s*model_provider\s*=\s*["'']([^"'']+)["'']'
        )
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }
    catch {
        return ''
    }

    return ''
}

function Get-CcSwitchAccountLabel {
    param([Parameter(Mandatory)]$ProviderRow)

    $id = [string]$ProviderRow.id
    $name = [string]$ProviderRow.name
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    return $id
}

function Select-Provider {
    param(
        [Parameter(Mandatory)]$Combo,
        [Parameter(Mandatory)][string]$Provider
    )

    $label = Get-ProviderLabel $Provider
    if ($Combo.Items.Contains($label)) {
        $Combo.SelectedItem = $label
    }
}

function Reset-ProviderCombo {
    param(
        [Parameter(Mandatory)]$Combo,
        [Parameter(Mandatory)]$Providers,
        [AllowNull()][string]$PreferredProvider
    )

    if (-not $Combo) { return }

    $current = Resolve-ProviderValue ([string]$Combo.SelectedItem)
    if ([string]::IsNullOrWhiteSpace($current)) {
        $current = $PreferredProvider
    }

    $Combo.Items.Clear()
    foreach ($provider in $Providers) {
        [void]$Combo.Items.Add((Get-ProviderLabel $provider))
    }

    if ($current) {
        Select-Provider $Combo $current
    }
    if (-not $Combo.SelectedItem -and $PreferredProvider) {
        Select-Provider $Combo $PreferredProvider
    }
    if (-not $Combo.SelectedItem -and $Combo.Items.Count -gt 0) {
        $Combo.SelectedIndex = 0
    }
}

function Reset-CcSwitchAccountCombo {
    param([Parameter(Mandatory)]$Providers)

    if (-not $script:CodexProviderCombo) { return }

    $current = Resolve-CcSwitchProviderId ([string]$script:CodexProviderCombo.SelectedItem)
    $script:CodexProviderCombo.Items.Clear()
    $script:CcSwitchProviderLabelToId = @{}
    $usedLabels = @{}
    $preferred = $null

    foreach ($provider in $Providers) {
        $id = [string]$provider.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $labelBase = Get-CcSwitchAccountLabel $provider
        $label = $labelBase
        if ($usedLabels.ContainsKey($label)) {
            $shortId = if ($id.Length -gt 8) { $id.Substring(0, 8) } else { $id }
            $label = "$labelBase ($shortId)"
        }
        $usedLabels[$label] = $true
        $script:CcSwitchProviderLabelToId[$label] = $id
        [void]$script:CodexProviderCombo.Items.Add($label)

        if ([string]::IsNullOrWhiteSpace($preferred) -and [bool]$provider.is_current) {
            $preferred = $id
        }
    }

    if ([string]::IsNullOrWhiteSpace($preferred)) { $preferred = 'codex-official' }
    if (-not [string]::IsNullOrWhiteSpace($current)) { $preferred = $current }

    foreach ($label in $script:CodexProviderCombo.Items) {
        if ($script:CcSwitchProviderLabelToId[$label] -eq $preferred) {
            $script:CodexProviderCombo.SelectedItem = $label
            break
        }
    }
    if (-not $script:CodexProviderCombo.SelectedItem -and $script:CodexProviderCombo.Items.Count -gt 0) {
        $script:CodexProviderCombo.SelectedIndex = 0
    }
}

function Get-Providers {
    $rows = Invoke-SqlJson @"
SELECT model_provider, count(*) AS count
FROM threads
GROUP BY model_provider
ORDER BY model_provider;
"@

    $providers = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('custom', 'openai')) {
        if (-not $providers.Contains($name)) { $providers.Add($name) }
    }
    foreach ($row in $rows) {
        $name = [string]$row.model_provider
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $providers.Contains($name)) {
            $providers.Add($name)
        }
    }
    foreach ($row in (Get-CcSwitchCodexProviders)) {
        $name = Get-HistoryProviderFromCcSwitchProvider $row
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $providers.Contains($name)) {
            $providers.Add($name)
        }
    }
    return $providers
}

function Get-ThreadRows {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [int]$Limit,
        [bool]$IncludeArchived,
        [string]$CwdFilter
    )

    $conditions = @("model_provider = $(Quote-Sql $Provider)")
    if (-not $IncludeArchived) { $conditions += 'archived = 0' }
    $where = 'WHERE ' + ($conditions -join ' AND ')
    $wantedCwd = Convert-CodexPath $CwdFilter
    $limitClause = if ([string]::IsNullOrWhiteSpace($wantedCwd)) { "LIMIT $Limit" } else { '' }

    $rows = Invoke-SqlJson @"
SELECT id, model_provider, cwd, title, archived, updated_at_ms
FROM threads
$where
ORDER BY updated_at_ms DESC, id DESC
$limitClause;
"@

    $items = @()

    foreach ($row in $rows) {
        $cwd = Convert-CodexPath ([string]$row.cwd)
        if (-not [string]::IsNullOrWhiteSpace($wantedCwd) -and $cwd -ne $wantedCwd) {
            continue
        }

        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$row.updated_at_ms).LocalDateTime
        $updatedText = $dt.ToString('yyyy-MM-dd HH:mm')
        $providerText = Get-ProviderLabel ([string]$row.model_provider)
        $archivedValue = [bool]$row.archived
        $idText = [string]$row.id
        $titleText = Shorten-Text ([string]$row.title) 140

        $items += [pscustomobject]@{
            Updated  = $updatedText
            Provider = $providerText
            Archived = $archivedValue
            Id       = $idText
            Cwd      = $cwd
            Title    = $titleText
        }

        if ($items.Count -ge $Limit) { break }
    }

    return @($items)
}

function Get-CwdOptions {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [bool]$IncludeArchived
    )

    $conditions = @(
        "model_provider = $(Quote-Sql $Provider)",
        "cwd IS NOT NULL",
        "trim(cwd) <> ''"
    )
    if (-not $IncludeArchived) { $conditions += 'archived = 0' }
    $where = 'WHERE ' + ($conditions -join ' AND ')

    $rows = Invoke-SqlJson @"
SELECT cwd, max(updated_at_ms) AS updated_at_ms
FROM threads
$where
GROUP BY cwd
ORDER BY updated_at_ms DESC, cwd ASC;
"@

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        $cwd = Convert-CodexPath ([string]$row.cwd)
        if (-not [string]::IsNullOrWhiteSpace($cwd) -and -not $paths.Contains($cwd)) {
            $paths.Add($cwd)
        }
    }
    return $paths.ToArray()
}

function Get-SelectedCwdFilter {
    if (-not $script:CwdCombo) { return '' }
    $selected = [string]$script:CwdCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($selected) -or $selected -eq $script:AllCwdLabel) {
        return ''
    }
    return $selected
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 70)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, 24)
    $label.TextAlign = 'MiddleLeft'
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 110)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, 28)
    $button.UseVisualStyleBackColor = $true
    return $button
}

function Select-FolderPath {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][string]$InitialDirectory
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.CheckFileExists = $false
    $dialog.CheckPathExists = $true
    $dialog.ValidateNames = $false
    $dialog.RestoreDirectory = $true
    $dialog.FileName = '选择此文件夹'
    $dialog.Filter = '文件夹|*.folder'
    if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and
        (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $dialog.InitialDirectory = $InitialDirectory
    }

    try {
        if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        $selected = Convert-CodexPath $dialog.FileName
        if (Test-Path -LiteralPath $selected -PathType Container) {
            return (Resolve-Path -LiteralPath $selected).Path
        }

        $parent = Split-Path -Parent $selected
        if (-not [string]::IsNullOrWhiteSpace($parent) -and
            (Test-Path -LiteralPath $parent -PathType Container)) {
            return (Resolve-Path -LiteralPath $parent).Path
        }

        return $null
    }
    finally {
        $dialog.Dispose()
    }
}

function Copy-TextToClipboard {
    param([Parameter(Mandatory)][string]$Text)

    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        return $true
    }
    catch {
        if ($script:OutputBox) {
            Append-Log "复制到剪贴板失败：$($_.Exception.Message)"
        }
        return $false
    }
}

function Append-Log {
    param([string]$Text)
    $script:OutputBox.AppendText(("> " + (Get-Date -Format 'HH:mm:ss') + [Environment]::NewLine))
    $script:OutputBox.AppendText($Text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine)
}

function Show-GuiError {
    param([Parameter(Mandatory)]$ErrorRecord)

    $line = $ErrorRecord.InvocationInfo.ScriptLineNumber
    $message = $ErrorRecord.Exception.Message
    if ($line) {
        $message = "第 $line 行：$message"
    }
    Append-Log $message
    if ($SelfTest) {
        throw $message
    }
    [System.Windows.Forms.MessageBox]::Show($message, '错误', 'OK', 'Error') | Out-Null
}

function Show-MainWindow {
    if (-not $script:Form -or $script:Form.IsDisposed) { return }

    try {
        if (-not $script:Form.Visible) {
            $script:Form.Show()
        }
        $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        [void][CodexHistorySyncWindow]::ShowWindow($script:Form.Handle, [CodexHistorySyncWindow]::SW_RESTORE)
        [void][CodexHistorySyncWindow]::ShowWindow($script:Form.Handle, [CodexHistorySyncWindow]::SW_SHOWNORMAL)
        $script:Form.Activate()
        [void][CodexHistorySyncWindow]::SetForegroundWindow($script:Form.Handle)
    }
    catch {
        return
    }
}

function Test-CodexHomeReady {
    return (-not [string]::IsNullOrWhiteSpace($CodexHome)) -and
        (-not [string]::IsNullOrWhiteSpace($script:StateDb)) -and
        (Test-Path -LiteralPath $script:StateDb)
}

function Assert-CodexHomeReady {
    if (Test-CodexHomeReady) { return }

    $reason = if ($script:CodexHomeResolveError) { $script:CodexHomeResolveError } else { '尚未加载 Codex 历史记录目录。' }
    throw ($reason + "`r`n`r`n请点击 ""增加记录目录""，选择包含 state_5.sqlite 的 .codex 目录。")
}

function Show-CodexHomeHelp {
    $clipboardNote = if (Copy-TextToClipboard 'state_5.sqlite') {
        "`r`n已复制 state_5.sqlite 到剪贴板，可直接粘贴到 Everything 搜索。"
    }
    else {
        "`r`n复制 state_5.sqlite 到剪贴板失败，请手动输入 state_5.sqlite 搜索。"
    }
    [System.Windows.Forms.MessageBox]::Show(
        ((Get-CodexHomeHelpText) + $clipboardNote),
        '记录目录寻找提示',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-CcSwitchHomeHelp {
    $clipboardNote = if (Copy-TextToClipboard 'cc-switch.db') {
        "`r`n已复制 cc-switch.db 到剪贴板，可直接粘贴到 Everything 搜索。"
    }
    else {
        "`r`n复制 cc-switch.db 到剪贴板失败，请手动输入 cc-switch.db 搜索。"
    }
    [System.Windows.Forms.MessageBox]::Show(
        ((Get-CcSwitchHomeHelpText) + $clipboardNote),
        '账号目录寻找提示',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Set-CodexHomeFromSelection {
    param([Parameter(Mandatory)][string]$SelectedPath)

    $resolved = Resolve-CodexHomeFromSelection $SelectedPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "没有在所选目录或其父目录中找到 state_5.sqlite。`r`n`r`n$(Get-CodexHomeHelpText)"
    }

    $script:CodexHome = $resolved
    $script:StateDb = Join-Path $script:CodexHome 'state_5.sqlite'
    $script:CodexHomeResolveError = $null

    Append-Log "已加载 Codex 历史记录目录：$script:CodexHome"
    Refresh-Providers
    Refresh-CwdOptions
    Refresh-Threads
    if ($script:TurnEndedNotifyBox -and [bool]$script:TurnEndedNotifyBox.Checked) {
        try {
            Start-TurnCompleteMonitor
        }
        catch {
            Append-Log "启动桌面版每次完成弹窗监控失败：$($_.Exception.Message)"
        }
    }
}

function Select-CodexHomeFolder {
    $initialDirectory = $null
    if (Test-CodexHomeReady) {
        $initialDirectory = $CodexHome
    }
    elseif ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE)) {
        $initialDirectory = $env:USERPROFILE
    }

    $selected = Select-FolderPath `
        -Title '请选择 Codex 记录目录；可选 .codex、sessions 或其子目录' `
        -InitialDirectory $initialDirectory
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        Set-CodexHomeFromSelection $selected
    }
}

function Set-CcSwitchHomeFromSelection {
    param([Parameter(Mandatory)][string]$SelectedPath)

    $resolved = Resolve-CcSwitchDbFromSelection $SelectedPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "没有在所选目录或其父目录中找到 cc-switch.db。`r`n`r`n$(Get-CcSwitchHomeHelpText)"
    }

    $script:CcSwitchDb = $resolved
    $script:CcSwitchSettingsPath = Join-Path (Split-Path -Parent $script:CcSwitchDb) 'settings.json'
    Append-Log "已加载 cc-switch 账号目录：$(Split-Path -Parent $script:CcSwitchDb)"
    Refresh-Providers
}

function Select-CcSwitchHomeFolder {
    $initialDirectory = $null
    if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchDb) -and
        (Test-Path -LiteralPath $script:CcSwitchDb)) {
        $initialDirectory = Split-Path -Parent $script:CcSwitchDb
    }
    elseif (Test-Path -LiteralPath $script:RootDir) {
        $initialDirectory = $script:RootDir
    }

    $selected = Select-FolderPath `
        -Title '请选择 cc-switch 账号目录；进入包含 cc-switch.db 的文件夹后点击打开' `
        -InitialDirectory $initialDirectory
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        Set-CcSwitchHomeFromSelection $selected
    }
}

function Get-SelectedThreadId {
    if (-not $script:Grid.CurrentRow -or $script:Grid.CurrentRow.IsNewRow) { return $null }
    $column = Get-GridColumnByProperty 'Id'
    if (-not $column) { return $null }
    foreach ($cell in $script:Grid.CurrentRow.Cells) {
        if ($cell.OwningColumn -and $cell.OwningColumn.Name -eq $column.Name) {
            return [string]$cell.Value
        }
    }
    return $null
}

function Get-CurrentGridValue {
    param([Parameter(Mandatory)][string]$ColumnName)

    if (-not $script:Grid.CurrentRow -or $script:Grid.CurrentRow.IsNewRow) {
        foreach ($row in $script:Grid.Rows) {
            if (-not $row.IsNewRow) {
                $script:Grid.CurrentCell = $row.Cells[0]
                break
            }
        }
    }
    if (-not $script:Grid.CurrentRow -or $script:Grid.CurrentRow.IsNewRow) { return $null }

    $column = Get-GridColumnByProperty $ColumnName
    if (-not $column) { return $null }

    foreach ($cell in $script:Grid.CurrentRow.Cells) {
        if ($cell.OwningColumn -and $cell.OwningColumn.Name -eq $column.Name) {
            return $cell.Value
        }
    }
    return $null
}

function Resolve-LaunchDirectory {
    Assert-CodexHomeReady
    $cwd = [string](Get-CurrentGridValue 'Cwd')
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = Get-SelectedCwdFilter
    }
    $cwd = Convert-CodexPath $cwd

    if ([string]::IsNullOrWhiteSpace($cwd)) {
        throw '请先选择一条记录，或在【目录筛选】里选择一个目录。'
    }

    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        throw "目录不存在：$cwd"
    }

    return (Resolve-Path -LiteralPath $cwd).Path
}

function Get-CodexExecutable {
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $fallback = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    throw '找不到 codex.exe。请确认 Codex CLI 已安装，并且路径已加入 PATH。'
}

function Start-CodexInDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [bool]$DisableApps
    )

    $codexExe = Get-CodexExecutable
    $quotedExe = '"' + ($codexExe -replace '"', '\"') + '"'
    $command = if ($DisableApps) { "$quotedExe --disable apps" } else { $quotedExe }
    Start-Process -FilePath 'cmd.exe' `
        -WorkingDirectory $Directory `
        -ArgumentList @('/k', $command)
}

function Backup-ProviderSwitchFiles {
    param([Parameter(Mandatory)][string]$ProviderId)

    Assert-CodexHomeReady
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeProvider = $ProviderId -replace '[^A-Za-z0-9_.-]', '-'
    $backupDir = Join-Path (Join-Path $CodexHome 'backups') "codex-provider-switch-$safeProvider-$stamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    foreach ($path in @(
            (Join-Path $CodexHome 'auth.json'),
            (Join-Path $CodexHome 'config.toml'),
            $script:CcSwitchSettingsPath
        )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir (Split-Path $path -Leaf)) -Force
        }
    }

    return $backupDir
}

function Get-CcSwitchProviderForHistoryProvider {
    param([Parameter(Mandatory)][string]$HistoryProvider)

    if ($HistoryProvider -eq 'openai') {
        $sql = "select id,name,settings_config from providers where app_type='codex' and id='codex-official' limit 1;"
    }
    elseif ($HistoryProvider -eq 'custom') {
        $sql = "select id,name,settings_config from providers where app_type='codex' and name='Any Router' order by is_current desc limit 1;"
    }
    else {
        $safe = Quote-Sql $HistoryProvider
        $sql = "select id,name,settings_config from providers where app_type='codex' and (id=$safe or name=$safe) order by is_current desc limit 1;"
    }

    $rows = Invoke-CcSwitchSqlJson $sql
    if ($rows.Count -eq 0) {
        throw "找不到与历史账号 '$HistoryProvider' 对应的 cc-switch Codex provider。"
    }
    return $rows[0]
}

function Get-CcSwitchProviderById {
    param([Parameter(Mandatory)][string]$ProviderId)

    $safe = Quote-Sql $ProviderId
    $rows = Invoke-CcSwitchSqlJson "select id,name,settings_config from providers where app_type='codex' and id=$safe limit 1;"
    if ($rows.Count -eq 0) {
        throw "找不到 cc-switch Codex 节点 '$ProviderId'。请点击【增加账号目录】选择包含 cc-switch.db 的目录，然后刷新。"
    }
    return $rows[0]
}

function Test-CcSwitchOfficialProvider {
    param([Parameter(Mandatory)]$Provider)

    return ([string]$Provider.id) -eq 'codex-official'
}

function Enable-CcSwitchCodexRouteForProvider {
    param([Parameter(Mandatory)]$Provider)

    if (Test-CcSwitchOfficialProvider $Provider) { return }

    $updatedAny = $false

    if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchSettingsPath) -and
        (Test-Path -LiteralPath $script:CcSwitchSettingsPath)) {
        try {
            $appSettings = Get-Content -LiteralPath $script:CcSwitchSettingsPath -Raw | ConvertFrom-Json
            if ($appSettings -and ($appSettings.PSObject.Properties.Name -contains 'enableLocalProxy')) {
                $appSettings.enableLocalProxy = $true
                $settingsJson = $appSettings | ConvertTo-Json -Depth 100
                [System.IO.File]::WriteAllText($script:CcSwitchSettingsPath, $settingsJson, $script:Utf8NoBom)
                $updatedAny = $true
                Append-Log '已为非官方 cc switch 节点开启本地路由开关：enableLocalProxy=true。'
            }
        }
        catch {
            Append-Log "尝试开启 cc switch 本地路由开关失败：$($_.Exception.Message)"
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchDb) -and
            (Test-Path -LiteralPath $script:CcSwitchDb)) {
            $rows = @(Invoke-CcSwitchSqlJson "select count(*) as row_count from proxy_config where app_type='codex';")
            $count = if ($rows.Count -gt 0) { [int]$rows[0].row_count } else { 0 }
            if ($count -gt 0) {
                & $script:Sqlite $script:CcSwitchDb "update proxy_config set proxy_enabled=1, enabled=1, updated_at=datetime('now') where app_type='codex';"
                if ($LASTEXITCODE -ne 0) {
                    throw "sqlite3 failed with exit code $LASTEXITCODE."
                }
                $updatedAny = $true
                Append-Log '已为非官方 cc switch 节点开启 Codex 路由配置：proxy_config.codex enabled=1。'
            }
        }
    }
    catch {
        Append-Log "尝试开启 cc switch Codex 路由配置失败：$($_.Exception.Message)"
    }

    if (-not $updatedAny) {
        Append-Log '未发现可自动更新的 cc switch 路由配置；如果第三方节点需要路由，请先在 cc switch 里配置路由。'
    }
}

function ConvertTo-TomlBasicString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $escaped = $Value -replace '\\', '\\' -replace '"', '\"'
    return '"' + $escaped + '"'
}

function ConvertFrom-TomlNotifyString {
    param([Parameter(Mandatory)][string]$Token)

    $text = $Token.Trim()
    if ($text.StartsWith("'") -and $text.EndsWith("'")) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text.StartsWith('"') -and $text.EndsWith('"')) {
        $value = $text.Substring(1, $text.Length - 2)
        $value = $value -replace '\\"', '"' -replace '\\\\', '\'
        return $value
    }
    return $text
}

function Get-CodexNotifyCommand {
    param([AllowNull()][string]$Config)

    if ([string]::IsNullOrWhiteSpace($Config)) { return @() }
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $Config,
        '(?m)^\s*notify\s*=\s*\[(?<body>[^\r\n]*)\]\s*$'
    )
    if (-not $match.Success) { return @() }

    $tokens = [System.Text.RegularExpressions.Regex]::Matches(
        $match.Groups['body'].Value,
        '"(?:\\.|[^"\\])*"|''[^'']*'''
    )
    $values = @()
    foreach ($token in $tokens) {
        $values += (ConvertFrom-TomlNotifyString $token.Value)
    }
    return $values
}

function Set-CodexTurnEndedNotify {
    param([AllowNull()][string]$Config)

    if ([string]::IsNullOrWhiteSpace($script:NotifierPath) -or
        -not (Test-Path -LiteralPath $script:NotifierPath)) {
        Append-Log "未找到会话结束提醒脚本，已跳过 notify 配置：$script:NotifierPath"
        return $Config
    }

    $existingNotify = @(Get-CodexNotifyCommand $Config)
    $forwardBase64 = ''
    if ($existingNotify.Count -gt 0) {
        if (($existingNotify -join ' ') -match 'codex-turn-ended-notify\.(?:ps1|vbs)') {
            for ($i = 0; $i -lt ($existingNotify.Count - 1); $i++) {
                if ([string]$existingNotify[$i] -eq '-ForwardBase64') {
                    $forwardBase64 = [string]$existingNotify[$i + 1]
                    break
                }
            }
        }
        else {
            $json = $existingNotify | ConvertTo-Json -Compress
            $forwardBase64 = [Convert]::ToBase64String($script:Utf8NoBom.GetBytes($json))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:NotifierLauncherPath) -and
        (Test-Path -LiteralPath $script:NotifierLauncherPath)) {
        $notifyArgs = @('wscript.exe', $script:NotifierLauncherPath)
    }
    else {
        $notifyArgs = @(
            'powershell.exe',
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            $script:NotifierPath
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($forwardBase64)) {
        $notifyArgs += @('-ForwardBase64', $forwardBase64)
    }

    $notifyLine = 'notify = [ ' + (($notifyArgs | ForEach-Object { ConvertTo-TomlBasicString ([string]$_) }) -join ', ') + ' ]'
    $pattern = '(?m)^\s*notify\s*=\s*\[[^\r\n]*\]\s*$'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($Config, $pattern)) {
        $configText = [System.Text.RegularExpressions.Regex]::Replace($Config, $pattern, $notifyLine, 1)
    }
    else {
        $configText = $notifyLine + [Environment]::NewLine + $Config
    }

    $message = '已启用 Codex 会话结束右下角置顶弹窗提醒。'
    if ([string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
        $script:LastCodexConfigFix = $message
    }
    elseif ($script:LastCodexConfigFix -notmatch [regex]::Escape($message)) {
        $script:LastCodexConfigFix = $script:LastCodexConfigFix + [Environment]::NewLine + $message
    }
    return $configText
}

function Apply-TurnEndedNotifyToCurrentConfig {
    Assert-CodexHomeReady
    $configPath = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "未找到 Codex 配置文件：$configPath"
    }

    $script:LastCodexConfigFix = $null
    $configText = Get-Content -LiteralPath $configPath -Raw
    $configText = Set-CodexTurnEndedNotify $configText
    [System.IO.File]::WriteAllText($configPath, $configText, $script:Utf8NoBom)
    if (-not [string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
        Append-Log $script:LastCodexConfigFix
    }
    Append-Log "已写入每次完成弹窗 CLI notify 配置：$configPath"
}

function Show-TestTurnEndedNotify {
    if ([string]::IsNullOrWhiteSpace($script:NotifierPath) -or
        -not (Test-Path -LiteralPath $script:NotifierPath)) {
        throw "未找到会话结束提醒脚本：$script:NotifierPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($script:NotifierLauncherPath) -and
        (Test-Path -LiteralPath $script:NotifierLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $script:NotifierLauncherPath,
            '-Seconds',
            '8'
        ) -WindowStyle Hidden | Out-Null
    }
    else {
        Start-Process -FilePath powershell.exe -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            $script:NotifierPath,
            '-Seconds',
            '8'
        ) -WindowStyle Hidden | Out-Null
    }
    Append-Log '已触发测试弹窗。'
}

function Start-TurnCompleteMonitor {
    Assert-CodexHomeReady

    if ([string]::IsNullOrWhiteSpace($script:TurnCompleteMonitorPath) -or
        -not (Test-Path -LiteralPath $script:TurnCompleteMonitorPath)) {
        Append-Log "未找到桌面版完成监控脚本，已跳过：$script:TurnCompleteMonitorPath"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($script:TurnCompleteMonitorLauncherPath) -and
        (Test-Path -LiteralPath $script:TurnCompleteMonitorLauncherPath)) {
        Start-Process -FilePath wscript.exe -ArgumentList @(
            $script:TurnCompleteMonitorLauncherPath,
            '-CodexHome',
            $CodexHome,
            '-NotifierLauncherPath',
            $script:NotifierLauncherPath,
            '-NotifierPath',
            $script:NotifierPath
        ) -WindowStyle Hidden | Out-Null
    }
    else {
        Start-Process -FilePath powershell.exe -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            $script:TurnCompleteMonitorPath,
            '-CodexHome',
            $CodexHome,
            '-NotifierLauncherPath',
            $script:NotifierLauncherPath,
            '-NotifierPath',
            $script:NotifierPath
        ) -WindowStyle Hidden | Out-Null
    }

    Append-Log '已启动桌面版每次完成弹窗监控。'
}

function Normalize-CodexConfig {
    param(
        [AllowNull()][string]$Config,
        [bool]$DisableCodexAppsOnFast,
        [bool]$EnableTurnEndedNotify
    )

    $script:LastCodexConfigFix = $null
    if ($null -eq $Config) { return '' }

    $configText = $Config
    $pattern = '(?m)^(\s*service_tier\s*=\s*["''])([^"'']+)(["''])'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)

        $value = $match.Groups[2].Value.Trim().ToLowerInvariant()
        if ($value -eq 'fast' -or $value -eq 'flex') {
            return $match.Value
        }

        $script:LastCodexConfigFix = "已将不兼容的 service_tier='$value' 修正为 'fast'。"
        return $match.Groups[1].Value + 'fast' + $match.Groups[3].Value
    }

    $configText = [System.Text.RegularExpressions.Regex]::Replace($configText, $pattern, $evaluator)

    if ($DisableCodexAppsOnFast -and ((Get-CodexServiceTier $configText) -eq 'fast')) {
        $configText = Disable-CodexAppsPlugins $configText
        if ($script:LastDisabledCodexAppsPluginCount -gt 0) {
            $message = "已在 fast 模式下禁用 $($script:LastDisabledCodexAppsPluginCount) 个 Codex Apps 插件，避免官网登录授权不完整时触发 Apps 连接错误。"
            if ([string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
                $script:LastCodexConfigFix = $message
            }
            else {
                $script:LastCodexConfigFix = $script:LastCodexConfigFix + [Environment]::NewLine + $message
            }
        }
    }

    if ($EnableTurnEndedNotify) {
        $configText = Set-CodexTurnEndedNotify $configText
    }

    return $configText
}

function Get-CodexServiceTier {
    param([AllowNull()][string]$Config)

    if ([string]::IsNullOrWhiteSpace($Config)) { return '' }
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $Config,
        '(?m)^\s*service_tier\s*=\s*["'']([^"'']+)["'']'
    )
    if (-not $match.Success) { return '' }
    return $match.Groups[1].Value.Trim().ToLowerInvariant()
}

function Disable-CodexAppsPlugins {
    param([AllowNull()][string]$Config)

    $script:LastDisabledCodexAppsPluginCount = 0
    if ([string]::IsNullOrWhiteSpace($Config)) { return $Config }

    $pattern = '(?ms)(^\[plugins\."[^"]+@(?:openai-curated(?:-remote)?|openai-primary-runtime|openai-bundled)"\]\s*\r?\n)(.*?)(?=^\[|\z)'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)

        $header = $match.Groups[1].Value
        $body = $match.Groups[2].Value
        if ($body -match '(?m)^\s*enabled\s*=\s*false\s*$') {
            return $match.Value
        }

        $script:LastDisabledCodexAppsPluginCount++
        if ($body -match '(?m)^\s*enabled\s*=') {
            $enabledEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
                param($enabledMatch)
                return $enabledMatch.Groups[1].Value + ' false'
            }
            $body = [System.Text.RegularExpressions.Regex]::Replace(
                $body,
                '(?m)^(\s*enabled\s*=).*$',
                $enabledEvaluator
            )
        }
        else {
            $body = "enabled = false" + [Environment]::NewLine + $body
        }

        return $header + $body
    }

    return [System.Text.RegularExpressions.Regex]::Replace($Config, $pattern, $evaluator)
}

function Switch-CodexProviderForHistoryProvider {
    param([Parameter(Mandatory)][string]$HistoryProvider)

    $provider = Get-CcSwitchProviderForHistoryProvider $HistoryProvider
    return Switch-CodexProviderRow $provider
}

function Switch-CodexProviderById {
    param([Parameter(Mandatory)][string]$ProviderId)

    $provider = Get-CcSwitchProviderById $ProviderId
    return Switch-CodexProviderRow $provider
}

function Switch-CodexProviderRow {
    param([Parameter(Mandatory)]$Provider)

    Assert-CodexHomeReady
    $provider = $Provider
    $settings = [string]$provider.settings_config | ConvertFrom-Json
    if (-not $settings) {
        throw "provider '$($provider.name)' 的 settings_config 无法解析。"
    }

    $backupDir = Backup-ProviderSwitchFiles ([string]$provider.id)

    $authPath = Join-Path $CodexHome 'auth.json'
    $configPath = Join-Path $CodexHome 'config.toml'
    $authJson = '{}'
    if ($settings.auth) {
        $authJson = $settings.auth | ConvertTo-Json -Depth 100 -Compress
    }
    $disableCodexAppsOnFast = $script:DisableCodexAppsBox -and [bool]$script:DisableCodexAppsBox.Checked
    $enableTurnEndedNotify = $script:TurnEndedNotifyBox -and [bool]$script:TurnEndedNotifyBox.Checked
    $configText = Normalize-CodexConfig ([string]$settings.config) `
        -DisableCodexAppsOnFast:$disableCodexAppsOnFast `
        -EnableTurnEndedNotify:$enableTurnEndedNotify
    [System.IO.File]::WriteAllText($authPath, $authJson, $script:Utf8NoBom)
    [System.IO.File]::WriteAllText($configPath, $configText, $script:Utf8NoBom)
    if (-not [string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
        Append-Log $script:LastCodexConfigFix
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchSettingsPath) -and
        (Test-Path -LiteralPath $script:CcSwitchSettingsPath)) {
        $appSettings = Get-Content -LiteralPath $script:CcSwitchSettingsPath -Raw | ConvertFrom-Json
        $appSettings.currentProviderCodex = [string]$provider.id
        $settingsJson = $appSettings | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($script:CcSwitchSettingsPath, $settingsJson, $script:Utf8NoBom)
    }

    $idSql = Quote-Sql ([string]$provider.id)
    & $script:Sqlite $script:CcSwitchDb "update providers set is_current = case when id = $idSql and app_type = 'codex' then 1 else 0 end where app_type = 'codex';"
    if ($LASTEXITCODE -ne 0) {
        throw "更新 cc-switch 当前 Codex provider 失败。"
    }

    Enable-CcSwitchCodexRouteForProvider $provider
    Append-Log "已切换 cc switch 节点：$($provider.name)。备份：$backupDir"
    return $provider
}

function Invoke-LaunchForProvider {
    param([Parameter(Mandatory)]$Combo)

    $providerLabel = [string]$Combo.SelectedItem
    $providerId = Resolve-CcSwitchProviderId $providerLabel
    if ([string]::IsNullOrWhiteSpace($providerId)) {
        throw '请先选择账号。'
    }
    $directory = Resolve-LaunchDirectory

    Switch-CodexProviderById $providerId | Out-Null
    $disableApps = $script:DisableCodexAppsBox -and [bool]$script:DisableCodexAppsBox.Checked -and ((Get-CodexServiceTier (Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw)) -eq 'fast')
    Start-CodexInDirectory -Directory $directory -DisableApps:$disableApps
    if ($disableApps) {
        Append-Log "已用 $providerLabel CMD启动 Codex，并追加 --disable apps：$directory"
    }
    else {
        Append-Log "已用 $providerLabel CMD启动 Codex：$directory"
    }
}

function Get-CheckedThreadIds {
    [void]$script:Grid.EndEdit()
    $ids = New-Object System.Collections.Generic.List[string]
    $selectedColumn = Get-GridColumnByProperty 'Selected'
    $idColumn = Get-GridColumnByProperty 'Id'
    if (-not $selectedColumn -or -not $idColumn) { return $ids }

    foreach ($row in $script:Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $isChecked = [bool]$row.Cells[$selectedColumn.Index].Value
        if ($isChecked) {
            $id = [string]$row.Cells[$idColumn.Index].Value
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $ids.Add($id.Trim())
            }
        }
    }
    return $ids.ToArray()
}

function Set-AllRowsChecked {
    param([bool]$Checked)

    $selectedColumn = Get-GridColumnByProperty 'Selected'
    if (-not $selectedColumn) { return }

    foreach ($row in $script:Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $row.Cells[$selectedColumn.Index].Value = $Checked
    }
}

function Get-GridColumnByProperty {
    param([Parameter(Mandatory)][string]$PropertyName)

    foreach ($column in $script:Grid.Columns) {
        if ([string]::Equals([string]$column.Name, $PropertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $column
        }
    }
    return $null
}

function Invoke-SyncCli {
    param(
        [string[]]$CommandArgs,
        [switch]$SkipConfirm,
        [switch]$NoRefresh
    )

    Assert-CodexHomeReady
    if (-not $SkipConfirm) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            '即将写入 Codex 历史文件和 state_5.sqlite。工具会先创建备份。是否继续？',
            '确认写入',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Append-Log '已取消。'
            return
        }
    }

    $allArgs = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $CommandArgs) { $allArgs.Add($arg) }
    $allArgs.Add('-CodexHome')
    $allArgs.Add($CodexHome)
    $actionName = $null
    foreach ($arg in $CommandArgs) {
        $actionName = $arg
        break
    }
    $cwdFilter = Get-SelectedCwdFilter
    if (($actionName -eq 'sync' -or $actionName -eq 'mirror') -and
        -not [string]::IsNullOrWhiteSpace($cwdFilter)) {
        $allArgs.Add('-Cwd')
        $allArgs.Add($cwdFilter)
    }
    if ($script:IncludeArchivedBox.Checked) { $allArgs.Add('-IncludeArchived') }

    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $cmdLine = $script:CliPath + ' ' + (($allArgs | ForEach-Object {
                    if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
                }) -join ' ')
        Append-Log $cmdLine
        $output = & $script:CliPath @allArgs 2>&1 | Out-String
        Append-Log $output
        if (-not $NoRefresh) {
            Refresh-Providers
            Refresh-Threads
        }
    }
    catch {
        Show-GuiError $_
    }
    finally {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Refresh-Providers {
    $oldSuppress = $script:SuppressThreadRefresh
    try {
        $ccSwitchProviders = @(Get-CcSwitchCodexProviders)
        Reset-CcSwitchAccountCombo $ccSwitchProviders

        if (-not (Test-CodexHomeReady)) {
            if ($script:SourceCombo) { $script:SourceCombo.Items.Clear() }
            if ($script:TargetCombo) { $script:TargetCombo.Items.Clear() }
            if ($script:StatusLabel) { $script:StatusLabel.Text = '请先选择 Codex 历史记录目录' }
            if ($script:CodexHomeResolveError) { Append-Log $script:CodexHomeResolveError }
            return
        }

        $script:SuppressThreadRefresh = $true
        $currentSource = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $currentTarget = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        $providers = Get-Providers

        $script:ProviderLabelToValue = @{}
        foreach ($provider in $providers) {
            $label = Get-ProviderLabel $provider
            if ($script:ProviderLabelToValue.ContainsKey($label)) {
                $script:ProviderLabelToValue.Remove($label)
            }
            $script:ProviderLabelToValue.Add($label, $provider)
        }

        Reset-ProviderCombo $script:SourceCombo $providers $(if ($currentSource) { $currentSource } else { 'openai' })
        Reset-ProviderCombo $script:TargetCombo $providers $(if ($currentTarget) { $currentTarget } else { 'custom' })
    }
    catch {
        Append-Log $_.Exception.Message
    }
    finally {
        $script:SuppressThreadRefresh = $oldSuppress
    }
}

function Refresh-CwdOptions {
    try {
        if (-not $script:CwdCombo) { return }

        $oldSuppress = $script:SuppressThreadRefresh
        $script:SuppressThreadRefresh = $true
        $currentCwd = Get-SelectedCwdFilter
        $provider = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)

        $script:CwdCombo.Items.Clear()
        [void]$script:CwdCombo.Items.Add($script:AllCwdLabel)

        if ((Test-CodexHomeReady) -and -not [string]::IsNullOrWhiteSpace($provider)) {
            $paths = Get-CwdOptions -Provider $provider -IncludeArchived ([bool]$script:IncludeArchivedBox.Checked)
            foreach ($path in $paths) {
                [void]$script:CwdCombo.Items.Add($path)
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($currentCwd) -and $script:CwdCombo.Items.Contains($currentCwd)) {
            $script:CwdCombo.SelectedItem = $currentCwd
        }
        else {
            $script:CwdCombo.SelectedItem = $script:AllCwdLabel
        }
    }
    catch {
        Append-Log $_.Exception.Message
    }
    finally {
        $script:SuppressThreadRefresh = $oldSuppress
    }
}

function Refresh-Threads {
    try {
        if (-not (Test-CodexHomeReady)) {
            $script:LastThreadTableCount = 0
            if ($script:Grid) { $script:Grid.Rows.Clear() }
            if ($script:StatusLabel) { $script:StatusLabel.Text = '请先选择 Codex 历史记录目录' }
            return
        }

        $provider = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        if ([string]::IsNullOrWhiteSpace($provider)) { return }

        $cwdFilter = Get-SelectedCwdFilter
        $items = @(Get-ThreadRows `
            -Provider $provider `
            -Limit ([int]$script:LimitBox.Value) `
            -IncludeArchived ([bool]$script:IncludeArchivedBox.Checked) `
            -CwdFilter $cwdFilter)

        $script:LastThreadTableCount = $items.Count
        $script:Grid.DataSource = $null
        $script:Grid.Rows.Clear()
        foreach ($row in $items) {
            [void]$script:Grid.Rows.Add(
                $false,
                [string]$row.Updated,
                [string]$row.Provider,
                [bool]$row.Archived,
                [string]$row.Id,
                [string]$row.Cwd,
                [string]$row.Title
            )
        }
        $widths = @{
            Selected = 56
            Updated  = 110
            Provider = 80
            Archived = 80
            Id       = 260
            Cwd      = 260
        }
        foreach ($key in $widths.Keys) {
            $column = Get-GridColumnByProperty $key
            if ($column) {
                $column.Width = $widths.Get_Item($key)
            }
        }
        $titleColumn = Get-GridColumnByProperty 'Title'
        if ($titleColumn) {
            $titleColumn.AutoSizeMode = 'Fill'
        }
        $headers = @{
            Selected = '选择'
            Updated  = '更新时间'
            Provider = '账号'
            Archived = '已归档'
            Id       = '线程 ID'
            Cwd      = '工作目录'
            Title    = '标题'
        }
        foreach ($key in $headers.Keys) {
            $column = Get-GridColumnByProperty $key
            if ($column) {
                $column.HeaderText = $headers.Get_Item($key)
            }
        }
        $script:StatusLabel.Text = "记录数：$($items.Count)"
        Append-Log "已加载 $($items.Count) 条记录：$(Get-ProviderLabel $provider)"
    }
    catch {
        Show-GuiError $_
    }
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Codex 历史记录同步'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = New-Object System.Drawing.Size(1200, 760)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1100, 640)
$script:Form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$script:Form.Controls.Add((New-Label 'Codex源账号' 12 14 88))
$script:SourceCombo = New-Object System.Windows.Forms.ComboBox
$script:SourceCombo.DropDownStyle = 'DropDownList'
$script:SourceCombo.Location = New-Object System.Drawing.Point(104, 12)
$script:SourceCombo.Size = New-Object System.Drawing.Size(120, 24)
$script:Form.Controls.Add($script:SourceCombo)

$script:Form.Controls.Add((New-Label 'Codex目标账号' 240 14 96))
$script:TargetCombo = New-Object System.Windows.Forms.ComboBox
$script:TargetCombo.DropDownStyle = 'DropDownList'
$script:TargetCombo.Location = New-Object System.Drawing.Point(340, 12)
$script:TargetCombo.Size = New-Object System.Drawing.Size(120, 24)
$script:Form.Controls.Add($script:TargetCombo)

$swapButton = New-Button '交换' 472 10 58
$script:Form.Controls.Add($swapButton)

$script:Form.Controls.Add((New-Label '显示条数' 548 14 62))
$script:LimitBox = New-Object System.Windows.Forms.NumericUpDown
$script:LimitBox.Location = New-Object System.Drawing.Point(614, 12)
$script:LimitBox.Size = New-Object System.Drawing.Size(60, 24)
$script:LimitBox.Minimum = 1
$script:LimitBox.Maximum = 1000
$script:LimitBox.Value = 50
$script:Form.Controls.Add($script:LimitBox)

$script:IncludeArchivedBox = New-Object System.Windows.Forms.CheckBox
$script:IncludeArchivedBox.Text = '包含归档'
$script:IncludeArchivedBox.Location = New-Object System.Drawing.Point(692, 13)
$script:IncludeArchivedBox.Size = New-Object System.Drawing.Size(88, 22)
$script:Form.Controls.Add($script:IncludeArchivedBox)

$script:Form.Controls.Add((New-Label '目录筛选' 12 52 70))
$script:CwdCombo = New-Object System.Windows.Forms.ComboBox
$script:CwdCombo.DropDownStyle = 'DropDownList'
$script:CwdCombo.Location = New-Object System.Drawing.Point(86, 50)
$script:CwdCombo.Size = New-Object System.Drawing.Size(230, 24)
$script:CwdCombo.DropDownWidth = 900
$script:Form.Controls.Add($script:CwdCombo)

$refreshButton = New-Button '刷新' 792 10 58
$selectAllButton = New-Button '全选' 334 47 54
$clearSelectionButton = New-Button '清空' 396 47 54
$cloneButton = New-Button '同步勾选' 458 47 82
$syncButton = New-Button '同步全部' 548 47 82
$mirrorButton = New-Button '双向同步' 638 47 84
$selectCodexHomeButton = New-Button '增加记录目录' 734 47 112
$codexHomeHelpButton = New-Button '记录目录寻找提示' 854 47 136
$script:Form.Controls.Add($selectCodexHomeButton)
$script:Form.Controls.Add($codexHomeHelpButton)
$script:Form.Controls.Add($refreshButton)
$script:Form.Controls.Add($selectAllButton)
$script:Form.Controls.Add($clearSelectionButton)
$script:Form.Controls.Add($cloneButton)
$script:Form.Controls.Add($syncButton)
$script:Form.Controls.Add($mirrorButton)

$script:Grid = New-Object System.Windows.Forms.DataGridView
$openCodexFolderButton = New-Button '打开.codex 目录' 862 10 122
$openRecordFolderButton = New-Button '打开记录目录' 754 83 120
$script:Form.Controls.Add($openCodexFolderButton)

$script:Form.Controls.Add((New-Label 'cc switch节点' 12 88 86))
$script:CodexProviderCombo = New-Object System.Windows.Forms.ComboBox
$script:CodexProviderCombo.DropDownStyle = 'DropDownList'
$script:CodexProviderCombo.Location = New-Object System.Drawing.Point(104, 86)
$script:CodexProviderCombo.Size = New-Object System.Drawing.Size(190, 24)
$script:Form.Controls.Add($script:CodexProviderCombo)
$openCodexButton = New-Button 'CMD启动' 302 83 82
$script:Form.Controls.Add($openCodexButton)

$script:DisableCodexAppsBox = New-Object System.Windows.Forms.CheckBox
$script:DisableCodexAppsBox.Text = 'fast 关闭 Apps MCP'
$script:DisableCodexAppsBox.Location = New-Object System.Drawing.Point(394, 87)
$script:DisableCodexAppsBox.Size = New-Object System.Drawing.Size(142, 22)
$script:DisableCodexAppsBox.Checked = $true
$script:Form.Controls.Add($script:DisableCodexAppsBox)

$script:TurnEndedNotifyBox = New-Object System.Windows.Forms.CheckBox
$script:TurnEndedNotifyBox.Text = '每次完成弹窗'
$script:TurnEndedNotifyBox.Location = New-Object System.Drawing.Point(542, 87)
$script:TurnEndedNotifyBox.Size = New-Object System.Drawing.Size(116, 22)
$script:TurnEndedNotifyBox.Checked = $true
$script:Form.Controls.Add($script:TurnEndedNotifyBox)

$testNotifyButton = New-Button '测试弹窗' 664 83 82
$selectCcSwitchHomeButton = New-Button '增加账号目录' 882 83 112
$ccSwitchHomeHelpButton = New-Button '账号目录寻找提示' 1002 83 136
$script:Form.Controls.Add($testNotifyButton)
$script:Form.Controls.Add($openRecordFolderButton)
$script:Form.Controls.Add($selectCcSwitchHomeButton)
$script:Form.Controls.Add($ccSwitchHomeHelpButton)

$script:Grid.Location = New-Object System.Drawing.Point(12, 122)
$script:Grid.Size = New-Object System.Drawing.Size(1150, 374)
$script:Grid.Anchor = 'Top,Left,Right,Bottom'
$script:Grid.ReadOnly = $false
$script:Grid.MultiSelect = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.RowHeadersVisible = $false
$script:Grid.AutoGenerateColumns = $false
$script:Grid.EditMode = 'EditOnEnter'
$gridColumns = @(
    @{ Name = 'Selected'; Header = '选择'; Width = 56; Type = 'Check'; Editable = $true },
    @{ Name = 'Updated'; Header = '更新时间'; Width = 110; Type = 'Text' },
    @{ Name = 'Provider'; Header = '账号'; Width = 80; Type = 'Text' },
    @{ Name = 'Archived'; Header = '已归档'; Width = 80; Type = 'Check' },
    @{ Name = 'Id'; Header = '线程 ID'; Width = 260; Type = 'Text' },
    @{ Name = 'Cwd'; Header = '工作目录'; Width = 260; Type = 'Text' },
    @{ Name = 'Title'; Header = '标题'; Width = 280; Type = 'Text'; Fill = $true }
)
foreach ($definition in $gridColumns) {
    if ($definition.Type -eq 'Check') {
        $column = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    }
    else {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    }
    $column.Name = $definition.Name
    $column.DataPropertyName = $definition.Name
    $column.HeaderText = $definition.Header
    $column.Width = $definition.Width
    $column.ReadOnly = -not [bool]$definition.Editable
    if ($definition.Fill) {
        $column.AutoSizeMode = 'Fill'
    }
    [void]$script:Grid.Columns.Add($column)
}
$script:Form.Controls.Add($script:Grid)

$script:OutputBox = New-Object System.Windows.Forms.TextBox
$script:OutputBox.Location = New-Object System.Drawing.Point(12, 506)
$script:OutputBox.Size = New-Object System.Drawing.Size(1150, 170)
$script:OutputBox.Anchor = 'Left,Right,Bottom'
$script:OutputBox.Multiline = $true
$script:OutputBox.ReadOnly = $true
$script:OutputBox.ScrollBars = 'Vertical'
$script:OutputBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.Controls.Add($script:OutputBox)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Location = New-Object System.Drawing.Point(12, 686)
$script:StatusLabel.Size = New-Object System.Drawing.Size(1150, 24)
$script:StatusLabel.Anchor = 'Left,Right,Bottom'
$script:StatusLabel.Text = '就绪'
$script:Form.Controls.Add($script:StatusLabel)

$selectCodexHomeButton.Add_Click({
        try {
            Select-CodexHomeFolder
        }
        catch {
            Show-GuiError $_
        }
    })

$codexHomeHelpButton.Add_Click({ Show-CodexHomeHelp })

$selectCcSwitchHomeButton.Add_Click({
        try {
            Select-CcSwitchHomeFolder
        }
        catch {
            Show-GuiError $_
        }
    })

$ccSwitchHomeHelpButton.Add_Click({ Show-CcSwitchHomeHelp })

$refreshButton.Add_Click({
        Refresh-Providers
        Refresh-CwdOptions
        Refresh-Threads
    })

$selectAllButton.Add_Click({ Set-AllRowsChecked $true })

$clearSelectionButton.Add_Click({ Set-AllRowsChecked $false })

$swapButton.Add_Click({
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        if ($target) { Select-Provider $script:SourceCombo $target }
        if ($source) { Select-Provider $script:TargetCombo $source }
        Refresh-CwdOptions
        Refresh-Threads
    })

$cloneButton.Add_Click({
        $ids = @(Get-CheckedThreadIds)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('请先勾选要同步的记录。', '未勾选记录', 'OK', 'Information') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show('请先选择 Codex目标账号。', '未选择 Codex目标账号', 'OK', 'Information') | Out-Null
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "即将同步 $($ids.Count) 条勾选记录到 $(Get-ProviderLabel $target)。工具会先创建备份。是否继续？",
            '确认同步勾选记录',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Append-Log '已取消。'
            return
        }

        foreach ($id in $ids) {
            Invoke-SyncCli -CommandArgs @('clone', '-Id', $id, '-To', $target) -SkipConfirm -NoRefresh
        }
        Refresh-Providers
        Refresh-Threads
    })

$syncButton.Add_Click({
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show('请先选择 Codex源账号和 Codex目标账号。', '账号不完整', 'OK', 'Information') | Out-Null
            return
        }
        Invoke-SyncCli -CommandArgs @('sync', '-From', $source, '-To', $target)
    })

$mirrorButton.Add_Click({
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show('请先选择两个 Codex 历史记录账号。', '账号不完整', 'OK', 'Information') | Out-Null
            return
        }
        Invoke-SyncCli -CommandArgs @('mirror', '-Providers', "$source,$target")
    })

$openCodexFolderButton.Add_Click({
        try {
            Assert-CodexHomeReady
            Start-Process -FilePath explorer.exe -ArgumentList $CodexHome
            Append-Log "已打开 .codex 目录：$CodexHome"
        }
        catch {
            Show-GuiError $_
        }
    })

$openRecordFolderButton.Add_Click({
        try {
            $directory = Resolve-LaunchDirectory
            Start-Process -FilePath explorer.exe -ArgumentList $directory
            Append-Log "已打开记录目录：$directory"
        }
        catch {
            Show-GuiError $_
        }
    })

$openCodexButton.Add_Click({
        try {
            Invoke-LaunchForProvider -Combo $script:CodexProviderCombo
        }
        catch {
            Show-GuiError $_
        }
    })

$testNotifyButton.Add_Click({
        try {
            Apply-TurnEndedNotifyToCurrentConfig
            Start-TurnCompleteMonitor
            Show-TestTurnEndedNotify
        }
        catch {
            Show-GuiError $_
        }
    })

$script:SourceCombo.Add_SelectedIndexChanged({
        if (-not $script:SuppressThreadRefresh) {
            Refresh-CwdOptions
            Refresh-Threads
        }
    })
$script:IncludeArchivedBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Refresh-CwdOptions
            Refresh-Threads
        }
    })
$script:LimitBox.Add_ValueChanged({
        if (-not $script:SuppressThreadRefresh) { Refresh-Threads }
    })
$script:CwdCombo.Add_SelectedIndexChanged({
        if (-not $script:SuppressThreadRefresh) { Refresh-Threads }
    })

$script:Grid.Add_CurrentCellDirtyStateChanged({
        if ($script:Grid.IsCurrentCellDirty) {
            [void]$script:Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

Refresh-Providers
Refresh-CwdOptions
$script:SuppressThreadRefresh = $false
Refresh-Threads
Append-Log '界面已加载。'
if (Test-CodexHomeReady) {
    Append-Log "Codex 记录目录：$CodexHome"
}
else {
    Append-Log ("尚未加载 Codex 记录目录。请点击 ""增加记录目录""。" + "`r`n`r`n" + (Get-CodexHomeHelpText))
}
if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb)) {
    Append-Log ("未找到 cc-switch.db：历史同步可用，切换账号启动功能不可用。请点击 ""增加账号目录""，选择包含 cc-switch.db 的目录。" + "`r`n`r`n" + (Get-CcSwitchHomeHelpText))
}
else {
    Append-Log "cc-switch 数据库：$script:CcSwitchDb"
}

if ($SelfTest) {
    Set-AllRowsChecked $true
    $checkedIds = @(Get-CheckedThreadIds)
    $codexAccounts = @()
    for ($i = 0; $i -lt $script:CodexProviderCombo.Items.Count; $i++) {
        $codexAccounts += [string]$script:CodexProviderCombo.Items[$i]
    }
    $ccRows = @(Get-CcSwitchCodexProviders)
    $ccNames = @()
    foreach ($row in $ccRows) { $ccNames += [string]$row.name }
    Write-Output "SelfTest OK. QueryRows: $($script:LastThreadTableCount). GridRows: $($script:Grid.Rows.Count). Checked: $($checkedIds.Count). Source: $($script:SourceCombo.SelectedItem). Target: $($script:TargetCombo.SelectedItem). CcSwitchDb: $script:CcSwitchDb. CcSwitchRows: $($ccRows.Count) [$($ccNames -join ', ')]. CodexAccountCount: $($script:CodexProviderCombo.Items.Count). CodexAccounts: $($codexAccounts -join ', '). IDs: $($checkedIds -join ', ')"
    return
}

if ($script:TurnEndedNotifyBox.Checked -and (Test-CodexHomeReady)) {
    try {
        Apply-TurnEndedNotifyToCurrentConfig
        Start-TurnCompleteMonitor
    }
    catch {
        Append-Log "自动启用每次完成弹窗失败：$($_.Exception.Message)"
    }
}

$script:InitialShowTimer = New-Object System.Windows.Forms.Timer
$script:InitialShowTimer.Interval = 300
$script:InitialShowTimer.Add_Tick({
        $script:InitialShowTimer.Stop()
        Show-MainWindow
        $script:InitialShowTimer.Dispose()
    })
$script:InitialShowTimer.Start()

[void][System.Windows.Forms.Application]::Run($script:Form)
