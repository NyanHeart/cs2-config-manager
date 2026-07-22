<#
.SYNOPSIS
    Lightweight command-line routing and help framework.

.DESCRIPTION
    Dot-source this file from a co-located entry script.
    The framework handles command paths, help tokens, and help-entry fallback. Entry scripts provide commands and localized text.
#>

function Resolve-CliRoute {
    param(
        [string[]]$Tokens,
        [hashtable]$Aliases = @{},
        [switch]$HelpRequested
    )

    $helpTokens = @('help', '--help', '-help', '-h', '/?')
    $path = [System.Collections.Generic.List[string]]::new()
    $isHelpRequested = [bool]$HelpRequested
    foreach ($token in $Tokens) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $normalizedToken = $token.Trim().ToLowerInvariant()
        if ($normalizedToken -in $helpTokens) {
            $isHelpRequested = $true
            continue
        }
        $path.Add($normalizedToken)
    }

    $aliasKey = $path -join ' '
    if ($Aliases.ContainsKey($aliasKey)) {
        $path = [System.Collections.Generic.List[string]]::new([string[]]$Aliases[$aliasKey])
    }

    [pscustomobject]@{
        Path = @($path)
        Key = $path -join ' '
        HelpRequested = $isHelpRequested -or $path.Count -eq 0
    }
}

function Get-CliHelpEntry {
    param(
        [pscustomobject]$Route,
        [hashtable]$Entries
    )

    $requestedKey = $Route.Key
    $helpKey = $requestedKey
    while (-not $Entries.ContainsKey($helpKey) -and $helpKey) {
        $helpKey = ($helpKey -split ' ' | Select-Object -SkipLast 1) -join ' '
    }
    if (-not $Entries.ContainsKey($helpKey)) { $helpKey = '' }

    [pscustomobject]@{
        RequestedKey = $requestedKey
        DisplayedKey = $helpKey
        IsExactMatch = $requestedKey -eq $helpKey
        Content = [string]$Entries[$helpKey]
    }
}

function Get-CliUsageCommand {
    param(
        [pscustomobject]$Route,
        [string]$ScriptPath
    )

    $parts = @((Split-Path -Leaf $ScriptPath)) + @($Route.Path) + @('--help')
    $parts -join ' '
}
