#Requires -Version 5.1
<#
.SYNOPSIS
  Install and verify Jack Session Console host dependencies.
.DESCRIPTION
  Fail-loud installer for Jack's gaming PC. Does not wrap capture in Docker.
  Writes an atomic Ready flag only after required checks pass. A machine
  that cannot record must not be reported as ready, and must not be allowed
  to publish.
.PARAMETER VerifyOnly
  Check current state; do not install packages.
.PARAMETER WithOptional
  Optional winget packages to include: OBS, Chrome, NvidiaApp.
.PARAMETER SessionDrive
  Drive used for recording sessions (default: the install root's drive).
.PARAMETER ConfirmDriverInstall
  Allow offering NVIDIA App via winget. Never silent.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [ValidateSet('OBS', 'Chrome', 'NvidiaApp')]
    [string[]]$WithOptional = @(),
    [string]$SessionDrive = '',
    [switch]$ConfirmDriverInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $InstallRoot
$ManifestPath = Join-Path $InstallRoot 'dependencies.json'
$StateDir = Join-Path $RepoRoot 'state'
$StatePath = Join-Path $StateDir 'install-state.json'
$LogPath = Join-Path $StateDir 'install.log'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'FAIL', 'OK', 'STEP')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'OK'   { Write-Host $line -ForegroundColor Green }
        'STEP' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function New-Check {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Severity, # required | soft | forbidden
        [bool]$Ok,
        [string]$Detail
    )
    [pscustomobject]@{
        id       = $Id
        name     = $Name
        severity = $Severity
        ok       = $Ok
        detail   = $Detail
    }
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dependency ledger missing: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-Winget {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        & winget --version | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-WingetPackage {
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-Winget)) { return $false }
    $out = & winget list --id $Id -e --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($out -join "`n") -match [regex]::Escape($Id)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Winget)) {
        throw "winget is not available; cannot install $Name ($Id)."
    }
    Write-Log -Level STEP "Installing $Name ($Id) via winget"
    & winget install -e --id $Id --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # -1978335189 = already installed (no newer version)
        throw "winget failed for $Name ($Id) with exit $LASTEXITCODE"
    }
    if (-not (Test-WingetPackage -Id $Id) -and $LASTEXITCODE -ne -1978335189) {
        throw "winget reported success but $Name ($Id) is not installed."
    }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user) -join ';'
}

function Find-FfmpegExe {
    Update-SessionPath
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $direct = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe')
    )
    $searchRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'ffmpeg'),
        (Join-Path ${env:ProgramFiles(x86)} 'ffmpeg')
    )
    foreach ($c in $direct) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-NvidiaSmi {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'),
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe')
    )
    $fromPath = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($fromPath) { $candidates = @($fromPath.Source) + $candidates }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Test-NvencInFfmpeg {
    $path = Find-FfmpegExe
    if (-not $path) { return [pscustomobject]@{ present = $false; nvenc = $false; path = $null } }
    $enc = & $path -hide_banner -encoders 2>&1 | Out-String
    return [pscustomobject]@{
        present = $true
        nvenc   = ($enc -match 'h264_nvenc' -or $enc -match 'hevc_nvenc')
        path    = $path
    }
}

function Get-DisplayCount {
    try {
        return @(Get-CimInstance -ClassName Win32_DesktopMonitor | Where-Object { $_.Status -eq 'OK' }).Count
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            return [System.Windows.Forms.Screen]::AllScreens.Count
        } catch {
            return 0
        }
    }
}

