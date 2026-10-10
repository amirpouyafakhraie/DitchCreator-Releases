param(
    [string]$PackagePath = '',
    [string]$Destination = '',
    [string]$CandidateRoot = (Join-Path $env:LOCALAPPDATA 'DitchCreator\Candidates'),
    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'DitchCreator\Packages'),
    [string]$ReleasesApiUrl = 'https://api.github.com/repos/amirpouyafakhraie/DitchCreator-Releases/releases',
    [switch]$Offline,
    [switch]$ValidateOnly,
    [switch]$NoRun,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$assetPattern = '^DitchCreator-v(\d+\.\d+\.\d+)-Release\.zip$'
$requiredFiles = @('Application/Ditch_Creator.exe', 'Application/Ditch_Creator.dll')

function Get-Version([string]$value) {
    if ($value -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid release version: $value" }
    return [version]::Parse($value)
}

function Select-Highest($options) {
    $top = @($options | Sort-Object -Property Version -Descending | Select-Object -First 1)
    if ($top.Count -eq 0) { return $null }
    $sameVersion = @($options | Where-Object { $_.Version -eq $top[0].Version })
    # Prefer the published package at an equal version so its commit identity is authoritative.
    $published = @($sameVersion | Where-Object { $_.Source -eq 'GitHub' })
    if ($published.Count -gt 0) { return $published[0] }
    $local = @($sameVersion | Where-Object { $_.Source -eq 'Package' })
    if ($local.Count -gt 0) { return $local[0] }
    return $sameVersion[0]
}

function Assert-SafePath([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.Contains(':') -or
        $name.StartsWith('/') -or $name -match '(^|/)(\.|\.\.)(/|$)' -or $name -match '[\x00-\x1f]') {
        throw "Unsafe package path: $name"
    }
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Read-Package([string]$path, [string]$expectedVersion = '') {
    $zip = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($path))
    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            Assert-SafePath $name.TrimEnd('/')
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Symbolic link: $name" }
            if (-not $name.EndsWith('/') -and -not $seen.Add($name)) { throw "Duplicate package path: $name" }
        }
        $manifestEntry = $zip.GetEntry('PACKAGE-MANIFEST.json')
        if ($null -eq $manifestEntry) { throw 'Missing PACKAGE-MANIFEST.json.' }
        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        $version = Get-Version ([string]$manifest.Version)
        if ($expectedVersion -and $version.ToString(3) -ne $expectedVersion) { throw 'Release asset and package versions differ.' }
        if ([string]$manifest.Commit -cnotmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid package commit.' }
        $files = @($manifest.Files)
        $declared = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $files) {
            $name = [string]$file.Path
            Assert-SafePath $name
            if (-not $declared.Add($name) -or $name -eq 'PACKAGE-MANIFEST.json') { throw "Duplicate manifest file: $name" }
            if ([string]$file.SHA256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA-256: $name" }
            $entry = $zip.GetEntry($name)
            if ($null -eq $entry) { throw "Missing package payload: $name" }
            $stream = $entry.Open()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($actual -ine [string]$file.SHA256) { throw "Package hash mismatch: $name" }
        }
        foreach ($name in $seen) {
            if ($name -ne 'PACKAGE-MANIFEST.json' -and -not $declared.Contains($name)) { throw "Unlisted package payload: $name" }
        }
        if ($seen.Count -ne $files.Count + 1) { throw 'Package file count mismatch.' }
        foreach ($name in $requiredFiles) {
            if (-not $declared.Contains($name)) { throw "Required application file missing: $name" }
        }
        return [pscustomobject]@{
            Version = $version; Commit = ([string]$manifest.Commit).ToLowerInvariant()
            Files = $files; Path = [System.IO.Path]::GetFullPath($path); Source = 'Package'
        }
    }
    finally { $zip.Dispose() }
}

function Test-Installed([string]$directory, [string]$expectedVersion = '', [string]$expectedCommit = '') {
    $manifestPath = Join-Path $directory 'PACKAGE-MANIFEST.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Installed manifest missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $version = Get-Version ([string]$manifest.Version)
    $commit = ([string]$manifest.Commit).ToLowerInvariant()
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Installed commit invalid.' }
    if (($expectedVersion -and $version.ToString(3) -ne $expectedVersion) -or
        ($expectedCommit -and $commit -ne $expectedCommit)) { throw 'Installed identity mismatch.' }
    $root = [System.IO.Path]::GetFullPath($directory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $declared = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($manifest.Files)) {
        $name = [string]$file.Path
        Assert-SafePath $name
        if (-not $declared.Add($name)) { throw "Duplicate installed path: $name" }
        $target = [System.IO.Path]::GetFullPath((Join-Path $root $name))
        if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed path escaped destination.' }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Installed file missing: $name" }
        if ([string]$file.SHA256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
            (Get-FileSha256 $target) -ine [string]$file.SHA256) { throw "Installed hash mismatch: $name" }
    }
    foreach ($name in $requiredFiles) {
        if (-not $declared.Contains($name)) { throw "Required installed file missing: $name" }
    }
    $dll = Join-Path $directory 'Application\Ditch_Creator.dll'
    $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
    if ($fileVersion -ne ($version.ToString(3) + '.0')) { throw "Installed application version mismatch: $fileVersion" }
    return [pscustomobject]@{ Version = $version; Commit = $commit; Path = [IO.Path]::GetFullPath($directory); Source = 'Installed' }
}

