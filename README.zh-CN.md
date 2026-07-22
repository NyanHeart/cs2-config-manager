# CS2 Config Manager

[English](README.md) | 中文

一个面向 Windows 与 PowerShell 7 的 CS2 配置管理脚本。它管理 Steam 多账号的通用游戏配置，并将本地跑图 cfg 作为独立模板部署到 CS2 实际读取的游戏目录。

## 功能

- 自动发现本机带有 CS2 配置的 Steam 账号。
- 为数字 Steam ID 设置可读的账号别名。
- 备份、预览、复制和恢复账号级配置。
- 从外来 cfg 中按 `Viewmodel`、`Video`、`Hud`、`Radar`、`Audio` 分类合并设置。
- 导入、更新和部署本地跑图练习服 cfg 模板。
- 对写入操作提供 `--what-if`、自动备份和 SHA-256 校验。
- 默认排除 Steam Cloud、库存状态和 `trustedlaunch.cfg` 等不可移植文件。

## 脚本语言

两份脚本功能完全相同，只是帮助、提示和错误信息语言不同：

- `Cs2Config.zh-CN.ps1`：中文版本
- `Cs2Config.en-US.ps1`：English version

两份脚本均把运行时数据保存到其所在目录相对路径的 `.tmp` 中：账号别名、模板、备份和操作日志都不会提交到 Git。

`CliFramework.ps1` 是共用的命令路径解析与帮助框架；使用任一入口脚本时，都应将它保留在同一目录。

## 命令行约定

- 高频参数使用单字母：`-a` 账号、`-s` 来源、`-t` 目标、`-n` 名称、`-p` 预设路径、`-c` 分类、`-b` 备份、`-i` 包含自定义 cfg、`-h` 帮助。
- 完整参数使用小写连字符：`--account`、`--preset-path`、`--include-custom-cfg`、`--what-if`。
- 低频参数仅提供完整形式，例如 `--new-name`、`--source-path`、`--config-path`、`--video-path`、`--force`。

## 要求

- Windows
- PowerShell 7 或更高版本
- 已安装 Steam 与 Counter-Strike 2

## 快速开始

使用中文版本列出可用账号：

```powershell
Cs2Config.zh-CN.ps1 account list
```

为账号建立别名（也支持更短的 `account set` 写法）：

```powershell
Cs2Config.zh-CN.ps1 `
  account set -a 123456789 -n primary
```

备份账号配置：

```powershell
Cs2Config.zh-CN.ps1 `
  backup --account primary --include-custom-cfg
```

预览并复制一个账号的通用配置到另一个账号：

```powershell
Cs2Config.zh-CN.ps1 `
  apply -s primary -t secondary --what-if

Cs2Config.zh-CN.ps1 `
  apply -s primary -t secondary
```

## 应用外来 cfg 的指定分类

外来 `autoexec.cfg` 往往同时包含键位、灵敏度、准星和其他个人信息。使用 `apply-preset` 只合并选定分类：

```powershell
Cs2Config.zh-CN.ps1 `
  apply-preset `
  --account primary `
  --preset-path C:\Users\you\Downloads\autoexec.cfg `
  --sections Viewmodel,Video,Hud,Radar,Audio `
  --what-if
```

先确认预览，再移除 `--what-if` 实际应用。未选择的分类，例如键位、准星与灵敏度，不会被修改。

如有独立 `cs2_video.txt`，可额外提供 `--video-path`。脚本会合并可识别的视频设置，不覆盖显卡设备 ID、显示器序号或刷新率。

## 跑图练习服模板

练习服 cfg 不是账号级文件。CS2 执行 `exec <名称>` 时优先从游戏安装目录读取 cfg，因此模板部署对本机所有账号有效。

```powershell
# 从已有 cfg 导入模板
Cs2Config.zh-CN.ps1 `
  practice template import `
  -n practice `
  --source-path C:\Users\you\Downloads\practice.cfg

# 部署到 CS2 游戏目录
Cs2Config.zh-CN.ps1 `
  practice apply -n practice
```

进入本地服务器后，在控制台执行：

```text
exec practice
```

## 安全说明

所有会写入配置的命令都会拒绝在 `cs2.exe` 运行时执行。写入前会在 `.tmp\backups` 创建带 `manifest.json` 和 SHA-256 的备份；操作摘要写入 `.tmp\logs`。

默认不会复制：

- `trustedlaunch.cfg`
- `*_lastclouded`
- `remote\`
- `remotecache.vdf`
- `socache.dt`

恢复前可先查看备份并使用 `--what-if`：

```powershell
Cs2Config.zh-CN.ps1 backup list -a primary
Cs2Config.zh-CN.ps1 restore -a primary -b <备份目录名> --what-if
```

## 帮助

不带参数运行脚本，或追加 `--help`，即可查看简洁的命令总览：

```powershell
Cs2Config.zh-CN.ps1
Cs2Config.zh-CN.ps1 --help
```

每一层命令都支持帮助，包括深层命令路径：

```powershell
Cs2Config.zh-CN.ps1 account set --help
Cs2Config.zh-CN.ps1 help practice template import
```

完整参数说明与示例可使用 PowerShell 帮助：

```powershell
Get-Help Cs2Config.zh-CN.ps1 -Full
Get-Help Cs2Config.en-US.ps1 -Examples
```

## 许可证

[MIT License](LICENSE)
