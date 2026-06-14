param(
    [string]$CodexHome,
    [string]$CcSwitchHome,
    [switch]$SelfTest,
    [string]$SelfTestSourceProvider
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
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$script:AppVersion = '2026.06.14.04'
$script:AppAuthor = 'Joff Pan'
$script:GitHubRepo = 'zhuofupan/codex-history-sync-portable'
$script:GitHubUrl = "https://github.com/$script:GitHubRepo"
$script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RootDir = Split-Path -Parent $script:ToolDir
$script:CliPath = Join-Path $script:RootDir 'codex-history-sync.cmd'
$script:NotifierPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.ps1'
$script:NotifierLauncherPath = Join-Path $script:ToolDir 'codex-turn-ended-notify.vbs'
$script:TurnCompleteMonitorPath = Join-Path $script:ToolDir 'codex-turn-complete-monitor.ps1'
$script:TurnCompleteMonitorLauncherPath = Join-Path $script:ToolDir 'codex-turn-complete-monitor.vbs'
$script:ConfigTemplatePath = Join-Path $script:RootDir 'codex-history-sync-config.template.json'
$script:AutoConfigPath = Join-Path $script:RootDir 'codex-history-sync-config.json'
$script:ConfiguredCodexExe = $null
$script:SuppressStateSave = $false
$script:ConfigWatcher = $null
$script:ConfigReloadTimer = $null
$script:ConfigReloadInProgress = $false
$script:ConfigPreferenceSaveInProgress = $false
$script:IgnoreConfigWatcherUntil = [datetime]::MinValue
$script:ConfigWatcherLastWriteUtc = [datetime]::MinValue
$script:DisableCodexAppsOnFast = $true
$script:GuiInstanceMutex = $null
$script:HelpForm = $null
$script:CodexSupportsBypassFullAccess = $null
$script:DiagnosticSessionId = [guid]::NewGuid().ToString('N')

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

$script:LastStateDir = Join-OptionalPath $env:APPDATA 'codex-history-sync-portable'
if ([string]::IsNullOrWhiteSpace($script:LastStateDir)) {
    $script:LastStateDir = Join-Path $script:RootDir '.local-state'
}
$script:LastStatePath = Join-Path $script:LastStateDir 'last-state.json'
$script:DiagnosticLogPath = Join-Path $script:LastStateDir 'diagnostic.log'

if (-not $SelfTest) {
    $createdNew = $false
    $script:GuiInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\CodexHistorySyncPortableGui', [ref]$createdNew)
    if (-not $createdNew) {
        [System.Windows.Forms.MessageBox]::Show(
            'Codex 历史记录同步已经在运行。请使用已打开的窗口，避免重复启动。后台弹窗提醒监控会单独保持运行。',
            '已经在运行',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
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
点击【加载codex账号】时，请选择包含 state_5.sqlite 的 .codex 文件夹。

常见位置：
1. C:\Users\<你的用户名>\.codex
2. 环境变量 CODEX_HOME 指向的目录
3. 便携或迁移环境中，可能在你手动设置过的 .codex 目录

判断是否选对：
- 目录里应该能看到 state_5.sqlite
- 通常还会有 sessions 文件夹
- sessions 下面会按年份、月份保存 rollout-*.jsonl 聊天记录文件

找不到时可以用 Everything 搜索 state_5.sqlite；它所在的目录就是要加载的 codex 账号目录。

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
            (Join-Path (Split-Path -Parent $script:RootDir) 'cc-switch\cc-switch.db'),
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
请选择 cc-switch.db 文件、同结构 .db 文件，或选择包含 cc-switch.db 的目录。

常见位置：
1. cc-switch.exe 所在目录
2. 你解压或安装 cc-switch 的目录，例如 C:\Tools\cc-switch
3. %LOCALAPPDATA%\cc-switch 或 %APPDATA%\cc-switch

如果自动加载不到新增账号：
- 先在 cc-switch 里确认已经新增并保存 Codex 节点
- 回到本工具点击【刷新】
- 仍然没有时，点击【加载cc-switch.db文件】，选择 cc-switch.db 或同结构 .db 文件

找不到时可以用 Everything 搜索 cc-switch.db，然后选择这个文件所在的目录或对应数据库文件。
"@
}

function Resolve-CcSwitchDbFromSelection {
    param([AllowNull()][string]$SelectedPath)

    if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return $null }
    $path = Convert-CodexPath $SelectedPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $leaf = Split-Path -Leaf $path
        $extension = [System.IO.Path]::GetExtension($leaf)
        if ($leaf -ieq 'cc-switch.db' -or $extension -ieq '.db') {
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
$script:UiLanguage = 'zh-CN'
$script:WindowWidthByLanguage = @{
    'zh-CN' = 1320
    'en-US' = 1320
}
$script:RestoringLanguageWindowWidth = $false
$script:UiStrings = @{
    'zh-CN' = @{
        AllFolders           = '全部目录'
        FormTitle            = 'Codex 历史记录同步'
        HeaderTitle          = 'Codex 历史记录同步'
        HeaderSubtitle       = '本地记录迁移、节点启动和完成提醒'
        AuthorLabel          = '作者'
        LanguageLabel        = '语言'
        GroupHistory         = '历史筛选'
        GroupSync            = '同步操作'
        GroupPath            = '目录与配置'
        GroupLaunch          = '启动与提醒'
        GroupSupport         = '帮助与更新'
        SourceProvider       = 'Codex源账号'
        TargetProvider       = 'Codex目标账号'
        DirectoryFilter      = '目录筛选'
        DisplayLimit         = '显示条数'
        CcSwitchProvider     = 'cc-switch供应商'
        Archived             = '显示归档'
        Refresh              = '刷新'
        SelectAll            = '全选'
        ClearSelection       = '清空'
        CloneChecked         = '同步勾选'
        SyncAll              = '同步全部'
        Mirror               = '双向同步'
        Swap                 = '交换'
        AddHistory           = '加载codex账号'
        OpenChatDir          = '打开聊天内容'
        CodexDir             = 'codex目录'
        ImportCcConfig       = '加载cc-switch.db文件'
        Settings             = '软件配置文件'
        LaunchTerminal       = '从终端启动'
        LoadCheckedRecord    = '启动时加载聊天'
        PowerShellLaunch     = 'PowerShell启动'
        ApprovalNeverLaunch  = '完全访问(-a never)'
        CompletionPopup      = '弹窗提醒'
        TestPopup            = '测试弹窗'
        Help                 = '帮助'
        CheckUpdate          = '检查更新'
        GridSelect           = '选择'
        GridUpdated          = '更新时间'
        GridProvider         = '账号'
        GridArchived         = '已归档'
        GridThreadId         = '线程 ID'
        GridCwd              = '项目目录'
        GridTitle            = '聊天内容'
        GridRollout          = '记录文件'
        MenuOpenChatDir      = '打开聊天内容'
        MenuOpenWorkspace    = '打开项目目录'
        MenuCopyCell         = '复制此单元格'
        MenuCheckOnly        = '只勾选此条'
        MenuCheckExcept      = '勾选此外所有条'
        MenuLaunchTerminal   = '启动终端'
        MenuLaunchWithChat   = '启动终端（+聊天）'
        MenuSyncTo           = '同步此条至'
        MenuSyncCurrent      = '同步此条至'
        MenuSyncChecked      = '同步勾选'
        MenuSyncAll          = '同步全部'
        StatusReady          = '就绪'
    }
    'en-US' = @{
        AllFolders           = 'All folders'
        FormTitle            = 'Codex History Sync'
        HeaderTitle          = 'Codex History Sync'
        HeaderSubtitle       = 'Local history migration, provider launch, completion alerts'
        AuthorLabel          = 'Author'
        LanguageLabel        = 'Language'
        GroupHistory         = 'History Filter'
        GroupSync            = 'Sync Actions'
        GroupPath            = 'Paths and Config'
        GroupLaunch          = 'Launch and Alerts'
        GroupSupport         = 'Help and Update'
        SourceProvider       = 'Codex Source'
        TargetProvider       = 'Codex Target'
        DirectoryFilter      = 'Directory'
        DisplayLimit         = 'Rows'
        CcSwitchProvider     = 'cc-switch Provider'
        Archived             = 'Show Archived'
        Refresh              = 'Refresh'
        SelectAll            = 'Select All'
        ClearSelection       = 'Clear'
        CloneChecked         = 'Sync Checked'
        SyncAll              = 'Sync All'
        Mirror               = 'Two-way Sync'
        Swap                 = 'Swap'
        AddHistory           = 'Load Codex Account'
        OpenChatDir          = 'Open Chat Content'
        CodexDir             = 'Codex Dir'
        ImportCcConfig       = 'Load cc-switch.db'
        Settings             = 'Software Config'
        LaunchTerminal       = 'Launch Terminal'
        LoadCheckedRecord    = 'Load Chat on Launch'
        PowerShellLaunch     = 'PowerShell'
        ApprovalNeverLaunch  = 'Full Access (-a never)'
        CompletionPopup      = 'Popup Alert'
        TestPopup            = 'Test Popup'
        Help                 = 'Help'
        CheckUpdate          = 'Check Update'
        GridSelect           = 'Select'
        GridUpdated          = 'Updated'
        GridProvider         = 'Provider'
        GridArchived         = 'Archived'
        GridThreadId         = 'Thread ID'
        GridCwd              = 'Project Dir'
        GridTitle            = 'Chat Content'
        GridRollout          = 'Record File'
        MenuOpenChatDir      = 'Open Chat Content'
        MenuOpenWorkspace    = 'Open Project Directory'
        MenuCopyCell         = 'Copy This Cell'
        MenuCheckOnly        = 'Only Check This'
        MenuCheckExcept      = 'Check All Except This'
        MenuLaunchTerminal   = 'Launch Terminal'
        MenuLaunchWithChat   = 'Launch Terminal (+Chat)'
        MenuSyncTo           = 'Sync This To'
        MenuSyncCurrent      = 'Sync This To'
        MenuSyncChecked      = 'Sync Checked'
        MenuSyncAll          = 'Sync All'
        StatusReady          = 'Ready'
    }
}

function Resolve-ToolPath {
    param([string]$Name)

    $exeName = if ($Name.EndsWith('.exe')) { $Name } else { "$Name.exe" }
    foreach ($path in @(
            (Join-Path $script:RootDir "bin\$exeName"),
            (Join-Path $script:ToolDir "bin\$exeName"),
            (Join-Path $script:RootDir "dist\codex-history-sync-portable\bin\$exeName"),
            (Join-Path (Split-Path -Parent $script:RootDir) "codex-history-sync-portable\bin\$exeName")
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

function Invoke-SqliteJson {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Context = 'SQLite'
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath) -or -not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        throw "$Context 数据库不存在：$DatabasePath"
    }

    $text = ''
    $exitCode = 0
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $output = & $script:Sqlite -cmd '.timeout 5000' -json $DatabasePath $Sql 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
            }) -join [Environment]::NewLine
        $text = $text.Trim()

        if ($exitCode -eq 0) { break }
        if ($text -notmatch 'database is locked|database is busy|SQLITE_BUSY' -or $attempt -ge 4) { break }

        Write-DiagnosticLog "$Context query hit SQLite busy/locked state; retry $attempt."
        Start-Sleep -Milliseconds (200 * $attempt)
    }

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "sqlite3 exit code $exitCode" }
        Write-DiagnosticLog "$Context query failed exit=$exitCode text=$text"
        throw "$Context 查询失败：$text"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "$Context 输出解析失败：$($_.Exception.Message)"
    }
}

function Invoke-SqlJson {
    param([Parameter(Mandatory)][string]$Sql)

    Assert-CodexHomeReady
    return (Invoke-SqliteJson -DatabasePath $script:StateDb -Sql $Sql -Context 'Codex 本地数据库')
}

function Invoke-CcSwitchSqlJson {
    param([Parameter(Mandatory)][string]$Sql)

    if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb) -or -not (Test-Path -LiteralPath $script:CcSwitchDb)) {
        throw '未找到 cc-switch.db。历史记录同步仍可使用；如需切换账号并启动，请把工具放到 cc-switch 目录，或用 -CcSwitchHome 指定 cc-switch 安装目录。'
    }

    return (Invoke-SqliteJson -DatabasePath $script:CcSwitchDb -Sql $Sql -Context 'cc-switch.db')
}

function Convert-CodexPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '^\\\\\?\\', '').TrimEnd('\')
}

function Convert-CodexFilePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '^\\\\\?\\', '')
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

    $value = ([string]$Provider).Trim()
    switch ($value.ToLowerInvariant()) {
        'openai' { return 'OpenAI' }
        'custom' { return 'API-Any Router' }
        'rightcode' { return 'API-rightcode' }
    }
    return $Provider
}

function Resolve-ProviderValue {
    param([AllowNull()][string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $Label }
    if ($script:ProviderLabelToValue -and $script:ProviderLabelToValue.ContainsKey($Label)) {
        return $script:ProviderLabelToValue.Get_Item($Label)
    }
    $normalized = ([string]$Label).Trim().ToLowerInvariant()
    switch ($normalized) {
        'openai' { return 'openai' }
        'openai official' { return 'openai' }
        'api-any router' { return 'custom' }
        'api-anyrouter' { return 'custom' }
        'any router' { return 'custom' }
        'anyrouter' { return 'custom' }
        'custom' { return 'custom' }
        'api-rightcode' { return 'rightcode' }
        'rightcode' { return 'rightcode' }
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

    return @(Get-CcSwitchCodexProvidersFromDatabase -DatabasePath $script:CcSwitchDb)
}

function Get-SqliteTableColumns {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$TableName
    )

    if ($TableName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "SQLite 表名不合法：$TableName"
    }

    $columns = @{}
    foreach ($row in @(Invoke-SqliteJson -DatabasePath $DatabasePath -Sql "PRAGMA table_info($TableName);" -Context 'cc-switch.db')) {
        $name = [string]$row.name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $columns[$name.ToLowerInvariant()] = $true
        }
    }
    return $columns
}

function Test-SqliteColumn {
    param(
        [Parameter(Mandatory)]$Columns,
        [Parameter(Mandatory)][string]$Name
    )

    return $Columns.ContainsKey($Name.ToLowerInvariant())
}

