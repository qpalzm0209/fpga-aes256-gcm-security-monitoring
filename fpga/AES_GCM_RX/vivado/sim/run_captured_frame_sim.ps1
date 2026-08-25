param([string]$VivadoBin)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$vivado = $VivadoBin
if (-not $vivado) {
    $xvlogCommand = Get-Command 'xvlog.bat', 'xvlog' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $xvlogCommand) {
        throw 'Vivado tools are not on PATH. Use a Vivado 2025.2 shell or pass -VivadoBin <Vivado-bin-folder>.'
    }
    $vivado = Split-Path -Parent $xvlogCommand.Source
}
$rtl = Join-Path $root 'rtl\aes256_gcm'
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'pcam-aes-gcm\rx-captured-frame-sim'
New-Item -ItemType Directory -Path $work -Force | Out-Null

$frameFile = Join-Path $work 'rx_encrypted_frame_1280x1472.bin'
python (Join-Path $root 'sim\generate_standard_mtu_frame.py') $frameFile
if ($LASTEXITCODE -ne 0) { throw 'standard-MTU frame generation failed' }

$sources = @(
    (Join-Path $rtl 'aes_key_rcon_pkg.sv'),
    (Join-Path $rtl 'aes_sbox_pkg.sv'),
    (Join-Path $rtl 'gcm_protocol_pkg.sv'),
    (Join-Path $rtl 'aes_addroundkey.sv'),
    (Join-Path $rtl 'aes_mixcolumns.sv'),
    (Join-Path $rtl 'aes_next_round_key.sv'),
    (Join-Path $rtl 'aes_round.sv'),
    (Join-Path $rtl 'aes_shiftrows.sv'),
    (Join-Path $rtl 'aes_subbytes.sv'),
    (Join-Path $rtl 'aes_subword32.sv'),
    (Join-Path $rtl 'aes256_iterative_core.sv'),
    (Join-Path $rtl 'aes256_key_expansion.sv'),
    (Join-Path $rtl 'aes256_key_transform.sv'),
    (Join-Path $rtl 'ghash_mul16.sv'),
    (Join-Path $rtl 'packet_buffer_bram.sv'),
    (Join-Path $rtl 'video_aes_gcm_rx_top.sv'),
    (Join-Path $root 'rtl\rx\axis_gcm_rx_frame_processor_v2.sv'),
    (Join-Path $root 'rtl\rx\axis_gcm_rx_frame_processor_bd.v'),
    (Join-Path $root 'sim\tb_rx_captured_frame.sv')
)

Push-Location $work
try {
    & (Join-Path $vivado 'xvlog.bat') -sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & (Join-Path $vivado 'xelab.bat') tb_rx_captured_frame `
        -timescale 1ns/1ps -s captured_rx_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    & (Join-Path $vivado 'xsim.bat') captured_rx_sim -runall
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
} finally {
    Pop-Location
}