function Test-Microphone {
    try {
        $mics = Get-CimInstance -ClassName Win32_SoundDevice | Where-Object { $_.StatusInfo -eq 3 -or $_.Status -eq 'OK' }
        $endpoints = Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue
        $capture = @(
            Get-PnpDevice -Class MEDIA -Status OK -ErrorAction SilentlyContinue
        )
        $ok = ($null -ne $mics) -or ($null -ne $endpoints) -or ($capture.Count -gt 0)
        # Prefer MMDevice capture list when available
        $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
        if (Test-Path $reg) {
            $keys = @(Get-ChildItem $reg -ErrorAction SilentlyContinue)
            if ($keys.Count -gt 0) { $ok = $true }
        }
        return [pscustomobject]@{ ok = [bool]$ok; detail = 'Capture endpoints enumerated' }
    } catch {
        return [pscustomobject]@{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-Camera {
    try {
        $cams = @(Get-PnpDevice -Class Camera -Status OK -ErrorAction SilentlyContinue)
        if ($cams.Count -eq 0) {
            $cams = @(Get-PnpDevice -Class Image -Status OK -ErrorAction SilentlyContinue | Where-Object {
                    $_.FriendlyName -match 'cam|webcam|usb video|capture'
                })
        }
        $frame = @(Get-PnpDevice -Class CameraFrameServer -Status OK -ErrorAction SilentlyContinue)
        $ok = ($cams.Count -gt 0) -or ($frame.Count -gt 0)
        $names = @($cams | ForEach-Object { $_.FriendlyName })
        return [pscustomobject]@{
            ok     = $ok
            detail = if ($ok) { ($names -join ', ') } else { 'No camera device in OK state' }
        }
    } catch {
        return [pscustomobject]@{ ok = $false; detail = $_.Exception.Message }
    }
}

function Get-FreeGb {
    param([string]$DriveLetter)
    $d = Get-PSDrive -Name $DriveLetter -ErrorAction Stop
    return [math]::Round(($d.Free / 1GB), 1)
}

function Write-StateAtomic {
    param(
        [Parameter(Mandatory)]$State
    )
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir | Out-Null
    }
    $tmp = "$StatePath.tmp"
    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }
    Move-Item -LiteralPath $tmp -Destination $StatePath
}

# --- begin ---
if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir | Out-Null
}
Write-Log -Level STEP 'Jack Session Console host install'
Write-Log "Ledger: $ManifestPath"

$manifest = Get-JsonFile -Path $ManifestPath
$checks = New-Object System.Collections.Generic.List[object]
$installed = New-Object System.Collections.Generic.List[string]

if (-not $VerifyOnly -and -not (Test-Administrator)) {
    Write-Log -Level FAIL 'Installer must run elevated (Run as administrator) unless -VerifyOnly.'
    exit 1
}

# OS
$os = Get-CimInstance Win32_OperatingSystem
$osOk = ($os.Caption -match 'Windows 10' -or $os.Caption -match 'Windows 11') -and $os.OSArchitecture -match '64'
$checks.Add((New-Check -Id 'windows' -Name 'Windows 64-bit 10/11' -Severity 'required' -Ok $osOk -Detail ($os.Caption + ' ' + $os.Version))) | Out-Null
if (-not $osOk) { Write-Log -Level FAIL $checks[-1].detail } else { Write-Log -Level OK $checks[-1].detail }

# Docker must not be required; warn if present so Jack knows we are ignoring it
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($docker) {
    $checks.Add((New-Check -Id 'docker-desktop' -Name 'Docker (must not wrap capture)' -Severity 'forbidden' -Ok $true -Detail ("Present at " + $docker.Source + " - ignored. Capture stays on the host."))) | Out-Null
    Write-Log -Level WARN $checks[-1].detail
} else {
    $checks.Add((New-Check -Id 'docker-desktop' -Name 'Docker not installed (correct)' -Severity 'forbidden' -Ok $true -Detail 'Docker absent - correct. Will not be installed.')) | Out-Null
    Write-Log -Level OK $checks[-1].detail
}

# winget
$wingetOk = Test-Winget
$checks.Add((New-Check -Id 'winget' -Name 'winget' -Severity 'required' -Ok $wingetOk -Detail $(if ($wingetOk) { (winget --version) } else { 'winget missing. Install App Installer from the Microsoft Store.' }))) | Out-Null
if (-not $wingetOk) {
    Write-Log -Level FAIL $checks[-1].detail
    if (-not $VerifyOnly) {
        Write-Log -Level FAIL 'Cannot continue installing packages without winget.'
        Write-StateAtomic -State @{
            status     = 'not-ready'
            product    = $manifest.product
            host       = $manifest.host
            checkedAt  = (Get-Date).ToString('o')
            reason     = 'winget missing'
            checks     = $checks
            docker     = $manifest.docker
        }
        exit 1
    }
} else {
    Write-Log -Level OK "winget $($checks[-1].detail)"
}

function Invoke-RequiredPackage {
    param([string]$Id, [string]$Name, [string]$WingetId, [scriptblock]$Verify)
    $ok = & $Verify
    if ($ok) {
        $checks.Add((New-Check -Id $Id -Name $Name -Severity 'required' -Ok $true -Detail 'already present')) | Out-Null
        Write-Log -Level OK "$Name already present"
        return
    }
    if ($VerifyOnly) {
        $checks.Add((New-Check -Id $Id -Name $Name -Severity 'required' -Ok $false -Detail 'missing (verify-only)')) | Out-Null
        Write-Log -Level FAIL "$Name missing"
        return
    }
    Install-WingetPackage -Id $WingetId -Name $Name
    $installed.Add($WingetId) | Out-Null
    $ok = & $Verify
    $checks.Add((New-Check -Id $Id -Name $Name -Severity 'required' -Ok $ok -Detail $(if ($ok) { "installed $WingetId" } else { "installed but verify failed" }))) | Out-Null
    if ($ok) { Write-Log -Level OK "$Name installed" } else { Write-Log -Level FAIL "$Name verify failed after install" }
}

