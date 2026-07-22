<#
.SYNOPSIS
    CS2 Configuration Manager.

.DESCRIPTION
    Manages account-level CS2 settings and shared local practice configurations.
    All runtime data is stored in a .tmp directory relative to this script.
    Omitting the command, or using help, --help, -h, or /?, prints a command overview.

    Account settings live in the Steam userdata directory and can be addressed by alias or numeric Steam ID.
    Practice configurations live in the CS2 installation directory and are shared by all local accounts.
    All write operations refuse to run while CS2 is running and support -WhatIf previews.

.PARAMETER Command
    Optional top-level command: account, backup, apply, apply-preset, restore, or practice.

.PARAMETER Account
    An account alias or numeric Steam ID. Use account list to view available accounts.

.PARAMETER Source
    The source account alias or numeric Steam ID for apply.

.PARAMETER Target
    The target account alias or numeric Steam ID for apply.

.PARAMETER Sections
    Categories to merge with apply-preset: Viewmodel, Video, Hud, Radar, and Audio.
    A comma-separated list is supported, for example Viewmodel,Hud,Radar.

.PARAMETER Name
    Practice template name without the .cfg extension. Run it in-game with exec <name>.

.EXAMPLE
    Cs2Config.ps1 account list

    Lists Steam accounts with detected CS2 configurations on this computer.

.EXAMPLE
    Cs2Config.ps1 account alias set -Account 123456789 -Name primary

    Sets an account alias. You can then use primary instead of a numeric Steam ID.

.EXAMPLE
    Cs2Config.ps1 backup -Account primary -IncludeCustomCfg

    Backs up common account settings and custom .cfg files to the script-relative .tmp\backups directory.
    trustedlaunch.cfg, Steam Cloud state, and inventory files are excluded.

.EXAMPLE
    Cs2Config.ps1 apply -Source primary -Target secondary -WhatIf

    Previews account configuration changes from primary to secondary without writing files.

.EXAMPLE
    Cs2Config.ps1 apply -Source primary -Target secondary

    Copies common account settings. Target files are backed up first and verified with SHA-256 after copying.

.EXAMPLE
    Cs2Config.ps1 apply-preset -Account primary -PresetPath C:\Users\<your-user>\Downloads\autoexec.cfg -Sections Viewmodel,Hud,Radar,Audio -WhatIf

    Previews category-based settings extracted from an external cfg. Bindings, crosshair, sensitivity, and unselected categories remain unchanged.

.EXAMPLE
    Cs2Config.ps1 practice template import -Name practice -SourcePath C:\Users\<your-user>\Downloads\practice.cfg
    Cs2Config.ps1 practice apply -Name practice

    Imports a practice template and deploys it to the CS2 game directory. On a local server, run exec practice in the console.

.EXAMPLE
    Cs2Config.ps1 backup list -Account primary
    Cs2Config.ps1 restore -Account primary -Backup <backup-directory-name> -WhatIf

    Lists account backups and previews restoration of a selected backup.

.NOTES
    Supporting data is relative to the script: .tmp\Cs2Config.accounts.json, .tmp\templates, .tmp\backups, and .tmp\logs.
    For commands that write settings, use -WhatIf first to review the scope.
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

