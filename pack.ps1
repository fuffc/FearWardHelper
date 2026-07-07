# Get the current script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$tocPath = Join-Path $scriptPath "FearWardHelper.toc"

# File list is read from the .toc itself so it can't drift out of sync
# (skip blank lines and ## directives). Keyed by the archive-relative path
# (the .toc line itself, e.g. "Libs\LibWidgets\LibWidgets.lua") so a
# vendored lib in a subfolder zips to the same relative path its own .toc
# reference expects at runtime, instead of being flattened to a bare filename.
# Normalized to forward slashes: the .toc is authored with Windows-style
# backslashes, but CI packs via `pwsh` on an Ubuntu runner, where Join-Path
# uses '/' -- comparing a literal '\'-separated .toc string against a
# Join-Path-built one further down silently fails there (a leading '/' isn't
# a leading '\', so TrimStart('\') is a no-op), which is how LibWidgets.lua
# ended up in the shipped zip twice. '/' also happens to be the only
# separator the zip format itself actually specifies.
$tocRelPaths = Get-Content $tocPath | Where-Object {
    $_.Trim() -ne "" -and -not $_.Trim().StartsWith("##")
} | ForEach-Object { ($_.Trim()) -replace '\\', '/' }

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
# shipping an incomplete zip). Archive paths are built by plain string
# concatenation with a literal '/', not Join-Path -- Join-Path would use '\'
# on Windows, and a zip entry name should use '/' regardless of the host OS
# packing it.
foreach ($rel in $entries.Keys) {
    $file = $entries[$rel]
    if (-not (Test-Path $file)) {
        throw "pack.ps1: file listed in FearWardHelper.toc not found: $file"
    }
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $file, "$folderName/$rel")
}

# Add textures directory recursively
if (Test-Path $texturesDir) {
    Get-ChildItem -Path $texturesDir -Recurse -File | ForEach-Object {
        $relativePath = (($_.FullName -replace [regex]::Escape($scriptPath), "") -replace '\\', '/').TrimStart('/')
        $archivePath = "$folderName/$relativePath"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $_.FullName, $archivePath)
    }
}

# A vendored lib under Libs\<name>\ ships its own manifest.ps1 declaring which
# files belong to it (its .lua files -- already .toc entries above -- plus its
# textures folder, which isn't a .toc entry). Packaging reads that manifest
# instead of a blind recursive copy of the lib's folder -- since that folder is
# a real git submodule, a blind copy would also sweep up its
# .git/.gitattributes/etc. Skip whatever's already a known entry (the .lua,
# added above via the .toc) to avoid a duplicate zip entry -- both sides of
# that comparison are normalized to '/' (see the .toc-reading comment above),
# so the check matches regardless of which OS is packing. The lookup path
# itself uses '/' too, not '\' -- '/' is a valid separator to the filesystem
# on both Windows and Linux, but Join-Path on Linux won't split an embedded
# '\' as a separator, so a literal "Libs\LibWidgets" child-path there would
# make Test-Path miss the real Libs/LibWidgets folder and silently skip this
# whole block (and ship a release zip with no LibWidgets textures) on CI.
$libWidgetsManifest = Join-Path $scriptPath "Libs/LibWidgets/manifest.ps1"
if (Test-Path $libWidgetsManifest) {
    . $libWidgetsManifest
    $libFiles = Get-LibWidgetsManifest -LibRoot (Join-Path $scriptPath "Libs/LibWidgets")
    foreach ($file in $libFiles) {
        if (-not (Test-Path $file)) {
            throw "pack.ps1: file listed in LibWidgets' manifest.ps1 not found: $file"
        }
        $relativePath = (($file -replace [regex]::Escape($scriptPath), "") -replace '\\', '/').TrimStart('/')
        if (-not $entries.ContainsKey($relativePath)) {
            $archivePath = "$folderName/$relativePath"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $file, $archivePath)
        }
    }
}

$ZipFile.Dispose()