function Get-CcSwitchCodexProvidersFromDatabase {
    param([Parameter(Mandatory)][string]$DatabasePath)

    $columns = Get-SqliteTableColumns -DatabasePath $DatabasePath -TableName 'providers'
    if ($columns.Count -eq 0) {
        throw '所选数据库不是 cc-switch 数据库：找不到 providers 表。请确认选择的是 cc-switch.db 或同结构的 .db 文件。'
    }

    $missing = @()
    foreach ($name in @('id', 'name', 'settings_config', 'app_type')) {
        if (-not (Test-SqliteColumn -Columns $columns -Name $name)) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        throw "所选数据库不是支持的 cc-switch 数据库：providers 表缺少字段 $($missing -join ', ')。"
    }

    $isCurrentSelect = if (Test-SqliteColumn -Columns $columns -Name 'is_current') { 'is_current' } else { '0 AS is_current' }
    $orderParts = @()
    if (Test-SqliteColumn -Columns $columns -Name 'is_current') { $orderParts += 'is_current DESC' }
    if (Test-SqliteColumn -Columns $columns -Name 'sort_index') { $orderParts += 'sort_index ASC' }
    $orderParts += 'name ASC'
    $orderClause = $orderParts -join ', '

    return @(Invoke-SqliteJson -DatabasePath $DatabasePath -Sql @"
SELECT id, name, settings_config, $isCurrentSelect
FROM providers
WHERE app_type = 'codex'
ORDER BY $orderClause;
"@)
}

function Get-HistoryProviderFromCcSwitchProvider {
    param([Parameter(Mandatory)]$ProviderRow)

    $id = [string]$ProviderRow.id
    $name = [string]$ProviderRow.name
    $normalizedId = Normalize-ProviderKey $id
    $normalizedName = Normalize-ProviderKey $name
    if ($normalizedId -eq 'codex-official') { return 'openai' }
    if ($normalizedName -eq 'any router' -or $normalizedName -eq 'anyrouter') { return 'custom' }
    if ($normalizedName -match 'right\s*code|rightcode') { return 'rightcode' }

    try {
        $settings = [string]$ProviderRow.settings_config | ConvertFrom-Json
        $config = [string]$settings.config

        $modelProvider = Get-CodexConfigStringValue $config 'model_provider'
        if (-not [string]::IsNullOrWhiteSpace($modelProvider)) {
            $providerName = Get-CodexModelProviderNameFromConfig -Config $config -ProviderId $modelProvider
            $normalizedProviderName = Normalize-ProviderKey $providerName
            if ($normalizedProviderName -match 'right\s*code|rightcode') { return 'rightcode' }
            if ($normalizedProviderName -eq 'any router' -or $normalizedProviderName -eq 'anyrouter') { return 'custom' }
            if (-not [string]::IsNullOrWhiteSpace($normalizedProviderName) -and $normalizedProviderName -ne 'custom') {
                return $providerName.Trim()
            }

            $normalizedModelProvider = Normalize-ProviderKey $modelProvider
            if ($normalizedModelProvider -ne 'custom') {
                return $modelProvider.Trim()
            }
            if ($normalizedName -eq 'custom') {
                return 'custom'
            }
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
        [AllowNull()][string]$PreferredProvider,
        [AllowNull()][string]$ExcludedProvider
    )

    if (-not $Combo) { return }

    $current = Resolve-ProviderValue ([string]$Combo.SelectedItem)
    if ([string]::IsNullOrWhiteSpace($current) -or (Test-SameHistoryProvider $current $ExcludedProvider)) {
        $current = $PreferredProvider
    }
    if (Test-SameHistoryProvider $current $ExcludedProvider) { $current = '' }
    if (Test-SameHistoryProvider $PreferredProvider $ExcludedProvider) { $PreferredProvider = '' }

    $Combo.Items.Clear()
    foreach ($provider in $Providers) {
        if (Test-SameHistoryProvider $provider $ExcludedProvider) { continue }
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

function Test-SameHistoryProvider {
    param(
        [AllowNull()][string]$A,
        [AllowNull()][string]$B
    )

    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $left = Resolve-ProviderValue $A
    $right = Resolve-ProviderValue $B
    return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-HistoryTargetProviderAllowed {
    param(
        [Parameter(Mandatory)][string]$SourceProvider,
        [Parameter(Mandatory)][string]$TargetProvider
    )

    if (Test-SameHistoryProvider $SourceProvider $TargetProvider) {
        throw "源账号与目标账号不能相同：$SourceProvider。请选择另一个目标账号。"
    }
}

function Update-TargetProviderComboForCurrentSource {
    param([AllowNull()][string]$PreferredProvider)

    if (-not $script:TargetCombo) { return }
    $providers = @(Get-Providers)
    $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
    if ([string]::IsNullOrWhiteSpace($PreferredProvider)) {
        $PreferredProvider = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
    }
    Reset-ProviderCombo $script:TargetCombo $providers $PreferredProvider -ExcludedProvider $source
}

function Reset-CcSwitchAccountCombo {
    param(
        [Parameter(Mandatory)]$Providers,
        [AllowNull()][string]$HistoryProvider
    )

    if (-not $script:CodexProviderCombo) { return }

    $current = Resolve-CcSwitchProviderId ([string]$script:CodexProviderCombo.SelectedItem)
    $script:CodexProviderCombo.Items.Clear()
    $script:CcSwitchProviderLabelToId = @{}
    $usedLabels = @{}
    $preferred = $null
    $shownLabels = New-Object System.Collections.Generic.List[string]

    foreach ($provider in $Providers) {
        if (-not (Test-CcSwitchProviderAllowedForHistoryProvider -ProviderRow $provider -HistoryProvider $HistoryProvider)) {
            continue
        }

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
        [void]$shownLabels.Add($label)

        if ([string]::IsNullOrWhiteSpace($preferred) -and [bool]$provider.is_current) {
            $preferred = $id
        }
    }

    $history = Normalize-ProviderKey $HistoryProvider
    if ([string]::IsNullOrWhiteSpace($preferred) -and $history -eq 'openai') {
        $preferred = 'codex-official'
    }
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        foreach ($label in $script:CodexProviderCombo.Items) {
            if ($script:CcSwitchProviderLabelToId[$label] -eq $current) {
                $preferred = $current
                break
            }
        }
    }

    foreach ($label in $script:CodexProviderCombo.Items) {
        if ($script:CcSwitchProviderLabelToId[$label] -eq $preferred) {
            $script:CodexProviderCombo.SelectedItem = $label
            break
        }
    }
    if (-not $script:CodexProviderCombo.SelectedItem -and $script:CodexProviderCombo.Items.Count -gt 0) {
        $script:CodexProviderCombo.SelectedIndex = 0
    }

    Write-DiagnosticLog ("CcSwitch combo reset history='{0}' selected='{1}' items=[{2}]" -f $HistoryProvider, ([string]$script:CodexProviderCombo.SelectedItem), ($shownLabels.ToArray() -join ', '))
}

function Get-CurrentSourceProvider {
    if (-not $script:SourceCombo) { return '' }
    return Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
}

function Update-CcSwitchAccountComboForCurrentSource {
    $providers = @()
    if ($null -ne $script:CcSwitchCodexProviders) {
        $providers = @($script:CcSwitchCodexProviders)
    }
    else {
        $providers = @(Get-CcSwitchCodexProviders)
        $script:CcSwitchCodexProviders = $providers
    }

    $oldSuppress = $script:SuppressThreadRefresh
    try {
        $script:SuppressThreadRefresh = $true
        Reset-CcSwitchAccountCombo -Providers $providers -HistoryProvider (Get-CurrentSourceProvider)
    }
    finally {
        $script:SuppressThreadRefresh = $oldSuppress
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
SELECT id, model_provider, cwd, title, archived, updated_at_ms, rollout_path
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
        $rolloutPath = Convert-CodexFilePath ([string]$row.rollout_path)

        $items += [pscustomobject]@{
            Updated     = $updatedText
            Provider    = $providerText
            Archived    = $archivedValue
            Id          = $idText
            Cwd         = $cwd
            Title       = $titleText
            RolloutPath = $rolloutPath
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
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(43, 51, 63)
    return $label
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 110,
        [ValidateSet('Default', 'Primary', 'Soft')]
        [string]$Kind = 'Default'
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, 28)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($Kind -eq 'Primary') {
        $button.BackColor = [System.Drawing.Color]::FromArgb(31, 111, 235)
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(31, 111, 235)
    }
    elseif ($Kind -eq 'Soft') {
        $button.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
        $button.ForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(191, 219, 254)
    }
    else {
        $button.BackColor = [System.Drawing.Color]::White
        $button.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    }
    return $button
}

function New-GroupBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)

    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Text
    $group.Location = New-Object System.Drawing.Point($X, $Y)
    $group.Size = New-Object System.Drawing.Size($W, $H)
    $group.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $group.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $group.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    return $group
}

function Get-UiText {
    param([Parameter(Mandatory)][string]$Key)

    $language = if ($script:UiStrings.ContainsKey($script:UiLanguage)) { $script:UiLanguage } else { 'zh-CN' }
    if ($script:UiStrings[$language].ContainsKey($Key)) {
        return [string]$script:UiStrings[$language][$Key]
    }
    if ($script:UiStrings['zh-CN'].ContainsKey($Key)) {
        return [string]$script:UiStrings['zh-CN'][$Key]
    }
    return $Key
}

function Normalize-UiLanguage {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'zh-CN' }
    $value = $Value.Trim()
    if ($value -match '^(en|english|en-us)$') { return 'en-US' }
    if ($value -match '^(zh|cn|chinese|zh-cn|中文)$') { return 'zh-CN' }
    if ($script:UiStrings.ContainsKey($value)) { return $value }
    return 'zh-CN'
}

function Get-LanguageDisplayText {
    param([Parameter(Mandatory)][string]$Language)

    if ($Language -eq 'en-US') { return 'English' }
    return '中文'
}

function Get-LanguageFromDisplayText {
    param([AllowNull()][string]$Text)

    if ([string]::Equals($Text, 'English', [System.StringComparison]::OrdinalIgnoreCase)) { return 'en-US' }
    return 'zh-CN'
}

function Get-LanguageToggleText {
    if ($script:UiLanguage -eq 'en-US') { return '中文' }
    return 'English'
}

function Toggle-UiLanguage {
    Remember-CurrentLanguageWindowWidth
    if ($script:UiLanguage -eq 'en-US') {
        Set-UiLanguage 'zh-CN' -RestoreWindowWidth
    }
    else {
        Set-UiLanguage 'en-US' -RestoreWindowWidth
    }
}

function Get-LanguageWindowWidth {
    param([Parameter(Mandatory)][string]$Language)

    $language = Normalize-UiLanguage $Language
    $value = $script:WindowWidthByLanguage[$language]
    if ($null -eq $value -or [int]$value -lt 1) { return 1320 }
    return [int]$value
}

function Set-LanguageWindowWidth {
    param(
        [Parameter(Mandatory)][string]$Language,
        [int]$Width
    )

    $language = Normalize-UiLanguage $Language
    if ($Width -lt 1) { return }
    $script:WindowWidthByLanguage[$language] = [int]$Width
}

function Remember-CurrentLanguageWindowWidth {
    if (-not $script:Form -or $script:Form.IsDisposed -or $script:RestoringLanguageWindowWidth) { return }
    Set-LanguageWindowWidth -Language $script:UiLanguage -Width $script:Form.Width
}

function Import-LanguageWindowWidths {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return }
    foreach ($language in @('zh-CN', 'en-US')) {
        $property = $Value.PSObject.Properties[$language]
        if ($property -and $null -ne $property.Value) {
            try {
                Set-LanguageWindowWidth -Language $language -Width ([int]$property.Value)
            }
            catch {
                continue
            }
        }
    }
}

function Get-LanguageWindowWidthsForConfig {
    Remember-CurrentLanguageWindowWidth
    return [pscustomobject][ordered]@{
        'zh-CN' = Get-LanguageWindowWidth 'zh-CN'
        'en-US' = Get-LanguageWindowWidth 'en-US'
    }
}

function Apply-LanguageWindowWidth {
    param([Parameter(Mandatory)][string]$Language)

    if (-not $script:Form -or $script:Form.IsDisposed) { return }

    $language = Normalize-UiLanguage $Language
    $targetWidth = [Math]::Max((Get-LanguageWindowWidth $language), $script:Form.MinimumSize.Width)
    $script:RestoringLanguageWindowWidth = $true
    try {
        if ($script:Form.Width -ne $targetWidth) {
            $script:Form.Width = $targetWidth
        }
        Set-LanguageWindowWidth -Language $language -Width $script:Form.Width
    }
    finally {
        $script:RestoringLanguageWindowWidth = $false
    }
}

function Measure-UiTextWidth {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)]$Font,
        [int]$Extra = 0
    )

    if ($null -eq $Text) { $Text = '' }
    return [System.Windows.Forms.TextRenderer]::MeasureText([string]$Text, $Font).Width + $Extra
}

function Set-ControlText {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Control) {
        $Control.Text = Get-UiText $Key
    }
}

function Set-ControlWidthForText {
    param(
        [Parameter(Mandatory)]$Control,
        [int]$MinWidth = 70,
        [int]$Extra = 28
    )

    if (-not $Control) { return }
    $width = [Math]::Max($MinWidth, (Measure-UiTextWidth -Text ([string]$Control.Text) -Font $Control.Font -Extra $Extra))
    $Control.Size = New-Object System.Drawing.Size($width, $Control.Height)
}

function Move-Control {
    param(
        [Parameter(Mandatory)]$Control,
        [int]$X,
        [int]$Y,
        [AllowNull()][int]$Width,
        [AllowNull()][int]$Height
    )

    if (-not $Control) { return }
    $newWidth = if ($PSBoundParameters.ContainsKey('Width')) { $Width } else { $Control.Width }
    $newHeight = if ($PSBoundParameters.ContainsKey('Height')) { $Height } else { $Control.Height }
    $Control.Location = New-Object System.Drawing.Point($X, $Y)
    $Control.Size = New-Object System.Drawing.Size($newWidth, $newHeight)
}

function Resize-GroupToFitControls {
    param(
        [Parameter(Mandatory)]$Group,
        [int]$MinWidth = 100,
        [int]$MinHeight = 58,
        [int]$RightPadding = 14,
        [int]$BottomPadding = 8
    )

    $maxRight = 0
    $maxBottom = 0
    foreach ($control in $Group.Controls) {
        $maxRight = [Math]::Max($maxRight, $control.Right)
        $maxBottom = [Math]::Max($maxBottom, $control.Bottom)
    }

    $titleWidth = 0
    if (-not [string]::IsNullOrWhiteSpace([string]$Group.Text)) {
        $titleWidth = Measure-UiTextWidth -Text ([string]$Group.Text) -Font $Group.Font -Extra 34
    }

    $Group.Size = New-Object System.Drawing.Size(
        [Math]::Max([Math]::Max($MinWidth, $titleWidth), $maxRight + $RightPadding),
        [Math]::Max($MinHeight, $maxBottom + $BottomPadding)
    )
}

function Layout-HeaderMeta {
    if (-not $headerPanel -or -not $headerMeta -or -not $headerGitHub -or -not $headerLanguageLink -or -not $headerLanguageSeparator) { return }

    $right = [Math]::Max(1000, $headerPanel.ClientSize.Width) - 28
    $languageWidth = [Math]::Max(52, (Measure-UiTextWidth -Text ([string]$headerLanguageLink.Text) -Font $headerLanguageLink.Font -Extra 10))
    $separatorWidth = 14
    $githubWidth = [Math]::Max(54, (Measure-UiTextWidth -Text ([string]$headerGitHub.Text) -Font $headerGitHub.Font -Extra 8))

    $headerLanguageLink.Size = New-Object System.Drawing.Size($languageWidth, 22)
    $headerLanguageLink.Location = New-Object System.Drawing.Point(($right - $languageWidth), 20)

    $headerLanguageSeparator.Size = New-Object System.Drawing.Size($separatorWidth, 22)
    $headerLanguageSeparator.Location = New-Object System.Drawing.Point(($headerLanguageLink.Left - $separatorWidth - 2), 20)

    $headerGitHub.Size = New-Object System.Drawing.Size($githubWidth, 22)
    $headerGitHub.Location = New-Object System.Drawing.Point(($headerLanguageSeparator.Left - $githubWidth - 2), 20)

    $metaWidth = 430
    $headerMeta.Size = New-Object System.Drawing.Size($metaWidth, 22)
    $headerMeta.Location = New-Object System.Drawing.Point(($headerGitHub.Left - $metaWidth - 4), 20)
}

function Layout-ToolbarGroups {
    if (-not $historyGroup -or -not $syncGroup -or -not $pathGroup -or -not $launchGroup -or -not $supportGroup) { return }

    foreach ($button in @(
            $swapButton, $refreshButton, $selectAllButton, $clearSelectionButton, $cloneButton, $syncButton, $mirrorButton,
            $selectCodexHomeButton, $openRecordFolderButton, $openCodexFolderButton, $selectCcSwitchHomeButton, $openConfigButton,
            $openCodexButton, $testNotifyButton, $helpButton, $updateButton
        )) {
        Set-ControlWidthForText -Control $button -MinWidth 58 -Extra 30
    }
    foreach ($check in @($script:IncludeArchivedBox, $script:LoadCheckedRecordBox, $script:UsePowerShellLaunchBox, $script:ApprovalNeverLaunchBox, $script:TurnEndedNotifyBox)) {
        Set-ControlWidthForText -Control $check -MinWidth 58 -Extra 28
    }
    foreach ($label in @($sourceLabel, $targetLabel, $cwdLabel, $limitLabel, $ccProviderLabel)) {
        Set-ControlWidthForText -Control $label -MinWidth 42 -Extra 8
    }

    Move-Control $sourceLabel 14 24
    Move-Control $script:SourceCombo ($sourceLabel.Right + 6) 24 118 24
    Move-Control $targetLabel ($script:SourceCombo.Right + 12) 24
    Move-Control $script:TargetCombo ($targetLabel.Right + 6) 24 118 24
    Move-Control $swapButton ($script:TargetCombo.Right + 10) 22
    Move-Control $cwdLabel 14 54
    Move-Control $script:CwdCombo ($cwdLabel.Right + 6) 54 222 24
    Move-Control $limitLabel ($script:CwdCombo.Right + 12) 54
    Move-Control $script:LimitBox ($limitLabel.Right + 6) 54 58 24
    Move-Control $script:IncludeArchivedBox ($script:LimitBox.Right + 8) 55
    Resize-GroupToFitControls -Group $historyGroup -MinWidth 500 -MinHeight 86 -RightPadding 16

    $x = 14
    foreach ($button in @($refreshButton, $selectAllButton, $clearSelectionButton, $cloneButton)) {
        Move-Control $button $x 24
        $x = $button.Right + 8
    }
    $x = 14
    foreach ($button in @($syncButton, $mirrorButton)) {
        Move-Control $button $x 54
        $x = $button.Right + 8
    }
    Resize-GroupToFitControls -Group $syncGroup -MinWidth 318 -MinHeight 86 -RightPadding 16

    $x = 14
    foreach ($button in @($selectCodexHomeButton, $openRecordFolderButton, $openCodexFolderButton)) {
        Move-Control $button $x 24
        $x = $button.Right + 10
    }
    $x = 14
    foreach ($button in @($selectCcSwitchHomeButton, $openConfigButton)) {
        Move-Control $button $x 54
        $x = $button.Right + 10
    }
    Resize-GroupToFitControls -Group $pathGroup -MinWidth 0 -MinHeight 86 -RightPadding 18

    Move-Control $ccProviderLabel 14 24
    Move-Control $script:CodexProviderCombo ($ccProviderLabel.Right + 6) 24 170 24
    Move-Control $openCodexButton ($script:CodexProviderCombo.Right + 12) 22
    Move-Control $script:UsePowerShellLaunchBox ($openCodexButton.Right + 12) 25
    Move-Control $script:ApprovalNeverLaunchBox ($script:UsePowerShellLaunchBox.Right + 12) 25
    Move-Control $script:LoadCheckedRecordBox ($script:ApprovalNeverLaunchBox.Right + 12) 25
    Move-Control $script:TurnEndedNotifyBox ($script:LoadCheckedRecordBox.Right + 12) 25
    Move-Control $testNotifyButton ($script:TurnEndedNotifyBox.Right + 12) 22
    Resize-GroupToFitControls -Group $launchGroup -MinWidth 0 -MinHeight 58 -RightPadding 18

    Move-Control $helpButton 14 22
    Move-Control $updateButton ($helpButton.Right + 10) 22
    Resize-GroupToFitControls -Group $supportGroup -MinWidth 0 -MinHeight 58 -RightPadding 18

    $gap = 12
    $historyGroup.Location = New-Object System.Drawing.Point(12, 70)
    $syncGroup.Location = New-Object System.Drawing.Point(($historyGroup.Right + $gap), 70)
    $pathGroup.Location = New-Object System.Drawing.Point(($syncGroup.Right + $gap), 70)
    $launchGroup.Location = New-Object System.Drawing.Point(12, 166)
    $supportGroup.Location = New-Object System.Drawing.Point(($launchGroup.Right + $gap), 166)

    $requiredWidth = [Math]::Max($pathGroup.Right, $supportGroup.Right) + 28
    $newMinWidth = [Math]::Max(1320, $requiredWidth)
    $script:Form.MinimumSize = New-Object System.Drawing.Size($newMinWidth, 820)
    if ($script:Form.Width -lt $newMinWidth) {
        $script:Form.Width = $newMinWidth
    }
}

function Apply-UiLanguage {
    $script:AllCwdLabel = Get-UiText 'AllFolders'

    if ($script:Form) {
        $script:Form.Text = Get-UiText 'FormTitle'
    }
    Set-ControlText $headerTitle 'HeaderTitle'
    Set-ControlText $headerSubTitle 'HeaderSubtitle'
    if ($headerMeta) {
        $headerMeta.Text = "v$script:AppVersion  |  $(Get-UiText 'AuthorLabel') $script:AppAuthor  |"
    }
    if ($headerGitHub) { $headerGitHub.Text = 'GitHub' }
    if ($headerLanguageSeparator) { $headerLanguageSeparator.Text = '|' }
    if ($headerLanguageLink) { $headerLanguageLink.Text = Get-LanguageToggleText }
    Set-ControlText $historyGroup 'GroupHistory'
    Set-ControlText $syncGroup 'GroupSync'
    Set-ControlText $pathGroup 'GroupPath'
    Set-ControlText $launchGroup 'GroupLaunch'
    Set-ControlText $supportGroup 'GroupSupport'
    Set-ControlText $sourceLabel 'SourceProvider'
    Set-ControlText $targetLabel 'TargetProvider'
    Set-ControlText $cwdLabel 'DirectoryFilter'
    Set-ControlText $limitLabel 'DisplayLimit'
    Set-ControlText $ccProviderLabel 'CcSwitchProvider'
    Set-ControlText $script:IncludeArchivedBox 'Archived'
    Set-ControlText $refreshButton 'Refresh'
    Set-ControlText $selectAllButton 'SelectAll'
    Set-ControlText $clearSelectionButton 'ClearSelection'
    Set-ControlText $cloneButton 'CloneChecked'
    Set-ControlText $syncButton 'SyncAll'
    Set-ControlText $mirrorButton 'Mirror'
    Set-ControlText $swapButton 'Swap'
    Set-ControlText $selectCodexHomeButton 'AddHistory'
    Set-ControlText $openRecordFolderButton 'OpenChatDir'
    Set-ControlText $openCodexFolderButton 'CodexDir'
    Set-ControlText $selectCcSwitchHomeButton 'ImportCcConfig'
    Set-ControlText $openConfigButton 'Settings'
    Set-ControlText $openCodexButton 'LaunchTerminal'
    Set-ControlText $script:LoadCheckedRecordBox 'LoadCheckedRecord'
    Set-ControlText $script:UsePowerShellLaunchBox 'PowerShellLaunch'
    Set-ControlText $script:ApprovalNeverLaunchBox 'ApprovalNeverLaunch'
    Set-ControlText $script:TurnEndedNotifyBox 'CompletionPopup'
    Set-ControlText $testNotifyButton 'TestPopup'
    Set-ControlText $helpButton 'Help'
    Set-ControlText $updateButton 'CheckUpdate'

    $gridHeaders = @{
        Selected    = 'GridSelect'
        Updated     = 'GridUpdated'
        Provider    = 'GridProvider'
        Archived    = 'GridArchived'
        Id          = 'GridThreadId'
        Cwd         = 'GridCwd'
        Title       = 'GridTitle'
        RolloutPath = 'GridRollout'
    }
    foreach ($property in $gridHeaders.Keys) {
        $column = Get-GridColumnByProperty $property
        if ($column) {
            $column.HeaderText = Get-UiText $gridHeaders[$property]
        }
    }

    Set-ControlText $gridOpenRecordDirItem 'MenuOpenChatDir'
    Set-ControlText $gridOpenWorkspaceItem 'MenuOpenWorkspace'
    Set-ControlText $gridCopyCellItem 'MenuCopyCell'
    Set-ControlText $gridCheckOnlyItem 'MenuCheckOnly'
    Set-ControlText $gridCheckExceptItem 'MenuCheckExcept'
    Set-ControlText $gridLaunchTerminalItem 'MenuLaunchTerminal'
    Set-ControlText $gridLaunchWithChatItem 'MenuLaunchWithChat'
    Set-ControlText $script:GridSyncToMenuItem 'MenuSyncTo'
    Set-ControlText $gridCloneCheckedItem 'MenuSyncChecked'
    Set-ControlText $gridSyncAllItem 'MenuSyncAll'

    if ($script:StatusLabel -and ([string]::IsNullOrWhiteSpace($script:StatusLabel.Text) -or $script:StatusLabel.Text -in @('就绪', 'Ready'))) {
        $script:StatusLabel.Text = Get-UiText 'StatusReady'
    }

    Layout-ToolbarGroups
    Layout-HeaderMeta
}

