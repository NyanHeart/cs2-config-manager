# CS2 Config Manager

English | [简体中文](README.zh-CN.md)

A Windows and PowerShell 7 tool for managing CS2 configuration files across Steam accounts. It also manages local practice-server cfg files as templates deployed to the CS2 game directory.

## Features

- Discovers local Steam accounts with CS2 configuration folders.
- Maps numeric Steam IDs to readable account aliases.
- Backs up, previews, copies, and restores account-level configuration.
- Merges selected settings from external cfg files by `Viewmodel`, `Video`, `Hud`, `Radar`, and `Audio` categories.
- Imports, updates, and deploys local practice-server cfg templates.
- Supports `-WhatIf`, automatic backups, and SHA-256 verification for write operations.
- Excludes non-portable Steam Cloud, inventory, and `trustedlaunch.cfg` state by default.

## Script Languages

The scripts have identical functionality. Their help, prompts, and errors are localized:

- `Cs2Config.zh-CN.ps1`: Simplified Chinese
- `Cs2Config.en-US.ps1`: English

Both scripts store runtime state relative to their own location in `.tmp`. Account aliases, templates, backups, and logs are not committed to Git.

## Requirements

- Windows
- PowerShell 7 or later
- Steam and Counter-Strike 2 installed

## Quick Start

List available accounts with the English script:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 account list
```

Set an account alias:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  account alias set -Account 123456789 -Name primary
```

Back up an account configuration:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  backup -Account primary -IncludeCustomCfg
```

Preview and then copy common settings from one account to another:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  apply -Source primary -Target secondary -WhatIf

pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  apply -Source primary -Target secondary
```

## Applying Selected Settings from an External cfg

External `autoexec.cfg` files commonly contain bindings, sensitivity, crosshair, and personal settings. Use `apply-preset` to merge only the categories you choose:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  apply-preset `
  -Account primary `
  -PresetPath C:\Users\you\Downloads\autoexec.cfg `
  -Sections Viewmodel,Video,Hud,Radar,Audio `
  -WhatIf
```

Review the preview, then remove `-WhatIf` to apply it. Unselected categories such as bindings, crosshair, and sensitivity are not changed.

If you have a separate `cs2_video.txt`, provide it with `-VideoPath`. Recognized video settings are merged without replacing GPU device IDs, monitor index, or refresh rate.

## Practice Templates

Practice cfg files are not account-level files. When you run `exec <name>`, CS2 resolves cfg files from the game installation directory, so a deployed practice template is shared by local accounts.

```powershell
# Import an existing cfg as a template
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  practice template import `
  -Name practice `
  -SourcePath C:\Users\you\Downloads\practice.cfg

# Deploy it to the CS2 game directory
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 `
  practice apply -Name practice
```

On a local server, open the CS2 console and run:

```text
exec practice
```

## Safety

Commands that write settings refuse to run while `cs2.exe` is active. Before writing, the script creates a backup with `manifest.json` and SHA-256 hashes in `.tmp\backups`; operation summaries go to `.tmp\logs`.

The following are excluded from account copying by default:

- `trustedlaunch.cfg`
- `*_lastclouded`
- `remote\`
- `remotecache.vdf`
- `socache.dt`

List backups and preview a restore before making a change:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 backup list -Account primary
pwsh.exe -NoLogo -NoProfile -File .\Cs2Config.en-US.ps1 restore -Account primary -Backup <backup-directory-name> -WhatIf
```

## Help

```powershell
Get-Help .\Cs2Config.en-US.ps1 -Full
Get-Help .\Cs2Config.zh-CN.ps1 -Examples
```

## License

[MIT License](LICENSE)
