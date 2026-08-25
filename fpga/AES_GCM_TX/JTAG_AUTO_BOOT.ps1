[CmdletBinding()]
param(
    [string]$Xsdb,
    [string]$SshPublicKeyPath,
    [int]$Seconds = 300,
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'

if ($Seconds -le 0) {
    throw '-Seconds must be greater than zero.'
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$txScript = Join-Path $root 'AES_GCM_TX\petalinux\JTAG_RAM_BOOT\run_jtag_boot.ps1'
$rxScript = Join-Path $root 'AES_GCM_RX\petalinux\JTAG_RAM_BOOT\run_jtag_boot.ps1'
$txStatus = Join-Path $root 'AES_GCM_TX\petalinux\JTAG_RAM_BOOT\jtag_boot_status.txt'

$boards = @(
    Get-CimInstance Win32_PnPEntity |
        ForEach-Object {
            $comMatch = [regex]::Match($_.Name, '\(COM(\d+)\)')
            $deviceMatch = [regex]::Match(
                $_.DeviceID,
                'VID_0403\+PID_6010\+([^\\]+)B\\'
            )
            if ($comMatch.Success -and $deviceMatch.Success) {
                [pscustomobject]@{
                    Port = "COM$($comMatch.Groups[1].Value)"
                    ComNumber = [int]$comMatch.Groups[1].Value
                    CableSerial = "$($deviceMatch.Groups[1].Value)A"
                    Name = $_.Name
                }
            }
        }
) | Sort-Object ComNumber

if ($boards.Count -ne 2) {
    $found = if ($boards.Count) { ($boards.Port -join ', ') } else { 'none' }
    throw "Exactly two Digilent FTDI UARTs are required; found $($boards.Count): $found"
}
if (($boards.CableSerial | Select-Object -Unique).Count -ne 2) {
    throw 'The two discovered UARTs do not map to distinct JTAG cables.'
}
if ($DetectOnly) {
    $boards | Select-Object Port, CableSerial, Name
    return
}

function Invoke-RoleBoot {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)]$Board
    )

    $arguments = @{
        Port = $Board.Port
        CableSerial = $Board.CableSerial
        Seconds = $Seconds
    }
    if (-not [string]::IsNullOrWhiteSpace($Xsdb)) {
        $arguments.Xsdb = $Xsdb
    }
    if (-not [string]::IsNullOrWhiteSpace($SshPublicKeyPath)) {
        $arguments.SshPublicKeyPath = $SshPublicKeyPath
    }
    & $Script @arguments
}

$first = $boards[0]
$second = $boards[1]
$txBoard = $null
$rxBoard = $null

Write-Host "Probing Pcam on $($first.Port) / $($first.CableSerial)"
try {
    Invoke-RoleBoot -Script $txScript -Board $first
    $txBoard = $first
    $rxBoard = $second
} catch {
    $status = Get-Content -LiteralPath $txStatus -Raw -ErrorAction SilentlyContinue
    if ($status -notmatch 'PCAM_CHECKED=1\s+PCAM=0') {
        throw
    }
    Write-Host "No Pcam on $($first.Port); assigning it as RX"
    $rxBoard = $first
    $txBoard = $second
    Invoke-RoleBoot -Script $rxScript -Board $rxBoard
    Write-Host "Loading TX on Pcam candidate $($txBoard.Port) / $($txBoard.CableSerial)"
    Invoke-RoleBoot -Script $txScript -Board $txBoard
}

if ($rxBoard -eq $second) {
    Write-Host "Loading RX on $($rxBoard.Port) / $($rxBoard.CableSerial)"
    Invoke-RoleBoot -Script $rxScript -Board $rxBoard
}

Write-Host "AUTO_JTAG_BOOT_READY TX=$($txBoard.Port)/$($txBoard.CableSerial) RX=$($rxBoard.Port)/$($rxBoard.CableSerial)"