# pwsh -File passes a comma-separated category list as one argument; normalize it here.
if ($Sections) {
    $Sections = @($Sections | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Supporting files are relative to this script, so moving the scripts directory preserves portability.
$ScriptRoot = Split-Path -Parent $PSCommandPath
$CliFrameworkPath = Join-Path $ScriptRoot 'CliFramework.ps1'
if (-not (Test-Path -LiteralPath $CliFrameworkPath)) {
    throw "CLI framework file was not found: $CliFrameworkPath"
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

    throw 'Unable to locate the Steam installation directory. Confirm that Steam is installed.'
}

function Get-GameCfgDirectory {
    $steamRoot = Get-SteamRoot
    $gameCfg = Join-Path $steamRoot 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
    if (-not (Test-Path -LiteralPath $gameCfg)) {
        throw "CS2 game configuration directory was not found: $gameCfg"
    }
    return $gameCfg
}

function Test-Cs2Running {
    return $null -ne (Get-Process -Name 'cs2' -ErrorAction SilentlyContinue)
}

function Assert-Cs2Stopped {
    if (Test-Cs2Running) {
        throw 'cs2.exe is running. Exit CS2 completely before running a command that writes settings.'
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
        throw "Unable to parse the account alias file: $AccountsFile。$($_.Exception.Message)"
    }

    if (-not $store.Contains('accounts')) {
        $store.accounts = [ordered]@{}
    }
    return $store
}

function Save-AccountsStore {
    param([System.Collections.IDictionary]$Store)

    Ensure-StateDirectories
    # Use a unique temporary file to prevent multiple PowerShell processes from competing for one .new file.
    $temporaryPath = "$AccountsFile.$([guid]::NewGuid().ToString('N')).new"
    $Store | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $AccountsFile -Force
}

function Invoke-WithAccountsLock {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    # Alias changes are read-modify-write operations; lock the entire operation, not only the final write.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\Cs2Config.AccountAliases')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $hasLock) { throw 'Timed out waiting for the account alias file lock. Try again shortly.' }
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
        throw "Steam userdata directory was not found: $userdataPath"
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
        throw "No CS2 configuration was found for account '$Identifier'. Run 'account list' first to confirm the account."
    }
    return $account
}

function Test-ValidName {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "Name '$Value' is invalid. Use letters, numbers, - and _, and start with a letter or number."
    }
}

function Get-AccountConfigFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ResolvedAccount,
        [switch]$CustomCfg
    )

    $files = foreach ($file in Get-ChildItem -LiteralPath $ResolvedAccount.CfgPath -File) {
        # trustedlaunch is CS2 trusted-launch state, not portable custom configuration.
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
        Write-Host 'There are no changes to write.' -ForegroundColor Green
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
        throw "Source configuration was not found: $Path"
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
            throw "Unsupported configuration category '$section'. Supported values: $($validSections -join ', ')"
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
        # CS2 machine configuration can append slot suffixes such as $2 and $3 to some keys.
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
        throw "Video source file was not found: $SourceFile"
    }

    $sourceContent = Get-Content -LiteralPath $SourceFile -Raw
    $sourceSettings = [ordered]@{}
    foreach ($match in [regex]::Matches($sourceContent, '(?m)^\s*"(?<key>setting\.[^"]+|AutoConfig)"\s+"(?<value>[^"]*)"')) {
        $sourceSettings[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }

    if ($sourceSettings.Count -eq 0) {
        throw "No setting.* values were found in the video source file: $SourceFile"
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
    if ($files.Count -eq 0) { throw 'No CS2 configuration files were found to back up.' }

    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, 'create account configuration backup')) {
        $result = New-Backup -Files $files -Scope 'account' -Label $resolvedAccount.SteamId
        Write-Info "Backup created: $($result.Directory)"
        Write-OperationLog -Operation 'backup' -Details @{ account = $resolvedAccount.SteamId; backup = $result.Id }
    }
}

function Invoke-AccountApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $sourceAccount = Resolve-Account -Identifier $Source
    $targetAccount = Resolve-Account -Identifier $Target
    if ($sourceAccount.SteamId -eq $targetAccount.SteamId) { throw 'The source and target accounts are the same.' }

    $sourceFiles = Get-AccountConfigFiles -ResolvedAccount $sourceAccount -CustomCfg:$IncludeCustomCfg
    $changes = foreach ($sourceFile in $sourceFiles) {
        $targetPath = Join-Path $targetAccount.CfgPath $sourceFile.Name
        $status = if (-not (Test-Path -LiteralPath $targetPath)) { 'Added' }
        elseif ((Get-FileSha256 -Path $sourceFile.FullName) -eq (Get-FileSha256 -Path $targetPath)) { 'Unchanged' }
        else { 'Updated' }
        [pscustomobject]@{ File = $sourceFile.Name; Status = $status }
    }

    Write-Info "Source: $($sourceAccount.Alias) ($($sourceAccount.SteamId))"
    Write-Info "Target: $($targetAccount.Alias) ($($targetAccount.SteamId))"
    Show-Changes -Changes $changes
    $pending = @($changes | Where-Object Status -ne 'Unchanged')
    if ($pending.Count -eq 0) { return }

    if ($PSCmdlet.ShouldProcess($targetAccount.CfgPath, "copy $($pending.Count) common configuration files")) {
        $existingTargetFiles = foreach ($change in $pending) {
            $path = Join-Path $targetAccount.CfgPath $change.File
            if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path }
        }
        if (@($existingTargetFiles).Count -gt 0) {
            $backupResult = New-Backup -Files @($existingTargetFiles) -Scope 'account' -Label $targetAccount.SteamId
            Write-Info "Target configuration backed up: $($backupResult.Directory)"
        }

        foreach ($change in $pending) {
            $sourceFile = $sourceFiles | Where-Object Name -eq $change.File | Select-Object -First 1
            $targetPath = Join-Path $targetAccount.CfgPath $change.File
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -Force
            if ((Get-FileSha256 -Path $sourceFile.FullName) -ne (Get-FileSha256 -Path $targetPath)) {
                throw "Verification failed: $($change.File)"
            }
        }
        Write-Info 'Account settings copied and SHA-256 verification completed.'
        Write-OperationLog -Operation 'apply' -Details @{ source = $sourceAccount.SteamId; target = $targetAccount.SteamId; files = @($pending.File) }
    }
}