function Set-UiLanguage {
    param(
        [AllowNull()][string]$Language,
        [switch]$RestoreWindowWidth
    )

    $normalized = Normalize-UiLanguage $Language
    if ($script:UiLanguage -eq $normalized -and $script:Form) {
        if ($RestoreWindowWidth) {
            Apply-LanguageWindowWidth $normalized
        }
        return
    }
    $oldRestoring = $script:RestoringLanguageWindowWidth
    if ($RestoreWindowWidth) { $script:RestoringLanguageWindowWidth = $true }
    $script:UiLanguage = $normalized
    try {
        Apply-UiLanguage
    }
    finally {
        $script:RestoringLanguageWindowWidth = $oldRestoring
    }
    if ($RestoreWindowWidth) {
        Apply-LanguageWindowWidth $normalized
    }
}

function New-HeaderImage {
    $bitmap = New-Object System.Drawing.Bitmap 220, 56
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $blue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(31, 111, 235))
    $teal = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 184, 166))
    $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(51, 65, 85))
    $line = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(148, 163, 184)), 2
    $whitePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2

    $cardPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $cardPath.AddArc(8, 10, 14, 14, 180, 90)
    $cardPath.AddArc(46, 10, 14, 14, 270, 90)
    $cardPath.AddArc(46, 32, 14, 14, 0, 90)
    $cardPath.AddArc(8, 32, 14, 14, 90, 90)
    $cardPath.CloseFigure()
    $graphics.FillPath($blue, $cardPath)
    $graphics.DrawLine($whitePen, 20, 23, 48, 23)
    $graphics.DrawLine($whitePen, 20, 33, 42, 33)
    $graphics.FillEllipse($teal, 52, 8, 13, 13)

    $bubblePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bubblePath.AddArc(82, 9, 16, 16, 180, 90)
    $bubblePath.AddArc(178, 9, 16, 16, 270, 90)
    $bubblePath.AddArc(178, 31, 16, 16, 0, 90)
    $bubblePath.AddArc(82, 31, 16, 16, 90, 90)
    $bubblePath.CloseFigure()
    $graphics.DrawPath($line, $bubblePath)
    $graphics.FillRectangle($ink, 96, 21, 64, 4)
    $graphics.FillRectangle($teal, 96, 31, 82, 4)
    $graphics.DrawLine($line, 62, 28, 82, 28)

    $bubblePath.Dispose()
    $cardPath.Dispose()
    $whitePen.Dispose()
    $line.Dispose()
    $ink.Dispose()
    $teal.Dispose()
    $blue.Dispose()
    $graphics.Dispose()
    return $bitmap
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

function Select-FilePath {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][string]$InitialDirectory,
        [string]$Filter = 'All files (*.*)|*.*'
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true
    $dialog.Filter = $Filter
    if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and
        (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $dialog.InitialDirectory = $InitialDirectory
    }

    try {
        if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        $selected = Convert-CodexPath $dialog.FileName
        if (Test-Path -LiteralPath $selected -PathType Leaf) {
            return (Resolve-Path -LiteralPath $selected).Path
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

function Write-DiagnosticLog {
    param([AllowNull()][string]$Text)

    try {
        if ([string]::IsNullOrWhiteSpace($script:DiagnosticLogPath)) { return }
        $dir = Split-Path -Parent $script:DiagnosticLogPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = '[{0}] [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), $script:DiagnosticSessionId, ([string]$Text), [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:DiagnosticLogPath, $line, $script:Utf8NoBom)
    }
    catch {
        return
    }
}

function Format-DiagnosticError {
    param([AllowNull()]$ErrorObject)

    if ($null -eq $ErrorObject) { return 'unknown error' }
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $line = $ErrorObject.InvocationInfo.ScriptLineNumber
        $message = $ErrorObject.Exception.Message
        if ($line) { $message = "line=$line $message" }
        return "$message stack=$($ErrorObject.ScriptStackTrace)"
    }
    if ($ErrorObject -is [Exception]) {
        return "$($ErrorObject.GetType().FullName): $($ErrorObject.Message) stack=$($ErrorObject.StackTrace)"
    }
    return [string]$ErrorObject
}

function Append-Log {
    param([AllowNull()][string]$Text)

    $message = if ($null -eq $Text) { '' } else { [string]$Text }
    Write-DiagnosticLog $message
    try {
        if (-not $script:OutputBox -or $script:OutputBox.IsDisposed) { return }
        $script:OutputBox.AppendText(("> " + (Get-Date -Format 'HH:mm:ss') + [Environment]::NewLine))
        $script:OutputBox.AppendText($message.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine)
    }
    catch {
        Write-DiagnosticLog ("Append-Log UI write failed: " + (Format-DiagnosticError $_))
    }
}

function Show-GuiError {
    param([Parameter(Mandatory)]$ErrorRecord)

    $line = $ErrorRecord.InvocationInfo.ScriptLineNumber
    $message = $ErrorRecord.Exception.Message
    if ($line) {
        $message = "第 $line 行：$message"
    }
    Write-DiagnosticLog ("Show-GuiError: " + (Format-DiagnosticError $ErrorRecord))
    Append-Log $message
    if ($SelfTest) {
        throw $message
    }
    [System.Windows.Forms.MessageBox]::Show($message, '错误', 'OK', 'Error') | Out-Null
}

function Show-UnhandledGuiException {
    param([AllowNull()][Exception]$Exception)

    $message = if ($Exception) { $Exception.Message } else { '未知界面异常' }
    Write-DiagnosticLog ("Unhandled GUI exception: " + (Format-DiagnosticError $Exception))
    try {
        if ($script:OutputBox -and -not $script:OutputBox.IsDisposed) {
            Append-Log "已拦截界面异常，程序会继续运行：$message"
        }
    }
    catch { }

    if ($SelfTest) {
        throw $message
    }

    try {
        [System.Windows.Forms.MessageBox]::Show(
            "已拦截界面异常，程序会继续运行。`r`n`r`n$message",
            '错误',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch { }
}

[System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $eventArgs)
        Show-UnhandledGuiException -Exception $eventArgs.Exception
    })

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

    $reason = if ($script:CodexHomeResolveError) { $script:CodexHomeResolveError } else { '尚未加载 Codex 账号。' }
    throw ($reason + "`r`n`r`n请点击 ""加载codex账号""，选择包含 state_5.sqlite 的 .codex 文件夹。")
}

function Get-AppHelpText {
    $clipboardNote = if (Copy-TextToClipboard "state_5.sqlite`r`ncc-switch.db") {
        "已复制 state_5.sqlite 和 cc-switch.db 到剪贴板，可直接粘贴到 Everything 搜索。"
    }
    else {
        "复制搜索关键词到剪贴板失败，请手动搜索 state_5.sqlite 或 cc-switch.db。"
    }

    return @"
Codex 历史记录同步
版本：$script:AppVersion
作者：$script:AppAuthor
GitHub：$script:GitHubUrl

$clipboardNote

【加载codex账号】
$(Get-CodexHomeHelpText)

【cc-switch.db 文件】
$(Get-CcSwitchHomeHelpText)
- 【加载cc-switch.db文件】用于选择 cc-switch.db；软件会从这里读取 Any Router、RightCode、OpenAI Official 等 Codex 节点，用于切换账号和从终端启动。

【配置文件】
- 点击【软件配置文件】会打开软件根目录下的 codex-history-sync-config.json。
- 第一次打开时会自动生成配置文件，并尽量写入已检测到的 Codex 账号目录、cc-switch 目录和账号列表。
- 保存配置文件后，软件会自动重新读取并刷新界面。
- 配置文件只写本机路径和默认选择，不要写 API key、token 或 auth.json 内容。

【从终端启动】
- 勾选【启动时加载聊天】：自动恢复当前选中的聊天。
- 取消【启动时加载聊天】：在当前目录创建新对话。
- 列表最左侧的勾选列只用于同步勾选记录，不再决定启动时是否加载聊天。
- 勾选【PowerShell启动】时优先用 PowerShell，否则优先用 CMD；找不到所选终端时会自动退回另一种。

【更新】
- 点击【检查更新】会从 GitHub main 分支检查版本；如果当前目录是干净的 Git checkout，会自动 git pull 同步 GitHub，否则继续使用 ZIP 热更新。
- 本机 codex-history-sync-config.json、数据库、auth.json、config.toml 不会被更新覆盖。
"@
}

function Add-HelpRichLine {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.RichTextBox]$Box,
        [AllowNull()][string]$Text,
        [AllowNull()][System.Drawing.Font]$Font,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty,
        [System.Drawing.Color]$BackColor = [System.Drawing.Color]::Empty
    )

    if ($null -eq $Text) { $Text = '' }
    if ($null -eq $Font) { $Font = $Box.Font }
    if ($Color.IsEmpty) { $Color = [System.Drawing.Color]::FromArgb(51, 65, 85) }
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionFont = $Font
    $Box.SelectionColor = $Color
    if (-not $BackColor.IsEmpty) {
        $Box.SelectionBackColor = $BackColor
    }
    else {
        $Box.SelectionBackColor = $Box.BackColor
    }
    $Box.AppendText(([string]$Text) + "`r`n")
}

function Add-HelpRichBlock {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.RichTextBox]$Box,
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][System.Drawing.Font]$Font,
        [Parameter(Mandatory)][System.Drawing.Color]$Color
    )

    foreach ($line in (([string]$Text) -split "`r?`n")) {
        Add-HelpRichLine -Box $Box -Text $line -Font $Font -Color $Color
    }
}

function Show-AppHelp {
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) {
        $script:HelpForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:HelpForm.Show()
        $script:HelpForm.Activate()
        return
    }

    $clipboardNote = if (Copy-TextToClipboard "state_5.sqlite`r`ncc-switch.db") {
        "已复制 state_5.sqlite 和 cc-switch.db 到剪贴板，可直接粘贴到 Everything 搜索。"
    }
    else {
        "复制搜索关键词到剪贴板失败，请手动搜索 state_5.sqlite 或 cc-switch.db。"
    }

    $helpForm = New-Object System.Windows.Forms.Form
    $helpForm.Text = '帮助'
    $helpForm.StartPosition = 'CenterParent'
    $helpForm.Size = New-Object System.Drawing.Size(820, 640)
    $helpForm.MinimumSize = New-Object System.Drawing.Size(720, 520)
    $helpForm.BackColor = [System.Drawing.Color]::White
    $helpForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $helpForm.ShowInTaskbar = $false
    $script:HelpForm = $helpForm
    $helpForm.Add_FormClosed({ $script:HelpForm = $null })

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Location = New-Object System.Drawing.Point(18, 18)
    $box.Size = New-Object System.Drawing.Size(768, 532)
    $box.Anchor = 'Top,Bottom,Left,Right'
    $box.BorderStyle = 'None'
    $box.BackColor = [System.Drawing.Color]::White
    $box.ReadOnly = $true
    $box.DetectUrls = $true
    $box.ScrollBars = 'Vertical'
    $box.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
    $box.Add_LinkClicked({ param($sender, $eventArgs) Start-Process $eventArgs.LinkText })
    $helpForm.Controls.Add($box)

    $closeButton = New-Button '关闭' 690 560 96 'Primary'
    $closeButton.Anchor = 'Bottom,Right'
    $closeButton.Add_Click({ $helpForm.Close() })
    $helpForm.Controls.Add($closeButton)

    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $sectionFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $bodyFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
    $strongFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $smallFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $blue = [System.Drawing.Color]::FromArgb(30, 64, 175)
    $green = [System.Drawing.Color]::FromArgb(22, 101, 52)
    $red = [System.Drawing.Color]::FromArgb(185, 28, 28)
    $slate = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $muted = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $highlight = [System.Drawing.Color]::FromArgb(239, 246, 255)
    $warningBack = [System.Drawing.Color]::FromArgb(254, 242, 242)

    Add-HelpRichLine -Box $box -Text 'Codex 历史记录同步' -Font $titleFont -Color $blue
    Add-HelpRichLine -Box $box -Text "版本 $script:AppVersion    作者 $script:AppAuthor    $script:GitHubUrl" -Font $smallFont -Color $muted
    Add-HelpRichLine -Box $box -Text ''
    Add-HelpRichLine -Box $box -Text $clipboardNote -Font $strongFont -Color $green -BackColor $highlight
    Add-HelpRichLine -Box $box -Text ''

    Add-HelpRichLine -Box $box -Text '重点概念' -Font $sectionFont -Color $blue
    Add-HelpRichLine -Box $box -Text 'Codex源账号 / Codex目标账号：历史记录数据库里的 model_provider 桶，用于迁移聊天记录。' -Font $strongFont -Color $slate -BackColor $highlight
    Add-HelpRichLine -Box $box -Text 'cc-switch供应商：从终端启动 Codex 时使用的 cc-switch 节点，和上面的历史记录账号不是同一个概念。' -Font $strongFont -Color $slate -BackColor $highlight
    Add-HelpRichLine -Box $box -Text ''

    Add-HelpRichLine -Box $box -Text '加载codex账号' -Font $sectionFont -Color $blue
    Add-HelpRichBlock -Box $box -Text (Get-CodexHomeHelpText) -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text ''

    Add-HelpRichLine -Box $box -Text 'cc-switch.db 配置' -Font $sectionFont -Color $blue
    Add-HelpRichBlock -Box $box -Text (Get-CcSwitchHomeHelpText) -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '点击【加载cc-switch.db文件】选择 cc-switch.db；软件会从这里读取 Any Router、RightCode、OpenAI Official 等 Codex 节点。' -Font $strongFont -Color $green -BackColor $highlight
    Add-HelpRichLine -Box $box -Text ''

    Add-HelpRichLine -Box $box -Text '从终端启动' -Font $sectionFont -Color $blue
    Add-HelpRichLine -Box $box -Text '- 勾选【启动时加载聊天】：自动恢复当前选中的聊天。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 取消【启动时加载聊天】：在当前目录创建新对话。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 列表最左侧的勾选列只用于同步勾选记录，不再决定启动时是否加载聊天。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 勾选【PowerShell启动】时优先用 PowerShell；取消勾选时优先用 CMD。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 勾选【完全访问(-a never)】时启动命令会追加 Codex 官方 bypass 参数，跳过审批并关闭沙箱。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 如果检测到权限审批请求等待超过 10 秒，会弹出橙色提醒。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text ''

    Add-HelpRichLine -Box $box -Text '配置与更新' -Font $sectionFont -Color $blue
    Add-HelpRichLine -Box $box -Text '- 点击【软件配置文件】会打开 codex-history-sync-config.json；保存后软件自动刷新；界面偏好也会自动写回配置文件。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '- 点击【检查更新】会从 GitHub main 分支检查新版；干净的 Git checkout 会自动 git pull，否则使用 ZIP 热更新。' -Font $bodyFont -Color $slate
    Add-HelpRichLine -Box $box -Text '不要把 API key、token、auth.json、config.toml 或 state_5.sqlite 内容写进配置文件。' -Font $strongFont -Color $red -BackColor $warningBack

    $box.SelectionStart = 0
    $box.ScrollToCaret()
    if ($script:Form -and -not $script:Form.IsDisposed) {
        $helpForm.Show($script:Form)
    }
    else {
        $helpForm.Show()
    }
}

function Set-CodexHomeFromSelection {
    param(
        [Parameter(Mandatory)][string]$SelectedPath,
        [switch]$SkipConfigSync,
        [switch]$SkipRefresh
    )

    $resolved = Resolve-CodexHomeFromSelection $SelectedPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "没有在所选目录或其父目录中找到 state_5.sqlite。`r`n`r`n$(Get-CodexHomeHelpText)"
    }

    $script:CodexHome = $resolved
    $script:StateDb = Join-Path $script:CodexHome 'state_5.sqlite'
    $script:CodexHomeResolveError = $null

    Append-Log "已加载 Codex 账号目录：$script:CodexHome"
    if (-not $SkipRefresh) {
        Refresh-Providers
        Refresh-CwdOptions
        Refresh-Threads
    }
    if (-not $SkipConfigSync) {
        Save-AppState
        Sync-AppConfigFileWithDetectedInfo -CreateIfMissing
    }
    if ((-not $SkipRefresh) -and $script:TurnEndedNotifyBox -and [bool]$script:TurnEndedNotifyBox.Checked) {
        try {
            Start-TurnCompleteMonitor
        }
        catch {
            Append-Log "启动桌面版弹窗提醒监控失败：$($_.Exception.Message)"
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
        -Title '加载codex账号：请选择包含 state_5.sqlite 的 .codex 文件夹' `
        -InitialDirectory $initialDirectory
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        Set-CodexHomeFromSelection $selected
    }
}

function Set-CcSwitchHomeFromSelection {
    param(
        [Parameter(Mandatory)][string]$SelectedPath,
        [switch]$SkipConfigSync
    )

    $resolved = Resolve-CcSwitchDbFromSelection $SelectedPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "没有在所选目录或其父目录中找到 cc-switch.db，也没有选中可识别的 .db 文件。`r`n`r`n$(Get-CcSwitchHomeHelpText)"
    }

    $providers = @(Get-CcSwitchCodexProvidersFromDatabase -DatabasePath $resolved)
    $script:CcSwitchDb = $resolved
    $script:CcSwitchSettingsPath = Join-Path (Split-Path -Parent $script:CcSwitchDb) 'settings.json'
    Append-Log "已加载 cc-switch.db 文件：$script:CcSwitchDb"
    if ($providers.Count -eq 0) {
        Append-Log '所选数据库可读取，但暂未发现 app_type=codex 的 cc-switch 供应商。请先在 cc-switch 中新增并保存 Codex 节点。'
    }
    Refresh-Providers
    if (-not $SkipConfigSync) {
        Save-AppState
        try {
            Sync-AppConfigFileWithDetectedInfo -CreateIfMissing -ForceCurrentCcSwitchHome
        }
        catch {
            Append-Log "写入软件配置文件失败，但 cc-switch.db 已加载：$($_.Exception.Message)"
        }
    }
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

    $selected = Select-FilePath `
        -Title '请选择 cc-switch.db 文件' `
        -InitialDirectory $initialDirectory `
        -Filter 'cc-switch database (cc-switch.db)|cc-switch.db|SQLite database (*.db)|*.db|All files (*.*)|*.*'
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        Set-CcSwitchHomeFromSelection $selected
    }
}

function Get-ConfigPropertyValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Config.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-ConfigStringValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Names
    )

    $value = Get-ConfigPropertyValue -Config $Config -Names $Names
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim()
}

function Get-ConfigBoolValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Names,
        [bool]$Default
    )

    $value = Get-ConfigPropertyValue -Config $Config -Names $Names
    if ($null -eq $value) { return $Default }
    if ($value -is [bool]) { return [bool]$value }
    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    return [System.Convert]::ToBoolean($text)
}

function Get-ConfigIntValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Names,
        [int]$Default
    )

    $value = Get-ConfigPropertyValue -Config $Config -Names $Names
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
    return [int]$value
}

function Test-TemplatePlaceholderValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '<|你的用户名|示例|改成')
}

function Normalize-ConfigPathValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if (Test-TemplatePlaceholderValue $Value) {
        if ($script:OutputBox) {
            Append-Log "配置项 $Name 仍是模板占位内容，已跳过：$Value"
        }
        return ''
    }
    return $Value
}

function Set-ConfiguredCodexExecutable {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if (Test-TemplatePlaceholderValue $Value) {
        Append-Log "配置项 codexExe 仍是模板占位内容，已跳过：$Value"
        return
    }

    $resolved = Resolve-CodexExecutableFromValue $Value
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "配置项 codexExe 无效，找不到 codex.exe：$Value"
    }

    $script:ConfiguredCodexExe = $resolved
    Append-Log "已加载 codex.exe 路径：$script:ConfiguredCodexExe"
}

