[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:CheckCount = 0
$script:HashCache = @{}

function Get-ReleasePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    return Join-Path $PSScriptRoot ($RelativePath -replace '/', '\')
}

function Add-Check {
    $script:CheckCount = $script:CheckCount + 1
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $Quiet) {
        Write-Host "[PASS] $Message"
    }
}

function Assert-Directory {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $path = Get-ReleasePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Missing directory: $Label ($RelativePath)"
    }
    Add-Check
}

function Assert-File {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $path = Get-ReleasePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing file: $Label ($RelativePath)"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
        throw "Empty file: $Label ($RelativePath)"
    }
    Add-Check
}

function Get-CachedSha256 {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Get-ReleasePath $RelativePath
    $key = [IO.Path]::GetFullPath($path).ToLowerInvariant()
    if (-not $script:HashCache.ContainsKey($key)) {
        $script:HashCache[$key] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $script:HashCache[$key]
}

function Assert-SameHash {
    param(
        [Parameter(Mandatory)][string[]]$RelativePaths,
        [Parameter(Mandatory)][string]$Label
    )
    if ($RelativePaths.Count -lt 2) {
        throw "Internal verifier error: $Label needs at least two files"
    }
    $referenceHash = Get-CachedSha256 $RelativePaths[0]
    foreach ($relativePath in $RelativePaths[1..($RelativePaths.Count - 1)]) {
        if ((Get-CachedSha256 $relativePath) -ne $referenceHash) {
            throw "Hash mismatch: $Label"
        }
    }
    Add-Check
    Write-Detail $Label
}

function Assert-TextContains {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string[]]$RequiredText,
        [Parameter(Mandatory)][string]$Label
    )
    $content = Get-Content -LiteralPath (Get-ReleasePath $RelativePath) -Raw -Encoding UTF8
    foreach ($text in $RequiredText) {
        if (-not $content.Contains($text)) {
            throw "Missing reference in ${Label}: $text"
        }
    }
    Add-Check
    Write-Detail $Label
}

function Assert-TextDoesNotContain {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string[]]$ForbiddenText,
        [Parameter(Mandatory)][string]$Label
    )
    $path = Get-ReleasePath $RelativePath
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($text in $ForbiddenText) {
        if ($content.Contains($text)) {
            throw "$Label unexpectedly contains '$text': $RelativePath"
        }
    }
    Add-Check
}

function Assert-NoHostPathDependencies {
    $textExtensions = @(
        '.bb', '.bbappend', '.bif', '.c', '.cfg', '.cmd', '.coe', '.conf',
        '.dtsi', '.h', '.inc', '.json', '.md', '.patch', '.ps1', '.rpt',
        '.sh', '.sv', '.tcl', '.txt', '.v', '.vhd', '.xdc', '.xci', '.xml'
    )
    $hostPathPattern = [regex]::new(
        '(?i)(?<![A-Za-z0-9+.-])[A-Z]:[\\/]|/mnt/[a-z]/'
    )

    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse) {
        if ($file.Extension.ToLowerInvariant() -notin $textExtensions -and
            $file.Name -notin @('Makefile', 'Kconfig')) {
            continue
        }
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $match = $hostPathPattern.Match($content)
        if ($match.Success) {
            $relative = $file.FullName.Substring($PSScriptRoot.Length).TrimStart('\')
            throw "Host-specific path or hostname remains in ${relative}: $($match.Value)"
        }
    }

    Add-Check
    Write-Detail 'Text sources contain no host-specific absolute paths'
}

function Assert-XsaPortable {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )

    Add-Type -AssemblyName System.IO.Compression
    $path = Get-ReleasePath $RelativePath
    $stream = [IO.File]::OpenRead($path)
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
                    throw "$Label contains a host path in archive entry $($entry.FullName)"
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    Add-Check
    Write-Detail "$Label has no embedded host path"
}