function Invoke-PresetApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $resolvedAccount = Resolve-Account -Identifier $Account
    if (-not $Sections -or $Sections.Count -eq 0) {
        throw 'apply-preset requires at least one category through -Sections.'
    }

    $commands = Get-CommandsFromCfg -Path $PresetPath
    $selectedCommands = Get-SectionCommands -Commands $commands -SelectedSections $Sections
    $updates = [System.Collections.Generic.List[object]]::new()

    $userFile = Get-ChildItem -LiteralPath $resolvedAccount.CfgPath -Filter 'cs2_user_convars_*.vcfg' -File | Where-Object Name -notlike '*_lastclouded' | Select-Object -First 1
    $machineFile = Get-Item -LiteralPath (Join-Path $resolvedAccount.CfgPath 'cs2_machine_convars.vcfg')
    if (-not $userFile) { throw 'cs2_user_convars configuration file was not found.' }

    $userCommands = [ordered]@{}
    $machineCommands = [ordered]@{}
    foreach ($entry in $selectedCommands.GetEnumerator()) {
        # CS2 can store a category in user or machine VCFG; route it by the key location.
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
        if ('Video' -notin $Sections) { Write-WarningMessage '-VideoPath was provided, but Video was not selected; the video file will be ignored.' }
        else {
            $videoFile = Get-Item -LiteralPath (Join-Path $resolvedAccount.CfgPath 'cs2_video.txt')
            $updates.Add((Get-VideoConfigUpdate -TargetFile $videoFile -SourceFile $VideoPath))
        }
    }

    $changes = foreach ($update in $updates) {
        foreach ($key in $update.ChangedKeys) {
            [pscustomobject]@{ File = $update.File.Name; Setting = $key; Status = 'Updated' }
        }
        foreach ($key in $update.MissingKeys) {
            [pscustomobject]@{ File = $update.File.Name; Setting = $key; Status = 'Missing from target; skipped' }
        }
    }
    Show-Changes -Changes @($changes)
    $changedUpdates = @($updates | Where-Object { $_.ChangedKeys.Count -gt 0 })
    if ($changedUpdates.Count -eq 0) { return }

    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, 'merge external configuration by category')) {
        $backupResult = New-Backup -Files @($changedUpdates.File) -Scope 'preset' -Label $resolvedAccount.SteamId
        Write-Info "Target configuration backed up: $($backupResult.Directory)"
        foreach ($update in $changedUpdates) {
            Save-TextFile -Path $update.File.FullName -Content $update.Content
        }
        Write-Info 'Preset applied.'
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
            throw "Source file was not found in the account configuration: $accountSource"
        }
        return $accountSource
    }
    throw 'Use -SourcePath, or provide both -Account and -ConfigPath to choose a template source.'
}