function Select-CcSwitchProviderFromConfig {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $script:CodexProviderCombo) { return }

    foreach ($item in $script:CodexProviderCombo.Items) {
        $label = [string]$item
        $id = Resolve-CcSwitchProviderId $label
        if ([string]::Equals($label, $Value, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($id, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:CodexProviderCombo.SelectedItem = $item
            return
        }
    }

    Append-Log "配置项 defaultCcSwitchNode 未匹配到当前源账号可用的 cc-switch 节点，已保留自动选择结果：$Value"
}

function Select-CwdFilterFromConfig {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $script:CwdCombo) { return }
    $cwd = Convert-CodexPath $Value
    if (-not $script:CwdCombo.Items.Contains($cwd)) {
        [void]$script:CwdCombo.Items.Add($cwd)
    }
    $script:CwdCombo.SelectedItem = $cwd
}

function Get-CurrentAppState {
    $ccSwitchHome = ''
    if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchDb)) {
        $ccSwitchHome = Split-Path -Parent $script:CcSwitchDb
    }

    return [pscustomobject]@{
        savedAt                = (Get-Date).ToString('o')
        codexHome              = [string]$CodexHome
        ccSwitchHome           = [string]$ccSwitchHome
        codexExe               = [string]$script:ConfiguredCodexExe
        defaultSourceProvider  = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        defaultTargetProvider  = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        defaultCcSwitchNode    = [string]$script:CodexProviderCombo.SelectedItem
        directoryFilter        = Get-SelectedCwdFilter
        limit                  = if ($script:LimitBox) { [int]$script:LimitBox.Value } else { 50 }
        includeArchived        = if ($script:IncludeArchivedBox) { [bool]$script:IncludeArchivedBox.Checked } else { $false }
        disableAppsOnFast      = [bool]$script:DisableCodexAppsOnFast
        turnCompletePopup      = if ($script:TurnEndedNotifyBox) { [bool]$script:TurnEndedNotifyBox.Checked } else { $true }
        usePowerShellTerminal  = if ($script:UsePowerShellLaunchBox) { [bool]$script:UsePowerShellLaunchBox.Checked } else { $false }
        approvalNeverOnLaunch  = if ($script:ApprovalNeverLaunchBox) { [bool]$script:ApprovalNeverLaunchBox.Checked } else { $true }
        loadChatOnLaunch      = if ($script:LoadCheckedRecordBox) { [bool]$script:LoadCheckedRecordBox.Checked } else { $true }
        uiLanguage             = [string]$script:UiLanguage
        windowWidth            = if ($script:Form) { [int]$script:Form.Width } else { 1320 }
        windowWidthByLanguage  = Get-LanguageWindowWidthsForConfig
    }
}

function Save-AppState {
    if ($script:SuppressStateSave) { return }
    if ($SelfTest) {
        Write-DiagnosticLog 'Save-AppState skipped in SelfTest.'
        return
    }
    if (-not $script:Form) { return }

    Write-DiagnosticLog ("Save-AppState start reload={0} prefSave={1} source='{2}' target='{3}' cc='{4}'" -f
        $script:ConfigReloadInProgress,
        $script:ConfigPreferenceSaveInProgress,
        (Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)),
        (Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)),
        ([string]$script:CodexProviderCombo.SelectedItem))

    try {
        if (-not (Test-Path -LiteralPath $script:LastStateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:LastStateDir -Force | Out-Null
        }
        $json = Get-CurrentAppState | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($script:LastStatePath, $json, $script:Utf8NoBom)
    }
    catch {
        if ($script:OutputBox) {
            Append-Log "保存上次配置失败：$($_.Exception.Message)"
        }
    }

    try {
        Save-AppPreferencesToConfigFile -CreateIfMissing
    }
    catch {
        if ($script:OutputBox) {
            Append-Log "保存软件配置文件失败：$($_.Exception.Message)"
        }
    }
}

function Get-StartupConfigPath {
    if (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) {
        return $script:AutoConfigPath
    }
    if (Test-Path -LiteralPath $script:LastStatePath -PathType Leaf) {
        return $script:LastStatePath
    }
    return $null
}

function Import-AppConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Silent
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "配置文件不存在：$Path"
    }

    $configText = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = $configText | ConvertFrom-Json

    $codexHomeValue = Normalize-ConfigPathValue -Name 'codexHome' -Value (Get-ConfigStringValue -Config $config -Names @('codexHome', 'CodexHome'))
    $ccSwitchHomeValue = Normalize-ConfigPathValue -Name 'ccSwitchHome' -Value (Get-ConfigStringValue -Config $config -Names @('ccSwitchHome', 'CcSwitchHome'))
    $codexExeValue = Normalize-ConfigPathValue -Name 'codexExe' -Value (Get-ConfigStringValue -Config $config -Names @('codexExe', 'CodexExe'))

    $oldSuppressStateSave = $script:SuppressStateSave
    $script:SuppressStateSave = $true
    try {
        if ($script:IncludeArchivedBox) {
            $script:IncludeArchivedBox.Checked = Get-ConfigBoolValue -Config $config -Names @('includeArchived') -Default ([bool]$script:IncludeArchivedBox.Checked)
        }
        $script:DisableCodexAppsOnFast = Get-ConfigBoolValue -Config $config -Names @('disableAppsOnFast', 'disableAppsMcpOnFast', 'disableCodexAppsOnFast') -Default ([bool]$script:DisableCodexAppsOnFast)
        if ($script:TurnEndedNotifyBox) {
            $script:TurnEndedNotifyBox.Checked = Get-ConfigBoolValue -Config $config -Names @('turnCompletePopup', 'turnEndedNotify') -Default ([bool]$script:TurnEndedNotifyBox.Checked)
        }
        if ($script:UsePowerShellLaunchBox) {
            $script:UsePowerShellLaunchBox.Checked = Get-ConfigBoolValue -Config $config -Names @('usePowerShellTerminal', 'preferPowerShell') -Default ([bool]$script:UsePowerShellLaunchBox.Checked)
        }
        if ($script:ApprovalNeverLaunchBox) {
            $script:ApprovalNeverLaunchBox.Checked = Get-ConfigBoolValue -Config $config -Names @('approvalNeverOnLaunch', 'fullAccessOnLaunch', 'approvalModeNeverOnLaunch') -Default ([bool]$script:ApprovalNeverLaunchBox.Checked)
        }
        if ($script:LoadCheckedRecordBox) {
            $script:LoadCheckedRecordBox.Checked = Get-ConfigBoolValue -Config $config -Names @('loadChatOnLaunch', 'loadCheckedRecordOnLaunch', 'resumeCheckedRecordOnLaunch', 'loadSelectedRecordOnLaunch') -Default ([bool]$script:LoadCheckedRecordBox.Checked)
        }
        Import-LanguageWindowWidths (Get-ConfigPropertyValue -Config $config -Names @('windowWidthByLanguage', 'windowWidthsByLanguage'))
        $windowWidth = Get-ConfigIntValue -Config $config -Names @('windowWidth') -Default 0
        if ($windowWidth -gt 0) {
            Set-LanguageWindowWidth -Language $script:UiLanguage -Width $windowWidth
        }

        $language = Get-ConfigStringValue -Config $config -Names @('uiLanguage', 'language')
        if (-not [string]::IsNullOrWhiteSpace($language)) {
            Set-UiLanguage $language -RestoreWindowWidth
        }
        if ($script:LimitBox) {
            $limit = Get-ConfigIntValue -Config $config -Names @('limit', 'displayLimit') -Default ([int]$script:LimitBox.Value)
            $script:LimitBox.Value = [Math]::Min([int]$script:LimitBox.Maximum, [Math]::Max([int]$script:LimitBox.Minimum, $limit))
        }

        Set-ConfiguredCodexExecutable $codexExeValue
        if (-not [string]::IsNullOrWhiteSpace($codexHomeValue)) {
            Set-CodexHomeFromSelection -SelectedPath $codexHomeValue -SkipConfigSync -SkipRefresh
        }
        if (-not [string]::IsNullOrWhiteSpace($ccSwitchHomeValue)) {
            Set-CcSwitchHomeFromSelection -SelectedPath $ccSwitchHomeValue -SkipConfigSync
        }

        Refresh-Providers
        $source = Get-ConfigStringValue -Config $config -Names @('defaultSourceProvider', 'sourceProvider')
        $target = Get-ConfigStringValue -Config $config -Names @('defaultTargetProvider', 'targetProvider')
        if (-not [string]::IsNullOrWhiteSpace($source)) { Select-Provider $script:SourceCombo $source }
        Update-TargetProviderComboForCurrentSource -PreferredProvider $target
        Update-CcSwitchAccountComboForCurrentSource

        $ccNode = Get-ConfigStringValue -Config $config -Names @('defaultCcSwitchNode', 'ccSwitchNode')
        Select-CcSwitchProviderFromConfig $ccNode

        Refresh-CwdOptions
        $cwdFilter = Get-ConfigStringValue -Config $config -Names @('directoryFilter', 'cwd')
        Select-CwdFilterFromConfig $cwdFilter
        Refresh-Threads
    }
    finally {
        $script:SuppressStateSave = $oldSuppressStateSave
    }

    if (-not $Silent) {
        [System.Windows.Forms.MessageBox]::Show(
            "配置已加载。`r`n`r`n$Path",
            '软件配置文件',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    Append-Log "已加载配置文件：$Path"
    Save-AppState
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-CodexExecutableForConfig {
    if (-not [string]::IsNullOrWhiteSpace($script:ConfiguredCodexExe)) {
        return [string]$script:ConfiguredCodexExe
    }
    try {
        return (Get-CodexExecutable)
    }
    catch {
        return ''
    }
}

function Get-DetectedCodexHistoryProvidersForConfig {
    $providers = @()
    if ($script:SourceCombo) {
        for ($i = 0; $i -lt $script:SourceCombo.Items.Count; $i++) {
            $label = [string]$script:SourceCombo.Items[$i]
            $value = Resolve-ProviderValue $label
            if ([string]::IsNullOrWhiteSpace($value)) { $value = $label }
            $providers += [pscustomobject][ordered]@{
                label = $label
                value = $value
            }
        }
    }
    return $providers
}

function Get-DetectedCcSwitchNodesForConfig {
    $nodes = @()
    try {
        $rows = @(Get-CcSwitchCodexProviders)
    }
    catch {
        if ($script:OutputBox) {
            Append-Log "读取 cc-switch 节点列表失败，软件配置文件将暂不写入节点参考：$($_.Exception.Message)"
        }
        return @()
    }

    foreach ($row in $rows) {
        $nodes += [pscustomobject][ordered]@{
            id              = [string]$row.id
            name            = [string]$row.name
            historyProvider = Get-HistoryProviderFromCcSwitchProvider $row
            isCurrent       = [bool]$row.is_current
        }
    }
    return $nodes
}

function New-AppConfigObject {
    $state = Get-CurrentAppState
    $codexHomeValue = if (Test-CodexHomeReady) { [string]$CodexHome } else { [string]$state.codexHome }
    $ccSwitchHomeValue = ''
    if (-not [string]::IsNullOrWhiteSpace($script:CcSwitchDb)) {
        $ccSwitchHomeValue = Split-Path -Parent $script:CcSwitchDb
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$state.ccSwitchHome)) {
        $ccSwitchHomeValue = [string]$state.ccSwitchHome
    }

    return [pscustomobject][ordered]@{
        _help                      = [pscustomobject][ordered]@{
            howToUse                  = '这个文件是本机配置。点击软件里的【软件配置文件】会打开它；保存后软件会自动刷新。JSON 不支持注释，所以说明文字放在 _help 里。'
            codexHome                 = '加载codex账号时选择的 .codex 文件夹，必须包含 state_5.sqlite 和 sessions 文件夹。常见值：C:\Users\你的用户名\.codex。'
            ccSwitchHome              = 'cc-switch.db 所在目录；点击【加载cc-switch.db文件】成功后会自动写入这里。'
            codexExe                  = 'codex.exe 的完整路径；如果 PATH 已经能找到 codex.exe，可以留空。'
            defaultSourceProvider     = 'Codex 历史记录里的 model_provider 桶，例如 openai、custom、rightcode。可参考 knownCodexHistoryProviders。'
            defaultTargetProvider     = '同步目标 model_provider 桶。'
            defaultCcSwitchNode       = '从终端启动时使用的 cc-switch Codex 节点名字或 id。可参考 knownCcSwitchNodes。'
            usePowerShellTerminal     = 'true 表示从终端启动时优先用 PowerShell；false 表示优先用 CMD。'
            approvalNeverOnLaunch     = 'true 表示从终端启动 Codex 时追加 --dangerously-bypass-approvals-and-sandbox，跳过审批并关闭沙箱。'
            loadChatOnLaunch          = 'true 表示从终端启动时，如果【启动时加载聊天】已开启，就自动恢复当前选中的聊天；false 表示在当前目录下新建对话。'
            lastSavedAt               = '软件最后一次自动保存界面偏好的时间。'
            uiLanguage                = '界面语言。zh-CN 表示中文，en-US 表示英文。'
            windowWidthByLanguage     = '分别记录中文和英文界面下的窗口宽度，避免切换语言时互相覆盖。'
            knownCodexHistoryProviders = '软件自动检测到的历史记录账号列表，只作参考。'
            knownCcSwitchNodes        = '软件自动检测到的 cc-switch Codex 节点列表，只作参考。'
            security                  = '不要在这里写 API key、token、auth.json、config.toml 或 state_5.sqlite 内容。'
        }
        version                    = $script:AppVersion
        lastSavedAt                = [string]$state.savedAt
        codexHome                  = $codexHomeValue
        ccSwitchHome               = $ccSwitchHomeValue
        codexExe                   = Get-CodexExecutableForConfig
        defaultSourceProvider      = [string]$state.defaultSourceProvider
        defaultTargetProvider      = [string]$state.defaultTargetProvider
        defaultCcSwitchNode        = [string]$state.defaultCcSwitchNode
        directoryFilter            = [string]$state.directoryFilter
        limit                      = [int]$state.limit
        includeArchived            = [bool]$state.includeArchived
        disableAppsOnFast          = [bool]$state.disableAppsOnFast
        turnCompletePopup          = [bool]$state.turnCompletePopup
        usePowerShellTerminal      = [bool]$state.usePowerShellTerminal
        approvalNeverOnLaunch      = [bool]$state.approvalNeverOnLaunch
        loadChatOnLaunch           = [bool]$state.loadChatOnLaunch
        uiLanguage                 = [string]$state.uiLanguage
        windowWidthByLanguage      = $state.windowWidthByLanguage
        knownCodexHistoryProviders = @(Get-DetectedCodexHistoryProvidersForConfig)
        knownCcSwitchNodes         = @(Get-DetectedCcSwitchNodesForConfig)
    }
}

function Write-AppConfigObject {
    param([Parameter(Mandatory)]$Config)

    $json = $Config | ConvertTo-Json -Depth 12
    $current = ''
    if (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) {
        $current = Get-Content -LiteralPath $script:AutoConfigPath -Raw -Encoding UTF8
    }
    if ($current -eq $json) { return $false }

    $script:IgnoreConfigWatcherUntil = (Get-Date).AddSeconds(2)
    Write-DiagnosticLog "Writing app config; suppressing config watcher until $($script:IgnoreConfigWatcherUntil.ToString('o'))."
    [System.IO.File]::WriteAllText($script:AutoConfigPath, $json, $script:Utf8NoBom)
    return $true
}

function Save-AppPreferencesToConfigFile {
    param([switch]$CreateIfMissing)

    if ($script:ConfigReloadInProgress -or $script:ConfigPreferenceSaveInProgress) {
        Write-DiagnosticLog "Save-AppPreferencesToConfigFile skipped reload=$script:ConfigReloadInProgress prefSave=$script:ConfigPreferenceSaveInProgress."
        return
    }
    if (-not (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) -and -not $CreateIfMissing) {
        Write-DiagnosticLog 'Save-AppPreferencesToConfigFile skipped because config file does not exist.'
        return
    }

    $script:ConfigPreferenceSaveInProgress = $true
    try {
        Write-DiagnosticLog 'Save-AppPreferencesToConfigFile start.'
        $config = $null
        if (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) {
            try {
                $config = Get-Content -LiteralPath $script:AutoConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                if ($script:OutputBox) {
                    Append-Log "读取现有配置失败，将用当前界面状态重新生成配置文件：$($_.Exception.Message)"
                }
            }
        }
        if (-not $config) {
            $config = New-AppConfigObject
        }

        $state = Get-CurrentAppState
        $preferenceValues = [ordered]@{
            version                   = $script:AppVersion
            lastSavedAt               = [string]$state.savedAt
            codexHome                 = [string]$state.codexHome
            ccSwitchHome              = [string]$state.ccSwitchHome
            codexExe                  = Get-CodexExecutableForConfig
            defaultSourceProvider     = [string]$state.defaultSourceProvider
            defaultTargetProvider     = [string]$state.defaultTargetProvider
            defaultCcSwitchNode       = [string]$state.defaultCcSwitchNode
            directoryFilter           = [string]$state.directoryFilter
            limit                     = [int]$state.limit
            includeArchived           = [bool]$state.includeArchived
            disableAppsOnFast         = [bool]$state.disableAppsOnFast
            turnCompletePopup         = [bool]$state.turnCompletePopup
            usePowerShellTerminal     = [bool]$state.usePowerShellTerminal
            approvalNeverOnLaunch     = [bool]$state.approvalNeverOnLaunch
            loadChatOnLaunch          = [bool]$state.loadChatOnLaunch
            uiLanguage                = [string]$state.uiLanguage
            windowWidthByLanguage     = $state.windowWidthByLanguage
        }

        foreach ($entry in $preferenceValues.GetEnumerator()) {
            Set-ObjectProperty -Object $config -Name $entry.Key -Value $entry.Value
        }
        if ($config.PSObject.Properties['loadCheckedRecordOnLaunch']) {
            $config.PSObject.Properties.Remove('loadCheckedRecordOnLaunch')
        }
        if ($config.PSObject.Properties['_help'] -and $config._help) {
            Set-ObjectProperty -Object $config._help -Name 'loadChatOnLaunch' -Value 'true 表示从终端启动时，如果【启动时加载聊天】已开启，就自动恢复当前选中的聊天；false 表示在当前目录下新建对话。'
            if ($config._help.PSObject.Properties['loadCheckedRecordOnLaunch']) {
                $config._help.PSObject.Properties.Remove('loadCheckedRecordOnLaunch')
            }
        }

        $changed = Write-AppConfigObject $config
        Write-DiagnosticLog "Save-AppPreferencesToConfigFile done changed=$changed."
    }
    finally {
        $script:ConfigPreferenceSaveInProgress = $false
    }
}

function Sync-AppConfigFileWithDetectedInfo {
    param(
        [switch]$CreateIfMissing,
        [switch]$ForceCurrentCcSwitchHome
    )

    if (-not (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) -and -not $CreateIfMissing) {
        return
    }

    $config = New-AppConfigObject
    if (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $script:AutoConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in @(
                    'codexHome',
                    'ccSwitchHome',
                    'codexExe',
                    'defaultSourceProvider',
                    'defaultTargetProvider',
                    'defaultCcSwitchNode',
                    'directoryFilter',
                    'limit',
                    'includeArchived',
                    'disableAppsOnFast',
                    'turnCompletePopup',
                    'usePowerShellTerminal',
                    'approvalNeverOnLaunch',
                    'loadChatOnLaunch',
                    'uiLanguage',
                    'windowWidthByLanguage'
                )) {
                if ($ForceCurrentCcSwitchHome -and $name -eq 'ccSwitchHome') { continue }
                $value = Get-ConfigPropertyValue -Config $existing -Names @($name)
                if ($null -ne $value -and -not (Test-TemplatePlaceholderValue ([string]$value))) {
                    Set-ObjectProperty -Object $config -Name $name -Value $value
                }
            }
            $disableAppsValue = Get-ConfigPropertyValue -Config $existing -Names @('disableAppsOnFast', 'disableAppsMcpOnFast', 'disableCodexAppsOnFast')
            if ($null -ne $disableAppsValue -and -not (Test-TemplatePlaceholderValue ([string]$disableAppsValue))) {
                Set-ObjectProperty -Object $config -Name 'disableAppsOnFast' -Value $disableAppsValue
            }
        }
        catch {
            Append-Log "读取现有配置失败，将重新生成配置文件：$($_.Exception.Message)"
        }
    }

    if (Write-AppConfigObject $config) {
        Append-Log "已更新配置文件中的账号和路径提示：$script:AutoConfigPath"
    }
}

