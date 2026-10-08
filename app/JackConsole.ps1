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

# FFmpeg writes its log on a threadpool thread. A PowerShell event scriptblock
# on that thread tears down the runspace and closes this window, while ffmpeg
# keeps recording. The sink stays in C# so the console survives.
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Collections.Concurrent;
public class ErrTail {
    readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    public void Attach(Process p) {
        p.ErrorDataReceived += OnLine;
        p.OutputDataReceived += OnLine;
    }
    public void OnLine(object sender, DataReceivedEventArgs e) {
        if (string.IsNullOrEmpty(e.Data)) return;
        lines.Enqueue(e.Data);
        string dump;
        while (lines.Count > 80 && lines.TryDequeue(out dump)) { }
    }
    public string Tail(int n) {
        string[] arr = lines.ToArray();
        int start = Math.Max(0, arr.Length - n);
        if (start >= arr.Length) return "";
        string[] slice = new string[arr.Length - start];
        Array.Copy(arr, start, slice, 0, slice.Length);
        return string.Join("\n", slice);
    }
}
"@

# If this process dies, the job handle closes and Windows kills every ffmpeg
# still in it. Recording uses a fragmented MP4 so that kill still leaves a playable file.
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class JackJob : IDisposable {
    IntPtr handle;
    bool disposed;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const int JobObjectExtendedLimitInformation = 9;
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr hJob, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint cb);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    public JackJob() {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        uint size = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ref info, size))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public void AddProcess(Process p) {
        if (!AssignProcessToJobObject(handle, p.Handle))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() {
        if (disposed) return;
        disposed = true;
        if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; }
    }
}
"@