function Get-InstalledCandidates([string]$root) {
    $result = @()
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $result }
    foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if ($versionDirectory.Name -notmatch '^\d+\.\d+\.\d+$') { continue }
        foreach ($candidateDirectory in @(Get-ChildItem -LiteralPath $versionDirectory.FullName -Directory)) {
            try {
                $candidate = Test-Installed $candidateDirectory.FullName $versionDirectory.Name
                if ($candidateDirectory.Name -ne $candidate.Commit -and
                    -not $candidateDirectory.Name.StartsWith(($candidate.Commit + '-repair-'), [StringComparison]::OrdinalIgnoreCase)) { continue }
                $result += $candidate
            }
            catch { Write-Warning "Ignoring invalid installed candidate $($candidateDirectory.FullName): $_" }
        }
    }
    return $result
}

function Get-ReleaseAssets([string]$apiUrl) {
    $headers = @{ 'User-Agent' = 'DitchCreator-Latest-Updater'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $result = @()
    for ($page = 1; $page -le 100; $page++) {
        $separator = if ($apiUrl.Contains('?')) { '&' } else { '?' }
        $releases = @(Invoke-RestMethod -Uri ($apiUrl + $separator + 'per_page=100&page=' + $page) -Headers $headers -TimeoutSec 20)
        foreach ($release in $releases) {
            if ($release.draft -or [string]$release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
            $releaseVersion = $Matches[1]
            foreach ($asset in @($release.assets)) {
                if ([string]$asset.name -cnotmatch $assetPattern -or $Matches[1] -ne $releaseVersion) { continue }
                if ([string]$asset.browser_download_url -notmatch '^https://') { continue }
                $result += [pscustomobject]@{
                    Version = Get-Version $releaseVersion; Url = [string]$asset.browser_download_url
                    Name = [string]$asset.name; Digest = [string]$asset.digest; ApiUrl = [string]$asset.url
                    Prerelease = [bool]$release.prerelease
                }
            }
        }
        if ($releases.Count -lt 100) { break }
    }
    return $result
}

function Get-ReleasePackage($asset, [string]$cacheRoot) {
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $cached = Join-Path $cacheRoot $asset.Name
    if (Test-Path -LiteralPath $cached -PathType Leaf) {
        try {
            $package = Read-Package $cached $asset.Version.ToString(3)
            if ($asset.Digest -match '^sha256:([0-9a-fA-F]{64})$' -and (Get-FileSha256 $cached) -ine $Matches[1]) {
                throw 'Cached ZIP differs from the GitHub asset digest.'
            }
            Write-Host "Validated cached package: $cached"
            return $package
        }
        catch {
            $preserved = $cached + '.invalid-' + [guid]::NewGuid().ToString('N')
            Move-Item -LiteralPath $cached -Destination $preserved
            Write-Warning "Preserved corrupt cache at $preserved; downloading again. $_"
        }
    }
    $partial = $cached + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        Write-Host "Downloading $($asset.Name)..."
        $headers = @{ 'User-Agent' = 'DitchCreator-Latest-Updater' }
        $downloadUrl = $asset.Url
        if ($env:GITHUB_TOKEN) {
            $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
            $headers['Accept'] = 'application/octet-stream'
            $downloadUrl = $asset.ApiUrl
        }
        Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $partial -TimeoutSec 120 -UseBasicParsing | Out-Null
        $package = Read-Package $partial $asset.Version.ToString(3)
        if ($asset.Digest -match '^sha256:([0-9a-fA-F]{64})$' -and (Get-FileSha256 $partial) -ine $Matches[1]) {
            throw 'Downloaded ZIP differs from the GitHub asset digest.'
        }
        Move-Item -LiteralPath $partial -Destination $cached
        return (Read-Package $cached $asset.Version.ToString(3))
    }
    finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}

function Install-Package($package, [string]$root, [string]$destination) {
    if ([string]::IsNullOrWhiteSpace($destination)) {
        $destination = Join-Path (Join-Path $root $package.Version.ToString(3)) $package.Commit
    }
    if (Test-Path -LiteralPath $destination) {
        try {
            Write-Host 'Candidate already installed. Validating existing candidate...'
            $candidate = Test-Installed $destination $package.Version.ToString(3) $package.Commit
            Write-Host 'Already installed and fully validated.'
            return $candidate
        }
        catch {
            Write-Warning "Existing candidate is invalid and will be preserved: $destination. $_"
            $destination += '-repair-' + [guid]::NewGuid().ToString('N')
        }
    }
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $staging = Join-Path $parent ('.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Host 'Installing...'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($package.Path, $staging)
        $candidate = Test-Installed $staging $package.Version.ToString(3) $package.Commit
        if (Test-Path -LiteralPath $destination) { throw "Destination became occupied: $destination" }
        Move-Item -LiteralPath $staging -Destination $destination
        $candidate = Test-Installed $destination $package.Version.ToString(3) $package.Commit
        Write-Host 'Post-install validation passed.'
        return $candidate
    }
    finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
}

try {
    if ($SelfTest) {
        $ordered = @('1.0.9', '1.0.10', '1.0.25', '1.0.26', '1.1.0', '2.0.0') |
            ForEach-Object { Get-Version $_ } | Sort-Object -Descending
        if (($ordered | ForEach-Object { $_.ToString(3) }) -join ',' -ne '2.0.0,1.1.0,1.0.26,1.0.25,1.0.10,1.0.9') {
            throw 'Semantic version ordering failed.'
        }
        $choice = Select-Highest @(
            [pscustomobject]@{ Version = Get-Version '1.0.26'; Source = 'Installed' },
            [pscustomobject]@{ Version = Get-Version '1.0.25'; Source = 'Package' }
        )
        if ($choice.Source -ne 'Installed') { throw 'Offline no-downgrade selection failed.' }
        Write-Host 'Semantic version ordering and offline no-downgrade selection passed.'
        exit 0
    }
    $installed = @(Get-InstalledCandidates $CandidateRoot)
    $localPackages = @()
    $paths = @()
    if ($PackagePath) { $paths += $PackagePath }
    else { $paths += @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'DitchCreator-v*-Release.zip' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) }
    foreach ($path in $paths) {
        try {
            if ([IO.Path]::GetFileName($path) -cnotmatch $assetPattern) { throw 'Local ZIP name does not follow the release contract.' }
            $localPackages += Read-Package $path $Matches[1]
        }
        catch { Write-Warning "Ignoring invalid local package $path`: $_" }
    }
    $selectedPackage = $null
    if (-not $Offline) {
        try {
            Write-Host 'Checking GitHub Releases...'
            $assets = @(Get-ReleaseAssets $ReleasesApiUrl)
            $normal = @($assets | Where-Object { -not $_.Prerelease })
            if ($normal.Count -gt 0) { $assets = $normal }
            $latest = $assets | Sort-Object -Property Version -Descending | Select-Object -First 1
            if ($null -ne $latest) {
                Write-Host "Latest release: v$($latest.Version.ToString(3))"
                $selectedPackage = Get-ReleasePackage $latest $CacheRoot
                $selectedPackage.Source = 'GitHub'
                Write-Host "Validated Ditch Creator $($selectedPackage.Version.ToString(3)) candidate $($selectedPackage.Commit)."
            }
            else { Write-Warning 'No valid GitHub Release asset was found.' }
        }
        catch { Write-Warning "GitHub release discovery/download unavailable: $_" }
    }
    else { Write-Host 'Offline mode: using local packages and validated installed candidates.' }
    $options = @($installed) + @($localPackages)
    if ($null -ne $selectedPackage) { $options += $selectedPackage }
    $chosen = Select-Highest $options
    if ($null -eq $chosen) { throw 'No valid GitHub release, local package, or installed candidate is available.' }
    if ($chosen.Source -eq 'Installed') {
        $candidate = Test-Installed $chosen.Path $chosen.Version.ToString(3) $chosen.Commit
        Write-Host "Using validated installed Ditch Creator $($candidate.Version.ToString(3)) $($candidate.Commit)."
    }
    else {
        if ($ValidateOnly) {
            Write-Host "Package validation passed: $($chosen.Version.ToString(3)) $($chosen.Commit)."
            exit 0
        }
        $candidate = Install-Package $chosen $CandidateRoot $Destination
    }
    if ($ValidateOnly -or $NoRun) { exit 0 }
    $exe = Join-Path $candidate.Path 'Application\Ditch_Creator.exe'
    Write-Host 'Launching Ditch Creator...'
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    exit 0
}
catch {
    Write-Error "Ditch Creator update failed: $_"
    exit 1
}