function Open-AppConfigFile {
    Sync-AppConfigFileWithDetectedInfo -CreateIfMissing
    Start-Process -FilePath notepad.exe -ArgumentList @($script:AutoConfigPath) | Out-Null
    Append-Log "已打开软件配置文件：$script:AutoConfigPath。保存后软件会自动刷新。"
}

function Start-AppConfigWatcher {
    if ($script:ConfigWatcher) { return }

    if (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf) {
        $script:ConfigWatcherLastWriteUtc = (Get-Item -LiteralPath $script:AutoConfigPath).LastWriteTimeUtc
    }

    $script:ConfigReloadTimer = New-Object System.Windows.Forms.Timer
    $script:ConfigReloadTimer.Interval = 700
    $script:ConfigReloadTimer.Add_Tick({
            $script:ConfigReloadTimer.Stop()
            if ($script:ConfigReloadInProgress) { return }
            if (-not (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf)) { return }

            $script:ConfigReloadInProgress = $true
            try {
                Write-DiagnosticLog 'Config reload timer importing app config.'
                Import-AppConfig -Path $script:AutoConfigPath -Silent
                Append-Log '检测到配置文件保存，已自动刷新配置。'
            }
            catch {
                Write-DiagnosticLog ("Config reload failed: " + (Format-DiagnosticError $_))
                Append-Log "自动刷新配置失败：$($_.Exception.Message)"
            }
            finally {
                Write-DiagnosticLog 'Config reload timer finished.'
                $script:ConfigReloadInProgress = $false
            }
        })

    $script:ConfigWatcher = New-Object System.Windows.Forms.Timer
    $script:ConfigWatcher.Interval = 1000
    $script:ConfigWatcher.Add_Tick({
            if (-not $script:Form -or $script:Form.IsDisposed) { return }
            if (-not (Test-Path -LiteralPath $script:AutoConfigPath -PathType Leaf)) { return }

            $lastWrite = (Get-Item -LiteralPath $script:AutoConfigPath).LastWriteTimeUtc
            if ($lastWrite -le $script:ConfigWatcherLastWriteUtc) { return }
            $script:ConfigWatcherLastWriteUtc = $lastWrite

            if ((Get-Date) -lt $script:IgnoreConfigWatcherUntil) {
                Write-DiagnosticLog "Config watcher polling ignored internal write until $($script:IgnoreConfigWatcherUntil.ToString('o'))."
                return
            }

            Write-DiagnosticLog 'Config watcher polling observed external config change.'
            if ($script:ConfigReloadTimer) {
                $script:ConfigReloadTimer.Stop()
                $script:ConfigReloadTimer.Start()
            }
        }
    )
    $script:ConfigWatcher.Start()
    Write-DiagnosticLog 'Config watcher polling timer started.'
}

function ConvertTo-AppVersion {
    param([AllowNull()][string]$Value)

    try {
        return [version]$Value
    }
    catch {
        return [version]'0.0.0.0'
    }
}

function Invoke-HttpDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [AllowNull()][string]$OutFile
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'Cache-Control' = 'no-cache'
        'User-Agent'    = 'codex-history-sync-portable'
    }
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        return (Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $headers).Content
    }
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -Headers $headers
}

function Get-RemoteAppVersion {
    $apiUri = "https://api.github.com/repos/$script:GitHubRepo/contents/tools/codex-history-sync-gui.ps1?ref=main"
    try {
        $api = Invoke-HttpDownload -Uri $apiUri | ConvertFrom-Json
        $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($api.content -replace '\s', '')))
    }
    catch {
        $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rawUri = "https://raw.githubusercontent.com/$script:GitHubRepo/main/tools/codex-history-sync-gui.ps1?ts=$stamp"
        $content = Invoke-HttpDownload -Uri $rawUri
    }
    $match = [System.Text.RegularExpressions.Regex]::Match($content, '\$script:AppVersion\s*=\s*''([^'']+)''')
    if (-not $match.Success) {
        $script:LastUpdateCheckNote = '远端版本暂未声明 AppVersion，无法判断它是否更新。'
        return '0.0.0.0'
    }
    $script:LastUpdateCheckNote = ''
    return $match.Groups[1].Value
}

function Copy-AppUpdateFiles {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $relativeItems = @(
        'assets',
        'bin',
        'tools',
        'codex-history-sync-config.template.json',
        'codex-history-sync-gui.cmd',
        'codex-history-sync-gui.vbs',
        'codex-history-sync.cmd',
        'README.md',
        'README.zh-CN.md'
    )

    foreach ($relative in $relativeItems) {
        $source = Join-Path $SourceRoot $relative
        if (-not (Test-Path -LiteralPath $source)) { continue }

        if (Test-Path -LiteralPath $source -PathType Container) {
            $sourceRootFull = (Resolve-Path -LiteralPath $source).Path
            foreach ($file in Get-ChildItem -LiteralPath $sourceRootFull -Recurse -Force -File) {
                $relativeFile = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
                $dest = Join-Path $script:RootDir $relativeFile
                $destDir = Split-Path -Parent $dest
                if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            }
        }
        else {
            $dest = Join-Path $script:RootDir $relative
            Copy-Item -LiteralPath $source -Destination $dest -Force
        }
    }
}

function ConvertTo-ProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutMilliseconds = 30000
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $process.StartInfo.WorkingDirectory = $WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    [void]$process.Start()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{
            ExitCode = -1
            Output   = ''
            Error    = "process timed out after $TimeoutMilliseconds ms"
        }
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $stdout
        Error    = $stderr
    }
}

function Get-GitCommandPath {
    foreach ($name in @('git.exe', 'git')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
            return $cmd.Source
        }
    }
    return $null
}

function Invoke-GitHubRepositorySync {
    $gitDir = Join-Path $script:RootDir '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Append-Log '当前目录不是 Git checkout，跳过 GitHub 自动同步，继续使用 ZIP 热更新。'
        return $false
    }

    $git = Get-GitCommandPath
    if ([string]::IsNullOrWhiteSpace($git)) {
        Append-Log '未找到 git 命令，跳过 GitHub 自动同步，继续使用 ZIP 热更新。'
        return $false
    }

    $remote = Invoke-ProcessCapture -FilePath $git -Arguments @('remote', 'get-url', 'origin') -WorkingDirectory $script:RootDir -TimeoutMilliseconds 10000
    if ($remote.ExitCode -ne 0) {
        Append-Log "读取 Git origin 失败，跳过 GitHub 自动同步：$($remote.Error.Trim())"
        return $false
    }

    $remoteUrl = (($remote.Output + $remote.Error).Trim()).ToLowerInvariant()
    $expectedRepo = $script:GitHubRepo.ToLowerInvariant()
    if ($remoteUrl -notlike "*$expectedRepo*") {
        Append-Log "Git origin 不是 $script:GitHubRepo，跳过 GitHub 自动同步：$($remoteUrl)"
        return $false
    }

    $status = Invoke-ProcessCapture -FilePath $git -Arguments @('status', '--porcelain') -WorkingDirectory $script:RootDir -TimeoutMilliseconds 10000
    if ($status.ExitCode -ne 0) {
        Append-Log "读取 Git 工作区状态失败，跳过 GitHub 自动同步：$($status.Error.Trim())"
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace(($status.Output + $status.Error).Trim())) {
        Append-Log '检测到本地 Git 工作区已有未提交改动，跳过 GitHub 自动同步，避免覆盖本地改动；继续使用 ZIP 热更新。'
        return $false
    }

    Append-Log '当前目录是干净的 GitHub checkout，正在自动同步 GitHub main...'
    $pull = Invoke-ProcessCapture -FilePath $git -Arguments @('pull', '--ff-only', 'origin', 'main') -WorkingDirectory $script:RootDir -TimeoutMilliseconds 60000
    $pullText = (($pull.Output + $pull.Error).Trim())
    if ($pull.ExitCode -ne 0) {
        Append-Log "GitHub 自动同步失败，继续使用 ZIP 热更新：$pullText"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($pullText)) {
        $pullText = 'git pull --ff-only origin main completed.'
    }
    Append-Log "GitHub 自动同步完成：$pullText"
    return $true
}

function Restart-AppAfterUpdate {
    $launcher = Join-Path $script:RootDir 'codex-history-sync-gui.vbs'
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        Start-Process -FilePath wscript.exe -ArgumentList $launcher -WindowStyle Hidden | Out-Null
    }
    else {
        Start-Process -FilePath powershell.exe -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            (Join-Path $script:ToolDir 'codex-history-sync-gui.ps1')
        ) -WindowStyle Hidden | Out-Null
    }
    $script:Form.Close()
}

function Invoke-AppSelfUpdate {
    Append-Log '正在检查 GitHub 更新...'
    $remoteVersion = Get-RemoteAppVersion
    $local = ConvertTo-AppVersion $script:AppVersion
    $remote = ConvertTo-AppVersion $remoteVersion

    if ($remote -le $local) {
        $note = if ([string]::IsNullOrWhiteSpace($script:LastUpdateCheckNote)) { '' } else { "`r`n`r`n$script:LastUpdateCheckNote" }
        [System.Windows.Forms.MessageBox]::Show(
            "当前未发现可用新版。`r`n`r`n本地：$script:AppVersion`r`n远端：$remoteVersion$note",
            '检查更新',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Append-Log "当前未发现可用新版。本地：$script:AppVersion；远端：$remoteVersion"
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "发现新版本。是否立即下载并热更新？`r`n`r`n本地：$script:AppVersion`r`n远端：$remoteVersion`r`n`r`n更新不会覆盖 codex-history-sync-config.json、数据库或认证文件。",
        '发现更新',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Append-Log '已取消更新。'
        return
    }

    $updatedByGit = Invoke-GitHubRepositorySync
    $tempDir = $null
    try {
        if (-not $updatedByGit) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-history-sync-update-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $zipPath = Join-Path $tempDir 'main.zip'

            $zipUri = "https://github.com/$script:GitHubRepo/archive/refs/heads/main.zip"
            Append-Log "正在下载更新包：$zipUri"
            Invoke-HttpDownload -Uri $zipUri -OutFile $zipPath

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempDir)
            $sourceRoot = Get-ChildItem -LiteralPath $tempDir -Directory |
                Where-Object { $_.Name -like 'codex-history-sync-portable-*' } |
                Select-Object -First 1
            if (-not $sourceRoot) {
                throw '更新包结构不符合预期。'
            }

            Copy-AppUpdateFiles -SourceRoot $sourceRoot.FullName
        }

        Append-Log "更新完成：$script:AppVersion -> $remoteVersion"

        $restart = [System.Windows.Forms.MessageBox]::Show(
            "更新已完成。是否立即重启界面并加载新版？",
            '更新完成',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($restart -eq [System.Windows.Forms.DialogResult]::Yes) {
            Restart-AppAfterUpdate
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempDir)) {
            try { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
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

function Get-ThreadRolloutPathById {
    param([AllowNull()][string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return '' }
    $rows = @(Invoke-SqlJson "SELECT rollout_path FROM threads WHERE id = $(Quote-Sql $ThreadId) LIMIT 1;")
    if ($rows.Count -eq 0) { return '' }
    return Convert-CodexFilePath ([string]$rows[0].rollout_path)
}

function Resolve-SelectedRecordDirectory {
    Assert-CodexHomeReady

    $rolloutPath = Convert-CodexFilePath ([string](Get-CurrentGridValue 'RolloutPath'))
    if ([string]::IsNullOrWhiteSpace($rolloutPath)) {
        $threadId = [string](Get-CurrentGridValue 'Id')
        $rolloutPath = Get-ThreadRolloutPathById $threadId
    }

    if (-not [string]::IsNullOrWhiteSpace($rolloutPath) -and
        (Test-Path -LiteralPath $rolloutPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $rolloutPath)).Path
    }

    $sessionsDir = Join-Path $CodexHome 'sessions'
    if (Test-Path -LiteralPath $sessionsDir -PathType Container) {
        return (Resolve-Path -LiteralPath $sessionsDir).Path
    }

    return $CodexHome
}

function Resolve-LaunchDirectory {
    param([AllowNull()][string]$PreferredCwd)

    Assert-CodexHomeReady
    $cwd = [string]$PreferredCwd
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = [string](Get-CurrentGridValue 'Cwd')
    }
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

function Resolve-CodexExecutableFromValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $path = Convert-CodexPath $Value
    if (Test-Path -LiteralPath $path -PathType Container) {
        $path = Join-Path $path 'codex.exe'
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $path).Path
    }
    return $null
}

function Get-CodexExecutable {
    foreach ($path in @($script:ConfiguredCodexExe, $env:CODEX_EXE)) {
        $resolved = Resolve-CodexExecutableFromValue $path
        if ($resolved) { return $resolved }
    }

    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $fallback = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    throw "找不到 codex.exe。请确认 Codex CLI 已安装并加入 PATH；或点击【软件配置文件】，填写 codexExe 后保存。配置文件：$script:AutoConfigPath"
}

function Test-CodexSupportsBypassFullAccess {
    param([Parameter(Mandatory)][string]$CodexExe)

    if ($null -ne $script:CodexSupportsBypassFullAccess) {
        return [bool]$script:CodexSupportsBypassFullAccess
    }

    try {
        $help = (& $CodexExe --help 2>&1 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $script:CodexSupportsBypassFullAccess = ($help -match '--dangerously-bypass-approvals-and-sandbox')
    }
    catch {
        $script:CodexSupportsBypassFullAccess = $false
    }

    return [bool]$script:CodexSupportsBypassFullAccess
}

function ConvertTo-PowerShellSingleQuotedString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-CmdArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"&|<>^()]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-LaunchShell {
    param([bool]$PreferPowerShell = $false)

    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $cmd = Get-Command cmd.exe -ErrorAction SilentlyContinue
    $choices = if ($PreferPowerShell) { @($powershell, $cmd) } else { @($cmd, $powershell) }
    foreach ($choice in $choices) {
        if (-not $choice) { continue }
        $name = if ([string]$choice.Name -ieq 'powershell.exe') { 'PowerShell' } else { 'CMD' }
        return [pscustomobject]@{
            Name = $name
            Path = $choice.Source
        }
    }

    throw '找不到 powershell.exe 或 cmd.exe，无法启动 Codex。'
}

function Get-CodexProjectTrustPath {
    param([Parameter(Mandatory)][string]$Directory)

    return (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('\').ToLowerInvariant()
}

function Get-CodexProjectTrustOverrideArg {
    param([Parameter(Mandatory)][string]$Directory)

    $resolved = Get-CodexProjectTrustPath -Directory $Directory
    $projectKey = ConvertTo-TomlBasicString $resolved
    return 'projects.{0}.trust_level="trusted"' -f $projectKey
}

function ConvertTo-TomlLiteralString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    return "'" + $Value + "'"
}

function Add-CodexProjectTrust {
    param([Parameter(Mandatory)][string]$Directory)

    Assert-CodexHomeReady
    $configPath = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }

    $resolved = Get-CodexProjectTrustPath -Directory $Directory
    $projectKey = ConvertTo-TomlBasicString $resolved
    $header = "[projects.$projectKey]"
    $configText = Get-Content -LiteralPath $configPath -Raw

    $headersToCheck = @(
        $header,
        ("[projects.{0}]" -f (ConvertTo-TomlLiteralString $resolved))
    )
    $sectionMatch = $null
    foreach ($candidateHeader in $headersToCheck) {
        $sectionPattern = "(?ms)^\s*$([regex]::Escape($candidateHeader))\s*\r?\n(?:(?!^\s*\[).)*"
        $candidateMatch = [System.Text.RegularExpressions.Regex]::Match($configText, $sectionPattern)
        if ($candidateMatch.Success) {
            $sectionMatch = $candidateMatch
            break
        }
    }
    if ($sectionMatch.Success) {
        $sectionText = $sectionMatch.Value
        $trustPattern = '(?m)^\s*trust_level\s*=\s*["''][^"'']*["'']\s*$'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($sectionText, '(?m)^\s*trust_level\s*=\s*["'']trusted["'']\s*$')) {
            return
        }

        if ([System.Text.RegularExpressions.Regex]::IsMatch($sectionText, $trustPattern)) {
            $replacement = [System.Text.RegularExpressions.Regex]::Replace($sectionText, $trustPattern, 'trust_level = "trusted"', 1)
        }
        else {
            if (-not $sectionText.EndsWith([Environment]::NewLine)) {
                $sectionText += [Environment]::NewLine
            }
            $replacement = $sectionText + 'trust_level = "trusted"' + [Environment]::NewLine
        }
        $configText = $configText.Remove($sectionMatch.Index, $sectionMatch.Length).Insert($sectionMatch.Index, $replacement)
        [System.IO.File]::WriteAllText($configPath, $configText, $script:Utf8NoBom)
        Append-Log "已更新 Codex 工作目录信任配置：$resolved"
        return
    }

    if (-not $configText.EndsWith([Environment]::NewLine)) {
        $configText += [Environment]::NewLine
    }
    $configText += [Environment]::NewLine + $header + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine
    [System.IO.File]::WriteAllText($configPath, $configText, $script:Utf8NoBom)
    Append-Log "已信任 Codex 工作目录，避免启动时重复确认：$resolved"
}