function Invoke-PracticeTemplateImport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Update)
    Assert-Cs2Stopped
    if (-not $Name) { throw 'practice template import/update requires -Name.' }
    $templatePath = Get-TemplatePath -TemplateName $Name
    $sourceCfgPath = Get-PracticeSourcePath
    if ((Test-Path -LiteralPath $templatePath) -and -not $Update -and -not $Force) {
        throw "Template already exists: $templatePath. Use 'practice template update' to update it, or use -Force to overwrite it."
    }

    if ($PSCmdlet.ShouldProcess($templatePath, "import template $Name")) {
        Ensure-StateDirectories
        if (Test-Path -LiteralPath $templatePath) {
            $backupResult = New-Backup -Files @((Get-Item -LiteralPath $templatePath)) -Scope 'template' -Label $Name
            Write-Info "Existing template backed up: $($backupResult.Directory)"
        }
        Copy-Item -LiteralPath $sourceCfgPath -Destination $templatePath -Force
        Write-Info "Template saved: $templatePath"
        Write-OperationLog -Operation 'practice-template-import' -Details @{ name = $Name; source = $sourceCfgPath }
    }
}

function Invoke-PracticeApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    if (-not $Name) { throw 'practice apply requires -Name.' }
    $templatePath = Get-TemplatePath -TemplateName $Name
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Template was not found: $templatePath. First use 'practice template import' to import it."
    }

    $targetPath = Join-Path (Get-GameCfgDirectory) "$Name.cfg"
    $status = if (-not (Test-Path -LiteralPath $targetPath)) { 'Added' }
    elseif ((Get-FileSha256 -Path $templatePath) -eq (Get-FileSha256 -Path $targetPath)) { 'Unchanged' }
    else { 'Updated' }
    Show-Changes -Changes @([pscustomobject]@{ File = "$Name.cfg"; Status = $status; Target = $targetPath })
    if ($status -eq 'Unchanged') { return }

    if ($PSCmdlet.ShouldProcess($targetPath, "deploy practice template $Name")) {
        if (Test-Path -LiteralPath $targetPath) {
            $backupResult = New-Backup -Files @((Get-Item -LiteralPath $targetPath)) -Scope 'practice' -Label $Name
            Write-Info "Existing game configuration backed up: $($backupResult.Directory)"
        }
        Copy-Item -LiteralPath $templatePath -Destination $targetPath -Force
        if ((Get-FileSha256 -Path $templatePath) -ne (Get-FileSha256 -Path $targetPath)) {
            throw "Practice configuration verification failed: $targetPath"
        }
        Write-Info "Practice configuration deployed. Run in-game: exec $Name"
        Write-OperationLog -Operation 'practice-apply' -Details @{ name = $Name; target = $targetPath }
    }
}

function Invoke-AccountRestore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Cs2Stopped
    $resolvedAccount = Resolve-Account -Identifier $Account
    if (-not $Backup) { throw 'restore requires -Backup. Use backup list to view available backups.' }
    $backupDirectory = Get-ChildItem -LiteralPath $BackupsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -eq $Backup | Select-Object -First 1
    if (-not $backupDirectory) { throw "Backup was not found: $Backup" }

    $manifestPath = Join-Path $backupDirectory.FullName 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.scope -notin @('account', 'preset')) {
        throw "Backup '$Backup' is not an account configuration backup and cannot be restored with restore -Account."
    }
    if ($manifest.label -ne $resolvedAccount.SteamId) {
        throw "Backup '$Backup' does not belong to account $($resolvedAccount.SteamId)。"
    }

    $files = foreach ($record in $manifest.files) {
        Get-Item -LiteralPath (Join-Path $backupDirectory.FullName "files\$($record.name)")
    }
    Show-Changes -Changes @($files | ForEach-Object { [pscustomobject]@{ File = $_.Name; Status = 'Restore' } })
    if ($PSCmdlet.ShouldProcess($resolvedAccount.CfgPath, "RestoreBackup $Backup")) {
        $existing = foreach ($file in $files) {
            $destination = Join-Path $resolvedAccount.CfgPath $file.Name
            if (Test-Path -LiteralPath $destination) { Get-Item -LiteralPath $destination }
        }
        if (@($existing).Count -gt 0) {
            $safetyBackup = New-Backup -Files @($existing) -Scope 'account' -Label $resolvedAccount.SteamId
            Write-Info "Current settings backed up before restore: $($safetyBackup.Directory)"
        }
        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $resolvedAccount.CfgPath $file.Name) -Force
        }
        Write-Info 'Configuration restore completed.'
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
    if (@($rows).Count -eq 0) { Write-Host 'No backups are available.'; return }
    $rows | Format-Table -AutoSize
}

