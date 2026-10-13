param(
    [string]$GameDirectory,
    [ValidateSet('Install','Restore','Verify','UpdateRules')][string]$Action,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rules.ps1')
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
function Set-PatchBytes([byte[]]$Bytes,$Patches,[bool]$Reverse) {
    foreach ($patch in $Patches) {
        $expectedBytes = Convert-HexBytes $(if ($Reverse) { $patch.after } else { $patch.before })
        $replacementBytes = Convert-HexBytes $(if ($Reverse) { $patch.before } else { $patch.after })
        # Reverse means patched -> original.
        for ($i=0; $i -lt $expectedBytes.Length; $i++) {
            if ($Bytes[[int]$patch.offset+$i] -ne $expectedBytes[$i]) { throw '补丁位置校验失败，已中止。' }
        }
        [Array]::Copy($replacementBytes,0,$Bytes,[int]$patch.offset,$replacementBytes.Length)
    }
}
function Invoke-Patch([string]$Root,[string]$Operation) {
    $target = Join-Path $Root 'GameAssembly.dll'
    $current = Get-FileDigest $target
    $database = Get-PatchDatabase
    $match = Find-PatchProfile $database $current
    if (!$match -and !$Offline) {
        Write-Host '本地规则未收录此哈希，正在检查公开仓库的新规则……'
        try { $database = Update-PatchDatabase; $match = Find-PatchProfile $database $current }
        catch { Write-Host ('规则更新失败，将保留原文件：' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    $state = if (!$match) { '尚未支持的版本或其他修改' } elseif (!$match.Variant) { '原版' } else { $match.Variant.id + ' 触屏补丁' }
    Write-Host "当前状态：$state"
    Write-Host "SHA-256：$current"
    if ($match) { Write-Host ("匹配规则：{0} / {1}（规则库修订 {2}）" -f $match.Profile.id,$match.Profile.target_variant,$database.revision) }
    if ($Operation -eq 'Verify') { return }
    if (!$match) { throw '此哈希暂无匹配补丁，未修改游戏文件。新版需完成分析并收录规则，不能套用旧偏移。' }
    if (Get-Process Endfield -ErrorAction SilentlyContinue) { throw '请先完全退出游戏，再应用或消除补丁。' }
    $profile = $match.Profile
    if ((Get-Item -LiteralPath $target).Length -ne $profile.size) { throw '文件大小与规则不符。' }
    $originalHash = $profile.original_sha256
    $targetVariant = @($profile.variants | Where-Object { $_.id -eq $profile.target_variant })[0]
    $install = $Operation -eq 'Install'
    $expected = if ($install) { $targetVariant.sha256 } else { $originalHash }
    if ($current -eq $expected) { Write-Host '已是目标状态，无需修改。'; return }
    $bytes = [IO.File]::ReadAllBytes($target)
    if ((Get-ByteHash $bytes) -ne $current) { throw '读取期间游戏文件发生变化，已中止。' }
    if ($match.Variant) { Set-PatchBytes $bytes $match.Variant.patches $true }
    if ((Get-ByteHash $bytes) -ne $originalHash) { throw '反向还原的原版哈希不匹配，已中止。' }
    $backup = Join-Path $Root ("GameAssembly.dll.touch-original.$originalHash.bak")
    if ($install) {
        if (Test-Path -LiteralPath $backup) {
            if ((Get-FileDigest $backup) -ne $originalHash) { throw '已有备份不是匹配的原版，未覆盖它。' }
        } else {
            $backupStream = [IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $backupStream.Write($bytes,0,$bytes.Length) } finally { $backupStream.Dispose() }
            if ((Get-FileDigest $backup) -ne $originalHash) { throw '原版备份校验失败，未应用补丁。' }
        }
        Set-PatchBytes $bytes $targetVariant.patches $false
    }
    if ((Get-ByteHash $bytes) -ne $expected) { throw '生成文件的完整哈希不匹配，已中止。' }
    # Each profile provides its own ranges and full original/output hashes.
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
        if ($install) { Write-Host ("已应用 {0} 补丁并完成哈希校验。原版备份已保留。" -f $targetVariant.id) -ForegroundColor Green }
        else { Write-Host '已消除补丁，完整文件哈希与原版一致。原版备份仍保留。' -ForegroundColor Green }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage }
    }
}
if ($Action) {
    try {
        if ($Action -eq 'UpdateRules') {
            if ($Offline) { throw '离线模式不能更新规则。' }
            Update-PatchDatabase | Out-Null
        } else { Invoke-Patch (Get-GameRoot $GameDirectory) $Action }
        exit 0
    }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
Write-Host '终末地 PC 触屏补丁 — 哈希匹配版' -ForegroundColor Cyan
Write-Host '应用后保持生效；退出游戏不会自动消除。可随时再次运行本工具恢复原版。'
while ($true) {
    if (!$GameDirectory) { $GameDirectory = Read-Host '输入游戏根目录（含 Endfield.exe，可粘贴带引号路径；输入 0 退出）' }
    if ($GameDirectory -eq '0') { break }
    try { $GameDirectory = Get-GameRoot $GameDirectory }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; $GameDirectory=$null; continue }
    Write-Host "`n游戏目录：$GameDirectory"
    Write-Host '[1] 应用匹配补丁  [2] 消除补丁  [3] 检查状态  [4] 更换目录  [5] 更新规则库  [0] 退出'
    $choice = Read-Host '请选择'
    if ($choice -eq '0') { break }
    if ($choice -eq '4') { $GameDirectory=$null; continue }
    if ($choice -eq '5') {
        try {
            if ($Offline) { throw '离线模式不能更新规则。' }
            Update-PatchDatabase | Out-Null
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        continue
    }
    $operation = switch ($choice) { '1' {'Install'} '2' {'Restore'} '3' {'Verify'} default {$null} }
    if (!$operation) { Write-Host '请输入 0–5。'; continue }
    try { Invoke-Patch $GameDirectory $operation }
    catch { Write-Host ("操作失败：" + $_.Exception.Message) -ForegroundColor Red }
}