function Start-CodexInDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [bool]$DisableApps,
        [bool]$ApprovalNever,
        [AllowNull()][string]$ResumeId,
        [bool]$PreferPowerShell
    )

    $codexExe = Get-CodexExecutable
    $commonArgs = New-Object System.Collections.Generic.List[string]
    $resolvedDirectory = (Resolve-Path -LiteralPath $Directory).Path
    $commonArgs.Add('-C')
    $commonArgs.Add($resolvedDirectory)
    if ($DisableApps) {
        $commonArgs.Add('--disable')
        $commonArgs.Add('apps')
    }
    if ($ApprovalNever) {
        if (Test-CodexSupportsBypassFullAccess -CodexExe $codexExe) {
            $commonArgs.Add('--dangerously-bypass-approvals-and-sandbox')
        }
        else {
            $commonArgs.Add('--sandbox')
            $commonArgs.Add('danger-full-access')
            $commonArgs.Add('-a')
            $commonArgs.Add('never')
        }
    }
    $codexArgs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ResumeId)) {
        $safeResumeId = $ResumeId.Trim()
        if ($safeResumeId -match '[\s"&|<>^]') {
            throw "会话 ID 包含终端不支持的字符，无法安全启动：$safeResumeId"
        }
        $codexArgs.Add('resume')
        foreach ($arg in $commonArgs) { $codexArgs.Add($arg) }
        $codexArgs.Add($safeResumeId)
    }
    else {
        foreach ($arg in $commonArgs) { $codexArgs.Add($arg) }
    }

    $shell = Get-LaunchShell -PreferPowerShell:$PreferPowerShell
    Write-DiagnosticLog ("Start-CodexInDirectory shell={0} directory='{1}' resume='{2}' args=[{3}]" -f
        $shell.Name,
        $resolvedDirectory,
        $ResumeId,
        (($codexArgs | ForEach-Object { [string]$_ }) -join ', '))

    if ($shell.Name -eq 'PowerShell') {
        $adminPrelude = @(
            '$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
            'if ($isAdmin) { $Host.UI.RawUI.WindowTitle = ''管理员 PowerShell - Codex''; Write-Host ''[管理员模式] 当前终端已提权'' -ForegroundColor Green } else { $Host.UI.RawUI.WindowTitle = ''非管理员 PowerShell - Codex''; Write-Host ''[非管理员] 当前终端未提权'' -ForegroundColor Yellow }'
        ) -join '; '
        $psExitLog = '; $codexExit = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }; Write-Host (''[Codex退出码] '' + $codexExit) -ForegroundColor Yellow; Add-Content -LiteralPath ' +
            (ConvertTo-PowerShellSingleQuotedString $script:DiagnosticLogPath) +
            ' -Encoding UTF8 -Value (''['' + (Get-Date -Format ''yyyy-MM-dd HH:mm:ss.fff zzz'') + ''] [' +
            $script:DiagnosticSessionId +
            '] Codex process exited code='' + $codexExit)'
        $psCommand = $adminPrelude + '; ' + ('Set-Location -LiteralPath {0}; & {1} {2}' -f
            (ConvertTo-PowerShellSingleQuotedString $resolvedDirectory),
            (ConvertTo-PowerShellSingleQuotedString $codexExe),
            (($codexArgs | ForEach-Object { ConvertTo-PowerShellSingleQuotedString $_ }) -join ' ')) + $psExitLog
        $psArgs = @(
            '-NoExit',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            $psCommand
        )
        Start-Process -FilePath $shell.Path `
            -WorkingDirectory $resolvedDirectory `
            -ArgumentList $psArgs `
            -Verb RunAs
        Write-DiagnosticLog "Start-Process launched PowerShell for Codex."
        return $shell.Name
    }

    $commandParts = @((ConvertTo-CmdArgument $codexExe)) + @($codexArgs | ForEach-Object { ConvertTo-CmdArgument $_ })
    $codexCommand = ($commandParts -join ' ').Trim()
    $adminPrelude = '(fltmc >nul 2>&1 && (title 管理员 CMD - Codex && echo [管理员模式] 当前终端已提权) || (title 非管理员 CMD - Codex && echo [非管理员] 当前终端未提权))'
    $cmdExitLog = ' & set CODEX_EXIT=%ERRORLEVEL% & echo [Codex退出码] %CODEX_EXIT% & echo [%DATE% %TIME%] [' + $script:DiagnosticSessionId + '] Codex process exited code=%CODEX_EXIT%>> ' + (ConvertTo-CmdArgument $script:DiagnosticLogPath)
    $command = $adminPrelude + ' & cd /d ' + (ConvertTo-CmdArgument $resolvedDirectory) + ' && ' + $codexCommand + $cmdExitLog
    Start-Process -FilePath $shell.Path `
        -WorkingDirectory $resolvedDirectory `
        -ArgumentList @('/d', '/k', $command) `
        -Verb RunAs
    Write-DiagnosticLog "Start-Process launched CMD for Codex."
    return $shell.Name
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

    $rows = @(Get-CcSwitchCodexProviders | Where-Object {
            Test-CcSwitchProviderAllowedForHistoryProvider -ProviderRow $_ -HistoryProvider $HistoryProvider
        })
    if ($rows.Count -eq 0) {
        throw "找不到与历史账号 '$HistoryProvider' 对应的 cc-switch Codex provider。"
    }

    foreach ($row in $rows) {
        if ([bool]$row.is_current) { return $row }
    }
    return $rows[0]
}

function Get-CcSwitchProviderById {
    param([Parameter(Mandatory)][string]$ProviderId)

    $safe = Quote-Sql $ProviderId
    $rows = Invoke-CcSwitchSqlJson "select id,name,settings_config from providers where app_type='codex' and id=$safe limit 1;"
    if ($rows.Count -eq 0) {
        throw "找不到 cc-switch Codex 节点 '$ProviderId'。请点击【加载cc-switch.db文件】选择 cc-switch.db，然后刷新。"
    }
    return $rows[0]
}

function Get-CodexConfigStringValue {
    param(
        [AllowNull()][string]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Config)) { return '' }
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*["'']([^"'']*)["'']\s*$'
    $match = [System.Text.RegularExpressions.Regex]::Match($Config, $pattern)
    if (-not $match.Success) { return '' }
    return $match.Groups[1].Value
}

function Get-CodexModelProviderNameFromConfig {
    param(
        [AllowNull()][string]$Config,
        [AllowNull()][string]$ProviderId
    )

    if ([string]::IsNullOrWhiteSpace($Config) -or [string]::IsNullOrWhiteSpace($ProviderId)) { return '' }
    $sectionPattern = '(?ms)^\s*\[model_providers\.' + [regex]::Escape($ProviderId.Trim()) + '\]\s*\r?\n(?<body>.*?)(?=^\s*\[|\z)'
    $section = [System.Text.RegularExpressions.Regex]::Match($Config, $sectionPattern)
    if (-not $section.Success) { return '' }
    return Get-CodexConfigStringValue $section.Groups['body'].Value 'name'
}

function Get-SyncTargetProfileArgs {
    param([Parameter(Mandatory)][string]$TargetProvider)

    $args = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb)) { return $args.ToArray() }

    try {
        $provider = Get-CcSwitchProviderForHistoryProvider $TargetProvider
        $settings = [string]$provider.settings_config | ConvertFrom-Json
        $config = [string]$settings.config

        $model = Get-CodexConfigStringValue $config 'model'
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $args.Add('-TargetModel')
            $args.Add($model)
        }

        $reasoningEffort = Get-CodexConfigStringValue $config 'model_reasoning_effort'
        if ([string]::IsNullOrWhiteSpace($reasoningEffort)) {
            $reasoningEffort = Get-CodexConfigStringValue $config 'reasoning_effort'
        }
        if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) {
            $args.Add('-TargetReasoningEffort')
            $args.Add($reasoningEffort)
        }

        if (-not (Test-CcSwitchOfficialProvider $provider)) {
            $args.Add('-SanitizeForProxy')
        }
    }
    catch {
        Append-Log "未能读取目标账号的 cc-switch 续聊配置，已按原始记录同步：$($_.Exception.Message)"
    }

    return $args.ToArray()
}

function Test-CcSwitchOfficialProvider {
    param([Parameter(Mandatory)]$Provider)

    return ([string]$Provider.id) -eq 'codex-official'
}

function Normalize-ProviderKey {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().ToLowerInvariant()
}

function Test-CcSwitchProviderAllowedForHistoryProvider {
    param(
        [Parameter(Mandatory)]$ProviderRow,
        [AllowNull()][string]$HistoryProvider
    )

    $history = Normalize-ProviderKey $HistoryProvider
    if ([string]::IsNullOrWhiteSpace($history)) { return $true }

    $mappedHistory = Normalize-ProviderKey (Get-HistoryProviderFromCcSwitchProvider $ProviderRow)
    if ($history -in @('openai', 'custom', 'rightcode')) {
        return $mappedHistory -eq $history
    }

    if ($mappedHistory -eq $history) { return $true }

    $id = Normalize-ProviderKey ([string]$ProviderRow.id)
    $name = Normalize-ProviderKey ([string]$ProviderRow.name)
    return $id -eq $history -or $name -eq $history -or $name -like "*$history*"
}

function Assert-CcSwitchProviderAllowedForHistoryProvider {
    param(
        [Parameter(Mandatory)]$ProviderRow,
        [AllowNull()][string]$HistoryProvider
    )

    if (Test-CcSwitchProviderAllowedForHistoryProvider -ProviderRow $ProviderRow -HistoryProvider $HistoryProvider) {
        return
    }

    $providerName = Get-CcSwitchAccountLabel $ProviderRow
    throw "当前源账号 '$HistoryProvider' 不能使用 cc-switch 供应商 '$providerName' 启动。已阻止本次启动，避免账号与聊天记录类型不匹配导致 Codex 闪退。请刷新后选择匹配的 cc-switch 供应商。"
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

function Add-CodexConfigFixMessage {
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    if ([string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
        $script:LastCodexConfigFix = $Message
    }
    elseif ($script:LastCodexConfigFix -notmatch [regex]::Escape($Message)) {
        $script:LastCodexConfigFix = $script:LastCodexConfigFix + [Environment]::NewLine + $Message
    }
}

function ConvertTo-TomlSafeString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    if ($Value -notmatch "'") {
        return ConvertTo-TomlLiteralString $Value
    }
    return ConvertTo-TomlBasicString $Value
}

function Get-TomlSectionMatch {
    param(
        [AllowNull()][string]$Config,
        [Parameter(Mandatory)][string]$SectionName
    )

    if ([string]::IsNullOrWhiteSpace($Config)) { return $null }
    $pattern = '(?ms)^\s*\[' + [regex]::Escape($SectionName) + '\]\s*\r?\n.*?(?=^\s*\[|\z)'
    $match = [System.Text.RegularExpressions.Regex]::Match($Config, $pattern)
    if ($match.Success) { return $match }
    return $null
}

function Get-TomlSectionStringValue {
    param(
        [AllowNull()][string]$Config,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][string]$Name
    )

    $match = Get-TomlSectionMatch -Config $Config -SectionName $SectionName
    if (-not $match) { return '' }
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*(?<value>"(?:\\.|[^"\\])*"|''[^'']*''|[^\r\n#]+)'
    $valueMatch = [System.Text.RegularExpressions.Regex]::Match($match.Value, $pattern)
    if (-not $valueMatch.Success) { return '' }
    return (ConvertFrom-TomlNotifyString $valueMatch.Groups['value'].Value.Trim())
}

function Set-TomlSectionStringValue {
    param(
        [AllowNull()][string]$Config,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Config) { $Config = '' }
    $tomlValue = ConvertTo-TomlSafeString $Value
    $line = "$Name = $tomlValue"
    $match = Get-TomlSectionMatch -Config $Config -SectionName $SectionName
    if (-not $match) {
        if (-not $Config.EndsWith([Environment]::NewLine)) {
            $Config += [Environment]::NewLine
        }
        return $Config + [Environment]::NewLine + "[$SectionName]" + [Environment]::NewLine + $line + [Environment]::NewLine
    }

    $sectionText = $match.Value
    $linePattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=.*$'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($sectionText, $linePattern)) {
        $sectionText = [System.Text.RegularExpressions.Regex]::Replace($sectionText, $linePattern, $line, 1)
    }
    else {
        if (-not $sectionText.EndsWith([Environment]::NewLine)) {
            $sectionText += [Environment]::NewLine
        }
        $sectionText += $line + [Environment]::NewLine
    }

    return $Config.Remove($match.Index, $match.Length).Insert($match.Index, $sectionText)
}

function Remove-TomlSection {
    param(
        [AllowNull()][string]$Config,
        [Parameter(Mandatory)][string]$SectionName
    )

    $match = Get-TomlSectionMatch -Config $Config -SectionName $SectionName
    if (-not $match) { return $Config }
    return $Config.Remove($match.Index, $match.Length).TrimEnd() + [Environment]::NewLine
}

function Test-PathListHasExistingItem {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($part in ($Value -split ';')) {
        $path = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return $false
}

function Get-CodexDesktopRuntimeFile {
    param([Parameter(Mandatory)][string]$FileName)

    $root = Join-OptionalPath $env:LOCALAPPDATA 'OpenAI\Codex'
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        return ''
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
            (Join-Path $root "bin\$FileName")
        )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $candidates.Contains($path)) {
            $candidates.Add($path)
        }
    }

    foreach ($parent in @(
            (Join-Path $root 'runtimes\cua_node'),
            (Join-Path $root 'bin')
        )) {
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        try {
            foreach ($hit in @(Get-ChildItem -LiteralPath $parent -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending)) {
                if (-not $candidates.Contains($hit.FullName)) {
                    $candidates.Add($hit.FullName)
                }
            }
        }
        catch {
            continue
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ''
}

function Get-CodexDesktopNodeModulesPath {
    param([AllowNull()][string]$RelatedExecutable)

    $paths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RelatedExecutable)) {
        $paths.Add((Join-Path (Split-Path -Parent $RelatedExecutable) 'node_modules'))
    }
    $runtimeRoot = Join-OptionalPath $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
    if (-not [string]::IsNullOrWhiteSpace($runtimeRoot)) {
        $paths.Add($runtimeRoot)
    }

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath $path -PathType Container) {
            if ((Split-Path -Leaf $path) -ieq 'cua_node') {
                try {
                    $hit = Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending |
                        ForEach-Object { Join-Path $_.FullName 'bin\node_modules' } |
                        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
                        Select-Object -First 1
                    if ($hit) { return (Resolve-Path -LiteralPath $hit).Path }
                }
                catch {
                    continue
                }
            }
            else {
                return (Resolve-Path -LiteralPath $path).Path
            }
        }
    }
    return ''
}

function Repair-NodeReplMcpConfig {
    param([AllowNull()][string]$Config)

    if ([string]::IsNullOrWhiteSpace($Config)) { return $Config }
    if (-not (Get-TomlSectionMatch -Config $Config -SectionName 'mcp_servers.node_repl')) {
        return $Config
    }

    $configText = $Config
    $currentCommand = Get-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl' -Name 'command'
    $commandExists = -not [string]::IsNullOrWhiteSpace($currentCommand) -and (Test-Path -LiteralPath $currentCommand -PathType Leaf)
    $nodeReplPath = if ($commandExists) { (Resolve-Path -LiteralPath $currentCommand).Path } else { Get-CodexDesktopRuntimeFile 'node_repl.exe' }

    if ([string]::IsNullOrWhiteSpace($nodeReplPath)) {
        $configText = Remove-TomlSection -Config $configText -SectionName 'mcp_servers.node_repl.env'
        $configText = Remove-TomlSection -Config $configText -SectionName 'mcp_servers.node_repl'
        Add-CodexConfigFixMessage '未找到可用 node_repl.exe，已移除失效的 node_repl MCP 配置，避免 Codex 启动时报 MCP 路径错误。'
        return $configText
    }

    if (-not $commandExists -or -not [string]::Equals($currentCommand, $nodeReplPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $configText = Set-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl' -Name 'command' -Value $nodeReplPath
        Add-CodexConfigFixMessage "已修复 node_repl MCP 启动路径：$nodeReplPath"
    }

    $currentNodePath = Get-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'NODE_REPL_NODE_PATH'
    if (-not (Test-PathListHasExistingItem $currentNodePath)) {
        $nodePath = Get-CodexDesktopRuntimeFile 'node.exe'
        if (-not [string]::IsNullOrWhiteSpace($nodePath)) {
            $configText = Set-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'NODE_REPL_NODE_PATH' -Value $nodePath
            Add-CodexConfigFixMessage "已修复 node_repl Node 路径：$nodePath"
        }
    }

    $currentNodeModules = Get-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'NODE_REPL_NODE_MODULE_DIRS'
    if (-not (Test-PathListHasExistingItem $currentNodeModules)) {
        $nodeModules = Get-CodexDesktopNodeModulesPath -RelatedExecutable $nodeReplPath
        if (-not [string]::IsNullOrWhiteSpace($nodeModules)) {
            $configText = Set-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'NODE_REPL_NODE_MODULE_DIRS' -Value $nodeModules
            Add-CodexConfigFixMessage "已修复 node_repl node_modules 路径：$nodeModules"
        }
    }

    $currentCodexCli = Get-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'CODEX_CLI_PATH'
    if (-not (Test-PathListHasExistingItem $currentCodexCli)) {
        try {
            $codexCli = Get-CodexExecutable
            if (-not [string]::IsNullOrWhiteSpace($codexCli)) {
                $configText = Set-TomlSectionStringValue -Config $configText -SectionName 'mcp_servers.node_repl.env' -Name 'CODEX_CLI_PATH' -Value $codexCli
                Add-CodexConfigFixMessage "已修复 node_repl Codex CLI 路径：$codexCli"
            }
        }
        catch {
            Add-CodexConfigFixMessage "node_repl MCP 的 CODEX_CLI_PATH 已失效，但暂未找到 codex.exe；如仍报错，请在【软件配置文件】里填写 codexExe。"
        }
    }

    return $configText
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
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $notifyArgs += @('-CodexHome', $CodexHome)
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

    Add-CodexConfigFixMessage '已启用 Codex 会话结束右下角置顶弹窗提醒。'
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
    $configText = Repair-NodeReplMcpConfig $configText
    $configText = Set-CodexTurnEndedNotify $configText
    [System.IO.File]::WriteAllText($configPath, $configText, $script:Utf8NoBom)
    if (-not [string]::IsNullOrWhiteSpace($script:LastCodexConfigFix)) {
        Append-Log $script:LastCodexConfigFix
    }
    Append-Log "已写入弹窗提醒 CLI notify 配置：$configPath"
}

function Show-TestTurnEndedNotify {
    if ([string]::IsNullOrWhiteSpace($script:NotifierPath) -or
        -not (Test-Path -LiteralPath $script:NotifierPath)) {
        throw "未找到会话结束提醒脚本：$script:NotifierPath"
    }

    $message = "账号：custom | 示例项目`r`n聊天：019eb473`r`n任务：测试弹窗显示完成摘要"
    $messageBase64 = [Convert]::ToBase64String($script:Utf8NoBom.GetBytes($message))
    Start-Process -FilePath powershell.exe -ArgumentList @(
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        $script:NotifierPath,
        '-CodexHome',
        $CodexHome,
        '-MessageBase64',
        $messageBase64,
        '-Seconds',
        '8'
    ) -WindowStyle Hidden | Out-Null
    Append-Log '已触发测试弹窗。'
}

function Stop-ExistingTurnCompleteMonitor {
    try {
        $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $currentPid -and
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                (
                    $_.CommandLine -match 'codex-turn-complete-monitor\.ps1' -or
                    $_.CommandLine -match 'codex-turn-complete-monitor\.vbs'
                )
            })
        foreach ($process in $processes) {
            try {
                Invoke-CimMethod -InputObject $process -MethodName Terminate | Out-Null
            }
            catch {
                try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        if ($processes.Count -gt 0) {
            Append-Log "已清理旧版桌面完成监控进程：$($processes.Count) 个。"
        }
    }
    catch {
        return
    }
}

function Start-TurnCompleteMonitor {
    Assert-CodexHomeReady

    if ([string]::IsNullOrWhiteSpace($script:TurnCompleteMonitorPath) -or
        -not (Test-Path -LiteralPath $script:TurnCompleteMonitorPath)) {
        Append-Log "未找到桌面版完成监控脚本，已跳过：$script:TurnCompleteMonitorPath"
        return
    }

    Stop-ExistingTurnCompleteMonitor

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

    Append-Log '已启动桌面版弹窗提醒监控。'
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
    $configText = Repair-NodeReplMcpConfig $configText

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
    Write-DiagnosticLog ("Switch-CodexProviderRow start id='{0}' name='{1}' history='{2}'" -f
        ([string]$provider.id),
        ([string]$provider.name),
        (Get-HistoryProviderFromCcSwitchProvider $provider))
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
    $disableCodexAppsOnFast = [bool]$script:DisableCodexAppsOnFast
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
    Write-DiagnosticLog ("Switch-CodexProviderRow done id='{0}' name='{1}' backup='{2}'" -f ([string]$provider.id), ([string]$provider.name), $backupDir)
    return $provider
}

function Invoke-LaunchForProvider {
    param([Parameter(Mandatory)]$Combo)

    Update-CcSwitchAccountComboForCurrentSource
    $providerLabel = [string]$Combo.SelectedItem
    $providerId = Resolve-CcSwitchProviderId $providerLabel
    if ([string]::IsNullOrWhiteSpace($providerId)) {
        throw '请先选择 cc-switch供应商。若下拉菜单为空，请点击【软件配置文件】填写 ccSwitchHome 后保存，或点击【加载cc-switch.db文件】选择 cc-switch.db。'
    }
    $loadChatOnLaunch = $script:LoadCheckedRecordBox -and [bool]$script:LoadCheckedRecordBox.Checked
    $resumeSelection = if ($loadChatOnLaunch) { Get-LaunchResumeSelection } else { $null }
    $resumeId = $null
    if ($resumeSelection) {
        $resumeId = [string]$resumeSelection.Id
        $directory = Resolve-LaunchDirectory -PreferredCwd ([string]$resumeSelection.Cwd)
    }
    else {
        $directory = Resolve-LaunchDirectory
    }

    $launchHistoryProvider = Get-CurrentSourceProvider
    if ($resumeSelection -and -not [string]::IsNullOrWhiteSpace([string]$resumeSelection.Provider)) {
        $launchHistoryProvider = Resolve-ProviderValue ([string]$resumeSelection.Provider)
    }
    $provider = Get-CcSwitchProviderById $providerId
    Write-DiagnosticLog ("Launch requested source='{0}' resumeProvider='{1}' launchHistory='{2}' ccLabel='{3}' ccId='{4}' ccName='{5}' ccHistory='{6}' resumeId='{7}' directory='{8}'" -f
        (Get-CurrentSourceProvider),
        $(if ($resumeSelection) { [string]$resumeSelection.Provider } else { '' }),
        $launchHistoryProvider,
        $providerLabel,
        $providerId,
        ([string]$provider.name),
        (Get-HistoryProviderFromCcSwitchProvider $provider),
        $resumeId,
        $directory)
    Assert-CcSwitchProviderAllowedForHistoryProvider -ProviderRow $provider -HistoryProvider $launchHistoryProvider
    Switch-CodexProviderRow $provider | Out-Null
    if ($script:TurnEndedNotifyBox -and [bool]$script:TurnEndedNotifyBox.Checked) {
        Start-TurnCompleteMonitor
    }
    Add-CodexProjectTrust -Directory $directory
    $disableApps = [bool]$script:DisableCodexAppsOnFast -and ((Get-CodexServiceTier (Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw)) -eq 'fast')
    $approvalNever = $script:ApprovalNeverLaunchBox -and [bool]$script:ApprovalNeverLaunchBox.Checked
    $preferPowerShell = $script:UsePowerShellLaunchBox -and [bool]$script:UsePowerShellLaunchBox.Checked
    $launchShell = Start-CodexInDirectory -Directory $directory -DisableApps:$disableApps -ApprovalNever:$approvalNever -ResumeId $resumeId -PreferPowerShell:$preferPowerShell
    $launchFlags = @()
    if ($disableApps) { $launchFlags += '--disable apps' }
    if ($approvalNever) {
        if ([bool]$script:CodexSupportsBypassFullAccess) {
            $launchFlags += '--dangerously-bypass-approvals-and-sandbox'
        }
        else {
            $launchFlags += '--sandbox danger-full-access'
            $launchFlags += '-a never'
        }
    }
    $launchFlagText = if ($launchFlags.Count -gt 0) { '，并追加 ' + ($launchFlags -join '、') } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($resumeId)) {
        Append-Log "已用 $providerLabel 管理员 $launchShell 恢复 Codex 会话 $resumeId$launchFlagText：$directory"
    }
    else {
        Append-Log "已用 $providerLabel 管理员 $launchShell 启动 Codex$launchFlagText：$directory"
    }
    Save-AppState
}

