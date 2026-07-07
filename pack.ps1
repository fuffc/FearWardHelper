# Get the current script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$tocPath = Join-Path $scriptPath "FearWardHelper.toc"

# File list is read from the .toc itself so it can't drift out of sync
# (skip blank lines and ## directives). Keyed by the archive-relative path
# (the .toc line itself, e.g. "Libs\LibWidgets\LibWidgets.lua") so a
# vendored lib in a subfolder zips to the same relative path its own .toc
# reference expects at runtime, instead of being flattened to a bare filename.
$tocRelPaths = Get-Content $tocPath | Where-Object {
    $_.Trim() -ne "" -and -not $_.Trim().StartsWith("##")
} | ForEach-Object { $_.Trim() }

$entries = @{ (Split-Path $tocPath -Leaf) = $tocPath }
foreach ($rel in $tocRelPaths) {
    $entries[$rel] = Join-Path $scriptPath $rel
}

$texturesDir = Join-Path $scriptPath "textures"
$zipFilePath = Join-Path $scriptPath "FearWardHelper.zip"

# Specify the folder name inside the zip archive
$folderName = "FearWardHelper"

Add-Type -assembly 'System.IO.Compression'
Add-Type -assembly 'System.IO.Compression.FileSystem'

# Check if the zip file already exists and delete it
if (Test-Path $zipFilePath) {
    Remove-Item $zipFilePath -Force
}

[System.IO.Compression.ZipArchive]$ZipFile = [System.IO.Compression.ZipFile]::Open($zipFilePath, ([System.IO.Compression.ZipArchiveMode]::Update))

# Add individual files (fail loudly on a stale .toc entry rather than silently
# shipping an incomplete zip)
foreach ($rel in $entries.Keys) {
    $file = $entries[$rel]
    if (-not (Test-Path $file)) {
        throw "pack.ps1: file listed in FearWardHelper.toc not found: $file"
    }
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $file, (Join-Path $folderName $rel))
}

# Add textures directory recursively
if (Test-Path $texturesDir) {
    Get-ChildItem -Path $texturesDir -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName -replace [regex]::Escape($scriptPath), ""
        $archivePath = Join-Path $folderName $relativePath
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $_.FullName, $archivePath)
    }
}

# A vendored lib under Libs\<name>\ ships its own manifest.ps1 declaring which
# files belong to it (its .lua files -- already .toc entries above -- plus its
# textures folder, which isn't a .toc entry). Packaging reads that manifest
# instead of a blind recursive copy of the lib's folder -- since that folder is
# a real git submodule, a blind copy would also sweep up its
# .git/.gitattributes/etc. Skip whatever's already a known entry (the .lua,
# added above via the .toc) to avoid a duplicate zip entry.
$libWidgetsManifest = Join-Path $scriptPath "Libs\LibWidgets\manifest.ps1"
if (Test-Path $libWidgetsManifest) {
    . $libWidgetsManifest
    $libFiles = Get-LibWidgetsManifest -LibRoot (Join-Path $scriptPath "Libs\LibWidgets")
    foreach ($file in $libFiles) {
        if (-not (Test-Path $file)) {
            throw "pack.ps1: file listed in LibWidgets' manifest.ps1 not found: $file"
        }
        $relativePath = ($file -replace [regex]::Escape($scriptPath), "").TrimStart('\')
        if (-not $entries.ContainsKey($relativePath)) {
            $archivePath = Join-Path $folderName $relativePath
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $file, $archivePath)
        }
    }
}

$ZipFile.Dispose()
