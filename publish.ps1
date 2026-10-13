$ErrorActionPreference = 'Stop'
$savedGitEnvironment = @{}
Push-Location $PSScriptRoot
try {
    # The repository may have been created by Codex's sandbox Windows account.
    # Trust only this path, only for this process and its git/gh children.
    # Keep the user's global Git configuration and existing command settings.
    $configCount = 0
    $previousCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT','Process')
    if ($previousCount -and (![int]::TryParse($previousCount,[ref]$configCount) -or $configCount -lt 0 -or $configCount -gt 1024)) {
        throw 'Invalid GIT_CONFIG_COUNT environment variable.'
    }
    $configKey = "GIT_CONFIG_KEY_$configCount"
    $configValue = "GIT_CONFIG_VALUE_$configCount"
    foreach ($name in @('GIT_CONFIG_COUNT',$configKey,$configValue)) {
        $savedGitEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    }
    [Environment]::SetEnvironmentVariable($configKey,'safe.directory','Process')
    [Environment]::SetEnvironmentVariable($configValue,([IO.Path]::GetFullPath($PSScriptRoot).Replace('\','/')),'Process')
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT',([string]($configCount+1)),'Process')
    $repositoryRoot = git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0) { throw 'Cannot access the local Git repository. Publication stopped.' }
    if ([IO.Path]::GetFullPath($repositoryRoot) -ne [IO.Path]::GetFullPath($PSScriptRoot)) {
        throw 'Unexpected Git repository root. Publication stopped.'
    }
    $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
    if (!$gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }
    if (!(Test-Path -LiteralPath $gh)) { throw 'GitHub CLI not found.' }
    $login = & $gh api user --jq .login
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed in this terminal. Run gh auth login, then retry.' }
    $repository = "$login/endfield-touch-patch"
    $origin = $null
    $remotes = @(git remote)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read Git remotes. Publication stopped.' }
    if ($remotes -contains 'origin') {
        $origin = git remote get-url origin
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read origin URL. Publication stopped.' }
    }
    if (!$origin) {
        & $gh repo create $repository --public --source . --remote origin --push --description 'Endfield PC touch UI patch: interactive apply/restore with SHA-256 verification'
        if ($LASTEXITCODE -ne 0) { throw 'Repository creation or push failed. Existing repositories are not overwritten.' }
    } else {
        if ($origin -notin @("https://github.com/$repository.git","https://github.com/$repository","git@github.com:$repository.git")) { throw "Unexpected origin: $origin" }
        git push -u origin main
        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
    }
    $url = & $gh repo view $repository --json url --jq .url
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify repository URL.' }
    $url | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'publish-result.txt') -Encoding UTF8
    Write-Host "Published: $url" -ForegroundColor Green
} finally {
    foreach ($name in $savedGitEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name,$savedGitEnvironment[$name],'Process')
    }
    Pop-Location
}
