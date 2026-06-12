# Codex History Sync Portable

[![Platform](https://img.shields.io/badge/platform-Windows-2563eb)](#requirements)
[![PowerShell](https://img.shields.io/badge/runtime-PowerShell-5391FE)](#requirements)
[![SQLite](https://img.shields.io/badge/storage-SQLite-003B57)](#data-layout)
[![Portable](https://img.shields.io/badge/install-portable-16a34a)](#quick-start)
[![Privacy](https://img.shields.io/badge/privacy-local--first-111827)](#privacy-and-safety)

Languages: [English](README.md) | [简体中文](README.zh-CN.md)

Codex History Sync Portable is a small Windows utility for copying Codex Desktop local chat history between different `model_provider` buckets, such as `openai`, `custom`, and other provider names used by local routing tools.

It is designed for people who switch Codex providers often and want the same local threads to remain visible across accounts without manually moving database rows or editing rollout files.

## Project Card

| Field | Value |
| --- | --- |
| Project type | Local desktop utility |
| Target platform | Windows |
| Interface | WinForms GUI plus PowerShell CLI |
| Data source | Local Codex `state_5.sqlite` and `sessions\rollout-*.jsonl` files |
| Network use | None for history sync |
| Write behavior | Copies or updates local history entries after confirmation |
| Backup behavior | Creates timestamped backups before modifying Codex files |
| Portable dependency | Bundled `sqlite3.exe` |

## TL;DR

1. Download or clone this project.
2. Run `codex-history-sync-gui.vbs` for the no-console GUI.
3. Pick a source provider and target provider.
4. Select the threads you want, then click `同步勾选`, or use `同步全部`.
5. The tool backs up Codex state before writing.

## Why This Exists

Codex Desktop stores local thread metadata in a SQLite database and places transcript rollout files under a `sessions` directory. The desktop UI separates those threads by the `threads.model_provider` value. If one provider writes history under `openai` and another writes under `custom`, the same local conversation can appear in one account bucket but not another.

This project automates the safe version of that migration:

- It keeps the original source thread.
- It creates or updates a destination copy.
- It rewrites the copied thread id inside the rollout file.
- It updates the target `model_provider`.
- When cc-switch is available, GUI sync uses the destination cc-switch node to rewrite `model`, `reasoning_effort`, and continuation metadata in the copied rollout.
- For non-official nodes, GUI sync enables proxy compatibility cleanup by removing official Codex-only reasoning and function/custom tool response items that can make routers such as Any Router or RightCode reject continued chats with `invalid codex request`.
- It records clone mappings so repeated syncs update existing copies instead of creating duplicates.

## Features

- GUI for browsing and syncing recent Codex threads.
- CLI for provider listing, one-off clone, one-way sync, two-way mirror, and mapping registration.
- Directory filter for syncing only threads from a selected workspace path.
- Automatic Codex history discovery from common local locations.
- Manual directory selection when the history directory is portable or custom.
- Automatic backups before writes.
- Optional cc-switch integration for reading Codex provider nodes and launching Codex through a selected node.
- Optional completion popup for Codex turn-ended notifications.
- Hidden-window VBS launchers for GUI and notification helpers.

## Requirements

- Windows 10 or later.
- PowerShell 5.1 or later.
- Codex Desktop local history files.
- A `state_5.sqlite` file and matching `sessions` directory.

The package includes `bin\sqlite3.exe` so users do not need to install SQLite separately for the normal portable workflow.

## Quick Start

Run the GUI:

```bat
codex-history-sync-gui.vbs
```

or, if you want to see a launcher console:

```bat
codex-history-sync-gui.cmd
```

The GUI opens with these main controls:

| Control | Purpose |
| --- | --- |
| `Codex源账号` | Provider bucket to copy from |
| `Codex目标账号` | Provider bucket to copy to |
| `目录筛选` | Restrict the list to a specific workspace path |
| `显示条数` | Maximum rows displayed in the thread table |
| `同步勾选` | Copy only checked rows |
| `同步全部` | Copy all listed source rows to the target provider |
| `双向同步` | Sync both directions between the selected providers |
| `cc switch节点` | cc-switch Codex node used by `从终端启动` |
| `从终端启动` | Open an elevated terminal; start a new chat when no row is checked; resume the one checked thread; reject multiple checked rows |
| `用 PowerShell` | Prefer PowerShell when checked; prefer CMD when unchecked; fall back automatically if the preferred terminal is unavailable |
| `打开配置` | Open root `codex-history-sync-config.json`; the GUI creates it if missing and reloads it after saves |
| `帮助` | Show path/account/start/update guidance and copy Everything search terms |
| `检查更新` | Check GitHub main for a newer version and apply a one-click hot update |
| `增加记录目录` | Manually load a `.codex` directory |

## CLI Usage

Use the CLI launcher when you want scriptable operations:

```bat
codex-history-sync.cmd providers
codex-history-sync.cmd list -From openai -Limit 20
codex-history-sync.cmd clone -Id <thread-id> -To custom
codex-history-sync.cmd sync -From openai -To custom
codex-history-sync.cmd mirror -Providers openai,custom
```

Useful switches:

| Switch | Applies to | Description |
| --- | --- | --- |
| `-CodexHome <path>` | all actions | Use a specific Codex home directory |
| `-Cwd <path>` | `list`, `sync`, `mirror` | Filter by workspace directory |
| `-IncludeArchived` | `list`, `sync`, `mirror` | Include archived Codex threads |
| `-IncludeImported` | `sync`, `mirror` | Include rows that are already imported clones |
| `-DryRun` | write actions | Show intended work without writing files |
| `-ForceNew` | `clone` | Create a new copy instead of updating an existing mapped copy |
| `-NoGlobalState` | write actions | Skip updates to Codex UI global state |

## Data Layout

The tool looks for Codex history in this order:

1. The `-CodexHome` argument.
2. The `CODEX_HOME` environment variable.
3. `%USERPROFILE%\.codex`.
4. `%HOME%\.codex`.
5. `state_5.sqlite` under user profile, LocalAppData, or Roaming AppData.

A valid Codex history directory usually contains:

```text
.codex\
  state_5.sqlite
  sessions\
    YYYY\
      MM\
        DD\
          rollout-*.jsonl
```

If you select `sessions` or a nested sessions folder by mistake, the GUI walks upward until it finds the parent directory containing `state_5.sqlite`.

## Config File

If a new user sees `请先选择账号` or `找不到 codex.exe`, click `打开配置`, fill the paths described in `_help`, then save the file.

1. The GUI creates root `codex-history-sync-config.json` automatically.
2. If Codex history, cc-switch nodes, or Codex CLI are detected, the config file is filled with those paths and account lists.
3. After you edit and save the config file, the GUI reloads it automatically.

`codex-history-sync-config.template.json` is a generic shareable template. The real local configuration lives in `codex-history-sync-config.json`. Keep API keys and tokens out of this file; it is intended only for local paths and default UI choices.

When no root `codex-history-sync-config.json` exists, the GUI restores the last saved runtime state from `%APPDATA%\codex-history-sync-portable\last-state.json`. That state stores local paths, selected providers, the directory filter, and checkbox choices, but not API keys or tokens.

`从终端启动` writes the current workspace to Codex `config.toml` as a trusted project and also passes the same trust override to Codex at launch, which reduces repeated `Do you trust the contents of this directory?` prompts for the same directory.

## Sync Semantics

`clone` and `sync` are copy operations, not moves. The original thread remains under the source provider. The target thread receives its own generated id and points to its own copied rollout file.

When the same source thread is synced again, the tool checks `codex-history-sync-map.json` in the Codex home directory. If a target copy is already mapped and still exists, the tool updates that existing copy.

## cc-switch Integration

Basic history copying does not strictly require cc-switch; without cc-switch, the tool can still copy between `model_provider` buckets.

When `cc-switch.db` is available, GUI sync reads the destination Codex node configuration and uses it to rewrite continuation metadata in the target copy. For example, syncing to `custom` reads the `Any Router` node model and reasoning settings, then applies proxy compatibility cleanup to the copied rollout.

If `cc-switch.db` is available, the GUI can read Codex nodes from cc-switch and display them in the `cc switch节点` dropdown. That dropdown is for launching Codex through a selected cc-switch node; the source and target history buckets still come from Codex `model_provider` values.

The tool searches for `cc-switch.db` in these places:

1. The `-CcSwitchHome` argument.
2. This project directory.
3. The parent of this project directory.
4. `%LOCALAPPDATA%\cc-switch\cc-switch.db`.
5. `%APPDATA%\cc-switch\cc-switch.db`.

If automatic discovery fails, use `增加账号目录` and select the folder containing `cc-switch.db`.

## Completion Popup

The GUI can enable a local completion popup for Codex responses. When `每次完成弹窗` is enabled, the tool:

- writes the local Codex `notify` setting to use `tools\codex-turn-ended-notify.vbs`;
- starts `tools\codex-turn-complete-monitor.vbs`;
- watches recent `rollout-*.jsonl` files for `task_complete` events;
- shows a topmost Windows popup and plays a short notification sound;
- includes a compact account, chat, and last user-task summary when local rollout context is available.
- also tries to parse event arguments passed by Codex Desktop's direct `notify` call and display the same compact summary.

This is local-only. It reads local session files and does not send notification data anywhere.

## Privacy And Safety

This repository is intended to contain only scripts, launchers, documentation, and the portable SQLite binary. It should not contain:

- API keys or access tokens.
- `.codex` directories.
- `state_5.sqlite`.
- `sessions` transcript files.
- `cc-switch.db`.
- local provider settings.
- backups generated by this tool.
- personal logs or screenshots.

Before every write operation, the sync scripts create backups under:

```text
%USERPROFILE%\.codex\backups\history-sync-*
%USERPROFILE%\.codex\backups\codex-provider-switch-*
```

The included `.gitignore` blocks common local databases, Codex state files, environment files, logs, temporary files, and generated backups from being committed.

## File Map

| Path | Purpose |
| --- | --- |
| `codex-history-sync-gui.vbs` | No-console GUI launcher |
| `codex-history-sync-gui.cmd` | Console-visible GUI launcher |
| `codex-history-sync.cmd` | CLI launcher |
| `tools\codex-history-sync-gui.ps1` | Main WinForms GUI |
| `tools\codex-history-sync.ps1` | Core CLI sync engine |
| `tools\codex-turn-complete-monitor.ps1` | Watches local rollout files for completion events |
| `tools\codex-turn-complete-monitor.vbs` | No-console monitor launcher |
| `tools\codex-turn-ended-notify.ps1` | Local popup notifier |
| `tools\codex-turn-ended-notify.vbs` | No-console notifier launcher |
| `bin\sqlite3.exe` | Portable SQLite command-line binary |

## Intended Use

This project is useful when:

- you switch between official and custom Codex providers;
- you keep multiple local provider buckets and want history continuity;
- you want a GUI instead of manually editing SQLite rows;
- you want a dry-run-friendly CLI for repeatable local maintenance.

## Limitations

- Windows-only.
- It depends on Codex Desktop's current local data layout.
- It does not decrypt, upload, or cloud-sync Codex history.
- It does not merge divergent conversations semantically; it copies and updates local records.
- cc-switch support is optional and depends on the local cc-switch database schema.

## Troubleshooting

If no Codex records appear, click `增加记录目录` and choose the folder containing `state_5.sqlite`.

If the provider list looks incomplete, click `刷新` after opening Codex once with the provider you expect.

If a sync fails because a rollout file is being written, close or pause active Codex work and retry. The copy routine already retries briefly when files are busy.

If cc-switch nodes do not appear, click `增加账号目录` and choose the directory that contains `cc-switch.db`.

## Development Notes

The code is intentionally plain PowerShell and WinForms so it can run on a normal Windows machine without a build step. The GUI delegates actual history writes to the CLI script, which keeps the sync behavior shared between GUI and command-line use.

Recommended pre-release checks:

```powershell
git status -sb
rg -n -i "api[_-]?key|secret|token|password|bearer|ghp_|github_pat_|sk-[A-Za-z0-9]"
rg -n -i "C:\\Users|\\.codex|state_5\\.sqlite|cc-switch\\.db|sessions\\\\|rollout-"
```

Review any matches before publishing.

## License

No license file is included yet. Until a license is added, treat the project as source-available by default.

SQLite is bundled as `bin\sqlite3.exe`; see the SQLite project for upstream license and distribution details.
