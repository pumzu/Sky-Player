[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateStateRoot,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateSet("stable", "beta")]
    [string]$Channel,

    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [Parameter(Mandatory = $true)]
    [string]$SourceSha,

    [string]$WorkflowSha,
    [string]$StateRoot,
    [switch]$KeepStateOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pipelinePath = Join-Path $PSScriptRoot "v4_release_pipeline.ps1"
$candidateRoot = [IO.Path]::GetFullPath($CandidateStateRoot)
$candidateManifestPath = Join-Path $candidateRoot "candidate-manifest.json"
$canonicalBundleDir = Join-Path $repoRoot "rust/target/dist/bundle/nsis"
$canonicalEvidenceDir = Join-Path $repoRoot "rust/target/dist"
. (Join-Path $PSScriptRoot "v4_qualification_evidence.ps1")

function Fail([string]$Message) {
    throw "V4 production-topology rehearsal failed closed: $Message"
}

function Resolve-ExternalDirectory([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Fail "$Name is required" }
    $full = [IO.Path]::GetFullPath($Path)
    $repoPrefix = $repoRoot.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    if ($full.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Name must be outside the repository workspace"
    }
    return $full
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Get-SourceAssetPath([object]$Record) {
    $sourceName = if ($null -ne $Record.PSObject.Properties["source_name"]) {
        [string]$Record.source_name
    } else {
        [string]$Record.name
    }
    $role = [string]$Record.role
    if ($role -in @("installer", "updater-signature")) {
        return Join-Path $canonicalBundleDir $sourceName
    }
    return Join-Path $canonicalEvidenceDir $sourceName
}

if ($SourceSha -notmatch "^[0-9a-fA-F]{40}$") { Fail "source SHA must be an exact 40-character commit SHA" }
if ($Tag -ne "v$Version") { Fail "tag must exactly equal v<version>" }

$candidateRoot = Resolve-ExternalDirectory $candidateRoot "CandidateStateRoot"
if (-not (Test-Path -LiteralPath $candidateManifestPath -PathType Leaf)) {
    Fail "BuildCandidate manifest is missing: $candidateManifestPath"
}

$effectiveWorkflowSha = if ([string]::IsNullOrWhiteSpace($WorkflowSha)) { $SourceSha } else { $WorkflowSha }
$effectiveStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    Join-Path ([IO.Path]::GetTempPath()) ("sky-v4-production-topology-" + [guid]::NewGuid().ToString("N"))
} else {
    $StateRoot
}
$effectiveStateRoot = Resolve-ExternalDirectory $effectiveStateRoot "StateRoot"
if ($effectiveStateRoot.Equals($candidateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "StateRoot must be separate from CandidateStateRoot"
}
if (Test-Path -LiteralPath $effectiveStateRoot -PathType Leaf) {
    Fail "StateRoot must be a directory"
}
$stateRootExisted = Test-Path -LiteralPath $effectiveStateRoot -PathType Container
if ($stateRootExisted -and @(Get-ChildItem -LiteralPath $effectiveStateRoot -Force).Count -ne 0) {
    Fail "StateRoot must be empty for a disposable topology rehearsal"
}
New-Item -ItemType Directory -Path $effectiveStateRoot -Force | Out-Null

$manifest = Get-Content -LiteralPath $candidateManifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.source_sha -ne $SourceSha.ToLowerInvariant() -or
    [string]$manifest.version -ne $Version -or
    [string]$manifest.channel -ne $Channel) {
    Fail "candidate manifest identity does not match the rehearsal request"
}

$records = @($manifest.assets)
if ($records.Count -eq 0) { Fail "candidate manifest contains no assets" }
$downloaded = Join-Path $effectiveStateRoot "downloaded"
New-Item -ItemType Directory -Path $downloaded -Force | Out-Null

try {
    foreach ($record in $records) {
        $sourceName = if ($null -ne $record.PSObject.Properties["source_name"]) {
            [string]$record.source_name
        } else {
            [string]$record.name
        }
        $authorityName = if ($null -ne $record.PSObject.Properties["authority_name"]) {
            [string]$record.authority_name
        } else {
            Get-V4SafeAuthorityAssetName $sourceName
        }
        $sourcePath = Get-SourceAssetPath $record
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Fail "candidate asset is missing from the BuildCandidate output: $sourcePath"
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([int64]$sourceItem.Length -ne [int64]$record.size -or
            $sourceHash -ne [string]$record.sha256) {
            Fail "candidate asset changed after BuildCandidate: $sourceName"
        }
        $destination = Join-Path $downloaded $authorityName
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
        $downloadedItem = Get-Item -LiteralPath $destination
        $downloadedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([int64]$downloadedItem.Length -ne [int64]$record.size -or
            $downloadedHash -ne [string]$record.sha256) {
            Fail "staged rehearsal asset is not byte-identical: $sourceName"
        }
    }

    $releaseState = [ordered]@{
        schema_version = 1
        source_sha = $SourceSha.ToLowerInvariant()
        version = $Version
        channel = $Channel
        tag = $Tag
        release_id = 0
        draft = $true
        published = $false
        immutable = $false
        attested = $false
        qualified_after_download = $false
        assets = $records
    }
    Write-JsonFile (Join-Path $effectiveStateRoot "release-state.json") $releaseState
    Write-JsonFile (Join-Path $effectiveStateRoot "downloaded-manifest.json") ([ordered]@{
        schema_version = 1
        source_sha = $SourceSha.ToLowerInvariant()
        version = $Version
        channel = $Channel
        assets = $records
    })

    $pipelineArguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $pipelinePath,
        "-State", "QualifyDownloaded",
        "-Version", $Version,
        "-Channel", $Channel,
        "-Tag", $Tag,
        "-SourceSha", $SourceSha,
        "-WorkflowSha", $effectiveWorkflowSha,
        "-StateRoot", $effectiveStateRoot
    )
    & pwsh @pipelineArguments
    if ($LASTEXITCODE -ne 0) {
        Fail "the production QualifyDownloaded entrypoint returned exit code $LASTEXITCODE"
    }
    Write-Host "V4 production-topology rehearsal: PASS (v4_release_pipeline.ps1 -State QualifyDownloaded; exact candidate bytes; isolated fixture target)"
}
finally {
    if (-not $KeepStateOnFailure -and -not $stateRootExisted -and (Test-Path -LiteralPath $effectiveStateRoot)) {
        Remove-Item -LiteralPath $effectiveStateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