function Show-ScriptHelp {
    param([pscustomobject]$Route)

    $scriptName = Split-Path -Leaf $PSCommandPath
    $entries = @{
        '' = @"
CS2 Config Manager

Usage:
  $scriptName <command> [subcommand] [parameters]

Commands:
  account        List CS2 accounts or manage account aliases
  backup         Create or list account configuration backups
  apply          Copy configuration from one account to another
  apply-preset   Apply selected settings from a cfg preset to an account
  restore        Restore account configuration from a backup
  practice       Import, update, or deploy local practice configuration

Help:
  $scriptName <command> --help
  $scriptName help <command> [subcommand]
"@
        'account' = @"
Account management

Usage:
  $scriptName account list
  $scriptName account alias <list|set|rename|remove> [parameters]

Subcommands:
  list            List detected CS2 accounts and their assigned aliases
  alias list      List account aliases
  alias set       Assign an alias to an account
  alias rename    Rename an account alias
  alias remove    Remove an account alias

Short forms:
  account set, account rename, and account remove map to their account alias counterparts.
"@
        'account list' = @"
List CS2 accounts

Usage:
  $scriptName account list

Lists detected CS2 configuration directories in Steam userdata, including assigned account aliases.
"@
        'account alias' = @"
Account alias management

Usage:
  $scriptName account alias list
  $scriptName account alias set -Account <alias-or-SteamId> -Name <new-alias>
  $scriptName account alias rename -Name <old-alias> -NewName <new-alias>
  $scriptName account alias remove -Name <alias>
"@
        'account alias list' = @"
List account aliases

Usage:
  $scriptName account alias list
"@
        'account alias set' = @"
Set an account alias

Usage:
  $scriptName account alias set -Account <alias-or-SteamId> -Name <new-alias>
  $scriptName account set -Account <alias-or-SteamId> -Name <new-alias>

Parameters:
  -Account   A detected account alias or numeric Steam ID
  -Name      Alias to create; only letters, numbers, periods, underscores, and hyphens are allowed
"@
        'account alias rename' = @"
Rename an account alias

Usage:
  $scriptName account alias rename -Name <old-alias> -NewName <new-alias>
"@
        'account alias remove' = @"
Remove an account alias

Usage:
  $scriptName account alias remove -Name <alias>
"@
        'backup' = @"
Back up account configuration

Usage:
  $scriptName backup -Account <alias-or-SteamId> [-IncludeCustomCfg] [-WhatIf]
  $scriptName backup list [-Account <alias-or-SteamId>]

By default, only common CS2 settings are backed up. -IncludeCustomCfg also includes custom cfg files.
trustedlaunch.cfg, Steam Cloud state, and inventory files are excluded.
"@
        'backup list' = @"
List configuration backups

Usage:
  $scriptName backup list [-Account <alias-or-SteamId>]
"@
        'apply' = @"
Copy account configuration

Usage:
  $scriptName apply -Source <source-alias-or-SteamId> -Target <target-alias-or-SteamId> [-IncludeCustomCfg] [-WhatIf]

The target account is backed up first. Copied files are then verified with SHA-256.
"@
        'apply-preset' = @"
Apply a cfg preset

Usage:
  $scriptName apply-preset -Account <alias-or-SteamId> -PresetPath <cfg-path> -Sections <categories> [-VideoPath <video-config-path>] [-WhatIf]

Categories:
  Viewmodel, Video, Hud, Radar, Audio. Separate multiple categories with commas.
"@
        'restore' = @"
Restore account configuration

Usage:
  $scriptName restore -Account <alias-or-SteamId> -Backup <backup-directory-name> [-WhatIf]

Use backup list to view backup directory names. The current target configuration is backed up before restoration.
"@
        'practice' = @"
Local practice configuration

Usage:
  $scriptName practice template <import|update> -Name <name> (-SourcePath <path> | -Account <account> -ConfigPath <file-name>)
  $scriptName practice apply -Name <name> [-WhatIf]
  $scriptName practice list
"@
        'practice template' = @"
Manage practice templates

Usage:
  $scriptName practice template import -Name <name> (-SourcePath <path> | -Account <account> -ConfigPath <file-name>)
  $scriptName practice template update -Name <name> (-SourcePath <path> | -Account <account> -ConfigPath <file-name>)

import creates a new template only. update overwrites an existing template. Templates are stored in the script-relative .tmp\\templates directory.
"@
        'practice template import' = @"
Import a practice template

Usage:
  $scriptName practice template import -Name <name> (-SourcePath <cfg-path> | -Account <alias-or-SteamId> -ConfigPath <file-name>)
"@
        'practice template update' = @"
Update a practice template

Usage:
  $scriptName practice template update -Name <name> (-SourcePath <cfg-path> | -Account <alias-or-SteamId> -ConfigPath <file-name>)
"@
        'practice apply' = @"
Deploy a practice template

Usage:
  $scriptName practice apply -Name <name> [-WhatIf]

The template is copied to the shared CS2 game cfg directory. On a local server, run exec <name>.
"@
        'practice list' = @"
List practice templates

Usage:
  $scriptName practice list
"@
    }

    $entry = Get-CliHelpEntry -Route $Route -Entries $entries
    if ($entry.RequestedKey -and -not $entry.IsExactMatch) {
        Write-Host "No dedicated help entry exists for '$($entry.RequestedKey)'; showing '$($entry.DisplayedKey)'.`n"
    }
    Write-Host $entry.Content
}

