#Requires -Version 5.1
<#
.SYNOPSIS
  Build Corne v4.1 vial_layers firmware with Docker, then flash both halves.

.DESCRIPTION
  1. Runs `docker compose run --rm qmk` to produce out\crkbd_rev4_1_standard_vial_layers.uf2
  2. Prompts you to enter bootloader on each half (hold Q / P while plugging USB)
  3. Waits for the RPI-RP2 drive, copies the UF2, waits for reboot
  4. Prints reassembly instructions

.PARAMETER SkipBuild
  Skip Docker compile and flash an existing UF2 in out\ (or -Uf2Path).

.PARAMETER Uf2Path
  Explicit UF2 to flash. Default: <repo>\out\crkbd_rev4_1_standard_vial_layers.uf2

.PARAMETER TimeoutSec
  How long to wait for RPI-RP2 per half (default 300).
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$Uf2Path = "",
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Resolve-Path (Join-Path $here "..")).Path
}

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-WarnBox([string[]]$Lines) {
    Write-Host ""
    foreach ($line in $Lines) {
        Write-Host $line -ForegroundColor Yellow
    }
    Write-Host ""
}

function Get-RpiRp2Drive {
    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.VolumeName -match 'RPI|RP2' }
}

function Wait-ForRpiRp2 {
    param(
        [string]$HalfName,
        [string]$HoldKey,
        [int]$TimeoutSec
    )

    Write-WarnBox @(
        "Flash $HalfName half:"
        "  1. Unplug USB from the PC (and disconnect the TRRS/interconnect cable if connected)."
        "  2. Hold the letter key  $HoldKey  on that half."
        "  3. While still holding $HoldKey, plug THAT HALF ONLY into USB."
        "  4. Keep holding ~1-2 seconds until a drive named RPI-RP2 appears."
        ""
        "Waiting up to $TimeoutSec seconds for RPI-RP2 ..."
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $vol = Get-RpiRp2Drive
        if ($vol) {
            Write-Host "Found $($vol.DeviceID) ($($vol.VolumeName))" -ForegroundColor Green
            return $vol
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for RPI-RP2 while flashing the $HalfName half. Try again (hold $HoldKey, different cable/port)."
}

function Wait-ForDriveGone {
    param(
        [string]$DeviceId,
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $still = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID -eq $DeviceId -and $_.VolumeName -match 'RPI|RP2' }
        if (-not $still) { return }
        Start-Sleep -Milliseconds 400
    }
    Write-Host "Note: $DeviceId is still mounted; unplug the half if flashing looks stuck." -ForegroundColor Yellow
}

function Flash-Half {
    param(
        [string]$HalfName,
        [string]$HoldKey,
        [string]$Uf2,
        [int]$TimeoutSec
    )

    # If a leftover bootloader drive is already present, ask before using it
    $existing = Get-RpiRp2Drive
    if ($existing) {
        Write-Host "RPI-RP2 is already present on $($existing.DeviceID)." -ForegroundColor Yellow
        $ans = Read-Host "Is this the $HalfName half ready to flash? [Y/n]"
        if ($ans -match '^[Nn]') {
            Write-Host "Unplug that half, then continue." -ForegroundColor Yellow
            Read-Host "Press Enter when unplugged"
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline -and (Get-RpiRp2Drive)) {
                Start-Sleep -Milliseconds 400
            }
        }
    }

    $vol = Get-RpiRp2Drive
    if (-not $vol) {
        $vol = Wait-ForRpiRp2 -HalfName $HalfName -HoldKey $HoldKey -TimeoutSec $TimeoutSec
    }

    $dest = Join-Path $vol.DeviceID ("crkbd_rev4_1_standard_vial_layers.uf2")
    Write-Host "Copying UF2 to $($vol.DeviceID) ..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $Uf2 -Destination $dest -Force
    Write-Host "Waiting for $HalfName half to leave bootloader ..." -ForegroundColor Cyan
    Wait-ForDriveGone -DeviceId $vol.DeviceID
    Write-Host "$HalfName half flashed." -ForegroundColor Green
}

# --- main ---
$repo = Get-RepoRoot
Set-Location $repo
Write-Host "Repo: $repo" -ForegroundColor DarkGray

if (-not $Uf2Path) {
    $Uf2Path = Join-Path $repo "out\crkbd_rev4_1_standard_vial_layers.uf2"
}

if (-not $SkipBuild) {
    Write-Step "Docker build / compile"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "docker not found on PATH. Start Docker Desktop and retry."
    }
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker daemon not reachable. Start Docker Desktop and retry."
    }

    $vq = Join-Path $repo "vial-qmk"
    if (-not (Test-Path (Join-Path $vq "keyboards\crkbd\keymaps\vial_layers\keymap.c"))) {
        throw "vial-qmk submodule missing keymap. Run: git submodule update --init --recursive"
    }
    if (-not (Test-Path (Join-Path $vq "lib\pico-sdk\src"))) {
        throw "vial-qmk lib/pico-sdk missing. Run: git submodule update --init --recursive"
    }

    Write-Host "Running: docker compose run --rm qmk" -ForegroundColor DarkGray
    docker compose run --rm qmk
    if ($LASTEXITCODE -ne 0) {
        throw "Docker compile failed (exit $LASTEXITCODE)."
    }
} else {
    Write-Step "Skipping build (-SkipBuild)"
}

if (-not (Test-Path -LiteralPath $Uf2Path)) {
    throw "UF2 not found: $Uf2Path"
}
Write-Host "UF2: $Uf2Path ($((Get-Item -LiteralPath $Uf2Path).Length) bytes)" -ForegroundColor DarkGray

Write-Step "Flash both halves"
Write-Host "You will flash LEFT (hold Q) then RIGHT (hold P), one USB half at a time."

Flash-Half -HalfName "LEFT" -HoldKey "Q" -Uf2 $Uf2Path -TimeoutSec $TimeoutSec

Write-WarnBox @(
    "LEFT done. Unplug the left half from USB."
    "Next: RIGHT half (hold P)."
)
Read-Host "Press Enter when the left half is unplugged and you are ready for the right half"

Flash-Half -HalfName "RIGHT" -HoldKey "P" -Uf2 $Uf2Path -TimeoutSec $TimeoutSec

Write-Step "Reassemble and test"
Write-WarnBox @(
    "Both halves are flashed. Put the keyboard back together:"
    "  1. Unplug USB from the PC."
    "  2. Connect the two halves with the TRRS (or board interconnect) cable."
    "     Do not hot-plug TRRS while USB is connected."
    "  3. Plug the main half (usually LEFT) into USB."
    "  4. Open Vial — board should appear as Corne v4."
    "  5. If the layout looks wrong: File -> Load from file -> corne-v4-layout-backup.vil"
    "  6. Check layers: Base = Vial Lighting; Lower green; Raise orange; Adjust white; Layer 4 blue."
)

Write-Host "Done." -ForegroundColor Green
