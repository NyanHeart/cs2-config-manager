<#
.SYNOPSIS
    CS2 配置管理工具。

.DESCRIPTION
    管理账号级 CS2 设置与本机共享的练习服配置。
    所有运行数据均存放在相对于脚本的 .tmp 目录。
    不提供命令，或使用 help、--help、-h、/? 时显示命令总览。

    账号级配置位于 Steam userdata 目录，使用账号别名或 Steam 数字 ID 操作。
    练习服配置位于 CS2 游戏安装目录，所有本机账号共享。
    所有写入命令会在 CS2 运行时拒绝执行，并支持 -WhatIf 预览。

.PARAMETER Command
    可选的顶级命令：account、backup、apply、apply-preset、restore 或 practice。

.PARAMETER Account
    账号别名或 Steam 数字 ID。可通过 account list 查看可用账号。

.PARAMETER Source
    apply 命令的来源账号别名或 Steam 数字 ID。

.PARAMETER Target
    apply 命令的目标账号别名或 Steam 数字 ID。

.PARAMETER Sections
    apply-preset 要合并的分类。可用值：Viewmodel、Video、Hud、Radar、Audio。
    可使用逗号分隔，例如 Viewmodel,Hud,Radar。

.PARAMETER Name
    练习服模板名称，不含 .cfg 扩展名。游戏内使用 exec <名称> 执行。

.EXAMPLE
    Cs2Config.ps1 account list

    列出当前电脑中检测到的、包含 CS2 配置的 Steam 账号。

.EXAMPLE
    Cs2Config.ps1 account alias set -Account 123456789 -Name primary

    为账号设置别名。之后可在命令中用 primary 代替数字 Steam ID。

.EXAMPLE
    Cs2Config.ps1 backup -Account primary -IncludeCustomCfg

    备份账号的通用 CS2 配置和自定义 .cfg 文件到脚本相对 .tmp\backups 目录。
    trustedlaunch.cfg、Steam Cloud 状态和库存文件会被排除。

.EXAMPLE
    Cs2Config.ps1 apply -Source primary -Target secondary -WhatIf

    预览从 primary 复制到 secondary 的账号配置变更，不写入任何文件。

.EXAMPLE
    Cs2Config.ps1 apply -Source primary -Target secondary

    实际复制通用账号配置。目标文件会先备份，并在复制后进行 SHA-256 校验。

.EXAMPLE
    Cs2Config.ps1 apply-preset -Account primary -PresetPath C:\Users\<your-user>\Downloads\autoexec.cfg -Sections Viewmodel,Hud,Radar,Audio -WhatIf

    预览从外来 cfg 中按分类提取设置并合并到指定账号。键位、准星、灵敏度等未选分类不会修改。

.EXAMPLE
    Cs2Config.ps1 practice template import -Name practice -SourcePath C:\Users\<your-user>\Downloads\practice.cfg
    Cs2Config.ps1 practice apply -Name practice

    导入练习服模板并部署到 CS2 游戏目录。进入本地服务器后，在控制台执行 exec practice。

.EXAMPLE
    Cs2Config.ps1 backup list -Account primary
    Cs2Config.ps1 restore -Account primary -Backup <备份目录名> -WhatIf

    列出账号备份，并预览恢复指定备份。

