<# : DawaScan setup. Double-click to run. Removes the old Pharmacy Automation app if present, trusts the DawaScan certificate, installs the latest DawaScan.
@echo off
title DawaScan setup
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
set "DS_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -LiteralPath '%~f0') -join [Environment]::NewLine)"
echo.
pause
exit /b
#>

$ErrorActionPreference = 'Stop'
$Repo = 'pssolutions/DawaScanDesktopRelease'
$CerName = 'dawascan-pilot-signing.cer'
$OldGuid = '6F1B1E1A-6C1B-4B8A-9C0B-2C7B6C6E9A11'

function Fail([string]$Message, [int]$Code) {
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    exit $Code
}

function Remove-OldItem([string]$Path) {
    if ($Path -match 'DawaScan') { throw "Refusing to remove DawaScan item: $Path" }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Host "  Removed $Path"
    }
}

function Get-OldUninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($key.PSChildName -like "*$OldGuid*" -or $item.DisplayName -like 'Pharmacy Automation*') { $item }
        }
    }
}

function Remove-OldApp {
    Write-Host 'Removing the old Pharmacy Automation app...'
    Stop-Process -Name pharma-runtime -Force -ErrorAction SilentlyContinue

    foreach ($item in @(Get-OldUninstallEntries)) {
        $exe = $item.UninstallString.Trim('"')
        if ($exe -match 'DawaScan') { throw "Refusing DawaScan uninstaller: $exe" }
        if (Test-Path -LiteralPath $exe) {
            $p = Start-Process -FilePath $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "The old uninstaller failed (exit $($p.ExitCode))." }
            Write-Host "  Uninstalled $($item.DisplayName)"
        }
        # A broken entry whose uninstaller is gone would block the DawaScan installer forever.
        if (Test-Path -LiteralPath $item.PSPath) { Remove-Item -LiteralPath $item.PSPath -Recurse -Force }
    }

    @(
        (Join-Path $env:ProgramFiles 'Pharmacy Automation'),
        (Join-Path ${env:ProgramFiles(x86)} 'Pharmacy Automation'),
        (Join-Path $env:ProgramData 'PharmacyAutomation'),
        (Join-Path $env:ProgramData 'Pharmacy Automation'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Pharmacy Automation'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Pharmacy Automation'),
        'HKCU:\Software\PS Solutions\PharmacyAutomation'
    ) | ForEach-Object { Remove-OldItem $_ }

    $parent = 'HKCU:\Software\PS Solutions'
    if (Test-Path -LiteralPath $parent) {
        $key = Get-Item -LiteralPath $parent
        if ($key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0) { Remove-OldItem $parent }
    }

    foreach ($target in @('pharma_automation:pharma_machine_token', 'dawascan:pharma_machine_token')) {
        & cmdkey "/delete:$target" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  Removed saved credential $target" }
    }

    foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher')) {
        Get-ChildItem -LiteralPath $store |
            Where-Object { $_.Subject -like '*Pharmacy Automation (Pilot Signing)*' } |
            ForEach-Object { Remove-OldItem $_.PSPath }
    }

    if (& cmdkey /list | Select-String -Pattern 'pharma_machine_token' -Quiet) {
        Write-Host '  An old saved credential belongs to another Windows user. It is harmless; remove it from Credential Manager when signed in as that user.' -ForegroundColor Yellow
    }
    Write-Host 'Old app removed.' -ForegroundColor Green
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 1. Remove the old app. The DawaScan installer refuses to run while it is installed.
    $hasOld = @(Get-OldUninstallEntries).Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Pharmacy Automation'))
    if ($hasOld) {
        Write-Host 'The old Pharmacy Automation app is installed on this PC and will be removed.' -ForegroundColor Yellow
        Write-Host 'Before continuing: no invoice may be claimed or running, and Sync Pending Results must show nothing pending.'
        Write-Host 'Write down any HELPER SOFT settings (process name, window title) from the old app''s Settings first.'
        if ((Read-Host 'Type y to continue') -ne 'y') { Fail 'Cancelled. Nothing was changed.' 6 }
        Remove-OldApp
    }

    # 2. Trust the DawaScan signing certificate.
    $cer = Join-Path $env:DS_DIR $CerName
    if (-not (Test-Path -LiteralPath $cer)) {
        Write-Host 'Downloading certificate...'
        $cer = Join-Path $env:TEMP $CerName
        Invoke-WebRequest "https://github.com/$Repo/raw/main/$CerName" -OutFile $cer -UseBasicParsing
    }
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    Write-Host 'Certificate installed.' -ForegroundColor Green

    # 3. Download the latest installer.
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'DawaScan-Setup' }
    $asset = $release.assets | Where-Object { $_.name -match '^DawaScanDesktopSetup-\d+\.\d+\.\d+\.exe$' } | Select-Object -First 1
    if (-not $asset) { Fail 'No DawaScan installer was found in the latest release.' 3 }
    $exe = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $exe -UseBasicParsing
    if ((Get-Item -LiteralPath $exe).Length -ne $asset.size) { Fail 'The download is incomplete. Run this again.' 4 }

    # 4. Refuse anything not signed by the DawaScan certificate.
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*DawaScan*') {
        Remove-Item -LiteralPath $exe -Force
        Fail "The installer signature is not valid ($($sig.Status)). Nothing was installed." 5
    }

    # 5. Run the installer.
    Write-Host 'Starting the DawaScan installer...' -ForegroundColor Green
    Start-Process -FilePath $exe -Wait
    Write-Host 'Done. Open DawaScan and enter your activation code.' -ForegroundColor Green
    exit 0
}
catch {
    Fail "Setup failed: $($_.Exception.Message)" 1
}