[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Apply','Restore')][string]$Mode,
    [string]$InstallDir = 'D:\SecureCRT',
    [string]$BackupRoot = ''
)
$ErrorActionPreference = 'Stop'

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Set-FileAtomic([string]$Source,[string]$Destination,[string]$BeforeHash,[string]$AfterHash) {
    # Commit only a fully written, verified temporary file in the target directory.
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.securecrt-zh-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $previous=$temporary+'.before'
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        if ((Get-Hash $temporary) -ne $AfterHash) { throw 'Atomic staging hash mismatch.' }
        if ((Get-Hash $Destination) -ne $BeforeHash) { throw 'Destination changed before atomic replacement.' }
        if (Get-Process -Name SecureCRT -ErrorAction SilentlyContinue) { throw 'SecureCRT started during deployment. Close it and retry.' }
        [IO.File]::Replace($temporary,$Destination,$previous)
        if ((Get-Hash $Destination) -ne $AfterHash) { throw 'Atomic replacement hash mismatch.' }
    } finally {
        foreach($path in @($temporary,$previous)) {
            if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}
        }
    }
}

function Write-StateAtomic($Value,[string]$Destination) {
    $temporary=$Destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $previous=$temporary+'.before'
    try {
        $Value | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
        if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($temporary,$Destination,$previous)}
        else{[IO.File]::Move($temporary,$Destination)}
    } finally {
        foreach($path in @($temporary,$previous)) {
            if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}
        }
    }
}

function Get-PackageFile([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw 'Absolute package paths are forbidden.' }
    $resolved=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Relative))
    $prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'A package path escapes the package directory.' }
    return $resolved
}

function Expand-Delta($Entry, [string]$Source, [string]$Destination) {
    $deltaPath=Get-PackageFile $Entry.patch
    $payloadPath=Get-PackageFile $Entry.payload
    if ((Get-Hash $deltaPath) -ne $Entry.patch_sha256 -or (Get-Hash $payloadPath) -ne $Entry.payload_sha256) {
        throw ('Damaged patch payload: ' + $Entry.file)
    }
    $delta=Get-Content -LiteralPath $deltaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $compressed=[IO.File]::OpenRead($payloadPath)
    $gzip=New-Object IO.Compression.GZipStream($compressed,[IO.Compression.CompressionMode]::Decompress)
    $literalStream=New-Object IO.MemoryStream
    try { $gzip.CopyTo($literalStream); $literal=$literalStream.ToArray() }
    finally { $gzip.Dispose(); $compressed.Dispose(); $literalStream.Dispose() }
    $original=[IO.File]::ReadAllBytes($Source)
    $output=New-Object IO.MemoryStream
    try {
        foreach($operation in $delta.operations) {
            $offset=[long]$operation.offset
            $length=[long]$operation.length
            if ($offset -lt 0 -or $length -lt 0 -or $length -gt [int]::MaxValue) { throw 'Invalid delta span.' }
            if ($operation.kind -eq 'copy') { $buffer=$original }
            elseif ($operation.kind -eq 'literal') { $buffer=$literal }
            else { throw 'Unknown delta operation.' }
            if ($offset+$length -gt $buffer.LongLength) { throw 'Delta span exceeds its input.' }
            $output.Write($buffer,[int]$offset,[int]$length)
        }
        if ($output.Length -ne [long]$Entry.patched_size) { throw 'Reconstructed file size mismatch.' }
        [IO.File]::WriteAllBytes($Destination,$output.ToArray())
    } finally { $output.Dispose() }
    if ((Get-Hash $Destination) -ne $Entry.patched_sha256) { throw ('Reconstructed hash mismatch: ' + $Entry.file) }
}

