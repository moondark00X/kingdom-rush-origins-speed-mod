[CmdletBinding()]
param([string]$DataDir = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'kingdom_rush_origins'))
. (Join-Path $PSScriptRoot 'scripts\Install.Common.ps1')
Assert-GameClosed
$paths = Get-ModPaths $DataDir
$source = Join-Path $PSScriptRoot 'kro_speed_mod.lua'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'kro_speed_mod.lua is missing from this package.' }
if (-not (Test-Path -LiteralPath $paths.Settings -PathType Leaf)) { throw 'settings.lua not found. Run the game once before installing.' }
$oldSettings = [IO.File]::ReadAllBytes($paths.Settings)
$newSettings = Add-Loader (Read-Utf8 $paths.Settings)
$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$oldModule = $null
$oldManifest = $null
if (Test-Path -LiteralPath $paths.Manifest) { $oldManifest = [IO.File]::ReadAllBytes($paths.Manifest) }
if (Test-Path -LiteralPath $paths.Module) {
    $existingHash = (Get-FileHash -LiteralPath $paths.Module -Algorithm SHA256).Hash
    if ($existingHash -ne $sourceHash) {
        if (-not $oldManifest) { throw 'An unowned kro_speed_mod.lua already exists. It was not overwritten.' }
        $previous = (Read-Utf8 $paths.Manifest) | ConvertFrom-Json
        if ($previous.module_sha256 -ne $existingHash) { throw 'Installed module was changed locally. It was not overwritten.' }
    }
    $oldModule = [IO.File]::ReadAllBytes($paths.Module)
}
$backup = Backup-Settings $paths 'install'
try {
    Write-AtomicBytes $paths.Module ([IO.File]::ReadAllBytes($source))
    $manifest = [ordered]@{
        module = $script:ModuleName
        version = '1.2.0'
        installed = $true
        module_sha256 = $sourceHash
        installed_at = (Get-Date).ToString('o')
        settings_backup = $backup
    } | ConvertTo-Json
    Write-AtomicText $paths.Manifest $manifest
    # Commit the loader last: it can never point at an absent module.
    Write-AtomicText $paths.Settings $newSettings
} catch {
    Write-AtomicBytes $paths.Settings $oldSettings
    if ($null -ne $oldModule) { Write-AtomicBytes $paths.Module $oldModule }
    elseif ([IO.File]::Exists($paths.Module)) { [IO.File]::Delete($paths.Module) }
    if ($null -ne $oldManifest) { Write-AtomicBytes $paths.Manifest $oldManifest }
    elseif ([IO.File]::Exists($paths.Manifest)) { [IO.File]::Delete($paths.Manifest) }
    throw
}
Write-Output ('Installed: ' + $paths.Module)
Write-Output 'Speeds: 1x / 1.5x / 2x / 3x / 5x. Q/E: cycle. R: reset to 1x. Voices unchanged.'
Write-Output ('Settings backup: ' + $backup)
