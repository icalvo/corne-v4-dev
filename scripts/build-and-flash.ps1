#Requires -Version 5.1
<#
.SYNOPSIS
  Build Corne v4.1 vial_layers firmware with Docker, then flash both halves.

.DESCRIPTION
  1. Runs `docker compose run --rm qmk` to produce out\crkbd_rev4_1_standard_vial_layers.uf2
  2. Prompts you to put each half in BOOTSEL (hold P/Q while plugging — safe after vial_layers flash)
  3. Waits for the RPI-RP2 drive and flashes the UF2 (drag-and-drop by default)
  4. Flashes left after right, then prints reassembly instructions

  With -PreserveEeprom: same BOOTSEL entry, then picotool backup → load UF2 → restore EEPROM.
  vial_layers skips Bootmagic's EEPROM wipe so Q/P-on-plug does not clear Vial data.

.PARAMETER SkipBuild
  Skip Docker compile and flash an existing UF2 in out\ (or -Uf2Path).

.PARAMETER FlashOnly
  Same as -SkipBuild: flash only, no compile.

.PARAMETER Uf2Path
  Explicit UF2 to flash. Default: <repo>\out\crkbd_rev4_1_standard_vial_layers.uf2

.PARAMETER TimeoutSec
  How long to wait for RPI-RP2 per half (default 300).

.PARAMETER PreserveEeprom
  Backup/restore the wear-leveling EEPROM region via picotool around each flash.

.EXAMPLE
  .\scripts\build-and-flash.ps1
  Build then flash both halves.

.EXAMPLE
  .\scripts\build-and-flash.ps1 -FlashOnly
  Flash the UF2 already in out\ (no Docker build).
#>
[CmdletBinding()]
param(
    [Alias("FlashOnly")]
    [switch]$SkipBuild,
    [string]$Uf2Path = "",
    [int]$TimeoutSec = 300,
    [switch]$PreserveEeprom
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
        [int]$TimeoutSec,
        [switch]$QuietPrompt
    )

    if (-not $QuietPrompt) {
        Write-WarnBox @(
            "Flash $HalfName half:"
            "  1. Unplug USB (and disconnect the TRRS/interconnect cable)."
            "  2. Hold the letter key  $HoldKey  on that half."
            "  3. While still holding $HoldKey, plug THAT HALF ONLY into USB."
            "  4. Keep holding ~1-2 seconds until a drive named RPI-RP2 appears."
            ""
            "  vial_layers: Q/P Bootmagic enters BOOTSEL without wiping EEPROM."
            "  (Stock Corne firmware still wipes — flash vial_layers once first.)"
            ""
            "Waiting up to $TimeoutSec seconds for RPI-RP2 ..."
        )
    } else {
        Write-Host "Waiting up to $TimeoutSec seconds for RPI-RP2 ($HalfName) ..." -ForegroundColor Yellow
    }

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

function Enter-BootselSafe {
    param(
        [string]$HalfName,
        [string]$HoldKey,
        [int]$TimeoutSec
    )

    if (Get-RpiRp2Drive) {
        Write-Host "$HalfName already in BOOTSEL." -ForegroundColor Green
        return Get-RpiRp2Drive
    }

    return Wait-ForRpiRp2 -HalfName $HalfName -HoldKey $HoldKey -TimeoutSec $TimeoutSec
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

function Wait-ForNoRpiRp2 {
    param(
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-RpiRp2Drive)) { return }
        Start-Sleep -Milliseconds 400
    }
    throw "Timed out waiting for RPI-RP2 to disappear. Unplug the half and retry."
}

# QMK RP2040 wear-leveling EEPROM: last 8 KiB of 2 MiB flash (XIP @ 0x10000000).
$script:EepromFrom = "0x101FE000"
$script:EepromTo = "0x10200000"
$script:EepromOffset = "0x101FE000"

function Get-PicotoolPath {
    param([string]$RepoRoot)
    $candidate = Join-Path $RepoRoot "tools\picotool\picotool\picotool.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $onPath = Get-Command picotool -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-Picotool {
    param(
        [string]$Picotool,
        [string[]]$PicotoolArgs
    )
    Write-Host "  picotool $($PicotoolArgs -join ' ')" -ForegroundColor DarkGray
    # Capture native stdout/stderr so progress bars do not become function output.
    # Otherwise `$rc = Invoke-Picotool ...` is a string[]+exitcode, and `$rc -ne 0`
    # filters that array (truthy) even when the real exit code was 0.
    $output = & $Picotool @PicotoolArgs 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    foreach ($line in @($output)) {
        if ($null -ne $line -and "$line".Length -gt 0) {
            Write-Host "$line"
        }
    }
    return [int]$code
}