function Assert-SdBootCommand {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName
    )

    $expectedLines = @(
        "echo Booting AES_GCM_$SideName from SD",
        'setenv bootargs console=ttyPS0,115200 earlycon root=/dev/ram0 rw mem=384M',
        'setenv bootm_low 0x00000000',
        'setenv bootm_size 0x18000000',
        'setenv initrd_high 0x16ffffff',
        'setenv fdt_high 0x17ffffff',
        'fatload mmc 0:1 0x10000000 image.ub',
        'bootm 0x10000000:kernel-1 0x10000000:ramdisk-1 0x00100000'
    )
    $actualLines = @(
        Get-Content -LiteralPath (Get-ReleasePath "$SideRoot/sd_card/boot.cmd") -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ([string]::Join("`n", $actualLines) -cne [string]::Join("`n", $expectedLines)) {
        throw "$SideName boot.cmd differs from the fixed SD boot command"
    }
    Add-Check
    Write-Detail "$SideName SD boot.cmd fixed memory/load addresses"
}

function Assert-BootScriptPayload {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName
    )

    $commandBytes = [IO.File]::ReadAllBytes(
        (Get-ReleasePath "$SideRoot/sd_card/boot.cmd")
    )
    $scriptBytes = [IO.File]::ReadAllBytes(
        (Get-ReleasePath "$SideRoot/sd_card/boot.scr")
    )
    if ($scriptBytes.Length -lt 72) {
        throw "$SideName boot.scr is too short for a U-Boot script image"
    }

    $magic = [uint32][Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($scriptBytes, 0)
    )
    $payloadLength = [uint32][Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($scriptBytes, 64)
    )
    $lengthTerminator = [uint32][Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($scriptBytes, 68)
    )
    if ($magic -ne 0x27051956 -or $scriptBytes[30] -ne 6 -or
        $lengthTerminator -ne 0 -or $payloadLength -ne $commandBytes.Length) {
        throw "$SideName boot.scr has an invalid U-Boot script header"
    }

    $paddingLength = $scriptBytes.Length - 72 - [int]$payloadLength
    if ($paddingLength -lt 0 -or $paddingLength -gt 3) {
        throw "$SideName boot.scr payload length is invalid"
    }
    $payloadBytes = New-Object byte[] ([int]$payloadLength)
    [Array]::Copy($scriptBytes, 72, $payloadBytes, 0, [int]$payloadLength)
    if ([Convert]::ToBase64String($payloadBytes) -cne
        [Convert]::ToBase64String($commandBytes)) {
        throw "$SideName boot.scr payload differs from boot.cmd"
    }
    for ($index = 72 + [int]$payloadLength; $index -lt $scriptBytes.Length; $index++) {
        if ($scriptBytes[$index] -ne 0) {
            throw "$SideName boot.scr has non-zero trailing data"
        }
    }

    Add-Check
    Write-Detail "$SideName boot.scr payload equals boot.cmd"
}

function Assert-BootBinLayout {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName
    )

    $bootgen = Get-Command bootgen, bootgen.bat, bootgen.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $bootgen) {
        Write-Warning "$SideName BOOT.BIN layout skipped: bootgen was not found; build_petalinux.sh must enforce the four-image layout."
        return
    }

    $oldLocation = Get-Location
    try {
        Set-Location -LiteralPath (Get-ReleasePath "$SideRoot/sd_card")
        $output = (& $bootgen.Source -arch zynq -read BOOT.BIN 2>&1 | Out-String)
    } finally {
        Set-Location -LiteralPath $oldLocation.Path
    }

    if ($output -notmatch 'total_images\s+\(0x04\)\s*:\s*0x00000004') {
        throw "$SideName BOOT.BIN does not contain exactly four images"
    }
    foreach ($imageName in @('zynq_fsbl.elf', 'system.bit', 'u-boot.elf', 'system.dtb')) {
        if ($output -notmatch [regex]::Escape("IMAGE HEADER ($imageName)")) {
            throw "$SideName BOOT.BIN is missing image: $imageName"
        }
    }
    if ($output -notmatch '(?s)PARTITION HEADER TABLE \(system\.dtb\.0\).*?load_addr \(0x0c\)\s*:\s*0x00100000') {
        throw "$SideName BOOT.BIN system.dtb load address is not 0x00100000"
    }

    Add-Check
    Write-Detail "$SideName BOOT.BIN four-image layout and DTB load address"
}