$script:AppData = Join-Path $env:APPDATA 'JackSessionConsole'
$script:SettingsPath = Join-Path $script:AppData 'settings.json'
$script:PidFile = Join-Path $script:AppData 'recording-pids.json'
$script:Tray = $null
$script:DefaultOut = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'JackSessions'
$script:Ffmpeg = $null
$script:HasDdagrab = $false
$script:Job = $null
$script:GameCapture = $null
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
    $bundled = Join-Path $PSScriptRoot 'ffmpeg\ffmpeg.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
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
    # FFmpeg 6 and older print a "DirectShow audio devices" header, then quoted names.
    # FFmpeg 7+ drops that header and tags the name on the same line: "Mic" (audio).
    $section = ''
    foreach ($line in ($err -split "`r?`n")) {
        if ($line -match 'DirectShow video devices') { $section = 'video'; continue }
        if ($line -match 'DirectShow audio devices') { $section = 'audio'; continue }
        if ($line -match 'Alternative name') { continue }
        if ($line -match '"([^"]+)"') {
            $name = $Matches[1]
            if ($name -like '@device*') { continue }
            $isVideo = $line -match '\(video'
            $isAudio = $line -match '\(audio'
            if (-not $isVideo -and -not $isAudio) {
                if ($section -eq 'video') { $isVideo = $true }
                elseif ($section -eq 'audio') { $isAudio = $true }
            }
            if ($isVideo) { $video.Add($name) }
            if ($isAudio) { $audio.Add($name) }
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

function Test-FfmpegDevice([string]$Name) {
    if (-not $script:Ffmpeg) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = '-hide_banner -devices'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit(8000) | Out-Null
    return ($out -match ('\b' + [regex]::Escape($Name) + '\b'))
}

function Get-CaptureJob {
    if ($script:Job) { return $script:Job }
    try { $script:Job = New-Object JackJob } catch { $script:Job = $null }
    return $script:Job
}

function Get-LiveNvencArgs {
    # p4, no lookahead, no B-frames: one NVENC session, little extra VRAM, game keeps the shaders.
    return @(
        '-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll', '-rc', 'vbr',
        '-cq', '23', '-b:v', '8M', '-maxrate', '12M',
        '-rc-lookahead', '0', '-bf', '0', '-spatial-aq', '0', '-temporal-aq', '0',
        '-multipass', 'disabled'
    )
}

function Get-FragFlags {
    # Playable even if the process is killed before it can finish a normal moov atom.
    return @('-movflags', '+frag_keyframe+empty_moov+default_base_moof')
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
    $sink = New-Object ErrTail
    $script:ErrTails[$Tag] = $sink
    $sink.Attach($p)
    [void]$p.Start()
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    try {
        $job = Get-CaptureJob
        if ($job) { $job.AddProcess($p) }
    } catch { }
    $p.BeginErrorReadLine()
    $p.BeginOutputReadLine()
    $p | Add-Member -NotePropertyName JackTag -NotePropertyValue $Tag
    $script:Procs.Add($p)
    Save-RecordingPids
    Start-Sleep -Milliseconds 400
    if ($p.HasExited) {
        $tail = $sink.Tail(12)
        throw "$Tag failed to start.`n$tail"
    }
    return $p
}

function Save-RecordingPids {
    try {
        Ensure-Dir $script:AppData
        $ids = New-Object System.Collections.Generic.List[int]
        foreach ($proc in @($script:Procs)) {
            if ($proc -and -not $proc.HasExited) { $ids.Add([int]$proc.Id) }
        }
        $payload = [pscustomobject]@{
            pids = @($ids)
            dir  = [string]$script:SessionDir
        }
        ($payload | ConvertTo-Json) | Set-Content -LiteralPath $script:PidFile -Encoding UTF8
    } catch { }
}

function Clear-RecordingPids {
    try {
        if (Test-Path -LiteralPath $script:PidFile) {
            Remove-Item -LiteralPath $script:PidFile -Force
        }
    } catch { }
}

function Stop-OrphanFfmpeg {
    # If a previous console crashed, ffmpeg is still recording with no Stop button.
    $killed = 0
    if (-not (Test-Path -LiteralPath $script:PidFile)) { return 0 }
    try {
        $saved = Get-Content -LiteralPath $script:PidFile -Raw | ConvertFrom-Json
        $allParentsDead = $true
        foreach ($id in @($saved.pids)) {
            $procId = [int]$id
            $op = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $op) { continue }
            if ($op.ProcessName -ne 'ffmpeg') { $allParentsDead = $false; continue }
            $parentAlive = $false
            try {
                $w = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
                if ($w.ParentProcessId) {
                    $parentAlive = $null -ne (Get-Process -Id ([int]$w.ParentProcessId) -ErrorAction SilentlyContinue)
                }
            } catch { }
            if ($parentAlive) { $allParentsDead = $false; continue }
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killed++
            } catch { }
        }
        if ($allParentsDead) { Clear-RecordingPids }
    } catch { }
    return $killed
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
    Clear-RecordingPids
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
    $script:GameCapture = $null
    if (-not (Test-Nvenc)) {
        [Windows.Forms.MessageBox]::Show('This FFmpeg has no NVENC. Recording the game on the CPU would hitch the match, so nothing was started.', 'Jack Session Console') | Out-Null
        return
    }
    try {
        $qual = Split-Path -Qualifier $outRoot
        if ($qual) {
            $free = (Get-PSDrive -Name $qual.TrimEnd(':') -ErrorAction Stop).Free
            if ($free -lt 8GB) {
                [Windows.Forms.MessageBox]::Show('Less than 8 GB free on the session drive. Free some space, then record.', 'Jack Session Console') | Out-Null
                return
            }
        }
    } catch { }

    $vCodec = Get-LiveNvencArgs
    $frag = Get-FragFlags
    $warnings = New-Object System.Collections.Generic.List[string]
    try {
        $screen = [Windows.Forms.Screen]::AllScreens[$cmbDisplay.SelectedIndex]
        if (-not $screen) { $screen = [Windows.Forms.Screen]::PrimaryScreen }
        $idx = [int]$cmbDisplay.SelectedIndex
        $gamePath = Join-Path $script:SessionDir 'game.mp4'
        $startedGame = $false
        if ($script:HasDdagrab) {
            $gpu = @(
                '-hide_banner', '-y', '-loglevel', 'warning',
                '-f', 'ddagrab', '-output_idx', "$idx", '-framerate', '60', '-draw_mouse', '1', '-i', 'desktop',
                '-vf', 'scale_d3d11=format=nv12'
            ) + $vCodec + $frag + @((Quote-Arg $gamePath))
            try {
                Start-Ffmpeg -ArgList $gpu -Tag 'game'
                $script:GameCapture = 'ddagrab'
                $startedGame = $true
            } catch {
                $plain = @(
                    '-hide_banner', '-y', '-loglevel', 'warning',
                    '-f', 'ddagrab', '-output_idx', "$idx", '-framerate', '60', '-draw_mouse', '1', '-i', 'desktop'
                ) + $vCodec + $frag + @((Quote-Arg $gamePath))
                try {
                    Start-Ffmpeg -ArgList $plain -Tag 'game'
                    $script:GameCapture = 'ddagrab'
                    $startedGame = $true
                } catch { }
            }
        }
        if (-not $startedGame) {
            $gdi = @(
                '-hide_banner', '-y', '-loglevel', 'warning',
                '-f', 'gdigrab', '-framerate', '60',
                '-offset_x', "$([int]$screen.Bounds.X)", '-offset_y', "$([int]$screen.Bounds.Y)",
                '-video_size', ('{0}x{1}' -f $screen.Bounds.Width, $screen.Bounds.Height),
                '-i', 'desktop'
            ) + $vCodec + @('-pix_fmt', 'yuv420p') + $frag + @((Quote-Arg $gamePath))
            Start-Ffmpeg -ArgList $gdi -Tag 'game'
            $script:GameCapture = 'gdi'
        }

        if ($chkCam.Checked -and $cmbCam.SelectedItem) {
            try {
                $camPath = Join-Path $script:SessionDir 'cam.mp4'
                $camArgs = @(
                    '-hide_banner', '-y', '-loglevel', 'warning',
                    '-f', 'dshow', '-rtbufsize', '64M', '-framerate', '30',
                    '-i', ('video="{0}"' -f (([string]$cmbCam.SelectedItem) -replace '"', '')),
                    '-vf', 'scale=1280:-2',
                    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
                    '-pix_fmt', 'yuv420p', '-an'
                ) + $frag + @((Quote-Arg $camPath))
                Start-Ffmpeg -ArgList $camArgs -Tag 'cam'
            } catch {
                $warnings.Add('Camera: ' + $_.Exception.Message)
            }
        }

        if ($chkMic.Checked -and $cmbMic.SelectedItem) {
            try {
                $micPath = Join-Path $script:SessionDir 'mic.m4a'
                $micArgs = @(
                    '-hide_banner', '-y', '-loglevel', 'warning',
                    '-f', 'dshow', '-rtbufsize', '64M',
                    '-i', ('audio="{0}"' -f (([string]$cmbMic.SelectedItem) -replace '"', '')),
                    '-c:a', 'aac', '-b:a', '192k'
                ) + $frag + @((Quote-Arg $micPath))
                Start-Ffmpeg -ArgList $micArgs -Tag 'mic'
            } catch {
                $warnings.Add('Mic: ' + $_.Exception.Message)
            }
        }

        if ($chkDesk.Checked -and $cmbDesk.SelectedItem) {
            try {
                $deskPath = Join-Path $script:SessionDir 'desktop.m4a'
                $deskName = [string]$cmbDesk.SelectedItem
                $deskArgs = @(
                    '-hide_banner', '-y', '-loglevel', 'warning',
                    '-f', 'dshow', '-rtbufsize', '64M',
                    '-i', ('audio="{0}"' -f ($deskName -replace '"', '')),
                    '-c:a', 'aac', '-b:a', '192k'
                ) + $frag + @((Quote-Arg $deskPath))
                Start-Ffmpeg -ArgList $deskArgs -Tag 'desktop'
            } catch {
                $warnings.Add('Desktop audio: ' + $_.Exception.Message)
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
        nvenc     = $true
        capture   = [string]$script:GameCapture
        display   = [string]$cmbDisplay.SelectedItem
        camera    = $(if ($chkCam.Checked) { [string]$cmbCam.SelectedItem } else { $null })
        mic       = $(if ($chkMic.Checked) { [string]$cmbMic.SelectedItem } else { $null })
        deskAudio = $(if ($chkDesk.Checked) { [string]$cmbDesk.SelectedItem } else { $null })
        tracks    = @('game.mp4') + $(if ($chkCam.Checked) { @('cam.mp4') } else { @() }) + $(if ($chkMic.Checked) { @('mic.m4a') } else { @() }) + $(if ($chkDesk.Checked) { @('desktop.m4a') } else { @() })
    }
    ($manifest | ConvertTo-Json) | Set-Content (Join-Path $script:SessionDir 'session.json') -Encoding UTF8
    Set-UiRecording $true
    Save-Settings
    if ($warnings.Count -gt 0) {
        $lblMark.Text = 'Game is recording. A side track failed.'
        [Windows.Forms.MessageBox]::Show(($warnings -join "`n`n"), 'Jack Session Console') | Out-Null
    }
}

function Repair-Mp4([string]$Path) {
    if (-not $script:Ffmpeg) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path).Length -lt 4096) { return }
    $tmp = $Path + '.fast.mp4'
    $args = @('-hide_banner', '-y', '-loglevel', 'error', '-i', (Quote-Arg $Path), '-c', 'copy', '-movflags', '+faststart', (Quote-Arg $tmp))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = ($args -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { } }
    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 4096) {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } else {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Session {
    if (-not $script:Recording) { return }
    Stop-AllFfmpeg
    $script:Recording = $false
    $script:LastSession = $script:SessionDir
    foreach ($name in @('game.mp4', 'cam.mp4', 'mic.m4a', 'desktop.m4a')) {
        Repair-Mp4 (Join-Path $script:SessionDir $name)
    }
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

function Show-ConsoleWindow {
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.Show()
    $form.Activate()
}

function Set-UiRecording([bool]$on) {
    $form.ShowInTaskbar = $true
    if ($on) {
        $form.Text = 'Jack Session Console — RECORDING'
        $lblStatus.Text = if ($script:GameCapture -eq 'gdi') { 'RECORDING (GDI)' } else { 'RECORDING' }
        $lblStatus.ForeColor = [Drawing.Color]::FromArgb(255, 70, 70)
        $lblMark.Text = 'Stays open — press Stop or F10'
        $btnRec.Enabled = $false
        $btnStop.Enabled = $true
        $btnMix.Enabled = $false
        $cmbDisplay.Enabled = $false
        $cmbCam.Enabled = $false
        $cmbMic.Enabled = $false
        $cmbDesk.Enabled = $false
        if ($script:Tray) { $script:Tray.Text = 'Recording — click to stop' }
    } else {
        $form.Text = 'Jack Session Console'
        $lblStatus.Text = 'NOT RECORDING'
        $lblStatus.ForeColor = [Drawing.Color]::FromArgb(180, 220, 140)
        $lblMark.Text = ''
        $btnRec.Enabled = $true
        $btnStop.Enabled = $false
        $btnMix.Enabled = [bool]$script:LastSession
        $cmbDisplay.Enabled = $true
        $cmbCam.Enabled = $true
        $cmbMic.Enabled = $true
        $cmbDesk.Enabled = $true
        $lblElapsed.Text = '00:00:00'
        if ($script:Tray) { $script:Tray.Text = 'Jack Session Console' }
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

# A click-handler error must not end the message loop and close the window.
try {
    [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
[Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try {
        Ensure-Dir $script:AppData
        $line = '{0}  {1}' -f (Get-Date).ToString('o'), $e.Exception.ToString()
        Add-Content -LiteralPath (Join-Path $script:AppData 'console.log') -Value $line
    } catch { }
    try {
        [Windows.Forms.MessageBox]::Show("Something went wrong, but the window stays open.`n$($e.Exception.Message)", 'Jack Session Console') | Out-Null
    } catch { }
})

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
$deskScreen = if ($screens.Count -gt 1) { $screens | Where-Object { -not $_.Primary } | Select-Object -First 1 } else { $screens[0] }
$form.Location = New-Object Drawing.Point(($deskScreen.WorkingArea.X + 40), ($deskScreen.WorkingArea.Y + 40))

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
$script:HasDdagrab = Test-FfmpegDevice 'ddagrab'
$devs = Get-DshowDevices
foreach ($v in $devs.video) { [void]$cmbCam.Items.Add($v) }
foreach ($a in $devs.audio) {
    [void]$cmbMic.Items.Add($a)
    [void]$cmbDesk.Items.Add($a)
}
if ($cmbCam.Items.Count -gt 0) { $cmbCam.SelectedIndex = 0 } else { $chkCam.Checked = $false }
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
if ($cmbCam.Items.Count -eq 0) { $chkCam.Checked = $false }

if (-not $script:Ffmpeg) {
    $lblStatus.Text = 'NOT READY — run Install.bat'
    $lblStatus.ForeColor = [Drawing.Color]::Orange
    $btnRec.Enabled = $false
}

function Invoke-Ui([scriptblock]$Action) {
    try {
        & $Action
    } catch {
        try {
            Ensure-Dir $script:AppData
            $line = '{0}  {1}' -f (Get-Date).ToString('o'), $_.Exception.ToString()
            Add-Content -LiteralPath (Join-Path $script:AppData 'console.log') -Value $line
        } catch { }
        [Windows.Forms.MessageBox]::Show("Something went wrong, but the window stays open.`n$($_.Exception.Message)", 'Jack Session Console') | Out-Null
    }
}

$btnRec.Add_Click({ Invoke-Ui { Start-Session } })
$btnStop.Add_Click({ Invoke-Ui { Stop-Session } })
$btnMark.Add_Click({ Invoke-Ui { Add-Marker } })
$btnMix.Add_Click({ Invoke-Ui { New-YoutubeMix } })
$btnBrowse.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.SelectedPath = $txtOut.Text
    if ($d.ShowDialog() -eq 'OK') { $txtOut.Text = $d.SelectedPath }
})

$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.Icon = [Drawing.SystemIcons]::Application
$script:Tray.Visible = $true
$script:Tray.Text = 'Jack Session Console'
$script:TrayMenu = New-Object Windows.Forms.ContextMenuStrip
$miShow = New-Object Windows.Forms.ToolStripMenuItem 'Show window'
$miStop = New-Object Windows.Forms.ToolStripMenuItem 'Stop recording'
$miQuit = New-Object Windows.Forms.ToolStripMenuItem 'Quit'
$miShow.Add_Click({ Show-ConsoleWindow })
$miStop.Add_Click({ Invoke-Ui { Stop-Session } })
$miQuit.Add_Click({
    if ($script:Recording) { Invoke-Ui { Stop-Session } }
    $form.Close()
})
[void]$script:TrayMenu.Items.Add($miShow)
[void]$script:TrayMenu.Items.Add($miStop)
[void]$script:TrayMenu.Items.Add($miQuit)
$script:Tray.ContextMenuStrip = $script:TrayMenu
$script:Tray.Add_DoubleClick({ Show-ConsoleWindow })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    if (-not $script:Recording) { return }
    $lblElapsed.Text = Get-Elapsed
    if ($script:Tray) {
        $tip = 'Recording ' + (Get-Elapsed) + ' — click to stop'
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        if ($script:Tray.Text -ne $tip) { $script:Tray.Text = $tip }
    }
})
$timer.Start()

$hot = New-Object JackHotkeys
$hot.Add_HotKeyPressed({
    param($id)
    try {
        switch ($id) {
            1 { if ($script:Recording) { Stop-Session } else { Start-Session } }
            2 { Stop-Session }
            3 { Add-Marker }
        }
    } catch {
        try {
            Ensure-Dir $script:AppData
            $line = '{0}  {1}' -f (Get-Date).ToString('o'), $_.Exception.ToString()
            Add-Content -LiteralPath (Join-Path $script:AppData 'console.log') -Value $line
        } catch { }
        [Windows.Forms.MessageBox]::Show("Something went wrong, but the window stays open.`n$($_.Exception.Message)", 'Jack Session Console') | Out-Null
    }
})
[Windows.Forms.Application]::AddMessageFilter($hot)

$form.Add_Shown({
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 1, 0, 0x78) # F9
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 2, 0, 0x79) # F10
    [void][JackHotkeys]::RegisterHotKey($form.Handle, 3, 0, 0x77) # F8
})
$form.Add_FormClosing({
    param($sender, $e)
    # Closing the window is what used to strand a recording with no Stop button.
    if ($script:Recording -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Show-ConsoleWindow
        $lblMark.Text = 'Still recording — press Stop or F10'
        return
    }
    if ($script:Recording) { Stop-Session }
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 1)
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 2)
    [void][JackHotkeys]::UnregisterHotKey($form.Handle, 3)
    Save-Settings
    $timer.Stop()
    if ($script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
})

$orphanCount = Stop-OrphanFfmpeg
if ($orphanCount -gt 0 -and $script:Ffmpeg) {
    $lblLast.Text = "Stopped $orphanCount leftover recording process(es)."
}

[Windows.Forms.Application]::EnableVisualStyles()
try {
    [void]$form.ShowDialog()
} finally {
    if ($script:Recording) { Stop-Session }
    if ($script:Job) { $script:Job.Dispose(); $script:Job = $null }
    if ($script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
}