.NOTES
    附属数据目录相对于脚本自身：.tmp\Cs2Config.accounts.json、.tmp\templates、.tmp\backups、.tmp\logs。
    对会写入配置的命令，建议先使用 -WhatIf 检查影响范围。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Action,

    [Parameter(Position = 2)]
    [string]$Subaction,

    [string]$Account,
    [string]$Source,
    [string]$Target,
    [string]$Name,
    [string]$NewName,
    [string]$PresetPath,
    [string]$VideoPath,
    [string]$SourcePath,
    [string]$ConfigPath,
    [string]$Backup,
    [string[]]$Sections,
    [switch]$IncludeCustomCfg,
    [switch]$Force,
    [Alias('h', '?')]
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# pwsh -File 会将逗号分隔的分类视为一个参数，统一拆分后再处理。
if ($Sections) {
    $Sections = @($Sections | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# 所有辅助文件相对于脚本自身存放，移动整个 scripts 目录后仍可工作。
$ScriptRoot = Split-Path -Parent $PSCommandPath
$CliFrameworkPath = Join-Path $ScriptRoot 'CliFramework.ps1'
if (-not (Test-Path -LiteralPath $CliFrameworkPath)) {
    throw "未找到 CLI 框架文件: $CliFrameworkPath"
}
. $CliFrameworkPath
$CliRouteAliases = @{ 'account set' = @('account', 'alias', 'set'); 'account rename' = @('account', 'alias', 'rename'); 'account remove' = @('account', 'alias', 'remove') }
$StateRoot = Join-Path $ScriptRoot '.tmp'
$AccountsFile = Join-Path $StateRoot 'Cs2Config.accounts.json'
$TemplatesRoot = Join-Path $StateRoot 'templates'
$BackupsRoot = Join-Path $StateRoot 'backups'
$LogsRoot = Join-Path $StateRoot 'logs'
$AppId = '730'

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Warning $Message
}

function Ensure-StateDirectories {
    foreach ($directory in @($StateRoot, $TemplatesRoot, $BackupsRoot, $LogsRoot)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
}

function Get-SteamRoot {
    $registryPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($registryPath in $registryPaths) {
        if (Test-Path -LiteralPath $registryPath) {
            $installPath = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).InstallPath
            if ($installPath -and (Test-Path -LiteralPath $installPath)) {
                return $installPath
            }
        }
    }

    $fallback = 'C:\Program Files (x86)\Steam'
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw '无法定位 Steam 安装目录。请确认 Steam 已安装。'
}

function Get-GameCfgDirectory {
    $steamRoot = Get-SteamRoot
    $gameCfg = Join-Path $steamRoot 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
    if (-not (Test-Path -LiteralPath $gameCfg)) {
        throw "未找到 CS2 游戏配置目录: $gameCfg"
    }
    return $gameCfg
}

function Test-Cs2Running {
    return $null -ne (Get-Process -Name 'cs2' -ErrorAction SilentlyContinue)
}

function Assert-Cs2Stopped {
    if (Test-Cs2Running) {
        throw '检测到 cs2.exe 正在运行。请先完全退出 CS2，再执行会写入配置的命令。'
    }
}

function Get-AccountsStore {
    if (-not (Test-Path -LiteralPath $AccountsFile)) {
        return [ordered]@{
            version = 1
            accounts = [ordered]@{}
        }
    }

    try {
        $store = Get-Content -LiteralPath $AccountsFile -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "账号别名文件无法解析: $AccountsFile。$($_.Exception.Message)"
    }

    if (-not $store.Contains('accounts')) {
        $store.accounts = [ordered]@{}
    }
    return $store
}

function Save-AccountsStore {
    param([System.Collections.IDictionary]$Store)

    Ensure-StateDirectories
    # 使用唯一临时文件，避免多个 PowerShell 进程争抢同一个 .new 文件。
    $temporaryPath = "$AccountsFile.$([guid]::NewGuid().ToString('N')).new"
    $Store | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $AccountsFile -Force
}

function Invoke-WithAccountsLock {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    # 别名操作是读-改-写流程，必须整体加锁，不能只锁最后一次写文件。
    $mutex = [System.Threading.Mutex]::new($false, 'Local\Cs2Config.AccountAliases')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $hasLock) { throw '等待账号别名文件锁超时。请稍后重试。' }
        return & $ScriptBlock
    }
    finally {
        if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Get-Cs2Accounts {
    $steamRoot = Get-SteamRoot
    $userdataPath = Join-Path $steamRoot 'userdata'
    if (-not (Test-Path -LiteralPath $userdataPath)) {
        throw "未找到 Steam userdata 目录: $userdataPath"
    }

    $store = Get-AccountsStore
    $accounts = foreach ($directory in Get-ChildItem -LiteralPath $userdataPath -Directory) {
        if ($directory.Name -notmatch '^\d+$') {
            continue
        }

        $cfgPath = Join-Path $directory.FullName "$AppId\local\cfg"
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            continue
        }

        $alias = ''
        foreach ($entry in $store.accounts.GetEnumerator()) {
            if ([string]$entry.Value.steamId -eq $directory.Name) {
                $alias = $entry.Key
                break
            }
        }

        [pscustomobject]@{
            Alias = $alias
            SteamId = $directory.Name
            CfgPath = $cfgPath
        }
    }

    return @($accounts | Sort-Object Alias, SteamId)
}

function Resolve-Account {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identifier
    )

    $store = Get-AccountsStore
    $steamId = $Identifier
    if ($store.accounts.Contains($Identifier)) {
        $steamId = [string]$store.accounts[$Identifier].steamId
    }

    $account = Get-Cs2Accounts | Where-Object { $_.SteamId -eq $steamId } | Select-Object -First 1
    if (-not $account) {
        throw "未找到账号 '$Identifier' 的 CS2 配置目录。先运行 'account list' 确认账号。"
    }
    return $account
}

function Test-ValidName {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "名称 '$Value' 不合法。只允许英文、数字、- 和 _，且必须以英文或数字开头。"
    }
}