# VC++
Invoke-RequiredPackage -Id 'vcredist' -Name 'VC++ Redistributable x64' -WingetId 'Microsoft.VCRedist.2015+.x64' -Verify {
    Test-WingetPackage -Id 'Microsoft.VCRedist.2015+.x64'
}

# .NET 8 Desktop
Invoke-RequiredPackage -Id 'dotnet8-desktop' -Name '.NET 8 Desktop Runtime' -WingetId 'Microsoft.DotNet.DesktopRuntime.8' -Verify {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { return (Test-WingetPackage -Id 'Microsoft.DotNet.DesktopRuntime.8') }
    $runtimes = & dotnet --list-runtimes 2>$null | Out-String
    return ($runtimes -match 'Microsoft\.WindowsDesktop\.App 8\.') -or (Test-WingetPackage -Id 'Microsoft.DotNet.DesktopRuntime.8')
}

# FFmpeg (winget updates PATH for *new* shells only — refresh this process)
Invoke-RequiredPackage -Id 'ffmpeg' -Name 'FFmpeg' -WingetId 'Gyan.FFmpeg' -Verify {
    $null -ne (Find-FfmpegExe)
}

$ff = Test-NvencInFfmpeg
$checks.Add((New-Check -Id 'ffmpeg-nvenc' -Name 'FFmpeg NVENC encoder' -Severity 'required' -Ok ($ff.present -and $ff.nvenc) -Detail $(
            if (-not $ff.present) { 'ffmpeg not on PATH' }
            elseif (-not $ff.nvenc) { "ffmpeg at $($ff.path) has no h264_nvenc/hevc_nvenc" }
            else { "NVENC present ($($ff.path))" }
        ))) | Out-Null
if ($checks[-1].ok) { Write-Log -Level OK $checks[-1].detail } else { Write-Log -Level FAIL $checks[-1].detail }

# NVIDIA
$smi = Get-NvidiaSmi
$gpuOk = $false
$gpuDetail = 'nvidia-smi not found - NVIDIA GPU/driver missing'
if ($smi) {
    try {
        $q = & $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
        $gpuOk = [bool]$q
        $gpuDetail = ($q | Out-String).Trim()
    } catch {
        $gpuDetail = $_.Exception.Message
    }
}
$checks.Add((New-Check -Id 'nvidia-gpu' -Name 'NVIDIA GPU + driver' -Severity 'required' -Ok $gpuOk -Detail $gpuDetail)) | Out-Null
if ($gpuOk) { Write-Log -Level OK $gpuDetail } else { Write-Log -Level FAIL $gpuDetail }

if (-not $gpuOk -and -not $VerifyOnly -and $ConfirmDriverInstall) {
    Write-Log -Level STEP 'Jack confirmed NVIDIA App install'
    try {
        Install-WingetPackage -Id 'NVIDIA.NVIDIAApp' -Name 'NVIDIA App'
        $installed.Add('NVIDIA.NVIDIAApp') | Out-Null
        Write-Log -Level WARN 'NVIDIA App installed. Reboot, then re-run this installer. Not Ready until nvidia-smi works.'
    } catch {
        Write-Log -Level FAIL "NVIDIA App install failed: $($_.Exception.Message)"
    }
} elseif (-not $gpuOk) {
    Write-Log -Level WARN 'GPU driver will not be force-installed. Re-run with -ConfirmDriverInstall if Jack wants NVIDIA App via winget.'
}

# Optional packages
foreach ($opt in $WithOptional) {
    $map = @{
        OBS        = @{ id = 'OBSProject.OBSStudio'; name = 'OBS Studio' }
        Chrome     = @{ id = 'Google.Chrome'; name = 'Google Chrome' }
        NvidiaApp  = @{ id = 'NVIDIA.NVIDIAApp'; name = 'NVIDIA App' }
    }
    $pkg = $map[$opt]
    if ($VerifyOnly) {
        $present = Test-WingetPackage -Id $pkg.id
        $checks.Add((New-Check -Id $opt -Name $pkg.name -Severity 'soft' -Ok $present -Detail $(if ($present) { 'present' } else { 'not installed' }))) | Out-Null
        continue
    }
    try {
        Install-WingetPackage -Id $pkg.id -Name $pkg.name
        $installed.Add($pkg.id) | Out-Null
        $checks.Add((New-Check -Id $opt -Name $pkg.name -Severity 'soft' -Ok $true -Detail 'installed')) | Out-Null
        Write-Log -Level OK "$($pkg.name) installed (optional)"
    } catch {
        $checks.Add((New-Check -Id $opt -Name $pkg.name -Severity 'soft' -Ok $false -Detail $_.Exception.Message)) | Out-Null
        Write-Log -Level WARN "$($pkg.name) optional install failed: $($_.Exception.Message)"
    }
}