function Assert-SdChecksums {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName
    )
    $expectedNames = @(
        'BOOT.BIN', 'boot.cmd', 'boot.scr', 'image.ub',
        'system.bit', 'system.dtb', 'README.md'
    )
    $expectedSdNames = @($expectedNames + 'SHA256SUMS') | Sort-Object
    $sdEntries = @(Get-ChildItem -LiteralPath (Get-ReleasePath "$SideRoot/sd_card") -Force)
    $actualSdNames = @($sdEntries | Select-Object -ExpandProperty Name | Sort-Object)
    $difference = @(Compare-Object -ReferenceObject $expectedSdNames `
        -DifferenceObject $actualSdNames -CaseSensitive)
    if ($sdEntries.Count -ne 8 -or $sdEntries.Where({ $_.PSIsContainer }).Count -ne 0 -or
        $difference.Count -ne 0) {
        throw "$SideName sd_card must contain exactly 8 release files; found: $($actualSdNames -join ', ')"
    }
    Add-Check
    Write-Detail "$SideName SD file set: exact 8/8"

    $checksumRelative = "$SideRoot/sd_card/SHA256SUMS"
    $lines = @(Get-Content -LiteralPath (Get-ReleasePath $checksumRelative) -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne 7) {
        throw "$SideName SHA256SUMS must contain exactly 7 entries"
    }

    $entries = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^(?<hash>[0-9A-Fa-f]{64})\s+[*]?(?<name>.+?)\s*$') {
            throw "$SideName SHA256SUMS contains an invalid line"
        }
        $name = $Matches['name']
        if ($entries.ContainsKey($name)) {
            throw "$SideName SHA256SUMS contains a duplicate entry: $name"
        }
        if ($expectedNames -cnotcontains $name) {
            throw "$SideName SHA256SUMS contains an unexpected entry: $name"
        }
        $entries[$name] = $Matches['hash'].ToLowerInvariant()
    }

    foreach ($name in $expectedNames) {
        if (-not $entries.ContainsKey($name)) {
            throw "$SideName SHA256SUMS is missing: $name"
        }
        $relativePath = "$SideRoot/sd_card/$name"
        if ((Get-CachedSha256 $relativePath) -ne $entries[$name]) {
            throw "$SideName SHA256SUMS mismatch: $name"
        }
    }
    Add-Check
    Write-Detail "$SideName SD SHA256SUMS: 7/7"
}

function Assert-SessionStaging {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName,
        [Parameter(Mandatory)][object[]]$Mappings
    )
    $stagingRelative = "$SideRoot/petalinux/project-spec/meta-user/recipes-apps/aes-session-agent/files"
    Assert-Directory $stagingRelative "$SideName session recipe staging"

    $actualNames = Get-ChildItem -LiteralPath (Get-ReleasePath $stagingRelative) -File |
        Select-Object -ExpandProperty Name | Sort-Object
    $expectedNames = $Mappings | ForEach-Object { $_.StageName } | Sort-Object
    $difference = Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames
    if ($difference) {
        throw "$SideName session recipe staging file set differs from session_control"
    }
    Add-Check

    foreach ($mapping in $Mappings) {
        $staged = "$stagingRelative/$($mapping.StageName)"
        Assert-File $mapping.Canonical "$SideName canonical session file $($mapping.StageName)"
        Assert-File $staged "$SideName staged session file $($mapping.StageName)"
        Assert-SameHash -RelativePaths @($mapping.Canonical, $staged) `
            -Label "$SideName session staging matches: $($mapping.StageName)"
    }
    Write-Detail "$SideName canonical session_control staging"
}