function Get-CheckedThreadRows {
    [void]$script:Grid.EndEdit()
    $items = New-Object System.Collections.Generic.List[object]
    $selectedColumn = Get-GridColumnByProperty 'Selected'
    $idColumn = Get-GridColumnByProperty 'Id'
    $providerColumn = Get-GridColumnByProperty 'Provider'
    $cwdColumn = Get-GridColumnByProperty 'Cwd'
    $titleColumn = Get-GridColumnByProperty 'Title'
    if (-not $selectedColumn -or -not $idColumn) { return $items.ToArray() }

    foreach ($row in $script:Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $isChecked = [bool]$row.Cells[$selectedColumn.Index].Value
        if ($isChecked) {
            $id = [string]$row.Cells[$idColumn.Index].Value
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $provider = ''
                $cwd = ''
                $title = ''
                if ($providerColumn) { $provider = [string]$row.Cells[$providerColumn.Index].Value }
                if ($cwdColumn) { $cwd = [string]$row.Cells[$cwdColumn.Index].Value }
                if ($titleColumn) { $title = [string]$row.Cells[$titleColumn.Index].Value }
                $items.Add([pscustomobject]@{
                        Id       = $id.Trim()
                        Provider = $provider
                        Cwd      = $cwd
                        Title    = $title
                    })
            }
        }
    }
    return $items.ToArray()
}

function Get-CheckedThreadIds {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($row in @(Get-CheckedThreadRows)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.Id)) {
            $ids.Add([string]$row.Id)
        }
    }
    return $ids.ToArray()
}

function Get-LaunchResumeSelection {
    $row = Get-CurrentGridRow
    if (-not $row) { return $null }

    $idColumn = Get-GridColumnByProperty 'Id'
    $providerColumn = Get-GridColumnByProperty 'Provider'
    $cwdColumn = Get-GridColumnByProperty 'Cwd'
    $titleColumn = Get-GridColumnByProperty 'Title'
    if (-not $idColumn) { return $null }

    $id = [string]$row.Cells[$idColumn.Index].Value
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }

    return [pscustomobject]@{
        Id       = $id.Trim()
        Provider = if ($providerColumn) { [string]$row.Cells[$providerColumn.Index].Value } else { '' }
        Cwd      = if ($cwdColumn) { [string]$row.Cells[$cwdColumn.Index].Value } else { '' }
        Title    = if ($titleColumn) { [string]$row.Cells[$titleColumn.Index].Value } else { '' }
    }
}

function Get-CurrentGridRow {
    if (-not $script:Grid) { return $null }
    if ($script:Grid.CurrentRow -and -not $script:Grid.CurrentRow.IsNewRow) {
        return $script:Grid.CurrentRow
    }
    foreach ($row in $script:Grid.Rows) {
        if (-not $row.IsNewRow) {
            $script:Grid.CurrentCell = $row.Cells[0]
            return $row
        }
    }
    return $null
}

function Set-CurrentRowChecked {
    param([bool]$Checked)

    [void]$script:Grid.EndEdit()
    $row = Get-CurrentGridRow
    $column = Get-GridColumnByProperty 'Selected'
    if (-not $row -or -not $column) { return }
    $row.Cells[$column.Index].Value = $Checked
}

function Set-OnlyCurrentRowChecked {
    Set-AllRowsChecked $false
    Set-CurrentRowChecked $true
}

function Set-AllRowsExceptCurrentChecked {
    [void]$script:Grid.EndEdit()
    $currentRow = Get-CurrentGridRow
    $selectedColumn = Get-GridColumnByProperty 'Selected'
    if (-not $currentRow -or -not $selectedColumn) { return }

    foreach ($row in $script:Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $row.Cells[$selectedColumn.Index].Value = -not [object]::ReferenceEquals($row, $currentRow)
    }
}

function Copy-GridValueToClipboard {
    param(
        [Parameter(Mandatory)][string]$ColumnName,
        [Parameter(Mandatory)][string]$Label
    )

    $value = [string](Get-CurrentGridValue $ColumnName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        [System.Windows.Forms.MessageBox]::Show("当前记录没有可复制的 $Label。", '没有内容', 'OK', 'Information') | Out-Null
        return
    }
    if (Copy-TextToClipboard $value) {
        Append-Log "已复制$Label：$value"
    }
}

function Copy-CurrentCellToClipboard {
    $cell = $script:Grid.CurrentCell
    if (-not $cell) { return }
    $value = [string]$cell.Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        [System.Windows.Forms.MessageBox]::Show('当前单元格没有可复制的内容。', '没有内容', 'OK', 'Information') | Out-Null
        return
    }
    if (Copy-TextToClipboard $value) {
        Append-Log "已复制此单元格：$value"
    }
}

function Open-CurrentWorkspaceDirectory {
    $cwd = Convert-CodexPath ([string](Get-CurrentGridValue 'Cwd'))
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        throw '当前记录没有项目目录。'
    }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        throw "项目目录不存在：$cwd"
    }
    Start-Process -FilePath explorer.exe -ArgumentList $cwd
    Append-Log "已打开项目目录：$cwd"
}

function Get-ClonedThreadIdFromSyncOutput {
    param([AllowNull()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return '' }
    $matches = [System.Text.RegularExpressions.Regex]::Matches($Output, '(?im)^\s*cloned_id\s*:\s*(?<id>\S+)\s*$')
    if ($matches.Count -eq 0) { return '' }
    return [string]$matches[$matches.Count - 1].Groups['id'].Value
}

function Switch-SourceProviderAndFocusThread {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [AllowNull()][string]$ThreadId
    )

    $oldSuppress = $script:SuppressThreadRefresh
    try {
        $script:SuppressThreadRefresh = $true
        Select-Provider $script:SourceCombo $Provider
        Update-TargetProviderComboForCurrentSource
        Update-CcSwitchAccountComboForCurrentSource
        Refresh-CwdOptions
    }
    finally {
        $script:SuppressThreadRefresh = $oldSuppress
    }
    Refresh-Threads -FocusThreadId $ThreadId
    Save-AppState
}

function Invoke-CloneCurrentRowToTarget {
    param([Parameter(Mandatory)][string]$TargetProvider)

    $row = Get-CurrentGridRow
    if (-not $row) { return }
    $id = [string](Get-CurrentGridValue 'Id')
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    $source = Get-CurrentSourceProvider
    Assert-HistoryTargetProviderAllowed -SourceProvider $source -TargetProvider $TargetProvider

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "即将同步当前记录到 $(Get-ProviderLabel $TargetProvider)。工具会先创建备份。是否继续？",
        '确认同步当前记录',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Append-Log '已取消。'
        return
    }

    $output = Invoke-SyncCli -CommandArgs (@('clone', '-Id', $id, '-To', $TargetProvider) + (Get-SyncTargetProfileArgs $TargetProvider)) -SkipConfirm -NoRefresh
    if ($null -eq $output) { return }
    $clonedId = Get-ClonedThreadIdFromSyncOutput $output
    if ([string]::IsNullOrWhiteSpace($clonedId)) {
        Append-Log '同步已完成，但未能从输出中解析目标线程 ID，已切换到目标账号。'
    }
    Switch-SourceProviderAndFocusThread -Provider $TargetProvider -ThreadId $clonedId
}

function Update-GridSyncToMenuItems {
    if (-not $script:GridSyncToMenuItem) { return }

    $script:GridSyncToMenuItem.DropDownItems.Clear()
    $source = Get-CurrentSourceProvider
    $providers = @(Get-Providers)
    foreach ($provider in $providers) {
        if (Test-SameHistoryProvider $provider $source) { continue }
        $targetProvider = [string]$provider
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = Get-ProviderLabel $targetProvider
        $item.Add_Click({
                try {
                    Invoke-CloneCurrentRowToTarget -TargetProvider $targetProvider
                }
                catch {
                    Show-GuiError $_
                }
            }.GetNewClosure())
        [void]$script:GridSyncToMenuItem.DropDownItems.Add($item)
    }

    if ($script:GridSyncToMenuItem.DropDownItems.Count -eq 0) {
        $emptyItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $emptyItem.Text = '无可用目标账号'
        $emptyItem.Enabled = $false
        [void]$script:GridSyncToMenuItem.DropDownItems.Add($emptyItem)
    }
}

function Invoke-CloneCheckedRowsToTarget {
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
    Assert-HistoryTargetProviderAllowed -SourceProvider (Get-CurrentSourceProvider) -TargetProvider $target
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
        Invoke-SyncCli -CommandArgs (@('clone', '-Id', $id, '-To', $target) + (Get-SyncTargetProfileArgs $target)) -SkipConfirm -NoRefresh
    }
    Refresh-Providers
    Refresh-Threads
}

function Invoke-SyncAllRowsToTarget {
    $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
    $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
    if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) {
        [System.Windows.Forms.MessageBox]::Show('请先选择 Codex源账号和 Codex目标账号。', '账号不完整', 'OK', 'Information') | Out-Null
        return
    }
    Assert-HistoryTargetProviderAllowed -SourceProvider $source -TargetProvider $target
    Invoke-SyncCli -CommandArgs (@('sync', '-From', $source, '-To', $target) + (Get-SyncTargetProfileArgs $target))
}

