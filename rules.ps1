# Declarative, versioned patch rules. Remote data is never executed as code.
$script:PatchDataDirectory = $PSScriptRoot
$script:PatchRulesUrl = 'https://raw.githubusercontent.com/orangetooth/endfield-touch-patch/main/profiles.json'

function Assert-PatchDatabase($Database) {
    if ($Database.schema_version -ne 1) { throw 'Unsupported patch database schema; update the tool.' }
    if ($null -eq $Database.revision -or $Database.revision -lt 1 -or [math]::Floor($Database.revision) -ne $Database.revision) { throw 'Invalid database revision.' }
    $profiles = @($Database.profiles)
    if (!$profiles.Count -or $profiles.Count -gt 128) { throw 'Invalid profile count.' }
    $knownHashes = @{}; $profileIds = @{}
    foreach ($profile in $profiles) {
        if ($profile.id -notmatch '^[a-zA-Z0-9._-]{1,80}$' -or $profileIds.ContainsKey($profile.id)) { throw 'Invalid or duplicate profile ID.' }
        $profileIds[$profile.id]=$true
        if ($null -eq $profile.size -or $profile.size -lt 1 -or $profile.size -gt [int]::MaxValue -or [math]::Floor($profile.size) -ne $profile.size) { throw 'Invalid file size.' }
        if ($profile.original_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $knownHashes.ContainsKey($profile.original_sha256)) { throw 'Invalid or duplicate original hash.' }
        $knownHashes[$profile.original_sha256]=$true
        $variants = @($profile.variants); $variantIds = @{}
        if (!$variants.Count -or $variants.Count -gt 16) { throw 'Invalid variant count.' }
        foreach ($variant in $variants) {
            if ($variant.id -notmatch '^[a-zA-Z0-9._-]{1,40}$' -or $variantIds.ContainsKey($variant.id)) { throw 'Invalid or duplicate variant ID.' }
            $variantIds[$variant.id]=$true
            if ($variant.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $knownHashes.ContainsKey($variant.sha256)) { throw 'Invalid or ambiguous patched hash.' }
            $knownHashes[$variant.sha256]=$true
            $patches = @($variant.patches); $end = 0
            if (!$patches.Count -or $patches.Count -gt 4096) { throw 'Invalid patch count.' }
            foreach ($patch in ($patches | Sort-Object offset)) {
                if ($patch.before -notmatch '^(?:[a-fA-F0-9]{2})+$' -or $patch.after -notmatch '^(?:[a-fA-F0-9]{2})+$' -or $patch.before.Length -ne $patch.after.Length) { throw 'Invalid or unequal patch bytes.' }
                if ($null -eq $patch.offset -or [math]::Floor($patch.offset) -ne $patch.offset -or $patch.offset -lt $end) { throw 'Invalid or overlapping patch offsets.' }
                $end = [long]$patch.offset + $patch.before.Length/2
                if ($end -gt $profile.size) { throw 'Patch outside file bounds.' }
            }
        }
        if (!$profile.target_variant -or !$variantIds.ContainsKey($profile.target_variant)) { throw 'Missing target variant.' }
    }
}
function Read-PatchDatabase([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 5MB) { throw 'Patch database is too large.' }
    $database = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PatchDatabase $database
    return $database
}
function Get-PatchDatabase {
    $database = Read-PatchDatabase (Join-Path $script:PatchDataDirectory 'profiles.json')
    $cache = Join-Path $script:PatchDataDirectory 'profiles-cache.json'
    if (Test-Path -LiteralPath $cache) {
        try {
            $cached = Read-PatchDatabase $cache
            if ($cached.revision -ge $database.revision) { $database=$cached }
        } catch { Write-Warning ('Ignored invalid cached rules: ' + $_.Exception.Message) }
    }
    return $database
}
function Update-PatchDatabase {
    $current = Get-PatchDatabase
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $script:PatchRulesUrl -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0
    } finally { [Net.ServicePointManager]::SecurityProtocol = $previousProtocol }
    $content = [string]$response.Content
    if ($content.Length -gt 5MB) { throw 'Downloaded rules are too large.' }
    $database = $content | ConvertFrom-Json
    Assert-PatchDatabase $database
    if ($database.revision -lt $current.revision) { throw 'Refusing an older patch database.' }
    foreach ($profile in $current.profiles) {
        foreach ($hash in @($profile.original_sha256) + @($profile.variants | ForEach-Object { $_.sha256 })) {
            if (!(Find-PatchProfile $database $hash)) { throw 'Update removes existing restore rules; refusing to replace the cache.' }
        }
    }
    $cache = Join-Path $script:PatchDataDirectory 'profiles-cache.json'
    $stage = $cache + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($stage,$content,(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $cache) { [IO.File]::Replace($stage,$cache,$null) }
        else { [IO.File]::Move($stage,$cache) }
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage } }
    Write-Host ("Patch rules updated: revision {0}, {1} game build(s)." -f $database.revision,@($database.profiles).Count)
    return $database
}
function Find-PatchProfile($Database,[string]$Hash) {
    foreach ($profile in $Database.profiles) {
        if ($profile.original_sha256 -eq $Hash) { return [pscustomobject]@{Profile=$profile;Variant=$null} }
        foreach ($variant in $profile.variants) {
            if ($variant.sha256 -eq $Hash) { return [pscustomobject]@{Profile=$profile;Variant=$variant} }
        }
    }
    return $null
}
