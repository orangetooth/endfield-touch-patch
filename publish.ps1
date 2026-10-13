$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
    if (!$gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }
    if (!(Test-Path -LiteralPath $gh)) { throw 'GitHub CLI not found.' }
    $login = & $gh api user --jq .login
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed in this terminal. Run gh auth login, then retry.' }
    $repository = "$login/endfield-touch-patch"
    $origin = git remote get-url origin 2>$null
    if (!$origin) {
        & $gh repo create $repository --public --source . --remote origin --push --description 'Endfield PC touch UI patch: interactive apply/restore with SHA-256 verification'
        if ($LASTEXITCODE -ne 0) { throw 'Repository creation or push failed. Existing repositories are not overwritten.' }
    } else {
        if ($origin -notin @("https://github.com/$repository.git","https://github.com/$repository","git@github.com:$repository.git")) { throw "Unexpected origin: $origin" }
        git -c credential.helper= -c "credential.helper=!`"$gh`" auth git-credential" push -u origin main
        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
    }
    $url = & $gh repo view $repository --json url --jq .url
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify repository URL.' }
    $url | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'publish-result.txt') -Encoding UTF8
    Write-Host "Published: $url" -ForegroundColor Green
} finally { Pop-Location }