function Get-AccountConfigFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ResolvedAccount,
        [switch]$CustomCfg
    )

    $files = foreach ($file in Get-ChildItem -LiteralPath $ResolvedAccount.CfgPath -File) {
        # trustedlaunch 是 CS2 的安全启动状态，不是可移植的自定义配置。
        if ($file.Name -eq 'trustedlaunch.cfg' -or $file.Name -like '*_lastclouded') {
            continue
        }

        $isCoreFile = $file.Name -match '^cs2_user_convars_.*\.vcfg$' -or
            $file.Name -match '^cs2_user_keys_.*\.vcfg$' -or
            $file.Name -in @('cs2_machine_convars.vcfg', 'cs2_video.txt')

        $isCustomCfg = $CustomCfg -and $file.Extension -eq '.cfg'
        if ($isCoreFile -or $isCustomCfg) {
            $file
        }
    }
    return @($files | Sort-Object Name)
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-Backup {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory = $true)]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Ensure-StateDirectories
    $backupId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $Scope, $Label
    $backupDirectory = Join-Path $BackupsRoot $backupId
    $filesDirectory = Join-Path $backupDirectory 'files'
    New-Item -ItemType Directory -Path $filesDirectory -Force | Out-Null

    $records = foreach ($file in $Files) {
        $backupFile = Join-Path $filesDirectory $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $backupFile -Force
        [ordered]@{
            name = $file.Name
            originalPath = $file.FullName
            size = $file.Length
            sha256 = Get-FileSha256 -Path $file.FullName
        }
    }

    $manifest = [ordered]@{
        version = 1
        createdAt = (Get-Date).ToString('o')
        scope = $Scope
        label = $Label
        files = @($records)
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupDirectory 'manifest.json') -Encoding utf8
    return [pscustomobject]@{ Id = $backupId; Directory = $backupDirectory }
}

function Show-Changes {
    param([object[]]$Changes)
    if ($Changes.Count -eq 0) {
        Write-Host '没有需要写入的变更。' -ForegroundColor Green
        return
    }
    $Changes | Format-Table -AutoSize | Out-Host
}

function Write-OperationLog {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [hashtable]$Details = @{}
    )
    Ensure-StateDirectories
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        operation = $Operation
        details = $Details
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    Add-Content -LiteralPath (Join-Path $LogsRoot 'operations.jsonl') -Value $line -Encoding utf8
}

function Get-CommandsFromCfg {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "未找到来源配置: $Path"
    }

    $commands = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*//') { continue }
        if ($line -match '^\s*([A-Za-z0-9_]+)\s+(?:"([^"]*)"|([^\s;]+))') {
            $key = $Matches[1].ToLowerInvariant()
            $value = if ($null -ne $Matches[2]) { $Matches[2] } else { $Matches[3] }
            $commands[$key] = $value
        }
    }
    return $commands
}

function Get-SectionCommands {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Commands,
        [Parameter(Mandatory = $true)][string[]]$SelectedSections
    )

    $validSections = @('Viewmodel', 'Video', 'Hud', 'Radar', 'Audio')
    foreach ($section in $SelectedSections) {
        if ($section -notin $validSections) {
            throw "不支持的配置分类 '$section'。可用值: $($validSections -join ', ')"
        }
    }

    $selected = [ordered]@{}
    foreach ($entry in $Commands.GetEnumerator()) {
        $key = $entry.Key
        $include =
            ($SelectedSections -contains 'Viewmodel' -and $key -like 'viewmodel_*') -or
            ($SelectedSections -contains 'Hud' -and ($key -match '^(cl_hud_|hud_|safezone)')) -or
            ($SelectedSections -contains 'Radar' -and ($key -match '^(cl_radar_|mapoverview_)')) -or
            ($SelectedSections -contains 'Audio' -and ($key -match '^(snd_|voice_)' -or $key -eq 'volume')) -or
            ($SelectedSections -contains 'Video' -and $key -in @('fps_max', 'r_fullscreen_gamma', 'r_player_visibility_mode', 'mat_vsync', 'r_low_latency'))

        if ($include) {
            $selected[$key] = $entry.Value
        }
    }
    return $selected
}

function Get-VcfgUpdate {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )

    $content = Get-Content -LiteralPath $File.FullName -Raw
    $updatedContent = $content
    $changedKeys = [System.Collections.Generic.List[string]]::new()
    $missingKeys = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $Settings.GetEnumerator()) {
        $key = $entry.Key
        $value = [string]$entry.Value
        # CS2 机器配置会为部分键附带 $2、$3 等槽位后缀。
        $pattern = '(?m)^(\s*"' + [regex]::Escape($key) + '(?:\$\d+)?"\s*")(?<value>[^"]*)(")'
        $match = [regex]::Match($updatedContent, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            $missingKeys.Add($key)
            continue
        }

        if ($match.Groups['value'].Value -ne $value) {
            $updatedContent = [regex]::Replace(
                $updatedContent,
                $pattern,
                {
                    param($matchValue)
                    "$($matchValue.Groups[1].Value)$value$($matchValue.Groups[3].Value)"
                },
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            $changedKeys.Add($key)
        }
    }

    return [pscustomobject]@{
        File = $File
        Content = $updatedContent
        ChangedKeys = @($changedKeys)
        MissingKeys = @($missingKeys)
    }
}