function Get-EepromBackupStats {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $programmed = 0
    foreach ($b in $bytes) {
        if ($b -ne 0xFF) { $programmed++ }
    }
    return [pscustomobject]@{
        Length      = $bytes.Length
        Programmed  = $programmed
    }
}

function Flash-HalfWithEeprom {
    param(
        [string]$Picotool,
        [string]$HalfName,
        [string]$Uf2,
        [string]$EepromBackupPath
    )

    Write-Host "Backing up EEPROM ($HalfName) -> $EepromBackupPath" -ForegroundColor Cyan
    $dir = Split-Path -Parent $EepromBackupPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $rc = Invoke-Picotool -Picotool $Picotool -PicotoolArgs @(
        "save", "-r", $script:EepromFrom, $script:EepromTo, "-t", "bin", $EepromBackupPath
    )
    if ($rc -ne 0) {
        throw "picotool EEPROM save failed (exit $rc). Install WinUSB on RP2 Boot (Interface 1) with Zadig in tools\, or omit -PreserveEeprom."
    }
    if (-not (Test-Path -LiteralPath $EepromBackupPath)) {
        throw "EEPROM backup file was not created: $EepromBackupPath"
    }
    $stats = Get-EepromBackupStats -Path $EepromBackupPath
    Write-Host "EEPROM backup: $($stats.Length) bytes, $($stats.Programmed) non-0xFF (programmed) bytes" -ForegroundColor DarkGray
    if ($stats.Programmed -lt 16) {
        $msg = @"
$HalfName EEPROM region looks blank/erased ($($stats.Programmed) programmed bytes).
If this half still runs stock Corne firmware, Q/P-on-plug wiped EEPROM (Bootmagic).
Flash vial_layers once (wipe OK), reload layouts/colors, then -PreserveEeprom works with Q/P.
"@
        # Vial layouts live on the USB master (usually LEFT). RIGHT is often sparse; only fail LEFT.
        if ($HalfName -match 'LEFT') {
            throw $msg
        }
        Write-Host "WARNING: $msg" -ForegroundColor Yellow
        Write-Host "Continuing anyway for $HalfName (slave half may not store Vial layouts)." -ForegroundColor Yellow
    }

    Write-Host "Loading UF2 via picotool ..." -ForegroundColor Cyan
    $rc = Invoke-Picotool -Picotool $Picotool -PicotoolArgs @("load", "-v", $Uf2)
    if ($rc -ne 0) {
        throw "picotool load UF2 failed (exit $rc)."
    }

    Write-Host "Restoring EEPROM ..." -ForegroundColor Cyan
    $rc = Invoke-Picotool -Picotool $Picotool -PicotoolArgs @(
        "load", "-v", "-o", $script:EepromOffset, "-t", "bin", $EepromBackupPath
    )
    if ($rc -ne 0) {
        throw "picotool EEPROM restore failed (exit $rc)."
    }

    Write-Host "Rebooting $HalfName half ..." -ForegroundColor Cyan
    $null = Invoke-Picotool -Picotool $Picotool -PicotoolArgs @("reboot")
}

function Flash-HalfDragDrop {
    param(
        [string]$HalfName,
        [string]$Uf2,
        [object]$Vol
    )
    $dest = Join-Path $Vol.DeviceID ("crkbd_rev4_1_standard_vial_layers.uf2")
    Write-Host "Copying UF2 to $($Vol.DeviceID) (drag-and-drop; no EEPROM restore) ..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $Uf2 -Destination $dest -Force
}

