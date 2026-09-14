#Requires -Version 5.1
# Jack Session Console — records game / camera / mic / desktop audio as separate files.
# Does not overlay the game. Rec/Stop via buttons or F9/F10.

param()

Set-Location -LiteralPath $PSScriptRoot
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $arg = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arg
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms.dll -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class JackHotkeys : IMessageFilter {
    public const int WM_HOTKEY = 0x0312;
    public event Action<int> HotKeyPressed;
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            var h = HotKeyPressed;
            if (h != null) h(m.WParam.ToInt32());
            return true;
        }
        return false;
    }
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@

$script:AppData = Join-Path $env:APPDATA 'JackSessionConsole'
$script:SettingsPath = Join-Path $script:AppData 'settings.json'
$script:DefaultOut = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'JackSessions'
$script:Ffmpeg = $null
$script:Procs = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$script:Recording = $false
$script:SessionDir = $null
$script:SessionStart = $null
$script:LastSession = $null
$script:Markers = New-Object System.Collections.Generic.List[string]
$script:ErrTails = @{}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-FfmpegPath {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'),
        (Join-Path $env:ProgramFiles 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\ffmpeg\current\bin\ffmpeg.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $winget = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($winget) { return $winget.FullName }
    return $null
}

function Read-Settings {
    Ensure-Dir $script:AppData
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try { return Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        outDir     = $script:DefaultOut
        recordCam  = $true
        recordMic  = $true
        recordDesk = $true
        display    = 0
    }
}

function Save-Settings {
    Ensure-Dir $script:AppData
    $o = [ordered]@{
        outDir     = $txtOut.Text
        recordCam  = $chkCam.Checked
        recordMic  = $chkMic.Checked
        recordDesk = $chkDesk.Checked
        display    = $cmbDisplay.SelectedIndex
        camera     = [string]$cmbCam.SelectedItem
        mic        = [string]$cmbMic.SelectedItem
        deskAudio  = [string]$cmbDesk.SelectedItem
    }
    ($o | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-DshowDevices {
    $video = New-Object System.Collections.Generic.List[string]
    $audio = New-Object System.Collections.Generic.List[string]
    if (-not $script:Ffmpeg) { return @{ video = $video; audio = $audio } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit(8000) | Out-Null
    $section = ''
    foreach ($line in ($err -split "`r?`n")) {
        if ($line -match 'DirectShow video devices') { $section = 'video'; continue }
        if ($line -match 'DirectShow audio devices') { $section = 'audio'; continue }
        if ($line -match 'Alternative name') { continue }
        if ($line -match '"([^"]+)"') {
            $name = $Matches[1]
            if ($section -eq 'video') { $video.Add($name) }
            elseif ($section -eq 'audio') { $audio.Add($name) }
        }
    }
    return @{ video = $video; audio = $audio }
}

function Test-Nvenc {
    if (-not $script:Ffmpeg) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = '-hide_banner -encoders'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit(8000) | Out-Null
    return ($out -match 'h264_nvenc')
}

function Quote-Arg([string]$s) {
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

function Start-Ffmpeg([string[]]$ArgList, [string]$Tag) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = ($ArgList | ForEach-Object { $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:SessionDir
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true
    $script:ErrTails[$Tag] = New-Object System.Collections.Generic.List[string]
    $p.add_ErrorDataReceived({
        param($sender, $e)
        if ($e.Data) {
            $list = $script:ErrTails[$Tag]
            if ($list.Count -gt 80) { $list.RemoveAt(0) }
            $list.Add($e.Data)
        }
    })
    [void]$p.Start()
    $p.BeginErrorReadLine()
    $p.BeginOutputReadLine()
    Start-Sleep -Milliseconds 400
    if ($p.HasExited) {
        $tail = ($script:ErrTails[$Tag] | Select-Object -Last 12) -join "`n"
        throw "$Tag failed to start.`n$tail"
    }
    $p | Add-Member -NotePropertyName JackTag -NotePropertyValue $Tag
    $script:Procs.Add($p)
    return $p
}

function Stop-AllFfmpeg {
    foreach ($p in @($script:Procs)) {
        if ($p -and -not $p.HasExited) {
            try {
                $p.StandardInput.WriteLine('q')
                $p.StandardInput.Flush()
            } catch { }
        }
    }
    $deadline = (Get-Date).AddSeconds(8)
    foreach ($p in @($script:Procs)) {
        if (-not $p) { continue }
        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($left -lt 200) { $left = 200 }
        if (-not $p.HasExited) { [void]$p.WaitForExit($left) }
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
        $p.Dispose()
    }
    $script:Procs.Clear()
}

function Get-Elapsed {
    if (-not $script:SessionStart) { return '00:00:00' }
    $t = (Get-Date) - $script:SessionStart
    return '{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds
}

function Start-Session {
    if ($script:Recording) { return }
    if (-not $script:Ffmpeg) {
        [Windows.Forms.MessageBox]::Show('FFmpeg is not installed. Run Install.bat first (right-click, Run as administrator).', 'Jack Session Console') | Out-Null
        return
    }
    $outRoot = $txtOut.Text.Trim()
    if (-not $outRoot) { $outRoot = $script:DefaultOut }
    Ensure-Dir $outRoot
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $script:SessionDir = Join-Path $outRoot $stamp
    Ensure-Dir $script:SessionDir
    $script:Markers = New-Object System.Collections.Generic.List[string]
    $script:ErrTails = @{}
    $script:Procs.Clear()
    $nv = Test-Nvenc
    $vCodec = if ($nv) { @('-c:v', 'h264_nvenc', '-preset', 'p5', '-rc', 'vbr', '-cq', '23', '-b:v', '8M', '-maxrate', '12M') } else { @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '21') }

    try {
        $screen = [Windows.Forms.Screen]::AllScreens[$cmbDisplay.SelectedIndex]
        if (-not $screen) { $screen = [Windows.Forms.Screen]::PrimaryScreen }
        $idx = [int]$cmbDisplay.SelectedIndex
        $gamePath = Join-Path $script:SessionDir 'game.mp4'
        $dda = @(
            '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
            '-f', 'ddagrab', '-output_idx', "$idx", '-framerate', '60', '-draw_mouse', '1', '-i', 'desktop'
        ) + $vCodec + @('-pix_fmt', 'yuv420p', '-movflags', '+faststart', (Quote-Arg $gamePath))
        try {
            Start-Ffmpeg -ArgList $dda -Tag 'game'
        } catch {
            $gdi = @(
                '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
                '-f', 'gdigrab', '-framerate', '60',
                '-offset_x', "$([int]$screen.Bounds.X)", '-offset_y', "$([int]$screen.Bounds.Y)",
                '-video_size', ('{0}x{1}' -f $screen.Bounds.Width, $screen.Bounds.Height),
                '-i', 'desktop'
            ) + $vCodec + @('-pix_fmt', 'yuv420p', '-movflags', '+faststart', (Quote-Arg $gamePath))
            Start-Ffmpeg -ArgList $gdi -Tag 'game'
        }

        if ($chkCam.Checked -and $cmbCam.SelectedItem) {
            $camPath = Join-Path $script:SessionDir 'cam.mp4'
            $camArgs = @(
                '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
                '-f', 'dshow', '-rtbufsize', '256M', '-framerate', '30',
                '-i', ('video="{0}"' -f (([string]$cmbCam.SelectedItem) -replace '"', '')),
                '-vf', 'scale=1280:-2',
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
                '-pix_fmt', 'yuv420p', '-an',
                (Quote-Arg $camPath)
            )
            Start-Ffmpeg -ArgList $camArgs -Tag 'cam'
        }

        if ($chkMic.Checked -and $cmbMic.SelectedItem) {
            $micPath = Join-Path $script:SessionDir 'mic.m4a'
            $micArgs = @(
                '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
                '-f', 'dshow', '-rtbufsize', '64M',
                '-i', ('audio="{0}"' -f (([string]$cmbMic.SelectedItem) -replace '"', '')),
                '-c:a', 'aac', '-b:a', '192k',
                (Quote-Arg $micPath)
            )
            Start-Ffmpeg -ArgList $micArgs -Tag 'mic'
        }

        if ($chkDesk.Checked -and $cmbDesk.SelectedItem) {
            $deskPath = Join-Path $script:SessionDir 'desktop.m4a'
            $deskName = [string]$cmbDesk.SelectedItem
            $deskArgs = @(
                '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
                '-f', 'dshow', '-rtbufsize', '64M',
                '-i', ('audio="{0}"' -f ($deskName -replace '"', '')),
                '-c:a', 'aac', '-b:a', '192k',
                (Quote-Arg $deskPath)
            )
            try {
                Start-Ffmpeg -ArgList $deskArgs -Tag 'desktop'
            } catch {
                $wasapi = @(
                    '-hide_banner', '-y', '-loglevel', 'warning', '-stats',
                    '-f', 'wasapi', '-i', (Quote-Arg $deskName),
                    '-c:a', 'aac', '-b:a', '192k',
                    (Quote-Arg $deskPath)
                )
                Start-Ffmpeg -ArgList $wasapi -Tag 'desktop'
            }
        }
    } catch {
        Stop-AllFfmpeg
        [Windows.Forms.MessageBox]::Show("Could not start recording.`n$($_.Exception.Message)", 'Jack Session Console') | Out-Null
        return
    }

    $script:Recording = $true
    $script:SessionStart = Get-Date
    $manifest = [ordered]@{
        product   = 'Jack Session Console'
        started   = $script:SessionStart.ToString('o')
        dir       = $script:SessionDir
        nvenc     = $nv
        display   = [string]$cmbDisplay.SelectedItem
        camera    = $(if ($chkCam.Checked) { [string]$cmbCam.SelectedItem } else { $null })
        mic       = $(if ($chkMic.Checked) { [string]$cmbMic.SelectedItem } else { $null })
        deskAudio = $(if ($chkDesk.Checked) { [string]$cmbDesk.SelectedItem } else { $null })
        tracks    = @('game.mp4') + $(if ($chkCam.Checked) { @('cam.mp4') } else { @() }) + $(if ($chkMic.Checked) { @('mic.m4a') } else { @() }) + $(if ($chkDesk.Checked) { @('desktop.m4a') } else { @() })
    }
    ($manifest | ConvertTo-Json) | Set-Content (Join-Path $script:SessionDir 'session.json') -Encoding UTF8
    Set-UiRecording $true
    Save-Settings
}

function Stop-Session {
    if (-not $script:Recording) { return }
    Stop-AllFfmpeg
    $script:Recording = $false
    $script:LastSession = $script:SessionDir
    if ($script:Markers.Count -gt 0) {
        $script:Markers | Set-Content (Join-Path $script:SessionDir 'markers.txt') -Encoding UTF8
    }
    $end = Get-Date
    try {
        $m = Get-Content (Join-Path $script:SessionDir 'session.json') -Raw | ConvertFrom-Json
        $m | Add-Member stopped $end.ToString('o') -Force
        $m | Add-Member elapsed (Get-Elapsed) -Force
        ($m | ConvertTo-Json) | Set-Content (Join-Path $script:SessionDir 'session.json') -Encoding UTF8
    } catch { }
    Set-UiRecording $false
    $lblLast.Text = "Last session: $script:LastSession"
}

function Add-Marker {
    if (-not $script:Recording) { return }
    $line = Get-Elapsed
    $script:Markers.Add($line)
    $lblMark.Text = "Marker $line"
}

function Set-UiRecording([bool]$on) {
    if ($on) {
        $lblStatus.Text = 'RECORDING'
        $lblStatus.ForeColor = [Drawing.Color]::FromArgb(255, 70, 70)
        $btnRec.Enabled = $false
        $btnStop.Enabled = $true
        $btnMix.Enabled = $false
        $cmbDisplay.Enabled = $false
        $cmbCam.Enabled = $false
        $cmbMic.Enabled = $false
        $cmbDesk.Enabled = $false
    } else {
        $lblStatus.Text = 'NOT RECORDING'
        $lblStatus.ForeColor = [Drawing.Color]::FromArgb(180, 220, 140)
        $btnRec.Enabled = $true
        $btnStop.Enabled = $false
        $btnMix.Enabled = [bool]$script:LastSession
        $cmbDisplay.Enabled = $true
        $cmbCam.Enabled = $true
        $cmbMic.Enabled = $true
        $cmbDesk.Enabled = $true
        $lblElapsed.Text = '00:00:00'
    }
}

function New-YoutubeMix {
    if (-not $script:LastSession) { return }
    if ($script:Recording) {
        [Windows.Forms.MessageBox]::Show('Stop recording first. Mix after the session — not during the game.', 'Jack Session Console') | Out-Null
        return
    }
    $game = Join-Path $script:LastSession 'game.mp4'
    $cam = Join-Path $script:LastSession 'cam.mp4'
    $mic = Join-Path $script:LastSession 'mic.m4a'
    $desk = Join-Path $script:LastSession 'desktop.m4a'
    $mix = Join-Path $script:LastSession 'youtube-mix.mp4'
    if (-not (Test-Path -LiteralPath $game)) {
        [Windows.Forms.MessageBox]::Show('No game.mp4 in the last session.', 'Jack Session Console') | Out-Null
        return
    }
    $lblStatus.Text = 'MIXING (do this after the game)...'
    $lblStatus.ForeColor = [Drawing.Color]::Khaki
    [Windows.Forms.Application]::DoEvents()
    $fc = '[0:v]setpts=PTS-STARTPTS[base]'
    $maps = @('-map', '[vout]')
    if (Test-Path -LiteralPath $cam) {
        $fc += ';[1:v]scale=iw/5:-2[cam];[base][cam]overlay=W-w-24:H-h-24[vout]'
    } else {
        $fc += ';[base]format=yuv420p[vout]'
    }
    $inputs = @('-i', (Quote-Arg $game))
    $idx = 1
    if (Test-Path -LiteralPath $cam) { $inputs += @('-i', (Quote-Arg $cam)); $idx++ }
    $audioIns = @()
    if (Test-Path -LiteralPath $mic) { $inputs += @('-i', (Quote-Arg $mic)); $audioIns += $idx; $idx++ }
    if (Test-Path -LiteralPath $desk) { $inputs += @('-i', (Quote-Arg $desk)); $audioIns += $idx; $idx++ }
    if ($audioIns.Count -eq 1) {
        $maps += @('-map', ('{0}:a' -f $audioIns[0]))
    } elseif ($audioIns.Count -ge 2) {
        $parts = @()
        foreach ($a in $audioIns) { $parts += ('[{0}:a]' -f $a) }
        $fc += (';{0}amix=inputs={1}:duration=longest:normalize=0[aout]' -f ($parts -join ''), $audioIns.Count)
        $maps += @('-map', '[aout]')
    }
    $ffArgs = @('-hide_banner', '-y') + $inputs + @('-filter_complex', (Quote-Arg $fc)) + $maps + @(
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-shortest',
        (Quote-Arg $mix)
    )
    $mixLog = Join-Path $script:LastSession 'mix.log'
    $p = Start-Process -FilePath $script:Ffmpeg -ArgumentList ($ffArgs -join ' ') -Wait -PassThru -NoNewWindow -RedirectStandardError $mixLog
    Set-UiRecording $false
    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $mix)) {
        [Windows.Forms.MessageBox]::Show("YouTube mix saved:`n$mix`n`nRaw tracks are still in that folder for editing.", 'Jack Session Console') | Out-Null
        Invoke-Item $script:LastSession
    } else {
        [Windows.Forms.MessageBox]::Show("Mix failed. See mix.log in:`n$script:LastSession", 'Jack Session Console') | Out-Null
    }
}

# --- UI ---
$form = New-Object Windows.Forms.Form
$form.Text = 'Jack Session Console'
$form.Size = New-Object Drawing.Size(560, 520)
$form.MinimumSize = New-Object Drawing.Size(520, 480)
$form.BackColor = [Drawing.Color]::FromArgb(28, 28, 30)
$form.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$screens = [Windows.Forms.Screen]::AllScreens
$home = if ($screens.Count -gt 1) { $screens | Where-Object { -not $_.Primary } | Select-Object -First 1 } else { $screens[0] }
$form.Location = New-Object Drawing.Point(($home.WorkingArea.X + 40), ($home.WorkingArea.Y + 40))

function Add-Label($text, $x, $y, $w = 200, $h = 24) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h)
    $l.ForeColor = [Drawing.Color]::WhiteSmoke
    $form.Controls.Add($l)
    return $l
}

$lblStatus = Add-Label 'NOT RECORDING' 20 16 300 36
$lblStatus.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [Drawing.Color]::FromArgb(180, 220, 140)

$lblElapsed = Add-Label '00:00:00' 20 56 200 24
$lblElapsed.Font = New-Object Drawing.Font('Consolas', 14)

$lblMark = Add-Label '' 220 56 300 24
$lblMark.ForeColor = [Drawing.Color]::Silver

$btnRec = New-Object Windows.Forms.Button
$btnRec.Text = 'REC  (F9)'
$btnRec.Location = New-Object Drawing.Point(20, 92)
$btnRec.Size = New-Object Drawing.Size(150, 40)
$btnRec.BackColor = [Drawing.Color]::FromArgb(160, 32, 32)
$btnRec.ForeColor = [Drawing.Color]::White
$btnRec.FlatStyle = 'Flat'
$form.Controls.Add($btnRec)

$btnStop = New-Object Windows.Forms.Button
$btnStop.Text = 'STOP  (F10)'
$btnStop.Location = New-Object Drawing.Point(180, 92)
$btnStop.Size = New-Object Drawing.Size(150, 40)
$btnStop.BackColor = [Drawing.Color]::FromArgb(50, 50, 54)
$btnStop.ForeColor = [Drawing.Color]::White
$btnStop.FlatStyle = 'Flat'
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnMark = New-Object Windows.Forms.Button
$btnMark.Text = 'Marker (F8)'
$btnMark.Location = New-Object Drawing.Point(340, 92)
$btnMark.Size = New-Object Drawing.Size(180, 40)
$btnMark.BackColor = [Drawing.Color]::FromArgb(50, 50, 54)
$btnMark.ForeColor = [Drawing.Color]::White
$btnMark.FlatStyle = 'Flat'
$form.Controls.Add($btnMark)

Add-Label 'Game display' 20 150 200 22 | Out-Null
$cmbDisplay = New-Object Windows.Forms.ComboBox
$cmbDisplay.DropDownStyle = 'DropDownList'
$cmbDisplay.Location = New-Object Drawing.Point(20, 172)
$cmbDisplay.Size = New-Object Drawing.Size(500, 28)
$cmbDisplay.BackColor = [Drawing.Color]::FromArgb(40, 40, 44)
$cmbDisplay.ForeColor = [Drawing.Color]::White
$form.Controls.Add($cmbDisplay)
$i = 0
foreach ($s in $screens) {
    $tag = if ($s.Primary) { 'primary — put the GAME here' } else { 'desk / this console' }
    [void]$cmbDisplay.Items.Add(('Monitor {0}: {1}x{2} @ {3},{4}  ({5})' -f ($i + 1), $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $tag))
    $i++
}
if ($cmbDisplay.Items.Count -gt 0) { $cmbDisplay.SelectedIndex = 0 }

Add-Label 'Camera' 20 210 200 22 | Out-Null
$cmbCam = New-Object Windows.Forms.ComboBox
$cmbCam.DropDownStyle = 'DropDownList'
$cmbCam.Location = New-Object Drawing.Point(20, 232)
$cmbCam.Size = New-Object Drawing.Size(380, 28)
$cmbCam.BackColor = [Drawing.Color]::FromArgb(40, 40, 44)
$cmbCam.ForeColor = [Drawing.Color]::White
$form.Controls.Add($cmbCam)
$chkCam = New-Object Windows.Forms.CheckBox
$chkCam.Text = 'Record'
$chkCam.Checked = $true
$chkCam.Location = New-Object Drawing.Point(410, 234)
$chkCam.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Controls.Add($chkCam)

Add-Label 'Your mic' 20 268 200 22 | Out-Null
$cmbMic = New-Object Windows.Forms.ComboBox
$cmbMic.DropDownStyle = 'DropDownList'
$cmbMic.Location = New-Object Drawing.Point(20, 290)
$cmbMic.Size = New-Object Drawing.Size(380, 28)
$cmbMic.BackColor = [Drawing.Color]::FromArgb(40, 40, 44)
$cmbMic.ForeColor = [Drawing.Color]::White
$form.Controls.Add($cmbMic)
$chkMic = New-Object Windows.Forms.CheckBox
$chkMic.Text = 'Record'
$chkMic.Checked = $true
$chkMic.Location = New-Object Drawing.Point(410, 292)
$chkMic.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Controls.Add($chkMic)

Add-Label 'Game / Discord audio (what you hear)' 20 326 400 22 | Out-Null
$cmbDesk = New-Object Windows.Forms.ComboBox
$cmbDesk.DropDownStyle = 'DropDownList'
$cmbDesk.Location = New-Object Drawing.Point(20, 348)
$cmbDesk.Size = New-Object Drawing.Size(380, 28)
$cmbDesk.BackColor = [Drawing.Color]::FromArgb(40, 40, 44)
$cmbDesk.ForeColor = [Drawing.Color]::White
$form.Controls.Add($cmbDesk)
$chkDesk = New-Object Windows.Forms.CheckBox
$chkDesk.Text = 'Record'
$chkDesk.Checked = $true
$chkDesk.Location = New-Object Drawing.Point(410, 350)
$chkDesk.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Controls.Add($chkDesk)

Add-Label 'Save sessions to' 20 384 200 22 | Out-Null
$txtOut = New-Object Windows.Forms.TextBox
$txtOut.Location = New-Object Drawing.Point(20, 406)
$txtOut.Size = New-Object Drawing.Size(380, 26)
$txtOut.BackColor = [Drawing.Color]::FromArgb(40, 40, 44)
$txtOut.ForeColor = [Drawing.Color]::White
$txtOut.Text = $script:DefaultOut
$form.Controls.Add($txtOut)
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Browse'
$btnBrowse.Location = New-Object Drawing.Point(410, 404)
$btnBrowse.Size = New-Object Drawing.Size(110, 28)
$btnBrowse.BackColor = [Drawing.Color]::FromArgb(50, 50, 54)
$btnBrowse.ForeColor = [Drawing.Color]::White
$btnBrowse.FlatStyle = 'Flat'
$form.Controls.Add($btnBrowse)

$btnMix = New-Object Windows.Forms.Button
$btnMix.Text = 'Make YouTube mix (after Stop)'
$btnMix.Location = New-Object Drawing.Point(20, 444)
$btnMix.Size = New-Object Drawing.Size(280, 28)
$btnMix.BackColor = [Drawing.Color]::FromArgb(50, 50, 54)
$btnMix.ForeColor = [Drawing.Color]::White
$btnMix.FlatStyle = 'Flat'
$btnMix.Enabled = $false
$form.Controls.Add($btnMix)

$lblLast = Add-Label 'Nothing recorded this session yet.' 310 446 230 28
$lblLast.ForeColor = [Drawing.Color]::Silver

$script:Ffmpeg = Get-FfmpegPath
$devs = Get-DshowDevices
foreach ($v in $devs.video) { [void]$cmbCam.Items.Add($v) }
foreach ($a in $devs.audio) {
    [void]$cmbMic.Items.Add($a)
    [void]$cmbDesk.Items.Add($a)
}
if ($cmbCam.Items.Count -gt 0) { $cmbCam.SelectedIndex = 0 }
if ($cmbMic.Items.Count -gt 0) { $cmbMic.SelectedIndex = 0 }
# Prefer a loopback-ish name for desktop audio
$loop = $null
foreach ($a in $devs.audio) {
    if ($a -match 'stereo mix|loopback|what u hear|wave out|cable output|voicemeeter') { $loop = $a; break }
}
if ($loop) { $cmbDesk.SelectedItem = $loop }
elseif ($cmbDesk.Items.Count -gt 0) { $cmbDesk.SelectedIndex = 0 }

$cfg = Read-Settings
if ($cfg.outDir) { $txtOut.Text = $cfg.outDir }
if ($null -ne $cfg.recordCam) { $chkCam.Checked = [bool]$cfg.recordCam }
if ($null -ne $cfg.recordMic) { $chkMic.Checked = [bool]$cfg.recordMic }
if ($null -ne $cfg.recordDesk) { $chkDesk.Checked = [bool]$cfg.recordDesk }
if ($cfg.camera -and $cmbCam.Items.Contains($cfg.camera)) { $cmbCam.SelectedItem = $cfg.camera }
if ($cfg.mic -and $cmbMic.Items.Contains($cfg.mic)) { $cmbMic.SelectedItem = $cfg.mic }
if ($cfg.deskAudio -and $cmbDesk.Items.Contains($cfg.deskAudio)) { $cmbDesk.SelectedItem = $cfg.deskAudio }
if ($cfg.display -ge 0 -and $cfg.display -lt $cmbDisplay.Items.Count) { $cmbDisplay.SelectedIndex = $cfg.display }

if (-not $script:Ffmpeg) {
    $lblStatus.Text = 'NOT READY — run Install.bat'
    $lblStatus.ForeColor = [Drawing.Color]::Orange
    $btnRec.Enabled = $false
}

$btnRec.Add_Click({ Start-Session })
$btnStop.Add_Click({ Stop-Session })
$btnMark.Add_Click({ Add-Marker })
$btnMix.Add_Click({ New-YoutubeMix })
$btnBrowse.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.SelectedPath = $txtOut.Text
    if ($d.ShowDialog() -eq 'OK') { $txtOut.Text = $d.SelectedPath }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    if ($script:Recording) { $lblElapsed.Text = Get-Elapsed }
})
$timer.Start()

$hot = New-Object JackHotkeys
$hot.Add_HotKeyPressed({
    param($id)
    switch ($id) {
        1 { if ($script:Recording) { Stop-Session } else { Start-Session } }
        2 { Stop-Session }
        3 { Add-Marker }
    }
})
[Windows.Forms.Application]::AddMessageFilter($hot)

$form.Add_Shown({
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 1, 0, 0x78) # F9
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 2, 0, 0x79) # F10
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 3, 0, 0x77) # F8
})
$form.Add_FormClosing({
    if ($script:Recording) { Stop-Session }
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 1)
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 2)
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 3)
    Save-Settings
    $timer.Stop()
})

[Windows.Forms.Application]::EnableVisualStyles()
[void]$form.ShowDialog()
