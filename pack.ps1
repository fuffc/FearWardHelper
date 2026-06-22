# Get the current script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$tocPath = Join-Path $scriptPath "FearWardHelper.toc"

# File list is read from the .toc itself so it can't drift out of sync
# (skip blank lines and ## directives).
$tocFiles = Get-Content $tocPath | Where-Object {
    $_.Trim() -ne "" -and -not $_.Trim().StartsWith("##")
} | ForEach-Object { Join-Path $scriptPath $_.Trim() }

$files = @($tocPath) + $tocFiles

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
foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        throw "pack.ps1: file listed in FearWardHelper.toc not found: $file"
    }
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $file, (Join-Path $folderName (Split-Path $file -Leaf)))
}

# Add textures directory recursively
if (Test-Path $texturesDir) {
    Get-ChildItem -Path $texturesDir -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName -replace [regex]::Escape($scriptPath), ""
        $archivePath = Join-Path $folderName $relativePath
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipFile, $_.FullName, $archivePath)
    }
}

$ZipFile.Dispose()