# Devices
$mic = Test-Microphone
$checks.Add((New-Check -Id 'microphone' -Name 'Microphone / capture endpoint' -Severity 'required' -Ok $mic.ok -Detail $mic.detail)) | Out-Null
if ($mic.ok) { Write-Log -Level OK 'Microphone/capture endpoint present' } else { Write-Log -Level FAIL 'No microphone/capture endpoint - NOT RECORDING capable' }

$cam = Test-Camera
$checks.Add((New-Check -Id 'webcam' -Name 'Camera' -Severity 'soft' -Ok $cam.ok -Detail $cam.detail)) | Out-Null
if ($cam.ok) {
    Write-Log -Level OK "Camera: $($cam.detail)"
} else {
    Write-Log -Level WARN 'No camera right now — game + mic recording still allowed. Plug the webcam in and pick it in Start-JackConsole.'
}

# Disk
if (-not $SessionDrive) {
    $SessionDrive = ([System.IO.Path]::GetPathRoot($RepoRoot)).Substring(0, 1)
}
$free = Get-FreeGb -DriveLetter $SessionDrive
$diskOk = $free -ge 50
$driveLabel = $SessionDrive + ':'
$checks.Add((New-Check -Id 'disk' -Name "Session disk $driveLabel at least 50 GB free" -Severity 'required' -Ok $diskOk -Detail "$free GB free")) | Out-Null
if ($diskOk) {
    Write-Log -Level OK "$free GB free on $driveLabel"
} else {
    Write-Log -Level FAIL "$free GB free on $driveLabel - need at least 50 GB"
}

# Displays (soft)
$nDisp = Get-DisplayCount
$dispOk = $nDisp -ge 2
$checks.Add((New-Check -Id 'displays' -Name 'Two monitors' -Severity 'soft' -Ok $dispOk -Detail "$nDisp display(s)")) | Out-Null
if ($dispOk) { Write-Log -Level OK "$nDisp displays" } else { Write-Log -Level WARN "$nDisp display(s) - desk console wants monitor 2" }

# LAN (soft)
$lan = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Private' }
$lanOk = $null -ne $lan
$checks.Add((New-Check -Id 'lan' -Name 'Private LAN for Android companion' -Severity 'soft' -Ok $lanOk -Detail $(if ($lanOk) { ($lan.Name -join ', ') } else { 'No Private profile - phone pairing will be blocked or noisy' }))) | Out-Null
if ($lanOk) { Write-Log -Level OK $checks[-1].detail } else { Write-Log -Level WARN $checks[-1].detail }

$requiredFailed = @($checks | Where-Object { $_.severity -eq 'required' -and -not $_.ok })
$ready = ($requiredFailed.Count -eq 0)
$reason = if ($ready) {
    'All required dependencies verified. Recording may be armed. Publishing still requires a committed session.'
} else {
    'NOT READY - recording must not start, and publish is forbidden. Failed: ' + (($requiredFailed | ForEach-Object { $_.name + ' (' + $_.detail + ')' }) -join '; ')
}

$state = [ordered]@{
    product       = $manifest.product
    host          = $manifest.host
    status        = $(if ($ready) { 'ready' } else { 'not-ready' })
    recording     = 'not-recording'
    publishRights = 'denied'
    reason        = $reason
    checkedAt     = (Get-Date).ToString('o')
    verifyOnly    = [bool]$VerifyOnly
    installed     = @($installed)
    docker        = @{
        required            = $false
        allowed_for_capture = $false
        verdict             = $manifest.docker.verdict
    }
    sessionDrive  = $SessionDrive
    checks        = $checks
}

Write-StateAtomic -State $state

if ($ready) {
    Write-Log -Level OK 'READY. Atomic install-state written. Rec may be armed. Publish stays denied until a session commits.'
    Write-Log "State: $StatePath"
    exit 0
}

Write-Log -Level FAIL $reason
Write-Log -Level FAIL 'NOT RECORDING. NOT READY. No publish rights.'
Write-Log "State: $StatePath"
if ($VerifyOnly) { exit 2 }
exit 2