function Flash-Half {
    param(
        [string]$HalfName,
        [string]$HoldKey,
        [string]$Uf2,
        [int]$TimeoutSec,
        [string]$Picotool,
        [string]$EepromBackupPath,
        [switch]$PreserveEeprom,
        [switch]$NoConfirm
    )

    $existing = Get-RpiRp2Drive
    if ($existing -and -not $NoConfirm) {
        Write-Host "RPI-RP2 is already present on $($existing.DeviceID)." -ForegroundColor Yellow
        $ans = Read-Host "Is this the $HalfName half ready to flash? [Y/n]"
        if ($ans -match '^[Nn]') {
            Write-Host "Unplug that half, then continue." -ForegroundColor Yellow
            Read-Host "Press Enter when unplugged"
            Wait-ForNoRpiRp2 -TimeoutSec 60
        }
    } elseif ($existing -and $NoConfirm) {
        Write-Host "Waiting for RPI-RP2 to disappear (unplug the previous half) ..." -ForegroundColor Yellow
        Wait-ForNoRpiRp2 -TimeoutSec 120
    }

    if ($PreserveEeprom -and $Picotool) {
        $null = Enter-BootselSafe -HalfName $HalfName -HoldKey $HoldKey -TimeoutSec $TimeoutSec
        Flash-HalfWithEeprom -Picotool $Picotool -HalfName $HalfName -Uf2 $Uf2 -EepromBackupPath $EepromBackupPath
        $vol = Get-RpiRp2Drive
        if ($vol) {
            Write-Host "Waiting for $HalfName half to leave bootloader ..." -ForegroundColor Cyan
            Wait-ForDriveGone -DeviceId $vol.DeviceID
        }
        Write-Host "$HalfName half flashed (EEPROM preserved)." -ForegroundColor Green
        return
    }

    if ($PreserveEeprom -and -not $Picotool) {
        Write-Host "picotool not found; flashing via drag-and-drop (no EEPROM backup/restore)." -ForegroundColor Yellow
    }

    $vol = Get-RpiRp2Drive
    if (-not $vol) {
        $vol = Wait-ForRpiRp2 -HalfName $HalfName -HoldKey $HoldKey -TimeoutSec $TimeoutSec
    }
    Flash-HalfDragDrop -HalfName $HalfName -Uf2 $Uf2 -Vol $vol
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
    Write-Step "Skipping build (-FlashOnly / -SkipBuild)"
}

if (-not (Test-Path -LiteralPath $Uf2Path)) {
    throw "UF2 not found: $Uf2Path"
}
Write-Host "UF2: $Uf2Path ($((Get-Item -LiteralPath $Uf2Path).Length) bytes)" -ForegroundColor DarkGray

$picotool = Get-PicotoolPath -RepoRoot $repo
$eepromDir = Join-Path $repo "out\eeprom-backup"
if ($PreserveEeprom) {
    if ($picotool) {
        Write-Host "picotool: $picotool" -ForegroundColor DarkGray
        Write-Host "EEPROM preserve ON: $script:EepromFrom .. $script:EepromTo (backups under out\eeprom-backup\)" -ForegroundColor DarkGray
    } else {
        Write-Host "picotool not found under tools\picotool — EEPROM backup/restore unavailable." -ForegroundColor Yellow
    }
} else {
    Write-Host "EEPROM backup/restore off (default). Pass -PreserveEeprom to enable." -ForegroundColor DarkGray
}

Write-Step "Flash both halves"
Write-Host "Flash RIGHT (hold P) then LEFT (hold Q), one USB half at a time." -ForegroundColor Yellow

Flash-Half -HalfName "RIGHT" -HoldKey "P" -Uf2 $Uf2Path -TimeoutSec $TimeoutSec `
    -Picotool $picotool -EepromBackupPath (Join-Path $eepromDir "right.bin") -PreserveEeprom:$PreserveEeprom

Write-WarnBox @(
    "RIGHT done. Unplug that half from USB."
    "Next: LEFT half — hold Q, plug THAT HALF ONLY into USB until RPI-RP2 appears."
)

if (Get-RpiRp2Drive) {
    Wait-ForNoRpiRp2 -TimeoutSec 120
}
Flash-Half -HalfName "LEFT" -HoldKey "Q" -Uf2 $Uf2Path -TimeoutSec $TimeoutSec -NoConfirm `
    -Picotool $picotool -EepromBackupPath (Join-Path $eepromDir "left.bin") -PreserveEeprom:$PreserveEeprom

Write-Step "Reassemble and test"
Write-WarnBox @(
    "Both halves are flashed. Put the keyboard back together:"
    "  1. Unplug USB from the PC."
    "  2. Connect the two halves with the TRRS (or board interconnect) cable."
    "     Do not hot-plug TRRS while USB is connected."
    "  3. Plug the main half (usually LEFT) into USB."
    "  4. Open Vial — stable BUILD_ID + vial_layers Bootmagic (no EEPROM wipe) keep settings."
    "  5. If the layout looks wrong: File -> Load from file -> corne-v4-layout-backup.vil"
    "  6. Check layers: Base = Vial Lighting; 1-9 = EEPROM colors."
)

Write-Host "Done." -ForegroundColor Green
