Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ModuleName = 'kro_speed_mod'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Get-ModPaths([string]$DataDir) {
    $root = [IO.Path]::GetFullPath($DataDir).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath (Join-Path $root 'Kingdom Rush Origins.exe')) {
        throw 'DataDir must be the user save directory, never the game installation directory.'
    }
    @{
        Root = $root
        Module = Join-Path $root 'kro_speed_mod.lua'
        Settings = Join-Path $root 'settings.lua'
        State = Join-Path $root '.kro_speed_mod'
        Manifest = Join-Path $root '.kro_speed_mod\manifest.json'
    }
}

function Assert-GameClosed {
    if (Get-Process -Name 'Kingdom Rush Origins' -ErrorAction SilentlyContinue) {
        throw 'Close Kingdom Rush Origins before installing or uninstalling the mod.'
    }
}

function Read-Utf8([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, $script:Utf8)
    return $text.TrimStart([char]0xFEFF)
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    $temporary = $Path + '.kro-tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Write-AtomicText([string]$Path, [string]$Text) {
    Write-AtomicBytes $Path ($script:Utf8.GetBytes($Text))
}

function Get-LoaderLines([string]$Text) {
    $pattern = @'
^\s*(?:\[\s*["']custom_script["']\s*\]|custom_script|[A-Za-z_]\w*(?:\.custom_script|\[\s*["']custom_script["']\s*\]))\s*=\s*(?<value>"[^"\\]*"|'[^'\\]*'|nil|false)\s*[;,]?\s*$
'@
    $index = 0
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $code = ($line -split '--', 2)[0]
        if ($code -cmatch 'custom_script') {
            $match = [regex]::Match($code, $pattern.Trim())
            if (-not $match.Success) { throw 'Unrecognized custom_script syntax. Settings were not changed.' }
            $value = $match.Groups['value'].Value
            if ($value -eq 'nil' -or $value -eq 'false') { $value = $null }
            else { $value = $value.Substring(1, $value.Length - 2) }
            [pscustomobject]@{ Index = $index; Value = $value }
        }
        $index++
    }
}

function Add-Loader([string]$Text) {
    $entries = @(Get-LoaderLines $Text)
    foreach ($entry in $entries) {
        if ($null -ne $entry.Value -and $entry.Value -ne $script:ModuleName) {
            throw ('Another custom_script is configured: ' + $entry.Value + '. It was not overwritten.')
        }
    }
    if (@($entries | Where-Object { $_.Value -eq $script:ModuleName }).Count) { return $Text }
    $return = [regex]::Match($Text, '(?m)^[ \t]*return[ \t]+(?<name>[A-Za-z_]\w*)[ \t]*;?[ \t]*(?=\r?$)')
    if (-not $return.Success -or $Text.Substring($return.Index + $return.Length).Trim().Length) {
        throw 'Unsupported settings.lua format. Expected a final return of the settings table; no files were changed.'
    }
    $name = $return.Groups['name'].Value
    if ($Text -notmatch ('(?m)^\s*local\s+' + [regex]::Escape($name) + '\s*=\s*\{')) {
        throw 'Settings table declaration was not found. No files were changed.'
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = '-- BEGIN KRO_SPEED_MOD' + $newline + $name + '["custom_script"] = "kro_speed_mod"' + $newline + '-- END KRO_SPEED_MOD' + $newline
    return $Text.Insert($return.Index, $block)
}

function Remove-Loader([string]$Text) {
    $entries = @(Get-LoaderLines $Text)
    $lines = [regex]::Split($Text, '\r?\n')
    $remove = @{}
    foreach ($entry in $entries) {
        if ($entry.Value -eq $script:ModuleName) { $remove[$entry.Index] = $true }
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $kept = for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $remove.ContainsKey($i) -and $lines[$i].Trim() -notin @('-- BEGIN KRO_SPEED_MOD', '-- END KRO_SPEED_MOD')) { $lines[$i] }
    }
    return $kept -join $newline
}

function Backup-Settings($Paths, [string]$Action) {
    $backupDir = Join-Path $Paths.State 'backups'
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $name = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Action + '-settings.lua'
    $backup = Join-Path $backupDir $name
    [IO.File]::Copy($Paths.Settings, $backup, $false)
    return $backup
}
