param([ValidateSet('Apply','Restore')][string]$Mode='Apply', [string]$ConfigFile='', [string]$BackupRoot='')
$ErrorActionPreference='Stop'
try {
    if (Get-Process -Name SecureCRT -ErrorAction SilentlyContinue) {throw 'Close SecureCRT before changing the menu cache.'}
    if (!$ConfigFile) {
        $config=(Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\VanDyke\SecureCRT').'Config Path'
        if (!$config) { throw 'SecureCRT configuration path is unavailable.' }
        $ConfigFile=Join-Path $config 'SCRTMenuToolbarV3.ini'
    }
    $ConfigFile=[IO.Path]::GetFullPath($ConfigFile)
    if (!(Test-Path -LiteralPath $ConfigFile)) {
        @{Status='NoMenuCache';Mode=$Mode} | ConvertTo-Json -Compress
        exit 0
    }
    if (!$BackupRoot) {$BackupRoot=Join-Path $env:LOCALAPPDATA 'SecureCRT-zh-CN\MenuCacheBackups'}
    $BackupRoot=[IO.Path]::GetFullPath($BackupRoot)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$identity=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfigFile.ToUpperInvariant())))).Replace('-','').Substring(0,20)}
    finally {$sha.Dispose()}
    $historyRoot=Join-Path $BackupRoot $identity
    $statePath=Join-Path $historyRoot 'state.json'
    $before=[IO.File]::ReadAllBytes($ConfigFile)
    $beforeHash=(Get-FileHash -LiteralPath $ConfigFile -Algorithm SHA256).Hash
    $state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
    if($state -and $state.ConfigFile -ne $ConfigFile){throw 'Menu-cache backup belongs to another configuration.'}
    $exactRestore=$false
    if($Mode -eq 'Restore' -and $state -and $state.ExactRestoreAllowed -ne $false -and $beforeHash -eq $state.PatchedHash) {
        $backup=[IO.Path]::GetFullPath($state.OriginalFile)
        if (!$backup.StartsWith($historyRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Invalid menu-cache backup path.'}
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $state.OriginalHash) {throw 'Menu-cache backup is damaged.'}
        $updated=[IO.File]::ReadAllBytes($backup)
        $exactRestore=$true
        $count=-1; $skipped=@()
    } else {
        if (-not ('CrtMenuCachePatch' -as [type])) {
            Add-Type @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
public static class CrtMenuCachePatch {
    static byte[] CString(string s) {
        byte[] text=Encoding.Unicode.GetBytes(s);
        int n=text.Length/2;
        using(MemoryStream m=new MemoryStream()) {
            m.Write(new byte[]{255,254,255},0,3);
            if(n<255) m.WriteByte((byte)n);
            else {m.WriteByte(255); byte[] size=BitConverter.GetBytes((ushort)n);m.Write(size,0,2);}
            m.Write(text,0,text.Length);return m.ToArray();
        }
    }
    static byte[] RewriteBytes(byte[] b,Dictionary<string,string> pairs,ref int changes) {
        using(MemoryStream m=new MemoryStream()) {
            for(int i=0;i<b.Length;) {
                bool replaced=false;
                if(i+4<=b.Length && b[i]==255 && b[i+1]==254 && b[i+2]==255) {
                    int start=i+3; long n=b[start++];
                    if(n==255 && start+2<=b.Length) {n=BitConverter.ToUInt16(b,start);start+=2;}
                    if(n==65535 && start+4<=b.Length) {n=BitConverter.ToUInt32(b,start);start+=4;}
                    if(n>0 && n<32768 && start+2*n<=b.Length) {
                        string text=Encoding.Unicode.GetString(b,start,(int)n*2),target;
                        if(pairs.TryGetValue(text,out target) && target!=text) {
                            byte[] value=CString(target);m.Write(value,0,value.Length);
                            i=start+(int)n*2;changes++;replaced=true;
                        }
                    }
                }
                if(!replaced)m.WriteByte(b[i++]);
            }
            return m.ToArray();
        }
    }
    public static string Rewrite(string input,Dictionary<string,string> pairs,bool restore,out int changes,out string[] skipped) {
        int count=0;List<string> ignored=new List<string>();
        Regex block=new Regex("(?m)^B:\"([^\"]+)\"=([0-9a-fA-F]{8})\\r?\\n((?:[ \\t]+[0-9a-fA-F ]+\\r?\\n)+)");
        string result=block.Replace(input,delegate(Match match) {
            string name=match.Groups[1].Value;
            if(!Regex.IsMatch(name,@"^BCGToolBar-32911\d*-(Buttons|OriginalItems|OrigResetItems)$"))return match.Value;
            string hex=Regex.Replace(match.Groups[3].Value,@"\s","");
            byte[] bytes=new byte[hex.Length/2];
            for(int i=0;i<bytes.Length;i++)bytes[i]=Convert.ToByte(hex.Substring(i*2,2),16);
            if(bytes.Length!=Convert.ToInt32(match.Groups[2].Value,16))throw new InvalidDataException("Menu-cache block size mismatch");
            foreach(Match cls in Regex.Matches(Encoding.ASCII.GetString(bytes),@"CBCGP\w+")) {
                if(cls.Value!="CBCGPToolbarMenuButton" && cls.Value!="CBCGPToolbarButton") {ignored.Add(name);return match.Value;}
            }
            int previous=count;
            byte[] modified=RewriteBytes(bytes,pairs,ref count);
            if(previous==count)return match.Value;
            string nl=match.Value.Contains("\r\n")?"\r\n":"\n";
            StringBuilder output=new StringBuilder("B:\""+name+"\"="+modified.Length.ToString("x8")+nl);
            for(int i=0;i<modified.Length;i+=30) {
                output.Append(' ');
                for(int j=i;j<Math.Min(i+30,modified.Length);j++) {if(j>i)output.Append(' ');output.Append(modified[j].ToString("x2"));}
                output.Append(nl);
            }
            return output.ToString();
        });
        string[,] names=new string[,]{{"Menu Bar","菜单栏"},{"Toolbar","工具栏"}};
        for(int i=0;i<2;i++) {
            string from=names[i,restore?1:0],to=names[i,restore?0:1];
            Regex label=new Regex("(?m)^(S:\"BCGToolBar-[^\"]+-Name\"=)"+Regex.Escape(from)+"(?=\\r?$)");
            result=label.Replace(result,delegate(Match m){count++;return m.Groups[1].Value+to;});
        }
        changes=count;skipped=ignored.ToArray();return result;
    }
}
'@
        }
        $encoding=New-Object Text.UTF8Encoding($false)
        $prefix=[byte[]]@();$offset=0
        if($before.Length -ge 3 -and $before[0] -eq 239 -and $before[1] -eq 187 -and $before[2] -eq 191) {$prefix=[byte[]]@(239,187,191);$offset=3}
        elseif($before.Length -ge 2 -and $before[0] -eq 255 -and $before[1] -eq 254) {$encoding=[Text.Encoding]::Unicode;$prefix=[byte[]]@(255,254);$offset=2}
        $text=$encoding.GetString($before,$offset,$before.Length-$offset)
        $captionPath=Join-Path $PSScriptRoot 'menu-captions.json'
        $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if($manifest.menu_captions_sha256 -and (Get-FileHash -LiteralPath $captionPath -Algorithm SHA256).Hash -ne $manifest.menu_captions_sha256) {throw 'Menu-caption dictionary is damaged.'}
        $mapping=Get-Content -LiteralPath $captionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pairs=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach($property in $mapping.PSObject.Properties) {
            if($Mode -eq 'Apply') {$a=$property.Name;$b=[string]$property.Value}
            else {$a=[string]$property.Value;$b=$property.Name}
            if(!$pairs.ContainsKey($a)){$pairs.Add($a,$b)}
        }
        $count=0;[string[]]$skipped=@()
        $result=[CrtMenuCachePatch]::Rewrite($text,$pairs,($Mode -eq 'Restore'),[ref]$count,[ref]$skipped)
        $updated=[byte[]]($prefix+$encoding.GetBytes($result))
    }
    if([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($updated)) {
        @{Status='AlreadyInRequestedState';Mode=$Mode;Replacements=0;SkippedBlocks=$skipped} | ConvertTo-Json -Compress
        exit 0
    }
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    $snapshot=Join-Path $historyRoot ((Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.ini')
    [IO.File]::WriteAllBytes($snapshot,$before)
    $stage=Join-Path (Split-Path -Parent $ConfigFile) ('SCRTMenuToolbarV3.zh-stage-'+[guid]::NewGuid().ToString('N')+'.ini')
    try {
        [IO.File]::WriteAllBytes($stage,$updated)
        $afterHash=(Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash
        if((Get-FileHash -LiteralPath $ConfigFile -Algorithm SHA256).Hash -ne $beforeHash) {throw 'Menu cache changed during preparation.'}
        if($Mode -eq 'Apply') {
            $originalFile=$snapshot;$originalHash=$beforeHash;$allowExact=$true
            if($state -and $beforeHash -ne $state.OriginalHash){
                $originalFile=$state.OriginalFile;$originalHash=$state.OriginalHash
                $allowExact=($state.ExactRestoreAllowed -ne $false -and $beforeHash -eq $state.PatchedHash)
            }
            $stateTemporary=$statePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
            $statePrevious=$stateTemporary+'.before'
            try {
                @{OriginalFile=$originalFile;OriginalHash=$originalHash;PatchedHash=$afterHash;ConfigFile=$ConfigFile;ExactRestoreAllowed=$allowExact} |
                    ConvertTo-Json | Set-Content -LiteralPath $stateTemporary -Encoding UTF8
                if(Test-Path -LiteralPath $statePath){[IO.File]::Replace($stateTemporary,$statePath,$statePrevious)}
                else{[IO.File]::Move($stateTemporary,$statePath)}
            } finally {
                foreach($path in @($stateTemporary,$statePrevious)) {
                    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}
                }
            }
        }
        $atomicBackup=$stage+'.before'
        [IO.File]::Replace($stage,$ConfigFile,$atomicBackup)
        if(Test-Path -LiteralPath $atomicBackup){Remove-Item -LiteralPath $atomicBackup -ErrorAction SilentlyContinue}
    } finally {if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage}}
    @{Status='Completed';Mode=$Mode;Replacements=$count;ExactRestore=$exactRestore;SkippedBlocks=$skipped;Snapshot=$snapshot} | ConvertTo-Json -Compress
    exit 0
} catch {[Console]::Error.WriteLine($_.Exception.Message);exit 1}