function Test-VcfgContainsSetting {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $content = Get-Content -LiteralPath $File.FullName -Raw
    $pattern = '(?m)^\s*"' + [regex]::Escape($Key) + '(?:\$\d+)?"\s*"'
    return [regex]::IsMatch($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-VideoConfigUpdate {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$TargetFile,
        [Parameter(Mandatory = $true)][string]$SourceFile
    )

    if (-not (Test-Path -LiteralPath $SourceFile)) {
        throw "未找到视频来源文件: $SourceFile"
    }

    $sourceContent = Get-Content -LiteralPath $SourceFile -Raw
    $sourceSettings = [ordered]@{}
    foreach ($match in [regex]::Matches($sourceContent, '(?m)^\s*"(?<key>setting\.[^"]+|AutoConfig)"\s+"(?<value>[^"]*)"')) {
        $sourceSettings[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }

    if ($sourceSettings.Count -eq 0) {
        throw "视频来源文件中未找到 setting.* 配置: $SourceFile"
    }

    $content = Get-Content -LiteralPath $TargetFile.FullName -Raw
    $updatedContent = $content
    $changedKeys = [System.Collections.Generic.List[string]]::new()
    $missingKeys = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $sourceSettings.GetEnumerator()) {
        $key = $entry.Key
        $value = [string]$entry.Value
        $pattern = '(?m)^(\s*"' + [regex]::Escape($key) + '"\s*")(?<value>[^"]*)(")'
        $match = [regex]::Match($updatedContent, $pattern)
        if (-not $match.Success) {
            $missingKeys.Add($key)
            continue
        }
        if ($match.Groups['value'].Value -ne $value) {
            $updatedContent = [regex]::Replace($updatedContent, $pattern, {
                    param($matchValue)
                    "$($matchValue.Groups[1].Value)$value$($matchValue.Groups[3].Value)"
                })
            $changedKeys.Add($key)
        }
    }

    return [pscustomobject]@{
        File = $TargetFile
        Content = $updatedContent
        ChangedKeys = @($changedKeys)
        MissingKeys = @($missingKeys)
    }
}

function Save-TextFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-AccountBackup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $resolvedAccount = Resolve-Account -Identifier $Account
    $files = Get-AccountConfigFiles -ResolvedAccount $resolvedAccount -CustomCfg:$IncludeCustomCfg
    if ($files.Count -eq 0) { throw '没有找到可备份的 CS2 配置文件。' }

    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, '创建账号配置备份')) {
        $result = New-Backup -Files $files -Scope 'account' -Label $resolvedAccount.SteamId
        Write-Info "备份完成: $($result.Directory)"
        Write-OperationLog -Operation 'backup' -Details @{ account = $resolvedAccount.SteamId; backup = $result.Id }
    }
}

function Invoke-AccountApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $sourceAccount = Resolve-Account -Identifier $Source
    $targetAccount = Resolve-Account -Identifier $Target
    if ($sourceAccount.SteamId -eq $targetAccount.SteamId) { throw '来源账号与目标账号相同。' }

    $sourceFiles = Get-AccountConfigFiles -ResolvedAccount $sourceAccount -CustomCfg:$IncludeCustomCfg
    $changes = foreach ($sourceFile in $sourceFiles) {
        $targetPath = Join-Path $targetAccount.CfgPath $sourceFile.Name
        $status = if (-not (Test-Path -LiteralPath $targetPath)) { '新增' }
        elseif ((Get-FileSha256 -Path $sourceFile.FullName) -eq (Get-FileSha256 -Path $targetPath)) { '相同' }
        else { '更新' }
        [pscustomobject]@{ File = $sourceFile.Name; Status = $status }
    }

    Write-Info "来源: $($sourceAccount.Alias) ($($sourceAccount.SteamId))"
    Write-Info "目标: $($targetAccount.Alias) ($($targetAccount.SteamId))"
    Show-Changes -Changes $changes
    $pending = @($changes | Where-Object Status -ne '相同')
    if ($pending.Count -eq 0) { return }

    if ($PSCmdlet.ShouldProcess($targetAccount.CfgPath, "复制 $($pending.Count) 个通用配置文件")) {
        $existingTargetFiles = foreach ($change in $pending) {
            $path = Join-Path $targetAccount.CfgPath $change.File
            if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path }
        }
        if (@($existingTargetFiles).Count -gt 0) {
            $backupResult = New-Backup -Files @($existingTargetFiles) -Scope 'account' -Label $targetAccount.SteamId
            Write-Info "目标配置已备份: $($backupResult.Directory)"
        }

        foreach ($change in $pending) {
            $sourceFile = $sourceFiles | Where-Object Name -eq $change.File | Select-Object -First 1
            $targetPath = Join-Path $targetAccount.CfgPath $change.File
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -Force
            if ((Get-FileSha256 -Path $sourceFile.FullName) -ne (Get-FileSha256 -Path $targetPath)) {
                throw "校验失败: $($change.File)"
            }
        }
        Write-Info '账号配置复制并哈希校验完成。'
        Write-OperationLog -Operation 'apply' -Details @{ source = $sourceAccount.SteamId; target = $targetAccount.SteamId; files = @($pending.File) }
    }
}

