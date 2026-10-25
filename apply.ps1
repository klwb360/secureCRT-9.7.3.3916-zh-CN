param([string]$InstallDir='D:\SecureCRT', [string]$BackupRoot='', [string]$ConfigFile='')
$ErrorActionPreference='Stop'
try {
    $deployment=& (Join-Path $PSScriptRoot 'deploy.ps1') -Mode Apply -InstallDir $InstallDir -BackupRoot $BackupRoot
    $code=$LASTEXITCODE
    $deployment | Write-Output
    if($code -ne 0){exit $code}
    $state=($deployment -join "`n") | ConvertFrom-Json
    if($ConfigFile -or [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') -eq 'D:\SecureCRT') {
        $cacheBackup=if($BackupRoot){Join-Path $BackupRoot 'menu-cache'}else{''}
        try {
            & (Join-Path $PSScriptRoot 'menu-cache.ps1') -Mode Apply -ConfigFile $ConfigFile -BackupRoot $cacheBackup
            if($LASTEXITCODE -ne 0){throw 'Menu-cache localization failed.'}
        } catch {
            $cacheError=$_.Exception.Message
            if($state.Status -eq 'Completed') {
                try {
                    & (Join-Path $PSScriptRoot 'deploy.ps1') -Mode Restore -InstallDir $InstallDir -BackupRoot $BackupRoot
                    if($LASTEXITCODE -ne 0){throw 'Program rollback returned a failure code.'}
                } catch {
                    throw ('Menu-cache localization failed; program rollback needs attention. '+$_.Exception.Message)
                }
                throw ($cacheError+' Program files were restored to their original state.')
            }
            throw ($cacheError+' Existing localized program files were retained.')
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
