param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('TX', 'RX')]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]:\\?$')]
    [string]$Drive,

    [switch]$AllowFixedDrive,

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceDir = Join-Path $packageRoot "AES_GCM_$Role\sd_card"
$driveRoot = [System.IO.Path]::GetPathRoot($Drive)
$systemRoot = [System.IO.Path]::GetPathRoot($env:SystemRoot)
$payloadFiles = @(
    'BOOT.BIN',
    'boot.cmd',
    'boot.scr',
    'image.ub',
    'system.bit',
    'system.dtb',
    'README.md'
)
$copyFiles = $payloadFiles + 'SHA256SUMS'

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "SD source folder is missing: $sourceDir"
}
if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
    throw "Target drive not found: $driveRoot"
}
if ($driveRoot -eq $systemRoot) {
    throw "Refusing Windows system drive: $driveRoot"
}

$driveLetter = $driveRoot.Substring(0, 2)
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveLetter'"
if (-not $disk) {
    throw "Cannot inspect target drive: $driveRoot"
}
if ($disk.DriveType -ne 2 -and -not $AllowFixedDrive) {
    throw "Target is not reported as removable. Recheck the drive and use -AllowFixedDrive only if it is definitely the SD card."
}

Write-Host ("Target: {0} label='{1}' filesystem={2} size={3:N0} bytes" -f `
    $driveRoot, $disk.VolumeName, $disk.FileSystem, [uint64]$disk.Size)

$checksumFile = Join-Path $sourceDir 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    throw "Missing checksum file: $checksumFile"
}

$expected = @{}
foreach ($line in Get-Content -LiteralPath $checksumFile -Encoding ASCII) {
    if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$') {
        $expected[$matches[2].Trim()] = $matches[1].ToUpperInvariant()
    }
}
if ($expected.Count -ne $payloadFiles.Count) {
    throw "SHA256SUMS must contain exactly $($payloadFiles.Count) release entries."
}

foreach ($name in $payloadFiles) {
    $source = Join-Path $sourceDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing source file: $source"
    }
    if (-not $expected.ContainsKey($name)) {
        throw "SHA256SUMS has no entry for: $name"
    }
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($sourceHash -ne $expected[$name]) {
        throw "Source checksum mismatch: $name"
    }
}

if ($Clean) {
    $resolvedTarget = (Resolve-Path -LiteralPath $driveRoot).Path
    if ([System.IO.Path]::GetPathRoot($resolvedTarget) -ne $driveRoot) {
        throw "Resolved target is not the requested drive root: $resolvedTarget"
    }
    Write-Host "Cleaning existing user files from $driveRoot"
    Get-ChildItem -LiteralPath $driveRoot -Force | Where-Object {
        $_.Name -ne 'System Volume Information'
    } | Remove-Item -Recurse -Force
}

Write-Host "Copying complete $Role SD release to $driveRoot"
foreach ($name in $copyFiles) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $name) `
        -Destination (Join-Path $driveRoot $name) -Force
}

foreach ($name in $payloadFiles) {
    $copied = Join-Path $driveRoot $name
    $copiedHash = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
    if ($copiedHash -ne $expected[$name]) {
        throw "Copied file checksum mismatch: $copied"
    }
}
$sourceChecksumHash = (Get-FileHash -LiteralPath $checksumFile -Algorithm SHA256).Hash
$copiedChecksumHash = (Get-FileHash -LiteralPath (Join-Path $driveRoot 'SHA256SUMS') -Algorithm SHA256).Hash
if ($sourceChecksumHash -ne $copiedChecksumHash) {
    throw 'Copied SHA256SUMS mismatch.'
}

Write-Host "$Role SD release copied and SHA-256 verified." -ForegroundColor Green