function Invoke-PresetApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $resolvedAccount = Resolve-Account -Identifier $Account
    if (-not $Sections -or $Sections.Count -eq 0) {
        throw 'apply-preset 必须通过 -Sections 指定至少一个分类。'
    }

    $commands = Get-CommandsFromCfg -Path $PresetPath
    $selectedCommands = Get-SectionCommands -Commands $commands -SelectedSections $Sections
    $updates = [System.Collections.Generic.List[object]]::new()

    $userFile = Get-ChildItem -LiteralPath $resolvedAccount.CfgPath -Filter 'cs2_user_convars_*.vcfg' -File | Where-Object Name -notlike '*_lastclouded' | Select-Object -First 1
    $machineFile = Get-Item -LiteralPath (Join-Path $resolvedAccount.CfgPath 'cs2_machine_convars.vcfg')
    if (-not $userFile) { throw '未找到 cs2_user_convars 配置文件。' }

    $userCommands = [ordered]@{}
    $machineCommands = [ordered]@{}
    foreach ($entry in $selectedCommands.GetEnumerator()) {
        # 同一类设置可能被 CS2 保存到用户 VCFG 或机器 VCFG；按实际键所在位置路由。
        if (Test-VcfgContainsSetting -File $userFile -Key $entry.Key) {
            $userCommands[$entry.Key] = $entry.Value
        }
        else {
            $machineCommands[$entry.Key] = $entry.Value
        }
    }
    if ($userCommands.Count -gt 0) { $updates.Add((Get-VcfgUpdate -File $userFile -Settings $userCommands)) }
    if ($machineCommands.Count -gt 0) { $updates.Add((Get-VcfgUpdate -File $machineFile -Settings $machineCommands)) }

    if ($VideoPath) {
        if ('Video' -notin $Sections) { Write-WarningMessage '已提供 -VideoPath，但未选择 Video 分类，视频文件将被忽略。' }
        else {
            $videoFile = Get-Item -LiteralPath (Join-Path $resolvedAccount.CfgPath 'cs2_video.txt')
            $updates.Add((Get-VideoConfigUpdate -TargetFile $videoFile -SourceFile $VideoPath))
        }
    }

    $changes = foreach ($update in $updates) {
        foreach ($key in $update.ChangedKeys) {
            [pscustomobject]@{ File = $update.File.Name; Setting = $key; Status = '更新' }
        }
        foreach ($key in $update.MissingKeys) {
            [pscustomobject]@{ File = $update.File.Name; Setting = $key; Status = '目标缺失，跳过' }
        }
    }
    Show-Changes -Changes @($changes)
    $changedUpdates = @($updates | Where-Object { $_.ChangedKeys.Count -gt 0 })
    if ($changedUpdates.Count -eq 0) { return }

    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, '按分类合并外来配置')) {
        $backupResult = New-Backup -Files @($changedUpdates.File) -Scope 'preset' -Label $resolvedAccount.SteamId
        Write-Info "目标配置已备份: $($backupResult.Directory)"
        foreach ($update in $changedUpdates) {
            Save-TextFile -Path $update.File.FullName -Content $update.Content
        }
        Write-Info '预设已应用。'
        Write-OperationLog -Operation 'apply-preset' -Details @{ account = $resolvedAccount.SteamId; sections = @($Sections); preset = $PresetPath }
    }
}

function Get-TemplatePath {
    param([Parameter(Mandatory = $true)][string]$TemplateName)
    Test-ValidName -Value $TemplateName
    return (Join-Path $TemplatesRoot "$TemplateName.cfg")
}

function Get-PracticeSourcePath {
    if ($SourcePath) {
        return (Resolve-Path -LiteralPath $SourcePath).Path
    }
    if ($Account -and $ConfigPath) {
        $resolvedAccount = Resolve-Account -Identifier $Account
        $accountSource = Join-Path $resolvedAccount.CfgPath $ConfigPath
        if (-not (Test-Path -LiteralPath $accountSource)) {
            throw "账号配置中未找到来源文件: $accountSource"
        }
        return $accountSource
    }
    throw '请使用 -SourcePath，或同时使用 -Account 和 -ConfigPath 指定模板来源。'
}

function Invoke-PracticeTemplateImport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Update)
    Assert-Cs2Stopped
    if (-not $Name) { throw 'practice template import/update 必须提供 -Name。' }
    $templatePath = Get-TemplatePath -TemplateName $Name
    $sourceCfgPath = Get-PracticeSourcePath
    if ((Test-Path -LiteralPath $templatePath) -and -not $Update -and -not $Force) {
        throw "模板已存在: $templatePath。使用 'practice template update' 更新，或加 -Force 覆盖。"
    }

    if ($PSCmdlet.ShouldProcess($templatePath, "导入模板 $Name")) {
        Ensure-StateDirectories
        if (Test-Path -LiteralPath $templatePath) {
            $backupResult = New-Backup -Files @((Get-Item -LiteralPath $templatePath)) -Scope 'template' -Label $Name
            Write-Info "旧模板已备份: $($backupResult.Directory)"
        }
        Copy-Item -LiteralPath $sourceCfgPath -Destination $templatePath -Force
        Write-Info "模板已保存: $templatePath"
        Write-OperationLog -Operation 'practice-template-import' -Details @{ name = $Name; source = $sourceCfgPath }
    }
}