function Throw-CliRouteError {
    param([pscustomobject]$Route, [string]$Message)

    throw "$Message Run '$(Get-CliUsageCommand -Route $Route -ScriptPath $PSCommandPath)' for usage."
}

try {
    $routeTokens = @($Command, $Action, $Subaction) + @($RemainingArguments)
    $route = Resolve-CliRoute -Tokens $routeTokens -Aliases $CliRouteAliases -HelpRequested:$Help
    if ($route.HelpRequested) {
        Show-ScriptHelp -Route $route
        return
    }
    if ($route.Path.Count -gt 3) {
        Throw-CliRouteError -Route $route -Message "Command path '$($route.Key)' is too long."
    }

    $Command = $route.Path[0]
    $Action = if ($route.Path.Count -gt 1) { $route.Path[1] } else { $null }
    $Subaction = if ($route.Path.Count -gt 2) { $route.Path[2] } else { $null }

    $validCommands = @('account', 'backup', 'apply', 'apply-preset', 'restore', 'practice')
    if ($Command -notin $validCommands) {
        Throw-CliRouteError -Route $route -Message "Unsupported command '$Command'."
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
                                    throw "Alias '$Name' is already assigned to another account."
                                }
                                $store.accounts[$Name] = [ordered]@{ steamId = $resolvedAccount.SteamId; note = '' }
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "Alias set: $Name -> $($resolvedAccount.SteamId)"
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
                                if (-not $store.accounts.Contains($Name)) { throw "Alias was not found: $Name" }
                                if ($store.accounts.Contains($NewName)) { throw "The new alias already exists: $NewName" }
                                $store.accounts[$NewName] = $store.accounts[$Name]
                                $store.accounts.Remove($Name)
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "Alias renamed: $Name -> $NewName"
                        }
                        'remove' {
                            if (-not $Name) { Show-ScriptHelp -Route $route; return }
                            Invoke-WithAccountsLock {
                                $store = Get-AccountsStore
                                if (-not $store.accounts.Contains($Name)) { throw "Alias was not found: $Name" }
                                $store.accounts.Remove($Name)
                                Save-AccountsStore -Store $store
                            }
                            Write-Info "Alias removed: $Name"
                        }
                        default { Throw-CliRouteError -Route $route -Message "Unsupported account alias command '$Subaction'." }
                    }
                }
                default { Throw-CliRouteError -Route $route -Message "Unsupported account command '$Action'." }
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
                        default { Throw-CliRouteError -Route $route -Message "Unsupported practice template command '$Subaction'." }
                    }
                }
                'apply' { Invoke-PracticeApply }
                'list' {
                    if (-not (Test-Path -LiteralPath $TemplatesRoot)) { Write-Host 'No practice templates have been imported.'; break }
                    Get-ChildItem -LiteralPath $TemplatesRoot -Filter '*.cfg' -File | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
                }
                default { Throw-CliRouteError -Route $route -Message "Unsupported practice command '$Action'." }
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
