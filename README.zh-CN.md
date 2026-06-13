# Codex History Sync Portable

[![平台](https://img.shields.io/badge/platform-Windows-2563eb)](#运行要求)
[![PowerShell](https://img.shields.io/badge/runtime-PowerShell-5391FE)](#运行要求)
[![SQLite](https://img.shields.io/badge/storage-SQLite-003B57)](#数据位置)
[![便携版](https://img.shields.io/badge/install-portable-16a34a)](#快速开始)
[![本地优先](https://img.shields.io/badge/privacy-local--first-111827)](#隐私与安全)

语言: [English](README.md) | [简体中文](README.zh-CN.md)

Codex History Sync Portable 是一个 Windows 便携工具，用来把 Codex Desktop 本地聊天记录复制同步到不同的 `model_provider` 账号桶里，例如 `openai`、`custom`，或者本地路由工具写入的其他 provider 名称。

它适合经常在官方账号、自定义 API、cc-switch 节点或其他 Codex provider 之间切换的人。你不用手动改 SQLite，也不用自己复制 `rollout-*.jsonl` 文件，就能让同一批本地对话在不同 provider 桶里可见。

## 项目卡片

| 项目 | 说明 |
| --- | --- |
| 项目类型 | 本地桌面工具 |
| 目标平台 | Windows |
| 交互方式 | WinForms 图形界面 + PowerShell 命令行 |
| 数据来源 | 本地 Codex `state_5.sqlite` 和 `sessions\rollout-*.jsonl` 文件 |
| 网络请求 | 普通历史同步不联网 |
| 写入行为 | 用户确认后复制或更新本地历史记录 |
| 备份行为 | 修改 Codex 文件前自动创建时间戳备份 |
| 便携依赖 | 自带 `sqlite3.exe` |

## 快速开始

1. 下载或 clone 这个项目。
2. 双击运行 `codex-history-sync-gui.vbs`，这是无控制台窗口版本。
3. 选择 `Codex源账号` 和 `Codex目标账号`。
4. 勾选要同步的记录，然后点 `同步勾选`；或者直接点 `同步全部`。
5. 工具会在真正写入前自动备份 Codex 本地状态。

如果想看到启动控制台，可以运行：

```bat
codex-history-sync-gui.cmd
```

## 为什么需要它

Codex Desktop 会把本地线程元数据放在 SQLite 数据库里，把对话 transcript 放在 `sessions` 目录下的 rollout 文件里。桌面端界面会按 `threads.model_provider` 区分历史记录。

这意味着，如果一个账号把历史写在 `openai` 桶里，另一个账号把历史写在 `custom` 桶里，同一个本地对话可能只在其中一个账号视图里出现。

这个工具做的是更安全的复制同步：

- 保留源线程，不移动、不删除原始记录。
- 为目标 provider 创建或更新一份副本。
- 自动生成新的线程 id。
- 自动重写复制出来的 rollout 文件里的线程 id。
- 自动把目标记录的 `model_provider` 改成目标账号桶。
- 如果检测到 cc-switch 目标节点，GUI 同步会按目标节点配置重写 `model`、`reasoning_effort` 和 rollout 里的续聊上下文。
- 同步到非官方节点时会启用第三方兼容清理，移除官方 Codex 专用的 reasoning、function/custom tool response item，降低 Any Router、RightCode 等路由续聊时出现 `invalid codex request` 的概率。
- 记录映射关系，重复同步同一条记录时更新已有副本，而不是无限创建重复记录。

## 主要功能

- 图形界面浏览和同步最近的 Codex 对话。
- 命令行支持 provider 列表、单条 clone、单向 sync、双向 mirror、映射注册。
- 支持按工作目录筛选，只同步某个项目下的历史。
- 自动寻找常见位置的 Codex 历史目录。
- 支持手动选择便携或自定义 `.codex` 目录。
- 写入前自动备份。
- 可选读取 cc-switch 的 Codex 节点并通过选中节点启动 Codex。
- 可选 Codex 完成回复后弹窗提醒。
- `.vbs` 启动器可以隐藏 PowerShell 控制台窗口。

## 运行要求

- Windows 10 或更高版本。
- PowerShell 5.1 或更高版本。
- 本机有 Codex Desktop 的本地历史文件。
- Codex 历史目录中有 `state_5.sqlite` 和对应的 `sessions` 目录。

项目已经自带 `bin\sqlite3.exe`，正常便携使用不需要额外安装 SQLite。

## 图形界面说明

GUI 里的主要控件如下：

| 控件 | 作用 |
| --- | --- |
| `Codex源账号` | 从哪个 provider 桶复制历史 |
| `Codex目标账号` | 把历史复制到哪个 provider 桶 |
| `目录筛选` | 只显示或同步某个工作目录下的对话 |
| `显示条数` | 每次最多显示多少条记录 |
| `同步勾选` | 只同步已勾选的记录 |
| `同步全部` | 同步当前源账号下列出的记录 |
| `双向同步` | 在两个 provider 桶之间互相同步 |
| `cc-switch供应商` | `从终端启动` 时使用哪个 cc-switch Codex 供应商 |
| `从终端启动` | 以管理员身份打开终端；终端第一行会显示 `[管理员模式]` 或 `[非管理员]`；不勾选记录时新建对话；开启 `按勾选加载聊天` 且只勾选一条记录时自动恢复该会话 |
| `按勾选加载聊天` | 开启后，勾选一条记录会执行 `codex resume <thread-id>`；关闭后忽略勾选并在当前目录新建对话 |
| `PowerShell启动` | 勾选时优先用 PowerShell 启动；取消勾选时优先用 CMD 启动；找不到首选终端时会自动退回另一种 |
| 标题栏 `GitHub` 右侧语言文字 | 在中文和英文界面之间切换 |
| `软件设置` | 打开根目录 `codex-history-sync-config.json`；首次会自动生成，保存后 GUI 自动刷新 |
| `帮助` | 显示记录目录、账号目录、启动、更新等说明，并复制 Everything 搜索关键词 |
| `检查更新` | 从 GitHub main 分支检查版本，发现新版后可一键热更新 |
| `增加聊天记录` | 手动选择 `.codex` 历史目录 |
| `打开聊天目录` | 打开当前选中聊天的 rollout 文件夹；未选中时打开 `.codex\sessions` |
| `codex目录` | 打开当前 Codex 历史根目录 |
| `加载cc-switch.db配置` | 手动选择包含 `cc-switch.db` 的 cc-switch 配置目录，让 GUI 读取 Any Router、RightCode 等启动供应商 |
| 表格右键菜单 | 在表格中快速启动终端、启动终端并加载当前聊天、同步此条/勾选/所有记录、打开目录或复制信息 |

如果你误选了 `sessions` 或它下面的子目录，工具会自动向上查找包含 `state_5.sqlite` 的父目录。

## 命令行用法

命令行入口是：

```bat
codex-history-sync.cmd providers
codex-history-sync.cmd list -From openai -Limit 20
codex-history-sync.cmd clone -Id <thread-id> -To custom
codex-history-sync.cmd sync -From openai -To custom
codex-history-sync.cmd mirror -Providers openai,custom
```

常用参数：

| 参数 | 适用动作 | 说明 |
| --- | --- | --- |
| `-CodexHome <path>` | 全部 | 指定 Codex 历史目录 |
| `-Cwd <path>` | `list`, `sync`, `mirror` | 按工作目录过滤 |
| `-IncludeArchived` | `list`, `sync`, `mirror` | 包含已归档线程 |
| `-IncludeImported` | `sync`, `mirror` | 包含已经是导入副本的记录 |
| `-DryRun` | 写入动作 | 只预览，不写入 |
| `-ForceNew` | `clone` | 强制创建新副本，不更新已有映射副本 |
| `-NoGlobalState` | 写入动作 | 跳过 Codex UI 全局状态更新 |

## 数据位置

工具按下面顺序寻找 Codex 历史目录：

1. 启动参数 `-CodexHome`。
2. 环境变量 `CODEX_HOME`。
3. `%USERPROFILE%\.codex`。
4. `%HOME%\.codex`。
5. 用户目录、LocalAppData、Roaming AppData 下的 `state_5.sqlite`。

一个典型的 Codex 历史目录长这样：

```text
.codex\
  state_5.sqlite
  sessions\
    YYYY\
      MM\
        DD\
          rollout-*.jsonl
```

找到后，GUI 日志区会显示 `Codex 记录目录：...`。如果没找到，GUI 会保持打开，等待你点击 `增加聊天记录`。

## 配置文件

新用户如果遇到 `请先选择账号` 或 `找不到 codex.exe`，点击 `软件设置`，按 `_help` 里的中文说明填写路径后保存即可。

1. GUI 会在根目录自动生成 `codex-history-sync-config.json`。
2. 如果已经自动检测到 Codex 历史记录、cc-switch 节点或 Codex CLI，配置文件会自动写入这些路径和账号列表。
3. 修改并保存配置文件后，GUI 会自动重新读取并刷新界面。

`codex-history-sync-config.template.json` 只是通用模板，适合发给别人参考；真实本机配置只写在 `codex-history-sync-config.json`。这个文件只适合保存本机路径和默认选项，不要写 API key 或 token。

如果根目录没有 `codex-history-sync-config.json`，GUI 会自动读取上一次运行保存的状态。这个状态保存在 `%APPDATA%\codex-history-sync-portable\last-state.json`，包含记录目录、账号目录、下拉菜单选择、目录筛选和勾选项，不包含 API key 或 token。

`从终端启动` 会在 Codex `config.toml` 里把当前工作目录写为 trusted，减少每次进入同一个目录都出现 `Do you trust the contents of this directory?` 确认提示。

关闭 GUI 后，弹窗提醒监控会继续在后台运行；再次打开 GUI 时会复用同一套配置并重启监控。GUI 本身只允许同时打开一个窗口。

fast 模式下的 Apps 插件兼容保护会自动启用，界面不再显示额外复选框。

## 同步规则

`clone` 和 `sync` 都是复制，不是移动。源线程仍然保留在原 provider 桶里，目标线程会有自己的新 id 和自己的 rollout 文件。

工具会在 Codex 历史目录里维护 `codex-history-sync-map.json`。如果同一条源线程已经同步过，下一次同步会更新已有目标副本，而不是重复创建一条新记录。

## cc-switch 支持

普通历史复制不强制依赖 cc-switch；没有 cc-switch 时仍然可以复制 `model_provider` 桶。

如果找到了 `cc-switch.db`，GUI 在同步到目标账号桶时会读取目标 cc-switch 节点的 Codex 配置，并用于改写目标副本的续聊元数据。例如同步到 `custom` 时，工具会读取 `Any Router` 节点里的 `model`、`model_reasoning_effort` 等配置，并对目标 rollout 做第三方兼容清理。

只有使用 GUI 里的 `cc-switch供应商` 下拉框切换供应商并启动 Codex 时，才需要找到 `cc-switch.db`。这个下拉框读取的是 cc-switch 里的 Codex 节点，例如 `OpenAI Official`、`Any Router` 或你自己配置的节点。

工具会自动尝试这些位置：

1. 启动参数 `-CcSwitchHome`。
2. 当前项目目录。
3. 当前项目目录的上级目录。
4. `%LOCALAPPDATA%\cc-switch\cc-switch.db`。
5. `%APPDATA%\cc-switch\cc-switch.db`。

如果新增节点后没有显示，先点 `刷新`。仍然没有时，点 `加载cc-switch.db配置`，选择包含 `cc-switch.db` 的目录。

注意：`Codex源账号` 和 `Codex目标账号` 表示 Codex 历史记录里的 `model_provider` 桶；`cc-switch供应商` 表示启动 Codex 时使用的 cc-switch 节点。两者不是同一个概念。

## 弹窗提醒

GUI 里的 `弹窗提醒` 默认用于本地提醒。启用后，工具会：

- 把 Codex 的 `notify` 设置写成 `tools\codex-turn-ended-notify.vbs`；
- 启动 `tools\codex-turn-complete-monitor.vbs`；
- 监控最近的 `rollout-*.jsonl` 文件；
- 发现 `task_complete` 事件后弹出置顶提示并播放提示音；
- 弹窗会尽量显示账号、完成的聊天和最近一条用户任务摘要。
- 桌面版 Codex 直接调用 `notify` 时，工具也会尝试解析 Codex 传入的事件参数；参数不足时会从最近的本地 rollout 记录补账号、会话和任务摘要。

这个功能只读取本机 session 文件，不会把通知内容发送到外部服务。

## 隐私与安全

这个仓库只应该包含脚本、启动器、文档和便携 SQLite 程序。它不应该包含：

- API key 或 access token。
- `.codex` 目录。
- `state_5.sqlite`。
- `sessions` 对话 transcript。
- `cc-switch.db`。
- 本地 provider 配置。
- 工具生成的备份。
- 个人日志或截图。

每次真实写入前，脚本会自动备份到：

```text
%USERPROFILE%\.codex\backups\history-sync-*
%USERPROFILE%\.codex\backups\codex-provider-switch-*
```

仓库里的 `.gitignore` 已经排除了常见本地数据库、Codex 状态文件、环境变量文件、日志、临时文件和备份目录。

## 文件说明

| 路径 | 说明 |
| --- | --- |
| `codex-history-sync-gui.vbs` | 无控制台窗口 GUI 启动器 |
| `codex-history-sync-gui.cmd` | 显示控制台的 GUI 启动器 |
| `codex-history-sync.cmd` | 命令行入口 |
| `tools\codex-history-sync-gui.ps1` | WinForms GUI 主程序 |
| `tools\codex-history-sync.ps1` | 核心同步脚本 |
| `tools\codex-turn-complete-monitor.ps1` | 监控本地 rollout 文件中的完成事件 |
| `tools\codex-turn-complete-monitor.vbs` | 无控制台窗口监控启动器 |
| `tools\codex-turn-ended-notify.ps1` | 本地弹窗提醒脚本 |
| `tools\codex-turn-ended-notify.vbs` | 无控制台窗口提醒启动器 |
| `bin\sqlite3.exe` | 便携 SQLite 命令行程序 |

## 适用场景

这个项目适合：

- 在官方 Codex provider 和自定义 provider 之间切换；
- 同时维护多个本地 provider 桶；
- 想保留不同账号视图下的历史连续性；
- 不想手动改 SQLite 或 rollout 文件；
- 想用 `-DryRun` 先预览本地历史同步操作。

## 限制

- 仅支持 Windows。
- 依赖 Codex Desktop 当前的本地历史文件结构。
- 不会解密、上传或云同步 Codex 历史。
- 不会做语义合并；它只复制和更新本地记录。
- cc-switch 支持是可选功能，并依赖本地 `cc-switch.db` 的结构。

## 常见问题

如果看不到 Codex 记录，点击 `增加聊天记录`，选择包含 `state_5.sqlite` 的文件夹。

如果 provider 列表不完整，先用对应 provider 打开一次 Codex，然后回到工具点击 `刷新`。

如果同步时报 rollout 文件正在被写入，暂停当前 Codex 对话或关闭 Codex 后再试。复制逻辑已经内置短暂重试。

如果启动 Codex 时看到 `MCP client for node_repl failed to start`，通常是 Codex Desktop 更新后旧运行时路径失效。通过 GUI 切换节点或启用弹窗提醒时，工具会自动修复 `config.toml` 里的 `node_repl.exe`、`node.exe`、`node_modules` 和 `codex.exe` 路径。

如果看不到 cc-switch 供应商，点击 `加载cc-switch.db配置`，选择包含 `cc-switch.db` 的目录。

## 开发说明

项目刻意使用普通 PowerShell 和 WinForms，不需要构建步骤。GUI 负责交互，真正的历史写入逻辑统一交给 CLI 脚本，这样 GUI 和命令行行为保持一致。

发布前建议检查：

```powershell
git status -sb
rg -n -i "api[_-]?key|secret|token|password|bearer|ghp_|github_pat_|sk-[A-Za-z0-9]"
rg -n -i "C:\\Users|\\.codex|state_5\\.sqlite|cc-switch\\.db|sessions\\\\|rollout-"
```

所有命中都应在发布前人工确认。

## 许可证

当前还没有添加 license 文件。在正式添加许可证前，请把这个项目视为 source-available。

项目内自带 `bin\sqlite3.exe`；SQLite 本身的许可证和分发说明请参考 SQLite 官方项目。