function Invoke-PracticeApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    if (-not $Name) { throw 'practice apply 必须提供 -Name。' }
    $templatePath = Get-TemplatePath -TemplateName $Name
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "未找到模板: $templatePath。先使用 'practice template import' 导入。"
    }

    $targetPath = Join-Path (Get-GameCfgDirectory) "$Name.cfg"
    $status = if (-not (Test-Path -LiteralPath $targetPath)) { '新增' }
    elseif ((Get-FileSha256 -Path $templatePath) -eq (Get-FileSha256 -Path $targetPath)) { '相同' }
    else { '更新' }
    Show-Changes -Changes @([pscustomobject]@{ File = "$Name.cfg"; Status = $status; Target = $targetPath })
    if ($status -eq '相同') { return }

    if ($PSCmdlet.ShouldProcess($targetPath, "部署练习服模板 $Name")) {
        if (Test-Path -LiteralPath $targetPath) {
            $backupResult = New-Backup -Files @((Get-Item -LiteralPath $targetPath)) -Scope 'practice' -Label $Name
            Write-Info "游戏目录旧配置已备份: $($backupResult.Directory)"
        }
        Copy-Item -LiteralPath $templatePath -Destination $targetPath -Force
        if ((Get-FileSha256 -Path $templatePath) -ne (Get-FileSha256 -Path $targetPath)) {
            throw "练习服配置校验失败: $targetPath"
        }
        Write-Info "练习服配置已部署。游戏内执行: exec $Name"
        Write-OperationLog -Operation 'practice-apply' -Details @{ name = $Name; target = $targetPath }
    }
}

function Invoke-AccountRestore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $resolvedAccount = Resolve-Account -Identifier $Account
    if (-not $Backup) { throw 'restore 必须提供 -Backup。先使用 backup list 查看可用备份。' }
    $backupDirectory = Get-ChildItem -LiteralPath $BackupsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -eq $Backup | Select-Object -First 1
    if (-not $backupDirectory) { throw "未找到备份: $Backup" }

    $manifestPath = Join-Path $backupDirectory.FullName 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.scope -notin @('account', 'preset')) {
        throw "备份 '$Backup' 不是账号配置备份，不能通过 restore -Account 恢复。"
    }
    if ($manifest.label -ne $resolvedAccount.SteamId) {
        throw "备份 '$Backup' 不属于账号 $($resolvedAccount.SteamId)。"
    }

    $files = foreach ($record in $manifest.files) {
        Get-Item -LiteralPath (Join-Path $backupDirectory.FullName "files\$($record.name)")
    }
    Show-Changes -Changes @($files | ForEach-Object { [pscustomobject]@{ File = $_.Name; Status = '恢复' } })
    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, "恢复备份 $Backup")) {
        $existing = foreach ($file in $files) {
            $destination = Join-Path $resolvedAccount.CfgPath $file.Name
            if (Test-Path -LiteralPath $destination) { Get-Item -LiteralPath $destination }
        }
        if (@($existing).Count -gt 0) {
            $safetyBackup = New-Backup -Files @($existing) -Scope 'account' -Label $resolvedAccount.SteamId
            Write-Info "恢复前的当前配置已备份: $($safetyBackup.Directory)"
        }
        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $resolvedAccount.CfgPath $file.Name) -Force
        }
        Write-Info '配置恢复完成。'
        Write-OperationLog -Operation 'restore' -Details @{ account = $resolvedAccount.SteamId; backup = $Backup }
    }
}

function Show-BackupList {
    param([string]$AccountIdentifier)
    $accountId = if ($AccountIdentifier) { (Resolve-Account -Identifier $AccountIdentifier).SteamId } else { $null }
    $rows = foreach ($directory in Get-ChildItem -LiteralPath $BackupsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($accountId -and $manifest.label -ne $accountId) { continue }
        [pscustomobject]@{
            Backup = $directory.Name
            Scope = $manifest.scope
            Label = $manifest.label
            CreatedAt = $manifest.createdAt
            Files = @($manifest.files).Count
        }
    }
    if (@($rows).Count -eq 0) { Write-Host '没有可用备份。'; return }
    $rows | Format-Table -AutoSize
}

