# LumixX release publisher - fixed release existence check
# Windows PowerShell 5.1 compatible.
$ErrorActionPreference = "Stop"

$Owner = "MrZalupkin"
$RepoName = "LumixX-Updates"
$RepoSlug = "$Owner/$RepoName"
$Branch = "main"
$ManifestPath = Join-Path $PSScriptRoot "manifest.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Git([string[]]$GitArgs) {
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Gh([string[]]$GhArgs) {
    & gh @GhArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($GhArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Ensure-ManifestObject($Manifest, [string]$Name) {
    $property = $Manifest.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        $value = [PSCustomObject]@{
            version = "0.0.0"
            file = ""
            url = ""
            sha256 = ""
        }
        if ($null -eq $property) {
            $Manifest | Add-Member -NotePropertyName $Name -NotePropertyValue $value
        } else {
            $Manifest.$Name = $value
        }
    }
}

function Read-ReleaseAsset([string]$Kind, [string]$AssetName, [string]$DefaultTagPrefix) {
    Write-Host ""
    Write-Host "=== $Kind ===" -ForegroundColor Cyan

    $inputPath = (Read-Host "Path to $AssetName").Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        throw "File path is empty."
    }
    if (!(Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "File not found: $inputPath"
    }

    $resolved = (Resolve-Path -LiteralPath $inputPath).Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.Length -le 0) {
        throw "$AssetName is empty."
    }
    if ($item.Length -gt 2GB) {
        throw "$AssetName exceeds GitHub's 2 GB per-file release asset limit."
    }

    $version = (Read-Host "Version (for example 1.0.1)").Trim()
    if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,39}$') {
        throw "Invalid version string: $version"
    }

    $defaultTag = "$DefaultTagPrefix$version"
    $tag = (Read-Host "Release tag [$defaultTag]").Trim()
    if ([string]::IsNullOrWhiteSpace($tag)) {
        $tag = $defaultTag
    }
    if ($tag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$') {
        throw "Invalid GitHub release tag: $tag"
    }

    $hash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()

    return [PSCustomObject]@{
        Kind = $Kind
        SourcePath = $resolved
        AssetName = $AssetName
        Version = $version
        Tag = $tag
        Sha256 = $hash
        ReleaseUrl = "https://github.com/$RepoSlug/releases/download/$tag/$AssetName"
        StagePath = ""
    }
}

