$ErrorActionPreference = "Stop"

$canonicalRepository = "pumni/Sky-Auto-Player"
if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY) -or
    $env:GITHUB_REPOSITORY -ne $canonicalRepository) {
    throw "legacy Latest guard requires the canonical repository identity"
}

function Get-GitHubJson([string]$Path) {
    $payload = & gh api $Path --header "Accept: application/vnd.github+json"
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub read failed for $Path"
    }
    return ($payload -join "`n") | ConvertFrom-Json
}

$latest = Get-GitHubJson "repos/$canonicalRepository/releases/latest"
if ($latest.url -notlike "https://api.github.com/repos/$canonicalRepository/releases/*") {
    throw "Unexpected canonical repository in GitHub Latest response: $($latest.url)"
}
if ($latest.draft -or $latest.prerelease) {
    throw "The legacy GitHub Latest release must be published and non-prerelease: $($latest.tag_name)"
}
if ($latest.tag_name -notmatch '^v(?<version>3\.\d+\.\d+)$') {
    throw "v4 publication displaced the legacy GitHub Latest release: $($latest.tag_name)"
}

$version = $Matches.version
$assetNames = @($latest.assets | ForEach-Object { $_.name })
$requiredLegacyAssets = @(
    "Sky-Auto-Player-v$version.zip",
    "Sky-Auto-Player-v$version.zip.sha256",
    "MANIFEST.json"
)
foreach ($asset in $requiredLegacyAssets) {
    if ($assetNames -notcontains $asset) {
        throw "The legacy GitHub Latest release is missing its canonical asset: $asset"
    }
}
if ($assetNames | Where-Object { $_ -match '^Sky Auto Player_4(?:\.\d+|-)' }) {
    throw "A canonical v4 Tauri artifact appeared in the legacy GitHub Latest release"
}

@"
V4 legacy GitHub Latest guard: PASS
repository=$canonicalRepository
legacy_latest_tag=$($latest.tag_name)
legacy_latest_release=$($latest.html_url)
make_latest=false
read_only=true
"@ | Write-Host
