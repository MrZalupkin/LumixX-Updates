# LumixX release publisher
# Windows PowerShell 5.1 compatible.
$ErrorActionPreference = "Stop"

$Owner = "MrZalupkin"
$RepoName = "LumixX-Updates"
$RepoSlug = "$Owner/$RepoName"
$Branch = "main"
$ManifestPath = Join-Path $PSScriptRoot "manifest.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Stop-WithError([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

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

    # Require a clone of the exact public repository.
    if (!(Test-Path (Join-Path $PSScriptRoot ".git"))) {
        throw "This folder is not a Git clone. Clone https://github.com/$RepoSlug.git, then put these two publisher files in the repository root."
    }

    $remote = (& git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Git remote 'origin' is missing."
    }
    $remote = ($remote | Out-String).Trim()
    $remoteOk = $remote -match '^(https://github\.com/MrZalupkin/LumixX-Updates(\.git)?|git@github\.com:MrZalupkin/LumixX-Updates(\.git)?)$'
    if (!$remoteOk) {
        throw "Unexpected origin remote: $remote"
    }

    $branch = (& git branch --show-current 2>$null | Out-String).Trim()
    if ($branch -ne $Branch) {
        throw "Switch to branch '$Branch' first. Current branch: '$branch'"
    }

    # Do not overwrite unrelated tracked work.
    & git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Tracked files have local changes. Commit or stash them before publishing."
    }
    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "The Git index contains staged changes. Commit or unstage them before publishing."
    }

    # Verify tools and GitHub authentication.
    if (!(Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git for Windows is not installed."
    }
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is missing. Install it with: winget install --id GitHub.cli"
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

    # Avoid accidental duplicate tags before uploading anything.
    $seenTags = @{}
    foreach ($asset in $assets) {
        if ($seenTags.ContainsKey($asset.Tag)) {
            throw "Duplicate release tag selected: $($asset.Tag)"
        }
        $seenTags[$asset.Tag] = $true

        & gh release view $asset.Tag --repo $RepoSlug *> $null
        if ($LASTEXITCODE -eq 0) {
            throw "Release tag '$($asset.Tag)' already exists. Choose a new version/tag."
        }
    }

    # Load or initialize manifest. Keep the unselected component intact.
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

    # Stage files with stable asset names. Hashes are computed from the exact staged bytes.
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
    }

    $confirm = (Read-Host "Create GitHub Release(s), upload assets, update manifest and push? (y/N)").Trim()
    if ($confirm -notin @("y", "Y", "yes", "YES")) {
        throw "Cancelled by user. No release or manifest was published."
    }

    # Create immutable release assets first. Do not update the manifest until all uploads verify.
    foreach ($asset in $assets) {
        $title = if ($asset.Kind -eq "Mod") { "HassleMod $($asset.Version)" } else { "LumixX Launcher $($asset.Version)" }
        $notes = if ($asset.Kind -eq "Mod") { "LumixX mod release $($asset.Version)." } else { "LumixX Launcher release $($asset.Version)." }

        Write-Host ""
        Write-Host "Creating release $($asset.Tag)..." -ForegroundColor Cyan
        Invoke-Gh @("release", "create", $asset.Tag, $asset.StagePath, "--repo", $RepoSlug, "--title", $title, "--notes", $notes)

        $remoteAssets = (& gh release view $asset.Tag --repo $RepoSlug --json assets --jq ".assets[].name" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $remoteAssets -notmatch [regex]::Escape($asset.AssetName)) {
            throw "Release was created but asset verification failed for $($asset.AssetName). Do not update manifest until the asset is visible."
        }
    }

    # Update only the selected manifest component(s).
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
    Write-Host "If a Release was created before an error, its asset may already be online. The manifest is only changed after upload verification."
    exit 1
}
