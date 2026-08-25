[CmdletBinding()]
param(
    [string]$VivadoBat,

    [ValidateSet('Both', 'TX', 'RX')]
    [string]$Side = 'Both',

    [switch]$ProjectOnly,

    [switch]$CleanOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$packageRoot = $PSScriptRoot

function Resolve-VivadoExecutable {
    if ($VivadoBat) {
        if (-not (Test-Path -LiteralPath $VivadoBat -PathType Leaf)) {
            throw "Vivado executable not found: $VivadoBat"
        }
        return (Resolve-Path -LiteralPath $VivadoBat).Path
    }

    if ($env:XILINX_VIVADO) {
        $fromEnvironment = Join-Path $env:XILINX_VIVADO 'bin\vivado.bat'
        if (Test-Path -LiteralPath $fromEnvironment -PathType Leaf) {
            return (Resolve-Path -LiteralPath $fromEnvironment).Path
        }
    }

    $fromPath = Get-Command vivado.bat, vivado -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($fromPath) {
        return $fromPath.Source
    }

    throw 'Vivado was not found. Run from a Vivado 2025.2 command prompt, set XILINX_VIVADO, or pass -VivadoBat.'
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExtraArguments = @()
    )

    & robocopy.exe $Source $Destination @ExtraArguments | Out-Host
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

function Assert-XsaHasNoHostPath {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::OpenRead($Path)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        try {
            foreach ($entry in $archive.Entries) {
                if ([IO.Path]::GetExtension($entry.FullName) -in @('.bit', '.mmi', '.nts')) {
                    continue
                }
                $reader = [IO.StreamReader]::new($entry.Open())
                try {
                    $content = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
                if ($content -match '(?i)(?<![A-Za-z0-9+.-])[A-Z]:[\\/]' -or
                    $content -match '(?i)/mnt/[a-z]/') {
                    throw "Host path embedded in $Path entry $($entry.FullName)"
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Export-XsaEntry {
    param(
        [Parameter(Mandatory)][string]$XsaPath,
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($XsaPath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) {
            throw "$EntryName is missing from $XsaPath"
        }
        [IO.Compression.ZipFileExtensions]::ExtractToFile(
            $entry,
            $DestinationPath,
            $true
        )
    } finally {
        $archive.Dispose()
    }
}

function Remove-PackageGeneratedJunk {
    $xilDirectory = Join-Path $packageRoot '.Xil'
    if (Test-Path -LiteralPath $xilDirectory -PathType Container) {
        $resolvedXil = (Resolve-Path -LiteralPath $xilDirectory).Path
        if ((Split-Path -Parent $resolvedXil) -ne $packageRoot -or
            (Split-Path -Leaf $resolvedXil) -ne '.Xil') {
            throw "Refusing unsafe Vivado cleanup target: $resolvedXil"
        }
        Remove-Item -LiteralPath $resolvedXil -Recurse -Force
    }

    Get-ChildItem -LiteralPath $packageRoot -File | Where-Object {
        $_.Name -match '^vivado(?:_[0-9]+\.backup)?\.(?:jou|log)$'
    } | Remove-Item -Force
}

Remove-PackageGeneratedJunk
if ($CleanOnly) {
    Write-Host 'Top-level Vivado generated files removed.' -ForegroundColor Green
    return
}

$vivado = Resolve-VivadoExecutable
$versionText = (& $vivado -version 2>&1 | Out-String)
if ($versionText -notmatch 'Vivado\s+v2025\.2') {
    throw "Vivado 2025.2 is required. Detected:`n$versionText"
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workRoot = Join-Path $temporaryBase ('aes_gcm_vivado_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null

$driveLetter = $null
foreach ($code in ([int][char]'Z')..([int][char]'P')) {
    $candidate = [string][char]$code
    if (-not (Get-PSDrive -Name $candidate -ErrorAction SilentlyContinue)) {
        $driveLetter = $candidate
        break
    }
}
if (-not $driveLetter) {
    throw 'No unused drive letter is available for the temporary Vivado build.'
}

$mappedDrive = "${driveLetter}:"
$sides = if ($Side -eq 'Both') { @('TX', 'RX') } else { @($Side) }
$locationPushed = $false
try {
    foreach ($currentSide in $sides) {
        $source = Join-Path $packageRoot "AES_GCM_$currentSide\vivado"
        $destination = Join-Path $workRoot "AES_GCM_$currentSide\vivado"
        Invoke-Robocopy -Source $source -Destination $destination -ExtraArguments @(
            '/E', '/R:2', '/W:1', '/NJH', '/NJS',
            '/XD', 'project', 'artifacts', 'xsim.dir', 'xsim_work',
            '/XF', '*.log', '*.jou', '*.str'
        )
    }

    & subst.exe $mappedDrive $workRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map temporary build drive $mappedDrive"
    }

    Push-Location "$mappedDrive\"
    $locationPushed = $true

    $scripts = @()
    foreach ($currentSide in $sides) {
        $lowerSide = $currentSide.ToLowerInvariant()
        $scripts += "AES_GCM_$currentSide\vivado\tcl\build_aes_gcm_$lowerSide.tcl"
        if (-not $ProjectOnly) {
            $scripts += "AES_GCM_$currentSide\vivado\tcl\run_synth_impl.tcl"
        }
    }
    foreach ($relativeScript in $scripts) {
        $scriptPath = Join-Path "$mappedDrive\" $relativeScript
        Write-Host "Running $relativeScript"
        & $vivado -mode batch -notrace -source $scriptPath
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado failed: $relativeScript"
        }
    }

    if ($ProjectOnly) {
        foreach ($currentSide in $sides) {
            $prebuildXsa = Join-Path $workRoot "AES_GCM_$currentSide\vivado\artifacts\AES_GCM_${currentSide}_prebuild.xsa"
            Assert-XsaHasNoHostPath -Path $prebuildXsa
        }
        Write-Host 'Vivado project generation and prebuild XSA portability verified.' -ForegroundColor Green
    } else {
        foreach ($currentSide in $sides) {
            $artifactSource = Join-Path $workRoot "AES_GCM_$currentSide\vivado\artifacts"
            $artifactDestination = Join-Path $packageRoot "AES_GCM_$currentSide\vivado\artifacts"

            foreach ($report in Get-ChildItem -LiteralPath $artifactSource -Filter '*.rpt' -File) {
                $content = [IO.File]::ReadAllText($report.FullName)
                $content = [regex]::Replace(
                    $content,
                    '(?m)^\| Host\s+:.*$',
                    '| Host         : <BUILD_HOST>'
                )
                $content = [regex]::Replace(
                    $content,
                    '(?i)(?<![A-Za-z0-9+.-])[A-Z]:[\\/][^\r\n|"'']+',
                    '<HOST_PATH>'
                )
                [IO.File]::WriteAllText(
                    $report.FullName,
                    $content,
                    [Text.UTF8Encoding]::new($false)
                )
            }

            $xsa = Join-Path $artifactSource "AES_GCM_$currentSide.xsa"
            Assert-XsaHasNoHostPath -Path $xsa
            Export-XsaEntry -XsaPath $xsa -EntryName 'ps7_init.tcl' `
                -DestinationPath (Join-Path $artifactSource 'ps7_init.tcl')
            Invoke-Robocopy -Source $artifactSource -Destination $artifactDestination `
                -ExtraArguments @('/MIR', '/R:2', '/W:1', '/NJH', '/NJS')
        }

        Write-Host 'Vivado 2025.2 artifacts updated. Rebuild PetaLinux before deploying.' -ForegroundColor Green
    }
} finally {
    if ($locationPushed) {
        Pop-Location
    }
    if ($driveLetter -and (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue)) {
        & subst.exe $mappedDrive /D | Out-Null
    }

    $resolvedWork = [IO.Path]::GetFullPath($workRoot)
    $leaf = Split-Path -Leaf $resolvedWork
    if ($resolvedWork.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        $leaf.StartsWith('aes_gcm_vivado_', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    } else {
        throw "Refusing unsafe temporary cleanup target: $resolvedWork"
    }
    Remove-PackageGeneratedJunk
}