try {
    Write-Host "LumixX release publisher" -ForegroundColor Magenta
    Write-Host "Repository: https://github.com/$RepoSlug"
    Write-Host ""

    if (!(Test-Path (Join-Path $PSScriptRoot ".git"))) {
        throw "This folder is not a Git clone. Clone https://github.com/$RepoSlug.git, then put the publisher files in the repository root."
    }

    if (!(Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git for Windows is not installed."
    }
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is missing. Install it with: winget install --id GitHub.cli"
    }

    $remote = (& git remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Git remote 'origin' is missing."
    }
    $remoteOk = $remote -match '^(https://github\.com/MrZalupkin/LumixX-Updates(\.git)?|git@github\.com:MrZalupkin/LumixX-Updates(\.git)?)$'
    if (!$remoteOk) {
        throw "Unexpected origin remote: $remote"
    }

    $branch = (& git branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -ne $Branch) {
        throw "Switch to branch '$Branch' first. Current branch: '$branch'"
    }

    & git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Tracked files have local changes. Commit or stash them before publishing."
    }
    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "The Git index contains staged changes. Commit or unstage them before publishing."
    }

    & gh auth status --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run: gh auth login"
    }

    Write-Host ""
    Write-Host "1 - Publish HassleMod.dll"
    Write-Host "2 - Publish LumixXLauncher.exe"
    Write-Host "3 - Publish both"
    $choice = (Read-Host "Select").Trim()

    $assets = @()
    switch ($choice) {
        "1" { $assets += Read-ReleaseAsset "Mod" "HassleMod.dll" "mod-v" }
        "2" { $assets += Read-ReleaseAsset "Launcher" "LumixXLauncher.exe" "launcher-v" }
        "3" {
            $assets += Read-ReleaseAsset "Mod" "HassleMod.dll" "mod-v"
            $assets += Read-ReleaseAsset "Launcher" "LumixXLauncher.exe" "launcher-v"
        }
        default { throw "Choose 1, 2, or 3." }
    }

    # Fetch existing release tags once. An absent tag is normal and must not be treated as an exception.
    Write-Host ""
    Write-Host "Checking existing GitHub Releases..." -ForegroundColor Cyan
    $releaseJsonOutput = & gh release list --repo $RepoSlug --limit 1000 --json tagName 2>&1
    $releaseListExitCode = $LASTEXITCODE
    if ($releaseListExitCode -ne 0) {
        throw "Could not list GitHub Releases: $($releaseJsonOutput | Out-String)"
    }

    $releaseJsonText = $releaseJsonOutput | Out-String
    if ([string]::IsNullOrWhiteSpace($releaseJsonText)) {
        $existingTags = @()
    } else {
        $releaseObjects = $releaseJsonText | ConvertFrom-Json
        $existingTags = @($releaseObjects | ForEach-Object { $_.tagName })
    }

    $seenTags = @{}
    foreach ($asset in $assets) {
        if ($seenTags.ContainsKey($asset.Tag)) {
            throw "Duplicate release tag selected: $($asset.Tag)"
        }
        $seenTags[$asset.Tag] = $true

        if ($existingTags -contains $asset.Tag) {
            throw "Release tag '$($asset.Tag)' already exists. Choose a new version/tag."
        }
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        $manifestText = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        $manifest = $manifestText | ConvertFrom-Json
        if ($null -eq $manifest -or $manifest -isnot [PSCustomObject]) {
            throw "manifest.json must contain a JSON object."
        }
    } else {
        $manifest = [PSCustomObject]@{
            schemaVersion = 1
            product = "LumixX"
            updatedAt = ""
            mod = [PSCustomObject]@{ version = "0.0.0"; file = "HassleMod.dll"; url = ""; sha256 = "" }
            launcher = [PSCustomObject]@{ version = "0.0.0"; file = "LumixXLauncher.exe"; url = ""; sha256 = "" }
        }
    }

    if ($null -eq $manifest.PSObject.Properties["schemaVersion"]) {
        $manifest | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1
    }
    if ($manifest.schemaVersion -ne 1) {
        throw "Unsupported manifest schemaVersion: $($manifest.schemaVersion)"
    }
    if ($null -eq $manifest.PSObject.Properties["product"]) {
        $manifest | Add-Member -NotePropertyName product -NotePropertyValue "LumixX"
    }
    Ensure-ManifestObject $manifest "mod"
    Ensure-ManifestObject $manifest "launcher"

    $stageRoot = Join-Path $env:TEMP ("LumixX-Release-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    foreach ($asset in $assets) {
        $asset.StagePath = Join-Path $stageRoot $asset.AssetName
        Copy-Item -LiteralPath $asset.SourcePath -Destination $asset.StagePath -Force
        $stagedHash = (Get-FileHash -LiteralPath $asset.StagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -ne $asset.Sha256) {
            throw "Staged file hash changed for $($asset.AssetName)."
        }
    }

    Write-Host ""
    Write-Host "Files prepared. SHA-256:" -ForegroundColor Cyan
    foreach ($asset in $assets) {
        Write-Host "$($asset.AssetName)  $($asset.Sha256)"
        Write-Host "Version: $($asset.Version) | Tag: $($asset.Tag)"
    }

    $confirm = (Read-Host "Create GitHub Release(s), upload assets, update manifest and push? (y/N)").Trim()
    if ($confirm -notin @("y", "Y", "yes", "YES")) {
        throw "Cancelled by user. No release or manifest was published."
    }

    foreach ($asset in $assets) {
        $title = if ($asset.Kind -eq "Mod") { "HassleMod $($asset.Version)" } else { "LumixX Launcher $($asset.Version)" }
        $notes = if ($asset.Kind -eq "Mod") { "LumixX mod release $($asset.Version)." } else { "LumixX Launcher release $($asset.Version)." }

        Write-Host ""
        Write-Host "Creating release $($asset.Tag)..." -ForegroundColor Cyan
        Invoke-Gh @("release", "create", $asset.Tag, $asset.StagePath, "--repo", $RepoSlug, "--title", $title, "--notes", $notes)

        $remoteAssetsOutput = & gh release view $asset.Tag --repo $RepoSlug --json assets --jq ".assets[].name" 2>&1
        $verifyExitCode = $LASTEXITCODE
        if ($verifyExitCode -ne 0) {
            throw "Release '$($asset.Tag)' was created, but GitHub asset verification failed: $($remoteAssetsOutput | Out-String)"
        }
        $remoteAssetNames = @($remoteAssetsOutput | ForEach-Object { "$_".Trim() })
        if ($remoteAssetNames -notcontains $asset.AssetName) {
            throw "Release '$($asset.Tag)' exists, but asset '$($asset.AssetName)' was not found."
        }
    }

    foreach ($asset in $assets) {
        $key = if ($asset.Kind -eq "Mod") { "mod" } else { "launcher" }
        $component = $manifest.$key
        $component.version = $asset.Version
        $component.file = $asset.AssetName
        $component.url = $asset.ReleaseUrl
        $component.sha256 = $asset.Sha256
    }
    $manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")

    $json = $manifest | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($ManifestPath, $json + [Environment]::NewLine, $Utf8NoBom)

    Invoke-Git @("add", "--", "manifest.json")
    & git diff --cached --quiet -- manifest.json
    if ($LASTEXITCODE -eq 0) {
        Write-Host "manifest.json did not change; nothing to commit." -ForegroundColor Yellow
    } else {
        Invoke-Git @("commit", "-m", "Publish LumixX update manifest")
        Invoke-Git @("push", "origin", $Branch)
    }

    Write-Host ""
    Write-Host "PUBLISH COMPLETE" -ForegroundColor Green
    Write-Host "Manifest: https://raw.githubusercontent.com/$RepoSlug/refs/heads/$Branch/manifest.json"
    Write-Host "Open releases: https://github.com/$RepoSlug/releases"
    foreach ($asset in $assets) {
        Write-Host "$($asset.AssetName): $($asset.ReleaseUrl)"
    }

    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "The manifest is only updated after all selected release assets have been uploaded and verified."
    exit 1
}