function Show-ScriptHelp {
    param([pscustomobject]$Route)

    $scriptName = Split-Path -Leaf $PSCommandPath
    $entries = @{
        '' = @"
CS2 配置管理工具

用法:
  $scriptName <命令> [子命令] [参数]

命令:
  account        列出 CS2 账号，或管理账号别名
  backup         创建或列出账号配置备份
  apply          将一个账号的配置复制到另一个账号
  apply-preset   对指定账号应用 cfg 预设中的部分设置
  restore        从备份恢复账号配置
  practice       导入、更新或部署本地练习服配置

帮助:
  $scriptName <命令> --help
  $scriptName help <命令> [子命令]
"@
        'account' = @"
账号管理

用法:
  $scriptName account list
  $scriptName account alias <list|set|rename|remove> [参数]

子命令:
  list            列出检测到的 CS2 账号和已设置的别名
  alias list      列出账号别名
  alias set       为账号设置别名
  alias rename    重命名账号别名
  alias remove    删除账号别名

短写法:
  account set、account rename、account remove 分别等同于 account alias 的对应子命令。
"@
        'account list' = @"
列出 CS2 账号

用法:
  $scriptName account list

输出 Steam userdata 下检测到的 CS2 配置目录，以及已关联的账号别名。
"@
        'account alias' = @"
账号别名管理

用法:
  $scriptName account alias list
  $scriptName account alias set -Account <别名或SteamId> -Name <新别名>
  $scriptName account alias rename -Name <旧别名> -NewName <新别名>
  $scriptName account alias remove -Name <别名>
"@
        'account alias list' = @"
列出账号别名

用法:
  $scriptName account alias list
"@
        'account alias set' = @"
设置账号别名

用法:
  $scriptName account alias set -Account <别名或SteamId> -Name <新别名>
  $scriptName account set -Account <别名或SteamId> -Name <新别名>

参数:
  -Account   已检测到的账号别名或 Steam 数字 ID
  -Name      要创建的别名，仅允许字母、数字、点、下划线和连字符
"@
        'account alias rename' = @"
重命名账号别名

用法:
  $scriptName account alias rename -Name <旧别名> -NewName <新别名>
"@
        'account alias remove' = @"
删除账号别名

用法:
  $scriptName account alias remove -Name <别名>
"@
        'backup' = @"
备份账号配置

用法:
  $scriptName backup -Account <别名或SteamId> [-IncludeCustomCfg] [-WhatIf]
  $scriptName backup list [-Account <别名或SteamId>]

说明:
  默认只备份通用 CS2 设置；-IncludeCustomCfg 额外包含自定义 cfg。
  trustedlaunch.cfg、Steam Cloud 状态和库存文件会被排除。
"@
        'backup list' = @"
列出配置备份

用法:
  $scriptName backup list [-Account <别名或SteamId>]
"@
        'apply' = @"
复制账号配置

用法:
  $scriptName apply -Source <来源别名或SteamId> -Target <目标别名或SteamId> [-IncludeCustomCfg] [-WhatIf]

目标账号会先自动备份；实际复制后会进行 SHA-256 校验。
"@
        'apply-preset' = @"
应用 cfg 预设

用法:
  $scriptName apply-preset -Account <别名或SteamId> -PresetPath <cfg路径> -Sections <分类> [-VideoPath <视频配置路径>] [-WhatIf]

分类:
  Viewmodel、Video、Hud、Radar、Audio。可用逗号分隔多个分类。
"@
        'restore' = @"
恢复账号配置

用法:
  $scriptName restore -Account <别名或SteamId> -Backup <备份目录名> [-WhatIf]

先使用 backup list 查看备份目录名。恢复前会自动备份当前目标配置。
"@
        'practice' = @"
本地练习服配置

用法:
  $scriptName practice template <import|update> -Name <名称> (-SourcePath <路径> | -Account <账号> -ConfigPath <文件名>)
  $scriptName practice apply -Name <名称> [-WhatIf]
  $scriptName practice list
"@
        'practice template' = @"
管理练习服模板

用法:
  $scriptName practice template import -Name <名称> (-SourcePath <路径> | -Account <账号> -ConfigPath <文件名>)
  $scriptName practice template update -Name <名称> (-SourcePath <路径> | -Account <账号> -ConfigPath <文件名>)

import 仅创建新模板；update 覆盖已有模板。模板存放在脚本相对 .tmp\\templates 目录。
"@
        'practice template import' = @"
导入练习服模板

用法:
  $scriptName practice template import -Name <名称> (-SourcePath <cfg路径> | -Account <别名或SteamId> -ConfigPath <文件名>)
"@
        'practice template update' = @"
更新练习服模板

用法:
  $scriptName practice template update -Name <名称> (-SourcePath <cfg路径> | -Account <别名或SteamId> -ConfigPath <文件名>)
"@
        'practice apply' = @"
部署练习服模板

用法:
  $scriptName practice apply -Name <名称> [-WhatIf]

模板会复制到 CS2 游戏共享 cfg 目录；进入本地服务器后执行 exec <名称>。
"@
        'practice list' = @"
列出练习服模板

用法:
  $scriptName practice list
"@
    }

    $entry = Get-CliHelpEntry -Route $Route -Entries $entries
    if ($entry.RequestedKey -and -not $entry.IsExactMatch) {
        Write-Host "未找到 '$($entry.RequestedKey)' 的独立帮助，显示 '$($entry.DisplayedKey)' 的可用信息。`n"
    }
    Write-Host $entry.Content
}

function Throw-CliRouteError {
    param([pscustomobject]$Route, [string]$Message)

    throw "$Message 运行 '$(Get-CliUsageCommand -Route $Route -ScriptPath $PSCommandPath)' 查看用法。"
}

