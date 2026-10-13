# Endfield Touch Patch

《明日方舟：终末地》PC 版触屏补丁 v3。保留普通登录，启用移动端触屏界面，并修复此次测试中好友页等 UI 按钮按下后不弹起的问题，可用于 Moonlight 触屏串流。

## 使用

1. 完全退出游戏，双击 `run.cmd`。
2. 输入含 `Endfield.exe` 和 `GameAssembly.dll` 的游戏根目录，例如 `D:\Hypergryph Launcher\games\Endfield Game`。
3. 选择 **1 应用补丁**、**2 消除补丁**，或 **3 检查状态**。可选择4更换目录。

无需安装 Python、下载修改后的 DLL，也不依赖原作者的工作区。若安装目录不可写，可用管理员终端运行脚本。

这是手动补丁工具：游戏退出后不会自动回退。应用时在游戏目录保留 `GameAssembly.dll.touch-original.bak`，不覆盖不匹配的已有备份。消除补丁会反向修改并验证原版完整哈希，即使备份丢失，也可还原本工具识别的 v3 文件。

## 支持范围

只处理以下两个 SHA-256，游戏更新或其他修改导致哈希不同会直接拒绝。旧 v1/v2/诊断版需先用原工具恢复。

|文件|SHA-256|
|---|---|
|原版|`c24495e51b406f03b03890c4788ee618ae022c991405be5d5b8b787cb775ae89`|
|v3|`9fa389729019198b7396aab9d9d637a71215be63bf3b544394df04695868f605`|

脚本验证输入哈希、修改位置和输出哈希，拒绝在 Endfield 运行时改文件；同目录临时文件完成校验后原子替换。原版文件大小为256677352字节。

## 修改原理

前三处改动启用本地触屏输入；第四处取消 UI 输入模块中会复用指针并清空待处理按钮状态的分支，修复触摸抬起被紧随其后的鼠标位置事件干扰的问题。它不补发点击，不修改普通登录和 ACE。

|文件偏移|原字节|修改后|
|---|---|---|
|`0x476391f`|`e87c000000`|`b801000000`|
|`0x32e4fe3`|`e838000000`|`b801000000`|
|`0x32e52ea`|`e931fdffff`|`b001c39090`|
|`0x2e26f79`|`0f84e511cd01`|`909090909090`|

用户已确认同一 v3 行为补丁有效；诊断会话记录25次 UIButton 按下、25次抬起、25次点击回调。并非所有游戏版本或输入设备都经过测试。

命令行用法（Windows PowerShell 5.1 或 PowerShell 7）：

```powershell
.\patch.ps1 -GameDirectory 'D:\Hypergryph Launcher\games\Endfield Game' -Action Verify
.\patch.ps1 -GameDirectory 'D:\Hypergryph Launcher\games\Endfield Game' -Action Install
.\patch.ps1 -GameDirectory 'D:\Hypergryph Launcher\games\Endfield Game' -Action Restore
```

仓库仅包含补丁脚本和说明，不含游戏 DLL、账号信息或运行日志。原创脚本采用 MIT 许可证；游戏及相关资产归各自权利人所有。
