# 使用与恢复

仅支持 SecureCRT 9.7.3.3916 x64 和 manifest.json 中列出的精确文件状态。请先安装相应原版并退出所有 SecureCRT 进程。遇到版本、哈希不匹配时，不要强行覆盖。

默认安装目录 D:\SecureCRT；补丁不包含原程序。应用和恢复都在当前文件夹运行。

```powershell
& .\apply.ps1
& .\restore.ps1
```

自定义安装目录和配置缓存路径：

```powershell
& .\apply.ps1 -InstallDir 'D:\SecureCRT' -ConfigFile "$env:APPDATA\VanDyke\Config\SCRTMenuToolbarV3.ini"
```

备份默认保存在本用户 LOCALAPPDATA\SecureCRT-zh-CN 下。使用自定义 BackupRoot 时，恢复必须传入相同 BackupRoot。请勿删除或从其他版本拼接备份。

自定义程序目录时，如果没有显式 ConfigFile，包装脚本不会触碰默认用户菜单缓存。默认 D:\SecureCRT 会定位注册表中的实际配置路径。菜单缓存只改已知标题，保留命令、工具栏布局和用户配置；遇到未知类的缓存块会跳过。

程序文件先完整重建并校验，再在目标目录原子替换。普通错误会自动回滚；如果进程被强制终止，重新运行 restore.ps1 恢复已知的原版/补丁混合状态。恢复脚本不会删除新增会话。

若本机此前使用其他汉化构建，请先使用其配套恢复入口还原，再应用此包。已经由其他来源汉化但没有匹配原始备份时，本包不会臆测还原未知文件。
