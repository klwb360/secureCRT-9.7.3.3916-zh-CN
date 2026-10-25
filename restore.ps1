param([string]$InstallDir='D:\SecureCRT', [string]$BackupRoot='', [string]$ConfigFile='')
$ErrorActionPreference='Stop'
try {
    & (Join-Path $PSScriptRoot 'deploy.ps1') -Mode Restore -InstallDir $InstallDir -BackupRoot $BackupRoot
    $code=$LASTEXITCODE
    if($code -ne 0){exit $code}
    if($ConfigFile -or [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') -eq 'D:\SecureCRT') {
        $cacheBackup=if($BackupRoot){Join-Path $BackupRoot 'menu-cache'}else{''}
        & (Join-Path $PSScriptRoot 'menu-cache.ps1') -Mode Restore -ConfigFile $ConfigFile -BackupRoot $cacheBackup
        if($LASTEXITCODE -ne 0){throw 'Program files were restored; menu-cache recovery failed. Close SecureCRT and retry restore.ps1.'}
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