try {
    $InstallDir=[IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    if (!(Test-Path -LiteralPath $InstallDir -PathType Container)) { throw 'Installation directory does not exist.' }
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $InstallDir 'SecureCRT.exe')).ProductVersion -ne '9.7.3.3916') {
        throw 'Only SecureCRT x64 9.7.3.3916 is supported.'
    }
    if (Get-Process -Name SecureCRT -ErrorAction SilentlyContinue) { throw 'Close SecureCRT before applying or restoring this patch.' }
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.version -ne '9.7.3.3916' -or $manifest.architecture -ne 'x64' -or @($manifest.files).Count -eq 0) {
        throw 'Unsupported or empty patch manifest.'
    }
    $files=@($manifest.files)
    $originalCount=0; $patchedCount=0
    foreach($entry in $files) {
        if ([IO.Path]::GetFileName($entry.file) -ne $entry.file -or $entry.file -match '[:/\\]') { throw 'Invalid program filename.' }
        $filePath=Join-Path $InstallDir $entry.file
        $hash=Get-Hash $filePath
        if ($hash -eq $entry.original_sha256) { $originalCount++ }
        elseif ($hash -eq $entry.patched_sha256) { $patchedCount++ }
        else { throw ('Unexpected file version or modification; no files were changed: ' + $entry.file) }
    }
    if (($Mode -eq 'Apply' -and $patchedCount -eq $files.Count) -or ($Mode -eq 'Restore' -and $originalCount -eq $files.Count)) {
        [pscustomobject]@{Mode=$Mode;Status='AlreadyInRequestedState';Files=$files.Count;InstallDir=$InstallDir} | ConvertTo-Json
        exit 0
    }
    if ($Mode -eq 'Apply' -and $originalCount -ne $files.Count) { throw 'Mixed file states detected. Restore the original files first.' }
    if (!$BackupRoot) { $BackupRoot=Join-Path $env:LOCALAPPDATA 'SecureCRT-zh-CN\Backups' }
    $BackupRoot=[IO.Path]::GetFullPath($BackupRoot)
    $digest=[Security.Cryptography.SHA256]::Create()
    try {$identity=([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstallDir.ToUpperInvariant())))).Replace('-','').Substring(0,20)}
    finally {$digest.Dispose()}
    $identityRoot=Join-Path $BackupRoot $identity
    $statePath=Join-Path $identityRoot 'active-backup.json'
    if ($Mode -eq 'Restore') {
        $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.InstallDir -ne $InstallDir) { throw 'Backup belongs to another installation.' }
        $sourceRoot=[IO.Path]::GetFullPath($state.OriginalDirectory)
        $backupPrefix=$identityRoot.TrimEnd('\')+'\'
        if (!$sourceRoot.StartsWith($backupPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup path is outside the expected backup directory.' }
        foreach($entry in $files) {
            if ((Get-Hash (Join-Path $sourceRoot $entry.file)) -ne $entry.original_sha256) { throw ('Original backup is damaged: '+$entry.file) }
        }
    }
    $runRoot=Join-Path $identityRoot ((Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $stageRoot=Join-Path $runRoot 'staged'
    $safetyRoot=Join-Path $runRoot 'before'
    New-Item -ItemType Directory -Path $stageRoot,$safetyRoot -Force | Out-Null
    foreach($entry in $files) {
        $current=Join-Path $InstallDir $entry.file
        Copy-Item -LiteralPath $current -Destination (Join-Path $safetyRoot $entry.file)
        $staged=Join-Path $stageRoot $entry.file
        if ($Mode -eq 'Apply') { Expand-Delta $entry $current $staged }
        else { Copy-Item -LiteralPath (Join-Path $sourceRoot $entry.file) -Destination $staged }
    }
    if ($Mode -eq 'Apply') {
        Write-StateAtomic ([ordered]@{InstallDir=$InstallDir;OriginalDirectory=$safetyRoot;Status='Prepared';Version=$manifest.version}) $statePath
    }
    $touched=New-Object Collections.Generic.List[string]
    try {
        foreach($entry in $files) {
            $destination=Join-Path $InstallDir $entry.file
            $before=Get-Hash (Join-Path $safetyRoot $entry.file)
            if ((Get-Hash $destination) -ne $before) { throw ('File changed during preparation: '+$entry.file) }
            $touched.Add($entry.file)
            $expected=if($Mode -eq 'Apply'){$entry.patched_sha256}else{$entry.original_sha256}
            Set-FileAtomic (Join-Path $stageRoot $entry.file) $destination $before $expected
        }
    } catch {
        $originalError=$_
        $restoreErrors=New-Object Collections.Generic.List[string]
        foreach($name in $touched) {
            try {
                $safe=Join-Path $safetyRoot $name
                $destination=Join-Path $InstallDir $name
                $safeHash=Get-Hash $safe
                $currentHash=Get-Hash $destination
                if($currentHash -eq $safeHash){continue}
                $entry=$files | Where-Object file -eq $name
                $expected=if($Mode -eq 'Apply'){$entry.patched_sha256}else{$entry.original_sha256}
                if($currentHash -ne $expected){throw 'File changed outside deployment; refusing to overwrite an unknown state.'}
                Set-FileAtomic $safe $destination $currentHash $safeHash
            } catch { $restoreErrors.Add($name+': '+$_.Exception.Message) }
        }
        if ($restoreErrors.Count) { throw ('Deployment failed and rollback needs attention. Backup: '+$safetyRoot+'; '+($restoreErrors -join '; ')) }
        throw ('Deployment failed; all touched files were restored. '+$originalError.Exception.Message)
    }
    if ($Mode -eq 'Apply') {
        Write-StateAtomic ([ordered]@{InstallDir=$InstallDir;OriginalDirectory=$safetyRoot;Status='Applied';Version=$manifest.version}) $statePath
    }
    [pscustomobject]@{Mode=$Mode;Status='Completed';Files=$files.Count;InstallDir=$InstallDir;SafetyCopy=$safetyRoot} | ConvertTo-Json
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