function Invoke-LaunchCurrentGridRow {
    param([switch]$WithChat)

    $oldSuppress = $script:SuppressThreadRefresh
    $oldLoadChecked = if ($script:LoadCheckedRecordBox) { [bool]$script:LoadCheckedRecordBox.Checked } else { $true }
    try {
        $script:SuppressThreadRefresh = $true
        if ($WithChat) {
            if ($script:LoadCheckedRecordBox) { $script:LoadCheckedRecordBox.Checked = $true }
        }
        else {
            if ($script:LoadCheckedRecordBox) { $script:LoadCheckedRecordBox.Checked = $false }
        }
    }
    finally {
        $script:SuppressThreadRefresh = $oldSuppress
    }

    try {
        Invoke-LaunchForProvider -Combo $script:CodexProviderCombo
    }
    finally {
        $oldSuppressRestore = $script:SuppressThreadRefresh
        try {
            $script:SuppressThreadRefresh = $true
            if ($script:LoadCheckedRecordBox) { $script:LoadCheckedRecordBox.Checked = $oldLoadChecked }
        }
        finally {
            $script:SuppressThreadRefresh = $oldSuppressRestore
        }
    }
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

function Select-GridRowByThreadId {
    param([AllowNull()][string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId) -or -not $script:Grid) { return $false }
    $idColumn = Get-GridColumnByProperty 'Id'
    if (-not $idColumn) { return $false }

    foreach ($row in $script:Grid.Rows) {
        if ($row.IsNewRow) { continue }
        if ([string]::Equals([string]$row.Cells[$idColumn.Index].Value, $ThreadId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:Grid.ClearSelection()
            $row.Selected = $true
            $script:Grid.CurrentCell = $row.Cells[$idColumn.Index]
            try {
                $script:Grid.FirstDisplayedScrollingRowIndex = $row.Index
            }
            catch { }
            return $true
        }
    }
    return $false
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
            return $null
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
        return $output
    }
    catch {
        Show-GuiError $_
        return $null
    }
    finally {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Refresh-Providers {
    $oldSuppress = $script:SuppressThreadRefresh
    try {
        $ccSwitchProviders = @(Get-CcSwitchCodexProviders)
        $script:CcSwitchCodexProviders = $ccSwitchProviders

        if (-not (Test-CodexHomeReady)) {
            if ($script:SourceCombo) { $script:SourceCombo.Items.Clear() }
            if ($script:TargetCombo) { $script:TargetCombo.Items.Clear() }
            Reset-CcSwitchAccountCombo -Providers $ccSwitchProviders -HistoryProvider $null
            if ($script:StatusLabel) { $script:StatusLabel.Text = '请先加载 codex 账号' }
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
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        Reset-ProviderCombo $script:TargetCombo $providers $(if ($currentTarget) { $currentTarget } else { 'custom' }) -ExcludedProvider $source
        Reset-CcSwitchAccountCombo -Providers $ccSwitchProviders -HistoryProvider (Get-CurrentSourceProvider)
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
    param([AllowNull()][string]$FocusThreadId)

    try {
        if (-not (Test-CodexHomeReady)) {
            $script:LastThreadTableCount = 0
            if ($script:Grid) { $script:Grid.Rows.Clear() }
            if ($script:StatusLabel) { $script:StatusLabel.Text = '请先加载 codex 账号' }
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
                [string]$row.Title,
                [string]$row.RolloutPath
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
            Selected = Get-UiText 'GridSelect'
            Updated  = Get-UiText 'GridUpdated'
            Provider = Get-UiText 'GridProvider'
            Archived = Get-UiText 'GridArchived'
            Id       = Get-UiText 'GridThreadId'
            Cwd      = Get-UiText 'GridCwd'
            Title    = Get-UiText 'GridTitle'
        }
        foreach ($key in $headers.Keys) {
            $column = Get-GridColumnByProperty $key
            if ($column) {
                $column.HeaderText = $headers.Get_Item($key)
            }
        }
        $script:StatusLabel.Text = "记录数：$($items.Count)"
        Append-Log "已加载 $($items.Count) 条记录：$(Get-ProviderLabel $provider)"
        if (-not [string]::IsNullOrWhiteSpace($FocusThreadId)) {
            if (Select-GridRowByThreadId $FocusThreadId) {
                Append-Log "已定位同步后的聊天记录：$FocusThreadId"
            }
            else {
                Append-Log "已切换到目标账号，但当前列表中未找到同步后的聊天记录：$FocusThreadId"
            }
        }
    }
    catch {
        Show-GuiError $_
    }
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Codex 历史记录同步'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = New-Object System.Drawing.Size(1320, 860)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1320, 820)
$script:Form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(1304, 62)
$headerPanel.Anchor = 'Top,Left,Right'
$headerPanel.BackColor = [System.Drawing.Color]::White
$script:Form.Controls.Add($headerPanel)

$headerImage = New-Object System.Windows.Forms.PictureBox
$headerImage.Location = New-Object System.Drawing.Point(18, 4)
$headerImage.Size = New-Object System.Drawing.Size(220, 56)
$headerImage.SizeMode = 'CenterImage'
$headerImage.Image = New-HeaderImage
$headerPanel.Controls.Add($headerImage)

$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = 'Codex 历史记录同步'
$headerTitle.Location = New-Object System.Drawing.Point(246, 10)
$headerTitle.Size = New-Object System.Drawing.Size(280, 24)
$headerTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$headerTitle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$headerPanel.Controls.Add($headerTitle)

$headerSubTitle = New-Object System.Windows.Forms.Label
$headerSubTitle.Text = '本地记录迁移、节点启动和完成提醒'
$headerSubTitle.Location = New-Object System.Drawing.Point(248, 34)
$headerSubTitle.Size = New-Object System.Drawing.Size(540, 20)
$headerSubTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$headerPanel.Controls.Add($headerSubTitle)

$headerMeta = New-Object System.Windows.Forms.Label
$headerMeta.Text = "v$script:AppVersion  |  作者 $script:AppAuthor  |"
$headerMeta.Location = New-Object System.Drawing.Point(820, 20)
$headerMeta.Size = New-Object System.Drawing.Size(360, 22)
$headerMeta.Anchor = 'Top,Right'
$headerMeta.TextAlign = 'MiddleRight'
$headerMeta.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$headerMeta.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$headerPanel.Controls.Add($headerMeta)

$headerGitHub = New-Object System.Windows.Forms.LinkLabel
$headerGitHub.Text = 'GitHub'
$headerGitHub.Location = New-Object System.Drawing.Point(1186, 20)
$headerGitHub.Size = New-Object System.Drawing.Size(88, 22)
$headerGitHub.Anchor = 'Top,Right'
$headerGitHub.TextAlign = 'MiddleLeft'
$headerGitHub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$headerGitHub.LinkColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$headerGitHub.ActiveLinkColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$headerGitHub.VisitedLinkColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$headerGitHub.Add_LinkClicked({ Start-Process $script:GitHubUrl })
$headerPanel.Controls.Add($headerGitHub)

$headerLanguageSeparator = New-Object System.Windows.Forms.Label
$headerLanguageSeparator.Text = '|'
$headerLanguageSeparator.Location = New-Object System.Drawing.Point(1236, 20)
$headerLanguageSeparator.Size = New-Object System.Drawing.Size(14, 22)
$headerLanguageSeparator.Anchor = 'Top,Right'
$headerLanguageSeparator.TextAlign = 'MiddleCenter'
$headerLanguageSeparator.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$headerLanguageSeparator.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$headerPanel.Controls.Add($headerLanguageSeparator)

$headerLanguageLink = New-Object System.Windows.Forms.LinkLabel
$headerLanguageLink.Text = 'English'
$headerLanguageLink.Location = New-Object System.Drawing.Point(1254, 20)
$headerLanguageLink.Size = New-Object System.Drawing.Size(62, 22)
$headerLanguageLink.Anchor = 'Top,Right'
$headerLanguageLink.TextAlign = 'MiddleLeft'
$headerLanguageLink.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$headerLanguageLink.LinkColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$headerLanguageLink.ActiveLinkColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$headerLanguageLink.VisitedLinkColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$headerPanel.Controls.Add($headerLanguageLink)

$historyGroup = New-GroupBox '历史筛选' 12 70 508 86
$script:Form.Controls.Add($historyGroup)
$sourceLabel = New-Label 'Codex源账号' 14 24 76
$historyGroup.Controls.Add($sourceLabel)
$script:SourceCombo = New-Object System.Windows.Forms.ComboBox
$script:SourceCombo.DropDownStyle = 'DropDownList'
$script:SourceCombo.Location = New-Object System.Drawing.Point(92, 24)
$script:SourceCombo.Size = New-Object System.Drawing.Size(118, 24)
$historyGroup.Controls.Add($script:SourceCombo)
$targetLabel = New-Label 'Codex目标账号' 218 24 86
$historyGroup.Controls.Add($targetLabel)
$script:TargetCombo = New-Object System.Windows.Forms.ComboBox
$script:TargetCombo.DropDownStyle = 'DropDownList'
$script:TargetCombo.Location = New-Object System.Drawing.Point(306, 24)
$script:TargetCombo.Size = New-Object System.Drawing.Size(118, 24)
$historyGroup.Controls.Add($script:TargetCombo)
$swapButton = New-Button '交换' 434 22 58 'Soft'
$historyGroup.Controls.Add($swapButton)
$cwdLabel = New-Label '目录筛选' 14 54 66
$historyGroup.Controls.Add($cwdLabel)
$script:CwdCombo = New-Object System.Windows.Forms.ComboBox
$script:CwdCombo.DropDownStyle = 'DropDownList'
$script:CwdCombo.Location = New-Object System.Drawing.Point(82, 54)
$script:CwdCombo.Size = New-Object System.Drawing.Size(222, 24)
$script:CwdCombo.DropDownWidth = 900
$historyGroup.Controls.Add($script:CwdCombo)
$limitLabel = New-Label '显示条数' 314 54 64
$historyGroup.Controls.Add($limitLabel)
$script:LimitBox = New-Object System.Windows.Forms.NumericUpDown
$script:LimitBox.Location = New-Object System.Drawing.Point(380, 54)
$script:LimitBox.Size = New-Object System.Drawing.Size(58, 24)
$script:LimitBox.Minimum = 1
$script:LimitBox.Maximum = 1000
$script:LimitBox.Value = 50
$historyGroup.Controls.Add($script:LimitBox)
$script:IncludeArchivedBox = New-Object System.Windows.Forms.CheckBox
$script:IncludeArchivedBox.Text = '显示归档'
$script:IncludeArchivedBox.Location = New-Object System.Drawing.Point(446, 55)
$script:IncludeArchivedBox.Size = New-Object System.Drawing.Size(48, 22)
$historyGroup.Controls.Add($script:IncludeArchivedBox)

$syncGroup = New-GroupBox '同步操作' 532 70 328 86
$script:Form.Controls.Add($syncGroup)
$refreshButton = New-Button '刷新' 14 24 62 'Soft'
$selectAllButton = New-Button '全选' 84 24 58
$clearSelectionButton = New-Button '清空' 150 24 58
$cloneButton = New-Button '同步勾选' 216 24 86 'Primary'
$syncButton = New-Button '同步全部' 14 54 86 'Primary'
$mirrorButton = New-Button '双向同步' 108 54 86 'Soft'
$syncGroup.Controls.Add($refreshButton)
$syncGroup.Controls.Add($selectAllButton)
$syncGroup.Controls.Add($clearSelectionButton)
$syncGroup.Controls.Add($cloneButton)
$syncGroup.Controls.Add($syncButton)
$syncGroup.Controls.Add($mirrorButton)

$pathGroup = New-GroupBox '目录与配置' 872 70 420 86
$script:Form.Controls.Add($pathGroup)
$selectCodexHomeButton = New-Button '加载codex账号' 14 24 118
$openRecordFolderButton = New-Button '打开聊天内容' 142 24 118 'Soft'
$openCodexFolderButton = New-Button 'codex目录' 270 24 112
$selectCcSwitchHomeButton = New-Button '加载cc-switch.db文件' 14 54 150
$openConfigButton = New-Button '软件配置文件' 178 54 126 'Soft'
$pathGroup.Controls.Add($selectCodexHomeButton)
$pathGroup.Controls.Add($openRecordFolderButton)
$pathGroup.Controls.Add($openCodexFolderButton)
$pathGroup.Controls.Add($selectCcSwitchHomeButton)
$pathGroup.Controls.Add($openConfigButton)

$launchGroup = New-GroupBox '启动与提醒' 12 166 880 58
$script:Form.Controls.Add($launchGroup)
$ccProviderLabel = New-Label 'cc-switch供应商' 14 24 102
$launchGroup.Controls.Add($ccProviderLabel)
$script:CodexProviderCombo = New-Object System.Windows.Forms.ComboBox
$script:CodexProviderCombo.DropDownStyle = 'DropDownList'
$script:CodexProviderCombo.Location = New-Object System.Drawing.Point(110, 24)
$script:CodexProviderCombo.Size = New-Object System.Drawing.Size(170, 24)
$launchGroup.Controls.Add($script:CodexProviderCombo)
$openCodexButton = New-Button '从终端启动' 292 22 110 'Primary'
$launchGroup.Controls.Add($openCodexButton)
$script:LoadCheckedRecordBox = New-Object System.Windows.Forms.CheckBox
$script:LoadCheckedRecordBox.Text = '启动时加载聊天'
$script:LoadCheckedRecordBox.Location = New-Object System.Drawing.Point(414, 25)
$script:LoadCheckedRecordBox.Size = New-Object System.Drawing.Size(140, 22)
$script:LoadCheckedRecordBox.Checked = $true
$launchGroup.Controls.Add($script:LoadCheckedRecordBox)
$script:UsePowerShellLaunchBox = New-Object System.Windows.Forms.CheckBox
$script:UsePowerShellLaunchBox.Text = 'PowerShell启动'
$script:UsePowerShellLaunchBox.Location = New-Object System.Drawing.Point(550, 25)
$script:UsePowerShellLaunchBox.Size = New-Object System.Drawing.Size(118, 22)
$script:UsePowerShellLaunchBox.Checked = $false
$launchGroup.Controls.Add($script:UsePowerShellLaunchBox)
$script:ApprovalNeverLaunchBox = New-Object System.Windows.Forms.CheckBox
$script:ApprovalNeverLaunchBox.Text = '完全访问(-a never)'
$script:ApprovalNeverLaunchBox.Location = New-Object System.Drawing.Point(676, 25)
$script:ApprovalNeverLaunchBox.Size = New-Object System.Drawing.Size(140, 22)
$script:ApprovalNeverLaunchBox.Checked = $true
$launchGroup.Controls.Add($script:ApprovalNeverLaunchBox)
$script:TurnEndedNotifyBox = New-Object System.Windows.Forms.CheckBox
$script:TurnEndedNotifyBox.Text = '弹窗提醒'
$script:TurnEndedNotifyBox.Location = New-Object System.Drawing.Point(824, 25)
$script:TurnEndedNotifyBox.Size = New-Object System.Drawing.Size(82, 22)
$script:TurnEndedNotifyBox.Checked = $true
$launchGroup.Controls.Add($script:TurnEndedNotifyBox)
$testNotifyButton = New-Button '测试弹窗' 914 22 94
$launchGroup.Controls.Add($testNotifyButton)

$supportGroup = New-GroupBox '帮助与更新' 904 166 226 58
$script:Form.Controls.Add($supportGroup)
$helpButton = New-Button '帮助' 14 22 86 'Soft'
$updateButton = New-Button '检查更新' 110 22 96
$supportGroup.Controls.Add($helpButton)
$supportGroup.Controls.Add($updateButton)

$script:Grid = New-Object System.Windows.Forms.DataGridView

$script:Grid.Location = New-Object System.Drawing.Point(12, 236)
$script:Grid.Size = New-Object System.Drawing.Size(1280, 372)
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
    @{ Name = 'Cwd'; Header = '项目目录'; Width = 260; Type = 'Text' },
    @{ Name = 'Title'; Header = '聊天内容'; Width = 280; Type = 'Text'; Fill = $true },
    @{ Name = 'RolloutPath'; Header = '记录文件'; Width = 80; Type = 'Text'; Hidden = $true }
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
    if ($definition.Hidden) {
        $column.Visible = $false
    }
    [void]$script:Grid.Columns.Add($column)
}
$script:Form.Controls.Add($script:Grid)

$script:GridContextRowIndex = -1
$script:GridContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$gridLaunchTerminalItem = $script:GridContextMenu.Items.Add('启动终端')
$gridLaunchTerminalItem.Add_Click({
        try {
            Invoke-LaunchCurrentGridRow
        }
        catch {
            Show-GuiError $_
        }
    })
$gridLaunchWithChatItem = $script:GridContextMenu.Items.Add('启动终端（+聊天）')
$gridLaunchWithChatItem.Add_Click({
        try {
            Invoke-LaunchCurrentGridRow -WithChat
        }
        catch {
            Show-GuiError $_
        }
    })
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:GridSyncToMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:GridSyncToMenuItem.Text = '同步此条至'
[void]$script:GridContextMenu.Items.Add($script:GridSyncToMenuItem)
$script:GridSyncToMenuItem.Add_DropDownOpening({
        try {
            Update-GridSyncToMenuItems
        }
        catch {
            Show-GuiError $_
        }
    })
$gridCloneCheckedItem = $script:GridContextMenu.Items.Add('同步勾选')
$gridCloneCheckedItem.Add_Click({
        try {
            Invoke-CloneCheckedRowsToTarget
        }
        catch {
            Show-GuiError $_
        }
    })
$gridSyncAllItem = $script:GridContextMenu.Items.Add('同步全部')
$gridSyncAllItem.Add_Click({
        try {
            Invoke-SyncAllRowsToTarget
        }
        catch {
            Show-GuiError $_
        }
    })
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$gridOpenRecordDirItem = $script:GridContextMenu.Items.Add('打开聊天内容')
$gridOpenRecordDirItem.Add_Click({
        try {
            $directory = Resolve-SelectedRecordDirectory
            Start-Process -FilePath explorer.exe -ArgumentList $directory
            Append-Log "已打开聊天内容目录：$directory"
        }
        catch {
            Show-GuiError $_
        }
    })
$gridOpenWorkspaceItem = $script:GridContextMenu.Items.Add('打开项目目录')
$gridOpenWorkspaceItem.Add_Click({
        try {
            Open-CurrentWorkspaceDirectory
        }
        catch {
            Show-GuiError $_
        }
    })
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$gridCopyCellItem = $script:GridContextMenu.Items.Add('复制此单元格')
$gridCopyCellItem.Add_Click({ Copy-CurrentCellToClipboard })
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$gridCheckOnlyItem = $script:GridContextMenu.Items.Add('只勾选此条')
$gridCheckOnlyItem.Add_Click({ Set-OnlyCurrentRowChecked })
$gridCheckExceptItem = $script:GridContextMenu.Items.Add('勾选此外所有条')
$gridCheckExceptItem.Add_Click({ Set-AllRowsExceptCurrentChecked })
$script:Grid.ContextMenuStrip = $script:GridContextMenu
$script:GridContextMenu.Add_Opening({
        param($Sender, $EventArgs)

        $hasRow = $script:GridContextRowIndex -ge 0 -and $script:Grid.CurrentRow -and -not $script:Grid.CurrentRow.IsNewRow
        if (-not $hasRow) {
            $EventArgs.Cancel = $true
            return
        }
        $cwd = Convert-CodexPath ([string](Get-CurrentGridValue 'Cwd'))
        $gridOpenWorkspaceItem.Enabled = (-not [string]::IsNullOrWhiteSpace($cwd)) -and (Test-Path -LiteralPath $cwd -PathType Container)
    })
$script:Grid.Add_MouseDown({
        param($Sender, $EventArgs)

        if ($EventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }

        $hit = $Sender.HitTest($EventArgs.X, $EventArgs.Y)
        if ($hit.RowIndex -lt 0) {
            $script:GridContextRowIndex = -1
            return
        }

        $script:GridContextRowIndex = $hit.RowIndex
        $Sender.ClearSelection()
        $row = $Sender.Rows[$hit.RowIndex]
        $row.Selected = $true
        $cellIndex = if ($hit.ColumnIndex -ge 0) { $hit.ColumnIndex } else { 0 }
        while ($cellIndex -lt $row.Cells.Count -and -not $Sender.Columns[$cellIndex].Visible) {
            $cellIndex++
        }
        if ($cellIndex -lt $row.Cells.Count) {
            $Sender.CurrentCell = $row.Cells[$cellIndex]
        }
    })

$script:OutputBox = New-Object System.Windows.Forms.TextBox
$script:OutputBox.Location = New-Object System.Drawing.Point(12, 620)
$script:OutputBox.Size = New-Object System.Drawing.Size(1280, 160)
$script:OutputBox.Anchor = 'Left,Right,Bottom'
$script:OutputBox.Multiline = $true
$script:OutputBox.ReadOnly = $true
$script:OutputBox.ScrollBars = 'Vertical'
$script:OutputBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.Controls.Add($script:OutputBox)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Location = New-Object System.Drawing.Point(12, 792)
$script:StatusLabel.Size = New-Object System.Drawing.Size(1280, 24)
$script:StatusLabel.Anchor = 'Left,Right,Bottom'
$script:StatusLabel.Text = '就绪'
$script:Form.Controls.Add($script:StatusLabel)

Apply-UiLanguage

$selectCodexHomeButton.Add_Click({
        try {
            Select-CodexHomeFolder
        }
        catch {
            Show-GuiError $_
        }
    })

$selectCcSwitchHomeButton.Add_Click({
        try {
            Select-CcSwitchHomeFolder
        }
        catch {
            Show-GuiError $_
        }
    })

$openConfigButton.Add_Click({
        try {
            Open-AppConfigFile
        }
        catch {
            Show-GuiError $_
        }
    })

$helpButton.Add_Click({ Show-AppHelp })

$updateButton.Add_Click({
        try {
            Invoke-AppSelfUpdate
        }
        catch {
            Show-GuiError $_
        }
    })

$headerLanguageLink.Add_LinkClicked({
        try {
            Toggle-UiLanguage
            Save-AppState
        }
        catch {
            Show-GuiError $_
        }
    })

$refreshButton.Add_Click({
        Refresh-Providers
        Refresh-CwdOptions
        Refresh-Threads
        Sync-AppConfigFileWithDetectedInfo -CreateIfMissing
    })

$selectAllButton.Add_Click({ Set-AllRowsChecked $true })

$clearSelectionButton.Add_Click({ Set-AllRowsChecked $false })

$swapButton.Add_Click({
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        $oldSuppress = $script:SuppressThreadRefresh
        try {
            $script:SuppressThreadRefresh = $true
            if ($target) { Select-Provider $script:SourceCombo $target }
            Update-TargetProviderComboForCurrentSource -PreferredProvider $source
        }
        finally {
            $script:SuppressThreadRefresh = $oldSuppress
        }
        Update-CcSwitchAccountComboForCurrentSource
        Refresh-CwdOptions
        Refresh-Threads
        Save-AppState
    })

$cloneButton.Add_Click({
        try {
            Invoke-CloneCheckedRowsToTarget
        }
        catch {
            Show-GuiError $_
        }
    })

$syncButton.Add_Click({
        try {
            Invoke-SyncAllRowsToTarget
        }
        catch {
            Show-GuiError $_
        }
    })

$mirrorButton.Add_Click({
        $source = Resolve-ProviderValue ([string]$script:SourceCombo.SelectedItem)
        $target = Resolve-ProviderValue ([string]$script:TargetCombo.SelectedItem)
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show('请先选择两个 Codex 历史记录账号。', '账号不完整', 'OK', 'Information') | Out-Null
            return
        }
        Assert-HistoryTargetProviderAllowed -SourceProvider $source -TargetProvider $target
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "即将在 $(Get-ProviderLabel $source) 和 $(Get-ProviderLabel $target) 之间双向同步。工具会先创建备份。是否继续？",
            '确认双向同步',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Append-Log '已取消。'
            return
        }

        Invoke-SyncCli -CommandArgs (@('sync', '-From', $source, '-To', $target) + (Get-SyncTargetProfileArgs $target)) -SkipConfirm -NoRefresh
        Invoke-SyncCli -CommandArgs (@('sync', '-From', $target, '-To', $source) + (Get-SyncTargetProfileArgs $source)) -SkipConfirm -NoRefresh
        Refresh-Providers
        Refresh-Threads
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
            $directory = Resolve-SelectedRecordDirectory
            Start-Process -FilePath explorer.exe -ArgumentList $directory
            Append-Log "已打开聊天内容目录：$directory"
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
            Update-TargetProviderComboForCurrentSource
            Update-CcSwitchAccountComboForCurrentSource
            Refresh-CwdOptions
            Refresh-Threads
            Save-AppState
        }
    })
$script:TargetCombo.Add_SelectedIndexChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })
$script:CodexProviderCombo.Add_SelectedIndexChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })
$script:IncludeArchivedBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Refresh-CwdOptions
            Refresh-Threads
            Save-AppState
        }
    })
$script:LimitBox.Add_ValueChanged({
        if (-not $script:SuppressThreadRefresh) {
            Refresh-Threads
            Save-AppState
        }
    })
$script:CwdCombo.Add_SelectedIndexChanged({
        if (-not $script:SuppressThreadRefresh) {
            Refresh-Threads
            Save-AppState
        }
    })
$script:UsePowerShellLaunchBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })
$script:ApprovalNeverLaunchBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })
$script:LoadCheckedRecordBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })
$script:TurnEndedNotifyBox.Add_CheckedChanged({
        if (-not $script:SuppressThreadRefresh) {
            Save-AppState
        }
    })

$script:Grid.Add_CurrentCellDirtyStateChanged({
        if ($script:Grid.IsCurrentCellDirty) {
            [void]$script:Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

$script:Form.Add_Resize({
        Remember-CurrentLanguageWindowWidth
        Layout-HeaderMeta
    })

$script:Form.Add_FormClosing({
        Save-AppState
        if ($script:ConfigWatcher) {
            try { $script:ConfigWatcher.Stop() } catch { }
            $script:ConfigWatcher.Dispose()
        }
        if ($script:ConfigReloadTimer) {
            $script:ConfigReloadTimer.Stop()
            $script:ConfigReloadTimer.Dispose()
        }
        if ($script:GuiInstanceMutex) {
            try { $script:GuiInstanceMutex.ReleaseMutex() | Out-Null } catch { }
            $script:GuiInstanceMutex.Dispose()
            $script:GuiInstanceMutex = $null
        }
    })

$startupConfigPath = Get-StartupConfigPath
if (-not [string]::IsNullOrWhiteSpace($startupConfigPath)) {
    try {
        Import-AppConfig -Path $startupConfigPath -Silent
    }
    catch {
        Append-Log "自动加载配置失败：$($_.Exception.Message)"
    }
}

Refresh-Providers
if (-not [string]::IsNullOrWhiteSpace($SelfTestSourceProvider)) {
    Select-Provider $script:SourceCombo $SelfTestSourceProvider
    Update-TargetProviderComboForCurrentSource
    Update-CcSwitchAccountComboForCurrentSource
}
Refresh-CwdOptions
$script:SuppressThreadRefresh = $false
Refresh-Threads
if (-not $SelfTest) {
    Sync-AppConfigFileWithDetectedInfo -CreateIfMissing
    Start-AppConfigWatcher
}
Append-Log '界面已加载。'
if (Test-CodexHomeReady) {
    Append-Log "Codex 账号目录：$CodexHome"
}
else {
    Append-Log ("尚未加载 Codex 账号。请点击 ""加载codex账号""。" + "`r`n`r`n" + (Get-CodexHomeHelpText))
}
if ([string]::IsNullOrWhiteSpace($script:CcSwitchDb)) {
    Append-Log ("未找到 cc-switch.db：历史同步可用，切换账号启动功能不可用。请点击 ""加载cc-switch.db文件""，选择 cc-switch.db。" + "`r`n`r`n" + (Get-CcSwitchHomeHelpText))
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
        Append-Log "自动启用弹窗提醒失败：$($_.Exception.Message)"
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
