param(
    [string]$GameDirectory,
    [ValidateSet('Install','Restore','Verify')][string]$Action
)
$ErrorActionPreference = 'Stop'
$originalHash = 'c24495e51b406f03b03890c4788ee618ae022c991405be5d5b8b787cb775ae89'
$patchedHash = '9fa389729019198b7396aab9d9d637a71215be63bf3b544394df04695868f605'
$patches = @(
    @{Offset=0x476391f; Before='e87c000000'; After='b801000000'},
    @{Offset=0x32e4fe3; Before='e838000000'; After='b801000000'},
    @{Offset=0x32e52ea; Before='e931fdffff'; After='b001c39090'},
    @{Offset=0x2e26f79; Before='0f84e511cd01'; After='909090909090'}
)
function Get-ByteHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-FileDigest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Convert-HexBytes([string]$Hex) {
    $result = New-Object byte[] ($Hex.Length / 2)
    for ($i=0; $i -lt $result.Length; $i++) { $result[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return ,$result
}
function Get-GameRoot([string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '请输入游戏根目录。' }
    $clean = [Environment]::ExpandEnvironmentVariables($InputPath.Trim().Trim('"'))
    $root = (Resolve-Path -LiteralPath $clean -ErrorAction Stop).ProviderPath
    foreach ($name in @('Endfield.exe','GameAssembly.dll')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) {
            throw "该目录缺少 $name。请选择游戏目录，不是启动器目录。"
        }
    }
    return $root
}
function Invoke-Patch([string]$Root,[string]$Operation) {
    $target = Join-Path $Root 'GameAssembly.dll'
    $current = Get-FileDigest $target
    $state = if ($current -eq $originalHash) { '原版' } elseif ($current -eq $patchedHash) { 'v3 触屏补丁' } else { '不支持的版本或其他修改' }
    Write-Host "当前状态：$state"
    if ($Operation -eq 'Verify') { Write-Host "SHA-256：$current"; return }
    if ($current -ne $originalHash -and $current -ne $patchedHash) {
        throw '文件版本不匹配，未修改任何文件。本工具不能用于其他版本或旧实验补丁。'
    }
    if (Get-Process Endfield -ErrorAction SilentlyContinue) { throw '请先完全退出游戏，再应用或消除补丁。' }
    $install = $Operation -eq 'Install'
    $expected = if ($install) { $patchedHash } else { $originalHash }
    if ($current -eq $expected) { Write-Host '已是目标状态，无需修改。'; return }
    $bytes = [IO.File]::ReadAllBytes($target)
    if ((Get-ByteHash $bytes) -ne $current) { throw '读取期间游戏文件发生变化，已中止。' }
    foreach ($patch in $patches) {
        $before = Convert-HexBytes $(if ($install) { $patch.Before } else { $patch.After })
        $after = Convert-HexBytes $(if ($install) { $patch.After } else { $patch.Before })
        for ($i=0; $i -lt $before.Length; $i++) {
            if ($bytes[$patch.Offset+$i] -ne $before[$i]) { throw '补丁位置校验失败，已中止。' }
        }
        [Array]::Copy($after,0,$bytes,$patch.Offset,$after.Length)
    }
    if ((Get-ByteHash $bytes) -ne $expected) { throw '生成文件的完整哈希不匹配，已中止。' }
    $backup = Join-Path $Root 'GameAssembly.dll.touch-original.bak'
    if ($install) {
        if (Test-Path -LiteralPath $backup) {
            if ((Get-FileDigest $backup) -ne $originalHash) { throw '已有备份不是匹配的原版，未覆盖它。' }
        } else {
            [IO.File]::Copy($target,$backup,$false)
            if ((Get-FileDigest $backup) -ne $originalHash) { throw '原版备份校验失败，未应用补丁。' }
        }
    }
    # Restore reverses only the four verified ranges; the complete output must
    # match the original SHA-256, so a lost backup does not prevent restoration.
    $stage = Join-Path $Root ('GameAssembly.dll.touch-stage-' + [Guid]::NewGuid().ToString('N'))
    $rollback = $stage + '.previous'
    try {
        [IO.File]::WriteAllBytes($stage,$bytes)
        if ((Get-FileDigest $stage) -ne $expected) { throw '临时文件写入校验失败。' }
        if (Get-Process Endfield -ErrorAction SilentlyContinue) { throw '游戏刚刚启动，已中止修改。' }
        if ((Get-FileDigest $target) -ne $current) { throw '游戏文件在准备期间改变，已中止修改。' }
        [IO.File]::Replace($stage,$target,$rollback)
        if ((Get-FileDigest $target) -ne $expected) { throw "最终校验失败，替换前的文件保留在：$rollback" }
        Remove-Item -LiteralPath $rollback
        if ($install) { Write-Host '已应用 v3 补丁并完成哈希校验。原版备份已保留。' -ForegroundColor Green }
        else { Write-Host '已消除补丁，完整文件哈希与原版一致。原版备份仍保留。' -ForegroundColor Green }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage }
    }
}
if ($Action) {
    try { Invoke-Patch (Get-GameRoot $GameDirectory) $Action; exit 0 }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
Write-Host '终末地 PC 触屏补丁 v3' -ForegroundColor Cyan
Write-Host '应用后保持生效；退出游戏不会自动消除。可随时再次运行本工具恢复原版。'
while ($true) {
    if (!$GameDirectory) { $GameDirectory = Read-Host '输入游戏根目录（含 Endfield.exe，可粘贴带引号路径；输入 0 退出）' }
    if ($GameDirectory -eq '0') { break }
    try { $GameDirectory = Get-GameRoot $GameDirectory }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; $GameDirectory=$null; continue }
    Write-Host "`n游戏目录：$GameDirectory"
    Write-Host '[1] 应用 v3 补丁  [2] 消除补丁  [3] 检查状态  [4] 更换目录  [0] 退出'
    $choice = Read-Host '请选择'
    if ($choice -eq '0') { break }
    if ($choice -eq '4') { $GameDirectory=$null; continue }
    $operation = switch ($choice) { '1' {'Install'} '2' {'Restore'} '3' {'Verify'} default {$null} }
    if (!$operation) { Write-Host '请输入 0–4。'; continue }
    try { Invoke-Patch $GameDirectory $operation }
    catch { Write-Host ("操作失败：" + $_.Exception.Message) -ForegroundColor Red }
}
