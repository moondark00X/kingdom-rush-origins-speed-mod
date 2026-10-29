[CmdletBinding()]
param([string]$DataDir = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'kingdom_rush_origins'))
. (Join-Path $PSScriptRoot 'scripts\Install.Common.ps1')
Assert-GameClosed
$paths = Get-ModPaths $DataDir
if (Test-Path -LiteralPath $paths.Settings -PathType Leaf) {
    $original = Read-Utf8 $paths.Settings
    $updated = Remove-Loader $original
    if ($updated -cne $original) {
        $backup = Backup-Settings $paths 'uninstall'
        Write-AtomicText $paths.Settings $updated
        Write-Output ('Settings backup: ' + $backup)
    }
}
# The loader has been removed before deleting any code.
if (Test-Path -LiteralPath $paths.Module -PathType Leaf) {
    if (Test-Path -LiteralPath $paths.Manifest -PathType Leaf) {
        $manifest = (Read-Utf8 $paths.Manifest) | ConvertFrom-Json
        $hash = (Get-FileHash -LiteralPath $paths.Module -Algorithm SHA256).Hash
        if ($manifest.module -eq $script:ModuleName -and $manifest.module_sha256 -eq $hash) {
            [IO.File]::Delete($paths.Module)
        } else { Write-Warning 'Module differs from the installed copy; preserved it. Its loading entry has been removed.' }
        $manifest.installed = $false
        Write-AtomicText $paths.Manifest ($manifest | ConvertTo-Json)
    } else { Write-Warning 'Unowned module was preserved. Its loading entry has been removed.' }
}
Write-Output 'Uninstalled. Save slots and current game preferences were preserved. Backups remain in .kro_speed_mod\backups.'