try {
    $routeTokens = @($Command, $Action, $Subaction) + @($RemainingArguments)
    $route = Resolve-CliRoute -Tokens $routeTokens -Aliases $CliRouteAliases -HelpRequested:$Help
    if ($route.HelpRequested) {
        Show-ScriptHelp -Route $route
        return
    }
    if ($route.Path.Count -gt 3) {
        Throw-CliRouteError -Route $route -Message "命令路径 '$($route.Key)' 过长。"
    }

    $Command = $route.Path[0]
    $Action = if ($route.Path.Count -gt 1) { $route.Path[1] } else { $null }
    $Subaction = if ($route.Path.Count -gt 2) { $route.Path[2] } else { $null }

    $validCommands = @('account', 'backup', 'apply', 'apply-preset', 'restore', 'practice')
    if ($Command -notin $validCommands) {
        Throw-CliRouteError -Route $route -Message "不支持的命令 '$Command'。"
    }
    if ($route.Key -in @('account', 'account alias', 'practice', 'practice template')) {
        Show-ScriptHelp -Route $route
        return
    }

    switch ($Command) {
        'account' {
            switch ($Action) {
                'list' { Get-Cs2Accounts | Format-Table -AutoSize }
                'alias' {
                    switch ($Subaction) {
                        'set' {
                            if (-not $Account -or -not $Name) { Show-ScriptHelp -Route $route; return }
                            Test-ValidName -Value $Name
                            $resolvedAccount = Resolve-Account -Identifier $Account
                            Invoke-WithAccountsLock {
                                $store = Get-AccountsStore
                                if ($store.accounts.Contains($Name) -and [string]$store.accounts[$Name].steamId -ne $resolvedAccount.SteamId) {
                                    throw "别名 '$Name' 已绑定其他账号。"
                                }
                                $store.accounts[$Name] = [ordered]@{ steamId = $resolvedAccount.SteamId; note = '' }
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "别名已设置: $Name -> $($resolvedAccount.SteamId)"
                        }
                        'list' {
                            $store = Get-AccountsStore
                            $store.accounts.GetEnumerator() | ForEach-Object {
                                [pscustomobject]@{ Alias = $_.Key; SteamId = $_.Value.steamId; Note = $_.Value.note }
                            } | Format-Table -AutoSize
                        }
                        'rename' {
                            if (-not $Name -or -not $NewName) { Show-ScriptHelp -Route $route; return }
                            Test-ValidName -Value $NewName
                            Invoke-WithAccountsLock {
                                $store = Get-AccountsStore
                                if (-not $store.accounts.Contains($Name)) { throw "未找到别名: $Name" }
                                if ($store.accounts.Contains($NewName)) { throw "新别名已存在: $NewName" }
                                $store.accounts[$NewName] = $store.accounts[$Name]
                                $store.accounts.Remove($Name)
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "别名已重命名: $Name -> $NewName"
                        }
                        'remove' {
                            if (-not $Name) { Show-ScriptHelp -Route $route; return }
                            Invoke-WithAccountsLock {
                                $store = Get-AccountsStore
                                if (-not $store.accounts.Contains($Name)) { throw "未找到别名: $Name" }
                                $store.accounts.Remove($Name)
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "别名已移除: $Name"
                        }
                        default { Throw-CliRouteError -Route $route -Message "不支持的账号别名命令 '$Subaction'。" }
                    }
                }
                default { Throw-CliRouteError -Route $route -Message "不支持的账号命令 '$Action'。" }
            }
        }
        'backup' {
            if ($Action -eq 'list') { Show-BackupList -AccountIdentifier $Account }
            elseif ($Account) { Invoke-AccountBackup }
            else { Show-ScriptHelp -Route $route }
        }
        'apply' {
            if (-not $Source -or -not $Target) { Show-ScriptHelp -Route $route; return }
            Invoke-AccountApply
        }
        'apply-preset' {
            if (-not $Account -or -not $PresetPath) { Show-ScriptHelp -Route $route; return }
            Invoke-PresetApply
        }
        'restore' {
            if (-not $Account -or -not $Backup) { Show-ScriptHelp -Route $route; return }
            Invoke-AccountRestore
        }
        'practice' {
            switch ($Action) {
                'template' {
                    switch ($Subaction) {
                        'import' { Invoke-PracticeTemplateImport }
                        'update' { Invoke-PracticeTemplateImport -Update }
                        default { Throw-CliRouteError -Route $route -Message "不支持的练习模板命令 '$Subaction'。" }
                    }
                }
                'apply' { Invoke-PracticeApply }
                'list' {
                    if (-not (Test-Path -LiteralPath $TemplatesRoot)) { Write-Host '没有已导入的练习模板。'; break }
                    Get-ChildItem -LiteralPath $TemplatesRoot -Filter '*.cfg' -File | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
                }
                default { Throw-CliRouteError -Route $route -Message "不支持的练习服命令 '$Action'。" }
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