function Assert-WiredNetworkPolicy {
    param(
        [Parameter(Mandatory)][string]$SideRoot,
        [Parameter(Mandatory)][string]$SideName,
        [Parameter(Mandatory)][string]$Address
    )

    $recipeRoot = "$SideRoot/petalinux/project-spec/meta-user/recipes-core/init-ifupdown"
    $appendRelative = "$recipeRoot/init-ifupdown_%.bbappend"
    $interfacesRelative = "$recipeRoot/files/interfaces"
    Assert-File $appendRelative "$SideName init-ifupdown override"
    Assert-File $interfacesRelative "$SideName role-specific network policy"
    Assert-TextContains `
        -RelativePath $appendRelative `
        -RequiredText @('FILESEXTRAPATHS:prepend := "${THISDIR}/files:"') `
        -Label "$SideName init-ifupdown file override"

    $content = Get-Content -LiteralPath (Get-ReleasePath $interfacesRelative) -Raw -Encoding UTF8
    foreach ($required in @(
        'auto /en*=eth',
        'iface eth inet static',
        "address $Address",
        'netmask 255.255.255.0',
        'network 10.10.15.0'
    )) {
        if (-not $content.Contains($required)) {
            throw "$SideName wired network policy is missing: $required"
        }
    }

    foreach ($forbidden in @(
        '(?m)^\s*iface\s+(?:eth\d*|en\S*)\s+inet\s+dhcp\s*$',
        '(?m)^\s*auto\s+eth\d+\s*$'
    )) {
        if ($content -match $forbidden) {
            throw "$SideName wired network policy still allows generic wired DHCP: $($Matches[0].Trim())"
        }
    }

    Add-Check
    Write-Detail "$SideName wired Ethernet is role-static at $Address with no generic DHCP"
}

function Write-ImportantHash {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if (-not $Quiet) {
        Write-Host "[HASH] $Label $(Get-CachedSha256 $RelativePath)"
    }
}

$commonRtl = @(
    'aes256_gcm/aes256_iterative_core.sv',
    'aes256_gcm/aes256_key_expansion.sv',
    'aes256_gcm/aes256_key_transform.sv',
    'aes256_gcm/aes_addroundkey.sv',
    'aes256_gcm/aes_key_rcon_pkg.sv',
    'aes256_gcm/aes_mixcolumns.sv',
    'aes256_gcm/aes_next_round_key.sv',
    'aes256_gcm/aes_round.sv',
    'aes256_gcm/aes_sbox_pkg.sv',
    'aes256_gcm/aes_shiftrows.sv',
    'aes256_gcm/aes_subbytes.sv',
    'aes256_gcm/aes_subword32.sv',
    'aes256_gcm/gcm_protocol_pkg.sv',
    'aes256_gcm/ghash_mul16.sv',
    'session/aes_session_key_regs.sv',
    'session/aes_session_key_regs_bd.v'
)

$sessionCommon = @(
    [pscustomobject]@{ StageName = 'aes-session-check';    Canonical = 'session_control/aes-session-check' },
    [pscustomobject]@{ StageName = 'aes-session-wifi';     Canonical = 'session_control/aes-session-wifi' },
    [pscustomobject]@{ StageName = 'aes_session_agent.c';  Canonical = 'session_control/aes_session_agent.c' },
    [pscustomobject]@{ StageName = 'aes_session_regs.c';   Canonical = 'session_control/aes_session_regs.c' },
    [pscustomobject]@{ StageName = 'aes_session_regs.h';   Canonical = 'session_control/aes_session_regs.h' },
    [pscustomobject]@{ StageName = 'ecdh_session_crypto.c'; Canonical = 'session_control/ecdh_session_crypto.c' },
    [pscustomobject]@{ StageName = 'ecdh_session_crypto.h'; Canonical = 'session_control/ecdh_session_crypto.h' },
    [pscustomobject]@{ StageName = 'wpa.conf';             Canonical = 'session_control/wpa.conf' }
)

$configs = @(
    [pscustomobject]@{
        Name = 'TX'
        Root = 'AES_GCM_TX'
        BitName = 'AES_GCM_TX.bit'
        XsaName = 'AES_GCM_TX.xsa'
        JtagFsblName = 'fsbl.elf'
        WiredAddress = '10.10.15.2'
        TclFiles = @(
            'vivado/tcl/build_aes_gcm_tx.tcl',
            'vivado/tcl/run_synth_impl.tcl',
            'vivado/tcl/AES_GCM_TX_bd.tcl',
            'vivado/tcl/pcam_system_yuv422_base_bd.tcl'
        )
        RtlFiles = $commonRtl + @(
            'aes256_gcm/video_aes_gcm_tx_top.sv',
            'tx/axis_gcm_tx_frame_processor_v1.sv',
            'tx/axis_gcm_tx_frame_processor_bd.v',
            'video/axis_video16_to_frame128.sv',
            'video/axis_video16_to_frame128_bd.v',
            'video/axis_frame128_to_video16.sv',
            'video/axis_frame128_to_video16_bd.v',
            'video/axis_metadata_bram_writer.v',
            'video/axis_video_aes_gcm_switch_bd.v',
            'video/metadata_status_cdc.v'
        )
        SessionMappings = $sessionCommon + @(
            [pscustomobject]@{ StageName = 'aes-session-tx.init'; Canonical = 'session_control/aes-session-tx.init' },
            [pscustomobject]@{ StageName = 'tx-demo-private.pem'; Canonical = 'session_control/keys/tx-demo-private.pem' },
            [pscustomobject]@{ StageName = 'rx-demo-public.pem'; Canonical = 'session_control/keys/rx-demo-public.pem' }
        )
    },
    [pscustomobject]@{
        Name = 'RX'
        Root = 'AES_GCM_RX'
        BitName = 'AES_GCM_RX.bit'
        XsaName = 'AES_GCM_RX.xsa'
        JtagFsblName = 'zynq_fsbl.elf'
        WiredAddress = '10.10.15.3'
        TclFiles = @(
            'vivado/tcl/build_aes_gcm_rx.tcl',
            'vivado/tcl/run_synth_impl.tcl',
            'vivado/tcl/AES_GCM_RX_bd.tcl'
        )
        RtlFiles = $commonRtl + @(
            'aes256_gcm/video_aes_gcm_rx_top.sv',
            'aes256_gcm/packet_buffer_bram.sv',
            'rx/gcm_rx_error_detector.sv',
            'rx/axis_gcm_rx_frame_processor_v2.sv',
            'rx/axis_gcm_rx_frame_processor_bd.v',
            'video/axis_yuyv32_to_rgb24.v',
            'video/hdmi_status_pack.v',
            'video/video_timing_720p.v'
        )
        SessionMappings = $sessionCommon + @(
            [pscustomobject]@{ StageName = 'aes-session-rx.init'; Canonical = 'session_control/aes-session-rx.init' },
            [pscustomobject]@{ StageName = 'rx-demo-private.pem'; Canonical = 'session_control/keys/rx-demo-private.pem' },
            [pscustomobject]@{ StageName = 'tx-demo-public.pem'; Canonical = 'session_control/keys/tx-demo-public.pem' }
        )
    }
)

try {
    foreach ($relative in @(
        'build_vivado_both.ps1',
        'build_petalinux_both.sh',
        'verify_release.ps1'
    )) {
        Assert-File $relative 'portable top-level release file'
    }
    $rootReadmes = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'README_*.md' -File)
    if ($rootReadmes.Count -ne 1 -or $rootReadmes[0].Length -le 0) {
        throw 'Exactly one non-empty top-level README_*.md is required'
    }
    Add-Check
    $sdCopyScripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'SD*.ps1' -File)
    if ($sdCopyScripts.Count -ne 1 -or $sdCopyScripts[0].Length -le 0) {
        throw 'Exactly one non-empty top-level SD*.ps1 copy script is required'
    }
    Add-Check
    Assert-NoHostPathDependencies

    foreach ($relative in @(
        'PC_RX_UI/server.py',
        'PC_RX_UI/run_pc_ui.bat',
        'PC_RX_UI/web/index.html',
        'PC_RX_UI/web/app.js',
        'PC_RX_UI/web/styles.css',
        'PC_RX_UI/web/normal-flow/index.html',
        'PC_RX_UI/web/normal-flow/embed.css',
        'PC_RX_UI/pc_rx_ui.env.example.cmd',
        'PC_RX_UI/README.md',
        'Jetson_Dashboard/index.html',
        'Jetson_Dashboard/assets/index-CIKfsJA1.js',
        'Jetson_Dashboard/assets/index-CIKfsJA1.js.pre-role-split-20260811',
        'Jetson_Dashboard/backend/server.py',
        'Jetson_Dashboard/operator/start-dashboard.sh',
        'Jetson_Dashboard/README.md',
        'docs/2026-08-11_RX_5detector_PC_UI_validation.md'
    )) {
        Assert-File $relative 'PC RX 01 UI and current detector documentation'
    }
    Assert-TextContains `
        -RelativePath 'AES_GCM_RX/vivado/tcl/AES_GCM_RX_bd.tcl' `
        -RequiredText @('0x41220000', 'rx_error_gpio') `
        -Label 'RX detector AXI GPIO mapping'
    Assert-TextContains `
        -RelativePath 'AES_GCM_RX/petalinux/project-spec/meta-user/recipes-apps/aes-gcm-rx/files/aes-gcm-rx.c' `
        -RequiredText @('PC_TELEMETRY_GROUP', 'PC_TELEMETRY_BROADCAST', 'PC_TELEMETRY_DISCOVERY_PORT', 'PC_RX_UI_SUBSCRIBE_V1', 'discover_video_sender', 'PCAM_TX_PEER_FILE', 'detector_tag_total', 'detector_timeout_total') `
        -Label 'RX detector PC telemetry v2 fields'
    Assert-TextContains `
        -RelativePath 'PC_RX_UI/server.py' `
        -RequiredText @('PC_TELEMETRY_GROUP', 'join_multicast_interfaces', 'PC_TELEMETRY_DISCOVERY_PORT', 'subscriber_discovery_targets', 'PC_RX_UI_SUBSCRIBE_V1', 'PC_RX_UI_PORT', 'create_server', 'JETSON_DASHBOARD_URL') `
        -Label 'PC UI runtime RX discovery, multicast auto-rejoin, and local web endpoint'
    Assert-TextContains `
        -RelativePath 'session_control/aes_session_agent.c' `
        -RequiredText @('PCAM_TX_PEER_FILE', '/run/aes-gcm-tx-peer', 'PCAM_RX_PEER_FILE', '/run/aes-gcm-rx-peer', 'CREATE_SECURE_SESSION') `
        -Label 'Session recovery uses runtime-learned video peers in both directions'
    Assert-TextContains `
        -RelativePath 'AES_GCM_TX/petalinux/project-spec/meta-user/recipes-apps/pcam-gcm-tx/files/pcam-gcm-udp-tx.c' `
        -RequiredText @('--discover-peer', 'PCAM_GCM_DISCOVERED_RX', 'PCAM_RX_PEER_FILE', 'TX_PL_DIRECT=1', 'PLAINTEXT_DDR_PRE_GCM=0', 'TX_PL_DIRECT_ALIGN', 'DMA_BUF_SYNC_START') `
        -Label 'TX learns RX and sends the PL-direct V4L2 frame'
    Assert-TextDoesNotContain `
        -RelativePath 'AES_GCM_TX/vivado/tcl/AES_GCM_TX_bd.tcl' `
        -ForbiddenText @(
            'axi_dma_gcm_tx',
            'CONFIG.PCW_USE_S_AXI_ACP {1}',
            '/S_AXI_ACP'
        ) `
        -Label 'TX block design excludes the old plaintext-DDR DMA round trip'
    Assert-TextDoesNotContain `
        -RelativePath 'AES_GCM_TX/petalinux/project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend' `
        -ForbiddenText @('pcam-aes-bridge', 'kernel-module-pcam-aes-bridge') `
        -Label 'TX rootfs excludes the obsolete AXI DMA bridge'

    foreach ($config in $configs) {
        $name = $config.Name
        $root = $config.Root
        if (-not $Quiet) {
            Write-Host "== $name release =="
        }

        $requiredFiles = @(
            "vivado/artifacts/$($config.BitName)",
            "vivado/artifacts/$($config.XsaName)",
            'vivado/artifacts/ps7_init.tcl',
            'petalinux/build_petalinux.sh',
            'petalinux/boot.bif',
            'petalinux/boot/BOOT.BIN',
            'petalinux/boot/image.ub',
            'petalinux/boot/system.dtb',
            'petalinux/boot/u-boot.elf',
            'petalinux/boot/zynq_fsbl.elf',
            "petalinux/JTAG_RAM_BOOT/$($config.JtagFsblName)",
            'petalinux/JTAG_RAM_BOOT/u-boot.elf',
            'petalinux/JTAG_RAM_BOOT/system.dtb',
            'petalinux/JTAG_RAM_BOOT/image.ub',
            'petalinux/JTAG_RAM_BOOT/jtag_boot_ram_direct.tcl',
            'petalinux/JTAG_RAM_BOOT/run_jtag_boot.ps1',
            'petalinux/JTAG_RAM_BOOT/uboot_direct_boot_serial.ps1',
            'sd_card/BOOT.BIN',
            'sd_card/boot.cmd',
            'sd_card/boot.scr',
            'sd_card/image.ub',
            'sd_card/system.bit',
            'sd_card/system.dtb',
            'sd_card/README.md',
            'sd_card/SHA256SUMS'
        )
        $requiredFiles += $config.TclFiles
        $requiredFiles += $config.RtlFiles | ForEach-Object { "vivado/rtl/$_" }
        foreach ($relative in $requiredFiles) {
            Assert-File "$root/$relative" "$name required release file"
        }
        Write-Detail "$name required BIT/XSA/boot/JTAG/SD/Tcl/RTL files"

        Assert-WiredNetworkPolicy `
            -SideRoot $root `
            -SideName $name `
            -Address $config.WiredAddress

        if ($name -eq 'TX') {
            foreach ($relative in @(
                'vivado/tb/tb_axis_video_frame_width_bridge.sv',
                'vivado/sim/run_tx_pl_direct_width_sim.tcl',
                'petalinux/TX_PL_DIRECT_30FPS_PATH.md'
            )) {
                Assert-File "$root/$relative" 'TX PL-direct reproducibility file'
            }
            Assert-TextContains `
                -RelativePath "$root/vivado/rtl/session/aes_session_key_regs_bd.v" `
                -RequiredText @(".ENABLE_TERMINATE_BUTTON(1'b0)") `
                -Label 'TX deployed wrapper keeps BTN3 inert'
        }

        Assert-XsaPortable `
            -RelativePath "$root/vivado/artifacts/$($config.XsaName)" `
            -Label "$name XSA"

        Assert-SameHash -RelativePaths @(
            "$root/vivado/artifacts/$($config.BitName)",
            "$root/sd_card/system.bit"
        ) -Label "$name artifact BIT equals SD system.bit"

        Assert-SameHash -RelativePaths @(
            "$root/petalinux/boot/BOOT.BIN",
            "$root/sd_card/BOOT.BIN"
        ) -Label "$name boot BOOT.BIN equals SD BOOT.BIN"

        Assert-SameHash -RelativePaths @(
            "$root/petalinux/boot/image.ub",
            "$root/petalinux/JTAG_RAM_BOOT/image.ub",
            "$root/sd_card/image.ub"
        ) -Label "$name boot/JTAG/SD image.ub"

        Assert-SameHash -RelativePaths @(
            "$root/petalinux/boot/system.dtb",
            "$root/petalinux/JTAG_RAM_BOOT/system.dtb",
            "$root/sd_card/system.dtb"
        ) -Label "$name boot/JTAG/SD system.dtb"

        Assert-SameHash -RelativePaths @(
            "$root/petalinux/boot/u-boot.elf",
            "$root/petalinux/JTAG_RAM_BOOT/u-boot.elf"
        ) -Label "$name boot/JTAG u-boot.elf"

        Assert-SameHash -RelativePaths @(
            "$root/petalinux/boot/zynq_fsbl.elf",
            "$root/petalinux/JTAG_RAM_BOOT/$($config.JtagFsblName)"
        ) -Label "$name boot/JTAG FSBL"

        Assert-SdChecksums -SideRoot $root -SideName $name
        Assert-SdBootCommand -SideRoot $root -SideName $name
        Assert-BootScriptPayload -SideRoot $root -SideName $name
        Assert-BootBinLayout -SideRoot $root -SideName $name

        $tclReferences = @(
            ('set bit_file [file join $root vivado artifacts ' + $config.BitName + ']'),
            ('set fsbl [file join $here ' + $config.JtagFsblName + ']'),
            'set uboot [file join $here u-boot.elf]',
            'set system_dtb [file join $here system.dtb]',
            'set image_ub [file join $here image.ub]',
            'fpga -file $bit_file',
            'dow $fsbl',
            'dow $uboot',
            'dow -data $system_dtb 0x00100000',
            'dow -data $image_ub 0x10000000'
        )
        Assert-TextContains `
            -RelativePath "$root/petalinux/JTAG_RAM_BOOT/jtag_boot_ram_direct.tcl" `
            -RequiredText $tclReferences `
            -Label "$name JTAG Tcl artifact/image references"

        Assert-SessionStaging -SideRoot $root -SideName $name -Mappings $config.SessionMappings

        Write-ImportantHash "$name BIT" "$root/vivado/artifacts/$($config.BitName)"
        Write-ImportantHash "$name XSA" "$root/vivado/artifacts/$($config.XsaName)"
        Write-ImportantHash "$name BOOT.BIN" "$root/petalinux/boot/BOOT.BIN"
        Write-ImportantHash "$name image.ub" "$root/petalinux/boot/image.ub"
    }

    Write-Host "RELEASE_VERIFY_PASS: TX/RX coherent; checks=$script:CheckCount"
} catch {
    [Console]::Error.WriteLine("RELEASE_VERIFY_FAIL: $($_.Exception.Message)")
    exit 1
}
