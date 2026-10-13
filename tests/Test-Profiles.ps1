$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$work = Join-Path $PSScriptRoot ('.work-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
function Digest([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Variant([string]$Id,[byte[]]$Original,[int]$Offset,[byte]$Value) {
    $copy = $Original.Clone(); $copy[$Offset]=$Value
    return @{id=$Id;sha256=(Digest $copy);patches=@(@{offset=$Offset;before=('{0:x2}' -f $Original[$Offset]);after=('{0:x2}' -f $Value)})}
}
function Run-Patch([string]$Operation,[int]$ExpectedExit=0) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'patch.ps1') -GameDirectory $work -Action $Operation -Offline | Out-Null
    Assert ($LASTEXITCODE -eq $ExpectedExit) "Unexpected exit code for $Operation : $LASTEXITCODE"
}
try {
    Copy-Item -LiteralPath (Join-Path $repository 'patch.ps1'),(Join-Path $repository 'rules.ps1') -Destination $work
    [IO.File]::WriteAllBytes((Join-Path $work 'Endfield.exe'),[byte[]]@(0))
    $first=[byte[]](0..127); $second=[byte[]](127..0)
    $a=@{id='build-a';size=128;original_sha256=(Digest $first);target_variant='new';variants=@((Variant 'old' $first 16 200),(Variant 'new' $first 16 201))}
    $b=@{id='build-b';size=128;original_sha256=(Digest $second);target_variant='new';variants=@((Variant 'new' $second 80 202))}
    $db=@{schema_version=1;revision=1;profiles=@($a,$b)}
    $rulesPath=Join-Path $work 'profiles.json'
    $db | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $rulesPath -Encoding UTF8
    $target=Join-Path $work 'GameAssembly.dll'
    foreach ($pair in @(@{Bytes=$first;Profile=$a},@{Bytes=$second;Profile=$b})) {
        [IO.File]::WriteAllBytes($target,$pair.Bytes)
        Run-Patch Install
        Assert ((Digest ([IO.File]::ReadAllBytes($target))) -eq $pair.Profile.variants[-1].sha256) 'Wrong build/offset selected'
        Run-Patch Install # idempotent
        Run-Patch Restore
        Assert ((Digest ([IO.File]::ReadAllBytes($target))) -eq $pair.Profile.original_sha256) 'Restore mismatch'
    }
    Assert (@(Get-ChildItem -LiteralPath $work -Filter '*.bak').Count -eq 2) 'Backups for different builds collided'
    Write-Host 'PASS two game hashes, independent offsets, reversible output and separate backups'
    $legacy=$first.Clone();$legacy[16]=200;[IO.File]::WriteAllBytes($target,$legacy)
    Run-Patch Install
    Assert ((Digest ([IO.File]::ReadAllBytes($target))) -eq $a.variants[-1].sha256) 'Legacy migration failed'
    Run-Patch Restore
    Write-Host 'PASS recognized old patch migrates through verified original to target'
    [IO.File]::WriteAllBytes($target,[byte[]]@(1,2,3));$unknown=Digest ([IO.File]::ReadAllBytes($target))
    Run-Patch Install 1
    Assert ((Digest ([IO.File]::ReadAllBytes($target))) -eq $unknown) 'Unknown file changed'
    Write-Host 'PASS unknown hashes leave input untouched'
    $wrongOutput=$db | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $wrongOutput.profiles[0].variants[1].sha256=('f'*64)
    $wrongOutput | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $rulesPath -Encoding UTF8
    [IO.File]::WriteAllBytes($target,$first)
    Run-Patch Install 1
    Assert ((Digest ([IO.File]::ReadAllBytes($target))) -eq $a.original_sha256) 'Bad output hash changed game file'
    $db | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $rulesPath -Encoding UTF8
    Write-Host 'PASS incorrect target hash rejected before game file replacement'
    . (Join-Path $work 'rules.ps1')
    $valid=Read-PatchDatabase $rulesPath
    foreach ($fault in @('duplicate','overlap','bounds','unequal')) {
        $bad=$db | ConvertTo-Json -Depth 15 | ConvertFrom-Json
        switch ($fault) {
            'duplicate' {$bad.profiles[1].original_sha256=$bad.profiles[0].original_sha256}
            'overlap' {$bad.profiles[0].variants[0].patches=@($bad.profiles[0].variants[0].patches[0],$bad.profiles[0].variants[0].patches[0])}
            'bounds' {$bad.profiles[0].variants[0].patches[0].offset=128}
            'unequal' {$bad.profiles[0].variants[0].patches[0].after='0000'}
        }
        $rejected=$false
        try { Assert-PatchDatabase $bad } catch { $rejected=$true }
        Assert $rejected "Invalid database accepted: $fault"
    }
    Write-Host 'PASS duplicate hashes, overlapping/out-of-bounds offsets and unequal edits rejected'
    # Exercise cache/update behavior without internet or public repository writes.
    $db.revision=2
    $script:downloadText=$db | ConvertTo-Json -Depth 15
    function Invoke-WebRequest { param($Uri,[switch]$UseBasicParsing,$TimeoutSec,$MaximumRedirection) return [pscustomobject]@{Content=$script:downloadText} }
    Update-PatchDatabase | Out-Null
    Assert ((Get-PatchDatabase).revision -eq 2) 'Updated cache not selected'
    $cache=Join-Path $work 'profiles-cache.json';$cacheHash=Digest ([IO.File]::ReadAllBytes($cache))
    $script:downloadText='{"schema_version":99}'
    $rejected=$false;try { Update-PatchDatabase | Out-Null } catch { $rejected=$true }
    Assert $rejected 'Invalid update accepted'
    Assert ((Digest ([IO.File]::ReadAllBytes($cache))) -eq $cacheHash) 'Invalid download changed cache'
    $db.revision=1;$script:downloadText=$db | ConvertTo-Json -Depth 15
    $rejected=$false;try { Update-PatchDatabase | Out-Null } catch { $rejected=$true }
    Assert $rejected 'Rollback accepted'
    $db.revision=3;$db.profiles=@($a);$script:downloadText=$db | ConvertTo-Json -Depth 15
    $rejected=$false;try { Update-PatchDatabase | Out-Null } catch { $rejected=$true }
    Assert $rejected 'Update silently discarded old restore rules'
    Assert ((Digest ([IO.File]::ReadAllBytes($cache))) -eq $cacheHash) 'Rejected update changed cache'
    Write-Host 'PASS cached updates selected; invalid/older downloads leave cache intact'
} finally {
    $resolved=[IO.Path]::GetFullPath($work)
    $allowed=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if (!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike '.work-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
