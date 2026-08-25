param([string]$VivadoBin)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$vivado = $VivadoBin
if (-not $vivado) {
    $xvlogCommand = Get-Command 'xvlog.bat', 'xvlog' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $xvlogCommand) {
        throw 'Vivado tools are not on PATH. Use Vivado 2025.2 or pass -VivadoBin <Vivado-bin-folder>.'
    }
    $vivado = Split-Path -Parent $xvlogCommand.Source
}

$rtl = Join-Path $root 'rtl\aes256_gcm'
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'pcam-aes-gcm\rx-frame-busy-sim'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$sources = @(
    (Join-Path $rtl 'aes_sbox_pkg.sv'),
    (Join-Path $rtl 'aes_key_rcon_pkg.sv'),
    (Join-Path $rtl 'gcm_protocol_pkg.sv'),
    (Join-Path $rtl 'aes_addroundkey.sv'),
    (Join-Path $rtl 'aes_mixcolumns.sv'),
    (Join-Path $rtl 'aes_shiftrows.sv'),
    (Join-Path $rtl 'aes_subbytes.sv'),
    (Join-Path $rtl 'aes_subword32.sv'),
    (Join-Path $rtl 'aes_next_round_key.sv'),
    (Join-Path $rtl 'aes256_key_transform.sv'),
    (Join-Path $rtl 'aes_round.sv'),
    (Join-Path $rtl 'aes256_key_expansion.sv'),
    (Join-Path $rtl 'aes256_iterative_core.sv'),
    (Join-Path $rtl 'ghash_mul16.sv'),
    (Join-Path $rtl 'packet_buffer_bram.sv'),
    (Join-Path $rtl 'video_aes_gcm_rx_top.sv'),
    (Join-Path $scriptDir 'tb_rx_frame_busy_boundary.sv')
)

Push-Location $work
try {
    & (Join-Path $vivado 'xvlog.bat') -sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & (Join-Path $vivado 'xelab.bat') tb_rx_frame_busy_boundary `
        -timescale 1ns/1ps -s rx_frame_busy_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    & (Join-Path $vivado 'xsim.bat') rx_frame_busy_sim -runall
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
} finally {
    Pop-Location
}
